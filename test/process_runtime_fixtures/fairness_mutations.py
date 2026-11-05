#!/usr/bin/env python3
"""Check that the process assertions reject specific broken implementations."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

root, scratch = map(Path, sys.argv[1:])
compiler = root / "medaka"
env = dict(os.environ, MEDAKA_STRICT="1", MEDAKA_TEST_JOBS="1",
           MEDAKA_CODEGEN_JOBS="1", GC_MARKERS="1")


def run(args, expected, success):
    result = subprocess.run([str(x) for x in args], env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=45)
    matched = expected in result.stdout if success else any(
        "FAIL " in line and expected in line for line in result.stdout.splitlines())
    if (result.returncode == 0) != success or not matched:
        raise RuntimeError(f"{args}: exit {result.returncode}\n{result.stdout}")


def replace(path, old, new):
    source = path.read_text()
    if source.count(old) != 1:
        raise RuntimeError(f"mutation site missing or ambiguous: {path}")
    path.write_text(source.replace(old, new))


async_source = root / "stdlib/async.mdk"
process_source = root / "stdlib/process_async.mdk"
tests = scratch / "process_async_test.mdk"
shutil.copy(root / "stdlib/process_async_test.mdk", tests)
shutil.copy(async_source, scratch / "async.mdk")
shutil.copy(process_source, scratch / "process_async.mdk")
replace(scratch / "async.mdk", "stepTask (Suspend k) = k ()",
        "stepTask (Suspend k) = stepTask (k ())")
run([compiler, "check", tests], "yieldSteps", True)
run([compiler, "test", tests], "continuous writable progress yields to cancellation", False)
shutil.copy(async_source, scratch / "async.mdk")
replace(scratch / "process_async.mdk",
        "Ok (Some n) => go (offset + n)",
        "Ok (Some n) => go offset")
run([compiler, "check", tests], "yieldSteps", True)
run([compiler, "test", tests], "backpressured write returns its committed prefix", False)

native = scratch / "medaka_process.c"
shutil.copy(root / "runtime/medaka_process.c", native)
replace(native,
        "return p->launch_step == MDK_LAUNCH_OWNED && p->state != DISPOSED && p->streams[stream] >= 0;",
        "return 1;")
binary = scratch / "owner-mutant"
run(["clang", "-DMDK_PROCESS_TESTING", "-std=gnu11", "-O0", "-pthread",
     "-I" + str(root / "runtime"), root / "runtime/medaka_rt.c", native,
     root / "test/process_runtime_fixtures/pipe_io.c", "-lgc", "-lm", "-o", binary], "", True)
run([binary], "error_code(mdk_process_try_write", False)
print("fairness mutation controls passed")
