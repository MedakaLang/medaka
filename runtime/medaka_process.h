#ifndef MEDAKA_PROCESS_H
#define MEDAKA_PROCESS_H

typedef struct MdkProcess MdkProcess;
long long mdk_process_start(long long program, long long argv, long long cwd,
                            long long env, long long in_mode, long long out_mode,
                            long long err_mode);
long long mdk_process_poll_exit(long long process);
long long mdk_process_close_stdin(long long process);
long long mdk_process_dispose(long long process);

#endif
