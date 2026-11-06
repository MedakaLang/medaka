#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <gc.h>
#include <poll.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

extern int mdk_process_test_roots(void);
extern int mdk_process_test_permits(void);
static _Atomic unsigned long calls;
static size_t allocated_before, heap_before, live_before;
static int fds_before;
static int count_fds(void) {
  int n = 0;
  for (int i = 0; i < 1024; ++i) n += fcntl(i, F_GETFD) >= 0;
  return n;
}
__attribute__((constructor)) static void baseline(void) {
  GC_INIT();
  GC_gcollect();
  allocated_before = GC_get_total_bytes();
  heap_before = GC_get_heap_size();
  live_before = heap_before - GC_get_free_bytes();
  fds_before = count_fds();
}
int poll(struct pollfd *fds, nfds_t count, int timeout) {
  static int (*real_poll)(struct pollfd *, nfds_t, int);
  if (!real_poll) real_poll = dlsym(RTLD_NEXT, "poll");
  atomic_fetch_add(&calls, 1);
  return real_poll(fds, count, timeout);
}
__attribute__((destructor)) static void receipt(void) {
  if (getenv("FAIRNESS_LEAK")) (void)open("/dev/null", O_RDONLY);
  GC_gcollect();
  size_t heap = GC_get_heap_size();
  size_t live = heap - GC_get_free_bytes();
  size_t allocation = GC_get_total_bytes() - allocated_before;
  int fds = count_fds(), roots = mdk_process_test_roots(), permits = mdk_process_test_permits();
  dprintf(2, "fairness polls pid=%ld count=%lu allocation=%zu heap_before=%zu heap_after=%zu live_before=%zu live_after=%zu fds_before=%d fds_after=%d roots=%d permits=%d\n",
          (long)getpid(), atomic_load(&calls), allocation, heap_before, heap, live_before, live, fds_before, fds, roots, permits);
  if (allocation > 64*1024*1024 || heap > heap_before+64*1024*1024 ||
      live > live_before+64*1024*1024 || fds != fds_before || roots || permits) _exit(4);
}
