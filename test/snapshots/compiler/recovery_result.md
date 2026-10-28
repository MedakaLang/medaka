# META
source_lines=63
stages=DESUGAR,MARK
# SOURCE
import frontend.ast.{Decl}
import frontend.parse_positions.{Positions}
import frontend.parse_diagnostic.{ParseDiagnostic}

public export data SourceExtent = SourceExtent Int Int
public export data InvalidReason =
  | InvalidDeclaration
  | TerminalLexError
  | UnclosedDelimiter
  | MismatchedDelimiter
  | UntrustedBoundary
  | RecoveryBudget
public export data RecoveryStop =
  | ReachedEnd
  | StoppedLexically
  | StoppedDelimiter
  | StoppedBoundary
  | ExhaustedBudget
-- Complete and Partial name source completeness, not presence of a value.
-- lint-disable-next-line rule-clone-type
public export data RecoveryCompleteness = Complete | Partial RecoveryStop
public export data RecoveryStats = RecoveryStats Int Int Int
export data InvalidRegion = InvalidRegion SourceExtent InvalidReason
export data RecoveredSource =
  RecoveredSource (List Decl) Positions (List ParseDiagnostic) (List InvalidRegion) RecoveryCompleteness RecoveryStats

export
makeInvalidRegion : SourceExtent -> InvalidReason -> InvalidRegion
makeInvalidRegion extent reason = InvalidRegion extent reason
export
invalidExtent : InvalidRegion -> SourceExtent
invalidExtent (InvalidRegion extent _) = extent
export
invalidReason : InvalidRegion -> InvalidReason
invalidReason (InvalidRegion _ reason) = reason
export
makeRecoveredSource : List Decl ->
  Positions ->
  List ParseDiagnostic ->
  List InvalidRegion ->
  RecoveryCompleteness ->
  RecoveryStats ->
  RecoveredSource
makeRecoveredSource ds ps diagnostics regions completeness stats =
  RecoveredSource ds ps diagnostics regions completeness stats
export
recoveredDecls : RecoveredSource -> List Decl
recoveredDecls (RecoveredSource ds _ _ _ _ _) = ds
export
recoveredPositions : RecoveredSource -> Positions
recoveredPositions (RecoveredSource _ ps _ _ _ _) = ps
export
recoveredDiagnostics : RecoveredSource -> List ParseDiagnostic
recoveredDiagnostics (RecoveredSource _ _ ds _ _ _) = ds
export
invalidRegions : RecoveredSource -> List InvalidRegion
invalidRegions (RecoveredSource _ _ _ rs _ _) = rs
export
recoveredCompleteness : RecoveredSource -> RecoveryCompleteness
recoveredCompleteness (RecoveredSource _ _ _ _ c _) = c
export
recoveredStats : RecoveredSource -> RecoveryStats
recoveredStats (RecoveredSource _ _ _ _ _ s) = s
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "parse_positions") ((mem "Positions" false))))
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnostic" false))))
(DData Public "SourceExtent" () ((variant "SourceExtent" (ConPos (TyCon "Int") (TyCon "Int")))) ())
(DData Public "InvalidReason" () ((variant "InvalidDeclaration" (ConPos)) (variant "TerminalLexError" (ConPos)) (variant "UnclosedDelimiter" (ConPos)) (variant "MismatchedDelimiter" (ConPos)) (variant "UntrustedBoundary" (ConPos)) (variant "RecoveryBudget" (ConPos))) ())
(DData Public "RecoveryStop" () ((variant "ReachedEnd" (ConPos)) (variant "StoppedLexically" (ConPos)) (variant "StoppedDelimiter" (ConPos)) (variant "StoppedBoundary" (ConPos)) (variant "ExhaustedBudget" (ConPos))) ())
(DData Public "RecoveryCompleteness" () ((variant "Complete" (ConPos)) (variant "Partial" (ConPos (TyCon "RecoveryStop")))) ())
(DData Public "RecoveryStats" () ((variant "RecoveryStats" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DData Abstract "InvalidRegion" () ((variant "InvalidRegion" (ConPos (TyCon "SourceExtent") (TyCon "InvalidReason")))) ())
(DData Abstract "RecoveredSource" () ((variant "RecoveredSource" (ConPos (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "ParseDiagnostic")) (TyApp (TyCon "List") (TyCon "InvalidRegion")) (TyCon "RecoveryCompleteness") (TyCon "RecoveryStats")))) ())
(DTypeSig true "makeInvalidRegion" (TyFun (TyCon "SourceExtent") (TyFun (TyCon "InvalidReason") (TyCon "InvalidRegion"))))
(DFunDef false "makeInvalidRegion" ((PVar "extent") (PVar "reason")) (EApp (EApp (EVar "InvalidRegion") (EVar "extent")) (EVar "reason")))
(DTypeSig true "invalidExtent" (TyFun (TyCon "InvalidRegion") (TyCon "SourceExtent")))
(DFunDef false "invalidExtent" ((PCon "InvalidRegion" (PVar "extent") PWild)) (EVar "extent"))
(DTypeSig true "invalidReason" (TyFun (TyCon "InvalidRegion") (TyCon "InvalidReason")))
(DFunDef false "invalidReason" ((PCon "InvalidRegion" PWild (PVar "reason"))) (EVar "reason"))
(DTypeSig true "makeRecoveredSource" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "ParseDiagnostic")) (TyFun (TyApp (TyCon "List") (TyCon "InvalidRegion")) (TyFun (TyCon "RecoveryCompleteness") (TyFun (TyCon "RecoveryStats") (TyCon "RecoveredSource"))))))))
(DFunDef false "makeRecoveredSource" ((PVar "ds") (PVar "ps") (PVar "diagnostics") (PVar "regions") (PVar "completeness") (PVar "stats")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "RecoveredSource") (EVar "ds")) (EVar "ps")) (EVar "diagnostics")) (EVar "regions")) (EVar "completeness")) (EVar "stats")))
(DTypeSig true "recoveredDecls" (TyFun (TyCon "RecoveredSource") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "recoveredDecls" ((PCon "RecoveredSource" (PVar "ds") PWild PWild PWild PWild PWild)) (EVar "ds"))
(DTypeSig true "recoveredPositions" (TyFun (TyCon "RecoveredSource") (TyCon "Positions")))
(DFunDef false "recoveredPositions" ((PCon "RecoveredSource" PWild (PVar "ps") PWild PWild PWild PWild)) (EVar "ps"))
(DTypeSig true "recoveredDiagnostics" (TyFun (TyCon "RecoveredSource") (TyApp (TyCon "List") (TyCon "ParseDiagnostic"))))
(DFunDef false "recoveredDiagnostics" ((PCon "RecoveredSource" PWild PWild (PVar "ds") PWild PWild PWild)) (EVar "ds"))
(DTypeSig true "invalidRegions" (TyFun (TyCon "RecoveredSource") (TyApp (TyCon "List") (TyCon "InvalidRegion"))))
(DFunDef false "invalidRegions" ((PCon "RecoveredSource" PWild PWild PWild (PVar "rs") PWild PWild)) (EVar "rs"))
(DTypeSig true "recoveredCompleteness" (TyFun (TyCon "RecoveredSource") (TyCon "RecoveryCompleteness")))
(DFunDef false "recoveredCompleteness" ((PCon "RecoveredSource" PWild PWild PWild PWild (PVar "c") PWild)) (EVar "c"))
(DTypeSig true "recoveredStats" (TyFun (TyCon "RecoveredSource") (TyCon "RecoveryStats")))
(DFunDef false "recoveredStats" ((PCon "RecoveredSource" PWild PWild PWild PWild PWild (PVar "s"))) (EVar "s"))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "parse_positions") ((mem "Positions" false))))
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnostic" false))))
(DData Public "SourceExtent" () ((variant "SourceExtent" (ConPos (TyCon "Int") (TyCon "Int")))) ())
(DData Public "InvalidReason" () ((variant "InvalidDeclaration" (ConPos)) (variant "TerminalLexError" (ConPos)) (variant "UnclosedDelimiter" (ConPos)) (variant "MismatchedDelimiter" (ConPos)) (variant "UntrustedBoundary" (ConPos)) (variant "RecoveryBudget" (ConPos))) ())
(DData Public "RecoveryStop" () ((variant "ReachedEnd" (ConPos)) (variant "StoppedLexically" (ConPos)) (variant "StoppedDelimiter" (ConPos)) (variant "StoppedBoundary" (ConPos)) (variant "ExhaustedBudget" (ConPos))) ())
(DData Public "RecoveryCompleteness" () ((variant "Complete" (ConPos)) (variant "Partial" (ConPos (TyCon "RecoveryStop")))) ())
(DData Public "RecoveryStats" () ((variant "RecoveryStats" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DData Abstract "InvalidRegion" () ((variant "InvalidRegion" (ConPos (TyCon "SourceExtent") (TyCon "InvalidReason")))) ())
(DData Abstract "RecoveredSource" () ((variant "RecoveredSource" (ConPos (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "ParseDiagnostic")) (TyApp (TyCon "List") (TyCon "InvalidRegion")) (TyCon "RecoveryCompleteness") (TyCon "RecoveryStats")))) ())
(DTypeSig true "makeInvalidRegion" (TyFun (TyCon "SourceExtent") (TyFun (TyCon "InvalidReason") (TyCon "InvalidRegion"))))
(DFunDef false "makeInvalidRegion" ((PVar "extent") (PVar "reason")) (EApp (EApp (EVar "InvalidRegion") (EVar "extent")) (EVar "reason")))
(DTypeSig true "invalidExtent" (TyFun (TyCon "InvalidRegion") (TyCon "SourceExtent")))
(DFunDef false "invalidExtent" ((PCon "InvalidRegion" (PVar "extent") PWild)) (EVar "extent"))
(DTypeSig true "invalidReason" (TyFun (TyCon "InvalidRegion") (TyCon "InvalidReason")))
(DFunDef false "invalidReason" ((PCon "InvalidRegion" PWild (PVar "reason"))) (EVar "reason"))
(DTypeSig true "makeRecoveredSource" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "ParseDiagnostic")) (TyFun (TyApp (TyCon "List") (TyCon "InvalidRegion")) (TyFun (TyCon "RecoveryCompleteness") (TyFun (TyCon "RecoveryStats") (TyCon "RecoveredSource"))))))))
(DFunDef false "makeRecoveredSource" ((PVar "ds") (PVar "ps") (PVar "diagnostics") (PVar "regions") (PVar "completeness") (PVar "stats")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "RecoveredSource") (EVar "ds")) (EVar "ps")) (EVar "diagnostics")) (EVar "regions")) (EVar "completeness")) (EVar "stats")))
(DTypeSig true "recoveredDecls" (TyFun (TyCon "RecoveredSource") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "recoveredDecls" ((PCon "RecoveredSource" (PVar "ds") PWild PWild PWild PWild PWild)) (EVar "ds"))
(DTypeSig true "recoveredPositions" (TyFun (TyCon "RecoveredSource") (TyCon "Positions")))
(DFunDef false "recoveredPositions" ((PCon "RecoveredSource" PWild (PVar "ps") PWild PWild PWild PWild)) (EVar "ps"))
(DTypeSig true "recoveredDiagnostics" (TyFun (TyCon "RecoveredSource") (TyApp (TyCon "List") (TyCon "ParseDiagnostic"))))
(DFunDef false "recoveredDiagnostics" ((PCon "RecoveredSource" PWild PWild (PVar "ds") PWild PWild PWild)) (EVar "ds"))
(DTypeSig true "invalidRegions" (TyFun (TyCon "RecoveredSource") (TyApp (TyCon "List") (TyCon "InvalidRegion"))))
(DFunDef false "invalidRegions" ((PCon "RecoveredSource" PWild PWild PWild (PVar "rs") PWild PWild)) (EVar "rs"))
(DTypeSig true "recoveredCompleteness" (TyFun (TyCon "RecoveredSource") (TyCon "RecoveryCompleteness")))
(DFunDef false "recoveredCompleteness" ((PCon "RecoveredSource" PWild PWild PWild PWild (PVar "c") PWild)) (EVar "c"))
(DTypeSig true "recoveredStats" (TyFun (TyCon "RecoveredSource") (TyCon "RecoveryStats")))
(DFunDef false "recoveredStats" ((PCon "RecoveredSource" PWild PWild PWild PWild PWild (PVar "s"))) (EVar "s"))
