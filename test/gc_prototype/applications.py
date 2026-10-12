#!/usr/bin/env python3
"""Opt-in Boehm application smoke/performance driver; not a CI gate.

Correctness mode builds the PDS and gzip CLI applications, then checks their
outputs against independent oracles. Measure mode times fresh CLI processes in
two explicitly named Boehm heap-policy cohorts. GC_PRINT_STATS is collected in
separate untimed processes so diagnostics never contaminate wall samples.
The opt-in --varint-only path builds the actual PDS varint encoder entry and
checks byte content and repeated consumption; measurement is not enabled there.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import shutil
import statistics
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SCRATCH = Path("/tmp/pool-verify-applications")
APP_SOURCES = {
    "pds": ROOT / "pds/test/performance_resource_main.mdk",
    "deflate": ROOT / "gzip/deflate_demo.mdk",
    "inflate": ROOT / "gzip/inflate_demo.mdk",
}
VARINT_SOURCE = ROOT / "pds/test/gc_varint_main.mdk"
SEED_GZIP = ROOT / "compiler/seed/emitter.ll.gz"
RUNTIME = ROOT / "runtime/medaka_rt.c"
EMITTER_SOURCE = ROOT / "compiler/backend/llvm_emit.mdk"
MEDAKA = ROOT / "medaka"
EMITTER = ROOT / "medaka_emitter"
def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(ROOT), *args], check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.decode().strip()


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def source_manifest() -> dict[str, str]:
    paths = {"pds/test/performance_resource_main.mdk", "gzip/deflate_demo.mdk", "gzip/inflate_demo.mdk",
             "runtime/medaka_rt.c", "compiler/backend/llvm_emit.mdk"}
    for source_root in (ROOT / "compiler", ROOT / "stdlib"):
        for path in source_root.rglob("*.mdk"):
            if not path.name.endswith("_test.mdk"):
                paths.add(path.relative_to(ROOT).as_posix())
    for project in (ROOT / "pds", ROOT / "gzip"):
        paths.update(path.relative_to(ROOT).as_posix() for path in project.rglob("*.mdk"))
    return {rel: sha256(ROOT / rel) for rel in sorted(paths)}


def provenance(scratch: Path, binary_names: tuple[str, ...] =
               ("performance_resource", "deflate_demo", "inflate_demo")) -> dict[str, object]:
    try:
        pkg = subprocess.run(["pkg-config", "--modversion", "bdw-gc"], check=True,
                             text=True, capture_output=True)
        gc_version = pkg.stdout.strip()
        gc_link_flags = subprocess.run(["pkg-config", "--libs", "--static", "bdw-gc"], check=True,
                                       text=True, capture_output=True).stdout.strip()
        libdir = subprocess.run(["pkg-config", "--variable=libdir", "bdw-gc"], check=True,
                                text=True, capture_output=True).stdout.strip()
        archive = Path(libdir) / "libgc.a"
    except (OSError, subprocess.CalledProcessError):
        prefix = subprocess.run(["brew", "--prefix", "bdw-gc"], check=True,
                                text=True, capture_output=True).stdout.strip()
        gc_version = "Homebrew headers; runtime version in linked artifact"
        gc_link_flags = f"-L{prefix}/lib -lgc"
        archive = Path(prefix) / "lib/libgc.a"
    clang_bin = shutil.which("clang")
    if not clang_bin:
        raise RuntimeError("clang is required for application provenance")
    clang_version = subprocess.run([clang_bin, "--version"], check=True, text=True,
                                   capture_output=True).stdout.splitlines()[0]
    linkage_rows = []
    for name in binary_names:
        binary = scratch / name
        linkage_command = (["otool", "-L", str(binary)] if sys.platform == "darwin"
                           else ["ldd", str(binary)])
        linkage = subprocess.run(linkage_command, check=False, text=True, capture_output=True)
        if linkage.returncode != 0:
            raise RuntimeError(f"dependency inspection failed for {binary}: {linkage.stderr}")
        stable_output = re.sub(r"\s+\(0x[0-9a-fA-F]+\)", "", linkage.stdout)
        linkage_rows.append({"binary": str(binary), "command": linkage_command,
                             "output": stable_output.strip(), "returncode": linkage.returncode})
    if any("libgc" in row["output"] for row in linkage_rows):
        raise RuntimeError("an application unexpectedly dynamically links libgc")
    return {
        "source_commit": git("rev-parse", "HEAD"),
        "platform": platform.platform(), "machine": platform.machine(),
        "source_sha256": source_manifest(), "applications_driver_sha256": sha256(Path(__file__).resolve()),
        "medaka_binary": str(MEDAKA), "medaka_binary_sha256": sha256(MEDAKA),
        "emitter_binary": str(EMITTER), "emitter_binary_sha256": sha256(EMITTER),
        "emitter_source": str(EMITTER_SOURCE), "emitter_source_sha256": sha256(EMITTER_SOURCE),
        "runtime_source": str(RUNTIME), "runtime_source_sha256": sha256(RUNTIME),
        "clang_binary": clang_bin, "clang_version": clang_version,
        "libgc_pkg_config_version": gc_version,
        "libgc_pkg_config_link_flags": gc_link_flags,
        "libgc_archive": str(archive) if archive.is_file() else None,
        "libgc_archive_sha256": sha256(archive) if archive.is_file() else None,
        "application_linkage": "static libgc (libgc absent from platform dependency output)",
        "application_dependencies": linkage_rows,
        "build_environment": {"CC": "clang", "MEDAKA_STRICT": "1", "MEDAKA_CLANG_OPT": "-O2"},
    }


def run(argv: list[str], *, env: dict[str, str], timeout: int,
        capture: bool = True) -> subprocess.CompletedProcess[str]:
    child = subprocess.Popen(argv, cwd=ROOT, env=env, text=True,
                             stdout=subprocess.PIPE if capture else None,
                             stderr=subprocess.PIPE if capture else None,
                             start_new_session=True)
    try:
        stdout, stderr = child.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        stdout, stderr = child.communicate()
        raise subprocess.TimeoutExpired(argv, timeout, output=stdout, stderr=stderr)
    return subprocess.CompletedProcess(argv, child.returncode, stdout, stderr)


def clean_env() -> dict[str, str]:
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(("GC_", "MEDAKA_")):
            del env[key]
    return env


def app_env(cohort: str, *, stats: bool = False) -> dict[str, str]:
    env = clean_env()
    env["GC_FREE_SPACE_DIVISOR"] = "1"
    if cohort == "fixed128m":
        env["GC_INITIAL_HEAP_SIZE"] = "134217728"
    elif cohort != "default":
        raise ValueError(f"unknown heap cohort: {cohort}")
    if stats:
        env["GC_PRINT_STATS"] = "1"
    return env


def write_incompressible(path: Path, size: int) -> None:
    # SHA-256(counter) is deterministic across Python implementations and does
    # not depend on the platform's PRNG implementation.
    out = bytearray()
    counter = 0
    while len(out) < size:
        out.extend(hashlib.sha256(b"medaka-app-input-v1:" + counter.to_bytes(8, "big")).digest())
        counter += 1
    path.write_bytes(out[:size])


def command_record(argv: list[str], env: dict[str, str]) -> dict[str, object]:
    return {"argv": argv, "cwd": str(ROOT), "environment": {
        k: env[k] for k in sorted(env) if k.startswith(("GC_", "MEDAKA_")) or k == "CC"
    }}


def checked(argv: list[str], env: dict[str, str], timeout: int,
            label: str) -> subprocess.CompletedProcess[str]:
    p = run(argv, env=env, timeout=timeout)
    if p.returncode != 0:
        raise RuntimeError(f"{label} failed ({p.returncode}): {p.stderr[-3000:]}")
    return p


def build_apps(scratch: Path, timeout: int, *, varint_only: bool = False) -> dict[str, object]:
    env = clean_env()
    env.update({"CC": "clang", "MEDAKA_STRICT": "1", "MEDAKA_CLANG_OPT": "-O2"})
    sources = {"varint": VARINT_SOURCE} if varint_only else APP_SOURCES
    fresh = [str(MEDAKA), "check", str(next(iter(sources.values())))]
    p = checked(fresh, env, timeout, "strict freshness check")
    builds = []
    bins = {"varint": scratch / "gc_varint"} if varint_only else {
        "pds": scratch / "performance_resource",
        "deflate": scratch / "deflate_demo",
        "inflate": scratch / "inflate_demo",
    }
    for name, source in sources.items():
        argv = [str(MEDAKA), "build", str(source), "-o", str(bins[name])]
        bp = checked(argv, env, timeout, f"build {name}")
        builds.append({"name": name, "command": command_record(argv, env),
                       "stdout": bp.stdout.strip(), "stderr": bp.stderr.strip(),
                       "binary": str(bins[name]), "binary_sha256": sha256(bins[name])})
    return {
        "freshness_check": {"command": command_record(fresh, env),
                            "returncode": p.returncode,
                            "stdout": p.stdout.strip(), "stderr": p.stderr.strip()},
        "builds": builds,
        "binaries": {k: str(v) for k, v in bins.items()},
    }


def unsigned_leb128(value: int) -> bytes:
    if not 0 <= value <= (1 << 62) - 1:
        raise ValueError("varint oracle input is outside Medaka's nonnegative Int range")
    output = bytearray()
    while True:
        value, digit = divmod(value, 128)
        output.append(digit + (128 if value else 0))
        if not value:
            return bytes(output)


def varint_expected(value: int, count: int | None = None) -> tuple[str, dict[str, object]]:
    encoded = unsigned_leb128(value)
    oracle = {"value": value, "expected_hex": encoded.hex(), "encoded_length": len(encoded)}
    if count is None:
        return f"VARINT {value} {encoded.hex()}\n", oracle
    checksum = 0
    for _ in range(count):
        for byte in encoded:
            checksum = (checksum * 257 + byte) % 1_000_000_007
    oracle.update({"count": count, "expected_total_bytes": count * len(encoded),
                   "expected_checksum": checksum})
    return f"VARINTREPEAT {count} {value} {count * len(encoded)} {checksum}\n", oracle


def verify_varint(p: subprocess.CompletedProcess[str], value: int,
                  count: int | None = None) -> dict[str, object]:
    expected, oracle = varint_expected(value, count)
    if p.returncode != 0 or p.stderr or p.stdout != expected:
        raise RuntimeError(f"varint oracle mismatch: expected {expected!r}, "
                           f"exit={p.returncode}, stdout={p.stdout!r}, stderr={p.stderr!r}")
    return {**oracle, "stdout": p.stdout, "stderr": p.stderr,
            "returncode": p.returncode, "byte_content_oracle_passed": True}


def varint_validator_controls() -> list[dict[str, object]]:
    encoded, _ = varint_expected(128)
    repeated, _ = varint_expected(128, 256)
    repeat_fields = repeated.strip().split(" ")
    controls = [("wrong_byte", "VARINT 128 8101\n", 128, None, 0, ""),
                ("wrong_value", "VARINT 129 8001\n", 128, None, 0, ""),
                ("missing_stdout", "", 128, None, 0, ""),
                ("truncated_stdout", encoded[:-1], 128, None, 0, ""),
                ("duplicate_stdout", encoded * 2, 128, None, 0, ""),
                ("extra_stdout", encoded + "extra\n", 128, None, 0, ""),
                ("nonzero_exit", encoded, 128, None, 1, ""),
                ("stderr_output", encoded, 128, None, 0, "unexpected diagnostic\n")]
    for label, index in [("wrong_repeat_count", 1), ("wrong_byte_count", 3), ("wrong_checksum", 4)]:
        fields = repeat_fields.copy()
        fields[index] = str(int(fields[index]) + 1)
        controls.append((label, " ".join(fields) + "\n", 128, 256, 0, ""))
    results = []
    for name, stdout, value, count, code, stderr in controls:
        p = subprocess.CompletedProcess(["validator-control", name], code, stdout, stderr)
        try:
            verify_varint(p, value, count)
        except RuntimeError as exc:
            results.append({"control": name, "rejected": True, "reason": str(exc)})
        else:
            raise RuntimeError(f"varint validator accepted its {name} control")
    return results


def varint_correctness(binary: str, timeout: int) -> dict[str, object]:
    values = sorted({0, 1, 255, 300, (1 << 62) - 1} |
                    {boundary + offset for k in range(1, 9)
                     for boundary in [1 << (7 * k)] for offset in (-1, 0, 1)})
    env = app_env("default")
    results = []
    for value in values:
        argv = [binary, "encode", str(value)]
        p = run(argv, env=env, timeout=timeout)
        results.append({"case": f"varint-{value}", "argv": argv, **verify_varint(p, value)})
    for value in (0, 128, 1 << 56, (1 << 62) - 1):
        argv = [binary, "repeat", "256", str(value)]
        p = run(argv, env=env, timeout=timeout)
        results.append({"case": f"varint-repeat-256-{value}", "argv": argv,
                        **verify_varint(p, value, 256)})
    negative_argv = [binary, "encode", "-1"]
    negative = run(negative_argv, env=env, timeout=timeout)
    diagnostic = "uvarint: negative value -1 (unsigned-varint encodes non-negative values only)"
    if negative.returncode != 1 or negative.stdout or diagnostic not in negative.stderr:
        raise RuntimeError(f"varint negative-input contract failed: {negative}")
    invalid_repeats = []
    repeat_diagnostic = "gc_varint: repeat count must be positive"
    for count in (0, -1):
        argv = [binary, "repeat", str(count), "128"]
        p = run(argv, env=env, timeout=timeout)
        if p.returncode != 1 or p.stdout or repeat_diagnostic not in p.stderr:
            raise RuntimeError(f"varint repeat-count contract failed: {p}")
        invalid_repeats.append({"argv": argv, "count": count, "returncode": p.returncode,
                                "stdout": p.stdout, "stderr": p.stderr,
                                "required_diagnostic": repeat_diagnostic, "rejected": True})
    return {"oracle": "independent Python unsigned LEB128 via divmod(128); exact hex and rolling byte checksum",
            "inputs": values, "encode_cases": len(values), "repetition_cases": 4,
            "results": results, "negative_input": {"argv": negative_argv,
                "returncode": negative.returncode, "stdout": negative.stdout,
                "stderr": negative.stderr, "required_diagnostic": diagnostic, "rejected": True},
            "invalid_repeat_counts": invalid_repeats,
            "validator_controls": varint_validator_controls(),
            "builder_growth": "real bytebuilder starts at capacity 0; nine-byte encodings grow through 1, 2, 4, 8, 16; no runtime allocation counts inferred",
            "collector": "production Boehm; custom collector execution is not established"}


def app_cases(scratch: Path) -> tuple[list[dict[str, object]], dict[str, object]]:
    repeated = scratch / "repeated-101700.txt"
    phrase = b"The quick brown fox jumps over the lazy dog.\n"
    repeated.write_bytes((phrase * ((101700 + len(phrase) - 1) // len(phrase)))[:101700])
    noisy50 = scratch / "sha256-counter-50000.bin"
    noisy200 = scratch / "sha256-counter-200000.bin"
    write_incompressible(noisy50, 50_000)
    write_incompressible(noisy200, 200_000)
    inputs = [repeated, noisy50, noisy200]
    records = [{"path": str(p), "size_bytes": p.stat().st_size, "sha256": sha256(p)} for p in inputs]
    seed_out = scratch / "emitter.ll.from-seed.gz"
    with seed_out.open("wb") as f:
        subprocess.run(["/usr/bin/gzip", "-dc", str(SEED_GZIP)], stdout=f, check=True,
                       env=clean_env(), timeout=120)
    return ([{"name": p.stem, "input": str(p)} for p in inputs], {
        "inputs": records,
        "seed_gzip": {"path": str(SEED_GZIP), "sha256": sha256(SEED_GZIP),
                      "decoded_path": str(seed_out), "decoded_size_bytes": seed_out.stat().st_size,
                      "decoded_sha256": sha256(seed_out)},
    })


def correctness(scratch: Path, bins: dict[str, str], timeout: int) -> list[dict[str, object]]:
    env = app_env("default")
    results: list[dict[str, object]] = []
    pds = bins["pds"]
    for n in (16, 1000, 2000):
        p = checked([pds, "car", str(n)], env, timeout, f"CAR {n}")
        m = re.fullmatch(r"CAR (\d+) (\d+)", p.stdout.strip())
        expected_bytes = 59 + 40 * n
        if not m or int(m.group(1)) != n or int(m.group(2)) != expected_bytes:
            raise RuntimeError(f"unexpected CAR output for n={n}: {p.stdout!r}")
        results.append({"case": f"car-{n}", "argv": [pds, "car", str(n)], "stdout": p.stdout.strip(),
                        "car_bytes": int(m.group(2)), "expected_car_bytes_59_plus_40n": expected_bytes,
                        "car_size_formula_passed": True, "returncode": p.returncode})
    for n in (1000, 2000):
        argv = [pds, "mst-insert", str(n)]
        p = checked(argv, env, timeout, f"MST insert {n}")
        m = re.fullmatch(r"MSTINSERT (\d+) (\d+) allocBytes=(\d+)", p.stdout.strip())
        if not m or int(m.group(1)) != n or int(m.group(2)) != n:
            raise RuntimeError(f"unexpected MST insert output for n={n}: {p.stdout!r}")
        results.append({"case": f"mst-insert-{n}", "argv": argv, "stdout": p.stdout.strip(),
                        "entry_count": int(m.group(2)), "alloc_bytes": int(m.group(3)),
                        "entry_count_scope": "CLI reports length(mstEntries tree); this does not inspect all key/CID/root contents",
                        "alloc_bytes_scope": "native allocBytes delta from Boehm accounting; not logical payload bytes or live bytes",
                        "returncode": p.returncode})

    for input_info in sorted(scratch.glob("repeated-101700.txt")) + sorted(scratch.glob("sha256-counter-*.bin")):
        label = input_info.stem
        app_gz = scratch / f"{label}.application.gz"
        decoded_app = scratch / f"{label}.application.decoded"
        system_gz = scratch / f"{label}.system.gz"
        decoded_system = scratch / f"{label}.system.decoded"
        argv = [bins["deflate"], str(input_info), str(app_gz)]
        p = checked(argv, env, timeout, f"application deflate {label}")
        checked(["/usr/bin/gzip", "-t", str(app_gz)], env, timeout, f"system gzip test {label}")
        with decoded_app.open("wb") as f:
            sys_dec = subprocess.run(["/usr/bin/gzip", "-dc", str(app_gz)],
                                     stdout=f, stderr=subprocess.PIPE, check=False, timeout=timeout,
                                     env=clean_env())
        if sys_dec.returncode != 0:
            raise RuntimeError(f"system gzip decode failed {label}: {sys_dec.stderr.decode(errors='replace')}")
        checked(["cmp", "-s", str(input_info), str(decoded_app)], env, timeout,
                f"compare app gzip with system gunzip {label}")
        decoded_app.unlink()
        checked([bins["inflate"], str(app_gz), str(decoded_app)], env, timeout, f"application inflate app gzip {label}")
        checked(["cmp", "-s", str(input_info), str(decoded_app)], env, timeout, f"compare app roundtrip {label}")
        # -n fixes header timestamps and original filename for reproducibility.
        with system_gz.open("wb") as f:
            sp = subprocess.run(["/usr/bin/gzip", "-n", "-c", str(input_info)],
                                stdout=f, stderr=subprocess.PIPE, check=False, timeout=timeout,
                                env=clean_env())
        if sp.returncode:
            raise RuntimeError(f"system gzip failed {label}: {sp.stderr.decode(errors='replace')}")
        checked([bins["inflate"], str(system_gz), str(decoded_system)], env, timeout,
                f"application inflate system gzip {label}")
        checked(["cmp", "-s", str(input_info), str(decoded_system)], env, timeout,
                f"compare system gzip decode {label}")
        results.append({"case": f"gzip-{label}", "input_sha256": sha256(input_info),
                        "input_bytes": input_info.stat().st_size,
                        "application_gzip_sha256": sha256(app_gz), "application_gzip_bytes": app_gz.stat().st_size,
                        "system_gzip_sha256": sha256(system_gz), "system_gzip_bytes": system_gz.stat().st_size,
                        "application_deflate_then_system_gzip_test_and_system_gunzip_cmp": True,
                        "application_deflate_then_application_inflate_cmp": True,
                        "system_gzip_then_application_inflate_cmp": True})

    seed_gz = SEED_GZIP
    seed_out = scratch / "emitter.ll.from-app-inflate.gz"
    expected = scratch / "emitter.ll.from-seed.gz"
    checked([bins["inflate"], str(seed_gz), str(seed_out)], env, timeout, "inflate committed seed")
    checked(["cmp", "-s", str(expected), str(seed_out)], env, timeout, "compare seed inflate")
    results.append({"case": "inflate-committed-seed", "input_sha256": sha256(seed_gz),
                    "output_sha256": sha256(seed_out), "output_bytes": seed_out.stat().st_size,
                    "system_gzip_decode_cmp": True})
    return results


def measurement_cases(scratch: Path, bins: dict[str, str]) -> list[dict[str, object]]:
    cases: list[dict[str, object]] = []
    for n in (16, 1000, 2000):
        expected_bytes = 59 + 40 * n
        cases.append({"name": f"car-{n}", "argv": [bins["pds"], "car", str(n)],
                      "expected_car_bytes": expected_bytes,
                      "oracle": f"CAR {n} {expected_bytes} (59 + 40*n)"})
    for n in (1000, 2000):
        cases.append({"name": f"mst-insert-{n}", "argv": [bins["pds"], "mst-insert", str(n)],
                      "oracle": f"MSTINSERT {n} {n} allocBytes=<nonnegative>"})
    for source in sorted(scratch.glob("repeated-101700.txt")) + sorted(scratch.glob("sha256-counter-*.bin")):
        app_gz = scratch / f"{source.stem}.measured.application.gz"
        cases.append({"name": f"deflate-{source.stem}", "argv": [bins["deflate"], str(source), str(app_gz)],
                      "output_gzip": str(app_gz), "input": str(source), "oracle": "gzip -t and gunzip -c cmp input"})
        # Use the system-created gzip as the input for measured application inflate.
        sys_gz = scratch / f"{source.stem}.measured.system.gz"
        with sys_gz.open("wb") as f:
            subprocess.run(["/usr/bin/gzip", "-n", "-c", str(source)], stdout=f, check=True,
                           env=clean_env(), timeout=120)
        app_out = scratch / f"{source.stem}.measured.inflate.out"
        cases.append({"name": f"inflate-{source.stem}", "argv": [bins["inflate"], str(sys_gz), str(app_out)],
                      "output": str(app_out), "input": str(source), "compressed_input": str(sys_gz),
                      "compressed_input_sha256": sha256(sys_gz), "oracle": "cmp output input"})
    seed_out = scratch / "emitter.ll.measured.inflate.out"
    cases.append({"name": "inflate-committed-seed", "argv": [bins["inflate"], str(SEED_GZIP), str(seed_out)],
                  "output": str(seed_out), "compressed_input_sha256": sha256(SEED_GZIP),
                  "oracle_sha256": sha256(scratch / "emitter.ll.from-seed.gz")})
    return cases


def verify_output(case: dict[str, object], stdout: str, scratch: Path) -> None:
    name = str(case["name"])
    if name.startswith("car-"):
        n = name.split("-")[-1]
        expected = int(case["expected_car_bytes"])
        if not re.fullmatch(rf"CAR {n} {expected}", stdout.strip()):
            raise RuntimeError(f"timed CAR output mismatch: {stdout!r}")
    elif name.startswith("mst-insert-"):
        n = name.split("-")[-1]
        if not re.fullmatch(rf"MSTINSERT {n} {n} allocBytes=\d+", stdout.strip()):
            raise RuntimeError(f"timed MST output mismatch: {stdout!r}")
    elif "output_gzip" in case:
        gz = Path(str(case["output_gzip"]))
        subprocess.run(["/usr/bin/gzip", "-t", str(gz)], check=True, timeout=60, env=clean_env())
        decoded = subprocess.run(["/usr/bin/gzip", "-dc", str(gz)], check=True,
                                 stdout=subprocess.PIPE, timeout=60, env=clean_env()).stdout
        if decoded != Path(str(case["input"])).read_bytes():
            raise RuntimeError(f"timed gzip oracle mismatch: {name}")
    elif "output" in case:
        output = Path(str(case["output"]))
        if name == "inflate-committed-seed":
            if sha256(output) != case["oracle_sha256"]:
                raise RuntimeError("timed seed inflate hash mismatch")
        elif output.read_bytes() != Path(str(case["input"])).read_bytes():
            raise RuntimeError(f"timed inflate oracle mismatch: {name}")


def gc_stats(text: str) -> dict[str, object]:
    cycles = re.findall(r"Marking for collection #(\d+) after (\d+) allocated bytes", text)
    durations = re.findall(r"Complete collection took (\d+) ms (\d+) ns", text)
    heaps = re.findall(r"GC #\d+ freed (-?\d+) bytes, heap (\d+) KiB", text)
    if not cycles:
        raise RuntimeError("GC_PRINT_STATS produced no collection boundary diagnostics")
    if len(cycles) != len(durations):
        raise RuntimeError(f"incomplete collection timing diagnostics: {len(cycles)} cycles, {len(durations)} durations")
    if len(cycles) != len(heaps):
        raise RuntimeError(f"incomplete collection heap diagnostics: {len(cycles)} cycles, {len(heaps)} heap rows")
    return {
        "collections_logged": len(cycles),
        "collection_numbers": [int(number) for number, _ in cycles],
        "allocated_bytes_at_collection_boundaries": sum(int(size) for _, size in cycles),
        "collection_boundary_allocated_bytes": [int(size) for _, size in cycles],
        "reported_freed_bytes": sum(int(size) for size, _ in heaps),
        "max_logged_heap_bytes": max((int(size) * 1024 for _, size in heaps), default=0),
        "full_collection_wall_seconds": sum(int(ms) / 1000 + int(ns) / 1e9 for ms, ns in durations),
        "limitations": "Boehm counters stop at collection boundaries; not exact total allocation or live bytes and omit the final allocation tail.",
    }


def timed_process(argv: list[str], env: dict[str, str], scratch: Path,
                  label: str, timeout: int) -> dict[str, object]:
    stdout_path = scratch / f"{label}.stdout"
    stderr_path = scratch / f"{label}.stderr"
    for path in (stdout_path, stderr_path):
        path.unlink(missing_ok=True)
    start = time.perf_counter()
    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        child = subprocess.Popen(argv, cwd=ROOT, env=env, stdout=stdout, stderr=stderr,
                                  start_new_session=True)
        previous = signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError()))
        signal.setitimer(signal.ITIMER_REAL, timeout)
        try:
            _, status, usage = os.wait4(child.pid, 0)
        except TimeoutError:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.wait4(child.pid, 0)
            child.returncode = -signal.SIGKILL
            raise RuntimeError(f"workload timed out after {timeout}s: {argv}")
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous)
    elapsed = time.perf_counter() - start
    returncode = os.WEXITSTATUS(status) if os.WIFEXITED(status) else -os.WTERMSIG(status)
    child.returncode = returncode
    if returncode != 0:
        raise RuntimeError(f"command failed ({returncode}): {argv}; stderr={stderr_path.read_text(errors='replace')[-3000:]}")
    # ru_maxrss is KiB on Linux, bytes on macOS.
    peak_rss_bytes = int(usage.ru_maxrss * (1024 if sys.platform.startswith("linux") else 1))
    return {"returncode": returncode, "elapsed_seconds": elapsed, "maxrss_bytes": peak_rss_bytes,
            "stdout_path": str(stdout_path), "stderr_path": str(stderr_path),
            "stdout": stdout_path.read_text(errors="replace"),
            "stderr": stderr_path.read_text(errors="replace")}


def measure(scratch: Path, bins: dict[str, str], repeats: int, timeout: int) -> dict[str, object]:
    driver_hash_start = sha256(Path(__file__).resolve())
    if repeats < 1:
        raise ValueError("--repeats must be positive")
    if timeout <= 0:
        raise ValueError("--timeout must be positive")
    cases = measurement_cases(scratch, bins)
    samples = []
    stats_records = []
    for cohort in ("default", "fixed128m"):
        env = app_env(cohort)
        stats_env = app_env(cohort, stats=True)
        for case in cases:
            for output_key in ("output_gzip", "output"):
                if output_key in case:
                    Path(str(case[output_key])).unlink(missing_ok=True)
            stats = run(case["argv"], env=stats_env, timeout=timeout)
            if stats.returncode != 0:
                raise RuntimeError(f"GC_PRINT_STATS run failed {case['name']}: {stats.stderr[-3000:]}")
            verify_output(case, stats.stdout, scratch)
            stats_path = scratch / f"gc-stats-{cohort}-{case['name']}.txt"
            stats_text = stats.stderr + stats.stdout
            stats_path.write_text(stats_text)
            stats_parsed = gc_stats(stats_text)
            stats_records.append({
                "cohort": cohort, "case": case["name"], "argv": case["argv"],
                "env_gc": {k: stats_env[k] for k in sorted(stats_env) if k.startswith("GC_")},
                "returncode": stats.returncode, "stdout": stats.stdout.strip(),
                "gc_stats_sha256": hashlib.sha256(stats_text.encode()).hexdigest(),
                "raw_path": str(stats_path), "stats": stats_parsed,
            })
    # Alternate heap-policy cohorts within each repeated case to limit order bias.
    execution_order = []
    for case in cases:
        for rep in range(repeats):
            cohort_order = ("default", "fixed128m") if rep % 2 == 0 else ("fixed128m", "default")
            for cohort in cohort_order:
                env = app_env(cohort)
                for output_key in ("output_gzip", "output"):
                    if output_key in case:
                        Path(str(case[output_key])).unlink(missing_ok=True)
                label = f"timed-{case['name']}-{rep}-{cohort}"
                p = timed_process(case["argv"], env, scratch, label, timeout)
                verify_output(case, p["stdout"], scratch)
                execution_order.append({"case": case["name"], "repeat": rep, "cohort": cohort})
                samples.append({"cohort": cohort, "case": case["name"], "repeat": rep,
                                "execution_order": len(execution_order) - 1,
                                "argv": case["argv"], "env_gc": {k: env[k] for k in sorted(env) if k.startswith("GC_")},
                                "elapsed_seconds": p["elapsed_seconds"], "maxrss_bytes": p["maxrss_bytes"],
                                "returncode": p["returncode"], "stdout": p["stdout"].strip(),
                                "stdout_path": p["stdout_path"], "stderr_path": p["stderr_path"],
                                "stdout_sha256": sha256(Path(p["stdout_path"])),
                                "stderr_sha256": sha256(Path(p["stderr_path"])),
                                "output_file": (str(case["output_gzip"]) if "output_gzip" in case else
                                                str(case["output"]) if "output" in case else None),
                                "output_size_bytes": (Path(str(case["output_gzip"])).stat().st_size
                                                      if "output_gzip" in case else
                                                      Path(str(case["output"])).stat().st_size
                                                      if "output" in case else None),
                                "output_sha256": (sha256(Path(str(case["output_gzip"])))
                                                  if "output_gzip" in case else
                                                  sha256(Path(str(case["output"]))) if "output" in case else None),
                                "output_oracle_passed": True})
    summary = []
    for cohort in ("default", "fixed128m"):
        for case in cases:
            rows = [row for row in samples if row["cohort"] == cohort and row["case"] == case["name"]]
            elapsed = [float(row["elapsed_seconds"]) for row in rows]
            rss = [int(row["maxrss_bytes"]) for row in rows]
            summary.append({"cohort": cohort, "case": case["name"], "n": len(rows),
                            "elapsed_min_seconds": min(elapsed), "elapsed_median_seconds": statistics.median(elapsed),
                            "elapsed_max_seconds": max(elapsed), "maxrss_min_bytes": min(rss),
                            "maxrss_median_bytes": statistics.median(rss), "maxrss_max_bytes": max(rss)})
    driver_hash_end = sha256(Path(__file__).resolve())
    if driver_hash_start != driver_hash_end:
        raise RuntimeError("applications.py changed during measured execution")
    return {
        "timing_boundary": "fresh application process including CLI startup, input read, computation, and output write; build and input generation outside timing",
        "timing_tool": "Python time.perf_counter around fresh Popen child; os.wait4 rusage",
        "repeats_per_case_per_cohort": repeats,
        "cohorts": {
            "default": "GC_* inherited variables cleared; GC_FREE_SPACE_DIVISOR=1; no GC_INITIAL_HEAP_SIZE override (runtime resizeable default policy)",
            "fixed128m": "GC_* inherited variables cleared; GC_FREE_SPACE_DIVISOR=1; GC_INITIAL_HEAP_SIZE=134217728",
        },
        "environment_policy": "clear inherited GC_* and MEDAKA_* for built app processes; build pins MEDAKA_STRICT=1 and MEDAKA_CLANG_OPT=-O2",
        "gc_print_stats_captured_in_separate_untimed_process": True,
        "applications_driver_sha256_start": driver_hash_start,
        "applications_driver_sha256_end": driver_hash_end,
        "gc_stats": stats_records, "execution_order": execution_order, "summary_min_median_max": summary,
        "cases": cases, "samples": samples,
    }


def write_report(report: dict[str, object], scratch: Path, requested: Path | None,
                 correctness_only: bool) -> Path:
    canonical = scratch / "correctness.json"
    if correctness_only:
        canonical.parent.mkdir(parents=True, exist_ok=True)
        serialized = json.dumps(report, indent=2, sort_keys=True) + "\n"
        canonical.write_text(serialized)
        if requested is not None and requested.resolve() != canonical.resolve():
            requested.parent.mkdir(parents=True, exist_ok=True)
            requested.write_text(serialized)
        return canonical
    target = requested if requested is not None else scratch / "measurements.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    return target


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--correctness-only", action="store_true")
    mode.add_argument("--measure", action="store_true")
    ap.add_argument("--varint-only", action="store_true",
                    help="correctness-only PDS varint integration workload; measurement is not enabled")
    ap.add_argument("--scratch", type=Path, default=DEFAULT_SCRATCH)
    ap.add_argument("--resume", action="store_true",
                    help="reuse an existing scratch directory after validating its correctness manifest")
    ap.add_argument("--output", type=Path)
    ap.add_argument("--repeats", type=int, default=5)
    ap.add_argument("--timeout", type=int, default=120)
    args = ap.parse_args()
    if args.repeats < 1:
        ap.error("--repeats must be positive")
    if args.timeout <= 0:
        ap.error("--timeout must be positive")
    if args.varint_only and args.measure:
        ap.error("--varint-only supports --correctness-only; varint measurement is not enabled")
    if args.varint_only and args.resume:
        ap.error("--varint-only requires fresh scratch; --resume is not supported")
    scratch = args.scratch.resolve()
    if args.measure and not args.resume:
        ap.error("--measure requires --resume to make scratch reuse explicit")
    if args.correctness_only and scratch.exists() and any(scratch.iterdir()):
        ap.error(f"scratch directory is nonempty; choose an empty path: {scratch}")
    scratch.mkdir(parents=True, exist_ok=True)
    requested_report_path = args.output.resolve() if args.output else None

    if args.varint_only:
        build = build_apps(scratch, args.timeout, varint_only=True)
        report = {"schema": "medaka.varint-correctness.v1", "mode": "correctness-only",
                  "application_set": "varint", "source_commit": git("rev-parse", "HEAD"),
                  "provenance": provenance(scratch, ("gc_varint",)), "build": build,
                  "correctness": varint_correctness(build["binaries"]["varint"], args.timeout),
                  "measurement_supported": False}
    elif args.correctness_only:
        build = build_apps(scratch, args.timeout)
        _, inputs = app_cases(scratch)
        correctness_results = correctness(scratch, build["binaries"], args.timeout)
        report = {
            "schema": "medaka.application-benchmark.v1", "mode": "correctness-only",
            "provenance": provenance(scratch),
            "source_commit": git("rev-parse", "HEAD"),
            "toolchain": {"medaka_binary": str(MEDAKA), "medaka_sha256": sha256(MEDAKA),
                          "emitter_binary": str(EMITTER), "emitter_sha256": sha256(EMITTER),
                          "emitter_source": str(EMITTER_SOURCE), "emitter_source_sha256": sha256(EMITTER_SOURCE),
                          "runtime_source": str(RUNTIME), "runtime_source_sha256": sha256(RUNTIME),
                          "initial_heap_policy": "weak runtime constant 0 for application links; no runtime GC_expand_hp unless GC_INITIAL_HEAP_SIZE is set"},
            "inputs": inputs, "build": build, "correctness": correctness_results,
            "measurement_authorized": False,
        }
    else:
        correctness_path = scratch / "correctness.json"
        prior = json.loads(correctness_path.read_text())
        if prior.get("mode") != "correctness-only":
            raise RuntimeError(f"scratch manifest is not correctness-only: {correctness_path}")
        if prior.get("application_set") == "varint":
            raise RuntimeError("varint measurement is not enabled; this manifest is correctness-only")
        current_commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT,
                                        text=True, capture_output=True, check=True).stdout.strip()
        if current_commit != prior["source_commit"]:
            raise RuntimeError("source commit changed since correctness manifest; rerun --correctness-only in a fresh scratch")
        if provenance(scratch) != prior["provenance"]:
            raise RuntimeError("source/toolchain/driver provenance changed since correctness manifest; rerun --correctness-only in a fresh scratch")
        for entry in prior["inputs"]["inputs"]:
            input_path = Path(entry["path"])
            if not input_path.is_file() or input_path.stat().st_size != entry["size_bytes"] or sha256(input_path) != entry["sha256"]:
                raise RuntimeError(f"input changed since correctness manifest: {input_path}")
        decoded_seed = Path(prior["inputs"]["seed_gzip"]["decoded_path"])
        if not decoded_seed.is_file() or sha256(decoded_seed) != prior["inputs"]["seed_gzip"]["decoded_sha256"]:
            raise RuntimeError("decoded seed changed since correctness manifest")
        if not SEED_GZIP.is_file() or sha256(SEED_GZIP) != prior["inputs"]["seed_gzip"]["sha256"]:
            raise RuntimeError("committed seed gzip changed since correctness manifest")
        bins = prior["build"]["binaries"]
        for name, path in bins.items():
            if not Path(path).is_file():
                raise RuntimeError(f"missing built binary {name}: {path}; rerun --correctness-only")
            expected_hash = next(row["binary_sha256"] for row in prior["build"]["builds"] if row["name"] == name)
            if sha256(Path(path)) != expected_hash:
                raise RuntimeError(f"binary {name} changed since correctness manifest; rerun --correctness-only")
        report = {"schema": "medaka.application-benchmark.v1", "mode": "measure",
                  "source_commit": prior["source_commit"], "provenance": prior["provenance"],
                  "toolchain": prior["toolchain"], "correctness_manifest": prior,
                  "inputs": prior["inputs"], "binaries": {k: {"path": v, "sha256": sha256(Path(v))}
                                                               for k, v in bins.items()},
                  "measurement": measure(scratch, bins, args.repeats, args.timeout)}
    report_path = write_report(report, scratch, requested_report_path, args.correctness_only)
    print(report_path)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.TimeoutExpired, RuntimeError, ValueError) as exc:
        print(f"applications.py: {exc}", file=sys.stderr)
        raise SystemExit(1)
