#!/usr/bin/env python3
"""Normalize the pinned Wycheproof PBKDF2-HMAC-SHA256 artifact into this
project's plain vector-row format.

`password`/`salt` are already hex in the source JSON, so no re-encoding is
needed beyond lowercasing. Two of the 60 rows (tcId 1/2) are Wycheproof's own
copy of the RFC 7914 §11 vectors already hand-transcribed in
pds/test/pbkdf2_test.mdk (same password/salt/iterationCount/dkLen/dk) --
kept here rather than excluded, since this is a new file from a
different-sourced answer key, not an edit to the RFC 7914 one; the overlap
is cross-validation between two independently published sources, not
duplication within one."""

import json
import pathlib
import sys


def rows(data: dict) -> list[str]:
    if data.get("numberOfTests") != 60:
        raise SystemExit(f"Wycheproof PBKDF2 numberOfTests drifted from 60 (got {data.get('numberOfTests')})")
    out = []
    for group in data["testGroups"]:
        for test in group["tests"]:
            password = test["password"].lower() or "-"
            salt = test["salt"].lower() or "-"
            dk = test["dk"].lower() or "-"
            out.append(
                f"wycheproof {test['tcId']} {password} {salt} "
                f"{test['iterationCount']} {test['dkLen']} {dk} {test['result']}"
            )
    if len(out) != 60 or len({int(row.split(' ')[1]) for row in out}) != 60:
        raise SystemExit("Wycheproof PBKDF2 rows are not 60 unique tcIds")
    return out


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: normalize_wycheproof_pbkdf2.py <source.json> <output.txt>")
    source = pathlib.Path(sys.argv[1])
    output = pathlib.Path(sys.argv[2])
    output.write_text("\n".join(rows(json.loads(source.read_text()))) + "\n")


if __name__ == "__main__":
    main()
