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
PROFILES = ("ephemeral", "list", "tree", "mutation", "atomic")


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
  return mdk_alloc_freelists ? GC_TINY_FREELISTS * sizeof(void *) : 0;
#else
  return 0;
#endif
}
"""
    path = directory / "boehm_adapter.c"
    path.write_text("#include <gc/gc.h>\n#define GC_ASSERT(expr) ((void)0)\n#include <gc/gc_inline.h>\n" + body + accessors)
    return path, hashlib.sha256(source[start:end].encode()).hexdigest()


def build(directory, name, defines=(), sanitize=False, boehm=False):
    binary = directory / name
    command = [os.environ.get("CC", "clang"), "-std=c11", "-O2", "-g", "-Wall", "-Wextra", "-Werror"]
    command += [f"-D{define}" for define in defines]
    if sanitize:
        command += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
    command += [str(HERE / "gc.c"), str(HERE / "workload.c")]
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
    return binary


def correctness(directory, binaries):
    for name, binary in binaries.items():
        run([str(binary), "--selftest"])
        for profile in PROFILES:
            row = json.loads(run([str(binary), profile, "1024", "240"]).stdout)
            assert row["allocations"] == 1024 + (profile == "mutation"), (name, row)
            assert row["checksum"] == 1024 * 1023 // 2, (name, row)
            if name == "custom":
                assert row["nursery_allocations"] + row["direct_old_allocations"] == row["allocations"]
                assert row["nursery_payload_bytes"] + row["direct_old_payload_bytes"] == row["payload_bytes"]
                assert row["allocation_header_bytes"] == (
                    row["nursery_allocations"] * row["nursery_header_bytes"]
                    + row["direct_old_allocations"] * row["old_header_bytes"])
    sanitized = build(directory, "custom_sanitized", sanitize=True)
    sanitizer_env = dict(os.environ, ASAN_OPTIONS=os.environ.get("ASAN_OPTIONS", "") + ":detect_leaks=0")
    sanitizer_env["UBSAN_OPTIONS"] = "halt_on_error=1:print_stacktrace=1"
    run([str(sanitized), "--selftest"], env=sanitizer_env)
    for profile in PROFILES:
        run([str(sanitized), profile, "1024", "240"], env=sanitizer_env)
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
    args = parser.parse_args()
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    for name in list(os.environ):
        if name.startswith("GC_"):
            os.environ.pop(name)
    with tempfile.TemporaryDirectory(prefix="medaka-gc-prototype-") as temporary:
        directory = Path(temporary)
        _, digest = adapter(directory)
        binaries = {"custom": build(directory, "custom"),
                    "boehm": build(directory, "boehm", ["USE_BOEHM"], boehm=True),
                    "boehm_inline": build(directory, "boehm_inline", ["USE_BOEHM", "USE_INLINE"], boehm=True)}
        sources = ("gc.h", "gc.c", "workload.c", "run.py", "llvm_contract/contract.ll",
                   "llvm_contract/driver.c", "llvm_contract/validate_llvm.py")
        print(json.dumps({"inline_allocator_source_sha256": digest,
                          "source_sha256": {name: hashlib.sha256((HERE / name).read_bytes()).hexdigest()
                                            for name in sources},
                          "platform": platform.platform(), "machine": platform.machine(),
                          "git_head": run(["git", "rev-parse", "HEAD"], cwd=REPO).stdout.strip(),
                          "count": args.count, "nursery_bytes": args.nursery_bytes,
                          "profiles": args.profiles, "optimization": "-O2; separate translation units; no LTO",
                          "boehm_compile_flags": ["-DGC_THREADS", "-pthread"],
                          "compiler": run([os.environ.get("CC", "clang"), "--version"]).stdout.splitlines()[0],
                          **boehm_config()}))
        correctness(directory, binaries)
        if args.correctness_only:
            return
        for profile in args.profiles:
            expected = None
            for name, binary in binaries.items():
                rows = [json.loads(run([str(binary), profile, str(args.count), str(args.nursery_bytes)]).stdout)
                        for _ in range(3)]
                for row in rows:
                    identity = (row["allocations"], row["payload_bytes"], row["checksum"])
                    if expected is None:
                        expected = identity
                    assert identity == expected, (name, profile, identity, expected)
                fastest = min(rows, key=lambda row: row["elapsed_seconds"])
                print(json.dumps({"backend": name, "timing": "sequential min-of-3; final collection included",
                                  "samples_seconds": [row["elapsed_seconds"] for row in rows], **fastest}))


if __name__ == "__main__":
    main()
