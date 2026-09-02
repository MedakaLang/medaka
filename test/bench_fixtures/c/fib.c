/* C sanity ceiling for test/bench_fixtures/fib.mdk — same recursive
 * definition, same input (fib 38), no I/O in the timed path. Compiled
 * with -O2, no GC/runtime — establishes an upper bound on how fast this
 * shape of computation can go on this box, for compiler/PERF-RUNTIME.md's
 * C sanity paragraph. Not built or run by any gate. */
#include <stdio.h>

static long fib(long n) {
  if (n == 0) return 0;
  if (n == 1) return 1;
  return fib(n - 1) + fib(n - 2);
}

int main(void) {
  printf("%ld\n", fib(38));
  return 0;
}
