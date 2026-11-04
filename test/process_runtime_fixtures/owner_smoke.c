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
  return mdk_process_start(str(program), args, str(cwd), env, in ? 1 : 3, 3, 3);
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
int mdk_program_main(int argc, char **argv) {
  alarm(30);
  if (argc > 1 && !strcmp(argv[1], "closed-stdio")) {
    long long p=must_start("/bin/true",nil(),0), t=wait_exit(p);
    CHECK(field(t,2)==1); CHECK(field(mdk_process_dispose(p),0)==MDK_TAG_OK);
    return 0;
  }
  if (argc > 1 && !strncmp(argv[1], "deny-", 5)) {
    int denied = !strcmp(argv[1], "deny-clone") ? SYS_clone3 :
                 !strcmp(argv[1], "deny-signal") ? SYS_pidfd_send_signal :
                 !strcmp(argv[1], "deny-wait") ? SYS_waitid : SYS_close_range;
    struct sock_filter insns[] = {
      BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
      BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, denied, 0, 1),
      BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
      BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW)
    };
    struct sock_fprog filter={sizeof(insns)/sizeof(insns[0]),insns};
    CHECK(prctl(PR_SET_NO_NEW_PRIVS,1,0,0,0)==0);
    CHECK(prctl(PR_SET_SECCOMP,SECCOMP_MODE_FILTER,&filter)==0);
    CHECK(error_code(start("/bin/true",nil(),"/tmp",nil(),0))==10);
    printf("unsupported %s: %d checks passed\n",argv[1],checks); return 0;
  }
  int baseline_fds=fd_count();
  struct rlimit original, pressure; CHECK(getrlimit(RLIMIT_NOFILE,&original)==0); pressure=original;
  pressure.rlim_cur=3; CHECK(setrlimit(RLIMIT_NOFILE,&pressure)==0);
  long long pressure_error=start("/bin/true",nil(),"/tmp",nil(),1);
  CHECK(error_code(pressure_error)==1); CHECK((field(field(pressure_error,1),2)>>1)==EMFILE);
  CHECK(setrlimit(RLIMIT_NOFILE,&original)==0); CHECK(fd_count()==baseline_fds); CHECK(mdk_process_test_roots()==0);
  struct sigaction old_action, ignored={0}; ignored.sa_handler=SIG_IGN; sigemptyset(&ignored.sa_mask);
  CHECK(sigaction(SIGCHLD,&ignored,&old_action)==0);
  CHECK(error_code(start("/bin/true",nil(),"/tmp",nil(),0))==7);
  CHECK(sigaction(SIGCHLD,&old_action,NULL)==0);
  long long *nulstr=mdk_alloc(28); nulstr[0]=MDK_STR_TAG; nulstr[1]=3; nulstr[2]=3; memcpy((char *)nulstr+24,"a\0b",3);
  CHECK(error_code(mdk_process_start((long long)nulstr,nil(),str("/tmp"),nil(),3,3,3))==0);
  CHECK(error_code(start("relative",nil(),"/tmp",nil(),0))==0);
  CHECK(error_code(start("/bin/true",nil(),"relative",nil(),0))==0);
  CHECK(error_code(mdk_process_start(str("/bin/true"),nil(),str("/tmp"),nil(),5,3,3))==0);
  long long missing=start("/not-a-medaka-program",nil(),"/tmp",nil(),0);
  CHECK(error_code(missing)==4); CHECK((field(field(missing,1),2)>>1)==ENOENT);
  missing=start("/bin/true",nil(),"/not-a-medaka-directory",nil(),0);
  CHECK(error_code(missing)==3); CHECK((field(field(missing,1),2)>>1)==ENOENT);
  CHECK(fd_count()==baseline_fds); CHECK(mdk_process_test_roots()==0);
  long long p=shell("exit 127",0), alias=p, t=wait_exit(p);
  CHECK(field(t,1)==1 && field(t,2)==255); t=wait_exit(alias); CHECK(field(t,2)==255);
  CHECK(field(mdk_process_dispose(p),0)==MDK_TAG_OK); CHECK(field(mdk_process_dispose(alias),0)==MDK_TAG_OK);
  CHECK(error_code(mdk_process_poll_exit(alias))==8);
  p=shell("kill -TERM $$",0); t=wait_exit(p); CHECK(field(t,1)==3 && field(t,2)==31);
  CHECK(field(mdk_process_dispose(p),0)==MDK_TAG_OK);
  CHECK(mdk_process_test_roots()==0);
  p=shell("read x; exit 23",1); alias=p; CHECK(mdk_process_test_roots()==1);
  CHECK(mdk_process_test_abort(p)==5);
  CHECK(field(mdk_process_poll_exit(p),1)==(MDK_TAG_NONE << 1 | 1));
  CHECK(error_code(mdk_process_dispose(p))==9);
  CHECK(mdk_process_test_flags(p,0) & O_NONBLOCK);
  GC_gcollect(); int oldfd=mdk_process_test_fd(p,0);
  CHECK(field(mdk_process_close_stdin(alias),0)==MDK_TAG_OK);
  int replacement=open("/dev/null",O_RDONLY); CHECK(replacement>=0);
  if (replacement!=oldfd) { CHECK(dup2(replacement,oldfd)==oldfd); close(replacement); }
  CHECK(field(mdk_process_close_stdin(p),0)==MDK_TAG_OK);
  CHECK(fcntl(oldfd,F_GETFD)>=0); close(oldfd);
  t=wait_exit(p); CHECK(field(t,2)==47); CHECK(field(mdk_process_dispose(p),0)==MDK_TAG_OK);
  CHECK(mdk_process_test_roots()==0);
  long long env = cons(pair(str("MDK_CHILD"),str("value")),nil());
  long long args = cons(str("-c"),cons(str("test \"$1\" = 'arg value' && test \"$PWD\" = /tmp && test \"$MDK_CHILD\" = value && test -z \"$HOME\""),cons(str("marker"),cons(str("arg value"),nil()))));
  long long rr = start("/bin/sh",args,"/tmp",env,0); CHECK(field(rr,0)==MDK_TAG_OK); p=field(rr,1);
  t=wait_exit(p); CHECK(field(t,2)==1); CHECK(field(mdk_process_dispose(p),0)==MDK_TAG_OK);
  CHECK(error_code(start("/bin/true",nil(),"/tmp",cons(pair(str("A"),str("1")),cons(pair(str("A"),str("2")),nil())),0))==0);
  CHECK(error_code(start("/bin/true",nil(),"/tmp",cons(pair(str("A=B"),str("1")),nil()),0))==0);
  int extra=open("/dev/null",O_RDONLY); CHECK(extra>=0); int marker=fcntl(extra,F_DUPFD,100); close(extra); CHECK(marker>=100);
  char command[128]; snprintf(command,sizeof command,"test ! -e /proc/self/fd/%d",marker);
  p=shell(command,0); t=wait_exit(p); CHECK(field(t,2)==1); CHECK(field(mdk_process_dispose(p),0)==MDK_TAG_OK); close(marker);
  long long all_pipes=mdk_process_start(str("/bin/true"),nil(),str("/tmp"),nil(),1,1,1);
  CHECK(field(all_pipes,0)==MDK_TAG_OK); p=field(all_pipes,1);
  for (int i=0;i<3;++i) CHECK(mdk_process_test_flags(p,i)&O_NONBLOCK);
  t=wait_exit(p); CHECK(field(t,2)==1); CHECK(field(mdk_process_dispose(p),0)==MDK_TAG_OK);
  p=shell("exit 4",0); int stolen; CHECK(waitpid(-1,&stolen,0)>0);
  CHECK(error_code(mdk_process_poll_exit(p))==5); CHECK(error_code(mdk_process_dispose(p))==5);
  CHECK(field(mdk_process_dispose(p),0)==MDK_TAG_OK);
  int gate[2], ready[2]; CHECK(pipe2(gate,O_CLOEXEC)==0 && pipe2(ready,O_CLOEXEC)==0);
  long long ticket=mdk_process_test_begin(gate[0],ready[1]); CHECK(ticket != 0);
  char byte; CHECK(read(ready[0],&byte,1)==1);
  int step=0; for (int i=0;i<10000 && step==0;++i) { step=mdk_process_test_abort(ticket); usleep(1000); }
  CHECK(step==3); CHECK(mdk_process_test_abort(ticket)==3);
  close(gate[0]); close(gate[1]); close(ready[0]); close(ready[1]);
  int stop=0; pthread_t gc_thread; CHECK(GC_pthread_create(&gc_thread,NULL,collect_loop,&stop)==0);
  for (int i=0;i<20;++i) { p=must_start("/bin/true",nil(),0); t=wait_exit(p); CHECK(field(t,2)==1); CHECK(field(mdk_process_dispose(p),0)==MDK_TAG_OK); }
  __atomic_store_n(&stop,1,__ATOMIC_RELAXED); CHECK(GC_pthread_join(gc_thread,NULL)==0);
  pid_t other=fork(); CHECK(other>=0); if (!other) _exit(23);
  p=must_start("/bin/true",nil(),0); t=wait_exit(p); CHECK(field(t,2)==1);
  CHECK(field(mdk_process_dispose(p),0)==MDK_TAG_OK);
  int st; CHECK(waitpid(other,&st,0)==other && WIFEXITED(st) && WEXITSTATUS(st)==23);
  CHECK(checks>20); printf("owner checks: %d passed\n",checks); return 0;
}
