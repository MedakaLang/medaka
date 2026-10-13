#!/usr/bin/env python3
"""Validate hand-written LLVM roots; this does not test Medaka code generation."""

import argparse
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gc-source", type=Path, required=True)
    parser.add_argument("--clang", default="clang")
    args = parser.parse_args()
    source = args.gc_source.resolve()
    fixture = Path(__file__).resolve().parent
    original = (fixture / "contract.ll").read_text()
    controls = [
        (
            "reload",
            "  %live = load i64, ptr %slot, align 8 ; mutation: omit relocated reload",
            "  %live = add i64 %before, 0 ; mutation: stale SSA operand",
            1,
            "moved root reload failed",
        ),
        (
            "argument",
            "  %live = load i64, ptr %slot, align 8 ; mutation: omit earlier argument reload",
            "  %live = add i64 %early, 0 ; mutation: stale earlier argument",
            2,
            "earlier argument relocation failed",
        ),
    ]
    base = [args.clang, "-g", "-Wall", "-Wextra", "-Werror",
            "-Wno-override-module", "-I", str(source.parent)]
    with tempfile.TemporaryDirectory(prefix="medaka-gc-llvm-") as temporary:
        work = Path(temporary)

        def compile_ir(name, ir, flags):
            ll = work / (name + ".ll")
            ll.write_text(ir)
            binary = work / name
            cmd = base + flags + [str(fixture / "driver.c"), str(ll),
                                  str(source), "-o", str(binary)]
            completed = subprocess.run(cmd, text=True, capture_output=True)
            if completed.returncode:
                raise RuntimeError("compile failed: " + " ".join(cmd)
                                   + "\n" + completed.stderr)
            return binary

        def run(binary, expected=0, message=None, env=None):
            completed = subprocess.run([str(binary)], text=True,
                                       capture_output=True, env=env, timeout=30)
            if completed.returncode != expected or (
                    message and message not in completed.stderr):
                raise RuntimeError(f"{binary.name}: expected exit {expected}, "
                                   f"got {completed.returncode}\n"
                                   + completed.stdout + completed.stderr)
            if expected == 0 and "checked 3" not in completed.stdout:
                raise RuntimeError("successful fixture omitted checked count")
            if expected == 0 and completed.stderr:
                raise RuntimeError("unexpected successful-fixture stderr: "
                                   + completed.stderr)
            print(f"{binary.name}: expected exit {expected}")

        for optimization in ("-O0", "-O2"):
            run(compile_ir("contract" + optimization, original, [optimization]))

        sanitizers = ["-O2", "-fno-omit-frame-pointer",
                      "-fsanitize=address,undefined"]
        try:
            sanitized = compile_ir("contract-sanitized", original, sanitizers)
        except RuntimeError as error:
            if "libclang_rt" not in str(error):
                raise
            sanitized = compile_ir(
                "contract-sanitized", original,
                sanitizers + ["-fno-sanitize-link-runtime", "-lasan", "-lubsan"])
            print("sanitizers: using installed GCC ASan/UBSan runtimes")
        environment = os.environ.copy()
        environment["ASAN_OPTIONS"] = "detect_leaks=0:halt_on_error=1"
        environment["UBSAN_OPTIONS"] = "halt_on_error=1:print_stacktrace=1"
        run(sanitized, env=environment)

        for name, before, after, expected, message in controls:
            if original.count(before) != 1:
                raise RuntimeError(f"{name}: mutation anchor is not unique")
            mutant = compile_ir("missing-" + name,
                                original.replace(before, after), ["-O2"])
            run(mutant, expected, message)
    print("LLVM contract validation: checked 3 builds and 2 failing mutations")


if __name__ == "__main__":
    main()
