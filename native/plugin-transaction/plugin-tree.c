#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/if_alg.h>
#include <linux/fs.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

enum {
  MAX_DEPTH = 32,
  MAX_ENTRIES = 4096,
  MAX_PATH_BYTES = 1024,
  MAX_FILE_BYTES = 16 * 1024 * 1024,
  COPY_BUFFER_BYTES = 64 * 1024,
  MAX_REQUEST_BYTES = 64 * 1024,
  MAX_JSON_DEPTH = 64,
};

static const uint64_t MAX_TOTAL_BYTES = 64ULL * 1024ULL * 1024ULL;
static const unsigned char DOMAIN[] = "omarchy-runtime-tree-sha256-v1\0";

/*
 * Canonical stream:
 *   DOMAIN
 *   repeated(type:u8, path_length:u32be, path:utf8-bytes,
 *            normalized_mode:u32be, content_length:u64be, content:bytes)
 * Directories have type 'D' and zero content length; files have type 'F'.
 */

typedef struct {
  int hash_fd;
  uint64_t total_bytes;
  size_t entries;
} WalkContext;

typedef struct {
  char *bytes;
  size_t length;
} Name;

static void fd_write_all(int fd, const void *buffer, size_t length,
                         const char *operation, const char *path);

static void fail_io(const char *operation, const char *path) {
  fprintf(stderr, "omarchy-plugin-tree: io: %s: %s: %s\n", operation, path,
          strerror(errno));
  exit(1);
}

static void reject_tree(const char *code, const char *path) {
  fprintf(stderr, "omarchy-plugin-tree: %s: %s\n", code,
          path[0] ? path : ".");
  exit(2);
}

static void operation_not_found(const char *operation_id) {
  fprintf(stderr, "omarchy-plugin-tree: operation-not-found: %s\n",
          operation_id);
  exit(3);
}

static bool valid_utf8(const unsigned char *bytes, size_t length) {
  size_t offset = 0;
  while (offset < length) {
    unsigned char first = bytes[offset++];
    if (first <= 0x7f)
      continue;
    size_t continuation;
    uint32_t codepoint;
    if (first >= 0xc2 && first <= 0xdf) {
      continuation = 1;
      codepoint = first & 0x1f;
    } else if (first >= 0xe0 && first <= 0xef) {
      continuation = 2;
      codepoint = first & 0x0f;
    } else if (first >= 0xf0 && first <= 0xf4) {
      continuation = 3;
      codepoint = first & 0x07;
    } else {
      return false;
    }
    if (continuation > length - offset)
      return false;
    for (size_t index = 0; index < continuation; index++) {
      unsigned char next = bytes[offset++];
      if ((next & 0xc0) != 0x80)
        return false;
      codepoint = (codepoint << 6) | (next & 0x3f);
    }
    if ((continuation == 2 && codepoint < 0x800) ||
        (continuation == 3 && codepoint < 0x10000) || codepoint > 0x10ffff ||
        (codepoint >= 0xd800 && codepoint <= 0xdfff))
      return false;
  }
  return true;
}

typedef struct {
  const unsigned char *bytes;
  size_t length;
  size_t offset;
} JsonParser;

typedef struct {
  unsigned char *bytes;
  size_t length;
  size_t capacity;
} JsonKey;

static void reject_json(const char *reason) {
  reject_tree("invalid-json-request", reason);
}

static void json_skip_whitespace(JsonParser *parser) {
  while (parser->offset < parser->length) {
    unsigned char value = parser->bytes[parser->offset];
    if (value != ' ' && value != '\t' && value != '\n' && value != '\r')
      break;
    parser->offset++;
  }
}

static unsigned int json_hex_digit(unsigned char value) {
  if (value >= '0' && value <= '9')
    return (unsigned int)(value - '0');
  if (value >= 'a' && value <= 'f')
    return (unsigned int)(value - 'a' + 10);
  if (value >= 'A' && value <= 'F')
    return (unsigned int)(value - 'A' + 10);
  reject_json("invalid-unicode-escape");
  return 0;
}

static uint32_t json_unicode_escape(JsonParser *parser) {
  if (parser->length - parser->offset < 4)
    reject_json("truncated-unicode-escape");
  uint32_t value = 0;
  for (size_t index = 0; index < 4; index++) {
    value = (value << 4) | json_hex_digit(parser->bytes[parser->offset]);
    parser->offset++;
  }
  return value;
}

static void json_append_byte(JsonKey *output, unsigned char value) {
  if (output->length == output->capacity) {
    size_t next_capacity = output->capacity == 0 ? 16 : output->capacity * 2;
    if (next_capacity > MAX_REQUEST_BYTES)
      reject_json("string-size-limit");
    unsigned char *next = realloc(output->bytes, next_capacity);
    if (!next)
      fail_io("allocate JSON string", "stdin");
    output->bytes = next;
    output->capacity = next_capacity;
  }
  output->bytes[output->length++] = value;
}

static void json_append_codepoint(JsonKey *output, uint32_t codepoint) {
  if (codepoint <= 0x7f) {
    json_append_byte(output, (unsigned char)codepoint);
  } else if (codepoint <= 0x7ff) {
    json_append_byte(output, (unsigned char)(0xc0 | (codepoint >> 6)));
    json_append_byte(output, (unsigned char)(0x80 | (codepoint & 0x3f)));
  } else if (codepoint <= 0xffff) {
    json_append_byte(output, (unsigned char)(0xe0 | (codepoint >> 12)));
    json_append_byte(output,
                     (unsigned char)(0x80 | ((codepoint >> 6) & 0x3f)));
    json_append_byte(output, (unsigned char)(0x80 | (codepoint & 0x3f)));
  } else {
    json_append_byte(output, (unsigned char)(0xf0 | (codepoint >> 18)));
    json_append_byte(output,
                     (unsigned char)(0x80 | ((codepoint >> 12) & 0x3f)));
    json_append_byte(output,
                     (unsigned char)(0x80 | ((codepoint >> 6) & 0x3f)));
    json_append_byte(output, (unsigned char)(0x80 | (codepoint & 0x3f)));
  }
}

static JsonKey json_parse_string(JsonParser *parser) {
  if (parser->offset >= parser->length || parser->bytes[parser->offset] != '"')
    reject_json("expected-string");
  parser->offset++;
  JsonKey decoded = {0};

  while (parser->offset < parser->length) {
    unsigned char value = parser->bytes[parser->offset++];
    if (value == '"')
      return decoded;
    if (value < 0x20)
      reject_json("unescaped-control-character");
    if (value != '\\') {
      json_append_byte(&decoded, value);
      continue;
    }
    if (parser->offset >= parser->length)
      reject_json("truncated-string-escape");
    unsigned char escaped = parser->bytes[parser->offset++];
    switch (escaped) {
    case '"':
    case '\\':
    case '/':
      json_append_byte(&decoded, escaped);
      break;
    case 'b':
      json_append_byte(&decoded, '\b');
      break;
    case 'f':
      json_append_byte(&decoded, '\f');
      break;
    case 'n':
      json_append_byte(&decoded, '\n');
      break;
    case 'r':
      json_append_byte(&decoded, '\r');
      break;
    case 't':
      json_append_byte(&decoded, '\t');
      break;
    case 'u': {
      uint32_t codepoint = json_unicode_escape(parser);
      if (codepoint >= 0xd800 && codepoint <= 0xdbff) {
        if (parser->length - parser->offset < 6 ||
            parser->bytes[parser->offset] != '\\' ||
            parser->bytes[parser->offset + 1] != 'u')
          reject_json("unpaired-high-surrogate");
        parser->offset += 2;
        uint32_t low = json_unicode_escape(parser);
        if (low < 0xdc00 || low > 0xdfff)
          reject_json("unpaired-high-surrogate");
        codepoint = 0x10000 + ((codepoint - 0xd800) << 10) + (low - 0xdc00);
      } else if (codepoint >= 0xdc00 && codepoint <= 0xdfff) {
        reject_json("unpaired-low-surrogate");
      }
      json_append_codepoint(&decoded, codepoint);
      break;
    }
    default:
      reject_json("invalid-string-escape");
    }
  }
  reject_json("unterminated-string");
  return decoded;
}

static bool json_key_equal(const JsonKey *left, const JsonKey *right) {
  return left->length == right->length &&
         (left->length == 0 ||
          memcmp(left->bytes, right->bytes, left->length) == 0);
}

static bool allow_duplicate_json_keys(void) {
#ifdef OMARCHY_PLUGIN_TREE_TEST_HOOKS
  return getenv("OMARCHY_PLUGIN_TREE_TEST_ALLOW_DUPLICATE_KEYS") != NULL;
#else
  return false;
#endif
}

static void json_parse_value(JsonParser *parser, unsigned int depth);

static void json_parse_object(JsonParser *parser, unsigned int depth) {
  parser->offset++;
  json_skip_whitespace(parser);
  JsonKey *keys = NULL;
  size_t key_count = 0;
  size_t key_capacity = 0;
  if (parser->offset < parser->length && parser->bytes[parser->offset] == '}') {
    parser->offset++;
    return;
  }
  for (;;) {
    JsonKey candidate = json_parse_string(parser);
    if (!allow_duplicate_json_keys()) {
      for (size_t index = 0; index < key_count; index++)
        if (json_key_equal(&keys[index], &candidate))
          reject_json("duplicate-object-key");
    }
    if (key_count == key_capacity) {
      size_t next_capacity = key_capacity == 0 ? 8 : key_capacity * 2;
      JsonKey *next = realloc(keys, next_capacity * sizeof(*next));
      if (!next)
        fail_io("allocate JSON object keys", "stdin");
      keys = next;
      key_capacity = next_capacity;
    }
    keys[key_count++] = candidate;
    json_skip_whitespace(parser);
    if (parser->offset >= parser->length || parser->bytes[parser->offset] != ':')
      reject_json("expected-object-colon");
    parser->offset++;
    json_skip_whitespace(parser);
    json_parse_value(parser, depth + 1);
    json_skip_whitespace(parser);
    if (parser->offset >= parser->length)
      reject_json("unterminated-object");
    unsigned char separator = parser->bytes[parser->offset++];
    if (separator == '}')
      break;
    if (separator != ',')
      reject_json("expected-object-separator");
    json_skip_whitespace(parser);
  }
  for (size_t index = 0; index < key_count; index++)
    free(keys[index].bytes);
  free(keys);
}

static void json_parse_array(JsonParser *parser, unsigned int depth) {
  parser->offset++;
  json_skip_whitespace(parser);
  if (parser->offset < parser->length && parser->bytes[parser->offset] == ']') {
    parser->offset++;
    return;
  }
  for (;;) {
    json_parse_value(parser, depth + 1);
    json_skip_whitespace(parser);
    if (parser->offset >= parser->length)
      reject_json("unterminated-array");
    unsigned char separator = parser->bytes[parser->offset++];
    if (separator == ']')
      return;
    if (separator != ',')
      reject_json("expected-array-separator");
    json_skip_whitespace(parser);
  }
}

static void json_parse_literal(JsonParser *parser, const char *literal) {
  size_t length = strlen(literal);
  if (length > parser->length - parser->offset ||
      memcmp(parser->bytes + parser->offset, literal, length) != 0)
    reject_json("invalid-literal");
  parser->offset += length;
}

static void json_parse_number(JsonParser *parser) {
  size_t offset = parser->offset;
  if (parser->bytes[offset] == '-') {
    offset++;
    if (offset >= parser->length)
      reject_json("invalid-number");
  }
  if (parser->bytes[offset] == '0') {
    offset++;
    if (offset < parser->length && parser->bytes[offset] >= '0' &&
        parser->bytes[offset] <= '9')
      reject_json("invalid-number-leading-zero");
  } else {
    if (parser->bytes[offset] < '1' || parser->bytes[offset] > '9')
      reject_json("invalid-number");
    do {
      offset++;
    } while (offset < parser->length && parser->bytes[offset] >= '0' &&
             parser->bytes[offset] <= '9');
  }
  if (offset < parser->length && parser->bytes[offset] == '.') {
    offset++;
    if (offset >= parser->length || parser->bytes[offset] < '0' ||
        parser->bytes[offset] > '9')
      reject_json("invalid-number-fraction");
    do {
      offset++;
    } while (offset < parser->length && parser->bytes[offset] >= '0' &&
             parser->bytes[offset] <= '9');
  }
  if (offset < parser->length &&
      (parser->bytes[offset] == 'e' || parser->bytes[offset] == 'E')) {
    offset++;
    if (offset < parser->length &&
        (parser->bytes[offset] == '+' || parser->bytes[offset] == '-'))
      offset++;
    if (offset >= parser->length || parser->bytes[offset] < '0' ||
        parser->bytes[offset] > '9')
      reject_json("invalid-number-exponent");
    do {
      offset++;
    } while (offset < parser->length && parser->bytes[offset] >= '0' &&
             parser->bytes[offset] <= '9');
  }
  parser->offset = offset;
}

static void json_parse_value(JsonParser *parser, unsigned int depth) {
  if (depth > MAX_JSON_DEPTH)
    reject_json("depth-limit");
  if (parser->offset >= parser->length)
    reject_json("missing-value");
  switch (parser->bytes[parser->offset]) {
  case '{':
    json_parse_object(parser, depth);
    break;
  case '[':
    json_parse_array(parser, depth);
    break;
  case '"': {
    JsonKey value = json_parse_string(parser);
    free(value.bytes);
    break;
  }
  case 't':
    json_parse_literal(parser, "true");
    break;
  case 'f':
    json_parse_literal(parser, "false");
    break;
  case 'n':
    json_parse_literal(parser, "null");
    break;
  default:
    json_parse_number(parser);
  }
}

static void validate_json_request(void) {
  unsigned char *buffer = malloc((size_t)MAX_REQUEST_BYTES + 1);
  if (!buffer)
    fail_io("allocate JSON request", "stdin");
  size_t length = 0;
  while (length < (size_t)MAX_REQUEST_BYTES + 1) {
    ssize_t received = read(STDIN_FILENO, buffer + length,
                            (size_t)MAX_REQUEST_BYTES + 1 - length);
    if (received < 0) {
      if (errno == EINTR)
        continue;
      fail_io("read JSON request", "stdin");
    }
    if (received == 0)
      break;
    length += (size_t)received;
  }
  if (length > MAX_REQUEST_BYTES)
    reject_tree("request-size-limit", "stdin");
  if (length == 0)
    reject_tree("empty-request", "stdin");
  if (memchr(buffer, 0, length))
    reject_tree("literal-nul", "stdin");
  if (!valid_utf8(buffer, length))
    reject_tree("invalid-utf8", "stdin");

  JsonParser parser = {.bytes = buffer, .length = length, .offset = 0};
  json_skip_whitespace(&parser);
  json_parse_value(&parser, 0);
  json_skip_whitespace(&parser);
  if (parser.offset != parser.length)
    reject_json("trailing-data");
  fd_write_all(STDOUT_FILENO, buffer, length, "write JSON request", "stdout");
  free(buffer);
}

#ifdef OMARCHY_PLUGIN_TREE_TEST_HOOKS
static bool inject_zero_write(void) {
  static bool consumed = false;
  if (!consumed && getenv("OMARCHY_PLUGIN_TREE_TEST_ZERO_WRITE")) {
    consumed = true;
    return true;
  }
  return false;
}

static bool inject_zero_hash_send(void) {
  static bool consumed = false;
  if (!consumed && getenv("OMARCHY_PLUGIN_TREE_TEST_ZERO_HASH_SEND")) {
    consumed = true;
    return true;
  }
  return false;
}

static ssize_t read_lock_input(int fd, void *buffer, size_t length) {
  static bool consumed = false;
  if (!consumed && getenv("OMARCHY_PLUGIN_TREE_TEST_EINTR_LOCK_READ")) {
    consumed = true;
    errno = EINTR;
    return -1;
  }
  return read(fd, buffer, length);
}
#else
static bool inject_zero_write(void) { return false; }
static bool inject_zero_hash_send(void) { return false; }
static ssize_t read_lock_input(int fd, void *buffer, size_t length) {
  return read(fd, buffer, length);
}
#endif

static void fd_write_all(int fd, const void *buffer, size_t length,
                         const char *operation, const char *path) {
  const unsigned char *cursor = buffer;
  while (length > 0) {
    bool inject = strcmp(operation, "write destination file") == 0 &&
                  inject_zero_write();
    ssize_t written = inject ? 0 : write(fd, cursor, length);
    if (written < 0)
      fail_io(operation, path);
    if (written == 0) {
      errno = EIO;
      fail_io(operation, path);
    }
    cursor += (size_t)written;
    length -= (size_t)written;
  }
}

static void hash_update(int fd, const void *buffer, size_t length,
                        const char *path) {
  const unsigned char *cursor = buffer;
  while (length > 0) {
    ssize_t written =
        inject_zero_hash_send() ? 0 : send(fd, cursor, length, MSG_MORE);
    if (written < 0)
      fail_io("hash update", path);
    if (written == 0) {
      errno = EIO;
      fail_io("hash update", path);
    }
    cursor += (size_t)written;
    length -= (size_t)written;
  }
}

static void hash_u32(int fd, uint32_t value, const char *path) {
  unsigned char encoded[4] = {
      (unsigned char)(value >> 24), (unsigned char)(value >> 16),
      (unsigned char)(value >> 8), (unsigned char)value};
  hash_update(fd, encoded, sizeof(encoded), path);
}

static void hash_u64(int fd, uint64_t value, const char *path) {
  unsigned char encoded[8];
  for (size_t index = 0; index < sizeof(encoded); index++)
    encoded[index] = (unsigned char)(value >> (56 - index * 8));
  hash_update(fd, encoded, sizeof(encoded), path);
}

static mode_t normalized_mode(mode_t mode, bool directory) {
  if (directory)
    return 0755;
  return (mode & 0111) ? 0755 : 0644;
}

static bool same_stat(const struct stat *before, const struct stat *after,
                      bool directory) {
  return before->st_dev == after->st_dev && before->st_ino == after->st_ino &&
         before->st_mode == after->st_mode && before->st_size == after->st_size &&
         before->st_nlink == after->st_nlink &&
         normalized_mode(before->st_mode, directory) ==
             normalized_mode(after->st_mode, directory) &&
         before->st_mtim.tv_sec == after->st_mtim.tv_sec &&
         before->st_mtim.tv_nsec == after->st_mtim.tv_nsec &&
         before->st_ctim.tv_sec == after->st_ctim.tv_sec &&
         before->st_ctim.tv_nsec == after->st_ctim.tv_nsec;
}

#ifdef OMARCHY_PLUGIN_TREE_TEST_HOOKS
static void test_hook(const char *name) {
  const char *crash = getenv("OMARCHY_PLUGIN_TREE_TEST_CRASH_POINT");
  if (crash && strcmp(crash, name) == 0)
    _exit(86);
  const char *selected = getenv("OMARCHY_PLUGIN_TREE_TEST_HOOK");
  if (!selected || strcmp(selected, name) != 0)
    return;
  const char *ready = getenv("OMARCHY_PLUGIN_TREE_TEST_READY_FIFO");
  const char *resume = getenv("OMARCHY_PLUGIN_TREE_TEST_RESUME_FIFO");
  if (!ready || !resume)
    reject_tree("invalid-test-hook", name);
  int ready_fd = open(ready, O_WRONLY | O_CLOEXEC);
  if (ready_fd < 0)
    fail_io("open ready fifo", ready);
  fd_write_all(ready_fd, name, strlen(name), "write test-hook marker", ready);
  close(ready_fd);
  int resume_fd = open(resume, O_RDONLY | O_CLOEXEC);
  if (resume_fd < 0)
    fail_io("open resume fifo", resume);
  char byte;
  if (read(resume_fd, &byte, 1) != 1)
    fail_io("read resume fifo", resume);
  close(resume_fd);
}

static bool test_fsync_failure(const char *name) {
  static bool consumed = false;
  const char *selected = getenv("OMARCHY_PLUGIN_TREE_TEST_FAIL_FSYNC");
  if (!consumed && selected && strcmp(selected, name) == 0) {
    consumed = true;
    errno = EIO;
    return true;
  }
  return false;
}

static bool test_rename_failure(const char *name) {
  static bool consumed = false;
  const char *selected = getenv("OMARCHY_PLUGIN_TREE_TEST_FAIL_RENAME");
  if (!consumed && selected && strcmp(selected, name) == 0) {
    consumed = true;
    errno = EIO;
    return true;
  }
  return false;
}
#else
static void test_hook(const char *name) { (void)name; }
static bool test_fsync_failure(const char *name) {
  (void)name;
  return false;
}
static bool test_rename_failure(const char *name) {
  (void)name;
  return false;
}
#endif

static int sync_fd(int fd, const char *point) {
  if (test_fsync_failure(point))
    return -1;
  return fsync(fd);
}

static int compare_names(const void *left_pointer, const void *right_pointer) {
  const Name *left = left_pointer;
  const Name *right = right_pointer;
  size_t common = left->length < right->length ? left->length : right->length;
  int compared = memcmp(left->bytes, right->bytes, common);
  if (compared != 0)
    return compared;
  return (left->length > right->length) - (left->length < right->length);
}

static void emit_record_header(WalkContext *context, unsigned char type,
                               const char *path, size_t path_length,
                               mode_t mode, uint64_t length) {
  if (context->hash_fd < 0)
    return;
  hash_update(context->hash_fd, &type, 1, path);
  hash_u32(context->hash_fd, (uint32_t)path_length, path);
  hash_update(context->hash_fd, path, path_length, path);
  hash_u32(context->hash_fd, (uint32_t)mode, path);
  hash_u64(context->hash_fd, length, path);
}

static void build_path(char output[MAX_PATH_BYTES + 1], const char *prefix,
                       size_t prefix_length, const Name *name) {
  size_t separator = prefix_length ? 1 : 0;
  if (name->length > MAX_PATH_BYTES ||
      prefix_length > MAX_PATH_BYTES - separator - name->length)
    reject_tree("path-limit", prefix);
  memcpy(output, prefix, prefix_length);
  if (separator)
    output[prefix_length] = '/';
  memcpy(output + prefix_length + separator, name->bytes, name->length);
  output[prefix_length + separator + name->length] = '\0';
}

static void free_names(Name *names, size_t count) {
  for (size_t index = 0; index < count; index++)
    free(names[index].bytes);
  free(names);
}

static Name *read_names(int directory_fd, const char *path, unsigned depth,
                        WalkContext *context, size_t *count_out) {
  int duplicate = dup(directory_fd);
  if (duplicate < 0)
    fail_io("duplicate directory", path);
  DIR *directory = fdopendir(duplicate);
  if (!directory)
    fail_io("open directory stream", path);
  Name *names = NULL;
  size_t count = 0;
#ifdef OMARCHY_PLUGIN_TREE_TEST_HOOKS
  bool inject_stale_errno =
      getenv("OMARCHY_PLUGIN_TREE_TEST_STALE_READDIR_ERRNO") != NULL;
  bool inject_readdir_error =
      getenv("OMARCHY_PLUGIN_TREE_TEST_READDIR_ERROR") != NULL;
#endif
  for (;;) {
    errno = 0;
    struct dirent *entry;
#ifdef OMARCHY_PLUGIN_TREE_TEST_HOOKS
    if (inject_readdir_error) {
      inject_readdir_error = false;
      errno = EIO;
      entry = NULL;
    } else {
      entry = readdir(directory);
    }
#else
    entry = readdir(directory);
#endif
    if (!entry) {
      int read_error = errno;
      if (read_error != 0) {
        errno = read_error;
        fail_io("read directory", path);
      }
      break;
    }
    size_t length = strlen(entry->d_name);
    if ((length == 1 && entry->d_name[0] == '.') ||
        (length == 2 && memcmp(entry->d_name, "..", 2) == 0))
      continue;
    if (!valid_utf8((const unsigned char *)entry->d_name, length))
      reject_tree("invalid-utf8", path);
    if (length == 4 && memcmp(entry->d_name, ".git", 4) == 0) {
      if (depth == 0)
        continue;
      reject_tree("nested-git", path);
    }
    if (context->entries >= MAX_ENTRIES || count >= MAX_ENTRIES - context->entries)
      reject_tree("entry-limit", path);
    if (count == SIZE_MAX / sizeof(*names))
      reject_tree("allocation-overflow", path);
    Name *grown = realloc(names, (count + 1) * sizeof(*names));
    if (!grown)
      fail_io("allocate names", path);
    names = grown;
    names[count].bytes = malloc(length + 1);
    if (!names[count].bytes)
      fail_io("allocate name", path);
    memcpy(names[count].bytes, entry->d_name, length + 1);
    names[count].length = length;
    count++;
#ifdef OMARCHY_PLUGIN_TREE_TEST_HOOKS
    if (inject_stale_errno) {
      inject_stale_errno = false;
      errno = EINVAL;
    }
#endif
  }
  closedir(directory);
  if (count > 1)
    qsort(names, count, sizeof(*names), compare_names);
  *count_out = count;
  return names;
}

static void walk_tree(int directory_fd, int destination_fd, const char *prefix,
                      unsigned depth, WalkContext *context) {
  if (depth > MAX_DEPTH)
    reject_tree("depth-limit", prefix);
  struct stat directory_before;
  if (fstat(directory_fd, &directory_before) < 0)
    fail_io("stat directory", prefix);
  if (!S_ISDIR(directory_before.st_mode))
    reject_tree("not-directory", prefix);

  size_t count;
  Name *names = read_names(directory_fd, prefix, depth, context, &count);
  size_t prefix_length = strlen(prefix);
  for (size_t index = 0; index < count; index++) {
    char path[MAX_PATH_BYTES + 1];
    build_path(path, prefix, prefix_length, &names[index]);
    if (depth >= MAX_DEPTH)
      reject_tree("depth-limit", path);
    if (context->entries >= MAX_ENTRIES)
      reject_tree("entry-limit", path);
    context->entries++;

    struct stat path_stat;
    if (fstatat(directory_fd, names[index].bytes, &path_stat,
                AT_SYMLINK_NOFOLLOW) < 0)
      fail_io("stat entry", path);
    if (S_ISLNK(path_stat.st_mode))
      reject_tree("symlink", path);
    if (S_ISDIR(path_stat.st_mode)) {
      emit_record_header(context, 'D', path, strlen(path), 0755, 0);
      if (destination_fd >= 0 &&
          mkdirat(destination_fd, names[index].bytes, 0755) < 0)
        fail_io("create destination directory", path);
      int child = openat(directory_fd, names[index].bytes,
                         O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      if (child < 0)
        fail_io("open directory", path);
      struct stat opened;
      if (fstat(child, &opened) < 0)
        fail_io("stat opened directory", path);
      if (path_stat.st_dev != opened.st_dev || path_stat.st_ino != opened.st_ino)
        reject_tree("tree-changed", path);
      int destination_child = -1;
      if (destination_fd >= 0) {
        destination_child =
            openat(destination_fd, names[index].bytes,
                   O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (destination_child < 0)
          fail_io("open destination directory", path);
        if (fchmod(destination_child, 0755) < 0)
          fail_io("set destination directory mode", path);
      }
      walk_tree(child, destination_child, path, depth + 1, context);
      if (destination_child >= 0) {
        if (sync_fd(destination_child, "destination-directory") < 0)
          fail_io("sync destination directory", path);
        close(destination_child);
      }
      close(child);
    } else if (S_ISREG(path_stat.st_mode)) {
      test_hook("before-regular-entry-open");
      int pinned = openat(directory_fd, names[index].bytes,
                          O_PATH | O_NOFOLLOW | O_CLOEXEC);
      if (pinned < 0)
        fail_io("pin file", path);
      struct stat pinned_stat;
      if (fstat(pinned, &pinned_stat) < 0)
        fail_io("stat pinned file", path);
      if (!S_ISREG(pinned_stat.st_mode))
        reject_tree("special-file", path);
      if (!same_stat(&path_stat, &pinned_stat, false))
        reject_tree("tree-changed", path);
      if (pinned_stat.st_nlink != 1)
        reject_tree("hard-link", path);
      if (pinned_stat.st_size < 0 ||
          (uint64_t)pinned_stat.st_size > MAX_FILE_BYTES)
        reject_tree("file-size-limit", path);
      uint64_t file_size = (uint64_t)pinned_stat.st_size;
      if (file_size > MAX_TOTAL_BYTES - context->total_bytes)
        reject_tree("total-size-limit", path);
      char pinned_path[64];
      int pinned_path_length = snprintf(pinned_path, sizeof(pinned_path),
                                        "/proc/self/fd/%d", pinned);
      if (pinned_path_length < 0 ||
          (size_t)pinned_path_length >= sizeof(pinned_path))
        reject_tree("descriptor-path-overflow", path);
      int file = open(pinned_path, O_RDONLY | O_CLOEXEC);
      if (file < 0)
        fail_io("open pinned file", path);
      struct stat opened;
      if (fstat(file, &opened) < 0)
        fail_io("stat opened file", path);
      if (!same_stat(&pinned_stat, &opened, false))
        reject_tree("tree-changed", path);
      close(pinned);
      emit_record_header(context, 'F', path, strlen(path),
                         normalized_mode(opened.st_mode, false), file_size);
      int destination_file = -1;
      if (destination_fd >= 0) {
        destination_file =
            openat(destination_fd, names[index].bytes,
                   O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (destination_file < 0)
          fail_io("create destination file", path);
        if (fchmod(destination_file, normalized_mode(opened.st_mode, false)) < 0)
          fail_io("set destination mode", path);
      }
      unsigned char buffer[COPY_BUFFER_BYTES];
      uint64_t remaining = file_size;
      while (remaining > 0) {
        size_t requested = remaining < sizeof(buffer) ? (size_t)remaining
                                                       : sizeof(buffer);
        ssize_t received = read(file, buffer, requested);
        if (received < 0)
          fail_io("read file", path);
        if (received == 0)
          reject_tree("tree-changed", path);
        if (context->hash_fd >= 0)
          hash_update(context->hash_fd, buffer, (size_t)received, path);
        if (destination_file >= 0)
          fd_write_all(destination_file, buffer, (size_t)received,
                       "write destination file", path);
        remaining -= (uint64_t)received;
      }
      test_hook("before-file-restat");
      struct stat after;
      if (fstat(file, &after) < 0)
        fail_io("restat file", path);
      close(file);
      if (!same_stat(&opened, &after, false))
        reject_tree("tree-changed", path);
      if (destination_file >= 0) {
        if (sync_fd(destination_file, "destination-file") < 0)
          fail_io("sync destination file", path);
        close(destination_file);
      }
      context->total_bytes += file_size;
    } else {
      reject_tree("special-file", path);
    }
  }
  free_names(names, count);
  struct stat directory_after;
  if (fstat(directory_fd, &directory_after) < 0)
    fail_io("restat directory", prefix);
  if (!same_stat(&directory_before, &directory_after, true))
    reject_tree("tree-changed", prefix);
}

static int open_hash(void) {
  int algorithm = socket(AF_ALG, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
  if (algorithm < 0)
    fail_io("open sha256", "AF_ALG");
  struct sockaddr_alg address = {.salg_family = AF_ALG,
                                 .salg_type = "hash",
                                 .salg_name = "sha256"};
  if (bind(algorithm, (struct sockaddr *)&address, sizeof(address)) < 0)
    fail_io("bind sha256", "AF_ALG");
  int hash = accept4(algorithm, NULL, NULL, SOCK_CLOEXEC);
  close(algorithm);
  if (hash < 0)
    fail_io("accept sha256", "AF_ALG");
  return hash;
}

static void print_identity(const char *root_path) {
  int root = open(root_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (root < 0)
    fail_io("open root", root_path);
  test_hook("after-root-open");
  int hash = open_hash();
  hash_update(hash, DOMAIN, sizeof(DOMAIN) - 1, ".");
  WalkContext context = {.hash_fd = hash, .total_bytes = 0, .entries = 0};
  walk_tree(root, -1, "", 0, &context);
  close(root);
  if (send(hash, NULL, 0, 0) < 0)
    fail_io("finalize sha256", "AF_ALG");
  unsigned char digest[32];
  ssize_t received = read(hash, digest, sizeof(digest));
  close(hash);
  if (received != (ssize_t)sizeof(digest))
    fail_io("read sha256", "AF_ALG");
  test_hook("after-identity");
  fputs("omarchy-runtime-tree-sha256-v1:", stdout);
  for (size_t index = 0; index < sizeof(digest); index++)
    printf("%02x", digest[index]);
  fputc('\n', stdout);
}

/* Compute an identity from an already opened, no-follow directory.  O-8
 * namespace operations use this descriptor-pinned boundary for every
 * precheck and postcheck; the operation never hashes a caller-replaceable
 * pathname. */
static void identity_from_fd(int root, char output[96]) {
  int hash = open_hash();
  hash_update(hash, DOMAIN, sizeof(DOMAIN) - 1, ".");
  WalkContext context = {.hash_fd = hash, .total_bytes = 0, .entries = 0};
  walk_tree(root, -1, "", 0, &context);
  if (send(hash, NULL, 0, 0) < 0)
    fail_io("finalize sha256", "AF_ALG");
  unsigned char digest[32];
  ssize_t received = read(hash, digest, sizeof(digest));
  close(hash);
  if (received != (ssize_t)sizeof(digest))
    fail_io("read sha256", "AF_ALG");
  int length = snprintf(output, 96, "omarchy-runtime-tree-sha256-v1:");
  if (length < 0 || length >= 96)
    fail_io("format identity", "namespace");
  for (size_t index = 0; index < sizeof(digest); index++)
    snprintf(output + 31 + index * 2, 3, "%02x", digest[index]);
}

static bool identity_matches(const char *actual, const char *expected) {
  return expected != NULL && strlen(expected) == 95 &&
         strcmp(actual, expected) == 0;
}

static bool simple_name(const char *name);

static void emit_namespace_result(const char *status, const char *operation,
                                  const char *source, const char *destination,
                                  const char *detail, int exit_code) {
  printf("{\"destinationIdentity\":\"%s\",\"operation\":\"%s\","
         "\"sourceIdentity\":\"%s\",\"status\":\"%s\","
         "\"detail\":\"%s\"}\n",
         destination != NULL ? destination : "", operation, source, status,
         detail != NULL ? detail : "");
  fflush(stdout);
  exit(exit_code);
}

static int open_namespace_parent(const char *path, const char *description) {
  int parent = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (parent < 0)
    fail_io(description, path);
  struct stat status;
  if (fstat(parent, &status) < 0)
    fail_io("stat namespace parent", path);
  if (!S_ISDIR(status.st_mode) || status.st_nlink < 1)
    reject_tree("invalid-namespace-parent", path);
  return parent;
}

static void namespace_mutate(const char *operation, const char *source_parent,
                             const char *source_name, const char *dest_parent,
                             const char *dest_name, const char *expected_source,
                             const char *expected_destination) {
  if (!simple_name(source_name) || !simple_name(dest_name))
    reject_tree("invalid-namespace-entry", "namespace");
  int source_directory = open_namespace_parent(source_parent,
                                                "open candidate parent");
  int destination_directory = open_namespace_parent(dest_parent,
                                                     "open discovery parent");
  struct stat source_parent_stat;
  struct stat destination_parent_stat;
  if (fstat(source_directory, &source_parent_stat) < 0 ||
      fstat(destination_directory, &destination_parent_stat) < 0)
    fail_io("stat namespace parent", "namespace");
  if (source_parent_stat.st_dev != destination_parent_stat.st_dev)
    emit_namespace_result("unsupported-atomic-operation", operation, "", "",
                          "different-filesystem", 4);

  struct stat source_stat;
  if (fstatat(source_directory, source_name, &source_stat,
              AT_SYMLINK_NOFOLLOW) < 0)
    fail_io("stat namespace source", source_name);
  if (!S_ISDIR(source_stat.st_mode))
    emit_namespace_result("stale-candidate", operation, "", "",
                          "source-not-directory", 2);
  int source = openat(source_directory, source_name,
                      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (source < 0)
    fail_io("open namespace source", source_name);
  char source_identity[96];
  identity_from_fd(source, source_identity);
  if (!identity_matches(source_identity, expected_source))
    emit_namespace_result("stale-candidate", operation, source_identity, "",
                          "source-identity-mismatch", 2);

  struct stat destination_stat;
  bool destination_exists =
      fstatat(destination_directory, dest_name, &destination_stat,
              AT_SYMLINK_NOFOLLOW) == 0;
  if (strcmp(operation, "install") == 0 ||
      strcmp(operation, "rollback-install") == 0) {
    if (destination_exists)
      emit_namespace_result("destination-unexpectedly-present", operation,
                            source_identity, "", "noreplace-destination", 2);
  } else {
    if (!destination_exists || !S_ISDIR(destination_stat.st_mode))
      emit_namespace_result("stale-active-tree", operation, source_identity,
                            "", "exchange-destination", 2);
    int destination = openat(destination_directory, dest_name,
                              O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (destination < 0)
      fail_io("open namespace destination", dest_name);
    char active_identity[96];
    identity_from_fd(destination, active_identity);
    close(destination);
    if (!identity_matches(active_identity, expected_destination))
      emit_namespace_result("stale-active-tree", operation, source_identity,
                            active_identity, "destination-identity-mismatch", 2);
  }

  bool exchange = strcmp(operation, "exchange") == 0 ||
                  strcmp(operation, "rollback-exchange") == 0;
  const unsigned int flags = exchange ? RENAME_EXCHANGE : RENAME_NOREPLACE;
  const char *fault_name = exchange ? "namespace-exchange" : "namespace-install";
  test_hook(exchange ? "before-namespace-exchange" : "before-namespace-install");
  if (test_rename_failure(fault_name))
    emit_namespace_result("definitely-not-performed", operation, source_identity,
                          "", "rename-failed", 3);
  if (syscall(SYS_renameat2, source_directory, source_name,
              destination_directory, dest_name, flags) < 0) {
    if (errno == ENOSYS || errno == EINVAL)
      emit_namespace_result("unsupported-atomic-operation", operation,
                            source_identity, "", "renameat2", 4);
    if (errno == EEXIST)
      emit_namespace_result("destination-unexpectedly-present", operation,
                            source_identity, "", "noreplace-destination", 2);
    fail_io("rename namespace", dest_name);
  }
  test_hook(exchange ? "after-namespace-exchange" : "after-namespace-install");

  int saved_errno = 0;
  if (sync_fd(source_directory, "namespace-candidate-parent") < 0)
    saved_errno = errno;
  if (saved_errno == 0 && sync_fd(destination_directory,
                                  "namespace-discovery-parent") < 0)
    saved_errno = errno;
  if (saved_errno != 0) {
    bool compensated = false;
    if (exchange) {
      compensated = syscall(SYS_renameat2, source_directory, source_name,
                            destination_directory, dest_name,
                            RENAME_EXCHANGE) == 0;
    } else {
      compensated = syscall(SYS_renameat2, destination_directory, dest_name,
                            source_directory, source_name,
                            RENAME_NOREPLACE) == 0;
    }
    if (compensated && sync_fd(source_directory,
                               "namespace-candidate-parent") == 0 &&
        sync_fd(destination_directory, "namespace-discovery-parent") == 0) {
      close(source);
      close(source_directory);
      close(destination_directory);
      emit_namespace_result("completed-and-exactly-compensated", operation,
                            source_identity, "", "parent-sync-failed", 0);
    }
    close(source);
    close(source_directory);
    close(destination_directory);
    emit_namespace_result("indeterminate-namespace", operation, source_identity,
                          "", "parent-sync-failed", 5);
  }
  close(source);
  int destination = openat(destination_directory, dest_name,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (destination < 0)
    emit_namespace_result("exact-postcheck-mismatch", operation, source_identity,
                          "", "destination-missing", 5);
  char destination_identity[96];
  identity_from_fd(destination, destination_identity);
  close(destination);
  if (exchange) {
    struct stat retained_status;
    if (fstatat(source_directory, source_name, &retained_status,
                AT_SYMLINK_NOFOLLOW) < 0)
      emit_namespace_result("exact-postcheck-mismatch", operation,
                            source_identity, destination_identity,
                            errno == ENOENT ? "retained-source-missing"
                                            : "retained-source-unreadable",
                            5);
    if (!S_ISDIR(retained_status.st_mode))
      emit_namespace_result("exact-postcheck-mismatch", operation,
                            source_identity, destination_identity,
                            "retained-source-not-directory", 5);
    int retained = openat(source_directory, source_name,
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (retained < 0)
      fail_io("open retained source", source_name);
    char retained_identity[96];
    identity_from_fd(retained, retained_identity);
    close(retained);
    if (!identity_matches(retained_identity, expected_destination))
      emit_namespace_result("exact-postcheck-mismatch", operation,
                            source_identity, destination_identity,
                            "retained-source-identity-mismatch", 5);
  } else {
    struct stat source_after;
    if (fstatat(source_directory, source_name, &source_after,
                AT_SYMLINK_NOFOLLOW) == 0)
      emit_namespace_result("exact-postcheck-mismatch", operation,
                            source_identity, destination_identity,
                            "source-slot-still-present", 5);
    if (errno != ENOENT)
      emit_namespace_result("indeterminate-namespace", operation,
                            source_identity, destination_identity,
                            "source-slot-unreadable", 5);
  }
  close(source_directory);
  close(destination_directory);
  if (!identity_matches(destination_identity, expected_source))
    emit_namespace_result("exact-postcheck-mismatch", operation, source_identity,
                          destination_identity, "candidate-not-live", 5);
  emit_namespace_result("completed-durable", operation, source_identity,
                        destination_identity, "", 0);
}

static bool simple_name(const char *name) {
  size_t length = strlen(name);
  return length > 0 && length <= 128 && strcmp(name, ".") != 0 &&
         strcmp(name, "..") != 0 && strchr(name, '/') == NULL &&
         valid_utf8((const unsigned char *)name, length);
}

static bool third_party_plugin_id(const char *name) {
  size_t length = strlen(name);
  if (length == 0 || length > 128 || strstr(name, "..") != NULL ||
      strncmp(name, "omarchy.", 8) == 0)
    return false;
  for (size_t index = 0; index < length; index++) {
    unsigned char value = (unsigned char)name[index];
    if (!((value >= 'A' && value <= 'Z') ||
          (value >= 'a' && value <= 'z') ||
          (value >= '0' && value <= '9') || value == '.' || value == '_' ||
          value == '-'))
      return false;
  }
  return true;
}

static void copy_snapshot(const char *source_path, const char *parent_path,
                          const char *name) {
  if (!simple_name(name))
    reject_tree("invalid-destination-name", name);
  int source =
      open(source_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (source < 0)
    fail_io("open root", source_path);
  int parent =
      open(parent_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (parent < 0)
    fail_io("open destination parent", parent_path);
  test_hook("before-import-temporary-create");
  if (mkdirat(parent, name, 0700) < 0)
    fail_io("create destination root", name);
  test_hook("after-import-temporary-create");
  int destination =
      openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (destination < 0)
    fail_io("open destination root", name);

  WalkContext context = {.hash_fd = -1, .total_bytes = 0, .entries = 0};
  test_hook("after-root-open");
  walk_tree(source, destination, "", 0, &context);
  close(source);
  if (sync_fd(destination, "destination-root") < 0)
    fail_io("sync destination root", name);
  close(destination);
  if (sync_fd(parent, "destination-parent") < 0)
    fail_io("sync destination parent", parent_path);
  close(parent);
}

static void prepare_import(const char *source_path, const char *store_path,
                           const char *temporary) {
  if (!simple_name(temporary))
    reject_tree("invalid-destination-name", temporary);
  int store =
      open(store_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (store < 0)
    fail_io("open candidate store", store_path);
  test_hook("before-import-directory-create");
  if (mkdirat(store, temporary, 0700) < 0)
    fail_io("create import directory", temporary);
  test_hook("after-import-directory-create");
  if (sync_fd(store, "import-directory-parent") < 0)
    fail_io("sync import directory parent", store_path);
  close(store);
  size_t required = strlen(store_path) + 1 + strlen(temporary) + 1;
  char *operation_path = malloc(required);
  if (!operation_path)
    fail_io("allocate import path", temporary);
  int length = snprintf(operation_path, required, "%s/%s", store_path,
                        temporary);
  if (length < 0 || (size_t)length >= required)
    reject_tree("path-limit", temporary);
  copy_snapshot(source_path, operation_path, "candidate");
  test_hook("after-import-copy");
  free(operation_path);
}

static void publish_snapshot(const char *parent_path, const char *temporary,
                             const char *completed) {
  if (!simple_name(temporary) || !simple_name(completed))
    reject_tree("invalid-destination-name", parent_path);
  int parent =
      open(parent_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (parent < 0)
    fail_io("open publication parent", parent_path);
  int operation =
      openat(parent, temporary, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (operation < 0)
    fail_io("open operation directory", temporary);
  int record = openat(operation, "result.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (record < 0)
    fail_io("open completed record", temporary);
  struct stat record_stat;
  if (fstat(record, &record_stat) < 0)
    fail_io("stat completed record", temporary);
  if (!S_ISREG(record_stat.st_mode) || record_stat.st_nlink != 1)
    reject_tree("invalid-completed-record", temporary);
  if (sync_fd(record, "completed-record") < 0)
    fail_io("sync completed record", temporary);
  close(record);
  if (sync_fd(operation, "completed-operation") < 0)
    fail_io("sync completed operation", temporary);
  close(operation);

  test_hook("before-publication");
  if (syscall(SYS_renameat2, parent, temporary, parent, completed,
              RENAME_NOREPLACE) < 0) {
    if (errno == EEXIST)
      reject_tree("destination-exists", completed);
    fail_io("publish destination", completed);
  }
  test_hook("after-publication-rename");
  if (sync_fd(parent, "publication-parent") < 0) {
    int publication_error = errno;
    if (syscall(SYS_renameat2, parent, completed, parent, temporary,
                RENAME_NOREPLACE) == 0) {
      if (sync_fd(parent, "publication-rollback-parent") == 0) {
        errno = publication_error;
        reject_tree("publication-rolled-back", completed);
      }
      reject_tree("publication-indeterminate", temporary);
    }
    reject_tree("publication-indeterminate", completed);
  }
  close(parent);
}

static void ensure_private_directory_at(int parent, const char *name) {
  bool created = false;
  if (mkdirat(parent, name, 0700) < 0) {
    if (errno != EEXIST)
      fail_io("create state directory", name);
  } else {
    created = true;
  }
  int directory =
      openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (directory < 0)
    fail_io("open state directory", name);
  struct stat status;
  if (fstat(directory, &status) < 0)
    fail_io("stat state directory", name);
  if (!S_ISDIR(status.st_mode))
    reject_tree("invalid-state-directory", name);
  if (fchmod(directory, 0700) < 0)
    fail_io("set state directory mode", name);
  if (created && sync_fd(parent, "state-directory-parent") < 0)
    fail_io("sync state directory parent", name);
  close(directory);
}

static int open_private_state_root(const char *path) {
  bool created = false;
  if (mkdir(path, 0700) < 0) {
    if (errno != EEXIST)
      fail_io("create state root", path);
  } else {
    created = true;
  }
  int root = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (root < 0)
    fail_io("open state root", path);
  struct stat status;
  if (fstat(root, &status) < 0)
    fail_io("stat state root", path);
  if (!S_ISDIR(status.st_mode))
    reject_tree("invalid-state-root", path);
  if (fchmod(root, 0700) < 0)
    fail_io("set state root mode", path);
  if (created) {
    char *copy = strdup(path);
    if (!copy)
      fail_io("copy state root path", path);
    char *slash = strrchr(copy, '/');
    const char *parent_path = ".";
    if (slash) {
      if (slash == copy)
        slash[1] = '\0';
      else
        *slash = '\0';
      parent_path = copy;
    }
    int parent =
        open(parent_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (parent < 0)
      fail_io("open state-root parent", parent_path);
    if (sync_fd(parent, "state-root-parent") < 0)
      fail_io("sync state-root parent", parent_path);
    close(parent);
    free(copy);
  }
  ensure_private_directory_at(root, "journals");
  ensure_private_directory_at(root, "gates");
  ensure_private_directory_at(root, "locks");
  int locks = openat(root, "locks",
                     O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (locks < 0)
    fail_io("open lock directory", path);
  ensure_private_directory_at(locks, "operations");
  ensure_private_directory_at(locks, "plugins");
  close(locks);
  return root;
}

static void copy_bounded_file(int source, int destination, const char *path) {
  unsigned char buffer[64 * 1024];
  uint64_t total = 0;
  for (;;) {
    ssize_t received = read(source, buffer, sizeof(buffer));
    if (received < 0)
      fail_io("read journal input", path);
    if (received == 0)
      break;
    if ((uint64_t)received > 1024ULL * 1024ULL - total)
      reject_tree("journal-size-limit", path);
    fd_write_all(destination, buffer, (size_t)received, "write journal", path);
    total += (uint64_t)received;
  }
  if (total == 0)
    reject_tree("empty-journal", path);
}

static void transition_hook(const char *point, const char *transition) {
  char name[192];
  int length = snprintf(name, sizeof(name), "%s:%s", point, transition);
  if (length < 0 || (size_t)length >= sizeof(name))
    reject_tree("transition-name-limit", transition);
  test_hook(name);
}

static int transition_sync_fd(int fd, const char *point,
                              const char *transition) {
  char name[192];
  int length = snprintf(name, sizeof(name), "%s:%s", point, transition);
  if (length < 0 || (size_t)length >= sizeof(name))
    reject_tree("transition-name-limit", transition);
  return sync_fd(fd, name);
}

static void replace_journal(const char *state_path, const char *operation_id,
                            const char *input_path, const char *transition) {
  if (!simple_name(operation_id))
    reject_tree("invalid-operation-id", operation_id);
  int state = open_private_state_root(state_path);
  int journals = openat(state, "journals",
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (journals < 0)
    fail_io("open journals", state_path);
  int input = open(input_path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (input < 0)
    fail_io("open journal input", input_path);
  struct stat input_status;
  if (fstat(input, &input_status) < 0)
    fail_io("stat journal input", input_path);
  if (!S_ISREG(input_status.st_mode) || input_status.st_nlink != 1)
    reject_tree("invalid-journal-input", input_path);

  char final_name[160];
  char temporary_name[192];
  int final_length = snprintf(final_name, sizeof(final_name), "%s.journal",
                              operation_id);
  int temporary_length =
      snprintf(temporary_name, sizeof(temporary_name), ".%s.tmp.%ld.%ld",
               operation_id, (long)getpid(), (long)time(NULL));
  if (final_length < 0 || (size_t)final_length >= sizeof(final_name) ||
      temporary_length < 0 ||
      (size_t)temporary_length >= sizeof(temporary_name))
    reject_tree("journal-name-limit", operation_id);

  int temporary = openat(journals, temporary_name,
                         O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                         0600);
  if (temporary < 0)
    fail_io("create temporary journal", temporary_name);
  if (fchmod(temporary, 0600) < 0)
    fail_io("set journal mode", temporary_name);
  transition_hook("before-journal-write", transition);
  copy_bounded_file(input, temporary, input_path);
  close(input);
  transition_hook("after-journal-write", transition);
  if (transition_sync_fd(temporary, "journal-file", transition) < 0)
    fail_io("sync journal file", temporary_name);
  transition_hook("after-journal-file-sync", transition);
  close(temporary);
  char rename_point[192];
  int rename_length = snprintf(rename_point, sizeof(rename_point),
                               "journal-rename:%s", transition);
  if (rename_length < 0 || (size_t)rename_length >= sizeof(rename_point))
    reject_tree("transition-name-limit", transition);
  if (test_rename_failure(rename_point) ||
      renameat(journals, temporary_name, journals, final_name) < 0)
    fail_io("replace journal", final_name);
  transition_hook("after-journal-rename", transition);
  if (transition_sync_fd(journals, "journal-parent", transition) < 0)
    reject_tree("journal-indeterminate", transition);
  close(journals);
  close(state);
}

static void replace_gate(const char *state_path, const char *plugin_id,
                         const char *input_path, const char *transition) {
  if (!third_party_plugin_id(plugin_id))
    reject_tree("invalid-plugin-id", plugin_id);
  int state = open_private_state_root(state_path);
  int gates = openat(state, "gates",
                     O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (gates < 0)
    fail_io("open gates", state_path);
  int input = open(input_path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (input < 0)
    fail_io("open gate input", input_path);
  struct stat input_status;
  if (fstat(input, &input_status) < 0)
    fail_io("stat gate input", input_path);
  if (!S_ISREG(input_status.st_mode) || input_status.st_nlink != 1)
    reject_tree("invalid-gate-input", input_path);

  char final_name[160];
  char temporary_name[192];
  int final_length = snprintf(final_name, sizeof(final_name), "%s.gate", plugin_id);
  int temporary_length = snprintf(temporary_name, sizeof(temporary_name),
                                  ".%s.gate.tmp.%ld.%ld", plugin_id,
                                  (long)getpid(), (long)time(NULL));
  if (final_length < 0 || (size_t)final_length >= sizeof(final_name) ||
      temporary_length < 0 ||
      (size_t)temporary_length >= sizeof(temporary_name))
    reject_tree("gate-name-limit", plugin_id);

  int temporary = openat(gates, temporary_name,
                         O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                         0600);
  if (temporary < 0)
    fail_io("create temporary gate", temporary_name);
  if (fchmod(temporary, 0600) < 0)
    fail_io("set gate mode", temporary_name);
  transition_hook("before-gate-write", transition);
  copy_bounded_file(input, temporary, input_path);
  close(input);
  transition_hook("after-gate-write", transition);
  if (transition_sync_fd(temporary, "gate-file", transition) < 0)
    fail_io("sync gate file", temporary_name);
  transition_hook("after-gate-file-sync", transition);
  close(temporary);
  char rename_point[192];
  int rename_length = snprintf(rename_point, sizeof(rename_point),
                               "gate-rename:%s", transition);
  if (rename_length < 0 || (size_t)rename_length >= sizeof(rename_point))
    reject_tree("transition-name-limit", transition);
  if (test_rename_failure(rename_point) ||
      renameat(gates, temporary_name, gates, final_name) < 0)
    fail_io("replace gate", final_name);
  transition_hook("after-gate-rename", transition);
  if (transition_sync_fd(gates, "gate-parent", transition) < 0)
    reject_tree("gate-indeterminate", transition);
  close(gates);
  close(state);
}

static void sync_gate_authority(const char *state_path) {
  int state = open_private_state_root(state_path);
  int gates = openat(state, "gates",
                     O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (gates < 0)
    fail_io("open gates", state_path);
  if (sync_fd(gates, "gate-reconciliation-parent") < 0)
    fail_io("sync gate authority", state_path);
  close(gates);
  close(state);
}

static void print_domain_hash(const char *domain) {
  size_t domain_length = strlen(domain);
  if (domain_length == 0 || domain_length > 128)
    reject_tree("invalid-hash-domain", domain);
  int hash = open_hash();
  hash_update(hash, domain, domain_length, "domain");
  const unsigned char separator = 0;
  hash_update(hash, &separator, 1, "domain");
  unsigned char buffer[4096];
  uint64_t total = 0;
  for (;;) {
    ssize_t received = read(STDIN_FILENO, buffer, sizeof(buffer));
    if (received < 0)
      fail_io("read hash input", "stdin");
    if (received == 0)
      break;
    if ((uint64_t)received > 1024ULL * 1024ULL - total)
      reject_tree("hash-input-limit", "stdin");
    hash_update(hash, buffer, (size_t)received, "stdin");
    total += (uint64_t)received;
  }
  if (send(hash, NULL, 0, 0) < 0)
    fail_io("finalize sha256", "AF_ALG");
  unsigned char digest[32];
  ssize_t received = read(hash, digest, sizeof(digest));
  close(hash);
  if (received != (ssize_t)sizeof(digest))
    fail_io("read sha256", "AF_ALG");
  for (size_t index = 0; index < sizeof(digest); index++)
    printf("%02x", digest[index]);
  fputc('\n', stdout);
}

static void sync_directory_path(const char *path, const char *point) {
  int directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (directory < 0)
    fail_io("open directory for sync", path);
  if (sync_fd(directory, point) < 0)
    fail_io("sync directory", path);
  close(directory);
}

static void probe_atomic_support(void) {
  errno = 0;
  long result = syscall(SYS_renameat2, -1, "", -1, "", RENAME_NOREPLACE);
  (void)result;
  if (errno == ENOSYS) {
    fputs("unsupported-atomic-operation\n", stdout);
    exit(4);
  }
  fputs("supported-atomic-operation\n", stdout);
}

static bool equal_file_bytes(int left, int right) {
  unsigned char left_buffer[4096];
  unsigned char right_buffer[4096];
  for (;;) {
    ssize_t left_count = read(left, left_buffer, sizeof(left_buffer));
    if (left_count < 0)
      fail_io("read corrupt journal", "authoritative");
    ssize_t right_count = read(right, right_buffer, sizeof(right_buffer));
    if (right_count < 0)
      fail_io("read corrupt evidence", "evidence");
    if (left_count != right_count)
      return false;
    if (left_count == 0)
      return true;
    if (memcmp(left_buffer, right_buffer, (size_t)left_count) != 0)
      return false;
  }
}

static void preserve_corrupt_journal(const char *state_path,
                                     const char *operation_id,
                                     const char *digest) {
  if (!simple_name(operation_id) || strlen(digest) != 64)
    reject_tree("invalid-quarantine-name", operation_id);
  for (size_t index = 0; index < 64; index++)
    if (!((digest[index] >= '0' && digest[index] <= '9') ||
          (digest[index] >= 'a' && digest[index] <= 'f')))
      reject_tree("invalid-quarantine-digest", digest);
  int state = open_private_state_root(state_path);
  int journals = openat(state, "journals",
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (journals < 0)
    fail_io("open journals", state_path);
  char current[160];
  char evidence[240];
  char evidence_temporary[256];
  int current_length =
      snprintf(current, sizeof(current), "%s.journal", operation_id);
  int evidence_length = snprintf(evidence, sizeof(evidence), "%s.corrupt.%s",
                                 operation_id, digest);
  int temporary_length =
      snprintf(evidence_temporary, sizeof(evidence_temporary),
               ".%s.corrupt.tmp.%ld", operation_id, (long)getpid());
  if (current_length < 0 || (size_t)current_length >= sizeof(current) ||
      evidence_length < 0 || (size_t)evidence_length >= sizeof(evidence) ||
      temporary_length < 0 ||
      (size_t)temporary_length >= sizeof(evidence_temporary))
    reject_tree("journal-name-limit", operation_id);
  int authoritative =
      openat(journals, current, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (authoritative < 0)
    fail_io("open corrupt journal", current);
  struct stat authoritative_status;
  if (fstat(authoritative, &authoritative_status) < 0)
    fail_io("stat corrupt journal", current);
  if (!S_ISREG(authoritative_status.st_mode) ||
      authoritative_status.st_nlink != 1)
    reject_tree("invalid-corrupt-journal", current);
  int existing =
      openat(journals, evidence, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (existing >= 0) {
    if (!equal_file_bytes(authoritative, existing))
      reject_tree("corrupt-evidence-conflict", evidence);
    if (sync_fd(existing, "corrupt-evidence-existing-file") < 0)
      fail_io("sync existing corrupt evidence", evidence);
    if (sync_fd(journals, "journal-quarantine-parent") < 0)
      fail_io("sync existing corrupt evidence parent", state_path);
    close(existing);
    close(authoritative);
    close(journals);
    close(state);
    return;
  }
  if (errno != ENOENT)
    fail_io("open corrupt evidence", evidence);
  int evidence_fd =
      openat(journals, evidence_temporary,
             O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (evidence_fd < 0)
    fail_io("create corrupt evidence", evidence_temporary);
  transition_hook("after-corrupt-evidence-create", "corruption-manual-attention");
  copy_bounded_file(authoritative, evidence_fd, current);
  if (sync_fd(evidence_fd, "corrupt-evidence-file") < 0)
    fail_io("sync corrupt evidence", evidence);
  transition_hook("after-corrupt-evidence-sync", "corruption-manual-attention");
  close(evidence_fd);
  if (syscall(SYS_renameat2, journals, evidence_temporary, journals, evidence,
              RENAME_NOREPLACE) < 0) {
    if (errno != EEXIST)
      fail_io("publish corrupt evidence", evidence);
    int competing =
        openat(journals, evidence, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (competing < 0)
      fail_io("open competing corrupt evidence", evidence);
    if (lseek(authoritative, 0, SEEK_SET) < 0)
      fail_io("rewind corrupt journal", current);
    if (!equal_file_bytes(authoritative, competing))
      reject_tree("corrupt-evidence-conflict", evidence);
    close(competing);
  }
  close(authoritative);
  if (sync_fd(journals, "journal-quarantine-parent") < 0)
    fail_io("sync corrupt journal evidence", state_path);
  close(journals);
  close(state);
}

static void sync_journal_authority(const char *state_path,
                                   const char *operation_id) {
  if (!simple_name(operation_id))
    reject_tree("invalid-operation-id", operation_id);
  int state = open_private_state_root(state_path);
  int journals = openat(state, "journals",
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (journals < 0)
    fail_io("open journals", state_path);
  if (sync_fd(journals, "journal-reconciliation-parent") < 0)
    fail_io("sync journal authority", state_path);
  char name[160];
  int length = snprintf(name, sizeof(name), "%s.journal", operation_id);
  if (length < 0 || (size_t)length >= sizeof(name))
    reject_tree("journal-name-limit", operation_id);
  int journal = openat(journals, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (journal >= 0) {
    struct stat status;
    if (fstat(journal, &status) < 0)
      fail_io("stat authoritative journal", name);
    if (!S_ISREG(status.st_mode) || status.st_nlink != 1 ||
        (status.st_mode & 0777) != 0600)
      reject_tree("invalid-authoritative-journal", name);
    close(journal);
  } else if (errno != ENOENT) {
    fail_io("open authoritative journal", name);
  }
  close(journals);
  close(state);
}

static bool same_timestamp(struct timespec left, struct timespec right) {
  return left.tv_sec == right.tv_sec && left.tv_nsec == right.tv_nsec;
}

static void journal_authority_indeterminate(const char *operation_id) {
  fprintf(stderr, "omarchy-plugin-tree: journal-authority-indeterminate: %s\n",
          operation_id);
  exit(5);
}

/* Read one atomically installed journal from an already opened journals dir. */
static void read_journal_from_directory(int journals,
                                         const char *operation_id) {
  if (!simple_name(operation_id))
    reject_tree("invalid-operation-id", operation_id);
  char name[160];
  int name_length =
      snprintf(name, sizeof(name), "%s.journal", operation_id);
  if (name_length < 0 || (size_t)name_length >= sizeof(name))
    reject_tree("journal-name-limit", operation_id);
  int journal = openat(journals, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC |
                                           O_NOATIME);
  if (journal < 0) {
    if (errno == ENOENT)
      operation_not_found(operation_id);
    reject_tree("invalid-authoritative-journal", operation_id);
  }
  struct stat before;
  if (fstat(journal, &before) < 0)
    fail_io("stat read-only journal", operation_id);
  if (!S_ISREG(before.st_mode) || before.st_nlink != 1 ||
      (before.st_mode & 0777) != 0600 || before.st_size <= 0 ||
      before.st_size > 1024 * 1024)
    reject_tree("invalid-authoritative-journal", operation_id);

  unsigned char buffer[64 * 1024];
  off_t total = 0;
  for (;;) {
    ssize_t received = read(journal, buffer, sizeof(buffer));
    if (received < 0) {
      if (errno == EINTR)
        continue;
      fail_io("read authoritative journal", operation_id);
    }
    if (received == 0)
      break;
    if (received > before.st_size - total)
      reject_tree("journal-changed", operation_id);
    fd_write_all(STDOUT_FILENO, buffer, (size_t)received,
                 "write authoritative journal", "stdout");
    total += received;
  }
  struct stat after;
  if (fstat(journal, &after) < 0)
    fail_io("restat read-only journal", operation_id);
  if (total != before.st_size || before.st_dev != after.st_dev ||
      before.st_ino != after.st_ino || before.st_size != after.st_size ||
      before.st_mode != after.st_mode || before.st_nlink != after.st_nlink ||
      !same_timestamp(before.st_mtim, after.st_mtim) ||
      !same_timestamp(before.st_ctim, after.st_ctim))
    reject_tree("journal-changed", operation_id);
  close(journal);
}

/* Read one atomically installed journal without creating or repairing state. */
static void read_journal_authority(const char *state_path,
                                   const char *operation_id) {
  if (!simple_name(operation_id))
    reject_tree("invalid-operation-id", operation_id);
  int state = open(state_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC |
                                   O_NOATIME);
  if (state < 0) {
    if (errno == ENOENT)
      operation_not_found(operation_id);
    reject_tree("invalid-state-root", operation_id);
  }
  struct stat state_status;
  if (fstat(state, &state_status) < 0)
    fail_io("stat read-only state root", state_path);
  if (!S_ISDIR(state_status.st_mode) || (state_status.st_mode & 0777) != 0700)
    reject_tree("invalid-state-root", operation_id);

  int journals = openat(state, "journals",
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC |
                            O_NOATIME);
  if (journals < 0) {
    if (errno == ENOENT)
      operation_not_found(operation_id);
    reject_tree("invalid-state-directory", operation_id);
  }
  struct stat directory_status;
  if (fstat(journals, &directory_status) < 0)
    fail_io("stat read-only journal directory", state_path);
  if (!S_ISDIR(directory_status.st_mode) ||
      (directory_status.st_mode & 0777) != 0700)
    reject_tree("invalid-state-directory", operation_id);
  read_journal_from_directory(journals, operation_id);
  close(journals);
  close(state);
}

static int open_existing_state_root(const char *state_path,
                                    const char *operation_id) {
  int state = open(state_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW |
                                  O_CLOEXEC | O_NOATIME);
  if (state < 0) {
    if (errno == ENOENT)
      operation_not_found(operation_id);
    reject_tree("invalid-state-root", operation_id);
  }
  struct stat status;
  if (fstat(state, &status) < 0)
    fail_io("stat read-only state root", state_path);
  if (!S_ISDIR(status.st_mode) || (status.st_mode & 0777) != 0700)
    reject_tree("invalid-state-root", operation_id);
  return state;
}

static int open_existing_directory(int parent, const char *name,
                                   const char *operation_id,
                                   const char *description,
                                   bool missing_is_not_found) {
  int directory = openat(parent, name,
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC |
                              O_NOATIME);
  if (directory < 0) {
    if (errno == ENOENT && missing_is_not_found)
      operation_not_found(operation_id);
    if (errno == ENOENT)
      reject_tree("invalid-state-directory", operation_id);
    fail_io(description, name);
  }
  struct stat status;
  if (fstat(directory, &status) < 0)
    fail_io("stat existing directory", name);
  if (!S_ISDIR(status.st_mode) || (status.st_mode & 0777) != 0700)
    reject_tree("invalid-state-directory", operation_id);
  return directory;
}

/* Status authority: lock an existing operation, sync journals, then read. */
static void read_journal_locked(const char *state_path,
                                const char *operation_id) {
  if (!simple_name(operation_id))
    reject_tree("invalid-operation-id", operation_id);
  int state = open_existing_state_root(state_path, operation_id);
  int locks = open_existing_directory(state, "locks", operation_id,
                                      "open existing lock directory", false);
  int operations = open_existing_directory(locks, "operations", operation_id,
                                           "open existing operation directory", false);
  char operation_name[160];
  int length = snprintf(operation_name, sizeof(operation_name), "%s.lock",
                        operation_id);
  if (length < 0 || (size_t)length >= sizeof(operation_name))
    reject_tree("operation-lock-name-limit", operation_id);
  int operation = openat(operations, operation_name,
                         O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (operation < 0)
    reject_tree("invalid-operation-lock", operation_id);
  struct stat operation_status;
  if (fstat(operation, &operation_status) < 0)
    fail_io("stat operation lock", operation_name);
  if (!S_ISREG(operation_status.st_mode) || operation_status.st_nlink != 1 ||
      (operation_status.st_mode & 0777) != 0600)
    reject_tree("invalid-operation-lock", operation_id);
  while (flock(operation, LOCK_SH) < 0) {
    if (errno == EINTR)
      continue;
    fail_io("acquire operation lock", operation_name);
  }
  int journals = open_existing_directory(state, "journals", operation_id,
                                         "open existing journal directory", true);
  if (sync_fd(journals, "journal-reconciliation-parent") < 0)
    journal_authority_indeterminate(operation_id);
  read_journal_from_directory(journals, operation_id);
  close(journals);
  close(operation);
  close(operations);
  close(locks);
  close(state);
}

/* Abort authority: caller already owns operation and plugin locks. */
static void read_journal_held(const char *state_path,
                              const char *operation_id) {
  if (!simple_name(operation_id))
    reject_tree("invalid-operation-id", operation_id);
  int state = open_existing_state_root(state_path, operation_id);
  int journals = open_existing_directory(state, "journals", operation_id,
                                         "open existing journal directory", true);
  if (sync_fd(journals, "journal-reconciliation-parent") < 0)
    journal_authority_indeterminate(operation_id);
  read_journal_from_directory(journals, operation_id);
  close(journals);
  close(state);
}

static void derive_plugin_lock_name(const char *plugin_id, char output[65]) {
  if (!third_party_plugin_id(plugin_id))
    reject_tree("invalid-plugin-id", plugin_id);
  static const char lock_domain[] = "omarchy-plugin-transaction-plugin-lock/v1";
  int hash = open_hash();
  hash_update(hash, lock_domain, sizeof(lock_domain) - 1, "plugin lock domain");
  const unsigned char separator = 0;
  hash_update(hash, &separator, 1, "plugin lock domain");
  hash_update(hash, plugin_id, strlen(plugin_id), "plugin lock id");
  if (send(hash, NULL, 0, 0) < 0)
    fail_io("finalize plugin lock hash", "AF_ALG");
  unsigned char digest[32];
  ssize_t received = read(hash, digest, sizeof(digest));
  close(hash);
  if (received != (ssize_t)sizeof(digest))
    fail_io("read plugin lock hash", "AF_ALG");
  for (size_t index = 0; index < sizeof(digest); index++)
    snprintf(output + index * 2, 3, "%02x", digest[index]);
}

static void hold_plugin_lock(const char *state_path, const char *plugin_id) {
  char derived_name[65];
  derive_plugin_lock_name(plugin_id, derived_name);
  int state = open_private_state_root(state_path);
  int locks = openat(state, "locks",
                     O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (locks < 0)
    fail_io("open lock directory", state_path);
  int plugins = openat(locks, "plugins",
                       O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (plugins < 0)
    fail_io("open plugin lock directory", state_path);
  int lock = openat(plugins, derived_name,
                    O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (lock < 0)
    fail_io("open plugin lifecycle lock", derived_name);
  if (fchmod(lock, 0600) < 0)
    fail_io("set plugin lock mode", derived_name);
  if (flock(lock, LOCK_EX | LOCK_NB) < 0) {
    if (errno == EWOULDBLOCK) {
      fputs("plugin-busy\n", stderr);
      exit(3);
    }
    fail_io("acquire plugin lifecycle lock", derived_name);
  }
  fputs("locked\n", stdout);
  fflush(stdout);
  unsigned char buffer[256];
  for (;;) {
    ssize_t count = read_lock_input(STDIN_FILENO, buffer, sizeof(buffer));
    if (count > 0)
      continue;
    if (count == 0)
      break;
    if (errno == EINTR)
      continue;
    fail_io("hold plugin lifecycle lock", derived_name);
  }
  close(lock);
  close(plugins);
  close(locks);
  close(state);
}

static int open_lock_file(int directory, const char *name,
                          const char *description) {
  if (!simple_name(name))
    reject_tree("invalid-lock-name", name);
  int lock = openat(directory, name,
                    O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (lock < 0)
    fail_io(description, name);
  if (fchmod(lock, 0600) < 0)
    fail_io("set lock mode", name);
  return lock;
}

static void hold_operation_lock(const char *state_path,
                                const char *operation_id) {
  if (!simple_name(operation_id))
    reject_tree("invalid-operation-id", operation_id);
  int state = open(state_path,
                   O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (state < 0)
    reject_tree("invalid-state-root", operation_id);
  struct stat state_status;
  if (fstat(state, &state_status) < 0)
    fail_io("stat operation-lock state root", state_path);
  if (!S_ISDIR(state_status.st_mode) ||
      (state_status.st_mode & 0777) != 0700)
    reject_tree("invalid-state-root", operation_id);
  int locks = openat(state, "locks",
                     O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (locks < 0)
    fail_io("open lock directory", state_path);
  struct stat locks_status;
  if (fstat(locks, &locks_status) < 0)
    fail_io("stat lock directory", state_path);
  if (!S_ISDIR(locks_status.st_mode) ||
      (locks_status.st_mode & 0777) != 0700)
    reject_tree("invalid-lock-directory", operation_id);
  int operations = openat(locks, "operations",
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (operations < 0)
    fail_io("open operation lock directory", state_path);
  struct stat operations_status;
  if (fstat(operations, &operations_status) < 0)
    fail_io("stat operation lock directory", state_path);
  if (!S_ISDIR(operations_status.st_mode) ||
      (operations_status.st_mode & 0777) != 0700)
    reject_tree("invalid-operation-lock-directory", operation_id);
  char operation_name[160];
  int length = snprintf(operation_name, sizeof(operation_name), "%s.lock",
                        operation_id);
  if (length < 0 || (size_t)length >= sizeof(operation_name))
    reject_tree("operation-lock-name-limit", operation_id);
  int operation = openat(operations, operation_name,
                         O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (operation < 0)
    reject_tree("invalid-operation-lock", operation_id);
  struct stat operation_status;
  if (fstat(operation, &operation_status) < 0)
    fail_io("stat operation lock", operation_name);
  if (!S_ISREG(operation_status.st_mode) || operation_status.st_nlink != 1 ||
      (operation_status.st_mode & 0777) != 0600)
    reject_tree("invalid-operation-lock", operation_id);
  while (flock(operation, LOCK_EX) < 0) {
    if (errno == EINTR)
      continue;
    fail_io("acquire operation lock", operation_name);
  }
  fputs("locked-operation\n", stdout);
  fflush(stdout);
  unsigned char buffer[256];
  for (;;) {
    ssize_t count = read_lock_input(STDIN_FILENO, buffer, sizeof(buffer));
    if (count > 0)
      continue;
    if (count == 0)
      break;
    if (errno == EINTR)
      continue;
    fail_io("hold operation lock", operation_name);
  }
  close(operation);
  close(operations);
  close(locks);
  close(state);
}

/* O-5's proof seam for the universal operation-before-plugin lock order. */
static void hold_ordered_locks(const char *state_path,
                               const char *operation_id,
                               const char *plugin_id) {
  char plugin_lock_name[65];
  derive_plugin_lock_name(plugin_id, plugin_lock_name);
  int state = open_private_state_root(state_path);
  int locks = openat(state, "locks",
                     O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (locks < 0)
    fail_io("open lock directory", state_path);
  int operations = openat(locks, "operations",
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  int plugins = openat(locks, "plugins",
                       O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (operations < 0 || plugins < 0)
    fail_io("open ordered lock directories", state_path);
  char operation_name[160];
  int length = snprintf(operation_name, sizeof(operation_name), "%s.lock",
                        operation_id);
  if (length < 0 || (size_t)length >= sizeof(operation_name))
    reject_tree("operation-lock-name-limit", operation_id);
  int operation = open_lock_file(operations, operation_name,
                                 "open operation lock");
  if (flock(operation, LOCK_EX) < 0)
    fail_io("acquire operation lock", operation_name);
  test_hook("after-ordered-operation-lock");
  int plugin = open_lock_file(plugins, plugin_lock_name,
                              "open plugin lifecycle lock");
  if (flock(plugin, LOCK_EX | LOCK_NB) < 0) {
    if (errno == EWOULDBLOCK) {
      fputs("plugin-busy\n", stderr);
      exit(3);
    }
    fail_io("acquire plugin lifecycle lock", plugin_lock_name);
  }
  fputs("locked-operation-then-plugin\n", stdout);
  fflush(stdout);
  unsigned char buffer[256];
  for (;;) {
    ssize_t count = read_lock_input(STDIN_FILENO, buffer, sizeof(buffer));
    if (count > 0)
      continue;
    if (count == 0)
      break;
    if (errno == EINTR)
      continue;
    fail_io("hold ordered locks", plugin_lock_name);
  }
  close(plugin);
  close(operation);
  close(plugins);
  close(operations);
  close(locks);
  close(state);
}

static int constant_time_hash_equal(const char *expected) {
  if (strlen(expected) != 64)
    return 1;
  unsigned char actual[65];
  size_t length = 0;
  while (length < sizeof(actual)) {
    ssize_t received = read(STDIN_FILENO, actual + length,
                            sizeof(actual) - length);
    if (received < 0)
      fail_io("read comparison hash", "stdin");
    if (received == 0)
      break;
    length += (size_t)received;
  }
  unsigned char different = (unsigned char)(length != 64);
  for (size_t index = 0; index < 64; index++) {
    unsigned char value = index < length ? actual[index] : 0;
    different |= (unsigned char)(value ^ (unsigned char)expected[index]);
  }
  return different == 0 ? 0 : 1;
}

int main(int argc, char **argv) {
  if (argc == 3 && strcmp(argv[1], "state-init") == 0) {
    int state = open_private_state_root(argv[2]);
    close(state);
    return 0;
  }
  if (argc == 3 && strcmp(argv[1], "identity") == 0) {
    print_identity(argv[2]);
    return 0;
  }
  if (argc == 5 && strcmp(argv[1], "copy") == 0) {
    copy_snapshot(argv[2], argv[3], argv[4]);
    return 0;
  }
  if (argc == 5 && strcmp(argv[1], "prepare-import") == 0) {
    prepare_import(argv[2], argv[3], argv[4]);
    return 0;
  }
  if (argc == 5 && strcmp(argv[1], "publish") == 0) {
    publish_snapshot(argv[2], argv[3], argv[4]);
    return 0;
  }
  if (argc == 9 && strcmp(argv[1], "namespace-mutate") == 0) {
    if (strcmp(argv[2], "install") != 0 && strcmp(argv[2], "exchange") != 0 &&
        strcmp(argv[2], "rollback-install") != 0 &&
        strcmp(argv[2], "rollback-exchange") != 0)
      reject_tree("invalid-namespace-operation", argv[2]);
    namespace_mutate(argv[2], argv[3], argv[4], argv[5], argv[6], argv[7],
                     argv[8]);
    return 0;
  }
  if (argc == 6 && strcmp(argv[1], "journal-replace") == 0) {
    replace_journal(argv[2], argv[3], argv[4], argv[5]);
    return 0;
  }
  if (argc == 6 && strcmp(argv[1], "gate-replace") == 0) {
    replace_gate(argv[2], argv[3], argv[4], argv[5]);
    return 0;
  }
  if (argc == 3 && strcmp(argv[1], "gate-sync") == 0) {
    sync_gate_authority(argv[2]);
    return 0;
  }
  if (argc == 3 && strcmp(argv[1], "domain-hash") == 0) {
    print_domain_hash(argv[2]);
    return 0;
  }
  if (argc == 2 && strcmp(argv[1], "atomic-support") == 0) {
    probe_atomic_support();
    return 0;
  }
  if (argc == 4 && strcmp(argv[1], "sync-directory") == 0) {
    sync_directory_path(argv[2], argv[3]);
    return 0;
  }
  if (argc == 5 && strcmp(argv[1], "journal-preserve") == 0) {
    preserve_corrupt_journal(argv[2], argv[3], argv[4]);
    return 0;
  }
  if (argc == 4 && strcmp(argv[1], "journal-sync") == 0) {
    sync_journal_authority(argv[2], argv[3]);
    return 0;
  }
  if (argc == 4 && strcmp(argv[1], "journal-read") == 0) {
    read_journal_authority(argv[2], argv[3]);
    return 0;
  }
  if (argc == 4 && strcmp(argv[1], "journal-read-locked") == 0) {
    read_journal_locked(argv[2], argv[3]);
    return 0;
  }
  if (argc == 4 && strcmp(argv[1], "journal-read-held") == 0) {
    read_journal_held(argv[2], argv[3]);
    return 0;
  }
  if (argc == 4 && strcmp(argv[1], "plugin-lock") == 0) {
    hold_plugin_lock(argv[2], argv[3]);
    return 0;
  }
  if (argc == 4 && strcmp(argv[1], "operation-lock") == 0) {
    hold_operation_lock(argv[2], argv[3]);
    return 0;
  }
  if (argc == 5 && strcmp(argv[1], "ordered-lock") == 0) {
    hold_ordered_locks(argv[2], argv[3], argv[4]);
    return 0;
  }
  if (argc == 3 && strcmp(argv[1], "hash-equal") == 0)
    return constant_time_hash_equal(argv[2]);
  if (argc == 2 && strcmp(argv[1], "json-request-check") == 0) {
    validate_json_request();
    return 0;
  }
  fprintf(stderr,
          "usage: %s identity ROOT | copy SOURCE PARENT NAME | prepare-import SOURCE STORE TEMPORARY | "
          "publish PARENT TEMPORARY COMPLETED | "
          "state-init STATE | journal-replace STATE OPERATION INPUT TRANSITION | "
          "namespace-mutate install|exchange|rollback-install|rollback-exchange SOURCE-PARENT SOURCE-NAME DEST-PARENT DEST-NAME EXPECTED-SOURCE EXPECTED-DEST | "
          "gate-replace STATE PLUGIN INPUT TRANSITION | gate-sync STATE | "
          "domain-hash DOMAIN | sync-directory PATH POINT | atomic-support | "
          "journal-preserve STATE OPERATION DIGEST | journal-sync STATE OPERATION | "
          "journal-read STATE OPERATION | journal-read-locked STATE OPERATION | "
          "journal-read-held STATE OPERATION | json-request-check | "
          "operation-lock STATE OPERATION | plugin-lock STATE PLUGIN-ID | "
          "ordered-lock STATE OPERATION PLUGIN-ID | "
          "hash-equal EXPECTED\n",
          argv[0]);
  return 64;
}
