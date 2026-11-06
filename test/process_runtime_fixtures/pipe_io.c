#define _GNU_SOURCE
#include "medaka_process.h"
#include "medaka_runtime.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#define GC_THREADS
#include <gc.h>
#include <pthread.h>
#include <signal.h>
#include <stddef.h>
#include <limits.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern int mdk_process_test_flags(long long, int);
extern int mdk_process_test_fd(long long, int);
extern int mdk_process_test_roots(void);
extern long long mdk_process_test_begin(int, int);
extern int mdk_process_test_abort(long long);
static int checks;
static int fd_count(void) { int n=0; for (int i=0;i<256;++i) if (fcntl(i,F_GETFD)>=0) ++n; return n; }
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); _exit(1); } } while (0)
static long long nil(void) { return (MDK_TAG_NIL << 1) | 1; }
static long long cons(long long head, long long tail) { long long *p=mdk_alloc(24); p[0]=MDK_TAG_CONS;p[1]=head;p[2]=tail;return (long long)p; }
static long long field(long long v, int i) { return ((long long *)v)[i]; }
static long long str(const char *s) { return mdk_runtime_string(s); }
static long long start(const char *program, long long args, const char *cwd, long long env, int in) {
  long long r=mdk_process_start(str(program), args, str(cwd), env, in ? 1 : 3, 3, 3);
  if (field(r,0)==MDK_TAG_ERR) CHECK(field(field(r,1),4)==(MDK_TAG_NONE<<1|1));
  return r;
}
static long long must_start(const char *program, long long args, int in) {
  long long r=start(program,args,"/tmp",nil(),in); CHECK(field(r,0)==MDK_TAG_OK); return field(r,1);
}
static int error_code(long long r) { CHECK(field(r,0)==MDK_TAG_ERR); return (int)(field(field(r,1),1)>>1); }
static long long wait_exit(long long p) {
  for (int i=0;i<10000;++i) {
    long long r=mdk_process_poll_exit(p); CHECK(field(r,0)==MDK_TAG_OK);
    long long o=field(r,1); if (!(o&1)) return field(o,1); usleep(1000);
  }
  CHECK(0); return 0;
}
static long long pair(long long a, long long b) { long long *p=mdk_alloc(24); p[0]=MDK_TUPLE_TAG; p[1]=a; p[2]=b; return (long long)p; }
static void *collect_loop(void *arg) { int *stop=arg; while (!__atomic_load_n(stop,__ATOMIC_RELAXED)) GC_gcollect(); return NULL; }
static long long shell(const char *command, int in) { return must_start("/bin/sh",cons(str("-c"),cons(str(command),nil())),in); }

extern void mdk_process_test_io_faults(int, int);
static long long boxed(int n) { return (long long)n * 2 + 1; }
static long long block(int n) { long long *p=mdk_alloc(16+n); p[0]=MDK_BYTEBLOCK_TAG; p[1]=n; memset((char *)p+16,'x',n); return (long long)p; }
static int none(long long r) { CHECK(field(r,0)==MDK_TAG_OK); return field(r,1)==(MDK_TAG_NONE<<1|1); }
static long long some(long long r) { CHECK(field(r,0)==MDK_TAG_OK); long long o=field(r,1); CHECK(!(o&1) && field(o,0)==MDK_TAG_SOME); return field(o,1); }
static long long pipe_shell(const char *cmd) {
  long long args=cons(str("-c"),cons(str(cmd),nil()));
  long long r=mdk_process_start(str("/bin/sh"),args,str("/tmp"),nil(),1,1,1);
  CHECK(field(r,0)==MDK_TAG_OK); return field(r,1);
}
int mdk_program_main(int argc, char **argv) {
  (void)argc; (void)argv; alarm(30);
  long long p=pipe_shell("sleep 1; printf abc; printf err >&2; cat >/dev/null"), b=block(100000);
  CHECK(error_code(mdk_process_try_read(p,boxed(0),boxed(1)))==13);
  CHECK(error_code(mdk_process_try_read(p,boxed(1),boxed(0)))==13);
  CHECK(error_code(mdk_process_stream_fd(p,boxed(3)))==13);
  CHECK(error_code(mdk_process_try_write(p,b,boxed(99999),boxed(2)))==13);
  CHECK(none(mdk_process_try_read(p,boxed(1),boxed(10))));
  mdk_process_test_io_faults(EINTR, EINTR);
  CHECK(none(mdk_process_try_read(p,boxed(1),boxed(10))));
  CHECK(none(mdk_process_try_write(p,b,boxed(0),boxed(1))));
  CHECK(fcntl(mdk_process_test_fd(p,0), F_SETPIPE_SZ, 4096)==4096);
  int written=(int)(some(mdk_process_try_write(p,b,boxed(0),boxed(100000)))>>1);
  CHECK(written>0 && written<65536);
  CHECK(none(mdk_process_try_write(p,b,boxed(written),boxed(1))));
  int old_stdin=mdk_process_test_fd(p,0);
  CHECK(field(mdk_process_close_stdin(p),0)==MDK_TAG_OK);
  int reused[2]; CHECK(pipe(reused)==0);
  if (reused[0]==old_stdin) { int moved=fcntl(reused[0],F_DUPFD_CLOEXEC,old_stdin+1); CHECK(moved>=0); close(reused[0]); reused[0]=moved; }
  if (reused[1]!=old_stdin) CHECK(dup2(reused[1],old_stdin)==old_stdin);
  CHECK(error_code(mdk_process_try_write(p,b,boxed(0),boxed(1)))==8);
  CHECK(fcntl(reused[0],F_SETFL,O_NONBLOCK)==0);
  char marker; CHECK(read(reused[0],&marker,1)<0 && errno==EAGAIN);
  close(old_stdin); close(reused[0]); if (reused[1]!=old_stdin) close(reused[1]);
  long long t=wait_exit(p); CHECK(field(t,2)==1);
  long long out=some(mdk_process_try_read(p,boxed(1),boxed(10)));
  CHECK(field(out,1)==3 && !memcmp((char *)out+16,"abc",3));
  out=some(mdk_process_try_read(p,boxed(2),boxed(10)));
  CHECK(field(out,1)==3 && !memcmp((char *)out+16,"err",3));
  out=some(mdk_process_try_read(p,boxed(1),boxed(10))); CHECK(field(out,1)==0);
  long long lookup=mdk_process_stream_fd(p,boxed(1)); CHECK(field(lookup,0)==MDK_TAG_OK);
  int fd=(int)(field(lookup,1)>>1);
  CHECK(field(mdk_process_dispose(p),0)==MDK_TAG_OK);
  int fds[2]; CHECK(pipe(fds)==0); if (fds[1]!=fd) CHECK(dup2(fds[1],fd)==fd);
  CHECK(error_code(mdk_process_try_read(p,boxed(1),boxed(10)))==8);
  CHECK(error_code(mdk_process_stream_fd(p,boxed(1)))==8);
  close(fd); close(fds[0]); if (fds[1]!=fd) close(fds[1]);
  p=pipe_shell("exit 0"); wait_exit(p);
  struct sigaction before, after; CHECK(sigaction(SIGPIPE,NULL,&before)==0);
  sigset_t set, old, pending; sigemptyset(&set); sigaddset(&set,SIGPIPE);
  CHECK(pthread_sigmask(SIG_BLOCK,&set,&old)==0);
  long long clean=mdk_process_try_write(p,b,boxed(0),boxed(1)); CHECK(error_code(clean)==15);
  CHECK(sigpending(&pending)==0 && !sigismember(&pending,SIGPIPE));
  CHECK(raise(SIGPIPE)==0);
  long long r=mdk_process_try_write(p,b,boxed(0),boxed(1)); CHECK(error_code(r)==15); CHECK((field(field(r,1),2)>>1)==EPIPE);
  CHECK(sigpending(&pending)==0 && sigismember(&pending,SIGPIPE));
  struct timespec zero={0,0}; CHECK(sigtimedwait(&set,NULL,&zero)==SIGPIPE);
  CHECK(pthread_sigmask(SIG_SETMASK,&old,NULL)==0); CHECK(sigaction(SIGPIPE,NULL,&after)==0 && before.sa_handler==after.sa_handler);
  CHECK(field(mdk_process_dispose(p),0)==MDK_TAG_OK);
  CHECK(checks>40); printf("pipe IO: %d checks passed\n",checks); return 0;
}
