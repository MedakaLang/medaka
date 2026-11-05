"""Exercise the real Async adapter under the native owner's locked mutex."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

root, scratch = map(Path, sys.argv[1:])
compiler = root / "medaka"
fixture = root / "test/process_runtime_fixtures"
env = dict(os.environ, MEDAKA_STRICT="1", MEDAKA_CODEGEN_JOBS="1",
           MEDAKA_TEST_JOBS="1", JOBS="1", GC_MARKERS="1")

def run(args, variables=None):
    return subprocess.run(list(map(str, args)), env={**env, **(variables or {})},
                          text=True, capture_output=True, timeout=120)

def build(source, name):
    binary = scratch / name
    result = run([compiler, "check", source])
    assert result.returncode == 0, result.stderr
    result = run([compiler, "build", "--keep-ir", source, "-o", binary])
    assert result.returncode == 0, result.stderr
    result = run(["clang", "-DMDK_PROCESS_TESTING", "-std=gnu11", "-O0", "-pthread",
                  "-I" + str(root / "runtime"), str(binary) + ".ll",
                  root / "runtime/medaka_rt.c", root / "runtime/medaka_process.c",
                  fixture / "adapter_contention.c", "-lgc", "-lm", "-o", binary])
    assert result.returncode == 0, result.stderr
    return binary

binary = build(fixture / "adapter_contention.mdk", "contention")
for mode in ("eventual", "expiry", "cancel"):
    result = run([binary], {"CONTENTION_MODE": mode})
    assert result.returncode == 0 and "contention outcome passed" in result.stdout, (mode, result.stdout, result.stderr)
    assert "roots=0 permits=0 children=0" in result.stderr, result.stderr
    print(mode, "contention passed", result.stderr.strip())

shutil.copy(fixture / "adapter_contention.mdk", scratch / "adapter_contention.mdk")
source = (root / "stdlib/process_async.mdk").read_text()
old = "        Err ProcessBusy => deferThen (park deadline token []) (_ =>\n          startUntil program opts deadline token)\n"
assert source.count(old) == 1
(scratch / "process_async.mdk").write_text(source.replace(old, ""))
mutant = build(scratch / "adapter_contention.mdk", "broken-retry")
result = run([mutant], {"CONTENTION_MODE": "eventual"})
assert result.returncode == 0 and "contention outcome failed" in result.stdout, (result.stdout, result.stderr)
print("broken retry rejected by eventual-start assertion")
print("adapter contention controls passed")
