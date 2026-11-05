#!/usr/bin/env python3
import os
import re
import resource
import subprocess
import sys
import time

binary, shim = sys.argv[1:]
env = dict(os.environ, LD_PRELOAD=shim, GC_MARKERS="1")
before = resource.getrusage(resource.RUSAGE_CHILDREN)
start = time.monotonic()
proc = subprocess.Popen([binary], env=env, text=True, stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE)
try:
    out, err = proc.communicate(timeout=15)
except subprocess.TimeoutExpired:
    proc.kill()
    proc.communicate()
    raise RuntimeError("idle fixture exceeded 15 seconds")
elapsed = time.monotonic() - start
after = resource.getrusage(resource.RUSAGE_CHILDREN)
cpu = after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime
match = re.search(rf"fairness polls pid={proc.pid} count=(\d+)", err)
if proc.returncode != 0 or "idle sessions=12 passed" not in out or not match:
    raise RuntimeError(f"idle fixture failed: {proc.returncode} {out} {err}")
polls = int(match.group(1))
if not (12 <= polls <= 1000 and cpu < 2 and elapsed < 15):
    raise RuntimeError(f"idle bounds failed: polls={polls} cpu={cpu} elapsed={elapsed}")
print(f"idle sessions=12 polls={polls} cpu_seconds={cpu:.3f} elapsed_seconds={elapsed:.3f} passed")
