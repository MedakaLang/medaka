# META
source_lines=24
stages=TYPES_USER
# SOURCE
-- Capability-effects v2 Stage 2b: NAMED-ARGUMENT authority + known-prefix
-- abstract analysis α.  Companion to effect_param.mdk (Stage 2a's concrete
-- parameterized rows).  This fixture is the CLI-level guard for:
--   * `(url : String) -> <Net url>` — the extern binds its Net authority to `url`
--   * α(that argument)      — at the call site `netGet "a.com/foo"`, the atom is
--                             α of the `url` argument: a string literal
--                             ⇒ Known "a.com/foo" ⇒ <Net "a.com/foo">
--   * delimiter-aware subsumption — the wildcard `<Net "a.com/*">` on `fetch`
--                             must ADMIT the α-derived `<Net "a.com/foo">`.
-- The reject side (sibling-host + computed/function-derived URL ⇒ α=Unknown⇒⊤,
-- both rejected) is exercised by the companion gate diff_compiler_effect_hole.sh.
effect Net Prefix

extern netGet : (url : String) -> <FFI, Net url> String

-- α("a.com/foo") = Known "a.com/foo"; admitted by the wildcard <Net "a.com/*">.
-- `fetch` is a function (unforced closure) so the extern netGet is never
-- actually evaluated — the fixture exercises the front-end (parse + α + subsume),
-- not the runtime, exactly like effect_param.mdk.
fetch : Unit -> <Net "a.com/*", FFI> String
fetch _ = netGet "a.com/foo"

main : <IO> Unit
main = println "effect hole ok"
# TYPES_USER
netGet : (url : String) -> <FFI, Net url> String
fetch : Unit -> <FFI, Net "a.com/*"> String
main : <IO> Unit
