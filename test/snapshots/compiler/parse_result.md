# META
source_lines=58
stages=DESUGAR,MARK
# SOURCE
import frontend.ast.{Decl, Loc(..)}
import frontend.parse_positions.{Positions}
import frontend.parse_diagnostic.{
  ParseDiagnostic, diagnosticLoc, renderParseDiagnostic
}

export data ParseMetadata =
  ParseMetadata (List (Int, Int)) (List (Int, Int, Int))
export data ParsedSource = ParsedSource (List Decl) Positions ParseMetadata

export
makeParseMetadata : List (Int, Int) -> List (Int, Int, Int) -> ParseMetadata
makeParseMetadata commas units = ParseMetadata commas units

export
makeParsedSource : List Decl -> Positions -> ParseMetadata -> ParsedSource
makeParsedSource decls positions metadata =
  ParsedSource decls positions metadata

export
parsedDecls : ParsedSource -> List Decl
parsedDecls (ParsedSource decls _ _) = decls

export
parsedPositions : ParsedSource -> Positions
parsedPositions (ParsedSource _ positions _) = positions

export
parsedMetadata : ParsedSource -> ParseMetadata
parsedMetadata (ParsedSource _ _ metadata) = metadata

export
metadataTrailingCommas : ParseMetadata -> List (Int, Int)
metadataTrailingCommas (ParseMetadata commas _) = commas

export
metadataUnitStarts : ParseMetadata -> List (Int, Int, Int)
metadataUnitStarts (ParseMetadata _ units) = units

public export data ParseError = ParseError ParseDiagnostic

export
parseErrorDiagnostic : ParseError -> ParseDiagnostic
parseErrorDiagnostic (ParseError diagnostic) = diagnostic

export
parseErrorLine : ParseError -> Int
parseErrorLine (ParseError diagnostic) = match diagnosticLoc diagnostic
  Loc _ line _ _ _ => line

export
parseErrorCol : ParseError -> Int
parseErrorCol (ParseError diagnostic) = match diagnosticLoc diagnostic
  Loc _ _ col _ _ => col

export
parseErrorMessage : ParseError -> String
parseErrorMessage (ParseError diagnostic) = renderParseDiagnostic diagnostic
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "parse_positions") ((mem "Positions" false))))
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnostic" false) (mem "diagnosticLoc" false) (mem "renderParseDiagnostic" false))))
(DData Abstract "ParseMetadata" () ((variant "ParseMetadata" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int")))))) ())
(DData Abstract "ParsedSource" () ((variant "ParsedSource" (ConPos (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions") (TyCon "ParseMetadata")))) ())
(DTypeSig true "makeParseMetadata" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int"))) (TyCon "ParseMetadata"))))
(DFunDef false "makeParseMetadata" ((PVar "commas") (PVar "units")) (EApp (EApp (EVar "ParseMetadata") (EVar "commas")) (EVar "units")))
(DTypeSig true "makeParsedSource" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Positions") (TyFun (TyCon "ParseMetadata") (TyCon "ParsedSource")))))
(DFunDef false "makeParsedSource" ((PVar "decls") (PVar "positions") (PVar "metadata")) (EApp (EApp (EApp (EVar "ParsedSource") (EVar "decls")) (EVar "positions")) (EVar "metadata")))
(DTypeSig true "parsedDecls" (TyFun (TyCon "ParsedSource") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "parsedDecls" ((PCon "ParsedSource" (PVar "decls") PWild PWild)) (EVar "decls"))
(DTypeSig true "parsedPositions" (TyFun (TyCon "ParsedSource") (TyCon "Positions")))
(DFunDef false "parsedPositions" ((PCon "ParsedSource" PWild (PVar "positions") PWild)) (EVar "positions"))
(DTypeSig true "parsedMetadata" (TyFun (TyCon "ParsedSource") (TyCon "ParseMetadata")))
(DFunDef false "parsedMetadata" ((PCon "ParsedSource" PWild PWild (PVar "metadata"))) (EVar "metadata"))
(DTypeSig true "metadataTrailingCommas" (TyFun (TyCon "ParseMetadata") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "metadataTrailingCommas" ((PCon "ParseMetadata" (PVar "commas") PWild)) (EVar "commas"))
(DTypeSig true "metadataUnitStarts" (TyFun (TyCon "ParseMetadata") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "metadataUnitStarts" ((PCon "ParseMetadata" PWild (PVar "units"))) (EVar "units"))
(DData Public "ParseError" () ((variant "ParseError" (ConPos (TyCon "ParseDiagnostic")))) ())
(DTypeSig true "parseErrorDiagnostic" (TyFun (TyCon "ParseError") (TyCon "ParseDiagnostic")))
(DFunDef false "parseErrorDiagnostic" ((PCon "ParseError" (PVar "diagnostic"))) (EVar "diagnostic"))
(DTypeSig true "parseErrorLine" (TyFun (TyCon "ParseError") (TyCon "Int")))
(DFunDef false "parseErrorLine" ((PCon "ParseError" (PVar "diagnostic"))) (EMatch (EApp (EVar "diagnosticLoc") (EVar "diagnostic")) (arm (PCon "Loc" PWild (PVar "line") PWild PWild PWild) () (EVar "line"))))
(DTypeSig true "parseErrorCol" (TyFun (TyCon "ParseError") (TyCon "Int")))
(DFunDef false "parseErrorCol" ((PCon "ParseError" (PVar "diagnostic"))) (EMatch (EApp (EVar "diagnosticLoc") (EVar "diagnostic")) (arm (PCon "Loc" PWild PWild (PVar "col") PWild PWild) () (EVar "col"))))
(DTypeSig true "parseErrorMessage" (TyFun (TyCon "ParseError") (TyCon "String")))
(DFunDef false "parseErrorMessage" ((PCon "ParseError" (PVar "diagnostic"))) (EApp (EVar "renderParseDiagnostic") (EVar "diagnostic")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "parse_positions") ((mem "Positions" false))))
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnostic" false) (mem "diagnosticLoc" false) (mem "renderParseDiagnostic" false))))
(DData Abstract "ParseMetadata" () ((variant "ParseMetadata" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int")))))) ())
(DData Abstract "ParsedSource" () ((variant "ParsedSource" (ConPos (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions") (TyCon "ParseMetadata")))) ())
(DTypeSig true "makeParseMetadata" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int"))) (TyCon "ParseMetadata"))))
(DFunDef false "makeParseMetadata" ((PVar "commas") (PVar "units")) (EApp (EApp (EVar "ParseMetadata") (EVar "commas")) (EVar "units")))
(DTypeSig true "makeParsedSource" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Positions") (TyFun (TyCon "ParseMetadata") (TyCon "ParsedSource")))))
(DFunDef false "makeParsedSource" ((PVar "decls") (PVar "positions") (PVar "metadata")) (EApp (EApp (EApp (EVar "ParsedSource") (EVar "decls")) (EVar "positions")) (EVar "metadata")))
(DTypeSig true "parsedDecls" (TyFun (TyCon "ParsedSource") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "parsedDecls" ((PCon "ParsedSource" (PVar "decls") PWild PWild)) (EVar "decls"))
(DTypeSig true "parsedPositions" (TyFun (TyCon "ParsedSource") (TyCon "Positions")))
(DFunDef false "parsedPositions" ((PCon "ParsedSource" PWild (PVar "positions") PWild)) (EVar "positions"))
(DTypeSig true "parsedMetadata" (TyFun (TyCon "ParsedSource") (TyCon "ParseMetadata")))
(DFunDef false "parsedMetadata" ((PCon "ParsedSource" PWild PWild (PVar "metadata"))) (EVar "metadata"))
(DTypeSig true "metadataTrailingCommas" (TyFun (TyCon "ParseMetadata") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "metadataTrailingCommas" ((PCon "ParseMetadata" (PVar "commas") PWild)) (EVar "commas"))
(DTypeSig true "metadataUnitStarts" (TyFun (TyCon "ParseMetadata") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "metadataUnitStarts" ((PCon "ParseMetadata" PWild (PVar "units"))) (EVar "units"))
(DData Public "ParseError" () ((variant "ParseError" (ConPos (TyCon "ParseDiagnostic")))) ())
(DTypeSig true "parseErrorDiagnostic" (TyFun (TyCon "ParseError") (TyCon "ParseDiagnostic")))
(DFunDef false "parseErrorDiagnostic" ((PCon "ParseError" (PVar "diagnostic"))) (EVar "diagnostic"))
(DTypeSig true "parseErrorLine" (TyFun (TyCon "ParseError") (TyCon "Int")))
(DFunDef false "parseErrorLine" ((PCon "ParseError" (PVar "diagnostic"))) (EMatch (EApp (EVar "diagnosticLoc") (EVar "diagnostic")) (arm (PCon "Loc" PWild (PVar "line") PWild PWild PWild) () (EVar "line"))))
(DTypeSig true "parseErrorCol" (TyFun (TyCon "ParseError") (TyCon "Int")))
(DFunDef false "parseErrorCol" ((PCon "ParseError" (PVar "diagnostic"))) (EMatch (EApp (EVar "diagnosticLoc") (EVar "diagnostic")) (arm (PCon "Loc" PWild PWild (PVar "col") PWild PWild) () (EVar "col"))))
(DTypeSig true "parseErrorMessage" (TyFun (TyCon "ParseError") (TyCon "String")))
(DFunDef false "parseErrorMessage" ((PCon "ParseError" (PVar "diagnostic"))) (EApp (EVar "renderParseDiagnostic") (EVar "diagnostic")))
