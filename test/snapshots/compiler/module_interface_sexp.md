# META
source_lines=497
stages=DESUGAR,MARK
# SOURCE
-- A module's interface as a file: `ModuleInterface` written as an `SExp` per
-- section and read back, framed by `types.interface_frame`.
--
-- The header carries the whole `ModuleKey`, field by field, so a reader knows
-- what the file was written for before it looks at a section:
--   (medaka-module <version> (module <id>) (source <text>)
--     (imports ((<module> <identity>) ...)) (graph <text>) (sections <n>)
--     (digest <hex>))
-- The key is opaque here: it is written as it is given and read back as it was
-- written.  A section is one interface valid under the joins it lists (the
-- join is a section tag, not a key field), one line per section:
--   (section (joins (<join> ...)) <interface>)   a join is a list of `atom`
--   (module-interface <field> x24)               `ModuleInterface`, field
--                                                order, less its key and
--                                                its trees, which no file holds
-- Every number in an interface is a plain integer: binder and evidence
-- ordinals and the serial are process-global values this codec neither
-- relocates nor interprets.  The scheme-level nodes are `types.interface_sexp`'s;
-- the others are written here:
--   (moddiags <id> (<binding> ...) (<tcdiag> ...) (<tcdiag> ...))
--   (tcdiag <code> <severity> <loc-opt> <message> <opt> <fix-opt>)
--   (loc <file> <int> <int> <int> <int>)      a fix is a `(<loc> <text>)` pair
--   (export <pub> <pub-opt> <bool>)           `FrozenExport`
--   (grant <arity> (<name> ...))              `MethodGrant`
--   (<evidence row> ...)                      `EvTable`, `frontend.ast_codec`
--   (<id> <name> <type> (<type>?) <bool>)     `BinderRow`; an id of module
--                                             `""` is its bare ordinal
-- A file whose key the reader's gate calls stale is refused before its digest
-- is checked and before any section is decoded.  A reader returns `Err`, never
-- a partial value, for a stale key, a lying digest, a torn text, a version
-- other than `moduleFormatVersion`, an unknown tag or a truncated list.
import frontend.ast.{BinderId(..), EvTable, Loc(..)}
import frontend.ast_codec.{decodeEvEntries, evEntriesSExp, sexpBinderId}
import support.sexp_value.{
  SExp(..), SexpError(..), atomBool, atomInt, expectAtom, parseSExp, renderSExp
}
import types.effect_rows.{Atom}
import types.interface_frame.{
  InterfaceFault(..), framedFile, openFramed, verifyDigest
}
import types.interface_sexp.{
  Reader, at, atomSExp, decJoins, decPairAtoms, pairAtoms, boolNode,
  bindingOfSExp, bindingSExp, cDeclaredPrefixOfSExp, cDeclaredPrefixSExp,
  dataVisOfSExp, dataVisSExp, ifaceRefOfSExp, ifaceRefSExp, intNode, listOfSExp,
  listSExp, methodPredicateSlotOfSExp, methodPredicateSlotSExp, misfit, nested,
  optionOfSExp, optionSExp, pairOfSExp, pairSExp, predicateSlotOfSExp,
  predicateSlotSExp, pubSchemeOfSExp, pubSchemeSExp, recordInfoOfSExp,
  recordInfoSExp, refuse, spellingPopOfSExp, spellingPopSExp, tabKeyOfSExp,
  tabKeySExp, tagged, tripleOfSExp, tripleSExp, variantOfSExp, variantSExp,
  vecOblOfSExp, vecOblSExp, invocationViewSExp, invocationViewOfSExp
}
import types.module_interface.{
  FrozenExport(..), ModuleInterface(..), ModuleKey(..), moduleKeyText
}
import types.publish.{ModDiags, TcDiag(..)}
import types.runtime_types.{
  BinderRow(..), RuntimeType, runtimeTypeFromName, runtimeTypeName
}
import types.tc_types.{MethodGrant(..)}

-- ── the value ───────────────────────────────────────────────────────────────

-- One interface of a file, with the IO joins it is valid under.
public export data ModuleSection = ModuleSection {
  msJoins : List (List Atom),
  msInterface : ModuleInterface,
}

export
moduleFormatVersion : Int
moduleFormatVersion = 2

fileTag : String
fileTag = "medaka-module"

-- ── writing ─────────────────────────────────────────────────────────────────

moduleHeaderFields : ModuleKey -> List SExp
moduleHeaderFields k = [
  tagged "module" [SAtom k.mkModule],
  tagged "source" [SAtom k.mkSource],
  tagged "imports" [listSExp (pairSExp SAtom SAtom) k.mkImports],
  tagged "graph" [SAtom k.mkGraph],
]

locNode : Loc -> SExp
locNode (Loc file a b c d) =
  tagged "loc" [SAtom file, intNode a, intNode b, intNode c, intNode d]

diagNode : TcDiag -> SExp
diagNode (TcDiag code severity loc message help fix) = tagged "tcdiag" [
  SAtom code,
  intNode severity,
  optionSExp locNode loc,
  SAtom message,
  optionSExp SAtom help,
  optionSExp (pairSExp locNode SAtom) fix,
]

modDiagsNode : ModDiags -> SExp
modDiagsNode (mid, (schemes, errs, warns)) = tagged "moddiags" [
  SAtom mid,
  listSExp (b => bindingSExp (fst b) (snd b)) schemes,
  listSExp diagNode errs,
  listSExp diagNode warns,
]

exportNode : FrozenExport -> SExp
exportNode fe = tagged "export" [
  pubSchemeSExp fe.feScheme,
  optionSExp pubSchemeSExp fe.feStandalone,
  boolNode fe.feExtern,
]

grantNode : MethodGrant -> SExp
grantNode g = tagged "grant" [intNode g.mgArity, listSExp SAtom g.mgNames]

binderNode : BinderRow -> SExp
binderNode row = SList [
  sexpBinderId row.brId,
  SAtom row.brName,
  SAtom (runtimeTypeName row.brType),
  optionList (map (t => SAtom (runtimeTypeName t)) row.brReturns),
  boolNode row.brSigned,
]

-- A binder's return type is a list of at most one element, not `optionSExp`'s
-- `none`/`some` pair: `decBinder` reads it back with the list reader.
optionList : Option SExp -> SExp
optionList None = SList []
optionList (Some x) = SList [x]

-- A constructor pattern over every field, so a field added to the record is a
-- build error here until it has an arm.  The key and its text are not encoded (the
-- file's header carries the identity) and neither is `miTrees`: an interface file
-- carries no trees.
interfaceNode : ModuleInterface -> SExp
interfaceNode (ModuleInterface _key _keyText serial row exports funNames dispatchIdx dataCtors ctorPop recordPop funSlots funSlotsQual declared declaredQual methodSlots methodSlotsQual schemeObls existentials patternAuth anyEx evTable binders topIds grants takers sticky view _trees) = tagged
  "module-interface"
  [
    intNode serial,
    modDiagsNode row,
    listSExp (pairSExp SAtom exportNode) exports,
    listSExp SAtom funNames,
    listSExp (pairSExp (pairSExp ifaceRefSExp SAtom) intNode) dispatchIdx,
    listSExp
      (pairSExp
        tabKeySExp
        (tripleSExp dataVisSExp (listSExp SAtom) (listSExp variantSExp)))
      dataCtors,
    spellingPopSExp pubSchemeSExp ctorPop,
    spellingPopSExp recordInfoSExp recordPop,
    listSExp (pairSExp SAtom (listSExp predicateSlotSExp)) funSlots,
    listSExp (pairSExp pairAtoms (listSExp predicateSlotSExp)) funSlotsQual,
    listSExp (pairSExp SAtom cDeclaredPrefixSExp) declared,
    listSExp (pairSExp pairAtoms cDeclaredPrefixSExp) declaredQual,
    listSExp (pairSExp SAtom (listSExp methodPredicateSlotSExp)) methodSlots,
    listSExp
      (pairSExp pairAtoms (listSExp methodPredicateSlotSExp))
      methodSlotsQual,
    listSExp (pairSExp pairAtoms (listSExp vecOblSExp)) schemeObls,
    listSExp intNode existentials,
    listSExp intNode patternAuth,
    boolNode anyEx,
    evEntriesSExp evTable,
    listSExp binderNode binders,
    listSExp (pairSExp SAtom (listSExp intNode)) topIds,
    listSExp (pairSExp SAtom grantNode) grants,
    listSExp SAtom takers,
    listSExp (pairSExp SAtom diagNode) sticky,
    invocationViewSExp view,
  ]

sectionLine : ModuleSection -> String
sectionLine s =
  renderSExp
      (tagged "section" [
        tagged "joins" [listSExp (listSExp atomSExp) s.msJoins],
        interfaceNode s.msInterface,
      ])
    ++ "\n"

-- The file for [sections] under [key].  Panics when a section's interface was
-- recorded under another key: the header is the only place the key is written.
export
encodeModuleSections : ModuleKey -> List ModuleSection -> String
encodeModuleSections key sections
  | any (s => s.msInterface.miKeyText /= moduleKeyText key) sections =
    panic "module_interface_sexp: a section was recorded under another key"
  | otherwise =
    framedFile
      fileTag
      moduleFormatVersion
      (moduleHeaderFields key
        ++ [tagged "sections" [intNode (length sections)]])
      (stringJoin "" (map sectionLine sections))

-- The file for one interface valid under every join.
export
encodeModuleInterface : ModuleInterface -> String
encodeModuleInterface mi = encodeModuleSections mi.miKey [
  ModuleSection { msJoins = [], msInterface = mi },
]

-- ── reading ─────────────────────────────────────────────────────────────────

decLoc : Reader Loc
decLoc path (SList [SAtom "loc", f, a, b, c, d]) = do
  file <- expectAtom (at path "loc" 1) f
  a1 <- atomInt (at path "loc" 2) a
  b1 <- atomInt (at path "loc" 3) b
  c1 <- atomInt (at path "loc" 4) c
  d1 <- atomInt (at path "loc" 5) d
  Ok (Loc file a1 b1 c1 d1)
decLoc path node = misfit path [("loc", 5)] node

decDiag : Reader TcDiag
decDiag path (SList [SAtom "tcdiag", c, s, l, m, h, f]) = do
  code <- expectAtom (at path "tcdiag" 1) c
  severity <- atomInt (at path "tcdiag" 2) s
  loc <- optionOfSExp decLoc (at path "tcdiag" 3) l
  message <- expectAtom (at path "tcdiag" 4) m
  help <- optionOfSExp expectAtom (at path "tcdiag" 5) h
  fix <- optionOfSExp (pairOfSExp decLoc expectAtom) (at path "tcdiag" 6) f
  Ok (TcDiag code severity loc message help fix)
decDiag path node = misfit path [("tcdiag", 6)] node

decModDiags : Reader ModDiags
decModDiags path (SList [SAtom "moddiags", m, ss, es, ws]) = do
  mid <- expectAtom (at path "moddiags" 1) m
  schemes <- listOfSExp (nested bindingOfSExp) (at path "moddiags" 2) ss
  errs <- listOfSExp decDiag (at path "moddiags" 3) es
  warns <- listOfSExp decDiag (at path "moddiags" 4) ws
  Ok (mid, (schemes, errs, warns))
decModDiags path node = misfit path [("moddiags", 4)] node

decExport : Reader FrozenExport
decExport path (SList [SAtom "export", s, alt, ext]) = do
  scheme <- nested pubSchemeOfSExp (at path "export" 1) s
  standalone <- optionOfSExp (nested pubSchemeOfSExp) (at path "export" 2) alt
  isExtern <- atomBool (at path "export" 3) ext
  Ok FrozenExport {
    feScheme = scheme,
    feStandalone = standalone,
    feExtern = isExtern,
  }
decExport path node = misfit path [("export", 3)] node

decGrant : Reader MethodGrant
decGrant path (SList [SAtom "grant", a, ns]) = do
  arity <- atomInt (at path "grant" 1) a
  names <- listOfSExp expectAtom (at path "grant" 2) ns
  Ok MethodGrant { mgArity = arity, mgNames = names }
decGrant path node = misfit path [("grant", 2)] node

decBinderId : Reader BinderId
decBinderId path (SAtom n) = map (BinderId "") (atomInt path (SAtom n))
decBinderId path (SList [SAtom m, n]) = map (BinderId m) (atomInt path n)
decBinderId path node = refuse path node "expected a binder id"

decRuntimeType : Reader RuntimeType
decRuntimeType path node = do
  name <- expectAtom path node
  match runtimeTypeFromName name
    Some t => Ok t
    None => refuse path node "unknown runtime type"

decBinder : Reader BinderRow
decBinder path (SList [i, n, t, r, s]) = do
  bid <- decBinderId (at path "binder" 1) i
  name <- expectAtom (at path "binder" 2) n
  ty <- decRuntimeType (at path "binder" 3) t
  returns <- listOfSExp decRuntimeType (at path "binder" 4) r
  signed <- atomBool (at path "binder" 5) s
  returned <- match returns
    [] => Ok None
    [x] => Ok (Some x)
    _ => refuse (at path "binder" 4) r "expected at most one type"
  Ok BinderRow {
    brId = bid,
    brName = name,
    brType = ty,
    brReturns = returned,
    brSigned = signed,
  }
decBinder path node = refuse path node "expected a binder row of five fields"

decEvTable : Reader EvTable
decEvTable path node =
  mapErr
    (e => { e | sePath = "\{path}/\{e.sePath}" })
    (decodeEvEntries (renderSExp node))

decInterface : ModuleKey -> Reader ModuleInterface
decInterface key path (SList [SAtom "module-interface", n1, n2, n3, n4, n5, n6, n7, n8, n9, n10, n11, n12, n13, n14, n15, n16, n17, n18, n19, n20, n21, n22, n23, n24, n25]) =
  do
    let p = at path "module-interface"
    serial <- atomInt (p 1) n1
    row <- decModDiags (p 2) n2
    exports <- listOfSExp (pairOfSExp expectAtom decExport) (p 3) n3
    funNames <- listOfSExp expectAtom (p 4) n4
    dispatchIdx <- listOfSExp
      (pairOfSExp (pairOfSExp (nested ifaceRefOfSExp) expectAtom) atomInt)
      (p 5)
      n5
    dataCtors <- listOfSExp
      (pairOfSExp
        (nested tabKeyOfSExp)
        (tripleOfSExp
          (nested dataVisOfSExp)
          (listOfSExp expectAtom)
          (listOfSExp (nested variantOfSExp))))
      (p 6)
      n6
    ctorPop <- spellingPopOfSExp (nested pubSchemeOfSExp) (p 7) n7
    recordPop <- spellingPopOfSExp (nested recordInfoOfSExp) (p 8) n8
    funSlots <- listOfSExp
      (pairOfSExp expectAtom (listOfSExp (nested predicateSlotOfSExp)))
      (p 9)
      n9
    funSlotsQual <- listOfSExp
      (pairOfSExp decPairAtoms (listOfSExp (nested predicateSlotOfSExp)))
      (p 10)
      n10
    declared <- listOfSExp
      (pairOfSExp expectAtom (nested cDeclaredPrefixOfSExp))
      (p 11)
      n11
    declaredQual <- listOfSExp
      (pairOfSExp decPairAtoms (nested cDeclaredPrefixOfSExp))
      (p 12)
      n12
    methodSlots <- listOfSExp
      (pairOfSExp expectAtom (listOfSExp (nested methodPredicateSlotOfSExp)))
      (p 13)
      n13
    methodSlotsQual <- listOfSExp
      (pairOfSExp decPairAtoms (listOfSExp (nested methodPredicateSlotOfSExp)))
      (p 14)
      n14
    schemeObls <- listOfSExp
      (pairOfSExp decPairAtoms (listOfSExp (nested vecOblOfSExp)))
      (p 15)
      n15
    existentials <- listOfSExp atomInt (p 16) n16
    patternAuth <- listOfSExp atomInt (p 17) n17
    anyEx <- atomBool (p 18) n18
    evTable <- decEvTable (p 19) n19
    binders <- listOfSExp decBinder (p 20) n20
    topIds <- listOfSExp (pairOfSExp expectAtom (listOfSExp atomInt)) (p 21) n21
    grants <- listOfSExp (pairOfSExp expectAtom decGrant) (p 22) n22
    takers <- listOfSExp expectAtom (p 23) n23
    sticky <- listOfSExp (pairOfSExp expectAtom decDiag) (p 24) n24
    view <- nested invocationViewOfSExp (p 25) n25
    Ok ModuleInterface {
      miKey = key,
      miKeyText = moduleKeyText key,
      miSerial = serial,
      miRow = row,
      miExports = exports,
      miFunNames = funNames,
      miDispatchIdx = dispatchIdx,
      miDataCtors = dataCtors,
      miCtorPop = ctorPop,
      miRecordPop = recordPop,
      miFunSlots = funSlots,
      miFunSlotsQual = funSlotsQual,
      miDeclared = declared,
      miDeclaredQual = declaredQual,
      miMethodSlots = methodSlots,
      miMethodSlotsQual = methodSlotsQual,
      miSchemeOblsQual = schemeObls,
      miExistentials = existentials,
      miPatternAuth = patternAuth,
      miAnyExistentials = anyEx,
      miEvTable = evTable,
      miBinders = binders,
      miTopIds = topIds,
      miMethodGrants = grants,
      miTakers = takers,
      miSticky = sticky,
      miInvocationView = view,
      miTrees = None,
    }
decInterface _ path node = misfit path [("module-interface", 25)] node

decSection : ModuleKey -> Reader ModuleSection
decSection key path (SList [SAtom "section", js, i]) = do
  joins <- decJoins (at path "section" 1) js
  value <- decInterface key (at path "section" 2) i
  Ok ModuleSection { msJoins = joins, msInterface = value }
decSection _ path node = misfit path [("section", 2)] node

-- The key of the header's fields, and the section count after it.
readHeaderFields : List SExp -> Result SexpError (ModuleKey, Int)
readHeaderFields [SList [SAtom "module", m], SList [SAtom "source", s], SList [SAtom "imports", imps], SList [SAtom "graph", g], SList [SAtom "sections", n]] =
  do
    modId <- expectAtom "header/module" m
    source <- expectAtom "header/source" s
    imports <- listOfSExp decPairAtoms "header/imports" imps
    graph <- expectAtom "header/graph" g
    count <- atomInt "header/sections" n
    Ok (
      ModuleKey {
        mkModule = modId,
        mkSource = source,
        mkImports = imports,
        mkGraph = graph,
      },
      count,
    )
readHeaderFields _ = Err SexpError {
  seOffset = 0,
  sePath = "header",
  seWhat = "expected the module, source, imports, graph and sections fields",
}

-- The component a key differs from [expected] in, if it does.
export
keyDifference : ModuleKey -> ModuleKey -> Option String
keyDifference expected k
  | k.mkModule /= expected.mkModule = Some "module"
  | k.mkSource /= expected.mkSource = Some "source"
  | k.mkImports /= expected.mkImports = Some "imports"
  | k.mkGraph /= expected.mkGraph = Some "graph"
  | otherwise = None

-- The key a file's header claims, read off that line alone: the version and the
-- header's shape are checked, the digest and the sections are not.
export
readModuleKey : String -> Result InterfaceFault ModuleKey
readModuleKey text = do
  (fields, _, _) <- openFramed fileTag moduleFormatVersion 5 text
  (key, _) <- mapErr Malformed (readHeaderFields fields)
  Ok key

-- The file's key and sections, once [gate] has found the header's key fresh.
-- The order is the version, the header, the gate, the digest, then the
-- sections, so a stale key never has its body decoded.
export
decodeModuleSections : (ModuleKey -> Option String) ->
  String ->
  Result InterfaceFault (ModuleKey, List ModuleSection)
decodeModuleSections gate text = do
  (fields, digest, covered) <- openFramed fileTag moduleFormatVersion 5 text
  (key, count) <- mapErr Malformed (readHeaderFields fields)
  _ <- stale (gate key)
  _ <- verifyDigest digest covered
  top <- mapErr Malformed (parseSExp ("(" ++ covered ++ ")"))
  sections <- mapErr Malformed (listOfSExp (decSection key) "file" top)
  if length sections /= count then
    Err
      (Malformed SexpError {
        seOffset = 0,
        sePath = "header/sections.1",
        seWhat =
          "header counts \{count} section(s), the file holds \{length sections}",
      })
  else
    Ok (key, sections)

-- `interface_frame.gated` over a `ModuleKey`: that gate is typed on `InterfaceKey`,
-- and this one has already run, so it takes the component it found.
stale : Option String -> Result InterfaceFault Unit
stale None = Ok ()
stale (Some component) = Err (StaleKey component)

-- The one interface of a file, once [gate] has found its key fresh.
export
decodeModuleInterfaceGated : (ModuleKey -> Option String) ->
  String ->
  Result InterfaceFault ModuleInterface
decodeModuleInterfaceGated gate text = do
  (_, sections) <- decodeModuleSections gate text
  match sections
    [s] => Ok s.msInterface
    _ =>
      Err
        (Malformed SexpError {
          seOffset = 0,
          sePath = "header/sections.1",
          seWhat = "expected one section, the file holds \{length sections}",
        })

-- The interface a file holds, whatever key it was written under.
export
decodeModuleInterface : String -> Result InterfaceFault ModuleInterface
decodeModuleInterface = decodeModuleInterfaceGated (_ => None)

-- The interface a file holds for [expected]: a header key that differs is
-- `StaleKey` of the component, before the digest or any section is read.
export
decodeModuleInterfaceFor : ModuleKey ->
  String ->
  Result InterfaceFault ModuleInterface
decodeModuleInterfaceFor expected =
  decodeModuleInterfaceGated (keyDifference expected)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "BinderId" true) (mem "EvTable" false) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "ast_codec") ((mem "decodeEvEntries" false) (mem "evEntriesSExp" false) (mem "sexpBinderId" false))))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SExp" true) (mem "SexpError" true) (mem "atomBool" false) (mem "atomInt" false) (mem "expectAtom" false) (mem "parseSExp" false) (mem "renderSExp" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" false))))
(DUse false (UseGroup ("types" "interface_frame") ((mem "InterfaceFault" true) (mem "framedFile" false) (mem "openFramed" false) (mem "verifyDigest" false))))
(DUse false (UseGroup ("types" "interface_sexp") ((mem "Reader" false) (mem "at" false) (mem "atomSExp" false) (mem "decJoins" false) (mem "decPairAtoms" false) (mem "pairAtoms" false) (mem "boolNode" false) (mem "bindingOfSExp" false) (mem "bindingSExp" false) (mem "cDeclaredPrefixOfSExp" false) (mem "cDeclaredPrefixSExp" false) (mem "dataVisOfSExp" false) (mem "dataVisSExp" false) (mem "ifaceRefOfSExp" false) (mem "ifaceRefSExp" false) (mem "intNode" false) (mem "listOfSExp" false) (mem "listSExp" false) (mem "methodPredicateSlotOfSExp" false) (mem "methodPredicateSlotSExp" false) (mem "misfit" false) (mem "nested" false) (mem "optionOfSExp" false) (mem "optionSExp" false) (mem "pairOfSExp" false) (mem "pairSExp" false) (mem "predicateSlotOfSExp" false) (mem "predicateSlotSExp" false) (mem "pubSchemeOfSExp" false) (mem "pubSchemeSExp" false) (mem "recordInfoOfSExp" false) (mem "recordInfoSExp" false) (mem "refuse" false) (mem "spellingPopOfSExp" false) (mem "spellingPopSExp" false) (mem "tabKeyOfSExp" false) (mem "tabKeySExp" false) (mem "tagged" false) (mem "tripleOfSExp" false) (mem "tripleSExp" false) (mem "variantOfSExp" false) (mem "variantSExp" false) (mem "vecOblOfSExp" false) (mem "vecOblSExp" false) (mem "invocationViewSExp" false) (mem "invocationViewOfSExp" false))))
(DUse false (UseGroup ("types" "module_interface") ((mem "FrozenExport" true) (mem "ModuleInterface" true) (mem "ModuleKey" true) (mem "moduleKeyText" false))))
(DUse false (UseGroup ("types" "publish") ((mem "ModDiags" false) (mem "TcDiag" true))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderRow" true) (mem "RuntimeType" false) (mem "runtimeTypeFromName" false) (mem "runtimeTypeName" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "MethodGrant" true))))
(DData Public "ModuleSection" () ((variant "ModuleSection" (ConNamed (field "msJoins" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom")))) (field "msInterface" (TyCon "ModuleInterface"))))) ())
(DTypeSig true "moduleFormatVersion" (TyCon "Int"))
(DFunDef false "moduleFormatVersion" () (ELit (LInt 2)))
(DTypeSig false "fileTag" (TyCon "String"))
(DFunDef false "fileTag" () (ELit (LString "medaka-module")))
(DTypeSig false "moduleHeaderFields" (TyFun (TyCon "ModuleKey") (TyApp (TyCon "List") (TyCon "SExp"))))
(DFunDef false "moduleHeaderFields" ((PVar "k")) (EListLit (EApp (EApp (EVar "tagged") (ELit (LString "module"))) (EListLit (EApp (EVar "SAtom") (EFieldAccess (EVar "k") "mkModule")))) (EApp (EApp (EVar "tagged") (ELit (LString "source"))) (EListLit (EApp (EVar "SAtom") (EFieldAccess (EVar "k") "mkSource")))) (EApp (EApp (EVar "tagged") (ELit (LString "imports"))) (EListLit (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "SAtom"))) (EFieldAccess (EVar "k") "mkImports")))) (EApp (EApp (EVar "tagged") (ELit (LString "graph"))) (EListLit (EApp (EVar "SAtom") (EFieldAccess (EVar "k") "mkGraph"))))))
(DTypeSig false "locNode" (TyFun (TyCon "Loc") (TyCon "SExp")))
(DFunDef false "locNode" ((PCon "Loc" (PVar "file") (PVar "a") (PVar "b") (PVar "c") (PVar "d"))) (EApp (EApp (EVar "tagged") (ELit (LString "loc"))) (EListLit (EApp (EVar "SAtom") (EVar "file")) (EApp (EVar "intNode") (EVar "a")) (EApp (EVar "intNode") (EVar "b")) (EApp (EVar "intNode") (EVar "c")) (EApp (EVar "intNode") (EVar "d")))))
(DTypeSig false "diagNode" (TyFun (TyCon "TcDiag") (TyCon "SExp")))
(DFunDef false "diagNode" ((PCon "TcDiag" (PVar "code") (PVar "severity") (PVar "loc") (PVar "message") (PVar "help") (PVar "fix"))) (EApp (EApp (EVar "tagged") (ELit (LString "tcdiag"))) (EListLit (EApp (EVar "SAtom") (EVar "code")) (EApp (EVar "intNode") (EVar "severity")) (EApp (EApp (EVar "optionSExp") (EVar "locNode")) (EVar "loc")) (EApp (EVar "SAtom") (EVar "message")) (EApp (EApp (EVar "optionSExp") (EVar "SAtom")) (EVar "help")) (EApp (EApp (EVar "optionSExp") (EApp (EApp (EVar "pairSExp") (EVar "locNode")) (EVar "SAtom"))) (EVar "fix")))))
(DTypeSig false "modDiagsNode" (TyFun (TyCon "ModDiags") (TyCon "SExp")))
(DFunDef false "modDiagsNode" ((PTuple (PVar "mid") (PTuple (PVar "schemes") (PVar "errs") (PVar "warns")))) (EApp (EApp (EVar "tagged") (ELit (LString "moddiags"))) (EListLit (EApp (EVar "SAtom") (EVar "mid")) (EApp (EApp (EVar "listSExp") (ELam ((PVar "b")) (EApp (EApp (EVar "bindingSExp") (EApp (EVar "fst") (EVar "b"))) (EApp (EVar "snd") (EVar "b"))))) (EVar "schemes")) (EApp (EApp (EVar "listSExp") (EVar "diagNode")) (EVar "errs")) (EApp (EApp (EVar "listSExp") (EVar "diagNode")) (EVar "warns")))))
(DTypeSig false "exportNode" (TyFun (TyCon "FrozenExport") (TyCon "SExp")))
(DFunDef false "exportNode" ((PVar "fe")) (EApp (EApp (EVar "tagged") (ELit (LString "export"))) (EListLit (EApp (EVar "pubSchemeSExp") (EFieldAccess (EVar "fe") "feScheme")) (EApp (EApp (EVar "optionSExp") (EVar "pubSchemeSExp")) (EFieldAccess (EVar "fe") "feStandalone")) (EApp (EVar "boolNode") (EFieldAccess (EVar "fe") "feExtern")))))
(DTypeSig false "grantNode" (TyFun (TyCon "MethodGrant") (TyCon "SExp")))
(DFunDef false "grantNode" ((PVar "g")) (EApp (EApp (EVar "tagged") (ELit (LString "grant"))) (EListLit (EApp (EVar "intNode") (EFieldAccess (EVar "g") "mgArity")) (EApp (EApp (EVar "listSExp") (EVar "SAtom")) (EFieldAccess (EVar "g") "mgNames")))))
(DTypeSig false "binderNode" (TyFun (TyCon "BinderRow") (TyCon "SExp")))
(DFunDef false "binderNode" ((PVar "row")) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpBinderId") (EFieldAccess (EVar "row") "brId")) (EApp (EVar "SAtom") (EFieldAccess (EVar "row") "brName")) (EApp (EVar "SAtom") (EApp (EVar "runtimeTypeName") (EFieldAccess (EVar "row") "brType"))) (EApp (EVar "optionList") (EApp (EApp (EVar "map") (ELam ((PVar "t")) (EApp (EVar "SAtom") (EApp (EVar "runtimeTypeName") (EVar "t"))))) (EFieldAccess (EVar "row") "brReturns"))) (EApp (EVar "boolNode") (EFieldAccess (EVar "row") "brSigned")))))
(DTypeSig false "optionList" (TyFun (TyApp (TyCon "Option") (TyCon "SExp")) (TyCon "SExp")))
(DFunDef false "optionList" ((PCon "None")) (EApp (EVar "SList") (EListLit)))
(DFunDef false "optionList" ((PCon "Some" (PVar "x"))) (EApp (EVar "SList") (EListLit (EVar "x"))))
(DTypeSig false "interfaceNode" (TyFun (TyCon "ModuleInterface") (TyCon "SExp")))
(DFunDef false "interfaceNode" ((PCon "ModuleInterface" (PVar "_key") (PVar "_keyText") (PVar "serial") (PVar "row") (PVar "exports") (PVar "funNames") (PVar "dispatchIdx") (PVar "dataCtors") (PVar "ctorPop") (PVar "recordPop") (PVar "funSlots") (PVar "funSlotsQual") (PVar "declared") (PVar "declaredQual") (PVar "methodSlots") (PVar "methodSlotsQual") (PVar "schemeObls") (PVar "existentials") (PVar "patternAuth") (PVar "anyEx") (PVar "evTable") (PVar "binders") (PVar "topIds") (PVar "grants") (PVar "takers") (PVar "sticky") (PVar "view") (PVar "_trees"))) (EApp (EApp (EVar "tagged") (ELit (LString "module-interface"))) (EListLit (EApp (EVar "intNode") (EVar "serial")) (EApp (EVar "modDiagsNode") (EVar "row")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "exportNode"))) (EVar "exports")) (EApp (EApp (EVar "listSExp") (EVar "SAtom")) (EVar "funNames")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EApp (EApp (EVar "pairSExp") (EVar "ifaceRefSExp")) (EVar "SAtom"))) (EVar "intNode"))) (EVar "dispatchIdx")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "tabKeySExp")) (EApp (EApp (EApp (EVar "tripleSExp") (EVar "dataVisSExp")) (EApp (EVar "listSExp") (EVar "SAtom"))) (EApp (EVar "listSExp") (EVar "variantSExp"))))) (EVar "dataCtors")) (EApp (EApp (EVar "spellingPopSExp") (EVar "pubSchemeSExp")) (EVar "ctorPop")) (EApp (EApp (EVar "spellingPopSExp") (EVar "recordInfoSExp")) (EVar "recordPop")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EApp (EVar "listSExp") (EVar "predicateSlotSExp")))) (EVar "funSlots")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "pairAtoms")) (EApp (EVar "listSExp") (EVar "predicateSlotSExp")))) (EVar "funSlotsQual")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "cDeclaredPrefixSExp"))) (EVar "declared")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "pairAtoms")) (EVar "cDeclaredPrefixSExp"))) (EVar "declaredQual")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EApp (EVar "listSExp") (EVar "methodPredicateSlotSExp")))) (EVar "methodSlots")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "pairAtoms")) (EApp (EVar "listSExp") (EVar "methodPredicateSlotSExp")))) (EVar "methodSlotsQual")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "pairAtoms")) (EApp (EVar "listSExp") (EVar "vecOblSExp")))) (EVar "schemeObls")) (EApp (EApp (EVar "listSExp") (EVar "intNode")) (EVar "existentials")) (EApp (EApp (EVar "listSExp") (EVar "intNode")) (EVar "patternAuth")) (EApp (EVar "boolNode") (EVar "anyEx")) (EApp (EVar "evEntriesSExp") (EVar "evTable")) (EApp (EApp (EVar "listSExp") (EVar "binderNode")) (EVar "binders")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EApp (EVar "listSExp") (EVar "intNode")))) (EVar "topIds")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "grantNode"))) (EVar "grants")) (EApp (EApp (EVar "listSExp") (EVar "SAtom")) (EVar "takers")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "diagNode"))) (EVar "sticky")) (EApp (EVar "invocationViewSExp") (EVar "view")))))
(DTypeSig false "sectionLine" (TyFun (TyCon "ModuleSection") (TyCon "String")))
(DFunDef false "sectionLine" ((PVar "s")) (EBinOp "++" (EApp (EVar "renderSExp") (EApp (EApp (EVar "tagged") (ELit (LString "section"))) (EListLit (EApp (EApp (EVar "tagged") (ELit (LString "joins"))) (EListLit (EApp (EApp (EVar "listSExp") (EApp (EVar "listSExp") (EVar "atomSExp"))) (EFieldAccess (EVar "s") "msJoins")))) (EApp (EVar "interfaceNode") (EFieldAccess (EVar "s") "msInterface"))))) (ELit (LString "\n"))))
(DTypeSig true "encodeModuleSections" (TyFun (TyCon "ModuleKey") (TyFun (TyApp (TyCon "List") (TyCon "ModuleSection")) (TyCon "String"))))
(DFunDef false "encodeModuleSections" ((PVar "key") (PVar "sections")) (EIf (EApp (EApp (EVar "any") (ELam ((PVar "s")) (EBinOp "/=" (EFieldAccess (EFieldAccess (EVar "s") "msInterface") "miKeyText") (EApp (EVar "moduleKeyText") (EVar "key"))))) (EVar "sections")) (EApp (EVar "panic") (ELit (LString "module_interface_sexp: a section was recorded under another key"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "framedFile") (EVar "fileTag")) (EVar "moduleFormatVersion")) (EBinOp "++" (EApp (EVar "moduleHeaderFields") (EVar "key")) (EListLit (EApp (EApp (EVar "tagged") (ELit (LString "sections"))) (EListLit (EApp (EVar "intNode") (EApp (EVar "length") (EVar "sections")))))))) (EApp (EApp (EVar "stringJoin") (ELit (LString ""))) (EApp (EApp (EVar "map") (EVar "sectionLine")) (EVar "sections")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "encodeModuleInterface" (TyFun (TyCon "ModuleInterface") (TyCon "String")))
(DFunDef false "encodeModuleInterface" ((PVar "mi")) (EApp (EApp (EVar "encodeModuleSections") (EFieldAccess (EVar "mi") "miKey")) (EListLit (ERecordCreate "ModuleSection" ((fa "msJoins" (EListLit)) (fa "msInterface" (EVar "mi")))))))
(DTypeSig false "decLoc" (TyApp (TyCon "Reader") (TyCon "Loc")))
(DFunDef false "decLoc" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "loc"))) (PVar "f") (PVar "a") (PVar "b") (PVar "c") (PVar "d")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "loc"))) (ELit (LInt 1)))) (EVar "f"))) (ELam ((PVar "file")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "loc"))) (ELit (LInt 2)))) (EVar "a"))) (ELam ((PVar "a1")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "loc"))) (ELit (LInt 3)))) (EVar "b"))) (ELam ((PVar "b1")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "loc"))) (ELit (LInt 4)))) (EVar "c"))) (ELam ((PVar "c1")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "loc"))) (ELit (LInt 5)))) (EVar "d"))) (ELam ((PVar "d1")) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "file")) (EVar "a1")) (EVar "b1")) (EVar "c1")) (EVar "d1"))))))))))))))
(DFunDef false "decLoc" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "loc")) (ELit (LInt 5))))) (EVar "node")))
(DTypeSig false "decDiag" (TyApp (TyCon "Reader") (TyCon "TcDiag")))
(DFunDef false "decDiag" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "tcdiag"))) (PVar "c") (PVar "s") (PVar "l") (PVar "m") (PVar "h") (PVar "f")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "tcdiag"))) (ELit (LInt 1)))) (EVar "c"))) (ELam ((PVar "code")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "tcdiag"))) (ELit (LInt 2)))) (EVar "s"))) (ELam ((PVar "severity")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "optionOfSExp") (EVar "decLoc")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "tcdiag"))) (ELit (LInt 3)))) (EVar "l"))) (ELam ((PVar "loc")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "tcdiag"))) (ELit (LInt 4)))) (EVar "m"))) (ELam ((PVar "message")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "optionOfSExp") (EVar "expectAtom")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "tcdiag"))) (ELit (LInt 5)))) (EVar "h"))) (ELam ((PVar "help")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "optionOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "decLoc")) (EVar "expectAtom"))) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "tcdiag"))) (ELit (LInt 6)))) (EVar "f"))) (ELam ((PVar "fix")) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "code")) (EVar "severity")) (EVar "loc")) (EVar "message")) (EVar "help")) (EVar "fix"))))))))))))))))
(DFunDef false "decDiag" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "tcdiag")) (ELit (LInt 6))))) (EVar "node")))
(DTypeSig false "decModDiags" (TyApp (TyCon "Reader") (TyCon "ModDiags")))
(DFunDef false "decModDiags" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "moddiags"))) (PVar "m") (PVar "ss") (PVar "es") (PVar "ws")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "moddiags"))) (ELit (LInt 1)))) (EVar "m"))) (ELam ((PVar "mid")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "bindingOfSExp"))) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "moddiags"))) (ELit (LInt 2)))) (EVar "ss"))) (ELam ((PVar "schemes")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EVar "decDiag")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "moddiags"))) (ELit (LInt 3)))) (EVar "es"))) (ELam ((PVar "errs")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EVar "decDiag")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "moddiags"))) (ELit (LInt 4)))) (EVar "ws"))) (ELam ((PVar "warns")) (EApp (EVar "Ok") (ETuple (EVar "mid") (ETuple (EVar "schemes") (EVar "errs") (EVar "warns")))))))))))))
(DFunDef false "decModDiags" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "moddiags")) (ELit (LInt 4))))) (EVar "node")))
(DTypeSig false "decExport" (TyApp (TyCon "Reader") (TyCon "FrozenExport")))
(DFunDef false "decExport" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "export"))) (PVar "s") (PVar "alt") (PVar "ext")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "nested") (EVar "pubSchemeOfSExp")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "export"))) (ELit (LInt 1)))) (EVar "s"))) (ELam ((PVar "scheme")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "optionOfSExp") (EApp (EVar "nested") (EVar "pubSchemeOfSExp"))) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "export"))) (ELit (LInt 2)))) (EVar "alt"))) (ELam ((PVar "standalone")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomBool") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "export"))) (ELit (LInt 3)))) (EVar "ext"))) (ELam ((PVar "isExtern")) (EApp (EVar "Ok") (ERecordCreate "FrozenExport" ((fa "feScheme" (EVar "scheme")) (fa "feStandalone" (EVar "standalone")) (fa "feExtern" (EVar "isExtern"))))))))))))
(DFunDef false "decExport" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "export")) (ELit (LInt 3))))) (EVar "node")))
(DTypeSig false "decGrant" (TyApp (TyCon "Reader") (TyCon "MethodGrant")))
(DFunDef false "decGrant" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "grant"))) (PVar "a") (PVar "ns")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "grant"))) (ELit (LInt 1)))) (EVar "a"))) (ELam ((PVar "arity")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EVar "expectAtom")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "grant"))) (ELit (LInt 2)))) (EVar "ns"))) (ELam ((PVar "names")) (EApp (EVar "Ok") (ERecordCreate "MethodGrant" ((fa "mgArity" (EVar "arity")) (fa "mgNames" (EVar "names"))))))))))
(DFunDef false "decGrant" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "grant")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "decBinderId" (TyApp (TyCon "Reader") (TyCon "BinderId")))
(DFunDef false "decBinderId" ((PVar "path") (PCon "SAtom" (PVar "n"))) (EApp (EApp (EVar "map") (EApp (EVar "BinderId") (ELit (LString "")))) (EApp (EApp (EVar "atomInt") (EVar "path")) (EApp (EVar "SAtom") (EVar "n")))))
(DFunDef false "decBinderId" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PVar "m")) (PVar "n")))) (EApp (EApp (EVar "map") (EApp (EVar "BinderId") (EVar "m"))) (EApp (EApp (EVar "atomInt") (EVar "path")) (EVar "n"))))
(DFunDef false "decBinderId" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "expected a binder id"))))
(DTypeSig false "decRuntimeType" (TyApp (TyCon "Reader") (TyCon "RuntimeType")))
(DFunDef false "decRuntimeType" ((PVar "path") (PVar "node")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (EVar "path")) (EVar "node"))) (ELam ((PVar "name")) (EMatch (EApp (EVar "runtimeTypeFromName") (EVar "name")) (arm (PCon "Some" (PVar "t")) () (EApp (EVar "Ok") (EVar "t"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "unknown runtime type"))))))))
(DTypeSig false "decBinder" (TyApp (TyCon "Reader") (TyCon "BinderRow")))
(DFunDef false "decBinder" ((PVar "path") (PCon "SList" (PList (PVar "i") (PVar "n") (PVar "t") (PVar "r") (PVar "s")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decBinderId") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "binder"))) (ELit (LInt 1)))) (EVar "i"))) (ELam ((PVar "bid")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "binder"))) (ELit (LInt 2)))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decRuntimeType") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "binder"))) (ELit (LInt 3)))) (EVar "t"))) (ELam ((PVar "ty")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EVar "decRuntimeType")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "binder"))) (ELit (LInt 4)))) (EVar "r"))) (ELam ((PVar "returns")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomBool") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "binder"))) (ELit (LInt 5)))) (EVar "s"))) (ELam ((PVar "signed")) (EApp (EApp (EVar "andThen") (EMatch (EVar "returns") (arm (PList) () (EApp (EVar "Ok") (EVar "None"))) (arm (PList (PVar "x")) () (EApp (EVar "Ok") (EApp (EVar "Some") (EVar "x")))) (arm PWild () (EApp (EApp (EApp (EVar "refuse") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "binder"))) (ELit (LInt 4)))) (EVar "r")) (ELit (LString "expected at most one type")))))) (ELam ((PVar "returned")) (EApp (EVar "Ok") (ERecordCreate "BinderRow" ((fa "brId" (EVar "bid")) (fa "brName" (EVar "name")) (fa "brType" (EVar "ty")) (fa "brReturns" (EVar "returned")) (fa "brSigned" (EVar "signed"))))))))))))))))))
(DFunDef false "decBinder" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "expected a binder row of five fields"))))
(DTypeSig false "decEvTable" (TyApp (TyCon "Reader") (TyCon "EvTable")))
(DFunDef false "decEvTable" ((PVar "path") (PVar "node")) (EApp (EApp (EVar "mapErr") (ELam ((PVar "e")) (ERecordUpdate (EVar "e") ((fa "sePath" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "/"))) (EApp (EVar "display") (EFieldAccess (EVar "e") "sePath"))) (ELit (LString "")))))))) (EApp (EVar "decodeEvEntries") (EApp (EVar "renderSExp") (EVar "node")))))
(DTypeSig false "decInterface" (TyFun (TyCon "ModuleKey") (TyApp (TyCon "Reader") (TyCon "ModuleInterface"))))
(DFunDef false "decInterface" ((PVar "key") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "module-interface"))) (PVar "n1") (PVar "n2") (PVar "n3") (PVar "n4") (PVar "n5") (PVar "n6") (PVar "n7") (PVar "n8") (PVar "n9") (PVar "n10") (PVar "n11") (PVar "n12") (PVar "n13") (PVar "n14") (PVar "n15") (PVar "n16") (PVar "n17") (PVar "n18") (PVar "n19") (PVar "n20") (PVar "n21") (PVar "n22") (PVar "n23") (PVar "n24") (PVar "n25")))) (ELet false (PVar "p") (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "module-interface"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (EApp (EVar "p") (ELit (LInt 1)))) (EVar "n1"))) (ELam ((PVar "serial")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decModDiags") (EApp (EVar "p") (ELit (LInt 2)))) (EVar "n2"))) (ELam ((PVar "row")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EVar "decExport"))) (EApp (EVar "p") (ELit (LInt 3)))) (EVar "n3"))) (ELam ((PVar "exports")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EVar "expectAtom")) (EApp (EVar "p") (ELit (LInt 4)))) (EVar "n4"))) (ELam ((PVar "funNames")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EApp (EApp (EVar "pairOfSExp") (EApp (EVar "nested") (EVar "ifaceRefOfSExp"))) (EVar "expectAtom"))) (EVar "atomInt"))) (EApp (EVar "p") (ELit (LInt 5)))) (EVar "n5"))) (ELam ((PVar "dispatchIdx")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EApp (EVar "nested") (EVar "tabKeyOfSExp"))) (EApp (EApp (EApp (EVar "tripleOfSExp") (EApp (EVar "nested") (EVar "dataVisOfSExp"))) (EApp (EVar "listOfSExp") (EVar "expectAtom"))) (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "variantOfSExp")))))) (EApp (EVar "p") (ELit (LInt 6)))) (EVar "n6"))) (ELam ((PVar "dataCtors")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "spellingPopOfSExp") (EApp (EVar "nested") (EVar "pubSchemeOfSExp"))) (EApp (EVar "p") (ELit (LInt 7)))) (EVar "n7"))) (ELam ((PVar "ctorPop")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "spellingPopOfSExp") (EApp (EVar "nested") (EVar "recordInfoOfSExp"))) (EApp (EVar "p") (ELit (LInt 8)))) (EVar "n8"))) (ELam ((PVar "recordPop")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "predicateSlotOfSExp"))))) (EApp (EVar "p") (ELit (LInt 9)))) (EVar "n9"))) (ELam ((PVar "funSlots")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "decPairAtoms")) (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "predicateSlotOfSExp"))))) (EApp (EVar "p") (ELit (LInt 10)))) (EVar "n10"))) (ELam ((PVar "funSlotsQual")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EApp (EVar "nested") (EVar "cDeclaredPrefixOfSExp")))) (EApp (EVar "p") (ELit (LInt 11)))) (EVar "n11"))) (ELam ((PVar "declared")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "decPairAtoms")) (EApp (EVar "nested") (EVar "cDeclaredPrefixOfSExp")))) (EApp (EVar "p") (ELit (LInt 12)))) (EVar "n12"))) (ELam ((PVar "declaredQual")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "methodPredicateSlotOfSExp"))))) (EApp (EVar "p") (ELit (LInt 13)))) (EVar "n13"))) (ELam ((PVar "methodSlots")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "decPairAtoms")) (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "methodPredicateSlotOfSExp"))))) (EApp (EVar "p") (ELit (LInt 14)))) (EVar "n14"))) (ELam ((PVar "methodSlotsQual")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "decPairAtoms")) (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "vecOblOfSExp"))))) (EApp (EVar "p") (ELit (LInt 15)))) (EVar "n15"))) (ELam ((PVar "schemeObls")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EVar "atomInt")) (EApp (EVar "p") (ELit (LInt 16)))) (EVar "n16"))) (ELam ((PVar "existentials")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EVar "atomInt")) (EApp (EVar "p") (ELit (LInt 17)))) (EVar "n17"))) (ELam ((PVar "patternAuth")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomBool") (EApp (EVar "p") (ELit (LInt 18)))) (EVar "n18"))) (ELam ((PVar "anyEx")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decEvTable") (EApp (EVar "p") (ELit (LInt 19)))) (EVar "n19"))) (ELam ((PVar "evTable")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EVar "decBinder")) (EApp (EVar "p") (ELit (LInt 20)))) (EVar "n20"))) (ELam ((PVar "binders")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EApp (EVar "listOfSExp") (EVar "atomInt")))) (EApp (EVar "p") (ELit (LInt 21)))) (EVar "n21"))) (ELam ((PVar "topIds")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EVar "decGrant"))) (EApp (EVar "p") (ELit (LInt 22)))) (EVar "n22"))) (ELam ((PVar "grants")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EVar "expectAtom")) (EApp (EVar "p") (ELit (LInt 23)))) (EVar "n23"))) (ELam ((PVar "takers")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EVar "decDiag"))) (EApp (EVar "p") (ELit (LInt 24)))) (EVar "n24"))) (ELam ((PVar "sticky")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "nested") (EVar "invocationViewOfSExp")) (EApp (EVar "p") (ELit (LInt 25)))) (EVar "n25"))) (ELam ((PVar "view")) (EApp (EVar "Ok") (ERecordCreate "ModuleInterface" ((fa "miKey" (EVar "key")) (fa "miKeyText" (EApp (EVar "moduleKeyText") (EVar "key"))) (fa "miSerial" (EVar "serial")) (fa "miRow" (EVar "row")) (fa "miExports" (EVar "exports")) (fa "miFunNames" (EVar "funNames")) (fa "miDispatchIdx" (EVar "dispatchIdx")) (fa "miDataCtors" (EVar "dataCtors")) (fa "miCtorPop" (EVar "ctorPop")) (fa "miRecordPop" (EVar "recordPop")) (fa "miFunSlots" (EVar "funSlots")) (fa "miFunSlotsQual" (EVar "funSlotsQual")) (fa "miDeclared" (EVar "declared")) (fa "miDeclaredQual" (EVar "declaredQual")) (fa "miMethodSlots" (EVar "methodSlots")) (fa "miMethodSlotsQual" (EVar "methodSlotsQual")) (fa "miSchemeOblsQual" (EVar "schemeObls")) (fa "miExistentials" (EVar "existentials")) (fa "miPatternAuth" (EVar "patternAuth")) (fa "miAnyExistentials" (EVar "anyEx")) (fa "miEvTable" (EVar "evTable")) (fa "miBinders" (EVar "binders")) (fa "miTopIds" (EVar "topIds")) (fa "miMethodGrants" (EVar "grants")) (fa "miTakers" (EVar "takers")) (fa "miSticky" (EVar "sticky")) (fa "miInvocationView" (EVar "view")) (fa "miTrees" (EVar "None")))))))))))))))))))))))))))))))))))))))))))))))))))))))))
(DFunDef false "decInterface" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "module-interface")) (ELit (LInt 25))))) (EVar "node")))
(DTypeSig false "decSection" (TyFun (TyCon "ModuleKey") (TyApp (TyCon "Reader") (TyCon "ModuleSection"))))
(DFunDef false "decSection" ((PVar "key") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "section"))) (PVar "js") (PVar "i")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decJoins") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "section"))) (ELit (LInt 1)))) (EVar "js"))) (ELam ((PVar "joins")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decInterface") (EVar "key")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "section"))) (ELit (LInt 2)))) (EVar "i"))) (ELam ((PVar "value")) (EApp (EVar "Ok") (ERecordCreate "ModuleSection" ((fa "msJoins" (EVar "joins")) (fa "msInterface" (EVar "value"))))))))))
(DFunDef false "decSection" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "section")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "readHeaderFields" (TyFun (TyApp (TyCon "List") (TyCon "SExp")) (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "ModuleKey") (TyCon "Int")))))
(DFunDef false "readHeaderFields" ((PList (PCon "SList" (PList (PCon "SAtom" (PLit (LString "module"))) (PVar "m"))) (PCon "SList" (PList (PCon "SAtom" (PLit (LString "source"))) (PVar "s"))) (PCon "SList" (PList (PCon "SAtom" (PLit (LString "imports"))) (PVar "imps"))) (PCon "SList" (PList (PCon "SAtom" (PLit (LString "graph"))) (PVar "g"))) (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sections"))) (PVar "n"))))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (ELit (LString "header/module"))) (EVar "m"))) (ELam ((PVar "modId")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (ELit (LString "header/source"))) (EVar "s"))) (ELam ((PVar "source")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EVar "decPairAtoms")) (ELit (LString "header/imports"))) (EVar "imps"))) (ELam ((PVar "imports")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (ELit (LString "header/graph"))) (EVar "g"))) (ELam ((PVar "graph")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "header/sections"))) (EVar "n"))) (ELam ((PVar "count")) (EApp (EVar "Ok") (ETuple (ERecordCreate "ModuleKey" ((fa "mkModule" (EVar "modId")) (fa "mkSource" (EVar "source")) (fa "mkImports" (EVar "imports")) (fa "mkGraph" (EVar "graph")))) (EVar "count"))))))))))))))
(DFunDef false "readHeaderFields" (PWild) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (ELit (LString "header"))) (fa "seWhat" (ELit (LString "expected the module, source, imports, graph and sections fields")))))))
(DTypeSig true "keyDifference" (TyFun (TyCon "ModuleKey") (TyFun (TyCon "ModuleKey") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "keyDifference" ((PVar "expected") (PVar "k")) (EIf (EBinOp "/=" (EFieldAccess (EVar "k") "mkModule") (EFieldAccess (EVar "expected") "mkModule")) (EApp (EVar "Some") (ELit (LString "module"))) (EIf (EBinOp "/=" (EFieldAccess (EVar "k") "mkSource") (EFieldAccess (EVar "expected") "mkSource")) (EApp (EVar "Some") (ELit (LString "source"))) (EIf (EBinOp "/=" (EFieldAccess (EVar "k") "mkImports") (EFieldAccess (EVar "expected") "mkImports")) (EApp (EVar "Some") (ELit (LString "imports"))) (EIf (EBinOp "/=" (EFieldAccess (EVar "k") "mkGraph") (EFieldAccess (EVar "expected") "mkGraph")) (EApp (EVar "Some") (ELit (LString "graph"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig true "readModuleKey" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "ModuleKey"))))
(DFunDef false "readModuleKey" ((PVar "text")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "openFramed") (EVar "fileTag")) (EVar "moduleFormatVersion")) (ELit (LInt 5))) (EVar "text"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "fields") PWild PWild) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "mapErr") (EVar "Malformed")) (EApp (EVar "readHeaderFields") (EVar "fields")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "key") PWild) () (EApp (EVar "Ok") (EVar "key")))))))))))
(DTypeSig true "decodeModuleSections" (TyFun (TyFun (TyCon "ModuleKey") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "ModuleKey") (TyApp (TyCon "List") (TyCon "ModuleSection")))))))
(DFunDef false "decodeModuleSections" ((PVar "gate") (PVar "text")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "openFramed") (EVar "fileTag")) (EVar "moduleFormatVersion")) (ELit (LInt 5))) (EVar "text"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "fields") (PVar "digest") (PVar "covered")) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "mapErr") (EVar "Malformed")) (EApp (EVar "readHeaderFields") (EVar "fields")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "key") (PVar "count")) () (EApp (EApp (EVar "andThen") (EApp (EVar "stale") (EApp (EVar "gate") (EVar "key")))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "verifyDigest") (EVar "digest")) (EVar "covered"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "mapErr") (EVar "Malformed")) (EApp (EVar "parseSExp") (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "covered")) (ELit (LString ")")))))) (ELam ((PVar "top")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "mapErr") (EVar "Malformed")) (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EVar "decSection") (EVar "key"))) (ELit (LString "file"))) (EVar "top")))) (ELam ((PVar "sections")) (EIf (EBinOp "/=" (EApp (EVar "length") (EVar "sections")) (EVar "count")) (EApp (EVar "Err") (EApp (EVar "Malformed") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (ELit (LString "header/sections.1"))) (fa "seWhat" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "header counts ")) (EApp (EVar "display") (EVar "count"))) (ELit (LString " section(s), the file holds "))) (EApp (EVar "display") (EApp (EVar "length") (EVar "sections")))) (ELit (LString "")))))))) (EApp (EVar "Ok") (ETuple (EVar "key") (EVar "sections")))))))))))))))))))))
(DTypeSig false "stale" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "Unit"))))
(DFunDef false "stale" ((PCon "None")) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "stale" ((PCon "Some" (PVar "component"))) (EApp (EVar "Err") (EApp (EVar "StaleKey") (EVar "component"))))
(DTypeSig true "decodeModuleInterfaceGated" (TyFun (TyFun (TyCon "ModuleKey") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "ModuleInterface")))))
(DFunDef false "decodeModuleInterfaceGated" ((PVar "gate") (PVar "text")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decodeModuleSections") (EVar "gate")) (EVar "text"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple PWild (PVar "sections")) () (EMatch (EVar "sections") (arm (PList (PVar "s")) () (EApp (EVar "Ok") (EFieldAccess (EVar "s") "msInterface"))) (arm PWild () (EApp (EVar "Err") (EApp (EVar "Malformed") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (ELit (LString "header/sections.1"))) (fa "seWhat" (EBinOp "++" (EBinOp "++" (ELit (LString "expected one section, the file holds ")) (EApp (EVar "display") (EApp (EVar "length") (EVar "sections")))) (ELit (LString "")))))))))))))))
(DTypeSig true "decodeModuleInterface" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "ModuleInterface"))))
(DFunDef false "decodeModuleInterface" () (EApp (EVar "decodeModuleInterfaceGated") (ELam (PWild) (EVar "None"))))
(DTypeSig true "decodeModuleInterfaceFor" (TyFun (TyCon "ModuleKey") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "ModuleInterface")))))
(DFunDef false "decodeModuleInterfaceFor" ((PVar "expected")) (EApp (EVar "decodeModuleInterfaceGated") (EApp (EVar "keyDifference") (EVar "expected"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "BinderId" true) (mem "EvTable" false) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "ast_codec") ((mem "decodeEvEntries" false) (mem "evEntriesSExp" false) (mem "sexpBinderId" false))))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SExp" true) (mem "SexpError" true) (mem "atomBool" false) (mem "atomInt" false) (mem "expectAtom" false) (mem "parseSExp" false) (mem "renderSExp" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" false))))
(DUse false (UseGroup ("types" "interface_frame") ((mem "InterfaceFault" true) (mem "framedFile" false) (mem "openFramed" false) (mem "verifyDigest" false))))
(DUse false (UseGroup ("types" "interface_sexp") ((mem "Reader" false) (mem "at" false) (mem "atomSExp" false) (mem "decJoins" false) (mem "decPairAtoms" false) (mem "pairAtoms" false) (mem "boolNode" false) (mem "bindingOfSExp" false) (mem "bindingSExp" false) (mem "cDeclaredPrefixOfSExp" false) (mem "cDeclaredPrefixSExp" false) (mem "dataVisOfSExp" false) (mem "dataVisSExp" false) (mem "ifaceRefOfSExp" false) (mem "ifaceRefSExp" false) (mem "intNode" false) (mem "listOfSExp" false) (mem "listSExp" false) (mem "methodPredicateSlotOfSExp" false) (mem "methodPredicateSlotSExp" false) (mem "misfit" false) (mem "nested" false) (mem "optionOfSExp" false) (mem "optionSExp" false) (mem "pairOfSExp" false) (mem "pairSExp" false) (mem "predicateSlotOfSExp" false) (mem "predicateSlotSExp" false) (mem "pubSchemeOfSExp" false) (mem "pubSchemeSExp" false) (mem "recordInfoOfSExp" false) (mem "recordInfoSExp" false) (mem "refuse" false) (mem "spellingPopOfSExp" false) (mem "spellingPopSExp" false) (mem "tabKeyOfSExp" false) (mem "tabKeySExp" false) (mem "tagged" false) (mem "tripleOfSExp" false) (mem "tripleSExp" false) (mem "variantOfSExp" false) (mem "variantSExp" false) (mem "vecOblOfSExp" false) (mem "vecOblSExp" false) (mem "invocationViewSExp" false) (mem "invocationViewOfSExp" false))))
(DUse false (UseGroup ("types" "module_interface") ((mem "FrozenExport" true) (mem "ModuleInterface" true) (mem "ModuleKey" true) (mem "moduleKeyText" false))))
(DUse false (UseGroup ("types" "publish") ((mem "ModDiags" false) (mem "TcDiag" true))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderRow" true) (mem "RuntimeType" false) (mem "runtimeTypeFromName" false) (mem "runtimeTypeName" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "MethodGrant" true))))
(DData Public "ModuleSection" () ((variant "ModuleSection" (ConNamed (field "msJoins" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom")))) (field "msInterface" (TyCon "ModuleInterface"))))) ())
(DTypeSig true "moduleFormatVersion" (TyCon "Int"))
(DFunDef false "moduleFormatVersion" () (ELit (LInt 2)))
(DTypeSig false "fileTag" (TyCon "String"))
(DFunDef false "fileTag" () (ELit (LString "medaka-module")))
(DTypeSig false "moduleHeaderFields" (TyFun (TyCon "ModuleKey") (TyApp (TyCon "List") (TyCon "SExp"))))
(DFunDef false "moduleHeaderFields" ((PVar "k")) (EListLit (EApp (EApp (EVar "tagged") (ELit (LString "module"))) (EListLit (EApp (EVar "SAtom") (EFieldAccess (EVar "k") "mkModule")))) (EApp (EApp (EVar "tagged") (ELit (LString "source"))) (EListLit (EApp (EVar "SAtom") (EFieldAccess (EVar "k") "mkSource")))) (EApp (EApp (EVar "tagged") (ELit (LString "imports"))) (EListLit (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "SAtom"))) (EFieldAccess (EVar "k") "mkImports")))) (EApp (EApp (EVar "tagged") (ELit (LString "graph"))) (EListLit (EApp (EVar "SAtom") (EFieldAccess (EVar "k") "mkGraph"))))))
(DTypeSig false "locNode" (TyFun (TyCon "Loc") (TyCon "SExp")))
(DFunDef false "locNode" ((PCon "Loc" (PVar "file") (PVar "a") (PVar "b") (PVar "c") (PVar "d"))) (EApp (EApp (EVar "tagged") (ELit (LString "loc"))) (EListLit (EApp (EVar "SAtom") (EVar "file")) (EApp (EVar "intNode") (EVar "a")) (EApp (EVar "intNode") (EVar "b")) (EApp (EVar "intNode") (EVar "c")) (EApp (EVar "intNode") (EVar "d")))))
(DTypeSig false "diagNode" (TyFun (TyCon "TcDiag") (TyCon "SExp")))
(DFunDef false "diagNode" ((PCon "TcDiag" (PVar "code") (PVar "severity") (PVar "loc") (PVar "message") (PVar "help") (PVar "fix"))) (EApp (EApp (EVar "tagged") (ELit (LString "tcdiag"))) (EListLit (EApp (EVar "SAtom") (EVar "code")) (EApp (EVar "intNode") (EVar "severity")) (EApp (EApp (EVar "optionSExp") (EVar "locNode")) (EVar "loc")) (EApp (EVar "SAtom") (EVar "message")) (EApp (EApp (EVar "optionSExp") (EVar "SAtom")) (EVar "help")) (EApp (EApp (EVar "optionSExp") (EApp (EApp (EVar "pairSExp") (EVar "locNode")) (EVar "SAtom"))) (EVar "fix")))))
(DTypeSig false "modDiagsNode" (TyFun (TyCon "ModDiags") (TyCon "SExp")))
(DFunDef false "modDiagsNode" ((PTuple (PVar "mid") (PTuple (PVar "schemes") (PVar "errs") (PVar "warns")))) (EApp (EApp (EVar "tagged") (ELit (LString "moddiags"))) (EListLit (EApp (EVar "SAtom") (EVar "mid")) (EApp (EApp (EVar "listSExp") (ELam ((PVar "b")) (EApp (EApp (EVar "bindingSExp") (EApp (EVar "fst") (EVar "b"))) (EApp (EVar "snd") (EVar "b"))))) (EVar "schemes")) (EApp (EApp (EVar "listSExp") (EVar "diagNode")) (EVar "errs")) (EApp (EApp (EVar "listSExp") (EVar "diagNode")) (EVar "warns")))))
(DTypeSig false "exportNode" (TyFun (TyCon "FrozenExport") (TyCon "SExp")))
(DFunDef false "exportNode" ((PVar "fe")) (EApp (EApp (EVar "tagged") (ELit (LString "export"))) (EListLit (EApp (EVar "pubSchemeSExp") (EFieldAccess (EVar "fe") "feScheme")) (EApp (EApp (EVar "optionSExp") (EVar "pubSchemeSExp")) (EFieldAccess (EVar "fe") "feStandalone")) (EApp (EVar "boolNode") (EFieldAccess (EVar "fe") "feExtern")))))
(DTypeSig false "grantNode" (TyFun (TyCon "MethodGrant") (TyCon "SExp")))
(DFunDef false "grantNode" ((PVar "g")) (EApp (EApp (EVar "tagged") (ELit (LString "grant"))) (EListLit (EApp (EVar "intNode") (EFieldAccess (EVar "g") "mgArity")) (EApp (EApp (EVar "listSExp") (EVar "SAtom")) (EFieldAccess (EVar "g") "mgNames")))))
(DTypeSig false "binderNode" (TyFun (TyCon "BinderRow") (TyCon "SExp")))
(DFunDef false "binderNode" ((PVar "row")) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpBinderId") (EFieldAccess (EVar "row") "brId")) (EApp (EVar "SAtom") (EFieldAccess (EVar "row") "brName")) (EApp (EVar "SAtom") (EApp (EVar "runtimeTypeName") (EFieldAccess (EVar "row") "brType"))) (EApp (EVar "optionList") (EApp (EApp (EMethodRef "map") (ELam ((PVar "t")) (EApp (EVar "SAtom") (EApp (EVar "runtimeTypeName") (EVar "t"))))) (EFieldAccess (EVar "row") "brReturns"))) (EApp (EVar "boolNode") (EFieldAccess (EVar "row") "brSigned")))))
(DTypeSig false "optionList" (TyFun (TyApp (TyCon "Option") (TyCon "SExp")) (TyCon "SExp")))
(DFunDef false "optionList" ((PCon "None")) (EApp (EVar "SList") (EListLit)))
(DFunDef false "optionList" ((PCon "Some" (PVar "x"))) (EApp (EVar "SList") (EListLit (EVar "x"))))
(DTypeSig false "interfaceNode" (TyFun (TyCon "ModuleInterface") (TyCon "SExp")))
(DFunDef false "interfaceNode" ((PCon "ModuleInterface" (PVar "_key") (PVar "_keyText") (PVar "serial") (PVar "row") (PVar "exports") (PVar "funNames") (PVar "dispatchIdx") (PVar "dataCtors") (PVar "ctorPop") (PVar "recordPop") (PVar "funSlots") (PVar "funSlotsQual") (PVar "declared") (PVar "declaredQual") (PVar "methodSlots") (PVar "methodSlotsQual") (PVar "schemeObls") (PVar "existentials") (PVar "patternAuth") (PVar "anyEx") (PVar "evTable") (PVar "binders") (PVar "topIds") (PVar "grants") (PVar "takers") (PVar "sticky") (PVar "view") (PVar "_trees"))) (EApp (EApp (EVar "tagged") (ELit (LString "module-interface"))) (EListLit (EApp (EVar "intNode") (EVar "serial")) (EApp (EVar "modDiagsNode") (EVar "row")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "exportNode"))) (EVar "exports")) (EApp (EApp (EVar "listSExp") (EVar "SAtom")) (EVar "funNames")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EApp (EApp (EVar "pairSExp") (EVar "ifaceRefSExp")) (EVar "SAtom"))) (EVar "intNode"))) (EVar "dispatchIdx")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "tabKeySExp")) (EApp (EApp (EApp (EVar "tripleSExp") (EVar "dataVisSExp")) (EApp (EVar "listSExp") (EVar "SAtom"))) (EApp (EVar "listSExp") (EVar "variantSExp"))))) (EVar "dataCtors")) (EApp (EApp (EVar "spellingPopSExp") (EVar "pubSchemeSExp")) (EVar "ctorPop")) (EApp (EApp (EVar "spellingPopSExp") (EVar "recordInfoSExp")) (EVar "recordPop")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EApp (EVar "listSExp") (EVar "predicateSlotSExp")))) (EVar "funSlots")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "pairAtoms")) (EApp (EVar "listSExp") (EVar "predicateSlotSExp")))) (EVar "funSlotsQual")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "cDeclaredPrefixSExp"))) (EVar "declared")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "pairAtoms")) (EVar "cDeclaredPrefixSExp"))) (EVar "declaredQual")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EApp (EVar "listSExp") (EVar "methodPredicateSlotSExp")))) (EVar "methodSlots")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "pairAtoms")) (EApp (EVar "listSExp") (EVar "methodPredicateSlotSExp")))) (EVar "methodSlotsQual")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "pairAtoms")) (EApp (EVar "listSExp") (EVar "vecOblSExp")))) (EVar "schemeObls")) (EApp (EApp (EVar "listSExp") (EVar "intNode")) (EVar "existentials")) (EApp (EApp (EVar "listSExp") (EVar "intNode")) (EVar "patternAuth")) (EApp (EVar "boolNode") (EVar "anyEx")) (EApp (EVar "evEntriesSExp") (EVar "evTable")) (EApp (EApp (EVar "listSExp") (EVar "binderNode")) (EVar "binders")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EApp (EVar "listSExp") (EVar "intNode")))) (EVar "topIds")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "grantNode"))) (EVar "grants")) (EApp (EApp (EVar "listSExp") (EVar "SAtom")) (EVar "takers")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "diagNode"))) (EVar "sticky")) (EApp (EVar "invocationViewSExp") (EVar "view")))))
(DTypeSig false "sectionLine" (TyFun (TyCon "ModuleSection") (TyCon "String")))
(DFunDef false "sectionLine" ((PVar "s")) (EBinOp "++" (EApp (EVar "renderSExp") (EApp (EApp (EVar "tagged") (ELit (LString "section"))) (EListLit (EApp (EApp (EVar "tagged") (ELit (LString "joins"))) (EListLit (EApp (EApp (EVar "listSExp") (EApp (EVar "listSExp") (EVar "atomSExp"))) (EFieldAccess (EVar "s") "msJoins")))) (EApp (EVar "interfaceNode") (EFieldAccess (EVar "s") "msInterface"))))) (ELit (LString "\n"))))
(DTypeSig true "encodeModuleSections" (TyFun (TyCon "ModuleKey") (TyFun (TyApp (TyCon "List") (TyCon "ModuleSection")) (TyCon "String"))))
(DFunDef false "encodeModuleSections" ((PVar "key") (PVar "sections")) (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "s")) (EBinOp "/=" (EFieldAccess (EFieldAccess (EVar "s") "msInterface") "miKeyText") (EApp (EVar "moduleKeyText") (EVar "key"))))) (EVar "sections")) (EApp (EVar "panic") (ELit (LString "module_interface_sexp: a section was recorded under another key"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "framedFile") (EVar "fileTag")) (EVar "moduleFormatVersion")) (EBinOp "++" (EApp (EVar "moduleHeaderFields") (EVar "key")) (EListLit (EApp (EApp (EVar "tagged") (ELit (LString "sections"))) (EListLit (EApp (EVar "intNode") (EApp (EMethodRef "length") (EVar "sections")))))))) (EApp (EApp (EVar "stringJoin") (ELit (LString ""))) (EApp (EApp (EMethodRef "map") (EVar "sectionLine")) (EVar "sections")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "encodeModuleInterface" (TyFun (TyCon "ModuleInterface") (TyCon "String")))
(DFunDef false "encodeModuleInterface" ((PVar "mi")) (EApp (EApp (EVar "encodeModuleSections") (EFieldAccess (EVar "mi") "miKey")) (EListLit (ERecordCreate "ModuleSection" ((fa "msJoins" (EListLit)) (fa "msInterface" (EVar "mi")))))))
(DTypeSig false "decLoc" (TyApp (TyCon "Reader") (TyCon "Loc")))
(DFunDef false "decLoc" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "loc"))) (PVar "f") (PVar "a") (PVar "b") (PVar "c") (PVar "d")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "loc"))) (ELit (LInt 1)))) (EVar "f"))) (ELam ((PVar "file")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "loc"))) (ELit (LInt 2)))) (EVar "a"))) (ELam ((PVar "a1")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "loc"))) (ELit (LInt 3)))) (EVar "b"))) (ELam ((PVar "b1")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "loc"))) (ELit (LInt 4)))) (EVar "c"))) (ELam ((PVar "c1")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "loc"))) (ELit (LInt 5)))) (EVar "d"))) (ELam ((PVar "d1")) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "file")) (EVar "a1")) (EVar "b1")) (EVar "c1")) (EVar "d1"))))))))))))))
(DFunDef false "decLoc" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "loc")) (ELit (LInt 5))))) (EVar "node")))
(DTypeSig false "decDiag" (TyApp (TyCon "Reader") (TyCon "TcDiag")))
(DFunDef false "decDiag" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "tcdiag"))) (PVar "c") (PVar "s") (PVar "l") (PVar "m") (PVar "h") (PVar "f")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "tcdiag"))) (ELit (LInt 1)))) (EVar "c"))) (ELam ((PVar "code")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "tcdiag"))) (ELit (LInt 2)))) (EVar "s"))) (ELam ((PVar "severity")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "optionOfSExp") (EVar "decLoc")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "tcdiag"))) (ELit (LInt 3)))) (EVar "l"))) (ELam ((PVar "loc")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "tcdiag"))) (ELit (LInt 4)))) (EVar "m"))) (ELam ((PVar "message")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "optionOfSExp") (EVar "expectAtom")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "tcdiag"))) (ELit (LInt 5)))) (EVar "h"))) (ELam ((PVar "help")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "optionOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "decLoc")) (EVar "expectAtom"))) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "tcdiag"))) (ELit (LInt 6)))) (EVar "f"))) (ELam ((PVar "fix")) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "code")) (EVar "severity")) (EVar "loc")) (EVar "message")) (EVar "help")) (EVar "fix"))))))))))))))))
(DFunDef false "decDiag" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "tcdiag")) (ELit (LInt 6))))) (EVar "node")))
(DTypeSig false "decModDiags" (TyApp (TyCon "Reader") (TyCon "ModDiags")))
(DFunDef false "decModDiags" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "moddiags"))) (PVar "m") (PVar "ss") (PVar "es") (PVar "ws")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "moddiags"))) (ELit (LInt 1)))) (EVar "m"))) (ELam ((PVar "mid")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "bindingOfSExp"))) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "moddiags"))) (ELit (LInt 2)))) (EVar "ss"))) (ELam ((PVar "schemes")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EVar "decDiag")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "moddiags"))) (ELit (LInt 3)))) (EVar "es"))) (ELam ((PVar "errs")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EVar "decDiag")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "moddiags"))) (ELit (LInt 4)))) (EVar "ws"))) (ELam ((PVar "warns")) (EApp (EVar "Ok") (ETuple (EVar "mid") (ETuple (EVar "schemes") (EVar "errs") (EVar "warns")))))))))))))
(DFunDef false "decModDiags" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "moddiags")) (ELit (LInt 4))))) (EVar "node")))
(DTypeSig false "decExport" (TyApp (TyCon "Reader") (TyCon "FrozenExport")))
(DFunDef false "decExport" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "export"))) (PVar "s") (PVar "alt") (PVar "ext")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "nested") (EVar "pubSchemeOfSExp")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "export"))) (ELit (LInt 1)))) (EVar "s"))) (ELam ((PVar "scheme")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "optionOfSExp") (EApp (EVar "nested") (EVar "pubSchemeOfSExp"))) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "export"))) (ELit (LInt 2)))) (EVar "alt"))) (ELam ((PVar "standalone")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomBool") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "export"))) (ELit (LInt 3)))) (EVar "ext"))) (ELam ((PVar "isExtern")) (EApp (EVar "Ok") (ERecordCreate "FrozenExport" ((fa "feScheme" (EVar "scheme")) (fa "feStandalone" (EVar "standalone")) (fa "feExtern" (EVar "isExtern"))))))))))))
(DFunDef false "decExport" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "export")) (ELit (LInt 3))))) (EVar "node")))
(DTypeSig false "decGrant" (TyApp (TyCon "Reader") (TyCon "MethodGrant")))
(DFunDef false "decGrant" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "grant"))) (PVar "a") (PVar "ns")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "grant"))) (ELit (LInt 1)))) (EVar "a"))) (ELam ((PVar "arity")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EVar "expectAtom")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "grant"))) (ELit (LInt 2)))) (EVar "ns"))) (ELam ((PVar "names")) (EApp (EVar "Ok") (ERecordCreate "MethodGrant" ((fa "mgArity" (EVar "arity")) (fa "mgNames" (EVar "names"))))))))))
(DFunDef false "decGrant" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "grant")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "decBinderId" (TyApp (TyCon "Reader") (TyCon "BinderId")))
(DFunDef false "decBinderId" ((PVar "path") (PCon "SAtom" (PVar "n"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "BinderId") (ELit (LString "")))) (EApp (EApp (EVar "atomInt") (EVar "path")) (EApp (EVar "SAtom") (EVar "n")))))
(DFunDef false "decBinderId" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PVar "m")) (PVar "n")))) (EApp (EApp (EMethodRef "map") (EApp (EVar "BinderId") (EVar "m"))) (EApp (EApp (EVar "atomInt") (EVar "path")) (EVar "n"))))
(DFunDef false "decBinderId" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "expected a binder id"))))
(DTypeSig false "decRuntimeType" (TyApp (TyCon "Reader") (TyCon "RuntimeType")))
(DFunDef false "decRuntimeType" ((PVar "path") (PVar "node")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (EVar "path")) (EVar "node"))) (ELam ((PVar "name")) (EMatch (EApp (EVar "runtimeTypeFromName") (EVar "name")) (arm (PCon "Some" (PVar "t")) () (EApp (EVar "Ok") (EVar "t"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "unknown runtime type"))))))))
(DTypeSig false "decBinder" (TyApp (TyCon "Reader") (TyCon "BinderRow")))
(DFunDef false "decBinder" ((PVar "path") (PCon "SList" (PList (PVar "i") (PVar "n") (PVar "t") (PVar "r") (PVar "s")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decBinderId") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "binder"))) (ELit (LInt 1)))) (EVar "i"))) (ELam ((PVar "bid")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "binder"))) (ELit (LInt 2)))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decRuntimeType") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "binder"))) (ELit (LInt 3)))) (EVar "t"))) (ELam ((PVar "ty")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EVar "decRuntimeType")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "binder"))) (ELit (LInt 4)))) (EVar "r"))) (ELam ((PVar "returns")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomBool") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "binder"))) (ELit (LInt 5)))) (EVar "s"))) (ELam ((PVar "signed")) (EApp (EApp (EMethodRef "andThen") (EMatch (EVar "returns") (arm (PList) () (EApp (EVar "Ok") (EVar "None"))) (arm (PList (PVar "x")) () (EApp (EVar "Ok") (EApp (EVar "Some") (EVar "x")))) (arm PWild () (EApp (EApp (EApp (EVar "refuse") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "binder"))) (ELit (LInt 4)))) (EVar "r")) (ELit (LString "expected at most one type")))))) (ELam ((PVar "returned")) (EApp (EVar "Ok") (ERecordCreate "BinderRow" ((fa "brId" (EVar "bid")) (fa "brName" (EVar "name")) (fa "brType" (EVar "ty")) (fa "brReturns" (EVar "returned")) (fa "brSigned" (EVar "signed"))))))))))))))))))
(DFunDef false "decBinder" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "expected a binder row of five fields"))))
(DTypeSig false "decEvTable" (TyApp (TyCon "Reader") (TyCon "EvTable")))
(DFunDef false "decEvTable" ((PVar "path") (PVar "node")) (EApp (EApp (EVar "mapErr") (ELam ((PVar "e")) (ERecordUpdate (EVar "e") ((fa "sePath" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "e") "sePath"))) (ELit (LString "")))))))) (EApp (EVar "decodeEvEntries") (EApp (EVar "renderSExp") (EVar "node")))))
(DTypeSig false "decInterface" (TyFun (TyCon "ModuleKey") (TyApp (TyCon "Reader") (TyCon "ModuleInterface"))))
(DFunDef false "decInterface" ((PVar "key") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "module-interface"))) (PVar "n1") (PVar "n2") (PVar "n3") (PVar "n4") (PVar "n5") (PVar "n6") (PVar "n7") (PVar "n8") (PVar "n9") (PVar "n10") (PVar "n11") (PVar "n12") (PVar "n13") (PVar "n14") (PVar "n15") (PVar "n16") (PVar "n17") (PVar "n18") (PVar "n19") (PVar "n20") (PVar "n21") (PVar "n22") (PVar "n23") (PVar "n24") (PVar "n25")))) (ELet false (PVar "p") (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "module-interface"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (EApp (EVar "p") (ELit (LInt 1)))) (EVar "n1"))) (ELam ((PVar "serial")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decModDiags") (EApp (EVar "p") (ELit (LInt 2)))) (EVar "n2"))) (ELam ((PVar "row")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EVar "decExport"))) (EApp (EVar "p") (ELit (LInt 3)))) (EVar "n3"))) (ELam ((PVar "exports")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EVar "expectAtom")) (EApp (EVar "p") (ELit (LInt 4)))) (EVar "n4"))) (ELam ((PVar "funNames")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EApp (EApp (EVar "pairOfSExp") (EApp (EVar "nested") (EVar "ifaceRefOfSExp"))) (EVar "expectAtom"))) (EVar "atomInt"))) (EApp (EVar "p") (ELit (LInt 5)))) (EVar "n5"))) (ELam ((PVar "dispatchIdx")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EApp (EVar "nested") (EVar "tabKeyOfSExp"))) (EApp (EApp (EApp (EVar "tripleOfSExp") (EApp (EVar "nested") (EVar "dataVisOfSExp"))) (EApp (EVar "listOfSExp") (EVar "expectAtom"))) (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "variantOfSExp")))))) (EApp (EVar "p") (ELit (LInt 6)))) (EVar "n6"))) (ELam ((PVar "dataCtors")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "spellingPopOfSExp") (EApp (EVar "nested") (EVar "pubSchemeOfSExp"))) (EApp (EVar "p") (ELit (LInt 7)))) (EVar "n7"))) (ELam ((PVar "ctorPop")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "spellingPopOfSExp") (EApp (EVar "nested") (EVar "recordInfoOfSExp"))) (EApp (EVar "p") (ELit (LInt 8)))) (EVar "n8"))) (ELam ((PVar "recordPop")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "predicateSlotOfSExp"))))) (EApp (EVar "p") (ELit (LInt 9)))) (EVar "n9"))) (ELam ((PVar "funSlots")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "decPairAtoms")) (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "predicateSlotOfSExp"))))) (EApp (EVar "p") (ELit (LInt 10)))) (EVar "n10"))) (ELam ((PVar "funSlotsQual")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EApp (EVar "nested") (EVar "cDeclaredPrefixOfSExp")))) (EApp (EVar "p") (ELit (LInt 11)))) (EVar "n11"))) (ELam ((PVar "declared")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "decPairAtoms")) (EApp (EVar "nested") (EVar "cDeclaredPrefixOfSExp")))) (EApp (EVar "p") (ELit (LInt 12)))) (EVar "n12"))) (ELam ((PVar "declaredQual")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "methodPredicateSlotOfSExp"))))) (EApp (EVar "p") (ELit (LInt 13)))) (EVar "n13"))) (ELam ((PVar "methodSlots")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "decPairAtoms")) (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "methodPredicateSlotOfSExp"))))) (EApp (EVar "p") (ELit (LInt 14)))) (EVar "n14"))) (ELam ((PVar "methodSlotsQual")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "decPairAtoms")) (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "vecOblOfSExp"))))) (EApp (EVar "p") (ELit (LInt 15)))) (EVar "n15"))) (ELam ((PVar "schemeObls")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EVar "atomInt")) (EApp (EVar "p") (ELit (LInt 16)))) (EVar "n16"))) (ELam ((PVar "existentials")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EVar "atomInt")) (EApp (EVar "p") (ELit (LInt 17)))) (EVar "n17"))) (ELam ((PVar "patternAuth")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomBool") (EApp (EVar "p") (ELit (LInt 18)))) (EVar "n18"))) (ELam ((PVar "anyEx")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decEvTable") (EApp (EVar "p") (ELit (LInt 19)))) (EVar "n19"))) (ELam ((PVar "evTable")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EVar "decBinder")) (EApp (EVar "p") (ELit (LInt 20)))) (EVar "n20"))) (ELam ((PVar "binders")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EApp (EVar "listOfSExp") (EVar "atomInt")))) (EApp (EVar "p") (ELit (LInt 21)))) (EVar "n21"))) (ELam ((PVar "topIds")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EVar "decGrant"))) (EApp (EVar "p") (ELit (LInt 22)))) (EVar "n22"))) (ELam ((PVar "grants")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EVar "expectAtom")) (EApp (EVar "p") (ELit (LInt 23)))) (EVar "n23"))) (ELam ((PVar "takers")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EVar "decDiag"))) (EApp (EVar "p") (ELit (LInt 24)))) (EVar "n24"))) (ELam ((PVar "sticky")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "nested") (EVar "invocationViewOfSExp")) (EApp (EVar "p") (ELit (LInt 25)))) (EVar "n25"))) (ELam ((PVar "view")) (EApp (EVar "Ok") (ERecordCreate "ModuleInterface" ((fa "miKey" (EVar "key")) (fa "miKeyText" (EApp (EVar "moduleKeyText") (EVar "key"))) (fa "miSerial" (EVar "serial")) (fa "miRow" (EVar "row")) (fa "miExports" (EVar "exports")) (fa "miFunNames" (EVar "funNames")) (fa "miDispatchIdx" (EVar "dispatchIdx")) (fa "miDataCtors" (EVar "dataCtors")) (fa "miCtorPop" (EVar "ctorPop")) (fa "miRecordPop" (EVar "recordPop")) (fa "miFunSlots" (EVar "funSlots")) (fa "miFunSlotsQual" (EVar "funSlotsQual")) (fa "miDeclared" (EVar "declared")) (fa "miDeclaredQual" (EVar "declaredQual")) (fa "miMethodSlots" (EVar "methodSlots")) (fa "miMethodSlotsQual" (EVar "methodSlotsQual")) (fa "miSchemeOblsQual" (EVar "schemeObls")) (fa "miExistentials" (EVar "existentials")) (fa "miPatternAuth" (EVar "patternAuth")) (fa "miAnyExistentials" (EVar "anyEx")) (fa "miEvTable" (EVar "evTable")) (fa "miBinders" (EVar "binders")) (fa "miTopIds" (EVar "topIds")) (fa "miMethodGrants" (EVar "grants")) (fa "miTakers" (EVar "takers")) (fa "miSticky" (EVar "sticky")) (fa "miInvocationView" (EVar "view")) (fa "miTrees" (EVar "None")))))))))))))))))))))))))))))))))))))))))))))))))))))))))
(DFunDef false "decInterface" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "module-interface")) (ELit (LInt 25))))) (EVar "node")))
(DTypeSig false "decSection" (TyFun (TyCon "ModuleKey") (TyApp (TyCon "Reader") (TyCon "ModuleSection"))))
(DFunDef false "decSection" ((PVar "key") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "section"))) (PVar "js") (PVar "i")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decJoins") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "section"))) (ELit (LInt 1)))) (EVar "js"))) (ELam ((PVar "joins")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decInterface") (EVar "key")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "section"))) (ELit (LInt 2)))) (EVar "i"))) (ELam ((PVar "value")) (EApp (EVar "Ok") (ERecordCreate "ModuleSection" ((fa "msJoins" (EVar "joins")) (fa "msInterface" (EVar "value"))))))))))
(DFunDef false "decSection" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "section")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "readHeaderFields" (TyFun (TyApp (TyCon "List") (TyCon "SExp")) (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "ModuleKey") (TyCon "Int")))))
(DFunDef false "readHeaderFields" ((PList (PCon "SList" (PList (PCon "SAtom" (PLit (LString "module"))) (PVar "m"))) (PCon "SList" (PList (PCon "SAtom" (PLit (LString "source"))) (PVar "s"))) (PCon "SList" (PList (PCon "SAtom" (PLit (LString "imports"))) (PVar "imps"))) (PCon "SList" (PList (PCon "SAtom" (PLit (LString "graph"))) (PVar "g"))) (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sections"))) (PVar "n"))))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (ELit (LString "header/module"))) (EVar "m"))) (ELam ((PVar "modId")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (ELit (LString "header/source"))) (EVar "s"))) (ELam ((PVar "source")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EVar "decPairAtoms")) (ELit (LString "header/imports"))) (EVar "imps"))) (ELam ((PVar "imports")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (ELit (LString "header/graph"))) (EVar "g"))) (ELam ((PVar "graph")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "header/sections"))) (EVar "n"))) (ELam ((PVar "count")) (EApp (EVar "Ok") (ETuple (ERecordCreate "ModuleKey" ((fa "mkModule" (EVar "modId")) (fa "mkSource" (EVar "source")) (fa "mkImports" (EVar "imports")) (fa "mkGraph" (EVar "graph")))) (EDictApp "count"))))))))))))))
(DFunDef false "readHeaderFields" (PWild) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (ELit (LString "header"))) (fa "seWhat" (ELit (LString "expected the module, source, imports, graph and sections fields")))))))
(DTypeSig true "keyDifference" (TyFun (TyCon "ModuleKey") (TyFun (TyCon "ModuleKey") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "keyDifference" ((PVar "expected") (PVar "k")) (EIf (EBinOp "/=" (EFieldAccess (EVar "k") "mkModule") (EFieldAccess (EVar "expected") "mkModule")) (EApp (EVar "Some") (ELit (LString "module"))) (EIf (EBinOp "/=" (EFieldAccess (EVar "k") "mkSource") (EFieldAccess (EVar "expected") "mkSource")) (EApp (EVar "Some") (ELit (LString "source"))) (EIf (EBinOp "/=" (EFieldAccess (EVar "k") "mkImports") (EFieldAccess (EVar "expected") "mkImports")) (EApp (EVar "Some") (ELit (LString "imports"))) (EIf (EBinOp "/=" (EFieldAccess (EVar "k") "mkGraph") (EFieldAccess (EVar "expected") "mkGraph")) (EApp (EVar "Some") (ELit (LString "graph"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig true "readModuleKey" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "ModuleKey"))))
(DFunDef false "readModuleKey" ((PVar "text")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "openFramed") (EVar "fileTag")) (EVar "moduleFormatVersion")) (ELit (LInt 5))) (EVar "text"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "fields") PWild PWild) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "mapErr") (EVar "Malformed")) (EApp (EVar "readHeaderFields") (EVar "fields")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "key") PWild) () (EApp (EVar "Ok") (EVar "key")))))))))))
(DTypeSig true "decodeModuleSections" (TyFun (TyFun (TyCon "ModuleKey") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "ModuleKey") (TyApp (TyCon "List") (TyCon "ModuleSection")))))))
(DFunDef false "decodeModuleSections" ((PVar "gate") (PVar "text")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "openFramed") (EVar "fileTag")) (EVar "moduleFormatVersion")) (ELit (LInt 5))) (EVar "text"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "fields") (PVar "digest") (PVar "covered")) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "mapErr") (EVar "Malformed")) (EApp (EVar "readHeaderFields") (EVar "fields")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "key") (PVar "count")) () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "stale") (EApp (EVar "gate") (EVar "key")))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "verifyDigest") (EVar "digest")) (EVar "covered"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "mapErr") (EVar "Malformed")) (EApp (EVar "parseSExp") (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "covered")) (ELit (LString ")")))))) (ELam ((PVar "top")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "mapErr") (EVar "Malformed")) (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EVar "decSection") (EVar "key"))) (ELit (LString "file"))) (EVar "top")))) (ELam ((PVar "sections")) (EIf (EBinOp "/=" (EApp (EMethodRef "length") (EVar "sections")) (EDictApp "count")) (EApp (EVar "Err") (EApp (EVar "Malformed") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (ELit (LString "header/sections.1"))) (fa "seWhat" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "header counts ")) (EApp (EMethodRef "display") (EDictApp "count"))) (ELit (LString " section(s), the file holds "))) (EApp (EMethodRef "display") (EApp (EMethodRef "length") (EVar "sections")))) (ELit (LString "")))))))) (EApp (EVar "Ok") (ETuple (EVar "key") (EVar "sections")))))))))))))))))))))
(DTypeSig false "stale" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "Unit"))))
(DFunDef false "stale" ((PCon "None")) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "stale" ((PCon "Some" (PVar "component"))) (EApp (EVar "Err") (EApp (EVar "StaleKey") (EVar "component"))))
(DTypeSig true "decodeModuleInterfaceGated" (TyFun (TyFun (TyCon "ModuleKey") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "ModuleInterface")))))
(DFunDef false "decodeModuleInterfaceGated" ((PVar "gate") (PVar "text")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decodeModuleSections") (EVar "gate")) (EVar "text"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple PWild (PVar "sections")) () (EMatch (EVar "sections") (arm (PList (PVar "s")) () (EApp (EVar "Ok") (EFieldAccess (EVar "s") "msInterface"))) (arm PWild () (EApp (EVar "Err") (EApp (EVar "Malformed") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (ELit (LString "header/sections.1"))) (fa "seWhat" (EBinOp "++" (EBinOp "++" (ELit (LString "expected one section, the file holds ")) (EApp (EMethodRef "display") (EApp (EMethodRef "length") (EVar "sections")))) (ELit (LString "")))))))))))))))
(DTypeSig true "decodeModuleInterface" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "ModuleInterface"))))
(DFunDef false "decodeModuleInterface" () (EApp (EVar "decodeModuleInterfaceGated") (ELam (PWild) (EVar "None"))))
(DTypeSig true "decodeModuleInterfaceFor" (TyFun (TyCon "ModuleKey") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "ModuleInterface")))))
(DFunDef false "decodeModuleInterfaceFor" ((PVar "expected")) (EApp (EVar "decodeModuleInterfaceGated") (EApp (EVar "keyDifference") (EVar "expected"))))
