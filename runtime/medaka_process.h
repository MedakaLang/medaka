#ifndef MEDAKA_PROCESS_H
#define MEDAKA_PROCESS_H

typedef struct MdkProcess MdkProcess;
long long mdk_process_start(long long program, long long argv, long long cwd,
                            long long env, long long in_mode, long long out_mode,
                            long long err_mode);
long long mdk_process_retry_start(long long ticket);
long long mdk_process_check_start(long long ticket);
long long mdk_process_abort_start(long long ticket);
long long mdk_process_poll_exit(long long process);
long long mdk_process_close_stdin(long long process);
long long mdk_process_dispose(long long process);

long long mdk_process_try_read(long long, long long, long long);
long long mdk_process_try_write(long long, long long, long long, long long);
long long mdk_process_stream_fd(long long, long long);

#endif
