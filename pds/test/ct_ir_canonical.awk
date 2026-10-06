# Canonicalizes a `medaka build --keep-ir` module for the constant-time gates
# (constant_time_reductions.sh, constant_time_public_key.sh,
# constant_time_signing.sh), so a located array read is the same operation as
# the plain one they audit.
#
# A located `xs[i]` on an Array calls the Index impl's body
# `mdk_core__arrayIndexAt(site, xs, i)` straight, where the impl itself,
# `mdk_impl_Array_index(xs, i)`, forwards to it with site 0 (tagged 1). The site
# is a compile-time packed source location. This rewrite admits it only as an
# integer literal at every call site, and only if the body uses it for nothing
# but the out-of-range trap call (`ashr` to untag, then `@mdk_oob_at_at`). A
# literal on an abort path is public data, so stripping it changes no claim.
# Then:
#   - each `call i64 @mdk_core__arrayIndexAt(i64 <literal>, ` becomes
#     `call i64 @mdk_impl_Array_index(`;
#   - the forwarding impl definition is dropped;
#   - the body is renamed `mdk_impl_Array_index`, so callers and closures
#     reach one definition with the impl's control shape.
# Anything else (a register site, a site used by a branch or a load, a changed
# forwarder) exits 1, and the build wrapper fails the gate.
# The List and String twins are left alone: no audited helper reads one, and a
# helper that began to would move its pinned shape.

function bad(msg) {
  print "ct_ir_canonical: " msg > "/dev/stderr"
  failed = 1
  exit 1
}

{ lines[++n] = $0 }

END {
  if (failed) exit 1
  twin = "@mdk_core__arrayIndexAt("
  impl = "@mdk_impl_Array_index("
  # Locate the twin's and the forwarder's definitions.
  for (i = 1; i <= n; i++) {
    if (index(lines[i], "define i64 " twin) == 1) twinStart = i
    if (index(lines[i], "define i64 " impl) == 1) implStart = i
  }
  if (!twinStart) {
    for (i = 1; i <= n; i++) print lines[i]
    exit 0
  }
  if (lines[twinStart] != "define i64 @mdk_core__arrayIndexAt(i64 %arg0, i64 %arg1, i64 %arg2) {")
    bad("unexpected arrayIndexAt signature: " lines[twinStart])
  for (twinEnd = twinStart; twinEnd <= n && lines[twinEnd] != "}"; twinEnd++) ;
  # The site parameter feeds only `%t = ashr i64 %arg0, 1`, and that register
  # only the trap call.
  siteReg = ""
  for (i = twinStart + 1; i < twinEnd; i++) {
    if (lines[i] ~ /%arg0([^0-9]|$)/) {
      if (siteReg != "" || lines[i] !~ /^  %t[0-9]+ = ashr i64 %arg0, 1$/)
        bad("arrayIndexAt uses its site beyond the trap: " lines[i])
      siteReg = lines[i]
      sub(/^  /, "", siteReg)
      sub(/ .*/, "", siteReg)
    }
  }
  if (siteReg == "") bad("arrayIndexAt has no site untag")
  for (i = twinStart + 1; i < twinEnd; i++) {
    rest = lines[i]
    if (index(rest, "  " siteReg " = ") == 1) continue
    if (match(rest, siteReg "([^0-9]|$)") && rest !~ /^  call void @mdk_oob_at_at\(i64 %t[0-9]+, i64 %t[0-9]+\)$/)
      bad("arrayIndexAt site reaches more than the trap: " rest)
  }
  if (implStart) {
    if (lines[implStart] != "define i64 @mdk_impl_Array_index(i64 %arg0, i64 %arg1) {" ||
        lines[implStart + 1] != "entry:" ||
        lines[implStart + 2] != "  %t0 = call i64 @mdk_core__arrayIndexAt(i64 1, i64 %arg0, i64 %arg1)" ||
        lines[implStart + 3] != "  ret i64 %t0" ||
        lines[implStart + 4] != "}")
      bad("mdk_impl_Array_index is not the plain forwarder to arrayIndexAt")
  }
  for (i = 1; i <= n; i++) {
    if (implStart && i >= implStart && i <= implStart + 4) continue
    line = lines[i]
    if (i == twinStart) {
      sub(/@mdk_core__arrayIndexAt\(/, "@mdk_impl_Array_index(", line)
      print line
      continue
    }
    while (match(line, /call i64 @mdk_core__arrayIndexAt\(/)) {
      head = substr(line, 1, RSTART - 1)
      tail = substr(line, RSTART + RLENGTH)
      if (!match(tail, /^i64 -?[0-9]+, /))
        bad("arrayIndexAt called with a non-literal site: " lines[i])
      line = head "call i64 @mdk_impl_Array_index(" substr(tail, RLENGTH + 1)
    }
    if (index(line, "@mdk_core__arrayIndexAt") && index(line, "declare ") != 1)
      bad("arrayIndexAt referenced other than by a direct call: " lines[i])
    print line
  }
}
