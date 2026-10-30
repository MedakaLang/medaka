# META
source_lines=199
stages=DESUGAR,MARK
# SOURCE
import support.symbol_encoding.{encodeComponent}

public export data WasmGeneratedFamily =
  | WLambda
  | WNamedPap
  | WIndirectPap
  | WMethodValue
  | WDictValue
  | WCtorPap
  | WCtorEta
  | WExternEta
  | WWrapper
  | WGroup
  | WConstCell
  | WFfi
  | WDispatch
  | WScratch
  | WGuard
  | WPosition
  | WAbiSelf
  | WAbiArgs
  | WLabelAexd
  | WLabelAexl
  | WLabelAexcd
  | WLabelAexcl
  | WLabelAexfd
  | WLabelAexfl
  | WLabelAfld
  | WLabelAfll
  | WLabelRld
  | WLabelRll
  | WLabelRad
  | WLabelRal
  | WClause
  | WGuardTail
  | WGuardValue
  | WDecision
  | WTmcLoop
  | WTmcExit
  | WSwitch
  | WSwitchTail
  | WTmcTemp
  | WScalarDivr
  | WForceValue
  | WTmcHead
  | WTmcDest
  | WTmcFirst
  | WTmcDctor
  | WDispSavedHead
  | WDispSavedDest
  | WDispSavedFirst
  | WDispResult
  | WSelfClosure
  | W7Rlacc
  | W7Rli
  | W7Rllo
  | W7Raarr
  | W7Rai
  | W7Ralo
  | W7Racnt
  | W7Ixarr
  | W7Ixi
  | W7Slsrc
  | W7Sldst
  | W7Sllo
  | W7Sllen
  | W7Aexi
  | W7Aexn
  | W7Aexarr
  | W7Aexlst
  | W7Aexf
  | W7Aexv
  | W7Aexbits
  | W7Rub
  | W7Divr

public export data WasmName =
  | WUserFunction String
  | WUserGlobal String
  | WGlobalState String
  | WGlobalForcer String
  | WImplMethod String String
  | WDefaultMethod String String String
  | WGenerated WasmGeneratedFamily String Int
  | WUserLocal String
  | WSyntheticLocal WasmGeneratedFamily Int
  | WJSImport String
  | WJSWrapper String
  | WConstGlobal Int
  | WDispatchHead String
  | WDispatchDest String
  | WDispatchFirst String
  | WConstructorType String
  | WUserType String
  | WLabel WasmGeneratedFamily Int
  | WLabelBranch WasmGeneratedFamily Int Int

wasmFamily : WasmGeneratedFamily -> String
wasmFamily WLambda = "lambda"
wasmFamily WNamedPap = "namedpap"
wasmFamily WIndirectPap = "indirectpap"
wasmFamily WMethodValue = "methodvalue"
wasmFamily WDictValue = "dictvalue"
wasmFamily WCtorPap = "ctorpap"
wasmFamily WCtorEta = "ctoreta"
wasmFamily WExternEta = "externeta"
wasmFamily WWrapper = "wrapper"
wasmFamily WGroup = "group"
wasmFamily WConstCell = "constcell"
wasmFamily WFfi = "ffi"
wasmFamily WDispatch = "dispatch"
wasmFamily WScratch = "scratch"
wasmFamily WGuard = "guard"
wasmFamily WPosition = "position"
wasmFamily WAbiSelf = "abiself"
wasmFamily WAbiArgs = "abiargs"
wasmFamily WLabelAexd = "aexd"
wasmFamily WLabelAexl = "aexl"
wasmFamily WLabelAexcd = "aexcd"
wasmFamily WLabelAexcl = "aexcl"
wasmFamily WLabelAexfd = "aexfd"
wasmFamily WLabelAexfl = "aexfl"
wasmFamily WLabelAfld = "afld"
wasmFamily WLabelAfll = "afll"
wasmFamily WLabelRld = "rld"
wasmFamily WLabelRll = "rll"
wasmFamily WLabelRad = "rad"
wasmFamily WLabelRal = "ral"
wasmFamily WClause = "clause"
wasmFamily WGuardTail = "guardtail"
wasmFamily WGuardValue = "guardvalue"
wasmFamily WDecision = "decision"
wasmFamily WTmcLoop = "tmcloop"
wasmFamily WTmcExit = "tmcexit"
wasmFamily WSwitch = "switch"
wasmFamily WSwitchTail = "switchtail"
wasmFamily WTmcTemp = "tmctemp"
wasmFamily WScalarDivr = "scalardivr"
wasmFamily WForceValue = "forcevalue"
wasmFamily WTmcHead = "tmchead"
wasmFamily WTmcDest = "tmcdest"
wasmFamily WTmcFirst = "tmcfirst"
wasmFamily WTmcDctor = "tmcdctor"
wasmFamily WDispSavedHead = "dispsavedhead"
wasmFamily WDispSavedDest = "dispsaveddest"
wasmFamily WDispSavedFirst = "dispsavedfirst"
wasmFamily WDispResult = "dispresult"
wasmFamily WSelfClosure = "selfclosure"
wasmFamily W7Rlacc = "rlacc"
wasmFamily W7Rli = "rli"
wasmFamily W7Rllo = "rllo"
wasmFamily W7Raarr = "raarr"
wasmFamily W7Rai = "rai"
wasmFamily W7Ralo = "ralo"
wasmFamily W7Racnt = "racnt"
wasmFamily W7Ixarr = "ixarr"
wasmFamily W7Ixi = "ixi"
wasmFamily W7Slsrc = "slsrc"
wasmFamily W7Sldst = "sldst"
wasmFamily W7Sllo = "sllo"
wasmFamily W7Sllen = "sllen"
wasmFamily W7Aexi = "aexi"
wasmFamily W7Aexn = "aexn"
wasmFamily W7Aexarr = "aexarr"
wasmFamily W7Aexlst = "aexlst"
wasmFamily W7Aexf = "aexf"
wasmFamily W7Aexv = "aexv"
wasmFamily W7Aexbits = "aexbits"
wasmFamily W7Rub = "rub"
wasmFamily W7Divr = "divr"

export
wasmName : WasmName -> String
wasmName (WUserFunction name) = "f.user." ++ encodeComponent name
wasmName (WUserGlobal name) = "g.user." ++ encodeComponent name
wasmName (WGlobalState name) = "g.state." ++ encodeComponent name
wasmName (WGlobalForcer name) = "f.force." ++ encodeComponent name
wasmName (WImplMethod tag method) =
  "f.impl.\{encodeComponent tag}.\{encodeComponent method}"
wasmName (WDefaultMethod iface method key) =
  "f.default.\{encodeComponent iface}.\{encodeComponent method}.\{encodeComponent key}"
wasmName (WGenerated family subject ordinal) =
  "f.gen.\{wasmFamily family}.\{encodeComponent subject}.\{intToString ordinal}"
wasmName (WUserLocal name) = "u." ++ encodeComponent name
wasmName (WSyntheticLocal family ordinal) =
  "s.\{wasmFamily family}.\{intToString ordinal}"
wasmName (WJSImport name) = "f.js.import." ++ encodeComponent name
wasmName (WJSWrapper name) = "f.js.wrapper." ++ encodeComponent name
wasmName (WConstGlobal i) = "g.const." ++ intToString i
wasmName (WDispatchHead root) = "g.dispatch.head." ++ encodeComponent root
wasmName (WDispatchDest root) = "g.dispatch.dest." ++ encodeComponent root
wasmName (WDispatchFirst root) = "g.dispatch.first." ++ encodeComponent root
wasmName (WConstructorType name) = "t.ctor." ++ encodeComponent name
wasmName (WUserType name) = "t.user." ++ encodeComponent name
wasmName (WLabel family ordinal) =
  "l.\{wasmFamily family}.\{intToString ordinal}"

wasmName (WLabelBranch family depth ordinal) =
  "l.\{wasmFamily family}.\{intToString depth}.\{intToString ordinal}"
# DESUGAR
(DUse false (UseGroup ("support" "symbol_encoding") ((mem "encodeComponent" false))))
(DData Public "WasmGeneratedFamily" () ((variant "WLambda" (ConPos)) (variant "WNamedPap" (ConPos)) (variant "WIndirectPap" (ConPos)) (variant "WMethodValue" (ConPos)) (variant "WDictValue" (ConPos)) (variant "WCtorPap" (ConPos)) (variant "WCtorEta" (ConPos)) (variant "WExternEta" (ConPos)) (variant "WWrapper" (ConPos)) (variant "WGroup" (ConPos)) (variant "WConstCell" (ConPos)) (variant "WFfi" (ConPos)) (variant "WDispatch" (ConPos)) (variant "WScratch" (ConPos)) (variant "WGuard" (ConPos)) (variant "WPosition" (ConPos)) (variant "WAbiSelf" (ConPos)) (variant "WAbiArgs" (ConPos)) (variant "WLabelAexd" (ConPos)) (variant "WLabelAexl" (ConPos)) (variant "WLabelAexcd" (ConPos)) (variant "WLabelAexcl" (ConPos)) (variant "WLabelAexfd" (ConPos)) (variant "WLabelAexfl" (ConPos)) (variant "WLabelAfld" (ConPos)) (variant "WLabelAfll" (ConPos)) (variant "WLabelRld" (ConPos)) (variant "WLabelRll" (ConPos)) (variant "WLabelRad" (ConPos)) (variant "WLabelRal" (ConPos)) (variant "WClause" (ConPos)) (variant "WGuardTail" (ConPos)) (variant "WGuardValue" (ConPos)) (variant "WDecision" (ConPos)) (variant "WTmcLoop" (ConPos)) (variant "WTmcExit" (ConPos)) (variant "WSwitch" (ConPos)) (variant "WSwitchTail" (ConPos)) (variant "WTmcTemp" (ConPos)) (variant "WScalarDivr" (ConPos)) (variant "WForceValue" (ConPos)) (variant "WTmcHead" (ConPos)) (variant "WTmcDest" (ConPos)) (variant "WTmcFirst" (ConPos)) (variant "WTmcDctor" (ConPos)) (variant "WDispSavedHead" (ConPos)) (variant "WDispSavedDest" (ConPos)) (variant "WDispSavedFirst" (ConPos)) (variant "WDispResult" (ConPos)) (variant "WSelfClosure" (ConPos)) (variant "W7Rlacc" (ConPos)) (variant "W7Rli" (ConPos)) (variant "W7Rllo" (ConPos)) (variant "W7Raarr" (ConPos)) (variant "W7Rai" (ConPos)) (variant "W7Ralo" (ConPos)) (variant "W7Racnt" (ConPos)) (variant "W7Ixarr" (ConPos)) (variant "W7Ixi" (ConPos)) (variant "W7Slsrc" (ConPos)) (variant "W7Sldst" (ConPos)) (variant "W7Sllo" (ConPos)) (variant "W7Sllen" (ConPos)) (variant "W7Aexi" (ConPos)) (variant "W7Aexn" (ConPos)) (variant "W7Aexarr" (ConPos)) (variant "W7Aexlst" (ConPos)) (variant "W7Aexf" (ConPos)) (variant "W7Aexv" (ConPos)) (variant "W7Aexbits" (ConPos)) (variant "W7Rub" (ConPos)) (variant "W7Divr" (ConPos))) ())
(DData Public "WasmName" () ((variant "WUserFunction" (ConPos (TyCon "String"))) (variant "WUserGlobal" (ConPos (TyCon "String"))) (variant "WGlobalState" (ConPos (TyCon "String"))) (variant "WGlobalForcer" (ConPos (TyCon "String"))) (variant "WImplMethod" (ConPos (TyCon "String") (TyCon "String"))) (variant "WDefaultMethod" (ConPos (TyCon "String") (TyCon "String") (TyCon "String"))) (variant "WGenerated" (ConPos (TyCon "WasmGeneratedFamily") (TyCon "String") (TyCon "Int"))) (variant "WUserLocal" (ConPos (TyCon "String"))) (variant "WSyntheticLocal" (ConPos (TyCon "WasmGeneratedFamily") (TyCon "Int"))) (variant "WJSImport" (ConPos (TyCon "String"))) (variant "WJSWrapper" (ConPos (TyCon "String"))) (variant "WConstGlobal" (ConPos (TyCon "Int"))) (variant "WDispatchHead" (ConPos (TyCon "String"))) (variant "WDispatchDest" (ConPos (TyCon "String"))) (variant "WDispatchFirst" (ConPos (TyCon "String"))) (variant "WConstructorType" (ConPos (TyCon "String"))) (variant "WUserType" (ConPos (TyCon "String"))) (variant "WLabel" (ConPos (TyCon "WasmGeneratedFamily") (TyCon "Int"))) (variant "WLabelBranch" (ConPos (TyCon "WasmGeneratedFamily") (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig false "wasmFamily" (TyFun (TyCon "WasmGeneratedFamily") (TyCon "String")))
(DFunDef false "wasmFamily" ((PCon "WLambda")) (ELit (LString "lambda")))
(DFunDef false "wasmFamily" ((PCon "WNamedPap")) (ELit (LString "namedpap")))
(DFunDef false "wasmFamily" ((PCon "WIndirectPap")) (ELit (LString "indirectpap")))
(DFunDef false "wasmFamily" ((PCon "WMethodValue")) (ELit (LString "methodvalue")))
(DFunDef false "wasmFamily" ((PCon "WDictValue")) (ELit (LString "dictvalue")))
(DFunDef false "wasmFamily" ((PCon "WCtorPap")) (ELit (LString "ctorpap")))
(DFunDef false "wasmFamily" ((PCon "WCtorEta")) (ELit (LString "ctoreta")))
(DFunDef false "wasmFamily" ((PCon "WExternEta")) (ELit (LString "externeta")))
(DFunDef false "wasmFamily" ((PCon "WWrapper")) (ELit (LString "wrapper")))
(DFunDef false "wasmFamily" ((PCon "WGroup")) (ELit (LString "group")))
(DFunDef false "wasmFamily" ((PCon "WConstCell")) (ELit (LString "constcell")))
(DFunDef false "wasmFamily" ((PCon "WFfi")) (ELit (LString "ffi")))
(DFunDef false "wasmFamily" ((PCon "WDispatch")) (ELit (LString "dispatch")))
(DFunDef false "wasmFamily" ((PCon "WScratch")) (ELit (LString "scratch")))
(DFunDef false "wasmFamily" ((PCon "WGuard")) (ELit (LString "guard")))
(DFunDef false "wasmFamily" ((PCon "WPosition")) (ELit (LString "position")))
(DFunDef false "wasmFamily" ((PCon "WAbiSelf")) (ELit (LString "abiself")))
(DFunDef false "wasmFamily" ((PCon "WAbiArgs")) (ELit (LString "abiargs")))
(DFunDef false "wasmFamily" ((PCon "WLabelAexd")) (ELit (LString "aexd")))
(DFunDef false "wasmFamily" ((PCon "WLabelAexl")) (ELit (LString "aexl")))
(DFunDef false "wasmFamily" ((PCon "WLabelAexcd")) (ELit (LString "aexcd")))
(DFunDef false "wasmFamily" ((PCon "WLabelAexcl")) (ELit (LString "aexcl")))
(DFunDef false "wasmFamily" ((PCon "WLabelAexfd")) (ELit (LString "aexfd")))
(DFunDef false "wasmFamily" ((PCon "WLabelAexfl")) (ELit (LString "aexfl")))
(DFunDef false "wasmFamily" ((PCon "WLabelAfld")) (ELit (LString "afld")))
(DFunDef false "wasmFamily" ((PCon "WLabelAfll")) (ELit (LString "afll")))
(DFunDef false "wasmFamily" ((PCon "WLabelRld")) (ELit (LString "rld")))
(DFunDef false "wasmFamily" ((PCon "WLabelRll")) (ELit (LString "rll")))
(DFunDef false "wasmFamily" ((PCon "WLabelRad")) (ELit (LString "rad")))
(DFunDef false "wasmFamily" ((PCon "WLabelRal")) (ELit (LString "ral")))
(DFunDef false "wasmFamily" ((PCon "WClause")) (ELit (LString "clause")))
(DFunDef false "wasmFamily" ((PCon "WGuardTail")) (ELit (LString "guardtail")))
(DFunDef false "wasmFamily" ((PCon "WGuardValue")) (ELit (LString "guardvalue")))
(DFunDef false "wasmFamily" ((PCon "WDecision")) (ELit (LString "decision")))
(DFunDef false "wasmFamily" ((PCon "WTmcLoop")) (ELit (LString "tmcloop")))
(DFunDef false "wasmFamily" ((PCon "WTmcExit")) (ELit (LString "tmcexit")))
(DFunDef false "wasmFamily" ((PCon "WSwitch")) (ELit (LString "switch")))
(DFunDef false "wasmFamily" ((PCon "WSwitchTail")) (ELit (LString "switchtail")))
(DFunDef false "wasmFamily" ((PCon "WTmcTemp")) (ELit (LString "tmctemp")))
(DFunDef false "wasmFamily" ((PCon "WScalarDivr")) (ELit (LString "scalardivr")))
(DFunDef false "wasmFamily" ((PCon "WForceValue")) (ELit (LString "forcevalue")))
(DFunDef false "wasmFamily" ((PCon "WTmcHead")) (ELit (LString "tmchead")))
(DFunDef false "wasmFamily" ((PCon "WTmcDest")) (ELit (LString "tmcdest")))
(DFunDef false "wasmFamily" ((PCon "WTmcFirst")) (ELit (LString "tmcfirst")))
(DFunDef false "wasmFamily" ((PCon "WTmcDctor")) (ELit (LString "tmcdctor")))
(DFunDef false "wasmFamily" ((PCon "WDispSavedHead")) (ELit (LString "dispsavedhead")))
(DFunDef false "wasmFamily" ((PCon "WDispSavedDest")) (ELit (LString "dispsaveddest")))
(DFunDef false "wasmFamily" ((PCon "WDispSavedFirst")) (ELit (LString "dispsavedfirst")))
(DFunDef false "wasmFamily" ((PCon "WDispResult")) (ELit (LString "dispresult")))
(DFunDef false "wasmFamily" ((PCon "WSelfClosure")) (ELit (LString "selfclosure")))
(DFunDef false "wasmFamily" ((PCon "W7Rlacc")) (ELit (LString "rlacc")))
(DFunDef false "wasmFamily" ((PCon "W7Rli")) (ELit (LString "rli")))
(DFunDef false "wasmFamily" ((PCon "W7Rllo")) (ELit (LString "rllo")))
(DFunDef false "wasmFamily" ((PCon "W7Raarr")) (ELit (LString "raarr")))
(DFunDef false "wasmFamily" ((PCon "W7Rai")) (ELit (LString "rai")))
(DFunDef false "wasmFamily" ((PCon "W7Ralo")) (ELit (LString "ralo")))
(DFunDef false "wasmFamily" ((PCon "W7Racnt")) (ELit (LString "racnt")))
(DFunDef false "wasmFamily" ((PCon "W7Ixarr")) (ELit (LString "ixarr")))
(DFunDef false "wasmFamily" ((PCon "W7Ixi")) (ELit (LString "ixi")))
(DFunDef false "wasmFamily" ((PCon "W7Slsrc")) (ELit (LString "slsrc")))
(DFunDef false "wasmFamily" ((PCon "W7Sldst")) (ELit (LString "sldst")))
(DFunDef false "wasmFamily" ((PCon "W7Sllo")) (ELit (LString "sllo")))
(DFunDef false "wasmFamily" ((PCon "W7Sllen")) (ELit (LString "sllen")))
(DFunDef false "wasmFamily" ((PCon "W7Aexi")) (ELit (LString "aexi")))
(DFunDef false "wasmFamily" ((PCon "W7Aexn")) (ELit (LString "aexn")))
(DFunDef false "wasmFamily" ((PCon "W7Aexarr")) (ELit (LString "aexarr")))
(DFunDef false "wasmFamily" ((PCon "W7Aexlst")) (ELit (LString "aexlst")))
(DFunDef false "wasmFamily" ((PCon "W7Aexf")) (ELit (LString "aexf")))
(DFunDef false "wasmFamily" ((PCon "W7Aexv")) (ELit (LString "aexv")))
(DFunDef false "wasmFamily" ((PCon "W7Aexbits")) (ELit (LString "aexbits")))
(DFunDef false "wasmFamily" ((PCon "W7Rub")) (ELit (LString "rub")))
(DFunDef false "wasmFamily" ((PCon "W7Divr")) (ELit (LString "divr")))
(DTypeSig true "wasmName" (TyFun (TyCon "WasmName") (TyCon "String")))
(DFunDef false "wasmName" ((PCon "WUserFunction" (PVar "name"))) (EBinOp "++" (ELit (LString "f.user.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "wasmName" ((PCon "WUserGlobal" (PVar "name"))) (EBinOp "++" (ELit (LString "g.user.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "wasmName" ((PCon "WGlobalState" (PVar "name"))) (EBinOp "++" (ELit (LString "g.state.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "wasmName" ((PCon "WGlobalForcer" (PVar "name"))) (EBinOp "++" (ELit (LString "f.force.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "wasmName" ((PCon "WImplMethod" (PVar "tag") (PVar "method"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "f.impl.")) (EApp (EVar "display") (EApp (EVar "encodeComponent") (EVar "tag")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "encodeComponent") (EVar "method")))) (ELit (LString ""))))
(DFunDef false "wasmName" ((PCon "WDefaultMethod" (PVar "iface") (PVar "method") (PVar "key"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "f.default.")) (EApp (EVar "display") (EApp (EVar "encodeComponent") (EVar "iface")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "encodeComponent") (EVar "method")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "encodeComponent") (EVar "key")))) (ELit (LString ""))))
(DFunDef false "wasmName" ((PCon "WGenerated" (PVar "family") (PVar "subject") (PVar "ordinal"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "f.gen.")) (EApp (EVar "display") (EApp (EVar "wasmFamily") (EVar "family")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "encodeComponent") (EVar "subject")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "ordinal")))) (ELit (LString ""))))
(DFunDef false "wasmName" ((PCon "WUserLocal" (PVar "name"))) (EBinOp "++" (ELit (LString "u.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "wasmName" ((PCon "WSyntheticLocal" (PVar "family") (PVar "ordinal"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "s.")) (EApp (EVar "display") (EApp (EVar "wasmFamily") (EVar "family")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "ordinal")))) (ELit (LString ""))))
(DFunDef false "wasmName" ((PCon "WJSImport" (PVar "name"))) (EBinOp "++" (ELit (LString "f.js.import.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "wasmName" ((PCon "WJSWrapper" (PVar "name"))) (EBinOp "++" (ELit (LString "f.js.wrapper.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "wasmName" ((PCon "WConstGlobal" (PVar "i"))) (EBinOp "++" (ELit (LString "g.const.")) (EApp (EVar "intToString") (EVar "i"))))
(DFunDef false "wasmName" ((PCon "WDispatchHead" (PVar "root"))) (EBinOp "++" (ELit (LString "g.dispatch.head.")) (EApp (EVar "encodeComponent") (EVar "root"))))
(DFunDef false "wasmName" ((PCon "WDispatchDest" (PVar "root"))) (EBinOp "++" (ELit (LString "g.dispatch.dest.")) (EApp (EVar "encodeComponent") (EVar "root"))))
(DFunDef false "wasmName" ((PCon "WDispatchFirst" (PVar "root"))) (EBinOp "++" (ELit (LString "g.dispatch.first.")) (EApp (EVar "encodeComponent") (EVar "root"))))
(DFunDef false "wasmName" ((PCon "WConstructorType" (PVar "name"))) (EBinOp "++" (ELit (LString "t.ctor.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "wasmName" ((PCon "WUserType" (PVar "name"))) (EBinOp "++" (ELit (LString "t.user.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "wasmName" ((PCon "WLabel" (PVar "family") (PVar "ordinal"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "l.")) (EApp (EVar "display") (EApp (EVar "wasmFamily") (EVar "family")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "ordinal")))) (ELit (LString ""))))
(DFunDef false "wasmName" ((PCon "WLabelBranch" (PVar "family") (PVar "depth") (PVar "ordinal"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "l.")) (EApp (EVar "display") (EApp (EVar "wasmFamily") (EVar "family")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "depth")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "ordinal")))) (ELit (LString ""))))
# MARK
(DUse false (UseGroup ("support" "symbol_encoding") ((mem "encodeComponent" false))))
(DData Public "WasmGeneratedFamily" () ((variant "WLambda" (ConPos)) (variant "WNamedPap" (ConPos)) (variant "WIndirectPap" (ConPos)) (variant "WMethodValue" (ConPos)) (variant "WDictValue" (ConPos)) (variant "WCtorPap" (ConPos)) (variant "WCtorEta" (ConPos)) (variant "WExternEta" (ConPos)) (variant "WWrapper" (ConPos)) (variant "WGroup" (ConPos)) (variant "WConstCell" (ConPos)) (variant "WFfi" (ConPos)) (variant "WDispatch" (ConPos)) (variant "WScratch" (ConPos)) (variant "WGuard" (ConPos)) (variant "WPosition" (ConPos)) (variant "WAbiSelf" (ConPos)) (variant "WAbiArgs" (ConPos)) (variant "WLabelAexd" (ConPos)) (variant "WLabelAexl" (ConPos)) (variant "WLabelAexcd" (ConPos)) (variant "WLabelAexcl" (ConPos)) (variant "WLabelAexfd" (ConPos)) (variant "WLabelAexfl" (ConPos)) (variant "WLabelAfld" (ConPos)) (variant "WLabelAfll" (ConPos)) (variant "WLabelRld" (ConPos)) (variant "WLabelRll" (ConPos)) (variant "WLabelRad" (ConPos)) (variant "WLabelRal" (ConPos)) (variant "WClause" (ConPos)) (variant "WGuardTail" (ConPos)) (variant "WGuardValue" (ConPos)) (variant "WDecision" (ConPos)) (variant "WTmcLoop" (ConPos)) (variant "WTmcExit" (ConPos)) (variant "WSwitch" (ConPos)) (variant "WSwitchTail" (ConPos)) (variant "WTmcTemp" (ConPos)) (variant "WScalarDivr" (ConPos)) (variant "WForceValue" (ConPos)) (variant "WTmcHead" (ConPos)) (variant "WTmcDest" (ConPos)) (variant "WTmcFirst" (ConPos)) (variant "WTmcDctor" (ConPos)) (variant "WDispSavedHead" (ConPos)) (variant "WDispSavedDest" (ConPos)) (variant "WDispSavedFirst" (ConPos)) (variant "WDispResult" (ConPos)) (variant "WSelfClosure" (ConPos)) (variant "W7Rlacc" (ConPos)) (variant "W7Rli" (ConPos)) (variant "W7Rllo" (ConPos)) (variant "W7Raarr" (ConPos)) (variant "W7Rai" (ConPos)) (variant "W7Ralo" (ConPos)) (variant "W7Racnt" (ConPos)) (variant "W7Ixarr" (ConPos)) (variant "W7Ixi" (ConPos)) (variant "W7Slsrc" (ConPos)) (variant "W7Sldst" (ConPos)) (variant "W7Sllo" (ConPos)) (variant "W7Sllen" (ConPos)) (variant "W7Aexi" (ConPos)) (variant "W7Aexn" (ConPos)) (variant "W7Aexarr" (ConPos)) (variant "W7Aexlst" (ConPos)) (variant "W7Aexf" (ConPos)) (variant "W7Aexv" (ConPos)) (variant "W7Aexbits" (ConPos)) (variant "W7Rub" (ConPos)) (variant "W7Divr" (ConPos))) ())
(DData Public "WasmName" () ((variant "WUserFunction" (ConPos (TyCon "String"))) (variant "WUserGlobal" (ConPos (TyCon "String"))) (variant "WGlobalState" (ConPos (TyCon "String"))) (variant "WGlobalForcer" (ConPos (TyCon "String"))) (variant "WImplMethod" (ConPos (TyCon "String") (TyCon "String"))) (variant "WDefaultMethod" (ConPos (TyCon "String") (TyCon "String") (TyCon "String"))) (variant "WGenerated" (ConPos (TyCon "WasmGeneratedFamily") (TyCon "String") (TyCon "Int"))) (variant "WUserLocal" (ConPos (TyCon "String"))) (variant "WSyntheticLocal" (ConPos (TyCon "WasmGeneratedFamily") (TyCon "Int"))) (variant "WJSImport" (ConPos (TyCon "String"))) (variant "WJSWrapper" (ConPos (TyCon "String"))) (variant "WConstGlobal" (ConPos (TyCon "Int"))) (variant "WDispatchHead" (ConPos (TyCon "String"))) (variant "WDispatchDest" (ConPos (TyCon "String"))) (variant "WDispatchFirst" (ConPos (TyCon "String"))) (variant "WConstructorType" (ConPos (TyCon "String"))) (variant "WUserType" (ConPos (TyCon "String"))) (variant "WLabel" (ConPos (TyCon "WasmGeneratedFamily") (TyCon "Int"))) (variant "WLabelBranch" (ConPos (TyCon "WasmGeneratedFamily") (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig false "wasmFamily" (TyFun (TyCon "WasmGeneratedFamily") (TyCon "String")))
(DFunDef false "wasmFamily" ((PCon "WLambda")) (ELit (LString "lambda")))
(DFunDef false "wasmFamily" ((PCon "WNamedPap")) (ELit (LString "namedpap")))
(DFunDef false "wasmFamily" ((PCon "WIndirectPap")) (ELit (LString "indirectpap")))
(DFunDef false "wasmFamily" ((PCon "WMethodValue")) (ELit (LString "methodvalue")))
(DFunDef false "wasmFamily" ((PCon "WDictValue")) (ELit (LString "dictvalue")))
(DFunDef false "wasmFamily" ((PCon "WCtorPap")) (ELit (LString "ctorpap")))
(DFunDef false "wasmFamily" ((PCon "WCtorEta")) (ELit (LString "ctoreta")))
(DFunDef false "wasmFamily" ((PCon "WExternEta")) (ELit (LString "externeta")))
(DFunDef false "wasmFamily" ((PCon "WWrapper")) (ELit (LString "wrapper")))
(DFunDef false "wasmFamily" ((PCon "WGroup")) (ELit (LString "group")))
(DFunDef false "wasmFamily" ((PCon "WConstCell")) (ELit (LString "constcell")))
(DFunDef false "wasmFamily" ((PCon "WFfi")) (ELit (LString "ffi")))
(DFunDef false "wasmFamily" ((PCon "WDispatch")) (ELit (LString "dispatch")))
(DFunDef false "wasmFamily" ((PCon "WScratch")) (ELit (LString "scratch")))
(DFunDef false "wasmFamily" ((PCon "WGuard")) (ELit (LString "guard")))
(DFunDef false "wasmFamily" ((PCon "WPosition")) (ELit (LString "position")))
(DFunDef false "wasmFamily" ((PCon "WAbiSelf")) (ELit (LString "abiself")))
(DFunDef false "wasmFamily" ((PCon "WAbiArgs")) (ELit (LString "abiargs")))
(DFunDef false "wasmFamily" ((PCon "WLabelAexd")) (ELit (LString "aexd")))
(DFunDef false "wasmFamily" ((PCon "WLabelAexl")) (ELit (LString "aexl")))
(DFunDef false "wasmFamily" ((PCon "WLabelAexcd")) (ELit (LString "aexcd")))
(DFunDef false "wasmFamily" ((PCon "WLabelAexcl")) (ELit (LString "aexcl")))
(DFunDef false "wasmFamily" ((PCon "WLabelAexfd")) (ELit (LString "aexfd")))
(DFunDef false "wasmFamily" ((PCon "WLabelAexfl")) (ELit (LString "aexfl")))
(DFunDef false "wasmFamily" ((PCon "WLabelAfld")) (ELit (LString "afld")))
(DFunDef false "wasmFamily" ((PCon "WLabelAfll")) (ELit (LString "afll")))
(DFunDef false "wasmFamily" ((PCon "WLabelRld")) (ELit (LString "rld")))
(DFunDef false "wasmFamily" ((PCon "WLabelRll")) (ELit (LString "rll")))
(DFunDef false "wasmFamily" ((PCon "WLabelRad")) (ELit (LString "rad")))
(DFunDef false "wasmFamily" ((PCon "WLabelRal")) (ELit (LString "ral")))
(DFunDef false "wasmFamily" ((PCon "WClause")) (ELit (LString "clause")))
(DFunDef false "wasmFamily" ((PCon "WGuardTail")) (ELit (LString "guardtail")))
(DFunDef false "wasmFamily" ((PCon "WGuardValue")) (ELit (LString "guardvalue")))
(DFunDef false "wasmFamily" ((PCon "WDecision")) (ELit (LString "decision")))
(DFunDef false "wasmFamily" ((PCon "WTmcLoop")) (ELit (LString "tmcloop")))
(DFunDef false "wasmFamily" ((PCon "WTmcExit")) (ELit (LString "tmcexit")))
(DFunDef false "wasmFamily" ((PCon "WSwitch")) (ELit (LString "switch")))
(DFunDef false "wasmFamily" ((PCon "WSwitchTail")) (ELit (LString "switchtail")))
(DFunDef false "wasmFamily" ((PCon "WTmcTemp")) (ELit (LString "tmctemp")))
(DFunDef false "wasmFamily" ((PCon "WScalarDivr")) (ELit (LString "scalardivr")))
(DFunDef false "wasmFamily" ((PCon "WForceValue")) (ELit (LString "forcevalue")))
(DFunDef false "wasmFamily" ((PCon "WTmcHead")) (ELit (LString "tmchead")))
(DFunDef false "wasmFamily" ((PCon "WTmcDest")) (ELit (LString "tmcdest")))
(DFunDef false "wasmFamily" ((PCon "WTmcFirst")) (ELit (LString "tmcfirst")))
(DFunDef false "wasmFamily" ((PCon "WTmcDctor")) (ELit (LString "tmcdctor")))
(DFunDef false "wasmFamily" ((PCon "WDispSavedHead")) (ELit (LString "dispsavedhead")))
(DFunDef false "wasmFamily" ((PCon "WDispSavedDest")) (ELit (LString "dispsaveddest")))
(DFunDef false "wasmFamily" ((PCon "WDispSavedFirst")) (ELit (LString "dispsavedfirst")))
(DFunDef false "wasmFamily" ((PCon "WDispResult")) (ELit (LString "dispresult")))
(DFunDef false "wasmFamily" ((PCon "WSelfClosure")) (ELit (LString "selfclosure")))
(DFunDef false "wasmFamily" ((PCon "W7Rlacc")) (ELit (LString "rlacc")))
(DFunDef false "wasmFamily" ((PCon "W7Rli")) (ELit (LString "rli")))
(DFunDef false "wasmFamily" ((PCon "W7Rllo")) (ELit (LString "rllo")))
(DFunDef false "wasmFamily" ((PCon "W7Raarr")) (ELit (LString "raarr")))
(DFunDef false "wasmFamily" ((PCon "W7Rai")) (ELit (LString "rai")))
(DFunDef false "wasmFamily" ((PCon "W7Ralo")) (ELit (LString "ralo")))
(DFunDef false "wasmFamily" ((PCon "W7Racnt")) (ELit (LString "racnt")))
(DFunDef false "wasmFamily" ((PCon "W7Ixarr")) (ELit (LString "ixarr")))
(DFunDef false "wasmFamily" ((PCon "W7Ixi")) (ELit (LString "ixi")))
(DFunDef false "wasmFamily" ((PCon "W7Slsrc")) (ELit (LString "slsrc")))
(DFunDef false "wasmFamily" ((PCon "W7Sldst")) (ELit (LString "sldst")))
(DFunDef false "wasmFamily" ((PCon "W7Sllo")) (ELit (LString "sllo")))
(DFunDef false "wasmFamily" ((PCon "W7Sllen")) (ELit (LString "sllen")))
(DFunDef false "wasmFamily" ((PCon "W7Aexi")) (ELit (LString "aexi")))
(DFunDef false "wasmFamily" ((PCon "W7Aexn")) (ELit (LString "aexn")))
(DFunDef false "wasmFamily" ((PCon "W7Aexarr")) (ELit (LString "aexarr")))
(DFunDef false "wasmFamily" ((PCon "W7Aexlst")) (ELit (LString "aexlst")))
(DFunDef false "wasmFamily" ((PCon "W7Aexf")) (ELit (LString "aexf")))
(DFunDef false "wasmFamily" ((PCon "W7Aexv")) (ELit (LString "aexv")))
(DFunDef false "wasmFamily" ((PCon "W7Aexbits")) (ELit (LString "aexbits")))
(DFunDef false "wasmFamily" ((PCon "W7Rub")) (ELit (LString "rub")))
(DFunDef false "wasmFamily" ((PCon "W7Divr")) (ELit (LString "divr")))
(DTypeSig true "wasmName" (TyFun (TyCon "WasmName") (TyCon "String")))
(DFunDef false "wasmName" ((PCon "WUserFunction" (PVar "name"))) (EBinOp "++" (ELit (LString "f.user.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "wasmName" ((PCon "WUserGlobal" (PVar "name"))) (EBinOp "++" (ELit (LString "g.user.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "wasmName" ((PCon "WGlobalState" (PVar "name"))) (EBinOp "++" (ELit (LString "g.state.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "wasmName" ((PCon "WGlobalForcer" (PVar "name"))) (EBinOp "++" (ELit (LString "f.force.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "wasmName" ((PCon "WImplMethod" (PVar "tag") (PVar "method"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "f.impl.")) (EApp (EMethodRef "display") (EApp (EVar "encodeComponent") (EVar "tag")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "encodeComponent") (EVar "method")))) (ELit (LString ""))))
(DFunDef false "wasmName" ((PCon "WDefaultMethod" (PVar "iface") (PVar "method") (PVar "key"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "f.default.")) (EApp (EMethodRef "display") (EApp (EVar "encodeComponent") (EVar "iface")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "encodeComponent") (EVar "method")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "encodeComponent") (EVar "key")))) (ELit (LString ""))))
(DFunDef false "wasmName" ((PCon "WGenerated" (PVar "family") (PVar "subject") (PVar "ordinal"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "f.gen.")) (EApp (EMethodRef "display") (EApp (EVar "wasmFamily") (EVar "family")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "encodeComponent") (EVar "subject")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "ordinal")))) (ELit (LString ""))))
(DFunDef false "wasmName" ((PCon "WUserLocal" (PVar "name"))) (EBinOp "++" (ELit (LString "u.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "wasmName" ((PCon "WSyntheticLocal" (PVar "family") (PVar "ordinal"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "s.")) (EApp (EMethodRef "display") (EApp (EVar "wasmFamily") (EVar "family")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "ordinal")))) (ELit (LString ""))))
(DFunDef false "wasmName" ((PCon "WJSImport" (PVar "name"))) (EBinOp "++" (ELit (LString "f.js.import.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "wasmName" ((PCon "WJSWrapper" (PVar "name"))) (EBinOp "++" (ELit (LString "f.js.wrapper.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "wasmName" ((PCon "WConstGlobal" (PVar "i"))) (EBinOp "++" (ELit (LString "g.const.")) (EApp (EVar "intToString") (EVar "i"))))
(DFunDef false "wasmName" ((PCon "WDispatchHead" (PVar "root"))) (EBinOp "++" (ELit (LString "g.dispatch.head.")) (EApp (EVar "encodeComponent") (EVar "root"))))
(DFunDef false "wasmName" ((PCon "WDispatchDest" (PVar "root"))) (EBinOp "++" (ELit (LString "g.dispatch.dest.")) (EApp (EVar "encodeComponent") (EVar "root"))))
(DFunDef false "wasmName" ((PCon "WDispatchFirst" (PVar "root"))) (EBinOp "++" (ELit (LString "g.dispatch.first.")) (EApp (EVar "encodeComponent") (EVar "root"))))
(DFunDef false "wasmName" ((PCon "WConstructorType" (PVar "name"))) (EBinOp "++" (ELit (LString "t.ctor.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "wasmName" ((PCon "WUserType" (PVar "name"))) (EBinOp "++" (ELit (LString "t.user.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "wasmName" ((PCon "WLabel" (PVar "family") (PVar "ordinal"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "l.")) (EApp (EMethodRef "display") (EApp (EVar "wasmFamily") (EVar "family")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "ordinal")))) (ELit (LString ""))))
(DFunDef false "wasmName" ((PCon "WLabelBranch" (PVar "family") (PVar "depth") (PVar "ordinal"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "l.")) (EApp (EMethodRef "display") (EApp (EVar "wasmFamily") (EVar "family")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "depth")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "ordinal")))) (ELit (LString ""))))
