#!/usr/bin/env python3
"""On-demand generated-code GC correctness experiment; no timing claims."""

import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from transform import Rejected, transform
from rejection_checks import check_rejections


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
MAKE = "mdk___user____make"
FIRST = "mdk___user____first"
BOX = {"tag": 0, "fields": ["Int"]}
PAIR = {"tag": 4294967296, "fields": ["Box", "Box"]}
WRAP_FIELD = {"tag": 4294967296, "fields": ["Box"]}
WRAP_NESTED = {"tag": 8589934592, "fields": ["Pair"]}
# Trusted semantic oracle inputs, authored from source declarations, not LTy.
CONTRACTS = {
    "arguments": {"records": {"Box": BOX}, "functions": {
        MAKE: {"args": ["Int"], "result": "Box"},
        FIRST: {"args": ["Box", "Box"], "result": "Int"}}},
    "field": {"records": {"Box": BOX, "Wrap": WRAP_FIELD}, "functions": {
        MAKE: {"args": ["Int"], "result": "Box"}}},
    "nested": {"records": {"Box": BOX, "Pair": PAIR, "Wrap": WRAP_NESTED},
               "functions": {MAKE: {"args": ["Int"], "result": "Box"}}},
}
CASES = {"arguments": (21, [4, 6]), "field": (137, [8, 12]),
         "nested": (89, [40, 56])}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def command(args, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, timeout=180, **kwargs)
    if result.returncode:
        raise RuntimeError("command failed: " + shlex.join(map(str, args)) + "\n"
                           + result.stdout + result.stderr)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emitter", type=Path, default=REPO / "test/bin/llvm_emit_typed_main")
    parser.add_argument("--gc-source", type=Path, default=HERE.parent / "gc.c")
    parser.add_argument("--clang", default="clang")
    parser.add_argument("--output", type=Path, required=True,
                        help="retain emitted/transformed LLVM and provenance here")
    args = parser.parse_args()
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        raise RuntimeError("output directory must be empty; preserve existing evidence: " + str(out))
    out.mkdir(parents=True, exist_ok=True)
    emitter = args.emitter.resolve()
    gc_source = args.gc_source.resolve()
    environment = os.environ.copy()
    environment["MEDAKA_STRICT"] = "1"
    environment["ASAN_OPTIONS"] = "detect_leaks=0:halt_on_error=1"
    environment["UBSAN_OPTIONS"] = "halt_on_error=1:print_stacktrace=1"
    provenance = {"emitter_sha256": digest(emitter.read_bytes()),
                  "gc_sha256": digest(gc_source.read_bytes()),
                  "gc_header_sha256": digest((gc_source.parent / "gc.h").read_bytes()),
                  "transform_sha256": digest((HERE / "transform.py").read_bytes()),
                  "runner_sha256": digest(Path(__file__).read_bytes()),
                  "shim_sha256": digest((HERE / "shim.c").read_bytes()),
                  "independent_checks_sha256": digest((HERE / "rejection_checks.py").read_bytes()),
                  "contracts_sha256": digest(json.dumps(CONTRACTS, sort_keys=True).encode()),
                  "runtime_catalog_sha256": digest((REPO / "stdlib/runtime.mdk").read_bytes()),
                  "git_head": command(["git", "rev-parse", "HEAD"], cwd=REPO).stdout.strip(),
                  "platform": platform.platform(),
                  "contracts": CONTRACTS, "cases": CASES, "sources": {},
                  "compiler": command([args.clang, "--version"]).stdout,
                  "results": []}

    def emit(stem):
        source = HERE / (stem + ".mdk")
        result = command([str(emitter), str(REPO / "stdlib/runtime.mdk"), str(source)],
                         env=environment)
        if result.stderr:
            raise RuntimeError("unexpected emitter diagnostic: " + result.stderr)
        provenance["sources"][stem] = digest(source.read_bytes())
        (out / (stem + ".emitted.ll")).write_text(result.stdout)
        return result.stdout

    raw = {stem: emit(stem) for stem in CASES}
    for stem, reason in [("reject_branch", "unsupported instruction"),
                         ("reject_global", "unsupported module item"),
                         ("reject_helper", "unsupported runtime/indirect call")]:
        try:
            transform(emit(stem), {"records": {}, "functions": {}})
        except Rejected as error:
            if reason not in str(error):
                raise RuntimeError(f"{stem}: wrong rejection: {error}")
            provenance["results"].append({"rejection": stem, "reason": str(error)})
        else:
            raise RuntimeError("unsupported source unexpectedly accepted: " + stem)

    anchor = "  %t1 = getelementptr i8, ptr %t0, i64 8\n  %t2 = load i64, ptr %t1"
    need_raw = raw["arguments"]
    if need_raw.count(anchor) != 1:
        raise RuntimeError("raw pointer liveness control anchor changed")
    ir_controls = {
        "raw_pointer_call": (need_raw.replace(anchor, "  %t99 = call i64 @" + MAKE
          + "(i64 3)\n" + anchor), "raw heap pointer lives across call"),
        "field_bounds": (need_raw.replace(anchor, anchor.replace("i64 8", "i64 16")),
                         "field offset outside record schema"),
        "raw_header_load": (need_raw.replace(anchor, "  %t2 = load i64, ptr %t0"),
                            "load lacks field provenance"),
        "raw_argument": (need_raw.replace("@" + MAKE + "(i64 43)", "@" + MAKE + "(i64 42)"),
                         "constant is not a tagged Int"),
        "constructor_interruption": (need_raw.replace("store i64 %arg0, ptr %t1",
          "store i64 %arg0, ptr %t1\n  %t99 = call i64 @" + MAKE + "(i64 3)"),
                           "constructor does not finish"),
    }
    for stem, (source, reason) in ir_controls.items():
        try:
            transform(source, CONTRACTS["arguments"])
        except Rejected as error:
            if reason not in str(error):
                raise RuntimeError(f"{stem}: wrong rejection: {error}")
            provenance["results"].append({"rejection": stem, "reason": str(error)})
        else:
            raise RuntimeError("invalid IR unexpectedly accepted: " + stem)
    independent = check_rejections(raw["arguments"], CONTRACTS["arguments"], MAKE, FIRST)
    provenance["results"].extend(independent)

    try:
        boehm_flags = shlex.split(command(["pkg-config", "--cflags", "--libs", "bdw-gc"]).stdout)
    except (RuntimeError, FileNotFoundError):
        prefix = command(["brew", "--prefix", "bdw-gc"]).stdout.strip()
        boehm_flags = ["-I" + prefix + "/include", "-L" + prefix + "/lib", "-lgc"]
    provenance["boehm_flags"] = boehm_flags
    successful = 0
    with tempfile.TemporaryDirectory(prefix="medaka-gc-generated-") as scratch:
        def build_run(stem, ir, flags, schedule, mutation=False, boehm=False):
            nonlocal successful
            ll = out / (stem + ".ll")
            ll.write_text(ir)
            binary = Path(scratch) / stem
            cmd = [args.clang, "-g", "-Wall", "-Wextra", "-Werror", "-Wno-override-module",
                   "-I", str(gc_source.parent), f"-DCOLLECT_MASK={schedule}ULL", *flags,
                   str(ll), str(HERE / "shim.c"), str(gc_source), "-o", str(binary)]
            if boehm:
                cmd += ["-DUSE_BOEHM", *boehm_flags]
            command(cmd)
            result = subprocess.run([str(binary)], capture_output=True, text=True,
                                    timeout=30, env=environment)
            fixture = stem.split("-")[0]
            expected = str(CASES[fixture][0]) + "\n"
            allocations = {"arguments": 2, "field": 3, "nested": 5}[fixture]
            stats_pattern = (rf"generated roots: allocations={allocations}, promoted="
                             + ("0" if boehm else "[1-9][0-9]*")
                             + r", roots=0, reclaimed-live=0\n")
            valid_stats = bool(re.fullmatch(stats_pattern, result.stderr))
            correct = result.returncode == 0 and result.stdout == expected and valid_stats
            if mutation:
                witnessed = {"arguments": "43\n", "field": "99\n"}[fixture]
                if not (result.returncode == 0 and result.stdout == witnessed and valid_stats):
                    raise RuntimeError("mutation omitted its semantic mismatch witness: " + stem
                                       + "\n" + result.stdout + result.stderr)
            else:
                if not correct:
                    raise RuntimeError(stem + ": wrong semantic result/status\n" + result.stdout + result.stderr)
                successful += 1
            provenance["results"].append({"run": stem, "command": cmd,
                "schedule": schedule, "mutation": mutation, "exit": result.returncode,
                "stdout": result.stdout, "stderr": result.stderr,
                "emitted_sha256": digest(raw[fixture].encode()), "ir_sha256": digest(ir.encode())})

        for fixture, (_, schedules) in CASES.items():
            ir = transform(raw[fixture], CONTRACTS[fixture])
            for schedule in schedules:
                for opt in ["-O0", "-O2"]:
                    build_run(f"{fixture}-{opt[1:]}-{schedule}", ir, [opt], schedule)
            build_run(f"{fixture}-boehm", ir, ["-O2"], schedules[0], boehm=True)
            sanitized = ["-O2", "-fno-omit-frame-pointer", "-fsanitize=address,undefined"]
            try:
                build_run(f"{fixture}-sanitized", ir, sanitized, schedules[0])
            except RuntimeError as error:
                if "libclang_rt" not in str(error):
                    raise
                build_run(f"{fixture}-sanitized", ir, sanitized + ["-fno-sanitize-link-runtime", "-lasan", "-lubsan"], schedules[0])
        for fixture, mutation in [("arguments", "stale_argument"), ("field", "drop_field_root")]:
            ir = transform(raw[fixture], CONTRACTS[fixture], mutation)
            build_run(f"{fixture}-mutant-{mutation}", ir, ["-O2"], CASES[fixture][1][0], mutation=True)
    (out / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print(f"generated LLVM GC: checked {successful} successful builds, 2 failing mutations, "
          f"{len(ir_controls) + len(independent) + 3} rejections")


if __name__ == "__main__":
    main()
