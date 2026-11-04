#define _POSIX_C_SOURCE 200809L
#ifdef NDEBUG
#error "SIGPIPE reference controls require assertions enabled"
#endif
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

static volatile sig_atomic_t handled;
static void handler(int sig) { (void)sig; handled++; }

static ssize_t pipe_write(int fd) {
  sigset_t blocked, old, pending;
  sigemptyset(&blocked); sigaddset(&blocked, SIGPIPE);
  assert(pthread_sigmask(SIG_BLOCK, &blocked, &old) == 0);
  assert(sigpending(&pending) == 0);
  int existed = sigismember(&pending, SIGPIPE);
  ssize_t n = write(fd, "x", 1);
  int saved = errno;
  if (n < 0 && saved == EPIPE && !existed) {
    struct timespec zero = {0, 0};
    int got;
    do { got = sigtimedwait(&blocked, NULL, &zero); } while (got < 0 && errno == EINTR);
    assert(got == SIGPIPE);
  }
  assert(pthread_sigmask(SIG_SETMASK, &old, NULL) == 0);
  errno = saved;
  return n;
}

int main(void) {
  struct sigaction action = {0}, observed;
  action.sa_handler = handler; sigemptyset(&action.sa_mask);
  assert(sigaction(SIGPIPE, &action, NULL) == 0);
  int ends[2]; assert(pipe(ends) == 0); close(ends[0]);
  assert(pipe_write(ends[1]) == -1 && errno == EPIPE && handled == 0);
  assert(sigaction(SIGPIPE, NULL, &observed) == 0 && observed.sa_handler == handler);
  puts("EPIPE returned; original handler preserved; generated signal consumed");
  sigset_t one, old, pending;
  sigemptyset(&one); sigaddset(&one, SIGPIPE);
  assert(pthread_sigmask(SIG_BLOCK, &one, &old) == 0);
  assert(raise(SIGPIPE) == 0);
  assert(pipe_write(ends[1]) == -1 && errno == EPIPE);
  assert(sigpending(&pending) == 0 && sigismember(&pending, SIGPIPE));
  puts("preexisting pending SIGPIPE preserved");
  struct timespec zero = {0, 0}; assert(sigtimedwait(&one, NULL, &zero) == SIGPIPE);
  assert(pthread_sigmask(SIG_SETMASK, &old, NULL) == 0);
  assert(handled == 0); close(ends[1]);
  puts("mask restored; no process-wide disposition change");
}
