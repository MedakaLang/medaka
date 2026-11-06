#include "medaka_process.h"
#include "medaka_runtime.h"
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>

extern int mdk_process_test_workers(void);
static long long field(long long value, int slot) { return ((long long *)value)[slot]; }
static int ok(long long value) { return field(value, 0) == MDK_TAG_OK; }

int mdk_program_main(int argc, char **argv) {
  (void)argc; (void)argv; alarm(10);
#ifndef MDK_SUBMIT_UNSUPPORTED
  if (mdk_process_test_workers() != 1) return 7;
#endif
  long long nil = (MDK_TAG_NIL << 1) | 1;
  long long path = mdk_runtime_string("/bin/true"), cwd = mdk_runtime_string("/tmp");
  long long submitted = mdk_process_submit(path, nil, cwd, nil, 1, 1, 1);
#ifdef MDK_SUBMIT_UNSUPPORTED
  if (mdk_process_test_workers() != 0 || ok(submitted) ||
      (field(field(submitted, 1), 1) >> 1) != 10) return 1;
  long long synchronous = mdk_process_start(path, nil, cwd, nil, 1, 1, 1);
  if (ok(synchronous) || (field(field(synchronous, 1), 1) >> 1) != 10) return 2;
  int fds[2];
  if (pipe(fds)) return 8;
  int before_read = fcntl(fds[0], F_GETFL), before_write = fcntl(fds[1], F_GETFL);
  long long results[] = {
    mdk_process_stream_fd(0, 3),
    mdk_process_try_read(0, 3, 3),
    mdk_process_try_write(0, 0, 1, 3),
    mdk_process_close_stdin(0)
  };
  for (unsigned i = 0; i < sizeof(results) / sizeof(results[0]); ++i)
    if (ok(results[i]) || (field(field(results[i], 1), 1) >> 1) != 10) return 9 + i;
  if (before_read < 0 || before_write < 0 || fcntl(fds[0], F_GETFL) != before_read ||
      fcntl(fds[1], F_GETFL) != before_write) return 13;
  close(fds[0]); close(fds[1]);
  puts("unsupported stream operations refuse without fd mutation passed");
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
