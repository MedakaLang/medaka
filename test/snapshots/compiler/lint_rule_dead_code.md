# META
source_lines=313
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-dead-code: a private top-level binding that nothing reachable from the file's exports, `main` or doctests uses.

import frontend.ast.{Loc(..), Decl(..)}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import support.util.{filterList, splitNl, startsWith, stringTrim}
import hash_map.{HashMap, new, setInPlace, has, findWithDefault}
import string.{drop as strDrop}
import tools.printer.{declToString}
import support.char.{isAlnum, isLower, isUpper}
import frontend.lexer.{Comment, commentText}
import tools.lint_core.{
  Category(..),
  FileFacts,
  Finding(..),
  Fixability(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  factComments,
  mkRule,
}
import tools.lint_shared.{
  dedupeNamesLoc,
  declLocList,
  nameSetOf,
  ruleNameDeadCode,
  sortUniqS,
}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNameDeadCode,
      summary =
        "private (unexported) top-level binding is unreachable from the file's exports/main/doctests. Dead code (Haskell -Wunused-top-binds)",
      doc =
        "A private top-level binding that nothing reachable from the file's exports, `main` or doctests uses is dead code (Haskell -Wunused-top-binds). Delete it or export it.\n\nBefore:\n  helper x = x + 1   -- never called\nAfter:\n  (binding removed)",
      category = Suspicious,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleDeadCode
    None

-- Flag a PRIVATE (unexported) top-level value/function binding that is NOT
-- reachable from the file's roots — Haskell's -Wunused-top-binds.  A private
-- binding has module-local visibility, so a whole-file reachability walk is
-- COMPLETE (nothing outside the file can reference it).
--
-- Roots = every exported (`export`/`public export`) top-level binding, `main`,
-- and every identifier referenced from a reachable decl's body.  Reachability
-- iterates to a fixpoint (a private helper used only by a DEAD private helper is
-- itself dead → both flagged).
--
-- Reference sites that keep a binding LIVE (miss one → false "dead" → we'd delete
-- live code, so we OVER-approximate references — safe direction):
--   * other top-level bindings' bodies (via the reachability graph),
--   * `impl`/`interface`(default)/`prop`/`test`/top-level-`let` bodies
--     (seeded as roots — they always run),
--   * identifiers in doctest `>` input lines inside comments.  Doctests live in
--     comments (stripped from the AST), so a helper exercised ONLY by a doctest
--     looks dead but is LIVE under `medaka test`.  We recover them from the
--     lexer's string-aware comment channel (`collectComments`) — NOT a naive
--     grep of the raw text (which would eat `>`/`--` tokens inside string
--     literals).
--
-- References are collected by tokenising the printed decl (`declToString`) into
-- identifier runs: this can only OVER-collect (a name mentioned in a string
-- literal keeps its def alive — safe), never under-collect within a body.
-- Operator-named bindings are NOT flagged (their call sites use operator syntax,
-- not name tokens, so a token scan can't see the reference → risk of false
-- "dead").  `fix = None` (suggest-only — deletion is by hand).
ruleDeadCode : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleDeadCode _ _ facts pos prog =
  let reach = reachableNames facts prog
  map deadFinding (filterList (deadPair reach) (privateDefLocs pos prog))

deadPair : HashMap String Unit -> (String, Option Loc) -> Bool
deadPair reach (n, _) = not (has n reach)

deadFinding : (String, Option Loc) -> Finding
deadFinding (name, loc) = Finding {
  rule = ruleNameDeadCode,
  message =
    "private top-level '"
      ++ name
      ++ "' is unreachable from exports/main/doctests — remove it (dead code)",
  severity = SevWarning,
  loc = loc,
  fix = None,
}

-- private (unexported) top-level fn/value bindings, deduped by name (first loc),
-- restricted to ordinary-identifier names (operator defs are skipped).
-- A binding is a dead-code CANDIDATE iff it is an ordinary-identifier top-level
-- `DFunDef` whose name is NOT exported.  IMPORTANT: the common idiom
-- `export name : T` / `name = …` puts the `export` on the *signature*
-- (`DTypeSig True`), NOT the `DFunDef` — so exportedness is decided by
-- `exportedNames` (which unions DFunDef-pub and DTypeSig-pub), not the DFunDef
-- flag alone.
privateDefLocs : Positions -> List Decl -> List (String, Option Loc)
privateDefLocs pos prog =
  -- HashMap-as-set: `contains` over the exported LIST was O(exports) per decl,
  -- i.e. O(decls x exports) over the filterList — one of this rule's four
  -- List-as-a-set quadratics (see reachableNames).  Membership only; order
  -- irrelevant.
  let exported = nameSetOf (exportedNames prog)
  dedupeNamesLoc
    (filterList
      (candidatePair exported)
      (flatMap allDefNameL (declLocList pos prog)))

allDefNameL : (Decl, Option Loc) -> List (String, Option Loc)
allDefNameL (DFunDef _ name _ _ _ _, loc) = [(name, loc)]
allDefNameL (DAttrib _ d, loc) = allDefNameL (d, loc)
allDefNameL _ = []

candidatePair : HashMap String Unit -> (String, Option Loc) -> Bool
candidatePair exported (n, _) = isOrdinaryIdent n && not (has n exported)

isOrdinaryIdent : String -> Bool
isOrdinaryIdent s
  | stringLength s == 0 = False
  | otherwise = isIdentStart (arrayGetUnsafe 0 (stringToChars s))

-- the set of names reachable from the file's roots (fixpoint closure).
--
-- HashMap-backed, mirroring ir/dce.mdk's `reachableNames`/`funGraph`/`closure`
-- (the SAME algorithm, whose assoc-list version was retired there for being
-- O(N^2)).  This copy kept the list version and so kept the quadratics: the ref
-- map was an assoc list rebuilt per clause (`acc ++ [(n, rs)]` copies a GROWING
-- list every element) with an O(names) `lookupAssoc`/`replaceAssoc` on each, and
-- the BFS tested membership with `contains` over a `visited` LIST.  Now: O(1)-
-- average membership + O(1) graph lookup -> ~O(names + edges).  Consumed only by
-- `deadPair`'s membership test, so order and duplicates are irrelevant.
reachableNames : FileFacts -> List Decl -> HashMap String Unit
reachableNames facts prog =
  let refMap = mergeRefs (flatMap defRefPair prog)
  let seed =
    exportedNames prog
      ++ ("main"
        :: flatMap nonDefRefL prog ++ doctestIdents (factComments facts))
  let visited = new ()
  let _ = bfsReach refMap visited seed
  visited

-- one (defName, bodyRefs) per top-level DFunDef clause; refs are the identifier
-- tokens of the printed decl (deduped).
defRefPair : Decl -> List (String, List String)
defRefPair d = match defNameOf d
  Some name => [(name, sortUniqS (identTokens (declToString (unAttrib d))))]
  None => []

defNameOf : Decl -> Option String
defNameOf (DFunDef _ name _ _ _ _) = Some name
defNameOf (DAttrib _ d) = defNameOf d
defNameOf _ = None

unAttrib : Decl -> Decl
unAttrib (DAttrib _ d) = d
unAttrib d = d

exportedNames : List Decl -> List String
exportedNames prog = flatMap exportedNameL prog

exportedNameL : Decl -> List String
exportedNameL (DFunDef True name _ _ _ _) = [name]
exportedNameL (DTypeSig True name _ _) = [name]
exportedNameL (DAttrib _ d) = exportedNameL d
exportedNameL _ = []

-- identifier roots from body-bearing NON-DFunDef decls (impl/interface-default/
-- prop/test/top-level-let).  Deliberately EXCLUDES DTypeSig/DExtern (they
-- NAME a binding, they don't reference it — including a sig would make every
-- signed private helper look reachable) and pure type/import decls.
-- Kinds that NAME a binding or a type/import rather than referencing a value are
-- matched positionally and skipped; everything else (DProp/DTest/
-- DInterface/DImpl/DLetGroup) is a body-bearing root.
nonDefRefL : Decl -> List String
nonDefRefL (DAttrib _ dd) = nonDefRefL dd
nonDefRefL (DFunDef _ _ _ _ _ _) = []
nonDefRefL (DTypeSig _ _ _ _) = []
nonDefRefL (DExtern _) = []
nonDefRefL (DData { dataOrigin = _ }) = []
nonDefRefL (DUse _ _ _) = []
nonDefRefL (DEffect _ _ _ _ _ _) = []
nonDefRefL (DTypeAlias { tyAliasOrigin = _ }) = []
nonDefRefL (DNewtype { newtypeOrigin = _ }) = []
nonDefRefL d = bodyIdents d

bodyIdents : Decl -> List String
bodyIdents d = sortUniqS (identTokens (declToString d))

-- ── reachability fixpoint ─────────────────────────────────────────────────────
-- BFS over the ref graph: pop a name; if already visited skip; else mark visited
-- and enqueue its body refs (only DFunDef keys have refs; every other name is a
-- leaf).  Terminates because `visited` grows monotonically and each name is
-- expanded once.
-- BFS over the ref graph: pop a name; if already visited skip; else mark visited
-- and enqueue its body refs (only DFunDef keys have refs; every other name is a
-- leaf).  Terminates because `visited` grows monotonically and each name is
-- expanded once.  `has`/`setInPlace` are O(1) average, so this is
-- ~O(names + edges); the old `contains x visited` over a list made it
-- O(names^2).
bfsReach : HashMap String (List String) ->
  HashMap String Unit ->
  List String ->
  Unit
bfsReach _ _ [] = ()
bfsReach refMap visited (x :: rest)
  | has x visited = bfsReach refMap visited rest
  | otherwise =
    let _ = setInPlace x () visited
    bfsReach refMap visited (refsOf refMap x ++ rest)

refsOf : HashMap String (List String) -> String -> List String
refsOf refMap n = findWithDefault [] n refMap

-- merge same-named clause ref-lists into one entry per name (union, deduped).
-- HashMap-backed: the old assoc-list version did an O(names) `lookupAssoc` plus
-- either an O(names) `replaceAssoc` or an `acc ++ [(n, rs)]` — which COPIES the
-- whole growing accumulator on every element — making map construction O(D^2) in
-- both time and allocation (the dominant allocator: 56 MB -> 1138 MB across
-- 400 -> 3200 defs).  Refs feed a membership-only closure, so order is irrelevant.
mergeRefs : List (String, List String) -> HashMap String (List String)
mergeRefs pairs =
  let m = new ()
  let _ = mergeRefsGo m pairs
  m

mergeRefsGo : HashMap String (List String) -> List (String, List String) -> Unit
mergeRefsGo _ [] = ()
mergeRefsGo acc ((n, rs) :: rest) =
  let _ = setInPlace n (sortUniqS (findWithDefault [] n acc ++ rs)) acc
  mergeRefsGo acc rest

-- ── identifier tokeniser ──────────────────────────────────────────────────────
-- Maximal runs of identifier characters that START with a letter or `_`.  Over-
-- approximates references (keywords, field names, ctor names, string-literal
-- words all included) — the safe direction for a dead-code scan.
identTokens : String -> List String
identTokens s =
  let cs = stringToChars s
  identTokGo cs (arrayLength cs) 0

identTokGo : Array Char -> Int -> Int -> List String
identTokGo cs n i
  | i >= n = []
  | isIdentStart (arrayGetUnsafe i cs) =
    let j = identEnd cs n (i + 1)
    charsSlice cs i j :: identTokGo cs n j
  | otherwise = identTokGo cs n (i + 1)

-- `Array Char` slice re-encoded straight to `String`, O(j - i).  `stringSlice`
-- takes a CODEPOINT index and rescans from the string's start to convert it to
-- a byte offset (`mdk_utf8_byte_offset`), which made `identTokGo` O(decl-
-- length^2) over a long declaration (#1032).  `cs` is already an `Array Char`
-- here, so slicing it directly and re-encoding with `stringFromChars` costs
-- only the token's own length, not the whole prefix.
charsSlice : Array Char -> Int -> Int -> String
charsSlice cs i j =
  stringFromChars (arrayMakeWith (j - i) (k => arrayGetUnsafe (i + k) cs))

isIdentStart : Char -> Bool
isIdentStart c = isLower c || isUpper c || c == '_'

identEnd : Array Char -> Int -> Int -> Int
identEnd cs n i
  | i >= n = i
  | isAlnum (arrayGetUnsafe i cs) = identEnd cs n (i + 1)
  | otherwise = i

-- ── doctest identifiers (string-aware comment channel) ────────────────────────
-- Identifiers on `>` input lines of doctests (both `-- > expr` line-comment and
-- `{- … > expr … -}` block-comment forms).  `collectComments` is the lexer's
-- string-aware comment scanner, so `>`/`--` inside string literals never leak in.
doctestIdents : List Comment -> List String
doctestIdents cmts = flatMap commentDocIdents cmts

commentDocIdents : Comment -> List String
commentDocIdents c =
  let t = commentText c
  if startsWith "{-" t then
    flatMap blockDocLineIdents (splitNl (blockInner t))
  else if startsWith "-- >" t then
    identTokens (strDrop 4 t)
  else
    []

-- strip the outer `{-` `-}` from a block-comment lexeme.
blockInner : String -> String
blockInner t =
  let n = stringLength t
  if n >= 4 then stringSlice 2 (n - 2) t else ""

-- an inner block line is a doctest input iff it trims to `> …`.
blockDocLineIdents : String -> List String
blockDocLineIdents line =
  let tr = stringTrim line
  if startsWith ">" tr then identTokens (strDrop 1 tr) else []
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "filterList" false) (mem "splitNl" false) (mem "startsWith" false) (mem "stringTrim" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "setInPlace" false) (mem "has" false) (mem "findWithDefault" false))))
(DUse false (UseGroup ("string") ((mem "drop" false "strDrop"))))
(DUse false (UseGroup ("tools" "printer") ((mem "declToString" false))))
(DUse false (UseGroup ("support" "char") ((mem "isAlnum" false) (mem "isLower" false) (mem "isUpper" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "commentText" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "factComments" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "dedupeNamesLoc" false) (mem "declLocList" false) (mem "nameSetOf" false) (mem "ruleNameDeadCode" false) (mem "sortUniqS" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDeadCode")) (fa "summary" (ELit (LString "private (unexported) top-level binding is unreachable from the file's exports/main/doctests. Dead code (Haskell -Wunused-top-binds)"))) (fa "doc" (ELit (LString "A private top-level binding that nothing reachable from the file's exports, `main` or doctests uses is dead code (Haskell -Wunused-top-binds). Delete it or export it.\n\nBefore:\n  helper x = x + 1   -- never called\nAfter:\n  (binding removed)"))) (fa "category" (EVar "Suspicious")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleDeadCode")) (EVar "None")))
(DTypeSig false "ruleDeadCode" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleDeadCode" (PWild PWild (PVar "facts") (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "reach") (EApp (EApp (EVar "reachableNames") (EVar "facts")) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "map") (EVar "deadFinding")) (EApp (EApp (EVar "filterList") (EApp (EVar "deadPair") (EVar "reach"))) (EApp (EApp (EVar "privateDefLocs") (EVar "pos")) (EVar "prog")))))))
(DTypeSig false "deadPair" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Bool"))))
(DFunDef false "deadPair" ((PVar "reach") (PTuple (PVar "n") PWild)) (EApp (EVar "not") (EApp (EApp (EVar "has") (EVar "n")) (EVar "reach"))))
(DTypeSig false "deadFinding" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Finding")))
(DFunDef false "deadFinding" ((PTuple (PVar "name") (PVar "loc"))) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDeadCode")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "private top-level '")) (EVar "name")) (ELit (LString "' is unreachable from exports/main/doctests — remove it (dead code)")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
(DTypeSig false "privateDefLocs" (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "privateDefLocs" ((PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "exported") (EApp (EVar "nameSetOf") (EApp (EVar "exportedNames") (EVar "prog")))) (DoExpr (EApp (EVar "dedupeNamesLoc") (EApp (EApp (EVar "filterList") (EApp (EVar "candidatePair") (EVar "exported"))) (EApp (EApp (EVar "flatMap") (EVar "allDefNameL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))))))
(DTypeSig false "allDefNameL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "allDefNameL" ((PTuple (PCon "DFunDef" PWild (PVar "name") PWild PWild PWild PWild) (PVar "loc"))) (EListLit (ETuple (EVar "name") (EVar "loc"))))
(DFunDef false "allDefNameL" ((PTuple (PCon "DAttrib" PWild (PVar "d")) (PVar "loc"))) (EApp (EVar "allDefNameL") (ETuple (EVar "d") (EVar "loc"))))
(DFunDef false "allDefNameL" (PWild) (EListLit))
(DTypeSig false "candidatePair" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Bool"))))
(DFunDef false "candidatePair" ((PVar "exported") (PTuple (PVar "n") PWild)) (EBinOp "&&" (EApp (EVar "isOrdinaryIdent") (EVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "has") (EVar "n")) (EVar "exported")))))
(DTypeSig false "isOrdinaryIdent" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isOrdinaryIdent" ((PVar "s")) (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 0))) (EVar "False") (EIf (EVar "otherwise") (EApp (EVar "isIdentStart") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EVar "stringToChars") (EVar "s")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reachableNames" (TyFun (TyCon "FileFacts") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "reachableNames" ((PVar "facts") (PVar "prog")) (EBlock (DoLet false false (PVar "refMap") (EApp (EVar "mergeRefs") (EApp (EApp (EVar "flatMap") (EVar "defRefPair")) (EVar "prog")))) (DoLet false false (PVar "seed") (EBinOp "++" (EApp (EVar "exportedNames") (EVar "prog")) (EBinOp "::" (ELit (LString "main")) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "nonDefRefL")) (EVar "prog")) (EApp (EVar "doctestIdents") (EApp (EVar "factComments") (EVar "facts"))))))) (DoLet false false (PVar "visited") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EVar "bfsReach") (EVar "refMap")) (EVar "visited")) (EVar "seed"))) (DoExpr (EVar "visited"))))
(DTypeSig false "defRefPair" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "defRefPair" ((PVar "d")) (EMatch (EApp (EVar "defNameOf") (EVar "d")) (arm (PCon "Some" (PVar "name")) () (EListLit (ETuple (EVar "name") (EApp (EVar "sortUniqS") (EApp (EVar "identTokens") (EApp (EVar "declToString") (EApp (EVar "unAttrib") (EVar "d")))))))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "defNameOf" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "defNameOf" ((PCon "DFunDef" PWild (PVar "name") PWild PWild PWild PWild)) (EApp (EVar "Some") (EVar "name")))
(DFunDef false "defNameOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "defNameOf") (EVar "d")))
(DFunDef false "defNameOf" (PWild) (EVar "None"))
(DTypeSig false "unAttrib" (TyFun (TyCon "Decl") (TyCon "Decl")))
(DFunDef false "unAttrib" ((PCon "DAttrib" PWild (PVar "d"))) (EVar "d"))
(DFunDef false "unAttrib" ((PVar "d")) (EVar "d"))
(DTypeSig false "exportedNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "exportedNames" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "exportedNameL")) (EVar "prog")))
(DTypeSig false "exportedNameL" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "exportedNameL" ((PCon "DFunDef" (PCon "True") (PVar "name") PWild PWild PWild PWild)) (EListLit (EVar "name")))
(DFunDef false "exportedNameL" ((PCon "DTypeSig" (PCon "True") (PVar "name") PWild PWild)) (EListLit (EVar "name")))
(DFunDef false "exportedNameL" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "exportedNameL") (EVar "d")))
(DFunDef false "exportedNameL" (PWild) (EListLit))
(DTypeSig false "nonDefRefL" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "nonDefRefL" ((PCon "DAttrib" PWild (PVar "dd"))) (EApp (EVar "nonDefRefL") (EVar "dd")))
(DFunDef false "nonDefRefL" ((PCon "DFunDef" PWild PWild PWild PWild PWild PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PCon "DTypeSig" PWild PWild PWild PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PCon "DExtern" PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PRec "DData" ((rf "dataOrigin" PWild)) false)) (EListLit))
(DFunDef false "nonDefRefL" ((PCon "DUse" PWild PWild PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PCon "DEffect" PWild PWild PWild PWild PWild PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PRec "DTypeAlias" ((rf "tyAliasOrigin" PWild)) false)) (EListLit))
(DFunDef false "nonDefRefL" ((PRec "DNewtype" ((rf "newtypeOrigin" PWild)) false)) (EListLit))
(DFunDef false "nonDefRefL" ((PVar "d")) (EApp (EVar "bodyIdents") (EVar "d")))
(DTypeSig false "bodyIdents" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "bodyIdents" ((PVar "d")) (EApp (EVar "sortUniqS") (EApp (EVar "identTokens") (EApp (EVar "declToString") (EVar "d")))))
(DTypeSig false "bfsReach" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "bfsReach" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "bfsReach" ((PVar "refMap") (PVar "visited") (PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "has") (EVar "x")) (EVar "visited")) (EApp (EApp (EApp (EVar "bfsReach") (EVar "refMap")) (EVar "visited")) (EVar "rest")) (EIf (EVar "otherwise") (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "x")) (ELit LUnit)) (EVar "visited"))) (DoExpr (EApp (EApp (EApp (EVar "bfsReach") (EVar "refMap")) (EVar "visited")) (EBinOp "++" (EApp (EApp (EVar "refsOf") (EVar "refMap")) (EVar "x")) (EVar "rest"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "refsOf" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "refsOf" ((PVar "refMap") (PVar "n")) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "n")) (EVar "refMap")))
(DTypeSig false "mergeRefs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "mergeRefs" ((PVar "pairs")) (EBlock (DoLet false false (PVar "m") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "mergeRefsGo") (EVar "m")) (EVar "pairs"))) (DoExpr (EVar "m"))))
(DTypeSig false "mergeRefsGo" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Unit"))))
(DFunDef false "mergeRefsGo" (PWild (PList)) (ELit LUnit))
(DFunDef false "mergeRefsGo" ((PVar "acc") (PCons (PTuple (PVar "n") (PVar "rs")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "n")) (EApp (EVar "sortUniqS") (EBinOp "++" (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "n")) (EVar "acc")) (EVar "rs")))) (EVar "acc"))) (DoExpr (EApp (EApp (EVar "mergeRefsGo") (EVar "acc")) (EVar "rest")))))
(DTypeSig false "identTokens" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "identTokens" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "identTokGo") (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0))))))
(DTypeSig false "identTokGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "identTokGo" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EIf (EApp (EVar "isIdentStart") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EBlock (DoLet false false (PVar "j") (EApp (EApp (EApp (EVar "identEnd") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EVar "charsSlice") (EVar "cs")) (EVar "i")) (EVar "j")) (EApp (EApp (EApp (EVar "identTokGo") (EVar "cs")) (EVar "n")) (EVar "j"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "identTokGo") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "charsSlice" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "charsSlice" ((PVar "cs") (PVar "i") (PVar "j")) (EApp (EVar "stringFromChars") (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "j") (EVar "i"))) (ELam ((PVar "k")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (EVar "k"))) (EVar "cs"))))))
(DTypeSig false "isIdentStart" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isIdentStart" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EApp (EVar "isLower") (EVar "c")) (EApp (EVar "isUpper") (EVar "c"))) (EBinOp "==" (EVar "c") (ELit (LChar "_")))))
(DTypeSig false "identEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "identEnd" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "i") (EIf (EApp (EVar "isAlnum") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EApp (EVar "identEnd") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "doctestIdents" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "doctestIdents" ((PVar "cmts")) (EApp (EApp (EVar "flatMap") (EVar "commentDocIdents")) (EVar "cmts")))
(DTypeSig false "commentDocIdents" (TyFun (TyCon "Comment") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "commentDocIdents" ((PVar "c")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "commentText") (EVar "c"))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "{-"))) (EVar "t")) (EApp (EApp (EVar "flatMap") (EVar "blockDocLineIdents")) (EApp (EVar "splitNl") (EApp (EVar "blockInner") (EVar "t")))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "-- >"))) (EVar "t")) (EApp (EVar "identTokens") (EApp (EApp (EVar "strDrop") (ELit (LInt 4))) (EVar "t"))) (EListLit))))))
(DTypeSig false "blockInner" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "blockInner" ((PVar "t")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "t"))) (DoExpr (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 4))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (EBinOp "-" (EVar "n") (ELit (LInt 2)))) (EVar "t")) (ELit (LString ""))))))
(DTypeSig false "blockDocLineIdents" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "blockDocLineIdents" ((PVar "line")) (EBlock (DoLet false false (PVar "tr") (EApp (EVar "stringTrim") (EVar "line"))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (ELit (LString ">"))) (EVar "tr")) (EApp (EVar "identTokens") (EApp (EApp (EVar "strDrop") (ELit (LInt 1))) (EVar "tr"))) (EListLit)))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "filterList" false) (mem "splitNl" false) (mem "startsWith" false) (mem "stringTrim" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "setInPlace" false) (mem "has" false) (mem "findWithDefault" false))))
(DUse false (UseGroup ("string") ((mem "drop" false "strDrop"))))
(DUse false (UseGroup ("tools" "printer") ((mem "declToString" false))))
(DUse false (UseGroup ("support" "char") ((mem "isAlnum" false) (mem "isLower" false) (mem "isUpper" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "commentText" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "factComments" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "dedupeNamesLoc" false) (mem "declLocList" false) (mem "nameSetOf" false) (mem "ruleNameDeadCode" false) (mem "sortUniqS" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDeadCode")) (fa "summary" (ELit (LString "private (unexported) top-level binding is unreachable from the file's exports/main/doctests. Dead code (Haskell -Wunused-top-binds)"))) (fa "doc" (ELit (LString "A private top-level binding that nothing reachable from the file's exports, `main` or doctests uses is dead code (Haskell -Wunused-top-binds). Delete it or export it.\n\nBefore:\n  helper x = x + 1   -- never called\nAfter:\n  (binding removed)"))) (fa "category" (EVar "Suspicious")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleDeadCode")) (EVar "None")))
(DTypeSig false "ruleDeadCode" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleDeadCode" (PWild PWild (PVar "facts") (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "reach") (EApp (EApp (EVar "reachableNames") (EVar "facts")) (EVar "prog"))) (DoExpr (EApp (EApp (EMethodRef "map") (EVar "deadFinding")) (EApp (EApp (EVar "filterList") (EApp (EVar "deadPair") (EVar "reach"))) (EApp (EApp (EVar "privateDefLocs") (EVar "pos")) (EVar "prog")))))))
(DTypeSig false "deadPair" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Bool"))))
(DFunDef false "deadPair" ((PVar "reach") (PTuple (PVar "n") PWild)) (EApp (EVar "not") (EApp (EApp (EVar "has") (EVar "n")) (EVar "reach"))))
(DTypeSig false "deadFinding" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Finding")))
(DFunDef false "deadFinding" ((PTuple (PVar "name") (PVar "loc"))) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDeadCode")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "private top-level '")) (EVar "name")) (ELit (LString "' is unreachable from exports/main/doctests — remove it (dead code)")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
(DTypeSig false "privateDefLocs" (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "privateDefLocs" ((PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "exported") (EApp (EVar "nameSetOf") (EApp (EVar "exportedNames") (EVar "prog")))) (DoExpr (EApp (EVar "dedupeNamesLoc") (EApp (EApp (EVar "filterList") (EApp (EVar "candidatePair") (EVar "exported"))) (EApp (EApp (EDictApp "flatMap") (EVar "allDefNameL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))))))
(DTypeSig false "allDefNameL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "allDefNameL" ((PTuple (PCon "DFunDef" PWild (PVar "name") PWild PWild PWild PWild) (PVar "loc"))) (EListLit (ETuple (EVar "name") (EVar "loc"))))
(DFunDef false "allDefNameL" ((PTuple (PCon "DAttrib" PWild (PVar "d")) (PVar "loc"))) (EApp (EVar "allDefNameL") (ETuple (EVar "d") (EVar "loc"))))
(DFunDef false "allDefNameL" (PWild) (EListLit))
(DTypeSig false "candidatePair" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Bool"))))
(DFunDef false "candidatePair" ((PVar "exported") (PTuple (PVar "n") PWild)) (EBinOp "&&" (EApp (EVar "isOrdinaryIdent") (EVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "has") (EVar "n")) (EVar "exported")))))
(DTypeSig false "isOrdinaryIdent" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isOrdinaryIdent" ((PVar "s")) (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 0))) (EVar "False") (EIf (EVar "otherwise") (EApp (EVar "isIdentStart") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EVar "stringToChars") (EVar "s")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reachableNames" (TyFun (TyCon "FileFacts") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "reachableNames" ((PVar "facts") (PVar "prog")) (EBlock (DoLet false false (PVar "refMap") (EApp (EVar "mergeRefs") (EApp (EApp (EDictApp "flatMap") (EVar "defRefPair")) (EVar "prog")))) (DoLet false false (PVar "seed") (EBinOp "++" (EApp (EVar "exportedNames") (EVar "prog")) (EBinOp "::" (ELit (LString "main")) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "nonDefRefL")) (EVar "prog")) (EApp (EVar "doctestIdents") (EApp (EVar "factComments") (EVar "facts"))))))) (DoLet false false (PVar "visited") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EVar "bfsReach") (EVar "refMap")) (EVar "visited")) (EVar "seed"))) (DoExpr (EVar "visited"))))
(DTypeSig false "defRefPair" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "defRefPair" ((PVar "d")) (EMatch (EApp (EVar "defNameOf") (EVar "d")) (arm (PCon "Some" (PVar "name")) () (EListLit (ETuple (EVar "name") (EApp (EVar "sortUniqS") (EApp (EVar "identTokens") (EApp (EVar "declToString") (EApp (EVar "unAttrib") (EVar "d")))))))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "defNameOf" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "defNameOf" ((PCon "DFunDef" PWild (PVar "name") PWild PWild PWild PWild)) (EApp (EVar "Some") (EVar "name")))
(DFunDef false "defNameOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "defNameOf") (EVar "d")))
(DFunDef false "defNameOf" (PWild) (EVar "None"))
(DTypeSig false "unAttrib" (TyFun (TyCon "Decl") (TyCon "Decl")))
(DFunDef false "unAttrib" ((PCon "DAttrib" PWild (PVar "d"))) (EVar "d"))
(DFunDef false "unAttrib" ((PVar "d")) (EVar "d"))
(DTypeSig false "exportedNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "exportedNames" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "exportedNameL")) (EVar "prog")))
(DTypeSig false "exportedNameL" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "exportedNameL" ((PCon "DFunDef" (PCon "True") (PVar "name") PWild PWild PWild PWild)) (EListLit (EVar "name")))
(DFunDef false "exportedNameL" ((PCon "DTypeSig" (PCon "True") (PVar "name") PWild PWild)) (EListLit (EVar "name")))
(DFunDef false "exportedNameL" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "exportedNameL") (EVar "d")))
(DFunDef false "exportedNameL" (PWild) (EListLit))
(DTypeSig false "nonDefRefL" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "nonDefRefL" ((PCon "DAttrib" PWild (PVar "dd"))) (EApp (EVar "nonDefRefL") (EVar "dd")))
(DFunDef false "nonDefRefL" ((PCon "DFunDef" PWild PWild PWild PWild PWild PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PCon "DTypeSig" PWild PWild PWild PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PCon "DExtern" PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PRec "DData" ((rf "dataOrigin" PWild)) false)) (EListLit))
(DFunDef false "nonDefRefL" ((PCon "DUse" PWild PWild PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PCon "DEffect" PWild PWild PWild PWild PWild PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PRec "DTypeAlias" ((rf "tyAliasOrigin" PWild)) false)) (EListLit))
(DFunDef false "nonDefRefL" ((PRec "DNewtype" ((rf "newtypeOrigin" PWild)) false)) (EListLit))
(DFunDef false "nonDefRefL" ((PVar "d")) (EApp (EVar "bodyIdents") (EVar "d")))
(DTypeSig false "bodyIdents" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "bodyIdents" ((PVar "d")) (EApp (EVar "sortUniqS") (EApp (EVar "identTokens") (EApp (EVar "declToString") (EVar "d")))))
(DTypeSig false "bfsReach" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "bfsReach" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "bfsReach" ((PVar "refMap") (PVar "visited") (PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "has") (EVar "x")) (EVar "visited")) (EApp (EApp (EApp (EVar "bfsReach") (EVar "refMap")) (EVar "visited")) (EVar "rest")) (EIf (EVar "otherwise") (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "x")) (ELit LUnit)) (EVar "visited"))) (DoExpr (EApp (EApp (EApp (EVar "bfsReach") (EVar "refMap")) (EVar "visited")) (EBinOp "++" (EApp (EApp (EVar "refsOf") (EVar "refMap")) (EVar "x")) (EVar "rest"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "refsOf" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "refsOf" ((PVar "refMap") (PVar "n")) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "n")) (EVar "refMap")))
(DTypeSig false "mergeRefs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "mergeRefs" ((PVar "pairs")) (EBlock (DoLet false false (PVar "m") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "mergeRefsGo") (EVar "m")) (EVar "pairs"))) (DoExpr (EVar "m"))))
(DTypeSig false "mergeRefsGo" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Unit"))))
(DFunDef false "mergeRefsGo" (PWild (PList)) (ELit LUnit))
(DFunDef false "mergeRefsGo" ((PVar "acc") (PCons (PTuple (PVar "n") (PVar "rs")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "n")) (EApp (EVar "sortUniqS") (EBinOp "++" (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "n")) (EVar "acc")) (EVar "rs")))) (EVar "acc"))) (DoExpr (EApp (EApp (EVar "mergeRefsGo") (EVar "acc")) (EVar "rest")))))
(DTypeSig false "identTokens" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "identTokens" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "identTokGo") (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0))))))
(DTypeSig false "identTokGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "identTokGo" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EIf (EApp (EVar "isIdentStart") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EBlock (DoLet false false (PVar "j") (EApp (EApp (EApp (EVar "identEnd") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EVar "charsSlice") (EVar "cs")) (EVar "i")) (EVar "j")) (EApp (EApp (EApp (EVar "identTokGo") (EVar "cs")) (EVar "n")) (EVar "j"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "identTokGo") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "charsSlice" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "charsSlice" ((PVar "cs") (PVar "i") (PVar "j")) (EApp (EVar "stringFromChars") (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "j") (EVar "i"))) (ELam ((PVar "k")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (EVar "k"))) (EVar "cs"))))))
(DTypeSig false "isIdentStart" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isIdentStart" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EApp (EVar "isLower") (EVar "c")) (EApp (EVar "isUpper") (EVar "c"))) (EBinOp "==" (EVar "c") (ELit (LChar "_")))))
(DTypeSig false "identEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "identEnd" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "i") (EIf (EApp (EVar "isAlnum") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EApp (EVar "identEnd") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "doctestIdents" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "doctestIdents" ((PVar "cmts")) (EApp (EApp (EDictApp "flatMap") (EVar "commentDocIdents")) (EVar "cmts")))
(DTypeSig false "commentDocIdents" (TyFun (TyCon "Comment") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "commentDocIdents" ((PVar "c")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "commentText") (EVar "c"))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "{-"))) (EVar "t")) (EApp (EApp (EDictApp "flatMap") (EVar "blockDocLineIdents")) (EApp (EVar "splitNl") (EApp (EVar "blockInner") (EVar "t")))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "-- >"))) (EVar "t")) (EApp (EVar "identTokens") (EApp (EApp (EVar "strDrop") (ELit (LInt 4))) (EVar "t"))) (EListLit))))))
(DTypeSig false "blockInner" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "blockInner" ((PVar "t")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "t"))) (DoExpr (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 4))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (EBinOp "-" (EVar "n") (ELit (LInt 2)))) (EVar "t")) (ELit (LString ""))))))
(DTypeSig false "blockDocLineIdents" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "blockDocLineIdents" ((PVar "line")) (EBlock (DoLet false false (PVar "tr") (EApp (EVar "stringTrim") (EVar "line"))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (ELit (LString ">"))) (EVar "tr")) (EApp (EVar "identTokens") (EApp (EApp (EVar "strDrop") (ELit (LInt 1))) (EVar "tr"))) (EListLit)))))
