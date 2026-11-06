#!/usr/bin/env python3
"""Record ownership prerequisites and local controls; unavailable is exit 77."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess
import sys
import uuid


QUALIFICATION = (
    'ordinary_client_deployment', 'pre_exec_attachment', 'fork_containment',
    'setsid_containment', 'double_fork_containment', 'repeated_fork_containment',
    'denied_migration', 'management_fd_theft_denied', 'unrelated_child_exit_23',
    'caller_death_cleanup', 'broker_death_cleanup', 'manager_recovery',
    'admission_kill_race', 'channel_loss_cleanup', 'stale_foreign_token',
    'token_replay', 'capacity_exhaustion', 'populated_zero_and_direct_reap',
    'cleanup_error_retains_authority',
)
PROTOCOL = (
    'missing_authority', 'stale_token', 'foreign_token', 'foreign_peer',
    'token_replay', 'capacity', 'admission_kill_race', 'channel_loss',
    'cleanup_retained', 'admitted_control', 'unrelated_child_status', 'local_cleanup',
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--cc', default=os.environ.get('CC', 'clang'))
    parser.add_argument('--refusal-only', action='store_true',
                        help='run local controls without inspecting host delegation')
    args = parser.parse_args()
    root, out = args.root.resolve(), args.out.resolve()
    if out == root or root in out.parents:
        parser.error('--out must be outside the checkout')
    if out.exists():
        parser.error('--out must be a new directory (external markers must be fresh)')
    fixture = root / 'scripts/mcp_bench/prototypes/ownership_fixture.c'
    if not fixture.is_file():
        parser.error('--root must contain ownership_fixture.c')
    out.mkdir(parents=True)
    receipt = {'schema': 1, 'qualified': False, 'root': str(root), 'rows': [],
               'commands': [], 'inventory': {}, 'source_sha256': {}}

    def save():
        (out / 'ownership.json').write_text(json.dumps(receipt, indent=2) + '\n')

    def row(name, status, **detail):
        value = dict(name=name, status=status, **detail)
        receipt['rows'].append(value)
        save()
        print(json.dumps(value), flush=True)

    def command(argv):
        result = subprocess.run(list(map(str, argv)), cwd=root, capture_output=True,
                                text=True, timeout=20, env=dict(os.environ, MEDAKA_STRICT='1'))
        receipt['commands'].append(dict(argv=list(map(str, argv)), rc=result.returncode,
                                        stdout=result.stdout, stderr=result.stderr))
        save()
        return result

    def require(condition, detail):
        if not condition:
            raise RuntimeError(detail)

    try:
        revision = command(['git', '-C', root, 'rev-parse', 'HEAD'])
        require(revision.returncode == 0, 'cannot pin source revision')
        receipt['revision'] = revision.stdout.strip()
        for path in (fixture, root / 'scripts/mcp_bench/prototypes/ownership_probe.py'):
            receipt['source_sha256'][str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
        receipt['inventory'] = dict(platform=platform.platform(), uid=os.getuid(), euid=os.geteuid(),
                                    gid=os.getgid(), groups=os.getgroups(), manager_configuration=None)
        if sys.platform == 'linux' and not args.refusal_only:
            status = Path('/proc/self/status').read_text()
            fields = ('Uid', 'Gid', 'CapInh', 'CapPrm', 'CapEff', 'CapBnd', 'CapAmb',
                      'NoNewPrivs', 'Seccomp')
            receipt['inventory']['process_status'] = {
                key: value.strip() for key, value in
                (line.split(':', 1) for line in status.splitlines() if ':' in line) if key in fields}
            receipt['inventory']['namespaces'] = {
                path.name: os.readlink(path) for path in Path('/proc/self/ns').iterdir()}
            receipt['inventory']['cgroup_membership'] = Path('/proc/self/cgroup').read_text()
            receipt['inventory']['identity_maps'] = {
                name: (Path('/proc/self') / name).read_text() for name in ('uid_map', 'gid_map')}
            mounts = [line for line in Path('/proc/self/mountinfo').read_text().splitlines()
                      if ' - cgroup2 ' in line]
            receipt['inventory']['cgroup_mountinfo'] = mounts
            row('cgroup_v2_inventory', 'OBSERVED' if mounts else 'UNAVAILABLE', mounts=mounts)
            if mounts:
                mount = mounts[0].split()
                mount_path = Path(mount[4])
                if 'ro' in mount[5].split(','):
                    disposable = mount_path / ('medaka-authority-' + uuid.uuid4().hex)
                    try:
                        disposable.mkdir()
                    except OSError as error:
                        row('disposable_scope_creation', 'UNAVAILABLE', operation='mkdir',
                            path=str(disposable), errno=error.errno, error=str(error))
                    else:
                        disposable.rmdir()
                        row('disposable_scope_creation', 'UNAVAILABLE',
                            reason='mount inventory changed; empty probe directory removed; no delegation accepted')
                else:
                    row('disposable_scope_creation', 'UNAVAILABLE',
                        reason='no explicitly delegated disposable parent; writable mount is not protected authority')
            else:
                row('disposable_scope_creation', 'UNAVAILABLE', reason='no cgroup2 mount')
        else:
            row('host_delegation', 'UNAVAILABLE', reason='not inspected in portable refusal/local-control mode'
                if args.refusal_only else 'Linux cgroup2 protected manager required')
        save()
        executable = out / 'ownership_fixture'
        compiled = command(shlex.split(args.cc) + ['-std=c11', '-Wall', '-Wextra', '-Werror',
                                                  str(fixture), '-o', str(executable)])
        require(compiled.returncode == 0, 'native fixture compilation failed: ' + compiled.stderr)
        row('native_fixture_build', 'PASS', compiler=args.cc)
        marker = out / 'refused-target.marker'
        refused = command([executable, 'refuse', marker])
        require(refused.returncode == 77 and not marker.exists(), 'refusal executed target or wrong result')
        require(json.loads(refused.stdout)['status'] == 'UNAVAILABLE', 'wrong refusal envelope')
        row('external_nonexecution', 'PASS', rc=refused.returncode, marker_exists=marker.exists())
        control = out / 'target-control.marker'
        executed = command([executable, 'target', control])
        require(executed.returncode == 0 and control.read_bytes() == b'executed\n',
                'external marker positive control failed')
        row('external_marker_control', 'PASS', observed_hex=control.read_bytes().hex())
        if sys.platform == 'linux':
            identity = command([executable, 'drop-identity'])
            require(identity.returncode == 0, 'identity child failed')
            row('ordinary_identity_attempt', 'OBSERVED', **json.loads(identity.stdout))
            protocol = command([executable, 'protocol', out])
            require(protocol.returncode == 0, 'local protocol failed: ' + protocol.stderr)
            values = [json.loads(line) for line in protocol.stdout.splitlines()]
            require(tuple(value['name'] for value in values) == ('credential_auth',) + PROTOCOL,
                    'local protocol matrix incomplete or unexpected')
            require(all(value['status'] == 'PASS' or
                        (value['name'] in ('credential_auth', 'foreign_peer') and
                         value['status'] == 'UNAVAILABLE') for value in values), 'local protocol row failed')
            for value in values:
                row(**dict(value, name='protocol_' + value['name']))
            for name in PROTOCOL[:-2]:
                path = out / (name + '.marker')
                expected = name in ('token_replay', 'cleanup_retained', 'admitted_control')
                require(path.exists() == expected, 'unexpected target execution: ' + name)
                if expected:
                    require(path.read_bytes() == b'executed\n', 'target executed more than once: ' + name)
            row('external_protocol_markers', 'PASS',
                executed=['token_replay', 'cleanup_retained', 'admitted_control'],
                absent=[name for name in PROTOCOL[:-2]
                        if name not in ('token_replay', 'cleanup_retained', 'admitted_control')])
        else:
            row('local_protocol', 'UNAVAILABLE', reason='Linux SCM_CREDENTIALS wire control required')
        reason = ('No protected delegated manager configured or exercised. Local wire-state controls '
                  'do not implement cgroup attachment, anti-escape or death recovery.')
        for name in QUALIFICATION:
            row(name, 'UNQUALIFIED', scope='deployment', reason=reason)
        row('qualification', 'UNAVAILABLE', reason=reason, exit_code=77)
        return 77
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        row('probe_failure', 'FAIL', reason=str(error),
            cleanup='incomplete/unknown after failed command; inspect receipt; no deployment scope admitted')
        return 1


if __name__ == '__main__':
    sys.exit(main())
