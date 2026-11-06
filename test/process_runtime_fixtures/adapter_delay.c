#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/wait.h>
#include <unistd.h>

static int (*real_execve)(const char *, char *const[], char *const[]);
static int (*real_pipe2)(int[2], int);
static int (*real_close)(int);
static int (*real_waitid)(idtype_t, id_t, siginfo_t *, int);
static ssize_t (*real_write)(int, const void *, size_t);
static int delay_write, delay_eintr, writes, fail_wait;
static int delay_exec, delay_pipe, replace_read_fd = -1, delay_reuse;
__attribute__((constructor)) static void setup(void) {
  const char *mode = getenv("ADAPTER_DELAY");
  delay_exec = mode && (!strcmp(mode, "exec") || !strcmp(mode, "wait-error"));
  fail_wait = mode && !strcmp(mode, "wait-error");
  delay_pipe = mode && !strcmp(mode, "pipe");
  delay_write = mode && !strcmp(mode, "write");
  delay_eintr = mode && !strcmp(mode, "eintr");
  delay_reuse = mode && !strcmp(mode, "reuse");
  real_execve = dlsym(RTLD_NEXT, "execve");
  real_pipe2 = dlsym(RTLD_NEXT, "pipe2");
  real_close = dlsym(RTLD_NEXT, "close");
  real_waitid = dlsym(RTLD_NEXT, "waitid");
  real_write = dlsym(RTLD_NEXT, "write");
}
static void delay(void) {
  struct timespec pause = {0, 500000000};
  nanosleep(&pause, NULL);
}
int execve(const char *path, char *const argv[], char *const envp[]) {
  if (delay_exec) delay();
  return real_execve(path, argv, envp);
}
ssize_t write(int fd, const void *buf, size_t count) {
  if (delay_eintr && !writes && count >= 65536 && ((const char *)buf)[0] == 'x') {
    writes++; delay(); errno = EINTR; return -1;
  }
  if (delay_write && count >= 65536 && ((const char *)buf)[0] == 'x') {
    if (writes++) { errno = EIO; return -1; }
    return real_write(fd, buf, 4096);
  }
  return real_write(fd, buf, count);
}
int waitid(idtype_t type, id_t id, siginfo_t *info, int options) {
  if (fail_wait && id != (id_t)INT_MAX) { fail_wait = 0; errno = EACCES; return -1; }
  return real_waitid(type, id, info, options);
}
int close(int fd) {
  int result = real_close(fd);
  if (!result && delay_reuse && fd == replace_read_fd) {
    replace_read_fd = -2;
    int replacement = open("/dev/zero", O_RDONLY | O_CLOEXEC);
    if (replacement >= 0) {
      int reused = replacement == fd ? fd : dup2(replacement, fd);
      if (replacement != fd) real_close(replacement);
      if (reused == fd) real_write(1, "adapter fd reused\n", 18);
    }
  }
  return result;
}
int pipe2(int fd[2], int flags) {
  if (delay_pipe) delay();
  int result = real_pipe2(fd, flags);
  if (!result && delay_reuse && replace_read_fd == -1) replace_read_fd = fd[0];
  return result;
}
