#!/usr/bin/env python3
"""Offline integrity and semantic checks for the S3-A signing authorities."""

import hashlib
import pathlib
import re
import subprocess
import sys
import tempfile

ORDER = int("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141", 16)
HALF_ORDER = ORDER // 2
LIBSECP_SHA = "3fe9fd705f4fdf2fe90d6e04b6c1fedd7e8f244a119315886f6468f52c2dfc33"
K256_SHA = "2413c10980e3a2648118953a6468699670d7f03674fe4dcbffa5d3ecc835ec5f"
RFC6979_SHA = "f8dd2a808d456c4a54e300a23e9f5a67e122c3024119acbfd73e3bf664491cb2"
WYCHEPROOF_SHA = "6508e9cc99c169c7d59a6891d939387f115491c479088ddcdcec4d137be69f34"
PDS_DIGEST = "sha256:d95725b24dbe53af9d91dc69750556931ebed6c396f2cfa42b221434db642f12"
PDS_REVISION = "374cf1d4ba782d4391bbb73e4e2d3f320d4846d6"
LIBSECP_CONTROL_RUNNER = """#!/bin/sh
printf '%s\\n' fresh-independent-oracle-output
"""
K256_CONTROL_RUNNER = """#!/bin/sh
control_output=fresh-independent-oracle-output
printf '%s\\n' "$control_output"
"""
K256_RUNNER = """#!/bin/sh
# ORACLE_EXECUTION: k256 + locked rfc6979 0.4.0
exec cargo run --quiet --locked --manifest-path "$ORACLE_WORK/rust/Cargo.toml" -- "$1"
"""


def fail(message: str) -> None:
    raise SystemExit(f"signing_corpus: FAIL: {message}")


def is_hex(text: str, size: int) -> bool:
    return len(text) == size * 2 and re.fullmatch(r"[0-9a-f]+", text) is not None


def expected_inputs() -> tuple[list[str], list[str], list[tuple[int, int]]]:
    keys = [1, 2, 3, HALF_ORDER - 1, HALF_ORDER, HALF_ORDER + 1, ORDER - 2, ORDER - 1]
    for i in range(8):
        value = int.from_bytes(hashlib.sha256(f"medaka-pds-signing-key-{i}".encode()).digest(), "big")
        if not 0 < value < ORDER:
            fail(f"derived key {i} unexpectedly needs rejection")
        keys.append(value)
    digests = [
        bytes(32),
        bytes(31) + b"\x01",
        bytes([255]) * 32,
        bytes.fromhex("79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"),
    ]
    digests.extend(hashlib.sha256(f"medaka-pds-signing-message-{i}".encode()).digest() for i in range(12))
    pairs = [(i, i) for i in range(16)]
    pairs.extend((key, digest) for key in range(8) for digest in range(8))
    return [f"{key:064x}" for key in keys], [digest.hex() for digest in digests], pairs


def check_manifest(root: pathlib.Path) -> None:
    keys, digests, pairs = expected_inputs()
    manifest = root / "pds/tools/signing_inputs.txt"
    found_keys: dict[int, str] = {}
    found_digests: dict[int, str] = {}
    found_pairs: dict[int, tuple[int, int]] = {}
    found_pds: dict[int, tuple[int, str, str]] = {}
    for line in manifest.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if fields[0] == "key":
            found_keys[int(fields[1])] = fields[2]
        elif fields[0] == "digest":
            found_digests[int(fields[1])] = fields[2]
        elif fields[0] == "pair":
            found_pairs[int(fields[1])] = (int(fields[2]), int(fields[3]))
        elif fields[0] == "pds":
            found_pds[int(fields[1])] = (int(fields[2]), fields[3], fields[4])
        else:
            fail(f"unknown manifest record {fields[0]}")
    if found_keys != dict(enumerate(keys)):
        fail("fixed private-key manifest drifted")
    if found_digests != dict(enumerate(digests)):
        fail("fixed prehash manifest drifted")
    if found_pairs != dict(enumerate(pairs)):
        fail("80-row pair schedule drifted")
    expected_pds = {}
    for i in range(16):
        message = f"medaka-pds-oracle-message-{i}".encode()
        expected_pds[i] = (i, message.hex(), hashlib.sha256(message).hexdigest())
    if found_pds != expected_pds:
        fail("16-row official-PDS message manifest drifted")


def run_oracle_control(generator: pathlib.Path, cwd: pathlib.Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["sh", str(generator), "--oracle-control"],
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
    )


def oracle_control_completed(proof: subprocess.CompletedProcess[str]) -> bool:
    proof_lines = proof.stdout.splitlines()
    if proof.returncode != 0 or len(proof_lines) != 5:
        return False
    rows = [line.split() for line in proof_lines]
    if [len(row) for row in rows] != [6, 6, 7, 7, 2]:
        return False
    libsecp_runner, k256_runner, libsecp_output, k256_output, compared = rows
    file_ids = [libsecp_runner[3], k256_runner[3]]
    return (
        libsecp_runner[:2] == ["runner", "libsecp256k1"]
        and k256_runner[:2] == ["runner", "k256"]
        and libsecp_output[:2] == ["output", "libsecp256k1"]
        and k256_output[:2] == ["output", "k256"]
        and compared[0] == "compared"
        and libsecp_runner[2:6] == libsecp_output[2:6]
        and k256_runner[2:6] == k256_output[2:6]
        and libsecp_runner[2] != k256_runner[2]
        and (file_ids == ["unavailable", "unavailable"] or len(set(file_ids)) == 2)
        and libsecp_runner[4] == libsecp_runner[5]
        and k256_runner[4] == k256_runner[5]
        and libsecp_runner[5] != k256_runner[5]
        and all(is_hex(value, 32) for value in [libsecp_runner[2], k256_runner[2]])
        and all(
            is_hex(value, 32)
            for value in [libsecp_runner[4], libsecp_runner[5], k256_runner[4], k256_runner[5]]
        )
        and len({libsecp_output[6], k256_output[6], compared[1]}) == 1
        and is_hex(compared[1], 32)
    )


def require_control_mutation_red(
    root: pathlib.Path,
    generator: str,
    real_anchors: list[str],
    label: str,
    anchor: str,
    replacement: str,
) -> None:
    if generator.count(anchor) != 1:
        fail(f"{label} mutation anchor is not unique")
    mutated = generator.replace(anchor, replacement)
    for real_anchor in real_anchors:
        if mutated.count(real_anchor) != generator.count(real_anchor):
            fail(f"{label} mutation changed a retained real-authority anchor")
    with tempfile.TemporaryDirectory(prefix="medaka-oracle-control-") as temporary:
        mutation_root = pathlib.Path(temporary)
        mutation_generator = mutation_root / "gen_signing_corpus.sh"
        mutation_generator.write_text(mutated)
        proof = run_oracle_control(mutation_generator, root)
    if oracle_control_completed(proof):
        fail(f"{label} unexpectedly preserved oracle completion")


def require_generator_authorities(root: pathlib.Path) -> None:
    generator_path = root / "pds/tools/gen_signing_corpus.sh"
    generator = generator_path.read_text()
    literals = [LIBSECP_SHA, K256_SHA, WYCHEPROOF_SHA, PDS_DIGEST, PDS_REVISION]
    for literal in literals:
        if generator.count(literal) != 1:
            fail(f"generator authority pin missing or duplicated: {literal}")
    real_anchors = [
        'LIBSECP_RUNNER="$WORK/libsecp-sign"',
        'exec cargo run --quiet --locked --manifest-path "$ORACLE_WORK/rust/Cargo.toml" -- "$1"',
        'K256_RUNNER="$WORK/k256-runner"',
        f"K256_WRAPPER_EXPECTED_SHA={hashlib.sha256(K256_RUNNER.encode()).hexdigest()}",
    ]
    for real_anchor in real_anchors:
        if generator.count(real_anchor) != 1:
            fail(f"real signing authority command missing or duplicated: {real_anchor}")
    runner_assignments = re.findall(r"^  (?:LIBSECP_RUNNER|K256_RUNNER)=.*$", generator, re.MULTILINE)
    if runner_assignments != [
        '  LIBSECP_RUNNER="$WORK/libsecp-control-runner"',
        '  K256_RUNNER="$WORK/k256-control-runner"',
        '  LIBSECP_RUNNER="$WORK/libsecp-sign"',
        '  K256_RUNNER="$WORK/k256-runner"',
    ]:
        fail("signing authority runner bindings drifted or were reassigned")
    expected_literals = [
        f"LIBSECP_CONTROL_RUNNER_EXPECTED_SHA={hashlib.sha256(LIBSECP_CONTROL_RUNNER.encode()).hexdigest()}",
        f"K256_CONTROL_RUNNER_EXPECTED_SHA={hashlib.sha256(K256_CONTROL_RUNNER.encode()).hexdigest()}",
        f"K256_WRAPPER_EXPECTED_SHA={hashlib.sha256(K256_RUNNER.encode()).hexdigest()}",
    ]
    for expected_literal in expected_literals:
        if generator.count(expected_literal) != 1:
            fail(f"expected runner implementation digest drifted: {expected_literal}")
    expected_assignments = re.findall(
        r"^  (?:LIBSECP_EXPECTED_SHA|K256_EXPECTED_SHA)=.*$", generator, re.MULTILINE
    )
    if expected_assignments != [
        "  LIBSECP_EXPECTED_SHA=$LIBSECP_CONTROL_RUNNER_EXPECTED_SHA",
        "  K256_EXPECTED_SHA=$K256_CONTROL_RUNNER_EXPECTED_SHA",
        '  LIBSECP_EXPECTED_SHA=$(sha256_file "$WORK/libsecp-sign")',
        "  K256_EXPECTED_SHA=$K256_WRAPPER_EXPECTED_SHA",
    ]:
        fail("runner expected-implementation bindings drifted or were reassigned")
    k256_setup = f'''  cat > "$WORK/k256-runner" <<'EOF'
{K256_RUNNER}EOF
  chmod +x "$WORK/k256-runner"
  K256_RUNNER="$WORK/k256-runner"'''
    if generator.count(k256_setup) != 1:
        fail("real k256 runner is not exactly bound to its locked cargo command")
    wrapper_templates = [
        ("libsecp control", "$WORK/libsecp-control-runner", LIBSECP_CONTROL_RUNNER),
        ("k256 control", "$WORK/k256-control-runner", K256_CONTROL_RUNNER),
        ("k256 real", "$WORK/k256-runner", K256_RUNNER),
    ]
    for label, path, template in wrapper_templates:
        block = f'''  cat > "{path}" <<'EOF'
{template}EOF'''
        if generator.count(block) != 1 or generator.count(f'cat > "{path}"') != 1:
            fail(f"{label} wrapper template is missing, duplicated, or rewritten")
    common_path = [
        "  attest_oracle_runners \\",
        '    "$libsecp_runner" "$k256_runner" "$libsecp_expected_sha" "$k256_expected_sha" "$receipt"',
        '  ORACLE_WORK="$WORK" "$libsecp_runner" "$input" > "$libsecp_output"',
        "  record_oracle_completion libsecp256k1 \\",
        '  ORACLE_WORK="$WORK" "$k256_runner" "$input" > "$k256_output"',
        "  record_oracle_completion k256 \\",
        '  compare_oracle_outputs "$libsecp_output" "$k256_output" "$receipt"',
        '  require_oracle_completion "$receipt"',
    ]
    positions = []
    for anchor in common_path:
        if generator.count(anchor) != 1:
            fail(f"common signing oracle execution disabled or duplicated: {anchor}")
        positions.append(generator.index(anchor))
    if positions != sorted(positions):
        fail("common signing oracle execution/receipt order drifted")
    proof = run_oracle_control(generator_path, root)
    if not oracle_control_completed(proof):
        fail("fresh oracle run/compare completion evidence is absent")
    mutations = [
        (
            "delegating wrapper rewrite",
            "# ORACLE_MODE_SETUP_COMPLETE",
            "# ORACLE_MODE_SETUP_COMPLETE\n"
            'if [ "$MODE" = oracle-control ]; then\n'
            '  cat > "$WORK/k256-control-runner" <<\'EOF\'\n'
            "#!/bin/sh\n"
            'exec "$WORK/libsecp-control-runner" "$1"\n'
            "EOF\n"
            "fi",
        ),
        (
            "expected digest omission",
            "  K256_EXPECTED_SHA=$K256_CONTROL_RUNNER_EXPECTED_SHA",
            "  K256_EXPECTED_SHA= # omit expected implementation digest",
        ),
        (
            "expected digest forgery",
            "  K256_EXPECTED_SHA=$K256_CONTROL_RUNNER_EXPECTED_SHA",
            "  K256_EXPECTED_SHA=" + ("0" * 64) + " # forge expected implementation digest",
        ),
        (
            "direct runner alias",
            '  K256_RUNNER="$WORK/k256-control-runner"',
            '  K256_RUNNER="$WORK/libsecp-control-runner" # alias the first runner',
        ),
        (
            "same-content runner copy",
            '  chmod +x "$WORK/libsecp-control-runner" "$WORK/k256-control-runner"',
            '  chmod +x "$WORK/libsecp-control-runner" "$WORK/k256-control-runner"\n'
            '  cp "$WORK/libsecp-control-runner" "$WORK/k256-control-runner" # copy first runner bytes',
        ),
        (
            "runner identity receipt omission",
            '    "$libsecp_runner" "$k256_runner" "$libsecp_expected_sha" "$k256_expected_sha" "$receipt"',
            '    "$libsecp_runner" "$k256_runner" "$libsecp_expected_sha" "$k256_expected_sha" "$receipt"\n'
            '  : > "$receipt" # omit runner identity receipt',
        ),
        (
            "runner identity receipt forgery",
            '    "$libsecp_runner" "$k256_runner" "$libsecp_expected_sha" "$k256_expected_sha" "$receipt"',
            '    "$libsecp_runner" "$k256_runner" "$libsecp_expected_sha" "$k256_expected_sha" "$receipt"\n'
            "  printf '%s\\n' 'runner libsecp256k1 forged-a forged-file-a forged-expected-a forged-content-a' "
            "'runner k256 forged-b forged-file-b forged-expected-b forged-content-b' > \"$receipt\"",
        ),
        (
            "post-setup early exit",
            "# ORACLE_MODE_SETUP_COMPLETE",
            "# ORACLE_MODE_SETUP_COMPLETE\nexit 0 # disable common oracle execution",
        ),
        (
            "libsecp runner disablement",
            '  ORACLE_WORK="$WORK" "$libsecp_runner" "$input" > "$libsecp_output"',
            '  : > "$libsecp_output" # disable libsecp runner',
        ),
        (
            "k256 runner disablement",
            '  ORACLE_WORK="$WORK" "$k256_runner" "$input" > "$k256_output"',
            '  : > "$k256_output" # disable k256 runner',
        ),
        (
            "oracle comparison skip",
            '  compare_oracle_outputs "$libsecp_output" "$k256_output" "$receipt"',
            "  : # skip oracle comparison",
        ),
        (
            "stale oracle output reuse",
            '  rm -f "$receipt" "$libsecp_output" "$k256_output"',
            "  : # retain stale pre-existing oracle outputs",
        ),
    ]
    for label, anchor, replacement in mutations:
        require_control_mutation_red(root, generator, real_anchors, label, anchor, replacement)
    lock = (root / "pds/tools/signing_k256/Cargo.lock").read_text()
    if f'name = "rfc6979"\nversion = "0.4.0"\nsource = "registry+https://github.com/rust-lang/crates.io-index"\nchecksum = "{RFC6979_SHA}"' not in lock:
        fail("locked rfc6979 0.4.0 checksum drifted")


def check_signing(root: pathlib.Path) -> None:
    keys, digests, pairs = expected_inputs()
    path = root / "pds/test/vectors/prehashed_signing_corpus.txt"
    seen: set[int] = set()
    rows = path.read_text().splitlines()
    if len(rows) != 80:
        fail(f"prehashed signing corpus has {len(rows)} rows, expected 80")
    for line in rows:
        fields = line.split()
        if len(fields) != 11 or fields[0] != "sign":
            fail("malformed prehashed signing row")
        row = int(fields[1])
        if row in seen:
            fail(f"duplicate prehashed row id {row}")
        seen.add(row)
        key_index, digest_index = pairs[row]
        key, digest, public, nonce, r, raw_s, low_s, compact, sources = fields[2:]
        if key != keys[key_index] or digest != digests[digest_index]:
            fail(f"prehashed row {row} input tuple drifted")
        if not is_hex(public, 33) or not is_hex(nonce, 32) or not is_hex(r, 32):
            fail(f"prehashed row {row} has malformed key/nonce/r")
        if not all(is_hex(value, 32) for value in (raw_s, low_s)) or not is_hex(compact, 64):
            fail(f"prehashed row {row} has malformed signature fields")
        expected_low = min(int(raw_s, 16), ORDER - int(raw_s, 16))
        if low_s != f"{expected_low:064x}" or compact != r + low_s:
            fail(f"prehashed row {row} low-S/compact relation failed")
        if sources != "libsecp256k1+k256":
            fail(f"prehashed row {row} lost dual-oracle attribution")
    if seen != set(range(80)):
        fail("prehashed row IDs are not exactly 0..79")


def check_pds(root: pathlib.Path) -> None:
    keys, _, _ = expected_inputs()
    rows = (root / "pds/test/vectors/pds_message_signing_corpus.txt").read_text().splitlines()
    if len(rows) != 16:
        fail(f"PDS message corpus has {len(rows)} rows, expected 16")
    seen = set()
    for line in rows:
        fields = line.split()
        if len(fields) != 8 or fields[0] != "pds":
            fail("malformed PDS message row")
        row = int(fields[1])
        key, message, digest, public, signature, sources = fields[2:]
        expected_message = f"medaka-pds-oracle-message-{row}".encode()
        if row in seen or not 0 <= row < 16:
            fail(f"duplicate/out-of-range PDS row {row}")
        seen.add(row)
        if key != keys[row] or message != expected_message.hex():
            fail(f"PDS row {row} input drifted")
        if digest != hashlib.sha256(expected_message).hexdigest():
            fail(f"PDS row {row} digest assertion failed")
        if not is_hex(public, 33) or not is_hex(signature, 64):
            fail(f"PDS row {row} has malformed public key/signature")
        if sources != "libsecp256k1+k256+official-pds":
            fail(f"PDS row {row} lost official corroboration")
    if seen != set(range(16)):
        fail("PDS row IDs are not exactly 0..15")


def classify(signature: str) -> str:
    if signature == "-" or not is_hex(signature, 64):
        return "malformed"
    s = int(signature[64:], 16)
    if not 0 < s < ORDER:
        return "invalid-s"
    return "low" if s <= HALF_ORDER else "high"


def check_wycheproof(root: pathlib.Path) -> tuple[int, int]:
    rows = (root / "pds/test/vectors/wycheproof_secp256k1_sha256_p1363.txt").read_text().splitlines()
    if len(rows) != 242:
        fail(f"Wycheproof corpus has {len(rows)} rows, expected 242")
    ids = set()
    upstream = {"valid": 0, "invalid": 0, "acceptable": 0}
    valid_s = {"low": 0, "high": 0}
    project = {"accept": 0, "reject": 0}
    high_witness = None
    invalid_witness = None
    for line in rows:
        fields = line.split()
        if len(fields) != 9 or fields[0] != "wycheproof":
            fail("malformed Wycheproof row")
        tcid = int(fields[1])
        public, message, signature, result, flags, recorded_class, expected = fields[2:]
        if tcid in ids:
            fail(f"duplicate Wycheproof tcId {tcid}")
        ids.add(tcid)
        if not is_hex(public, 65) or (message != "-" and not is_hex(message, len(message) // 2)):
            fail(f"Wycheproof tcId {tcid} has malformed public/message encoding")
        if result not in upstream:
            fail(f"Wycheproof tcId {tcid} has unknown result {result}")
        upstream[result] += 1
        actual_class = classify(signature)
        if recorded_class != actual_class:
            fail(f"Wycheproof tcId {tcid} s classification drifted")
        actual_expected = "accept" if result == "valid" and actual_class == "low" else "reject"
        if expected != actual_expected:
            fail(f"Wycheproof tcId {tcid} project expectation drifted")
        project[expected] += 1
        if result == "valid":
            if actual_class not in valid_s:
                fail(f"valid Wycheproof tcId {tcid} lacks a valid scalar")
            valid_s[actual_class] += 1
            if actual_class == "high" and high_witness is None:
                high_witness = tcid
        elif invalid_witness is None:
            invalid_witness = (tcid, actual_class, flags)
    if len(ids) != 242 or upstream != {"valid": 163, "invalid": 79, "acceptable": 0}:
        fail(f"Wycheproof upstream partitions drifted: {upstream}")
    if valid_s != {"low": 94, "high": 69}:
        fail(f"Wycheproof valid low/high partitions drifted: {valid_s}")
    if project != {"accept": 94, "reject": 148}:
        fail(f"Wycheproof project partitions drifted: {project}")
    if high_witness is None or invalid_witness is None:
        fail("Wycheproof high-S/invalid routes were not executed")
    print(f"Wycheproof high-S classification route: tcId={high_witness}")
    print(
        "Wycheproof malformed/invalid verification route: "
        f"tcId={invalid_witness[0]} class={invalid_witness[1]} flags={invalid_witness[2]}"
    )
    return high_witness, invalid_witness[0]


def main() -> None:
    if len(sys.argv) not in (2, 3):
        fail("usage: signing_corpus_check.py <repo-root> [--provenance]")
    root = pathlib.Path(sys.argv[1]).resolve()
    provenance_only = len(sys.argv) == 3 and sys.argv[2] == "--provenance"
    check_manifest(root)
    require_generator_authorities(root)
    check_signing(root)
    check_pds(root)
    check_wycheproof(root)
    label = "PROVENANCE PASS" if provenance_only else "PASS"
    print(
        f"signing_corpus: {label} — 80 dual-oracle prehashed, 16 official-PDS, "
        "242 unique Wycheproof (163 valid/79 invalid; 69 high-S/94 low-S; 94 accept/148 reject)"
    )
    print(
        "signing_corpus: pins "
        f"libsecp={LIBSECP_SHA} k256={K256_SHA} rfc6979={RFC6979_SHA} "
        f"wycheproof={WYCHEPROOF_SHA} pds={PDS_DIGEST} revision={PDS_REVISION}"
    )


if __name__ == "__main__":
    main()
