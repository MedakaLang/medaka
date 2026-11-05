#!/usr/bin/env python3
import os
from pathlib import Path
import re
import resource
import subprocess
import sys
import time

binary = sys.argv[1]

def rss(pid):
    try:
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    except (FileNotFoundError, ProcessLookupError):
        pass
    return 0

def children(pid):
    found = set()
    for task in Path(f"/proc/{pid}/task").glob("*/children"):
        try:
            found.update(map(int, task.read_text().split()))
        except FileNotFoundError:
            pass
    return found

def observe(leak=False):
    env = dict(os.environ, GC_MARKERS="1")
    if leak:
        env["FAIRNESS_LEAK"] = "1"
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    start = time.monotonic()
    proc = subprocess.Popen([binary], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    parent_peak = child_peak = samples = 0
    seen = set()
    try:
        while proc.poll() is None:
            if time.monotonic() - start > 15:
                raise RuntimeError("idle fixture exceeded 15 seconds")
            parent_peak = max(parent_peak, rss(proc.pid))
            current = children(proc.pid)
            seen.update(current)
            child_peak = max(child_peak, sum(rss(pid) for pid in current))
            samples += 1
            time.sleep(.005)
        out, err = proc.communicate(timeout=2)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.communicate()
    elapsed = time.monotonic() - start
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime
    match = re.search(rf"fairness polls pid={proc.pid} count=(\d+) allocation=(\d+) heap_before=(\d+) heap_after=(\d+) live_before=(\d+) live_after=(\d+) fds_before=(\d+) fds_after=(\d+) roots=(\d+) permits=(\d+)", err)
    if not match or (not leak and "idle sessions=12 passed" not in out):
        raise RuntimeError(f"idle fixture failed: {proc.returncode} {out} {err}")
    polls = int(match.group(1))
    if leak:
        if proc.returncode != 4 or match.group(7) == match.group(8):
            raise RuntimeError(f"leak control escaped: {proc.returncode} {err}")
        print("injected fd leak rejected by resource assertion")
        return
    if not (proc.returncode == 0 and 12 <= polls <= 1000 and cpu < 2 and elapsed < 15
            and samples > 0 and seen and 0 < parent_peak < 262144 and 0 < child_peak < 262144):
        raise RuntimeError(f"idle bounds failed: {proc.returncode} polls={polls} cpu={cpu} elapsed={elapsed} samples={samples} children={seen} parent={parent_peak} child={child_peak} {err}")
    print(f"idle sessions=12 {err.strip()} parent_peak_kib={parent_peak} child_tree_peak_kib={child_peak} child_pids={len(seen)} samples={samples} cpu_seconds={cpu:.3f} elapsed_seconds={elapsed:.3f} passed")

observe()
observe(leak=True)
