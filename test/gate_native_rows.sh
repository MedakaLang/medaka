# test/gate_native_rows.sh — THE ONE PARSER FOR A `kind = "native"` ROW (#2636)
#
# NOT A GATE. This file is `.`-sourced; it runs nothing and exits nothing. It is
# listed in test/CI-COVERAGE-TOOLS.txt — the "sourced libraries" ledger — for
# exactly that reason (every `.sh` in the tree is enumerated by
# test/diff_compiler_ci_shard_coverage.sh, which cannot tell a library from a
# gate by looking at it). It is NOT in test/CI-COVERAGE-EXCEPTIONS.txt: that
# file is for GATES deliberately kept out of CI, a different claim.
#
# WHY THIS FILE EXISTS. The same awk block parsing test/gates.toml for
# `kind = "native"` name/run pairs used to be PASTED, byte-for-byte, into three
# places: test/run_gates.sh, test/preflight.sh and test/build_oracles.sh — three
# copies of the one rule that answers "which gates are `.mdk` modules, not
# `.sh` scripts" (#2591). A fourth, differently-shaped consumer,
# .github/workflows/ci.yml's `plan` step, reads a pre-generated
# `$RUNNER_TEMP/native_gates.txt` rather than re-parsing gates.toml itself, so
# it has no copy to fold in here. One source, sourced by the three that do
# re-parse, is cheaper than three copies that can only be kept honest by
# remembering to edit them in lockstep.
#
# Defines `_native_rows()`: one line per row, "<name> <repo-relative run
# path>" — neither field can contain a space (`gate verify` constrains a name;
# `run` is a path in this tree), so a caller can safely word-split it, or (as
# preflight.sh and build_oracles.sh do) `tr ' ' ':'` it into "<name>:<run>"
# pairs for a `for`-loop split. Requires `$ROOT` (repo root), which every
# caller already sets before sourcing this — read straight out of
# test/gates.toml, before any ./medaka binary exists, since two of the three
# callers run at a point in CI where nothing has been built yet.
_native_rows() {
  awk -F'"' '
    /^\[\[gate\]\]/ { if (k == "native" && n != "" && r != "") print n, r; n=""; k=""; r="" }
    /^name = "/       { n = $2 }
    /^kind = "/       { k = $2 }
    /^run = "/        { r = $2 }
    END               { if (k == "native" && n != "" && r != "") print n, r }
  ' "$ROOT/test/gates.toml" 2>/dev/null
}
