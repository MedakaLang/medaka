"""Compile isolated runtime defects and require the owner/collector controls to reject them."""
import os
from pathlib import Path
import subprocess
import sys

root, scratch = map(Path, sys.argv[1:])
source = (root / "runtime/medaka_process.c").read_text()
mutations = [
    ("owner-root", "  root(p);\n  atomic_store_explicit(&q->phase, SUBMISSION_QUEUED",
     "  ;\n  atomic_store_explicit(&q->phase, SUBMISSION_QUEUED", [],
     "mdk_process_test_roots()>=1"),
    ("gc-active", "else GC_do_blocking(construct_native, &q->launch);",
     "else construct_native(&q->launch);", ["gc"], "elapsed<0.15"),
    ("pipe-slot", "close_once(&fd[1]); errno = e; return -1;",
     "close(fd[1]); errno = e; return -1;", [], "pipefds[0]==-1 && pipefds[1]==-1"),
]
for name, before, after, args, marker in mutations:
    assert source.count(before) == 1, (name, source.count(before))
    unit, binary = scratch / f"{name}.c", scratch / name
    unit.write_text(source.replace(before, after))
    subprocess.run([
        "clang", "-DMDK_PROCESS_TESTING", "-std=gnu11", "-O0", "-pthread",
        f"-I{root / 'runtime'}", str(root / "runtime/medaka_rt.c"), str(unit),
        str(root / "test/process_runtime_fixtures/submission.c"), "-lgc", "-lm",
        "-o", str(binary),
    ], check=True, capture_output=True, text=True)
    result = subprocess.run([str(binary), *args], capture_output=True, text=True,
                            env={**os.environ, "GC_MARKERS": "1"}, timeout=40)
    assert result.returncode != 0 and marker in result.stderr, (name, result)
    print(f"{name} defect rejected: {result.stderr.strip()}")
print("submission mutation controls passed")
