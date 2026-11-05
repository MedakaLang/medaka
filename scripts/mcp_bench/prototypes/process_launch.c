#define _GNU_SOURCE
#ifdef NDEBUG
#error "launch controls require assertions enabled"
#endif
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __linux__
#include <linux/close_range.h>
#include <linux/sched.h>
#endif

/* Independent Linux mechanism probe; no Medaka runtime implementation. */
#ifndef __linux__
int main(void) { puts("BLOCKED: Linux pipe2/close_range receipts unavailable"); return 77; }
#else
enum { LAUNCHING, RUNNING, FAILING, ABORTING, REAPED, LOST };
typedef struct { int stage, error; } Failure;
typedef struct { pid_t pid; int pidfd, error_fd, state, status; Failure failure; } Ticket;

static void pipe_ce(int fd[2]) { assert(pipe2(fd, O_CLOEXEC)==0); }
static int above_stdio(int fd) {
  if (fd>2) return fd;
  int moved=fcntl(fd,F_DUPFD_CLOEXEC,3); assert(moved>=3);
  assert(close(fd)==0); return moved;
}
static void normalized_pipe(int fd[2]) {
  pipe_ce(fd); fd[0]=above_stdio(fd[0]); fd[1]=above_stdio(fd[1]);
}
static int wait_owned(pid_t pid, int *status, int flags) {
  int r; do r=waitpid(pid,status,flags); while(r<0 && errno==EINTR); return r;
}
static pid_t clone_identity(int *pidfd) {
  struct clone_args args={.flags=CLONE_PIDFD,.pidfd=(unsigned long)pidfd,.exit_signal=SIGCHLD};
  pid_t pid=syscall(SYS_clone3,&args,sizeof args);
  if(pid<0) { fprintf(stderr,"BLOCKED: clone3(CLONE_PIDFD) errno=%d\n",errno); exit(77); }
  return pid;
}
static int identity_wait(Ticket *t, int flags) {
  siginfo_t info={0}; int r;
  do r=waitid(P_PIDFD,t->pidfd,&info,WEXITED|flags); while(r<0 && errno==EINTR);
  if(r<0) return -1;
  if(!info.si_pid) return 0;
  assert(info.si_pid==t->pid);
  if(info.si_code==CLD_EXITED) t->status=info.si_status<<8;
  else { assert(info.si_code==CLD_KILLED || info.si_code==CLD_DUMPED); t->status=info.si_status|(info.si_code==CLD_DUMPED ? 128 : 0); }
  return t->pid;
}
static void close_identity(Ticket *t) {
  if(t->pidfd>=0) { int fd=t->pidfd; t->pidfd=-1; assert(close(fd)==0); }
}
static void close_error(Ticket *t) {
  if(t->error_fd>=0) { int fd=t->error_fd; t->error_fd=-1; assert(close(fd)==0); }
}
static void observe(Ticket *t) {
  if(t->pid<=0) return;
  int r=identity_wait(t,WNOHANG);
  assert(r==0 || r==t->pid || (r==-1 && errno==ECHILD));
  if(r) { t->state=r<0 ? LOST : REAPED; t->pid=-1; close_error(t); close_identity(t); }
}
static void check_launch(Ticket *t) {
  if(t->state!=LAUNCHING && t->state!=FAILING && t->state!=ABORTING) return;
  if(t->state==LAUNCHING) {
    Failure e; ssize_t n=read(t->error_fd,&e,sizeof e);
    if(n<0) { assert(errno==EAGAIN || errno==EINTR); return; }
    assert(n==0 || n==sizeof e);
    close_error(t);
    if(n) { t->failure=e; t->state=FAILING; }
    else t->state=RUNNING;
  }
  if(t->state!=RUNNING) observe(t);
}
static void abort_launch(Ticket *t) {
  observe(t);
  if(t->pid<=0) return;
  if(t->state!=ABORTING) {
    int r=syscall(SYS_pidfd_send_signal,t->pidfd,SIGKILL,NULL,0);
    assert(r==0 || (r<0 && errno==ESRCH));
    t->state=ABORTING; close_error(t);
  }
  observe(t);
}
static void finish(Ticket *t) {
  if(t->pid>0) {
    assert(identity_wait(t,0)==t->pid);
    t->pid=-1; t->state=REAPED;
  }
  close_error(t); close_identity(t);
}
static int compatible_sigchld(void) {
  struct sigaction a; assert(sigaction(SIGCHLD,NULL,&a)==0);
  return a.sa_handler==SIG_DFL && !(a.sa_flags & SA_NOCLDWAIT);
}
/* gate != -1 holds the child before exec; ready acknowledges the hold. */
static Ticket begin(const char *image, char *const args[], int gate, int ready,
                    int null_stdio, int seal_fds, int die_before_exec) {
  assert(compatible_sigchld());
  int e[2]; normalized_pipe(e);
  int null=-1;
  if(null_stdio) { null=open("/dev/null",O_RDWR|O_CLOEXEC); assert(null>=0); null=above_stdio(null); }
  int pidfd=-1; pid_t pid=clone_identity(&pidfd); assert(pid>=0);
  if(pid==0) {
    close(e[0]);
    if(gate>=0) {
      char byte='r'; if(write(ready,&byte,1)!=1) _exit(90);
      if(read(gate,&byte,1)!=1) _exit(91);
    }
    if(die_before_exec) _exit(127);
    Failure failure={1,0};
    if(null_stdio && (dup2(null,0)<0 || dup2(null,1)<0 || dup2(null,2)<0)) goto failed;
    if(seal_fds && syscall(SYS_close_range,3,UINT_MAX,CLOSE_RANGE_CLOEXEC)<0) { failure.stage=2; goto failed; }
    execve(image,args,(char *const[]){NULL}); failure.stage=3;
  failed:
    failure.error=errno;
    ssize_t n; do n=write(e[1],&failure,sizeof failure); while(n<0 && errno==EINTR);
    _exit(n==sizeof failure ? 127 : 92);
  }
  close(e[1]); if(null>=0) close(null);
  assert(fcntl(e[0],F_SETFL,O_NONBLOCK)==0);
  return (Ticket){.pid=pid,.pidfd=pidfd,.error_fd=e[0],.state=LAUNCHING};
}
static Ticket shell(const char *script, int seal_fds) {
  char *args[]={"/bin/sh","-c",(char *)script,NULL};
  return begin(args[0],args,-1,-1,1,seal_fds,0);
}
static void settle_launch(Ticket *t) {
  while(t->state==LAUNCHING || t->state==FAILING) {
    check_launch(t);
    if(t->error_fd>=0) { struct pollfd p={t->error_fd,POLLIN|POLLHUP,0}; assert(poll(&p,1,100)>=0); }
  }
}
static void stalled(void) {
  int gate[2],ready[2]; pipe_ce(gate); pipe_ce(ready);
  char *args[]={"/bin/true",NULL};
  Ticket t=begin(args[0],args,gate[0],ready[1],0,1,0);
  close(gate[0]); close(ready[1]); char byte;
  assert(read(ready[0],&byte,1)==1); close(ready[0]);
  for(int i=0;i<10000;i++) { check_launch(&t); assert(t.state==LAUNCHING); }
  struct pollfd p={t.error_fd,POLLIN|POLLHUP,0}; assert(poll(&p,1,25)==0);
  puts("stall: 10000 nonblocking checks pending; blocking-read control not readable after 25ms");
  pid_t pid=t.pid; abort_launch(&t); abort_launch(&t); finish(&t); close(gate[1]);
  assert(WIFSIGNALED(t.status) && WTERMSIG(t.status)==SIGKILL);
  assert(wait_owned(pid,&t.status,WNOHANG)==-1 && errno==ECHILD);
  puts("abort: stalled pre-exec child pidfd SIGKILL/reaped once; repeated abort does not signal");
}
static void handshake(void) {
  char *missing[]={"/missing-medaka-launch-image",NULL};
  Ticket t=begin(missing[0],missing,-1,-1,0,1,0); settle_launch(&t); finish(&t);
  assert(t.failure.stage==3 && t.failure.error==ENOENT);
  puts("missing: stage=ExecImage errno=ENOENT; failed child reaped");
  t=shell("exit 127",1); settle_launch(&t); assert(t.failure.stage==0); finish(&t);
  assert(WIFEXITED(t.status) && WEXITSTATUS(t.status)==127);
  int real=t.status;
  t=begin("/bin/true",(char *const[]){"/bin/true",NULL},-1,-1,0,1,1);
  settle_launch(&t); assert(t.failure.stage==0); finish(&t); assert(t.status==real);
  puts("EOF-control: real exec+exit127 and pre-exec _exit127 have identical EOF/status; no exec attestation");
  pid_t other=fork(); assert(other>=0); if(!other) _exit(23);
  t=shell("exit 4",1); settle_launch(&t); finish(&t);
  int status; assert(wait_owned(other,&status,0)==other && WEXITSTATUS(status)==23);
  puts("wait: unrelated child remains waitable with exit23");
}
static void closed_stdio(void) {
  for(int mask=1;mask<8;mask++) {
    pid_t pid=fork(); assert(pid>=0);
    if(pid==0) {
      for(int fd=0;fd<3;fd++) if(mask & (1<<fd)) close(fd);
      Ticket t=shell("test -r /dev/fd/0 && test -w /dev/fd/1 && test -w /dev/fd/2; exit $?",1);
      settle_launch(&t); finish(&t);
      _exit(WIFEXITED(t.status) ? WEXITSTATUS(t.status) : 100);
    }
    int status; assert(wait_owned(pid,&status,0)==pid && WIFEXITED(status) && WEXITSTATUS(status)==0);
  }
  pid_t pid=fork(); assert(pid>=0);
  if(!pid) {
    close(0); int p[2]; pipe_ce(p); assert(p[0]==0);
    assert(dup2(p[0],0)==0); close(p[0]);
    assert(fcntl(0,F_GETFD)==-1 && errno==EBADF); close(p[1]); _exit(0);
  }
  int status; assert(wait_owned(pid,&status,0)==pid && WEXITSTATUS(status)==0);
  puts("stdio: all seven initially-closed subsets normalized above fd2, then dup2; naive close-after-dup2 self-close reproduced");
}
static void inheritance(void) {
  int fd=open("/dev/null",O_RDONLY); assert(fd>=0);
  int marker=fcntl(fd,F_DUPFD,100); assert(marker>=100); close(fd);
  char script[200]; snprintf(script,sizeof script,"test ! -e /proc/self/fd/%d",marker);
  Ticket t=shell(script,1); settle_launch(&t); finish(&t); assert(WEXITSTATUS(t.status)==0);
  t=shell(script,0); settle_launch(&t); finish(&t); assert(WEXITSTATUS(t.status)==1);
  close(marker);
  puts("inheritance: child close_range(CLOEXEC) seals unrelated non-CLOEXEC fd; omitted-seal control leaks");
}
static void sigchld(void) {
  struct sigaction old,a={0}; sigemptyset(&a.sa_mask);
  a.sa_handler=SIG_IGN; assert(sigaction(SIGCHLD,&a,&old)==0); assert(!compatible_sigchld());
  a.sa_handler=SIG_DFL; a.sa_flags=SA_NOCLDWAIT; assert(sigaction(SIGCHLD,&a,NULL)==0); assert(!compatible_sigchld());
  assert(sigaction(SIGCHLD,&old,NULL)==0);
  Ticket t=shell("exit 5",1); int status; assert(wait_owned(t.pid,&status,0)==t.pid);
  abort_launch(&t); assert(t.state==LOST && t.pid==-1 && t.error_fd==-1);
  puts("SIGCHLD: IGN/NOCLDWAIT refused; external-reaper control loses ownership, abort never signals invalidated pid");
  int gate[2],ready[2]; pipe_ce(gate); pipe_ce(ready);
  t=begin("/bin/true",(char *const[]){"/bin/true",NULL},gate[0],ready[1],0,1,0);
  close(gate[0]); close(ready[1]); char byte; assert(read(ready[0],&byte,1)==1); close(ready[0]);
  a.sa_handler=SIG_IGN; a.sa_flags=0; assert(sigaction(SIGCHLD,&a,&old)==0);
  while(t.pid>0) abort_launch(&t);
  assert(t.state==LOST && t.pidfd==-1);
  assert(sigaction(SIGCHLD,&old,NULL)==0); close(gate[1]);
  puts("SIGCHLD-race: post-creation SIG_IGN auto-reaps; pidfd wait ECHILD invalidates authority");
}
typedef struct { int fd, report; } Race;
static void *spawner(void *arg) {
  Race *r=arg;
  pid_t pid=fork(); assert(pid>=0);
  if(!pid) {
    char script[128]; snprintf(script,sizeof script,"test -e /proc/self/fd/%d",r->fd);
    execl("/bin/sh","sh","-c",script,(char *)NULL); _exit(99);
  }
  int status; assert(wait_owned(pid,&status,0)==pid); r->report=WEXITSTATUS(status); return NULL;
}
static void creation_race(void) {
  for(int atomic=0;atomic<2;atomic++) {
    int p[2]; if(atomic) pipe_ce(p); else assert(pipe(p)==0);
    Race r={p[0],-1}; pthread_t thread;
    assert(pthread_create(&thread,NULL,spawner,&r)==0); assert(pthread_join(thread,NULL)==0);
    assert(r.report==(atomic ? 1 : 0));
    if(!atomic) { assert(fcntl(p[0],F_SETFD,FD_CLOEXEC)==0); assert(fcntl(p[1],F_SETFD,FD_CLOEXEC)==0); }
    close(p[0]); close(p[1]);
  }
  puts("creation-race: competing native thread exec leaks pipe-before-fcntl; pipe2(O_CLOEXEC) control does not leak");
}
static void *foreign_reaper(void *arg) {
  int fd=*(int *)arg; siginfo_t info; int r;
  do r=waitid(P_PIDFD,fd,&info,WEXITED); while(r<0 && errno==EINTR);
  assert(r==0 || (r<0 && errno==ECHILD)); close(fd); return NULL;
}
static void abort_reap_race(void) {
  for(int i=0;i<64;i++) {
    Ticket t=shell("exit 23",1);
    int fd=fcntl(t.pidfd,F_DUPFD_CLOEXEC,3); assert(fd>=3); pthread_t thread;
    assert(pthread_create(&thread,NULL,foreign_reaper,&fd)==0);
    while(t.pid>0) abort_launch(&t);
    assert(t.state==LOST || t.state==REAPED);
    assert(pthread_join(thread,NULL)==0);
  }
  puts("abort-reap-race: 64 concurrent foreign waits versus abort; cached terminal or ECHILD, no pid-number signal/wait");
}
static void atomic_identity(void) {
  int pidfd=-1;
  struct clone_args args={.flags=CLONE_PIDFD,.pidfd=(unsigned long)&pidfd,.exit_signal=SIGCHLD};
  pid_t pid=syscall(SYS_clone3,&args,sizeof args);
  if(pid<0) printf("clone3: unavailable errno=%d; testing fork-like clone(CLONE_PIDFD)\n",errno);
  if(pid<0) pid=syscall(SYS_clone,CLONE_PIDFD|SIGCHLD,NULL,&pidfd,NULL,0UL);
  if(pid<0) { printf("BLOCKED: atomic child identity errno=%d\n",errno); exit(77); }
  if(!pid) { for(;;) pause(); }
  assert(pidfd>=0 && (fcntl(pidfd,F_GETFD)&FD_CLOEXEC));
  siginfo_t info={0};
  assert(waitid(P_PIDFD,pidfd,&info,WEXITED|WNOHANG)==0 && info.si_pid==0);
  assert(syscall(SYS_pidfd_send_signal,pidfd,SIGKILL,NULL,0)==0);
  assert(waitid(P_PIDFD,pidfd,&info,WEXITED)==0 && info.si_pid==pid && info.si_code==CLD_KILLED && info.si_status==SIGKILL);
  errno=0; assert(syscall(SYS_pidfd_send_signal,pidfd,SIGKILL,NULL,0)==-1 && errno==ESRCH);
  close(pidfd);
  puts("atomic-identity: CLONE_PIDFD supplies CLOEXEC identity; waitid(P_PIDFD) reaps exact child; post-reap signal ESRCH");

  pidfd=-1; pid=syscall(SYS_clone,CLONE_PIDFD|SIGCHLD,NULL,&pidfd,NULL,0UL);
  assert(pid>=0); if(!pid) _exit(23);
  int status; assert(wait_owned(pid,&status,0)==pid && WEXITSTATUS(status)==23);
  errno=0; assert(waitid(P_PIDFD,pidfd,&info,WEXITED|WNOHANG)==-1 && errno==ECHILD);
  errno=0; assert(syscall(SYS_pidfd_send_signal,pidfd,SIGKILL,NULL,0)==-1 && errno==ESRCH);
  close(pidfd);
  puts("foreign-reaper: atomic pidfd survives stolen status; identity wait ECHILD, signal ESRCH; no numeric-pid fallback");
}
int main(void) {
  alarm(15); stalled(); handshake(); closed_stdio(); inheritance(); sigchld(); creation_race(); atomic_identity(); abort_reap_race();
  puts("launch mechanism controls passed"); return 0;
}
#endif
