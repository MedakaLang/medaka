# META
source_lines=508
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/lint_cache.mdk — the on-disk cache behind `medaka lint --cache` (#395).
--
-- WHY.  The pre-commit hook runs `medaka lint compiler stdlib sqlite` on every
-- commit: ~6.8 s, parse-bound.  A typical commit touches 1–2 files, so ~99% of
-- that work re-lints files that did not change.  This module lets a run skip the
-- parse + rule pass for a file whose CONTENT is unchanged.
--
-- ── THE INVARIANT (hold every change in this file to it) ──────────────────────
--   A miss is always safe.  A wrong hit is silent wrongness.
-- Every ambiguity — unreadable shard, malformed text, unknown format version, a
-- foreign rule-set stamp, a path/hash mismatch, a field of the wrong shape —
-- resolves to `ShardMiss` (re-lint the file).  There is no "probably fine"
-- branch and there must never be one.  A miss costs milliseconds; a wrong hit is
-- a lint that reports nothing and exits 0, which is this repo's defining failure
-- mode ("this didn't run" == "this passed").
--
-- ── what is cached, and the one thing that must not be ───────────────────────
-- Per file, keyed by content hash: its findings (in two groups, below), its
-- project-rule `summaries`, its `directives`.
--
-- A summary is the per-file INPUT to a project rule's cross-file join, and
-- caching it (rather than the join's OUTPUT) is not an optimisation detail — it
-- is the correctness argument.  A duplicate-body finding names file A *because
-- of* file B.  Cache A's findings and B's edit cannot retract them: A is
-- unchanged, so A cache-hits, and A's stale finding survives.  So every project
-- rule's `prEvaluate` re-runs from scratch on every run, over summaries that
-- are pure functions of one file each.  `lint_cache_test.mdk` fails if a
-- project rule's join is cached.
-- Every registered project rule's summary is stored, so a second project rule
-- keeps the cache sound with no further work here.
--
-- ── two finding groups ────────────────────────────────────────────────────────
-- The index-free rules' findings are valid for as long as the binary is.  The
-- index-reading rules' findings were made against one declaration index.  They
-- are stored with `indexKey`, the fingerprint of every row of that index
-- (`lint_walk.indexKeyFor`), and with `indexAnswers`, each question the file's
-- rules asked of it and a digest of the answer (`lint_index.recording`).  They
-- still hold when the fingerprint is today's, or, when it is not, when today's
-- index answers every recorded question with the recorded digest: an edit to a
-- declaration no rule of this file asked about leaves its findings alone.  A
-- shard that agrees on the binary but on neither is `ShardStale`: the caller
-- keeps its free findings, summaries and directives and re-runs only the
-- index-reading rules.
--
-- ── SHARDS, NOT A BLOB ───────────────────────────────────────────────────────
-- One shard per source file, not one cache file: a typical commit changes 1–2
-- files, and a monolithic cache would pay the write for all of them every run,
-- while sharding makes it O(changed).  Shards are s-expressions read by the
-- cursor reader (`support/sexp_value`), which decodes about four times faster
-- than the JSON they replaced.  `structuralKey`s are stored exactly, never
-- hashed: hashing them would risk a false-duplicate report to save space.
--
-- Flags are deliberately NOT part of the key: `--only`/`--disable`/`--deny` are
-- pure post-filters (`applyFindingFilters`), so shards store PRE-filter findings
-- and every flag combination shares one cache.

import frontend.ast.{Loc(..)}
import driver.diagnostics.{Severity(..)}
import path.{dirname}
import u64 as U64
import tools.lint_core.{Finding(..), Directive(..), DirScope(..), Summary(..)}
import tools.lint_index.{Answer(..), makeStagingDir, stageAndRename}
import support.util.{joinWith, listLen, filterList}
import support.char.{isAlnum}
import support.sexp_value.{
  SexpCursor,
  atomText,
  cursorOf,
  cursorFailed,
  cursorAtEnd,
  cursorOpen,
  cursorClose,
  cursorInt,
  cursorAtom,
  cursorChar,
  cursorList,
  cursorPeek,
  cursorAdvance,
  cursorFail,
  isCloseByte,
}

-- ── the cached unit ──────────────────────────────────────────────────────────

-- Everything a run needs about ONE file, whether freshly linted or loaded from a
-- shard.  `dirty = True` means it was computed this run and its shard needs
-- (re)writing; a cache hit is clean and writes nothing.
--
-- Findings are held in two groups, each finding with the rank of the rule that
-- made it (`lint_walk.ranked`).  `freeFindings` come from rules that read no
-- index and are valid for as long as the shard's stamp is.  `indexFindings` come
-- from rules that read the index and are valid only while the index they saw is
-- the one `indexKey` names or answers `indexAnswers` as it did then.
public export data LintEntry = LintEntry {
  path : String,
  contentHash : String,
  freeFindings : List (Int, Finding),
  indexFindings : List (Int, Finding),
  indexKey : String,
  indexAnswers : List Answer,
  summaries : List (String, Summary),
  directives : List Directive,
  dirty : Bool,
}

-- What a shard answered.  `ShardStale` is a shard that is right for this file
-- and this binary but whose index-reading findings were made against another
-- index: its other fields are usable, its `indexFindings` are empty.
public export data ShardLoad =
  | ShardHit LintEntry
  | ShardStale LintEntry
  | ShardMiss

-- The entry's findings in the order one run over the whole roster produces.
export
entryFindings : LintEntry -> List Finding
entryFindings e = match e.indexFindings
  [] => map snd e.freeFindings
  _ => map snd (mergeRanked e.freeFindings e.indexFindings)

mergeRanked : List (Int, Finding) -> List (Int, Finding) -> List (Int, Finding)
mergeRanked [] ys = ys
mergeRanked xs [] = xs
mergeRanked (x :: xs) (y :: ys) =
  if fst y < fst x then
    y :: mergeRanked (x :: xs) ys
  else
    x :: mergeRanked xs (y :: ys)

-- Bump when the shard schema changes in any way that would make an OLD shard
-- decode into something WRONG rather than fail to decode.  A version mismatch is
-- a miss, so bumping is always safe and never needs a cache purge.  Shards from
-- before the sexp codec (version 2, JSON) fail at the first byte.
cacheFormatVersion : Int
cacheFormatVersion = 3

-- ── content hashing ──────────────────────────────────────────────────────────
-- The key on which a hit is decided: the 64-bit word-wide digest of the source
-- (`hashStringHex`).  `hashString` masks its result to 30 bits, too thin to bet
-- correctness on: a collision between two versions of one file is a STALE HIT,
-- the silent wrongness this cache must not manufacture.
export
contentHashOf : String -> String
contentHashOf src = hashStringHex src

-- ── the rule-set stamp ───────────────────────────────────────────────────────
-- Editing a rule's LOGIC (its name unchanged) must invalidate every entry, so
-- the key covers the rule set's identity as well as the file's content.  We hash
-- the running binary.  Rejected alternatives, all silent-green (#395):
--   * `medaka --version` — a release string; does not move when a rule changes.
--   * a hand-bumped `lintRulesVersion` — rots the first time someone forgets.
--   * a hash of `allRules` names/severities — catches added/removed rules and
--     MISSES logic changes, i.e. exactly the dangerous half.
-- Hashing the binary is also strictly more conservative than a
-- `compiler/**/*.mdk` source stamp: it catches runtime/medaka_rt.c and clang
-- changes too.  Consequence, CORRECT not a bug: for compiler devs the cache dies
-- on every `make medaka`; for a user on a released binary it is stable.
--
-- `hashFile` hashes the bytes raw, so a binary is no obstacle (`readFile` would
-- refuse it as non-UTF-8).  Kept behind this ONE function so it stays swappable.
export
ruleSetStamp : Unit -> <IO> String
ruleSetStamp _ = resultOr "" (hashFile (executablePath ()))

-- ── shard paths ──────────────────────────────────────────────────────────────

-- The cache lives next to the project's `medaka.toml` (the caller resolves that
-- root) and is gitignored.
export
cacheDirOf : String -> String
cacheDirOf root = "\{root}/.medaka/lint-cache"

-- A source path → its shard filename.  Flattened (the cache dir is flat) and
-- disambiguated by a hash of the FULL path, since sanitising alone would collide
-- `a/b.mdk` with `a_b.mdk`.  The hash is only a filename disambiguator, never a
-- correctness argument: the full path is stored INSIDE the shard and checked on
-- load, so a collision costs both files a permanent miss, never a wrong hit.
export
shardPathOf : String -> String -> String
shardPathOf cacheDir srcPath =
  "\{cacheDir}/\{sanitizePath srcPath}-\{hashString srcPath}.sx"

-- Map a path to [A-Za-z0-9._-]*, keeping the tail (the basename end is the
-- legible part) so shard names stay recognisable when eyeballing the dir.
sanitizePath : String -> String
sanitizePath p =
  let cs = stringToChars p
  let n = arrayLength cs
  let start = if n > 60 then n - 60 else 0
  stringFromChars (arrayFromList (sanitizeGo cs start n))

sanitizeGo : Array Char -> Int -> Int -> List Char
sanitizeGo cs i n
  | i >= n = []
  | otherwise = sanitizeChar (arrayGetUnsafe i cs) :: sanitizeGo cs (i + 1) n

sanitizeChar : Char -> Char
sanitizeChar c
  | isAlnum c || c == '.' || c == '_' || c == '-' = c
  | otherwise = '_'

-- ── encode ───────────────────────────────────────────────────────────────────
-- A shard is one s-expression:
--   (version "stamp" "path" "hash" "indexKey" (answers) (free) (index) (summaries) (directives))
-- An older-format shard has a different list count, so its last read fails
-- and it is a miss.
-- read by the cursor reader of `support/sexp_value`, which records the first
-- refusal and hands every later read a neutral value; the decoder checks it once
-- at the end.

export
encodeEntry : String -> LintEntry -> String
encodeEntry stamp e =
  "(\{intToString cacheFormatVersion} \{atomText stamp} \{atomText e.path} \{atomText e.contentHash} \{atomText e.indexKey} \{listText encAnswer e.indexAnswers} \{listText encRanked e.freeFindings} \{listText encRanked e.indexFindings} \{listText encNamedSummary e.summaries} \{listText encDirective e.directives})"

listText : (a -> String) -> List a -> String
listText f xs = "(" ++ joinWith " " (map f xs) ++ ")"

encAnswer : Answer -> String
encAnswer a = "(\{atomText a.ansQuestion} \{atomText a.ansDigest})"

encRanked : (Int, Finding) -> String
encRanked (rank, f) =
  "(\{intToString rank} \{atomText f.rule} \{atomText f.message} \{encSeverity f.severity} \{encLoc f.loc})"

encSeverity : Severity -> String
encSeverity SevError = "e"
encSeverity SevWarning = "w"

encLoc : Option Loc -> String
encLoc None = "()"
encLoc (Some (Loc file l c el ec)) =
  "(\{atomText file} \{intToString l} \{intToString c} \{intToString el} \{intToString ec})"

-- `encSummary` and `summaryTag` have no wildcard arm, so a missing arm for a
-- new summary kind is a non-exhaustive warning from `medaka check` and a
-- runtime failure on the first store; `readSummary` falls through to a cursor
-- failure, so a missing decode arm makes every shard holding that summary a
-- miss.  The `lint_test.mdk` round trip of every `Summary` constructor pins
-- both.
encNamedSummary : (String, Summary) -> String
encNamedSummary (rule, summary) = "(\{atomText rule} \{encSummary summary})"

encSummary : Summary -> String
encSummary (DupOccs occs) =
  "(\{summaryTag (DupOccs occs)} \{listText encOcc occs})"

summaryTag : Summary -> String
summaryTag (DupOccs _) = "d"

encOcc : (Int, String, String) -> String
encOcc (line, name, key) =
  "(\{intToString line} \{atomText name} \{atomText key})"

encDirective : Directive -> String
encDirective (Directive scope names) =
  "(\{encScope scope} \{listText atomText names})"

encScope : DirScope -> String
encScope DScopeFile = "f"
encScope (DScopeLine l) = "l \{intToString l}"

-- ── decode ───────────────────────────────────────────────────────────────────
-- Every failure is `ShardMiss`.  This is the half of the module the invariant is
-- really about: `decodeEntry` is handed whatever bytes are on disk, which may be
-- a shard from a different compiler, a half-written file, or something an editor
-- mangled.

-- `path` and `hash` are checked against what the CALLER observed on disk, so a
-- shard can only ever answer for the exact file+content it was written from; the
-- stamp against the running binary.  `indexKey` is the fingerprint of the index
-- this run holds and `answersHold` re-asks a shard's recorded questions of it:
-- a shard that agrees on everything else but on neither is `ShardStale`.
export
decodeEntry : String ->
  String ->
  (List Answer -> Bool) ->
  String ->
  String ->
  String ->
  ShardLoad
decodeEntry stamp indexKey answersHold path hash text =
  let cur = cursorOf text
  let _ = cursorOpen cur
  let v = cursorInt cur
  let st = cursorAtom cur
  let p = cursorAtom cur
  let h = cursorAtom cur
  if cursorFailed cur
    || v /= cacheFormatVersion
    || st /= stamp
    || p /= path
    || h /= hash then
    ShardMiss
  else
    let key = cursorAtom cur
    let answers = cursorList readAnswer cur
    let free = cursorList readRanked cur
    let indexed = cursorList readRanked cur
    let sums = cursorList readNamedSummary cur
    let dirs = cursorList readDirective cur
    let _ = cursorClose cur
    if cursorFailed cur || not (cursorAtEnd cur) then
      ShardMiss
    else
      let entry = LintEntry {
        path = path,
        contentHash = hash,
        freeFindings = free,
        indexFindings = indexed,
        indexKey = key,
        indexAnswers = answers,
        summaries = sums,
        directives = dirs,
        dirty = False,
      }
      if key == indexKey || answersHold answers then
        ShardHit entry
      else
        staleShard indexKey entry

-- A shard kept for its index-free findings, summaries and directives alone: the
-- index-reading findings and the answers they were made against are dropped.
export
staleShard : String -> LintEntry -> ShardLoad
staleShard indexKey entry = ShardStale ({ entry |
  indexFindings = [],
  indexKey = indexKey,
  indexAnswers = [],
})

readAnswer : SexpCursor -> Answer
readAnswer cur =
  let _ = cursorOpen cur
  let question = cursorAtom cur
  let digest = cursorAtom cur
  let _ = cursorClose cur
  Answer { ansQuestion = question, ansDigest = digest }

readRanked : SexpCursor -> (Int, Finding)
readRanked cur =
  let _ = cursorOpen cur
  let rank = cursorInt cur
  let rule = cursorAtom cur
  let message = cursorAtom cur
  let sev = readSeverity cur
  let loc = readLoc cur
  let _ = cursorClose cur
  (
    rank,
    Finding {
      rule = rule,
      message = message,
      severity = sev,
      loc = loc,
      fix = None,
    },
  )

readSeverity : SexpCursor -> Severity
readSeverity cur =
  let c = cursorChar cur
  if c == 101 then
    SevError
  else if c == 119 then
    SevWarning
  else
    cursorFail cur SevWarning

-- `()` is no location; otherwise `(file line col endLine endCol)`.
readLoc : SexpCursor -> Option Loc
readLoc cur =
  let _ = cursorOpen cur
  if isCloseByte (cursorPeek cur) then
    let _ = cursorAdvance cur
    None
  else
    let file = cursorAtom cur
    let l = cursorInt cur
    let c = cursorInt cur
    let el = cursorInt cur
    let ec = cursorInt cur
    let _ = cursorClose cur
    Some (Loc file l c el ec)

readNamedSummary : SexpCursor -> (String, Summary)
readNamedSummary cur =
  let _ = cursorOpen cur
  let rule = cursorAtom cur
  let summary = readSummary cur
  let _ = cursorClose cur
  (rule, summary)

-- The tag names the constructor; a tag no constructor owns fails the cursor.
readSummary : SexpCursor -> Summary
readSummary cur =
  let _ = cursorOpen cur
  let tag = cursorChar cur
  let summary =
    if tag == 100 then
      DupOccs (cursorList readOcc cur)
    else
      cursorFail cur (DupOccs [])
  let _ = cursorClose cur
  summary

readOcc : SexpCursor -> (Int, String, String)
readOcc cur =
  let _ = cursorOpen cur
  let line = cursorInt cur
  let name = cursorAtom cur
  let key = cursorAtom cur
  let _ = cursorClose cur
  (line, name, key)

readDirective : SexpCursor -> Directive
readDirective cur =
  let _ = cursorOpen cur
  let tag = cursorChar cur
  let scope =
    if tag == 102 then
      DScopeFile
    else if tag == 108 then
      DScopeLine (cursorInt cur)
    else
      cursorFail cur DScopeFile
  let names = cursorList cursorAtom cur
  let _ = cursorClose cur
  Directive scope names

-- ── load ─────────────────────────────────────────────────────────────────────

-- Try to answer for `path` at content `hash`.  `ShardMiss` on any doubt
-- whatsoever.
export
loadEntry : String ->
  String ->
  String ->
  (List Answer -> Bool) ->
  String ->
  String ->
  <IO> ShardLoad
loadEntry cacheDir stamp indexKey answersHold path hash =
  match readFile (shardPathOf cacheDir path)
    Err _ => ShardMiss
    Ok text => decodeEntry stamp indexKey answersHold path hash text

-- ── store ────────────────────────────────────────────────────────────────────

-- Write every dirty entry's shard.  Best-effort THROUGHOUT: a cache that cannot
-- be written must never fail a lint, so every IO error here is swallowed and the
-- run reports its findings regardless (the next run simply misses).
--
-- ATOMICITY.  Each shard is staged in a per-process temp dir and `rename`d
-- into place — a reader therefore sees a shard whole or not at all, never
-- half-written, no matter how many `medaka lint --cache` runs are in flight.
-- Two traps this shape avoids:
--   * A FIXED temp name would let concurrent runs clobber each other's staging
--     and rename a torn file into place.  `medaka build` shipped exactly that
--     bug — its IR path was keyed on the output basename in global /tmp, so two
--     concurrent builds produced a stable-looking WRONG binary (19/20 runs).
--     Only a per-PROCESS temp dir is correct, and `randomInt` cannot supply one:
--     the RNG is seeded identically per process BY DESIGN, so two concurrent
--     runs would draw the SAME "random" name.  `mktemp -d` is the repo's proven
--     answer (build_cmd.mdk uses it for the same reason).
--   * The temp dir must live INSIDE the cache dir, not /tmp: rename(2) fails
--     with EXDEV across filesystems, and /tmp here is a RAM-backed tmpfs.
export
storeEntries : String -> String -> List LintEntry -> <IO> Unit
storeEntries cacheDir stamp entries =
  let dirty = filterList entryDirty entries
  if listLen dirty == 0 then
    ()
  else match ensureCacheDir cacheDir
    Err _ => ()
    Ok _ => match makeStagingDir cacheDir
      Err _ => ()
      Ok tmp =>
        let _ = storeGo cacheDir tmp stamp dirty
        let _ = removeDir tmp
        ()

entryDirty : LintEntry -> Bool
entryDirty e = e.dirty

storeGo : String -> String -> String -> List LintEntry -> <IO> Unit
storeGo _ _ _ [] = ()
storeGo cacheDir tmp stamp (e :: rest) =
  let _ = storeOne cacheDir tmp stamp e
  storeGo cacheDir tmp stamp rest

-- Stage under the temp dir, then rename ONTO the shard path (same filesystem —
-- the temp dir is inside the cache dir).  A failed write leaves the staged file
-- behind; the staging dir is removed by `storeEntries` only if empty, so a
-- failure leaks one temp dir rather than a corrupt shard.  That trade is
-- deliberate: the invariant is about never being WRONG, not never leaking.
storeOne : String -> String -> String -> LintEntry -> <IO> Unit
storeOne cacheDir tmp stamp e =
  stageAndRename tmp (shardPathOf cacheDir e.path) (encodeEntry stamp e)

-- `mkdir -p` for the two-level cache dir (`<root>/.medaka/lint-cache`).  An
-- already-existing dir makes `makeDir` fail (EEXIST), which is success here, so
-- the result is judged by `fileExists`, not by makeDir's own status.
ensureCacheDir : String -> <IO> Result String Unit
ensureCacheDir cacheDir =
  let _ = makeDir (dirname cacheDir)
  let _ = makeDir cacheDir
  if fileExists cacheDir then Ok () else Err "cannot create \{cacheDir}"
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("path") ((mem "dirname" false))))
(DUse false (UseAlias ("u64") "U64"))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Finding" true) (mem "Directive" true) (mem "DirScope" true) (mem "Summary" true))))
(DUse false (UseGroup ("tools" "lint_index") ((mem "Answer" true) (mem "makeStagingDir" false) (mem "stageAndRename" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "listLen" false) (mem "filterList" false))))
(DUse false (UseGroup ("support" "char") ((mem "isAlnum" false))))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SexpCursor" false) (mem "atomText" false) (mem "cursorOf" false) (mem "cursorFailed" false) (mem "cursorAtEnd" false) (mem "cursorOpen" false) (mem "cursorClose" false) (mem "cursorInt" false) (mem "cursorAtom" false) (mem "cursorChar" false) (mem "cursorList" false) (mem "cursorPeek" false) (mem "cursorAdvance" false) (mem "cursorFail" false) (mem "isCloseByte" false))))
(DData Public "LintEntry" () ((variant "LintEntry" (ConNamed (field "path" (TyCon "String")) (field "contentHash" (TyCon "String")) (field "freeFindings" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding")))) (field "indexFindings" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding")))) (field "indexKey" (TyCon "String")) (field "indexAnswers" (TyApp (TyCon "List") (TyCon "Answer"))) (field "summaries" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Summary")))) (field "directives" (TyApp (TyCon "List") (TyCon "Directive"))) (field "dirty" (TyCon "Bool"))))) ())
(DData Public "ShardLoad" () ((variant "ShardHit" (ConPos (TyCon "LintEntry"))) (variant "ShardStale" (ConPos (TyCon "LintEntry"))) (variant "ShardMiss" (ConPos))) ())
(DTypeSig true "entryFindings" (TyFun (TyCon "LintEntry") (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "entryFindings" ((PVar "e")) (EMatch (EFieldAccess (EVar "e") "indexFindings") (arm (PList) () (EApp (EApp (EVar "map") (EVar "snd")) (EFieldAccess (EVar "e") "freeFindings"))) (arm PWild () (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EApp (EVar "mergeRanked") (EFieldAccess (EVar "e") "freeFindings")) (EFieldAccess (EVar "e") "indexFindings"))))))
(DTypeSig false "mergeRanked" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))))))
(DFunDef false "mergeRanked" ((PList) (PVar "ys")) (EVar "ys"))
(DFunDef false "mergeRanked" ((PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "mergeRanked" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "<" (EApp (EVar "fst") (EVar "y")) (EApp (EVar "fst") (EVar "x"))) (EBinOp "::" (EVar "y") (EApp (EApp (EVar "mergeRanked") (EBinOp "::" (EVar "x") (EVar "xs"))) (EVar "ys"))) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "mergeRanked") (EVar "xs")) (EBinOp "::" (EVar "y") (EVar "ys"))))))
(DTypeSig false "cacheFormatVersion" (TyCon "Int"))
(DFunDef false "cacheFormatVersion" () (ELit (LInt 3)))
(DTypeSig true "contentHashOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "contentHashOf" ((PVar "src")) (EApp (EVar "hashStringHex") (EVar "src")))
(DTypeSig true "ruleSetStamp" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "ruleSetStamp" (PWild) (EApp (EApp (EVar "resultOr") (ELit (LString ""))) (EApp (EVar "hashFile") (EApp (EVar "executablePath") (ELit LUnit)))))
(DTypeSig true "cacheDirOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "cacheDirOf" ((PVar "root")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "root"))) (ELit (LString "/.medaka/lint-cache"))))
(DTypeSig true "shardPathOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "shardPathOf" ((PVar "cacheDir") (PVar "srcPath")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "cacheDir"))) (ELit (LString "/"))) (EApp (EVar "display") (EApp (EVar "sanitizePath") (EVar "srcPath")))) (ELit (LString "-"))) (EApp (EVar "display") (EApp (EVar "hashString") (EVar "srcPath")))) (ELit (LString ".sx"))))
(DTypeSig false "sanitizePath" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "sanitizePath" ((PVar "p")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "p"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoLet false false (PVar "start") (EIf (EBinOp ">" (EVar "n") (ELit (LInt 60))) (EBinOp "-" (EVar "n") (ELit (LInt 60))) (ELit (LInt 0)))) (DoExpr (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "sanitizeGo") (EVar "cs")) (EVar "start")) (EVar "n")))))))
(DTypeSig false "sanitizeGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "sanitizeGo" ((PVar "cs") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "sanitizeChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EApp (EVar "sanitizeGo") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "sanitizeChar" (TyFun (TyCon "Char") (TyCon "Char")))
(DFunDef false "sanitizeChar" ((PVar "c")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isAlnum") (EVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar ".")))) (EBinOp "==" (EVar "c") (ELit (LChar "_")))) (EBinOp "==" (EVar "c") (ELit (LChar "-")))) (EVar "c") (EIf (EVar "otherwise") (ELit (LChar "_")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "encodeEntry" (TyFun (TyCon "String") (TyFun (TyCon "LintEntry") (TyCon "String"))))
(DFunDef false "encodeEntry" ((PVar "stamp") (PVar "e")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "cacheFormatVersion")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "atomText") (EVar "stamp")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "atomText") (EFieldAccess (EVar "e") "path")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "atomText") (EFieldAccess (EVar "e") "contentHash")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "atomText") (EFieldAccess (EVar "e") "indexKey")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "listText") (EVar "encAnswer")) (EFieldAccess (EVar "e") "indexAnswers")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "listText") (EVar "encRanked")) (EFieldAccess (EVar "e") "freeFindings")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "listText") (EVar "encRanked")) (EFieldAccess (EVar "e") "indexFindings")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "listText") (EVar "encNamedSummary")) (EFieldAccess (EVar "e") "summaries")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "listText") (EVar "encDirective")) (EFieldAccess (EVar "e") "directives")))) (ELit (LString ")"))))
(DTypeSig false "listText" (TyFun (TyFun (TyVar "a") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "String"))))
(DFunDef false "listText" ((PVar "f") (PVar "xs")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EVar "f")) (EVar "xs")))) (ELit (LString ")"))))
(DTypeSig false "encAnswer" (TyFun (TyCon "Answer") (TyCon "String")))
(DFunDef false "encAnswer" ((PVar "a")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EApp (EVar "atomText") (EFieldAccess (EVar "a") "ansQuestion")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "atomText") (EFieldAccess (EVar "a") "ansDigest")))) (ELit (LString ")"))))
(DTypeSig false "encRanked" (TyFun (TyTuple (TyCon "Int") (TyCon "Finding")) (TyCon "String")))
(DFunDef false "encRanked" ((PTuple (PVar "rank") (PVar "f"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "rank")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "atomText") (EFieldAccess (EVar "f") "rule")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "atomText") (EFieldAccess (EVar "f") "message")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "encSeverity") (EFieldAccess (EVar "f") "severity")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "encLoc") (EFieldAccess (EVar "f") "loc")))) (ELit (LString ")"))))
(DTypeSig false "encSeverity" (TyFun (TyCon "Severity") (TyCon "String")))
(DFunDef false "encSeverity" ((PCon "SevError")) (ELit (LString "e")))
(DFunDef false "encSeverity" ((PCon "SevWarning")) (ELit (LString "w")))
(DTypeSig false "encLoc" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "encLoc" ((PCon "None")) (ELit (LString "()")))
(DFunDef false "encLoc" ((PCon "Some" (PCon "Loc" (PVar "file") (PVar "l") (PVar "c") (PVar "el") (PVar "ec")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EApp (EVar "atomText") (EVar "file")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "l")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "c")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "el")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "ec")))) (ELit (LString ")"))))
(DTypeSig false "encNamedSummary" (TyFun (TyTuple (TyCon "String") (TyCon "Summary")) (TyCon "String")))
(DFunDef false "encNamedSummary" ((PTuple (PVar "rule") (PVar "summary"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EApp (EVar "atomText") (EVar "rule")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "encSummary") (EVar "summary")))) (ELit (LString ")"))))
(DTypeSig false "encSummary" (TyFun (TyCon "Summary") (TyCon "String")))
(DFunDef false "encSummary" ((PCon "DupOccs" (PVar "occs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EApp (EVar "summaryTag") (EApp (EVar "DupOccs") (EVar "occs"))))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "listText") (EVar "encOcc")) (EVar "occs")))) (ELit (LString ")"))))
(DTypeSig false "summaryTag" (TyFun (TyCon "Summary") (TyCon "String")))
(DFunDef false "summaryTag" ((PCon "DupOccs" PWild)) (ELit (LString "d")))
(DTypeSig false "encOcc" (TyFun (TyTuple (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "encOcc" ((PTuple (PVar "line") (PVar "name") (PVar "key"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "atomText") (EVar "name")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "atomText") (EVar "key")))) (ELit (LString ")"))))
(DTypeSig false "encDirective" (TyFun (TyCon "Directive") (TyCon "String")))
(DFunDef false "encDirective" ((PCon "Directive" (PVar "scope") (PVar "names"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EApp (EVar "encScope") (EVar "scope")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "listText") (EVar "atomText")) (EVar "names")))) (ELit (LString ")"))))
(DTypeSig false "encScope" (TyFun (TyCon "DirScope") (TyCon "String")))
(DFunDef false "encScope" ((PCon "DScopeFile")) (ELit (LString "f")))
(DFunDef false "encScope" ((PCon "DScopeLine" (PVar "l"))) (EBinOp "++" (EBinOp "++" (ELit (LString "l ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "l")))) (ELit (LString ""))))
(DTypeSig true "decodeEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Answer")) (TyCon "Bool")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "ShardLoad"))))))))
(DFunDef false "decodeEntry" ((PVar "stamp") (PVar "indexKey") (PVar "answersHold") (PVar "path") (PVar "hash") (PVar "text")) (EBlock (DoLet false false (PVar "cur") (EApp (EVar "cursorOf") (EVar "text"))) (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false (PVar "st") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "p") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "h") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "cursorFailed") (EVar "cur")) (EBinOp "/=" (EVar "v") (EVar "cacheFormatVersion"))) (EBinOp "/=" (EVar "st") (EVar "stamp"))) (EBinOp "/=" (EVar "p") (EVar "path"))) (EBinOp "/=" (EVar "h") (EVar "hash"))) (EVar "ShardMiss") (EBlock (DoLet false false (PVar "key") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "answers") (EApp (EApp (EVar "cursorList") (EVar "readAnswer")) (EVar "cur"))) (DoLet false false (PVar "free") (EApp (EApp (EVar "cursorList") (EVar "readRanked")) (EVar "cur"))) (DoLet false false (PVar "indexed") (EApp (EApp (EVar "cursorList") (EVar "readRanked")) (EVar "cur"))) (DoLet false false (PVar "sums") (EApp (EApp (EVar "cursorList") (EVar "readNamedSummary")) (EVar "cur"))) (DoLet false false (PVar "dirs") (EApp (EApp (EVar "cursorList") (EVar "readDirective")) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "cursorFailed") (EVar "cur")) (EApp (EVar "not") (EApp (EVar "cursorAtEnd") (EVar "cur")))) (EVar "ShardMiss") (EBlock (DoLet false false (PVar "entry") (ERecordCreate "LintEntry" ((fa "path" (EVar "path")) (fa "contentHash" (EVar "hash")) (fa "freeFindings" (EVar "free")) (fa "indexFindings" (EVar "indexed")) (fa "indexKey" (EVar "key")) (fa "indexAnswers" (EVar "answers")) (fa "summaries" (EVar "sums")) (fa "directives" (EVar "dirs")) (fa "dirty" (EVar "False"))))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "key") (EVar "indexKey")) (EApp (EVar "answersHold") (EVar "answers"))) (EApp (EVar "ShardHit") (EVar "entry")) (EApp (EApp (EVar "staleShard") (EVar "indexKey")) (EVar "entry"))))))))))))
(DTypeSig true "staleShard" (TyFun (TyCon "String") (TyFun (TyCon "LintEntry") (TyCon "ShardLoad"))))
(DFunDef false "staleShard" ((PVar "indexKey") (PVar "entry")) (EApp (EVar "ShardStale") (ERecordUpdate (EVar "entry") ((fa "indexFindings" (EListLit)) (fa "indexKey" (EVar "indexKey")) (fa "indexAnswers" (EListLit))))))
(DTypeSig false "readAnswer" (TyFun (TyCon "SexpCursor") (TyCon "Answer")))
(DFunDef false "readAnswer" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "question") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "digest") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ERecordCreate "Answer" ((fa "ansQuestion" (EVar "question")) (fa "ansDigest" (EVar "digest")))))))
(DTypeSig false "readRanked" (TyFun (TyCon "SexpCursor") (TyTuple (TyCon "Int") (TyCon "Finding"))))
(DFunDef false "readRanked" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "rank") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false (PVar "rule") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "message") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "sev") (EApp (EVar "readSeverity") (EVar "cur"))) (DoLet false false (PVar "loc") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ETuple (EVar "rank") (ERecordCreate "Finding" ((fa "rule" (EVar "rule")) (fa "message" (EVar "message")) (fa "severity" (EVar "sev")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None"))))))))
(DTypeSig false "readSeverity" (TyFun (TyCon "SexpCursor") (TyCon "Severity")))
(DFunDef false "readSeverity" ((PVar "cur")) (EBlock (DoLet false false (PVar "c") (EApp (EVar "cursorChar") (EVar "cur"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LInt 101))) (EVar "SevError") (EIf (EBinOp "==" (EVar "c") (ELit (LInt 119))) (EVar "SevWarning") (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "SevWarning")))))))
(DTypeSig false "readLoc" (TyFun (TyCon "SexpCursor") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "readLoc" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoExpr (EIf (EApp (EVar "isCloseByte") (EApp (EVar "cursorPeek") (EVar "cur"))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoExpr (EVar "None"))) (EBlock (DoLet false false (PVar "file") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "l") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false (PVar "c") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false (PVar "el") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false (PVar "ec") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "file")) (EVar "l")) (EVar "c")) (EVar "el")) (EVar "ec")))))))))
(DTypeSig false "readNamedSummary" (TyFun (TyCon "SexpCursor") (TyTuple (TyCon "String") (TyCon "Summary"))))
(DFunDef false "readNamedSummary" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "rule") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "summary") (EApp (EVar "readSummary") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ETuple (EVar "rule") (EVar "summary")))))
(DTypeSig false "readSummary" (TyFun (TyCon "SexpCursor") (TyCon "Summary")))
(DFunDef false "readSummary" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "tag") (EApp (EVar "cursorChar") (EVar "cur"))) (DoLet false false (PVar "summary") (EIf (EBinOp "==" (EVar "tag") (ELit (LInt 100))) (EApp (EVar "DupOccs") (EApp (EApp (EVar "cursorList") (EVar "readOcc")) (EVar "cur"))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EApp (EVar "DupOccs") (EListLit))))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "summary"))))
(DTypeSig false "readOcc" (TyFun (TyCon "SexpCursor") (TyTuple (TyCon "Int") (TyCon "String") (TyCon "String"))))
(DFunDef false "readOcc" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "line") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false (PVar "name") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "key") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ETuple (EVar "line") (EVar "name") (EVar "key")))))
(DTypeSig false "readDirective" (TyFun (TyCon "SexpCursor") (TyCon "Directive")))
(DFunDef false "readDirective" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "tag") (EApp (EVar "cursorChar") (EVar "cur"))) (DoLet false false (PVar "scope") (EIf (EBinOp "==" (EVar "tag") (ELit (LInt 102))) (EVar "DScopeFile") (EIf (EBinOp "==" (EVar "tag") (ELit (LInt 108))) (EApp (EVar "DScopeLine") (EApp (EVar "cursorInt") (EVar "cur"))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "DScopeFile"))))) (DoLet false false (PVar "names") (EApp (EApp (EVar "cursorList") (EVar "cursorAtom")) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "Directive") (EVar "scope")) (EVar "names")))))
(DTypeSig true "loadEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Answer")) (TyCon "Bool")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "ShardLoad")))))))))
(DFunDef false "loadEntry" ((PVar "cacheDir") (PVar "stamp") (PVar "indexKey") (PVar "answersHold") (PVar "path") (PVar "hash")) (EMatch (EApp (EVar "readFile") (EApp (EApp (EVar "shardPathOf") (EVar "cacheDir")) (EVar "path"))) (arm (PCon "Err" PWild) () (EVar "ShardMiss")) (arm (PCon "Ok" (PVar "text")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "decodeEntry") (EVar "stamp")) (EVar "indexKey")) (EVar "answersHold")) (EVar "path")) (EVar "hash")) (EVar "text")))))
(DTypeSig true "storeEntries" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "LintEntry")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "storeEntries" ((PVar "cacheDir") (PVar "stamp") (PVar "entries")) (EBlock (DoLet false false (PVar "dirty") (EApp (EApp (EVar "filterList") (EVar "entryDirty")) (EVar "entries"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "dirty")) (ELit (LInt 0))) (ELit LUnit) (EMatch (EApp (EVar "ensureCacheDir") (EVar "cacheDir")) (arm (PCon "Err" PWild) () (ELit LUnit)) (arm (PCon "Ok" PWild) () (EMatch (EApp (EVar "makeStagingDir") (EVar "cacheDir")) (arm (PCon "Err" PWild) () (ELit LUnit)) (arm (PCon "Ok" (PVar "tmp")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "storeGo") (EVar "cacheDir")) (EVar "tmp")) (EVar "stamp")) (EVar "dirty"))) (DoLet false false PWild (EApp (EVar "removeDir") (EVar "tmp"))) (DoExpr (ELit LUnit)))))))))))
(DTypeSig false "entryDirty" (TyFun (TyCon "LintEntry") (TyCon "Bool")))
(DFunDef false "entryDirty" ((PVar "e")) (EFieldAccess (EVar "e") "dirty"))
(DTypeSig false "storeGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "LintEntry")) (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "storeGo" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "storeGo" ((PVar "cacheDir") (PVar "tmp") (PVar "stamp") (PCons (PVar "e") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "storeOne") (EVar "cacheDir")) (EVar "tmp")) (EVar "stamp")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "storeGo") (EVar "cacheDir")) (EVar "tmp")) (EVar "stamp")) (EVar "rest")))))
(DTypeSig false "storeOne" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "LintEntry") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "storeOne" ((PVar "cacheDir") (PVar "tmp") (PVar "stamp") (PVar "e")) (EApp (EApp (EApp (EVar "stageAndRename") (EVar "tmp")) (EApp (EApp (EVar "shardPathOf") (EVar "cacheDir")) (EFieldAccess (EVar "e") "path"))) (EApp (EApp (EVar "encodeEntry") (EVar "stamp")) (EVar "e"))))
(DTypeSig false "ensureCacheDir" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "ensureCacheDir" ((PVar "cacheDir")) (EBlock (DoLet false false PWild (EApp (EVar "makeDir") (EApp (EVar "dirname") (EVar "cacheDir")))) (DoLet false false PWild (EApp (EVar "makeDir") (EVar "cacheDir"))) (DoExpr (EIf (EApp (EVar "fileExists") (EVar "cacheDir")) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "cannot create ")) (EApp (EVar "display") (EVar "cacheDir"))) (ELit (LString ""))))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("path") ((mem "dirname" false))))
(DUse false (UseAlias ("u64") "U64"))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Finding" true) (mem "Directive" true) (mem "DirScope" true) (mem "Summary" true))))
(DUse false (UseGroup ("tools" "lint_index") ((mem "Answer" true) (mem "makeStagingDir" false) (mem "stageAndRename" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "listLen" false) (mem "filterList" false))))
(DUse false (UseGroup ("support" "char") ((mem "isAlnum" false))))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SexpCursor" false) (mem "atomText" false) (mem "cursorOf" false) (mem "cursorFailed" false) (mem "cursorAtEnd" false) (mem "cursorOpen" false) (mem "cursorClose" false) (mem "cursorInt" false) (mem "cursorAtom" false) (mem "cursorChar" false) (mem "cursorList" false) (mem "cursorPeek" false) (mem "cursorAdvance" false) (mem "cursorFail" false) (mem "isCloseByte" false))))
(DData Public "LintEntry" () ((variant "LintEntry" (ConNamed (field "path" (TyCon "String")) (field "contentHash" (TyCon "String")) (field "freeFindings" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding")))) (field "indexFindings" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding")))) (field "indexKey" (TyCon "String")) (field "indexAnswers" (TyApp (TyCon "List") (TyCon "Answer"))) (field "summaries" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Summary")))) (field "directives" (TyApp (TyCon "List") (TyCon "Directive"))) (field "dirty" (TyCon "Bool"))))) ())
(DData Public "ShardLoad" () ((variant "ShardHit" (ConPos (TyCon "LintEntry"))) (variant "ShardStale" (ConPos (TyCon "LintEntry"))) (variant "ShardMiss" (ConPos))) ())
(DTypeSig true "entryFindings" (TyFun (TyCon "LintEntry") (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "entryFindings" ((PVar "e")) (EMatch (EFieldAccess (EVar "e") "indexFindings") (arm (PList) () (EApp (EApp (EMethodRef "map") (EVar "snd")) (EFieldAccess (EVar "e") "freeFindings"))) (arm PWild () (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EApp (EVar "mergeRanked") (EFieldAccess (EVar "e") "freeFindings")) (EFieldAccess (EVar "e") "indexFindings"))))))
(DTypeSig false "mergeRanked" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))))))
(DFunDef false "mergeRanked" ((PList) (PVar "ys")) (EVar "ys"))
(DFunDef false "mergeRanked" ((PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "mergeRanked" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "<" (EApp (EVar "fst") (EVar "y")) (EApp (EVar "fst") (EVar "x"))) (EBinOp "::" (EVar "y") (EApp (EApp (EVar "mergeRanked") (EBinOp "::" (EVar "x") (EVar "xs"))) (EVar "ys"))) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "mergeRanked") (EVar "xs")) (EBinOp "::" (EVar "y") (EVar "ys"))))))
(DTypeSig false "cacheFormatVersion" (TyCon "Int"))
(DFunDef false "cacheFormatVersion" () (ELit (LInt 3)))
(DTypeSig true "contentHashOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "contentHashOf" ((PVar "src")) (EApp (EVar "hashStringHex") (EVar "src")))
(DTypeSig true "ruleSetStamp" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "ruleSetStamp" (PWild) (EApp (EApp (EVar "resultOr") (ELit (LString ""))) (EApp (EVar "hashFile") (EApp (EVar "executablePath") (ELit LUnit)))))
(DTypeSig true "cacheDirOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "cacheDirOf" ((PVar "root")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString "/.medaka/lint-cache"))))
(DTypeSig true "shardPathOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "shardPathOf" ((PVar "cacheDir") (PVar "srcPath")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "cacheDir"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EApp (EVar "sanitizePath") (EVar "srcPath")))) (ELit (LString "-"))) (EApp (EMethodRef "display") (EApp (EVar "hashString") (EVar "srcPath")))) (ELit (LString ".sx"))))
(DTypeSig false "sanitizePath" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "sanitizePath" ((PVar "p")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "p"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoLet false false (PVar "start") (EIf (EBinOp ">" (EVar "n") (ELit (LInt 60))) (EBinOp "-" (EVar "n") (ELit (LInt 60))) (ELit (LInt 0)))) (DoExpr (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "sanitizeGo") (EVar "cs")) (EVar "start")) (EVar "n")))))))
(DTypeSig false "sanitizeGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "sanitizeGo" ((PVar "cs") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "sanitizeChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EApp (EVar "sanitizeGo") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "sanitizeChar" (TyFun (TyCon "Char") (TyCon "Char")))
(DFunDef false "sanitizeChar" ((PVar "c")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isAlnum") (EVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar ".")))) (EBinOp "==" (EVar "c") (ELit (LChar "_")))) (EBinOp "==" (EVar "c") (ELit (LChar "-")))) (EVar "c") (EIf (EVar "otherwise") (ELit (LChar "_")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "encodeEntry" (TyFun (TyCon "String") (TyFun (TyCon "LintEntry") (TyCon "String"))))
(DFunDef false "encodeEntry" ((PVar "stamp") (PVar "e")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "cacheFormatVersion")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "atomText") (EVar "stamp")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "atomText") (EFieldAccess (EVar "e") "path")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "atomText") (EFieldAccess (EVar "e") "contentHash")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "atomText") (EFieldAccess (EVar "e") "indexKey")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "listText") (EVar "encAnswer")) (EFieldAccess (EVar "e") "indexAnswers")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "listText") (EVar "encRanked")) (EFieldAccess (EVar "e") "freeFindings")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "listText") (EVar "encRanked")) (EFieldAccess (EVar "e") "indexFindings")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "listText") (EVar "encNamedSummary")) (EFieldAccess (EVar "e") "summaries")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "listText") (EVar "encDirective")) (EFieldAccess (EVar "e") "directives")))) (ELit (LString ")"))))
(DTypeSig false "listText" (TyFun (TyFun (TyVar "a") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "String"))))
(DFunDef false "listText" ((PVar "f") (PVar "xs")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EVar "f")) (EVar "xs")))) (ELit (LString ")"))))
(DTypeSig false "encAnswer" (TyFun (TyCon "Answer") (TyCon "String")))
(DFunDef false "encAnswer" ((PVar "a")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EApp (EVar "atomText") (EFieldAccess (EVar "a") "ansQuestion")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "atomText") (EFieldAccess (EVar "a") "ansDigest")))) (ELit (LString ")"))))
(DTypeSig false "encRanked" (TyFun (TyTuple (TyCon "Int") (TyCon "Finding")) (TyCon "String")))
(DFunDef false "encRanked" ((PTuple (PVar "rank") (PVar "f"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "rank")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "atomText") (EFieldAccess (EVar "f") "rule")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "atomText") (EFieldAccess (EVar "f") "message")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "encSeverity") (EFieldAccess (EVar "f") "severity")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "encLoc") (EFieldAccess (EVar "f") "loc")))) (ELit (LString ")"))))
(DTypeSig false "encSeverity" (TyFun (TyCon "Severity") (TyCon "String")))
(DFunDef false "encSeverity" ((PCon "SevError")) (ELit (LString "e")))
(DFunDef false "encSeverity" ((PCon "SevWarning")) (ELit (LString "w")))
(DTypeSig false "encLoc" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "encLoc" ((PCon "None")) (ELit (LString "()")))
(DFunDef false "encLoc" ((PCon "Some" (PCon "Loc" (PVar "file") (PVar "l") (PVar "c") (PVar "el") (PVar "ec")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EApp (EVar "atomText") (EVar "file")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "l")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "c")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "el")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "ec")))) (ELit (LString ")"))))
(DTypeSig false "encNamedSummary" (TyFun (TyTuple (TyCon "String") (TyCon "Summary")) (TyCon "String")))
(DFunDef false "encNamedSummary" ((PTuple (PVar "rule") (PVar "summary"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EApp (EVar "atomText") (EVar "rule")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "encSummary") (EVar "summary")))) (ELit (LString ")"))))
(DTypeSig false "encSummary" (TyFun (TyCon "Summary") (TyCon "String")))
(DFunDef false "encSummary" ((PCon "DupOccs" (PVar "occs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EApp (EVar "summaryTag") (EApp (EVar "DupOccs") (EVar "occs"))))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "listText") (EVar "encOcc")) (EVar "occs")))) (ELit (LString ")"))))
(DTypeSig false "summaryTag" (TyFun (TyCon "Summary") (TyCon "String")))
(DFunDef false "summaryTag" ((PCon "DupOccs" PWild)) (ELit (LString "d")))
(DTypeSig false "encOcc" (TyFun (TyTuple (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "encOcc" ((PTuple (PVar "line") (PVar "name") (PVar "key"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "atomText") (EVar "name")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "atomText") (EVar "key")))) (ELit (LString ")"))))
(DTypeSig false "encDirective" (TyFun (TyCon "Directive") (TyCon "String")))
(DFunDef false "encDirective" ((PCon "Directive" (PVar "scope") (PVar "names"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EApp (EVar "encScope") (EVar "scope")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "listText") (EVar "atomText")) (EVar "names")))) (ELit (LString ")"))))
(DTypeSig false "encScope" (TyFun (TyCon "DirScope") (TyCon "String")))
(DFunDef false "encScope" ((PCon "DScopeFile")) (ELit (LString "f")))
(DFunDef false "encScope" ((PCon "DScopeLine" (PVar "l"))) (EBinOp "++" (EBinOp "++" (ELit (LString "l ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "l")))) (ELit (LString ""))))
(DTypeSig true "decodeEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Answer")) (TyCon "Bool")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "ShardLoad"))))))))
(DFunDef false "decodeEntry" ((PVar "stamp") (PVar "indexKey") (PVar "answersHold") (PVar "path") (PVar "hash") (PVar "text")) (EBlock (DoLet false false (PVar "cur") (EApp (EVar "cursorOf") (EVar "text"))) (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false (PVar "st") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "p") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "h") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "cursorFailed") (EVar "cur")) (EBinOp "/=" (EVar "v") (EVar "cacheFormatVersion"))) (EBinOp "/=" (EVar "st") (EVar "stamp"))) (EBinOp "/=" (EVar "p") (EVar "path"))) (EBinOp "/=" (EVar "h") (EMethodRef "hash"))) (EVar "ShardMiss") (EBlock (DoLet false false (PVar "key") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "answers") (EApp (EApp (EVar "cursorList") (EVar "readAnswer")) (EVar "cur"))) (DoLet false false (PVar "free") (EApp (EApp (EVar "cursorList") (EVar "readRanked")) (EVar "cur"))) (DoLet false false (PVar "indexed") (EApp (EApp (EVar "cursorList") (EVar "readRanked")) (EVar "cur"))) (DoLet false false (PVar "sums") (EApp (EApp (EVar "cursorList") (EVar "readNamedSummary")) (EVar "cur"))) (DoLet false false (PVar "dirs") (EApp (EApp (EVar "cursorList") (EVar "readDirective")) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "cursorFailed") (EVar "cur")) (EApp (EVar "not") (EApp (EVar "cursorAtEnd") (EVar "cur")))) (EVar "ShardMiss") (EBlock (DoLet false false (PVar "entry") (ERecordCreate "LintEntry" ((fa "path" (EVar "path")) (fa "contentHash" (EMethodRef "hash")) (fa "freeFindings" (EVar "free")) (fa "indexFindings" (EVar "indexed")) (fa "indexKey" (EVar "key")) (fa "indexAnswers" (EVar "answers")) (fa "summaries" (EVar "sums")) (fa "directives" (EVar "dirs")) (fa "dirty" (EVar "False"))))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "key") (EVar "indexKey")) (EApp (EVar "answersHold") (EVar "answers"))) (EApp (EVar "ShardHit") (EVar "entry")) (EApp (EApp (EVar "staleShard") (EVar "indexKey")) (EVar "entry"))))))))))))
(DTypeSig true "staleShard" (TyFun (TyCon "String") (TyFun (TyCon "LintEntry") (TyCon "ShardLoad"))))
(DFunDef false "staleShard" ((PVar "indexKey") (PVar "entry")) (EApp (EVar "ShardStale") (ERecordUpdate (EVar "entry") ((fa "indexFindings" (EListLit)) (fa "indexKey" (EVar "indexKey")) (fa "indexAnswers" (EListLit))))))
(DTypeSig false "readAnswer" (TyFun (TyCon "SexpCursor") (TyCon "Answer")))
(DFunDef false "readAnswer" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "question") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "digest") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ERecordCreate "Answer" ((fa "ansQuestion" (EVar "question")) (fa "ansDigest" (EVar "digest")))))))
(DTypeSig false "readRanked" (TyFun (TyCon "SexpCursor") (TyTuple (TyCon "Int") (TyCon "Finding"))))
(DFunDef false "readRanked" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "rank") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false (PVar "rule") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "message") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "sev") (EApp (EVar "readSeverity") (EVar "cur"))) (DoLet false false (PVar "loc") (EApp (EVar "readLoc") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ETuple (EVar "rank") (ERecordCreate "Finding" ((fa "rule" (EVar "rule")) (fa "message" (EVar "message")) (fa "severity" (EVar "sev")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None"))))))))
(DTypeSig false "readSeverity" (TyFun (TyCon "SexpCursor") (TyCon "Severity")))
(DFunDef false "readSeverity" ((PVar "cur")) (EBlock (DoLet false false (PVar "c") (EApp (EVar "cursorChar") (EVar "cur"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LInt 101))) (EVar "SevError") (EIf (EBinOp "==" (EVar "c") (ELit (LInt 119))) (EVar "SevWarning") (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "SevWarning")))))))
(DTypeSig false "readLoc" (TyFun (TyCon "SexpCursor") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "readLoc" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoExpr (EIf (EApp (EVar "isCloseByte") (EApp (EVar "cursorPeek") (EVar "cur"))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoExpr (EVar "None"))) (EBlock (DoLet false false (PVar "file") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "l") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false (PVar "c") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false (PVar "el") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false (PVar "ec") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "file")) (EVar "l")) (EVar "c")) (EVar "el")) (EVar "ec")))))))))
(DTypeSig false "readNamedSummary" (TyFun (TyCon "SexpCursor") (TyTuple (TyCon "String") (TyCon "Summary"))))
(DFunDef false "readNamedSummary" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "rule") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "summary") (EApp (EVar "readSummary") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ETuple (EVar "rule") (EVar "summary")))))
(DTypeSig false "readSummary" (TyFun (TyCon "SexpCursor") (TyCon "Summary")))
(DFunDef false "readSummary" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "tag") (EApp (EVar "cursorChar") (EVar "cur"))) (DoLet false false (PVar "summary") (EIf (EBinOp "==" (EVar "tag") (ELit (LInt 100))) (EApp (EVar "DupOccs") (EApp (EApp (EVar "cursorList") (EVar "readOcc")) (EVar "cur"))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EApp (EVar "DupOccs") (EListLit))))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EVar "summary"))))
(DTypeSig false "readOcc" (TyFun (TyCon "SexpCursor") (TyTuple (TyCon "Int") (TyCon "String") (TyCon "String"))))
(DFunDef false "readOcc" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "line") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false (PVar "name") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "key") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ETuple (EVar "line") (EVar "name") (EVar "key")))))
(DTypeSig false "readDirective" (TyFun (TyCon "SexpCursor") (TyCon "Directive")))
(DFunDef false "readDirective" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "tag") (EApp (EVar "cursorChar") (EVar "cur"))) (DoLet false false (PVar "scope") (EIf (EBinOp "==" (EVar "tag") (ELit (LInt 102))) (EVar "DScopeFile") (EIf (EBinOp "==" (EVar "tag") (ELit (LInt 108))) (EApp (EVar "DScopeLine") (EApp (EVar "cursorInt") (EVar "cur"))) (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "DScopeFile"))))) (DoLet false false (PVar "names") (EApp (EApp (EVar "cursorList") (EVar "cursorAtom")) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "Directive") (EVar "scope")) (EVar "names")))))
(DTypeSig true "loadEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Answer")) (TyCon "Bool")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "ShardLoad")))))))))
(DFunDef false "loadEntry" ((PVar "cacheDir") (PVar "stamp") (PVar "indexKey") (PVar "answersHold") (PVar "path") (PVar "hash")) (EMatch (EApp (EVar "readFile") (EApp (EApp (EVar "shardPathOf") (EVar "cacheDir")) (EVar "path"))) (arm (PCon "Err" PWild) () (EVar "ShardMiss")) (arm (PCon "Ok" (PVar "text")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "decodeEntry") (EVar "stamp")) (EVar "indexKey")) (EVar "answersHold")) (EVar "path")) (EMethodRef "hash")) (EVar "text")))))
(DTypeSig true "storeEntries" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "LintEntry")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "storeEntries" ((PVar "cacheDir") (PVar "stamp") (PVar "entries")) (EBlock (DoLet false false (PVar "dirty") (EApp (EApp (EVar "filterList") (EVar "entryDirty")) (EVar "entries"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "dirty")) (ELit (LInt 0))) (ELit LUnit) (EMatch (EApp (EVar "ensureCacheDir") (EVar "cacheDir")) (arm (PCon "Err" PWild) () (ELit LUnit)) (arm (PCon "Ok" PWild) () (EMatch (EApp (EVar "makeStagingDir") (EVar "cacheDir")) (arm (PCon "Err" PWild) () (ELit LUnit)) (arm (PCon "Ok" (PVar "tmp")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "storeGo") (EVar "cacheDir")) (EVar "tmp")) (EVar "stamp")) (EVar "dirty"))) (DoLet false false PWild (EApp (EVar "removeDir") (EVar "tmp"))) (DoExpr (ELit LUnit)))))))))))
(DTypeSig false "entryDirty" (TyFun (TyCon "LintEntry") (TyCon "Bool")))
(DFunDef false "entryDirty" ((PVar "e")) (EFieldAccess (EVar "e") "dirty"))
(DTypeSig false "storeGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "LintEntry")) (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "storeGo" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "storeGo" ((PVar "cacheDir") (PVar "tmp") (PVar "stamp") (PCons (PVar "e") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "storeOne") (EVar "cacheDir")) (EVar "tmp")) (EVar "stamp")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "storeGo") (EVar "cacheDir")) (EVar "tmp")) (EVar "stamp")) (EVar "rest")))))
(DTypeSig false "storeOne" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "LintEntry") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "storeOne" ((PVar "cacheDir") (PVar "tmp") (PVar "stamp") (PVar "e")) (EApp (EApp (EApp (EVar "stageAndRename") (EVar "tmp")) (EApp (EApp (EVar "shardPathOf") (EVar "cacheDir")) (EFieldAccess (EVar "e") "path"))) (EApp (EApp (EVar "encodeEntry") (EVar "stamp")) (EVar "e"))))
(DTypeSig false "ensureCacheDir" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "ensureCacheDir" ((PVar "cacheDir")) (EBlock (DoLet false false PWild (EApp (EVar "makeDir") (EApp (EVar "dirname") (EVar "cacheDir")))) (DoLet false false PWild (EApp (EVar "makeDir") (EVar "cacheDir"))) (DoExpr (EIf (EApp (EVar "fileExists") (EVar "cacheDir")) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "cannot create ")) (EApp (EMethodRef "display") (EVar "cacheDir"))) (ELit (LString ""))))))))
