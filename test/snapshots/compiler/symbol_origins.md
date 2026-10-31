# META
source_lines=159
stages=DESUGAR,MARK
# SOURCE
import frontend.ast.{BinderId(..), Decl(..), LetBind(..), variantName}
import types.route_key.{typeTagOf}
import support.ordmap.{OrdMap, omEmpty, omLookup, omInsert}
import support.symbol_encoding.{encodeComponent}
import support.util.{joinWith}
import map.{Map(..), get, set, foldlWithKey}

public export data SymbolOrigin =
  | ModuleOrigin String String
  | SingleOrigin String
  | GeneratedOrigin String (List String)
  | BuiltinOrigin String
  deriving (Eq, Debug)

public export data OriginRow = OriginRow {
  binder : BinderId,
  origin : SymbolOrigin,
}
public export data SymbolOrigins = SymbolOrigins {
  functions : Map Int (OrdMap OriginRow),
  constructors : OrdMap (OrdMap SymbolOrigin),
}
public export data CoreSymbolOrigins = CoreSymbolOrigins {
  functions : OrdMap SymbolOrigin,
  constructors : OrdMap (OrdMap SymbolOrigin),
}

export
emptyOrigins : SymbolOrigins
emptyOrigins = SymbolOrigins { functions = Tip, constructors = omEmpty }

export
originKey : SymbolOrigin -> String
originKey (ModuleOrigin mid name) =
  "m.\{encodeComponent mid}.\{encodeComponent name}"
originKey (SingleOrigin name) = "s." ++ encodeComponent name
originKey (BuiltinOrigin tag) = "b." ++ encodeComponent tag
originKey (GeneratedOrigin family parts) =
  let encoded = joinWith "." (map encodeComponent parts)
  "g.\{encodeComponent family}.\{intToString (length parts)}.\{encoded}"

ordinal : BinderId -> Int
ordinal (BinderId _ i) = i

sameBinder : BinderId -> BinderId -> Bool
sameBinder (BinderId m i) (BinderId n j) = i == j && (i < 0 || m == n)

export
functionOrigin : SymbolOrigins -> BinderId -> String -> SymbolOrigin
functionOrigin origins bid name = match get (ordinal bid) origins.functions
  None => panic "symbol origin: missing function ordinal"
  Some rows => match omLookup name rows
    None => panic "symbol origin: missing function name"
    Some row =>
      if sameBinder bid row.binder then
        row.origin
      else
        panic "symbol origin: binder mismatch"

addFunction : String ->
  BinderId ->
  SymbolOrigin ->
  SymbolOrigins ->
  SymbolOrigins
addFunction name bid origin origins =
  let i = ordinal bid
  let rows = optionOr omEmpty (get i origins.functions)
  let row = OriginRow { binder = bid, origin = origin }
  match omLookup name rows
    Some old =>
      if sameBinder bid old.binder && old.origin == origin then
        origins
      else
        panic "symbol origin: conflicting function"
    None =>
      { origins | functions = set i (omInsert name row rows) origins.functions }

addConstructor : String ->
  String ->
  SymbolOrigin ->
  SymbolOrigins ->
  SymbolOrigins
addConstructor owner name origin origins =
  let rows = optionOr omEmpty (omLookup owner origins.constructors)
  match omLookup name rows
    Some old =>
      if old == origin then
        origins
      else
        panic "symbol origin: conflicting constructor"
    None => { origins |
      constructors =
        omInsert owner (omInsert name origin rows) origins.constructors,
    }

renamed : OrdMap String -> String -> String
renamed rm name = optionOr name (omLookup name rm)

unitDecl : (String -> SymbolOrigin) ->
  OrdMap String ->
  SymbolOrigins ->
  Decl ->
  SymbolOrigins
unitDecl origin rm acc (DFunDef _ n _ _ _ bid) =
  addFunction (renamed rm n) bid (origin n) acc
unitDecl origin rm acc (DLetGroup _ binds) = fold (unitBind origin rm) acc binds
unitDecl origin rm acc (DData { dataName = n, dataOrigin = o, dataCtors = variants }) =
  fold
    (a v =>
      addConstructor
        (typeTagOf o n)
        (renamed rm (variantName v))
        (origin (variantName v))
        a)
    acc
    variants
unitDecl origin rm acc (DNewtype { newtypeName = n, newtypeOrigin = o, newtypeCtor = c }) =
  addConstructor (typeTagOf o n) (renamed rm c) (origin c) acc
unitDecl origin rm acc (DAttrib _ d) = unitDecl origin rm acc d
unitDecl _ _ acc _ = acc

unitBind : (String -> SymbolOrigin) ->
  OrdMap String ->
  SymbolOrigins ->
  LetBind ->
  SymbolOrigins
unitBind origin rm acc (LetBind n _ _ bid) =
  addFunction (renamed rm n) bid (origin n) acc

export
unitOrigins : String -> OrdMap String -> List Decl -> SymbolOrigins
unitOrigins mid rm decls =
  fold (unitDecl (ModuleOrigin mid) rm) emptyOrigins decls

export
singleProgramOrigins : List Decl -> SymbolOrigins
singleProgramOrigins decls =
  fold (unitDecl SingleOrigin omEmpty) emptyOrigins decls

export
mergeOrigins : SymbolOrigins -> SymbolOrigins -> SymbolOrigins
mergeOrigins a b =
  let withFunctions =
    foldlWithKey
      (acc _ rows =>
        foldlWithKey
          (next name row => addFunction name row.binder row.origin next)
          acc
          rows)
      a
      b.functions
  foldlWithKey
    (acc owner rows =>
      foldlWithKey
        (next name origin => addConstructor owner name origin next)
        acc
        rows)
    withFunctions
    b.constructors
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "BinderId" true) (mem "Decl" true) (mem "LetBind" true) (mem "variantName" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "typeTagOf" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omLookup" false) (mem "omInsert" false))))
(DUse false (UseGroup ("support" "symbol_encoding") ((mem "encodeComponent" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false))))
(DUse false (UseGroup ("map") ((mem "Map" true) (mem "get" false) (mem "set" false) (mem "foldlWithKey" false))))
(DData Public "SymbolOrigin" () ((variant "ModuleOrigin" (ConPos (TyCon "String") (TyCon "String"))) (variant "SingleOrigin" (ConPos (TyCon "String"))) (variant "GeneratedOrigin" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (variant "BuiltinOrigin" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "SymbolOrigin")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ModuleOrigin" (PVar "__a0") (PVar "__a1")) (PCon "ModuleOrigin" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "SingleOrigin" (PVar "__a0")) (PCon "SingleOrigin" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "GeneratedOrigin" (PVar "__a0") (PVar "__a1")) (PCon "GeneratedOrigin" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "BuiltinOrigin" (PVar "__a0")) (PCon "BuiltinOrigin" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "SymbolOrigin")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "ModuleOrigin" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ModuleOrigin ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1"))))) (arm (PCon "SingleOrigin" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SingleOrigin ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "GeneratedOrigin" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "GeneratedOrigin ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1"))))) (arm (PCon "BuiltinOrigin" (PVar "__a0")) () (EBinOp "++" (ELit (LString "BuiltinOrigin ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))))))))
(DData Public "OriginRow" () ((variant "OriginRow" (ConNamed (field "binder" (TyCon "BinderId")) (field "origin" (TyCon "SymbolOrigin"))))) ())
(DData Public "SymbolOrigins" () ((variant "SymbolOrigins" (ConNamed (field "functions" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "OriginRow")))) (field "constructors" (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "SymbolOrigin"))))))) ())
(DData Public "CoreSymbolOrigins" () ((variant "CoreSymbolOrigins" (ConNamed (field "functions" (TyApp (TyCon "OrdMap") (TyCon "SymbolOrigin"))) (field "constructors" (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "SymbolOrigin"))))))) ())
(DTypeSig true "emptyOrigins" (TyCon "SymbolOrigins"))
(DFunDef false "emptyOrigins" () (ERecordCreate "SymbolOrigins" ((fa "functions" (EVar "Tip")) (fa "constructors" (EVar "omEmpty")))))
(DTypeSig true "originKey" (TyFun (TyCon "SymbolOrigin") (TyCon "String")))
(DFunDef false "originKey" ((PCon "ModuleOrigin" (PVar "mid") (PVar "name"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "m.")) (EApp (EVar "display") (EApp (EVar "encodeComponent") (EVar "mid")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "encodeComponent") (EVar "name")))) (ELit (LString ""))))
(DFunDef false "originKey" ((PCon "SingleOrigin" (PVar "name"))) (EBinOp "++" (ELit (LString "s.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "originKey" ((PCon "BuiltinOrigin" (PVar "tag"))) (EBinOp "++" (ELit (LString "b.")) (EApp (EVar "encodeComponent") (EVar "tag"))))
(DFunDef false "originKey" ((PCon "GeneratedOrigin" (PVar "family") (PVar "parts"))) (EBlock (DoLet false false (PVar "encoded") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EApp (EApp (EVar "map") (EVar "encodeComponent")) (EVar "parts")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "g.")) (EApp (EVar "display") (EApp (EVar "encodeComponent") (EVar "family")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "length") (EVar "parts"))))) (ELit (LString "."))) (EApp (EVar "display") (EVar "encoded"))) (ELit (LString ""))))))
(DTypeSig false "ordinal" (TyFun (TyCon "BinderId") (TyCon "Int")))
(DFunDef false "ordinal" ((PCon "BinderId" PWild (PVar "i"))) (EVar "i"))
(DTypeSig false "sameBinder" (TyFun (TyCon "BinderId") (TyFun (TyCon "BinderId") (TyCon "Bool"))))
(DFunDef false "sameBinder" ((PCon "BinderId" (PVar "m") (PVar "i")) (PCon "BinderId" (PVar "n") (PVar "j"))) (EBinOp "&&" (EBinOp "==" (EVar "i") (EVar "j")) (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp "==" (EVar "m") (EVar "n")))))
(DTypeSig true "functionOrigin" (TyFun (TyCon "SymbolOrigins") (TyFun (TyCon "BinderId") (TyFun (TyCon "String") (TyCon "SymbolOrigin")))))
(DFunDef false "functionOrigin" ((PVar "origins") (PVar "bid") (PVar "name")) (EMatch (EApp (EApp (EVar "get") (EApp (EVar "ordinal") (EVar "bid"))) (EFieldAccess (EVar "origins") "functions")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "symbol origin: missing function ordinal")))) (arm (PCon "Some" (PVar "rows")) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "rows")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "symbol origin: missing function name")))) (arm (PCon "Some" (PVar "row")) () (EIf (EApp (EApp (EVar "sameBinder") (EVar "bid")) (EFieldAccess (EVar "row") "binder")) (EFieldAccess (EVar "row") "origin") (EApp (EVar "panic") (ELit (LString "symbol origin: binder mismatch")))))))))
(DTypeSig false "addFunction" (TyFun (TyCon "String") (TyFun (TyCon "BinderId") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolOrigins") (TyCon "SymbolOrigins"))))))
(DFunDef false "addFunction" ((PVar "name") (PVar "bid") (PVar "origin") (PVar "origins")) (EBlock (DoLet false false (PVar "i") (EApp (EVar "ordinal") (EVar "bid"))) (DoLet false false (PVar "rows") (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "get") (EVar "i")) (EFieldAccess (EVar "origins") "functions")))) (DoLet false false (PVar "row") (ERecordCreate "OriginRow" ((fa "binder" (EVar "bid")) (fa "origin" (EVar "origin"))))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "rows")) (arm (PCon "Some" (PVar "old")) () (EIf (EBinOp "&&" (EApp (EApp (EVar "sameBinder") (EVar "bid")) (EFieldAccess (EVar "old") "binder")) (EBinOp "==" (EFieldAccess (EVar "old") "origin") (EVar "origin"))) (EVar "origins") (EApp (EVar "panic") (ELit (LString "symbol origin: conflicting function"))))) (arm (PCon "None") () (ERecordUpdate (EVar "origins") ((fa "functions" (EApp (EApp (EApp (EVar "set") (EVar "i")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "row")) (EVar "rows"))) (EFieldAccess (EVar "origins") "functions"))))))))))
(DTypeSig false "addConstructor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolOrigins") (TyCon "SymbolOrigins"))))))
(DFunDef false "addConstructor" ((PVar "owner") (PVar "name") (PVar "origin") (PVar "origins")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EVar "owner")) (EFieldAccess (EVar "origins") "constructors")))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "rows")) (arm (PCon "Some" (PVar "old")) () (EIf (EBinOp "==" (EVar "old") (EVar "origin")) (EVar "origins") (EApp (EVar "panic") (ELit (LString "symbol origin: conflicting constructor"))))) (arm (PCon "None") () (ERecordUpdate (EVar "origins") ((fa "constructors" (EApp (EApp (EApp (EVar "omInsert") (EVar "owner")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "origin")) (EVar "rows"))) (EFieldAccess (EVar "origins") "constructors"))))))))))
(DTypeSig false "renamed" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "renamed" ((PVar "rm") (PVar "name")) (EApp (EApp (EVar "optionOr") (EVar "name")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "rm"))))
(DTypeSig false "unitDecl" (TyFun (TyFun (TyCon "String") (TyCon "SymbolOrigin")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "SymbolOrigins") (TyFun (TyCon "Decl") (TyCon "SymbolOrigins"))))))
(DFunDef false "unitDecl" ((PVar "origin") (PVar "rm") (PVar "acc") (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "addFunction") (EApp (EApp (EVar "renamed") (EVar "rm")) (EVar "n"))) (EVar "bid")) (EApp (EVar "origin") (EVar "n"))) (EVar "acc")))
(DFunDef false "unitDecl" ((PVar "origin") (PVar "rm") (PVar "acc") (PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EApp (EVar "fold") (EApp (EApp (EVar "unitBind") (EVar "origin")) (EVar "rm"))) (EVar "acc")) (EVar "binds")))
(DFunDef false "unitDecl" ((PVar "origin") (PVar "rm") (PVar "acc") (PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataOrigin" (PVar "o")) (rf "dataCtors" (PVar "variants"))) false)) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "a") (PVar "v")) (EApp (EApp (EApp (EApp (EVar "addConstructor") (EApp (EApp (EVar "typeTagOf") (EVar "o")) (EVar "n"))) (EApp (EApp (EVar "renamed") (EVar "rm")) (EApp (EVar "variantName") (EVar "v")))) (EApp (EVar "origin") (EApp (EVar "variantName") (EVar "v")))) (EVar "a")))) (EVar "acc")) (EVar "variants")))
(DFunDef false "unitDecl" ((PVar "origin") (PVar "rm") (PVar "acc") (PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeOrigin" (PVar "o")) (rf "newtypeCtor" (PVar "c"))) false)) (EApp (EApp (EApp (EApp (EVar "addConstructor") (EApp (EApp (EVar "typeTagOf") (EVar "o")) (EVar "n"))) (EApp (EApp (EVar "renamed") (EVar "rm")) (EVar "c"))) (EApp (EVar "origin") (EVar "c"))) (EVar "acc")))
(DFunDef false "unitDecl" ((PVar "origin") (PVar "rm") (PVar "acc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "unitDecl") (EVar "origin")) (EVar "rm")) (EVar "acc")) (EVar "d")))
(DFunDef false "unitDecl" (PWild PWild (PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "unitBind" (TyFun (TyFun (TyCon "String") (TyCon "SymbolOrigin")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "SymbolOrigins") (TyFun (TyCon "LetBind") (TyCon "SymbolOrigins"))))))
(DFunDef false "unitBind" ((PVar "origin") (PVar "rm") (PVar "acc") (PCon "LetBind" (PVar "n") PWild PWild (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "addFunction") (EApp (EApp (EVar "renamed") (EVar "rm")) (EVar "n"))) (EVar "bid")) (EApp (EVar "origin") (EVar "n"))) (EVar "acc")))
(DTypeSig true "unitOrigins" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "SymbolOrigins")))))
(DFunDef false "unitOrigins" ((PVar "mid") (PVar "rm") (PVar "decls")) (EApp (EApp (EApp (EVar "fold") (EApp (EApp (EVar "unitDecl") (EApp (EVar "ModuleOrigin") (EVar "mid"))) (EVar "rm"))) (EVar "emptyOrigins")) (EVar "decls")))
(DTypeSig true "singleProgramOrigins" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "SymbolOrigins")))
(DFunDef false "singleProgramOrigins" ((PVar "decls")) (EApp (EApp (EApp (EVar "fold") (EApp (EApp (EVar "unitDecl") (EVar "SingleOrigin")) (EVar "omEmpty"))) (EVar "emptyOrigins")) (EVar "decls")))
(DTypeSig true "mergeOrigins" (TyFun (TyCon "SymbolOrigins") (TyFun (TyCon "SymbolOrigins") (TyCon "SymbolOrigins"))))
(DFunDef false "mergeOrigins" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "withFunctions") (EApp (EApp (EApp (EVar "foldlWithKey") (ELam ((PVar "acc") PWild (PVar "rows")) (EApp (EApp (EApp (EVar "foldlWithKey") (ELam ((PVar "next") (PVar "name") (PVar "row")) (EApp (EApp (EApp (EApp (EVar "addFunction") (EVar "name")) (EFieldAccess (EVar "row") "binder")) (EFieldAccess (EVar "row") "origin")) (EVar "next")))) (EVar "acc")) (EVar "rows")))) (EVar "a")) (EFieldAccess (EVar "b") "functions"))) (DoExpr (EApp (EApp (EApp (EVar "foldlWithKey") (ELam ((PVar "acc") (PVar "owner") (PVar "rows")) (EApp (EApp (EApp (EVar "foldlWithKey") (ELam ((PVar "next") (PVar "name") (PVar "origin")) (EApp (EApp (EApp (EApp (EVar "addConstructor") (EVar "owner")) (EVar "name")) (EVar "origin")) (EVar "next")))) (EVar "acc")) (EVar "rows")))) (EVar "withFunctions")) (EFieldAccess (EVar "b") "constructors")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "BinderId" true) (mem "Decl" true) (mem "LetBind" true) (mem "variantName" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "typeTagOf" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omLookup" false) (mem "omInsert" false))))
(DUse false (UseGroup ("support" "symbol_encoding") ((mem "encodeComponent" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false))))
(DUse false (UseGroup ("map") ((mem "Map" true) (mem "get" false) (mem "set" false) (mem "foldlWithKey" false))))
(DData Public "SymbolOrigin" () ((variant "ModuleOrigin" (ConPos (TyCon "String") (TyCon "String"))) (variant "SingleOrigin" (ConPos (TyCon "String"))) (variant "GeneratedOrigin" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (variant "BuiltinOrigin" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "SymbolOrigin")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ModuleOrigin" (PVar "__a0") (PVar "__a1")) (PCon "ModuleOrigin" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "SingleOrigin" (PVar "__a0")) (PCon "SingleOrigin" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "GeneratedOrigin" (PVar "__a0") (PVar "__a1")) (PCon "GeneratedOrigin" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "BuiltinOrigin" (PVar "__a0")) (PCon "BuiltinOrigin" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "SymbolOrigin")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "ModuleOrigin" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ModuleOrigin ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1"))))) (arm (PCon "SingleOrigin" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SingleOrigin ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "GeneratedOrigin" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "GeneratedOrigin ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1"))))) (arm (PCon "BuiltinOrigin" (PVar "__a0")) () (EBinOp "++" (ELit (LString "BuiltinOrigin ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))))))))
(DData Public "OriginRow" () ((variant "OriginRow" (ConNamed (field "binder" (TyCon "BinderId")) (field "origin" (TyCon "SymbolOrigin"))))) ())
(DData Public "SymbolOrigins" () ((variant "SymbolOrigins" (ConNamed (field "functions" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "OriginRow")))) (field "constructors" (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "SymbolOrigin"))))))) ())
(DData Public "CoreSymbolOrigins" () ((variant "CoreSymbolOrigins" (ConNamed (field "functions" (TyApp (TyCon "OrdMap") (TyCon "SymbolOrigin"))) (field "constructors" (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "SymbolOrigin"))))))) ())
(DTypeSig true "emptyOrigins" (TyCon "SymbolOrigins"))
(DFunDef false "emptyOrigins" () (ERecordCreate "SymbolOrigins" ((fa "functions" (EVar "Tip")) (fa "constructors" (EVar "omEmpty")))))
(DTypeSig true "originKey" (TyFun (TyCon "SymbolOrigin") (TyCon "String")))
(DFunDef false "originKey" ((PCon "ModuleOrigin" (PVar "mid") (PVar "name"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "m.")) (EApp (EMethodRef "display") (EApp (EVar "encodeComponent") (EVar "mid")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "encodeComponent") (EVar "name")))) (ELit (LString ""))))
(DFunDef false "originKey" ((PCon "SingleOrigin" (PVar "name"))) (EBinOp "++" (ELit (LString "s.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "originKey" ((PCon "BuiltinOrigin" (PVar "tag"))) (EBinOp "++" (ELit (LString "b.")) (EApp (EVar "encodeComponent") (EVar "tag"))))
(DFunDef false "originKey" ((PCon "GeneratedOrigin" (PVar "family") (PVar "parts"))) (EBlock (DoLet false false (PVar "encoded") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EApp (EApp (EMethodRef "map") (EVar "encodeComponent")) (EVar "parts")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "g.")) (EApp (EMethodRef "display") (EApp (EVar "encodeComponent") (EVar "family")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EMethodRef "length") (EVar "parts"))))) (ELit (LString "."))) (EApp (EMethodRef "display") (EVar "encoded"))) (ELit (LString ""))))))
(DTypeSig false "ordinal" (TyFun (TyCon "BinderId") (TyCon "Int")))
(DFunDef false "ordinal" ((PCon "BinderId" PWild (PVar "i"))) (EVar "i"))
(DTypeSig false "sameBinder" (TyFun (TyCon "BinderId") (TyFun (TyCon "BinderId") (TyCon "Bool"))))
(DFunDef false "sameBinder" ((PCon "BinderId" (PVar "m") (PVar "i")) (PCon "BinderId" (PVar "n") (PVar "j"))) (EBinOp "&&" (EBinOp "==" (EVar "i") (EVar "j")) (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp "==" (EVar "m") (EVar "n")))))
(DTypeSig true "functionOrigin" (TyFun (TyCon "SymbolOrigins") (TyFun (TyCon "BinderId") (TyFun (TyCon "String") (TyCon "SymbolOrigin")))))
(DFunDef false "functionOrigin" ((PVar "origins") (PVar "bid") (PVar "name")) (EMatch (EApp (EApp (EVar "get") (EApp (EVar "ordinal") (EVar "bid"))) (EFieldAccess (EVar "origins") "functions")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "symbol origin: missing function ordinal")))) (arm (PCon "Some" (PVar "rows")) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "rows")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "symbol origin: missing function name")))) (arm (PCon "Some" (PVar "row")) () (EIf (EApp (EApp (EVar "sameBinder") (EVar "bid")) (EFieldAccess (EVar "row") "binder")) (EFieldAccess (EVar "row") "origin") (EApp (EVar "panic") (ELit (LString "symbol origin: binder mismatch")))))))))
(DTypeSig false "addFunction" (TyFun (TyCon "String") (TyFun (TyCon "BinderId") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolOrigins") (TyCon "SymbolOrigins"))))))
(DFunDef false "addFunction" ((PVar "name") (PVar "bid") (PVar "origin") (PVar "origins")) (EBlock (DoLet false false (PVar "i") (EApp (EVar "ordinal") (EVar "bid"))) (DoLet false false (PVar "rows") (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "get") (EVar "i")) (EFieldAccess (EVar "origins") "functions")))) (DoLet false false (PVar "row") (ERecordCreate "OriginRow" ((fa "binder" (EVar "bid")) (fa "origin" (EVar "origin"))))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "rows")) (arm (PCon "Some" (PVar "old")) () (EIf (EBinOp "&&" (EApp (EApp (EVar "sameBinder") (EVar "bid")) (EFieldAccess (EVar "old") "binder")) (EBinOp "==" (EFieldAccess (EVar "old") "origin") (EVar "origin"))) (EVar "origins") (EApp (EVar "panic") (ELit (LString "symbol origin: conflicting function"))))) (arm (PCon "None") () (ERecordUpdate (EVar "origins") ((fa "functions" (EApp (EApp (EApp (EVar "set") (EVar "i")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "row")) (EVar "rows"))) (EFieldAccess (EVar "origins") "functions"))))))))))
(DTypeSig false "addConstructor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolOrigins") (TyCon "SymbolOrigins"))))))
(DFunDef false "addConstructor" ((PVar "owner") (PVar "name") (PVar "origin") (PVar "origins")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EVar "owner")) (EFieldAccess (EVar "origins") "constructors")))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "rows")) (arm (PCon "Some" (PVar "old")) () (EIf (EBinOp "==" (EVar "old") (EVar "origin")) (EVar "origins") (EApp (EVar "panic") (ELit (LString "symbol origin: conflicting constructor"))))) (arm (PCon "None") () (ERecordUpdate (EVar "origins") ((fa "constructors" (EApp (EApp (EApp (EVar "omInsert") (EVar "owner")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "origin")) (EVar "rows"))) (EFieldAccess (EVar "origins") "constructors"))))))))))
(DTypeSig false "renamed" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "renamed" ((PVar "rm") (PVar "name")) (EApp (EApp (EVar "optionOr") (EVar "name")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "rm"))))
(DTypeSig false "unitDecl" (TyFun (TyFun (TyCon "String") (TyCon "SymbolOrigin")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "SymbolOrigins") (TyFun (TyCon "Decl") (TyCon "SymbolOrigins"))))))
(DFunDef false "unitDecl" ((PVar "origin") (PVar "rm") (PVar "acc") (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "addFunction") (EApp (EApp (EVar "renamed") (EVar "rm")) (EVar "n"))) (EVar "bid")) (EApp (EVar "origin") (EVar "n"))) (EVar "acc")))
(DFunDef false "unitDecl" ((PVar "origin") (PVar "rm") (PVar "acc") (PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EApp (EMethodRef "fold") (EApp (EApp (EVar "unitBind") (EVar "origin")) (EVar "rm"))) (EVar "acc")) (EVar "binds")))
(DFunDef false "unitDecl" ((PVar "origin") (PVar "rm") (PVar "acc") (PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataOrigin" (PVar "o")) (rf "dataCtors" (PVar "variants"))) false)) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "a") (PVar "v")) (EApp (EApp (EApp (EApp (EVar "addConstructor") (EApp (EApp (EVar "typeTagOf") (EVar "o")) (EVar "n"))) (EApp (EApp (EVar "renamed") (EVar "rm")) (EApp (EVar "variantName") (EVar "v")))) (EApp (EVar "origin") (EApp (EVar "variantName") (EVar "v")))) (EVar "a")))) (EVar "acc")) (EVar "variants")))
(DFunDef false "unitDecl" ((PVar "origin") (PVar "rm") (PVar "acc") (PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeOrigin" (PVar "o")) (rf "newtypeCtor" (PVar "c"))) false)) (EApp (EApp (EApp (EApp (EVar "addConstructor") (EApp (EApp (EVar "typeTagOf") (EVar "o")) (EVar "n"))) (EApp (EApp (EVar "renamed") (EVar "rm")) (EVar "c"))) (EApp (EVar "origin") (EVar "c"))) (EVar "acc")))
(DFunDef false "unitDecl" ((PVar "origin") (PVar "rm") (PVar "acc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "unitDecl") (EVar "origin")) (EVar "rm")) (EVar "acc")) (EVar "d")))
(DFunDef false "unitDecl" (PWild PWild (PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "unitBind" (TyFun (TyFun (TyCon "String") (TyCon "SymbolOrigin")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "SymbolOrigins") (TyFun (TyCon "LetBind") (TyCon "SymbolOrigins"))))))
(DFunDef false "unitBind" ((PVar "origin") (PVar "rm") (PVar "acc") (PCon "LetBind" (PVar "n") PWild PWild (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "addFunction") (EApp (EApp (EVar "renamed") (EVar "rm")) (EVar "n"))) (EVar "bid")) (EApp (EVar "origin") (EVar "n"))) (EVar "acc")))
(DTypeSig true "unitOrigins" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "SymbolOrigins")))))
(DFunDef false "unitOrigins" ((PVar "mid") (PVar "rm") (PVar "decls")) (EApp (EApp (EApp (EMethodRef "fold") (EApp (EApp (EVar "unitDecl") (EApp (EVar "ModuleOrigin") (EVar "mid"))) (EVar "rm"))) (EVar "emptyOrigins")) (EVar "decls")))
(DTypeSig true "singleProgramOrigins" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "SymbolOrigins")))
(DFunDef false "singleProgramOrigins" ((PVar "decls")) (EApp (EApp (EApp (EMethodRef "fold") (EApp (EApp (EVar "unitDecl") (EVar "SingleOrigin")) (EVar "omEmpty"))) (EVar "emptyOrigins")) (EVar "decls")))
(DTypeSig true "mergeOrigins" (TyFun (TyCon "SymbolOrigins") (TyFun (TyCon "SymbolOrigins") (TyCon "SymbolOrigins"))))
(DFunDef false "mergeOrigins" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "withFunctions") (EApp (EApp (EApp (EVar "foldlWithKey") (ELam ((PVar "acc") PWild (PVar "rows")) (EApp (EApp (EApp (EVar "foldlWithKey") (ELam ((PVar "next") (PVar "name") (PVar "row")) (EApp (EApp (EApp (EApp (EVar "addFunction") (EVar "name")) (EFieldAccess (EVar "row") "binder")) (EFieldAccess (EVar "row") "origin")) (EVar "next")))) (EVar "acc")) (EVar "rows")))) (EVar "a")) (EFieldAccess (EVar "b") "functions"))) (DoExpr (EApp (EApp (EApp (EVar "foldlWithKey") (ELam ((PVar "acc") (PVar "owner") (PVar "rows")) (EApp (EApp (EApp (EVar "foldlWithKey") (ELam ((PVar "next") (PVar "name") (PVar "origin")) (EApp (EApp (EApp (EApp (EVar "addConstructor") (EVar "owner")) (EVar "name")) (EVar "origin")) (EVar "next")))) (EVar "acc")) (EVar "rows")))) (EVar "withFunctions")) (EFieldAccess (EVar "b") "constructors")))))
