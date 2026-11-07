#define _GNU_SOURCE
#ifdef NDEBUG
#error "descriptor experiment requires assertions"
#endif
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/vfs.h>
#include <unistd.h>

/* Only the generated scratch copies call these hooks. No installed runtime
   or compiler entry uses this candidate. The report fd is observer equipment. */
static struct stat endpoints[2];
static int pins[2] = {-1, -1}, claimed, report_fd;
static const char *mutation;
static int disabled(const char *name) { return !strcmp(mutation, name); }
static int same(const struct stat *a, const struct stat *b) {
  return a->st_dev == b->st_dev && a->st_ino == b->st_ino;
}
static void event(const char *name, int value, int error) {
  dprintf(report_fd, "{\"name\":\"%s\",\"value\":%d,\"errno\":%d}\n", name, value, error);
}
static int claim(void) {
  struct stat err;
  struct statfs fs;
  if (fstat(2, &err)) return -1;
  for (int i = 0; i < 2; ++i) {
    int flags = fcntl(i, F_GETFL);
    if (fstat(i, &endpoints[i]) || fstatfs(i, &fs) ||
        !S_ISFIFO(endpoints[i].st_mode) || fs.f_type != 0x50495045 ||
        flags < 0 || !(flags & O_NONBLOCK) ||
        (flags & O_ACCMODE) != (i ? O_WRONLY : O_RDONLY) || same(&endpoints[i], &err)) return -1;
    pins[i] = fcntl(i, F_DUPFD_CLOEXEC, 20);
    if (pins[i] < 0) return -1;
  }
  if (same(&endpoints[0], &endpoints[1])) return -1;
  claimed = 1;
  return 0;
}

static int descriptor_open(const char *path, int flags, ...) {
  mode_t mode = 0;
  if (flags & O_CREAT) {
    va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap);
  }
  int fd = open(path, (flags & ~O_TRUNC) | O_NONBLOCK | O_CLOEXEC, mode);
  if (fd < 0) return -1;
  int error = 0;
  struct stat target;
  if (fstat(fd, &target)) error = errno;
  else if (claimed && !disabled("identity") &&
           (same(&target, &endpoints[0]) || same(&target, &endpoints[1]))) error = EPERM;
  else if (claimed && !disabled("types") &&
           !S_ISREG(target.st_mode) && !S_ISFIFO(target.st_mode)) {
    error = EINVAL; event("type_denied", target.st_mode & S_IFMT, error);
  }
  if (!error && (flags & O_TRUNC) && ftruncate(fd, 0)) error = errno;
  if (error) { close(fd); errno = error; return -1; }
  return fd;
}

static FILE *descriptor_fopen(const char *path, const char *mode) {
  int flags = mode[0] == 'r' ? O_RDONLY : O_WRONLY | O_CREAT;
  if (mode[0] == 'w') flags |= O_TRUNC;
  if (mode[0] == 'a') flags |= O_APPEND;
  int fd = descriptor_open(path, flags, 0666);
  if (fd < 0) return NULL;
  FILE *f = fdopen(fd, mode);
  if (!f) { int error = errno; close(fd); errno = error; }
  return f;
}

#define main embedded_runtime_main
#include "stdio_descriptor_runtime.c"
#undef main
#include "stdio_descriptor_process.c"

static long long field(long long w, int n) { return ((long long *)w)[n]; }
static int ok(long long w) { return field(w, 0) == MDK_TAG_OK; }
static long long content(const char *op, const char *path) {
  long long p = mdk_str_cstr(path), s = mdk_str_cstr("BYTES\n");
  if (!strcmp(op, "read")) return mdk_read_file(p, mdk_nil());
  if (!strcmp(op, "hash")) return mdk_hash_file(p, mdk_nil());
  if (!strcmp(op, "read-bytes")) return mdk_read_file_bytes(p, mdk_nil());
  if (!strcmp(op, "write")) return mdk_write_file(p, s, mdk_nil());
  if (!strcmp(op, "append")) return mdk_append_file(p, s, mdk_nil());
  if (!strcmp(op, "telemetry")) return mdk_append_file_except_stdout(p, s, mdk_nil());
  if (!strcmp(op, "write-mode")) return mdk_write_file_mode(p, (0600 << 1) | 1, s, mdk_nil());
  if (!strcmp(op, "fsync")) return mdk_fsync(p, mdk_nil());
  assert(!strcmp(op, "write-bytes"));
  long long *a = mdk_alloc(32); a[0] = 3; a[1] = 511; a[2] = 1; a[3] = 165;
  return mdk_write_file_bytes(p, (long long)a, mdk_nil());
}

static int worker(const char *marker, int stream_mode) {
  long long r = mdk_process_submit(mdk_str_cstr("/usr/bin/touch"),
    mdk_cons(mdk_str_cstr(marker), mdk_nil()), mdk_str_cstr("/tmp"), mdk_nil(), stream_mode, stream_mode, stream_mode);
  if (!ok(r)) { event("submit_error", 1, 0); return 77; }
  long long ticket = field(r, 1), process = 0;
  for (int i = 0; i < 10000; ++i) {
    r = mdk_process_check_start(ticket);
    if (!ok(r)) { event("check_start_error", 1, 0); return 78; }
    long long row = field(r, 1); int kind = field(row, 1) >> 1;
    if (kind == 1) { process = field(field(row, 2), 1); break; }
    if (kind == 2) {
      long long error = field(field(row, 3), 1);
      event("launch_failed", field(error, 1) >> 1, field(error, 2) >> 1);
      event("owner_roots_after_failure", mdk_process_test_roots(), 0);
      return 77;
    }
    usleep(1000);
  }
  if (!process) { event("cleanup_incomplete_ticket", 1, 0); return 78; }
  event("worker_pid", mdk_process_test_pid(process), 0);
  for (int i = 0; i < 10000; ++i) {
    r = mdk_process_poll_exit(process);
    if (!ok(r)) { event("cleanup_incomplete_process", 1, 0); return 78; }
    if (!(field(r, 1) & 1)) {
      long long status = field(field(r, 1), 1);
      event("worker_exit", field(status, 2) >> 1, field(status, 1) >> 1);
      event("worker_disposed", ok(mdk_process_dispose(process)), 0);
      event("owner_roots_after_dispose", mdk_process_test_roots(), 0);
      return 0;
    }
    usleep(1000);
  }
  event("cleanup_incomplete_process", 1, 0); return 78;
}

int main(int argc, char **argv) {
  assert(argc == 6);
  report_fd = atoi(argv[1]); mutation = argv[5];
  int result = claim(); event("claim", result, errno);
  if (result) { result = 77; goto cleanup; }
  if (!strcmp(argv[2], "worker")) {
    mdk_process_submission_init(); result = worker(argv[4], !strcmp(argv[3], "null") ? 3 : 1);
  } else {
    long long r = content(argv[3], argv[4]);
    event("content_ok", ok(r), 0);
    if (!ok(r)) event("content_error", 1, errno);
    else if (!strcmp(argv[3], "read")) {
      long long s = field(r, 1);
      event("read_length", ((long long *)s)[1], 0);
      int fd = open(getenv("DESCRIPTOR_READ_RECEIPT"), O_WRONLY | O_CREAT | O_EXCL, 0600);
      assert(fd >= 0);
      assert(write(fd, (char *)s + 24, ((long long *)s)[1]) == ((long long *)s)[1]);
      assert(close(fd) == 0);
    }
    result = 0;
  }
cleanup:
  for (int i = 0; i < 2; ++i) if (pins[i] >= 0) close(pins[i]);
  return result;
}
