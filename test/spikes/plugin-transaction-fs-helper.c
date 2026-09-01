#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

enum { MAX_DEPTH = 32, MAX_ENTRIES = 4096 };
static const uint64_t MAX_BYTES = 64U * 1024U * 1024U;
static size_t entries;
static uint64_t bytes;

static void die(const char *message) {
  perror(message);
  exit(1);
}

static void reject(const char *message, const char *path) {
  fprintf(stderr, "reject: %s: %s\n", message, path);
  exit(2);
}

static int name_compare(const void *left, const void *right) {
  return strcmp(*(const char *const *)left, *(const char *const *)right);
}

static void write_all(const void *buffer, size_t length) {
  const unsigned char *cursor = buffer;
  while (length > 0) {
    ssize_t written = write(STDOUT_FILENO, cursor, length);
    if (written < 0)
      die("write");
    cursor += written;
    length -= (size_t)written;
  }
}

static void emit_header(char type, mode_t mode, off_t size, const char *path) {
  char header[128];
  int length = snprintf(header, sizeof(header), "%c %04o %lld %zu\n", type,
                        (unsigned)(mode & 0777), (long long)size, strlen(path));
  if (length < 0 || (size_t)length >= sizeof(header))
    reject("header overflow", path);
  write_all(header, (size_t)length);
  write_all(path, strlen(path));
  write_all("\n", 1);
}

static void walk(int directory_fd, const char *prefix, unsigned depth) {
  if (depth > MAX_DEPTH)
    reject("depth limit", prefix);
  int scan_fd = dup(directory_fd);
  if (scan_fd < 0)
    die("dup");
  DIR *directory = fdopendir(scan_fd);
  if (!directory)
    die("fdopendir");

  char **names = NULL;
  size_t count = 0;
  struct dirent *entry;
  while ((entry = readdir(directory))) {
    if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..") ||
        !strcmp(entry->d_name, ".git"))
      continue;
    char **grown = realloc(names, (count + 1) * sizeof(*names));
    if (!grown)
      die("realloc");
    names = grown;
    names[count] = strdup(entry->d_name);
    if (!names[count])
      die("strdup");
    count++;
  }
  closedir(directory);
  qsort(names, count, sizeof(*names), name_compare);

  for (size_t index = 0; index < count; index++) {
    char path[4096];
    int path_length =
        prefix[0] ? snprintf(path, sizeof(path), "%s/%s", prefix, names[index])
                  : snprintf(path, sizeof(path), "%s", names[index]);
    if (path_length < 0 || (size_t)path_length >= sizeof(path))
      reject("path limit", names[index]);
    if (++entries > MAX_ENTRIES)
      reject("entry limit", path);

    struct stat metadata;
    if (fstatat(directory_fd, names[index], &metadata, AT_SYMLINK_NOFOLLOW) < 0)
      die("fstatat");
    if (S_ISLNK(metadata.st_mode))
      reject("symlink", path);
    if (S_ISDIR(metadata.st_mode)) {
      emit_header('D', metadata.st_mode, 0, path);
      int child = openat(directory_fd, names[index],
                         O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      if (child < 0)
        die("openat directory");
      walk(child, path, depth + 1);
      close(child);
    } else if (S_ISREG(metadata.st_mode)) {
      if (metadata.st_size < 0 ||
          bytes + (uint64_t)metadata.st_size > MAX_BYTES)
        reject("byte limit", path);
      emit_header('F', metadata.st_mode, metadata.st_size, path);
      int file =
          openat(directory_fd, names[index], O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
      if (file < 0)
        die("openat file");
      char buffer[16384];
      ssize_t received;
      off_t observed = 0;
      while ((received = read(file, buffer, sizeof(buffer))) > 0) {
        write_all(buffer, (size_t)received);
        observed += received;
      }
      if (received < 0)
        die("read");
      close(file);
      if (observed != metadata.st_size)
        reject("file changed while read", path);
      bytes += (uint64_t)observed;
      write_all("\n", 1);
    } else {
      reject("special file", path);
    }
    free(names[index]);
  }
  free(names);
}

static void fault(const char *point) {
  const char *selected = getenv("OMARCHY_FS_SPIKE_FAULT");
  if (selected && !strcmp(selected, point)) {
    fprintf(stderr, "fault: %s\n", point);
    _exit(73);
  }
}

static int open_parent(const char *path) {
  int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0)
    die("open parent");
  return fd;
}

static void mutate(const char *operation, const char *source_parent,
                   const char *source_name, const char *target_parent,
                   const char *target_name) {
  int source_fd = open_parent(source_parent);
  int target_fd = open_parent(target_parent);
  unsigned flags =
      !strcmp(operation, "install") ? RENAME_NOREPLACE : RENAME_EXCHANGE;
  const char *before =
      !strcmp(operation, "install") ? "before-install" : "before-exchange";
  const char *after =
      !strcmp(operation, "install") ? "after-install" : "after-exchange";
  fault(before);
  if (syscall(SYS_renameat2, source_fd, source_name, target_fd, target_name,
              flags) < 0)
    die("renameat2");
  fault(after);
  if (fsync(source_fd) < 0)
    die("fsync source parent");
  if (source_fd != target_fd && fsync(target_fd) < 0)
    die("fsync target parent");
  int live = openat(target_fd, target_name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (live < 0)
    die("postcheck live tree");
  close(live);
  close(source_fd);
  close(target_fd);
}

int main(int argc, char **argv) {
  if (argc == 3 && !strcmp(argv[1], "stream")) {
    int root = open_parent(argv[2]);
    write_all("omarchy-tree-spike-v1\n", 22);
    walk(root, "", 0);
    close(root);
    return 0;
  }
  if (argc == 6 &&
      (!strcmp(argv[1], "install") || !strcmp(argv[1], "exchange"))) {
    mutate(argv[1], argv[2], argv[3], argv[4], argv[5]);
    return 0;
  }
  fprintf(stderr,
          "usage: %s stream ROOT | install|exchange SOURCE_PARENT SOURCE_NAME "
          "TARGET_PARENT TARGET_NAME\n",
          argv[0]);
  return 64;
}
