# P0-E — Is `TyRow` reachable at `headTyconTy`, and is it a defect?

Binary: `/root/medaka/.claude/worktrees/peppy-brewing-kitten/medaka` @ HEAD `aaa43716`.
All probes run with `MEDAKA_STRICT=1`. Scratch: `/var/tmp/medaka-scratch/p0e/`.

## Step 0 — source reading (structural, no build)

### 0.1 `TyRow` has exactly ONE producer in the parser

```
$ grep -n 'TyRow' compiler/frontend/parser.mdk
2068:-- a row means. Produces `TyRow`, NOT a filler-wrapped `TyEffect`: a bare row
2071:-- `TyRow`'s doc comment, ast.mdk).
2082:mkRow (labels, tail) loc = TyRow labels tail (Some loc)
```

`mkRow` has exactly one caller, `parseBareEffectAtom` (`parser.mdk:2072-2079`), which is
reached from `parseTyAtom`:

```
parseTyAtom : Parser Ty
parseTyAtom = do
  t <- peekP
  match t
    TUpper c => ...
    TIdent v => emit (TyVar v)
    TLParen => parseTyParen
    TLt => parseBareEffectAtom          <-- the only TyRow route
    _ => failP "expected type atom"
```

Note the contrast with `tyFor TLt = parseEffectTy` (`parser.mdk:1847`), which produces
`TyEffect` — so a `<...>` at the START of a full type (`parseTyFun`) is `TyEffect`, and a
`<...>` in an ATOM slot is `TyRow`. Parenthesising (`(<Stdout> Unit)`) routes through
`parseTyParen` → `parseTy` → `tyFor TLt` → `TyEffect`, NOT `TyRow`.

### 0.2 An impl's head-type vector is parsed with `parseTyAtom` — so `TyRow` CAN be slot 0

```
implRest : Bool -> Int -> String -> Parser Decl
implRest pub kw iface = do
  tyargs <- many parseTyAtom          <-- parser.mdk:2792
  ...
```

`keyEntryOf` (`typecheck.mdk:18413`) and `keyEntryOfRow` (`:19100`) both project
`headTyconTy headTy` where `headTy` is the FIRST element of that vector. `headTyNode`
unwraps only `TyApp`, so a slot-0 `TyRow` lands directly on the `_ => None` arm.

⇒ `impl Foo <Stdout>` is the shape to probe. (`impl Foo (Async <Stdout> Unit)` is NOT —
`headTyNode` unwraps the `TyApp` spine to `TyCon Async`.)

### 0.3 Two arms that make a `TyRow` impl head look dangerous a priori

```
$ grep -n 'TyRow' compiler/types/typecheck.mdk    (excerpt)
18059:tyIsConcrete (TyRow _ _ _) = True
19001:tyStep (TyRow _ _ _) _ = MOk
```

i.e. a `TyRow` impl head is classified CONCRETE by the specificity ranking, and its
head-match step answers `MOk` (matches ANY goal) — while `headTyconTy` files it in the
HEADLESS bucket. That combination is exactly the #1617/#1618 hazard shape. Whether it is
observable is the empirical question below.

---

## VERDICT: `REACHABLE, NO DEFECT`

`TyRow` IS reachable at `headTyconTy`'s `_ => None` arm — `impl Foo <Stdout>` parses a bare
`TyRow` into head slot 0 and `keyEntryOf` projects that slot unconditionally. But it is not a
defect of the #1617/#1618 shape: **every spelling is rejected LOUDLY at `check`/`run`/`build`,
exit 1, in both impl-declaration permutations, single-file and cross-module, human and `--json`
arms** — and, independently, a `TyRow`-headed impl is *unselectable* (it captures no goal),
so there is no wrong-impl selection to be silent about.

## Step 1 — Reachability

### 1.1 Bare row as impl head: PARSES, then hard-rejected

r1.mdk:
```
interface Foo a where
  foo : a -> Int

impl Foo <Stdout> where
  foo _ = 1

main = println 0
```
```
$ MEDAKA_STRICT=1 ./medaka check /var/tmp/medaka-scratch/p0e/r1.mdk
Exit code 1
/var/tmp/medaka-scratch/p0e/r1.mdk:4:9: A row <Stdout> was written here, but this type-argument position isn't row-kinded — it expects an ordinary type, not an effect row. Rows can only be written where a type constructor's parameter has row kind (e.g. the `e` of `Async e a`).
  |
4 | impl Foo <Stdout> where
  |          ^
```

It parses (no parse error, no resolve error) — the rejection is `T-ROW-KIND-MISMATCH` from
`fromAstTypeE`'s `TyRow` arm (`typecheck.mdk:8287-8289`), pointing at the impl head's own span.
So the AST really does carry `TyRow` in `DImpl.tys` slot 0, which is exactly what `keyEntryOf`
feeds to `headTyconTy`.

### 1.2 The rejection is NOT a method-typechecking artifact — a method-less impl gets it too

```
$ MEDAKA_STRICT=1 ./medaka check /var/tmp/medaka-scratch/p0e/m_marker.mdk
Exit code 1
/var/tmp/medaka-scratch/p0e/m_marker.mdk:4:12: A row <Stdout> was written here, but this type-argument position isn't row-kinded — it expects an ordinary type, not an effect row. Rows can only be written where a type constructor's parameter has row kind (e.g. the `e` of `Async e a`).
  |
4 | impl Marker <Stdout> where
  |             ^
/var/tmp/medaka-scratch/p0e/m_marker.mdk:1:0: 'impl Marker <Stdout>' is missing method 'mk'. Every interface method without a default body must be implemented — define 'mk' in the impl (or check for a typo in a method name)
  |
1 | interface Marker a where
  | ^
```
The row error fires at impl-head elaboration, before/independent of any method body. Note the
second diagnostic names the impl as `impl Marker <Stdout>` — the head really is the row.

### 1.3 Every row spelling behaves the same

```
$ MEDAKA_STRICT=1 ./medaka check /var/tmp/medaka-scratch/p0e/e_empty.mdk     # impl Foo <> where
Exit code 1
/var/tmp/medaka-scratch/p0e/e_empty.mdk:4:9: A row <> was written here, but this type-argument position isn't row-kinded — it expects an ordinary type, not an effect row. Rows can only be written where a type constructor's parameter has row kind (e.g. the `e` of `Async e a`).
  |
4 | impl Foo <> where
  |          ^

$ MEDAKA_STRICT=1 ./medaka check /var/tmp/medaka-scratch/p0e/e_tail.mdk      # impl Foo <e> where
Exit code 1
/var/tmp/medaka-scratch/p0e/e_tail.mdk:4:9: A row <e> was written here, but this type-argument position isn't row-kinded — it expects an ordinary type, not an effect row. Rows can only be written where a type constructor's parameter has row kind (e.g. the `e` of `Async e a`).
  |
4 | impl Foo <e> where
  |          ^

$ MEDAKA_STRICT=1 ./medaka check /var/tmp/medaka-scratch/p0e/m_two.mdk       # impl Foo <Stdout> <Net> where
Exit code 1
/var/tmp/medaka-scratch/p0e/m_two.mdk:4:9: A row <Stdout> was written here, but this type-argument position isn't row-kinded — it expects an ordinary type, not an effect row. Rows can only be written where a type constructor's parameter has row kind (e.g. the `e` of `Async e a`).
  |
4 | impl Foo <Stdout> <Net> where
  |          ^
/var/tmp/medaka-scratch/p0e/m_two.mdk:4:18: A row <Net> was written here, but this type-argument position isn't row-kinded — it expects an ordinary type, not an effect row. Rows can only be written where a type constructor's parameter has row kind (e.g. the `e` of `Async e a`).
  |
4 | impl Foo <Stdout> <Net> where
  |                   ^
```
The closed-row (`<>`) and tail-var (`<e>`) forms matter: `isRowSlotArg`'s history (#823, the
`graded_closed_row_grade_ok` fixture) is exactly a case where those three spellings disagreed.
Here they do not.

### 1.4 The GRADED case — a row-kinded slot does NOT open a hole

The one shape where a `TyRow` is *legitimate* is a KRow type-app argument slot
(`isRowSlotArg`/`rowArgOf`, `typecheck.mdk:8413/8461`). Probed with a graded interface whose
slot 0 kind list is `[KRow, KType]` (the `test/typecheck_error_fixtures/graded_closed_row_grade_ok.mdk`
shape):

g_row.mdk:
```
data Async e a = Done a | Suspend (Unit -> <e> Async e a)

interface GT f where
  gth : f e a -> (a -> <e> f e b) -> f e b
  gpure : a -> f <> a

impl GT <Stdout> where
  gth m k = m
  gpure x = x

main = println 0
```
```
$ MEDAKA_STRICT=1 ./medaka check /var/tmp/medaka-scratch/p0e/g_row.mdk
Exit code 1
/var/tmp/medaka-scratch/p0e/g_row.mdk:7:8: A row <Stdout> was written here, but this type-argument position isn't row-kinded — it expects an ordinary type, not an effect row. Rows can only be written where a type constructor's parameter has row kind (e.g. the `e` of `Async e a`).
  |
7 | impl GT <Stdout> where
  |         ^
/var/tmp/medaka-scratch/p0e/g_row.mdk:8:12: Impl of 'gth' for interface 'GT' identifies quantified type variables that the declared type 'f e a -> (a -> <e> f e b) -> f e b' keeps distinct (two method variables forced equal, or a method variable forced equal to an impl-head variable). Every caller may instantiate each independently, so the body must keep them independent.
  |
8 |   gth m k = m
  |             ^
/var/tmp/medaka-scratch/p0e/g_row.mdk:9:12: Cannot construct infinite type involving a
  |
9 |   gpure x = x
  |             ^
```
(The 2nd/3rd diagnostics are my deliberately-stub method bodies; the control below shows the
2nd is *not* caused by the row.)

CONTROL — same file with `impl GT Async` (a `TyCon` head), `gpure x = Done x`:
```
$ MEDAKA_STRICT=1 ./medaka check /var/tmp/medaka-scratch/p0e/g_ctl.mdk
Exit code 1
/var/tmp/medaka-scratch/p0e/g_ctl.mdk:8:12: Impl of 'gth' for interface 'GT' identifies quantified type variables that the declared type 'f e a -> (a -> <e> f e b) -> f e b' keeps distinct (two method variables forced equal, or a method variable forced equal to an impl-head variable). Every caller may instantiate each independently, so the body must keep them independent.
  |
8 |   gth m k = m
  |             ^
```
The control shows the row head is what adds `T-ROW-KIND-MISMATCH` at 7:8; the `gth` complaint
is my stub body, present in both arms. `checkGradedImplHead` abstains on a `TyRow` (its `_ => ()`
arm), but `fromAstTypeE` catches it anyway — belt and braces.

### 1.5 The `argument-slot` variant is NOT this question (control on the spine)

`impl C (Async <Stdout> Unit)` cannot put a `TyRow` at the head: `headTyNode` unwraps the
`TyApp` spine to `TyCon Async`. Structurally, a `TyApp` spine can never be *headed* by a
`TyRow` either — `parseTyApp`'s `head <- parseTyAtom` is only reached from `tyFor`'s NON-`TLt`
branch (`tyFor TLt = parseEffectTy`, which yields `TyEffect`). A `TyRow` therefore appears only
as a standalone element of a `many parseTyAtom` list, which for `implRest` means: as one of the
impl's head types. Slot 0 is the only route to `headTyconTy`.

## Step 2 — The #1617/#1618 template applied

### 2.1 Both permutations, one file (`check` + `run`)

r2a.mdk (row impl FIRST) / r2b.mdk (concrete impl FIRST), both with `impl Foo Int` and
`main = println (foo 7)`:

```
$ MEDAKA_STRICT=1 ./medaka run /var/tmp/medaka-scratch/p0e/r2a.mdk
Exit code 1
/var/tmp/medaka-scratch/p0e/r2a.mdk:4:9: A row <Stdout> was written here, but this type-argument position isn't row-kinded — it expects an ordinary type, not an effect row. Rows can only be written where a type constructor's parameter has row kind (e.g. the `e` of `Async e a`).
  |
4 | impl Foo <Stdout> where
  |          ^

$ MEDAKA_STRICT=1 ./medaka run /var/tmp/medaka-scratch/p0e/r2b.mdk
Exit code 1
/var/tmp/medaka-scratch/p0e/r2b.mdk:7:9: A row <Stdout> was written here, but this type-argument position isn't row-kinded — it expects an ordinary type, not an effect row. Rows can only be written where a type constructor's parameter has row kind (e.g. the `e` of `Async e a`).
  |
7 | impl Foo <Stdout> where
  |          ^
```

CONTROL (ctl.mdk — identical but `impl Foo Bool` in place of `impl Foo <Stdout>`):
```
$ MEDAKA_STRICT=1 ./medaka run /var/tmp/medaka-scratch/p0e/ctl.mdk
222
```
The row head is the only variable, and it is what turns a working exit-0 program into a loud
exit-1 rejection. Order does not change the answer.

### 2.2 The DISCRIMINATING probe — does the row impl CAPTURE goals?

Source reading gave two arms that suggest it should: `tyIsConcrete (TyRow _ _ _) = True`
(`:18059`) and `tyStep (TyRow _ _ _) _ = MOk` (`:19001`) — i.e. maximally specific AND matches
anything — while `headTyconTy` files it in the HEADLESS bucket. If the entry were selectable,
that is a wildcard that outranks every concrete impl.

It is NOT selectable. With ONLY the row impl present:

```
$ MEDAKA_STRICT=1 ./medaka check /var/tmp/medaka-scratch/p0e/d_row.mdk    # goal: foo True
Exit code 1
/var/tmp/medaka-scratch/p0e/d_row.mdk:4:9: A row <Stdout> was written here, but this type-argument position isn't row-kinded — it expects an ordinary type, not an effect row. Rows can only be written where a type constructor's parameter has row kind (e.g. the `e` of `Async e a`).
  |
4 | impl Foo <Stdout> where
  |          ^
/var/tmp/medaka-scratch/p0e/d_row.mdk:7:16: No impl of Foo for Bool
  |
7 | main = println (foo True)
  |                 ^

$ MEDAKA_STRICT=1 ./medaka check /var/tmp/medaka-scratch/p0e/d_int.mdk    # goal: foo 7
Exit code 1
/var/tmp/medaka-scratch/p0e/d_int.mdk:4:9: A row <Stdout> was written here, but this type-argument position isn't row-kinded — it expects an ordinary type, not an effect row. Rows can only be written where a type constructor's parameter has row kind (e.g. the `e` of `Async e a`).
  |
4 | impl Foo <Stdout> where
  |          ^
/var/tmp/medaka-scratch/p0e/d_int.mdk:7:16: No impl of Foo for Int
  |
7 | main = println (foo 7)
  |                 ^

$ MEDAKA_STRICT=1 ./medaka check /var/tmp/medaka-scratch/p0e/d_unit.mdk   # goal: foo ()
Exit code 1
/var/tmp/medaka-scratch/p0e/d_unit.mdk:4:9: A row <Stdout> was written here, but this type-argument position isn't row-kinded — it expects an ordinary type, not an effect row. Rows can only be written where a type constructor's parameter has row kind (e.g. the `e` of `Async e a`).
  |
4 | impl Foo <Stdout> where
  |          ^
/var/tmp/medaka-scratch/p0e/d_unit.mdk:7:16: No impl of Foo for Unit
  |
7 | main = println (foo ())
  |                 ^
```

CONTROL (d_ctl.mdk — `impl Foo Int` instead of the row impl, same `foo True` goal):
```
$ MEDAKA_STRICT=1 ./medaka check /var/tmp/medaka-scratch/p0e/d_ctl.mdk
Exit code 1
/var/tmp/medaka-scratch/p0e/d_ctl.mdk:7:16: No impl of Foo for Bool
  |
7 | main = println (foo True)
  |                 ^
```
`No impl of Foo for <T>` fires for **Bool, Int and Unit alike**, i.e. the row impl matches
nothing at all — including `Unit`, which rules out the "post-error recovery elaborated it to
`TCon "Unit"` and it now matches Unit goals" hypothesis. This is a positive discriminating
result, not an absence: the control shows the same message shape is producible, so the probe
could have distinguished capture from non-capture.

**Mechanism** (derived after the measurement, not before): the impl-head-vs-goal matcher is
`matchStep` (`typecheck.mdk:19676-19709`), a DIFFERENT function from the specificity engine's
`tyStep`. `matchStep` has no `TyRow` arm and ends in `matchStep _ _ = MFail` (`:19709`). So a
`TyRow`-headed entry never becomes a candidate, and `tyStep`'s `MOk` / `tyIsConcrete`'s `True`
are dead for it. Two guards, either alone sufficient.

### 2.3 Cross-module, both permutations, all three verbs

`/var/tmp/medaka-scratch/p0e/proj/` = `medaka.toml` + `m.mdk` (the interface + both impls,
`export`ed) + `main.mdk` (`import m.{Foo, foo}` / `main = println (foo 7)`).

Permutation A (row impl first, m.mdk:4):
```
$ MEDAKA_STRICT=1 ./medaka check /var/tmp/medaka-scratch/p0e/proj/main.mdk
Exit code 1
/var/tmp/medaka-scratch/p0e/proj/m.mdk:4:16: A row <Stdout> was written here, but this type-argument position isn't row-kinded — it expects an ordinary type, not an effect row. Rows can only be written where a type constructor's parameter has row kind (e.g. the `e` of `Async e a`).
  |
4 | export impl Foo <Stdout> where
  |                 ^

$ MEDAKA_STRICT=1 ./medaka run /var/tmp/medaka-scratch/p0e/proj/main.mdk
Exit code 1
/var/tmp/medaka-scratch/p0e/proj/m.mdk:4:16: A row <Stdout> was written here, but this type-argument position isn't row-kinded — it expects an ordinary type, not an effect row. Rows can only be written where a type constructor's parameter has row kind (e.g. the `e` of `Async e a`).
  |
4 | export impl Foo <Stdout> where
  |                 ^

$ MEDAKA_STRICT=1 ./medaka check --json /var/tmp/medaka-scratch/p0e/proj/main.mdk
Exit code 1
{"files":[{"file":"/var/tmp/medaka-scratch/p0e/proj/m.mdk","diagnostics":[{"code":"T-ROW-KIND-MISMATCH","kind":"type","message":"A row <Stdout> was written here, but this type-argument position isn't row-kinded — it expects an ordinary type, not an effect row. Rows can only be written where a type constructor's parameter has row kind (e.g. the `e` of `Async e a`).","range":{"end":{"character":24,"line":3},"start":{"character":16,"line":3}},"severity":1,"source":"medaka"}]},{"file":"/var/tmp/medaka-scratch/p0e/proj/main.mdk","diagnostics":[]}]}

$ MEDAKA_STRICT=1 ./medaka build /var/tmp/medaka-scratch/p0e/proj/main.mdk -o /var/tmp/medaka-scratch/p0e/proj/out > /var/tmp/medaka-scratch/p0e/build.log 2>&1; echo "build exit=$?"
build exit=1
$ cat /var/tmp/medaka-scratch/p0e/build.log
/var/tmp/medaka-scratch/p0e/proj/m.mdk:4:16: A row <Stdout> was written here, but this type-argument position isn't row-kinded — it expects an ordinary type, not an effect row. Rows can only be written where a type constructor's parameter has row kind (e.g. the `e` of `Async e a`).
  |
4 | export impl Foo <Stdout> where
  |                 ^
```

Permutation B (concrete impl first, row impl at m.mdk:7):
```
$ MEDAKA_STRICT=1 ./medaka check /var/tmp/medaka-scratch/p0e/proj/main.mdk
Exit code 1
/var/tmp/medaka-scratch/p0e/proj/m.mdk:7:16: A row <Stdout> was written here, but this type-argument position isn't row-kinded — it expects an ordinary type, not an effect row. Rows can only be written where a type constructor's parameter has row kind (e.g. the `e` of `Async e a`).
  |
7 | export impl Foo <Stdout> where
  |                 ^

$ MEDAKA_STRICT=1 ./medaka build /var/tmp/medaka-scratch/p0e/proj/main.mdk -o /var/tmp/medaka-scratch/p0e/proj/outb > /var/tmp/medaka-scratch/p0e/buildb.log 2>&1; echo "build exit=$?"; ls /var/tmp/medaka-scratch/p0e/proj/
build exit=1
main.mdk
medaka.toml
m.mdk
```
No binary is produced in either permutation (`ls` shows neither `out` nor `outb`), so there is
no "built binary disagrees with `run`" arm to compare — the divergence axis #1617/#1618 exploit
is closed off by the exit-1.

⚠️ Both `build` exit codes were read from a FILE redirect + `$?`, never through a pipe.

Notably the `--json` arm carries the diagnostic on a MULTI-MODULE project — this is *not* an
instance of the #1362 silent-accept hole (which is specific to `env.internalGuard`'s single read
site in `resolvePass`).

### 2.4 Severity, derived

- Silent wrongness (S0) requires exit 0 with a wrong answer. **Never observed**: every probe
  carrying a `TyRow` impl head exited 1 with a located `T-ROW-KIND-MISMATCH`.
- Wrong-impl selection requires the entry to be selectable. **Measured not selectable** (§2.2).
- ⇒ No severity to assign. Not a defect.

## Step 3 — Tracker

```
$ gh issue list --state all --search TyRow --limit 30
1090	CLOSED	typecheck.mdk:16931-16936 comment falsely claims a different-arity dataParamKindsRef clash safely 'abstains' — it actually false-rejects via T-ROW-KIND-MISMATCH	S2: misleading, verified, ws:typecheck	2026-08-03T21:02:29Z
1028	CLOSED	Cross-module opaque (plain-export) KRow-kinded data type: kind info not visible to importer, mistypes any written row as the wrapped type		2026-07-25T03:16:32Z
1094	CLOSED	S0: the Effect-kinded (KRow) type-argument slot is NOT CHECKED at unification — Async <Stdout> Int is accepted as Async <> Int and a value typed Int with no effect row prints (both engines)	S0: silent wrongness, verified, ws:language, ws:typecheck	2026-07-27T07:14:53Z

$ gh issue list --state all --search 997 --limit 30
997	CLOSED	S3: a row/grade cannot be written in a type-ARGUMENT slot (`Async <Stdout> Unit`) — parseTyAtom has no TLt arm	verified, ws:language	2026-07-24T22:20:36Z
1091	OPEN	test coverage gap: no import-order-swapped fixture for method-name / data-type-name cross-module collisions (the graded_iface_head_collision_swapped shape was deleted, not replaced, for these axes)	S3: friction & debt, ws:testing	2026-07-26T21:19:04Z
1028	CLOSED	Cross-module opaque (plain-export) KRow-kinded data type: kind info not visible to importer, mistypes any written row as the wrapped type		2026-07-25T03:16:32Z
822	CLOSED	Graded interfaces phase 2: interface heads of kind Row -> Type -> Type, graded instances, W3 integration	ws:typecheck	2026-07-25T01:25:57Z
804	CLOSED	S3: abstractly-exported (`export data`) row-kinded type spuriously rejected with T-EFFECT-UNDETERMINED cross-module (param-kinds not propagated for private-ctor types)	S3: friction & debt, verified, ws:typecheck	2026-07-25T03:16:32Z
```
No open or closed issue covers a `TyRow` impl HEAD or `headTyconTy`'s handling of one.
Nothing to dedupe against, and nothing to file.

## Step 4 — Two observations, neither a defect claim

1. **`headTyconTy`'s live wildcard set stays at TWO.** Of the five shapes the `_ => None` arm
   swallows: `TyVar` correct by design; `TyFun` = #1617; `TyEffect` = #1618; `TyConstrained`
   measured-not-a-defect (#1617 body line 43); **`TyRow` measured-not-a-defect here**, by a
   different mechanism — `TyConstrained` agrees on both sides because stripping a constraint
   still leaves a headless type, whereas `TyRow` is unreachable *in a program that checks*, and
   doubly unselectable via `matchStep`'s `_ => MFail`. #1617's "the live set is two" is
   unchanged by this packet.

2. **Reporting dedupe (informational, S3-adjacent at most).** `pushTypeErrorOnceAt` keys on
   MESSAGE TEXT ALONE (its own comment, `typecheck.mdk` just below `rowArgOf`, says so), so two
   impls whose heads carry the SAME row body fold into ONE diagnostic and only the first is
   located. `f_fold.mdk` has `impl Foo <Stdout>` at :7 AND `impl Bar <Stdout>` at :10:
   ```
   $ MEDAKA_STRICT=1 ./medaka check /var/tmp/medaka-scratch/p0e/f_fold.mdk
   Exit code 1
   /var/tmp/medaka-scratch/p0e/f_fold.mdk:7:9: A row <Stdout> was written here, but this type-argument position isn't row-kinded — it expects an ordinary type, not an effect row. Rows can only be written where a type constructor's parameter has row kind (e.g. the `e` of `Async e a`).
     |
   7 | impl Foo <Stdout> where
     |          ^
   ```
   Only :7 is reported. This is the documented, deliberate behaviour of that helper and it does
   not change the exit code — the program is still rejected. Recorded so a future reader does not
   mistake the single diagnostic for single-site coverage. (Two DIFFERENT rows do both report —
   see `m_two.mdk` in §1.3.)

## REFUSALS

- **I did not instrument `headTyconTy` to observe a `TyRow` arriving there.** The packet forbids
  building, and there is no probe entry that prints the impl registry's head-key buckets. The
  reachability claim in §1 is therefore SOURCE-DERIVED (parser produces `TyRow` at impl slot 0;
  `keyEntryOf` projects slot 0 unconditionally with no guard between them) and corroborated
  behaviourally (§1.2's `'impl Marker <Stdout>' is missing method 'mk'` proves the `DImpl` with a
  row head reaches impl-completeness checking, i.e. registration, and §2.2 proves whatever entry
  exists matches nothing). It is NOT a direct observation of the `_ => None` arm firing.
- **I did not exercise the wasm engine arm.** No program with a `TyRow` impl head reaches any
  engine — all three verbs exit 1 at typecheck — so there is nothing for a third engine to
  disagree about. If a future change makes such a program check clean, the wasm arm becomes
  live and this conclusion must be re-derived.
- **I did not probe `requires`-clause or constraint-position rows** (`reqTyToMono`,
  `typecheck.mdk:23249`, which pushes the same `T-ROW-KIND-MISMATCH`). Those positions do not
  feed `headTyconTy` — its only three call sites are `keyEntryOf` (:18413), `keyEntryOfRow`
  (:19100) and `univReceiverTag` (:22574), and all 12 callers of the last take an impl's head-type
  vector (`grep -nw univReceiverTag compiler/types/typecheck.mdk`). So they are outside this
  packet's question.
- **I could not determine whether the `_ => None` fall-through is *intentional* for `TyRow`.**
  The arm has no `TyRow`-specific comment, unlike `tyStep`/`tyIsConcrete`, which each carry an
  explicit "rows are transparent" rationale. Whether Phase 4 should make that abstention explicit
  is a design call, not a measurement, so I leave it to you.

