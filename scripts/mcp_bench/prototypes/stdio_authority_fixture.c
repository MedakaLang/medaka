#define _GNU_SOURCE
#ifdef NDEBUG
#error "stdio controls require assertions"
#endif
#include <assert.h>
#include <sys/prctl.h>
#include <sys/vfs.h>
#define main embedded_runtime_main
#include "medaka_rt.c"
#undef main

/* These guards model a candidate; the included production runtime is unchanged.
   The inherited report descriptor is test instrumentation, never a protocol fd. */
static int report_fd, sealed, prior, active, mutation;
static int native_ready = -1, native_gate = -1, native_ack = -1, native_release = -1;
static _Atomic int cancelled;
extern void mdk_process_test_submit_hold(int, int, int);
static pthread_mutex_t admission = PTHREAD_MUTEX_INITIALIZER;
static long long field(long long w, int n) { return ((long long *)w)[n]; }
static int ok(long long w) { return field(w, 0) == MDK_TAG_OK; }
static void report(const char *name, int value, int error) {
  dprintf(report_fd, "{\"name\":\"%s\",\"value\":%d,\"errno\":%d}\n", name, value, error);
}
static int enter(void) {
  assert(pthread_mutex_lock(&admission) == 0);
  if (sealed && !mutation) { pthread_mutex_unlock(&admission); errno = EPERM; return 0; }
  prior = 1; ++active;
  assert(pthread_mutex_unlock(&admission) == 0);
  return 1;
}
static void leave(void) {
  assert(pthread_mutex_lock(&admission) == 0);
  --active;
  assert(pthread_mutex_unlock(&admission) == 0);
}
static int acquire(void) {
  if (pthread_mutex_trylock(&admission)) return 2;
  int result = active && !mutation ? 2 : prior && !mutation ? 3 : 0;
  if (!result) {
    struct stat in, out, err;
    struct statfs fs, output_fs;
    if (fstat(0, &in) || fstat(1, &out) || fstat(2, &err) || fstatfs(0, &fs) || fstatfs(1, &output_fs) ||
        !S_ISFIFO(in.st_mode) || !S_ISFIFO(out.st_mode) || fs.f_type != 0x50495045 || output_fs.f_type != 0x50495045 ||
        (in.st_dev == out.st_dev && in.st_ino == out.st_ino) ||
        (out.st_dev == err.st_dev && out.st_ino == err.st_ino) ||
        !(fcntl(0, F_GETFL) & O_NONBLOCK) || !(fcntl(1, F_GETFL) & O_NONBLOCK) ||
        (fcntl(0, F_GETFL) & O_ACCMODE) != O_RDONLY ||
        (fcntl(1, F_GETFL) & O_ACCMODE) != O_WRONLY || prctl(PR_GET_NO_NEW_PRIVS,0,0,0,0) != 1) result = 4;
    if (!result && prctl(PR_SET_DUMPABLE, 0)) result = 5;
    if (!result) sealed = 1;
  }
  pthread_mutex_unlock(&admission);
  return result;
}
static long long guarded(const char *op, const char *path) {
  if (!enter()) return mdk_err(mdk_str_cstr("E-STDIO-SEAL"));
  long long r;
  if (!strcmp(op, "write")) r = mdk_write_file(mdk_str_cstr(path), mdk_str_cstr("BYPASS"), mdk_nil());
  else if (!strcmp(op, "read")) r = mdk_read_file(mdk_str_cstr(path), mdk_nil());
  else if (!strcmp(op, "hash")) r = mdk_hash_file(mdk_str_cstr(path), mdk_nil());
  else if (!strcmp(op, "telemetry")) r = mdk_append_file_except_stdout(mdk_str_cstr(path), mdk_str_cstr("EVENT\n"), mdk_nil());
  else if (!strcmp(op, "resolver")) r = mdk_net_resolve(mdk_str_cstr(path));
  else if (!strcmp(op, "input")) { mdk_read_line(1); r = mdk_ok(1); }
  else {
    assert(!strcmp(op, "legacy"));
    r = mdk_run_command(mdk_str_cstr("/bin/sh"),
          mdk_cons(mdk_str_cstr("-c"), mdk_cons(mdk_str_cstr(path), mdk_nil())));
  }
  leave(); return r;
}
static int native(const char *script, const char *marker) {
  long long args = marker ? mdk_cons(mdk_str_cstr(marker),mdk_nil()) :
    mdk_cons(mdk_str_cstr("-c"), mdk_cons(mdk_str_cstr(script), mdk_nil()));
  long long r = mdk_process_submit(mdk_str_cstr(marker ? "/usr/bin/touch" : "/bin/sh"), args,
                                  mdk_str_cstr("/tmp"), mdk_nil(), 1, 1, 1);
  if (!ok(r)) { report("submit_error", (int)(field(field(r,1),1)>>1), (int)(field(field(r,1),2)>>1)); return 77; }
  long long ticket = field(r, 1), process = 0;
  if (native_ready >= 0) {
    char byte; assert(read(native_ack,&byte,1) == 1);
    report("native_ticket_accepted_held_before_create",1,0);
    assert(write(native_ready,"r",1) == 1); assert(read(native_gate,&byte,1) == 1);
    mdk_process_test_submit_hold(0,-1,-1); assert(write(native_release,"x",1) == 1);
  }
  for (int i = 0; i < 10000; ++i) {
    r = mdk_process_check_start(ticket);
    if (!ok(r)) { usleep(1000); continue; }
    long long row = field(r,1); int kind = (int)(field(row,1)>>1);
    if (kind == 1) { process = field(field(row,2),1); break; }
    if (kind == 2) {
      long long e = field(field(row,3),1);
      report("native_launch_unavailable", (int)(field(e,1)>>1), (int)(field(e,2)>>1));
      return 77;
    }
    usleep(1000);
  }
  assert(process);
  for (int i = 0; i < 10000; ++i) {
    r = mdk_process_poll_exit(process); assert(ok(r));
    if (!(field(r,1) & 1)) {
      assert(ok(mdk_process_dispose(process))); report("native_reaped_disposed", 1, 0); return 0;
    }
    usleep(1000);
  }
  report("native_cleanup_incomplete", 1, 0); return 78;
}
static void output(const char *kind) {
  if (!strcmp(kind, "buffered")) mdk_putstr(mdk_str_cstr("BUFFERED"));
  else if (!strcmp(kind, "raw")) {
    long long *bb = mdk_alloc(19); bb[0] = 0; bb[1] = 3;
    memcpy((char *)bb + 16, "\377\0R", 3); mdk_byteblock_write_stdout((long long)bb);
  } else if (!strcmp(kind, "automatic")) mdk_print_int(7);
  else {
    assert(!strcmp(kind, "abort"));
    mdk_enable_run_stdout_flush(1);
    mdk_stash_run_stdout(mdk_str_cstr("STASH"));
    mdk_panic(mdk_str_cstr("CONTROL"));
  }
}
typedef struct { const char *op, *path; int ready[2], gate[2]; } Flight;
static void *flight(void *arg) {
  Flight *f = arg;
  assert(enter());
  if (!strcmp(f->op, "native")) {
    int gate[2], ack[2]; assert(pipe(gate) == 0); assert(pipe(ack) == 0);
    native_ready=f->ready[1]; native_gate=f->gate[0]; native_ack=ack[0]; native_release=gate[1];
    mdk_process_test_submit_hold(1,gate[0],ack[1]); native(f->path,NULL);
    close(gate[0]); close(gate[1]); close(ack[0]); close(ack[1]);
  } else {
    assert(write(f->ready[1], "r", 1) == 1);
    char byte; assert(read(f->gate[0], &byte, 1) == 1);
    long long r = guarded(f->op, f->path); report("operation_ok", ok(r), 0);
  }
  report("cancel_requested_without_releasing_admission",atomic_load(&cancelled),0);
  leave(); return NULL;
}
static void parent_alias(int protect, const char *self) {
  if (protect) assert(prctl(PR_SET_DUMPABLE, 0) == 0);
  char parent[32]; snprintf(parent, sizeof parent, "%d", getpid());
  pid_t pid = fork(); assert(pid >= 0);
  if (!pid) {
    int null = open("/dev/null", O_RDWR); assert(null >= 0);
    for (int i = 0; i < 3; ++i) assert(dup2(null, i) == i);
    close(null);
    execl(self, self, "child", parent, (char *)NULL); _exit(91);
  }
  int status; assert(waitpid(pid, &status, 0) == pid);
  report("child_status", WIFEXITED(status) ? WEXITSTATUS(status) : -1, 0);
}
int main(int argc, char **argv) {
  assert(argc >= 3);
  if (!strcmp(argv[1], "child")) {
    char path[100]; snprintf(path, sizeof path, "/proc/%s/fd/1", argv[2]);
    int fd = open(path, O_WRONLY);
    if (fd < 0) return errno == EACCES || errno == EPERM ? 13 : 92;
    assert(write(fd, "CHILD", 5) == 5); close(fd); return 0;
  }
  report_fd = atoi(argv[2]); assert(argc >= 5);
  const char *mode = argv[1], *op = argv[3], *path = argv[4];
  mutation = argc > 5 && !strcmp(argv[5], "mutate");
  GC_INIT(); mdk_process_submission_init();
  if (!strcmp(mode, "parent")) { parent_alias(!mutation, argv[0]); return 0; }
  if (!strcmp(mode, "history")) {
    prior = 1;
    if (!strcmp(op,"native")) report("operation_rc", native(path,NULL), 0);
    else report("operation_ok", ok(guarded(op,path)), 0);
    report("acquire", acquire(), 0); return 0;
  }
  if (!strcmp(mode, "inflight")) {
    Flight f = {.op=op,.path=path}; assert(pipe(f.ready) == 0); assert(pipe(f.gate) == 0);
    pthread_t tid; assert(GC_pthread_create(&tid, NULL, flight, &f) == 0);
    char byte; assert(read(f.ready[0], &byte, 1) == 1);
    report("acquire_busy", acquire(), 0);
    atomic_store(&cancelled,1);
    report("cancel_does_not_release", acquire(), 0);
    assert(write(f.gate[1], "x", 1) == 1); assert(GC_pthread_join(tid,NULL) == 0);
    close(f.ready[0]); close(f.ready[1]); close(f.gate[0]); close(f.gate[1]);
    report("acquire_after", acquire(), 0); return 0;
  }
  if (!strcmp(mode, "sealed") || !strcmp(mode,"release") || !strcmp(mode,"work")) {
    int a = acquire(); report("acquire", a, 0); if (a) return 77;
  }
  if (!strcmp(mode, "release")) {
    report("release", 1, 0); report("reacquire", acquire(), 0);
  }
  if (!strcmp(mode, "work") || !strcmp(mode,"work-control")) {
    char target[PATH_MAX];
    snprintf(target,sizeof target,"%s/stdlib/core.mdk",path);
    report("read_source", ok(guarded("read",target)), 0);
    snprintf(target,sizeof target,"%s/compiler/medaka.toml",path);
    report("read_config", ok(guarded("read",target)), 0);
    report("select_toolchain_metadata", access("/usr/bin/clang", X_OK) == 0, 0);
    report("emit_telemetry", ok(guarded("telemetry",op)), 0);
    char scratch[PATH_MAX]; snprintf(scratch,sizeof scratch,"%s.scratch",op);
    int made = mkdir(scratch,0700) == 0; report("mkdir_scratch", made, made ? 0 : errno);
    snprintf(target,sizeof target,"%s.scratch/request",op);
    report("write_scratch", ok(guarded("write",target)), 0);
    char marker[PATH_MAX]; snprintf(marker,sizeof marker,"%s.worker",op);
    report("submit_worker_rc", native(NULL,marker), 0);
    if (made) { if (!sealed) assert(unlink(target) == 0); assert(rmdir(scratch) == 0); }
    return 0;
  }
  if (!strcmp(op,"replace")) {
    struct stat before, after; assert(fstat(1,&before) == 0);
    int saved = dup(1); assert(saved >= 0); int fd = open(path,O_WRONLY|O_CREAT|O_TRUNC,0600); assert(fd >= 0);
    assert(dup2(fd,1) == 1); close(fd); assert(fstat(1,&after) == 0);
    int same = before.st_dev == after.st_dev && before.st_ino == after.st_ino;
    report("identity_guard", same, 0);
    if (same || mutation) assert(write(1,"REPLACED",8) == 8);
    assert(dup2(saved,1) == 1); close(saved); return 0;
  }
  if (!strcmp(op,"output")) {
    if (sealed && !mutation) { report("output_denied",1,EPERM); return 0; }
    output(path); return 0;
  }
  if (!strcmp(op,"input")) {
    if (sealed && !mutation) { report("input_denied",1,EPERM); return 0; }
    mdk_read_line(1); report("buffered_read",1,0); return 0;
  }
  if (!strcmp(op,"native")) { report("operation_rc",native(path,NULL),0); return 0; }
  report("operation_ok", ok(guarded(op,path)), 0);
  return 0;
}
