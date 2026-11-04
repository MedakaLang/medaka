#!/usr/bin/env python3
"""Independent POSIX pipe/Linux ownership controls, not a Medaka supervisor."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time
OUT = None
ROWS = []

def record(name, **values):
    row = dict(name=name, status='PASS')
    row.update(values)
    ROWS.append(row)
    (OUT / 'readiness.json').write_text(json.dumps(ROWS, indent=2) + '\n')
    print(json.dumps(row), flush=True)

def pipe():
    """Reference-only fcntl setup; not an atomic production spawn primitive."""
    r, w = os.pipe()
    for fd in (r, w):
        os.set_blocking(fd, False)
        os.set_inheritable(fd, False)
    return (r, w)

def fill(fd):
    total = 0
    while True:
        try:
            total += os.write(fd, b'x' * 65536)
        except BlockingIOError:
            return total

def saturation():
    """One blocked OS write prevents all cooperative work on that thread."""
    r, w = pipe()
    try:
        cap = fill(w)
        poll = select.poll()
        poll.register(w, select.POLLOUT)
        assert poll.poll(0) == []
        start = time.monotonic()
        ticks = 0
        while time.monotonic() - start < 0.1:
            poll.poll(5)
            ticks += 1
        assert ticks > 5
        os.read(r, cap)
        assert poll.poll(30)
        n = os.write(w, b'y' * (cap * 2))
        assert 0 < n < cap * 2
        record('saturated_nonblocking_write', capacity=cap, partial_write=n, heartbeat_ticks=ticks, deadline_ms=round((time.monotonic() - start) * 1000))
        os.set_blocking(w, True)
        if n < cap:
            os.set_blocking(w, False)
            fill(w)
            os.set_blocking(w, True)
        p = subprocess.Popen([sys.executable, '-c', 'import os,sys; os.write(int(sys.argv[1]),b"z"); print("unexpected",flush=True)', str(w)], pass_fds=(w,), stdout=subprocess.PIPE)
        try:
            p.communicate(timeout=0.12)
            raise AssertionError('blocking negative failed to block')
        except subprocess.TimeoutExpired:
            p.kill()
            out, _ = p.communicate()
            assert out == b''
            record('blocking_write_negative', observed='120ms timeout, no heartbeat/progress', child_rc=p.returncode)
    finally:
        os.close(r)
        os.close(w)

def duplex():
    """Input-first service stalls when the child's error pipe fills first."""
    probe_r, probe_w = pipe()
    try:
        amount = 2 * fill(probe_w)
    finally:
        os.close(probe_r)
        os.close(probe_w)
    child = '''import os
import sys
amount = int(sys.argv[1])
os.write(2, b'e' * amount)
n = 0
while n < amount:
    b = os.read(0, 16384)
    if not b:
        break
    assert b == b'i' * len(b)
    n += len(b)
os.write(1, str(n).encode())
'''
    p = subprocess.Popen([sys.executable, '-c', child, str(amount)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        for f in (p.stdin, p.stdout, p.stderr):
            os.set_blocking(f.fileno(), False)
        sent = 0
        outs = {p.stdout.fileno(): bytearray(), p.stderr.fileno(): bytearray()}
        poll = select.poll()
        poll.register(p.stdin.fileno(), select.POLLOUT)
        for fd in outs:
            poll.register(fd, select.POLLIN)
        live = set(outs)
        start = time.monotonic()
        rounds = 0
        while live or p.poll() is None:
            assert time.monotonic() - start < 3
            rounds += 1
            for fd, re in poll.poll(10):
                if p.stdin is not None and fd == p.stdin.fileno():
                    try:
                        sent += os.write(fd, b'i' * min(16384, amount - sent))
                    except BlockingIOError:
                        pass
                    if sent == amount:
                        poll.unregister(fd)
                        p.stdin.close()
                        p.stdin = None
                else:
                    try:
                        b = os.read(fd, 16384)
                    except BlockingIOError:
                        continue
                    if b:
                        outs[fd].extend(b)
                    else:
                        poll.unregister(fd)
                        live.remove(fd)
        assert p.wait(timeout=1) == 0 and sent == amount
        assert bytes(outs[p.stdout.fileno()]) == str(amount).encode()
        assert bytes(outs[p.stderr.fileno()]) == b'e' * amount
        record('concurrent_stdin_stdout_stderr', sent=sent, stderr_bytes=amount, stdout=str(amount), rounds=rounds)
    finally:
        if p.poll() is None:
            p.kill()
            p.wait()
        for f in (p.stdin, p.stdout, p.stderr):
            if f:
                f.close()
    p = subprocess.Popen([sys.executable, '-c', child, str(amount)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    writer = '''import os, sys
n = 0
amount = int(sys.argv[2])
while n < amount:
    n += os.write(int(sys.argv[1]), b'i' * (amount - n))
'''
    q = subprocess.Popen([sys.executable, '-c', writer, str(p.stdin.fileno()), str(amount)], pass_fds=(p.stdin.fileno(),))
    try:
        try:
            q.wait(timeout=0.12)
            raise AssertionError('sequential control did not stall')
        except subprocess.TimeoutExpired:
            record('sequential_duplex_negative', observed='input writer stalls >=120ms while stderr full')
    finally:
        q.kill()
        q.wait()
        p.kill()
        p.wait()
        p.stdin.close()
        p.stdout.close()
        p.stderr.close()

def exit_and_reuse():
    """A descriptor number or HUP is not an owner check or an empty stream."""
    r, w = pipe()
    try:
        try:
            os.read(r, 1)
            raise AssertionError('empty open pipe is not EOF')
        except BlockingIOError:
            pass
        os.write(w, b'last')
        os.close(w)
        w = -1
        po = select.poll()
        po.register(r, select.POLLIN)
        re = po.poll(20)[0][1]
        assert re & select.POLLHUP
        assert os.read(r, 100) == b'last' and os.read(r, 1) == b''
        record('exit_drain', poll_mask=re, bytes_before_eof='last', empty_open='EAGAIN')
    finally:
        os.close(r)
        if w >= 0:
            os.close(w)
    r, w = pipe()
    old = r
    snapshot_generation = 1
    current_generation = 2
    os.close(r)
    r2, w2 = pipe()
    if r2 != old:
        os.dup2(r2, old)
        os.close(r2)
        r2 = old
    try:
        os.write(w2, b'UNRELATED')
        po = select.poll()
        po.register(old, select.POLLIN)
        assert po.poll(0)
        guarded = 'Closed' if current_generation != snapshot_generation else os.read(old, 99).decode()
        assert guarded == 'Closed'
        naive = os.read(old, 99).decode()
        assert naive == 'UNRELATED'
        record('fd_reuse', reused_fd=old, owner_check=guarded, naive_retry_consumed=naive)
    finally:
        os.close(w)
        os.close(r2)
        os.close(w2)

def cancellation():
    """An external cancellation needs a wake; dup shares the parent's flags."""
    r, w = pipe()
    cr, cw = pipe()
    try:
        pid = os.fork()
        if pid == 0:
            time.sleep(0.04)
            os.write(cw, b'c')
            os._exit(0)
        po = select.poll()
        po.register(r, select.POLLIN)
        po.register(cr, select.POLLIN)
        start = time.monotonic()
        event = po.poll(220)
        elapsed = (time.monotonic() - start) * 1000
        os.waitpid(pid, 0)
        assert event and event[0][0] == cr and (elapsed < 180)
        record('external_cancel_wake_pipe', elapsed_ms=round(elapsed), data_pipe_idle=True)
        start = time.monotonic()
        po = select.poll()
        po.register(r, select.POLLIN)
        assert po.poll(120) == []
        elapsed = (time.monotonic() - start) * 1000
        assert elapsed >= 100
        record('cancel_flag_without_wake_negative', latency_ms=round(elapsed), observed='cannot observe external cancellation until poll timeout')
    finally:
        for fd in (r, w, cr, cw):
            os.close(fd)
    code = 'import os,signal; signal.signal(signal.SIGPIPE,signal.SIG_DFL);r,w=os.pipe();os.close(r);os.write(w,b"x")'
    p = subprocess.run([sys.executable, '-c', code], capture_output=True)
    assert p.returncode == -signal.SIGPIPE
    record('sigpipe_negative', returncode=p.returncode)
    r, w = pipe()
    dup = os.dup(r)
    try:
        os.set_blocking(dup, True)
        assert os.get_blocking(r)
        record('stdio_dup_flag_negative', dup_changes_original_open_file_description=True)
    finally:
        for fd in (r, w, dup):
            os.close(fd)

class OwnedChildren:
    """Keep exact owned pidfds; failure cleanup never scans or signals by reuse."""

    def __init__(self):
        self.handles = {}

    def add(self, pid):
        self.handles[pid] = os.pidfd_open(pid)
        return pid

    def fork(self, action):
        pid = os.fork()
        if pid == 0:
            try:
                signal.alarm(5)
                action()
            except BaseException:
                os._exit(101)
            os._exit(0)
        return self.add(pid)

    def wait(self, pid):
        _, status = os.waitpid(pid, 0)
        os.close(self.handles.pop(pid))
        return os.waitstatus_to_exitcode(status)

    def kill(self, pid):
        try:
            signal.pidfd_send_signal(self.handles[pid], signal.SIGKILL)
        except ProcessLookupError:
            pass

    def close(self):
        for pid in self.handles:
            self.kill(pid)
        for pid in list(self.handles):
            self.wait(pid)


def pause():
    while True:
        signal.pause()


def descendants():
    """setsid escapes a group; subreaping preserves waits, not containment."""
    owned = OwnedChildren()
    r, w = pipe()
    release_r, release_w = os.pipe()

    def unrelated_child():
        os.close(release_w)
        os.read(release_r, 1)
        os._exit(23)

    def group_worker():
        os.setsid()
        if os.fork() == 0:
            signal.alarm(5)
            os.setsid()
            os.write(w, str(os.getpid()).encode() + b'\n')
        pause()

    try:
        unrelated = owned.fork(unrelated_child)
        worker = owned.fork(group_worker)
        po = select.poll()
        po.register(r, select.POLLIN)
        assert po.poll(1000)
        descendant = owned.add(int(os.read(r, 100)))
        pidfd = owned.handles[descendant]
        os.killpg(worker, signal.SIGKILL)
        assert owned.wait(worker) == -signal.SIGKILL
        pidpoll = select.poll()
        pidpoll.register(pidfd, select.POLLIN)
        assert pidpoll.poll(40) == []
        os.close(w)
        w = -1
        assert po.poll(40) == []
        signal.pidfd_send_signal(pidfd, signal.SIGKILL)
        assert pidpoll.poll(1000)
        assert owned.wait(descendant) == -signal.SIGKILL
        os.write(release_w, b'x')
        assert owned.wait(unrelated) == 23
        record('escaped_descendant', group_kill_left_setsid_descendant_alive=True, direct_child_exit_not_pipe_eof=True, subreaper_did_not_kill=True, explicit_owned_pidfd_cleanup=True, unrelated_child_exit=23)
    finally:
        owned.close()
        os.close(r)
        if w >= 0:
            os.close(w)
        os.close(release_r)
        os.close(release_w)

def fail_before_spawn():
    """Dispatch model only: a real protected-broker positive remains blocked."""
    launches = []

    def target():
        launches.append(True)
        return 'Spawned'

    def start_owned(broker, spawn):
        if broker is None:
            return 'UnsupportedContainment'
        return spawn()
    verdict = start_owned(None, target)
    assert verdict == 'UnsupportedContainment' and launches == []
    assert start_owned(object(), target) == 'Spawned' and launches == [True]
    record('fail_before_spawn', verdict=verdict, spawn_callback_calls=0, control_callback_calls=1, model_only=True)

def authority():
    """Observe authority without writing kill/procs in a populated host scope."""
    if sys.platform != 'linux':
        record('containment_authority', status='BLOCKED', reason='cgroup-v2 broker requires Linux; macOS acceptance is deferred')
        return
    cgroup = Path('/sys/fs/cgroup')
    own = next((x.split('::', 1)[1] for x in Path('/proc/self/cgroup').read_text().splitlines() if x.startswith('0::')), None)
    if own is None or not (cgroup / 'cgroup.controllers').exists():
        record('containment_authority', status='BLOCKED', reason='cgroup v2 unified hierarchy unavailable')
        return
    if '..' in Path(own).parts:
        record('containment_authority', status='BLOCKED', reason='own cgroup is outside visible mount root')
        return
    current = cgroup / own.lstrip('/')
    checks = dict(uid=os.getuid(), cgroup=own, kill_file=(current / 'cgroup.kill').exists(), controllers=(cgroup / 'cgroup.controllers').read_text().strip(), readonly_mount=bool(os.statvfs(cgroup).f_flag & os.ST_RDONLY))
    try:
        trial = current / ('medaka-spike-' + str(os.getpid()))
        trial.mkdir()
        trial.rmdir()
        checks['create_owned_subgroup'] = 'available'
    except OSError as e:
        checks['create_owned_subgroup'] = dict(errno=e.errno, message=e.strerror)
    record('host_cgroup_authority', **checks)
    code = '''import json
import os
from pathlib import Path
result = {'uid': os.getuid()}
if os.getuid() == 0:
    try:
        os.setgroups([])
        os.setgid(65534)
        os.setuid(65534)
        result['uid'] = os.getuid()
    except OSError as e:
        result['ordinary_user_blocker'] = {'errno': e.errno, 'message': e.strerror}
        print(json.dumps(result))
        raise SystemExit(0)
own = next(x.split('::', 1)[1] for x in Path('/proc/self/cgroup').read_text().splitlines() if x.startswith('0::'))
p = Path('/sys/fs/cgroup') / own.lstrip('/') / ('medaka-user-spike-' + str(os.getpid()))
try:
    p.mkdir()
    p.rmdir()
    result['mkdir'] = 'available'
except OSError as e:
    result['mkdir'] = {'errno': e.errno, 'message': e.strerror}
print(json.dumps(result))
'''
    p = subprocess.run([sys.executable, '-c', code], capture_output=True, text=True, timeout=3)
    assert p.returncode == 0, p.stderr
    ordinary = json.loads(p.stdout)
    record('ordinary_user_authority', status='BLOCKED' if 'ordinary_user_blocker' in ordinary else 'OBSERVED', **ordinary)
    record('protected_broker_positive', status='BLOCKED', reason='No protected delegated broker or positive cgroup/death/escape proof; writable cgroups alone are insufficient')

def supervisor_death():
    """PDEATHSIG is cleared at fork, so it cannot own the grandchild tree."""
    owned = OwnedChildren()
    r, w = pipe()

    def supervisor_action():
        child = os.fork()
        if child == 0:
            libc = ctypes.CDLL(None, use_errno=True)
            assert libc.prctl(1, signal.SIGKILL, 0, 0, 0) == 0
            grandchild = os.fork()
            if grandchild == 0:
                signal.alarm(5)
                os.setsid()
                os.write(w, ('grandchild ' + str(os.getpid()) + '\n').encode())
                pause()
            os.write(w, ('child ' + str(os.getpid()) + '\n').encode())
        pause()

    try:
        supervisor = owned.fork(supervisor_action)
        po = select.poll()
        po.register(r, select.POLLIN)
        data = b''
        while data.count(b'\n') < 2:
            assert po.poll(1000)
            data += os.read(r, 200)
        ids = {name: owned.add(int(pid)) for name, pid in
               (line.split() for line in data.decode().splitlines())}
        childfd = owned.handles[ids['child']]
        grandfd = owned.handles[ids['grandchild']]
        owned.kill(supervisor)
        assert owned.wait(supervisor) == -signal.SIGKILL
        cp = select.poll()
        cp.register(childfd, select.POLLIN)
        assert cp.poll(1000)
        gp = select.poll()
        gp.register(grandfd, select.POLLIN)
        assert gp.poll(40) == []
        signal.pidfd_send_signal(grandfd, signal.SIGKILL)
        assert gp.poll(1000)
        assert owned.wait(ids['child']) == -signal.SIGKILL
        assert owned.wait(ids['grandchild']) == -signal.SIGKILL
        record('supervisor_death_pdeathsig_negative', direct_child_killed=True, grandchild_survived=True, explicit_owned_pidfd_cleanup=True)
    finally:
        owned.close()
        for fd in (r, w):
            os.close(fd)

def main():
    global OUT
    if not __debug__:
        raise RuntimeError('readiness controls require Python assertions enabled')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    OUT = args.out.resolve()
    root = Path(__file__).resolve().parents[3]
    if OUT == root or root in OUT.parents:
        parser.error('--out must be outside the checkout')
    OUT.mkdir(parents=True, exist_ok=True)
    if sys.platform not in ('linux', 'darwin'):
        record('platform', status='BLOCKED', reason='POSIX pipe reference supports Linux and macOS only')
        return
    saturation()
    duplex()
    exit_and_reuse()
    cancellation()
    fail_before_spawn()
    if sys.platform == 'linux' and hasattr(os, 'pidfd_open') and hasattr(signal, 'pidfd_send_signal'):
        libc = ctypes.CDLL(None, use_errno=True)
        # Linux PR_SET_CHILD_SUBREAPER is scoped to this reference process.
        if libc.prctl(36, 1, 0, 0, 0) == 0:
            try:
                self_fd = os.pidfd_open(os.getpid())
                try:
                    signal.pidfd_send_signal(self_fd, 0)
                finally:
                    os.close(self_fd)
            except OSError as error:
                record('linux_descendant_controls', status='BLOCKED', reason=str(error))
            else:
                descendants()
                supervisor_death()
        else:
            record('linux_descendant_controls', status='BLOCKED', reason='PR_SET_CHILD_SUBREAPER denied', errno=ctypes.get_errno())
    else:
        record('linux_descendant_controls', status='BLOCKED', reason='Linux prctl and Python pidfd support required; no portable strong substitute')
    authority()
    record('reference_complete', checks=len(ROWS))
if __name__ == '__main__':
    main()
