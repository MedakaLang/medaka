#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern void mdk_process_test_lock(int);
extern int mdk_process_test_roots(void);
extern int mdk_process_test_permits(void);
static pthread_t holder;
static pthread_mutex_t ready_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ready_cond = PTHREAD_COND_INITIALIZER;
static int ready;
static void *hold(void *unused) {
  (void)unused;
  mdk_process_test_lock(1);
  pthread_mutex_lock(&ready_lock);
  ready = 1;
  pthread_cond_signal(&ready_cond);
  pthread_mutex_unlock(&ready_lock);
  const char *mode = getenv("CONTENTION_MODE");
  struct timespec delay = {0, mode && !strcmp(mode, "eventual") ? 150000000 : 500000000};
  nanosleep(&delay, NULL);
  mdk_process_test_lock(0);
  return NULL;
}
__attribute__((constructor)) static void start_hold(void) {
  if (pthread_create(&holder, NULL, hold, NULL)) _exit(2);
  pthread_mutex_lock(&ready_lock);
  while (!ready) pthread_cond_wait(&ready_cond, &ready_lock);
  pthread_mutex_unlock(&ready_lock);
}
__attribute__((destructor)) static void verify_empty(void) {
  pthread_join(holder, NULL);
  int status;
  if (mdk_process_test_roots() || mdk_process_test_permits() ||
      waitpid(-1, &status, WNOHANG) != -1 || errno != ECHILD) {
    dprintf(2, "contention leaked child or ticket\n"); _exit(3);
  }
  dprintf(2, "contention roots=0 permits=0 children=0\n");
}
