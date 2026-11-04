#!/usr/bin/env python3
"""Regression test for #4859: the pre-commit lint filter must not read stderr.

Runs .githooks/pre-commit in a throwaway git repo against a fake `medaka`. The fake
writes an unterminated stdout `error:` line, then a stderr line, then the rest of the
stdout line, which is what `2>&1` interleaving does to a real run. The only finding is
in an unstaged file, so the commit must not be blocked by the lint section.
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

FAKE_MEDAKA = """#!/bin/sh
case "$1" in
  fmt) exit 0 ;;
  lint)
    case "$*" in
      *--list-rules*--ratchet=gated*--tier=cross*) exit 0 ;;
      *--list-rules*--ratchet=baselined*) exit 0 ;;
      *--list-rules*--ratchet=gated*) echo rule-gated; exit 0 ;;
      *--list-rules*) exit 0 ;;
    esac
    echo "$*" >> "$FAKE_LOG"
    printf 'error: compiler/back'
    echo 'medaka lint: baseline: compiler/backend/wasm_emit.mdk: stale' >&2
    echo 'end.mdk:3:1: rule-gated: a finding in an unstaged file'
    exit 1 ;;
esac
exit 0
"""


def find_sh():
    # The hook needs a POSIX sh plus awk, sed and mktemp. On Windows those ship with
    # Git for Windows in usr/bin, which is not always on PATH; derive it from git.
    sh = shutil.which("sh")
    if sh is None:
        git_bin = os.path.dirname(os.path.realpath(shutil.which("git")))
        for up in range(3):
            candidate = os.path.join(git_bin, "usr", "bin", "sh.exe")
            if os.path.isfile(candidate):
                return candidate
            git_bin = os.path.dirname(git_bin)
        raise RuntimeError("no sh found on PATH or beside git")
    return sh


def git(cwd, *args):
    subprocess.run([shutil.which("git"), *args], cwd=cwd, check=True, capture_output=True)


def main():
    sh = find_sh()
    tmp = tempfile.mkdtemp(prefix=".hooktest-", dir=ROOT)
    try:
        os.makedirs(os.path.join(tmp, "compiler"))
        os.makedirs(os.path.join(tmp, ".githooks"))
        os.makedirs(os.path.join(tmp, "test"))
        shutil.copy(os.path.join(ROOT, ".githooks", "pre-commit"),
                    os.path.join(tmp, ".githooks", "pre-commit"))
        shutil.copy(os.path.join(ROOT, "test", "lint_rule_lists.sh"),
                    os.path.join(tmp, "test", "lint_rule_lists.sh"))
        for name in ("comment_register_census.sh", "comment_register_baseline.toml"):
            shutil.copy(os.path.join(ROOT, "test", name), os.path.join(tmp, "test", name))
        fake = os.path.join(tmp, "fake-medaka")
        with open(fake, "w", newline="\n") as f:
            f.write(FAKE_MEDAKA)
        os.chmod(fake, 0o755)
        with open(os.path.join(tmp, "compiler", "staged.mdk"), "w", newline="\n") as f:
            f.write("main = 1\n")
        git(tmp, "init", "-q")
        git(tmp, "add", "compiler/staged.mdk")

        log = os.path.join(tmp, "lint.log")
        env = dict(os.environ, MEDAKA=fake, FAKE_LOG=log)
        env["PATH"] = os.path.dirname(sh) + os.pathsep + env.get("PATH", "")
        res = subprocess.run([sh, os.path.join(tmp, ".githooks", "pre-commit")],
                             cwd=tmp, env=env, capture_output=True, text=True)
        # Positive proof that the lint section ran: the fake logs its real lint call.
        # Without it, an early exit before lint would pass the block check below.
        lint_calls = open(log).read() if os.path.isfile(log) else ""
        if "--cache" not in lint_calls:
            print("FAIL: the hook never reached the lint section (no lint call logged)")
            print(res.stderr)
            return 1
        if "lint violated" in res.stderr:
            print("FAIL: lint section blocked a commit whose only finding is unstaged")
            print(res.stderr)
            return 1
        # The hook must allow the commit outright: another section blocking it would
        # still leave "lint violated" out of stderr, so check the exit status too.
        if res.returncode != 0:
            print(f"FAIL: hook blocked the commit (exit {res.returncode})")
            print(res.stderr)
            return 1
        print("ok: lint section did not block; findings outside staged files pass")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
