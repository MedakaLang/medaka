# test/lib/pcg_partition.sh — sourceable pcg_partition(), extracted verbatim
# from test/build_native_medaka.sh (#2780) so a gate can test the SAME code the
# build actually uses without running a build. Usage:
#
#   . "$ROOT/test/lib/pcg_partition.sh"
#   pcg_partition <in.ll> <outdir> <n>
#
# See the header comment on pcg_partition() below for its full contract; that
# comment is the one normative copy — do not duplicate it here.
# ---- pcg_partition: cut the emitted IR by SOURCE MODULE ------------------------
#
#   pcg_partition <in.ll> <outdir> <n>     -> writes <outdir>/p0 .. p<k-1>,
#                                             prints "<k> mod" or "<k> nomark"
#
# <n> empty means DERIVE k: one partition per module scope, each `impl:` group
# folded onto the module scope that precedes it, `program` alone at the end. <n>
# nonzero coalesces to exactly n instead (see MEDAKA_CODEGEN_PARTS).
#
# IR WITH NO MARKERS AT ALL degrades to one partition holding the input verbatim,
# printing "1 nomark", because the caller cannot avoid meeting it: stage A always
# runs the PREVIOUS generation's emitter, and in every worktree whose
# ./medaka_emitter predates the markers that emitter is what produces stage A's IR.
# Failing there would make the first build after this landed a hard error for every
# developer and every warm CI cache, for one build — stage B, run by the emitter
# stage A just rebuilt, partitions normally, and so does every build after it.
#
# A marker that IS present but unusable stays a hard failure: it means the emitter
# is producing corrupt IR, and binning by a marker this file cannot read would put
# entities in the preamble and duplicate them into every partition.
#
# The emitter precedes every top-level entity with a `; mdk-module <scope>` comment,
# where <scope> is a module id (`frontend_lexer`), an impl-group key (`impl:List_eq`)
# or `program` (dispatchers, interface defaults, @mdk_program_main, the $memo
# forcers). Scopes are NOT contiguous in the text, so this bins by marker and never
# by position. Only a marker at TOP LEVEL moves the current scope, which is what the
# `define`/`}` state machine is for: a marker inside a function body would be a
# comment about an instruction, and acting on it would split a define from its own
# scope. The emitter currently emits none there, and this does not rely on that.
#
# A partition's bytes then depend only on the modules IN it, so editing one module
# leaves the other partitions byte-identical and the ThinLTO cache can serve them —
# but only if the changed partition is not an importer of most of the rest, which is
# why the default is one module per partition rather than a handful of big ones. It
# also isolates @mdk_program_main, which concatenates every module's initializers and
# therefore moves whenever any module gains or loses a top-level binding.
#
# Two things a text split has to do that llvm-split did in the IR:
#   * local-linkage globals (`private` string constants, `internal` closure records)
#     are referenced across partition boundaries, so their definitions are promoted
#     from private/internal to `hidden` — external linkage, still not exported from
#     the binary, and exactly what llvm-split emitted for the same globals. lld's
#     LTO re-internalizes what stays partition-local.
#   * a partition needs a declaration for every symbol it references but does not
#     define. They are derived from the definition text and appended (top-level IR
#     is order-insensitive), and ONLY for symbols the partition actually mentions —
#     declaring everything everywhere would put every module's string-constant types
#     in every partition and hand the cache a miss on every edit.
# The `; mdk-module` markers themselves are dropped: 3.7% of the IR text, and clang
# does not need them.
#
# Both halves of that promise depend on every entity carrying a marker: an entity
# that reached the preamble instead would be BROADCAST, i.e. defined n times over.
# That is why an unreadable marker is refused rather than skipped.
pcg_partition() {
  awk -v PARTS="$3" -v DIR="$2" '
  # The type of a global, as the balanced prefix of the text after `constant`/
  # `global`: `{ i64, i64, i64, [2 x i8] }` before its initializer, `[2 x i64]`
  # before its elements, or a bare `i64`.
  function typeprefix(s,   c, o, cl, d, i, ch, n) {
    c = substr(s, 1, 1)
    if (c == "{") { o = "{"; cl = "}" }
    else if (c == "[") { o = "["; cl = "]" }
    else { i = index(s, " "); return (i > 0 ? substr(s, 1, i - 1) : s) }
    d = 0; n = length(s)
    for (i = 1; i <= n; i++) {
      ch = substr(s, i, 1)
      if (ch == o) d++
      else if (ch == cl) { d--; if (d == 0) return substr(s, 1, i) }
    }
    return ""
  }
  function die(msg) { print "pcg: " msg > "/dev/stderr"; bad = 1; exit 1 }
  function note(s) { if (!(s in sz)) { sz[s] = 0; ord[++nord] = s } }
  function assign(   i, s, tot, mp, tgt, cum, p, cnt) {
    if (markers == 0) { DEG = 1; NPARTS = 1; part[""] = 0; OF[0] = DIR "/p0"; return }
    if (PARTS == "") {
      # Derived: a partition per module scope. An `impl:` group joins the module
      # before it — impl groups are numerous: 337 of the 414 scopes in the CLI IR,
      # and tiny, and the module they follow is the one whose edit moves them.
      p = -1
      for (i = 1; i <= nord; i++) {
        s = ord[i]
        if (s == "program" || s == "") continue
        if (substr(s, 1, 5) == "impl:") { if (p < 0) p = 0; part[s] = p; continue }
        part[s] = ++p
      }
      NPARTS = p + 2
      part["program"] = p + 1
    } else {
      tot = 0
      for (i = 1; i <= nord; i++) if (ord[i] != "program") tot += sz[ord[i]]
      mp = PARTS - 1; if (mp < 1) mp = 1
      tgt = tot / mp
      cum = 0; p = 0
      for (i = 1; i <= nord; i++) {
        s = ord[i]
        if (s == "program") { part[s] = PARTS - 1; continue }
        # Close a partition BEFORE the scope that would overshoot it, never after:
        # types_typecheck alone is a fifth of the module, and appending it to a
        # nearly-full partition is how one job ends up doing a third of the work.
        if (p < mp - 1 && cnt[p] > 0 && cum + sz[s] > tgt * (p + 1)) p++
        part[s] = p; cnt[p]++
        cum += sz[s]
      }
      NPARTS = PARTS
    }
    part[""] = 0
    for (i = 0; i < NPARTS; i++) OF[i] = DIR "/p" i
  }
  # ONE output file open at a time. A partition per module means ~77 of them, and
  # one-true-awk (the /usr/bin/awk of older macOS) caps simultaneous output
  # redirections near 17 — writing to the 18th is a runtime error, not a slow path.
  # Lines arrive in scope order, so switching costs one close per marker.
  function put(f, l) {
    if (f != curf) { if (curf != "") close(curf); curf = f }
    if (f in opened) print l >> f
    else { print l > f; opened[f] = 1 }
  }
  function emit(l,   s, sym) {
    # The preamble belongs to every partition. Buffered rather than broadcast, so
    # it costs one append per partition at END instead of NPARTS open files here.
    if (tp < 0) { pre[++npre] = l; return }
    put(OF[tp], l)
    if (index(l, "@")) {
      s = l
      while (match(s, /@[-a-zA-Z$._0-9]+/)) {
        sym = substr(s, RSTART, RLENGTH)
        # Remember the ORDER of first reference, not just the fact of it. The
        # declarations below are written in this order, so the partition bytes do not
        # depend on which awk ran: `for (k in ref)` is hash order, and gawk, mawk and
        # busybox awk each give a different one — which would give the same source
        # three different sets of ThinLTO cache keys.
        if (!((tp, sym) in ref)) { ref[tp, sym] = 1; rlist[tp, ++rn[tp]] = sym }
        s = substr(s, RSTART + RLENGTH)
      }
    }
  }
  BEGIN { ind = 0; cur = ""; tp = -1; markers = 0; bad = 0; note("") }

  # ---- pass 1: scope sizes, symbol owners, and each symbol s external declaration
  NR == FNR {
    if (ind) { sz[cur]++; if ($0 ~ /^\}/) ind = 0; next }
    if ($0 ~ /^; mdk-module($| )/) {
      cur = substr($0, 14)
      sub(/^[ \t]+/, "", cur); sub(/[ \t]+$/, "", cur)
      if (cur == "") die("`; mdk-module` marker with no scope name at line " FNR " — the emitted IR is corrupt")
      markers++; note(cur); next
    }
    sz[cur]++
    if ($0 ~ /^define /) {
      ind = 1
      nm = $3; sub(/\(.*/, "", nm)
      d = $0; sub(/^define /, "declare ", d); sub(/[ \t]*\{[ \t]*$/, "", d)
      owner[nm] = cur; decl[nm] = d
      next
    }
    if ($0 ~ /^@/) {
      nm = $1
      rest = $0; sub(/^[^ ]+ = /, "", rest)
      nt = split(rest, T, " ")
      kw = 0
      for (i = 1; i <= nt; i++) if (T[i] == "constant" || T[i] == "global") { kw = i; break }
      if (!kw) die("unrecognized global definition: " $0)
      vis = ""; st = 1
      if (T[1] == "private" || T[1] == "internal") { vis = "hidden "; st = 2 }
      head = ""
      for (i = st; i <= kw; i++) head = head (head == "" ? "" : " ") T[i]
      after = rest
      for (i = 1; i <= kw; i++) sub(/^[^ ]+ +/, "", after)
      ty = typeprefix(after)
      if (ty == "") die("cannot read the type of global " nm ": " $0)
      owner[nm] = cur; decl[nm] = nm " = external " vis head " " ty
      next
    }
    next
  }

  # ---- pass 2: write each line to its partition (preamble to all of them)
  {
    if (!assigned) { assign(); assigned = 1 }
    # Degraded: one partition, byte-identical to the input. No linkage promotion and
    # no synthesized declarations, because nothing crosses a partition boundary.
    if (DEG) { put(OF[0], $0); next }
    if (ind) { emit($0); if ($0 ~ /^\}/) ind = 0; next }
    if ($0 ~ /^; mdk-module($| )/) {
      cur = substr($0, 14)
      sub(/^[ \t]+/, "", cur); sub(/[ \t]+$/, "", cur)
      tp = part[cur]; next
    }
    l = $0
    if (l ~ /^define /) ind = 1
    else if (l ~ /^@/) { sub(/ = private /, " = hidden ", l); sub(/ = internal /, " = hidden ", l) }
    emit(l)
  }

  END {
    if (bad) exit 1
    if (curf != "") { close(curf); curf = "" }
    if (DEG) { print "1 nomark"; exit 0 }
    # One pass per partition, each opening its file once: the preamble it shares with
    # every other partition, then a declaration for each symbol it references but does
    # not define, in first-reference order.
    for (q = 0; q < NPARTS; q++) {
      if (!(OF[q] in opened)) { printf "" > OF[q]; opened[OF[q]] = 1 }
      for (i = 1; i <= npre; i++) print pre[i] >> OF[q]
      for (i = 1; i <= rn[q]; i++) {
        sym = rlist[q, i]
        if (!(sym in owner)) continue
        if (part[owner[sym]] == q) continue
        print decl[sym] >> OF[q]
      }
      close(OF[q])
    }
    print NPARTS " mod"
  }
  ' "$1" "$1"
}
