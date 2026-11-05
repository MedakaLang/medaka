#define _GNU_SOURCE
#include "medaka_process.h"
#include "medaka_runtime.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#define GC_THREADS
#define GC_NO_THREAD_REDIRECTS
#include <gc.h>
#include <stdatomic.h>
#include <semaphore.h>
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
typedef enum { SUBMITTED, LAUNCHING, FAILING, ABORTING, RUNNING, REAPED, LOST, DISPOSED } State;
struct MdkProcess {
  struct MdkProcess *next, *previous;
  State state;
  MdkLaunchStep launch_step;
  int pidfd, error_fd, streams[3], signalled;
  int status_kind, status_value, status_core;
  unsigned char record[2 * sizeof(int)];
  size_t record_len;
  MdkProcessError failure;
  unsigned submission_slot;
  uint64_t submission_generation;
  int stop_requested;
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
static int test_read_error, test_write_error;
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
static void root(MdkProcess *p) {
  p->next = process_roots;
  if (process_roots) process_roots->previous = p;
  process_roots = p;
}
static void unroot(MdkProcess *p) {
  if (p->previous) p->previous->next = p->next;
  else if (process_roots == p) process_roots = p->next;
  else return;
  if (p->next) p->next->previous = p->previous;
  p->next = p->previous = NULL;
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
  if (fd[0] < 0) { int e = errno; close_once(&fd[1]); errno = e; return -1; }
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

/* The inactive callback owns native memory only; its result moves after acknowledgement. */
typedef struct {
  MdkSpawnSpec spec;
  _Atomic int *stop;
  int pidfd, error_fd, streams[3], created, cancelled;
  MdkProcessError failure;
#ifdef MDK_PROCESS_TESTING
  pid_t test_pid;
  int child_gate, child_ready;
#endif
} NativeLaunch;
enum { SUBMISSION_FREE, SUBMISSION_QUEUED, SUBMISSION_WORKING, SUBMISSION_DONE };
typedef struct {
  _Atomic int phase, stop;
  uint64_t generation;
  NativeLaunch launch;
  char arena[65536];
  char *argv[258], *env[257];
} Submission;
static Submission submissions[8];
/* Boehm scans static storage; malloc-only sidecars would not retain these graphs. */
static long long submission_inputs[8][4];
static MdkProcess *submission_owners[8];
static sem_t submission_jobs;
static int submission_available, submission_init_error;
#ifdef MDK_PROCESS_TESTING
static _Atomic int test_submit_gate = -1, test_submit_ready = -1, test_submit_stage;
static _Atomic int test_child_gate = -1, test_child_ready = -1;
#endif

static void native_init(NativeLaunch *p) {
  memset(p, 0, sizeof(*p));
  p->pidfd = p->error_fd = -1;
  for (int i = 0; i < 3; ++i) p->streams[i] = -1;
}
#ifdef MDK_PROCESS_TESTING
static void submission_hold(int stage) {
  int gate = atomic_load_explicit(&test_submit_gate, memory_order_acquire);
  if (gate >= 0 && atomic_load_explicit(&test_submit_stage, memory_order_acquire) == stage) {
    char byte = 1;
    int ready = atomic_load_explicit(&test_submit_ready, memory_order_acquire);
    if (write(ready, &byte, 1) != 1 || read(gate, &byte, 1) != 1) abort();
  }
}
#endif
static void *construct_native(void *arg) {
  NativeLaunch *p = arg;
  const MdkSpawnSpec *s = &p->spec;
  MdkProcessError *error = &p->failure;
  if (p->stop && atomic_load_explicit(p->stop, memory_order_acquire)) {
    p->cancelled = 1; return NULL;
  }
#ifdef MDK_PROCESS_TESTING
  if (p->stop) submission_hold(1);
#endif
  struct sigaction action;
  if (sigaction(SIGCHLD, NULL, &action)) {
    *error = (MdkProcessError){7, errno, "SIGCHLD wait ownership unavailable"}; return NULL;
  }
  if (action.sa_handler != SIG_DFL || (action.sa_flags & SA_NOCLDWAIT)) {
    *error = (MdkProcessError){7, 0, "SIGCHLD wait ownership unavailable"}; return NULL;
  }
  if (capability()) { *error = (MdkProcessError){10, errno, "required process facility unavailable"}; return NULL; }
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
  if (p->stop && atomic_load_explicit(p->stop, memory_order_acquire)) {
    p->cancelled = 1; goto cleanup;
  }
  sigset_t blocked, old_mask;
  sigfillset(&blocked);
  int mask_error = pthread_sigmask(SIG_BLOCK, &blocked, &old_mask);
  if (mask_error) { *error = (MdkProcessError){10, mask_error, "signal mask"}; goto cleanup; }
#ifdef MDK_PROCESS_TESTING
  if (p->stop) submission_hold(2);
#endif
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
    if (p->child_gate >= 0) {
      char byte = 1;
      if (write(p->child_ready, &byte, 1) != 1 || read(p->child_gate, &byte, 1) != 1) _exit(126);
    }
#endif
    for (int sig = 1; sig < NSIG; ++sig) {
      if (sig == SIGKILL || sig == SIGSTOP) continue;
      struct sigaction prior;
      if (sigaction(sig, NULL, &prior)) { if (errno == EINVAL) continue; goto child_failure; }
      if (prior.sa_handler != SIG_DFL && (sig == SIGPIPE || prior.sa_handler != SIG_IGN)) {
        struct sigaction reset = {0}; reset.sa_handler = SIG_DFL; sigemptyset(&reset.sa_mask);
        if (sigaction(sig, &reset, NULL)) goto child_failure;
      }
    }
    if (sigprocmask(SIG_SETMASK, &old_mask, NULL)) goto child_failure;
    for (int i = 0; i < 3; ++i) if (dup2(child[i], i) < 0) goto child_failure;
    failure[0] = 10; if (syscall(SYS_close_range, 3U, UINT_MAX, CLOSE_RANGE_CLOEXEC) < 0) goto child_failure;
    failure[0] = 3; if (chdir(s->cwd) < 0) goto child_failure;
    failure[0] = 4; execve(s->program, s->argv, s->env);
  child_failure:
    failure[1] = errno;
    while (write(ep[1], failure, sizeof(failure)) < 0 && errno == EINTR) {}
    _exit(127);
  }
  for (int i = 0; i < 3; ++i) close(child[i]);
  close(ep[1]); p->error_fd = ep[0]; p->created = 1;
#ifdef MDK_PROCESS_TESTING
  p->test_pid = (pid_t)pid;
#endif
  return NULL;
fail:
  *error = (MdkProcessError){1, errno, "pipe or descriptor setup"};
cleanup:
  for (int i = 0; i < 3; ++i) if (child[i] >= 0) close(child[i]);
  if (ep[0] >= 0) close(ep[0]); if (ep[1] >= 0) close(ep[1]);
  for (int i = 0; i < 3; ++i) close_once(&p->streams[i]);
  return NULL;
}

static MdkProcess *new_owner(void) {
  MdkProcess *p = mdk_alloc(sizeof(*p));
  memset(p, 0, sizeof(*p));
  p->pidfd = p->error_fd = -1;
  for (int i = 0; i < 3; ++i) p->streams[i] = -1;
  return p;
}
static void adopt_native(MdkProcess *p, NativeLaunch *n) {
  p->pidfd = n->pidfd; n->pidfd = -1;
  p->error_fd = n->error_fd; n->error_fd = -1;
  for (int i = 0; i < 3; ++i) { p->streams[i] = n->streams[i]; n->streams[i] = -1; }
  p->state = LAUNCHING;
#ifdef MDK_PROCESS_TESTING
  p->test_pid = n->test_pid;
#endif
}
static MdkProcess *process_begin(const MdkSpawnSpec *s, MdkProcessError *error) {
  MdkProcess *p = new_owner();
  NativeLaunch native;
  native_init(&native); native.spec = *s;
#ifdef MDK_PROCESS_TESTING
  native.child_gate = test_gate; native.child_ready = test_ready;
#endif
  GC_do_blocking(construct_native, &native);
  if (!native.created) { *error = native.failure; return NULL; }
  adopt_native(p, &native); root(p); return p;
}
static int bounded_string(long long word, size_t *remaining, int absolute) {
  const long long *cell = (const long long *)word;
  long long length = cell[MDK_STRING_BYTE_LENGTH_SLOT];
  if (length < 0 || (uint64_t)length >= *remaining) return 0;
  const char *bytes = (const char *)cell + MDK_STRING_BYTES_OFFSET;
  if ((absolute && (!length || bytes[0] != '/')) || memchr(bytes, 0, (size_t)length)) return 0;
  *remaining -= (size_t)length + 1; return 1;
}
static int bounded_inputs(long long program, long long argv, long long cwd, long long env,
                           long long in, long long out, long long err) {
  if ((in != 1 && in != 3) || (out != 1 && out != 3) || (err != 1 && err != 3)) return 0;
  size_t remaining = 65536;
  if (!bounded_string(program, &remaining, 1) || !bounded_string(cwd, &remaining, 1)) return 0;
  unsigned count = 0;
  while (!(argv & 1)) {
    if (++count > 256) return 0;
    const long long *cell = (const long long *)argv;
    if (!bounded_string(cell[1], &remaining, 0)) return 0;
    argv = cell[2];
  }
  count = 0;
  while (!(env & 1)) {
    if (++count > 256) return 0;
    const long long *cell = (const long long *)env, *pair = (const long long *)cell[1];
    if (!bounded_string(pair[1], &remaining, 0) || !bounded_string(pair[2], &remaining, 0)) return 0;
    env = cell[2];
  }
  return 1;
}
static char *snapshot_string(char **cursor, long long word) {
  const long long *cell = (const long long *)word;
  size_t length = (size_t)cell[MDK_STRING_BYTE_LENGTH_SLOT];
  char *out = *cursor;
  memcpy(out, (const char *)cell + MDK_STRING_BYTES_OFFSET, length);
  out[length] = 0; *cursor += length + 1; return out;
}
static int snapshot_submission(unsigned i) {
  Submission *q = &submissions[i];
  NativeLaunch *n = &q->launch;
#ifdef MDK_PROCESS_TESTING
  n->child_gate = atomic_load_explicit(&test_child_gate, memory_order_acquire);
  n->child_ready = atomic_load_explicit(&test_child_ready, memory_order_acquire);
#endif
  char *cursor = q->arena;
  n->spec.program = snapshot_string(&cursor, submission_inputs[i][0]);
  n->spec.cwd = snapshot_string(&cursor, submission_inputs[i][2]);
  n->spec.argv = q->argv; n->spec.env = q->env;
  q->argv[0] = n->spec.program;
  long long list = submission_inputs[i][1]; unsigned count = 1;
  while (!(list & 1)) {
    const long long *cell = (const long long *)list;
    q->argv[count++] = snapshot_string(&cursor, cell[1]); list = cell[2];
  }
  q->argv[count] = NULL;
  list = submission_inputs[i][3]; count = 0;
  while (!(list & 1)) {
    const long long *cell = (const long long *)list, *pair = (const long long *)cell[1];
    char *key = snapshot_string(&cursor, pair[1]);
    size_t length = strlen(key);
    if (!length || strchr(key, '=')) return 0;
    for (unsigned j = 0; j < count; ++j)
      if (!strncmp(q->env[j], key, length) && q->env[j][length] == '=') return 0;
    /* Reuse the key terminator for '='; the validated two-string budget is exact. */
    key[length] = '=';
    snapshot_string(&cursor, pair[2]);
    q->env[count++] = key; list = cell[2];
  }
  q->env[count] = NULL; return 1;
}
static void *wait_submission(void *unused) {
  (void)unused;
  while (sem_wait(&submission_jobs) && errno == EINTR) {}
  return NULL;
}
static void *submission_worker(void *unused) {
  (void)unused;
  unsigned next = 0;
  for (;;) {
    GC_do_blocking(wait_submission, NULL);
    for (unsigned offset = 0; offset < 8; ++offset) {
      unsigned i = (next + offset) % 8;
      Submission *q = &submissions[i]; int expected = SUBMISSION_QUEUED;
      if (!atomic_compare_exchange_strong_explicit(&q->phase, &expected, SUBMISSION_WORKING,
                                                    memory_order_acquire, memory_order_relaxed)) continue;
      if (!snapshot_submission(i)) q->launch.failure = (MdkProcessError){0, 0, "invalid spawn options"};
      else GC_do_blocking(construct_native, &q->launch);
      atomic_store_explicit(&q->phase, SUBMISSION_DONE, memory_order_release);
      next = (i + 1) % 8;
      break;
    }
  }
  return NULL;
}
static void release_submission(MdkProcess *p) {
  if (!p->submission_slot) return;
  unsigned i = p->submission_slot - 1; Submission *q = &submissions[i];
  if (q->generation != p->submission_generation || submission_owners[i] != p ||
      atomic_load_explicit(&q->phase, memory_order_acquire) != SUBMISSION_DONE) abort();
  submission_owners[i] = NULL;
  memset(submission_inputs[i], 0, sizeof(submission_inputs[i]));
  p->submission_slot = 0;
  atomic_store_explicit(&q->phase, SUBMISSION_FREE, memory_order_release);
}
static int adopt_submission(MdkProcess *p) {
  if (p->state != SUBMITTED) return 1;
  unsigned i = p->submission_slot - 1; Submission *q = &submissions[i];
  if (q->generation != p->submission_generation || submission_owners[i] != p) abort();
  if (atomic_load_explicit(&q->phase, memory_order_acquire) != SUBMISSION_DONE) return 0;
  NativeLaunch *n = &q->launch;
  if (!n->created) {
    p->failure = n->cancelled ? (MdkProcessError){12, 0, "launch cancelled"} : n->failure;
    p->launch_step = n->cancelled ? MDK_LAUNCH_ABORTED : MDK_LAUNCH_FAILED;
    p->state = REAPED;
    release_submission(p); unroot(p); return 1;
  }
  adopt_native(p, n);
  if (p->stop_requested) { p->state = ABORTING; close_once(&p->error_fd); close_streams(p); }
  return 1;
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
  if (!adopt_submission(p)) return MDK_LAUNCH_PENDING;
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
      p->failure = (MdkProcessError){pair[0] == 1 || pair[0] == 3 || pair[0] == 4 || pair[0] == 10 ? pair[0] : 11, pair[1], "child setup"};
      close_once(&p->error_fd); close_streams(p); p->state = FAILING;
    } else if (!n) {
      close_once(&p->error_fd);
      if (!p->record_len) { p->state = RUNNING; p->launch_step = MDK_LAUNCH_OWNED; release_submission(p); return MDK_LAUNCH_OWNED; }
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
    close_once(&p->error_fd); close_streams(p); release_submission(p); unroot(p);
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
  if (p->state == SUBMITTED) {
    p->stop_requested = 1;
    atomic_store_explicit(&submissions[p->submission_slot - 1].stop, 1, memory_order_release);
    if (!adopt_submission(p)) return MDK_LAUNCH_PENDING;
  }
  if (p->launch_step == MDK_LAUNCH_OWNED) { *error = (MdkProcessError){0, 0, "launch ownership already transferred"}; return MDK_LAUNCH_ERROR; }
  if (p->state == LAUNCHING || p->state == FAILING) { p->state = ABORTING; close_once(&p->error_fd); close_streams(p); }
  return process_check_start(p, error);
}
static MdkLaunchStep drive_start(MdkProcess *p, MdkProcessError *error) {
  MdkLaunchStep step;
  while ((step = process_check_start(p, error)) == MDK_LAUNCH_PENDING) {
    if (p->state == SUBMITTED) {
      pthread_mutex_unlock(&process_lock);
      struct timespec pause = {0, 1000000}; nanosleep(&pause, NULL);
      pthread_mutex_lock(&process_lock); continue;
    }
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

void mdk_process_submission_init(void) {
#ifdef __linux__
#ifdef MDK_PROCESS_TESTING
  if (getenv("MEDAKA_TEST_SUBMISSION_INIT_FAIL")) { submission_init_error = EAGAIN; return; }
#endif
  pthread_attr_t attr;
  if (sem_init(&submission_jobs, 0, 0)) { submission_init_error = errno; return; }
  int error = pthread_attr_init(&attr);
  if (error) { submission_init_error = error; sem_destroy(&submission_jobs); return; }
  error = pthread_attr_setstacksize(&attr, 512 * 1024);
  if (!error) error = pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
  pthread_t worker;
  if (!error) error = GC_pthread_create(&worker, &attr, submission_worker, NULL);
  pthread_attr_destroy(&attr);
  if (error) { submission_init_error = error; sem_destroy(&submission_jobs); return; }
  submission_available = 1;
#endif
}
long long mdk_process_submit(long long program, long long argv, long long cwd, long long env,
                            long long in, long long out, long long err) {
#ifndef __linux__
  (void)program; (void)argv; (void)cwd; (void)env; (void)in; (void)out; (void)err;
  return error_result(10, 0, "native process submission unsupported");
#else
  if (!submission_available) return error_result(10, submission_init_error, "native process submission unavailable");
  if (!bounded_inputs(program, argv, cwd, env, in, out, err))
    return error_result(0, 0, "invalid or oversized spawn options");
  MdkProcess *p = new_owner();
  if (pthread_mutex_trylock(&process_lock)) return error_result(MDK_PROCESS_BUSY, 0, "process busy");
  unsigned i;
  for (i = 0; i < 8; ++i)
    if (atomic_load_explicit(&submissions[i].phase, memory_order_acquire) == SUBMISSION_FREE &&
        submissions[i].generation != UINT64_MAX) break;
  if (i == 8) { pthread_mutex_unlock(&process_lock); return error_result(MDK_PROCESS_QUEUE_FULL, 0, "submission queue full"); }
  Submission *q = &submissions[i];
  ++q->generation; native_init(&q->launch);
  atomic_store_explicit(&q->stop, 0, memory_order_relaxed);
  q->launch.stop = &q->stop;
  q->launch.spec.mode[0] = (int)(in >> 1);
  q->launch.spec.mode[1] = (int)(out >> 1);
  q->launch.spec.mode[2] = (int)(err >> 1);
  submission_inputs[i][0] = program; submission_inputs[i][1] = argv;
  submission_inputs[i][2] = cwd; submission_inputs[i][3] = env;
  submission_owners[i] = p;
  p->state = SUBMITTED; p->submission_slot = i + 1; p->submission_generation = q->generation;
  root(p);
  atomic_store_explicit(&q->phase, SUBMISSION_QUEUED, memory_order_release);
  pthread_mutex_unlock(&process_lock);
  sem_post(&submission_jobs);
  return mdk_ok((long long)p);
#endif
}

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
  if (pthread_mutex_trylock(&process_lock)) return error_result(MDK_PROCESS_BUSY, 0, "process busy");
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
  if (pthread_mutex_trylock(&process_lock)) return error_result(MDK_PROCESS_BUSY, 0, "process busy");
  MdkLaunchStep step = process_abort_start(p, &error);
  pthread_mutex_unlock(&process_lock);
  return launch_result(step, p, error);
#endif
}
long long mdk_process_poll_exit(long long word) {
  MdkProcess *p = (MdkProcess *)word;
  if (pthread_mutex_trylock(&process_lock)) return error_result(MDK_PROCESS_BUSY, 0, "process busy");
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
#ifndef __linux__
  (void)word;
  return error_result(10, 0, "native process unsupported");
#else
  MdkProcess *p = (MdkProcess *)word;
  if (pthread_mutex_trylock(&process_lock)) return error_result(MDK_PROCESS_BUSY, 0, "process busy");
  if (p->launch_step != MDK_LAUNCH_OWNED) { pthread_mutex_unlock(&process_lock); return error_result(0, 0, "launch ownership not transferred"); }
  if (p->state == DISPOSED) { pthread_mutex_unlock(&process_lock); return error_result(8, 0, "process closed"); }
  int r = close_once(&p->streams[0]), e = errno;
  pthread_mutex_unlock(&process_lock);
  return r ? error_result(6, e, "close stdin") : mdk_ok(1);
#endif
}
long long mdk_process_dispose(long long word) {
  MdkProcess *p = (MdkProcess *)word;
  if (pthread_mutex_trylock(&process_lock)) return error_result(MDK_PROCESS_BUSY, 0, "process busy");
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

static int stream_owner(MdkProcess *p, int stream) {
  return p->launch_step == MDK_LAUNCH_OWNED && p->state != DISPOSED && p->streams[stream] >= 0;
}
static long long stream_busy(void) { return error_result(MDK_PROCESS_BUSY, 0, "process busy"); }
static long long stream_closed(void) { return error_result(8, 0, "process stream closed"); }
long long mdk_process_stream_fd(long long word, long long stream_word) {
#ifndef __linux__
  (void)word; (void)stream_word;
  return error_result(10, 0, "native process unsupported");
#else
  long long stream = stream_word >> 1;
  if (stream < 0 || stream > 2) return error_result(MDK_PROCESS_INVALID_IO, 0, "invalid stream");
  if (pthread_mutex_trylock(&process_lock)) return stream_busy();
  MdkProcess *p = (MdkProcess *)word;
  if (!stream_owner(p, (int)stream)) { pthread_mutex_unlock(&process_lock); return stream_closed(); }
  int fd = p->streams[stream];
  pthread_mutex_unlock(&process_lock);
  return mdk_ok(box_int(fd));
#endif
}
long long mdk_process_try_read(long long word, long long stream_word, long long limit_word) {
#ifndef __linux__
  (void)word; (void)stream_word; (void)limit_word;
  return error_result(10, 0, "native process unsupported");
#else
  long long stream = stream_word >> 1, limit = limit_word >> 1;
  if ((stream != 1 && stream != 2) || limit < 1 || limit > 65536)
    return error_result(MDK_PROCESS_INVALID_IO, 0, "invalid read stream or limit");
  unsigned char buf[65536];
  if (pthread_mutex_trylock(&process_lock)) return stream_busy();
  MdkProcess *p = (MdkProcess *)word;
  if (!stream_owner(p, (int)stream)) { pthread_mutex_unlock(&process_lock); return stream_closed(); }
  ssize_t n;
#ifdef MDK_PROCESS_TESTING
  if (test_read_error) { errno = test_read_error; test_read_error = 0; n = -1; }
  else
#endif
  n = read(p->streams[stream], buf, (size_t)limit);
  int e = errno;
  pthread_mutex_unlock(&process_lock);
  if (n < 0 && (e == EAGAIN || e == EWOULDBLOCK || e == EINTR)) return mdk_ok(mdk_none());
  if (n < 0) return error_result(MDK_PROCESS_READ_FAILED, e, "read process stream");
  size_t size = 16 + ((size_t)n + 7) / 8 * 8;
  long long *block = mdk_alloc(size);
  memset(block, 0, size); block[0] = MDK_BYTEBLOCK_TAG; block[1] = n;
  memcpy((char *)block + 16, buf, (size_t)n);
  return mdk_ok(mdk_some((long long)block));
#endif
}
long long mdk_process_try_write(long long word, long long block_word, long long offset_word, long long count_word) {
#ifndef __linux__
  (void)word; (void)block_word; (void)offset_word; (void)count_word;
  return error_result(10, 0, "native process unsupported");
#else
  long long offset = offset_word >> 1, count = count_word >> 1;
  long long *block = (long long *)block_word;
  long long length = block[1];
  if (offset < 0 || count < 0 || offset > length || count > length - offset)
    return error_result(MDK_PROCESS_INVALID_IO, 0, "invalid write window");
  if (count > 65536) count = 65536;
  if (pthread_mutex_trylock(&process_lock)) return stream_busy();
  MdkProcess *p = (MdkProcess *)word;
  if (!stream_owner(p, 0)) { pthread_mutex_unlock(&process_lock); return stream_closed(); }
  if (!count) { pthread_mutex_unlock(&process_lock); return mdk_ok(mdk_some(box_int(0))); }
  sigset_t set, prior, pending;
  sigemptyset(&set); sigaddset(&set, SIGPIPE);
  int mask_error = pthread_sigmask(SIG_BLOCK, &set, &prior);
  if (mask_error) { pthread_mutex_unlock(&process_lock); return error_result(MDK_PROCESS_WRITE_FAILED, mask_error, "block SIGPIPE"); }
  int pending_error = sigpending(&pending);
  int pending_errno = errno;
  if (pending_error) {
    pthread_sigmask(SIG_SETMASK, &prior, NULL); pthread_mutex_unlock(&process_lock);
    return error_result(MDK_PROCESS_WRITE_FAILED, pending_errno, "query SIGPIPE");
  }
  int was_pending = sigismember(&pending, SIGPIPE);
  ssize_t n;
#ifdef MDK_PROCESS_TESTING
  if (test_write_error) { errno = test_write_error; test_write_error = 0; n = -1; }
  else
#endif
  n = write(p->streams[0], (char *)block + 16 + offset, (size_t)count);
  int e = errno;
  if (n < 0 && e == EPIPE && !was_pending) {
    struct timespec zero = {0, 0};
    while (sigtimedwait(&set, NULL, &zero) < 0 && errno == EINTR) {}
  }
  int restore_error = pthread_sigmask(SIG_SETMASK, &prior, NULL);
  pthread_mutex_unlock(&process_lock);
  if (restore_error) return error_result(MDK_PROCESS_WRITE_FAILED, restore_error, "restore SIGPIPE mask");
  if (n < 0 && (e == EAGAIN || e == EWOULDBLOCK || e == EINTR)) return mdk_ok(mdk_none());
  if (n < 0 || !n) return error_result(MDK_PROCESS_WRITE_FAILED, n < 0 ? e : EIO, "write process stream");
  return mdk_ok(mdk_some(box_int((int)n)));
#endif
}

#ifdef MDK_PROCESS_TESTING
void mdk_process_test_io_faults(int read_error, int write_error) {
  test_read_error = read_error; test_write_error = write_error;
}
#endif

#ifdef MDK_PROCESS_TESTING
int mdk_process_test_pipe(int fd[2]) {
#ifdef __linux__
  return make_pipe(fd);
#else
  (void)fd; return -1;
#endif
}
int mdk_process_test_workers(void) {
#ifdef __linux__
  return submission_available;
#else
  return 0;
#endif
}
void mdk_process_test_submit_hold(int stage, int gate, int ready) {
#ifdef __linux__
  atomic_store_explicit(&test_submit_ready, ready, memory_order_release);
  atomic_store_explicit(&test_submit_stage, stage, memory_order_release);
  atomic_store_explicit(&test_submit_gate, gate, memory_order_release);
#endif
}
void mdk_process_test_child_hold(int gate, int ready) {
#ifdef __linux__
  atomic_store_explicit(&test_child_ready, ready, memory_order_release);
  atomic_store_explicit(&test_child_gate, gate, memory_order_release);
#endif
}
int mdk_process_test_permits(void) {
  int count = 0;
#ifdef __linux__
  pthread_mutex_lock(&process_lock);
  for (unsigned i = 0; i < 8; ++i)
    count += atomic_load_explicit(&submissions[i].phase, memory_order_acquire) != SUBMISSION_FREE;
  pthread_mutex_unlock(&process_lock);
#endif
  return count;
}
void mdk_process_test_lock(int lock) {
  if (lock) pthread_mutex_lock(&process_lock); else pthread_mutex_unlock(&process_lock);
}
#endif
