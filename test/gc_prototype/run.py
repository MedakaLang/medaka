#!/usr/bin/env python3
"""On-demand collector correctness and synthetic allocation comparison."""
import argparse
import hashlib
import functools
import json
import os
import platform
from pathlib import Path
import shlex
import subprocess
import sys
import resource
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
PROFILES = ("ephemeral", "list", "tree", "mutation", "atomic", "mixed", "sizes")
BACKENDS = {
    "custom": ((), False),
    "custom_P": (("USE_PREPARED_ALLOC",), False),
    "custom_K": (("USE_PREPARED",), False),
    "custom_A": (("USE_PREPARED", "INLINE_ALLOC"), False),
    "custom_S": (("USE_PREPARED", "INLINE_STORE"), False),
    "custom_AS": (("USE_PREPARED", "INLINE_ALLOC", "INLINE_STORE"), False),
    "boehm": (("USE_BOEHM",), True),
    "boehm_inline": (("USE_BOEHM", "USE_INLINE"), True),
    "boehm_prepared_outline": (("USE_BOEHM", "USE_CALLER_INLINE", "USE_PREPARED"), True),
    "boehm_caller_inline": (("USE_BOEHM", "USE_CALLER_INLINE", "USE_PREPARED", "INLINE_ALLOC", "INLINE_STORE"), True),
}
BUILD_COMMANDS = {}


def run(command, quiet_failure=False, **kwargs):
    try:
        return subprocess.run(command, check=True, text=True, capture_output=True, timeout=180, **kwargs)
    except subprocess.CalledProcessError as error:
        if not quiet_failure:
            print(error.stderr, file=sys.stderr)
        raise


@functools.lru_cache(maxsize=1)
def boehm_config():
    try:
        cflags = shlex.split(run(["pkg-config", "--cflags", "bdw-gc"]).stdout)
        libs = shlex.split(run(["pkg-config", "--libs", "--static", "bdw-gc"]).stdout)
        archive = Path(run(["pkg-config", "--variable=libdir", "bdw-gc"]).stdout.strip()) / "libgc.a"
        version = run(["pkg-config", "--modversion", "bdw-gc"]).stdout.strip()
    except (FileNotFoundError, subprocess.CalledProcessError):
        prefix = run(["brew", "--prefix", "bdw-gc"]).stdout.strip()
        cflags, libs = [f"-I{prefix}/include"], [f"-L{prefix}/lib", "-lgc"]
        archive, version = Path(prefix) / "lib/libgc.a", "Homebrew headers; runtime version in rows"
    if archive.is_file():
        libs = [str(archive) if flag == "-lgc" else flag for flag in libs]
        linkage = {"boehm_linkage": "static", "boehm_archive": str(archive),
                   "boehm_archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}
    else:
        linkage = {"boehm_linkage": "dynamic; archive unavailable", "boehm_archive": None}
    return {"flags": cflags + libs, "boehm_pkg_version": version, **linkage}


def adapter(directory):
    source = (REPO / "runtime/medaka_rt.c").read_text()
    start = source.index("#if GC_VERSION_MAJOR == 8 && GC_VERSION_MINOR == 2")
    end = source.index("/* Allocate `n` bytes of POINTER-FREE", start)
    body = source[start:end].replace("mdk_alloc(", "prototype_inline_alloc(")
    caller = source[start:end].replace("mdk_alloc", "prototype_caller")
    caller_start = caller.index("__attribute__((noinline)) void *prototype_caller(")
    caller_end = caller.index("\n#else", caller_start)
    prefix = caller[:caller_start]
    prefix = prefix.replace("static __thread void **prototype_caller_freelists;",
                            "__thread void **prototype_caller_freelists;")
    prefix = prefix.replace("static __attribute__((noinline)) void *prototype_caller_refill",
                            "__attribute__((noinline)) void *prototype_caller_refill")
    hit = caller[caller_start:caller_end].replace("__attribute__((noinline)) void *prototype_caller(",
                                                "static inline void *prototype_caller_alloc(")
    header = ("#ifndef PROTOTYPE_BOEHM_CALLER_H\n#define PROTOTYPE_BOEHM_CALLER_H\n"
              "#include <gc/gc.h>\n#define GC_ASSERT(expr) ((void)0)\n#include <gc/gc_inline.h>\n"
              "#if GC_VERSION_MAJOR == 8 && GC_VERSION_MINOR == 2\n"
              "#define MDK_ALLOC_INLINE_LIMIT ((GC_TINY_FREELISTS - 1) * GC_GRANULE_BYTES)\n"
              "extern __thread void **prototype_caller_freelists;\n"
              "void *prototype_caller_refill(long long n);\n" + hit +
              "\n#else\nstatic inline void *prototype_caller_alloc(long long n) { return GC_malloc((size_t)n); }\n"
              "#endif\n#endif\n")
    (directory / "boehm_caller.h").write_text(header)
    accessors = """
int prototype_inline_enabled(void) {
#if GC_VERSION_MAJOR == 8 && GC_VERSION_MINOR == 2
  return 1;
#else
  return 0;
#endif
}
size_t prototype_inline_root_bytes(void) {
#if GC_VERSION_MAJOR == 8 && GC_VERSION_MINOR == 2
#ifdef USE_CALLER_INLINE
  return prototype_caller_freelists ? GC_TINY_FREELISTS * sizeof(void *) : 0;
#else
  return mdk_alloc_freelists ? GC_TINY_FREELISTS * sizeof(void *) : 0;
#endif
#else
  return 0;
#endif
}
"""
    path = directory / "boehm_adapter.c"
    path.write_text("#include <gc/gc.h>\n#define GC_ASSERT(expr) ((void)0)\n#include <gc/gc_inline.h>\n"
                    + body + prefix + "\n#endif\n" + accessors)
    return path, hashlib.sha256(source[start:end].encode()).hexdigest()


def build(directory, name, defines=(), sanitize=False, boehm=False, workload="workload.c"):
    binary = directory / name
    command = [os.environ.get("CC", "clang"), "-std=c11", "-O2", "-g", "-Wall", "-Wextra", "-Werror"]
    command += [f"-D{define}" for define in defines]
    command += ["-I", str(directory)]
    if sanitize:
        command += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
    command += [str(HERE / "gc.c"), str(HERE / workload)]
    if boehm:
        command += ["-DGC_THREADS", "-pthread", str(directory / "boehm_adapter.c"), *boehm_config()["flags"]]
    command += ["-o", str(binary)]
    try:
        run(command, quiet_failure=sanitize)
    except subprocess.CalledProcessError as error:
        if not (sanitize and sys.platform.startswith("linux") and "libclang_rt" in error.stderr):
            raise
        command += ["-fno-sanitize-link-runtime", "-lasan", "-lubsan"]
        run(command)
        print(json.dumps({"sanitizer_runtime": "clang instrumentation; installed GCC ASan/UBSan libraries"}))
    BUILD_COMMANDS[name] = command
    return binary


def correctness(directory, binaries):
    for name, binary in binaries.items():
        run([str(binary), "--selftest"])
        for profile in PROFILES:
            row = json.loads(run([str(binary), profile, "1024", "240"]).stdout)
            assert row["allocations"] == 1024 + (profile == "mutation"), (name, row)
            assert row["checksum"] == 1024 * 1023 // 2, (name, row)
            if name.startswith("custom"):
                assert row["nursery_allocations"] + row["direct_old_allocations"] == row["allocations"]
                assert row["nursery_payload_bytes"] + row["direct_old_payload_bytes"] == row["payload_bytes"]
                assert row["allocation_header_bytes"] == (
                    row["nursery_allocations"] * row["nursery_header_bytes"]
                    + row["direct_old_allocations"] * row["old_header_bytes"])
                assert row["old_total_allocated_bytes"] - row["reclaimed_bytes"] == row["old_live_bytes"]
                assert row["exact_live_payload_bytes"] + row["old_object_count"] * row["old_header_bytes"] == row["old_live_bytes"]
                assert row["pool_allocations"] - row["pool_releases"] == row["pool_count"]
                assert row["pool_reserved_bytes"] >= row["old_slot_bytes"]
                assert row["accounted_bytes"] == (row["nursery_capacity_bytes"] + row["pool_reserved_bytes"]
                    + row["large_reserved_bytes"] + row["descriptor_bytes"] + row["work_queue_bytes"]
                    + row["remembered_queue_bytes"] + row["root_bytes"] + row["static_metadata_bytes"])
                assert row["peak_accounted_bytes"] >= row["accounted_bytes"]
                if profile == "mixed":
                    assert row["exact_live_payload_bytes"] == 16 * 3 * 8
    sanitized = build(directory, "custom_sanitized", sanitize=True,
                      defines=["USE_PREPARED", "INLINE_ALLOC", "INLINE_STORE"])
    sanitizer_env = dict(os.environ, ASAN_OPTIONS=os.environ.get("ASAN_OPTIONS", "") + ":detect_leaks=0")
    sanitizer_env["UBSAN_OPTIONS"] = "halt_on_error=1:print_stacktrace=1"
    run([str(sanitized), "--selftest"], env=sanitizer_env)
    for profile in PROFILES:
        run([str(sanitized), profile, "1024", "240"], env=sanitizer_env)
    for count in (1, 63, 64, 65, 127):
        run([str(sanitized), "mixed", str(count), "240"], env=sanitizer_env)
        run([str(sanitized), "sizes", str(count), "240"], env=sanitizer_env)
    prepared = build(directory, "prepared_api_sanitized", sanitize=True, workload="prepared_api.c")
    prepared_capacities = (32, 33, 39, 40, 47, 48, 63, 64, 239, 240, 511, 512, 519, 520,
                           521, 2047, 2048, 2049, 2055, 2056, 2057, 262136, 262144)
    for capacity in prepared_capacities:
        for mode in ("inline", "outline"):
            result = run([str(prepared), str(capacity), "all", mode], env=sanitizer_env)
            assert result.stdout == "prepared API passed\n" and not result.stderr
    for mutation, case, message in (("GC_MUTATE_ROOTS", "roots", "prepared root relocation"),
                                    ("GC_MUTATE_ZERO", "zero", "prepared zero initialization"),
                                    ("GC_MUTATE_BARRIER", "barrier", "prepared direct-old initialization barrier")):
        broken = build(directory, "prepared_" + mutation.lower(), defines=[mutation], workload="prepared_api.c")
        for mode in ("inline", "outline"):
            result = subprocess.run([str(broken), "240", case, mode], text=True, capture_output=True, timeout=30)
            assert result.returncode != 0 and "prepared-api assertion: " + message in result.stderr, result
    print(json.dumps({"prepared_api_review": "ASan+UBSan passed", "nursery_capacities": prepared_capacities,
                      "api_modes": ["inline", "outline"], "fail_capability": ["roots", "zero", "barrier"]}))
    pools = build(directory, "pool_review_sanitized", sanitize=True, workload="pool_review.c")
    pool_capacities = (32, 33, 39, 40, 47, 48, 63, 64, 127, 128, 239, 240, 511, 512,
                       2047, 2048, 2049, 2055, 2056, 2057, 262144)
    for capacity in pool_capacities:
        result = run([str(pools), str(capacity)], env=sanitizer_env)
        assert result.stdout == "pool review passed\n" and not result.stderr
    print(json.dumps({"pooled_heap_review": "ASan+UBSan passed", "nursery_capacities": pool_capacities}))
    adversarial = build(directory, "custom_adversarial_sanitized", sanitize=True, workload="adversarial.c")
    capacities = (32, 33, 39, 40, 41, 47, 48, 49, 55, 56, 63, 64, 79, 80, 81, 95, 96, 97, 239, 240, 241,
                  319, 320, 321, 519, 520, 521, 535, 536, 537, 567, 568, 569, 1024, 262144)
    for capacity in capacities:
        result = run([str(adversarial), str(capacity)], env=sanitizer_env)
        assert result.stdout == "review graph passed\n" and not result.stderr
    print(json.dumps({"adversarial_graph": "ASan+UBSan passed", "nursery_capacities": capacities}))
    for mutation, fixture in (("GC_MUTATE_ROOTS", "root"), ("GC_MUTATE_BARRIER", "barrier")):
        binary = build(directory, mutation.lower(), defines=[mutation])
        result = subprocess.run([str(binary), "--selftest", fixture], text=True, capture_output=True, timeout=30)
        assert result.returncode != 0 and "Assertion" in result.stderr, (mutation, result)
    llvm = run([sys.executable, str(HERE / "llvm_contract/validate_llvm.py"), "--gc-source", str(HERE / "gc.c"),
                "--clang", os.environ.get("CC", "clang")])
    print(json.dumps({"llvm_contract": llvm.stdout.splitlines()}))
    print(json.dumps({"correctness": "passed", "sanitizers": "ASan+UBSan passed; LeakSanitizer disabled",
                      "fail_capability": ["root relocation", "remembered-set barrier"]}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--correctness-only", action="store_true")
    parser.add_argument("--count", type=int, default=500_000)
    parser.add_argument("--nursery-bytes", type=int, default=262_144)
    parser.add_argument("--profiles", nargs="+", choices=PROFILES, default=PROFILES)
    parser.add_argument("--backends", nargs="+", choices=BACKENDS, default=list(BACKENDS))
    parser.add_argument("--repeats", type=int, default=3)
    args = parser.parse_args()
    if args.repeats < 1:
        parser.error("--repeats must be positive")
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    for name in list(os.environ):
        if name.startswith("GC_"):
            os.environ.pop(name)
    with tempfile.TemporaryDirectory(prefix="medaka-gc-prototype-") as temporary:
        directory = Path(temporary)
        _, digest = adapter(directory)
        binaries = {name: build(directory, name, BACKENDS[name][0], boehm=BACKENDS[name][1]) for name in args.backends}
        sources = ("gc.h", "gc.c", "workload.c", "run.py", "adversarial.c", "pool_review.c", "prepared_api.c", "llvm_contract/contract.ll",
                   "llvm_contract/driver.c", "llvm_contract/validate_llvm.py")
        print(json.dumps({"inline_allocator_source_sha256": digest,
                          "source_sha256": {name: hashlib.sha256((HERE / name).read_bytes()).hexdigest()
                                            for name in sources},
                          "platform": platform.platform(), "machine": platform.machine(),
                          "git_head": run(["git", "rev-parse", "HEAD"], cwd=REPO).stdout.strip(),
                          "count": args.count, "nursery_bytes": args.nursery_bytes,
                          "profiles": args.profiles, "optimization": "-O2; separate translation units; no LTO",
                          "backends": args.backends, "repeats": args.repeats,
                          "backend_defines": {name: BACKENDS[name][0] for name in args.backends},
                          "build_commands": {name: BUILD_COMMANDS[name] for name in args.backends},
                          "caller_inline_header_sha256": hashlib.sha256((directory / "boehm_caller.h").read_bytes()).hexdigest(),
                          "descriptor_setup": "all eleven workload layouts prepared before timing in every arm",
                          "atomic_zero_contract": "prepared API clears atomic payloads; historical generic Boehm does not promise clearing",
                          "boehm_compile_flags": ["-DGC_THREADS", "-pthread"],
                          "compiler": run([os.environ.get("CC", "clang"), "--version"]).stdout.splitlines()[0],
                          **boehm_config()}))
        correctness(directory, binaries)
        if args.correctness_only:
            return
        for profile in args.profiles:
            expected = None
            samples = {name: [] for name in binaries}
            names = list(binaries)
            execution_order = []
            for repeat in range(args.repeats):
                offset = repeat % len(names)
                order = names[offset:] + names[:offset]
                execution_order.append(order)
                for position, name in enumerate(order):
                    row = json.loads(run([str(binaries[name]), profile, str(args.count), str(args.nursery_bytes)]).stdout)
                    identity = (row["allocations"], row["payload_bytes"], row["checksum"])
                    if expected is None:
                        expected = identity
                    assert identity == expected, (name, profile, identity, expected)
                    samples[name].append({"repeat": repeat, "execution_position": position, **row})
            for name, rows in samples.items():
                fastest = min(rows, key=lambda row: row["elapsed_seconds"])
                print(json.dumps({"backend": name, "timing": "sequential cyclic rotations; each full backend-count cycle balances positions; final collection included",
                                  "summary": f"minimum of {args.repeats} fresh-process samples",
                                  "execution_order": execution_order, "samples": rows,
                                  "samples_seconds": [row["elapsed_seconds"] for row in rows], **fastest}))


if __name__ == "__main__":
    main()
