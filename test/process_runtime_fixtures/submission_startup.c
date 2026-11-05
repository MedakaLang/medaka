#include "medaka_process.h"
#include "medaka_runtime.h"
#include <stdio.h>
#include <unistd.h>

extern int mdk_process_test_workers(void);
static long long field(long long value, int slot) { return ((long long *)value)[slot]; }
static int ok(long long value) { return field(value, 0) == MDK_TAG_OK; }

int mdk_program_main(int argc, char **argv) {
  (void)argc; (void)argv; alarm(10);
  long long nil = (MDK_TAG_NIL << 1) | 1;
  long long path = mdk_runtime_string("/bin/true"), cwd = mdk_runtime_string("/tmp");
  long long submitted = mdk_process_submit(path, nil, cwd, nil, 1, 1, 1);
#ifdef MDK_SUBMIT_UNSUPPORTED
  if (mdk_process_test_workers() != 0 || ok(submitted) ||
      (field(field(submitted, 1), 1) >> 1) != 10) return 1;
  long long synchronous = mdk_process_start(path, nil, cwd, nil, 1, 1, 1);
  if (ok(synchronous) || (field(field(synchronous, 1), 1) >> 1) != 10) return 2;
  puts("unsupported submission refuses without a worker passed");
#else
  if (mdk_process_test_workers() != 1 || !ok(submitted)) return 3;
  long long started = mdk_process_retry_start(field(submitted, 1));
  if (!ok(started)) return 4;
  long long p = field(started, 1);
  for (;;) {
    long long status = mdk_process_poll_exit(p);
    if (!ok(status)) return 5;
    if (!(field(status, 1) & 1)) break;
    usleep(1000);
  }
  if (!ok(mdk_process_dispose(p))) return 6;
  puts("linked process worker startup passed");
#endif
  return 0;
}
