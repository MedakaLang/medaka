#!/usr/bin/env python3
"""On-demand serial GC confirmation; prepare once, then measure frozen binaries."""
import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import resource
import shlex
import shutil
import statistics
import subprocess
import sys
import time

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
ARMS = (
    ("custom_AS", "custom_AS", "custom"),
    ("boehm_inline_default", "boehm_inline", "default"),
    ("boehm_caller_inline_default", "boehm_caller_inline", "default"),
    ("boehm_inline_fixed128m", "boehm_inline", "fixed128m"),
    ("boehm_caller_inline_fixed128m", "boehm_caller_inline", "fixed128m"),
)
SOURCES = ("gc.c", "gc.h", "workload.c", "run.py", "confirm.py", "adversarial.c",
           "pool_review.c", "prepared_api.c", "llvm_contract/contract.ll",
           "llvm_contract/driver.c", "llvm_contract/validate_llvm.py")


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def runner():
    spec = importlib.util.spec_from_file_location("gc_confirmation_run", HERE / "run.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def child_env(cohort):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("GC_", "MEDAKA_"))}
    if cohort != "custom":
        env["GC_FREE_SPACE_DIVISOR"] = "1"
        if cohort == "fixed128m":
            env["GC_INITIAL_HEAP_SIZE"] = "134217728"
        elif cohort != "default":
            raise ValueError(f"unknown cohort: {cohort}")
    return env


def points(profiles):
    cases = [(p, n, 262136) for p in ("list", "tree") for n in (500000, 2000000, 8000000)]
    cases += [(p, 2000000, 262136) for p in profiles if p not in ("list", "tree")]
    cases += [(p, 2000000, cap) for p in ("tree", "mixed") for cap in (65528, 1048568)]
    return [{"id": f"{p}-{n}-n{cap}", "profile": p, "count": n, "nursery_bytes": cap}
            for p, n, cap in cases]


def sources():
    paths = [HERE / name for name in SOURCES]
    paths += [ROOT / "runtime/medaka_rt.c", ROOT / "compiler/backend/llvm_emit.mdk"]
    return {str(p.relative_to(ROOT)): sha(p) for p in paths}


def toolchain(module):
    compiler = shutil.which(os.environ.get("CC", "clang"))
    if not compiler:
        raise RuntimeError("C compiler unavailable")
    config = module.boehm_config()
    archive = config.get("boehm_archive")
    if config.get("boehm_linkage") != "static" or not archive or not Path(archive).is_file():
        raise RuntimeError("confirmation requires the frozen static libgc.a comparison")
    cflags = [f for f in config["flags"] if f != archive and not f.startswith(("-l", "-L"))]
    command = [compiler, "-std=c11", *cflags, "-DGC_THREADS", "-pthread", "-M", "-MT", "gc_headers", "-x", "c", "-"]
    text = "#include <gc/gc.h>\n#include <gc/gc_inline.h>\n#include <gc/gc_version.h>\n"
    dependencies = module.run(command, input=text).stdout.replace("\\\n", "")
    paths = [Path(p.replace("$$", "$")).resolve() for p in shlex.split(dependencies.split(":", 1)[1])]
    names = {"gc.h", "gc_inline.h", "gc_version.h"}
    include_roots = {p.parent for p in paths if p.name == "gc.h"}
    headers = {str(p): sha(p) for p in paths if any(p.is_relative_to(root) for root in include_roots)}
    if not names <= {Path(p).name for p in headers}:
        raise RuntimeError("compiler dependency output omitted a required Boehm header")
    return {"compiler": compiler, "compiler_sha256": sha(compiler),
            "compiler_version": module.run([compiler, "--version"]).stdout.splitlines()[0],
            "boehm": config, "archive_sha256": sha(archive), "boehm_header_sha256": headers,
            "platform": platform.platform(), "machine": platform.machine()}


def validate_row(row, profile, count):
    identity = (row["allocations"], row["payload_bytes"], row["checksum"])
    if (row["profile"] != profile or row["count"] != count
            or identity[0] != count + (profile == "mutation")
            or identity[2] != count * (count - 1) // 2):
        raise RuntimeError(f"workload identity failed: {profile}, {count}: {identity}")
    return identity


def validate_custom(row):
    # These conservation identities match run.py's custom correctness checks.
    checks = (
        row["nursery_allocations"] + row["direct_old_allocations"] == row["allocations"],
        row["nursery_payload_bytes"] + row["direct_old_payload_bytes"] == row["payload_bytes"],
        row["allocation_header_bytes"] == row["nursery_allocations"] * row["nursery_header_bytes"]
            + row["direct_old_allocations"] * row["old_header_bytes"],
        row["old_total_allocated_bytes"] - row["reclaimed_bytes"] == row["old_live_bytes"],
        row["exact_live_payload_bytes"] + row["old_object_count"] * row["old_header_bytes"] == row["old_live_bytes"],
        row["pool_allocations"] - row["pool_releases"] == row["pool_count"],
        row["pool_reserved_bytes"] >= row["old_slot_bytes"],
        row["accounted_bytes"] == sum(row[k] for k in ("nursery_capacity_bytes", "pool_reserved_bytes",
            "large_reserved_bytes", "descriptor_bytes", "work_queue_bytes", "remembered_queue_bytes",
            "root_bytes", "static_metadata_bytes")),
        row["peak_accounted_bytes"] >= row["accounted_bytes"],
    )
    if not all(checks):
        raise RuntimeError(f"custom conservation/accounting failed: checks {[i for i, ok in enumerate(checks) if not ok]}")


def sample(module, binary, point, cohort):
    argv = [binary, point["profile"], str(point["count"]), str(point["nursery_bytes"])]
    env = child_env(cohort)
    started = time.perf_counter()
    completed = module.run(argv, env=env)
    wall = time.perf_counter() - started
    if completed.stderr:
        raise RuntimeError(f"unexpected workload stderr: {completed.stderr}")
    row = json.loads(completed.stdout)
    validate_row(row, point["profile"], point["count"])
    if cohort == "custom":
        validate_custom(row)
    return {**row, "process_wall_seconds": wall, "argv": argv,
            "environment": {k: v for k, v in env.items() if k.startswith(("GC_", "MEDAKA_"))}}


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def prepare(module, scratch):
    if scratch.exists() and any(scratch.iterdir()):
        raise RuntimeError("prepare requires an empty scratch directory")
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    scratch.mkdir(parents=True, exist_ok=True)
    source_hashes, tools = sources(), toolchain(module)
    compiler = tools["compiler"]
    with contextlib.ExitStack() as stack:
        original = os.environ.copy()
        stack.callback(lambda: (os.environ.clear(), os.environ.update(original)))
        build_env = child_env("custom")
        os.environ.clear(); os.environ.update(build_env); os.environ["CC"] = compiler
        _, adapter_region = module.adapter(scratch)
        binaries = {name: module.build(scratch, name, module.BACKENDS[name][0],
                                      boehm=module.BACKENDS[name][1])
                    for name in dict.fromkeys(backend for _, backend, _ in ARMS)}
        log = io.StringIO()
        with contextlib.redirect_stdout(log):
            module.correctness(scratch, binaries)
        checks, identities = [], {}
        for arm, backend, cohort in ARMS:
            for profile in module.PROFILES:
                point = {"profile": profile, "count": 1024, "nursery_bytes": 240}
                row = sample(module, str(binaries[backend]), point, cohort)
                identity = validate_row(row, profile, 1024)
                if identity != identities.setdefault(profile, identity):
                    raise RuntimeError(f"correctness arms disagree: {arm}, {profile}")
                checks.append({"arm": arm, **row})
    if source_hashes != sources() or tools != toolchain(module):
        raise RuntimeError("sources/toolchain changed during preparation")
    manifest = {"schema": "medaka.gc-confirmation-prepared.v1", "source_sha256": source_hashes,
                "git_head": module.run(["git", "rev-parse", "HEAD"], cwd=ROOT).stdout.strip(),
                "toolchain": tools, "adapter_region_sha256": adapter_region,
                "adapter_files": {name: sha(scratch / name) for name in ("boehm_adapter.c", "boehm_caller.h")},
                "binaries": {name: {"path": str(path), "sha256": sha(path),
                                   "command": module.BUILD_COMMANDS[name]}
                             for name, path in binaries.items()},
                "points": points(module.PROFILES), "arms": [list(a) for a in ARMS],
                "correctness": {"full_harness_stdout": log.getvalue(), "cohort_checks": checks},
                "contracts": {"custom": "prepared caller-inline allocation/store; full payload clearing",
                              "boehm_caller_inline": "prepared caller-inline production adapter; full payload clearing",
                              "boehm_inline": "historical production adapter; atomic payload clearing is not guaranteed",
                              "roots": "custom exact mutable roots; Boehm conservative stack/register roots",
                              "custom_heap": "point nursery; initial old limit 4*nursery, then 2*live+4*nursery",
                              "boehm_heap": "divisor 1; default or 128 MiB initial heap, neither a maximum heap"}}
    write_json(scratch / "prepared.json", manifest)
    return manifest


def frozen(module, scratch, manifest):
    if manifest.get("schema") != "medaka.gc-confirmation-prepared.v1":
        raise RuntimeError("scratch is not a prepared confirmation")
    if manifest["points"] != points(module.PROFILES) or manifest["arms"] != [list(a) for a in ARMS]:
        raise RuntimeError("confirmation plan changed; prepare fresh scratch")
    if manifest["source_sha256"] != sources() or manifest["toolchain"] != toolchain(module):
        raise RuntimeError("sources/toolchain changed; prepare fresh scratch")
    head = module.run(["git", "rev-parse", "HEAD"], cwd=ROOT).stdout.strip()
    if head != manifest["git_head"]:
        raise RuntimeError("Git HEAD changed; prepare fresh scratch")
    for name, digest in manifest["adapter_files"].items():
        if sha(scratch / name) != digest:
            raise RuntimeError(f"adapter changed: {name}")
    for name, entry in manifest["binaries"].items():
        if sha(entry["path"]) != entry["sha256"]:
            raise RuntimeError(f"binary changed: {name}")


def summaries(rows, cases):
    result = []
    for point in cases:
        arms = {}
        for arm, _, _ in ARMS:
            group = [r for r in rows if r["point"] == point["id"] and r["arm"] == arm]
            arms[arm] = {key: {"min": min(r[key] for r in group),
                               "median": statistics.median(r[key] for r in group),
                               "max": max(r[key] for r in group)}
                         for key in ("elapsed_seconds", "process_wall_seconds", "process_peak_rss_bytes")}
            arms[arm]["samples"] = len(group)
        record = {"point": point, "arms": arms}
        for metric, label in (("elapsed_seconds", "internal"), ("process_wall_seconds", "wall")):
            best = min((a for a in arms if a != "custom_AS"), key=lambda a: arms[a][metric]["median"])
            record[f"best_boehm_by_{label}_median"] = best
            record[f"custom_over_best_boehm_{label}_median"] = arms["custom_AS"][metric]["median"] / arms[best][metric]["median"]
        result.append(record)
    return result


def measure(module, scratch, manifest, repeats):
    frozen(module, scratch, manifest)
    checkpoint = scratch / "samples.jsonl"
    if checkpoint.exists() or (scratch / "measurement.json").exists():
        raise RuntimeError("scratch already contains measurement; partial timing batches are not resumed")
    rows, orders = [], []
    with checkpoint.open("x") as output:
        for index, point in enumerate(manifest["points"]):
            identity = None
            for repeat in range(repeats):
                offset = (index + repeat) % len(ARMS)
                order = ARMS[offset:] + ARMS[:offset]
                orders.append({"point": point["id"], "repeat": repeat, "arms": [a[0] for a in order]})
                for position, (arm, backend, cohort) in enumerate(order):
                    row = sample(module, manifest["binaries"][backend]["path"], point, cohort)
                    actual = validate_row(row, point["profile"], point["count"])
                    if identity is not None and actual != identity:
                        raise RuntimeError(f"measurement arms disagree: {point['id']}, {arm}")
                    identity = actual
                    row.update(point=point["id"], arm=arm, cohort=cohort, repeat=repeat,
                               execution_position=position, execution_order=len(rows))
                    rows.append(row); output.write(json.dumps(row, sort_keys=True) + "\n"); output.flush()
            print(f"completed {point['id']}: {len(rows)} samples", flush=True)
    frozen(module, scratch, manifest)
    return {"schema": "medaka.gc-confirmation-measurement.v1", "prepared_sha256": sha(scratch / "prepared.json"),
            "prepared": manifest, "repeats": repeats, "samples": rows, "execution_order": orders,
            "summary": summaries(rows, manifest["points"]), "checkpoint_sha256": sha(checkpoint),
            "timing": "internal includes workload/traversal/final full GC; wall includes whole fresh process",
            "ordering": "serial cyclic rotations; positions balanced when repeats is a multiple of five",
            "positions_balanced": repeats % len(ARMS) == 0,
            "rss": "process high-water includes inherited launcher floor; reserved custom storage remains in raw counters",
            "comparison": "fastest Boehm median selected separately per point and timing metric; no aggregate claim"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--prepare", action="store_true")
    mode.add_argument("--measure", action="store_true")
    parser.add_argument("--resume", action="store_true", help="reuse prepared scratch; partial timings are not resumable")
    parser.add_argument("--scratch", type=Path, required=True)
    parser.add_argument("--repeats", type=int, default=5, help="measurement rounds per point; used only with --measure")
    args = parser.parse_args()
    if args.repeats < 1 or args.measure != args.resume:
        parser.error("positive repeats required; --measure requires --resume, --prepare excludes --resume")
    module, scratch = runner(), args.scratch.resolve()
    if args.prepare:
        prepare(module, scratch); print(scratch / "prepared.json")
    else:
        manifest = json.loads((scratch / "prepared.json").read_text())
        report = measure(module, scratch, manifest, args.repeats)
        write_json(scratch / "measurement.json", report); print(scratch / "measurement.json")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(f"confirm.py: {error}", file=sys.stderr)
        raise SystemExit(1)
