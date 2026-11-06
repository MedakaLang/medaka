#define _GNU_SOURCE
#define GC_THREADS
#define GC_NO_THREAD_REDIRECTS
#include <gc.h>
#include "medaka_process.h"
#include "medaka_runtime.h"
#include <errno.h>
#include <fcntl.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

extern int mdk_process_test_roots(void);
extern int mdk_process_test_permits(void);
extern int mdk_process_test_pid(long long);
extern int mdk_process_test_pidfd(long long);
extern void mdk_process_test_submit_hold(int, int, int);
extern void mdk_process_test_child_hold(int, int);
extern void mdk_process_test_faults(int, int, int);
extern void mdk_process_test_lock(int);
extern int mdk_process_test_pipe(int[2]);
static int checks, skip_adoption;
#define CHECK(x) do { ++checks; if (!(x)) { dprintf(2,"FAIL line %d: %s\n",__LINE__,#x); _exit(1); } } while (0)
static long long field(long long w, unsigned i) { return ((long long *)w)[i]; }
static long long nil(void) { return (MDK_TAG_NIL << 1) | 1; }
static long long cons(long long value, long long tail) {
  long long *c = mdk_alloc(3*sizeof(long long)); c[0]=MDK_TAG_CONS; c[1]=value; c[2]=tail; return (long long)c;
}
static long long pair(long long a, long long b) {
  long long *c = mdk_alloc(3*sizeof(long long)); c[0]=MDK_TUPLE_TAG; c[1]=a; c[2]=b; return (long long)c;
}
static int code(long long r) { CHECK(field(r,0)==MDK_TAG_ERR); return (int)(field(field(r,1),1)>>1); }
static int kind(long long r) { CHECK(field(r,0)==MDK_TAG_OK); return (int)(field(field(r,1),1)>>1); }
static long long submit(const char *path, long long argv, long long env) {
  return mdk_process_submit(mdk_runtime_string(path),argv,mdk_runtime_string("/tmp"),env,1,1,1);
}
static long long ticket(const char *path) {
  long long r=submit(path,nil(),nil()); CHECK(field(r,0)==MDK_TAG_OK); return field(r,1);
}
static int fds(void) { int count=0; for (int i=0;i<1024;++i) count+=fcntl(i,F_GETFD)>=0; return count; }
static double now(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts); return ts.tv_sec+ts.tv_nsec/1e9; }
typedef struct { int gate[2],ready[2]; } Gate;
static void gate_open(Gate *g) { CHECK(pipe2(g->gate,O_CLOEXEC)==0); CHECK(pipe2(g->ready,O_CLOEXEC)==0); }
static void gate_ready(Gate *g) { char byte; CHECK(read(g->ready[0],&byte,1)==1); }
static void gate_release(Gate *g) { CHECK(write(g->gate[1],"x",1)==1); }
static void gate_close(Gate *g) { close(g->gate[0]);close(g->gate[1]);close(g->ready[0]);close(g->ready[1]); }
static long long drain(long long p,int aborting) {
  for (int i=0;i<10000;++i) {
    long long r=aborting?mdk_process_abort_start(p):mdk_process_check_start(p);
    if (field(r,0)==MDK_TAG_ERR) { CHECK(code(r)==MDK_PROCESS_BUSY); }
    else if (kind(r)!=0) return r;
    usleep(1000);
  }
  CHECK(0); return 0;
}
static void finish(long long p) {
  for (int i=0;i<10000;++i) {
    long long r=mdk_process_poll_exit(p); CHECK(field(r,0)==MDK_TAG_OK);
    if (!(field(r,1)&1)) { CHECK(field(mdk_process_dispose(p),0)==MDK_TAG_OK); return; }
    usleep(1000);
  }
  CHECK(0);
}
static void empty(void) { CHECK(mdk_process_test_permits()==0); CHECK(mdk_process_test_roots()==0); }
static void pending_work(long long p) {
  double before=now(); int ticks=0;
  for (int i=0;i<1000;++i) {
    CHECK(kind(mdk_process_check_start(p))==0);
    ++ticks;
  }
  CHECK(ticks==1000); CHECK(now()-before<0.2);
  GC_gcollect(); CHECK(mdk_process_test_roots()>=1);
}
static void repeated_resources(void) {
  const int sessions=32; int baseline=fds();
  struct rusage before, after; CHECK(getrusage(RUSAGE_SELF,&before)==0);
  GC_gcollect(); size_t allocated=GC_get_total_bytes(), heap=GC_get_heap_size();
  size_t live=heap-GC_get_free_bytes();
  for (int i=0;i<sessions;++i) {
    long long p=ticket("/bin/true"); CHECK(kind(drain(p,0))==1); finish(p); empty();
  }
  GC_gcollect(); CHECK(getrusage(RUSAGE_SELF,&after)==0);
  size_t bytes=GC_get_total_bytes()-allocated, retained=GC_get_heap_size();
  size_t live_after=retained-GC_get_free_bytes();
  CHECK(fds()==baseline); CHECK(bytes<64*1024*1024); CHECK(retained<=heap+64*1024*1024);
  CHECK(live_after<=live+64*1024*1024); CHECK(after.ru_maxrss<=before.ru_maxrss+64*1024);
  printf("resource sessions=%d allocation_bytes=%zu gc_heap_before=%zu gc_heap_after=%zu gc_used_before=%zu gc_used_after=%zu roots=0 permits=0 fds=%d peak_rss_kib=%ld passed\n", sessions,bytes,heap,retained,live,live_after,baseline,after.ru_maxrss);
}
static void before_creation(void) {
  int baseline=fds(); Gate g;gate_open(&g);
  mdk_process_test_submit_hold(1,g.gate[0],g.ready[1]);
  long long p=ticket("/bin/true");gate_ready(&g);
  CHECK(mdk_process_test_pidfd(p)==-1);pending_work(p);
  CHECK(kind(mdk_process_abort_start(p))==0);
  CHECK(mdk_process_test_permits()==1 && mdk_process_test_roots()==1);
  mdk_process_test_submit_hold(0,-1,-1);gate_release(&g);
  CHECK(kind(drain(p,1))==3);CHECK(mdk_process_test_pid(p)==0);empty();
  for (int i=0;i<16;++i) {
    long long other=ticket("/bin/true");CHECK(kind(drain(other,0))==1);finish(other);
    CHECK(kind(mdk_process_abort_start(p))==3);
  }
  gate_close(&g);CHECK(fds()==baseline);
  puts("pre-create cancellation, independent turns, acknowledgement and stale aliases passed");
}
static void creation_race(void) {
  int baseline=fds(); Gate g;gate_open(&g);
  mdk_process_test_submit_hold(2,g.gate[0],g.ready[1]);
  long long p=ticket("/bin/true");gate_ready(&g);pending_work(p);
  CHECK(kind(mdk_process_abort_start(p))==0);
  mdk_process_test_submit_hold(0,-1,-1);gate_release(&g);
  CHECK(kind(drain(p,1))==3);CHECK(mdk_process_test_pid(p)>0);empty();
  int status;CHECK(waitpid(mdk_process_test_pid(p),&status,WNOHANG)==-1 && errno==ECHILD);
  gate_close(&g);CHECK(fds()==baseline);
  puts("cancellation after final stop check still creates one exactly reaped child passed");
}
static long long held_child(Gate *g) {
  Gate publication;gate_open(&publication);mdk_process_test_submit_hold(3,publication.gate[0],publication.ready[1]);
  gate_open(g);mdk_process_test_child_hold(g->gate[0],g->ready[1]);
  long long p=ticket("/bin/true");gate_ready(g);gate_ready(&publication);
  CHECK(kind(mdk_process_check_start(p))==0);CHECK(mdk_process_test_pid(p)==0);
  mdk_process_test_submit_hold(0,-1,-1);gate_release(&publication);
  for (int i=0;i<1000 && !mdk_process_test_pid(p);++i) {
    if (!skip_adoption) CHECK(kind(mdk_process_check_start(p))==0);
    usleep(1000);
  }
  CHECK(mdk_process_test_pid(p)>0);CHECK(mdk_process_test_pidfd(p)>=0);
  CHECK(kill(mdk_process_test_pid(p),0)==0);
  CHECK(mdk_process_test_permits()==1 && mdk_process_test_roots()==1);
  gate_close(&publication);mdk_process_test_child_hold(-1,-1);return p;
}
static void before_exec(void) {
  int baseline=fds();Gate g;long long p=held_child(&g);pending_work(p);
  mdk_process_test_faults(EPERM,EIO,0);
  long long r=mdk_process_abort_start(p);CHECK(code(r)==5);CHECK((field(field(r,1),2)>>1)==EIO);
  CHECK(mdk_process_test_permits()==1 && mdk_process_test_roots()==1);
  mdk_process_test_faults(EPERM,0,0);r=mdk_process_abort_start(p);CHECK(code(r)==5);CHECK((field(field(r,1),2)>>1)==EPERM);
  GC_gcollect();CHECK(mdk_process_test_permits()==1);
  mdk_process_test_faults(0,0,0);CHECK(kind(drain(p,1))==3);empty();
  int status;CHECK(waitpid(mdk_process_test_pid(p),&status,WNOHANG)==-1 && errno==ECHILD);
  gate_close(&g);CHECK(fds()==baseline);puts("pre-exec cancellation, signal/wait denial, retained owner and exact pidfd reap passed");
}
static void overflow(void) {
  int baseline=fds();Gate g;gate_open(&g);
  mdk_process_test_submit_hold(1,g.gate[0],g.ready[1]);
  long long ps[8];ps[0]=ticket("/bin/true");gate_ready(&g);
  for (int i=1;i<8;++i) ps[i]=ticket("/bin/true");
  for (int i=0;i<32;++i) CHECK(code(submit("/bin/true",nil(),nil()))==MDK_PROCESS_QUEUE_FULL);
  CHECK(mdk_process_test_permits()==8 && mdk_process_test_roots()==8);
  for (int i=0;i<8;++i) CHECK(kind(mdk_process_abort_start(ps[i]))==0);
  CHECK(code(submit("/bin/true",nil(),nil()))==MDK_PROCESS_QUEUE_FULL);
  GC_gcollect();CHECK(mdk_process_test_roots()==8);
  mdk_process_test_submit_hold(0,-1,-1);gate_release(&g);
  for (int i=0;i<8;++i) CHECK(kind(drain(ps[i],1))==3);
  empty();gate_close(&g);CHECK(fds()==baseline);puts("eight permits, nonwaiting overflow and pre-ack retention passed");
}
static void wait_denial(void) {
  int baseline=fds();long long ps[8];mdk_process_test_faults(0,EIO,0);
  for (int i=0;i<8;++i) ps[i]=ticket("/no-such-submission-program");
  for (int i=0;i<8;++i) {
    int found=0;
    for (int j=0;j<10000;++j) {
      long long r=mdk_process_check_start(ps[i]);
      if (field(r,0)==MDK_TAG_ERR) { CHECK(code(r)==5);found=1;break; }
      CHECK(kind(r)==0);usleep(1000);
    }
    CHECK(found);
  }
  for (int round=0;round<32;++round) for (int i=0;i<8;++i) CHECK(code(mdk_process_check_start(ps[i]))==5);
  GC_gcollect();CHECK(mdk_process_test_permits()==8 && mdk_process_test_roots()==8);
  CHECK(code(submit("/bin/true",nil(),nil()))==MDK_PROCESS_QUEUE_FULL);
  /* Denial retains zombies and authority; only clearing the fault permits a reap claim. */
  for (int i=0;i<8;++i) {
    siginfo_t info={0};CHECK(waitid(P_PID,mdk_process_test_pid(ps[i]),&info,WEXITED|WNOWAIT)==0);
    CHECK(info.si_pid==mdk_process_test_pid(ps[i]));
  }
  mdk_process_test_faults(0,0,0);
  for (int i=0;i<8;++i) CHECK(kind(drain(ps[i],0))==2);
  empty();CHECK(fds()==baseline);puts("permanent wait denial retains all permits and is never labelled a reap passed");
}
static void lost_wait(void) {
  int baseline=fds();Gate g;long long p=held_child(&g);
  mdk_process_test_faults(EPERM,0,0);CHECK(code(mdk_process_abort_start(p))==5);
  gate_release(&g);int status;CHECK(waitpid(mdk_process_test_pid(p),&status,0)==mdk_process_test_pid(p));
  long long r=drain(p,1);CHECK(kind(r)==2);
  long long e=field(field(field(r,1),3),1);CHECK((field(e,1)>>1)==5 && (field(e,2)>>1)==ECHILD);
  CHECK(kind(mdk_process_abort_start(p))==2);empty();mdk_process_test_faults(0,0,0);
  gate_close(&g);CHECK(fds()==baseline);puts("ECHILD invalidates authority without a fabricated reap passed");
}
static void trylocks(void) {
  Gate g;long long p=held_child(&g);mdk_process_test_lock(1);double before=now();
  CHECK(code(mdk_process_check_start(p))==17);CHECK(code(mdk_process_abort_start(p))==17);
  CHECK(code(mdk_process_poll_exit(p))==17);CHECK(code(mdk_process_close_stdin(p))==17);
  CHECK(code(mdk_process_dispose(p))==17);CHECK(code(mdk_process_stream_fd(p,1))==17);
  CHECK(code(mdk_process_try_read(p,3,3))==17);
  CHECK(code(submit("/bin/true",nil(),nil()))==17);
  CHECK(now()-before<0.1);mdk_process_test_lock(0);
  CHECK(kind(drain(p,1))==3);gate_close(&g);empty();puts("scheduler-facing trylock operations do not wait passed");
}
static void bounds(void) {
  int baseline=fds();long long args=nil(),env=nil();
  for (int i=0;i<257;++i) args=cons(mdk_runtime_string("x"),args);
  CHECK(code(submit("/bin/true",args,nil()))==0);
  for (int i=0;i<257;++i) env=cons(pair(mdk_runtime_string("x"),mdk_runtime_string("y")),env);
  CHECK(code(submit("/bin/true",nil(),env))==0);
  char *large=malloc(65537);memset(large,'x',65536);large[65536]=0;
  CHECK(code(submit("/bin/true",cons(mdk_runtime_string(large),nil()),nil()))==0);free(large);
  long long bad=mdk_runtime_string("a");((long long *)bad)[MDK_STRING_BYTE_LENGTH_SLOT]=INT64_MAX;
  CHECK(code(submit("/bin/true",cons(bad,nil()),nil()))==0);
  long long nul=mdk_runtime_string("abc");((char *)nul)[MDK_STRING_BYTES_OFFSET+1]=0;
  CHECK(code(submit("/bin/true",cons(nul,nil()),nil()))==0);
  CHECK(code(submit("relative",nil(),nil()))==0);
  env=cons(pair(mdk_runtime_string("X"),mdk_runtime_string("a")),cons(pair(mdk_runtime_string("X"),mdk_runtime_string("b")),nil()));
  long long r=submit("/bin/true",nil(),env);CHECK(field(r,0)==MDK_TAG_OK);
  CHECK(kind(drain(field(r,1),0))==2);empty();CHECK(fds()==baseline);
  puts("bounded metadata rejects counts, oversize lengths, embedded NUL and duplicate env passed");
}
static void pipe_failure_slots(void) {
  struct rlimit before,limited;
  CHECK(getrlimit(RLIMIT_NOFILE,&before)==0);limited=before;limited.rlim_cur=64;
  CHECK(setrlimit(RLIMIT_NOFILE,&limited)==0);
  int saved=dup(0);CHECK(saved>=3);
  int opened[64],count=0,fd;
  while((fd=open("/dev/null",O_RDONLY))>=0) opened[count++]=fd;
  CHECK(errno==EMFILE && count>0);
  CHECK(close(opened[--count])==0);CHECK(close(0)==0);
  int pipefds[2]={-1,-1};CHECK(mdk_process_test_pipe(pipefds)==-1 && errno==EMFILE);
  CHECK(pipefds[0]==-1 && pipefds[1]==-1);
  CHECK(dup2(saved,0)==0);close(saved);
  for(int i=0;i<count;++i) close(opened[i]);
  CHECK(setrlimit(RLIMIT_NOFILE,&before)==0);
  puts("failed pipe relocation disarms both descriptor slots passed");
}
typedef struct { Gate *g; } Releaser;
static void *later(void *arg) {
  Releaser *r=arg;struct timespec delay={0,300000000};
  while(nanosleep(&delay,&delay) && errno==EINTR) {}
  write(r->g->gate[1],"x",1);return NULL;
}
static void gc_inactive(void) {
  Gate g;gate_open(&g);mdk_process_test_submit_hold(2,g.gate[0],g.ready[1]);
  long long p=ticket("/bin/true");gate_ready(&g);
  pthread_t thread;Releaser release={&g};CHECK(pthread_create(&thread,NULL,later,&release)==0);
  double before=now();GC_gcollect();double elapsed=now()-before;
  CHECK(elapsed<0.15);printf("collector completed with worker signals masked in %.6fs\n",elapsed);
  CHECK(pthread_join(thread,NULL)==0);mdk_process_test_submit_hold(0,-1,-1);
  CHECK(kind(drain(p,0))==1);finish(p);gate_close(&g);empty();puts("GC-inactive native callback permits collection passed");
}
static void roots_and_env(void) {
  Gate g;gate_open(&g);mdk_process_test_submit_hold(1,g.gate[0],g.ready[1]);
  long long env=cons(pair(mdk_runtime_string("MDK_SUBMIT_VALUE"),mdk_runtime_string("rooted-inputs")),nil());
  long long args=cons(mdk_runtime_string("-c"),cons(mdk_runtime_string("test \"$MDK_SUBMIT_VALUE\" = rooted-inputs"),nil()));
  long long r=submit("/bin/sh",args,env);CHECK(field(r,0)==MDK_TAG_OK);long long p=field(r,1);gate_ready(&g);
  args=env=0;for(int i=0;i<10000;++i) memset(mdk_alloc(128),0,128);
  GC_gcollect();CHECK(mdk_process_test_roots()==1 && mdk_process_test_permits()==1);
  mdk_process_test_submit_hold(0,-1,-1);gate_release(&g);CHECK(kind(drain(p,0))==1);
  for (int i=0;i<10000;++i) {
    r=mdk_process_poll_exit(p);CHECK(field(r,0)==MDK_TAG_OK);
    if (!(field(r,1)&1)) { CHECK(field(field(field(r,1),1),2)==1);break; }
    usleep(1000);CHECK(i<9999);
  }
  CHECK(field(mdk_process_dispose(p),0)==MDK_TAG_OK);gate_close(&g);empty();puts("static owner/input roots survive collection and preserve env bytes passed");
}
static void synchronous_retry(void) {
  Gate g;gate_open(&g);mdk_process_test_submit_hold(1,g.gate[0],g.ready[1]);
  long long p=ticket("/bin/true");gate_ready(&g);
  pthread_t thread;Releaser release={&g};CHECK(pthread_create(&thread,NULL,later,&release)==0);
  long long r=mdk_process_retry_start(p);CHECK(field(r,0)==MDK_TAG_OK && field(r,1)==p);
  CHECK(pthread_join(thread,NULL)==0);mdk_process_test_submit_hold(0,-1,-1);
  CHECK(code(mdk_process_abort_start(p))==0);finish(p);gate_close(&g);empty();puts("retryStart synchronously waits for pre-child publication and preserves transfer passed");
}
typedef struct { long long ticket; unsigned call; } Denial;
static void *denied(void *arg) {
  Denial *d=arg;
  struct sock_filter instructions[]={
    BPF_STMT(BPF_LD|BPF_W|BPF_ABS,offsetof(struct seccomp_data,nr)),
    BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,d->call,0,1),
    BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ERRNO|EPERM),
    BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ALLOW),
  };
  struct sock_fprog filter={sizeof(instructions)/sizeof(instructions[0]),instructions};
  CHECK(prctl(PR_SET_NO_NEW_PRIVS,1,0,0,0)==0);
  CHECK(prctl(PR_SET_SECCOMP,SECCOMP_MODE_FILTER,&filter)==0);
  for(int i=0;i<32;++i) {
    long long r=mdk_process_abort_start(d->ticket);
    CHECK(code(r)==5 && (field(field(r,1),2)>>1)==EPERM);
    CHECK(mdk_process_test_permits()==1 && mdk_process_test_roots()==1);
  }
  return NULL;
}
static void kernel_denial(int signal) {
  int baseline=fds();Gate g;Denial denial={held_child(&g),signal?SYS_pidfd_send_signal:SYS_waitid};
  pthread_t thread;CHECK(GC_pthread_create(&thread,NULL,denied,&denial)==0);
  CHECK(GC_pthread_join(thread,NULL)==0);GC_gcollect();
  CHECK(kind(drain(denial.ticket,1))==3);empty();gate_close(&g);CHECK(fds()==baseline);
  printf("real kernel %s denial retains ownership until unrestricted cleanup passed\n",signal?"signal":"wait");
}
int mdk_program_main(int argc,char **argv) {
  alarm(30);
  if (getenv("MEDAKA_TEST_SUBMISSION_INIT_FAIL")) {
    CHECK(code(submit("/bin/true",nil(),nil()))==10);
    long long r=mdk_process_start(mdk_runtime_string("/bin/true"),nil(),mdk_runtime_string("/tmp"),nil(),1,1,1);
    CHECK(field(r,0)==MDK_TAG_OK);finish(field(r,1));empty();
    puts("worker initialization refusal preserves synchronous launch passed");return 0;
  }
  if (argc>1 && !strcmp(argv[1],"no-adoption")) { skip_adoption=1; Gate g; held_child(&g); }
  else if (argc>1 && !strcmp(argv[1],"gc")) gc_inactive();
  else if (argc>1 && !strcmp(argv[1],"signal")) kernel_denial(1);
  else if (argc>1 && !strcmp(argv[1],"wait")) kernel_denial(0);
  else {
    pipe_failure_slots();bounds();repeated_resources();before_creation();creation_race();before_exec();overflow();wait_denial();lost_wait();trylocks();roots_and_env();synchronous_retry();
  }
  CHECK(checks>10);printf("submission controls: %d passed\n",checks);return 0;
}
