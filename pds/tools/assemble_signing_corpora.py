#!/usr/bin/env python3
"""Join byte-identical independent answers with official-PDS corroboration."""

import pathlib
import sys


def rows(path: str, prefix: str) -> list[list[str]]:
    result = []
    for line in pathlib.Path(path).read_text().splitlines():
        fields = line.split()
        if fields and fields[0] == prefix:
            result.append(fields)
    return result


def main() -> None:
    if len(sys.argv) != 5:
        raise SystemExit(
            "usage: assemble_signing_corpora.py <agreed.out> <pds.out> <prehashed.txt> <pds.txt>"
        )
    agreed_path, pds_path, prehashed_path, pds_corpus_path = sys.argv[1:]
    signing = rows(agreed_path, "sign")
    references = rows(agreed_path, "pds-ref")
    official = rows(pds_path, "pds-oracle")
    if len(signing) != 80 or len(references) != 16 or len(official) != 16:
        raise SystemExit("unexpected 80/16/16 signing row counts")
    if [row[1] for row in signing] != [str(i) for i in range(80)]:
        raise SystemExit("signing row IDs drifted")
    if [row[1] for row in references] != [str(i) for i in range(16)]:
        raise SystemExit("PDS reference row IDs drifted")
    if [row[1] for row in official] != [str(i) for i in range(16)]:
        raise SystemExit("PDS oracle row IDs drifted")

    prehashed = []
    for row in signing:
        # sign id key digest pub k r raw-s low-s compact
        if len(row) != 10:
            raise SystemExit(f"malformed independent signing row {row[1]}")
        prehashed.append(" ".join(row + ["libsecp256k1+k256"]))

    pds_rows = []
    for reference, pds in zip(references, official):
        # pds-ref id key message digest pub k r raw-s low-s compact
        # pds-oracle id key message digest pub compact
        if len(reference) != 11 or len(pds) != 7:
            raise SystemExit(f"malformed PDS row {reference[1]}")
        if reference[1:5] != pds[1:5] or reference[5] != pds[5] or reference[10] != pds[6]:
            raise SystemExit(f"official PDS disagrees with independent oracles at row {reference[1]}")
        pds_rows.append(" ".join(["pds"] + pds[1:] + ["libsecp256k1+k256+official-pds"]))

    pathlib.Path(prehashed_path).write_text("\n".join(prehashed) + "\n")
    pathlib.Path(pds_corpus_path).write_text("\n".join(pds_rows) + "\n")


if __name__ == "__main__":
    main()
