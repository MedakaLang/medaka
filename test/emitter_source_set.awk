# emitter_source_set.awk — the STATIC import-closure walker behind FP_FULL.
#
# Prints, one repo-relative path per line (unsorted; the caller sorts), every
# `.mdk` file in the transitive import closure of an entry module.  Run from the
# repo root:
#
#   awk -v entry=compiler/entries/llvm_emit_modules_main.mdk \
#       -v roots=compiler:stdlib -f test/emitter_source_set.awk
#
# WHY AWK, AND WHY STATIC.  Its one caller that matters is
# test/build_native_medaka.sh's src_fingerprint_full(), which runs on the COLD
# path — before any ./medaka exists — so the closure cannot be asked of the real
# loader here.  This reimplements the subset of compiler/driver/loader.mdk's
# `directImports` + `findInRoots` that a compiler-tree walk needs, and
# test/check_fingerprint_parity.sh proves the two still agree by diffing this
# list against the loader's own graph (compiler/entries/module_closure_probe.mdk)
# on a built binary.  A single awk file, rather than a shell function, so that
# the CI mirror in .github/actions/setup-medaka/action.yml can run the SAME bytes
# instead of becoming a fourth hand-synced copy of the algorithm.
#
# FAILS CLOSED.  Any import that resolves to no file under `roots`, any file that
# cannot be read, and any missing entry is a hard exit 1 with NOTHING on stdout.
# Callers must treat that as "hash everything": an over-broad file set costs one
# unnecessary rebuild, an under-broad one silently ships an emitter built from
# source that is no longer on disk.
#
# NOT MODELLED, deliberately: cross-project `[dependencies]` resolution
# (`resolveDepFile`).  compiler/medaka.toml declares none, and the caller refuses
# to run this walker if one ever appears.

function fail(msg) {
  printf("emitter_source_set.awk: %s\n", msg) > "/dev/stderr"
  failed = 1
  exit 1
}

# `modId` -> path under the first root that has the file, or "" if nowhere.
function resolve(modId,   i, cand, probe, rc) {
  gsub(/\./, "/", modId)
  for (i = 1; i <= nroots; i++) {
    cand = rootv[i] "/" modId ".mdk"
    rc = (getline probe < cand)
    close(cand)
    if (rc >= 0) return cand
  }
  return ""
}

# The module id an `import` line names, mirroring loader.mdk's `importModId`:
# a group (`m.{a, b}`) or wildcard (`m.*`) or alias (`m as A`) import names the
# whole dotted path, but a bare `import a.b.c` names the module `a.b` and the
# NAME `c` inside it.  Returns "" for a line that is not an import we follow.
function importModId(line,   rest, path, n, parts, i) {
  if (line !~ /^import[ \t]/) return ""
  rest = line
  sub(/^import[ \t]+/, "", rest)
  if (index(rest, ".{") > 0) {
    path = substr(rest, 1, index(rest, ".{") - 1)
  } else if (index(rest, ".*") > 0) {
    path = substr(rest, 1, index(rest, ".*") - 1)
  } else if (match(rest, /[ \t]+as[ \t]+/) > 0) {
    # `m as A` names the whole dotted path `m`, same as `.{`/`.*` above —
    # matches loader.mdk's `importModId` (`UseAlias ns _` -> `joinDot ns`).
    path = substr(rest, 1, RSTART - 1)
  } else {
    sub(/--.*$/, "", rest)
    sub(/[ \t]+$/, "", rest)
    path = rest
    # Bare `import a.b.c` imports module `a.b`; `import a` imports module `a`.
    n = split(path, parts, ".")
    if (n > 1) {
      path = parts[1]
      for (i = 2; i < n; i++) path = path "." parts[i]
    }
  }
  if (path !~ /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$/) return ""
  return path
}

function walk(path,   line, modId, target) {
  if (path in seen) return
  seen[path] = 1
  out[++nout] = path
  while ((getline line < path) > 0) {
    modId = importModId(line)
    if (modId == "" || modId == "core") continue
    target = resolve(modId)
    if (target == "") {
      close(path)
      fail("unresolvable import `" modId "` in " path)
    }
    pending[++npend] = target
  }
  close(path)
}

BEGIN {
  if (entry == "" || roots == "") fail("need -v entry=<path> -v roots=<a:b>")
  nroots = split(roots, rootv, ":")
  if ((getline probe < entry) < 0) fail("cannot read entry " entry)
  close(entry)

  nout = 0; npend = 0
  pending[++npend] = entry
  # Breadth-first over a queue rather than recursion: awk has no local arrays,
  # so a recursive walk would share `pending` across frames.
  head = 0
  while (head < npend) walk(pending[++head])

  for (i = 1; i <= nout; i++) print out[i]
}

END {
  if (failed) exit 1
}
