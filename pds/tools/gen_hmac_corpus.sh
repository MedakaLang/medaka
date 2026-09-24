#!/bin/sh
# Reproduce the Wycheproof HMAC-SHA256 corpus (S-more-answer-keys round 2, #3362).
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
MODE=write
if [ "${1:-}" = "--check" ]; then MODE=check; shift; fi
OUT=${1:-"$ROOT/pds/test/vectors"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-hmac.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

WYCHEPROOF_COMMIT=cff6adf42662469a1871e57303a0ad1d758ed8c0
WYCHEPROOF_SHA=1a86eeafc894491322137f4352608e4422670c906e18722e2892dde6ecaba688

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1
  else shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}
fetch() { curl --fail --location --silent --show-error "$1" -o "$2"; }
check_digest() {
  [ "$(sha256_file "$1")" = "$2" ] || {
    echo "gen_hmac_corpus: digest mismatch for $1" >&2
    exit 1
  }
}
check_tag() {
  git ls-remote "$1" "$2" "$2^{}" | cut -f 1 | grep -q "^$3$" || {
    echo "gen_hmac_corpus: tag/commit mismatch for $2" >&2
    exit 1
  }
}

check_tag https://github.com/C2SP/wycheproof refs/tags/google-wycheproof/v0.9 "$WYCHEPROOF_COMMIT"
fetch "https://raw.githubusercontent.com/C2SP/wycheproof/$WYCHEPROOF_COMMIT/testvectors_v1/hmac_sha256_test.json" "$WORK/wycheproof.json"
check_digest "$WORK/wycheproof.json" "$WYCHEPROOF_SHA"

python3 "$HERE/normalize_wycheproof_hmac.py" "$WORK/wycheproof.json" "$WORK/wycheproof_hmac_sha256.txt"

if [ "$MODE" = check ]; then
  cmp "$WORK/wycheproof_hmac_sha256.txt" "$OUT/wycheproof_hmac_sha256.txt"
  echo "gen_hmac_corpus: CHECK PASS — 174 Wycheproof HMAC-SHA256 rows"
else
  mkdir -p "$OUT"
  cp "$WORK/wycheproof_hmac_sha256.txt" "$OUT/wycheproof_hmac_sha256.txt"
  echo "gen_hmac_corpus: wrote 174 Wycheproof HMAC-SHA256 rows"
fi
