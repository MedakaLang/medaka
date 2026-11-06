# META
source_lines=357
stages=DESUGAR,MARK
# SOURCE
import frontend.ast.{Loc(..), Lit(..)}
import ir.core_ir.{
  CProgram(..), CBind(..), CClause(..), CExpr(..), CField(..), CArm(..),
  CGuard(..), CTree(..), CTBranch(..), FailSite(..), CStmt(..), CImplEntry(..),
  CImplBody(..), siteSentinelName
}
import ir.constructor_facts.{planConstructors}
import backend.runtime_layout.{
  abiVersion, reservedTypeBase, siteFileBits, siteLineBits, siteColumnBits,
  siteFileShift, siteLineShift
}
import support.ordmap.{
  OrdMap, omEmpty, omLookup, omInsert, omHasKey, omFromNames
}
import map.{entries, fromList, get}

public export data PackageIdentity = PackageIdentity {
  fingerprint : String,
  abi : Int,
  types : OrdMap Int,
  files : OrdMap Int,
  typeHigh : Int,
  fileHigh : Int,
}

public export data IdentityPlan = IdentityPlan {
  imported : PackageIdentity,
  types : OrdMap Int,
  files : OrdMap Int,
  orderedFiles : List String,
}

public export data IdentityKind =
  | TypeIdentity
  | FileIdentity
  deriving (Eq, Debug, Display)

public export data IdentityDefect =
  | IdentityIncompatibleAbi
  | InvalidHighWater IdentityKind
  | InvalidAssignment IdentityKind String
  | DuplicateNumber IdentityKind
  | Exhausted IdentityKind
  | MissingAssignment IdentityKind String
  | AllocationDisagrees IdentityKind
  | ReservedHole IdentityKind String
  | ImportedChanged IdentityKind String
  | FileTableDisagrees
  deriving (Eq, Debug, Display)

kindName : IdentityKind -> String
kindName TypeIdentity = "type"
kindName FileIdentity = "file"

export
renderIdentityDefect : IdentityDefect -> String
renderIdentityDefect IdentityIncompatibleAbi = "identity: incompatible ABI"
renderIdentityDefect (InvalidHighWater kind) =
  "identity: invalid \{kindName kind} high-water mark"
renderIdentityDefect (InvalidAssignment kind name) =
  "identity: invalid \{kindName kind} assignment \{name}"
renderIdentityDefect (DuplicateNumber kind) =
  "identity: duplicate \{kindName kind} number"
renderIdentityDefect (Exhausted kind) =
  "identity: \{kindName kind} IDs exhausted"
renderIdentityDefect (MissingAssignment kind name) =
  "identity: missing \{kindName kind} \{name}"
renderIdentityDefect (AllocationDisagrees kind) =
  "identity: \{kindName kind} allocation disagrees"
renderIdentityDefect (ReservedHole kind name) =
  "identity: local \{kindName kind} uses reserved hole \{name}"
renderIdentityDefect (ImportedChanged kind name) =
  "identity: imported \{kindName kind} changed \{name}"
renderIdentityDefect FileTableDisagrees = "identity: file table disagrees"

export
emptyPackage : PackageIdentity
emptyPackage = PackageIdentity {
  fingerprint = "",
  abi = abiVersion,
  types = omEmpty,
  files = omEmpty,
  typeHigh = 0,
  fileHigh = 0,
}

export
sitePackable : Loc -> Bool
sitePackable (Loc f sl sc el ec) =
  f /= ""
    && not (sl == 1 && sc == 0 && el == 1 && ec == 0)
    && sl >= 0
    && sl < shiftLeft 1 siteLineBits
    && sc >= 0
    && sc < shiftLeft 1 siteColumnBits

fileOf : Loc -> OrdMap Int -> OrdMap Int
fileOf (l@(Loc f _ _ _ _)) files =
  if sitePackable l then omInsert f 0 files else files

bindFiles : OrdMap Int -> CBind -> OrdMap Int
bindFiles files (CBind _ clauses loc _) =
  fold clauseFiles (fileOf loc files) clauses
clauseFiles : OrdMap Int -> CClause -> OrdMap Int
clauseFiles files (CClause _ body) = exprFiles files body
fieldFiles : OrdMap Int -> CField -> OrdMap Int
fieldFiles files (CField _ _ e) = exprFiles files e
armFiles : OrdMap Int -> CArm -> OrdMap Int
armFiles files (CArm _ guards body) =
  exprFiles (fold guardFiles files guards) body
armFiles files (CArmAlt _ guards _) = fold guardFiles files guards
guardFiles : OrdMap Int -> CGuard -> OrdMap Int
guardFiles files (CGBool e) = exprFiles files e
guardFiles files (CGBind _ e) = exprFiles files e
stmtFiles : OrdMap Int -> CStmt -> OrdMap Int
stmtFiles files (CSExpr e) = exprFiles files e
stmtFiles files (CSLet _ _ e) = exprFiles files e
stmtFiles files (CSAssign _ e) = exprFiles files e
treeFiles : OrdMap Int -> CTree -> OrdMap Int
treeFiles files (CTFail (NoArm loc)) = fileOf loc files
treeFiles files (CTFail (LetRefuted loc)) = fileOf loc files
treeFiles files (CTLeaf _) = files
treeFiles files (CTGuard _ tree) = treeFiles files tree
treeFiles files (CTSwitch branches fallback) =
  treeFiles (fold branchFiles files branches) fallback
treeFiles files (CTDrop tree) = treeFiles files tree
branchFiles : OrdMap Int -> CTBranch -> OrdMap Int
branchFiles files (CTBranch _ tree) = treeFiles files tree
implFiles : OrdMap Int -> CImplEntry -> OrdMap Int
implFiles files (CImplEntry _ _ _ (CImplTagged _ _ _ _ _ _ body)) =
  exprFiles files body
implFiles files (CImplEntry _ _ _ (CImplDefault _ _ _ _ _ _ body)) =
  exprFiles files body

exprFiles : OrdMap Int -> CExpr -> OrdMap Int
exprFiles files (CLit _) = files
exprFiles files (CVar _ _) = files
exprFiles files (CApp (CVar name _) [CLit (LString f), CLit (LInt line), CLit (LInt col)] _) =
  if name == siteSentinelName then
    fileOf (Loc f line col line (col + 1)) files
  else
    files
exprFiles files (CApp head args _) = fold exprFiles (exprFiles files head) args
exprFiles files (CLam _ body) = exprFiles files body
exprFiles files (CLet _ _ rhs body) = exprFiles (exprFiles files rhs) body
exprFiles files (CLetGroup binds body) =
  exprFiles (fold bindFiles files binds) body
exprFiles files (CMatch e arms) = fold armFiles (exprFiles files e) arms
exprFiles files (CDecision e arms tree) =
  treeFiles (fold armFiles (exprFiles files e) arms) tree
exprFiles files (CIf a b c) = exprFiles (exprFiles (exprFiles files a) b) c
exprFiles files (CBinPrim _ a b _ loc) =
  exprFiles (exprFiles (fileOf loc files) a) b
exprFiles files (CUnOp _ e) = exprFiles files e
exprFiles files (CTuple es) = fold exprFiles files es
exprFiles files (CList es) = fold exprFiles files es
exprFiles files (CRecord _ fs) = fold fieldFiles files fs
exprFiles files (CFieldAccess e _ _ _) = exprFiles files e
exprFiles files (CRecordUpdate _ e fs) = fold fieldFiles (exprFiles files e) fs
exprFiles files (CVariantUpdate _ e fs) = fold fieldFiles (exprFiles files e) fs
exprFiles files (CArray es) = fold exprFiles files es
exprFiles files (CRangeList a b _) = exprFiles (exprFiles files a) b
exprFiles files (CRangeArray a b _) = exprFiles (exprFiles files a) b
exprFiles files (CBlock stmts) = fold stmtFiles files stmts
exprFiles files (CMethod _ _) = files
exprFiles files (CDict _ _) = files

programFiles : CProgram -> List String
programFiles (CProgram binds _ _ impls _ _) =
  map fst (entries (fold implFiles (fold bindFiles omEmpty binds) impls))

assign : List String -> Int -> OrdMap Int -> (OrdMap Int, Int)
assign [] high table = (table, high)
assign (name :: rest) high table =
  if omHasKey name table then
    assign rest high table
  else
    assign rest (high + 1) (omInsert name (high + 1) table)

ordered : Int -> OrdMap Int -> List String
ordered high files =
  let reverse = fromList (map (pair => (snd pair, fst pair)) (entries files))
  if high < 1 then [] else map (n => optionOr "" (get n reverse)) [1..=high]

data IdentityBounds = IdentityBounds {
  kind : IdentityKind,
  limit : Int,
  high : Int,
}

mapDefects : IdentityBounds -> OrdMap Int -> List IdentityDefect
mapDefects bounds table =
  let rows = entries table
  let invalid = flatMap (assignmentDefect bounds) rows
  let nums = map (p => intToString (snd p)) rows
  invalid
    ++ (if length (entries (omFromNames nums omEmpty)) /= length nums then
      [DuplicateNumber bounds.kind]
    else
      [])

assignmentDefect : IdentityBounds -> (String, Int) -> List IdentityDefect
assignmentDefect bounds (name, n) =
  if name == "" || n < 1 || n >= bounds.limit || n > bounds.high then
    [InvalidAssignment bounds.kind name]
  else
    []

export
packageDefects : PackageIdentity -> List IdentityDefect
packageDefects p =
  (if p.abi == abiVersion then [] else [IdentityIncompatibleAbi])
    ++ (if p.typeHigh >= 0 && p.typeHigh < reservedTypeBase then
      []
    else
      [InvalidHighWater TypeIdentity])
    ++ (if p.fileHigh >= 0 && p.fileHigh < shiftLeft 1 siteFileBits then
      []
    else
      [InvalidHighWater FileIdentity])
    ++ mapDefects
      (IdentityBounds TypeIdentity reservedTypeBase p.typeHigh)
      p.types
    ++ mapDefects
      (IdentityBounds FileIdentity (shiftLeft 1 siteFileBits) p.fileHigh)
      p.files

export
planProgramIdentity : PackageIdentity ->
  CProgram ->
  Result (List IdentityDefect) IdentityPlan
planProgramIdentity imported cp =
  let (types, typeHigh) =
    assign
      (map fst (entries (omFromNames (planConstructors cp).typeOrder omEmpty)))
      imported.typeHigh
      imported.types
  let (files, fileHigh) =
    assign (programFiles cp) imported.fileHigh imported.files
  let defects =
    packageDefects imported
      ++ (if typeHigh < reservedTypeBase then [] else [Exhausted TypeIdentity])
      ++ (if fileHigh < shiftLeft 1 siteFileBits then
        []
      else
        [Exhausted FileIdentity])
  if isEmpty defects then
    Ok IdentityPlan {
      imported = imported,
      types = types,
      files = files,
      orderedFiles = ordered fileHigh files,
    }
  else
    Err defects

export
planPackageIdentity : String ->
  CProgram ->
  Result (List IdentityDefect) PackageIdentity
planPackageIdentity fingerprint cp =
  map
    (plan => PackageIdentity {
      fingerprint = fingerprint,
      abi = abiVersion,
      types = (plan : IdentityPlan).types,
      files = (plan : IdentityPlan).files,
      typeHigh = highWater 0 (plan : IdentityPlan).types,
      fileHigh = highWater 0 (plan : IdentityPlan).files,
    })
    (planProgramIdentity emptyPackage cp)

highWater : Int -> OrdMap Int -> Int
highWater initial table =
  fold (n pair => max n (snd pair)) initial (entries table)

export
validateIdentityPlan : CProgram -> IdentityPlan -> List IdentityDefect
validateIdentityPlan cp plan =
  let imported = plan.imported
  let typeHigh = highWater imported.typeHigh plan.types
  let fileHigh = highWater imported.fileHigh plan.files
  let (expectedTypes, _) =
    assign (map fst (entries plan.types)) imported.typeHigh imported.types
  let (expectedFiles, _) =
    assign (map fst (entries plan.files)) imported.fileHigh imported.files
  packageDefects imported
    ++ mapDefects
      (IdentityBounds TypeIdentity reservedTypeBase typeHigh)
      plan.types
    ++ mapDefects
      (IdentityBounds FileIdentity (shiftLeft 1 siteFileBits) fileHigh)
      plan.files
    ++ flatMap (importDefect TypeIdentity plan.types) (entries imported.types)
    ++ flatMap (importDefect FileIdentity plan.files) (entries imported.files)
    ++ flatMap
      (name =>
        if omHasKey name plan.types then
          []
        else
          [MissingAssignment TypeIdentity name])
      (planConstructors cp).typeOrder
    ++ flatMap
      (name =>
        if omHasKey name plan.files then
          []
        else
          [MissingAssignment FileIdentity name])
      (programFiles cp)
    ++ (if entries expectedTypes == entries plan.types then
      []
    else
      [AllocationDisagrees TypeIdentity])
    ++ (if entries expectedFiles == entries plan.files then
      []
    else
      [AllocationDisagrees FileIdentity])
    ++ flatMap
      (localDefect TypeIdentity imported.typeHigh imported.types)
      (entries plan.types)
    ++ flatMap
      (localDefect FileIdentity imported.fileHigh imported.files)
      (entries plan.files)
    ++ (if fileHigh >= 0
      && fileHigh < shiftLeft 1 siteFileBits
      && plan.orderedFiles == ordered fileHigh plan.files then
      []
    else
      [FileTableDisagrees])

localDefect : IdentityKind ->
  Int ->
  OrdMap Int ->
  (String, Int) ->
  List IdentityDefect
localDefect label high imported (name, n) =
  if not (omHasKey name imported) && n <= high then
    [ReservedHole label name]
  else
    []

importDefect : IdentityKind ->
  OrdMap Int ->
  (String, Int) ->
  List IdentityDefect
importDefect label table (name, n) =
  if omLookup name table == Some n then [] else [ImportedChanged label name]

export
packSite : IdentityPlan -> Loc -> Int
packSite plan (loc@(Loc f line col _ _)) =
  if not (sitePackable loc) then
    0
  else match omLookup f plan.files
    None => panic "identity: missing file \{f}"
    Some n =>
      n * shiftLeft 1 siteFileShift + line * shiftLeft 1 siteLineShift + col
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Lit" true))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CField" true) (mem "CArm" true) (mem "CGuard" true) (mem "CTree" true) (mem "CTBranch" true) (mem "FailSite" true) (mem "CStmt" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "siteSentinelName" false))))
(DUse false (UseGroup ("ir" "constructor_facts") ((mem "planConstructors" false))))
(DUse false (UseGroup ("backend" "runtime_layout") ((mem "abiVersion" false) (mem "reservedTypeBase" false) (mem "siteFileBits" false) (mem "siteLineBits" false) (mem "siteColumnBits" false) (mem "siteFileShift" false) (mem "siteLineShift" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omLookup" false) (mem "omInsert" false) (mem "omHasKey" false) (mem "omFromNames" false))))
(DUse false (UseGroup ("map") ((mem "entries" false) (mem "fromList" false) (mem "get" false))))
(DData Public "PackageIdentity" () ((variant "PackageIdentity" (ConNamed (field "fingerprint" (TyCon "String")) (field "abi" (TyCon "Int")) (field "types" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "files" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "typeHigh" (TyCon "Int")) (field "fileHigh" (TyCon "Int"))))) ())
(DData Public "IdentityPlan" () ((variant "IdentityPlan" (ConNamed (field "imported" (TyCon "PackageIdentity")) (field "types" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "files" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "orderedFiles" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DData Public "IdentityKind" () ((variant "TypeIdentity" (ConPos)) (variant "FileIdentity" (ConPos))) ())
(DImpl true "Eq" ((TyCon "IdentityKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "TypeIdentity") (PCon "TypeIdentity")) () (EVar "True")) (arm (PTuple (PCon "FileIdentity") (PCon "FileIdentity")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "IdentityKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "TypeIdentity") () (ELit (LString "TypeIdentity"))) (arm (PCon "FileIdentity") () (ELit (LString "FileIdentity")))))))
(DImpl true "Display" ((TyCon "IdentityKind")) () ((im "display" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "TypeIdentity") () (ELit (LString "TypeIdentity"))) (arm (PCon "FileIdentity") () (ELit (LString "FileIdentity")))))))
(DData Public "IdentityDefect" () ((variant "IdentityIncompatibleAbi" (ConPos)) (variant "InvalidHighWater" (ConPos (TyCon "IdentityKind"))) (variant "InvalidAssignment" (ConPos (TyCon "IdentityKind") (TyCon "String"))) (variant "DuplicateNumber" (ConPos (TyCon "IdentityKind"))) (variant "Exhausted" (ConPos (TyCon "IdentityKind"))) (variant "MissingAssignment" (ConPos (TyCon "IdentityKind") (TyCon "String"))) (variant "AllocationDisagrees" (ConPos (TyCon "IdentityKind"))) (variant "ReservedHole" (ConPos (TyCon "IdentityKind") (TyCon "String"))) (variant "ImportedChanged" (ConPos (TyCon "IdentityKind") (TyCon "String"))) (variant "FileTableDisagrees" (ConPos))) ())
(DImpl true "Eq" ((TyCon "IdentityDefect")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "IdentityIncompatibleAbi") (PCon "IdentityIncompatibleAbi")) () (EVar "True")) (arm (PTuple (PCon "InvalidHighWater" (PVar "__a0")) (PCon "InvalidHighWater" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "InvalidAssignment" (PVar "__a0") (PVar "__a1")) (PCon "InvalidAssignment" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "DuplicateNumber" (PVar "__a0")) (PCon "DuplicateNumber" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "Exhausted" (PVar "__a0")) (PCon "Exhausted" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "MissingAssignment" (PVar "__a0") (PVar "__a1")) (PCon "MissingAssignment" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "AllocationDisagrees" (PVar "__a0")) (PCon "AllocationDisagrees" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "ReservedHole" (PVar "__a0") (PVar "__a1")) (PCon "ReservedHole" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "ImportedChanged" (PVar "__a0") (PVar "__a1")) (PCon "ImportedChanged" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "FileTableDisagrees") (PCon "FileTableDisagrees")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "IdentityDefect")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "IdentityIncompatibleAbi") () (ELit (LString "IdentityIncompatibleAbi"))) (arm (PCon "InvalidHighWater" (PVar "__a0")) () (EBinOp "++" (ELit (LString "InvalidHighWater ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "InvalidAssignment" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "InvalidAssignment ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1"))))) (arm (PCon "DuplicateNumber" (PVar "__a0")) () (EBinOp "++" (ELit (LString "DuplicateNumber ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "Exhausted" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Exhausted ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "MissingAssignment" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "MissingAssignment ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1"))))) (arm (PCon "AllocationDisagrees" (PVar "__a0")) () (EBinOp "++" (ELit (LString "AllocationDisagrees ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "ReservedHole" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ReservedHole ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1"))))) (arm (PCon "ImportedChanged" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ImportedChanged ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1"))))) (arm (PCon "FileTableDisagrees") () (ELit (LString "FileTableDisagrees")))))))
(DImpl true "Display" ((TyCon "IdentityDefect")) () ((im "display" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "IdentityIncompatibleAbi") () (ELit (LString "IdentityIncompatibleAbi"))) (arm (PCon "InvalidHighWater" (PVar "__a0")) () (EBinOp "++" (ELit (LString "InvalidHighWater ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "display") (EVar "__a0"))))) (arm (PCon "InvalidAssignment" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "InvalidAssignment ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "display") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "display") (EVar "__a1"))))) (arm (PCon "DuplicateNumber" (PVar "__a0")) () (EBinOp "++" (ELit (LString "DuplicateNumber ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "display") (EVar "__a0"))))) (arm (PCon "Exhausted" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Exhausted ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "display") (EVar "__a0"))))) (arm (PCon "MissingAssignment" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "MissingAssignment ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "display") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "display") (EVar "__a1"))))) (arm (PCon "AllocationDisagrees" (PVar "__a0")) () (EBinOp "++" (ELit (LString "AllocationDisagrees ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "display") (EVar "__a0"))))) (arm (PCon "ReservedHole" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ReservedHole ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "display") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "display") (EVar "__a1"))))) (arm (PCon "ImportedChanged" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ImportedChanged ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "display") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "display") (EVar "__a1"))))) (arm (PCon "FileTableDisagrees") () (ELit (LString "FileTableDisagrees")))))))
(DTypeSig false "kindName" (TyFun (TyCon "IdentityKind") (TyCon "String")))
(DFunDef false "kindName" ((PCon "TypeIdentity")) (ELit (LString "type")))
(DFunDef false "kindName" ((PCon "FileIdentity")) (ELit (LString "file")))
(DTypeSig true "renderIdentityDefect" (TyFun (TyCon "IdentityDefect") (TyCon "String")))
(DFunDef false "renderIdentityDefect" ((PCon "IdentityIncompatibleAbi")) (ELit (LString "identity: incompatible ABI")))
(DFunDef false "renderIdentityDefect" ((PCon "InvalidHighWater" (PVar "kind"))) (EBinOp "++" (EBinOp "++" (ELit (LString "identity: invalid ")) (EApp (EVar "display") (EApp (EVar "kindName") (EVar "kind")))) (ELit (LString " high-water mark"))))
(DFunDef false "renderIdentityDefect" ((PCon "InvalidAssignment" (PVar "kind") (PVar "name"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "identity: invalid ")) (EApp (EVar "display") (EApp (EVar "kindName") (EVar "kind")))) (ELit (LString " assignment "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "renderIdentityDefect" ((PCon "DuplicateNumber" (PVar "kind"))) (EBinOp "++" (EBinOp "++" (ELit (LString "identity: duplicate ")) (EApp (EVar "display") (EApp (EVar "kindName") (EVar "kind")))) (ELit (LString " number"))))
(DFunDef false "renderIdentityDefect" ((PCon "Exhausted" (PVar "kind"))) (EBinOp "++" (EBinOp "++" (ELit (LString "identity: ")) (EApp (EVar "display") (EApp (EVar "kindName") (EVar "kind")))) (ELit (LString " IDs exhausted"))))
(DFunDef false "renderIdentityDefect" ((PCon "MissingAssignment" (PVar "kind") (PVar "name"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "identity: missing ")) (EApp (EVar "display") (EApp (EVar "kindName") (EVar "kind")))) (ELit (LString " "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "renderIdentityDefect" ((PCon "AllocationDisagrees" (PVar "kind"))) (EBinOp "++" (EBinOp "++" (ELit (LString "identity: ")) (EApp (EVar "display") (EApp (EVar "kindName") (EVar "kind")))) (ELit (LString " allocation disagrees"))))
(DFunDef false "renderIdentityDefect" ((PCon "ReservedHole" (PVar "kind") (PVar "name"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "identity: local ")) (EApp (EVar "display") (EApp (EVar "kindName") (EVar "kind")))) (ELit (LString " uses reserved hole "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "renderIdentityDefect" ((PCon "ImportedChanged" (PVar "kind") (PVar "name"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "identity: imported ")) (EApp (EVar "display") (EApp (EVar "kindName") (EVar "kind")))) (ELit (LString " changed "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "renderIdentityDefect" ((PCon "FileTableDisagrees")) (ELit (LString "identity: file table disagrees")))
(DTypeSig true "emptyPackage" (TyCon "PackageIdentity"))
(DFunDef false "emptyPackage" () (ERecordCreate "PackageIdentity" ((fa "fingerprint" (ELit (LString ""))) (fa "abi" (EVar "abiVersion")) (fa "types" (EVar "omEmpty")) (fa "files" (EVar "omEmpty")) (fa "typeHigh" (ELit (LInt 0))) (fa "fileHigh" (ELit (LInt 0))))))
(DTypeSig true "sitePackable" (TyFun (TyCon "Loc") (TyCon "Bool")))
(DFunDef false "sitePackable" ((PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "f") (ELit (LString ""))) (EApp (EVar "not") (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "sl") (ELit (LInt 1))) (EBinOp "==" (EVar "sc") (ELit (LInt 0)))) (EBinOp "==" (EVar "el") (ELit (LInt 1)))) (EBinOp "==" (EVar "ec") (ELit (LInt 0)))))) (EBinOp ">=" (EVar "sl") (ELit (LInt 0)))) (EBinOp "<" (EVar "sl") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteLineBits")))) (EBinOp ">=" (EVar "sc") (ELit (LInt 0)))) (EBinOp "<" (EVar "sc") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteColumnBits")))))
(DTypeSig false "fileOf" (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "fileOf" ((PAs "l" (PCon "Loc" (PVar "f") PWild PWild PWild PWild)) (PVar "files")) (EIf (EApp (EVar "sitePackable") (EVar "l")) (EApp (EApp (EApp (EVar "omInsert") (EVar "f")) (ELit (LInt 0))) (EVar "files")) (EVar "files")))
(DTypeSig false "bindFiles" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CBind") (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "bindFiles" ((PVar "files") (PCon "CBind" PWild (PVar "clauses") (PVar "loc") PWild)) (EApp (EApp (EApp (EVar "fold") (EVar "clauseFiles")) (EApp (EApp (EVar "fileOf") (EVar "loc")) (EVar "files"))) (EVar "clauses")))
(DTypeSig false "clauseFiles" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CClause") (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "clauseFiles" ((PVar "files") (PCon "CClause" PWild (PVar "body"))) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "body")))
(DTypeSig false "fieldFiles" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CField") (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "fieldFiles" ((PVar "files") (PCon "CField" PWild PWild (PVar "e"))) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "e")))
(DTypeSig false "armFiles" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CArm") (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "armFiles" ((PVar "files") (PCon "CArm" PWild (PVar "guards") (PVar "body"))) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EApp (EVar "fold") (EVar "guardFiles")) (EVar "files")) (EVar "guards"))) (EVar "body")))
(DFunDef false "armFiles" ((PVar "files") (PCon "CArmAlt" PWild (PVar "guards") PWild)) (EApp (EApp (EApp (EVar "fold") (EVar "guardFiles")) (EVar "files")) (EVar "guards")))
(DTypeSig false "guardFiles" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CGuard") (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "guardFiles" ((PVar "files") (PCon "CGBool" (PVar "e"))) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "e")))
(DFunDef false "guardFiles" ((PVar "files") (PCon "CGBind" PWild (PVar "e"))) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "e")))
(DTypeSig false "stmtFiles" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CStmt") (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "stmtFiles" ((PVar "files") (PCon "CSExpr" (PVar "e"))) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "e")))
(DFunDef false "stmtFiles" ((PVar "files") (PCon "CSLet" PWild PWild (PVar "e"))) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "e")))
(DFunDef false "stmtFiles" ((PVar "files") (PCon "CSAssign" PWild (PVar "e"))) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "e")))
(DTypeSig false "treeFiles" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CTree") (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "treeFiles" ((PVar "files") (PCon "CTFail" (PCon "NoArm" (PVar "loc")))) (EApp (EApp (EVar "fileOf") (EVar "loc")) (EVar "files")))
(DFunDef false "treeFiles" ((PVar "files") (PCon "CTFail" (PCon "LetRefuted" (PVar "loc")))) (EApp (EApp (EVar "fileOf") (EVar "loc")) (EVar "files")))
(DFunDef false "treeFiles" ((PVar "files") (PCon "CTLeaf" PWild)) (EVar "files"))
(DFunDef false "treeFiles" ((PVar "files") (PCon "CTGuard" PWild (PVar "tree"))) (EApp (EApp (EVar "treeFiles") (EVar "files")) (EVar "tree")))
(DFunDef false "treeFiles" ((PVar "files") (PCon "CTSwitch" (PVar "branches") (PVar "fallback"))) (EApp (EApp (EVar "treeFiles") (EApp (EApp (EApp (EVar "fold") (EVar "branchFiles")) (EVar "files")) (EVar "branches"))) (EVar "fallback")))
(DFunDef false "treeFiles" ((PVar "files") (PCon "CTDrop" (PVar "tree"))) (EApp (EApp (EVar "treeFiles") (EVar "files")) (EVar "tree")))
(DTypeSig false "branchFiles" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CTBranch") (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "branchFiles" ((PVar "files") (PCon "CTBranch" PWild (PVar "tree"))) (EApp (EApp (EVar "treeFiles") (EVar "files")) (EVar "tree")))
(DTypeSig false "implFiles" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CImplEntry") (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "implFiles" ((PVar "files") (PCon "CImplEntry" PWild PWild PWild (PCon "CImplTagged" PWild PWild PWild PWild PWild PWild (PVar "body")))) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "body")))
(DFunDef false "implFiles" ((PVar "files") (PCon "CImplEntry" PWild PWild PWild (PCon "CImplDefault" PWild PWild PWild PWild PWild PWild (PVar "body")))) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "body")))
(DTypeSig false "exprFiles" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CExpr") (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CLit" PWild)) (EVar "files"))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CVar" PWild PWild)) (EVar "files"))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CApp" (PCon "CVar" (PVar "name") PWild) (PList (PCon "CLit" (PCon "LString" (PVar "f"))) (PCon "CLit" (PCon "LInt" (PVar "line"))) (PCon "CLit" (PCon "LInt" (PVar "col")))) PWild)) (EIf (EBinOp "==" (EVar "name") (EVar "siteSentinelName")) (EApp (EApp (EVar "fileOf") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "line")) (EVar "col")) (EVar "line")) (EBinOp "+" (EVar "col") (ELit (LInt 1))))) (EVar "files")) (EVar "files")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CApp" (PVar "head") (PVar "args") PWild)) (EApp (EApp (EApp (EVar "fold") (EVar "exprFiles")) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "head"))) (EVar "args")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CLam" PWild (PVar "body"))) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "body")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CLet" PWild PWild (PVar "rhs") (PVar "body"))) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "rhs"))) (EVar "body")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EApp (EVar "fold") (EVar "bindFiles")) (EVar "files")) (EVar "binds"))) (EVar "body")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CMatch" (PVar "e") (PVar "arms"))) (EApp (EApp (EApp (EVar "fold") (EVar "armFiles")) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "e"))) (EVar "arms")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CDecision" (PVar "e") (PVar "arms") (PVar "tree"))) (EApp (EApp (EVar "treeFiles") (EApp (EApp (EApp (EVar "fold") (EVar "armFiles")) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "e"))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CIf" (PVar "a") (PVar "b") (PVar "c"))) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "a"))) (EVar "b"))) (EVar "c")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CBinPrim" PWild (PVar "a") (PVar "b") PWild (PVar "loc"))) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "fileOf") (EVar "loc")) (EVar "files"))) (EVar "a"))) (EVar "b")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CUnOp" PWild (PVar "e"))) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "e")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CTuple" (PVar "es"))) (EApp (EApp (EApp (EVar "fold") (EVar "exprFiles")) (EVar "files")) (EVar "es")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CList" (PVar "es"))) (EApp (EApp (EApp (EVar "fold") (EVar "exprFiles")) (EVar "files")) (EVar "es")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CRecord" PWild (PVar "fs"))) (EApp (EApp (EApp (EVar "fold") (EVar "fieldFiles")) (EVar "files")) (EVar "fs")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CFieldAccess" (PVar "e") PWild PWild PWild)) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "e")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CRecordUpdate" PWild (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EVar "fold") (EVar "fieldFiles")) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "e"))) (EVar "fs")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CVariantUpdate" PWild (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EVar "fold") (EVar "fieldFiles")) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "e"))) (EVar "fs")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CArray" (PVar "es"))) (EApp (EApp (EApp (EVar "fold") (EVar "exprFiles")) (EVar "files")) (EVar "es")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CRangeList" (PVar "a") (PVar "b") PWild)) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "a"))) (EVar "b")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CRangeArray" (PVar "a") (PVar "b") PWild)) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "a"))) (EVar "b")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EApp (EVar "fold") (EVar "stmtFiles")) (EVar "files")) (EVar "stmts")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CMethod" PWild PWild)) (EVar "files"))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CDict" PWild PWild)) (EVar "files"))
(DTypeSig false "programFiles" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "programFiles" ((PCon "CProgram" (PVar "binds") PWild PWild (PVar "impls") PWild PWild)) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "entries") (EApp (EApp (EApp (EVar "fold") (EVar "implFiles")) (EApp (EApp (EApp (EVar "fold") (EVar "bindFiles")) (EVar "omEmpty")) (EVar "binds"))) (EVar "impls")))))
(DTypeSig false "assign" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyTuple (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyCon "Int"))))))
(DFunDef false "assign" ((PList) (PVar "high") (PVar "table")) (ETuple (EVar "table") (EVar "high")))
(DFunDef false "assign" ((PCons (PVar "name") (PVar "rest")) (PVar "high") (PVar "table")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "table")) (EApp (EApp (EApp (EVar "assign") (EVar "rest")) (EVar "high")) (EVar "table")) (EApp (EApp (EApp (EVar "assign") (EVar "rest")) (EBinOp "+" (EVar "high") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EBinOp "+" (EVar "high") (ELit (LInt 1)))) (EVar "table")))))
(DTypeSig false "ordered" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ordered" ((PVar "high") (PVar "files")) (EBlock (DoLet false false (PVar "reverse") (EApp (EVar "fromList") (EApp (EApp (EVar "map") (ELam ((PVar "pair")) (ETuple (EApp (EVar "snd") (EVar "pair")) (EApp (EVar "fst") (EVar "pair"))))) (EApp (EVar "entries") (EVar "files"))))) (DoExpr (EIf (EBinOp "<" (EVar "high") (ELit (LInt 1))) (EListLit) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EApp (EVar "get") (EVar "n")) (EVar "reverse"))))) (ERangeList (ELit (LInt 1)) (EVar "high") true))))))
(DData Private "IdentityBounds" () ((variant "IdentityBounds" (ConNamed (field "kind" (TyCon "IdentityKind")) (field "limit" (TyCon "Int")) (field "high" (TyCon "Int"))))) ())
(DTypeSig false "mapDefects" (TyFun (TyCon "IdentityBounds") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "IdentityDefect")))))
(DFunDef false "mapDefects" ((PVar "bounds") (PVar "table")) (EBlock (DoLet false false (PVar "rows") (EApp (EVar "entries") (EVar "table"))) (DoLet false false (PVar "invalid") (EApp (EApp (EVar "flatMap") (EApp (EVar "assignmentDefect") (EVar "bounds"))) (EVar "rows"))) (DoLet false false (PVar "nums") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EVar "intToString") (EApp (EVar "snd") (EVar "p"))))) (EVar "rows"))) (DoExpr (EBinOp "++" (EVar "invalid") (EIf (EBinOp "/=" (EApp (EVar "length") (EApp (EVar "entries") (EApp (EApp (EVar "omFromNames") (EVar "nums")) (EVar "omEmpty")))) (EApp (EVar "length") (EVar "nums"))) (EListLit (EApp (EVar "DuplicateNumber") (EFieldAccess (EVar "bounds") "kind"))) (EListLit))))))
(DTypeSig false "assignmentDefect" (TyFun (TyCon "IdentityBounds") (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "IdentityDefect")))))
(DFunDef false "assignmentDefect" ((PVar "bounds") (PTuple (PVar "name") (PVar "n"))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString ""))) (EBinOp "<" (EVar "n") (ELit (LInt 1)))) (EBinOp ">=" (EVar "n") (EFieldAccess (EVar "bounds") "limit"))) (EBinOp ">" (EVar "n") (EFieldAccess (EVar "bounds") "high"))) (EListLit (EApp (EApp (EVar "InvalidAssignment") (EFieldAccess (EVar "bounds") "kind")) (EVar "name"))) (EListLit)))
(DTypeSig true "packageDefects" (TyFun (TyCon "PackageIdentity") (TyApp (TyCon "List") (TyCon "IdentityDefect"))))
(DFunDef false "packageDefects" ((PVar "p")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EIf (EBinOp "==" (EFieldAccess (EVar "p") "abi") (EVar "abiVersion")) (EListLit) (EListLit (EVar "IdentityIncompatibleAbi"))) (EIf (EBinOp "&&" (EBinOp ">=" (EFieldAccess (EVar "p") "typeHigh") (ELit (LInt 0))) (EBinOp "<" (EFieldAccess (EVar "p") "typeHigh") (EVar "reservedTypeBase"))) (EListLit) (EListLit (EApp (EVar "InvalidHighWater") (EVar "TypeIdentity"))))) (EIf (EBinOp "&&" (EBinOp ">=" (EFieldAccess (EVar "p") "fileHigh") (ELit (LInt 0))) (EBinOp "<" (EFieldAccess (EVar "p") "fileHigh") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteFileBits")))) (EListLit) (EListLit (EApp (EVar "InvalidHighWater") (EVar "FileIdentity"))))) (EApp (EApp (EVar "mapDefects") (EApp (EApp (EApp (EVar "IdentityBounds") (EVar "TypeIdentity")) (EVar "reservedTypeBase")) (EFieldAccess (EVar "p") "typeHigh"))) (EFieldAccess (EVar "p") "types"))) (EApp (EApp (EVar "mapDefects") (EApp (EApp (EApp (EVar "IdentityBounds") (EVar "FileIdentity")) (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteFileBits"))) (EFieldAccess (EVar "p") "fileHigh"))) (EFieldAccess (EVar "p") "files"))))
(DTypeSig true "planProgramIdentity" (TyFun (TyCon "PackageIdentity") (TyFun (TyCon "CProgram") (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "List") (TyCon "IdentityDefect"))) (TyCon "IdentityPlan")))))
(DFunDef false "planProgramIdentity" ((PVar "imported") (PVar "cp")) (EBlock (DoLet false false (PTuple (PVar "types") (PVar "typeHigh")) (EApp (EApp (EApp (EVar "assign") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "entries") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EApp (EVar "planConstructors") (EVar "cp")) "typeOrder")) (EVar "omEmpty"))))) (EFieldAccess (EVar "imported") "typeHigh")) (EFieldAccess (EVar "imported") "types"))) (DoLet false false (PTuple (PVar "files") (PVar "fileHigh")) (EApp (EApp (EApp (EVar "assign") (EApp (EVar "programFiles") (EVar "cp"))) (EFieldAccess (EVar "imported") "fileHigh")) (EFieldAccess (EVar "imported") "files"))) (DoLet false false (PVar "defects") (EBinOp "++" (EBinOp "++" (EApp (EVar "packageDefects") (EVar "imported")) (EIf (EBinOp "<" (EVar "typeHigh") (EVar "reservedTypeBase")) (EListLit) (EListLit (EApp (EVar "Exhausted") (EVar "TypeIdentity"))))) (EIf (EBinOp "<" (EVar "fileHigh") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteFileBits"))) (EListLit) (EListLit (EApp (EVar "Exhausted") (EVar "FileIdentity")))))) (DoExpr (EIf (EApp (EVar "isEmpty") (EVar "defects")) (EApp (EVar "Ok") (ERecordCreate "IdentityPlan" ((fa "imported" (EVar "imported")) (fa "types" (EVar "types")) (fa "files" (EVar "files")) (fa "orderedFiles" (EApp (EApp (EVar "ordered") (EVar "fileHigh")) (EVar "files")))))) (EApp (EVar "Err") (EVar "defects"))))))
(DTypeSig true "planPackageIdentity" (TyFun (TyCon "String") (TyFun (TyCon "CProgram") (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "List") (TyCon "IdentityDefect"))) (TyCon "PackageIdentity")))))
(DFunDef false "planPackageIdentity" ((PVar "fingerprint") (PVar "cp")) (EApp (EApp (EVar "map") (ELam ((PVar "plan")) (ERecordCreate "PackageIdentity" ((fa "fingerprint" (EVar "fingerprint")) (fa "abi" (EVar "abiVersion")) (fa "types" (EFieldAccess (EAnnot (EVar "plan") (TyCon "IdentityPlan")) "types")) (fa "files" (EFieldAccess (EAnnot (EVar "plan") (TyCon "IdentityPlan")) "files")) (fa "typeHigh" (EApp (EApp (EVar "highWater") (ELit (LInt 0))) (EFieldAccess (EAnnot (EVar "plan") (TyCon "IdentityPlan")) "types"))) (fa "fileHigh" (EApp (EApp (EVar "highWater") (ELit (LInt 0))) (EFieldAccess (EAnnot (EVar "plan") (TyCon "IdentityPlan")) "files"))))))) (EApp (EApp (EVar "planProgramIdentity") (EVar "emptyPackage")) (EVar "cp"))))
(DTypeSig false "highWater" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyCon "Int"))))
(DFunDef false "highWater" ((PVar "initial") (PVar "table")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "n") (PVar "pair")) (EApp (EApp (EVar "max") (EVar "n")) (EApp (EVar "snd") (EVar "pair"))))) (EVar "initial")) (EApp (EVar "entries") (EVar "table"))))
(DTypeSig true "validateIdentityPlan" (TyFun (TyCon "CProgram") (TyFun (TyCon "IdentityPlan") (TyApp (TyCon "List") (TyCon "IdentityDefect")))))
(DFunDef false "validateIdentityPlan" ((PVar "cp") (PVar "plan")) (EBlock (DoLet false false (PVar "imported") (EFieldAccess (EVar "plan") "imported")) (DoLet false false (PVar "typeHigh") (EApp (EApp (EVar "highWater") (EFieldAccess (EVar "imported") "typeHigh")) (EFieldAccess (EVar "plan") "types"))) (DoLet false false (PVar "fileHigh") (EApp (EApp (EVar "highWater") (EFieldAccess (EVar "imported") "fileHigh")) (EFieldAccess (EVar "plan") "files"))) (DoLet false false (PTuple (PVar "expectedTypes") PWild) (EApp (EApp (EApp (EVar "assign") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "types")))) (EFieldAccess (EVar "imported") "typeHigh")) (EFieldAccess (EVar "imported") "types"))) (DoLet false false (PTuple (PVar "expectedFiles") PWild) (EApp (EApp (EApp (EVar "assign") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "files")))) (EFieldAccess (EVar "imported") "fileHigh")) (EFieldAccess (EVar "imported") "files"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "packageDefects") (EVar "imported")) (EApp (EApp (EVar "mapDefects") (EApp (EApp (EApp (EVar "IdentityBounds") (EVar "TypeIdentity")) (EVar "reservedTypeBase")) (EVar "typeHigh"))) (EFieldAccess (EVar "plan") "types"))) (EApp (EApp (EVar "mapDefects") (EApp (EApp (EApp (EVar "IdentityBounds") (EVar "FileIdentity")) (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteFileBits"))) (EVar "fileHigh"))) (EFieldAccess (EVar "plan") "files"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "importDefect") (EVar "TypeIdentity")) (EFieldAccess (EVar "plan") "types"))) (EApp (EVar "entries") (EFieldAccess (EVar "imported") "types")))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "importDefect") (EVar "FileIdentity")) (EFieldAccess (EVar "plan") "files"))) (EApp (EVar "entries") (EFieldAccess (EVar "imported") "files")))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "plan") "types")) (EListLit) (EListLit (EApp (EApp (EVar "MissingAssignment") (EVar "TypeIdentity")) (EVar "name")))))) (EFieldAccess (EApp (EVar "planConstructors") (EVar "cp")) "typeOrder"))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "plan") "files")) (EListLit) (EListLit (EApp (EApp (EVar "MissingAssignment") (EVar "FileIdentity")) (EVar "name")))))) (EApp (EVar "programFiles") (EVar "cp")))) (EIf (EBinOp "==" (EApp (EVar "entries") (EVar "expectedTypes")) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "types"))) (EListLit) (EListLit (EApp (EVar "AllocationDisagrees") (EVar "TypeIdentity"))))) (EIf (EBinOp "==" (EApp (EVar "entries") (EVar "expectedFiles")) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "files"))) (EListLit) (EListLit (EApp (EVar "AllocationDisagrees") (EVar "FileIdentity"))))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "localDefect") (EVar "TypeIdentity")) (EFieldAccess (EVar "imported") "typeHigh")) (EFieldAccess (EVar "imported") "types"))) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "types")))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "localDefect") (EVar "FileIdentity")) (EFieldAccess (EVar "imported") "fileHigh")) (EFieldAccess (EVar "imported") "files"))) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "files")))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "fileHigh") (ELit (LInt 0))) (EBinOp "<" (EVar "fileHigh") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteFileBits")))) (EBinOp "==" (EFieldAccess (EVar "plan") "orderedFiles") (EApp (EApp (EVar "ordered") (EVar "fileHigh")) (EFieldAccess (EVar "plan") "files")))) (EListLit) (EListLit (EVar "FileTableDisagrees")))))))
(DTypeSig false "localDefect" (TyFun (TyCon "IdentityKind") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "IdentityDefect")))))))
(DFunDef false "localDefect" ((PVar "label") (PVar "high") (PVar "imported") (PTuple (PVar "name") (PVar "n"))) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "imported"))) (EBinOp "<=" (EVar "n") (EVar "high"))) (EListLit (EApp (EApp (EVar "ReservedHole") (EVar "label")) (EVar "name"))) (EListLit)))
(DTypeSig false "importDefect" (TyFun (TyCon "IdentityKind") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "IdentityDefect"))))))
(DFunDef false "importDefect" ((PVar "label") (PVar "table") (PTuple (PVar "name") (PVar "n"))) (EIf (EBinOp "==" (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "table")) (EApp (EVar "Some") (EVar "n"))) (EListLit) (EListLit (EApp (EApp (EVar "ImportedChanged") (EVar "label")) (EVar "name")))))
(DTypeSig true "packSite" (TyFun (TyCon "IdentityPlan") (TyFun (TyCon "Loc") (TyCon "Int"))))
(DFunDef false "packSite" ((PVar "plan") (PAs "loc" (PCon "Loc" (PVar "f") (PVar "line") (PVar "col") PWild PWild))) (EIf (EApp (EVar "not") (EApp (EVar "sitePackable") (EVar "loc"))) (ELit (LInt 0)) (EMatch (EApp (EApp (EVar "omLookup") (EVar "f")) (EFieldAccess (EVar "plan") "files")) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "identity: missing file ")) (EApp (EVar "display") (EVar "f"))) (ELit (LString ""))))) (arm (PCon "Some" (PVar "n")) () (EBinOp "+" (EBinOp "+" (EBinOp "*" (EVar "n") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteFileShift"))) (EBinOp "*" (EVar "line") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteLineShift")))) (EVar "col"))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Lit" true))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CField" true) (mem "CArm" true) (mem "CGuard" true) (mem "CTree" true) (mem "CTBranch" true) (mem "FailSite" true) (mem "CStmt" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "siteSentinelName" false))))
(DUse false (UseGroup ("ir" "constructor_facts") ((mem "planConstructors" false))))
(DUse false (UseGroup ("backend" "runtime_layout") ((mem "abiVersion" false) (mem "reservedTypeBase" false) (mem "siteFileBits" false) (mem "siteLineBits" false) (mem "siteColumnBits" false) (mem "siteFileShift" false) (mem "siteLineShift" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omLookup" false) (mem "omInsert" false) (mem "omHasKey" false) (mem "omFromNames" false))))
(DUse false (UseGroup ("map") ((mem "entries" false) (mem "fromList" false) (mem "get" false))))
(DData Public "PackageIdentity" () ((variant "PackageIdentity" (ConNamed (field "fingerprint" (TyCon "String")) (field "abi" (TyCon "Int")) (field "types" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "files" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "typeHigh" (TyCon "Int")) (field "fileHigh" (TyCon "Int"))))) ())
(DData Public "IdentityPlan" () ((variant "IdentityPlan" (ConNamed (field "imported" (TyCon "PackageIdentity")) (field "types" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "files" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "orderedFiles" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DData Public "IdentityKind" () ((variant "TypeIdentity" (ConPos)) (variant "FileIdentity" (ConPos))) ())
(DImpl true "Eq" ((TyCon "IdentityKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "TypeIdentity") (PCon "TypeIdentity")) () (EVar "True")) (arm (PTuple (PCon "FileIdentity") (PCon "FileIdentity")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "IdentityKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "TypeIdentity") () (ELit (LString "TypeIdentity"))) (arm (PCon "FileIdentity") () (ELit (LString "FileIdentity")))))))
(DImpl true "Display" ((TyCon "IdentityKind")) () ((im "display" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "TypeIdentity") () (ELit (LString "TypeIdentity"))) (arm (PCon "FileIdentity") () (ELit (LString "FileIdentity")))))))
(DData Public "IdentityDefect" () ((variant "IdentityIncompatibleAbi" (ConPos)) (variant "InvalidHighWater" (ConPos (TyCon "IdentityKind"))) (variant "InvalidAssignment" (ConPos (TyCon "IdentityKind") (TyCon "String"))) (variant "DuplicateNumber" (ConPos (TyCon "IdentityKind"))) (variant "Exhausted" (ConPos (TyCon "IdentityKind"))) (variant "MissingAssignment" (ConPos (TyCon "IdentityKind") (TyCon "String"))) (variant "AllocationDisagrees" (ConPos (TyCon "IdentityKind"))) (variant "ReservedHole" (ConPos (TyCon "IdentityKind") (TyCon "String"))) (variant "ImportedChanged" (ConPos (TyCon "IdentityKind") (TyCon "String"))) (variant "FileTableDisagrees" (ConPos))) ())
(DImpl true "Eq" ((TyCon "IdentityDefect")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "IdentityIncompatibleAbi") (PCon "IdentityIncompatibleAbi")) () (EVar "True")) (arm (PTuple (PCon "InvalidHighWater" (PVar "__a0")) (PCon "InvalidHighWater" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "InvalidAssignment" (PVar "__a0") (PVar "__a1")) (PCon "InvalidAssignment" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "DuplicateNumber" (PVar "__a0")) (PCon "DuplicateNumber" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "Exhausted" (PVar "__a0")) (PCon "Exhausted" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "MissingAssignment" (PVar "__a0") (PVar "__a1")) (PCon "MissingAssignment" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "AllocationDisagrees" (PVar "__a0")) (PCon "AllocationDisagrees" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "ReservedHole" (PVar "__a0") (PVar "__a1")) (PCon "ReservedHole" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "ImportedChanged" (PVar "__a0") (PVar "__a1")) (PCon "ImportedChanged" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "FileTableDisagrees") (PCon "FileTableDisagrees")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "IdentityDefect")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "IdentityIncompatibleAbi") () (ELit (LString "IdentityIncompatibleAbi"))) (arm (PCon "InvalidHighWater" (PVar "__a0")) () (EBinOp "++" (ELit (LString "InvalidHighWater ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "InvalidAssignment" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "InvalidAssignment ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1"))))) (arm (PCon "DuplicateNumber" (PVar "__a0")) () (EBinOp "++" (ELit (LString "DuplicateNumber ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "Exhausted" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Exhausted ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "MissingAssignment" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "MissingAssignment ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1"))))) (arm (PCon "AllocationDisagrees" (PVar "__a0")) () (EBinOp "++" (ELit (LString "AllocationDisagrees ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "ReservedHole" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ReservedHole ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1"))))) (arm (PCon "ImportedChanged" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ImportedChanged ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1"))))) (arm (PCon "FileTableDisagrees") () (ELit (LString "FileTableDisagrees")))))))
(DImpl true "Display" ((TyCon "IdentityDefect")) () ((im "display" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "IdentityIncompatibleAbi") () (ELit (LString "IdentityIncompatibleAbi"))) (arm (PCon "InvalidHighWater" (PVar "__a0")) () (EBinOp "++" (ELit (LString "InvalidHighWater ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a0"))))) (arm (PCon "InvalidAssignment" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "InvalidAssignment ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a1"))))) (arm (PCon "DuplicateNumber" (PVar "__a0")) () (EBinOp "++" (ELit (LString "DuplicateNumber ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a0"))))) (arm (PCon "Exhausted" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Exhausted ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a0"))))) (arm (PCon "MissingAssignment" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "MissingAssignment ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a1"))))) (arm (PCon "AllocationDisagrees" (PVar "__a0")) () (EBinOp "++" (ELit (LString "AllocationDisagrees ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a0"))))) (arm (PCon "ReservedHole" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ReservedHole ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a1"))))) (arm (PCon "ImportedChanged" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ImportedChanged ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a1"))))) (arm (PCon "FileTableDisagrees") () (ELit (LString "FileTableDisagrees")))))))
(DTypeSig false "kindName" (TyFun (TyCon "IdentityKind") (TyCon "String")))
(DFunDef false "kindName" ((PCon "TypeIdentity")) (ELit (LString "type")))
(DFunDef false "kindName" ((PCon "FileIdentity")) (ELit (LString "file")))
(DTypeSig true "renderIdentityDefect" (TyFun (TyCon "IdentityDefect") (TyCon "String")))
(DFunDef false "renderIdentityDefect" ((PCon "IdentityIncompatibleAbi")) (ELit (LString "identity: incompatible ABI")))
(DFunDef false "renderIdentityDefect" ((PCon "InvalidHighWater" (PVar "kind"))) (EBinOp "++" (EBinOp "++" (ELit (LString "identity: invalid ")) (EApp (EMethodRef "display") (EApp (EVar "kindName") (EVar "kind")))) (ELit (LString " high-water mark"))))
(DFunDef false "renderIdentityDefect" ((PCon "InvalidAssignment" (PVar "kind") (PVar "name"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "identity: invalid ")) (EApp (EMethodRef "display") (EApp (EVar "kindName") (EVar "kind")))) (ELit (LString " assignment "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "renderIdentityDefect" ((PCon "DuplicateNumber" (PVar "kind"))) (EBinOp "++" (EBinOp "++" (ELit (LString "identity: duplicate ")) (EApp (EMethodRef "display") (EApp (EVar "kindName") (EVar "kind")))) (ELit (LString " number"))))
(DFunDef false "renderIdentityDefect" ((PCon "Exhausted" (PVar "kind"))) (EBinOp "++" (EBinOp "++" (ELit (LString "identity: ")) (EApp (EMethodRef "display") (EApp (EVar "kindName") (EVar "kind")))) (ELit (LString " IDs exhausted"))))
(DFunDef false "renderIdentityDefect" ((PCon "MissingAssignment" (PVar "kind") (PVar "name"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "identity: missing ")) (EApp (EMethodRef "display") (EApp (EVar "kindName") (EVar "kind")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "renderIdentityDefect" ((PCon "AllocationDisagrees" (PVar "kind"))) (EBinOp "++" (EBinOp "++" (ELit (LString "identity: ")) (EApp (EMethodRef "display") (EApp (EVar "kindName") (EVar "kind")))) (ELit (LString " allocation disagrees"))))
(DFunDef false "renderIdentityDefect" ((PCon "ReservedHole" (PVar "kind") (PVar "name"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "identity: local ")) (EApp (EMethodRef "display") (EApp (EVar "kindName") (EVar "kind")))) (ELit (LString " uses reserved hole "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "renderIdentityDefect" ((PCon "ImportedChanged" (PVar "kind") (PVar "name"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "identity: imported ")) (EApp (EMethodRef "display") (EApp (EVar "kindName") (EVar "kind")))) (ELit (LString " changed "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "renderIdentityDefect" ((PCon "FileTableDisagrees")) (ELit (LString "identity: file table disagrees")))
(DTypeSig true "emptyPackage" (TyCon "PackageIdentity"))
(DFunDef false "emptyPackage" () (ERecordCreate "PackageIdentity" ((fa "fingerprint" (ELit (LString ""))) (fa "abi" (EVar "abiVersion")) (fa "types" (EVar "omEmpty")) (fa "files" (EVar "omEmpty")) (fa "typeHigh" (ELit (LInt 0))) (fa "fileHigh" (ELit (LInt 0))))))
(DTypeSig true "sitePackable" (TyFun (TyCon "Loc") (TyCon "Bool")))
(DFunDef false "sitePackable" ((PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "f") (ELit (LString ""))) (EApp (EVar "not") (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "sl") (ELit (LInt 1))) (EBinOp "==" (EVar "sc") (ELit (LInt 0)))) (EBinOp "==" (EVar "el") (ELit (LInt 1)))) (EBinOp "==" (EVar "ec") (ELit (LInt 0)))))) (EBinOp ">=" (EVar "sl") (ELit (LInt 0)))) (EBinOp "<" (EVar "sl") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteLineBits")))) (EBinOp ">=" (EVar "sc") (ELit (LInt 0)))) (EBinOp "<" (EVar "sc") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteColumnBits")))))
(DTypeSig false "fileOf" (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "fileOf" ((PAs "l" (PCon "Loc" (PVar "f") PWild PWild PWild PWild)) (PVar "files")) (EIf (EApp (EVar "sitePackable") (EVar "l")) (EApp (EApp (EApp (EVar "omInsert") (EVar "f")) (ELit (LInt 0))) (EVar "files")) (EVar "files")))
(DTypeSig false "bindFiles" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CBind") (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "bindFiles" ((PVar "files") (PCon "CBind" PWild (PVar "clauses") (PVar "loc") PWild)) (EApp (EApp (EApp (EMethodRef "fold") (EVar "clauseFiles")) (EApp (EApp (EVar "fileOf") (EVar "loc")) (EVar "files"))) (EVar "clauses")))
(DTypeSig false "clauseFiles" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CClause") (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "clauseFiles" ((PVar "files") (PCon "CClause" PWild (PVar "body"))) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "body")))
(DTypeSig false "fieldFiles" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CField") (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "fieldFiles" ((PVar "files") (PCon "CField" PWild PWild (PVar "e"))) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "e")))
(DTypeSig false "armFiles" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CArm") (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "armFiles" ((PVar "files") (PCon "CArm" PWild (PVar "guards") (PVar "body"))) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EApp (EMethodRef "fold") (EVar "guardFiles")) (EVar "files")) (EVar "guards"))) (EVar "body")))
(DFunDef false "armFiles" ((PVar "files") (PCon "CArmAlt" PWild (PVar "guards") PWild)) (EApp (EApp (EApp (EMethodRef "fold") (EVar "guardFiles")) (EVar "files")) (EVar "guards")))
(DTypeSig false "guardFiles" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CGuard") (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "guardFiles" ((PVar "files") (PCon "CGBool" (PVar "e"))) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "e")))
(DFunDef false "guardFiles" ((PVar "files") (PCon "CGBind" PWild (PVar "e"))) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "e")))
(DTypeSig false "stmtFiles" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CStmt") (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "stmtFiles" ((PVar "files") (PCon "CSExpr" (PVar "e"))) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "e")))
(DFunDef false "stmtFiles" ((PVar "files") (PCon "CSLet" PWild PWild (PVar "e"))) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "e")))
(DFunDef false "stmtFiles" ((PVar "files") (PCon "CSAssign" PWild (PVar "e"))) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "e")))
(DTypeSig false "treeFiles" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CTree") (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "treeFiles" ((PVar "files") (PCon "CTFail" (PCon "NoArm" (PVar "loc")))) (EApp (EApp (EVar "fileOf") (EVar "loc")) (EVar "files")))
(DFunDef false "treeFiles" ((PVar "files") (PCon "CTFail" (PCon "LetRefuted" (PVar "loc")))) (EApp (EApp (EVar "fileOf") (EVar "loc")) (EVar "files")))
(DFunDef false "treeFiles" ((PVar "files") (PCon "CTLeaf" PWild)) (EVar "files"))
(DFunDef false "treeFiles" ((PVar "files") (PCon "CTGuard" PWild (PVar "tree"))) (EApp (EApp (EVar "treeFiles") (EVar "files")) (EVar "tree")))
(DFunDef false "treeFiles" ((PVar "files") (PCon "CTSwitch" (PVar "branches") (PVar "fallback"))) (EApp (EApp (EVar "treeFiles") (EApp (EApp (EApp (EMethodRef "fold") (EVar "branchFiles")) (EVar "files")) (EVar "branches"))) (EVar "fallback")))
(DFunDef false "treeFiles" ((PVar "files") (PCon "CTDrop" (PVar "tree"))) (EApp (EApp (EVar "treeFiles") (EVar "files")) (EVar "tree")))
(DTypeSig false "branchFiles" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CTBranch") (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "branchFiles" ((PVar "files") (PCon "CTBranch" PWild (PVar "tree"))) (EApp (EApp (EVar "treeFiles") (EVar "files")) (EVar "tree")))
(DTypeSig false "implFiles" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CImplEntry") (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "implFiles" ((PVar "files") (PCon "CImplEntry" PWild PWild PWild (PCon "CImplTagged" PWild PWild PWild PWild PWild PWild (PVar "body")))) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "body")))
(DFunDef false "implFiles" ((PVar "files") (PCon "CImplEntry" PWild PWild PWild (PCon "CImplDefault" PWild PWild PWild PWild PWild PWild (PVar "body")))) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "body")))
(DTypeSig false "exprFiles" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CExpr") (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CLit" PWild)) (EVar "files"))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CVar" PWild PWild)) (EVar "files"))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CApp" (PCon "CVar" (PVar "name") PWild) (PList (PCon "CLit" (PCon "LString" (PVar "f"))) (PCon "CLit" (PCon "LInt" (PVar "line"))) (PCon "CLit" (PCon "LInt" (PVar "col")))) PWild)) (EIf (EBinOp "==" (EVar "name") (EVar "siteSentinelName")) (EApp (EApp (EVar "fileOf") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "line")) (EVar "col")) (EVar "line")) (EBinOp "+" (EVar "col") (ELit (LInt 1))))) (EVar "files")) (EVar "files")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CApp" (PVar "head") (PVar "args") PWild)) (EApp (EApp (EApp (EMethodRef "fold") (EVar "exprFiles")) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "head"))) (EVar "args")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CLam" PWild (PVar "body"))) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "body")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CLet" PWild PWild (PVar "rhs") (PVar "body"))) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "rhs"))) (EVar "body")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EApp (EMethodRef "fold") (EVar "bindFiles")) (EVar "files")) (EVar "binds"))) (EVar "body")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CMatch" (PVar "e") (PVar "arms"))) (EApp (EApp (EApp (EMethodRef "fold") (EVar "armFiles")) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "e"))) (EVar "arms")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CDecision" (PVar "e") (PVar "arms") (PVar "tree"))) (EApp (EApp (EVar "treeFiles") (EApp (EApp (EApp (EMethodRef "fold") (EVar "armFiles")) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "e"))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CIf" (PVar "a") (PVar "b") (PVar "c"))) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "a"))) (EVar "b"))) (EVar "c")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CBinPrim" PWild (PVar "a") (PVar "b") PWild (PVar "loc"))) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "fileOf") (EVar "loc")) (EVar "files"))) (EVar "a"))) (EVar "b")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CUnOp" PWild (PVar "e"))) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "e")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CTuple" (PVar "es"))) (EApp (EApp (EApp (EMethodRef "fold") (EVar "exprFiles")) (EVar "files")) (EVar "es")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CList" (PVar "es"))) (EApp (EApp (EApp (EMethodRef "fold") (EVar "exprFiles")) (EVar "files")) (EVar "es")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CRecord" PWild (PVar "fs"))) (EApp (EApp (EApp (EMethodRef "fold") (EVar "fieldFiles")) (EVar "files")) (EVar "fs")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CFieldAccess" (PVar "e") PWild PWild PWild)) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "e")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CRecordUpdate" PWild (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EMethodRef "fold") (EVar "fieldFiles")) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "e"))) (EVar "fs")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CVariantUpdate" PWild (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EMethodRef "fold") (EVar "fieldFiles")) (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "e"))) (EVar "fs")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CArray" (PVar "es"))) (EApp (EApp (EApp (EMethodRef "fold") (EVar "exprFiles")) (EVar "files")) (EVar "es")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CRangeList" (PVar "a") (PVar "b") PWild)) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "a"))) (EVar "b")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CRangeArray" (PVar "a") (PVar "b") PWild)) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "a"))) (EVar "b")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EApp (EMethodRef "fold") (EVar "stmtFiles")) (EVar "files")) (EVar "stmts")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CMethod" PWild PWild)) (EVar "files"))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CDict" PWild PWild)) (EVar "files"))
(DTypeSig false "programFiles" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "programFiles" ((PCon "CProgram" (PVar "binds") PWild PWild (PVar "impls") PWild PWild)) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "entries") (EApp (EApp (EApp (EMethodRef "fold") (EVar "implFiles")) (EApp (EApp (EApp (EMethodRef "fold") (EVar "bindFiles")) (EVar "omEmpty")) (EVar "binds"))) (EVar "impls")))))
(DTypeSig false "assign" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyTuple (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyCon "Int"))))))
(DFunDef false "assign" ((PList) (PVar "high") (PVar "table")) (ETuple (EVar "table") (EVar "high")))
(DFunDef false "assign" ((PCons (PVar "name") (PVar "rest")) (PVar "high") (PVar "table")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "table")) (EApp (EApp (EApp (EVar "assign") (EVar "rest")) (EVar "high")) (EVar "table")) (EApp (EApp (EApp (EVar "assign") (EVar "rest")) (EBinOp "+" (EVar "high") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EBinOp "+" (EVar "high") (ELit (LInt 1)))) (EVar "table")))))
(DTypeSig false "ordered" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ordered" ((PVar "high") (PVar "files")) (EBlock (DoLet false false (PVar "reverse") (EApp (EVar "fromList") (EApp (EApp (EMethodRef "map") (ELam ((PVar "pair")) (ETuple (EApp (EVar "snd") (EVar "pair")) (EApp (EVar "fst") (EVar "pair"))))) (EApp (EVar "entries") (EVar "files"))))) (DoExpr (EIf (EBinOp "<" (EVar "high") (ELit (LInt 1))) (EListLit) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EApp (EVar "get") (EVar "n")) (EVar "reverse"))))) (ERangeList (ELit (LInt 1)) (EVar "high") true))))))
(DData Private "IdentityBounds" () ((variant "IdentityBounds" (ConNamed (field "kind" (TyCon "IdentityKind")) (field "limit" (TyCon "Int")) (field "high" (TyCon "Int"))))) ())
(DTypeSig false "mapDefects" (TyFun (TyCon "IdentityBounds") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "IdentityDefect")))))
(DFunDef false "mapDefects" ((PVar "bounds") (PVar "table")) (EBlock (DoLet false false (PVar "rows") (EApp (EVar "entries") (EVar "table"))) (DoLet false false (PVar "invalid") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "assignmentDefect") (EVar "bounds"))) (EVar "rows"))) (DoLet false false (PVar "nums") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EVar "intToString") (EApp (EVar "snd") (EVar "p"))))) (EVar "rows"))) (DoExpr (EBinOp "++" (EVar "invalid") (EIf (EBinOp "/=" (EApp (EMethodRef "length") (EApp (EVar "entries") (EApp (EApp (EVar "omFromNames") (EVar "nums")) (EVar "omEmpty")))) (EApp (EMethodRef "length") (EVar "nums"))) (EListLit (EApp (EVar "DuplicateNumber") (EFieldAccess (EVar "bounds") "kind"))) (EListLit))))))
(DTypeSig false "assignmentDefect" (TyFun (TyCon "IdentityBounds") (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "IdentityDefect")))))
(DFunDef false "assignmentDefect" ((PVar "bounds") (PTuple (PVar "name") (PVar "n"))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString ""))) (EBinOp "<" (EVar "n") (ELit (LInt 1)))) (EBinOp ">=" (EVar "n") (EFieldAccess (EVar "bounds") "limit"))) (EBinOp ">" (EVar "n") (EFieldAccess (EVar "bounds") "high"))) (EListLit (EApp (EApp (EVar "InvalidAssignment") (EFieldAccess (EVar "bounds") "kind")) (EVar "name"))) (EListLit)))
(DTypeSig true "packageDefects" (TyFun (TyCon "PackageIdentity") (TyApp (TyCon "List") (TyCon "IdentityDefect"))))
(DFunDef false "packageDefects" ((PVar "p")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EIf (EBinOp "==" (EFieldAccess (EVar "p") "abi") (EVar "abiVersion")) (EListLit) (EListLit (EVar "IdentityIncompatibleAbi"))) (EIf (EBinOp "&&" (EBinOp ">=" (EFieldAccess (EVar "p") "typeHigh") (ELit (LInt 0))) (EBinOp "<" (EFieldAccess (EVar "p") "typeHigh") (EVar "reservedTypeBase"))) (EListLit) (EListLit (EApp (EVar "InvalidHighWater") (EVar "TypeIdentity"))))) (EIf (EBinOp "&&" (EBinOp ">=" (EFieldAccess (EVar "p") "fileHigh") (ELit (LInt 0))) (EBinOp "<" (EFieldAccess (EVar "p") "fileHigh") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteFileBits")))) (EListLit) (EListLit (EApp (EVar "InvalidHighWater") (EVar "FileIdentity"))))) (EApp (EApp (EVar "mapDefects") (EApp (EApp (EApp (EVar "IdentityBounds") (EVar "TypeIdentity")) (EVar "reservedTypeBase")) (EFieldAccess (EVar "p") "typeHigh"))) (EFieldAccess (EVar "p") "types"))) (EApp (EApp (EVar "mapDefects") (EApp (EApp (EApp (EVar "IdentityBounds") (EVar "FileIdentity")) (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteFileBits"))) (EFieldAccess (EVar "p") "fileHigh"))) (EFieldAccess (EVar "p") "files"))))
(DTypeSig true "planProgramIdentity" (TyFun (TyCon "PackageIdentity") (TyFun (TyCon "CProgram") (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "List") (TyCon "IdentityDefect"))) (TyCon "IdentityPlan")))))
(DFunDef false "planProgramIdentity" ((PVar "imported") (PVar "cp")) (EBlock (DoLet false false (PTuple (PVar "types") (PVar "typeHigh")) (EApp (EApp (EApp (EVar "assign") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "entries") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EApp (EVar "planConstructors") (EVar "cp")) "typeOrder")) (EVar "omEmpty"))))) (EFieldAccess (EVar "imported") "typeHigh")) (EFieldAccess (EVar "imported") "types"))) (DoLet false false (PTuple (PVar "files") (PVar "fileHigh")) (EApp (EApp (EApp (EVar "assign") (EApp (EVar "programFiles") (EVar "cp"))) (EFieldAccess (EVar "imported") "fileHigh")) (EFieldAccess (EVar "imported") "files"))) (DoLet false false (PVar "defects") (EBinOp "++" (EBinOp "++" (EApp (EVar "packageDefects") (EVar "imported")) (EIf (EBinOp "<" (EVar "typeHigh") (EVar "reservedTypeBase")) (EListLit) (EListLit (EApp (EVar "Exhausted") (EVar "TypeIdentity"))))) (EIf (EBinOp "<" (EVar "fileHigh") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteFileBits"))) (EListLit) (EListLit (EApp (EVar "Exhausted") (EVar "FileIdentity")))))) (DoExpr (EIf (EApp (EMethodRef "isEmpty") (EVar "defects")) (EApp (EVar "Ok") (ERecordCreate "IdentityPlan" ((fa "imported" (EVar "imported")) (fa "types" (EVar "types")) (fa "files" (EVar "files")) (fa "orderedFiles" (EApp (EApp (EVar "ordered") (EVar "fileHigh")) (EVar "files")))))) (EApp (EVar "Err") (EVar "defects"))))))
(DTypeSig true "planPackageIdentity" (TyFun (TyCon "String") (TyFun (TyCon "CProgram") (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "List") (TyCon "IdentityDefect"))) (TyCon "PackageIdentity")))))
(DFunDef false "planPackageIdentity" ((PVar "fingerprint") (PVar "cp")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "plan")) (ERecordCreate "PackageIdentity" ((fa "fingerprint" (EVar "fingerprint")) (fa "abi" (EVar "abiVersion")) (fa "types" (EFieldAccess (EAnnot (EVar "plan") (TyCon "IdentityPlan")) "types")) (fa "files" (EFieldAccess (EAnnot (EVar "plan") (TyCon "IdentityPlan")) "files")) (fa "typeHigh" (EApp (EApp (EVar "highWater") (ELit (LInt 0))) (EFieldAccess (EAnnot (EVar "plan") (TyCon "IdentityPlan")) "types"))) (fa "fileHigh" (EApp (EApp (EVar "highWater") (ELit (LInt 0))) (EFieldAccess (EAnnot (EVar "plan") (TyCon "IdentityPlan")) "files"))))))) (EApp (EApp (EVar "planProgramIdentity") (EVar "emptyPackage")) (EVar "cp"))))
(DTypeSig false "highWater" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyCon "Int"))))
(DFunDef false "highWater" ((PVar "initial") (PVar "table")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "n") (PVar "pair")) (EApp (EApp (EMethodRef "max") (EVar "n")) (EApp (EVar "snd") (EVar "pair"))))) (EVar "initial")) (EApp (EVar "entries") (EVar "table"))))
(DTypeSig true "validateIdentityPlan" (TyFun (TyCon "CProgram") (TyFun (TyCon "IdentityPlan") (TyApp (TyCon "List") (TyCon "IdentityDefect")))))
(DFunDef false "validateIdentityPlan" ((PVar "cp") (PVar "plan")) (EBlock (DoLet false false (PVar "imported") (EFieldAccess (EVar "plan") "imported")) (DoLet false false (PVar "typeHigh") (EApp (EApp (EVar "highWater") (EFieldAccess (EVar "imported") "typeHigh")) (EFieldAccess (EVar "plan") "types"))) (DoLet false false (PVar "fileHigh") (EApp (EApp (EVar "highWater") (EFieldAccess (EVar "imported") "fileHigh")) (EFieldAccess (EVar "plan") "files"))) (DoLet false false (PTuple (PVar "expectedTypes") PWild) (EApp (EApp (EApp (EVar "assign") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "types")))) (EFieldAccess (EVar "imported") "typeHigh")) (EFieldAccess (EVar "imported") "types"))) (DoLet false false (PTuple (PVar "expectedFiles") PWild) (EApp (EApp (EApp (EVar "assign") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "files")))) (EFieldAccess (EVar "imported") "fileHigh")) (EFieldAccess (EVar "imported") "files"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "packageDefects") (EVar "imported")) (EApp (EApp (EVar "mapDefects") (EApp (EApp (EApp (EVar "IdentityBounds") (EVar "TypeIdentity")) (EVar "reservedTypeBase")) (EVar "typeHigh"))) (EFieldAccess (EVar "plan") "types"))) (EApp (EApp (EVar "mapDefects") (EApp (EApp (EApp (EVar "IdentityBounds") (EVar "FileIdentity")) (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteFileBits"))) (EVar "fileHigh"))) (EFieldAccess (EVar "plan") "files"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "importDefect") (EVar "TypeIdentity")) (EFieldAccess (EVar "plan") "types"))) (EApp (EVar "entries") (EFieldAccess (EVar "imported") "types")))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "importDefect") (EVar "FileIdentity")) (EFieldAccess (EVar "plan") "files"))) (EApp (EVar "entries") (EFieldAccess (EVar "imported") "files")))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "plan") "types")) (EListLit) (EListLit (EApp (EApp (EVar "MissingAssignment") (EVar "TypeIdentity")) (EVar "name")))))) (EFieldAccess (EApp (EVar "planConstructors") (EVar "cp")) "typeOrder"))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "plan") "files")) (EListLit) (EListLit (EApp (EApp (EVar "MissingAssignment") (EVar "FileIdentity")) (EVar "name")))))) (EApp (EVar "programFiles") (EVar "cp")))) (EIf (EBinOp "==" (EApp (EVar "entries") (EVar "expectedTypes")) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "types"))) (EListLit) (EListLit (EApp (EVar "AllocationDisagrees") (EVar "TypeIdentity"))))) (EIf (EBinOp "==" (EApp (EVar "entries") (EVar "expectedFiles")) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "files"))) (EListLit) (EListLit (EApp (EVar "AllocationDisagrees") (EVar "FileIdentity"))))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "localDefect") (EVar "TypeIdentity")) (EFieldAccess (EVar "imported") "typeHigh")) (EFieldAccess (EVar "imported") "types"))) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "types")))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "localDefect") (EVar "FileIdentity")) (EFieldAccess (EVar "imported") "fileHigh")) (EFieldAccess (EVar "imported") "files"))) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "files")))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "fileHigh") (ELit (LInt 0))) (EBinOp "<" (EVar "fileHigh") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteFileBits")))) (EBinOp "==" (EFieldAccess (EVar "plan") "orderedFiles") (EApp (EApp (EVar "ordered") (EVar "fileHigh")) (EFieldAccess (EVar "plan") "files")))) (EListLit) (EListLit (EVar "FileTableDisagrees")))))))
(DTypeSig false "localDefect" (TyFun (TyCon "IdentityKind") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "IdentityDefect")))))))
(DFunDef false "localDefect" ((PVar "label") (PVar "high") (PVar "imported") (PTuple (PVar "name") (PVar "n"))) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "imported"))) (EBinOp "<=" (EVar "n") (EVar "high"))) (EListLit (EApp (EApp (EVar "ReservedHole") (EVar "label")) (EVar "name"))) (EListLit)))
(DTypeSig false "importDefect" (TyFun (TyCon "IdentityKind") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "IdentityDefect"))))))
(DFunDef false "importDefect" ((PVar "label") (PVar "table") (PTuple (PVar "name") (PVar "n"))) (EIf (EBinOp "==" (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "table")) (EApp (EVar "Some") (EVar "n"))) (EListLit) (EListLit (EApp (EApp (EVar "ImportedChanged") (EVar "label")) (EVar "name")))))
(DTypeSig true "packSite" (TyFun (TyCon "IdentityPlan") (TyFun (TyCon "Loc") (TyCon "Int"))))
(DFunDef false "packSite" ((PVar "plan") (PAs "loc" (PCon "Loc" (PVar "f") (PVar "line") (PVar "col") PWild PWild))) (EIf (EApp (EVar "not") (EApp (EVar "sitePackable") (EVar "loc"))) (ELit (LInt 0)) (EMatch (EApp (EApp (EVar "omLookup") (EVar "f")) (EFieldAccess (EVar "plan") "files")) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "identity: missing file ")) (EApp (EMethodRef "display") (EVar "f"))) (ELit (LString ""))))) (arm (PCon "Some" (PVar "n")) () (EBinOp "+" (EBinOp "+" (EBinOp "*" (EVar "n") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteFileShift"))) (EBinOp "*" (EVar "line") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteLineShift")))) (EVar "col"))))))
