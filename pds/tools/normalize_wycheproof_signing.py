#!/usr/bin/env python3
"""Normalize the pinned Wycheproof secp256k1/SHA-256 signing artifacts.

Two independent source shapes, one row format. The P1363 artifact already
carries fixed 64-byte r||s signatures; the Bitcoin (strict-DER) artifact
carries variable-length ASN.1 DER signatures that must first be converted to
r||s, and only the ones NOT already exercised by the P1363 corpus are kept
(see `bitcoin_rows` below for the exact criteria)."""

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


def project(result: str, classification: str) -> str:
    return "accept" if result == "valid" and classification == "low" else "reject"


def p1363_rows(data: dict) -> list[str]:
    if data.get("numberOfTests") != 242:
        raise SystemExit("Wycheproof numberOfTests drifted from 242")
    rows = []
    for group in data["testGroups"]:
        public = group["publicKey"]["uncompressed"].lower()
        for test in group["tests"]:
            signature = test["sig"].lower()
            classification = s_class(signature)
            message = test["msg"].lower() or "-"
            flags = ",".join(test["flags"]) or "-"
            rows.append(
                f"wycheproof {test['tcId']} {public} {message} {signature or '-'} "
                f"{test['result']} {flags} {classification} "
                f"{project(test['result'], classification)}"
            )
    if len(rows) != 242 or len({int(row.split()[1]) for row in rows}) != 242:
        raise SystemExit("Wycheproof rows are not 242 unique tcIds")
    return rows


def _der_read_int(body: bytes, idx: int):
    """One ASN.1 INTEGER TLV starting at `idx`. Rejects any encoding that
    is not already minimal (long-form length, a redundant leading 0x00, or
    a positive value missing its required 0x00 pad) -- Wycheproof's own
    strict-DER definition, not merely "parses"."""
    if idx + 1 >= len(body) or body[idx] != 0x02:
        return None
    length = body[idx + 1]
    if length & 0x80:
        return None
    start = idx + 2
    end = start + length
    if end > len(body):
        return None
    value = body[start:end]
    if len(value) == 0:
        return None
    if len(value) > 1 and value[0] == 0 and (value[1] & 0x80) == 0:
        return None
    if value[0] & 0x80:
        return None
    return value, end


def der_to_rs(sig_hex: str):
    """Strict-DER ECDSA signature -> 32-byte (r, s), or None when `sig_hex`
    is not a strict, minimally-encoded DER signature with both components
    in (0, ORDER). This is what "convertible" means for the Bitcoin
    corpus: a row this returns None for cannot be represented as the
    fixed-width r||s rows the rest of this corpus family uses, so it is
    out of scope rather than converted."""
    try:
        body = bytes.fromhex(sig_hex)
    except ValueError:
        return None
    if len(body) < 8 or body[0] != 0x30:
        return None
    outer_len = body[1]
    if outer_len & 0x80 or len(body) != 2 + outer_len:
        return None
    parsed_r = _der_read_int(body, 2)
    if parsed_r is None:
        return None
    r_bytes, idx = parsed_r
    parsed_s = _der_read_int(body, idx)
    if parsed_s is None:
        return None
    s_bytes, idx = parsed_s
    if idx != len(body):
        return None
    r = int.from_bytes(r_bytes, "big")
    s = int.from_bytes(s_bytes, "big")
    if not (0 < r < ORDER and 0 < s < ORDER):
        return None
    return r.to_bytes(32, "big"), s.to_bytes(32, "big")


def _p1363_seen(p1363_normalized: pathlib.Path) -> set[tuple[str, str, int, int]]:
    """(pubkey, message, r, s) of every signature the P1363 corpus already
    tests. Only an exact match is a duplicate: a signature sharing s but
    not r, or sharing r with s replaced by its `n - s` mirror, is a
    different verifier input."""
    seen: set[tuple[str, str, int, int]] = set()
    for line in p1363_normalized.read_text().splitlines():
        fields = line.split(" ")
        if len(fields) < 5:
            continue
        public, message, signature = fields[2], fields[3], fields[4]
        if signature == "-" or len(signature) != 128:
            continue
        seen.add((public, message, int(signature[:64], 16), int(signature[64:], 16)))
    return seen


def bitcoin_rows(data: dict, p1363_normalized: pathlib.Path) -> list[str]:
    """Rows new to this corpus family from the Wycheproof Bitcoin
    (strict-DER, BIP66-style) artifact.

    Measured against the pinned commit's actual JSON (`der_to_rs` is
    cross-checked against `cryptography.hazmat...decode_dss_signature` +
    `encode_dss_signature` round-tripping, independently agreeing byte for
    byte): 463 source rows, of which 181 are strict-DER with both
    components in range ("convertible" -- the rest are the deliberately
    malformed/BER/wrong-type/out-of-range rows this corpus cannot
    represent as fixed-width r||s). Of those 181, 107 are exact
    (pubkey, message, r, s) duplicates of a P1363 row and are dropped; the
    other 74 are kept. 69 of the kept rows share r with a P1363 row whose
    s is high, carrying the low-S mirror `n - s` instead (68 valid, 1
    invalid). The P1363 corpus never exercises those low-S values: its
    high-S sibling is rejected by the low-S rule before the verify
    arithmetic runs. The issue's estimate (#3362) of 231 convertible / 77
    new came from the flag vocabulary alone, without decoding signature
    values; 181/74 is what is enforced below."""
    if data.get("numberOfTests") != 463:
        raise SystemExit("Wycheproof Bitcoin numberOfTests drifted from 463")
    seen = _p1363_seen(p1363_normalized)
    convertible = 0
    rows = []
    for group in data["testGroups"]:
        public = group["publicKey"]["uncompressed"].lower()
        for test in group["tests"]:
            parsed = der_to_rs(test.get("sig") or "")
            if parsed is None:
                continue
            convertible += 1
            r_bytes, s_bytes = parsed
            r = int.from_bytes(r_bytes, "big")
            s = int.from_bytes(s_bytes, "big")
            message = test["msg"].lower() or "-"
            if (public, message, r, s) in seen:
                continue
            signature = (r_bytes + s_bytes).hex()
            classification = s_class(signature)
            flags = ",".join(test["flags"]) or "-"
            rows.append(
                f"wycheproof {test['tcId']} {public} {message} {signature} "
                f"{test['result']} {flags} {classification} "
                f"{project(test['result'], classification)}"
            )
    if convertible != 181:
        raise SystemExit(
            f"Wycheproof Bitcoin convertible count drifted from 181 (measured {convertible})"
        )
    if len(rows) != 74:
        raise SystemExit(
            f"Wycheproof Bitcoin new-row count drifted from 74 (measured {len(rows)})"
        )
    seen_ids = {int(row.split(" ")[1]) for row in rows}
    if len(seen_ids) != len(rows):
        raise SystemExit("Wycheproof Bitcoin rows are not unique tcIds")
    return rows


def main() -> None:
    if len(sys.argv) == 3:
        source = pathlib.Path(sys.argv[1])
        output = pathlib.Path(sys.argv[2])
        rows = p1363_rows(json.loads(source.read_text()))
    elif len(sys.argv) == 4:
        source = pathlib.Path(sys.argv[1])
        p1363_normalized = pathlib.Path(sys.argv[2])
        output = pathlib.Path(sys.argv[3])
        rows = bitcoin_rows(json.loads(source.read_text()), p1363_normalized)
    else:
        raise SystemExit(
            "usage: normalize_wycheproof_signing.py <source.json> <output.txt>\n"
            "   or: normalize_wycheproof_signing.py <bitcoin.json> <p1363-output.txt> <output.txt>"
        )
    output.write_text("\n".join(rows) + "\n")


if __name__ == "__main__":
    main()
