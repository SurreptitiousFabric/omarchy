#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/if_alg.h>
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
#else
static bool inject_zero_write(void) { return false; }
static bool inject_zero_hash_send(void) { return false; }
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
#else
static void test_hook(const char *name) { (void)name; }
static bool test_fsync_failure(const char *name) {
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

static bool simple_name(const char *name) {
  size_t length = strlen(name);
  return length > 0 && length <= 128 && strcmp(name, ".") != 0 &&
         strcmp(name, "..") != 0 && strchr(name, '/') == NULL &&
         valid_utf8((const unsigned char *)name, length);
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
  if (renameat(journals, temporary_name, journals, final_name) < 0)
    fail_io("replace journal", final_name);
  transition_hook("after-journal-rename", transition);
  if (transition_sync_fd(journals, "journal-parent", transition) < 0)
    reject_tree("journal-indeterminate", transition);
  close(journals);
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

static void hold_plugin_lock(const char *state_path, const char *lock_name) {
  if (!simple_name(lock_name))
    reject_tree("invalid-plugin-lock-name", lock_name);
  int state = open_private_state_root(state_path);
  int locks = openat(state, "locks",
                     O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (locks < 0)
    fail_io("open lock directory", state_path);
  int plugins = openat(locks, "plugins",
                       O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (plugins < 0)
    fail_io("open plugin lock directory", state_path);
  int lock = openat(plugins, lock_name,
                    O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (lock < 0)
    fail_io("open plugin lifecycle lock", lock_name);
  if (fchmod(lock, 0600) < 0)
    fail_io("set plugin lock mode", lock_name);
  if (flock(lock, LOCK_EX | LOCK_NB) < 0) {
    if (errno == EWOULDBLOCK) {
      fputs("plugin-busy\n", stderr);
      exit(3);
    }
    fail_io("acquire plugin lifecycle lock", lock_name);
  }
  fputs("locked\n", stdout);
  fflush(stdout);
  unsigned char buffer[256];
  while (read(STDIN_FILENO, buffer, sizeof(buffer)) > 0) {
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

/* O-5's proof seam for the universal operation-before-plugin lock order. */
static void hold_ordered_locks(const char *state_path,
                               const char *operation_id,
                               const char *plugin_lock_name) {
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
  while (read(STDIN_FILENO, buffer, sizeof(buffer)) > 0) {
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
  if (argc == 6 && strcmp(argv[1], "journal-replace") == 0) {
    replace_journal(argv[2], argv[3], argv[4], argv[5]);
    return 0;
  }
  if (argc == 3 && strcmp(argv[1], "domain-hash") == 0) {
    print_domain_hash(argv[2]);
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
  if (argc == 4 && strcmp(argv[1], "plugin-lock") == 0) {
    hold_plugin_lock(argv[2], argv[3]);
    return 0;
  }
  if (argc == 5 && strcmp(argv[1], "ordered-lock") == 0) {
    hold_ordered_locks(argv[2], argv[3], argv[4]);
    return 0;
  }
  if (argc == 3 && strcmp(argv[1], "hash-equal") == 0)
    return constant_time_hash_equal(argv[2]);
  fprintf(stderr,
          "usage: %s identity ROOT | copy SOURCE PARENT NAME | prepare-import SOURCE STORE TEMPORARY | "
          "publish PARENT TEMPORARY COMPLETED | "
          "state-init STATE | journal-replace STATE OPERATION INPUT TRANSITION | "
          "domain-hash DOMAIN | sync-directory PATH POINT | "
          "journal-preserve STATE OPERATION DIGEST | journal-sync STATE OPERATION | "
          "plugin-lock STATE LOCK-NAME | ordered-lock STATE OPERATION LOCK-NAME | hash-equal EXPECTED\n",
          argv[0]);
  return 64;
}
