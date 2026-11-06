#define _GNU_SOURCE
#include "medaka_process.h"
#include "medaka_runtime.h"
#include <errno.h>
#include <fcntl.h>
#define GC_THREADS
#include <gc.h>
#include <limits.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <pthread.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern int mdk_process_test_roots(void);
extern int mdk_process_test_pidfd(long long);
extern int mdk_process_test_pid(long long);
extern long long mdk_process_test_begin(int, int);
extern void mdk_process_test_faults(int, int, int);
extern int mdk_process_test_calls(int);
static int checks, fast_failure;
#define CHECK(x) do { __atomic_add_fetch(&checks,1,__ATOMIC_RELAXED); if (!(x)) { dprintf(2,"FAIL line %d: %s\n",__LINE__,#x); _exit(1); } } while (0)
static long long field(long long v, int i) { return ((long long *)v)[i]; }
static long long none(void) { return (MDK_TAG_NONE<<1)|1; }
static int fd_count(void) { int n=0; for (int i=0;i<256;++i) if (fcntl(i,F_GETFD)>=0) ++n; return n; }
static int error_code(long long r) { CHECK(field(r,0)==MDK_TAG_ERR); return (int)(field(field(r,1),1)>>1); }
static void error_is(long long r, int op, int number) {
  CHECK(error_code(r)==op); CHECK((field(field(r,1),2)>>1)==number);
}
static long long ticket_in(long long r) {
  long long option=field(field(r,1),4);
  CHECK(!(option&1) && field(option,0)==MDK_TAG_SOME); return field(option,1);
}
static void rejected(long long r, int op, int number) {
  error_is(r,op,number); CHECK(field(field(r,1),4)==none());
}
static long long start(const char *path) {
  long long nil=(MDK_TAG_NIL<<1)|1;
  return mdk_process_start(mdk_runtime_string(path),nil,mdk_runtime_string("/tmp"),nil,1,1,1);
}
static long long progress(long long r) {
  CHECK(field(r,0)==MDK_TAG_OK);
  long long t=field(r,1); CHECK(field(t,0)==MDK_TUPLE_TAG);
  int kind=(int)(field(t,1)>>1); CHECK(kind>=0 && kind<=3);
  long long process=field(t,2), error=field(t,3);
  if (kind==1) { CHECK(!(process&1) && field(process,0)==MDK_TAG_SOME); CHECK(error==none()); }
  else if (kind==2) { CHECK(process==none()); CHECK(!(error&1) && field(error,0)==MDK_TAG_SOME); }
  else CHECK(process==none() && error==none());
  return t;
}
static int kind(long long r) { return (int)(field(progress(r),1)>>1); }
static void failed(long long r, int op, int number) {
  long long t=progress(r); CHECK((field(t,1)>>1)==2);
  long long error=field(field(t,3),1);
  CHECK((field(error,1)>>1)==op && (field(error,2)>>1)==number);
}
static long long finish(long long ticket, int aborting) {
  for (int i=0;i<10000;++i) {
    long long r=aborting ? mdk_process_abort_start(ticket) : mdk_process_check_start(ticket);
    if (kind(r)!=0) return r;
    usleep(1000);
  }
  CHECK(0); return 0;
}
static void finish_process(long long p) {
  for (int i=0;i<10000;++i) {
    long long r=mdk_process_poll_exit(p); CHECK(field(r,0)==MDK_TAG_OK);
    long long option=field(r,1);
    if (!(option&1)) {
      long long t=field(option,1); CHECK(field(t,1)==1 && field(t,2)==1);
      CHECK(field(mdk_process_dispose(p),0)==MDK_TAG_OK); return;
    }
    usleep(1000);
  }
  CHECK(0);
}
typedef struct { int gate[2], ready[2]; } Gate;
static void gate_open(Gate *g) { CHECK(pipe2(g->gate,O_CLOEXEC)==0); CHECK(pipe2(g->ready,O_CLOEXEC)==0); }
static void gate_close(Gate *g) { close(g->gate[0]); close(g->gate[1]); close(g->ready[0]); close(g->ready[1]); }
static long long stalled(Gate *g) {
  long long p=mdk_process_test_begin(g->gate[0],g->ready[1]); CHECK(p!=0);
  char byte; CHECK(read(g->ready[0],&byte,1)==1); return p;
}
static void release(Gate *g) { CHECK(write(g->gate[1],"x",1)==1); }
static int reuse(int oldfd) {
  int fd=open("/dev/null",O_RDONLY); CHECK(fd>=0);
  if (fd!=oldfd) { CHECK(dup2(fd,oldfd)==oldfd); close(fd); }
  return oldfd;
}
static void cached_failure(long long ticket, int op, int number) {
  int signals=mdk_process_test_calls(0), waits=mdk_process_test_calls(1);
  failed(mdk_process_check_start(ticket),op,number);
  failed(mdk_process_abort_start(ticket),op,number);
  rejected(mdk_process_retry_start(ticket),op,number);
  CHECK(mdk_process_test_calls(0)==signals && mdk_process_test_calls(1)==waits);
}
static void wait_denial(void) {
  int baseline=fd_count(), waits=mdk_process_test_calls(1);
  mdk_process_test_faults(EPERM,EIO,0);
  long long r=start("/not-a-medaka-program"); error_is(r,5,EIO);
  CHECK(mdk_process_test_calls(1)==waits+1);
  long long ticket=ticket_in(r), alias=ticket;
  int oldfd=mdk_process_test_pidfd(ticket), pid=mdk_process_test_pid(ticket);
  CHECK(mdk_process_test_roots()==1 && fd_count()==baseline+1);
  GC_gcollect(); CHECK(mdk_process_test_roots()==1);
  for (int i=0;i<32;++i) {
    waits=mdk_process_test_calls(1);
    error_is(mdk_process_check_start(alias),5,EIO);
    CHECK(mdk_process_test_calls(1)==waits+1 && mdk_process_test_roots()==1);
  }
  r=mdk_process_retry_start(alias); error_is(r,5,EIO); CHECK(ticket_in(r)==ticket);
  siginfo_t info={0}; CHECK(waitid(P_PID,pid,&info,WEXITED|WNOWAIT)==0 && info.si_pid==pid);
  mdk_process_test_faults(EPERM,0,0);
  failed(mdk_process_check_start(ticket),4,ENOENT);
  CHECK(mdk_process_test_roots()==0 && fd_count()==baseline);
  int fd=reuse(oldfd); cached_failure(alias,4,ENOENT); CHECK(fcntl(fd,F_GETFD)>=0); close(fd);
  mdk_process_test_faults(0,0,0);
}
static void abort_denial(void) {
  int baseline=fd_count(); Gate g; gate_open(&g);
  long long ticket=stalled(&g); CHECK(kind(mdk_process_check_start(ticket))==0);
  int oldfd=mdk_process_test_pidfd(ticket);
  error_is(mdk_process_poll_exit(ticket),0,0);
  error_is(mdk_process_close_stdin(ticket),0,0);
  error_is(mdk_process_dispose(ticket),0,0);
  mdk_process_test_faults(EPERM,EIO,0);
  error_is(mdk_process_abort_start(ticket),5,EIO);
  mdk_process_test_faults(EPERM,0,0);
  int signals=mdk_process_test_calls(0), waits=mdk_process_test_calls(1);
  error_is(mdk_process_abort_start(ticket),5,EPERM);
  CHECK(mdk_process_test_calls(0)==signals+1 && mdk_process_test_calls(1)==waits+1);
  long long r=mdk_process_retry_start(ticket); error_is(r,5,EPERM); CHECK(ticket_in(r)==ticket);
  CHECK(mdk_process_test_roots()==1 && mdk_process_test_pidfd(ticket)==oldfd);
  GC_gcollect(); mdk_process_test_faults(0,0,0);
  CHECK(kind(finish(ticket,1))==3);
  CHECK(mdk_process_test_roots()==0 && fd_count()==baseline+4);
  int fd=reuse(oldfd); signals=mdk_process_test_calls(0); waits=mdk_process_test_calls(1);
  CHECK(kind(mdk_process_abort_start(ticket))==3 && kind(mdk_process_check_start(ticket))==3);
  rejected(mdk_process_retry_start(ticket),12,0);
  CHECK(mdk_process_test_calls(0)==signals && mdk_process_test_calls(1)==waits);
  CHECK(fcntl(fd,F_GETFD)>=0); close(fd); gate_close(&g); CHECK(fd_count()==baseline);
}
static void lost_wait(void) {
  int baseline=fd_count(); Gate g; gate_open(&g); long long ticket=stalled(&g);
  int pid=mdk_process_test_pid(ticket), oldfd=mdk_process_test_pidfd(ticket);
  mdk_process_test_faults(EPERM,0,0); error_is(mdk_process_abort_start(ticket),5,EPERM);
  release(&g); int status; CHECK(waitpid(pid,&status,0)==pid && WIFEXITED(status) && WEXITSTATUS(status)==0);
  failed(mdk_process_check_start(ticket),5,ECHILD);
  CHECK(mdk_process_test_roots()==0 && fd_count()==baseline+4);
  int fd=reuse(oldfd); cached_failure(ticket,5,ECHILD); CHECK(fcntl(fd,F_GETFD)>=0); close(fd);
  gate_close(&g); mdk_process_test_faults(0,0,0); CHECK(fd_count()==baseline);
}
static void transferred(long long ticket) {
  long long r=mdk_process_retry_start(ticket); CHECK(field(r,0)==MDK_TAG_OK && field(r,1)==ticket);
  long long t=progress(mdk_process_check_start(ticket)); CHECK(field(t,1)==3 && field(field(t,2),1)==ticket);
  error_is(mdk_process_abort_start(ticket),0,0);
  finish_process(ticket);
  error_is(mdk_process_check_start(ticket),8,0);
  rejected(mdk_process_retry_start(ticket),8,0);
  error_is(mdk_process_abort_start(ticket),0,0);
}
static void readiness_failure(void) {
  int baseline=fd_count(); Gate g; gate_open(&g); long long ticket=stalled(&g);
  mdk_process_test_faults(0,0,EIO);
  long long r=mdk_process_retry_start(ticket); error_is(r,11,EIO); CHECK(ticket_in(r)==ticket);
  CHECK(mdk_process_test_roots()==1 && fd_count()==baseline+6);
  CHECK(kind(mdk_process_check_start(ticket))==0);
  mdk_process_test_faults(0,0,0); release(&g); transferred(ticket);
  gate_close(&g); CHECK(mdk_process_test_roots()==0 && fd_count()==baseline);
}
typedef struct { long long ticket, result; } Retry;
static void *retry_thread(void *arg) { Retry *r=arg; r->result=mdk_process_retry_start(r->ticket); return NULL; }
static void blocking_wait(void) {
  int baseline=fd_count(); Gate g; gate_open(&g); Retry retry={stalled(&g),0};
  int polls=mdk_process_test_calls(2); pthread_t thread;
  CHECK(GC_pthread_create(&thread,NULL,retry_thread,&retry)==0);
  for (int i=0;i<10000 && mdk_process_test_calls(2)==polls;++i) usleep(1000);
  CHECK(mdk_process_test_calls(2)==polls+1);
  usleep(20000); CHECK(mdk_process_test_calls(2)==polls+1);
  long long other=start("/bin/true"); CHECK(field(other,0)==MDK_TAG_OK); finish_process(field(other,1));
  CHECK(mdk_process_test_roots()==1);
  release(&g); CHECK(GC_pthread_join(thread,NULL)==0);
  CHECK(field(retry.result,0)==MDK_TAG_OK && field(retry.result,1)==retry.ticket);
  transferred(retry.ticket); gate_close(&g); CHECK(fd_count()==baseline && mdk_process_test_roots()==0);
}
static void deny_actual(int signal) {
  unsigned call=signal ? SYS_pidfd_send_signal : SYS_waitid;
  unsigned slot=signal ? offsetof(struct seccomp_data,args[0]) : offsetof(struct seccomp_data,args[1]);
  unsigned probe=signal ? UINT_MAX : INT_MAX;
  struct sock_filter insns[]={
    BPF_STMT(BPF_LD|BPF_W|BPF_ABS,offsetof(struct seccomp_data,nr)),
    BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,call,0,3),
    BPF_STMT(BPF_LD|BPF_W|BPF_ABS,slot),
    BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,probe,1,0),
    BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ERRNO|EPERM),
    BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ALLOW)
  };
  struct sock_fprog filter={sizeof(insns)/sizeof(insns[0]),insns};
  CHECK(prctl(PR_SET_NO_NEW_PRIVS,1,0,0,0)==0);
  CHECK(prctl(PR_SET_SECCOMP,SECCOMP_MODE_FILTER,&filter)==0);
}
typedef struct { int signal, stalled; Gate gate; long long ticket; } Denial;
static void *denial_thread(void *arg) {
  Denial *d=arg; struct timespec before,after; clock_gettime(CLOCK_THREAD_CPUTIME_ID,&before);
  deny_actual(d->signal);
  if (d->stalled) {
    d->ticket=stalled(&d->gate); error_is(mdk_process_abort_start(d->ticket),5,EPERM);
    long long r=mdk_process_retry_start(d->ticket); error_is(r,5,EPERM); CHECK(ticket_in(r)==d->ticket);
    for (int i=0;i<16;++i) error_is(mdk_process_check_start(d->ticket),5,EPERM);
    CHECK(mdk_process_test_roots()==1);
  } else {
    long long r=start("/not-a-medaka-program"); CHECK(field(r,0)==MDK_TAG_ERR);
    if (field(field(r,1),4)==none()) { fast_failure=1; CHECK(d->signal); rejected(r,4,ENOENT); }
    else {
      error_is(r,5,EPERM); d->ticket=ticket_in(r); CHECK(mdk_process_test_roots()==1);
      for (int i=0;i<16;++i) {
        r=mdk_process_check_start(d->ticket);
        if (field(r,0)==MDK_TAG_ERR) error_is(r,5,EPERM);
        else { CHECK(d->signal); failed(r,4,ENOENT); }
      }
    }
  }
  clock_gettime(CLOCK_THREAD_CPUTIME_ID,&after);
  double cpu=after.tv_sec-before.tv_sec+(after.tv_nsec-before.tv_nsec)/1e9;
  CHECK(cpu<0.25); printf("selective %s%s denial CPU=%.6fs\n",d->signal ? "signal" : "wait",d->stalled ? " stalled" : "",cpu);
  return NULL;
}
static void persistent_denial(const char *mode) {
  int baseline=fd_count(); Denial d={.signal=strstr(mode,"signal")!=NULL,.stalled=strstr(mode,"stalled")!=NULL};
  if (d.stalled) gate_open(&d.gate);
  pid_t other=fork(); CHECK(other>=0); if (!other) _exit(23);
  pthread_t thread; CHECK(GC_pthread_create(&thread,NULL,denial_thread,&d)==0);
  CHECK(GC_pthread_join(thread,NULL)==0);
  if (d.ticket) {
    if (d.stalled) CHECK(kind(finish(d.ticket,1))==3);
    else failed(finish(d.ticket,0),4,ENOENT);
  }
  if (d.stalled) gate_close(&d.gate);
  int status; CHECK(waitpid(other,&status,0)==other && WIFEXITED(status) && WEXITSTATUS(status)==23);
  CHECK(mdk_process_test_roots()==0 && fd_count()==baseline);
  CHECK(waitpid(-1,&status,WNOHANG)==-1 && errno==ECHILD);
}
int mdk_program_main(int argc, char **argv) {
  alarm(30);
  if (argc>1) persistent_denial(argv[1]);
  else { wait_denial(); abort_denial(); lost_wait(); readiness_failure(); blocking_wait(); }
  CHECK(checks >= (fast_failure ? 13 : 21)); printf("launch ticket checks: %d passed (%s)\n",checks,fast_failure ? "fast" : "retained"); return 0;
}
