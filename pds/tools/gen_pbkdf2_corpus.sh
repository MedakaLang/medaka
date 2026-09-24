#!/bin/sh
# Reproduce the Wycheproof PBKDF2-HMAC-SHA256 corpus (S-more-answer-keys round 2, #3362).
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
MODE=write
if [ "${1:-}" = "--check" ]; then MODE=check; shift; fi
OUT=${1:-"$ROOT/pds/test/vectors"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-pbkdf2.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

WYCHEPROOF_COMMIT=cff6adf42662469a1871e57303a0ad1d758ed8c0
WYCHEPROOF_SHA=716230dfb58e248ad57bc81c0fa54e88f629a7cef6a85f72c5dc71457c894f6a

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1
  else shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}
fetch() { curl --fail --location --silent --show-error "$1" -o "$2"; }
check_digest() {
  [ "$(sha256_file "$1")" = "$2" ] || {
    echo "gen_pbkdf2_corpus: digest mismatch for $1" >&2
    exit 1
  }
}
check_tag() {
  git ls-remote "$1" "$2" "$2^{}" | cut -f 1 | grep -q "^$3$" || {
    echo "gen_pbkdf2_corpus: tag/commit mismatch for $2" >&2
    exit 1
  }
}

check_tag https://github.com/C2SP/wycheproof refs/tags/google-wycheproof/v0.9 "$WYCHEPROOF_COMMIT"
fetch "https://raw.githubusercontent.com/C2SP/wycheproof/$WYCHEPROOF_COMMIT/testvectors_v1/pbkdf2_hmacsha256_test.json" "$WORK/wycheproof.json"
check_digest "$WORK/wycheproof.json" "$WYCHEPROOF_SHA"

python3 "$HERE/normalize_wycheproof_pbkdf2.py" "$WORK/wycheproof.json" "$WORK/wycheproof_pbkdf2_hmac_sha256.txt"

if [ "$MODE" = check ]; then
  cmp "$WORK/wycheproof_pbkdf2_hmac_sha256.txt" "$OUT/wycheproof_pbkdf2_hmac_sha256.txt"
  echo "gen_pbkdf2_corpus: CHECK PASS — 60 Wycheproof PBKDF2-HMAC-SHA256 rows"
else
  mkdir -p "$OUT"
  cp "$WORK/wycheproof_pbkdf2_hmac_sha256.txt" "$OUT/wycheproof_pbkdf2_hmac_sha256.txt"
  echo "gen_pbkdf2_corpus: wrote 60 Wycheproof PBKDF2-HMAC-SHA256 rows"
fi
