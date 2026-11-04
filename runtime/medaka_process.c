#define _GNU_SOURCE
#include "medaka_process.h"
#include "medaka_runtime.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __linux__
#include <linux/close_range.h>
#include <linux/sched.h>
#include <sys/syscall.h>
#include <limits.h>
#endif

typedef struct { int operation, error; const char *message; } MdkProcessError;
typedef struct { char *program, *cwd; char **argv, **env; int mode[3]; } MdkSpawnSpec;
typedef enum { MDK_LAUNCH_PENDING, MDK_LAUNCH_OWNED, MDK_LAUNCH_FAILED,
  MDK_LAUNCH_ABORTED, MDK_LAUNCH_LOST_WAIT, MDK_LAUNCH_ERROR } MdkLaunchStep;
typedef enum { LAUNCHING, FAILING, ABORTING, RUNNING, REAPED, LOST, DISPOSED } State;
struct MdkProcess {
  struct MdkProcess *next;
  State state;
  MdkLaunchStep launch_step;
  int pidfd, error_fd, streams[3], signalled;
  int status_kind, status_value, status_core;
  unsigned char record[2 * sizeof(int)];
  size_t record_len;
  MdkProcessError failure;
#ifdef MDK_PROCESS_TESTING
  pid_t test_pid;
#endif
};
static pthread_mutex_t process_lock = PTHREAD_MUTEX_INITIALIZER;
static MdkProcess *process_roots;
#ifdef MDK_PROCESS_TESTING
static int test_gate = -1, test_ready = -1;
static int test_signal_error, test_wait_error, test_poll_error;
static int test_signals, test_waits, test_polls;
#endif

static long long box_int(int n) { return (long long)n * 2 + 1; }
static long long error_tuple(int op, int err, const char *message) {
  long long *tuple = mdk_alloc(4 * sizeof(long long));
  tuple[0] = MDK_TUPLE_TAG; tuple[1] = box_int(op); tuple[2] = box_int(err);
  tuple[3] = mdk_runtime_string(message);
  return (long long)tuple;
}
static long long error_result(int op, int err, const char *message) {
  return mdk_err(error_tuple(op, err, message));
}
static long long start_error(MdkProcessError error, MdkProcess *ticket) {
  long long *tuple = mdk_alloc(5 * sizeof(long long));
  tuple[0] = MDK_TUPLE_TAG; tuple[1] = box_int(error.operation);
  tuple[2] = box_int(error.error); tuple[3] = mdk_runtime_string(error.message);
  tuple[4] = ticket ? mdk_some((long long)ticket) : mdk_none();
  return mdk_err((long long)tuple);
}
static long long launch_result(MdkLaunchStep step, MdkProcess *p, MdkProcessError error) {
  if (step == MDK_LAUNCH_ERROR) return error_result(error.operation, error.error, error.message);
  int kind = step == MDK_LAUNCH_OWNED ? 1 : step == MDK_LAUNCH_ABORTED ? 3 :
             step == MDK_LAUNCH_PENDING ? 0 : 2;
  long long *tuple = mdk_alloc(4 * sizeof(long long));
  tuple[0] = MDK_TUPLE_TAG; tuple[1] = box_int(kind);
  tuple[2] = kind == 1 ? mdk_some((long long)p) : mdk_none();
  tuple[3] = kind == 2 ? mdk_some(error_tuple(error.operation, error.error, error.message)) : mdk_none();
  return mdk_ok((long long)tuple);
}
static void root(MdkProcess *p) { p->next = process_roots; process_roots = p; }
static void unroot(MdkProcess *p) {
  MdkProcess **link = &process_roots;
  while (*link && *link != p) link = &(*link)->next;
  if (*link) *link = p->next;
  p->next = NULL;
}
static int close_once(int *slot) {
  int fd = *slot; *slot = -1;
  return fd < 0 ? 0 : close(fd);
}
static void close_streams(MdkProcess *p) {
  for (int i = 0; i < 3; ++i) close_once(&p->streams[i]);
}
static void free_spec(MdkSpawnSpec *s) {
  free(s->program); free(s->cwd);
  if (s->argv) { for (size_t i = 0; s->argv[i]; ++i) free(s->argv[i]); free(s->argv); }
  if (s->env) { for (size_t i = 0; s->env[i]; ++i) free(s->env[i]); free(s->env); }
}
static char *copy_string(long long word) {
  const long long *cell = (const long long *)word;
  long long len = cell[MDK_STRING_BYTE_LENGTH_SLOT];
  if (len < 0 || (uint64_t)len >= SIZE_MAX) { errno = EINVAL; return NULL; }
  const char *bytes = (const char *)cell + MDK_STRING_BYTES_OFFSET;
  if (memchr(bytes, 0, (size_t)len)) { errno = EINVAL; return NULL; }
  char *out = malloc((size_t)len + 1);
  if (out) { memcpy(out, bytes, (size_t)len); out[len] = 0; }
  return out;
}
static size_t list_length(long long list) {
  size_t n = 0;
  while (!(list & 1)) { ++n; list = ((long long *)list)[2]; }
  return n;
}
static int fill_spec(MdkSpawnSpec *s, long long program, long long argv,
                     long long cwd, long long env, long long in, long long out, long long err) {
  long long modes[] = {in, out, err};
  for (int i = 0; i < 3; ++i) { if (modes[i] != 1 && modes[i] != 3) return 0; s->mode[i] = (int)(modes[i] >> 1); }
  s->program = copy_string(program); s->cwd = copy_string(cwd);
  if (!s->program || !s->cwd || s->program[0] != '/' || s->cwd[0] != '/') return 0;
  size_t n = list_length(argv), m = list_length(env);
  if (n > SIZE_MAX / sizeof(char *) - 2 || m > SIZE_MAX / sizeof(char *) - 1) return 0;
  s->argv = calloc(n + 2, sizeof(char *)); s->env = calloc(m + 1, sizeof(char *));
  if (!s->argv || !s->env || !(s->argv[0] = strdup(s->program))) return 0;
  for (size_t i = 0; i < n; ++i) {
    long long *c = (long long *)argv; s->argv[i + 1] = copy_string(c[1]); argv = c[2];
    if (!s->argv[i + 1]) return 0;
  }
  for (size_t i = 0; i < m; ++i) {
    long long *c = (long long *)env, *pair = (long long *)c[1]; env = c[2];
    char *key = copy_string(pair[1]), *value = copy_string(pair[2]);
    if (!key || !value || !*key || strchr(key, '=')) { free(key); free(value); return 0; }
    size_t k = strlen(key), v = strlen(value);
    for (size_t j = 0; j < i; ++j) if (!strncmp(s->env[j], key, k) && s->env[j][k] == '=') { free(key); free(value); return 0; }
    if (k > SIZE_MAX - v - 2 || !(s->env[i] = malloc(k + v + 2))) { free(key); free(value); return 0; }
    memcpy(s->env[i], key, k); s->env[i][k] = '='; memcpy(s->env[i] + k + 1, value, v + 1);
    free(key); free(value);
  }
  return 1;
}
#ifdef __linux__
static int move_fd(int fd) {
  if (fd > 2) return fd;
  int moved = fcntl(fd, F_DUPFD_CLOEXEC, 3);
  int saved = errno; close(fd); errno = saved; return moved;
}
static int make_pipe(int fd[2]) {
  if (pipe2(fd, O_CLOEXEC)) return -1;
  fd[0] = move_fd(fd[0]);
  if (fd[0] < 0) { int e = errno; close(fd[1]); errno = e; return -1; }
  fd[1] = move_fd(fd[1]);
  if (fd[1] < 0) { int e = errno; close(fd[0]); fd[0] = -1; errno = e; return -1; }
  return 0;
}
static int nonblock(int fd) {
  int flags = fcntl(fd, F_GETFL);
  return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}
static int capability(void) {
  errno = 0;
  if (syscall(SYS_pidfd_send_signal, -1, 0, NULL, 0) != -1 || errno != EBADF) return -1;
  siginfo_t info = {0};
  errno = 0;
  if (waitid(P_PIDFD, (id_t)INT_MAX, &info, WEXITED | WNOHANG) != -1 || errno != EBADF) return -1;
  return (int)syscall(SYS_close_range, UINT_MAX, UINT_MAX, CLOSE_RANGE_CLOEXEC);
}
static MdkProcess *process_begin(const MdkSpawnSpec *s, MdkProcessError *error) {
  struct sigaction action;
  if (sigaction(SIGCHLD, NULL, &action)) {
    *error = (MdkProcessError){7, errno, "SIGCHLD wait ownership unavailable"}; return NULL;
  }
  if (action.sa_handler != SIG_DFL || (action.sa_flags & SA_NOCLDWAIT)) {
    *error = (MdkProcessError){7, 0, "SIGCHLD wait ownership unavailable"}; return NULL;
  }
  if (capability()) { *error = (MdkProcessError){10, errno, "required process facility unavailable"}; return NULL; }
  MdkProcess *p = mdk_alloc(sizeof(*p));
  memset(p, 0, sizeof(*p));
  p->pidfd = p->error_fd = -1;
  for (int i = 0; i < 3; ++i) p->streams[i] = -1;
  root(p);
  int child[3] = {-1, -1, -1}, ep[2] = {-1, -1};
  for (int i = 0; i < 3; ++i) {
    if (s->mode[i] == 1) {
      int fd = open("/dev/null", (i ? O_WRONLY : O_RDONLY) | O_CLOEXEC);
      if (fd < 0 || (child[i] = move_fd(fd)) < 0) goto fail;
    } else {
      int pair[2]; if (make_pipe(pair)) goto fail;
      child[i] = pair[i == 0 ? 0 : 1]; p->streams[i] = pair[i == 0 ? 1 : 0];
      if (nonblock(p->streams[i])) goto fail;
    }
  }
  if (make_pipe(ep) || nonblock(ep[0])) goto fail;
  struct clone_args args = {0};
  args.flags = CLONE_PIDFD; args.pidfd = (uintptr_t)&p->pidfd; args.exit_signal = SIGCHLD;
  sigset_t blocked, old_mask;
  sigfillset(&blocked);
  int mask_error = pthread_sigmask(SIG_BLOCK, &blocked, &old_mask);
  if (mask_error) { *error = (MdkProcessError){10, mask_error, "signal mask"}; goto cleanup; }
  long pid = syscall(SYS_clone3, &args, sizeof(args));
  if (pid) {
    int saved = errno;
    pthread_sigmask(SIG_SETMASK, &old_mask, NULL);
    errno = saved;
  }
  if (pid < 0) { int e = errno; *error = (MdkProcessError){e == ENOSYS || e == EPERM ? 10 : 2, e, "clone3"}; goto cleanup; }
  if (!pid) {
    int failure[2] = {1, 0};
#ifdef MDK_PROCESS_TESTING
    if (test_gate >= 0) {
      char byte = 1;
      if (write(test_ready, &byte, 1) != 1 || read(test_gate, &byte, 1) != 1) _exit(126);
    }
#endif
    for (int sig = 1; sig < NSIG; ++sig) {
      if (sig == SIGKILL || sig == SIGSTOP) continue;
      struct sigaction prior;
      if (sigaction(sig, NULL, &prior)) { if (errno == EINVAL) continue; goto child_failure; }
      if (prior.sa_handler != SIG_DFL && prior.sa_handler != SIG_IGN) {
        struct sigaction reset = {0}; reset.sa_handler = SIG_DFL; sigemptyset(&reset.sa_mask);
        if (sigaction(sig, &reset, NULL)) goto child_failure;
      }
    }
    if (sigprocmask(SIG_SETMASK, &old_mask, NULL)) goto child_failure;
    for (int i = 0; i < 3; ++i) if (dup2(child[i], i) < 0) goto child_failure;
    if (syscall(SYS_close_range, 3U, UINT_MAX, CLOSE_RANGE_CLOEXEC) < 0) goto child_failure;
    failure[0] = 3; if (chdir(s->cwd) < 0) goto child_failure;
    failure[0] = 4; execve(s->program, s->argv, s->env);
  child_failure:
    failure[1] = errno;
    while (write(ep[1], failure, sizeof(failure)) < 0 && errno == EINTR) {}
    _exit(127);
  }
  for (int i = 0; i < 3; ++i) close(child[i]);
  close(ep[1]); p->error_fd = ep[0]; p->state = LAUNCHING;
#ifdef MDK_PROCESS_TESTING
  p->test_pid = (pid_t)pid;
#endif
  return p;
fail:
  *error = (MdkProcessError){1, errno, "pipe or descriptor setup"};
cleanup:
  for (int i = 0; i < 3; ++i) if (child[i] >= 0) close(child[i]);
  if (ep[0] >= 0) close(ep[0]); if (ep[1] >= 0) close(ep[1]);
  close_streams(p); unroot(p); return NULL;
}
static int observe(MdkProcess *p, MdkProcessError *error) {
  siginfo_t info = {0};
  int result;
#ifdef MDK_PROCESS_TESTING
  ++test_waits;
  if (test_wait_error) { errno = test_wait_error; result = -1; }
  else
#endif
  result = waitid(P_PIDFD, p->pidfd, &info, WEXITED | WNOHANG);
  if (result) {
    if (errno == EINTR) return 0;
    *error = (MdkProcessError){5, errno, "waitid"};
    if (errno == ECHILD) { close_once(&p->pidfd); p->state = LOST; return -1; }
    return -2;
  }
  if (!info.si_pid) return 0;
  p->status_kind = info.si_code == CLD_EXITED ? 0 : 1;
  p->status_value = info.si_status; p->status_core = info.si_code == CLD_DUMPED;
  close_once(&p->pidfd); p->state = REAPED; return 1;
}
static MdkLaunchStep process_check_start(MdkProcess *p, MdkProcessError *error) {
  if (p->launch_step == MDK_LAUNCH_OWNED) {
    if (p->state != DISPOSED) return MDK_LAUNCH_OWNED;
    *error = (MdkProcessError){8, 0, "process closed"}; return MDK_LAUNCH_ERROR;
  }
  if (p->launch_step != MDK_LAUNCH_PENDING) {
    *error = p->failure; return p->launch_step;
  }
  if (p->state == LAUNCHING) {
    ssize_t n = read(p->error_fd, p->record + p->record_len, sizeof(p->record) - p->record_len);
    if (n < 0 && (errno == EAGAIN || errno == EINTR)) return MDK_LAUNCH_PENDING;
    if (n > 0) p->record_len += (size_t)n;
    if (p->record_len == sizeof(p->record)) {
      int pair[2]; memcpy(pair, p->record, sizeof(pair));
      p->failure = (MdkProcessError){pair[0] == 1 || pair[0] == 3 || pair[0] == 4 ? pair[0] : 11, pair[1], "child setup"};
      close_once(&p->error_fd); close_streams(p); p->state = FAILING;
    } else if (!n) {
      close_once(&p->error_fd);
      if (!p->record_len) { p->state = RUNNING; p->launch_step = MDK_LAUNCH_OWNED; return MDK_LAUNCH_OWNED; }
      p->failure = (MdkProcessError){11, 0, "partial launch record"}; close_streams(p); p->state = FAILING;
    } else if (n < 0) {
      p->failure = (MdkProcessError){11, errno, "launch handshake"}; close_once(&p->error_fd); close_streams(p); p->state = FAILING;
    } else return MDK_LAUNCH_PENDING;
  }
  if (p->state == FAILING || p->state == ABORTING) {
    State before = p->state;
    int signal_error = 0;
    if (!p->signalled) {
      int result;
#ifdef MDK_PROCESS_TESTING
      ++test_signals;
      if (test_signal_error) { errno = test_signal_error; result = -1; }
      else
#endif
      result = (int)syscall(SYS_pidfd_send_signal, p->pidfd, SIGKILL, NULL, 0);
      if (result && errno != ESRCH) signal_error = errno;
      else p->signalled = 1;
    }
    int r = observe(p, error);
    if (!r) {
      if (!signal_error) return MDK_LAUNCH_PENDING;
      *error = (MdkProcessError){5, signal_error, "pidfd_send_signal"}; return MDK_LAUNCH_ERROR;
    }
    if (r == -2) return MDK_LAUNCH_ERROR;
    close_once(&p->error_fd); close_streams(p); unroot(p);
    if (r == -1) { p->failure = *error; p->launch_step = MDK_LAUNCH_LOST_WAIT; }
    else if (before == ABORTING) {
      p->failure = (MdkProcessError){12, 0, "launch cancelled"}; p->launch_step = MDK_LAUNCH_ABORTED;
    } else p->launch_step = MDK_LAUNCH_FAILED;
    *error = p->failure; return p->launch_step;
  }
  *error = (MdkProcessError){0, 0, "invalid launch state"};
  return MDK_LAUNCH_ERROR;
}
static MdkLaunchStep process_abort_start(MdkProcess *p, MdkProcessError *error) {
  if (p->launch_step == MDK_LAUNCH_OWNED) { *error = (MdkProcessError){0, 0, "launch ownership already transferred"}; return MDK_LAUNCH_ERROR; }
  if (p->state == LAUNCHING || p->state == FAILING) { p->state = ABORTING; close_once(&p->error_fd); close_streams(p); }
  return process_check_start(p, error);
}
static MdkLaunchStep drive_start(MdkProcess *p, MdkProcessError *error) {
  MdkLaunchStep step;
  while ((step = process_check_start(p, error)) == MDK_LAUNCH_PENDING) {
    int operation = p->state == LAUNCHING ? 11 : 5;
    int fd = p->state == LAUNCHING ? p->error_fd : p->pidfd;
    int held = fcntl(fd, F_DUPFD_CLOEXEC, 3);
    if (held < 0) { *error = (MdkProcessError){operation, errno, "launch readiness duplicate"}; return MDK_LAUNCH_ERROR; }
    struct pollfd ready = {held, POLLIN, 0};
    int injected = 0;
#ifdef MDK_PROCESS_TESTING
    ++test_polls; injected = test_poll_error;
#endif
    /* An alias may release the original fd while this caller waits without the mutex. */
    pthread_mutex_unlock(&process_lock);
    int result = injected ? -1 : poll(&ready, 1, -1);
    int saved = injected ? injected : errno;
    close(held);
    pthread_mutex_lock(&process_lock);
    if (p->launch_step != MDK_LAUNCH_PENDING) continue;
    if (result < 0 && saved == EINTR) continue;
    if (result < 0 || (ready.revents & (POLLERR | POLLNVAL))) {
      *error = (MdkProcessError){operation, result < 0 ? saved : EIO, "launch readiness wait"};
      return MDK_LAUNCH_ERROR;
    }
  }
  return step;
}
#ifdef MDK_PROCESS_TESTING
int mdk_process_test_roots(void) {
  int n = 0;
  pthread_mutex_lock(&process_lock);
  for (MdkProcess *p = process_roots; p; p = p->next) ++n;
  pthread_mutex_unlock(&process_lock);
  return n;
}
int mdk_process_test_fd(long long word, int stream) {
  return ((MdkProcess *)word)->streams[stream];
}
int mdk_process_test_flags(long long word, int stream) {
  MdkProcess *p = (MdkProcess *)word;
  return fcntl(p->streams[stream], F_GETFL);
}
int mdk_process_test_pidfd(long long word) { return ((MdkProcess *)word)->pidfd; }
int mdk_process_test_pid(long long word) { return ((MdkProcess *)word)->test_pid; }
void mdk_process_test_faults(int signal_error, int wait_error, int poll_error) {
  pthread_mutex_lock(&process_lock);
  test_signal_error = signal_error; test_wait_error = wait_error; test_poll_error = poll_error;
  pthread_mutex_unlock(&process_lock);
}
int mdk_process_test_calls(int operation) {
  pthread_mutex_lock(&process_lock);
  int n = operation == 0 ? test_signals : operation == 1 ? test_waits : test_polls;
  pthread_mutex_unlock(&process_lock);
  return n;
}
long long mdk_process_test_begin(int gate, int ready) {
  char *argv[] = {"/bin/true", NULL};
  char *env[] = {NULL};
  MdkSpawnSpec spec = {"/bin/true", "/tmp", argv, env, {1, 1, 1}};
  MdkProcessError error = {0};
  test_gate = gate; test_ready = ready;
  pthread_mutex_lock(&process_lock);
  MdkProcess *p = process_begin(&spec, &error);
  pthread_mutex_unlock(&process_lock);
  test_gate = test_ready = -1;
  return (long long)p;
}
int mdk_process_test_abort(long long word) {
  MdkProcessError error = {0};
  pthread_mutex_lock(&process_lock);
  MdkLaunchStep step = process_abort_start((MdkProcess *)word, &error);
  pthread_mutex_unlock(&process_lock);
  return (int)step;
}
#endif
#endif
long long mdk_process_start(long long program, long long argv, long long cwd, long long env,
                            long long in, long long out, long long err) {
  MdkSpawnSpec spec = {0};
  if (!fill_spec(&spec, program, argv, cwd, env, in, out, err)) {
    free_spec(&spec); return start_error((MdkProcessError){0, 0, "invalid spawn options"}, NULL);
  }
#ifndef __linux__
  free_spec(&spec); return start_error((MdkProcessError){10, 0, "native process unsupported"}, NULL);
#else
  MdkProcessError error = {0};
  pthread_mutex_lock(&process_lock);
  MdkProcess *p = process_begin(&spec, &error);
  free_spec(&spec);
  if (!p) { pthread_mutex_unlock(&process_lock); return start_error(error, NULL); }
  MdkLaunchStep step = drive_start(p, &error);
  MdkProcess *ticket = step == MDK_LAUNCH_ERROR && p->launch_step == MDK_LAUNCH_PENDING ? p : NULL;
  pthread_mutex_unlock(&process_lock);
  if (step == MDK_LAUNCH_OWNED) return mdk_ok((long long)p);
  return start_error(error, ticket);
#endif
}
long long mdk_process_retry_start(long long word) {
#ifndef __linux__
  (void)word;
  return start_error((MdkProcessError){10, 0, "native process unsupported"}, NULL);
#else
  MdkProcess *p = (MdkProcess *)word;
  MdkProcessError error = {0};
  pthread_mutex_lock(&process_lock);
  MdkLaunchStep step = drive_start(p, &error);
  MdkProcess *ticket = step == MDK_LAUNCH_ERROR && p->launch_step == MDK_LAUNCH_PENDING ? p : NULL;
  pthread_mutex_unlock(&process_lock);
  if (step == MDK_LAUNCH_OWNED) return mdk_ok(word);
  return start_error(error, ticket);
#endif
}
long long mdk_process_check_start(long long word) {
#ifndef __linux__
  (void)word;
  return error_result(10, 0, "native process unsupported");
#else
  MdkProcess *p = (MdkProcess *)word;
  MdkProcessError error = {0};
  pthread_mutex_lock(&process_lock);
  MdkLaunchStep step = process_check_start(p, &error);
  pthread_mutex_unlock(&process_lock);
  return launch_result(step, p, error);
#endif
}
long long mdk_process_abort_start(long long word) {
#ifndef __linux__
  (void)word;
  return error_result(10, 0, "native process unsupported");
#else
  MdkProcess *p = (MdkProcess *)word;
  MdkProcessError error = {0};
  pthread_mutex_lock(&process_lock);
  MdkLaunchStep step = process_abort_start(p, &error);
  pthread_mutex_unlock(&process_lock);
  return launch_result(step, p, error);
#endif
}
long long mdk_process_poll_exit(long long word) {
  MdkProcess *p = (MdkProcess *)word;
  pthread_mutex_lock(&process_lock);
  if (p->launch_step != MDK_LAUNCH_OWNED) { pthread_mutex_unlock(&process_lock); return error_result(0, 0, "launch ownership not transferred"); }
  if (p->state == DISPOSED) { pthread_mutex_unlock(&process_lock); return error_result(8, 0, "process closed"); }
#ifdef __linux__
  if (p->state == RUNNING) {
    MdkProcessError error = {0}; int r = observe(p, &error);
    if (r < 0) { pthread_mutex_unlock(&process_lock); return error_result(error.operation, error.error, error.message); }
  }
#endif
  if (p->state == LOST) { pthread_mutex_unlock(&process_lock); return error_result(5, ECHILD, "wait ownership lost"); }
  if (p->state == RUNNING) { pthread_mutex_unlock(&process_lock); return mdk_ok(mdk_none()); }
  int kind = p->status_kind, value = p->status_value, core = p->status_core;
  pthread_mutex_unlock(&process_lock);
  long long *tuple = mdk_alloc(4 * sizeof(long long));
  tuple[0] = MDK_TUPLE_TAG; tuple[1] = box_int(kind); tuple[2] = box_int(value); tuple[3] = box_int(core);
  return mdk_ok(mdk_some((long long)tuple));
}
long long mdk_process_close_stdin(long long word) {
  MdkProcess *p = (MdkProcess *)word;
  pthread_mutex_lock(&process_lock);
  if (p->launch_step != MDK_LAUNCH_OWNED) { pthread_mutex_unlock(&process_lock); return error_result(0, 0, "launch ownership not transferred"); }
  if (p->state == DISPOSED) { pthread_mutex_unlock(&process_lock); return error_result(8, 0, "process closed"); }
  int r = close_once(&p->streams[0]), e = errno;
  pthread_mutex_unlock(&process_lock);
  return r ? error_result(6, e, "close stdin") : mdk_ok(1);
}
long long mdk_process_dispose(long long word) {
  MdkProcess *p = (MdkProcess *)word;
  pthread_mutex_lock(&process_lock);
  if (p->launch_step != MDK_LAUNCH_OWNED) { pthread_mutex_unlock(&process_lock); return error_result(0, 0, "launch ownership not transferred"); }
  if (p->state == DISPOSED) { pthread_mutex_unlock(&process_lock); return mdk_ok(1); }
  if (p->state == RUNNING) { pthread_mutex_unlock(&process_lock); return error_result(9, 0, "process still running"); }
  int lost = p->state == LOST, e = 0;
  for (int i = 0; i < 3; ++i) if (close_once(&p->streams[i]) && !e) e = errno;
  close_once(&p->pidfd); p->state = DISPOSED; unroot(p);
  pthread_mutex_unlock(&process_lock);
  if (lost) return error_result(5, ECHILD, "wait ownership lost");
  return e ? error_result(6, e, "close process stream") : mdk_ok(1);
}
