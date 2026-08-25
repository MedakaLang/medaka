#!/usr/bin/env python3
"""Normalize the pinned Wycheproof secp256k1/SHA-256/P1363 artifact."""

import json
import pathlib
import sys

ORDER = int("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141", 16)
HALF_ORDER = ORDER // 2


def s_class(signature: str) -> str:
    if len(signature) != 128:
        return "malformed"
    try:
        s = int(signature[64:], 16)
    except ValueError:
        return "malformed"
    if not 0 < s < ORDER:
        return "invalid-s"
    return "low" if s <= HALF_ORDER else "high"


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: normalize_wycheproof_signing.py <source.json> <output.txt>")
    source = pathlib.Path(sys.argv[1])
    output = pathlib.Path(sys.argv[2])
    data = json.loads(source.read_text())
    if data.get("numberOfTests") != 242:
        raise SystemExit("Wycheproof numberOfTests drifted from 242")
    rows = []
    for group in data["testGroups"]:
        public = group["publicKey"]["uncompressed"].lower()
        for test in group["tests"]:
            signature = test["sig"].lower()
            classification = s_class(signature)
            project = "accept" if test["result"] == "valid" and classification == "low" else "reject"
            message = test["msg"].lower() or "-"
            flags = ",".join(test["flags"]) or "-"
            rows.append(
                f"wycheproof {test['tcId']} {public} {message} {signature or '-'} "
                f"{test['result']} {flags} {classification} {project}"
            )
    if len(rows) != 242 or len({int(row.split()[1]) for row in rows}) != 242:
        raise SystemExit("Wycheproof rows are not 242 unique tcIds")
    output.write_text("\n".join(rows) + "\n")


if __name__ == "__main__":
    main()
