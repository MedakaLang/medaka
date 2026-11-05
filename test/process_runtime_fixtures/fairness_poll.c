#define _GNU_SOURCE
#include <dlfcn.h>
#include <poll.h>
#include <stdatomic.h>
#include <stdio.h>
#include <unistd.h>

static _Atomic unsigned long calls;
int poll(struct pollfd *fds, nfds_t count, int timeout) {
  static int (*real_poll)(struct pollfd *, nfds_t, int);
  if (!real_poll) real_poll = dlsym(RTLD_NEXT, "poll");
  atomic_fetch_add(&calls, 1);
  return real_poll(fds, count, timeout);
}
__attribute__((destructor)) static void receipt(void) {
  dprintf(2, "fairness polls pid=%ld count=%lu\n", (long)getpid(), atomic_load(&calls));
}
