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
#include <sys/stat.h>
#include <sys/syscall.h>
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

static void fd_write_all(int fd, const void *buffer, size_t length,
                         const char *path) {
  const unsigned char *cursor = buffer;
  while (length > 0) {
    ssize_t written = write(fd, cursor, length);
    if (written < 0)
      fail_io("hash write", path);
    cursor += (size_t)written;
    length -= (size_t)written;
  }
}

static void hash_update(int fd, const void *buffer, size_t length,
                        const char *path) {
  const unsigned char *cursor = buffer;
  while (length > 0) {
    ssize_t written = send(fd, cursor, length, MSG_MORE);
    if (written < 0)
      fail_io("hash update", path);
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
  fd_write_all(ready_fd, name, strlen(name), ready);
  close(ready_fd);
  int resume_fd = open(resume, O_RDONLY | O_CLOEXEC);
  if (resume_fd < 0)
    fail_io("open resume fifo", resume);
  char byte;
  if (read(resume_fd, &byte, 1) != 1)
    fail_io("read resume fifo", resume);
  close(resume_fd);
}
#else
static void test_hook(const char *name) { (void)name; }
#endif

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
        if (fsync(destination_child) < 0)
          fail_io("sync destination directory", path);
        close(destination_child);
      }
      close(child);
    } else if (S_ISREG(path_stat.st_mode)) {
      if (path_stat.st_nlink != 1)
        reject_tree("hard-link", path);
      if (path_stat.st_size < 0 || (uint64_t)path_stat.st_size > MAX_FILE_BYTES)
        reject_tree("file-size-limit", path);
      uint64_t file_size = (uint64_t)path_stat.st_size;
      if (file_size > MAX_TOTAL_BYTES - context->total_bytes)
        reject_tree("total-size-limit", path);
      int file = openat(directory_fd, names[index].bytes,
                        O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
      if (file < 0)
        fail_io("open file", path);
      struct stat opened;
      if (fstat(file, &opened) < 0)
        fail_io("stat opened file", path);
      if (!same_stat(&path_stat, &opened, false))
        reject_tree("tree-changed", path);
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
          fd_write_all(destination_file, buffer, (size_t)received, path);
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
        if (fsync(destination_file) < 0)
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
  if (mkdirat(parent, name, 0700) < 0)
    fail_io("create destination root", name);
  int destination =
      openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (destination < 0)
    fail_io("open destination root", name);

  WalkContext context = {.hash_fd = -1, .total_bytes = 0, .entries = 0};
  test_hook("after-root-open");
  walk_tree(source, destination, "", 0, &context);
  close(source);
  if (fsync(destination) < 0)
    fail_io("sync destination root", name);
  close(destination);
  if (fsync(parent) < 0)
    fail_io("sync destination parent", parent_path);
  close(parent);
}

static void publish_snapshot(const char *parent_path, const char *temporary,
                             const char *completed) {
  if (!simple_name(temporary) || !simple_name(completed))
    reject_tree("invalid-destination-name", parent_path);
  int parent =
      open(parent_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (parent < 0)
    fail_io("open publication parent", parent_path);
  if (syscall(SYS_renameat2, parent, temporary, parent, completed,
              RENAME_NOREPLACE) < 0) {
    if (errno == EEXIST)
      reject_tree("destination-exists", completed);
    fail_io("publish destination", completed);
  }
  if (fsync(parent) < 0)
    fail_io("sync publication parent", parent_path);
  close(parent);
}

int main(int argc, char **argv) {
  if (argc == 3 && strcmp(argv[1], "identity") == 0) {
    print_identity(argv[2]);
    return 0;
  }
  if (argc == 5 && strcmp(argv[1], "copy") == 0) {
    copy_snapshot(argv[2], argv[3], argv[4]);
    return 0;
  }
  if (argc == 5 && strcmp(argv[1], "publish") == 0) {
    publish_snapshot(argv[2], argv[3], argv[4]);
    return 0;
  }
  fprintf(stderr,
          "usage: %s identity ROOT | copy SOURCE PARENT NAME | "
          "publish PARENT TEMPORARY COMPLETED\n",
          argv[0]);
  return 64;
}
