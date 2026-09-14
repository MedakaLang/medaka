#!/bin/sh
# #2481 pds/lib ⇄ pds/shell boundary: pds/lib/*.mdk must never import
# pds/shell/ (the pure core performs no I/O — see pds/README.md's "Layout")
# every pds/lib/*.mdk export must carry an explicit type signature, and no
# such signature may declare an effect row (`<...>`). The signature check is
# what makes the effect check non-bypassable: an unannotated export gets an
# inferred row, which no grep over declared rows can see. All three checks
# are cheap static greps/awk, no build required.
#
# A FOURTH check (#2604, #2611) covers a different boundary in the same
# source: SECRET CONTAINMENT. No password, session secret, token, salt or
# derived key may be interpolated into a string, because every string this
# server builds out of one is a string that can reach a diagnostic, an error
# body, or a log line. It is a source-shape property, so it is graded here
# with the other source-shape checks rather than in
# pds/test/trust_boundary_guards.sh, whose cells run one probe process each
# and grade a runtime abort — a secret that leaks into a string nothing in the
# suite happens to print is invisible to a runtime probe and plain to a grep.
# Its scope is wider than the other three: pds/lib, pds/shell and
# pds/serve.mdk, because the entry point is where the secrets are read.
#
# A FIFTH check is check 4's other half, for the one containment hole the
# interpolation scan cannot see: the per-request ACCESS LOG (#2964). Its
# formatter interpolates its own fields (`event.method`, `event.client`), so a
# secret reaching a line does so as an ARGUMENT at a call site — `logAccess`,
# `logAccessBytes`, `accessLogLine`, a `RequestTrace`, or a field of an
# `AccessEvent` record literal — and never as a secret-named interpolation the
# fourth check would match. The record literal spans lines, so this check
# tracks the block rather than grading one line at a time.
#
# A mutation control proves each check can actually fail: a throwaway
# violation is injected into a scratch copy of one pds/lib file — or, for the
# fifth check, of pds/shell, where its call sites actually are — shown to red,
# then the real tree is checked again to prove it is untouched and green.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
LIB_DIR="$ROOT/pds/lib"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-boundary.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# ── the two checks, parameterized over a directory ──────────────────────────

# Prints one violation line per offending import; exit 0 with no output when
# clean.
check_no_shell_import() {
  dir=$1
  find "$dir" -name '*.mdk' -print0 |
    xargs -0 grep -n '^import shell\.' 2>/dev/null || true
}

# Prints one violation line per exported signature that declares an effect
# row; exit 0 with no output when clean. An exported signature starts on its
# own "export" (or "public export") line, and may wrap across further
# INDENTED lines — the signature block ends at the next column-0 line.
check_no_effect_export() {
  dir=$1
  for f in "$dir"/*.mdk; do
    [ -f "$f" ] || continue
    awk -v file="$f" '
      /^export$/ || /^public export$/ { collecting = 1; sig = ""; first = 1; next }
      collecting {
        if (!first && $0 !~ /^[ \t]/) {
          if (sig ~ /</) print file ": " sig
          collecting = 0
        } else {
          sig = sig " " $0
          first = 0
        }
      }
    ' "$f"
  done
}

# Prints one violation line per export that carries no explicit type
# signature; exit 0 with no output when clean. Without this the effect check
# above is bypassable by omission: an export with no signature at all
# compiles (the typechecker infers its row), and an inferred effect row is
# invisible to a grep over declared ones.
#
# A signature is the first non-blank line after the `export` line and has the
# form `<name> : ...`; a definition (`<name> <args> = ...`) does not. `export
# data`/`export interface` and friends put the keyword on the `export` line
# itself, so they never enter this state machine.
check_export_has_signature() {
  dir=$1
  for f in "$dir"/*.mdk; do
    [ -f "$f" ] || continue
    awk -v file="$f" '
      /^export$/ || /^public export$/ { pending = NR; next }
      pending {
        if ($0 ~ /^[ \t]*$/) next
        if ($0 !~ /^[^ \t:]+[ \t]*:/)
          print file ":" pending ": export without a type signature: " $0
        pending = 0
      }
    ' "$f"
  done
}

# Prints one violation line per string interpolation that names a secret; exit
# 0 with no output when clean. `\{expr}` is Medaka's only interpolation form,
# so every string built out of a value goes through this shape.
#
# The identifiers are matched as WHOLE WORDS, which is what makes the check
# usable rather than noisy: `secretPath`, `tokenSecretHex` and `saltBytes` name
# a path, a file and a length, and none of them is a secret. `secret`,
# `password`, `digest` and `salt` on their own are.
#
# THE LEDGER below is the exemption list, and it is deliberately tiny: a site
# is exempt only when building the string IS the point, never because the
# leak was judged harmless. Format: one `file:expression` per line.
# The leading backslash of the interpolation is dropped in this ledger: an
# awk -v assignment processes escapes in its value, so a backslash here would
# not survive to the comparison.
SECRET_INTERPOLATION_LEDGER="
jwt.mdk:{hs256Signature secret signingInput}
"

check_no_secret_interpolation() {
  dir=$1
  entry=$2
  for f in "$dir"/*.mdk "$entry"; do
    [ -f "$f" ] || continue
    awk -v file="$f" -v ledger="$SECRET_INTERPOLATION_LEDGER" '
      BEGIN {
        n = split(ledger, rows, "\n")
        for (i = 1; i <= n; i++)
          if (rows[i] != "") allowed[rows[i]] = 1
        base = file
        sub(/^.*\//, "", base)
      }
      {
        line = $0
        while (match(line, /\\[{][^}]*[}]/)) {
          expr = substr(line, RSTART, RLENGTH)
          line = substr(line, RSTART + RLENGTH)
          if (expr ~ /(^|[^A-Za-z0-9_])(password|passphrase|secret|salt|digest|credential|jwt)([^A-Za-z0-9_]|$)/) {
            key = expr
            sub(/^\\/, "", key)
            if (!((base ":" key) in allowed))
              print file ":" FNR ": secret interpolated into a string: " expr
          }
        }
      }
    ' "$f"
  done
}

# Prints one violation line per access-log site that names a secret; exit 0
# with no output when clean.
#
# The names below are the whole access-log surface: the two emitters
# (`logAccess`, `logAccessBytes`), the pure formatter (`accessLogLine`), the
# shell trace it is built from (`RequestTrace`), and the `AccessEvent` record
# literal, whose fields are on their own lines and are therefore tracked as a
# block. A secret reaching any of them reaches a line that whoever reads the
# journal reads — a wider audience than whoever holds the account.
#
# The identifier list is the fourth check's, plus `token` and `bearer`: an
# access log is the one place a request's own Authorization material would
# plausibly be put "for debugging", and unlike a diagnostic it is written on
# EVERY request rather than on a failure.
#
# Matched case-insensitively and as a SUBSTRING, which is stricter than the
# fourth check's whole-word rule and deliberately so: the identifiers actually
# holding these values in this tree are camelCase (`sessionSecret`,
# `credentialDigest`, `tokenSecret`), and a whole-word lowercase scan sees
# none of them. The width costs nothing here, because the allow-list of six
# `AccessEvent` fields is narrow enough that no legitimate argument to any
# site below is named after a secret — a hit is a leak or a misnamed value,
# and both want a human.
#
# Unlike the fourth check, this one grades CODE and not source text: comments
# are stripped before matching. A doc comment that explains which values may
# NOT reach a log line necessarily names both an access-log symbol and a
# secret, so a text-level scan reds on the very prose that documents the rule
# — and the first thing an author would do about that is delete the
# explanation. Strings are tracked so that `"--did"` and friends do not read as
# a line comment.
ACCESS_LOG_SECRETS='(password|passphrase|secret|salt|digest|credential|jwt|token|bearer)'

check_no_secret_in_access_log() {
  dir=$1
  entry=$2
  for f in "$dir"/*.mdk "$entry"; do
    [ -f "$f" ] || continue
    awk -v file="$f" -v words="$ACCESS_LOG_SECRETS" '
      function strip(line,   out, i, c, c2, inq) {
        out = ""
        inq = 0
        i = 1
        while (i <= length(line)) {
          c = substr(line, i, 1)
          c2 = substr(line, i, 2)
          if (inq && c == "\\") { i += 2; continue }
          if (inq) { if (c == "\"") inq = 0; if (depth == 0) out = out c; i++; continue }
          if (depth == 0 && c == "\"") { inq = 1; out = out c; i++; continue }
          if (depth == 0 && c2 == "--") break
          if (c2 == "{-") { depth++; i += 2; continue }
          if (c2 == "-}") { if (depth > 0) depth--; i += 2; continue }
          if (depth == 0) out = out c
          i++
        }
        return out
      }
      BEGIN {
        depth = 0
        site = "(^|[^A-Za-z0-9_])(logAccess|logAccessBytes|accessLogLine|traceFor|RequestTrace|AccessEvent|StatsEvent|statsLogLine|emitStats)([^A-Za-z0-9_]|$)"
      }
      {
        code = strip($0)
        if (code ~ /AccessEvent[ \t]*\{/ || code ~ /StatsEvent[ \t]*\{/) inrecord = 1
        if ((inrecord || code ~ site) && tolower(code) ~ words)
          print file ":" FNR ": a secret reaches the access log: " code
        if (inrecord && code ~ /\}/) inrecord = 0
      }
    ' "$f"
  done
}

# ── the real tree ────────────────────────────────────────────────────────────

run_checks() {
  dir=$1
  label=$2
  entry=${3:-$ROOT/pds/serve.mdk}
  shell_hits=$(check_no_shell_import "$dir")
  effect_hits=$(check_no_effect_export "$dir")
  unsigned_hits=$(check_export_has_signature "$dir")
  secret_hits=$(check_no_secret_interpolation "$dir" "$entry")
  access_hits=$(check_no_secret_in_access_log "$dir" "$entry")
  if [ -n "$shell_hits" ]; then
    echo "$shell_hits" >&2
    fail "$label: pds/lib imports pds/shell"
  fi
  if [ -n "$effect_hits" ]; then
    echo "$effect_hits" >&2
    fail "$label: pds/lib exports an effect-bearing signature"
  fi
  if [ -n "$unsigned_hits" ]; then
    echo "$unsigned_hits" >&2
    fail "$label: pds/lib export carries no type signature"
  fi
  if [ -n "$secret_hits" ]; then
    echo "$secret_hits" >&2
    fail "$label: a secret is interpolated into a string"
  fi
  if [ -n "$access_hits" ]; then
    echo "$access_hits" >&2
    fail "$label: a secret reaches the access log"
  fi
}

# The shell half of the secret scan, run once against the real tree: the
# entry point and the socket shell hold the same secrets pds/lib does.
shell_secret_hits=$(check_no_secret_interpolation "$ROOT/pds/shell" \
  "$ROOT/pds/serve.mdk")
if [ -n "$shell_secret_hits" ]; then
  echo "$shell_secret_hits" >&2
  fail 'real tree: a secret is interpolated into a string in pds/shell'
fi

# The shell half of the access-log scan. It matters MORE here than in pds/lib:
# every `logAccess` call site in this tree is in pds/shell/server.mdk, which is
# also where the request's own headers are still in scope.
shell_access_hits=$(check_no_secret_in_access_log "$ROOT/pds/shell" \
  "$ROOT/pds/serve.mdk")
if [ -n "$shell_access_hits" ]; then
  echo "$shell_access_hits" >&2
  fail 'real tree: a secret reaches the access log in pds/shell'
fi

run_checks "$LIB_DIR" 'real tree'
echo 'boundary clean: no pds/lib -> pds/shell import, every pds/lib export signed, none effect-bearing, no secret interpolated into a string, no secret reaching the access log'

# ── mutation control: prove each check can fail ─────────────────────────────

SCRATCH="$WORK/lib"
cp -R "$LIB_DIR" "$SCRATCH"

# Violation 1: a throwaway import of pds/shell.
VICTIM1="$SCRATCH/repo.mdk"
printf 'import shell.persist.{persistSave}\n' >>"$VICTIM1"
if shell_hits=$(check_no_shell_import "$SCRATCH") && [ -z "$shell_hits" ]; then
  fail 'mutation control: injected shell import was not caught'
fi
echo 'mutation control: injected shell import correctly caught'
rm -rf "$SCRATCH"

# Violation 2: a throwaway effect-bearing exported signature.
cp -R "$LIB_DIR" "$SCRATCH"
VICTIM2="$SCRATCH/repo.mdk"
printf '\nexport\nboundaryProbeForTest : Int -> <IO> Int\nboundaryProbeForTest x = x\n' \
  >>"$VICTIM2"
if effect_hits=$(check_no_effect_export "$SCRATCH") && [ -z "$effect_hits" ]; then
  fail 'mutation control: injected effect-bearing export was not caught'
fi
echo 'mutation control: injected effect-bearing export correctly caught'
rm -rf "$SCRATCH"

# Violation 3: an unannotated export whose effect row the typechecker would
# infer. This is exactly what violation 2's check cannot see, which is why
# the signature check exists.
cp -R "$LIB_DIR" "$SCRATCH"
VICTIM3="$SCRATCH/repo.mdk"
printf '\nexport\nboundaryUnsignedProbeForTest x = println x\n' >>"$VICTIM3"
if effect_hits=$(check_no_effect_export "$SCRATCH") && [ -n "$effect_hits" ]; then
  fail 'mutation control: the effect check was expected to MISS an unannotated export'
fi
if unsigned_hits=$(check_export_has_signature "$SCRATCH") \
  && [ -z "$unsigned_hits" ]; then
  fail 'mutation control: injected unannotated export was not caught'
fi
echo 'mutation control: injected unannotated effect-bearing export correctly caught'
rm -rf "$SCRATCH"

# Violation 4: a secret interpolated into a diagnostic string — the shape
# that turns an error message into a credential disclosure.
cp -R "$LIB_DIR" "$SCRATCH"
VICTIM4="$SCRATCH/repo.mdk"
printf '\nsecretProbeForTest : String -> String\nsecretProbeForTest password = "login failed for \\{password}"\n' \
  >>"$VICTIM4"
if secret_hits=$(check_no_secret_interpolation "$SCRATCH" "$VICTIM4") \
  && [ -z "$secret_hits" ]; then
  fail 'mutation control: injected secret interpolation was not caught'
fi
echo 'mutation control: injected secret interpolation correctly caught'
rm -rf "$SCRATCH"

# Violation 5: the LEDGER must not be a blanket amnesty. The one ledgered
# expression is exempt in jwt.mdk, where building that string is the whole
# job; the same expression anywhere else is still a violation.
cp -R "$LIB_DIR" "$SCRATCH"
VICTIM5="$SCRATCH/repo.mdk"
printf '\nledgerProbeForTest : String -> String\nledgerProbeForTest secret = "\\{hs256Signature secret signingInput}"\n' \
  >>"$VICTIM5"
if secret_hits=$(check_no_secret_interpolation "$SCRATCH" "$VICTIM5") \
  && [ -z "$secret_hits" ]; then
  fail 'mutation control: the ledger exempted a site it does not name'
fi
echo 'mutation control: the ledger is per-file, not a blanket exemption'
rm -rf "$SCRATCH"

# Violation 6: a secret handed to the access log as an ARGUMENT. This is the
# shape the interpolation check above cannot see — there is no secret-named
# `\{...}` anywhere, because the formatter interpolates its own field names —
# so both halves are asserted, exactly as violation 3 asserts both halves of
# the signature/effect pair.
cp -R "$LIB_DIR" "$SCRATCH"
VICTIM6="$SCRATCH/repo.mdk"
printf '\naccessLogProbeForTest : String -> String\naccessLogProbeForTest password = accessLogLine password\n' \
  >>"$VICTIM6"
if secret_hits=$(check_no_secret_interpolation "$SCRATCH" "$VICTIM6") \
  && [ -n "$secret_hits" ]; then
  fail 'mutation control: the interpolation check was expected to MISS a secret passed as an argument'
fi
if access_hits=$(check_no_secret_in_access_log "$SCRATCH" "$VICTIM6") \
  && [ -z "$access_hits" ]; then
  fail 'mutation control: a secret passed to the access log was not caught'
fi
echo 'mutation control: a secret passed to the access log correctly caught'
rm -rf "$SCRATCH"

# Violation 7: the same leak inside an `AccessEvent` record literal, where the
# offending field is on a DIFFERENT line from the constructor. A line-at-a-time
# scan would report this clean, which is why the check tracks the block.
cp -R "$LIB_DIR" "$SCRATCH"
VICTIM7="$SCRATCH/repo.mdk"
printf '\naccessRecordProbeForTest : String -> AccessEvent\naccessRecordProbeForTest sessionSecret =\n  AccessEvent {\n    method = "GET",\n    path = "/xrpc/probe",\n    status = 200,\n    responseBytes = 0,\n    durationMillis = 0,\n    client = sessionSecret,\n  }\n' \
  >>"$VICTIM7"
if access_hits=$(check_no_secret_in_access_log "$SCRATCH" "$VICTIM7") \
  && [ -z "$access_hits" ]; then
  fail 'mutation control: a secret in an AccessEvent field was not caught'
fi
echo 'mutation control: a secret in an AccessEvent record field correctly caught'
rm -rf "$SCRATCH"

# Violation 8: the same leak at a REAL call site, in a copy of pds/shell. The
# two controls above grade the function over a pds/lib directory; this one
# grades it over the directory that actually holds every `logAccess` call, so
# a scan that silently stopped reaching pds/shell — the one arm no other
# control covers — reds here instead of going quiet.
SHELL_SCRATCH="$WORK/shell"
cp -R "$ROOT/pds/shell" "$SHELL_SCRATCH"
VICTIM8="$SHELL_SCRATCH/server.mdk"
sed 's/logAccessBytes trace responseBytes/logAccessBytes trace sessionSecret/' \
  "$VICTIM8" >"$VICTIM8.new"
mv "$VICTIM8.new" "$VICTIM8"
if ! grep -q 'logAccessBytes trace sessionSecret' "$VICTIM8"; then
  fail 'mutation control: the pds/shell call site this control mutates has moved — repoint it'
fi
if access_hits=$(check_no_secret_in_access_log "$SHELL_SCRATCH" \
  "$ROOT/pds/serve.mdk") && [ -z "$access_hits" ]; then
  fail 'mutation control: a secret at a real pds/shell access-log call site was not caught'
fi
echo 'mutation control: a secret at a real pds/shell call site correctly caught'
rm -rf "$SHELL_SCRATCH"

# The real tree is untouched (checks ran against copies only) and still green.
run_checks "$LIB_DIR" 'real tree, post-mutation-control'

echo 'PASS: lib_boundary — no shell import, every export signed, no effect export, no secret interpolated into a string, no secret reaching the access log, mutation control caught all eight'
