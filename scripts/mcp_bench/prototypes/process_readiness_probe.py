#!/usr/bin/env python3
"""Replay readiness controls; blocked containment is reported, never passed."""

import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time


def main():
    if not __debug__:
        raise RuntimeError('readiness controls require Python assertions enabled')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument('--out', type=Path)
    parser.add_argument('--cc', default=os.environ.get('CC', 'clang'))
    args = parser.parse_args()
    root = args.root.resolve()
    out = args.out.resolve() if args.out else Path(tempfile.mkdtemp(prefix='medaka-readiness-'))
    if out == root or root in out.parents:
        parser.error('--out must be outside the checkout (contains generated binaries)')
    out.mkdir(parents=True, exist_ok=True)
    sources = Path(__file__).resolve().parent
    binary = str(root / 'medaka')
    env = dict(os.environ, MEDAKA_STRICT='1')
    rows = []

    def save(row):
        rows.append(row)
        (out / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')
        print(json.dumps(row), flush=True)

    def command(argv, **options):
        started = time.monotonic()
        result = subprocess.run(argv, cwd=root, env=env, capture_output=True,
                                text=True, timeout=120, **options)
        save(dict(command=list(map(str, argv)), rc=result.returncode,
                  stdout=result.stdout, stderr=result.stderr,
                  elapsed_ms=round((time.monotonic() - started) * 1000)))
        assert result.returncode == 0, rows[-1]
        return result

    if sys.platform not in ('linux', 'darwin'):
        save(dict(name='platform', status='BLOCKED', reason='Linux/macOS POSIX reference required'))
        return

    command([sys.executable, str(sources / 'process_readiness_reference.py'), '--out', str(out)])

    def build(name, source):
        path = out / (name + '.mdk')
        path.write_text(source)
        command([binary, 'fmt', '--write', str(path)])
        command([binary, 'lint', str(path)])
        exe = out / (name + '.exe')
        command([binary, 'build', str(path), '-o', str(exe)])
        return exe

    io = build('io-poll', '''import array.{fromList}
main = match ioPoll (fromList [0]) (fromList [1]) 80
  Err e => putStrLn e
  Ok a => println (toList a)
''')
    cases = [('idle', b'', False, '[0]\n'), ('readable', b'x', False, '[1]\n'),
             ('hup', b'last', True, '[3]\n')]
    for name, data, close, expected in cases:
        r, w = os.pipe()
        try:
            if data:
                os.write(w, data)
            if close:
                os.close(w)
                w = -1
            result = command([str(io)], stdin=r)
            assert result.stdout == expected and result.stderr == '', rows[-1]
            save(dict(name='native_ioPoll_' + name, status='PASS', expected=expected))
        finally:
            os.close(r)
            if w >= 0:
                os.close(w)

    template = '''import async.{runAsync, spawn, sleep, liftIO, deadlineAfter, awaitAny, waitReadCANCEL_IMPORT}
import time.{millis}
main =
  let flag = Ref False
  let result = runAsync (deferThen
    (spawn (deferThen (sleep (millis 40)) (_ => liftIO (_ => flag := True))))
    (_ => deferThen (deadlineAfter (millis 220)) (dl => deferThen
      (awaitAny [WAITS])
      (_ => liftIO (_ => if !flag then "cancelled" else "other")))))
  putStrLn result
'''
    for name, waits, extra in [
        ('cooperative-cancel', 'waitRead 0, waitFlag flag, dl', ', waitFlag'),
        ('missing-cancel-wait', 'waitRead 0, dl', ''),
    ]:
        exe = build(name, template.replace('WAITS', waits).replace('CANCEL_IMPORT', extra))
        r, w = os.pipe()
        try:
            start = time.monotonic()
            result = command([str(exe)], stdin=r)
            elapsed = (time.monotonic() - start) * 1000
            assert result.stdout == 'cancelled\n' and result.stderr == '', rows[-1]
            timely = elapsed < 180 if name == 'cooperative-cancel' else elapsed >= 200
            assert timely, (name, elapsed)
            save(dict(name=name, status='PASS', elapsed_ms=round(elapsed)))
        finally:
            os.close(r)
            os.close(w)

    if sys.platform == 'linux':
        exe = out / 'sigpipe.exe'
        command(shlex.split(args.cc) + ['-std=c11', '-Wall', '-Wextra', '-Werror',
                                      '-pthread', str(sources / 'process_sigpipe.c'), '-o', str(exe)])
        result = command([str(exe)])
        assert result.stdout == ('EPIPE returned; original handler preserved; generated signal consumed\n'
                                 'preexisting pending SIGPIPE preserved\n'
                                 'mask restored; no process-wide disposition change\n')
        assert result.stderr == ''
    else:
        save(dict(name='sigpipe_mask_control', status='BLOCKED',
                  reason='Linux sigtimedwait reference; actual macOS signal handling deferred'))

    save(dict(name='strong_containment', status='BLOCKED',
              reason='No protected broker deployment tested; escaped descendants/death negatives are not containment'))
    print('Readiness controls passed; strong containment remains BLOCKED. Receipts: ' + str(out))


if __name__ == '__main__':
    main()
