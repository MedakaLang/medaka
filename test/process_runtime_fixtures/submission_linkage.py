"""Exercise optional startup with standalone, archive, cached and installed runtime links."""
import os
from pathlib import Path
import subprocess
import sys
import tarfile

root, scratch = map(Path, sys.argv[1:])
environment = {**os.environ, "GC_MARKERS": "1", "MEDAKA_STRICT": "1"}
cc = ["clang", "-DMDK_PROCESS_TESTING", "-std=gnu11", "-O0", "-pthread", f"-I{root / 'runtime'}"]
fixtures = root / "test/process_runtime_fixtures"


def run(args, marker=None, env=environment, cwd=scratch):
    result = subprocess.run(list(map(str, args)), env=env, cwd=cwd,
                            capture_output=True, text=True, timeout=180)
    assert result.returncode == 0, (args, result.returncode, result.stdout, result.stderr)
    if marker is not None:
        assert marker in result.stdout.splitlines(), (args, result.stdout, result.stderr)
    return result.stdout


runtime, process, probe = (scratch / name for name in ("runtime.o", "process.o", "probe.o"))
run([*cc, "-c", root / "runtime/medaka_rt.c", "-o", runtime])
run([*cc, "-c", root / "runtime/medaka_process.c", "-o", process])
run([*cc, "-c", fixtures / "submission_startup.c", "-o", probe])
stub = scratch / "standalone.c"
stub.write_text("int mdk_program_main(int argc,char **argv) {(void)argc;(void)argv;return 0;}\n")
run([*cc, runtime, stub, "-lgc", "-lm", "-o", scratch / "standalone"])
run([scratch / "standalone"])
run([*cc, runtime, process, probe, "-lgc", "-lm", "-o", scratch / "linked"])
run([scratch / "linked"], "linked process worker startup passed")
archive = scratch / "libprocess.a"
run(["ar", "rcs", archive, process])
run([*cc, runtime, probe, archive, "-lgc", "-lm", "-o", scratch / "archived"])
run([scratch / "archived"], "linked process worker startup passed")
run([*cc, "-U__linux__", "-c", root / "runtime/medaka_process.c", "-o", scratch / "unsupported.o"])
run([*cc, "-DMDK_SUBMIT_UNSUPPORTED", runtime, scratch / "unsupported.o",
     fixtures / "submission_startup.c", "-lgc", "-lm", "-o", scratch / "unsupported"])
run([scratch / "unsupported"], "unsupported submission refuses without a worker passed")
print("standalone, direct, archive and unsupported runtime startup passed")

compiler = root / "medaka"
source = fixtures / "submission_typed.mdk"
explicit = scratch / "explicit.o"
run([compiler, "build", "--emit-rt-obj", explicit])
for name, variables in [
    ("inline", {"MEDAKA_NO_OBJ_CACHE": "1", "MEDAKA_RT_OBJ": ""}),
    ("explicit", {"MEDAKA_NO_OBJ_CACHE": "", "MEDAKA_RT_OBJ": str(explicit)}),
    ("cache-first", {"MEDAKA_NO_OBJ_CACHE": "", "MEDAKA_RT_OBJ": ""}),
    ("cache-hit", {"MEDAKA_NO_OBJ_CACHE": "", "MEDAKA_RT_OBJ": ""}),
]:
    env = {**environment, "MEDAKA_CACHE_DIR": str(scratch / "cache"), **variables}
    binary = scratch / name
    run([compiler, "build", source, "-o", binary], env=env)
    run([binary], "submitted native passed")
assert list((scratch / "cache").rglob("rt-*.o")), "runtime object cache never filled"
print("inline, explicit runtime object, cache fill and cache hit submission passed")

tarball = Path(run(["sh", root / "scripts/make_dist.sh", scratch / "dist"]).strip())
install = scratch / "install"
install.mkdir()
with tarfile.open(tarball) as package:
    package.extractall(install, filter="data")
trees = [path for path in install.iterdir() if path.is_dir()]
assert len(trees) == 1, trees
installed = trees[0]
outside = scratch / "outside"
outside.mkdir()
(outside / "submitted.mdk").write_text(source.read_text())
installed_env = dict(environment)
for key in ("MEDAKA_ROOT", "MEDAKA_EMITTER", "MEDAKA_RT_OBJ", "MEDAKA_CACHE_DIR"):
    installed_env.pop(key, None)
run([installed / "medaka", "build", "submitted.mdk", "-o", "submitted"],
    env=installed_env, cwd=outside)
run([outside / "submitted"], "submitted native passed", env=installed_env, cwd=outside)
print("installed compiler builds and starts submitted worker outside the source tree passed")
print("submission linkage controls passed")
