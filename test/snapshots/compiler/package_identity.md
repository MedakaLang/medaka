# META
source_lines=311
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
exprFiles files (CIndex a b) = exprFiles (exprFiles files a) b
exprFiles files (CSlice a b c _) = exprFiles (exprFiles (exprFiles files a) b) c
exprFiles files (CStringIndex a b) = exprFiles (exprFiles files a) b
exprFiles files (CStringSlice a b c _) =
  exprFiles (exprFiles (exprFiles files a) b) c
exprFiles files (CListIndex a b) = exprFiles (exprFiles files a) b
exprFiles files (CListSlice a b c _) =
  exprFiles (exprFiles (exprFiles files a) b) c
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

export
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
(DFunDef false "exprFiles" ((PVar "files") (PCon "CIndex" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "a"))) (EVar "b")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CSlice" (PVar "a") (PVar "b") (PVar "c") PWild)) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "a"))) (EVar "b"))) (EVar "c")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CStringIndex" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "a"))) (EVar "b")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CStringSlice" (PVar "a") (PVar "b") (PVar "c") PWild)) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "a"))) (EVar "b"))) (EVar "c")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CListIndex" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "a"))) (EVar "b")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CListSlice" (PVar "a") (PVar "b") (PVar "c") PWild)) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "a"))) (EVar "b"))) (EVar "c")))
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
(DTypeSig false "mapDefects" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "mapDefects" ((PVar "label") (PVar "low") (PVar "limit") (PVar "high") (PVar "table")) (EBlock (DoLet false false (PVar "rows") (EApp (EVar "entries") (EVar "table"))) (DoLet false false (PVar "invalid") (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EApp (EVar "assignmentDefect") (EVar "label")) (EVar "low")) (EVar "limit")) (EVar "high"))) (EVar "rows"))) (DoLet false false (PVar "nums") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EVar "intToString") (EApp (EVar "snd") (EVar "p"))))) (EVar "rows"))) (DoExpr (EBinOp "++" (EVar "invalid") (EIf (EBinOp "/=" (EApp (EVar "length") (EApp (EVar "entries") (EApp (EApp (EVar "omFromNames") (EVar "nums")) (EVar "omEmpty")))) (EApp (EVar "length") (EVar "nums"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "identity: duplicate ")) (EVar "label")) (ELit (LString " number")))) (EListLit))))))
(DTypeSig false "assignmentDefect" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "assignmentDefect" ((PVar "label") (PVar "low") (PVar "limit") (PVar "high") (PTuple (PVar "name") (PVar "n"))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString ""))) (EBinOp "<" (EVar "n") (EVar "low"))) (EBinOp ">=" (EVar "n") (EVar "limit"))) (EBinOp ">" (EVar "n") (EVar "high"))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "identity: invalid ")) (EApp (EVar "display") (EVar "label"))) (ELit (LString " assignment "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "")))) (EListLit)))
(DTypeSig true "packageDefects" (TyFun (TyCon "PackageIdentity") (TyApp (TyCon "List") (TyCon "String"))))
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
(DFunDef false "exprFiles" ((PVar "files") (PCon "CIndex" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "a"))) (EVar "b")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CSlice" (PVar "a") (PVar "b") (PVar "c") PWild)) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "a"))) (EVar "b"))) (EVar "c")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CStringIndex" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "a"))) (EVar "b")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CStringSlice" (PVar "a") (PVar "b") (PVar "c") PWild)) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "a"))) (EVar "b"))) (EVar "c")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CListIndex" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "a"))) (EVar "b")))
(DFunDef false "exprFiles" ((PVar "files") (PCon "CListSlice" (PVar "a") (PVar "b") (PVar "c") PWild)) (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EApp (EApp (EVar "exprFiles") (EVar "files")) (EVar "a"))) (EVar "b"))) (EVar "c")))
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
(DTypeSig false "mapDefects" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "mapDefects" ((PVar "label") (PVar "low") (PVar "limit") (PVar "high") (PVar "table")) (EBlock (DoLet false false (PVar "rows") (EApp (EVar "entries") (EVar "table"))) (DoLet false false (PVar "invalid") (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EApp (EVar "assignmentDefect") (EVar "label")) (EVar "low")) (EVar "limit")) (EVar "high"))) (EVar "rows"))) (DoLet false false (PVar "nums") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EVar "intToString") (EApp (EVar "snd") (EVar "p"))))) (EVar "rows"))) (DoExpr (EBinOp "++" (EVar "invalid") (EIf (EBinOp "/=" (EApp (EMethodRef "length") (EApp (EVar "entries") (EApp (EApp (EVar "omFromNames") (EVar "nums")) (EVar "omEmpty")))) (EApp (EMethodRef "length") (EVar "nums"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "identity: duplicate ")) (EVar "label")) (ELit (LString " number")))) (EListLit))))))
(DTypeSig false "assignmentDefect" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "assignmentDefect" ((PVar "label") (PVar "low") (PVar "limit") (PVar "high") (PTuple (PVar "name") (PVar "n"))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString ""))) (EBinOp "<" (EVar "n") (EVar "low"))) (EBinOp ">=" (EVar "n") (EVar "limit"))) (EBinOp ">" (EVar "n") (EVar "high"))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "identity: invalid ")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString " assignment "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "")))) (EListLit)))
(DTypeSig true "packageDefects" (TyFun (TyCon "PackageIdentity") (TyApp (TyCon "List") (TyCon "String"))))
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
