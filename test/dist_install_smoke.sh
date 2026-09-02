#!/bin/sh
# dist_install_smoke.sh — proves the dist tarball from `make dist` is a
# genuinely relocatable install (#74 D3: native distribution, Linux tarball
# arm; tracking #2514).
#
# Builds the tarball (scripts/make_dist.sh), unpacks it into a scratch
# directory OUTSIDE this repo that has never held a checkout, cd's there, and
# with MEDAKA_ROOT unset: runs a trivial program (`medaka run`), builds it
# (`medaka build`), and executes the produced binary. All three must succeed
# with no reference back to this repo — that's what "relocatable" means.
#
# Usage:  sh test/dist_install_smoke.sh [tarball]
#   tarball  smoke-test THIS already-built tarball instead of packaging a
#            fresh one — release.yml passes the exact file it is about to
#            upload/checksum/publish, so the artifact validated here and the
#            artifact that ships are provably the same bytes (#2514 review
#            F-5: a smoke test that repackages diverges from what's shipped).
#            Omitted: packages a fresh tarball via scripts/make_dist.sh, as
#            a local/CI gate run does.
# Exit:   0 all three steps succeed; 1 any step fails; 2 setup failure
#         (missing build, tar not found).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA_BIN="$ROOT/medaka"
GIVEN_TARBALL="${1:-}"

DIST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dist_smoke_build.XXXXXX")" || exit 2
INSTALL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dist_smoke_install.XXXXXX")" || exit 2
cleanup() { rm -rf "$DIST_TMP" "$INSTALL_TMP"; }
trap cleanup EXIT INT TERM

if [ -n "$GIVEN_TARBALL" ]; then
  [ -f "$GIVEN_TARBALL" ] || { echo "dist_install_smoke.sh: given tarball does not exist: $GIVEN_TARBALL"; exit 2; }
  TARBALL="$GIVEN_TARBALL"
else
  [ -x "$MEDAKA_BIN" ] || { echo "build native first: make medaka (missing $MEDAKA_BIN)"; exit 2; }
  TARBALL="$(sh "$ROOT/scripts/make_dist.sh" "$DIST_TMP")" || {
    echo "make_dist.sh failed to produce a tarball"
    exit 2
  }
  [ -f "$TARBALL" ] || { echo "make_dist.sh reported $TARBALL but it does not exist"; exit 2; }
fi

tar -C "$INSTALL_TMP" -xzf "$TARBALL" || { echo "failed to unpack $TARBALL"; exit 2; }

# The tarball has exactly one top-level dir (medaka-<version>-<os>-<arch>/).
TREE="$(find "$INSTALL_TMP" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[ -n "$TREE" ] || { echo "no top-level dir found under $INSTALL_TMP"; exit 2; }

for f in medaka medaka_emitter stdlib runtime/medaka_rt.c LICENSE README.md; do
  [ -e "$TREE/$f" ] || { echo "unpacked tree missing $f"; exit 1; }
done

# Run from a cwd OUTSIDE the repo, with MEDAKA_ROOT explicitly unset, so
# nothing can accidentally fall back onto this checkout's compiler/ or
# stdlib/.
PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dist_smoke_probe.XXXXXX")" || exit 2
trap 'rm -rf "$DIST_TMP" "$INSTALL_TMP" "$PROBE_DIR"' EXIT INT TERM
cd "$PROBE_DIR" || exit 2
unset MEDAKA_ROOT

printf 'main = println 12345\n' > hello.mdk

fail=0

out="$("$TREE/medaka" run hello.mdk 2>&1)"
if [ "$out" != "12345" ]; then
  echo "FAIL: run — expected 12345, got: $out"
  fail=1
fi

if ! "$TREE/medaka" build hello.mdk -o hello_built >build.log 2>&1; then
  echo "FAIL: build — exit nonzero:"
  cat build.log
  fail=1
elif [ ! -x "$PROBE_DIR/hello_built" ]; then
  echo "FAIL: build reported success but $PROBE_DIR/hello_built is not an executable"
  fail=1
else
  out2="$("$PROBE_DIR/hello_built" 2>&1)"
  if [ "$out2" != "12345" ]; then
    echo "FAIL: executing the built binary — expected 12345, got: $out2"
    fail=1
  fi
fi

if [ "$fail" -eq 0 ]; then
  echo "dist_install_smoke: ok ($TREE, MEDAKA_ROOT unset, run+build+execute all succeeded)"
  exit 0
fi
exit 1
