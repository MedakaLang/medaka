# META
source_lines=306
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

fileOf : Loc -> List String
fileOf (l@(Loc f _ _ _ _)) = if sitePackable l then [f] else []

bindFiles : CBind -> List String
bindFiles (CBind _ clauses loc _) = fileOf loc ++ flatMap clauseFiles clauses
clauseFiles : CClause -> List String
clauseFiles (CClause _ body) = exprFiles body
fieldFiles : CField -> List String
fieldFiles (CField _ _ e) = exprFiles e
armFiles : CArm -> List String
armFiles (CArm _ guards body) = flatMap guardFiles guards ++ exprFiles body
armFiles (CArmAlt _ guards _) = flatMap guardFiles guards
guardFiles : CGuard -> List String
guardFiles (CGBool e) = exprFiles e
guardFiles (CGBind _ e) = exprFiles e
stmtFiles : CStmt -> List String
stmtFiles (CSExpr e) = exprFiles e
stmtFiles (CSLet _ _ e) = exprFiles e
stmtFiles (CSAssign _ e) = exprFiles e
treeFiles : CTree -> List String
treeFiles (CTFail (NoArm loc)) = fileOf loc
treeFiles (CTFail (LetRefuted loc)) = fileOf loc
treeFiles (CTLeaf _) = []
treeFiles (CTGuard _ tree) = treeFiles tree
treeFiles (CTSwitch branches fallback) =
  flatMap branchFiles branches ++ treeFiles fallback
treeFiles (CTDrop tree) = treeFiles tree
branchFiles : CTBranch -> List String
branchFiles (CTBranch _ tree) = treeFiles tree
implFiles : CImplEntry -> List String
implFiles (CImplEntry _ _ _ (CImplTagged _ _ _ _ _ _ body)) = exprFiles body
implFiles (CImplEntry _ _ _ (CImplDefault _ _ _ _ _ _ body)) = exprFiles body

exprFiles : CExpr -> List String
exprFiles (CLit _) = []
exprFiles (CVar _ _) = []
exprFiles (CApp (CVar name _) [CLit (LString f), CLit (LInt line), CLit (LInt col)] _) =
  if name == siteSentinelName then
    fileOf (Loc f line col line (col + 1))
  else
    []
exprFiles (CApp head args _) = exprFiles head ++ flatMap exprFiles args
exprFiles (CLam _ body) = exprFiles body
exprFiles (CLet _ _ rhs body) = exprFiles rhs ++ exprFiles body
exprFiles (CLetGroup binds body) = flatMap bindFiles binds ++ exprFiles body
exprFiles (CMatch e arms) = exprFiles e ++ flatMap armFiles arms
exprFiles (CDecision e arms tree) =
  exprFiles e ++ flatMap armFiles arms ++ treeFiles tree
exprFiles (CIf a b c) = exprFiles a ++ exprFiles b ++ exprFiles c
exprFiles (CBinPrim _ a b _ loc) = fileOf loc ++ exprFiles a ++ exprFiles b
exprFiles (CUnOp _ e) = exprFiles e
exprFiles (CTuple es) = flatMap exprFiles es
exprFiles (CList es) = flatMap exprFiles es
exprFiles (CRecord _ fs) = flatMap fieldFiles fs
exprFiles (CFieldAccess e _ _ _) = exprFiles e
exprFiles (CRecordUpdate _ e fs) = exprFiles e ++ flatMap fieldFiles fs
exprFiles (CVariantUpdate _ e fs) = exprFiles e ++ flatMap fieldFiles fs
exprFiles (CArray es) = flatMap exprFiles es
exprFiles (CRangeList a b _) = exprFiles a ++ exprFiles b
exprFiles (CRangeArray a b _) = exprFiles a ++ exprFiles b
exprFiles (CIndex a b) = exprFiles a ++ exprFiles b
exprFiles (CSlice a b c _) = exprFiles a ++ exprFiles b ++ exprFiles c
exprFiles (CStringIndex a b) = exprFiles a ++ exprFiles b
exprFiles (CStringSlice a b c _) = exprFiles a ++ exprFiles b ++ exprFiles c
exprFiles (CListIndex a b) = exprFiles a ++ exprFiles b
exprFiles (CListSlice a b c _) = exprFiles a ++ exprFiles b ++ exprFiles c
exprFiles (CBlock stmts) = flatMap stmtFiles stmts
exprFiles (CMethod _ _) = []
exprFiles (CDict _ _) = []

programFiles : CProgram -> List String
programFiles (CProgram binds _ _ impls _ _) =
  map
    fst
    (entries
      (omFromNames
        (flatMap bindFiles binds ++ flatMap implFiles impls)
        omEmpty))

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

mapDefects : String -> Int -> Int -> Int -> OrdMap Int -> List String
mapDefects label low limit high table =
  let rows = entries table
  let invalid = flatMap (assignmentDefect label low limit high) rows
  let nums = map (p => intToString (snd p)) rows
  invalid
    ++ (if length (entries (omFromNames nums omEmpty)) /= length nums then
      ["identity: duplicate " ++ label ++ " number"]
    else
      [])

assignmentDefect : String -> Int -> Int -> Int -> (String, Int) -> List String
assignmentDefect label low limit high (name, n) =
  if name == "" || n < low || n >= limit || n > high then
    ["identity: invalid \{label} assignment \{name}"]
  else
    []

packageDefects : PackageIdentity -> List String
packageDefects p =
  (if p.abi == abiVersion then [] else ["identity: incompatible ABI"])
    ++ (if p.typeHigh >= 0 && p.typeHigh < reservedTypeBase then
      []
    else
      ["identity: invalid type high-water mark"])
    ++ (if p.fileHigh >= 0 && p.fileHigh < shiftLeft 1 siteFileBits then
      []
    else
      ["identity: invalid file high-water mark"])
    ++ mapDefects "type" 1 reservedTypeBase p.typeHigh p.types
    ++ mapDefects "file" 1 (shiftLeft 1 siteFileBits) p.fileHigh p.files

export
planProgramIdentity : PackageIdentity ->
  CProgram ->
  Result (List String) IdentityPlan
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
      ++ (if typeHigh < reservedTypeBase then
        []
      else
        ["identity: type IDs exhausted"])
      ++ (if fileHigh < shiftLeft 1 siteFileBits then
        []
      else
        ["identity: file IDs exhausted"])
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
planPackageIdentity : String -> CProgram -> Result (List String) PackageIdentity
planPackageIdentity fingerprint cp =
  map
    (plan => PackageIdentity {
      fingerprint = fingerprint,
      abi = abiVersion,
      types = (plan : IdentityPlan).types,
      files = (plan : IdentityPlan).files,
      typeHigh =
        fold
          (n pair => max n (snd pair))
          0
          (entries (plan : IdentityPlan).types),
      fileHigh =
        fold
          (n pair => max n (snd pair))
          0
          (entries (plan : IdentityPlan).files),
    })
    (planProgramIdentity emptyPackage cp)

export
validateIdentityPlan : CProgram -> IdentityPlan -> List String
validateIdentityPlan cp plan =
  let imported = plan.imported
  let typeHigh =
    fold (n pair => max n (snd pair)) imported.typeHigh (entries plan.types)
  let fileHigh =
    fold (n pair => max n (snd pair)) imported.fileHigh (entries plan.files)
  let (expectedTypes, _) =
    assign (map fst (entries plan.types)) imported.typeHigh imported.types
  let (expectedFiles, _) =
    assign (map fst (entries plan.files)) imported.fileHigh imported.files
  packageDefects imported
    ++ mapDefects "type" 1 reservedTypeBase typeHigh plan.types
    ++ mapDefects "file" 1 (shiftLeft 1 siteFileBits) fileHigh plan.files
    ++ flatMap (importDefect "type" plan.types) (entries imported.types)
    ++ flatMap (importDefect "file" plan.files) (entries imported.files)
    ++ flatMap
      (name =>
        if omHasKey name plan.types then
          []
        else
          ["identity: missing type " ++ name])
      (planConstructors cp).typeOrder
    ++ flatMap
      (name =>
        if omHasKey name plan.files then
          []
        else
          ["identity: missing file " ++ name])
      (programFiles cp)
    ++ (if entries expectedTypes == entries plan.types then
      []
    else
      ["identity: type allocation disagrees"])
    ++ (if entries expectedFiles == entries plan.files then
      []
    else
      ["identity: file allocation disagrees"])
    ++ flatMap
      (localDefect "type" imported.typeHigh imported.types)
      (entries plan.types)
    ++ flatMap
      (localDefect "file" imported.fileHigh imported.files)
      (entries plan.files)
    ++ (if fileHigh >= 0
      && fileHigh < shiftLeft 1 siteFileBits
      && plan.orderedFiles == ordered fileHigh plan.files then
      []
    else
      ["identity: file table disagrees"])

localDefect : String -> Int -> OrdMap Int -> (String, Int) -> List String
localDefect label high imported (name, n) =
  if not (omHasKey name imported) && n <= high then
    ["identity: local \{label} uses reserved hole \{name}"]
  else
    []

importDefect : String -> OrdMap Int -> (String, Int) -> List String
importDefect label table (name, n) =
  if omLookup name table == Some n then
    []
  else
    ["identity: imported \{label} changed \{name}"]

export
packSite : IdentityPlan -> Loc -> Int
packSite plan (loc@(Loc f line col _ _)) =
  if not (sitePackable loc) then
    0
  else match omLookup f plan.files
    None => 0
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
(DTypeSig true "emptyPackage" (TyCon "PackageIdentity"))
(DFunDef false "emptyPackage" () (ERecordCreate "PackageIdentity" ((fa "fingerprint" (ELit (LString ""))) (fa "abi" (EVar "abiVersion")) (fa "types" (EVar "omEmpty")) (fa "files" (EVar "omEmpty")) (fa "typeHigh" (ELit (LInt 0))) (fa "fileHigh" (ELit (LInt 0))))))
(DTypeSig true "sitePackable" (TyFun (TyCon "Loc") (TyCon "Bool")))
(DFunDef false "sitePackable" ((PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "f") (ELit (LString ""))) (EApp (EVar "not") (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "sl") (ELit (LInt 1))) (EBinOp "==" (EVar "sc") (ELit (LInt 0)))) (EBinOp "==" (EVar "el") (ELit (LInt 1)))) (EBinOp "==" (EVar "ec") (ELit (LInt 0)))))) (EBinOp ">=" (EVar "sl") (ELit (LInt 0)))) (EBinOp "<" (EVar "sl") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteLineBits")))) (EBinOp ">=" (EVar "sc") (ELit (LInt 0)))) (EBinOp "<" (EVar "sc") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteColumnBits")))))
(DTypeSig false "fileOf" (TyFun (TyCon "Loc") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "fileOf" ((PAs "l" (PCon "Loc" (PVar "f") PWild PWild PWild PWild))) (EIf (EApp (EVar "sitePackable") (EVar "l")) (EListLit (EVar "f")) (EListLit)))
(DTypeSig false "bindFiles" (TyFun (TyCon "CBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "bindFiles" ((PCon "CBind" PWild (PVar "clauses") (PVar "loc") PWild)) (EBinOp "++" (EApp (EVar "fileOf") (EVar "loc")) (EApp (EApp (EVar "flatMap") (EVar "clauseFiles")) (EVar "clauses"))))
(DTypeSig false "clauseFiles" (TyFun (TyCon "CClause") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "clauseFiles" ((PCon "CClause" PWild (PVar "body"))) (EApp (EVar "exprFiles") (EVar "body")))
(DTypeSig false "fieldFiles" (TyFun (TyCon "CField") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "fieldFiles" ((PCon "CField" PWild PWild (PVar "e"))) (EApp (EVar "exprFiles") (EVar "e")))
(DTypeSig false "armFiles" (TyFun (TyCon "CArm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "armFiles" ((PCon "CArm" PWild (PVar "guards") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "guardFiles")) (EVar "guards")) (EApp (EVar "exprFiles") (EVar "body"))))
(DFunDef false "armFiles" ((PCon "CArmAlt" PWild (PVar "guards") PWild)) (EApp (EApp (EVar "flatMap") (EVar "guardFiles")) (EVar "guards")))
(DTypeSig false "guardFiles" (TyFun (TyCon "CGuard") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "guardFiles" ((PCon "CGBool" (PVar "e"))) (EApp (EVar "exprFiles") (EVar "e")))
(DFunDef false "guardFiles" ((PCon "CGBind" PWild (PVar "e"))) (EApp (EVar "exprFiles") (EVar "e")))
(DTypeSig false "stmtFiles" (TyFun (TyCon "CStmt") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "stmtFiles" ((PCon "CSExpr" (PVar "e"))) (EApp (EVar "exprFiles") (EVar "e")))
(DFunDef false "stmtFiles" ((PCon "CSLet" PWild PWild (PVar "e"))) (EApp (EVar "exprFiles") (EVar "e")))
(DFunDef false "stmtFiles" ((PCon "CSAssign" PWild (PVar "e"))) (EApp (EVar "exprFiles") (EVar "e")))
(DTypeSig false "treeFiles" (TyFun (TyCon "CTree") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "treeFiles" ((PCon "CTFail" (PCon "NoArm" (PVar "loc")))) (EApp (EVar "fileOf") (EVar "loc")))
(DFunDef false "treeFiles" ((PCon "CTFail" (PCon "LetRefuted" (PVar "loc")))) (EApp (EVar "fileOf") (EVar "loc")))
(DFunDef false "treeFiles" ((PCon "CTLeaf" PWild)) (EListLit))
(DFunDef false "treeFiles" ((PCon "CTGuard" PWild (PVar "tree"))) (EApp (EVar "treeFiles") (EVar "tree")))
(DFunDef false "treeFiles" ((PCon "CTSwitch" (PVar "branches") (PVar "fallback"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "branchFiles")) (EVar "branches")) (EApp (EVar "treeFiles") (EVar "fallback"))))
(DFunDef false "treeFiles" ((PCon "CTDrop" (PVar "tree"))) (EApp (EVar "treeFiles") (EVar "tree")))
(DTypeSig false "branchFiles" (TyFun (TyCon "CTBranch") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "branchFiles" ((PCon "CTBranch" PWild (PVar "tree"))) (EApp (EVar "treeFiles") (EVar "tree")))
(DTypeSig false "implFiles" (TyFun (TyCon "CImplEntry") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "implFiles" ((PCon "CImplEntry" PWild PWild PWild (PCon "CImplTagged" PWild PWild PWild PWild PWild PWild (PVar "body")))) (EApp (EVar "exprFiles") (EVar "body")))
(DFunDef false "implFiles" ((PCon "CImplEntry" PWild PWild PWild (PCon "CImplDefault" PWild PWild PWild PWild PWild PWild (PVar "body")))) (EApp (EVar "exprFiles") (EVar "body")))
(DTypeSig false "exprFiles" (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "exprFiles" ((PCon "CLit" PWild)) (EListLit))
(DFunDef false "exprFiles" ((PCon "CVar" PWild PWild)) (EListLit))
(DFunDef false "exprFiles" ((PCon "CApp" (PCon "CVar" (PVar "name") PWild) (PList (PCon "CLit" (PCon "LString" (PVar "f"))) (PCon "CLit" (PCon "LInt" (PVar "line"))) (PCon "CLit" (PCon "LInt" (PVar "col")))) PWild)) (EIf (EBinOp "==" (EVar "name") (EVar "siteSentinelName")) (EApp (EVar "fileOf") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "line")) (EVar "col")) (EVar "line")) (EBinOp "+" (EVar "col") (ELit (LInt 1))))) (EListLit)))
(DFunDef false "exprFiles" ((PCon "CApp" (PVar "head") (PVar "args") PWild)) (EBinOp "++" (EApp (EVar "exprFiles") (EVar "head")) (EApp (EApp (EVar "flatMap") (EVar "exprFiles")) (EVar "args"))))
(DFunDef false "exprFiles" ((PCon "CLam" PWild (PVar "body"))) (EApp (EVar "exprFiles") (EVar "body")))
(DFunDef false "exprFiles" ((PCon "CLet" PWild PWild (PVar "rhs") (PVar "body"))) (EBinOp "++" (EApp (EVar "exprFiles") (EVar "rhs")) (EApp (EVar "exprFiles") (EVar "body"))))
(DFunDef false "exprFiles" ((PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "bindFiles")) (EVar "binds")) (EApp (EVar "exprFiles") (EVar "body"))))
(DFunDef false "exprFiles" ((PCon "CMatch" (PVar "e") (PVar "arms"))) (EBinOp "++" (EApp (EVar "exprFiles") (EVar "e")) (EApp (EApp (EVar "flatMap") (EVar "armFiles")) (EVar "arms"))))
(DFunDef false "exprFiles" ((PCon "CDecision" (PVar "e") (PVar "arms") (PVar "tree"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "exprFiles") (EVar "e")) (EApp (EApp (EVar "flatMap") (EVar "armFiles")) (EVar "arms"))) (EApp (EVar "treeFiles") (EVar "tree"))))
(DFunDef false "exprFiles" ((PCon "CIf" (PVar "a") (PVar "b") (PVar "c"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "exprFiles") (EVar "a")) (EApp (EVar "exprFiles") (EVar "b"))) (EApp (EVar "exprFiles") (EVar "c"))))
(DFunDef false "exprFiles" ((PCon "CBinPrim" PWild (PVar "a") (PVar "b") PWild (PVar "loc"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "fileOf") (EVar "loc")) (EApp (EVar "exprFiles") (EVar "a"))) (EApp (EVar "exprFiles") (EVar "b"))))
(DFunDef false "exprFiles" ((PCon "CUnOp" PWild (PVar "e"))) (EApp (EVar "exprFiles") (EVar "e")))
(DFunDef false "exprFiles" ((PCon "CTuple" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EVar "exprFiles")) (EVar "es")))
(DFunDef false "exprFiles" ((PCon "CList" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EVar "exprFiles")) (EVar "es")))
(DFunDef false "exprFiles" ((PCon "CRecord" PWild (PVar "fs"))) (EApp (EApp (EVar "flatMap") (EVar "fieldFiles")) (EVar "fs")))
(DFunDef false "exprFiles" ((PCon "CFieldAccess" (PVar "e") PWild PWild PWild)) (EApp (EVar "exprFiles") (EVar "e")))
(DFunDef false "exprFiles" ((PCon "CRecordUpdate" PWild (PVar "e") (PVar "fs"))) (EBinOp "++" (EApp (EVar "exprFiles") (EVar "e")) (EApp (EApp (EVar "flatMap") (EVar "fieldFiles")) (EVar "fs"))))
(DFunDef false "exprFiles" ((PCon "CVariantUpdate" PWild (PVar "e") (PVar "fs"))) (EBinOp "++" (EApp (EVar "exprFiles") (EVar "e")) (EApp (EApp (EVar "flatMap") (EVar "fieldFiles")) (EVar "fs"))))
(DFunDef false "exprFiles" ((PCon "CArray" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EVar "exprFiles")) (EVar "es")))
(DFunDef false "exprFiles" ((PCon "CRangeList" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "exprFiles") (EVar "a")) (EApp (EVar "exprFiles") (EVar "b"))))
(DFunDef false "exprFiles" ((PCon "CRangeArray" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "exprFiles") (EVar "a")) (EApp (EVar "exprFiles") (EVar "b"))))
(DFunDef false "exprFiles" ((PCon "CIndex" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "exprFiles") (EVar "a")) (EApp (EVar "exprFiles") (EVar "b"))))
(DFunDef false "exprFiles" ((PCon "CSlice" (PVar "a") (PVar "b") (PVar "c") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "exprFiles") (EVar "a")) (EApp (EVar "exprFiles") (EVar "b"))) (EApp (EVar "exprFiles") (EVar "c"))))
(DFunDef false "exprFiles" ((PCon "CStringIndex" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "exprFiles") (EVar "a")) (EApp (EVar "exprFiles") (EVar "b"))))
(DFunDef false "exprFiles" ((PCon "CStringSlice" (PVar "a") (PVar "b") (PVar "c") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "exprFiles") (EVar "a")) (EApp (EVar "exprFiles") (EVar "b"))) (EApp (EVar "exprFiles") (EVar "c"))))
(DFunDef false "exprFiles" ((PCon "CListIndex" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "exprFiles") (EVar "a")) (EApp (EVar "exprFiles") (EVar "b"))))
(DFunDef false "exprFiles" ((PCon "CListSlice" (PVar "a") (PVar "b") (PVar "c") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "exprFiles") (EVar "a")) (EApp (EVar "exprFiles") (EVar "b"))) (EApp (EVar "exprFiles") (EVar "c"))))
(DFunDef false "exprFiles" ((PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EVar "flatMap") (EVar "stmtFiles")) (EVar "stmts")))
(DFunDef false "exprFiles" ((PCon "CMethod" PWild PWild)) (EListLit))
(DFunDef false "exprFiles" ((PCon "CDict" PWild PWild)) (EListLit))
(DTypeSig false "programFiles" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "programFiles" ((PCon "CProgram" (PVar "binds") PWild PWild (PVar "impls") PWild PWild)) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "entries") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "bindFiles")) (EVar "binds")) (EApp (EApp (EVar "flatMap") (EVar "implFiles")) (EVar "impls")))) (EVar "omEmpty")))))
(DTypeSig false "assign" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyTuple (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyCon "Int"))))))
(DFunDef false "assign" ((PList) (PVar "high") (PVar "table")) (ETuple (EVar "table") (EVar "high")))
(DFunDef false "assign" ((PCons (PVar "name") (PVar "rest")) (PVar "high") (PVar "table")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "table")) (EApp (EApp (EApp (EVar "assign") (EVar "rest")) (EVar "high")) (EVar "table")) (EApp (EApp (EApp (EVar "assign") (EVar "rest")) (EBinOp "+" (EVar "high") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EBinOp "+" (EVar "high") (ELit (LInt 1)))) (EVar "table")))))
(DTypeSig false "ordered" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ordered" ((PVar "high") (PVar "files")) (EBlock (DoLet false false (PVar "reverse") (EApp (EVar "fromList") (EApp (EApp (EVar "map") (ELam ((PVar "pair")) (ETuple (EApp (EVar "snd") (EVar "pair")) (EApp (EVar "fst") (EVar "pair"))))) (EApp (EVar "entries") (EVar "files"))))) (DoExpr (EIf (EBinOp "<" (EVar "high") (ELit (LInt 1))) (EListLit) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EApp (EVar "get") (EVar "n")) (EVar "reverse"))))) (ERangeList (ELit (LInt 1)) (EVar "high") true))))))
(DTypeSig false "mapDefects" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "mapDefects" ((PVar "label") (PVar "low") (PVar "limit") (PVar "high") (PVar "table")) (EBlock (DoLet false false (PVar "rows") (EApp (EVar "entries") (EVar "table"))) (DoLet false false (PVar "invalid") (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EApp (EVar "assignmentDefect") (EVar "label")) (EVar "low")) (EVar "limit")) (EVar "high"))) (EVar "rows"))) (DoLet false false (PVar "nums") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EVar "intToString") (EApp (EVar "snd") (EVar "p"))))) (EVar "rows"))) (DoExpr (EBinOp "++" (EVar "invalid") (EIf (EBinOp "/=" (EApp (EVar "length") (EApp (EVar "entries") (EApp (EApp (EVar "omFromNames") (EVar "nums")) (EVar "omEmpty")))) (EApp (EVar "length") (EVar "nums"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "identity: duplicate ")) (EVar "label")) (ELit (LString " number")))) (EListLit))))))
(DTypeSig false "assignmentDefect" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "assignmentDefect" ((PVar "label") (PVar "low") (PVar "limit") (PVar "high") (PTuple (PVar "name") (PVar "n"))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString ""))) (EBinOp "<" (EVar "n") (EVar "low"))) (EBinOp ">=" (EVar "n") (EVar "limit"))) (EBinOp ">" (EVar "n") (EVar "high"))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "identity: invalid ")) (EApp (EVar "display") (EVar "label"))) (ELit (LString " assignment "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "")))) (EListLit)))
(DTypeSig false "packageDefects" (TyFun (TyCon "PackageIdentity") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "packageDefects" ((PVar "p")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EIf (EBinOp "==" (EFieldAccess (EVar "p") "abi") (EVar "abiVersion")) (EListLit) (EListLit (ELit (LString "identity: incompatible ABI")))) (EIf (EBinOp "&&" (EBinOp ">=" (EFieldAccess (EVar "p") "typeHigh") (ELit (LInt 0))) (EBinOp "<" (EFieldAccess (EVar "p") "typeHigh") (EVar "reservedTypeBase"))) (EListLit) (EListLit (ELit (LString "identity: invalid type high-water mark"))))) (EIf (EBinOp "&&" (EBinOp ">=" (EFieldAccess (EVar "p") "fileHigh") (ELit (LInt 0))) (EBinOp "<" (EFieldAccess (EVar "p") "fileHigh") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteFileBits")))) (EListLit) (EListLit (ELit (LString "identity: invalid file high-water mark"))))) (EApp (EApp (EApp (EApp (EApp (EVar "mapDefects") (ELit (LString "type"))) (ELit (LInt 1))) (EVar "reservedTypeBase")) (EFieldAccess (EVar "p") "typeHigh")) (EFieldAccess (EVar "p") "types"))) (EApp (EApp (EApp (EApp (EApp (EVar "mapDefects") (ELit (LString "file"))) (ELit (LInt 1))) (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteFileBits"))) (EFieldAccess (EVar "p") "fileHigh")) (EFieldAccess (EVar "p") "files"))))
(DTypeSig true "planProgramIdentity" (TyFun (TyCon "PackageIdentity") (TyFun (TyCon "CProgram") (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "IdentityPlan")))))
(DFunDef false "planProgramIdentity" ((PVar "imported") (PVar "cp")) (EBlock (DoLet false false (PTuple (PVar "types") (PVar "typeHigh")) (EApp (EApp (EApp (EVar "assign") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "entries") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EApp (EVar "planConstructors") (EVar "cp")) "typeOrder")) (EVar "omEmpty"))))) (EFieldAccess (EVar "imported") "typeHigh")) (EFieldAccess (EVar "imported") "types"))) (DoLet false false (PTuple (PVar "files") (PVar "fileHigh")) (EApp (EApp (EApp (EVar "assign") (EApp (EVar "programFiles") (EVar "cp"))) (EFieldAccess (EVar "imported") "fileHigh")) (EFieldAccess (EVar "imported") "files"))) (DoLet false false (PVar "defects") (EBinOp "++" (EBinOp "++" (EApp (EVar "packageDefects") (EVar "imported")) (EIf (EBinOp "<" (EVar "typeHigh") (EVar "reservedTypeBase")) (EListLit) (EListLit (ELit (LString "identity: type IDs exhausted"))))) (EIf (EBinOp "<" (EVar "fileHigh") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteFileBits"))) (EListLit) (EListLit (ELit (LString "identity: file IDs exhausted")))))) (DoExpr (EIf (EApp (EVar "isEmpty") (EVar "defects")) (EApp (EVar "Ok") (ERecordCreate "IdentityPlan" ((fa "imported" (EVar "imported")) (fa "types" (EVar "types")) (fa "files" (EVar "files")) (fa "orderedFiles" (EApp (EApp (EVar "ordered") (EVar "fileHigh")) (EVar "files")))))) (EApp (EVar "Err") (EVar "defects"))))))
(DTypeSig true "planPackageIdentity" (TyFun (TyCon "String") (TyFun (TyCon "CProgram") (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "PackageIdentity")))))
(DFunDef false "planPackageIdentity" ((PVar "fingerprint") (PVar "cp")) (EApp (EApp (EVar "map") (ELam ((PVar "plan")) (ERecordCreate "PackageIdentity" ((fa "fingerprint" (EVar "fingerprint")) (fa "abi" (EVar "abiVersion")) (fa "types" (EFieldAccess (EAnnot (EVar "plan") (TyCon "IdentityPlan")) "types")) (fa "files" (EFieldAccess (EAnnot (EVar "plan") (TyCon "IdentityPlan")) "files")) (fa "typeHigh" (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "n") (PVar "pair")) (EApp (EApp (EVar "max") (EVar "n")) (EApp (EVar "snd") (EVar "pair"))))) (ELit (LInt 0))) (EApp (EVar "entries") (EFieldAccess (EAnnot (EVar "plan") (TyCon "IdentityPlan")) "types")))) (fa "fileHigh" (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "n") (PVar "pair")) (EApp (EApp (EVar "max") (EVar "n")) (EApp (EVar "snd") (EVar "pair"))))) (ELit (LInt 0))) (EApp (EVar "entries") (EFieldAccess (EAnnot (EVar "plan") (TyCon "IdentityPlan")) "files")))))))) (EApp (EApp (EVar "planProgramIdentity") (EVar "emptyPackage")) (EVar "cp"))))
(DTypeSig true "validateIdentityPlan" (TyFun (TyCon "CProgram") (TyFun (TyCon "IdentityPlan") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "validateIdentityPlan" ((PVar "cp") (PVar "plan")) (EBlock (DoLet false false (PVar "imported") (EFieldAccess (EVar "plan") "imported")) (DoLet false false (PVar "typeHigh") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "n") (PVar "pair")) (EApp (EApp (EVar "max") (EVar "n")) (EApp (EVar "snd") (EVar "pair"))))) (EFieldAccess (EVar "imported") "typeHigh")) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "types")))) (DoLet false false (PVar "fileHigh") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "n") (PVar "pair")) (EApp (EApp (EVar "max") (EVar "n")) (EApp (EVar "snd") (EVar "pair"))))) (EFieldAccess (EVar "imported") "fileHigh")) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "files")))) (DoLet false false (PTuple (PVar "expectedTypes") PWild) (EApp (EApp (EApp (EVar "assign") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "types")))) (EFieldAccess (EVar "imported") "typeHigh")) (EFieldAccess (EVar "imported") "types"))) (DoLet false false (PTuple (PVar "expectedFiles") PWild) (EApp (EApp (EApp (EVar "assign") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "files")))) (EFieldAccess (EVar "imported") "fileHigh")) (EFieldAccess (EVar "imported") "files"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "packageDefects") (EVar "imported")) (EApp (EApp (EApp (EApp (EApp (EVar "mapDefects") (ELit (LString "type"))) (ELit (LInt 1))) (EVar "reservedTypeBase")) (EVar "typeHigh")) (EFieldAccess (EVar "plan") "types"))) (EApp (EApp (EApp (EApp (EApp (EVar "mapDefects") (ELit (LString "file"))) (ELit (LInt 1))) (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteFileBits"))) (EVar "fileHigh")) (EFieldAccess (EVar "plan") "files"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "importDefect") (ELit (LString "type"))) (EFieldAccess (EVar "plan") "types"))) (EApp (EVar "entries") (EFieldAccess (EVar "imported") "types")))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "importDefect") (ELit (LString "file"))) (EFieldAccess (EVar "plan") "files"))) (EApp (EVar "entries") (EFieldAccess (EVar "imported") "files")))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "plan") "types")) (EListLit) (EListLit (EBinOp "++" (ELit (LString "identity: missing type ")) (EVar "name")))))) (EFieldAccess (EApp (EVar "planConstructors") (EVar "cp")) "typeOrder"))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "plan") "files")) (EListLit) (EListLit (EBinOp "++" (ELit (LString "identity: missing file ")) (EVar "name")))))) (EApp (EVar "programFiles") (EVar "cp")))) (EIf (EBinOp "==" (EApp (EVar "entries") (EVar "expectedTypes")) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "types"))) (EListLit) (EListLit (ELit (LString "identity: type allocation disagrees"))))) (EIf (EBinOp "==" (EApp (EVar "entries") (EVar "expectedFiles")) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "files"))) (EListLit) (EListLit (ELit (LString "identity: file allocation disagrees"))))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "localDefect") (ELit (LString "type"))) (EFieldAccess (EVar "imported") "typeHigh")) (EFieldAccess (EVar "imported") "types"))) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "types")))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "localDefect") (ELit (LString "file"))) (EFieldAccess (EVar "imported") "fileHigh")) (EFieldAccess (EVar "imported") "files"))) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "files")))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "fileHigh") (ELit (LInt 0))) (EBinOp "<" (EVar "fileHigh") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteFileBits")))) (EBinOp "==" (EFieldAccess (EVar "plan") "orderedFiles") (EApp (EApp (EVar "ordered") (EVar "fileHigh")) (EFieldAccess (EVar "plan") "files")))) (EListLit) (EListLit (ELit (LString "identity: file table disagrees"))))))))
(DTypeSig false "localDefect" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "localDefect" ((PVar "label") (PVar "high") (PVar "imported") (PTuple (PVar "name") (PVar "n"))) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "imported"))) (EBinOp "<=" (EVar "n") (EVar "high"))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "identity: local ")) (EApp (EVar "display") (EVar "label"))) (ELit (LString " uses reserved hole "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "")))) (EListLit)))
(DTypeSig false "importDefect" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "importDefect" ((PVar "label") (PVar "table") (PTuple (PVar "name") (PVar "n"))) (EIf (EBinOp "==" (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "table")) (EApp (EVar "Some") (EVar "n"))) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "identity: imported ")) (EApp (EVar "display") (EVar "label"))) (ELit (LString " changed "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))))
(DTypeSig true "packSite" (TyFun (TyCon "IdentityPlan") (TyFun (TyCon "Loc") (TyCon "Int"))))
(DFunDef false "packSite" ((PVar "plan") (PAs "loc" (PCon "Loc" (PVar "f") (PVar "line") (PVar "col") PWild PWild))) (EIf (EApp (EVar "not") (EApp (EVar "sitePackable") (EVar "loc"))) (ELit (LInt 0)) (EMatch (EApp (EApp (EVar "omLookup") (EVar "f")) (EFieldAccess (EVar "plan") "files")) (arm (PCon "None") () (ELit (LInt 0))) (arm (PCon "Some" (PVar "n")) () (EBinOp "+" (EBinOp "+" (EBinOp "*" (EVar "n") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteFileShift"))) (EBinOp "*" (EVar "line") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteLineShift")))) (EVar "col"))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Lit" true))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CField" true) (mem "CArm" true) (mem "CGuard" true) (mem "CTree" true) (mem "CTBranch" true) (mem "FailSite" true) (mem "CStmt" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "siteSentinelName" false))))
(DUse false (UseGroup ("ir" "constructor_facts") ((mem "planConstructors" false))))
(DUse false (UseGroup ("backend" "runtime_layout") ((mem "abiVersion" false) (mem "reservedTypeBase" false) (mem "siteFileBits" false) (mem "siteLineBits" false) (mem "siteColumnBits" false) (mem "siteFileShift" false) (mem "siteLineShift" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omLookup" false) (mem "omInsert" false) (mem "omHasKey" false) (mem "omFromNames" false))))
(DUse false (UseGroup ("map") ((mem "entries" false) (mem "fromList" false) (mem "get" false))))
(DData Public "PackageIdentity" () ((variant "PackageIdentity" (ConNamed (field "fingerprint" (TyCon "String")) (field "abi" (TyCon "Int")) (field "types" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "files" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "typeHigh" (TyCon "Int")) (field "fileHigh" (TyCon "Int"))))) ())
(DData Public "IdentityPlan" () ((variant "IdentityPlan" (ConNamed (field "imported" (TyCon "PackageIdentity")) (field "types" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "files" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "orderedFiles" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig true "emptyPackage" (TyCon "PackageIdentity"))
(DFunDef false "emptyPackage" () (ERecordCreate "PackageIdentity" ((fa "fingerprint" (ELit (LString ""))) (fa "abi" (EVar "abiVersion")) (fa "types" (EVar "omEmpty")) (fa "files" (EVar "omEmpty")) (fa "typeHigh" (ELit (LInt 0))) (fa "fileHigh" (ELit (LInt 0))))))
(DTypeSig true "sitePackable" (TyFun (TyCon "Loc") (TyCon "Bool")))
(DFunDef false "sitePackable" ((PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "f") (ELit (LString ""))) (EApp (EVar "not") (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "sl") (ELit (LInt 1))) (EBinOp "==" (EVar "sc") (ELit (LInt 0)))) (EBinOp "==" (EVar "el") (ELit (LInt 1)))) (EBinOp "==" (EVar "ec") (ELit (LInt 0)))))) (EBinOp ">=" (EVar "sl") (ELit (LInt 0)))) (EBinOp "<" (EVar "sl") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteLineBits")))) (EBinOp ">=" (EVar "sc") (ELit (LInt 0)))) (EBinOp "<" (EVar "sc") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteColumnBits")))))
(DTypeSig false "fileOf" (TyFun (TyCon "Loc") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "fileOf" ((PAs "l" (PCon "Loc" (PVar "f") PWild PWild PWild PWild))) (EIf (EApp (EVar "sitePackable") (EVar "l")) (EListLit (EVar "f")) (EListLit)))
(DTypeSig false "bindFiles" (TyFun (TyCon "CBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "bindFiles" ((PCon "CBind" PWild (PVar "clauses") (PVar "loc") PWild)) (EBinOp "++" (EApp (EVar "fileOf") (EVar "loc")) (EApp (EApp (EDictApp "flatMap") (EVar "clauseFiles")) (EVar "clauses"))))
(DTypeSig false "clauseFiles" (TyFun (TyCon "CClause") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "clauseFiles" ((PCon "CClause" PWild (PVar "body"))) (EApp (EVar "exprFiles") (EVar "body")))
(DTypeSig false "fieldFiles" (TyFun (TyCon "CField") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "fieldFiles" ((PCon "CField" PWild PWild (PVar "e"))) (EApp (EVar "exprFiles") (EVar "e")))
(DTypeSig false "armFiles" (TyFun (TyCon "CArm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "armFiles" ((PCon "CArm" PWild (PVar "guards") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "guardFiles")) (EVar "guards")) (EApp (EVar "exprFiles") (EVar "body"))))
(DFunDef false "armFiles" ((PCon "CArmAlt" PWild (PVar "guards") PWild)) (EApp (EApp (EDictApp "flatMap") (EVar "guardFiles")) (EVar "guards")))
(DTypeSig false "guardFiles" (TyFun (TyCon "CGuard") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "guardFiles" ((PCon "CGBool" (PVar "e"))) (EApp (EVar "exprFiles") (EVar "e")))
(DFunDef false "guardFiles" ((PCon "CGBind" PWild (PVar "e"))) (EApp (EVar "exprFiles") (EVar "e")))
(DTypeSig false "stmtFiles" (TyFun (TyCon "CStmt") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "stmtFiles" ((PCon "CSExpr" (PVar "e"))) (EApp (EVar "exprFiles") (EVar "e")))
(DFunDef false "stmtFiles" ((PCon "CSLet" PWild PWild (PVar "e"))) (EApp (EVar "exprFiles") (EVar "e")))
(DFunDef false "stmtFiles" ((PCon "CSAssign" PWild (PVar "e"))) (EApp (EVar "exprFiles") (EVar "e")))
(DTypeSig false "treeFiles" (TyFun (TyCon "CTree") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "treeFiles" ((PCon "CTFail" (PCon "NoArm" (PVar "loc")))) (EApp (EVar "fileOf") (EVar "loc")))
(DFunDef false "treeFiles" ((PCon "CTFail" (PCon "LetRefuted" (PVar "loc")))) (EApp (EVar "fileOf") (EVar "loc")))
(DFunDef false "treeFiles" ((PCon "CTLeaf" PWild)) (EListLit))
(DFunDef false "treeFiles" ((PCon "CTGuard" PWild (PVar "tree"))) (EApp (EVar "treeFiles") (EVar "tree")))
(DFunDef false "treeFiles" ((PCon "CTSwitch" (PVar "branches") (PVar "fallback"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "branchFiles")) (EVar "branches")) (EApp (EVar "treeFiles") (EVar "fallback"))))
(DFunDef false "treeFiles" ((PCon "CTDrop" (PVar "tree"))) (EApp (EVar "treeFiles") (EVar "tree")))
(DTypeSig false "branchFiles" (TyFun (TyCon "CTBranch") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "branchFiles" ((PCon "CTBranch" PWild (PVar "tree"))) (EApp (EVar "treeFiles") (EVar "tree")))
(DTypeSig false "implFiles" (TyFun (TyCon "CImplEntry") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "implFiles" ((PCon "CImplEntry" PWild PWild PWild (PCon "CImplTagged" PWild PWild PWild PWild PWild PWild (PVar "body")))) (EApp (EVar "exprFiles") (EVar "body")))
(DFunDef false "implFiles" ((PCon "CImplEntry" PWild PWild PWild (PCon "CImplDefault" PWild PWild PWild PWild PWild PWild (PVar "body")))) (EApp (EVar "exprFiles") (EVar "body")))
(DTypeSig false "exprFiles" (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "exprFiles" ((PCon "CLit" PWild)) (EListLit))
(DFunDef false "exprFiles" ((PCon "CVar" PWild PWild)) (EListLit))
(DFunDef false "exprFiles" ((PCon "CApp" (PCon "CVar" (PVar "name") PWild) (PList (PCon "CLit" (PCon "LString" (PVar "f"))) (PCon "CLit" (PCon "LInt" (PVar "line"))) (PCon "CLit" (PCon "LInt" (PVar "col")))) PWild)) (EIf (EBinOp "==" (EVar "name") (EVar "siteSentinelName")) (EApp (EVar "fileOf") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "line")) (EVar "col")) (EVar "line")) (EBinOp "+" (EVar "col") (ELit (LInt 1))))) (EListLit)))
(DFunDef false "exprFiles" ((PCon "CApp" (PVar "head") (PVar "args") PWild)) (EBinOp "++" (EApp (EVar "exprFiles") (EVar "head")) (EApp (EApp (EDictApp "flatMap") (EVar "exprFiles")) (EVar "args"))))
(DFunDef false "exprFiles" ((PCon "CLam" PWild (PVar "body"))) (EApp (EVar "exprFiles") (EVar "body")))
(DFunDef false "exprFiles" ((PCon "CLet" PWild PWild (PVar "rhs") (PVar "body"))) (EBinOp "++" (EApp (EVar "exprFiles") (EVar "rhs")) (EApp (EVar "exprFiles") (EVar "body"))))
(DFunDef false "exprFiles" ((PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "bindFiles")) (EVar "binds")) (EApp (EVar "exprFiles") (EVar "body"))))
(DFunDef false "exprFiles" ((PCon "CMatch" (PVar "e") (PVar "arms"))) (EBinOp "++" (EApp (EVar "exprFiles") (EVar "e")) (EApp (EApp (EDictApp "flatMap") (EVar "armFiles")) (EVar "arms"))))
(DFunDef false "exprFiles" ((PCon "CDecision" (PVar "e") (PVar "arms") (PVar "tree"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "exprFiles") (EVar "e")) (EApp (EApp (EDictApp "flatMap") (EVar "armFiles")) (EVar "arms"))) (EApp (EVar "treeFiles") (EVar "tree"))))
(DFunDef false "exprFiles" ((PCon "CIf" (PVar "a") (PVar "b") (PVar "c"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "exprFiles") (EVar "a")) (EApp (EVar "exprFiles") (EVar "b"))) (EApp (EVar "exprFiles") (EVar "c"))))
(DFunDef false "exprFiles" ((PCon "CBinPrim" PWild (PVar "a") (PVar "b") PWild (PVar "loc"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "fileOf") (EVar "loc")) (EApp (EVar "exprFiles") (EVar "a"))) (EApp (EVar "exprFiles") (EVar "b"))))
(DFunDef false "exprFiles" ((PCon "CUnOp" PWild (PVar "e"))) (EApp (EVar "exprFiles") (EVar "e")))
(DFunDef false "exprFiles" ((PCon "CTuple" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EVar "exprFiles")) (EVar "es")))
(DFunDef false "exprFiles" ((PCon "CList" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EVar "exprFiles")) (EVar "es")))
(DFunDef false "exprFiles" ((PCon "CRecord" PWild (PVar "fs"))) (EApp (EApp (EDictApp "flatMap") (EVar "fieldFiles")) (EVar "fs")))
(DFunDef false "exprFiles" ((PCon "CFieldAccess" (PVar "e") PWild PWild PWild)) (EApp (EVar "exprFiles") (EVar "e")))
(DFunDef false "exprFiles" ((PCon "CRecordUpdate" PWild (PVar "e") (PVar "fs"))) (EBinOp "++" (EApp (EVar "exprFiles") (EVar "e")) (EApp (EApp (EDictApp "flatMap") (EVar "fieldFiles")) (EVar "fs"))))
(DFunDef false "exprFiles" ((PCon "CVariantUpdate" PWild (PVar "e") (PVar "fs"))) (EBinOp "++" (EApp (EVar "exprFiles") (EVar "e")) (EApp (EApp (EDictApp "flatMap") (EVar "fieldFiles")) (EVar "fs"))))
(DFunDef false "exprFiles" ((PCon "CArray" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EVar "exprFiles")) (EVar "es")))
(DFunDef false "exprFiles" ((PCon "CRangeList" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "exprFiles") (EVar "a")) (EApp (EVar "exprFiles") (EVar "b"))))
(DFunDef false "exprFiles" ((PCon "CRangeArray" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "exprFiles") (EVar "a")) (EApp (EVar "exprFiles") (EVar "b"))))
(DFunDef false "exprFiles" ((PCon "CIndex" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "exprFiles") (EVar "a")) (EApp (EVar "exprFiles") (EVar "b"))))
(DFunDef false "exprFiles" ((PCon "CSlice" (PVar "a") (PVar "b") (PVar "c") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "exprFiles") (EVar "a")) (EApp (EVar "exprFiles") (EVar "b"))) (EApp (EVar "exprFiles") (EVar "c"))))
(DFunDef false "exprFiles" ((PCon "CStringIndex" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "exprFiles") (EVar "a")) (EApp (EVar "exprFiles") (EVar "b"))))
(DFunDef false "exprFiles" ((PCon "CStringSlice" (PVar "a") (PVar "b") (PVar "c") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "exprFiles") (EVar "a")) (EApp (EVar "exprFiles") (EVar "b"))) (EApp (EVar "exprFiles") (EVar "c"))))
(DFunDef false "exprFiles" ((PCon "CListIndex" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "exprFiles") (EVar "a")) (EApp (EVar "exprFiles") (EVar "b"))))
(DFunDef false "exprFiles" ((PCon "CListSlice" (PVar "a") (PVar "b") (PVar "c") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "exprFiles") (EVar "a")) (EApp (EVar "exprFiles") (EVar "b"))) (EApp (EVar "exprFiles") (EVar "c"))))
(DFunDef false "exprFiles" ((PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EDictApp "flatMap") (EVar "stmtFiles")) (EVar "stmts")))
(DFunDef false "exprFiles" ((PCon "CMethod" PWild PWild)) (EListLit))
(DFunDef false "exprFiles" ((PCon "CDict" PWild PWild)) (EListLit))
(DTypeSig false "programFiles" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "programFiles" ((PCon "CProgram" (PVar "binds") PWild PWild (PVar "impls") PWild PWild)) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "entries") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "bindFiles")) (EVar "binds")) (EApp (EApp (EDictApp "flatMap") (EVar "implFiles")) (EVar "impls")))) (EVar "omEmpty")))))
(DTypeSig false "assign" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyTuple (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyCon "Int"))))))
(DFunDef false "assign" ((PList) (PVar "high") (PVar "table")) (ETuple (EVar "table") (EVar "high")))
(DFunDef false "assign" ((PCons (PVar "name") (PVar "rest")) (PVar "high") (PVar "table")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "table")) (EApp (EApp (EApp (EVar "assign") (EVar "rest")) (EVar "high")) (EVar "table")) (EApp (EApp (EApp (EVar "assign") (EVar "rest")) (EBinOp "+" (EVar "high") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EBinOp "+" (EVar "high") (ELit (LInt 1)))) (EVar "table")))))
(DTypeSig false "ordered" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ordered" ((PVar "high") (PVar "files")) (EBlock (DoLet false false (PVar "reverse") (EApp (EVar "fromList") (EApp (EApp (EMethodRef "map") (ELam ((PVar "pair")) (ETuple (EApp (EVar "snd") (EVar "pair")) (EApp (EVar "fst") (EVar "pair"))))) (EApp (EVar "entries") (EVar "files"))))) (DoExpr (EIf (EBinOp "<" (EVar "high") (ELit (LInt 1))) (EListLit) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EApp (EVar "get") (EVar "n")) (EVar "reverse"))))) (ERangeList (ELit (LInt 1)) (EVar "high") true))))))
(DTypeSig false "mapDefects" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "mapDefects" ((PVar "label") (PVar "low") (PVar "limit") (PVar "high") (PVar "table")) (EBlock (DoLet false false (PVar "rows") (EApp (EVar "entries") (EVar "table"))) (DoLet false false (PVar "invalid") (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EApp (EVar "assignmentDefect") (EVar "label")) (EVar "low")) (EVar "limit")) (EVar "high"))) (EVar "rows"))) (DoLet false false (PVar "nums") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EVar "intToString") (EApp (EVar "snd") (EVar "p"))))) (EVar "rows"))) (DoExpr (EBinOp "++" (EVar "invalid") (EIf (EBinOp "/=" (EApp (EMethodRef "length") (EApp (EVar "entries") (EApp (EApp (EVar "omFromNames") (EVar "nums")) (EVar "omEmpty")))) (EApp (EMethodRef "length") (EVar "nums"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "identity: duplicate ")) (EVar "label")) (ELit (LString " number")))) (EListLit))))))
(DTypeSig false "assignmentDefect" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "assignmentDefect" ((PVar "label") (PVar "low") (PVar "limit") (PVar "high") (PTuple (PVar "name") (PVar "n"))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString ""))) (EBinOp "<" (EVar "n") (EVar "low"))) (EBinOp ">=" (EVar "n") (EVar "limit"))) (EBinOp ">" (EVar "n") (EVar "high"))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "identity: invalid ")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString " assignment "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "")))) (EListLit)))
(DTypeSig false "packageDefects" (TyFun (TyCon "PackageIdentity") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "packageDefects" ((PVar "p")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EIf (EBinOp "==" (EFieldAccess (EVar "p") "abi") (EVar "abiVersion")) (EListLit) (EListLit (ELit (LString "identity: incompatible ABI")))) (EIf (EBinOp "&&" (EBinOp ">=" (EFieldAccess (EVar "p") "typeHigh") (ELit (LInt 0))) (EBinOp "<" (EFieldAccess (EVar "p") "typeHigh") (EVar "reservedTypeBase"))) (EListLit) (EListLit (ELit (LString "identity: invalid type high-water mark"))))) (EIf (EBinOp "&&" (EBinOp ">=" (EFieldAccess (EVar "p") "fileHigh") (ELit (LInt 0))) (EBinOp "<" (EFieldAccess (EVar "p") "fileHigh") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteFileBits")))) (EListLit) (EListLit (ELit (LString "identity: invalid file high-water mark"))))) (EApp (EApp (EApp (EApp (EApp (EVar "mapDefects") (ELit (LString "type"))) (ELit (LInt 1))) (EVar "reservedTypeBase")) (EFieldAccess (EVar "p") "typeHigh")) (EFieldAccess (EVar "p") "types"))) (EApp (EApp (EApp (EApp (EApp (EVar "mapDefects") (ELit (LString "file"))) (ELit (LInt 1))) (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteFileBits"))) (EFieldAccess (EVar "p") "fileHigh")) (EFieldAccess (EVar "p") "files"))))
(DTypeSig true "planProgramIdentity" (TyFun (TyCon "PackageIdentity") (TyFun (TyCon "CProgram") (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "IdentityPlan")))))
(DFunDef false "planProgramIdentity" ((PVar "imported") (PVar "cp")) (EBlock (DoLet false false (PTuple (PVar "types") (PVar "typeHigh")) (EApp (EApp (EApp (EVar "assign") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "entries") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EApp (EVar "planConstructors") (EVar "cp")) "typeOrder")) (EVar "omEmpty"))))) (EFieldAccess (EVar "imported") "typeHigh")) (EFieldAccess (EVar "imported") "types"))) (DoLet false false (PTuple (PVar "files") (PVar "fileHigh")) (EApp (EApp (EApp (EVar "assign") (EApp (EVar "programFiles") (EVar "cp"))) (EFieldAccess (EVar "imported") "fileHigh")) (EFieldAccess (EVar "imported") "files"))) (DoLet false false (PVar "defects") (EBinOp "++" (EBinOp "++" (EApp (EVar "packageDefects") (EVar "imported")) (EIf (EBinOp "<" (EVar "typeHigh") (EVar "reservedTypeBase")) (EListLit) (EListLit (ELit (LString "identity: type IDs exhausted"))))) (EIf (EBinOp "<" (EVar "fileHigh") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteFileBits"))) (EListLit) (EListLit (ELit (LString "identity: file IDs exhausted")))))) (DoExpr (EIf (EApp (EMethodRef "isEmpty") (EVar "defects")) (EApp (EVar "Ok") (ERecordCreate "IdentityPlan" ((fa "imported" (EVar "imported")) (fa "types" (EVar "types")) (fa "files" (EVar "files")) (fa "orderedFiles" (EApp (EApp (EVar "ordered") (EVar "fileHigh")) (EVar "files")))))) (EApp (EVar "Err") (EVar "defects"))))))
(DTypeSig true "planPackageIdentity" (TyFun (TyCon "String") (TyFun (TyCon "CProgram") (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "PackageIdentity")))))
(DFunDef false "planPackageIdentity" ((PVar "fingerprint") (PVar "cp")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "plan")) (ERecordCreate "PackageIdentity" ((fa "fingerprint" (EVar "fingerprint")) (fa "abi" (EVar "abiVersion")) (fa "types" (EFieldAccess (EAnnot (EVar "plan") (TyCon "IdentityPlan")) "types")) (fa "files" (EFieldAccess (EAnnot (EVar "plan") (TyCon "IdentityPlan")) "files")) (fa "typeHigh" (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "n") (PVar "pair")) (EApp (EApp (EMethodRef "max") (EVar "n")) (EApp (EVar "snd") (EVar "pair"))))) (ELit (LInt 0))) (EApp (EVar "entries") (EFieldAccess (EAnnot (EVar "plan") (TyCon "IdentityPlan")) "types")))) (fa "fileHigh" (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "n") (PVar "pair")) (EApp (EApp (EMethodRef "max") (EVar "n")) (EApp (EVar "snd") (EVar "pair"))))) (ELit (LInt 0))) (EApp (EVar "entries") (EFieldAccess (EAnnot (EVar "plan") (TyCon "IdentityPlan")) "files")))))))) (EApp (EApp (EVar "planProgramIdentity") (EVar "emptyPackage")) (EVar "cp"))))
(DTypeSig true "validateIdentityPlan" (TyFun (TyCon "CProgram") (TyFun (TyCon "IdentityPlan") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "validateIdentityPlan" ((PVar "cp") (PVar "plan")) (EBlock (DoLet false false (PVar "imported") (EFieldAccess (EVar "plan") "imported")) (DoLet false false (PVar "typeHigh") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "n") (PVar "pair")) (EApp (EApp (EMethodRef "max") (EVar "n")) (EApp (EVar "snd") (EVar "pair"))))) (EFieldAccess (EVar "imported") "typeHigh")) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "types")))) (DoLet false false (PVar "fileHigh") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "n") (PVar "pair")) (EApp (EApp (EMethodRef "max") (EVar "n")) (EApp (EVar "snd") (EVar "pair"))))) (EFieldAccess (EVar "imported") "fileHigh")) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "files")))) (DoLet false false (PTuple (PVar "expectedTypes") PWild) (EApp (EApp (EApp (EVar "assign") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "types")))) (EFieldAccess (EVar "imported") "typeHigh")) (EFieldAccess (EVar "imported") "types"))) (DoLet false false (PTuple (PVar "expectedFiles") PWild) (EApp (EApp (EApp (EVar "assign") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "files")))) (EFieldAccess (EVar "imported") "fileHigh")) (EFieldAccess (EVar "imported") "files"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "packageDefects") (EVar "imported")) (EApp (EApp (EApp (EApp (EApp (EVar "mapDefects") (ELit (LString "type"))) (ELit (LInt 1))) (EVar "reservedTypeBase")) (EVar "typeHigh")) (EFieldAccess (EVar "plan") "types"))) (EApp (EApp (EApp (EApp (EApp (EVar "mapDefects") (ELit (LString "file"))) (ELit (LInt 1))) (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteFileBits"))) (EVar "fileHigh")) (EFieldAccess (EVar "plan") "files"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "importDefect") (ELit (LString "type"))) (EFieldAccess (EVar "plan") "types"))) (EApp (EVar "entries") (EFieldAccess (EVar "imported") "types")))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "importDefect") (ELit (LString "file"))) (EFieldAccess (EVar "plan") "files"))) (EApp (EVar "entries") (EFieldAccess (EVar "imported") "files")))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "plan") "types")) (EListLit) (EListLit (EBinOp "++" (ELit (LString "identity: missing type ")) (EVar "name")))))) (EFieldAccess (EApp (EVar "planConstructors") (EVar "cp")) "typeOrder"))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "plan") "files")) (EListLit) (EListLit (EBinOp "++" (ELit (LString "identity: missing file ")) (EVar "name")))))) (EApp (EVar "programFiles") (EVar "cp")))) (EIf (EBinOp "==" (EApp (EVar "entries") (EVar "expectedTypes")) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "types"))) (EListLit) (EListLit (ELit (LString "identity: type allocation disagrees"))))) (EIf (EBinOp "==" (EApp (EVar "entries") (EVar "expectedFiles")) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "files"))) (EListLit) (EListLit (ELit (LString "identity: file allocation disagrees"))))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "localDefect") (ELit (LString "type"))) (EFieldAccess (EVar "imported") "typeHigh")) (EFieldAccess (EVar "imported") "types"))) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "types")))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "localDefect") (ELit (LString "file"))) (EFieldAccess (EVar "imported") "fileHigh")) (EFieldAccess (EVar "imported") "files"))) (EApp (EVar "entries") (EFieldAccess (EVar "plan") "files")))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "fileHigh") (ELit (LInt 0))) (EBinOp "<" (EVar "fileHigh") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteFileBits")))) (EBinOp "==" (EFieldAccess (EVar "plan") "orderedFiles") (EApp (EApp (EVar "ordered") (EVar "fileHigh")) (EFieldAccess (EVar "plan") "files")))) (EListLit) (EListLit (ELit (LString "identity: file table disagrees"))))))))
(DTypeSig false "localDefect" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "localDefect" ((PVar "label") (PVar "high") (PVar "imported") (PTuple (PVar "name") (PVar "n"))) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "imported"))) (EBinOp "<=" (EVar "n") (EVar "high"))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "identity: local ")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString " uses reserved hole "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "")))) (EListLit)))
(DTypeSig false "importDefect" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "importDefect" ((PVar "label") (PVar "table") (PTuple (PVar "name") (PVar "n"))) (EIf (EBinOp "==" (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "table")) (EApp (EVar "Some") (EVar "n"))) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "identity: imported ")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString " changed "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))))
(DTypeSig true "packSite" (TyFun (TyCon "IdentityPlan") (TyFun (TyCon "Loc") (TyCon "Int"))))
(DFunDef false "packSite" ((PVar "plan") (PAs "loc" (PCon "Loc" (PVar "f") (PVar "line") (PVar "col") PWild PWild))) (EIf (EApp (EVar "not") (EApp (EVar "sitePackable") (EVar "loc"))) (ELit (LInt 0)) (EMatch (EApp (EApp (EVar "omLookup") (EVar "f")) (EFieldAccess (EVar "plan") "files")) (arm (PCon "None") () (ELit (LInt 0))) (arm (PCon "Some" (PVar "n")) () (EBinOp "+" (EBinOp "+" (EBinOp "*" (EVar "n") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteFileShift"))) (EBinOp "*" (EVar "line") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "siteLineShift")))) (EVar "col"))))))
