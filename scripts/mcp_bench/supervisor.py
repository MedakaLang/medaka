"""Linux cgroup authority and private PID-namespace init for one run."""
import ctypes
import json
import os
from pathlib import Path
import pwd
import secrets
import signal
import subprocess
import sys
import time
import uuid


class Unavailable(Exception):
    pass


class Boundary:
    def __init__(self):
        self.path = self.lease = None
        self.resources = None
        if sys.platform != 'linux' or os.geteuid() != 0:
            raise Unavailable('root cgroup and namespace authority required')
        try:
            current = Path('/sys/fs/cgroup') / Path('/proc/self/cgroup').read_text().strip().split('0::')[1].lstrip('/')
            parent = Path(os.environ.get('MEDAKA_MCP_CGROUP_PARENT', str(current))).resolve()
            if not parent.is_relative_to('/sys/fs/cgroup'):
                raise Unavailable('cgroup parent must be inside the cgroup mount')
            info = parent.stat()
            if info.st_uid != 0 or info.st_mode & 0o022:
                raise Unavailable('cgroup delegation must be private to the authority')
            path = parent / ('medaka-mcp-' + uuid.uuid4().hex)
            path.mkdir(mode=0o700)
            self.path = path
            (self.path / 'cgroup.kill').write_text('1')
            (self.path / 'cgroup.events').read_text()
            for _ in range(100):
                self.uid = 0x40000000 + secrets.randbelow(0x3fffffff)
                try:
                    pwd.getpwuid(self.uid)
                except KeyError:
                    lease = Path('/tmp') / f'medaka-mcp-uid-{self.uid}'
                    try:
                        lease.mkdir(mode=0o700)
                    except FileExistsError:
                        continue
                    self.lease = lease
                    break
            else:
                raise Unavailable('no private worker identity available')
        except (OSError, IndexError, Unavailable) as error:
            if self.path is not None:
                self.path.rmdir()
                self.path = None
            if self.lease is not None:
                self.lease.rmdir()
                self.lease = None
            raise Unavailable(str(error)) from error

    def close(self):
        if self.path is not None:
            if self.path.exists():
                (self.path / 'cgroup.kill').write_text('1')
                # populated=0 is the kernel acknowledgement, not a PID-list snapshot.
                while 'populated 1' in (self.path / 'cgroup.events').read_text():
                    time.sleep(.01)
                self.resources = self.measure()
                self.path.rmdir()
            self.path = None
        if self.lease is not None:
            self.lease.rmdir()
            self.lease = None

    def measure(self):
        """Read cumulative cgroup counters before removal, including exited members."""
        result = {'scope': 'private cgroup: supervisor, namespace init, worker and descendants; excludes collector',
                  'cpu_ns': None, 'peak_memory_charge_bytes': None, 'reason': {}}
        for name, filename in [('cpu_ns', 'cpu.stat'), ('peak_memory_charge_bytes', 'memory.peak')]:
            try:
                raw = (self.path / filename).read_text()
                if name == 'cpu_ns':
                    value = dict(line.split() for line in raw.splitlines())['usage_usec']
                    result[name] = int(value) * 1000
                else:
                    result[name] = int(raw.strip())
                if result[name] < 0:
                    raise ValueError('negative cgroup counter')
                result['reason'][name] = None
            except (OSError, ValueError, KeyError) as error:
                result[name] = None
                result['reason'][name] = str(error)
        return result


def syscall(name, *arguments):
    libc = ctypes.CDLL(None, use_errno=True)
    if getattr(libc, name)(*arguments) != 0:
        raise OSError(ctypes.get_errno(), name)


def drop_privileges(uid):
    os.setgroups([])
    os.setresgid(uid, uid, uid)
    os.setresuid(uid, uid, uid)
    header = (ctypes.c_uint32 * 2)(0x20080522, 0)
    data = (ctypes.c_uint32 * 6)()
    syscall('capset', header, data)
    status = Path('/proc/self/status').read_text()
    if (os.getresuid() != (uid, uid, uid) or os.getresgid() != (uid, uid, uid)
            or os.getgroups() or any(int(line.split()[1], 16) for line in status.splitlines()
                                    if line.startswith(('CapPrm:', 'CapEff:', 'CapAmb:')))):
        raise OSError('worker credentials retain authority')


def namespace_init(command, environment, uid, transcript, status_fd):
    status = 'unsupported'
    try:
        syscall('mount', b'proc', b'/proc', b'proc', 14, None)
        mounts = [line.split()[4] for line in Path('/proc/self/mountinfo').read_text().splitlines()
                  if ' - cgroup2 ' in line or ' - cgroup ' in line]
        for mount in mounts:
            target = os.fsencode(mount)
            syscall('mount', target, target, None, 4096 | 16384, None)
            syscall('mount', None, target, None, 4096 | 32 | 1, None)
        syscall('prctl', 38, 1, 0, 0, 0)  # no_new_privs survives exec and blocks setuid/capability gains.
        try:
            # This helper has one thread; all credential checks precede the worker exec.
            worker = subprocess.Popen(command, stdin=sys.stdin.buffer if transcript is None else subprocess.PIPE, env=environment,
                                      preexec_fn=lambda: drop_privileges(uid))
        except OSError:
            status = 'startup_failure'
        else:
            if transcript is None:
                worker.wait()
            else:
                worker.communicate(transcript)
            status = worker.returncode
    except (OSError, subprocess.SubprocessError):
        pass
    os.write(status_fd, json.dumps(status).encode())
    # Exiting namespace PID 1 makes the kernel kill and reap every remaining member.
    os._exit(0)


def main():
    status_fd = int(sys.argv[1])
    options = json.loads(sys.argv[2])
    cgroup, uid, command, environment = options[:4]
    interactive = len(options) == 5 and options[4]
    os.set_inheritable(status_fd, False)
    status = 'unsupported'
    child = None
    read_fd, write_fd = os.pipe()
    try:
        Path(cgroup, 'cgroup.procs').write_text(str(os.getpid()))
        transcript = None if interactive else sys.stdin.buffer.read()
        syscall('unshare', 0x20000000 | 0x00020000)
        syscall('mount', None, b'/', None, 16384 | (1 << 18), None)
        child = os.fork()
        if child == 0:
            os.close(read_fd)
            os.close(status_fd)
            namespace_init(command, environment, uid, transcript, write_fd)
        os.close(write_fd)
        write_fd = None
        status = 'observer_failure'
        _, result = os.waitpid(child, 0)
        child = None
        with os.fdopen(read_fd, 'rb') as stream:
            read_fd = None
            status = json.load(stream) if result == 0 else 'observer_failure'
    except (OSError, ValueError):
        if child is not None:
            os.kill(child, signal.SIGKILL)
            os.waitpid(child, 0)
    finally:
        for descriptor in (read_fd, write_fd):
            if descriptor is not None:
                os.close(descriptor)
    os.write(status_fd, json.dumps(status).encode())


if __name__ == '__main__':
    main()
