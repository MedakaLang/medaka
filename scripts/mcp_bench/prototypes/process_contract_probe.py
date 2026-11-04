#!/usr/bin/env python3
"""Replay process-contract experiments; this is not a production supervisor."""

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile

COMMON = '''data Model (p : Authority Exec) = Model (String @p)
type Alias (p : Authority Exec) = Model p
newtype Wrapped (p : Authority Exec) = Wrapped (Model p)
data Packed = Packed (p : Authority Exec) (Model p)
startModel : (program : String) -> Model program
startModel program = Model program
pollModel : Model p -> <Exec p> Int
pollModel (Model program) = match runCommand program []
  Ok (code, _, _) => code
  Err _ => -1
throughAlias : Alias p -> <Exec p> Int
throughAlias h = pollModel h
throughWrapper : Wrapped p -> <Exec p> Int
throughWrapper (Wrapped h) = throughAlias h
throughList : List (Model p) -> <Exec p> Int
throughList hs = match hs
  [] => 0
  h :: _ => pollModel h
throughRef : Ref (Model p) -> <Exec p> Int
throughRef h = pollModel h.value
throughPacked : Packed -> <Exec> Int
throughPacked (Packed h) = pollModel h
entry : Unit -> <Exec "/bin/true"> Int
entry _ = throughWrapper (Wrapped (startModel "/bin/true"))
'''
CASES = {
 'model-native': COMMON + '''main : <Exec, Stdout> Unit
main =
  let h = startModel "/bin/true"
  let alias = h
  println (entry ())
  println (throughAlias alias)
  println (throughList [h])
  println (throughRef (Ref h))
  println (throughPacked (Packed h))
''',
 'opaque': '''extern data Process (p : Authority Exec)
type ProcessAlias (p : Authority Exec) = Process p
newtype Box (p : Authority Exec) = Box (Process p)
data AnyProcess = AnyProcess (p : Authority Exec) (Process p)
identity : Process p -> Process p
identity h = h
pollExit : ProcessAlias p -> <Exec p> Option Int
pollExit _ = None
wrapped : Box p -> <Exec p> Option Int
wrapped (Box h) = pollExit h
listed : List (Process p) -> <Exec p> Option Int
listed hs = match hs
  [] => None
  h :: _ => pollExit h
main = println "opaque-signatures-compile"
''',
 'wrong-bound': COMMON + '''bad : Model "/bin/true" -> <Exec "/usr/bin/*"> Int
bad h = throughList [h]
main = println 1
''',
 'ref-launder': COMMON + '''bad : Ref (Model "/bin/true") -> Ref (Model "/usr/bin/*")
bad h = h
main = println 1
''',
 'existential-narrow': COMMON + '''bad : Packed -> <Exec "/bin/true"> Int
bad h = throughPacked h
main = println 1
''',
 'foreign-forge': '''extern data Process (p : Authority Exec)
extern forge : Unit -> <FFI "c"> Process "/bin/true"
main = println 1
''',
 'start-signature': '''extern data Process (p : Authority Exec)
data Options = Options { argv : List String, cwd : Option String, env : List (String, String) }
startShape : (program : String) -> Options -> <Exec program> Result String (Process program)
startShape _ _ = Err "no catalog producer in spike"
main = match startShape "/bin/true" Options { argv = [], cwd = None, env = [] }
  Ok _ => println "unexpected"
  Err s => println s
''',
 'legacy-status': '''report : String -> List String -> <Exec, Stdout> Unit
report p args = match runCommand p args
  Err s => println ("Err " ++ s)
  Ok (code, _, err) => println ("Ok " ++ intToString code ++ " stderr=" ++ err)
main : <Exec, Stdout> Unit
main =
  report "/this-path-does-not-exist-medaka-process-spike" []
  report "/bin/sh" ["-c", "exit 127"]
  report "/bin/sh" ["-c", "exit 143"]
  report "/bin/sh" ["-c", "kill -TERM $$"]
''',
}

SURFACE = """extern data Process (p : Authority Exec)

data PipeChoice = Piped | Null

data SpawnOptions = SpawnOptions {
  argv : List String,
  cwd : String,
  env : List (String, String),
  stdin : PipeChoice,
  stdout : PipeChoice,
  stderr : PipeChoice,
}

data ProcessOperation =
  | Validate
  | Pipe
  | Fork
  | Chdir
  | ExecImage
  | Wait
  | Close

data ProcessError =
  | InvalidSpawn String
  | SpawnFailed ProcessOperation Int String
  | ProcessClosed
  | StillRunning
  | WaitFailed Int String
  | CloseFailed Int String
  | Unsupported String

data ExitStatus = Exited Int | Signalled Int Bool

start : (program : String) ->
  SpawnOptions ->
  <Exec program> Result ProcessError (Process program)
start _ _ = Err (Unsupported "signature probe only")

pollExit : Process p -> <Exec p> Result ProcessError (Option ExitStatus)
pollExit _ = Err (Unsupported "signature probe only")

closeStdin : Process p -> <Exec p> Result ProcessError Unit
closeStdin _ = Err (Unsupported "signature probe only")

dispose : Process p -> <Exec p> Result ProcessError Unit
dispose _ = Err (Unsupported "signature probe only")

literal : Unit -> <Exec "/bin/true"> Result ProcessError (Process "/bin/true")
literal _ = start "/bin/true" SpawnOptions {
  argv = [],
  cwd = "/tmp",
  env = [("SPIKE_ONLY", "literal")],
  stdin = Null,
  stdout = Piped,
  stderr = Piped,
}

fromHost : Unit ->
  <Exec "/bin/true", Env {"SPIKE_ONLY"}> Result ProcessError (Process "/bin/true")
fromHost _ =
  let value = match getEnv "SPIKE_ONLY"
    Some s => s
    None => ""
  start "/bin/true" SpawnOptions {
    argv = [],
    cwd = "/tmp",
    env = [("SPIKE_ONLY", value)],
    stdin = Null,
    stdout = Piped,
    stderr = Piped,
  }

main = match literal ()
  Err (Unsupported s) => println s
  _ => println "unexpected"
"""


def gc_flags():
    if shutil.which("pkg-config"):
        for package in ("bdw-gc", "gc"):
            result = subprocess.run(
                ["pkg-config", "--cflags", "--libs", package],
                capture_output=True, text=True, timeout=10,
            )
            if result.returncode == 0:
                return shlex.split(result.stdout)
    if shutil.which("brew"):
        result = subprocess.run(
            ["brew", "--prefix", "bdw-gc"], capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0:
            prefix = Path(result.stdout.strip())
            return ["-I" + str(prefix / "include"), "-L" + str(prefix / "lib"), "-lgc"]
    return ["-lgc"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument("--out", type=Path)
    parser.add_argument("--cc", default=os.environ.get("CC", "clang"))
    args = parser.parse_args()
    root = args.root.resolve()
    out = args.out.resolve() if args.out else Path(tempfile.mkdtemp(prefix="medaka-process-"))
    if out == root or root in out.parents:
        parser.error("--out must be outside the checkout (contains generated binaries)")
    out.mkdir(parents=True, exist_ok=True)
    binary = str(root / "medaka")
    env = dict(os.environ, MEDAKA_STRICT="1")
    results = []
    print("process contract replay: " + str(out), flush=True)

    def run(command, expected=0, contains=None, exact=None):
        result = subprocess.run(
            command, cwd=root, env=env, text=True, capture_output=True, timeout=120,
        )
        row = dict(command=command, expected_rc=expected, rc=result.returncode,
                   stdout=result.stdout, stderr=result.stderr)
        results.append(row)
        (out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        if result.returncode != expected:
            raise AssertionError(row)
        if contains is not None and contains not in result.stdout + result.stderr:
            raise AssertionError(row)
        if exact is not None and (result.stdout != exact or result.stderr):
            raise AssertionError(row)
        return result

    rejected = {
        "wrong-bound": 'performs <Exec "/bin/true"> where only <Exec "/usr/bin/*"> is allowed',
        "ref-launder": 'authority index mismatch: "/bin/true" vs "/usr/bin/*"',
        "existential-narrow": 'performs <Exec> where only <Exec "/bin/true"> is allowed',
        "foreign-forge": "cannot cross the foreign-function boundary",
    }
    outputs = {
        "model-native": "0\n0\n0\n0\n0\n",
        "opaque": "opaque-signatures-compile\n",
        "start-signature": "no catalog producer in spike\n",
        "surface": "signature probe only\n",
    }
    for name, source in dict(CASES, surface=SURFACE).items():
        path = out / (name + ".mdk")
        path.write_text(source)
        run([binary, "fmt", "--write", str(path)])
        run([binary, "lint", str(path)])
        run([binary, "check", str(path)], 1 if name in rejected else 0, rejected.get(name))
        if name not in rejected:
            exe = out / (name + ".exe")
            run([binary, "build", str(path), "-o", str(exe)])
            result = run([str(exe)], exact=outputs.get(name))
            if name == "legacy-status":
                if not re.fullmatch(r"Ok 127 stderr=.+\nOk 127 stderr=\nOk 143 stderr=\nOk 143 stderr=\n", result.stdout):
                    raise AssertionError(result.stdout)
        print(name + ": " + ("rejected as expected" if name in rejected else "native output matched"), flush=True)

    model = str(out / "model-native.mdk")
    for allowed, expected in [("Exec=/bin/true", 0), ("Exec=/bin/*", 0),
                              ("Exec=/usr/bin/*", 1), ("Stdout", 1)]:
        run([binary, "check-policy", model, "--fn", "entry", "--allow", allowed],
            expected, "accepted" if expected == 0 else "rejected")
    for fn in ("throughAlias", "throughWrapper", "throughList", "throughRef"):
        run([binary, "manifest", model, "--fn", fn], contains="Exec = true  # unresolved: authority variable `p`")
    run([binary, "manifest", model, "--fn", "throughPacked"], exact="[package.capabilities]\nExec = true\n")

    surface = str(out / "surface.mdk")
    for fn, allowed, expected in [
        ("literal", "Exec=/bin/true", 0), ("literal", "Env={SPIKE_ONLY}", 1),
        ("fromHost", "Exec=/bin/true", 1), ("fromHost", "Exec=/bin/true,Env={OTHER}", 1),
        ("fromHost", "Exec=/bin/true,Env={SPIKE_ONLY}", 0),
    ]:
        run([binary, "check-policy", surface, "--fn", fn, "--allow", allowed],
            expected, "accepted" if expected == 0 else "rejected")
    bad = out / "env-launder.mdk"
    bad.write_text(SURFACE.replace('Exec "/bin/true", Env {"SPIKE_ONLY"}', 'Exec "/bin/true"'))
    run([binary, "fmt", "--write", str(bad)])
    run([binary, "lint", str(bad)])
    run([binary, "check", str(bad)], 1, 'performs <Env {"SPIKE_ONLY"}>')
    print("indexed Exec and Env policy controls matched", flush=True)

    c_source = Path(__file__).resolve().with_name("process_lifecycle.c")
    lifecycle = out / "lifecycle.exe"
    run(shlex.split(args.cc) + ["-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", str(c_source)]
        + gc_flags() + ["-o", str(lifecycle)])
    native = run([str(lifecycle)], contains="lifecycle controls passed")
    (out / "lifecycle-output.txt").write_text(native.stdout + native.stderr)
    print(native.stdout, end="", flush=True)
    print("process contract replay passed; commands and actual verdicts in " + str(out / "results.json"))


if __name__ == "__main__":
    main()
