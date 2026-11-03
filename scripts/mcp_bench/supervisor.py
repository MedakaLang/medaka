"""Isolated Linux subreaper for one collector run."""
import ctypes
import json
import os
import signal
import subprocess
import sys


def clean_children():
    children = f'/proc/self/task/{os.getpid()}/children'
    while True:
        for pid in map(int, open(children, encoding='ascii').read().split()):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        try:
            os.waitpid(-1, 0)
        except ChildProcessError:
            return


def main():
    status_fd = int(sys.argv[1])
    timeout, cancel, command = json.loads(sys.argv[2])
    status = 'startup_failure'
    try:
        with open(f'/proc/self/task/{os.getpid()}/children', encoding='ascii') as children:
            children.read()
        ready = ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) == 0
    except OSError:
        ready = False
    if ready:
        try:
            worker = subprocess.Popen(command, stdin=subprocess.PIPE)
        except OSError:
            pass
        else:
            try:
                worker.communicate(sys.stdin.buffer.read(), timeout=timeout)
                status = worker.returncode
            except subprocess.TimeoutExpired:
                worker.kill()
                worker.communicate()
                status = 'cancelled' if cancel else 'timeout'
            finally:
                clean_children()
    os.write(status_fd, json.dumps(status).encode())


if __name__ == '__main__':
    main()
