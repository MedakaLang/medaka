"""Exercise optional startup with standalone, archive, cached and installed runtime links."""
import os
from pathlib import Path
import subprocess
import sys
import tarfile

root, scratch = map(Path, sys.argv[1:])
environment = {**os.environ, "GC_MARKERS": "1", "MEDAKA_STRICT": "1"}
cc = ["clang", "-DMDK_PROCESS_TESTING", "-std=gnu11", "-O0", "-pthread", f"-I{root / 'runtime'}"]
fixtures = root / "test/process_runtime_fixtures"

trace_source = scratch / "threads.c"
trace_source.write_text(r"""
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
int pthread_create(pthread_t *thread, const pthread_attr_t *attr,
                   void *(*entry)(void *), void *arg) {
  size_t stack = 0;
  if (attr) pthread_attr_getstacksize(attr, &stack);
  FILE *log = fopen(getenv("MDK_THREAD_TRACE"), "a");
  if (!log) abort();
  fprintf(log, "%zu\n", stack);
  fclose(log);
  int (*real_create)(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *) =
    dlsym(RTLD_NEXT, "pthread_create");
  return real_create(thread, attr, entry, arg);
}
""")


def run(args, marker=None, env=environment, cwd=scratch):
    result = subprocess.run(list(map(str, args)), env=env, cwd=cwd,
                            capture_output=True, text=True, timeout=180)
    assert result.returncode == 0, (args, result.returncode, result.stdout, result.stderr)
    if marker is not None:
        assert marker in result.stdout.splitlines(), (args, result.stdout, result.stderr)
    return result.stdout


trace_library = scratch / "threads.so"
run(["clang", "-shared", "-fPIC", trace_source, "-ldl", "-o", trace_library])


def startup(binary, process_used, marker=None, env=environment, cwd=scratch):
    trace = scratch / "threads.log"
    trace.unlink(missing_ok=True)
    run([binary], marker, {**env, "LD_PRELOAD": str(trace_library),
                          "MDK_THREAD_TRACE": str(trace)}, cwd)
    stacks = list(map(int, trace.read_text().splitlines()))
    expected = ([512 * 1024] if process_used else []) + [256 * 1024 * 1024]
    assert stacks == expected, (binary, stacks, expected)
    symbols = run(["nm", binary])
    defined_worker = any("submission_worker" in line and " U " not in line
                         for line in symbols.splitlines())
    assert defined_worker == process_used, (binary, defined_worker, process_used)


runtime, process, probe = (scratch / name for name in ("runtime.o", "process.o", "probe.o"))
run([*cc, "-c", root / "runtime/medaka_rt.c", "-o", runtime])
run([*cc, "-c", root / "runtime/medaka_process.c", "-o", process])
run([*cc, "-c", fixtures / "submission_startup.c", "-o", probe])
stub = scratch / "standalone.c"
stub.write_text("int mdk_program_main(int argc,char **argv) {(void)argc;(void)argv;return 0;}\n")
run([*cc, runtime, stub, "-lgc", "-lm", "-o", scratch / "standalone"])
startup(scratch / "standalone", False)
run([*cc, runtime, process, probe, "-lgc", "-lm", "-o", scratch / "linked"])
startup(scratch / "linked", True, "linked process worker startup passed")
archive = scratch / "libprocess.a"
run(["ar", "rcs", archive, process])
run([*cc, runtime, probe, archive, "-lgc", "-lm", "-o", scratch / "archived"])
startup(scratch / "archived", True, "linked process worker startup passed")
run([*cc, runtime, stub, archive, "-lgc", "-lm", "-o", scratch / "unused-archive"])
startup(scratch / "unused-archive", False)
mutated = scratch / "missing-hook.c"
runtime_source = (root / "runtime/medaka_rt.c").read_text()
hook = "  if (mdk_process_submission_init) mdk_process_submission_init();"
assert runtime_source.count(hook) == 1
mutated.write_text(runtime_source.replace(hook, "  (void)0;"))
run([*cc, mutated, process, probe, "-lgc", "-lm", "-o", scratch / "missing-hook"])
result = subprocess.run([scratch / "missing-hook"], env=environment, timeout=15)
assert result.returncode == 7, result
print("missing-hook defect rejected before the first process API call")
run([*cc, "-U__linux__", "-c", root / "runtime/medaka_process.c", "-o", scratch / "unsupported.o"])
run([*cc, "-DMDK_SUBMIT_UNSUPPORTED", runtime, scratch / "unsupported.o",
     fixtures / "submission_startup.c", "-lgc", "-lm", "-o", scratch / "unsupported"])
run([scratch / "unsupported"], "unsupported submission refuses without a worker passed")
print("standalone, direct, archive and unsupported runtime startup passed")

compiler = root / "medaka"
source = fixtures / "submission_typed.mdk"
indirect = scratch / "indirect.mdk"
indirect.write_text(source.read_text().replace(
    'launch _ = submit "/bin/true" options',
    'launch _ = apply (submit "/bin/true") options\n\napply f value = f value'))
ordinary = scratch / "ordinary.mdk"
ordinary.write_text('main = println "ordinary native passed"\n')
explicit = scratch / "explicit.o"
run([compiler, "build", "--emit-rt-obj", explicit])
for name, variables in [
    ("inline", {"MEDAKA_NO_OBJ_CACHE": "1", "MEDAKA_RT_OBJ": ""}),
    ("explicit", {"MEDAKA_NO_OBJ_CACHE": "", "MEDAKA_RT_OBJ": str(explicit)}),
    ("cache-first", {"MEDAKA_NO_OBJ_CACHE": "", "MEDAKA_RT_OBJ": ""}),
    ("cache-hit", {"MEDAKA_NO_OBJ_CACHE": "", "MEDAKA_RT_OBJ": ""}),
]:
    env = {**environment, "MEDAKA_CACHE_DIR": str(scratch / "cache"), **variables}
    for kind, input_source, process_used, marker in [
        ("direct", source, True, "submitted native passed"),
        ("indirect", indirect, True, "submitted native passed"),
        ("ordinary", ordinary, False, "ordinary native passed"),
    ]:
        binary = scratch / f"{name}-{kind}"
        run([compiler, "build", input_source, "-o", binary], env=env)
        startup(binary, process_used, marker, env)
assert list((scratch / "cache").rglob("rt-*.o")), "runtime object cache never filled"
print("inline, explicit runtime object, cache fill and cache hit submission passed")

tarball = Path(run(["sh", root / "scripts/make_dist.sh", scratch / "dist"]).strip())
install = scratch / "install"
install.mkdir()
with tarfile.open(tarball) as package:
    package.extractall(install, filter="data")
trees = [path for path in install.iterdir() if path.is_dir()]
assert len(trees) == 1, trees
installed = trees[0]
outside = scratch / "outside"
outside.mkdir()
(outside / "submitted.mdk").write_text(source.read_text())
installed_env = dict(environment)
for key in ("MEDAKA_ROOT", "MEDAKA_EMITTER", "MEDAKA_RT_OBJ", "MEDAKA_CACHE_DIR"):
    installed_env.pop(key, None)
run([installed / "medaka", "build", "submitted.mdk", "-o", "submitted"],
    env=installed_env, cwd=outside)
startup(outside / "submitted", True, "submitted native passed", installed_env, outside)
(outside / "ordinary.mdk").write_text(ordinary.read_text())
run([installed / "medaka", "build", "ordinary.mdk", "-o", "ordinary"],
    env=installed_env, cwd=outside)
startup(outside / "ordinary", False, "ordinary native passed", installed_env, outside)
print("installed compiler builds and starts submitted worker outside the source tree passed")
print("submission linkage controls passed")
