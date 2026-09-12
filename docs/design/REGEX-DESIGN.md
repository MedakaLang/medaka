# Regular expressions in the stdlib

Status: DESIGN, 2026-09-11. Nothing built. Tracking: #435 lists `regex` as a
post-P1 roadmap item; `docs/spec/language-design.md` § Standard Library has
listed "regex" under string utilities since the start.

## 1. Why now

Two sweeps of the tree on 2026-09-11 (one over `compiler/`, one over
`stdlib/`, `test/`, `pds/`, `sqlite/`, `gzip/`, `parsec/`, `byteparser/`)
found roughly 170 candidate sites in the compiler and roughly 100 outside it
where hand-written character scanning stands in for a pattern. The recurring
shapes:

- **Word boundary.** `\bNAME\b` is hand-rolled four separate times
  (`compiler/tools/lint.mdk` twice, `compiler/tools/doc.mdk`,
  `compiler/tools/lsp.mdk`, plus a copy in
  `compiler/entries/playground_main.mdk`), each with its own boundary
  predicate, and they disagree on whether `'` is a word character.
- **Capture by hard-coded offset.** `stdlib/time.mdk` `parseIso` checks six
  separator positions by `sliceClamped` and then slices six fields by number.
  `pds/test/serve_client_main.mdk` reads a header value with `drop 15`
  where 15 is the length of `content-length:`.
- **Alternation by `split` then list pattern.** `split "*"` to fake a glob,
  `split "\"code\":\""` to pull every diagnostic code out of JSON, `split "."`
  to validate an IPv4 address. Eight of the fifteen strongest sites outside
  the compiler use `split` to do a regex's job.
- **Char class by substring search per character.**
  `pds/lib/ratelimit.mdk` tests hex-or-colon with
  `contains (toLower (fromChar c)) "0123456789abcdef:"`, allocating a
  one-char string and running `stringIndexOf` for every character.
- **Mini engines.** `compiler/tools/gate_registry.mdk` `globMatchAt` and
  `sqlite/lib/select.mdk` `likeMatch` are both backtracking star matchers.
  Both are exponential on patterns like `%a%a%a%a%b` against a long run of
  `a`; the SQL one runs per row inside `WHERE` evaluation.
- **Six copies of the ASCII class predicates** (`isDigit`, `isAlpha`, byte
  twins `digitByte`, `alphaByte`, `isHexByte`, `isDigitCode`) across
  `string.mdk`, `http.mdk`, `pds/lib/atsyntax.mdk`, `pds/lib/nsid.mdk`,
  `sqlite/lib/select.mdk`, `sqlite/lib/sqlparse.mdk`, and a thirteen-predicate
  `compiler/support/char.mdk` that seven compiler modules re-implement
  locally anyway.

The sweep also turned up two latent defects a regex would have prevented:
`test/diff_compiler_import_order_test.mdk` `issueDigits` accepts `#12ab`
because it only classifies the first character, and the two backtracking
matchers above have no linear-time bound.

Full per-file census: § 8.

## 2. Decision: pure Medaka, one module, no new primitive

A new `regex` module under `stdlib/`, written in Medaka over the externs
that already exist. No `extern`, no `<FFI>`. (No file exists yet; the
doc-link gate checks cited paths against disk, so planned files are named
without their extension throughout this document.)

Why not an extern bound to a C library (PCRE2, POSIX `regex.h`):

- An extern needs three implementations (interpreter, LLVM, WasmGC) or a
  `test/CAPABILITY-EXCEPTIONS.txt` row for each engine it skips. The
  playground would need a JS host shim, and JS `RegExp` semantics differ
  from PCRE (Unicode classes, `\b`, `$` and newlines), so the three engines
  would disagree on the same program. The three-engine gate exists to catch
  exactly that.
- A new prelude extern forces a seed re-mint and can break the fixpoint;
  `docs/design/GZIP-DESIGN.md` chose pure Medaka for the same reason and the
  codec is fine.
- User-declared `extern` calls carry `<FFI>` in their effect row and only
  `Int`/`Float`/`Bool`/`Char`/`String`/`Array Int`/`Unit` cross
  (`docs/spec/SYNTAX.md` § extern). A pure function that can only be called
  from an `<FFI>` context is unusable as a stdlib primitive.
- A regex matcher is a few hundred lines of ordinary array code. `json`,
  `toml`, `sha256`, `gzip` are all larger and all pure.

The cost is speed. A Pike VM in Medaka will be slower than the hand-written
index walk at the sites that are on a hot path. § 7 says which sites those
are; they are the minority, and they keep their hand code until measured.

## 3. Semantics

### POSIX, Perl, or RE2

Three families exist, and the choice is the whole design:

| | POSIX ERE (`grep -E`, `regex.h`) | Perl / PCRE (Python, JS, Ruby) | RE2 family (Go `regexp`, Rust `regex`, RE2) |
|---|---|---|---|
| Syntax | `[[:digit:]]`, no `\d`, no `(?:…)`, no lazy `*?` | the syntax everyone writes from memory | Perl syntax minus the non-regular parts |
| Match choice | leftmost-**longest** | leftmost-**first** (alternation order wins) | leftmost-first |
| Backreferences, lookaround | no | yes | no |
| Worst case | implementation-dependent, often exponential submatching | exponential (catastrophic backtracking) | linear, guaranteed |
| Submatch rules | notoriously underspecified; implementations disagree | well defined by the backtracking order | well defined, matches Perl on the shared subset |

**Recommendation: the RE2 family.** It is "something different" from both
classic answers, and it is what every modern regex-from-scratch has
converged on. Perl syntax is the dialect agents and users already know, so
patterns written from memory work; leftmost-first is the semantics they
expect (`a|ab` on `ab` matches `a`, greedy versus lazy works); and the
linear-time guarantee is exactly the property the two backtracking matchers
in the tree (`globMatchAt`, `likeMatch`) lack. POSIX would force
`[[:digit:]]` spellings nobody writes and leftmost-longest submatching that
no popular language implements. Full Perl would mean shipping a backtracker,
which reintroduces the failure mode we are trying to remove and roughly
triples the engine.

What the census says about the cost of dropping the non-regular features:
none of the roughly 270 sites needs a backreference; two want a negative
lookahead and both rewrite as a trailing class or a post-check; many want
`\d`, `\s`, lazy `*?`, and `(?:…)`, which POSIX does not have. The RE2
subset covers every site found.

**Regular languages only, linear time.** The engine is a Thompson NFA run
as a Pike VM with submatch tracking: `O(n * m)` in subject length and
pattern size, no backtracking, no pathological inputs. This is the RE2 and
Go `regexp` contract. Consequences, all deliberate:

- No backreferences (`\1` in a pattern).
- No lookaround (`(?=…)`, `(?!…)`, `(?<=…)`). The census found two sites
  that would want a negative lookahead (`lint.mdk` `isDefinitionLine` wants
  `:` not followed by `=`). Write `:([^=]|$)` or match then test the tail.
- Leftmost-first match priority (Perl, RE2), not POSIX leftmost-longest, so
  `a|ab` on `ab` matches `a` and greedy versus lazy quantifiers behave as
  everyone expects.

**Codepoints, ASCII classes.** Strings are codepoint sequences and `Char` is
one codepoint (`stdlib/string.mdk` header), so the engine matches over
codepoints. `.` matches any codepoint except `\n` (flag `s` lifts that).
`[a-z]` and `[^…]` are codepoint ranges. `\d \w \s \b` and case folding
under `(?i)` are ASCII only, exactly as `string.isDigit`, `isAlpha`,
`toUpper` are today. A non-ASCII letter is not `\w`. This keeps the module
consistent with its neighbour and avoids shipping Unicode tables.

### Syntax accepted in v1

| Form | Meaning |
|---|---|
| `x`, `\.`, `\\`, `\n`, `\t`, `\r`, `\xHH`, `\u{HEX}` | literal codepoint |
| `.` | any codepoint but `\n` |
| `[abc]`, `[a-z0-9]`, `[^…]`, classes inside `[…]` | set, range, negation |
| `\d \D \w \W \s \S` | ASCII digit, word (`[A-Za-z0-9_]`), space (`[ \t\n\r]`), and complements |
| `^`, `$` | start and end of subject; of line under `(?m)` |
| `\b`, `\B` | ASCII word boundary and its complement |
| `ab`, `a\|b` | concatenation, alternation |
| `(…)`, `(?:…)` | capturing and non-capturing group |
| `*`, `+`, `?`, `{n}`, `{n,}`, `{n,m}` | greedy repetition |
| `*?`, `+?`, `??`, `{n,m}?` | lazy repetition |
| `(?i)`, `(?m)`, `(?s)`, `(?ims)` | flags, leading position only in v1 |

Not in v1, on the record: named groups `(?<name>…)` (v2, needs a
`Map String` in `Match`), inline flag scoping `(?i:…)`, Unicode classes
`\p{L}`, POSIX classes `[[:alpha:]]`, `\A`/`\z` (redundant without `(?m)`
being the default), and `\Q…\E` (use `regex.escape`).

A `{` that does not open a valid `{n,m}` is a literal `{`, as in RE2; this
matters because a Medaka string already treats `\{` as the interpolation
opener, so a pattern cannot spell an escaped brace without `\\{`.

## 4. API

Data-last throughout (`stdlib/README.md` § API conventions rule 3: the
regex is the verb's configuration, the subject string is the data).

```medaka-nocheck: the proposed regex API as type signatures and abstract data declarations for a module that does not exist yet, not a standalone program
export data Regex                       -- abstract; compiled program + source + flags
export data RegexError = RegexError { message : String, position : Int }
export data Group = Group { start : Int, end : Int, text : String }
export data Match = Match {
  start : Int,          -- codepoint offset of the whole match
  end : Int,            -- exclusive
  text : String,
  groups : List (Option Group)   -- capture 1.., None for a group that did not participate
}

compile      : String -> Result RegexError Regex
mustCompile  : String -> Regex          -- panics on a bad pattern; for literal patterns
source       : Regex -> String
escape       : String -> String         -- quote every metacharacter

isMatch      : Regex -> String -> Bool
isFullMatch  : Regex -> String -> Bool  -- anchored at both ends, the validator shape
find         : Regex -> String -> Option Match
findFrom     : Int -> Regex -> String -> Option Match
findAll      : Regex -> String -> List Match
fullMatch    : Regex -> String -> Option Match

replace      : Regex -> String -> String -> String   -- first match, `$0`..`$9`, `$$`
replaceAll   : Regex -> String -> String -> String
replaceAllWith : Regex -> (Match -> String) -> String -> String
split        : Regex -> String -> List String
```

Notes:

- **`mustCompile` and lazy top-level bindings.** Top-level nullary bindings
  are lazy and evaluated once, so `isoRe = mustCompile "^(\\d{4})-…"` is the
  compile-once constant every migration site wants, with no new syntax. A
  bad literal panics on first use, which is the same contract as Go's
  `MustCompile`. Panics are not catchable by design; a pattern that comes
  from data must go through `compile`.
- **Byte subjects.** Half of the strongest sites outside the compiler
  (`stdlib/http.mdk`, `pds/lib/atsyntax.mdk`, `pds/lib/nsid.mdk`,
  `pds/lib/blob.mdk`) match over `Array Int` UTF-8 byte buffers and never
  hold a `String`. The VM therefore runs over an integer code sequence with
  a `(start, end)` window, and `String` is one front door over it (`toChars`
  then `charCode`). A byte front door (`isFullMatchBytes : Regex -> Array
  Int -> Int -> Int -> Bool`, and a `findBytes` peer) treats each byte as a
  code 0..255, which is exactly right for the ASCII grammars those sites
  validate (RFC 7230 tokens, DNS labels, DIDs). One engine, two front
  doors, not two engines. Whether the byte door ships in v1 or v2 is the
  implementer's call after measuring `http.mdk`; the VM shape must allow it
  from the start.
- **Offsets are codepoint offsets**, consistent with `string.indexOf` and
  `stringSlice`. The compiler sites that need positions (`mcp.mdk`
  `identsOf`, `gate_cmd.mdk` `firstBadChar`, `lsp.mdk` occurrences) get them
  from `Match.start`.
- **`escape`** is what turns the two glob engines and SQL `LIKE` into
  translations: `*` becomes `.*`, `?` and `_` become `.`, `%` becomes `.*`,
  everything else goes through `escape`, then `isFullMatch`.
- No `Regex` `Eq` or `Ord` impl in v1; `Debug` renders the source.

## 5. Engine shape

Four stages, all private to the module:

1. **Parser**: pattern `String` to an AST (`Lit`, `AnyChar`, `Class (List
   (Int, Int)) negated`, `Cat`, `Alt`, `Star greedy`, `Plus`, `Opt`,
   `Repeat lo hi`, `Group idx`, `Assert kind`). Bounded repetition `{n,m}`
   expands at compile time with a cap (RE2 uses 1000) so the program size
   stays proportional to the pattern; exceeding the cap is a `RegexError`.
2. **Compiler**: AST to a flat `Array Inst` program: `IChar c`, `IClass`,
   `IAny`, `ISplit x y` (x preferred), `IJmp`, `ISave n`, `IAssert`,
   `IMatch`. Standard Thompson construction.
3. **Pike VM**: two thread lists (sparse sets keyed by program counter, so
   each pc appears once per step and the step is `O(m)`), each thread
   carrying its capture array; add threads in priority order, follow
   epsilon edges eagerly, stop adding after the first `IMatch` in a step
   (leftmost-first). Mutable `Array` and `Ref` are available and appropriate
   here; the `Regex` value itself stays immutable.
4. **Front doors**: the § 4 functions, plus `findAll` iterating `findFrom`
   with the empty-match advance rule (an empty match at `i` resumes at
   `i + 1`).

Optimisations are explicitly deferred: a literal-prefix skip via
`stringIndexOf`, a DFA cache, one-pass detection. Get the linear bound and
the semantics right first; measure on `medaka lint compiler` (the largest
cold consumer once migrated) before adding any of them.

## 6. Testing

Vehicles, in the order the `write-tests` skill prefers:

- **Doctests** on every exported function, run by `medaka test` on the
  module. The module is outside every entry's import closure, so
  the Makefile `test:` target must name it explicitly ([W-MODULE-BLIND]),
  the same way `stdlib/base32.mdk` and `stdlib/hmac.mdk` are named.
- **A conformance table** in an in-language harness under `test/` (the
  sprint contract names it `regex_conformance_test`; not a `stdlib/`
  sibling, which the stdlib doc and inventory globs would pick up as a
  module): pattern, subject, expected spans and groups. Seed it from the
  public RE2 and Go `regexp` test tables for the subset in § 3, which are
  already the authority for leftmost-first semantics. This is the golden
  that says what is CORRECT, decided before any capture
  ([WT-GOLDEN-ENSHRINES]).
- **Property tests** through `stdlib/test.mdk`: `escape s` full-matches
  exactly `s`; `split` then `join` with a literal separator round-trips;
  `findAll` spans are disjoint and ascending; `isFullMatch re s ==
  isSome (fullMatch re s)`.
- **A linear-time sentinel**: `(a*)*b` and `(a|a)*b` against a long `a` run
  must finish; bound it with a step counter rather than wall-clock so it
  cannot flake on a shared box.
- **Three-engine agreement**: one fixture under `test/engine_fixtures/`
  exercising compile, find, captures, replace, split, so `eval`, `native`,
  and `wasm` are diffed against each other on the same program.
- **A differential oracle** against `grep -E` or Python `re` over the
  conformance corpus is worth having but is a shell gate, and every new
  shell gate pays the `test/gates.toml` enrolment and balance cycle
  ([W-SHARD-DERIVED]). Make it the last item, not the first, and only if
  the in-language table leaves a gap.

New-module landing checklist, from the `base32` precedent (commit
`b26478fd2`): the module, its lextok golden beside it, a snapshot under
`test/snapshots/stdlib/` blessed through the snapshot gate, its page under
`docs/stdlib/` and `docs/stdlib/index.md` regenerated by `medaka doc`, `docs/stdlib/inventory.json` updated for the conventions gate, and the
Makefile `test:` line. A new `docs/design/*.md` also needs `make docs-index`.

## 7. Adoption plan

Land the module first with no consumers, then migrate in bands. Each band
is one PR, each site's tests must pass unchanged, and a site keeps its hand
code if the replacement is not clearly shorter or is on a measured hot path.

**Band A, cold compiler tooling.** Highest value, zero perf risk; every one
of these runs once per CLI invocation.

| Site | Today | Becomes |
|---|---|---|
| `compiler/tools/lint.mdk` `wholeWordIn`, `wordReadIn`, `identBoundaryAt`; `doc.mdk` `mentionsToken`; `lsp.mdk` `occGo`; `playground_main.mdk` copy | four boundary scanners | one `\b…\b` pattern built with `escape` |
| `compiler/tools/lint.mdk` `parseDirective`, `matchKeyword` | three-way keyword cascade with boundary guard | `^--\s*lint-disable-(next-line\|line\|file)(?:[ \t]+(.*))?$` |
| `compiler/tools/lint.mdk` `isIssueRefToken`, `isRuleNameToken`, `isNonEmptyDigits` | four functions | `^#[0-9]+$`, `^rule-` |
| `compiler/tools/lint.mdk` `stripQuoted`, `hasSubstantiveWord`, `declaredNameOf`, `isPromissoryText`, `identTokens` | recursion and counters | `replaceAll`, `[A-Za-z]{4}`, one capture, one alternation, `findAll` |
| `compiler/tools/gate_registry.mdk` `globMatchAt` | exponential backtracker | glob-to-regex translation, `isFullMatch` |
| `compiler/tools/doc.mdk` `slugifyAnchor`, `firstSentence`, `commentBody`, `isDecorativeLine` | index walks | two `replaceAll`, lazy `.*?\.`, anchored classes |
| `compiler/tools/doctest.mdk` `isInputLine` and siblings | four predicates plus magic slice offsets | `^--(?: (>) ?)?(.*)$` with one capture |
| `compiler/tools/snapshot.mdk` `isHeaderLine`, `streamGo` protocol, duration normaliser | `startsWith` plus `drop N` constants kept in sync by eye | `^(BEGIN\|END\|SECD\|SEC\|D) ?(.*)$`, `^[0-9]+(\.[0-9]+)?(ms\|s)$` |
| `compiler/tools/lsp.mdk` and `lsp_harness.mdk` `Content-Length` parsers | two hand parsers with two `parseDigits` | `Content-Length:[ ]*([0-9]+)\r\n\r\n` |
| `compiler/driver/loader.mdk` manifest line scanner, `scanAllowInternal` | about 90 lines of index arithmetic | `^\s*([A-Za-z0-9_-]+)\s*=\s*(.*?)\s*(?:#.*)?$`, `^\s*\[([^\]]+)\]` |
| `compiler/driver/diagnostics.mdk` `allBacktickWords`, `wordBetweenBackticks`; `lint.mdk` `backtickedAfterReads` | double `stringIndexOf` and slice, twice | `` `([^`]*)` `` with `findAll` |
| `compiler/driver/medaka_cli.mdk` `codemodFlagEq` | prefix and split | `^--([^=]+)=(.*)$` |
| `compiler/tools/mcp.mdk` `identsOf` | tokeniser with offsets | `findAll` of `[A-Za-z0-9_']+`, offsets from `Match.start` |

**Band B, stdlib and projects.**

| Site | Today | Becomes |
|---|---|---|
| `stdlib/time.mdk` `parseIso` | six separator slices, six field slices | `^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$`, six groups |
| `stdlib/toml.mdk` `parseHeader` | four edge slices | `^\[\[(.+)\]\]$`, `^\[(.+)\]$` |
| `sqlite/lib/select.mdk` `likeMatch` | exponential backtracker in the per-row loop | `LIKE`-to-regex translation; measure before and after on a `WHERE … LIKE` benchmark, since the current code is fast on benign patterns |
| `sqlite/lib/select.mdk` numeric-prefix cast | seven helper predicates | `^[ \t\n\r]*[+-]?\d*(\.\d*)?([eE][+-]?\d+)?` |
| `pds/lib/atsyntax.mdk`, `pds/lib/nsid.mdk`, `pds/lib/repo.mdk` `validateDid` (a duplicate) | byte-cursor validators, five duplicated ASCII predicates | DNS-label, handle, DID, record-key, NSID patterns through the byte front door; one shared ASCII predicate set |
| `pds/lib/ratelimit.mdk` IPv4, IPv6, mapped-tail checks | `split "."` plus per-char substring search | `^(25[0-5]\|2[0-4]\d\|1\d\d\|[1-9]?\d)(\.…){3}$`, `[0-9A-Fa-f:]` |
| `pds/lib/blob.mdk` `validMimeShape` | token walk | `^[token]+/[token]+$` |
| `test/diff_compiler_import_order_test.mdk` `codesIn`, `schemeLine`, `importHead`, `issueDigits` | `split` chains; the last one under-checks | `"code":"([^"]*)"` findAll, `^[A-Za-z_][A-Za-z0-9_']* : `, `^(?:export[ \t]+)?import[ \t]`, `^#(\d+)$` |
| `test/diff_compiler_eval_test.mdk` `matchesSpec` | single-`*` glob via `split` | glob translation, multi-`*` for free |
| `test/compiler_cli_test_support.mdk` `rejectionLine` | three `contains` | `(?i)(type error\|parse error)\|^error:`, extendable to `^error\[E-…\]` |
| `pds/test/serve_client_main.mdk`, `serve_subscribe_main.mdk` header readers | `drop 15`, `drop 13` | `^content-length:\s*(\d+)$`, `^content-type:\s*(.*)$` |

**Band C, do not migrate without a measurement.** These are on the
per-compile or per-request path and the hand code is the right shape today:
`compiler/types/typecheck.mdk` `ctorHeadShaped`, `compiler/frontend/exhaust.mdk`
`tupleArityOfName`, `compiler/eval/eval.mdk` `stripModPrefix`,
`compiler/backend/private_mangle.mdk` (injectivity-critical, fixpoint-bearing),
`compiler/backend/wasm_emit.mdk` line validators, `compiler/support/path.mdk`,
and the whole request-parsing loop of `stdlib/http.mdk`
(`parseRequestLine`, `parseHeaderLine`, `validTarget`, the chunk-size
parser). The `http.mdk` validators (`validIpv4`, `validRegName`,
`validHostAuthority`, `validIpvFuture`) are per-connection rather than
per-byte and can move once the byte front door exists and is measured.

**Do not regex, ever.** `compiler/tools/check_policy.mdk` `splitCommaGo`
(brace depth), `compiler/ir/core_ir_sexp_parse.mdk` (an s-expression lexer),
`compiler/tools/repl.mdk` `looksLikeDecl` (walks tokens, not text),
`compiler/types/repr.mdk` `commonPrefixLen`, `lsp.mdk` `identStart`/`identStop`
(expand outward from a cursor has no regex analogue), every escaping and
rendering function in `compiler/tools/printer.mdk`, `stdlib/toml.mdk`
`stripComment` (tracks quote state), and every structured-format parser
(`json`, `toml` values, `gzip`, `sqlite` file format, `byteparser`,
`parsec`, `pds/lib/dagcbor` and friends).

**Keeping agents from hand-rolling the next one.** `rule-stdlib-reimpl`
catches a local function whose NAME collides with a stdlib export; it
cannot see a `toChars` index walk with a fresh name, which is what every
site above is. Two cheap levers once the module exists: a pointer in
`AGENTS.md` § Dogfooding ("a scan over `toChars` with a char predicate is
usually a `regex` call") and, later, a lint heuristic that flags a function
whose body is a recursion over `arrayGetUnsafe i chars` guarded by
`isDigit`/`isAlpha`/`== '…'` comparisons. The second is judgment-heavy and
not a v1 item.

## 8. Syntax: no regex literal, and why

Val asked whether the language should grow syntax for this. Recommendation:
**no regex literal in v1, and probably never.** Three reasons and one
genuine gap.

1. **The two things a literal buys are already available.** A literal
   syntax gives (a) a compile-once constant and (b) compile-time validation
   of the pattern. Lazy top-level nullary bindings already give (a): a
   `mustCompile` binding at top level runs once on first use. For (b), the
   pattern parser is pure Medaka, so `medaka lint` can run it on any string
   literal passed directly to `compile` or `mustCompile` and report a
   located error without a type environment (lint runs on the raw AST and
   can see the literal). That is a lint rule, not a language change, and it
   also serves the LSP through the same rule.
2. **The cost is the whole pipeline.** A new literal is an
   `add-language-feature` job: lexer, parser, a new AST constructor (and
   [T-GLOBAL-TABLE]'s audit of every `_ =>` wildcard arm across every pass),
   desugar, typecheck, both emitters, `fmt`, `printer`, the LSP semantic
   tokens, `tree-sitter-medaka`, the VS Code grammar, the seed re-mint, and
   a `docs/spec/SYNTAX.md` entry. All of that to save `mustCompile "…"`.
3. **A literal invites the wrong thing.** Languages with `/…/` literals
   tend to grow match operators and implicit global match state around
   them; Medaka's errors-as-values and explicit-effects posture is better
   served by a plain value with a `Result`-returning constructor.

The genuine gap is **string escaping**, and it is not regex-specific. Every
`\d`, `\w`, `\s`, `\b`, `\.` must be written `\\d` today because plain
strings accept only `\n \t \r \0 \\ \" \u{…}` and reject anything else with
a located error. That is the right strictness. But an escaped brace in a
pattern must be `\\{` because `\{` opens interpolation, and a pattern with
many classes reads badly doubled. The candidate fix is a **raw string
literal** (`r"…"` or a similar marker) with no escapes and no
interpolation, which also helps LLVM IR text in `llvm_emit.mdk`, shell
snippets in test harnesses, and Windows paths. That is a separate, small,
general-purpose language change, and the recommendation is to decide it
after the Band A migration has shown how much the doubling actually hurts.

One lexer finding from probing this on the 2026-09-11 binary, worth its own
issue before any raw-string discussion: a plain string rejects `"\d+"` with
`invalid escape sequence '\d'`, but a triple-quoted string **silently drops
the backslash**, so `"""\d+"""` evaluates to `d+` with exit 0. A regex
pattern written in a triple-quoted string would lose every class escape
with no error. Triple-quoted strings should either reject unknown escapes
as plain strings do, or be documented as raw; today they are neither.

## 9. Open questions for the implementer

- `Match.groups` as `List (Option Group)` versus `Array`: `List` matches
  the rest of the stdlib's collection-returning surface; `Array` is what the
  VM naturally produces. Convert at the boundary and keep `List`.
- Should `split` drop a leading empty piece when the subject starts with a
  separator? Go keeps it; `string.split` keeps it; keep it.
- Cap on `{n,m}` expansion and on program size, with the `RegexError`
  message naming the cap.
- Whether the byte front door lands in v1 (needed for `http.mdk` and
  `pds/`) or v2 (after the `String` API has consumers). The VM must be
  written over integer codes either way.
