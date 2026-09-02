#!/bin/sh
# scripts/make_dist.sh — package a relocatable Medaka install tree into
# medaka-<version>-<os>-<arch>.tar.gz (#74 D3: native distribution, Linux
# tarball arm; tracking #2514).
#
# The tree packaged is the flat 4-item layout already proven to work outside
# the repo with MEDAKA_ROOT unset (`exeDir` resolution,
# compiler/driver/build_cmd.mdk): `medaka`, `medaka_emitter`, `stdlib/`,
# `runtime/medaka_rt.c`, as siblings in one directory. `compiler/` is
# deliberately NOT shipped — `sourceStalenessVerdict`
# (compiler/driver/medaka_cli.mdk) returns None when <root>/compiler doesn't
# exist, so a shipped install emits no staleness warning without it.
#
# Requires `medaka` and `medaka_emitter` already built (`make medaka`) — this
# script does not build them itself.
#
# Version: scraped from `medaka --version`'s second word (the bare
# medakaVersion literal, compiler/driver/medaka_cli.mdk), the same single
# definition `--version`/MCP consume — so the archive name can never drift
# from the version the shipped binary reports. $MEDAKA_DIST_VERSION overrides
# it (used for a dev/CI build whose checked-out `medaka` predates this run).
#
# Usage: sh scripts/make_dist.sh [output-dir]
#   MEDAKA_DIST_VERSION  override the version string embedded in the artifact name
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -z "${MEDAKA_DIST_VERSION:-}" ]; then
  if [ ! -x "$REPO_ROOT/medaka" ]; then
    echo "make_dist.sh: missing $REPO_ROOT/medaka — run 'make medaka' first" >&2
    exit 1
  fi
  MEDAKA_DIST_VERSION="$("$REPO_ROOT/medaka" --version | awk '{print $2}')"
  if [ -z "$MEDAKA_DIST_VERSION" ]; then
    echo "make_dist.sh: could not parse a version from '$REPO_ROOT/medaka --version'" >&2
    exit 1
  fi
fi
VERSION="$MEDAKA_DIST_VERSION"
OUT_DIR="${1:-$REPO_ROOT/dist}"

# ── OS/arch naming — dual-platform (B-DUAL-PLATFORM): Linux `uname -m` names
#    and macOS's arm64 naming both handled, though this need not actually run
#    on macOS today.
UNAME_S="$(uname -s)"
case "$UNAME_S" in
  Linux) OS_NAME="linux" ;;
  Darwin) OS_NAME="macos" ;;
  *) OS_NAME="$(printf '%s' "$UNAME_S" | tr '[:upper:]' '[:lower:]')" ;;
esac

UNAME_M="$(uname -m)"
case "$UNAME_M" in
  x86_64|amd64) ARCH_NAME="x86_64" ;;
  arm64|aarch64) ARCH_NAME="arm64" ;;
  *) ARCH_NAME="$UNAME_M" ;;
esac

ARTIFACT="medaka-${VERSION}-${OS_NAME}-${ARCH_NAME}"

for f in "$REPO_ROOT/medaka" "$REPO_ROOT/medaka_emitter" "$REPO_ROOT/stdlib" "$REPO_ROOT/runtime/medaka_rt.c" "$REPO_ROOT/LICENSE"; do
  if [ ! -e "$f" ]; then
    echo "make_dist.sh: missing $f — run 'make medaka' first" >&2
    exit 1
  fi
done

mkdir -p "$OUT_DIR"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

TREE="$STAGE/$ARTIFACT"
mkdir -p "$TREE/runtime"
cp "$REPO_ROOT/medaka" "$TREE/medaka"
cp "$REPO_ROOT/medaka_emitter" "$TREE/medaka_emitter"
cp -R "$REPO_ROOT/stdlib" "$TREE/stdlib"
cp "$REPO_ROOT/runtime/medaka_rt.c" "$TREE/runtime/medaka_rt.c"
cp "$REPO_ROOT/LICENSE" "$TREE/LICENSE"

# Test scaffolding, not an install artifact — the repo's own golden fixtures,
# irrelevant once shipped (764 KB of the 8.6 MB tree, #2514 review F-7).
find "$TREE/stdlib" \( -name '*.lextok.golden' -o -name '*.test.golden' \) -delete

cat > "$TREE/README.md" <<README
# Medaka $VERSION ($OS_NAME-$ARCH_NAME)

A relocatable Medaka install: run \`./medaka run yourfile.mdk\` from this
directory, or move the whole directory anywhere and run it from there.

## Requirements

- \`medaka run\`/\`medaka check\` etc. need no additional runtime dependency —
  \`medaka\` is dynamically linked against the Boehm GC (\`libgc\`); most Linux
  distributions and macOS via Homebrew (\`brew install bdw-gc\`) already have it.
- \`medaka build\` additionally needs \`clang\` on \$PATH, and libgc's headers
  (\`gc.h\`) at build time (Debian/Ubuntu: \`apt install libgc-dev\`; macOS:
  \`brew install bdw-gc\`).

See LICENSE for the terms this software is distributed under.
README

TARBALL="$OUT_DIR/$ARTIFACT.tar.gz"
# -C into the staging dir so the tarball's paths are relative
# (medaka-<version>-<os>-<arch>/...), not absolute.
tar -C "$STAGE" -czf "$TARBALL" "$ARTIFACT"

echo "$TARBALL"
