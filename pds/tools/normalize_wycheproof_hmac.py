#!/usr/bin/env python3
"""Normalize the pinned Wycheproof HMAC-SHA256 artifact into this project's
plain vector-row format.

One row per test, across every `testGroups` entry regardless of key size or
tag size -- `hmac_sha256_test.json` groups by (keySize, tagSize) but the row
format below carries tagSize per row, so a driver can truncate the full
32-byte tag to it before comparing (a Wycheproof `tagSize < 256` row is a
truncated-tag row: RFC 2104 HMAC truncation, not a different algorithm).
Empty `msg`/`key` fields are written as `-` rather than an empty token, so a
whitespace-split line parser keeps every row's field count fixed."""

import json
import pathlib
import sys


def rows(data: dict) -> list[str]:
    if data.get("numberOfTests") != 174:
        raise SystemExit(f"Wycheproof HMAC numberOfTests drifted from 174 (got {data.get('numberOfTests')})")
    out = []
    for group in data["testGroups"]:
        tag_bits = group["tagSize"]
        for test in group["tests"]:
            key = test["key"].lower() or "-"
            msg = test["msg"].lower() or "-"
            tag = test["tag"].lower() or "-"
            out.append(
                f"wycheproof {test['tcId']} {key} {msg} {tag} {tag_bits} {test['result']}"
            )
    if len(out) != 174 or len({int(row.split(' ')[1]) for row in out}) != 174:
        raise SystemExit("Wycheproof HMAC rows are not 174 unique tcIds")
    return out


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: normalize_wycheproof_hmac.py <source.json> <output.txt>")
    source = pathlib.Path(sys.argv[1])
    output = pathlib.Path(sys.argv[2])
    output.write_text("\n".join(rows(json.loads(source.read_text()))) + "\n")


if __name__ == "__main__":
    main()
