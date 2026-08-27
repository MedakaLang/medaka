#!/usr/bin/env python3
"""Offline integrity checks for the official-PDS secp256k1 did:key corpus."""

import hashlib
import pathlib
import re
import shutil
import sys
import tempfile


PDS_DIGEST = "sha256:d95725b24dbe53af9d91dc69750556931ebed6c396f2cfa42b221434db642f12"
PDS_IMAGE = f"ghcr.io/bluesky-social/pds@{PDS_DIGEST}"
PDS_REVISION = "374cf1d4ba782d4391bbb73e4e2d3f320d4846d6"
PDS_VERSION = "0.4.5027 (@atproto/pds 0.5.27, @atproto/crypto 0.5.4)"
PDS_PACKAGE = "@atproto/crypto@0.5.4"
PDS_PACKAGE_PATH = (
    "/app/node_modules/.pnpm/@atproto+crypto@0.5.4/node_modules/"
    "@atproto/crypto/dist/secp256k1/keypair.js"
)
SIGNING_INPUTS_SHA = "94da19c323a5c96d5a7b41e99fc9806081c565deae7d69ef3390fad7418fa6b8"
CORPUS_PATH = pathlib.Path("pds/test/vectors/pds_did_key_corpus.txt")
SIGNING_CORPUS_PATH = pathlib.Path("pds/test/vectors/pds_message_signing_corpus.txt")
ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


class CheckFailure(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise CheckFailure(message)


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def base58_decode(text: str) -> bytes:
    require(text != "", "DID has an empty base58btc payload")
    require(all(character in ALPHABET for character in text), "DID has invalid base58btc syntax")
    value = 0
    for character in text:
        value = value * 58 + ALPHABET.index(character)
    body = b"" if value == 0 else value.to_bytes((value.bit_length() + 7) // 8, "big")
    return bytes(len(text) - len(text.lstrip("1"))) + body


def base58_encode(data: bytes) -> str:
    value = int.from_bytes(data, "big")
    encoded = ""
    while value:
        value, digit = divmod(value, 58)
        encoded = ALPHABET[digit] + encoded
    return "1" * (len(data) - len(data.lstrip(b"\x00"))) + encoded


def check_inputs(root: pathlib.Path) -> list[tuple[int, str]]:
    path = root / "pds/tools/signing_inputs.txt"
    require(sha256(path) == SIGNING_INPUTS_SHA, "fixed input manifest digest drifted")
    rows = []
    for line in path.read_text().splitlines():
        if line.startswith("key "):
            fields = line.split()
            require(len(fields) == 3, "malformed fixed key input row")
            rows.append((int(fields[1]), fields[2]))
    require([row[0] for row in rows] == list(range(16)), "fixed key inputs changed or reordered")
    require(
        all(re.fullmatch(r"[0-9a-f]{64}", row[1]) for row in rows),
        "fixed key input syntax drifted",
    )
    require(len({row[1] for row in rows}) == 16, "fixed key inputs are not unique")
    return rows


def check_signing_mapping(
    root: pathlib.Path, fixed_inputs: list[tuple[int, str]]
) -> list[str]:
    rows = []
    for line in (root / SIGNING_CORPUS_PATH).read_text().splitlines():
        fields = line.split()
        if fields and fields[0] == "pds":
            rows.append(fields)
            if len(rows) == 16:
                break
    require(len(rows) == 16, "official-PDS signing corpus has fewer than 16 pds rows")

    public_keys = []
    for expected_id, fields in enumerate(rows):
        require(len(fields) == 8, f"official-PDS signing row {expected_id} is malformed")
        require(
            fields[1] == str(expected_id),
            f"official-PDS signing row IDs changed or reordered at {expected_id}",
        )
        require(
            fields[2] == fixed_inputs[expected_id][1],
            f"official-PDS signing row {expected_id} does not match fixed key input",
        )
        public_key = fields[5]
        require(
            re.fullmatch(r"(?:02|03)[0-9a-f]{64}", public_key) is not None,
            f"official-PDS signing row {expected_id} has malformed compressed public key",
        )
        public_keys.append(public_key)
    require(len(set(public_keys)) == 16, "official-PDS signing public keys are not unique")
    return public_keys


def check_authority_routes(root: pathlib.Path) -> None:
    generator = (root / "pds/tools/gen_did_key_corpus.sh").read_text()
    extractor = (root / "pds/tools/extract_pds_did_keys.mjs").read_text()

    generator_anchors = [
        f"PDS_IMAGE={PDS_IMAGE}",
        f"PDS_REVISION={PDS_REVISION}",
        f"PDS_CRYPTO_PACKAGE={PDS_PACKAGE}",
        "docker image inspect --format",
        '"$actual_revision" = "$PDS_REVISION"',
        "docker run --rm --entrypoint node",
        '-v "$HERE:/medaka-tools:ro" "$PDS_IMAGE"',
        "/medaka-tools/extract_pds_did_keys.mjs /medaka-tools/signing_inputs.txt",
    ]
    for anchor in generator_anchors:
        require(generator.count(anchor) == 1, f"generator authority route missing or duplicated: {anchor}")

    extractor_anchors = [
        f"from '{PDS_PACKAGE_PATH}'",
        "const pair = await Secp256k1Keypair.import(key, { exportable: false })",
        "const publicKey = Buffer.from(pair.publicKeyBytes()).toString('hex')",
        "const did = await pair.did()",
        "console.log(`did-key ${id} ${publicKey} ${did}`)",
    ]
    for anchor in extractor_anchors:
        require(extractor.count(anchor) == 1, f"direct pair.did() route missing or duplicated: {anchor}")
    require("console.log(`did-key ${id} ${key}" not in extractor, "extractor would persist private keys")


def check_corpus(path: pathlib.Path, expected_public_keys: list[str]) -> None:
    lines = path.read_text().splitlines()
    require(len(lines) == 16, f"corpus has {len(lines)} rows, expected 16")
    public_keys = set()
    dids = set()
    for expected_id, line in enumerate(lines):
        fields = line.split()
        require(len(fields) == 4 and fields[0] == "did-key", "malformed did:key corpus row")
        require(fields[1] == str(expected_id), f"corpus row IDs changed or reordered at {expected_id}")
        public_key, did = fields[2:]
        require(
            re.fullmatch(r"(?:02|03)[0-9a-f]{64}", public_key) is not None,
            f"row {expected_id} has malformed compressed public key",
        )
        require(
            public_key == expected_public_keys[expected_id],
            f"row {expected_id} public key does not match fixed signing input",
        )
        require(did.startswith("did:key:z"), f"row {expected_id} has malformed did:key syntax")
        payload_text = did[len("did:key:z") :]
        payload = base58_decode(payload_text)
        expected_payload = bytes.fromhex("e701" + public_key)
        require(payload == expected_payload, f"row {expected_id} DID payload does not match public key")
        require(base58_encode(payload) == payload_text, f"row {expected_id} DID is not canonical base58btc")
        public_keys.add(public_key)
        dids.add(did)
    require(len(public_keys) == 16, "corpus public keys are not unique")
    require(len(dids) == 16, "corpus DIDs are not unique")


def parse_stanzas(path: pathlib.Path) -> list[tuple[str, dict[str, str]]]:
    stanzas = []
    kind = None
    values = {}
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped in ("[impl]", "[vector]"):
            if kind is not None:
                stanzas.append((kind, values))
            kind = stripped[1:-1]
            values = {}
            continue
        if kind is not None and ":" in stripped:
            key, value = stripped.split(":", 1)
            values[key.strip()] = value.strip()
    if kind is not None:
        stanzas.append((kind, values))
    return stanzas


def check_provenance(root: pathlib.Path, corpus: pathlib.Path) -> None:
    ledger = parse_stanzas(root / "pds/test/VECTOR-PROVENANCE.txt")
    impls = [values for kind, values in ledger if kind == "impl" and values.get("id") == "official-pds"]
    require(len(impls) == 1, "official-pds authority stanza is missing or duplicated")
    impl = impls[0]
    require(impl.get("repo") == "https://github.com/bluesky-social/pds", "official-pds repo drifted")
    require(impl.get("version") == PDS_VERSION, "official-pds package pin drifted")
    require(impl.get("commit") == PDS_REVISION, "official-pds revision pin drifted")
    require(PDS_IMAGE in impl.get("notes", ""), "official-pds image pin drifted")
    require("did()" in impl.get("notes", ""), "official-pds direct DID authority note is absent")

    rows = [
        values
        for kind, values in ledger
        if kind == "vector" and values.get("file") == CORPUS_PATH.as_posix()
    ]
    require(len(rows) == 1, "did:key corpus provenance row is missing or duplicated")
    row = rows[0]
    expected = {
        "local-sha256": sha256(corpus),
        "kind": "reference-impl",
        "impl": "official-pds",
        "source-url": PDS_IMAGE,
        "retrieved": "2026-08-27",
        "consumer": "P0C-D-did-key-oracle (#1701 did:key)",
    }
    for key, value in expected.items():
        require(row.get(key) == value, f"did:key provenance {key} drifted")
    extraction = row.get("extraction", "")
    require("pds/tools/gen_did_key_corpus.sh" in extraction, "did:key generator provenance is absent")
    require("pair.did() directly" in extraction, "direct pair.did() provenance is absent")


def check_root(root: pathlib.Path, corpus_override: pathlib.Path | None = None) -> None:
    fixed_inputs = check_inputs(root)
    expected_public_keys = check_signing_mapping(root, fixed_inputs)
    check_authority_routes(root)
    corpus = corpus_override or root / CORPUS_PATH
    check_corpus(corpus, expected_public_keys)
    if corpus_override is None:
        check_provenance(root, corpus)


def copy_fixture(root: pathlib.Path, destination: pathlib.Path) -> None:
    paths = [
        "pds/tools/signing_inputs.txt",
        "pds/tools/gen_did_key_corpus.sh",
        "pds/tools/extract_pds_did_keys.mjs",
        "pds/test/vectors/pds_did_key_corpus.txt",
        "pds/test/vectors/pds_message_signing_corpus.txt",
        "pds/test/VECTOR-PROVENANCE.txt",
    ]
    for relative in paths:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / relative, target)


def update_ledger_digest(root: pathlib.Path) -> None:
    ledger_path = root / "pds/test/VECTOR-PROVENANCE.txt"
    corpus_hash = sha256(root / CORPUS_PATH)
    text = ledger_path.read_text()
    marker = f"file:          {CORPUS_PATH.as_posix()}"
    start = text.index(marker)
    digest_start = text.index("local-sha256:", start)
    digest_end = text.index("\n", digest_start)
    text = text[:digest_start] + f"local-sha256:  {corpus_hash}" + text[digest_end:]
    ledger_path.write_text(text)


def expect_mutation_red(
    root: pathlib.Path, label: str, mutate, expected_message: str
) -> None:
    with tempfile.TemporaryDirectory(prefix="medaka-did-key-mutation-") as temporary:
        fixture = pathlib.Path(temporary)
        copy_fixture(root, fixture)
        mutate(fixture)
        try:
            check_root(fixture)
        except CheckFailure as failure:
            require(
                expected_message in str(failure),
                f"{label} red for unrelated reason: {failure}",
            )
            print(f"did_key_corpus self-test: {label}: PASS ({failure})")
            return
        raise CheckFailure(f"{label} unexpectedly passed")


def replace_once(path: pathlib.Path, old: str, new: str) -> None:
    text = path.read_text()
    require(text.count(old) == 1, f"mutation anchor is not unique: {old}")
    path.write_text(text.replace(old, new))


def self_test(root: pathlib.Path) -> None:
    tracked = [
        root / "pds/tools/signing_inputs.txt",
        root / "pds/tools/gen_did_key_corpus.sh",
        root / "pds/tools/extract_pds_did_keys.mjs",
        root / CORPUS_PATH,
        root / SIGNING_CORPUS_PATH,
        root / "pds/test/VECTOR-PROVENANCE.txt",
    ]
    before = {path: sha256(path) for path in tracked}

    expect_mutation_red(
        root,
        "deleted corpus row",
        lambda fixture: replace_once(
            fixture / CORPUS_PATH,
            (fixture / CORPUS_PATH).read_text().splitlines()[-1] + "\n",
            "",
        ),
        "corpus has 15 rows",
    )

    def change_did(fixture: pathlib.Path) -> None:
        path = fixture / CORPUS_PATH
        lines = path.read_text().splitlines()
        fields = lines[0].split()
        replacement = "1" if fields[3][-1] != "1" else "2"
        fields[3] = fields[3][:-1] + replacement
        lines[0] = " ".join(fields)
        path.write_text("\n".join(lines) + "\n")
        update_ledger_digest(fixture)

    expect_mutation_red(root, "changed DID", change_did, "DID payload does not match public key")

    def swap_row_pairs(fixture: pathlib.Path) -> None:
        path = fixture / CORPUS_PATH
        rows = [line.split() for line in path.read_text().splitlines()]
        rows[0][2:], rows[1][2:] = rows[1][2:], rows[0][2:]
        path.write_text("\n".join(" ".join(row) for row in rows) + "\n")
        update_ledger_digest(fixture)

    expect_mutation_red(
        root,
        "swapped public-key/DID row pairs",
        swap_row_pairs,
        "row 0 public key does not match fixed signing input",
    )

    def reorder_inputs(fixture: pathlib.Path) -> None:
        path = fixture / "pds/tools/signing_inputs.txt"
        lines = path.read_text().splitlines()
        first = next(index for index, line in enumerate(lines) if line.startswith("key 0 "))
        lines[first], lines[first + 1] = lines[first + 1], lines[first]
        path.write_text("\n".join(lines) + "\n")

    expect_mutation_red(root, "changed/reordered fixed input", reorder_inputs, "fixed input manifest digest drifted")
    expect_mutation_red(
        root,
        "pair.did() route replaced",
        lambda fixture: replace_once(
            fixture / "pds/tools/extract_pds_did_keys.mjs",
            "const did = await pair.did()",
            "const did = 'did:key:z-replaced'",
        ),
        "direct pair.did() route missing",
    )
    expect_mutation_red(
        root,
        "pinned image drift",
        lambda fixture: replace_once(
            fixture / "pds/tools/gen_did_key_corpus.sh", PDS_DIGEST, "sha256:" + "0" * 64
        ),
        "generator authority route missing",
    )
    expect_mutation_red(
        root,
        "pinned revision drift",
        lambda fixture: replace_once(
            fixture / "pds/tools/gen_did_key_corpus.sh", PDS_REVISION, "0" * 40
        ),
        "generator authority route missing",
    )
    expect_mutation_red(
        root,
        "pinned package drift",
        lambda fixture: replace_once(
            fixture / "pds/tools/extract_pds_did_keys.mjs",
            "@atproto+crypto@0.5.4",
            "@atproto+crypto@0.5.3",
        ),
        "direct pair.did() route missing",
    )

    after = {path: sha256(path) for path in tracked}
    require(before == after, "self-test did not restore tracked inputs byte-exactly")
    print("did_key_corpus self-test: PASS — 8 direct-red mutations; tracked bytes restored")


def main() -> None:
    if len(sys.argv) < 2:
        raise CheckFailure(
            "usage: did_key_corpus_check.py <repo-root> [--self-test|--provenance|--corpus PATH]"
        )
    root = pathlib.Path(sys.argv[1]).resolve()
    args = sys.argv[2:]
    corpus_override = None
    self_tests = False
    provenance = False
    if args == ["--self-test"]:
        self_tests = True
    elif args == ["--provenance"]:
        provenance = True
    elif len(args) == 2 and args[0] == "--corpus":
        corpus_override = pathlib.Path(args[1]).resolve()
    elif args:
        raise CheckFailure(
            "usage: did_key_corpus_check.py <repo-root> [--self-test|--provenance|--corpus PATH]"
        )

    check_root(root, corpus_override)
    if self_tests:
        self_test(root)
    label = "PROVENANCE PASS" if provenance else "PASS"
    print(
        f"did_key_corpus: {label} — 16 ordered unique secp256k1 rows; "
        "fixed-input public keys match official-PDS signing rows; "
        "DIDs decode to 0xe7/0x01 + compressed public key"
    )
    print(
        f"did_key_corpus: pins image={PDS_IMAGE} revision={PDS_REVISION} "
        f"package={PDS_PACKAGE} route=Secp256k1Keypair.did() inputs={SIGNING_INPUTS_SHA}"
    )


if __name__ == "__main__":
    try:
        main()
    except (CheckFailure, FileNotFoundError, ValueError) as failure:
        print(f"did_key_corpus: FAIL: {failure}", file=sys.stderr)
        raise SystemExit(1)
