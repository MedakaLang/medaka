#define _POSIX_C_SOURCE 200809L
#ifdef NDEBUG
#error "process lifecycle controls require assertions enabled"
#endif
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <gc/gc.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

typedef struct Proc {
  struct Proc *next;
  pid_t pid;
  int in, out, state, status;
  uint64_t identity;
} Proc;
static Proc *owned;
static uint64_t next_identity;
enum { RUNNING, EXITED, DISPOSED, LOST_WAIT };
typedef struct { int stage, error; } SpawnError;

static int cloexec_pipe(int fds[2]) {
  if (pipe(fds)) return -1;
  if (fcntl(fds[0], F_SETFD, FD_CLOEXEC) < 0 || fcntl(fds[1], F_SETFD, FD_CLOEXEC) < 0) {
    int error = errno;
    close(fds[0]); close(fds[1]); errno = error; return -1;
  }
  return 0;
}

static int alive_fd(int fd) { return fcntl(fd, F_GETFD) >= 0; }
static int own_count(void) { int n=0; for (Proc *p=owned;p;p=p->next) ++n; return n; }
static void unlink_owner(Proc *p) {
  Proc **at=&owned;
  while (*at && *at!=p) at=&(*at)->next;
  assert(*at==p); *at=p->next; p->next=NULL;
}
static Proc *start(const char *program, char *const argv[], const char *cwd,
                   char *const env[], SpawnError *failure) {
  struct sigaction disposition;
  assert(sigaction(SIGCHLD,NULL,&disposition)==0);
  if (disposition.sa_handler!=SIG_DFL || (disposition.sa_flags & SA_NOCLDWAIT)) {
    failure->stage=4; failure->error=ECHILD; return NULL;
  }
  int input[2], output[2], error[2];
  assert(cloexec_pipe(input)==0); assert(cloexec_pipe(output)==0);
  assert(cloexec_pipe(error)==0);
  pid_t pid=fork(); assert(pid>=0);
  if (!pid) {
    close(error[0]); close(input[1]); close(output[0]);
    SpawnError e={1,0};
    if (dup2(input[0],0)<0 || dup2(output[1],1)<0) goto fail;
    close(input[0]); close(output[1]);
    if (cwd && chdir(cwd)) { e.stage=2; goto fail; }
    execve(program,argv,env); e.stage=3;
  fail:
    e.error=errno; assert(write(error[1],&e,sizeof e)==sizeof e); _exit(127);
  }
  close(error[1]); close(input[0]); close(output[1]);
  SpawnError e={0,0};
  ssize_t n; do n=read(error[0],&e,sizeof e); while(n<0 && errno==EINTR);
  close(error[0]);
  if (n) {
    assert(n==sizeof e); close(input[1]); close(output[0]);
    int status; assert(waitpid(pid,&status,0)==pid); *failure=e; return NULL;
  }
  Proc *p=GC_MALLOC(sizeof *p); assert(p);
  p->pid=pid; p->in=input[1]; p->out=output[0]; p->state=RUNNING;
  p->identity=++next_identity; p->next=owned; owned=p;
  return p;
}
static int poll_exit(Proc *p) {
  if (p->state==DISPOSED) return -1;
  if (p->state==EXITED) return 1;
  if (p->state==LOST_WAIT) return -2;
  pid_t r; do r=waitpid(p->pid,&p->status,WNOHANG); while(r<0 && errno==EINTR);
  if(r<0) { p->status=errno; p->pid=-1; p->state=LOST_WAIT; return -2; }
  assert(r==0 || r==p->pid);
  if (r) { p->state=EXITED; p->pid=-1; return 1; }
  return 0;
}
static void await_exit(Proc *p) {
  if(p->state==EXITED) return;
  assert(waitpid(p->pid,&p->status,0)==p->pid); p->pid=-1; p->state=EXITED;
}
static int close_stdin(Proc *p) {
  if(p->state==DISPOSED) return -1;
  if(p->in>=0) { int fd=p->in; p->in=-1; close(fd); }
  return 0;
}
static int dispose(Proc *p) {
  if(p->state==DISPOSED) return 0;
  int status=poll_exit(p);
  if(status==0) return 1;
  close_stdin(p);
  if(p->out>=0) { int fd=p->out; p->out=-1; close(fd); }
  p->state=DISPOSED; unlink_owner(p); return status==-2 ? -2 : 0;
}
static Proc *shell(const char *text) {
  char *argv[]={"/bin/sh","-c",(char *)text,NULL}; char *env[]={NULL}; SpawnError e;
  Proc *p=start("/bin/sh",argv,NULL,env,&e); assert(p); return p;
}
static void status_tests(void) {
  char *argv[]={"missing",NULL}; char *env[]={NULL}; SpawnError e;
  assert(!start("/no-such-medaka-spike-executable",argv,NULL,env,&e));
  assert(e.stage==3 && e.error==ENOENT);
  printf("spawn-missing: SpawnFailed Exec ENOENT=%d\n",e.error);
  Proc *p=shell("exit 127"); await_exit(p);
  assert(WIFEXITED(p->status) && WEXITSTATUS(p->status)==127);
  assert(poll_exit(p)==1 && poll_exit(p)==1);
  puts("exit-127: Exited 127; repeated poll cached"); assert(dispose(p)==0);
  p=shell("exit 143"); await_exit(p); assert(WIFEXITED(p->status) && WEXITSTATUS(p->status)==143);
  puts("exit-143: Exited 143"); assert(dispose(p)==0);
  p=shell("kill -TERM $$"); await_exit(p); assert(WIFSIGNALED(p->status) && WTERMSIG(p->status)==SIGTERM);
  puts("signal-term: Signalled 15"); assert(dispose(p)==0);
}
static void alias_tests(void) {
  Proc *p=shell("read value; exit 0"), *alias=p;
  assert(poll_exit(p)==0); assert(dispose(p)==1);
  assert(own_count()==1); GC_gcollect(); assert(own_count()==1);
  puts("running: poll=None dispose=StillRunning; explicit owner root survives GC");
  int old=p->in; assert(close_stdin(p)==0 && alias->in==-1);
  int replacement=open("/dev/null",O_WRONLY); assert(replacement>=0);
  if(replacement!=old) { assert(dup2(replacement,old)==old); close(replacement); replacement=old; }
  assert(close_stdin(alias)==0 && alive_fd(replacement));
  puts("alias-close: shared closed bit prevents stale close of reused fd");
  close(replacement); assert(!alive_fd(replacement));
  puts("raw-fd-control: stale close would close replacement descriptor");
  await_exit(p); assert(dispose(p)==0 && dispose(alias)==0);
  assert(poll_exit(alias)==-1 && own_count()==0 && alias->pid==-1);
  puts("disposed: alias poll=Closed; repeated dispose=Ok; pid invalidated; owned=0");
}
static void option_tests(void) {
  char *argv[]={"/bin/sh","-c","printf '%s|%s|%s' \"$PWD\" \"$SPIKE_ONLY\" \"${SPIKE_LEAK-unset}\"",NULL};
  char *env[]={"SPIKE_ONLY=explicit",NULL}; SpawnError e;
  assert(setenv("SPIKE_LEAK","ambient",1)==0);
  Proc *p=start("/bin/sh",argv,"/tmp",env,&e); assert(p); await_exit(p);
  char text[200]={0}; assert(read(p->out,text,sizeof text-1)>0);
  assert(!strcmp(text,"/tmp|explicit|unset")); printf("cwd-env: %s\n",text); assert(dispose(p)==0);
  assert(!start("/bin/sh",argv,"/missing-medaka-spike-dir",env,&e));
  assert(e.stage==2 && e.error==ENOENT); puts("cwd-missing: SpawnFailed Chdir ENOENT");
  assert(!start("sh",argv,"/tmp",env,&e));
  assert(e.stage==3 && e.error==ENOENT); puts("execve-control: bare sh does not use PATH");
}
static void wait_ownership_tests(void) {
  pid_t unrelated=fork(); assert(unrelated>=0);
  if(!unrelated) _exit(23);
  Proc *p=shell("exit 4"); await_exit(p); assert(dispose(p)==0);
  int status; assert(waitpid(unrelated,&status,0)==unrelated);
  assert(WIFEXITED(status) && WEXITSTATUS(status)==23);
  puts("wait-ownership: unrelated child still waitable, Exited 23");
  struct sigaction ignored={0}, old;
  ignored.sa_handler=SIG_IGN; sigemptyset(&ignored.sa_mask);
  assert(sigaction(SIGCHLD,&ignored,&old)==0);
  char *argv[]={"/bin/true",NULL}, *env[]={NULL}; SpawnError e;
  assert(!start("/bin/true",argv,NULL,env,&e) && e.stage==4 && e.error==ECHILD);
  assert(sigaction(SIGCHLD,&old,NULL)==0);
  puts("SIGCHLD-ignore: UnsupportedWaitOwnership before fork; no global disposition rewrite");
  struct sigaction no_wait={0};
  no_wait.sa_handler=SIG_DFL; no_wait.sa_flags=SA_NOCLDWAIT; sigemptyset(&no_wait.sa_mask);
  assert(sigaction(SIGCHLD,&no_wait,&old)==0);
  assert(!start("/bin/true",argv,NULL,env,&e) && e.stage==4 && e.error==ECHILD);
  assert(sigaction(SIGCHLD,&old,NULL)==0);
  puts("SIGCHLD-no-cldwait: UnsupportedWaitOwnership before fork");
  p=shell("exit 5"); assert(waitpid(p->pid,&status,0)==p->pid);
  assert(poll_exit(p)==-2 && p->status==ECHILD && p->pid==-1);
  assert(dispose(p)==-2 && dispose(p)==0 && own_count()==0);
  puts("external-reaper-control: WaitFailed ECHILD invalidates pid; dispose still closes resources");
}
static void allocation_test(void) {
  size_t n=100000; Proc **aliases=GC_MALLOC(n*sizeof *aliases);
  GC_gcollect(); size_t before=GC_get_total_bytes();
  for(size_t i=0;i<n;i++) { aliases[i]=GC_MALLOC(sizeof(Proc)); aliases[i]->state=DISPOSED; }
  size_t allocated=GC_get_total_bytes()-before;
  GC_gcollect(); assert(aliases[n-1]->state==DISPOSED);
  printf("allocation stable-pointer: n=%zu sizeof_owner=%zu GC_total_delta=%zu alias_array=%zu retained_owner_payload=%zu\n",
         n,sizeof(Proc),allocated,n*sizeof *aliases,n*sizeof(Proc));
  typedef struct { uint64_t generation; Proc owner; } Slot;
  Slot *slots=calloc(n,sizeof *slots); assert(slots);
  for(size_t i=0;i<n;i++) slots[i].generation=1;
  uint64_t stale=slots[0].generation; slots[0].generation++;
  assert(stale!=slots[0].generation);
  printf("allocation generation-table: n=%zu sizeof_slot=%zu native_calloc_bytes=%zu GC_owner_bytes=0 stale_generation_rejected=1 retained_after_close=%zu\n",
         n,sizeof(Slot),n*sizeof *slots,n*sizeof *slots);
  free(slots);
  memset(aliases,0,n*sizeof *aliases); GC_gcollect();
  printf("release stable-pointer: cleared_aliases=%zu owned=%d finalizer_calls=0; conservative-GC reclamation timing unproven\n",n,own_count());
}
int main(void) {
  alarm(20); GC_INIT();
  status_tests(); alias_tests(); option_tests(); wait_ownership_tests(); allocation_test();
  assert(own_count()==0); puts("lifecycle controls passed"); return 0;
}
