## [P-DOCTEST-RESIDUAL] `compiler/tools/doctest.mdk` module-identity residual (#1223)

⚠️ **NOT two drivers.** This row said "prelude-only → single-file" until 2026-07-30, which
reads as a second elaboration path and is false: `runSingle` routes a no-import file
*"through the SAME multi-module path as an import-bearing one — the 1-module wrappers"*
(its own comment), and both arms of `runChosen` reach `elaborateModules`.

What the no-import arm actually carries is a residual **flatten** — the prelude is
concatenated into the user's decl list rather than being a node — which is why it must
first compute `livePrelude = dropShadowedExp userNames coreDecls` and needs a
`programIsCore` guard so `medaka test stdlib/core.mdk` doesn't double-declare everything.
Both are workarounds for the flatten; under DICT §7.1 U1 (prelude is a node) a genuine
2-node graph needs neither, since SHADOW S1's per-module scoping already answers them.

⚠️ **A third residual existed here, not of the flatten, and it is now PARTIALLY fixed**
(ARCH E-5, #1521, owns but does not close #1223): `runSingle` used to stamp its one node
under a synthetic id, `"__user__"`, hardcoded at four sites, while `loadProgram` stamped
the same file under its loader-derived id — one declaration, two identities in a single
`medaka test <dir>` process (#1223, S2). `runSingle`/`runPropsSingle`/`runTestDeclsSingle`/
`propsReportSingle` now compute `canonicalPathId` (`driver/loader.mdk`) — the SAME
last-containing-root, round-trip-guarded convention a sibling's import canonicalizes
through — over roots derived from the target's own directory.

⚠️ A first pass at this fix used plain `moduleIdOfPath` (first-root) instead, which agrees
with the loader only when a project has ONE root and still diverged the moment a target sat
below its own `medaka.toml` — caught in adversarial review before merge (#1526); see
`test/origin_fixtures/nested` for the discriminating fixture.

Orthogonal to the flatten: `runSingle` was already on the Module path; only the node's NAME
was wrong. **This closes only the NO-IMPORT case.** `driver/loader.mdk:662-669` documents a
separate, still-open residual for IMPORT-BEARING files (`runMulti`, untouched by this fix):
an entry's own id is first-root while the same file reached as another target's dependency
is last-root — MEASURED still reproducing (`test/origin_entry_residual_fixture`, pinned as
`diff_compiler_origin_agreement.sh`'s `entry_residual` section). #1223 stays OPEN.

Derive rather than trust this row: `grep -n 'SAME multi-module path' compiler/tools/test_cmd.mdk`

## [P-IMPORT-BINDS] Bare `import` detail + example

A bare `import map` binds NO names — not values, not types, not `map.get` (qualified access
exists *only* via `as`). It is not a no-op: **any** import of a module brings that module's
`impl`s into scope for dispatch, which is the whole job of the bare form. Example:
`stdlib/json.mdk`'s bare `import array` — without it, `map (+ 1) [|1,2,3|]` is *"No impl of
Mappable for Array"*.

Also for the record on import forms: an alias-qualified name (`import map as M` → `M.get`)
works for **values only** — an alias-qualified name in *type* position is a parse error, so
types must be imported by name (`import map.{Map}`), never through the alias.
