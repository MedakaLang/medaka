#define _GNU_SOURCE
#ifdef NDEBUG
#error "lease experiment requires assertions"
#endif
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/vfs.h>
#include <unistd.h>

/* Observer equipment is outside caller authority; no hook is installed in production. */
static struct stat endpoints[2];
static int pins[2] = {-1, -1}, claimed, report_fd;
static const char *mutation, *scenario;
static const char *self_exe;
static _Atomic int ambient, owner_calls, shutdown_owner;
static sem_t owner_ready, owner_resume;
static pthread_t owner_thread;
static int first_owner_fd = -1;
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
static int content_open(const char *path, int flags, ...) {
  mode_t mode = 0;
  if (flags & O_CREAT) {
    va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap);
  }
  int fd = open(path, (flags & ~O_TRUNC) | O_NONBLOCK | O_CLOEXEC, mode);
  if (fd < 0) return -1;
  int error = 0;
  struct stat target;
  int bypass = (disabled("ambient") || disabled("sticky")) && atomic_load(&ambient);
  int path_exception = disabled("pathname") && !strcmp(path, "/dev/null");
  if (fstat(fd, &target)) error = errno;
  else if (claimed && !bypass && !disabled("identity") &&
           (same(&target, &endpoints[0]) || same(&target, &endpoints[1]))) error = EPERM;
  else if (claimed && !bypass && !path_exception && !S_ISREG(target.st_mode) &&
           !S_ISFIFO(target.st_mode) &&
           !(!strcmp(scenario, "directory") && disabled("directory") && S_ISDIR(target.st_mode))) {
    error = EINVAL; event("type_denied", target.st_mode & S_IFMT, error);
  }
  if (!error && (flags & O_TRUNC) && ftruncate(fd, 0)) error = errno;
  if (error) { close(fd); errno = error; return -1; }
  return fd;
}
static FILE *content_fopen(const char *path, const char *mode) {
  int flags = mode[0] == 'r' ? O_RDONLY : O_WRONLY | O_CREAT;
  if (mode[0] == 'w') flags |= O_TRUNC;
  if (mode[0] == 'a') flags |= O_APPEND;
  int fd = content_open(path, flags, 0666);
  if (fd < 0) return NULL;
  FILE *f = fdopen(fd, mode);
  if (!f) { int error = errno; close(fd); errno = error; }
  return f;
}

/* The scratch transform substitutes only construct_native's literal open.
   Direction is the sole operand: no caller pathname or dynamic authority flag. */
static int owner_null(int stream) {
  assert(stream >= 0 && stream < 3);
  int call = atomic_fetch_add(&owner_calls, 1) + 1;
  if (disabled("owner")) return content_open("/dev/null", (stream ? O_WRONLY : O_RDONLY) | O_CLOEXEC);
  if ((!strcmp(scenario, "overlap") || !strcmp(scenario, "rollback")) && call == 1) {
    atomic_store(&ambient, 1);
    int nested = content_open("/proc/self/fd/1", O_WRONLY | O_APPEND);
    event("nested_endpoint_open", nested >= 0, errno);
    if (nested >= 0) { assert(write(nested, "NESTED\n", 7) == 7); close(nested); }
    int null_fd = content_open("/dev/null", O_RDONLY);
    event("nested_null_open", null_fd >= 0, errno);
    if (null_fd >= 0) close(null_fd);
    assert(!sem_post(&owner_ready));
    while (sem_wait(&owner_resume)) assert(errno == EINTR);
    if (!disabled("sticky")) atomic_store(&ambient, 0);
  }
  if (!strcmp(scenario, "rollback") && call == 2 && !disabled("rollback")) {
    event("injected_setup_failure", call, EIO); errno = EIO; return -1;
  }
  int fd = open("/dev/null", (stream ? O_WRONLY : O_RDONLY) | O_CLOEXEC);
  struct stat st;
  if (fd < 0) return fd;
  if (call == 1) first_owner_fd = fd;
  assert(!fstat(fd, &st));
  event("owner_null_open", stream, S_ISCHR(st.st_mode));
  return fd;
}

#define main embedded_runtime_main
#include "stdio_lease_runtime.c"
#undef main
#include "stdio_lease_process.c"

static long long field(long long w, int n) { return ((long long *)w)[n]; }
static int ok(long long w) { return field(w, 0) == MDK_TAG_OK; }
static const char *operations[] = {"read", "hash", "read-bytes", "write", "append",
  "telemetry", "write-bytes", "write-mode", "fsync"};
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
static void content_attacks(const char *prefix) {
  char label[80];
  for (int i = 0; i < 9; ++i) {
    const char *path = i < 3 ? "/proc/self/fd/0" : "/proc/self/fd/1";
    snprintf(label, sizeof(label), "%s_%s", prefix, operations[i]);
    event(label, ok(content(operations[i], path)), 0);
  }
  int fd = content_open("/dev/null", O_RDONLY);
  snprintf(label, sizeof(label), "%s_null_open", prefix);
  event(label, fd >= 0, errno);
  if (fd >= 0) close(fd);
}
static int fd_count(void) {
  DIR *directory = opendir("/proc/self/fd");
  assert(directory);
  int n = 0;
  struct dirent *entry;
  while ((entry = readdir(directory))) if (strcmp(entry->d_name, ".") && strcmp(entry->d_name, "..")) ++n;
  assert(!closedir(directory));
  return n - 1;
}
static int worker(const char *marker, int stream_mode) {
  long long r = mdk_process_submit(mdk_str_cstr(self_exe),
    mdk_cons(mdk_str_cstr("child"), mdk_cons(mdk_str_cstr(marker), mdk_nil())),
    mdk_str_cstr("/tmp"), mdk_nil(), stream_mode, stream_mode, stream_mode);
  if (!ok(r)) { event("submit_error", 1, 0); return 1; }
  if (!strcmp(scenario, "overlap") || !strcmp(scenario, "rollback")) {
    while (sem_wait(&owner_ready)) assert(errno == EINTR);
    event("owner_held", atomic_load(&owner_calls), 0);
    content_attacks("concurrent");
    assert(!sem_post(&owner_resume));
  }
  long long ticket = field(r, 1), process = 0;
  for (int i = 0; i < 10000; ++i) {
    r = mdk_process_check_start(ticket);
    if (!ok(r)) { event("check_start_error", 1, 0); return 1; }
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
  if (!process) { event("cleanup_incomplete_ticket", 1, 0); return 1; }
  event("worker_pid", mdk_process_test_pid(process), 0);
  for (int i = 0; i < 10000; ++i) {
    r = mdk_process_poll_exit(process);
    if (!ok(r)) { event("cleanup_incomplete_process", 1, 0); return 1; }
    if (!(field(r, 1) & 1)) {
      long long status = field(field(r, 1), 1);
      event("worker_exit", field(status, 2) >> 1, field(status, 1) >> 1);
      if (stream_mode == 1) {
        int fd = open(getenv("LEASE_WORKER_RECEIPT"), O_WRONLY | O_CREAT | O_EXCL, 0600);
        assert(fd >= 0);
        for (;;) {
          long long chunk = mdk_process_try_read(process, 3, 129);
          assert(ok(chunk));
          long long option = field(chunk, 1);
          assert(!(option & 1));
          long long block = field(option, 1), size = field(block, 1);
          if (!size) break;
          assert(write(fd, (char *)block + 16, size) == size);
        }
        assert(!close(fd));
        event("worker_stream_eof", 1, 0);
      } else {
        event("worker_stream_closed", !ok(mdk_process_try_read(process, 3, 129)), 0);
      }
      event("worker_disposed", ok(mdk_process_dispose(process)), 0);
      event("owner_roots_after_dispose", mdk_process_test_roots(), 0);
      return 0;
    }
    usleep(1000);
  }
  event("cleanup_incomplete_process", 1, 0); return 1;
}
int main(int argc, char **argv) {
  if (argc == 3 && !strcmp(argv[1], "child")) {
    int fd = open(argv[2], O_WRONLY | O_CREAT | O_EXCL, 0600);
    assert(fd >= 0 && write(fd, "CHILD\n", 6) == 6 && !close(fd));
    assert(write(1, "WIRE\0\xff\n", 7) == 7);
    return 0;
  }
  assert(argc == 6);
  self_exe = argv[0];
  report_fd = atoi(argv[1]); scenario = argv[2]; mutation = argv[5];
  assert(!sem_init(&owner_ready, 0, 0) && !sem_init(&owner_resume, 0, 0));
  int result = claim(); event("claim", result, errno);
  if (result) { result = 1; goto cleanup; }
  if (!strcmp(scenario, "worker") || !strcmp(scenario, "overlap") || !strcmp(scenario, "rollback")) {
    mdk_process_submission_init();
    assert(submission_available);
    int before = fd_count();
    event("fds_before_worker", before, 0);
    result = worker(argv[4], !strcmp(argv[3], "null") ? 3 : 1);
    content_attacks("after");
    event("owner_calls", atomic_load(&owner_calls), 0);
    event("fds_after_worker", fd_count(), 0);
    if (disabled("cleanup")) {
      assert(first_owner_fd >= 0 && !close(first_owner_fd));
      event("mutation_leak_reclaimed", 1, 0);
    }
    assert(mdk_process_test_roots() == 0);
    for (int i = 0; i < 8; ++i) assert(atomic_load(&submissions[i].phase) == SUBMISSION_FREE);
    atomic_store(&shutdown_owner, 1);
    assert(!sem_post(&submission_jobs));
    assert(!GC_pthread_join(owner_thread, NULL));
    assert(!sem_destroy(&submission_jobs));
    event("owner_thread_joined", 1, 0);
  } else {
    long long r = content(argv[3], argv[4]);
    event("content_ok", ok(r), 0);
    if (!ok(r)) event("content_error", 1, errno);
    else if (!strcmp(argv[3], "read")) {
      long long s = field(r, 1);
      event("read_length", ((long long *)s)[1], 0);
      int fd = open(getenv("LEASE_READ_RECEIPT"), O_WRONLY | O_CREAT | O_EXCL, 0600);
      assert(fd >= 0);
      assert(write(fd, (char *)s + 24, ((long long *)s)[1]) == ((long long *)s)[1]);
      assert(close(fd) == 0);
    }
  }
cleanup:
  for (int i = 0; i < 2; ++i) if (pins[i] >= 0) close(pins[i]);
  assert(!sem_destroy(&owner_ready) && !sem_destroy(&owner_resume));
  return result;
}
