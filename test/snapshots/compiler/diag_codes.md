# META
source_lines=512
stages=DESUGAR,MARK
# SOURCE
-- diag_codes: the closed set of diagnostic codes the compiler mints, as one flat type.
-- It holds `DiagCode` (one nullary constructor per live code; `T-TYPE-MISMATCH` is
-- `TTypeMismatch`, the prefix letter then the CamelCase of the dash segments; constructors share
-- the `E*`/`P*`/`T*` namespace with the AST constructors, so a code whose camel name collides
-- with one is renamed in the registry), the one place
-- a code's text exists (`codeText`), its prefix family (`DiagKind`, `codeKind`), the list of
-- every code (`allDiagCodes`) and the inverse of `codeText` (`codeOfText`).
--
-- Spec: DIAGNOSTIC-CODES-DESIGN.md section 2 (code taxonomy: prefixes, `kind` derived from the
-- prefix, names stable and append-only); ARCHITECTURE.md A1 (support is the bottom layer).
--
-- Closure rule: this module imports only the prelude and `string`; it may not import any
-- module of `frontend`, `types`, `ir`, `backend`, `eval`, `driver`, `tools` or `entries`.
-- A retired or reserved code text has no constructor and is never reused.  There is no `Ord`
-- on `DiagCode`: a derived `Ord` is one arm per constructor pair; order by `codeText`.

import string.{startsWith}

-- The coarse family of a code, as the JSON `kind` field renders it.  `E-*` codes render as
-- "error".
public export data DiagKind =
  | DkLex
  | DkParse
  | DkResolve
  | DkType
  | DkWarning
  | DkError
  deriving (Eq, Debug)

public export data DiagCode =
  | EAmbiguousDispatch
  | ECyclicValue
  | EDivZero
  | EIndexOob
  | EIntOverflow
  | ELetRefute
  | EMainAsyncPayload
  | EModZero
  | ENoMain
  | ENonexhaustiveMatch
  | ENotAFunction
  | EPanic
  | EPhysDuplicate
  | EPhysShape
  | EPhysUndeclaredFuncref
  | EPhysUndeclaredType
  | EPhysUndefined
  | ESliceOob
  | EStackOverflow
  | EWasmNoBinding
  | LBadByteLiteral
  | LBadChar
  | LBadCharLiteral
  | LBadEscape
  | LBadUnicodeEscape
  | LBareUnicodeEscape
  | LBlockcomment
  | LByteLiteralIdent
  | LByteNonAscii
  | LFloatOverflow
  | LHsDollar
  | LHsLambda
  | LIntOverflow
  | LMalformedFloat
  | LMalformedRadix
  | LNestedInterpolation
  | LSemicolon
  | LUnterminatedComment
  | LUnterminatedString
  | PBadNeq
  | PBraceBlock
  | PDefKeyword
  | PDoEndsInBinding
  | PForWhile
  | PGuardBarInMatch
  | PGuardIfInEquation
  | PHsCase
  | PHsSig
  | PMissingWhere
  | PNoPowOperator
  | POcamlMatchWith
  | PParse
  | PRawStringAfterDot
  | PReservedKeyword
  | PUnexpectedEof
  | PWhereBodySameLine
  | RAbstractCtorImport
  | RAbstractField
  | RAmbiguousCtor
  | RAmbiguousEffect
  | RAmbiguousInterface
  | RAmbiguousOccurrence
  | RAmbiguousType
  | RAsPatternMisplaced
  | RBareCtorImport
  | RBuildFailed
  | RCannotDerive
  | RDupBinder
  | RDupBinding
  | RDuplicateBinding
  | RDuplicateDef
  | RDuplicateIfaceMethod
  | RDuplicateSignature
  | REffectLabelNoMembers
  | RExternWithBody
  | RFieldNotInRecord
  | RFileNotFound
  | RFileNotUtf8
  | RImmutableAssign
  | RInternalExtern
  | RMethodNotInInterface
  | RMisplacedAuthorityBinder
  | RModuleLoad
  | RNewtypeCtorPrivate
  | RNoExportedCtors
  | RNonrecValueLet
  | ROrPatternBinders
  | ROrPatternMisplaced
  | ROrphanSignature
  | RPrivateName
  | RUnbound
  | RUnboundAuthority
  | RUnknownCtor
  | RUnknownEffect
  | RUnknownField
  | RUnknownInterface
  | RUnknownModule
  | RUnknownType
  | TAbstractField
  | TAliasArity
  | TAmbiguousAliasMethod
  | TAmbiguousField
  | TAmbiguousInstance
  | TAmbiguousMethod
  | TAmbiguousReexport
  | TAmbiguousShadowDecl
  | TAuthority
  | TAuthorityBinder
  | TAuthorityDomain
  | TAuthorityEscape
  | TAuthorityExistentialScope
  | TAuthorityIndexMismatch
  | TAuthorityKind
  | TAuthorityPattern
  | TAuthorityPhantomExport
  | TBangOnBool
  | TBindOutsideDo
  | TConflictingImpl
  | TCyclicSuperinterface
  | TDiscardedValue
  | TDoNotMonad
  | TEffectArgUncovered
  | TEffectIndexEager
  | TEffectIndexMismatch
  | TEffectKindMismatch
  | TEffectLaunder
  | TEffectLeak
  | TEffectParam
  | TEffectParamVariance
  | TEffectUndetermined
  | TExportUnsolvedAuthority
  | TFfiBuiltinBind
  | TFfiBuiltinShadow
  | TFfiCatalogNarrow
  | TFfiCSymbol
  | TFfiDuplicateHost
  | TFfiJsName
  | TFfiNoHost
  | TFfiNoncrossable
  | TFfiNullary
  | TFfiReservedName
  | TFfiUnboundHost
  | TFfiUnknownHost
  | TFfiUnlabelled
  | TFieldNotInAllCtors
  | TFieldPositionDiffers
  | TFieldTypeDiffers
  | TFileBoundValue
  | TImplKindMismatch
  | TImplMissingRequires
  | TImplTooSpecific
  | TIncompleteImpl
  | TInfiniteType
  | TInternalOrdinal
  | TMainUsed
  | TManifestEntry
  | TManifestInvalid
  | TManifestWrapper
  | TMethodMismatch
  | TMissingConstraint
  | TMissingField
  | TMissingSuperImpl
  | TNoImpl
  | TNonrecValueLet
  | TNotAFunction
  | TOrPatternBinderTypes
  | TOrPatternTooMany
  | TPhantomMethod
  | TRecursiveAlias
  | TRequiresCycle
  | TRequiresDepth
  | TRequiresUnrouted
  | TResidual
  | TSigOverExpansive
  | TTargetCapability
  | TTargetNoBinding
  | TTargetNotProvided
  | TTypeMismatch
  | TTypeTooGeneral
  | TUnbound
  | TUnknownCtor
  | TUnknownField
  | TUnknownRecord
  | TUnroutedDispatch
  | TUpdateMultiCtor
  | WGuardInexhaustive
  | WImportMethodShadow
  | WIncomparableImpls
  | WKeepIrFailed
  | WMainMissing
  | WMainShape
  | WNonexhaustive
  | WNonexhaustiveClauses
  | WPreludeMethodShadow
  | WUnreachableAlt
  | WUnreachableArm
  deriving (Eq, Debug)

-- The text of [c], as it appears in `--json` output, the LSP and the interface cache.
export
codeText : DiagCode -> String
codeText EAmbiguousDispatch = "E-AMBIGUOUS-DISPATCH"
codeText ECyclicValue = "E-CYCLIC-VALUE"
codeText EDivZero = "E-DIV-ZERO"
codeText EIndexOob = "E-INDEX-OOB"
codeText EIntOverflow = "E-INT-OVERFLOW"
codeText ELetRefute = "E-LET-REFUTE"
codeText EMainAsyncPayload = "E-MAIN-ASYNC-PAYLOAD"
codeText EModZero = "E-MOD-ZERO"
codeText ENoMain = "E-NO-MAIN"
codeText ENonexhaustiveMatch = "E-NONEXHAUSTIVE-MATCH"
codeText ENotAFunction = "E-NOT-A-FUNCTION"
codeText EPanic = "E-PANIC"
codeText EPhysDuplicate = "E-PHYS-DUPLICATE"
codeText EPhysShape = "E-PHYS-SHAPE"
codeText EPhysUndeclaredFuncref = "E-PHYS-UNDECLARED-FUNCREF"
codeText EPhysUndeclaredType = "E-PHYS-UNDECLARED-TYPE"
codeText EPhysUndefined = "E-PHYS-UNDEFINED"
codeText ESliceOob = "E-SLICE-OOB"
codeText EStackOverflow = "E-STACK-OVERFLOW"
codeText EWasmNoBinding = "E-WASM-NO-BINDING"
codeText LBadByteLiteral = "L-BAD-BYTE-LITERAL"
codeText LBadChar = "L-BAD-CHAR"
codeText LBadCharLiteral = "L-BAD-CHAR-LITERAL"
codeText LBadEscape = "L-BAD-ESCAPE"
codeText LBadUnicodeEscape = "L-BAD-UNICODE-ESCAPE"
codeText LBareUnicodeEscape = "L-BARE-UNICODE-ESCAPE"
codeText LBlockcomment = "L-BLOCKCOMMENT"
codeText LByteLiteralIdent = "L-BYTE-LITERAL-IDENT"
codeText LByteNonAscii = "L-BYTE-NON-ASCII"
codeText LFloatOverflow = "L-FLOAT-OVERFLOW"
codeText LHsDollar = "L-HS-DOLLAR"
codeText LHsLambda = "L-HS-LAMBDA"
codeText LIntOverflow = "L-INT-OVERFLOW"
codeText LMalformedFloat = "L-MALFORMED-FLOAT"
codeText LMalformedRadix = "L-MALFORMED-RADIX"
codeText LNestedInterpolation = "L-NESTED-INTERPOLATION"
codeText LSemicolon = "L-SEMICOLON"
codeText LUnterminatedComment = "L-UNTERMINATED-COMMENT"
codeText LUnterminatedString = "L-UNTERMINATED-STRING"
codeText PBadNeq = "P-BAD-NEQ"
codeText PBraceBlock = "P-BRACE-BLOCK"
codeText PDefKeyword = "P-DEF-KEYWORD"
codeText PDoEndsInBinding = "P-DO-ENDS-IN-BINDING"
codeText PForWhile = "P-FOR-WHILE"
codeText PGuardBarInMatch = "P-GUARD-BAR-IN-MATCH"
codeText PGuardIfInEquation = "P-GUARD-IF-IN-EQUATION"
codeText PHsCase = "P-HS-CASE"
codeText PHsSig = "P-HS-SIG"
codeText PMissingWhere = "P-MISSING-WHERE"
codeText PNoPowOperator = "P-NO-POW-OPERATOR"
codeText POcamlMatchWith = "P-OCAML-MATCH-WITH"
codeText PParse = "P-PARSE"
codeText PRawStringAfterDot = "P-RAW-STRING-AFTER-DOT"
codeText PReservedKeyword = "P-RESERVED-KEYWORD"
codeText PUnexpectedEof = "P-UNEXPECTED-EOF"
codeText PWhereBodySameLine = "P-WHERE-BODY-SAME-LINE"
codeText RAbstractCtorImport = "R-ABSTRACT-CTOR-IMPORT"
codeText RAbstractField = "R-ABSTRACT-FIELD"
codeText RAmbiguousCtor = "R-AMBIGUOUS-CTOR"
codeText RAmbiguousEffect = "R-AMBIGUOUS-EFFECT"
codeText RAmbiguousInterface = "R-AMBIGUOUS-INTERFACE"
codeText RAmbiguousOccurrence = "R-AMBIGUOUS-OCCURRENCE"
codeText RAmbiguousType = "R-AMBIGUOUS-TYPE"
codeText RAsPatternMisplaced = "R-AS-PATTERN-MISPLACED"
codeText RBareCtorImport = "R-BARE-CTOR-IMPORT"
codeText RBuildFailed = "R-BUILD-FAILED"
codeText RCannotDerive = "R-CANNOT-DERIVE"
codeText RDupBinder = "R-DUP-BINDER"
codeText RDupBinding = "R-DUP-BINDING"
codeText RDuplicateBinding = "R-DUPLICATE-BINDING"
codeText RDuplicateDef = "R-DUPLICATE-DEF"
codeText RDuplicateIfaceMethod = "R-DUPLICATE-IFACE-METHOD"
codeText RDuplicateSignature = "R-DUPLICATE-SIGNATURE"
codeText REffectLabelNoMembers = "R-EFFECT-LABEL-NO-MEMBERS"
codeText RExternWithBody = "R-EXTERN-WITH-BODY"
codeText RFieldNotInRecord = "R-FIELD-NOT-IN-RECORD"
codeText RFileNotFound = "R-FILE-NOT-FOUND"
codeText RFileNotUtf8 = "R-FILE-NOT-UTF8"
codeText RImmutableAssign = "R-IMMUTABLE-ASSIGN"
codeText RInternalExtern = "R-INTERNAL-EXTERN"
codeText RMethodNotInInterface = "R-METHOD-NOT-IN-INTERFACE"
codeText RMisplacedAuthorityBinder = "R-MISPLACED-AUTHORITY-BINDER"
codeText RModuleLoad = "R-MODULE-LOAD"
codeText RNewtypeCtorPrivate = "R-NEWTYPE-CTOR-PRIVATE"
codeText RNoExportedCtors = "R-NO-EXPORTED-CTORS"
codeText RNonrecValueLet = "R-NONREC-VALUE-LET"
codeText ROrPatternBinders = "R-OR-PATTERN-BINDERS"
codeText ROrPatternMisplaced = "R-OR-PATTERN-MISPLACED"
codeText ROrphanSignature = "R-ORPHAN-SIGNATURE"
codeText RPrivateName = "R-PRIVATE-NAME"
codeText RUnbound = "R-UNBOUND"
codeText RUnboundAuthority = "R-UNBOUND-AUTHORITY"
codeText RUnknownCtor = "R-UNKNOWN-CTOR"
codeText RUnknownEffect = "R-UNKNOWN-EFFECT"
codeText RUnknownField = "R-UNKNOWN-FIELD"
codeText RUnknownInterface = "R-UNKNOWN-INTERFACE"
codeText RUnknownModule = "R-UNKNOWN-MODULE"
codeText RUnknownType = "R-UNKNOWN-TYPE"
codeText TAbstractField = "T-ABSTRACT-FIELD"
codeText TAliasArity = "T-ALIAS-ARITY"
codeText TAmbiguousAliasMethod = "T-AMBIGUOUS-ALIAS-METHOD"
codeText TAmbiguousField = "T-AMBIGUOUS-FIELD"
codeText TAmbiguousInstance = "T-AMBIGUOUS-INSTANCE"
codeText TAmbiguousMethod = "T-AMBIGUOUS-METHOD"
codeText TAmbiguousReexport = "T-AMBIGUOUS-REEXPORT"
codeText TAmbiguousShadowDecl = "T-AMBIGUOUS-SHADOW-DECL"
codeText TAuthority = "T-AUTHORITY"
codeText TAuthorityBinder = "T-AUTHORITY-BINDER"
codeText TAuthorityDomain = "T-AUTHORITY-DOMAIN"
codeText TAuthorityEscape = "T-AUTHORITY-ESCAPE"
codeText TAuthorityExistentialScope = "T-AUTHORITY-EXISTENTIAL-SCOPE"
codeText TAuthorityIndexMismatch = "T-AUTHORITY-INDEX-MISMATCH"
codeText TAuthorityKind = "T-AUTHORITY-KIND"
codeText TAuthorityPattern = "T-AUTHORITY-PATTERN"
codeText TAuthorityPhantomExport = "T-AUTHORITY-PHANTOM-EXPORT"
codeText TBangOnBool = "T-BANG-ON-BOOL"
codeText TBindOutsideDo = "T-BIND-OUTSIDE-DO"
codeText TConflictingImpl = "T-CONFLICTING-IMPL"
codeText TCyclicSuperinterface = "T-CYCLIC-SUPERINTERFACE"
codeText TDiscardedValue = "T-DISCARDED-VALUE"
codeText TDoNotMonad = "T-DO-NOT-MONAD"
codeText TEffectArgUncovered = "T-EFFECT-ARG-UNCOVERED"
codeText TEffectIndexEager = "T-EFFECT-INDEX-EAGER"
codeText TEffectIndexMismatch = "T-EFFECT-INDEX-MISMATCH"
codeText TEffectKindMismatch = "T-EFFECT-KIND-MISMATCH"
codeText TEffectLaunder = "T-EFFECT-LAUNDER"
codeText TEffectLeak = "T-EFFECT-LEAK"
codeText TEffectParam = "T-EFFECT-PARAM"
codeText TEffectParamVariance = "T-EFFECT-PARAM-VARIANCE"
codeText TEffectUndetermined = "T-EFFECT-UNDETERMINED"
codeText TExportUnsolvedAuthority = "T-EXPORT-UNSOLVED-AUTHORITY"
codeText TFfiBuiltinBind = "T-FFI-BUILTIN-BIND"
codeText TFfiBuiltinShadow = "T-FFI-BUILTIN-SHADOW"
codeText TFfiCatalogNarrow = "T-FFI-CATALOG-NARROW"
codeText TFfiCSymbol = "T-FFI-C-SYMBOL"
codeText TFfiDuplicateHost = "T-FFI-DUPLICATE-HOST"
codeText TFfiJsName = "T-FFI-JS-NAME"
codeText TFfiNoHost = "T-FFI-NO-HOST"
codeText TFfiNoncrossable = "T-FFI-NONCROSSABLE"
codeText TFfiNullary = "T-FFI-NULLARY"
codeText TFfiReservedName = "T-FFI-RESERVED-NAME"
codeText TFfiUnboundHost = "T-FFI-UNBOUND-HOST"
codeText TFfiUnknownHost = "T-FFI-UNKNOWN-HOST"
codeText TFfiUnlabelled = "T-FFI-UNLABELLED"
codeText TFieldNotInAllCtors = "T-FIELD-NOT-IN-ALL-CTORS"
codeText TFieldPositionDiffers = "T-FIELD-POSITION-DIFFERS"
codeText TFieldTypeDiffers = "T-FIELD-TYPE-DIFFERS"
codeText TFileBoundValue = "T-FILE-BOUND-VALUE"
codeText TImplKindMismatch = "T-IMPL-KIND-MISMATCH"
codeText TImplMissingRequires = "T-IMPL-MISSING-REQUIRES"
codeText TImplTooSpecific = "T-IMPL-TOO-SPECIFIC"
codeText TIncompleteImpl = "T-INCOMPLETE-IMPL"
codeText TInfiniteType = "T-INFINITE-TYPE"
codeText TInternalOrdinal = "T-INTERNAL-ORDINAL"
codeText TMainUsed = "T-MAIN-USED"
codeText TManifestEntry = "T-MANIFEST-ENTRY"
codeText TManifestInvalid = "T-MANIFEST-INVALID"
codeText TManifestWrapper = "T-MANIFEST-WRAPPER"
codeText TMethodMismatch = "T-METHOD-MISMATCH"
codeText TMissingConstraint = "T-MISSING-CONSTRAINT"
codeText TMissingField = "T-MISSING-FIELD"
codeText TMissingSuperImpl = "T-MISSING-SUPER-IMPL"
codeText TNoImpl = "T-NO-IMPL"
codeText TNonrecValueLet = "T-NONREC-VALUE-LET"
codeText TNotAFunction = "T-NOT-A-FUNCTION"
codeText TOrPatternBinderTypes = "T-OR-PATTERN-BINDER-TYPES"
codeText TOrPatternTooMany = "T-OR-PATTERN-TOO-MANY"
codeText TPhantomMethod = "T-PHANTOM-METHOD"
codeText TRecursiveAlias = "T-RECURSIVE-ALIAS"
codeText TRequiresCycle = "T-REQUIRES-CYCLE"
codeText TRequiresDepth = "T-REQUIRES-DEPTH"
codeText TRequiresUnrouted = "T-REQUIRES-UNROUTED"
codeText TResidual = "T-RESIDUAL"
codeText TSigOverExpansive = "T-SIG-OVER-EXPANSIVE"
codeText TTargetCapability = "T-TARGET-CAPABILITY"
codeText TTargetNoBinding = "T-TARGET-NO-BINDING"
codeText TTargetNotProvided = "T-TARGET-NOT-PROVIDED"
codeText TTypeMismatch = "T-TYPE-MISMATCH"
codeText TTypeTooGeneral = "T-TYPE-TOO-GENERAL"
codeText TUnbound = "T-UNBOUND"
codeText TUnknownCtor = "T-UNKNOWN-CTOR"
codeText TUnknownField = "T-UNKNOWN-FIELD"
codeText TUnknownRecord = "T-UNKNOWN-RECORD"
codeText TUnroutedDispatch = "T-UNROUTED-DISPATCH"
codeText TUpdateMultiCtor = "T-UPDATE-MULTI-CTOR"
codeText WGuardInexhaustive = "W-GUARD-INEXHAUSTIVE"
codeText WImportMethodShadow = "W-IMPORT-METHOD-SHADOW"
codeText WIncomparableImpls = "W-INCOMPARABLE-IMPLS"
codeText WKeepIrFailed = "W-KEEP-IR-FAILED"
codeText WMainMissing = "W-MAIN-MISSING"
codeText WMainShape = "W-MAIN-SHAPE"
codeText WNonexhaustive = "W-NONEXHAUSTIVE"
codeText WNonexhaustiveClauses = "W-NONEXHAUSTIVE-CLAUSES"
codeText WPreludeMethodShadow = "W-PRELUDE-METHOD-SHADOW"
codeText WUnreachableAlt = "W-UNREACHABLE-ALT"
codeText WUnreachableArm = "W-UNREACHABLE-ARM"

-- The JSON `kind` text of [k].
export
kindText : DiagKind -> String
kindText DkLex = "lex"
kindText DkParse = "parse"
kindText DkResolve = "resolve"
kindText DkType = "type"
kindText DkWarning = "warning"
kindText DkError = "error"

-- The family of [c], from the prefix letter of its text.
export
codeKind : DiagCode -> DiagKind
codeKind c = kindOfText (codeText c)

kindOfText : String -> DiagKind
kindOfText t
  | startsWith "L-" t = DkLex
  | startsWith "P-" t = DkParse
  | startsWith "R-" t = DkResolve
  | startsWith "T-" t = DkType
  | startsWith "W-" t = DkWarning
  | otherwise = DkError

-- Every code, once, in the order of the declaration.
export
allDiagCodes : List DiagCode
allDiagCodes = [
  EAmbiguousDispatch, ECyclicValue, EDivZero, EIndexOob, EIntOverflow,
  ELetRefute, EMainAsyncPayload, EModZero, ENoMain, ENonexhaustiveMatch,
  ENotAFunction, EPanic, EPhysDuplicate, EPhysShape, EPhysUndeclaredFuncref,
  EPhysUndeclaredType, EPhysUndefined, ESliceOob, EStackOverflow,
  EWasmNoBinding, LBadByteLiteral, LBadChar, LBadCharLiteral, LBadEscape,
  LBadUnicodeEscape, LBareUnicodeEscape, LBlockcomment, LByteLiteralIdent,
  LByteNonAscii, LFloatOverflow, LHsDollar, LHsLambda, LIntOverflow,
  LMalformedFloat, LMalformedRadix, LNestedInterpolation, LSemicolon,
  LUnterminatedComment, LUnterminatedString, PBadNeq, PBraceBlock, PDefKeyword,
  PDoEndsInBinding, PForWhile, PGuardBarInMatch, PGuardIfInEquation, PHsCase,
  PHsSig, PMissingWhere, PNoPowOperator, POcamlMatchWith, PParse,
  PRawStringAfterDot, PReservedKeyword, PUnexpectedEof, PWhereBodySameLine,
  RAbstractCtorImport, RAbstractField, RAmbiguousCtor, RAmbiguousEffect,
  RAmbiguousInterface, RAmbiguousOccurrence, RAmbiguousType,
  RAsPatternMisplaced, RBareCtorImport, RBuildFailed, RCannotDerive, RDupBinder,
  RDupBinding, RDuplicateBinding, RDuplicateDef, RDuplicateIfaceMethod,
  RDuplicateSignature, REffectLabelNoMembers, RExternWithBody,
  RFieldNotInRecord, RFileNotFound, RFileNotUtf8, RImmutableAssign,
  RInternalExtern, RMethodNotInInterface, RMisplacedAuthorityBinder,
  RModuleLoad, RNewtypeCtorPrivate, RNoExportedCtors, RNonrecValueLet,
  ROrPatternBinders, ROrPatternMisplaced, ROrphanSignature, RPrivateName,
  RUnbound, RUnboundAuthority, RUnknownCtor, RUnknownEffect, RUnknownField,
  RUnknownInterface, RUnknownModule, RUnknownType, TAbstractField, TAliasArity,
  TAmbiguousAliasMethod, TAmbiguousField, TAmbiguousInstance, TAmbiguousMethod,
  TAmbiguousReexport, TAmbiguousShadowDecl, TAuthority, TAuthorityBinder,
  TAuthorityDomain, TAuthorityEscape, TAuthorityExistentialScope,
  TAuthorityIndexMismatch, TAuthorityKind, TAuthorityPattern,
  TAuthorityPhantomExport, TBangOnBool, TBindOutsideDo, TConflictingImpl,
  TCyclicSuperinterface, TDiscardedValue, TDoNotMonad, TEffectArgUncovered,
  TEffectIndexEager, TEffectIndexMismatch, TEffectKindMismatch, TEffectLaunder,
  TEffectLeak, TEffectParam, TEffectParamVariance, TEffectUndetermined,
  TExportUnsolvedAuthority, TFfiBuiltinBind, TFfiBuiltinShadow,
  TFfiCatalogNarrow, TFfiCSymbol, TFfiDuplicateHost, TFfiJsName, TFfiNoHost,
  TFfiNoncrossable, TFfiNullary, TFfiReservedName, TFfiUnboundHost,
  TFfiUnknownHost, TFfiUnlabelled, TFieldNotInAllCtors, TFieldPositionDiffers,
  TFieldTypeDiffers, TFileBoundValue, TImplKindMismatch, TImplMissingRequires,
  TImplTooSpecific, TIncompleteImpl, TInfiniteType, TInternalOrdinal, TMainUsed,
  TManifestEntry, TManifestInvalid, TManifestWrapper, TMethodMismatch,
  TMissingConstraint, TMissingField, TMissingSuperImpl, TNoImpl,
  TNonrecValueLet, TNotAFunction, TOrPatternBinderTypes, TOrPatternTooMany,
  TPhantomMethod, TRecursiveAlias, TRequiresCycle, TRequiresDepth,
  TRequiresUnrouted, TResidual, TSigOverExpansive, TTargetCapability,
  TTargetNoBinding, TTargetNotProvided, TTypeMismatch, TTypeTooGeneral,
  TUnbound, TUnknownCtor, TUnknownField, TUnknownRecord, TUnroutedDispatch,
  TUpdateMultiCtor, WGuardInexhaustive, WImportMethodShadow, WIncomparableImpls,
  WKeepIrFailed, WMainMissing, WMainShape, WNonexhaustive,
  WNonexhaustiveClauses, WPreludeMethodShadow, WUnreachableAlt, WUnreachableArm
]

-- The code whose text is [t], or `None` when [t] is no live code.
export
codeOfText : String -> Option DiagCode
codeOfText t = find (c => codeText c == t) allDiagCodes

impl Display DiagCode where
  display = codeText
# DESUGAR
(DUse false (UseGroup ("string") ((mem "startsWith" false))))
(DData Public "DiagKind" () ((variant "DkLex" (ConPos)) (variant "DkParse" (ConPos)) (variant "DkResolve" (ConPos)) (variant "DkType" (ConPos)) (variant "DkWarning" (ConPos)) (variant "DkError" (ConPos))) ())
(DImpl true "Eq" ((TyCon "DiagKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "DkLex") (PCon "DkLex")) () (EVar "True")) (arm (PTuple (PCon "DkParse") (PCon "DkParse")) () (EVar "True")) (arm (PTuple (PCon "DkResolve") (PCon "DkResolve")) () (EVar "True")) (arm (PTuple (PCon "DkType") (PCon "DkType")) () (EVar "True")) (arm (PTuple (PCon "DkWarning") (PCon "DkWarning")) () (EVar "True")) (arm (PTuple (PCon "DkError") (PCon "DkError")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "DiagKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "DkLex") () (ELit (LString "DkLex"))) (arm (PCon "DkParse") () (ELit (LString "DkParse"))) (arm (PCon "DkResolve") () (ELit (LString "DkResolve"))) (arm (PCon "DkType") () (ELit (LString "DkType"))) (arm (PCon "DkWarning") () (ELit (LString "DkWarning"))) (arm (PCon "DkError") () (ELit (LString "DkError")))))))
(DData Public "DiagCode" () ((variant "EAmbiguousDispatch" (ConPos)) (variant "ECyclicValue" (ConPos)) (variant "EDivZero" (ConPos)) (variant "EIndexOob" (ConPos)) (variant "EIntOverflow" (ConPos)) (variant "ELetRefute" (ConPos)) (variant "EMainAsyncPayload" (ConPos)) (variant "EModZero" (ConPos)) (variant "ENoMain" (ConPos)) (variant "ENonexhaustiveMatch" (ConPos)) (variant "ENotAFunction" (ConPos)) (variant "EPanic" (ConPos)) (variant "EPhysDuplicate" (ConPos)) (variant "EPhysShape" (ConPos)) (variant "EPhysUndeclaredFuncref" (ConPos)) (variant "EPhysUndeclaredType" (ConPos)) (variant "EPhysUndefined" (ConPos)) (variant "ESliceOob" (ConPos)) (variant "EStackOverflow" (ConPos)) (variant "EWasmNoBinding" (ConPos)) (variant "LBadByteLiteral" (ConPos)) (variant "LBadChar" (ConPos)) (variant "LBadCharLiteral" (ConPos)) (variant "LBadEscape" (ConPos)) (variant "LBadUnicodeEscape" (ConPos)) (variant "LBareUnicodeEscape" (ConPos)) (variant "LBlockcomment" (ConPos)) (variant "LByteLiteralIdent" (ConPos)) (variant "LByteNonAscii" (ConPos)) (variant "LFloatOverflow" (ConPos)) (variant "LHsDollar" (ConPos)) (variant "LHsLambda" (ConPos)) (variant "LIntOverflow" (ConPos)) (variant "LMalformedFloat" (ConPos)) (variant "LMalformedRadix" (ConPos)) (variant "LNestedInterpolation" (ConPos)) (variant "LSemicolon" (ConPos)) (variant "LUnterminatedComment" (ConPos)) (variant "LUnterminatedString" (ConPos)) (variant "PBadNeq" (ConPos)) (variant "PBraceBlock" (ConPos)) (variant "PDefKeyword" (ConPos)) (variant "PDoEndsInBinding" (ConPos)) (variant "PForWhile" (ConPos)) (variant "PGuardBarInMatch" (ConPos)) (variant "PGuardIfInEquation" (ConPos)) (variant "PHsCase" (ConPos)) (variant "PHsSig" (ConPos)) (variant "PMissingWhere" (ConPos)) (variant "PNoPowOperator" (ConPos)) (variant "POcamlMatchWith" (ConPos)) (variant "PParse" (ConPos)) (variant "PRawStringAfterDot" (ConPos)) (variant "PReservedKeyword" (ConPos)) (variant "PUnexpectedEof" (ConPos)) (variant "PWhereBodySameLine" (ConPos)) (variant "RAbstractCtorImport" (ConPos)) (variant "RAbstractField" (ConPos)) (variant "RAmbiguousCtor" (ConPos)) (variant "RAmbiguousEffect" (ConPos)) (variant "RAmbiguousInterface" (ConPos)) (variant "RAmbiguousOccurrence" (ConPos)) (variant "RAmbiguousType" (ConPos)) (variant "RAsPatternMisplaced" (ConPos)) (variant "RBareCtorImport" (ConPos)) (variant "RBuildFailed" (ConPos)) (variant "RCannotDerive" (ConPos)) (variant "RDupBinder" (ConPos)) (variant "RDupBinding" (ConPos)) (variant "RDuplicateBinding" (ConPos)) (variant "RDuplicateDef" (ConPos)) (variant "RDuplicateIfaceMethod" (ConPos)) (variant "RDuplicateSignature" (ConPos)) (variant "REffectLabelNoMembers" (ConPos)) (variant "RExternWithBody" (ConPos)) (variant "RFieldNotInRecord" (ConPos)) (variant "RFileNotFound" (ConPos)) (variant "RFileNotUtf8" (ConPos)) (variant "RImmutableAssign" (ConPos)) (variant "RInternalExtern" (ConPos)) (variant "RMethodNotInInterface" (ConPos)) (variant "RMisplacedAuthorityBinder" (ConPos)) (variant "RModuleLoad" (ConPos)) (variant "RNewtypeCtorPrivate" (ConPos)) (variant "RNoExportedCtors" (ConPos)) (variant "RNonrecValueLet" (ConPos)) (variant "ROrPatternBinders" (ConPos)) (variant "ROrPatternMisplaced" (ConPos)) (variant "ROrphanSignature" (ConPos)) (variant "RPrivateName" (ConPos)) (variant "RUnbound" (ConPos)) (variant "RUnboundAuthority" (ConPos)) (variant "RUnknownCtor" (ConPos)) (variant "RUnknownEffect" (ConPos)) (variant "RUnknownField" (ConPos)) (variant "RUnknownInterface" (ConPos)) (variant "RUnknownModule" (ConPos)) (variant "RUnknownType" (ConPos)) (variant "TAbstractField" (ConPos)) (variant "TAliasArity" (ConPos)) (variant "TAmbiguousAliasMethod" (ConPos)) (variant "TAmbiguousField" (ConPos)) (variant "TAmbiguousInstance" (ConPos)) (variant "TAmbiguousMethod" (ConPos)) (variant "TAmbiguousReexport" (ConPos)) (variant "TAmbiguousShadowDecl" (ConPos)) (variant "TAuthority" (ConPos)) (variant "TAuthorityBinder" (ConPos)) (variant "TAuthorityDomain" (ConPos)) (variant "TAuthorityEscape" (ConPos)) (variant "TAuthorityExistentialScope" (ConPos)) (variant "TAuthorityIndexMismatch" (ConPos)) (variant "TAuthorityKind" (ConPos)) (variant "TAuthorityPattern" (ConPos)) (variant "TAuthorityPhantomExport" (ConPos)) (variant "TBangOnBool" (ConPos)) (variant "TBindOutsideDo" (ConPos)) (variant "TConflictingImpl" (ConPos)) (variant "TCyclicSuperinterface" (ConPos)) (variant "TDiscardedValue" (ConPos)) (variant "TDoNotMonad" (ConPos)) (variant "TEffectArgUncovered" (ConPos)) (variant "TEffectIndexEager" (ConPos)) (variant "TEffectIndexMismatch" (ConPos)) (variant "TEffectKindMismatch" (ConPos)) (variant "TEffectLaunder" (ConPos)) (variant "TEffectLeak" (ConPos)) (variant "TEffectParam" (ConPos)) (variant "TEffectParamVariance" (ConPos)) (variant "TEffectUndetermined" (ConPos)) (variant "TExportUnsolvedAuthority" (ConPos)) (variant "TFfiBuiltinBind" (ConPos)) (variant "TFfiBuiltinShadow" (ConPos)) (variant "TFfiCatalogNarrow" (ConPos)) (variant "TFfiCSymbol" (ConPos)) (variant "TFfiDuplicateHost" (ConPos)) (variant "TFfiJsName" (ConPos)) (variant "TFfiNoHost" (ConPos)) (variant "TFfiNoncrossable" (ConPos)) (variant "TFfiNullary" (ConPos)) (variant "TFfiReservedName" (ConPos)) (variant "TFfiUnboundHost" (ConPos)) (variant "TFfiUnknownHost" (ConPos)) (variant "TFfiUnlabelled" (ConPos)) (variant "TFieldNotInAllCtors" (ConPos)) (variant "TFieldPositionDiffers" (ConPos)) (variant "TFieldTypeDiffers" (ConPos)) (variant "TFileBoundValue" (ConPos)) (variant "TImplKindMismatch" (ConPos)) (variant "TImplMissingRequires" (ConPos)) (variant "TImplTooSpecific" (ConPos)) (variant "TIncompleteImpl" (ConPos)) (variant "TInfiniteType" (ConPos)) (variant "TInternalOrdinal" (ConPos)) (variant "TMainUsed" (ConPos)) (variant "TManifestEntry" (ConPos)) (variant "TManifestInvalid" (ConPos)) (variant "TManifestWrapper" (ConPos)) (variant "TMethodMismatch" (ConPos)) (variant "TMissingConstraint" (ConPos)) (variant "TMissingField" (ConPos)) (variant "TMissingSuperImpl" (ConPos)) (variant "TNoImpl" (ConPos)) (variant "TNonrecValueLet" (ConPos)) (variant "TNotAFunction" (ConPos)) (variant "TOrPatternBinderTypes" (ConPos)) (variant "TOrPatternTooMany" (ConPos)) (variant "TPhantomMethod" (ConPos)) (variant "TRecursiveAlias" (ConPos)) (variant "TRequiresCycle" (ConPos)) (variant "TRequiresDepth" (ConPos)) (variant "TRequiresUnrouted" (ConPos)) (variant "TResidual" (ConPos)) (variant "TSigOverExpansive" (ConPos)) (variant "TTargetCapability" (ConPos)) (variant "TTargetNoBinding" (ConPos)) (variant "TTargetNotProvided" (ConPos)) (variant "TTypeMismatch" (ConPos)) (variant "TTypeTooGeneral" (ConPos)) (variant "TUnbound" (ConPos)) (variant "TUnknownCtor" (ConPos)) (variant "TUnknownField" (ConPos)) (variant "TUnknownRecord" (ConPos)) (variant "TUnroutedDispatch" (ConPos)) (variant "TUpdateMultiCtor" (ConPos)) (variant "WGuardInexhaustive" (ConPos)) (variant "WImportMethodShadow" (ConPos)) (variant "WIncomparableImpls" (ConPos)) (variant "WKeepIrFailed" (ConPos)) (variant "WMainMissing" (ConPos)) (variant "WMainShape" (ConPos)) (variant "WNonexhaustive" (ConPos)) (variant "WNonexhaustiveClauses" (ConPos)) (variant "WPreludeMethodShadow" (ConPos)) (variant "WUnreachableAlt" (ConPos)) (variant "WUnreachableArm" (ConPos))) ())
(DImpl true "Eq" ((TyCon "DiagCode")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "EAmbiguousDispatch") (PCon "EAmbiguousDispatch")) () (EVar "True")) (arm (PTuple (PCon "ECyclicValue") (PCon "ECyclicValue")) () (EVar "True")) (arm (PTuple (PCon "EDivZero") (PCon "EDivZero")) () (EVar "True")) (arm (PTuple (PCon "EIndexOob") (PCon "EIndexOob")) () (EVar "True")) (arm (PTuple (PCon "EIntOverflow") (PCon "EIntOverflow")) () (EVar "True")) (arm (PTuple (PCon "ELetRefute") (PCon "ELetRefute")) () (EVar "True")) (arm (PTuple (PCon "EMainAsyncPayload") (PCon "EMainAsyncPayload")) () (EVar "True")) (arm (PTuple (PCon "EModZero") (PCon "EModZero")) () (EVar "True")) (arm (PTuple (PCon "ENoMain") (PCon "ENoMain")) () (EVar "True")) (arm (PTuple (PCon "ENonexhaustiveMatch") (PCon "ENonexhaustiveMatch")) () (EVar "True")) (arm (PTuple (PCon "ENotAFunction") (PCon "ENotAFunction")) () (EVar "True")) (arm (PTuple (PCon "EPanic") (PCon "EPanic")) () (EVar "True")) (arm (PTuple (PCon "EPhysDuplicate") (PCon "EPhysDuplicate")) () (EVar "True")) (arm (PTuple (PCon "EPhysShape") (PCon "EPhysShape")) () (EVar "True")) (arm (PTuple (PCon "EPhysUndeclaredFuncref") (PCon "EPhysUndeclaredFuncref")) () (EVar "True")) (arm (PTuple (PCon "EPhysUndeclaredType") (PCon "EPhysUndeclaredType")) () (EVar "True")) (arm (PTuple (PCon "EPhysUndefined") (PCon "EPhysUndefined")) () (EVar "True")) (arm (PTuple (PCon "ESliceOob") (PCon "ESliceOob")) () (EVar "True")) (arm (PTuple (PCon "EStackOverflow") (PCon "EStackOverflow")) () (EVar "True")) (arm (PTuple (PCon "EWasmNoBinding") (PCon "EWasmNoBinding")) () (EVar "True")) (arm (PTuple (PCon "LBadByteLiteral") (PCon "LBadByteLiteral")) () (EVar "True")) (arm (PTuple (PCon "LBadChar") (PCon "LBadChar")) () (EVar "True")) (arm (PTuple (PCon "LBadCharLiteral") (PCon "LBadCharLiteral")) () (EVar "True")) (arm (PTuple (PCon "LBadEscape") (PCon "LBadEscape")) () (EVar "True")) (arm (PTuple (PCon "LBadUnicodeEscape") (PCon "LBadUnicodeEscape")) () (EVar "True")) (arm (PTuple (PCon "LBareUnicodeEscape") (PCon "LBareUnicodeEscape")) () (EVar "True")) (arm (PTuple (PCon "LBlockcomment") (PCon "LBlockcomment")) () (EVar "True")) (arm (PTuple (PCon "LByteLiteralIdent") (PCon "LByteLiteralIdent")) () (EVar "True")) (arm (PTuple (PCon "LByteNonAscii") (PCon "LByteNonAscii")) () (EVar "True")) (arm (PTuple (PCon "LFloatOverflow") (PCon "LFloatOverflow")) () (EVar "True")) (arm (PTuple (PCon "LHsDollar") (PCon "LHsDollar")) () (EVar "True")) (arm (PTuple (PCon "LHsLambda") (PCon "LHsLambda")) () (EVar "True")) (arm (PTuple (PCon "LIntOverflow") (PCon "LIntOverflow")) () (EVar "True")) (arm (PTuple (PCon "LMalformedFloat") (PCon "LMalformedFloat")) () (EVar "True")) (arm (PTuple (PCon "LMalformedRadix") (PCon "LMalformedRadix")) () (EVar "True")) (arm (PTuple (PCon "LNestedInterpolation") (PCon "LNestedInterpolation")) () (EVar "True")) (arm (PTuple (PCon "LSemicolon") (PCon "LSemicolon")) () (EVar "True")) (arm (PTuple (PCon "LUnterminatedComment") (PCon "LUnterminatedComment")) () (EVar "True")) (arm (PTuple (PCon "LUnterminatedString") (PCon "LUnterminatedString")) () (EVar "True")) (arm (PTuple (PCon "PBadNeq") (PCon "PBadNeq")) () (EVar "True")) (arm (PTuple (PCon "PBraceBlock") (PCon "PBraceBlock")) () (EVar "True")) (arm (PTuple (PCon "PDefKeyword") (PCon "PDefKeyword")) () (EVar "True")) (arm (PTuple (PCon "PDoEndsInBinding") (PCon "PDoEndsInBinding")) () (EVar "True")) (arm (PTuple (PCon "PForWhile") (PCon "PForWhile")) () (EVar "True")) (arm (PTuple (PCon "PGuardBarInMatch") (PCon "PGuardBarInMatch")) () (EVar "True")) (arm (PTuple (PCon "PGuardIfInEquation") (PCon "PGuardIfInEquation")) () (EVar "True")) (arm (PTuple (PCon "PHsCase") (PCon "PHsCase")) () (EVar "True")) (arm (PTuple (PCon "PHsSig") (PCon "PHsSig")) () (EVar "True")) (arm (PTuple (PCon "PMissingWhere") (PCon "PMissingWhere")) () (EVar "True")) (arm (PTuple (PCon "PNoPowOperator") (PCon "PNoPowOperator")) () (EVar "True")) (arm (PTuple (PCon "POcamlMatchWith") (PCon "POcamlMatchWith")) () (EVar "True")) (arm (PTuple (PCon "PParse") (PCon "PParse")) () (EVar "True")) (arm (PTuple (PCon "PRawStringAfterDot") (PCon "PRawStringAfterDot")) () (EVar "True")) (arm (PTuple (PCon "PReservedKeyword") (PCon "PReservedKeyword")) () (EVar "True")) (arm (PTuple (PCon "PUnexpectedEof") (PCon "PUnexpectedEof")) () (EVar "True")) (arm (PTuple (PCon "PWhereBodySameLine") (PCon "PWhereBodySameLine")) () (EVar "True")) (arm (PTuple (PCon "RAbstractCtorImport") (PCon "RAbstractCtorImport")) () (EVar "True")) (arm (PTuple (PCon "RAbstractField") (PCon "RAbstractField")) () (EVar "True")) (arm (PTuple (PCon "RAmbiguousCtor") (PCon "RAmbiguousCtor")) () (EVar "True")) (arm (PTuple (PCon "RAmbiguousEffect") (PCon "RAmbiguousEffect")) () (EVar "True")) (arm (PTuple (PCon "RAmbiguousInterface") (PCon "RAmbiguousInterface")) () (EVar "True")) (arm (PTuple (PCon "RAmbiguousOccurrence") (PCon "RAmbiguousOccurrence")) () (EVar "True")) (arm (PTuple (PCon "RAmbiguousType") (PCon "RAmbiguousType")) () (EVar "True")) (arm (PTuple (PCon "RAsPatternMisplaced") (PCon "RAsPatternMisplaced")) () (EVar "True")) (arm (PTuple (PCon "RBareCtorImport") (PCon "RBareCtorImport")) () (EVar "True")) (arm (PTuple (PCon "RBuildFailed") (PCon "RBuildFailed")) () (EVar "True")) (arm (PTuple (PCon "RCannotDerive") (PCon "RCannotDerive")) () (EVar "True")) (arm (PTuple (PCon "RDupBinder") (PCon "RDupBinder")) () (EVar "True")) (arm (PTuple (PCon "RDupBinding") (PCon "RDupBinding")) () (EVar "True")) (arm (PTuple (PCon "RDuplicateBinding") (PCon "RDuplicateBinding")) () (EVar "True")) (arm (PTuple (PCon "RDuplicateDef") (PCon "RDuplicateDef")) () (EVar "True")) (arm (PTuple (PCon "RDuplicateIfaceMethod") (PCon "RDuplicateIfaceMethod")) () (EVar "True")) (arm (PTuple (PCon "RDuplicateSignature") (PCon "RDuplicateSignature")) () (EVar "True")) (arm (PTuple (PCon "REffectLabelNoMembers") (PCon "REffectLabelNoMembers")) () (EVar "True")) (arm (PTuple (PCon "RExternWithBody") (PCon "RExternWithBody")) () (EVar "True")) (arm (PTuple (PCon "RFieldNotInRecord") (PCon "RFieldNotInRecord")) () (EVar "True")) (arm (PTuple (PCon "RFileNotFound") (PCon "RFileNotFound")) () (EVar "True")) (arm (PTuple (PCon "RFileNotUtf8") (PCon "RFileNotUtf8")) () (EVar "True")) (arm (PTuple (PCon "RImmutableAssign") (PCon "RImmutableAssign")) () (EVar "True")) (arm (PTuple (PCon "RInternalExtern") (PCon "RInternalExtern")) () (EVar "True")) (arm (PTuple (PCon "RMethodNotInInterface") (PCon "RMethodNotInInterface")) () (EVar "True")) (arm (PTuple (PCon "RMisplacedAuthorityBinder") (PCon "RMisplacedAuthorityBinder")) () (EVar "True")) (arm (PTuple (PCon "RModuleLoad") (PCon "RModuleLoad")) () (EVar "True")) (arm (PTuple (PCon "RNewtypeCtorPrivate") (PCon "RNewtypeCtorPrivate")) () (EVar "True")) (arm (PTuple (PCon "RNoExportedCtors") (PCon "RNoExportedCtors")) () (EVar "True")) (arm (PTuple (PCon "RNonrecValueLet") (PCon "RNonrecValueLet")) () (EVar "True")) (arm (PTuple (PCon "ROrPatternBinders") (PCon "ROrPatternBinders")) () (EVar "True")) (arm (PTuple (PCon "ROrPatternMisplaced") (PCon "ROrPatternMisplaced")) () (EVar "True")) (arm (PTuple (PCon "ROrphanSignature") (PCon "ROrphanSignature")) () (EVar "True")) (arm (PTuple (PCon "RPrivateName") (PCon "RPrivateName")) () (EVar "True")) (arm (PTuple (PCon "RUnbound") (PCon "RUnbound")) () (EVar "True")) (arm (PTuple (PCon "RUnboundAuthority") (PCon "RUnboundAuthority")) () (EVar "True")) (arm (PTuple (PCon "RUnknownCtor") (PCon "RUnknownCtor")) () (EVar "True")) (arm (PTuple (PCon "RUnknownEffect") (PCon "RUnknownEffect")) () (EVar "True")) (arm (PTuple (PCon "RUnknownField") (PCon "RUnknownField")) () (EVar "True")) (arm (PTuple (PCon "RUnknownInterface") (PCon "RUnknownInterface")) () (EVar "True")) (arm (PTuple (PCon "RUnknownModule") (PCon "RUnknownModule")) () (EVar "True")) (arm (PTuple (PCon "RUnknownType") (PCon "RUnknownType")) () (EVar "True")) (arm (PTuple (PCon "TAbstractField") (PCon "TAbstractField")) () (EVar "True")) (arm (PTuple (PCon "TAliasArity") (PCon "TAliasArity")) () (EVar "True")) (arm (PTuple (PCon "TAmbiguousAliasMethod") (PCon "TAmbiguousAliasMethod")) () (EVar "True")) (arm (PTuple (PCon "TAmbiguousField") (PCon "TAmbiguousField")) () (EVar "True")) (arm (PTuple (PCon "TAmbiguousInstance") (PCon "TAmbiguousInstance")) () (EVar "True")) (arm (PTuple (PCon "TAmbiguousMethod") (PCon "TAmbiguousMethod")) () (EVar "True")) (arm (PTuple (PCon "TAmbiguousReexport") (PCon "TAmbiguousReexport")) () (EVar "True")) (arm (PTuple (PCon "TAmbiguousShadowDecl") (PCon "TAmbiguousShadowDecl")) () (EVar "True")) (arm (PTuple (PCon "TAuthority") (PCon "TAuthority")) () (EVar "True")) (arm (PTuple (PCon "TAuthorityBinder") (PCon "TAuthorityBinder")) () (EVar "True")) (arm (PTuple (PCon "TAuthorityDomain") (PCon "TAuthorityDomain")) () (EVar "True")) (arm (PTuple (PCon "TAuthorityEscape") (PCon "TAuthorityEscape")) () (EVar "True")) (arm (PTuple (PCon "TAuthorityExistentialScope") (PCon "TAuthorityExistentialScope")) () (EVar "True")) (arm (PTuple (PCon "TAuthorityIndexMismatch") (PCon "TAuthorityIndexMismatch")) () (EVar "True")) (arm (PTuple (PCon "TAuthorityKind") (PCon "TAuthorityKind")) () (EVar "True")) (arm (PTuple (PCon "TAuthorityPattern") (PCon "TAuthorityPattern")) () (EVar "True")) (arm (PTuple (PCon "TAuthorityPhantomExport") (PCon "TAuthorityPhantomExport")) () (EVar "True")) (arm (PTuple (PCon "TBangOnBool") (PCon "TBangOnBool")) () (EVar "True")) (arm (PTuple (PCon "TBindOutsideDo") (PCon "TBindOutsideDo")) () (EVar "True")) (arm (PTuple (PCon "TConflictingImpl") (PCon "TConflictingImpl")) () (EVar "True")) (arm (PTuple (PCon "TCyclicSuperinterface") (PCon "TCyclicSuperinterface")) () (EVar "True")) (arm (PTuple (PCon "TDiscardedValue") (PCon "TDiscardedValue")) () (EVar "True")) (arm (PTuple (PCon "TDoNotMonad") (PCon "TDoNotMonad")) () (EVar "True")) (arm (PTuple (PCon "TEffectArgUncovered") (PCon "TEffectArgUncovered")) () (EVar "True")) (arm (PTuple (PCon "TEffectIndexEager") (PCon "TEffectIndexEager")) () (EVar "True")) (arm (PTuple (PCon "TEffectIndexMismatch") (PCon "TEffectIndexMismatch")) () (EVar "True")) (arm (PTuple (PCon "TEffectKindMismatch") (PCon "TEffectKindMismatch")) () (EVar "True")) (arm (PTuple (PCon "TEffectLaunder") (PCon "TEffectLaunder")) () (EVar "True")) (arm (PTuple (PCon "TEffectLeak") (PCon "TEffectLeak")) () (EVar "True")) (arm (PTuple (PCon "TEffectParam") (PCon "TEffectParam")) () (EVar "True")) (arm (PTuple (PCon "TEffectParamVariance") (PCon "TEffectParamVariance")) () (EVar "True")) (arm (PTuple (PCon "TEffectUndetermined") (PCon "TEffectUndetermined")) () (EVar "True")) (arm (PTuple (PCon "TExportUnsolvedAuthority") (PCon "TExportUnsolvedAuthority")) () (EVar "True")) (arm (PTuple (PCon "TFfiBuiltinBind") (PCon "TFfiBuiltinBind")) () (EVar "True")) (arm (PTuple (PCon "TFfiBuiltinShadow") (PCon "TFfiBuiltinShadow")) () (EVar "True")) (arm (PTuple (PCon "TFfiCatalogNarrow") (PCon "TFfiCatalogNarrow")) () (EVar "True")) (arm (PTuple (PCon "TFfiCSymbol") (PCon "TFfiCSymbol")) () (EVar "True")) (arm (PTuple (PCon "TFfiDuplicateHost") (PCon "TFfiDuplicateHost")) () (EVar "True")) (arm (PTuple (PCon "TFfiJsName") (PCon "TFfiJsName")) () (EVar "True")) (arm (PTuple (PCon "TFfiNoHost") (PCon "TFfiNoHost")) () (EVar "True")) (arm (PTuple (PCon "TFfiNoncrossable") (PCon "TFfiNoncrossable")) () (EVar "True")) (arm (PTuple (PCon "TFfiNullary") (PCon "TFfiNullary")) () (EVar "True")) (arm (PTuple (PCon "TFfiReservedName") (PCon "TFfiReservedName")) () (EVar "True")) (arm (PTuple (PCon "TFfiUnboundHost") (PCon "TFfiUnboundHost")) () (EVar "True")) (arm (PTuple (PCon "TFfiUnknownHost") (PCon "TFfiUnknownHost")) () (EVar "True")) (arm (PTuple (PCon "TFfiUnlabelled") (PCon "TFfiUnlabelled")) () (EVar "True")) (arm (PTuple (PCon "TFieldNotInAllCtors") (PCon "TFieldNotInAllCtors")) () (EVar "True")) (arm (PTuple (PCon "TFieldPositionDiffers") (PCon "TFieldPositionDiffers")) () (EVar "True")) (arm (PTuple (PCon "TFieldTypeDiffers") (PCon "TFieldTypeDiffers")) () (EVar "True")) (arm (PTuple (PCon "TFileBoundValue") (PCon "TFileBoundValue")) () (EVar "True")) (arm (PTuple (PCon "TImplKindMismatch") (PCon "TImplKindMismatch")) () (EVar "True")) (arm (PTuple (PCon "TImplMissingRequires") (PCon "TImplMissingRequires")) () (EVar "True")) (arm (PTuple (PCon "TImplTooSpecific") (PCon "TImplTooSpecific")) () (EVar "True")) (arm (PTuple (PCon "TIncompleteImpl") (PCon "TIncompleteImpl")) () (EVar "True")) (arm (PTuple (PCon "TInfiniteType") (PCon "TInfiniteType")) () (EVar "True")) (arm (PTuple (PCon "TInternalOrdinal") (PCon "TInternalOrdinal")) () (EVar "True")) (arm (PTuple (PCon "TMainUsed") (PCon "TMainUsed")) () (EVar "True")) (arm (PTuple (PCon "TManifestEntry") (PCon "TManifestEntry")) () (EVar "True")) (arm (PTuple (PCon "TManifestInvalid") (PCon "TManifestInvalid")) () (EVar "True")) (arm (PTuple (PCon "TManifestWrapper") (PCon "TManifestWrapper")) () (EVar "True")) (arm (PTuple (PCon "TMethodMismatch") (PCon "TMethodMismatch")) () (EVar "True")) (arm (PTuple (PCon "TMissingConstraint") (PCon "TMissingConstraint")) () (EVar "True")) (arm (PTuple (PCon "TMissingField") (PCon "TMissingField")) () (EVar "True")) (arm (PTuple (PCon "TMissingSuperImpl") (PCon "TMissingSuperImpl")) () (EVar "True")) (arm (PTuple (PCon "TNoImpl") (PCon "TNoImpl")) () (EVar "True")) (arm (PTuple (PCon "TNonrecValueLet") (PCon "TNonrecValueLet")) () (EVar "True")) (arm (PTuple (PCon "TNotAFunction") (PCon "TNotAFunction")) () (EVar "True")) (arm (PTuple (PCon "TOrPatternBinderTypes") (PCon "TOrPatternBinderTypes")) () (EVar "True")) (arm (PTuple (PCon "TOrPatternTooMany") (PCon "TOrPatternTooMany")) () (EVar "True")) (arm (PTuple (PCon "TPhantomMethod") (PCon "TPhantomMethod")) () (EVar "True")) (arm (PTuple (PCon "TRecursiveAlias") (PCon "TRecursiveAlias")) () (EVar "True")) (arm (PTuple (PCon "TRequiresCycle") (PCon "TRequiresCycle")) () (EVar "True")) (arm (PTuple (PCon "TRequiresDepth") (PCon "TRequiresDepth")) () (EVar "True")) (arm (PTuple (PCon "TRequiresUnrouted") (PCon "TRequiresUnrouted")) () (EVar "True")) (arm (PTuple (PCon "TResidual") (PCon "TResidual")) () (EVar "True")) (arm (PTuple (PCon "TSigOverExpansive") (PCon "TSigOverExpansive")) () (EVar "True")) (arm (PTuple (PCon "TTargetCapability") (PCon "TTargetCapability")) () (EVar "True")) (arm (PTuple (PCon "TTargetNoBinding") (PCon "TTargetNoBinding")) () (EVar "True")) (arm (PTuple (PCon "TTargetNotProvided") (PCon "TTargetNotProvided")) () (EVar "True")) (arm (PTuple (PCon "TTypeMismatch") (PCon "TTypeMismatch")) () (EVar "True")) (arm (PTuple (PCon "TTypeTooGeneral") (PCon "TTypeTooGeneral")) () (EVar "True")) (arm (PTuple (PCon "TUnbound") (PCon "TUnbound")) () (EVar "True")) (arm (PTuple (PCon "TUnknownCtor") (PCon "TUnknownCtor")) () (EVar "True")) (arm (PTuple (PCon "TUnknownField") (PCon "TUnknownField")) () (EVar "True")) (arm (PTuple (PCon "TUnknownRecord") (PCon "TUnknownRecord")) () (EVar "True")) (arm (PTuple (PCon "TUnroutedDispatch") (PCon "TUnroutedDispatch")) () (EVar "True")) (arm (PTuple (PCon "TUpdateMultiCtor") (PCon "TUpdateMultiCtor")) () (EVar "True")) (arm (PTuple (PCon "WGuardInexhaustive") (PCon "WGuardInexhaustive")) () (EVar "True")) (arm (PTuple (PCon "WImportMethodShadow") (PCon "WImportMethodShadow")) () (EVar "True")) (arm (PTuple (PCon "WIncomparableImpls") (PCon "WIncomparableImpls")) () (EVar "True")) (arm (PTuple (PCon "WKeepIrFailed") (PCon "WKeepIrFailed")) () (EVar "True")) (arm (PTuple (PCon "WMainMissing") (PCon "WMainMissing")) () (EVar "True")) (arm (PTuple (PCon "WMainShape") (PCon "WMainShape")) () (EVar "True")) (arm (PTuple (PCon "WNonexhaustive") (PCon "WNonexhaustive")) () (EVar "True")) (arm (PTuple (PCon "WNonexhaustiveClauses") (PCon "WNonexhaustiveClauses")) () (EVar "True")) (arm (PTuple (PCon "WPreludeMethodShadow") (PCon "WPreludeMethodShadow")) () (EVar "True")) (arm (PTuple (PCon "WUnreachableAlt") (PCon "WUnreachableAlt")) () (EVar "True")) (arm (PTuple (PCon "WUnreachableArm") (PCon "WUnreachableArm")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "DiagCode")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "EAmbiguousDispatch") () (ELit (LString "EAmbiguousDispatch"))) (arm (PCon "ECyclicValue") () (ELit (LString "ECyclicValue"))) (arm (PCon "EDivZero") () (ELit (LString "EDivZero"))) (arm (PCon "EIndexOob") () (ELit (LString "EIndexOob"))) (arm (PCon "EIntOverflow") () (ELit (LString "EIntOverflow"))) (arm (PCon "ELetRefute") () (ELit (LString "ELetRefute"))) (arm (PCon "EMainAsyncPayload") () (ELit (LString "EMainAsyncPayload"))) (arm (PCon "EModZero") () (ELit (LString "EModZero"))) (arm (PCon "ENoMain") () (ELit (LString "ENoMain"))) (arm (PCon "ENonexhaustiveMatch") () (ELit (LString "ENonexhaustiveMatch"))) (arm (PCon "ENotAFunction") () (ELit (LString "ENotAFunction"))) (arm (PCon "EPanic") () (ELit (LString "EPanic"))) (arm (PCon "EPhysDuplicate") () (ELit (LString "EPhysDuplicate"))) (arm (PCon "EPhysShape") () (ELit (LString "EPhysShape"))) (arm (PCon "EPhysUndeclaredFuncref") () (ELit (LString "EPhysUndeclaredFuncref"))) (arm (PCon "EPhysUndeclaredType") () (ELit (LString "EPhysUndeclaredType"))) (arm (PCon "EPhysUndefined") () (ELit (LString "EPhysUndefined"))) (arm (PCon "ESliceOob") () (ELit (LString "ESliceOob"))) (arm (PCon "EStackOverflow") () (ELit (LString "EStackOverflow"))) (arm (PCon "EWasmNoBinding") () (ELit (LString "EWasmNoBinding"))) (arm (PCon "LBadByteLiteral") () (ELit (LString "LBadByteLiteral"))) (arm (PCon "LBadChar") () (ELit (LString "LBadChar"))) (arm (PCon "LBadCharLiteral") () (ELit (LString "LBadCharLiteral"))) (arm (PCon "LBadEscape") () (ELit (LString "LBadEscape"))) (arm (PCon "LBadUnicodeEscape") () (ELit (LString "LBadUnicodeEscape"))) (arm (PCon "LBareUnicodeEscape") () (ELit (LString "LBareUnicodeEscape"))) (arm (PCon "LBlockcomment") () (ELit (LString "LBlockcomment"))) (arm (PCon "LByteLiteralIdent") () (ELit (LString "LByteLiteralIdent"))) (arm (PCon "LByteNonAscii") () (ELit (LString "LByteNonAscii"))) (arm (PCon "LFloatOverflow") () (ELit (LString "LFloatOverflow"))) (arm (PCon "LHsDollar") () (ELit (LString "LHsDollar"))) (arm (PCon "LHsLambda") () (ELit (LString "LHsLambda"))) (arm (PCon "LIntOverflow") () (ELit (LString "LIntOverflow"))) (arm (PCon "LMalformedFloat") () (ELit (LString "LMalformedFloat"))) (arm (PCon "LMalformedRadix") () (ELit (LString "LMalformedRadix"))) (arm (PCon "LNestedInterpolation") () (ELit (LString "LNestedInterpolation"))) (arm (PCon "LSemicolon") () (ELit (LString "LSemicolon"))) (arm (PCon "LUnterminatedComment") () (ELit (LString "LUnterminatedComment"))) (arm (PCon "LUnterminatedString") () (ELit (LString "LUnterminatedString"))) (arm (PCon "PBadNeq") () (ELit (LString "PBadNeq"))) (arm (PCon "PBraceBlock") () (ELit (LString "PBraceBlock"))) (arm (PCon "PDefKeyword") () (ELit (LString "PDefKeyword"))) (arm (PCon "PDoEndsInBinding") () (ELit (LString "PDoEndsInBinding"))) (arm (PCon "PForWhile") () (ELit (LString "PForWhile"))) (arm (PCon "PGuardBarInMatch") () (ELit (LString "PGuardBarInMatch"))) (arm (PCon "PGuardIfInEquation") () (ELit (LString "PGuardIfInEquation"))) (arm (PCon "PHsCase") () (ELit (LString "PHsCase"))) (arm (PCon "PHsSig") () (ELit (LString "PHsSig"))) (arm (PCon "PMissingWhere") () (ELit (LString "PMissingWhere"))) (arm (PCon "PNoPowOperator") () (ELit (LString "PNoPowOperator"))) (arm (PCon "POcamlMatchWith") () (ELit (LString "POcamlMatchWith"))) (arm (PCon "PParse") () (ELit (LString "PParse"))) (arm (PCon "PRawStringAfterDot") () (ELit (LString "PRawStringAfterDot"))) (arm (PCon "PReservedKeyword") () (ELit (LString "PReservedKeyword"))) (arm (PCon "PUnexpectedEof") () (ELit (LString "PUnexpectedEof"))) (arm (PCon "PWhereBodySameLine") () (ELit (LString "PWhereBodySameLine"))) (arm (PCon "RAbstractCtorImport") () (ELit (LString "RAbstractCtorImport"))) (arm (PCon "RAbstractField") () (ELit (LString "RAbstractField"))) (arm (PCon "RAmbiguousCtor") () (ELit (LString "RAmbiguousCtor"))) (arm (PCon "RAmbiguousEffect") () (ELit (LString "RAmbiguousEffect"))) (arm (PCon "RAmbiguousInterface") () (ELit (LString "RAmbiguousInterface"))) (arm (PCon "RAmbiguousOccurrence") () (ELit (LString "RAmbiguousOccurrence"))) (arm (PCon "RAmbiguousType") () (ELit (LString "RAmbiguousType"))) (arm (PCon "RAsPatternMisplaced") () (ELit (LString "RAsPatternMisplaced"))) (arm (PCon "RBareCtorImport") () (ELit (LString "RBareCtorImport"))) (arm (PCon "RBuildFailed") () (ELit (LString "RBuildFailed"))) (arm (PCon "RCannotDerive") () (ELit (LString "RCannotDerive"))) (arm (PCon "RDupBinder") () (ELit (LString "RDupBinder"))) (arm (PCon "RDupBinding") () (ELit (LString "RDupBinding"))) (arm (PCon "RDuplicateBinding") () (ELit (LString "RDuplicateBinding"))) (arm (PCon "RDuplicateDef") () (ELit (LString "RDuplicateDef"))) (arm (PCon "RDuplicateIfaceMethod") () (ELit (LString "RDuplicateIfaceMethod"))) (arm (PCon "RDuplicateSignature") () (ELit (LString "RDuplicateSignature"))) (arm (PCon "REffectLabelNoMembers") () (ELit (LString "REffectLabelNoMembers"))) (arm (PCon "RExternWithBody") () (ELit (LString "RExternWithBody"))) (arm (PCon "RFieldNotInRecord") () (ELit (LString "RFieldNotInRecord"))) (arm (PCon "RFileNotFound") () (ELit (LString "RFileNotFound"))) (arm (PCon "RFileNotUtf8") () (ELit (LString "RFileNotUtf8"))) (arm (PCon "RImmutableAssign") () (ELit (LString "RImmutableAssign"))) (arm (PCon "RInternalExtern") () (ELit (LString "RInternalExtern"))) (arm (PCon "RMethodNotInInterface") () (ELit (LString "RMethodNotInInterface"))) (arm (PCon "RMisplacedAuthorityBinder") () (ELit (LString "RMisplacedAuthorityBinder"))) (arm (PCon "RModuleLoad") () (ELit (LString "RModuleLoad"))) (arm (PCon "RNewtypeCtorPrivate") () (ELit (LString "RNewtypeCtorPrivate"))) (arm (PCon "RNoExportedCtors") () (ELit (LString "RNoExportedCtors"))) (arm (PCon "RNonrecValueLet") () (ELit (LString "RNonrecValueLet"))) (arm (PCon "ROrPatternBinders") () (ELit (LString "ROrPatternBinders"))) (arm (PCon "ROrPatternMisplaced") () (ELit (LString "ROrPatternMisplaced"))) (arm (PCon "ROrphanSignature") () (ELit (LString "ROrphanSignature"))) (arm (PCon "RPrivateName") () (ELit (LString "RPrivateName"))) (arm (PCon "RUnbound") () (ELit (LString "RUnbound"))) (arm (PCon "RUnboundAuthority") () (ELit (LString "RUnboundAuthority"))) (arm (PCon "RUnknownCtor") () (ELit (LString "RUnknownCtor"))) (arm (PCon "RUnknownEffect") () (ELit (LString "RUnknownEffect"))) (arm (PCon "RUnknownField") () (ELit (LString "RUnknownField"))) (arm (PCon "RUnknownInterface") () (ELit (LString "RUnknownInterface"))) (arm (PCon "RUnknownModule") () (ELit (LString "RUnknownModule"))) (arm (PCon "RUnknownType") () (ELit (LString "RUnknownType"))) (arm (PCon "TAbstractField") () (ELit (LString "TAbstractField"))) (arm (PCon "TAliasArity") () (ELit (LString "TAliasArity"))) (arm (PCon "TAmbiguousAliasMethod") () (ELit (LString "TAmbiguousAliasMethod"))) (arm (PCon "TAmbiguousField") () (ELit (LString "TAmbiguousField"))) (arm (PCon "TAmbiguousInstance") () (ELit (LString "TAmbiguousInstance"))) (arm (PCon "TAmbiguousMethod") () (ELit (LString "TAmbiguousMethod"))) (arm (PCon "TAmbiguousReexport") () (ELit (LString "TAmbiguousReexport"))) (arm (PCon "TAmbiguousShadowDecl") () (ELit (LString "TAmbiguousShadowDecl"))) (arm (PCon "TAuthority") () (ELit (LString "TAuthority"))) (arm (PCon "TAuthorityBinder") () (ELit (LString "TAuthorityBinder"))) (arm (PCon "TAuthorityDomain") () (ELit (LString "TAuthorityDomain"))) (arm (PCon "TAuthorityEscape") () (ELit (LString "TAuthorityEscape"))) (arm (PCon "TAuthorityExistentialScope") () (ELit (LString "TAuthorityExistentialScope"))) (arm (PCon "TAuthorityIndexMismatch") () (ELit (LString "TAuthorityIndexMismatch"))) (arm (PCon "TAuthorityKind") () (ELit (LString "TAuthorityKind"))) (arm (PCon "TAuthorityPattern") () (ELit (LString "TAuthorityPattern"))) (arm (PCon "TAuthorityPhantomExport") () (ELit (LString "TAuthorityPhantomExport"))) (arm (PCon "TBangOnBool") () (ELit (LString "TBangOnBool"))) (arm (PCon "TBindOutsideDo") () (ELit (LString "TBindOutsideDo"))) (arm (PCon "TConflictingImpl") () (ELit (LString "TConflictingImpl"))) (arm (PCon "TCyclicSuperinterface") () (ELit (LString "TCyclicSuperinterface"))) (arm (PCon "TDiscardedValue") () (ELit (LString "TDiscardedValue"))) (arm (PCon "TDoNotMonad") () (ELit (LString "TDoNotMonad"))) (arm (PCon "TEffectArgUncovered") () (ELit (LString "TEffectArgUncovered"))) (arm (PCon "TEffectIndexEager") () (ELit (LString "TEffectIndexEager"))) (arm (PCon "TEffectIndexMismatch") () (ELit (LString "TEffectIndexMismatch"))) (arm (PCon "TEffectKindMismatch") () (ELit (LString "TEffectKindMismatch"))) (arm (PCon "TEffectLaunder") () (ELit (LString "TEffectLaunder"))) (arm (PCon "TEffectLeak") () (ELit (LString "TEffectLeak"))) (arm (PCon "TEffectParam") () (ELit (LString "TEffectParam"))) (arm (PCon "TEffectParamVariance") () (ELit (LString "TEffectParamVariance"))) (arm (PCon "TEffectUndetermined") () (ELit (LString "TEffectUndetermined"))) (arm (PCon "TExportUnsolvedAuthority") () (ELit (LString "TExportUnsolvedAuthority"))) (arm (PCon "TFfiBuiltinBind") () (ELit (LString "TFfiBuiltinBind"))) (arm (PCon "TFfiBuiltinShadow") () (ELit (LString "TFfiBuiltinShadow"))) (arm (PCon "TFfiCatalogNarrow") () (ELit (LString "TFfiCatalogNarrow"))) (arm (PCon "TFfiCSymbol") () (ELit (LString "TFfiCSymbol"))) (arm (PCon "TFfiDuplicateHost") () (ELit (LString "TFfiDuplicateHost"))) (arm (PCon "TFfiJsName") () (ELit (LString "TFfiJsName"))) (arm (PCon "TFfiNoHost") () (ELit (LString "TFfiNoHost"))) (arm (PCon "TFfiNoncrossable") () (ELit (LString "TFfiNoncrossable"))) (arm (PCon "TFfiNullary") () (ELit (LString "TFfiNullary"))) (arm (PCon "TFfiReservedName") () (ELit (LString "TFfiReservedName"))) (arm (PCon "TFfiUnboundHost") () (ELit (LString "TFfiUnboundHost"))) (arm (PCon "TFfiUnknownHost") () (ELit (LString "TFfiUnknownHost"))) (arm (PCon "TFfiUnlabelled") () (ELit (LString "TFfiUnlabelled"))) (arm (PCon "TFieldNotInAllCtors") () (ELit (LString "TFieldNotInAllCtors"))) (arm (PCon "TFieldPositionDiffers") () (ELit (LString "TFieldPositionDiffers"))) (arm (PCon "TFieldTypeDiffers") () (ELit (LString "TFieldTypeDiffers"))) (arm (PCon "TFileBoundValue") () (ELit (LString "TFileBoundValue"))) (arm (PCon "TImplKindMismatch") () (ELit (LString "TImplKindMismatch"))) (arm (PCon "TImplMissingRequires") () (ELit (LString "TImplMissingRequires"))) (arm (PCon "TImplTooSpecific") () (ELit (LString "TImplTooSpecific"))) (arm (PCon "TIncompleteImpl") () (ELit (LString "TIncompleteImpl"))) (arm (PCon "TInfiniteType") () (ELit (LString "TInfiniteType"))) (arm (PCon "TInternalOrdinal") () (ELit (LString "TInternalOrdinal"))) (arm (PCon "TMainUsed") () (ELit (LString "TMainUsed"))) (arm (PCon "TManifestEntry") () (ELit (LString "TManifestEntry"))) (arm (PCon "TManifestInvalid") () (ELit (LString "TManifestInvalid"))) (arm (PCon "TManifestWrapper") () (ELit (LString "TManifestWrapper"))) (arm (PCon "TMethodMismatch") () (ELit (LString "TMethodMismatch"))) (arm (PCon "TMissingConstraint") () (ELit (LString "TMissingConstraint"))) (arm (PCon "TMissingField") () (ELit (LString "TMissingField"))) (arm (PCon "TMissingSuperImpl") () (ELit (LString "TMissingSuperImpl"))) (arm (PCon "TNoImpl") () (ELit (LString "TNoImpl"))) (arm (PCon "TNonrecValueLet") () (ELit (LString "TNonrecValueLet"))) (arm (PCon "TNotAFunction") () (ELit (LString "TNotAFunction"))) (arm (PCon "TOrPatternBinderTypes") () (ELit (LString "TOrPatternBinderTypes"))) (arm (PCon "TOrPatternTooMany") () (ELit (LString "TOrPatternTooMany"))) (arm (PCon "TPhantomMethod") () (ELit (LString "TPhantomMethod"))) (arm (PCon "TRecursiveAlias") () (ELit (LString "TRecursiveAlias"))) (arm (PCon "TRequiresCycle") () (ELit (LString "TRequiresCycle"))) (arm (PCon "TRequiresDepth") () (ELit (LString "TRequiresDepth"))) (arm (PCon "TRequiresUnrouted") () (ELit (LString "TRequiresUnrouted"))) (arm (PCon "TResidual") () (ELit (LString "TResidual"))) (arm (PCon "TSigOverExpansive") () (ELit (LString "TSigOverExpansive"))) (arm (PCon "TTargetCapability") () (ELit (LString "TTargetCapability"))) (arm (PCon "TTargetNoBinding") () (ELit (LString "TTargetNoBinding"))) (arm (PCon "TTargetNotProvided") () (ELit (LString "TTargetNotProvided"))) (arm (PCon "TTypeMismatch") () (ELit (LString "TTypeMismatch"))) (arm (PCon "TTypeTooGeneral") () (ELit (LString "TTypeTooGeneral"))) (arm (PCon "TUnbound") () (ELit (LString "TUnbound"))) (arm (PCon "TUnknownCtor") () (ELit (LString "TUnknownCtor"))) (arm (PCon "TUnknownField") () (ELit (LString "TUnknownField"))) (arm (PCon "TUnknownRecord") () (ELit (LString "TUnknownRecord"))) (arm (PCon "TUnroutedDispatch") () (ELit (LString "TUnroutedDispatch"))) (arm (PCon "TUpdateMultiCtor") () (ELit (LString "TUpdateMultiCtor"))) (arm (PCon "WGuardInexhaustive") () (ELit (LString "WGuardInexhaustive"))) (arm (PCon "WImportMethodShadow") () (ELit (LString "WImportMethodShadow"))) (arm (PCon "WIncomparableImpls") () (ELit (LString "WIncomparableImpls"))) (arm (PCon "WKeepIrFailed") () (ELit (LString "WKeepIrFailed"))) (arm (PCon "WMainMissing") () (ELit (LString "WMainMissing"))) (arm (PCon "WMainShape") () (ELit (LString "WMainShape"))) (arm (PCon "WNonexhaustive") () (ELit (LString "WNonexhaustive"))) (arm (PCon "WNonexhaustiveClauses") () (ELit (LString "WNonexhaustiveClauses"))) (arm (PCon "WPreludeMethodShadow") () (ELit (LString "WPreludeMethodShadow"))) (arm (PCon "WUnreachableAlt") () (ELit (LString "WUnreachableAlt"))) (arm (PCon "WUnreachableArm") () (ELit (LString "WUnreachableArm")))))))
(DTypeSig true "codeText" (TyFun (TyCon "DiagCode") (TyCon "String")))
(DFunDef false "codeText" ((PCon "EAmbiguousDispatch")) (ELit (LString "E-AMBIGUOUS-DISPATCH")))
(DFunDef false "codeText" ((PCon "ECyclicValue")) (ELit (LString "E-CYCLIC-VALUE")))
(DFunDef false "codeText" ((PCon "EDivZero")) (ELit (LString "E-DIV-ZERO")))
(DFunDef false "codeText" ((PCon "EIndexOob")) (ELit (LString "E-INDEX-OOB")))
(DFunDef false "codeText" ((PCon "EIntOverflow")) (ELit (LString "E-INT-OVERFLOW")))
(DFunDef false "codeText" ((PCon "ELetRefute")) (ELit (LString "E-LET-REFUTE")))
(DFunDef false "codeText" ((PCon "EMainAsyncPayload")) (ELit (LString "E-MAIN-ASYNC-PAYLOAD")))
(DFunDef false "codeText" ((PCon "EModZero")) (ELit (LString "E-MOD-ZERO")))
(DFunDef false "codeText" ((PCon "ENoMain")) (ELit (LString "E-NO-MAIN")))
(DFunDef false "codeText" ((PCon "ENonexhaustiveMatch")) (ELit (LString "E-NONEXHAUSTIVE-MATCH")))
(DFunDef false "codeText" ((PCon "ENotAFunction")) (ELit (LString "E-NOT-A-FUNCTION")))
(DFunDef false "codeText" ((PCon "EPanic")) (ELit (LString "E-PANIC")))
(DFunDef false "codeText" ((PCon "EPhysDuplicate")) (ELit (LString "E-PHYS-DUPLICATE")))
(DFunDef false "codeText" ((PCon "EPhysShape")) (ELit (LString "E-PHYS-SHAPE")))
(DFunDef false "codeText" ((PCon "EPhysUndeclaredFuncref")) (ELit (LString "E-PHYS-UNDECLARED-FUNCREF")))
(DFunDef false "codeText" ((PCon "EPhysUndeclaredType")) (ELit (LString "E-PHYS-UNDECLARED-TYPE")))
(DFunDef false "codeText" ((PCon "EPhysUndefined")) (ELit (LString "E-PHYS-UNDEFINED")))
(DFunDef false "codeText" ((PCon "ESliceOob")) (ELit (LString "E-SLICE-OOB")))
(DFunDef false "codeText" ((PCon "EStackOverflow")) (ELit (LString "E-STACK-OVERFLOW")))
(DFunDef false "codeText" ((PCon "EWasmNoBinding")) (ELit (LString "E-WASM-NO-BINDING")))
(DFunDef false "codeText" ((PCon "LBadByteLiteral")) (ELit (LString "L-BAD-BYTE-LITERAL")))
(DFunDef false "codeText" ((PCon "LBadChar")) (ELit (LString "L-BAD-CHAR")))
(DFunDef false "codeText" ((PCon "LBadCharLiteral")) (ELit (LString "L-BAD-CHAR-LITERAL")))
(DFunDef false "codeText" ((PCon "LBadEscape")) (ELit (LString "L-BAD-ESCAPE")))
(DFunDef false "codeText" ((PCon "LBadUnicodeEscape")) (ELit (LString "L-BAD-UNICODE-ESCAPE")))
(DFunDef false "codeText" ((PCon "LBareUnicodeEscape")) (ELit (LString "L-BARE-UNICODE-ESCAPE")))
(DFunDef false "codeText" ((PCon "LBlockcomment")) (ELit (LString "L-BLOCKCOMMENT")))
(DFunDef false "codeText" ((PCon "LByteLiteralIdent")) (ELit (LString "L-BYTE-LITERAL-IDENT")))
(DFunDef false "codeText" ((PCon "LByteNonAscii")) (ELit (LString "L-BYTE-NON-ASCII")))
(DFunDef false "codeText" ((PCon "LFloatOverflow")) (ELit (LString "L-FLOAT-OVERFLOW")))
(DFunDef false "codeText" ((PCon "LHsDollar")) (ELit (LString "L-HS-DOLLAR")))
(DFunDef false "codeText" ((PCon "LHsLambda")) (ELit (LString "L-HS-LAMBDA")))
(DFunDef false "codeText" ((PCon "LIntOverflow")) (ELit (LString "L-INT-OVERFLOW")))
(DFunDef false "codeText" ((PCon "LMalformedFloat")) (ELit (LString "L-MALFORMED-FLOAT")))
(DFunDef false "codeText" ((PCon "LMalformedRadix")) (ELit (LString "L-MALFORMED-RADIX")))
(DFunDef false "codeText" ((PCon "LNestedInterpolation")) (ELit (LString "L-NESTED-INTERPOLATION")))
(DFunDef false "codeText" ((PCon "LSemicolon")) (ELit (LString "L-SEMICOLON")))
(DFunDef false "codeText" ((PCon "LUnterminatedComment")) (ELit (LString "L-UNTERMINATED-COMMENT")))
(DFunDef false "codeText" ((PCon "LUnterminatedString")) (ELit (LString "L-UNTERMINATED-STRING")))
(DFunDef false "codeText" ((PCon "PBadNeq")) (ELit (LString "P-BAD-NEQ")))
(DFunDef false "codeText" ((PCon "PBraceBlock")) (ELit (LString "P-BRACE-BLOCK")))
(DFunDef false "codeText" ((PCon "PDefKeyword")) (ELit (LString "P-DEF-KEYWORD")))
(DFunDef false "codeText" ((PCon "PDoEndsInBinding")) (ELit (LString "P-DO-ENDS-IN-BINDING")))
(DFunDef false "codeText" ((PCon "PForWhile")) (ELit (LString "P-FOR-WHILE")))
(DFunDef false "codeText" ((PCon "PGuardBarInMatch")) (ELit (LString "P-GUARD-BAR-IN-MATCH")))
(DFunDef false "codeText" ((PCon "PGuardIfInEquation")) (ELit (LString "P-GUARD-IF-IN-EQUATION")))
(DFunDef false "codeText" ((PCon "PHsCase")) (ELit (LString "P-HS-CASE")))
(DFunDef false "codeText" ((PCon "PHsSig")) (ELit (LString "P-HS-SIG")))
(DFunDef false "codeText" ((PCon "PMissingWhere")) (ELit (LString "P-MISSING-WHERE")))
(DFunDef false "codeText" ((PCon "PNoPowOperator")) (ELit (LString "P-NO-POW-OPERATOR")))
(DFunDef false "codeText" ((PCon "POcamlMatchWith")) (ELit (LString "P-OCAML-MATCH-WITH")))
(DFunDef false "codeText" ((PCon "PParse")) (ELit (LString "P-PARSE")))
(DFunDef false "codeText" ((PCon "PRawStringAfterDot")) (ELit (LString "P-RAW-STRING-AFTER-DOT")))
(DFunDef false "codeText" ((PCon "PReservedKeyword")) (ELit (LString "P-RESERVED-KEYWORD")))
(DFunDef false "codeText" ((PCon "PUnexpectedEof")) (ELit (LString "P-UNEXPECTED-EOF")))
(DFunDef false "codeText" ((PCon "PWhereBodySameLine")) (ELit (LString "P-WHERE-BODY-SAME-LINE")))
(DFunDef false "codeText" ((PCon "RAbstractCtorImport")) (ELit (LString "R-ABSTRACT-CTOR-IMPORT")))
(DFunDef false "codeText" ((PCon "RAbstractField")) (ELit (LString "R-ABSTRACT-FIELD")))
(DFunDef false "codeText" ((PCon "RAmbiguousCtor")) (ELit (LString "R-AMBIGUOUS-CTOR")))
(DFunDef false "codeText" ((PCon "RAmbiguousEffect")) (ELit (LString "R-AMBIGUOUS-EFFECT")))
(DFunDef false "codeText" ((PCon "RAmbiguousInterface")) (ELit (LString "R-AMBIGUOUS-INTERFACE")))
(DFunDef false "codeText" ((PCon "RAmbiguousOccurrence")) (ELit (LString "R-AMBIGUOUS-OCCURRENCE")))
(DFunDef false "codeText" ((PCon "RAmbiguousType")) (ELit (LString "R-AMBIGUOUS-TYPE")))
(DFunDef false "codeText" ((PCon "RAsPatternMisplaced")) (ELit (LString "R-AS-PATTERN-MISPLACED")))
(DFunDef false "codeText" ((PCon "RBareCtorImport")) (ELit (LString "R-BARE-CTOR-IMPORT")))
(DFunDef false "codeText" ((PCon "RBuildFailed")) (ELit (LString "R-BUILD-FAILED")))
(DFunDef false "codeText" ((PCon "RCannotDerive")) (ELit (LString "R-CANNOT-DERIVE")))
(DFunDef false "codeText" ((PCon "RDupBinder")) (ELit (LString "R-DUP-BINDER")))
(DFunDef false "codeText" ((PCon "RDupBinding")) (ELit (LString "R-DUP-BINDING")))
(DFunDef false "codeText" ((PCon "RDuplicateBinding")) (ELit (LString "R-DUPLICATE-BINDING")))
(DFunDef false "codeText" ((PCon "RDuplicateDef")) (ELit (LString "R-DUPLICATE-DEF")))
(DFunDef false "codeText" ((PCon "RDuplicateIfaceMethod")) (ELit (LString "R-DUPLICATE-IFACE-METHOD")))
(DFunDef false "codeText" ((PCon "RDuplicateSignature")) (ELit (LString "R-DUPLICATE-SIGNATURE")))
(DFunDef false "codeText" ((PCon "REffectLabelNoMembers")) (ELit (LString "R-EFFECT-LABEL-NO-MEMBERS")))
(DFunDef false "codeText" ((PCon "RExternWithBody")) (ELit (LString "R-EXTERN-WITH-BODY")))
(DFunDef false "codeText" ((PCon "RFieldNotInRecord")) (ELit (LString "R-FIELD-NOT-IN-RECORD")))
(DFunDef false "codeText" ((PCon "RFileNotFound")) (ELit (LString "R-FILE-NOT-FOUND")))
(DFunDef false "codeText" ((PCon "RFileNotUtf8")) (ELit (LString "R-FILE-NOT-UTF8")))
(DFunDef false "codeText" ((PCon "RImmutableAssign")) (ELit (LString "R-IMMUTABLE-ASSIGN")))
(DFunDef false "codeText" ((PCon "RInternalExtern")) (ELit (LString "R-INTERNAL-EXTERN")))
(DFunDef false "codeText" ((PCon "RMethodNotInInterface")) (ELit (LString "R-METHOD-NOT-IN-INTERFACE")))
(DFunDef false "codeText" ((PCon "RMisplacedAuthorityBinder")) (ELit (LString "R-MISPLACED-AUTHORITY-BINDER")))
(DFunDef false "codeText" ((PCon "RModuleLoad")) (ELit (LString "R-MODULE-LOAD")))
(DFunDef false "codeText" ((PCon "RNewtypeCtorPrivate")) (ELit (LString "R-NEWTYPE-CTOR-PRIVATE")))
(DFunDef false "codeText" ((PCon "RNoExportedCtors")) (ELit (LString "R-NO-EXPORTED-CTORS")))
(DFunDef false "codeText" ((PCon "RNonrecValueLet")) (ELit (LString "R-NONREC-VALUE-LET")))
(DFunDef false "codeText" ((PCon "ROrPatternBinders")) (ELit (LString "R-OR-PATTERN-BINDERS")))
(DFunDef false "codeText" ((PCon "ROrPatternMisplaced")) (ELit (LString "R-OR-PATTERN-MISPLACED")))
(DFunDef false "codeText" ((PCon "ROrphanSignature")) (ELit (LString "R-ORPHAN-SIGNATURE")))
(DFunDef false "codeText" ((PCon "RPrivateName")) (ELit (LString "R-PRIVATE-NAME")))
(DFunDef false "codeText" ((PCon "RUnbound")) (ELit (LString "R-UNBOUND")))
(DFunDef false "codeText" ((PCon "RUnboundAuthority")) (ELit (LString "R-UNBOUND-AUTHORITY")))
(DFunDef false "codeText" ((PCon "RUnknownCtor")) (ELit (LString "R-UNKNOWN-CTOR")))
(DFunDef false "codeText" ((PCon "RUnknownEffect")) (ELit (LString "R-UNKNOWN-EFFECT")))
(DFunDef false "codeText" ((PCon "RUnknownField")) (ELit (LString "R-UNKNOWN-FIELD")))
(DFunDef false "codeText" ((PCon "RUnknownInterface")) (ELit (LString "R-UNKNOWN-INTERFACE")))
(DFunDef false "codeText" ((PCon "RUnknownModule")) (ELit (LString "R-UNKNOWN-MODULE")))
(DFunDef false "codeText" ((PCon "RUnknownType")) (ELit (LString "R-UNKNOWN-TYPE")))
(DFunDef false "codeText" ((PCon "TAbstractField")) (ELit (LString "T-ABSTRACT-FIELD")))
(DFunDef false "codeText" ((PCon "TAliasArity")) (ELit (LString "T-ALIAS-ARITY")))
(DFunDef false "codeText" ((PCon "TAmbiguousAliasMethod")) (ELit (LString "T-AMBIGUOUS-ALIAS-METHOD")))
(DFunDef false "codeText" ((PCon "TAmbiguousField")) (ELit (LString "T-AMBIGUOUS-FIELD")))
(DFunDef false "codeText" ((PCon "TAmbiguousInstance")) (ELit (LString "T-AMBIGUOUS-INSTANCE")))
(DFunDef false "codeText" ((PCon "TAmbiguousMethod")) (ELit (LString "T-AMBIGUOUS-METHOD")))
(DFunDef false "codeText" ((PCon "TAmbiguousReexport")) (ELit (LString "T-AMBIGUOUS-REEXPORT")))
(DFunDef false "codeText" ((PCon "TAmbiguousShadowDecl")) (ELit (LString "T-AMBIGUOUS-SHADOW-DECL")))
(DFunDef false "codeText" ((PCon "TAuthority")) (ELit (LString "T-AUTHORITY")))
(DFunDef false "codeText" ((PCon "TAuthorityBinder")) (ELit (LString "T-AUTHORITY-BINDER")))
(DFunDef false "codeText" ((PCon "TAuthorityDomain")) (ELit (LString "T-AUTHORITY-DOMAIN")))
(DFunDef false "codeText" ((PCon "TAuthorityEscape")) (ELit (LString "T-AUTHORITY-ESCAPE")))
(DFunDef false "codeText" ((PCon "TAuthorityExistentialScope")) (ELit (LString "T-AUTHORITY-EXISTENTIAL-SCOPE")))
(DFunDef false "codeText" ((PCon "TAuthorityIndexMismatch")) (ELit (LString "T-AUTHORITY-INDEX-MISMATCH")))
(DFunDef false "codeText" ((PCon "TAuthorityKind")) (ELit (LString "T-AUTHORITY-KIND")))
(DFunDef false "codeText" ((PCon "TAuthorityPattern")) (ELit (LString "T-AUTHORITY-PATTERN")))
(DFunDef false "codeText" ((PCon "TAuthorityPhantomExport")) (ELit (LString "T-AUTHORITY-PHANTOM-EXPORT")))
(DFunDef false "codeText" ((PCon "TBangOnBool")) (ELit (LString "T-BANG-ON-BOOL")))
(DFunDef false "codeText" ((PCon "TBindOutsideDo")) (ELit (LString "T-BIND-OUTSIDE-DO")))
(DFunDef false "codeText" ((PCon "TConflictingImpl")) (ELit (LString "T-CONFLICTING-IMPL")))
(DFunDef false "codeText" ((PCon "TCyclicSuperinterface")) (ELit (LString "T-CYCLIC-SUPERINTERFACE")))
(DFunDef false "codeText" ((PCon "TDiscardedValue")) (ELit (LString "T-DISCARDED-VALUE")))
(DFunDef false "codeText" ((PCon "TDoNotMonad")) (ELit (LString "T-DO-NOT-MONAD")))
(DFunDef false "codeText" ((PCon "TEffectArgUncovered")) (ELit (LString "T-EFFECT-ARG-UNCOVERED")))
(DFunDef false "codeText" ((PCon "TEffectIndexEager")) (ELit (LString "T-EFFECT-INDEX-EAGER")))
(DFunDef false "codeText" ((PCon "TEffectIndexMismatch")) (ELit (LString "T-EFFECT-INDEX-MISMATCH")))
(DFunDef false "codeText" ((PCon "TEffectKindMismatch")) (ELit (LString "T-EFFECT-KIND-MISMATCH")))
(DFunDef false "codeText" ((PCon "TEffectLaunder")) (ELit (LString "T-EFFECT-LAUNDER")))
(DFunDef false "codeText" ((PCon "TEffectLeak")) (ELit (LString "T-EFFECT-LEAK")))
(DFunDef false "codeText" ((PCon "TEffectParam")) (ELit (LString "T-EFFECT-PARAM")))
(DFunDef false "codeText" ((PCon "TEffectParamVariance")) (ELit (LString "T-EFFECT-PARAM-VARIANCE")))
(DFunDef false "codeText" ((PCon "TEffectUndetermined")) (ELit (LString "T-EFFECT-UNDETERMINED")))
(DFunDef false "codeText" ((PCon "TExportUnsolvedAuthority")) (ELit (LString "T-EXPORT-UNSOLVED-AUTHORITY")))
(DFunDef false "codeText" ((PCon "TFfiBuiltinBind")) (ELit (LString "T-FFI-BUILTIN-BIND")))
(DFunDef false "codeText" ((PCon "TFfiBuiltinShadow")) (ELit (LString "T-FFI-BUILTIN-SHADOW")))
(DFunDef false "codeText" ((PCon "TFfiCatalogNarrow")) (ELit (LString "T-FFI-CATALOG-NARROW")))
(DFunDef false "codeText" ((PCon "TFfiCSymbol")) (ELit (LString "T-FFI-C-SYMBOL")))
(DFunDef false "codeText" ((PCon "TFfiDuplicateHost")) (ELit (LString "T-FFI-DUPLICATE-HOST")))
(DFunDef false "codeText" ((PCon "TFfiJsName")) (ELit (LString "T-FFI-JS-NAME")))
(DFunDef false "codeText" ((PCon "TFfiNoHost")) (ELit (LString "T-FFI-NO-HOST")))
(DFunDef false "codeText" ((PCon "TFfiNoncrossable")) (ELit (LString "T-FFI-NONCROSSABLE")))
(DFunDef false "codeText" ((PCon "TFfiNullary")) (ELit (LString "T-FFI-NULLARY")))
(DFunDef false "codeText" ((PCon "TFfiReservedName")) (ELit (LString "T-FFI-RESERVED-NAME")))
(DFunDef false "codeText" ((PCon "TFfiUnboundHost")) (ELit (LString "T-FFI-UNBOUND-HOST")))
(DFunDef false "codeText" ((PCon "TFfiUnknownHost")) (ELit (LString "T-FFI-UNKNOWN-HOST")))
(DFunDef false "codeText" ((PCon "TFfiUnlabelled")) (ELit (LString "T-FFI-UNLABELLED")))
(DFunDef false "codeText" ((PCon "TFieldNotInAllCtors")) (ELit (LString "T-FIELD-NOT-IN-ALL-CTORS")))
(DFunDef false "codeText" ((PCon "TFieldPositionDiffers")) (ELit (LString "T-FIELD-POSITION-DIFFERS")))
(DFunDef false "codeText" ((PCon "TFieldTypeDiffers")) (ELit (LString "T-FIELD-TYPE-DIFFERS")))
(DFunDef false "codeText" ((PCon "TFileBoundValue")) (ELit (LString "T-FILE-BOUND-VALUE")))
(DFunDef false "codeText" ((PCon "TImplKindMismatch")) (ELit (LString "T-IMPL-KIND-MISMATCH")))
(DFunDef false "codeText" ((PCon "TImplMissingRequires")) (ELit (LString "T-IMPL-MISSING-REQUIRES")))
(DFunDef false "codeText" ((PCon "TImplTooSpecific")) (ELit (LString "T-IMPL-TOO-SPECIFIC")))
(DFunDef false "codeText" ((PCon "TIncompleteImpl")) (ELit (LString "T-INCOMPLETE-IMPL")))
(DFunDef false "codeText" ((PCon "TInfiniteType")) (ELit (LString "T-INFINITE-TYPE")))
(DFunDef false "codeText" ((PCon "TInternalOrdinal")) (ELit (LString "T-INTERNAL-ORDINAL")))
(DFunDef false "codeText" ((PCon "TMainUsed")) (ELit (LString "T-MAIN-USED")))
(DFunDef false "codeText" ((PCon "TManifestEntry")) (ELit (LString "T-MANIFEST-ENTRY")))
(DFunDef false "codeText" ((PCon "TManifestInvalid")) (ELit (LString "T-MANIFEST-INVALID")))
(DFunDef false "codeText" ((PCon "TManifestWrapper")) (ELit (LString "T-MANIFEST-WRAPPER")))
(DFunDef false "codeText" ((PCon "TMethodMismatch")) (ELit (LString "T-METHOD-MISMATCH")))
(DFunDef false "codeText" ((PCon "TMissingConstraint")) (ELit (LString "T-MISSING-CONSTRAINT")))
(DFunDef false "codeText" ((PCon "TMissingField")) (ELit (LString "T-MISSING-FIELD")))
(DFunDef false "codeText" ((PCon "TMissingSuperImpl")) (ELit (LString "T-MISSING-SUPER-IMPL")))
(DFunDef false "codeText" ((PCon "TNoImpl")) (ELit (LString "T-NO-IMPL")))
(DFunDef false "codeText" ((PCon "TNonrecValueLet")) (ELit (LString "T-NONREC-VALUE-LET")))
(DFunDef false "codeText" ((PCon "TNotAFunction")) (ELit (LString "T-NOT-A-FUNCTION")))
(DFunDef false "codeText" ((PCon "TOrPatternBinderTypes")) (ELit (LString "T-OR-PATTERN-BINDER-TYPES")))
(DFunDef false "codeText" ((PCon "TOrPatternTooMany")) (ELit (LString "T-OR-PATTERN-TOO-MANY")))
(DFunDef false "codeText" ((PCon "TPhantomMethod")) (ELit (LString "T-PHANTOM-METHOD")))
(DFunDef false "codeText" ((PCon "TRecursiveAlias")) (ELit (LString "T-RECURSIVE-ALIAS")))
(DFunDef false "codeText" ((PCon "TRequiresCycle")) (ELit (LString "T-REQUIRES-CYCLE")))
(DFunDef false "codeText" ((PCon "TRequiresDepth")) (ELit (LString "T-REQUIRES-DEPTH")))
(DFunDef false "codeText" ((PCon "TRequiresUnrouted")) (ELit (LString "T-REQUIRES-UNROUTED")))
(DFunDef false "codeText" ((PCon "TResidual")) (ELit (LString "T-RESIDUAL")))
(DFunDef false "codeText" ((PCon "TSigOverExpansive")) (ELit (LString "T-SIG-OVER-EXPANSIVE")))
(DFunDef false "codeText" ((PCon "TTargetCapability")) (ELit (LString "T-TARGET-CAPABILITY")))
(DFunDef false "codeText" ((PCon "TTargetNoBinding")) (ELit (LString "T-TARGET-NO-BINDING")))
(DFunDef false "codeText" ((PCon "TTargetNotProvided")) (ELit (LString "T-TARGET-NOT-PROVIDED")))
(DFunDef false "codeText" ((PCon "TTypeMismatch")) (ELit (LString "T-TYPE-MISMATCH")))
(DFunDef false "codeText" ((PCon "TTypeTooGeneral")) (ELit (LString "T-TYPE-TOO-GENERAL")))
(DFunDef false "codeText" ((PCon "TUnbound")) (ELit (LString "T-UNBOUND")))
(DFunDef false "codeText" ((PCon "TUnknownCtor")) (ELit (LString "T-UNKNOWN-CTOR")))
(DFunDef false "codeText" ((PCon "TUnknownField")) (ELit (LString "T-UNKNOWN-FIELD")))
(DFunDef false "codeText" ((PCon "TUnknownRecord")) (ELit (LString "T-UNKNOWN-RECORD")))
(DFunDef false "codeText" ((PCon "TUnroutedDispatch")) (ELit (LString "T-UNROUTED-DISPATCH")))
(DFunDef false "codeText" ((PCon "TUpdateMultiCtor")) (ELit (LString "T-UPDATE-MULTI-CTOR")))
(DFunDef false "codeText" ((PCon "WGuardInexhaustive")) (ELit (LString "W-GUARD-INEXHAUSTIVE")))
(DFunDef false "codeText" ((PCon "WImportMethodShadow")) (ELit (LString "W-IMPORT-METHOD-SHADOW")))
(DFunDef false "codeText" ((PCon "WIncomparableImpls")) (ELit (LString "W-INCOMPARABLE-IMPLS")))
(DFunDef false "codeText" ((PCon "WKeepIrFailed")) (ELit (LString "W-KEEP-IR-FAILED")))
(DFunDef false "codeText" ((PCon "WMainMissing")) (ELit (LString "W-MAIN-MISSING")))
(DFunDef false "codeText" ((PCon "WMainShape")) (ELit (LString "W-MAIN-SHAPE")))
(DFunDef false "codeText" ((PCon "WNonexhaustive")) (ELit (LString "W-NONEXHAUSTIVE")))
(DFunDef false "codeText" ((PCon "WNonexhaustiveClauses")) (ELit (LString "W-NONEXHAUSTIVE-CLAUSES")))
(DFunDef false "codeText" ((PCon "WPreludeMethodShadow")) (ELit (LString "W-PRELUDE-METHOD-SHADOW")))
(DFunDef false "codeText" ((PCon "WUnreachableAlt")) (ELit (LString "W-UNREACHABLE-ALT")))
(DFunDef false "codeText" ((PCon "WUnreachableArm")) (ELit (LString "W-UNREACHABLE-ARM")))
(DTypeSig true "kindText" (TyFun (TyCon "DiagKind") (TyCon "String")))
(DFunDef false "kindText" ((PCon "DkLex")) (ELit (LString "lex")))
(DFunDef false "kindText" ((PCon "DkParse")) (ELit (LString "parse")))
(DFunDef false "kindText" ((PCon "DkResolve")) (ELit (LString "resolve")))
(DFunDef false "kindText" ((PCon "DkType")) (ELit (LString "type")))
(DFunDef false "kindText" ((PCon "DkWarning")) (ELit (LString "warning")))
(DFunDef false "kindText" ((PCon "DkError")) (ELit (LString "error")))
(DTypeSig true "codeKind" (TyFun (TyCon "DiagCode") (TyCon "DiagKind")))
(DFunDef false "codeKind" ((PVar "c")) (EApp (EVar "kindOfText") (EApp (EVar "codeText") (EVar "c"))))
(DTypeSig false "kindOfText" (TyFun (TyCon "String") (TyCon "DiagKind")))
(DFunDef false "kindOfText" ((PVar "t")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "L-"))) (EVar "t")) (EVar "DkLex") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "P-"))) (EVar "t")) (EVar "DkParse") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "R-"))) (EVar "t")) (EVar "DkResolve") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "T-"))) (EVar "t")) (EVar "DkType") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "W-"))) (EVar "t")) (EVar "DkWarning") (EIf (EVar "otherwise") (EVar "DkError") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig true "allDiagCodes" (TyApp (TyCon "List") (TyCon "DiagCode")))
(DFunDef false "allDiagCodes" () (EListLit (EVar "EAmbiguousDispatch") (EVar "ECyclicValue") (EVar "EDivZero") (EVar "EIndexOob") (EVar "EIntOverflow") (EVar "ELetRefute") (EVar "EMainAsyncPayload") (EVar "EModZero") (EVar "ENoMain") (EVar "ENonexhaustiveMatch") (EVar "ENotAFunction") (EVar "EPanic") (EVar "EPhysDuplicate") (EVar "EPhysShape") (EVar "EPhysUndeclaredFuncref") (EVar "EPhysUndeclaredType") (EVar "EPhysUndefined") (EVar "ESliceOob") (EVar "EStackOverflow") (EVar "EWasmNoBinding") (EVar "LBadByteLiteral") (EVar "LBadChar") (EVar "LBadCharLiteral") (EVar "LBadEscape") (EVar "LBadUnicodeEscape") (EVar "LBareUnicodeEscape") (EVar "LBlockcomment") (EVar "LByteLiteralIdent") (EVar "LByteNonAscii") (EVar "LFloatOverflow") (EVar "LHsDollar") (EVar "LHsLambda") (EVar "LIntOverflow") (EVar "LMalformedFloat") (EVar "LMalformedRadix") (EVar "LNestedInterpolation") (EVar "LSemicolon") (EVar "LUnterminatedComment") (EVar "LUnterminatedString") (EVar "PBadNeq") (EVar "PBraceBlock") (EVar "PDefKeyword") (EVar "PDoEndsInBinding") (EVar "PForWhile") (EVar "PGuardBarInMatch") (EVar "PGuardIfInEquation") (EVar "PHsCase") (EVar "PHsSig") (EVar "PMissingWhere") (EVar "PNoPowOperator") (EVar "POcamlMatchWith") (EVar "PParse") (EVar "PRawStringAfterDot") (EVar "PReservedKeyword") (EVar "PUnexpectedEof") (EVar "PWhereBodySameLine") (EVar "RAbstractCtorImport") (EVar "RAbstractField") (EVar "RAmbiguousCtor") (EVar "RAmbiguousEffect") (EVar "RAmbiguousInterface") (EVar "RAmbiguousOccurrence") (EVar "RAmbiguousType") (EVar "RAsPatternMisplaced") (EVar "RBareCtorImport") (EVar "RBuildFailed") (EVar "RCannotDerive") (EVar "RDupBinder") (EVar "RDupBinding") (EVar "RDuplicateBinding") (EVar "RDuplicateDef") (EVar "RDuplicateIfaceMethod") (EVar "RDuplicateSignature") (EVar "REffectLabelNoMembers") (EVar "RExternWithBody") (EVar "RFieldNotInRecord") (EVar "RFileNotFound") (EVar "RFileNotUtf8") (EVar "RImmutableAssign") (EVar "RInternalExtern") (EVar "RMethodNotInInterface") (EVar "RMisplacedAuthorityBinder") (EVar "RModuleLoad") (EVar "RNewtypeCtorPrivate") (EVar "RNoExportedCtors") (EVar "RNonrecValueLet") (EVar "ROrPatternBinders") (EVar "ROrPatternMisplaced") (EVar "ROrphanSignature") (EVar "RPrivateName") (EVar "RUnbound") (EVar "RUnboundAuthority") (EVar "RUnknownCtor") (EVar "RUnknownEffect") (EVar "RUnknownField") (EVar "RUnknownInterface") (EVar "RUnknownModule") (EVar "RUnknownType") (EVar "TAbstractField") (EVar "TAliasArity") (EVar "TAmbiguousAliasMethod") (EVar "TAmbiguousField") (EVar "TAmbiguousInstance") (EVar "TAmbiguousMethod") (EVar "TAmbiguousReexport") (EVar "TAmbiguousShadowDecl") (EVar "TAuthority") (EVar "TAuthorityBinder") (EVar "TAuthorityDomain") (EVar "TAuthorityEscape") (EVar "TAuthorityExistentialScope") (EVar "TAuthorityIndexMismatch") (EVar "TAuthorityKind") (EVar "TAuthorityPattern") (EVar "TAuthorityPhantomExport") (EVar "TBangOnBool") (EVar "TBindOutsideDo") (EVar "TConflictingImpl") (EVar "TCyclicSuperinterface") (EVar "TDiscardedValue") (EVar "TDoNotMonad") (EVar "TEffectArgUncovered") (EVar "TEffectIndexEager") (EVar "TEffectIndexMismatch") (EVar "TEffectKindMismatch") (EVar "TEffectLaunder") (EVar "TEffectLeak") (EVar "TEffectParam") (EVar "TEffectParamVariance") (EVar "TEffectUndetermined") (EVar "TExportUnsolvedAuthority") (EVar "TFfiBuiltinBind") (EVar "TFfiBuiltinShadow") (EVar "TFfiCatalogNarrow") (EVar "TFfiCSymbol") (EVar "TFfiDuplicateHost") (EVar "TFfiJsName") (EVar "TFfiNoHost") (EVar "TFfiNoncrossable") (EVar "TFfiNullary") (EVar "TFfiReservedName") (EVar "TFfiUnboundHost") (EVar "TFfiUnknownHost") (EVar "TFfiUnlabelled") (EVar "TFieldNotInAllCtors") (EVar "TFieldPositionDiffers") (EVar "TFieldTypeDiffers") (EVar "TFileBoundValue") (EVar "TImplKindMismatch") (EVar "TImplMissingRequires") (EVar "TImplTooSpecific") (EVar "TIncompleteImpl") (EVar "TInfiniteType") (EVar "TInternalOrdinal") (EVar "TMainUsed") (EVar "TManifestEntry") (EVar "TManifestInvalid") (EVar "TManifestWrapper") (EVar "TMethodMismatch") (EVar "TMissingConstraint") (EVar "TMissingField") (EVar "TMissingSuperImpl") (EVar "TNoImpl") (EVar "TNonrecValueLet") (EVar "TNotAFunction") (EVar "TOrPatternBinderTypes") (EVar "TOrPatternTooMany") (EVar "TPhantomMethod") (EVar "TRecursiveAlias") (EVar "TRequiresCycle") (EVar "TRequiresDepth") (EVar "TRequiresUnrouted") (EVar "TResidual") (EVar "TSigOverExpansive") (EVar "TTargetCapability") (EVar "TTargetNoBinding") (EVar "TTargetNotProvided") (EVar "TTypeMismatch") (EVar "TTypeTooGeneral") (EVar "TUnbound") (EVar "TUnknownCtor") (EVar "TUnknownField") (EVar "TUnknownRecord") (EVar "TUnroutedDispatch") (EVar "TUpdateMultiCtor") (EVar "WGuardInexhaustive") (EVar "WImportMethodShadow") (EVar "WIncomparableImpls") (EVar "WKeepIrFailed") (EVar "WMainMissing") (EVar "WMainShape") (EVar "WNonexhaustive") (EVar "WNonexhaustiveClauses") (EVar "WPreludeMethodShadow") (EVar "WUnreachableAlt") (EVar "WUnreachableArm")))
(DTypeSig true "codeOfText" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "DiagCode"))))
(DFunDef false "codeOfText" ((PVar "t")) (EApp (EApp (EVar "find") (ELam ((PVar "c")) (EBinOp "==" (EApp (EVar "codeText") (EVar "c")) (EVar "t")))) (EVar "allDiagCodes")))
(DImpl false "Display" ((TyCon "DiagCode")) () ((im "display" () (EVar "codeText"))))
# MARK
(DUse false (UseGroup ("string") ((mem "startsWith" false))))
(DData Public "DiagKind" () ((variant "DkLex" (ConPos)) (variant "DkParse" (ConPos)) (variant "DkResolve" (ConPos)) (variant "DkType" (ConPos)) (variant "DkWarning" (ConPos)) (variant "DkError" (ConPos))) ())
(DImpl true "Eq" ((TyCon "DiagKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "DkLex") (PCon "DkLex")) () (EVar "True")) (arm (PTuple (PCon "DkParse") (PCon "DkParse")) () (EVar "True")) (arm (PTuple (PCon "DkResolve") (PCon "DkResolve")) () (EVar "True")) (arm (PTuple (PCon "DkType") (PCon "DkType")) () (EVar "True")) (arm (PTuple (PCon "DkWarning") (PCon "DkWarning")) () (EVar "True")) (arm (PTuple (PCon "DkError") (PCon "DkError")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "DiagKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "DkLex") () (ELit (LString "DkLex"))) (arm (PCon "DkParse") () (ELit (LString "DkParse"))) (arm (PCon "DkResolve") () (ELit (LString "DkResolve"))) (arm (PCon "DkType") () (ELit (LString "DkType"))) (arm (PCon "DkWarning") () (ELit (LString "DkWarning"))) (arm (PCon "DkError") () (ELit (LString "DkError")))))))
(DData Public "DiagCode" () ((variant "EAmbiguousDispatch" (ConPos)) (variant "ECyclicValue" (ConPos)) (variant "EDivZero" (ConPos)) (variant "EIndexOob" (ConPos)) (variant "EIntOverflow" (ConPos)) (variant "ELetRefute" (ConPos)) (variant "EMainAsyncPayload" (ConPos)) (variant "EModZero" (ConPos)) (variant "ENoMain" (ConPos)) (variant "ENonexhaustiveMatch" (ConPos)) (variant "ENotAFunction" (ConPos)) (variant "EPanic" (ConPos)) (variant "EPhysDuplicate" (ConPos)) (variant "EPhysShape" (ConPos)) (variant "EPhysUndeclaredFuncref" (ConPos)) (variant "EPhysUndeclaredType" (ConPos)) (variant "EPhysUndefined" (ConPos)) (variant "ESliceOob" (ConPos)) (variant "EStackOverflow" (ConPos)) (variant "EWasmNoBinding" (ConPos)) (variant "LBadByteLiteral" (ConPos)) (variant "LBadChar" (ConPos)) (variant "LBadCharLiteral" (ConPos)) (variant "LBadEscape" (ConPos)) (variant "LBadUnicodeEscape" (ConPos)) (variant "LBareUnicodeEscape" (ConPos)) (variant "LBlockcomment" (ConPos)) (variant "LByteLiteralIdent" (ConPos)) (variant "LByteNonAscii" (ConPos)) (variant "LFloatOverflow" (ConPos)) (variant "LHsDollar" (ConPos)) (variant "LHsLambda" (ConPos)) (variant "LIntOverflow" (ConPos)) (variant "LMalformedFloat" (ConPos)) (variant "LMalformedRadix" (ConPos)) (variant "LNestedInterpolation" (ConPos)) (variant "LSemicolon" (ConPos)) (variant "LUnterminatedComment" (ConPos)) (variant "LUnterminatedString" (ConPos)) (variant "PBadNeq" (ConPos)) (variant "PBraceBlock" (ConPos)) (variant "PDefKeyword" (ConPos)) (variant "PDoEndsInBinding" (ConPos)) (variant "PForWhile" (ConPos)) (variant "PGuardBarInMatch" (ConPos)) (variant "PGuardIfInEquation" (ConPos)) (variant "PHsCase" (ConPos)) (variant "PHsSig" (ConPos)) (variant "PMissingWhere" (ConPos)) (variant "PNoPowOperator" (ConPos)) (variant "POcamlMatchWith" (ConPos)) (variant "PParse" (ConPos)) (variant "PRawStringAfterDot" (ConPos)) (variant "PReservedKeyword" (ConPos)) (variant "PUnexpectedEof" (ConPos)) (variant "PWhereBodySameLine" (ConPos)) (variant "RAbstractCtorImport" (ConPos)) (variant "RAbstractField" (ConPos)) (variant "RAmbiguousCtor" (ConPos)) (variant "RAmbiguousEffect" (ConPos)) (variant "RAmbiguousInterface" (ConPos)) (variant "RAmbiguousOccurrence" (ConPos)) (variant "RAmbiguousType" (ConPos)) (variant "RAsPatternMisplaced" (ConPos)) (variant "RBareCtorImport" (ConPos)) (variant "RBuildFailed" (ConPos)) (variant "RCannotDerive" (ConPos)) (variant "RDupBinder" (ConPos)) (variant "RDupBinding" (ConPos)) (variant "RDuplicateBinding" (ConPos)) (variant "RDuplicateDef" (ConPos)) (variant "RDuplicateIfaceMethod" (ConPos)) (variant "RDuplicateSignature" (ConPos)) (variant "REffectLabelNoMembers" (ConPos)) (variant "RExternWithBody" (ConPos)) (variant "RFieldNotInRecord" (ConPos)) (variant "RFileNotFound" (ConPos)) (variant "RFileNotUtf8" (ConPos)) (variant "RImmutableAssign" (ConPos)) (variant "RInternalExtern" (ConPos)) (variant "RMethodNotInInterface" (ConPos)) (variant "RMisplacedAuthorityBinder" (ConPos)) (variant "RModuleLoad" (ConPos)) (variant "RNewtypeCtorPrivate" (ConPos)) (variant "RNoExportedCtors" (ConPos)) (variant "RNonrecValueLet" (ConPos)) (variant "ROrPatternBinders" (ConPos)) (variant "ROrPatternMisplaced" (ConPos)) (variant "ROrphanSignature" (ConPos)) (variant "RPrivateName" (ConPos)) (variant "RUnbound" (ConPos)) (variant "RUnboundAuthority" (ConPos)) (variant "RUnknownCtor" (ConPos)) (variant "RUnknownEffect" (ConPos)) (variant "RUnknownField" (ConPos)) (variant "RUnknownInterface" (ConPos)) (variant "RUnknownModule" (ConPos)) (variant "RUnknownType" (ConPos)) (variant "TAbstractField" (ConPos)) (variant "TAliasArity" (ConPos)) (variant "TAmbiguousAliasMethod" (ConPos)) (variant "TAmbiguousField" (ConPos)) (variant "TAmbiguousInstance" (ConPos)) (variant "TAmbiguousMethod" (ConPos)) (variant "TAmbiguousReexport" (ConPos)) (variant "TAmbiguousShadowDecl" (ConPos)) (variant "TAuthority" (ConPos)) (variant "TAuthorityBinder" (ConPos)) (variant "TAuthorityDomain" (ConPos)) (variant "TAuthorityEscape" (ConPos)) (variant "TAuthorityExistentialScope" (ConPos)) (variant "TAuthorityIndexMismatch" (ConPos)) (variant "TAuthorityKind" (ConPos)) (variant "TAuthorityPattern" (ConPos)) (variant "TAuthorityPhantomExport" (ConPos)) (variant "TBangOnBool" (ConPos)) (variant "TBindOutsideDo" (ConPos)) (variant "TConflictingImpl" (ConPos)) (variant "TCyclicSuperinterface" (ConPos)) (variant "TDiscardedValue" (ConPos)) (variant "TDoNotMonad" (ConPos)) (variant "TEffectArgUncovered" (ConPos)) (variant "TEffectIndexEager" (ConPos)) (variant "TEffectIndexMismatch" (ConPos)) (variant "TEffectKindMismatch" (ConPos)) (variant "TEffectLaunder" (ConPos)) (variant "TEffectLeak" (ConPos)) (variant "TEffectParam" (ConPos)) (variant "TEffectParamVariance" (ConPos)) (variant "TEffectUndetermined" (ConPos)) (variant "TExportUnsolvedAuthority" (ConPos)) (variant "TFfiBuiltinBind" (ConPos)) (variant "TFfiBuiltinShadow" (ConPos)) (variant "TFfiCatalogNarrow" (ConPos)) (variant "TFfiCSymbol" (ConPos)) (variant "TFfiDuplicateHost" (ConPos)) (variant "TFfiJsName" (ConPos)) (variant "TFfiNoHost" (ConPos)) (variant "TFfiNoncrossable" (ConPos)) (variant "TFfiNullary" (ConPos)) (variant "TFfiReservedName" (ConPos)) (variant "TFfiUnboundHost" (ConPos)) (variant "TFfiUnknownHost" (ConPos)) (variant "TFfiUnlabelled" (ConPos)) (variant "TFieldNotInAllCtors" (ConPos)) (variant "TFieldPositionDiffers" (ConPos)) (variant "TFieldTypeDiffers" (ConPos)) (variant "TFileBoundValue" (ConPos)) (variant "TImplKindMismatch" (ConPos)) (variant "TImplMissingRequires" (ConPos)) (variant "TImplTooSpecific" (ConPos)) (variant "TIncompleteImpl" (ConPos)) (variant "TInfiniteType" (ConPos)) (variant "TInternalOrdinal" (ConPos)) (variant "TMainUsed" (ConPos)) (variant "TManifestEntry" (ConPos)) (variant "TManifestInvalid" (ConPos)) (variant "TManifestWrapper" (ConPos)) (variant "TMethodMismatch" (ConPos)) (variant "TMissingConstraint" (ConPos)) (variant "TMissingField" (ConPos)) (variant "TMissingSuperImpl" (ConPos)) (variant "TNoImpl" (ConPos)) (variant "TNonrecValueLet" (ConPos)) (variant "TNotAFunction" (ConPos)) (variant "TOrPatternBinderTypes" (ConPos)) (variant "TOrPatternTooMany" (ConPos)) (variant "TPhantomMethod" (ConPos)) (variant "TRecursiveAlias" (ConPos)) (variant "TRequiresCycle" (ConPos)) (variant "TRequiresDepth" (ConPos)) (variant "TRequiresUnrouted" (ConPos)) (variant "TResidual" (ConPos)) (variant "TSigOverExpansive" (ConPos)) (variant "TTargetCapability" (ConPos)) (variant "TTargetNoBinding" (ConPos)) (variant "TTargetNotProvided" (ConPos)) (variant "TTypeMismatch" (ConPos)) (variant "TTypeTooGeneral" (ConPos)) (variant "TUnbound" (ConPos)) (variant "TUnknownCtor" (ConPos)) (variant "TUnknownField" (ConPos)) (variant "TUnknownRecord" (ConPos)) (variant "TUnroutedDispatch" (ConPos)) (variant "TUpdateMultiCtor" (ConPos)) (variant "WGuardInexhaustive" (ConPos)) (variant "WImportMethodShadow" (ConPos)) (variant "WIncomparableImpls" (ConPos)) (variant "WKeepIrFailed" (ConPos)) (variant "WMainMissing" (ConPos)) (variant "WMainShape" (ConPos)) (variant "WNonexhaustive" (ConPos)) (variant "WNonexhaustiveClauses" (ConPos)) (variant "WPreludeMethodShadow" (ConPos)) (variant "WUnreachableAlt" (ConPos)) (variant "WUnreachableArm" (ConPos))) ())
(DImpl true "Eq" ((TyCon "DiagCode")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "EAmbiguousDispatch") (PCon "EAmbiguousDispatch")) () (EVar "True")) (arm (PTuple (PCon "ECyclicValue") (PCon "ECyclicValue")) () (EVar "True")) (arm (PTuple (PCon "EDivZero") (PCon "EDivZero")) () (EVar "True")) (arm (PTuple (PCon "EIndexOob") (PCon "EIndexOob")) () (EVar "True")) (arm (PTuple (PCon "EIntOverflow") (PCon "EIntOverflow")) () (EVar "True")) (arm (PTuple (PCon "ELetRefute") (PCon "ELetRefute")) () (EVar "True")) (arm (PTuple (PCon "EMainAsyncPayload") (PCon "EMainAsyncPayload")) () (EVar "True")) (arm (PTuple (PCon "EModZero") (PCon "EModZero")) () (EVar "True")) (arm (PTuple (PCon "ENoMain") (PCon "ENoMain")) () (EVar "True")) (arm (PTuple (PCon "ENonexhaustiveMatch") (PCon "ENonexhaustiveMatch")) () (EVar "True")) (arm (PTuple (PCon "ENotAFunction") (PCon "ENotAFunction")) () (EVar "True")) (arm (PTuple (PCon "EPanic") (PCon "EPanic")) () (EVar "True")) (arm (PTuple (PCon "EPhysDuplicate") (PCon "EPhysDuplicate")) () (EVar "True")) (arm (PTuple (PCon "EPhysShape") (PCon "EPhysShape")) () (EVar "True")) (arm (PTuple (PCon "EPhysUndeclaredFuncref") (PCon "EPhysUndeclaredFuncref")) () (EVar "True")) (arm (PTuple (PCon "EPhysUndeclaredType") (PCon "EPhysUndeclaredType")) () (EVar "True")) (arm (PTuple (PCon "EPhysUndefined") (PCon "EPhysUndefined")) () (EVar "True")) (arm (PTuple (PCon "ESliceOob") (PCon "ESliceOob")) () (EVar "True")) (arm (PTuple (PCon "EStackOverflow") (PCon "EStackOverflow")) () (EVar "True")) (arm (PTuple (PCon "EWasmNoBinding") (PCon "EWasmNoBinding")) () (EVar "True")) (arm (PTuple (PCon "LBadByteLiteral") (PCon "LBadByteLiteral")) () (EVar "True")) (arm (PTuple (PCon "LBadChar") (PCon "LBadChar")) () (EVar "True")) (arm (PTuple (PCon "LBadCharLiteral") (PCon "LBadCharLiteral")) () (EVar "True")) (arm (PTuple (PCon "LBadEscape") (PCon "LBadEscape")) () (EVar "True")) (arm (PTuple (PCon "LBadUnicodeEscape") (PCon "LBadUnicodeEscape")) () (EVar "True")) (arm (PTuple (PCon "LBareUnicodeEscape") (PCon "LBareUnicodeEscape")) () (EVar "True")) (arm (PTuple (PCon "LBlockcomment") (PCon "LBlockcomment")) () (EVar "True")) (arm (PTuple (PCon "LByteLiteralIdent") (PCon "LByteLiteralIdent")) () (EVar "True")) (arm (PTuple (PCon "LByteNonAscii") (PCon "LByteNonAscii")) () (EVar "True")) (arm (PTuple (PCon "LFloatOverflow") (PCon "LFloatOverflow")) () (EVar "True")) (arm (PTuple (PCon "LHsDollar") (PCon "LHsDollar")) () (EVar "True")) (arm (PTuple (PCon "LHsLambda") (PCon "LHsLambda")) () (EVar "True")) (arm (PTuple (PCon "LIntOverflow") (PCon "LIntOverflow")) () (EVar "True")) (arm (PTuple (PCon "LMalformedFloat") (PCon "LMalformedFloat")) () (EVar "True")) (arm (PTuple (PCon "LMalformedRadix") (PCon "LMalformedRadix")) () (EVar "True")) (arm (PTuple (PCon "LNestedInterpolation") (PCon "LNestedInterpolation")) () (EVar "True")) (arm (PTuple (PCon "LSemicolon") (PCon "LSemicolon")) () (EVar "True")) (arm (PTuple (PCon "LUnterminatedComment") (PCon "LUnterminatedComment")) () (EVar "True")) (arm (PTuple (PCon "LUnterminatedString") (PCon "LUnterminatedString")) () (EVar "True")) (arm (PTuple (PCon "PBadNeq") (PCon "PBadNeq")) () (EVar "True")) (arm (PTuple (PCon "PBraceBlock") (PCon "PBraceBlock")) () (EVar "True")) (arm (PTuple (PCon "PDefKeyword") (PCon "PDefKeyword")) () (EVar "True")) (arm (PTuple (PCon "PDoEndsInBinding") (PCon "PDoEndsInBinding")) () (EVar "True")) (arm (PTuple (PCon "PForWhile") (PCon "PForWhile")) () (EVar "True")) (arm (PTuple (PCon "PGuardBarInMatch") (PCon "PGuardBarInMatch")) () (EVar "True")) (arm (PTuple (PCon "PGuardIfInEquation") (PCon "PGuardIfInEquation")) () (EVar "True")) (arm (PTuple (PCon "PHsCase") (PCon "PHsCase")) () (EVar "True")) (arm (PTuple (PCon "PHsSig") (PCon "PHsSig")) () (EVar "True")) (arm (PTuple (PCon "PMissingWhere") (PCon "PMissingWhere")) () (EVar "True")) (arm (PTuple (PCon "PNoPowOperator") (PCon "PNoPowOperator")) () (EVar "True")) (arm (PTuple (PCon "POcamlMatchWith") (PCon "POcamlMatchWith")) () (EVar "True")) (arm (PTuple (PCon "PParse") (PCon "PParse")) () (EVar "True")) (arm (PTuple (PCon "PRawStringAfterDot") (PCon "PRawStringAfterDot")) () (EVar "True")) (arm (PTuple (PCon "PReservedKeyword") (PCon "PReservedKeyword")) () (EVar "True")) (arm (PTuple (PCon "PUnexpectedEof") (PCon "PUnexpectedEof")) () (EVar "True")) (arm (PTuple (PCon "PWhereBodySameLine") (PCon "PWhereBodySameLine")) () (EVar "True")) (arm (PTuple (PCon "RAbstractCtorImport") (PCon "RAbstractCtorImport")) () (EVar "True")) (arm (PTuple (PCon "RAbstractField") (PCon "RAbstractField")) () (EVar "True")) (arm (PTuple (PCon "RAmbiguousCtor") (PCon "RAmbiguousCtor")) () (EVar "True")) (arm (PTuple (PCon "RAmbiguousEffect") (PCon "RAmbiguousEffect")) () (EVar "True")) (arm (PTuple (PCon "RAmbiguousInterface") (PCon "RAmbiguousInterface")) () (EVar "True")) (arm (PTuple (PCon "RAmbiguousOccurrence") (PCon "RAmbiguousOccurrence")) () (EVar "True")) (arm (PTuple (PCon "RAmbiguousType") (PCon "RAmbiguousType")) () (EVar "True")) (arm (PTuple (PCon "RAsPatternMisplaced") (PCon "RAsPatternMisplaced")) () (EVar "True")) (arm (PTuple (PCon "RBareCtorImport") (PCon "RBareCtorImport")) () (EVar "True")) (arm (PTuple (PCon "RBuildFailed") (PCon "RBuildFailed")) () (EVar "True")) (arm (PTuple (PCon "RCannotDerive") (PCon "RCannotDerive")) () (EVar "True")) (arm (PTuple (PCon "RDupBinder") (PCon "RDupBinder")) () (EVar "True")) (arm (PTuple (PCon "RDupBinding") (PCon "RDupBinding")) () (EVar "True")) (arm (PTuple (PCon "RDuplicateBinding") (PCon "RDuplicateBinding")) () (EVar "True")) (arm (PTuple (PCon "RDuplicateDef") (PCon "RDuplicateDef")) () (EVar "True")) (arm (PTuple (PCon "RDuplicateIfaceMethod") (PCon "RDuplicateIfaceMethod")) () (EVar "True")) (arm (PTuple (PCon "RDuplicateSignature") (PCon "RDuplicateSignature")) () (EVar "True")) (arm (PTuple (PCon "REffectLabelNoMembers") (PCon "REffectLabelNoMembers")) () (EVar "True")) (arm (PTuple (PCon "RExternWithBody") (PCon "RExternWithBody")) () (EVar "True")) (arm (PTuple (PCon "RFieldNotInRecord") (PCon "RFieldNotInRecord")) () (EVar "True")) (arm (PTuple (PCon "RFileNotFound") (PCon "RFileNotFound")) () (EVar "True")) (arm (PTuple (PCon "RFileNotUtf8") (PCon "RFileNotUtf8")) () (EVar "True")) (arm (PTuple (PCon "RImmutableAssign") (PCon "RImmutableAssign")) () (EVar "True")) (arm (PTuple (PCon "RInternalExtern") (PCon "RInternalExtern")) () (EVar "True")) (arm (PTuple (PCon "RMethodNotInInterface") (PCon "RMethodNotInInterface")) () (EVar "True")) (arm (PTuple (PCon "RMisplacedAuthorityBinder") (PCon "RMisplacedAuthorityBinder")) () (EVar "True")) (arm (PTuple (PCon "RModuleLoad") (PCon "RModuleLoad")) () (EVar "True")) (arm (PTuple (PCon "RNewtypeCtorPrivate") (PCon "RNewtypeCtorPrivate")) () (EVar "True")) (arm (PTuple (PCon "RNoExportedCtors") (PCon "RNoExportedCtors")) () (EVar "True")) (arm (PTuple (PCon "RNonrecValueLet") (PCon "RNonrecValueLet")) () (EVar "True")) (arm (PTuple (PCon "ROrPatternBinders") (PCon "ROrPatternBinders")) () (EVar "True")) (arm (PTuple (PCon "ROrPatternMisplaced") (PCon "ROrPatternMisplaced")) () (EVar "True")) (arm (PTuple (PCon "ROrphanSignature") (PCon "ROrphanSignature")) () (EVar "True")) (arm (PTuple (PCon "RPrivateName") (PCon "RPrivateName")) () (EVar "True")) (arm (PTuple (PCon "RUnbound") (PCon "RUnbound")) () (EVar "True")) (arm (PTuple (PCon "RUnboundAuthority") (PCon "RUnboundAuthority")) () (EVar "True")) (arm (PTuple (PCon "RUnknownCtor") (PCon "RUnknownCtor")) () (EVar "True")) (arm (PTuple (PCon "RUnknownEffect") (PCon "RUnknownEffect")) () (EVar "True")) (arm (PTuple (PCon "RUnknownField") (PCon "RUnknownField")) () (EVar "True")) (arm (PTuple (PCon "RUnknownInterface") (PCon "RUnknownInterface")) () (EVar "True")) (arm (PTuple (PCon "RUnknownModule") (PCon "RUnknownModule")) () (EVar "True")) (arm (PTuple (PCon "RUnknownType") (PCon "RUnknownType")) () (EVar "True")) (arm (PTuple (PCon "TAbstractField") (PCon "TAbstractField")) () (EVar "True")) (arm (PTuple (PCon "TAliasArity") (PCon "TAliasArity")) () (EVar "True")) (arm (PTuple (PCon "TAmbiguousAliasMethod") (PCon "TAmbiguousAliasMethod")) () (EVar "True")) (arm (PTuple (PCon "TAmbiguousField") (PCon "TAmbiguousField")) () (EVar "True")) (arm (PTuple (PCon "TAmbiguousInstance") (PCon "TAmbiguousInstance")) () (EVar "True")) (arm (PTuple (PCon "TAmbiguousMethod") (PCon "TAmbiguousMethod")) () (EVar "True")) (arm (PTuple (PCon "TAmbiguousReexport") (PCon "TAmbiguousReexport")) () (EVar "True")) (arm (PTuple (PCon "TAmbiguousShadowDecl") (PCon "TAmbiguousShadowDecl")) () (EVar "True")) (arm (PTuple (PCon "TAuthority") (PCon "TAuthority")) () (EVar "True")) (arm (PTuple (PCon "TAuthorityBinder") (PCon "TAuthorityBinder")) () (EVar "True")) (arm (PTuple (PCon "TAuthorityDomain") (PCon "TAuthorityDomain")) () (EVar "True")) (arm (PTuple (PCon "TAuthorityEscape") (PCon "TAuthorityEscape")) () (EVar "True")) (arm (PTuple (PCon "TAuthorityExistentialScope") (PCon "TAuthorityExistentialScope")) () (EVar "True")) (arm (PTuple (PCon "TAuthorityIndexMismatch") (PCon "TAuthorityIndexMismatch")) () (EVar "True")) (arm (PTuple (PCon "TAuthorityKind") (PCon "TAuthorityKind")) () (EVar "True")) (arm (PTuple (PCon "TAuthorityPattern") (PCon "TAuthorityPattern")) () (EVar "True")) (arm (PTuple (PCon "TAuthorityPhantomExport") (PCon "TAuthorityPhantomExport")) () (EVar "True")) (arm (PTuple (PCon "TBangOnBool") (PCon "TBangOnBool")) () (EVar "True")) (arm (PTuple (PCon "TBindOutsideDo") (PCon "TBindOutsideDo")) () (EVar "True")) (arm (PTuple (PCon "TConflictingImpl") (PCon "TConflictingImpl")) () (EVar "True")) (arm (PTuple (PCon "TCyclicSuperinterface") (PCon "TCyclicSuperinterface")) () (EVar "True")) (arm (PTuple (PCon "TDiscardedValue") (PCon "TDiscardedValue")) () (EVar "True")) (arm (PTuple (PCon "TDoNotMonad") (PCon "TDoNotMonad")) () (EVar "True")) (arm (PTuple (PCon "TEffectArgUncovered") (PCon "TEffectArgUncovered")) () (EVar "True")) (arm (PTuple (PCon "TEffectIndexEager") (PCon "TEffectIndexEager")) () (EVar "True")) (arm (PTuple (PCon "TEffectIndexMismatch") (PCon "TEffectIndexMismatch")) () (EVar "True")) (arm (PTuple (PCon "TEffectKindMismatch") (PCon "TEffectKindMismatch")) () (EVar "True")) (arm (PTuple (PCon "TEffectLaunder") (PCon "TEffectLaunder")) () (EVar "True")) (arm (PTuple (PCon "TEffectLeak") (PCon "TEffectLeak")) () (EVar "True")) (arm (PTuple (PCon "TEffectParam") (PCon "TEffectParam")) () (EVar "True")) (arm (PTuple (PCon "TEffectParamVariance") (PCon "TEffectParamVariance")) () (EVar "True")) (arm (PTuple (PCon "TEffectUndetermined") (PCon "TEffectUndetermined")) () (EVar "True")) (arm (PTuple (PCon "TExportUnsolvedAuthority") (PCon "TExportUnsolvedAuthority")) () (EVar "True")) (arm (PTuple (PCon "TFfiBuiltinBind") (PCon "TFfiBuiltinBind")) () (EVar "True")) (arm (PTuple (PCon "TFfiBuiltinShadow") (PCon "TFfiBuiltinShadow")) () (EVar "True")) (arm (PTuple (PCon "TFfiCatalogNarrow") (PCon "TFfiCatalogNarrow")) () (EVar "True")) (arm (PTuple (PCon "TFfiCSymbol") (PCon "TFfiCSymbol")) () (EVar "True")) (arm (PTuple (PCon "TFfiDuplicateHost") (PCon "TFfiDuplicateHost")) () (EVar "True")) (arm (PTuple (PCon "TFfiJsName") (PCon "TFfiJsName")) () (EVar "True")) (arm (PTuple (PCon "TFfiNoHost") (PCon "TFfiNoHost")) () (EVar "True")) (arm (PTuple (PCon "TFfiNoncrossable") (PCon "TFfiNoncrossable")) () (EVar "True")) (arm (PTuple (PCon "TFfiNullary") (PCon "TFfiNullary")) () (EVar "True")) (arm (PTuple (PCon "TFfiReservedName") (PCon "TFfiReservedName")) () (EVar "True")) (arm (PTuple (PCon "TFfiUnboundHost") (PCon "TFfiUnboundHost")) () (EVar "True")) (arm (PTuple (PCon "TFfiUnknownHost") (PCon "TFfiUnknownHost")) () (EVar "True")) (arm (PTuple (PCon "TFfiUnlabelled") (PCon "TFfiUnlabelled")) () (EVar "True")) (arm (PTuple (PCon "TFieldNotInAllCtors") (PCon "TFieldNotInAllCtors")) () (EVar "True")) (arm (PTuple (PCon "TFieldPositionDiffers") (PCon "TFieldPositionDiffers")) () (EVar "True")) (arm (PTuple (PCon "TFieldTypeDiffers") (PCon "TFieldTypeDiffers")) () (EVar "True")) (arm (PTuple (PCon "TFileBoundValue") (PCon "TFileBoundValue")) () (EVar "True")) (arm (PTuple (PCon "TImplKindMismatch") (PCon "TImplKindMismatch")) () (EVar "True")) (arm (PTuple (PCon "TImplMissingRequires") (PCon "TImplMissingRequires")) () (EVar "True")) (arm (PTuple (PCon "TImplTooSpecific") (PCon "TImplTooSpecific")) () (EVar "True")) (arm (PTuple (PCon "TIncompleteImpl") (PCon "TIncompleteImpl")) () (EVar "True")) (arm (PTuple (PCon "TInfiniteType") (PCon "TInfiniteType")) () (EVar "True")) (arm (PTuple (PCon "TInternalOrdinal") (PCon "TInternalOrdinal")) () (EVar "True")) (arm (PTuple (PCon "TMainUsed") (PCon "TMainUsed")) () (EVar "True")) (arm (PTuple (PCon "TManifestEntry") (PCon "TManifestEntry")) () (EVar "True")) (arm (PTuple (PCon "TManifestInvalid") (PCon "TManifestInvalid")) () (EVar "True")) (arm (PTuple (PCon "TManifestWrapper") (PCon "TManifestWrapper")) () (EVar "True")) (arm (PTuple (PCon "TMethodMismatch") (PCon "TMethodMismatch")) () (EVar "True")) (arm (PTuple (PCon "TMissingConstraint") (PCon "TMissingConstraint")) () (EVar "True")) (arm (PTuple (PCon "TMissingField") (PCon "TMissingField")) () (EVar "True")) (arm (PTuple (PCon "TMissingSuperImpl") (PCon "TMissingSuperImpl")) () (EVar "True")) (arm (PTuple (PCon "TNoImpl") (PCon "TNoImpl")) () (EVar "True")) (arm (PTuple (PCon "TNonrecValueLet") (PCon "TNonrecValueLet")) () (EVar "True")) (arm (PTuple (PCon "TNotAFunction") (PCon "TNotAFunction")) () (EVar "True")) (arm (PTuple (PCon "TOrPatternBinderTypes") (PCon "TOrPatternBinderTypes")) () (EVar "True")) (arm (PTuple (PCon "TOrPatternTooMany") (PCon "TOrPatternTooMany")) () (EVar "True")) (arm (PTuple (PCon "TPhantomMethod") (PCon "TPhantomMethod")) () (EVar "True")) (arm (PTuple (PCon "TRecursiveAlias") (PCon "TRecursiveAlias")) () (EVar "True")) (arm (PTuple (PCon "TRequiresCycle") (PCon "TRequiresCycle")) () (EVar "True")) (arm (PTuple (PCon "TRequiresDepth") (PCon "TRequiresDepth")) () (EVar "True")) (arm (PTuple (PCon "TRequiresUnrouted") (PCon "TRequiresUnrouted")) () (EVar "True")) (arm (PTuple (PCon "TResidual") (PCon "TResidual")) () (EVar "True")) (arm (PTuple (PCon "TSigOverExpansive") (PCon "TSigOverExpansive")) () (EVar "True")) (arm (PTuple (PCon "TTargetCapability") (PCon "TTargetCapability")) () (EVar "True")) (arm (PTuple (PCon "TTargetNoBinding") (PCon "TTargetNoBinding")) () (EVar "True")) (arm (PTuple (PCon "TTargetNotProvided") (PCon "TTargetNotProvided")) () (EVar "True")) (arm (PTuple (PCon "TTypeMismatch") (PCon "TTypeMismatch")) () (EVar "True")) (arm (PTuple (PCon "TTypeTooGeneral") (PCon "TTypeTooGeneral")) () (EVar "True")) (arm (PTuple (PCon "TUnbound") (PCon "TUnbound")) () (EVar "True")) (arm (PTuple (PCon "TUnknownCtor") (PCon "TUnknownCtor")) () (EVar "True")) (arm (PTuple (PCon "TUnknownField") (PCon "TUnknownField")) () (EVar "True")) (arm (PTuple (PCon "TUnknownRecord") (PCon "TUnknownRecord")) () (EVar "True")) (arm (PTuple (PCon "TUnroutedDispatch") (PCon "TUnroutedDispatch")) () (EVar "True")) (arm (PTuple (PCon "TUpdateMultiCtor") (PCon "TUpdateMultiCtor")) () (EVar "True")) (arm (PTuple (PCon "WGuardInexhaustive") (PCon "WGuardInexhaustive")) () (EVar "True")) (arm (PTuple (PCon "WImportMethodShadow") (PCon "WImportMethodShadow")) () (EVar "True")) (arm (PTuple (PCon "WIncomparableImpls") (PCon "WIncomparableImpls")) () (EVar "True")) (arm (PTuple (PCon "WKeepIrFailed") (PCon "WKeepIrFailed")) () (EVar "True")) (arm (PTuple (PCon "WMainMissing") (PCon "WMainMissing")) () (EVar "True")) (arm (PTuple (PCon "WMainShape") (PCon "WMainShape")) () (EVar "True")) (arm (PTuple (PCon "WNonexhaustive") (PCon "WNonexhaustive")) () (EVar "True")) (arm (PTuple (PCon "WNonexhaustiveClauses") (PCon "WNonexhaustiveClauses")) () (EVar "True")) (arm (PTuple (PCon "WPreludeMethodShadow") (PCon "WPreludeMethodShadow")) () (EVar "True")) (arm (PTuple (PCon "WUnreachableAlt") (PCon "WUnreachableAlt")) () (EVar "True")) (arm (PTuple (PCon "WUnreachableArm") (PCon "WUnreachableArm")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "DiagCode")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "EAmbiguousDispatch") () (ELit (LString "EAmbiguousDispatch"))) (arm (PCon "ECyclicValue") () (ELit (LString "ECyclicValue"))) (arm (PCon "EDivZero") () (ELit (LString "EDivZero"))) (arm (PCon "EIndexOob") () (ELit (LString "EIndexOob"))) (arm (PCon "EIntOverflow") () (ELit (LString "EIntOverflow"))) (arm (PCon "ELetRefute") () (ELit (LString "ELetRefute"))) (arm (PCon "EMainAsyncPayload") () (ELit (LString "EMainAsyncPayload"))) (arm (PCon "EModZero") () (ELit (LString "EModZero"))) (arm (PCon "ENoMain") () (ELit (LString "ENoMain"))) (arm (PCon "ENonexhaustiveMatch") () (ELit (LString "ENonexhaustiveMatch"))) (arm (PCon "ENotAFunction") () (ELit (LString "ENotAFunction"))) (arm (PCon "EPanic") () (ELit (LString "EPanic"))) (arm (PCon "EPhysDuplicate") () (ELit (LString "EPhysDuplicate"))) (arm (PCon "EPhysShape") () (ELit (LString "EPhysShape"))) (arm (PCon "EPhysUndeclaredFuncref") () (ELit (LString "EPhysUndeclaredFuncref"))) (arm (PCon "EPhysUndeclaredType") () (ELit (LString "EPhysUndeclaredType"))) (arm (PCon "EPhysUndefined") () (ELit (LString "EPhysUndefined"))) (arm (PCon "ESliceOob") () (ELit (LString "ESliceOob"))) (arm (PCon "EStackOverflow") () (ELit (LString "EStackOverflow"))) (arm (PCon "EWasmNoBinding") () (ELit (LString "EWasmNoBinding"))) (arm (PCon "LBadByteLiteral") () (ELit (LString "LBadByteLiteral"))) (arm (PCon "LBadChar") () (ELit (LString "LBadChar"))) (arm (PCon "LBadCharLiteral") () (ELit (LString "LBadCharLiteral"))) (arm (PCon "LBadEscape") () (ELit (LString "LBadEscape"))) (arm (PCon "LBadUnicodeEscape") () (ELit (LString "LBadUnicodeEscape"))) (arm (PCon "LBareUnicodeEscape") () (ELit (LString "LBareUnicodeEscape"))) (arm (PCon "LBlockcomment") () (ELit (LString "LBlockcomment"))) (arm (PCon "LByteLiteralIdent") () (ELit (LString "LByteLiteralIdent"))) (arm (PCon "LByteNonAscii") () (ELit (LString "LByteNonAscii"))) (arm (PCon "LFloatOverflow") () (ELit (LString "LFloatOverflow"))) (arm (PCon "LHsDollar") () (ELit (LString "LHsDollar"))) (arm (PCon "LHsLambda") () (ELit (LString "LHsLambda"))) (arm (PCon "LIntOverflow") () (ELit (LString "LIntOverflow"))) (arm (PCon "LMalformedFloat") () (ELit (LString "LMalformedFloat"))) (arm (PCon "LMalformedRadix") () (ELit (LString "LMalformedRadix"))) (arm (PCon "LNestedInterpolation") () (ELit (LString "LNestedInterpolation"))) (arm (PCon "LSemicolon") () (ELit (LString "LSemicolon"))) (arm (PCon "LUnterminatedComment") () (ELit (LString "LUnterminatedComment"))) (arm (PCon "LUnterminatedString") () (ELit (LString "LUnterminatedString"))) (arm (PCon "PBadNeq") () (ELit (LString "PBadNeq"))) (arm (PCon "PBraceBlock") () (ELit (LString "PBraceBlock"))) (arm (PCon "PDefKeyword") () (ELit (LString "PDefKeyword"))) (arm (PCon "PDoEndsInBinding") () (ELit (LString "PDoEndsInBinding"))) (arm (PCon "PForWhile") () (ELit (LString "PForWhile"))) (arm (PCon "PGuardBarInMatch") () (ELit (LString "PGuardBarInMatch"))) (arm (PCon "PGuardIfInEquation") () (ELit (LString "PGuardIfInEquation"))) (arm (PCon "PHsCase") () (ELit (LString "PHsCase"))) (arm (PCon "PHsSig") () (ELit (LString "PHsSig"))) (arm (PCon "PMissingWhere") () (ELit (LString "PMissingWhere"))) (arm (PCon "PNoPowOperator") () (ELit (LString "PNoPowOperator"))) (arm (PCon "POcamlMatchWith") () (ELit (LString "POcamlMatchWith"))) (arm (PCon "PParse") () (ELit (LString "PParse"))) (arm (PCon "PRawStringAfterDot") () (ELit (LString "PRawStringAfterDot"))) (arm (PCon "PReservedKeyword") () (ELit (LString "PReservedKeyword"))) (arm (PCon "PUnexpectedEof") () (ELit (LString "PUnexpectedEof"))) (arm (PCon "PWhereBodySameLine") () (ELit (LString "PWhereBodySameLine"))) (arm (PCon "RAbstractCtorImport") () (ELit (LString "RAbstractCtorImport"))) (arm (PCon "RAbstractField") () (ELit (LString "RAbstractField"))) (arm (PCon "RAmbiguousCtor") () (ELit (LString "RAmbiguousCtor"))) (arm (PCon "RAmbiguousEffect") () (ELit (LString "RAmbiguousEffect"))) (arm (PCon "RAmbiguousInterface") () (ELit (LString "RAmbiguousInterface"))) (arm (PCon "RAmbiguousOccurrence") () (ELit (LString "RAmbiguousOccurrence"))) (arm (PCon "RAmbiguousType") () (ELit (LString "RAmbiguousType"))) (arm (PCon "RAsPatternMisplaced") () (ELit (LString "RAsPatternMisplaced"))) (arm (PCon "RBareCtorImport") () (ELit (LString "RBareCtorImport"))) (arm (PCon "RBuildFailed") () (ELit (LString "RBuildFailed"))) (arm (PCon "RCannotDerive") () (ELit (LString "RCannotDerive"))) (arm (PCon "RDupBinder") () (ELit (LString "RDupBinder"))) (arm (PCon "RDupBinding") () (ELit (LString "RDupBinding"))) (arm (PCon "RDuplicateBinding") () (ELit (LString "RDuplicateBinding"))) (arm (PCon "RDuplicateDef") () (ELit (LString "RDuplicateDef"))) (arm (PCon "RDuplicateIfaceMethod") () (ELit (LString "RDuplicateIfaceMethod"))) (arm (PCon "RDuplicateSignature") () (ELit (LString "RDuplicateSignature"))) (arm (PCon "REffectLabelNoMembers") () (ELit (LString "REffectLabelNoMembers"))) (arm (PCon "RExternWithBody") () (ELit (LString "RExternWithBody"))) (arm (PCon "RFieldNotInRecord") () (ELit (LString "RFieldNotInRecord"))) (arm (PCon "RFileNotFound") () (ELit (LString "RFileNotFound"))) (arm (PCon "RFileNotUtf8") () (ELit (LString "RFileNotUtf8"))) (arm (PCon "RImmutableAssign") () (ELit (LString "RImmutableAssign"))) (arm (PCon "RInternalExtern") () (ELit (LString "RInternalExtern"))) (arm (PCon "RMethodNotInInterface") () (ELit (LString "RMethodNotInInterface"))) (arm (PCon "RMisplacedAuthorityBinder") () (ELit (LString "RMisplacedAuthorityBinder"))) (arm (PCon "RModuleLoad") () (ELit (LString "RModuleLoad"))) (arm (PCon "RNewtypeCtorPrivate") () (ELit (LString "RNewtypeCtorPrivate"))) (arm (PCon "RNoExportedCtors") () (ELit (LString "RNoExportedCtors"))) (arm (PCon "RNonrecValueLet") () (ELit (LString "RNonrecValueLet"))) (arm (PCon "ROrPatternBinders") () (ELit (LString "ROrPatternBinders"))) (arm (PCon "ROrPatternMisplaced") () (ELit (LString "ROrPatternMisplaced"))) (arm (PCon "ROrphanSignature") () (ELit (LString "ROrphanSignature"))) (arm (PCon "RPrivateName") () (ELit (LString "RPrivateName"))) (arm (PCon "RUnbound") () (ELit (LString "RUnbound"))) (arm (PCon "RUnboundAuthority") () (ELit (LString "RUnboundAuthority"))) (arm (PCon "RUnknownCtor") () (ELit (LString "RUnknownCtor"))) (arm (PCon "RUnknownEffect") () (ELit (LString "RUnknownEffect"))) (arm (PCon "RUnknownField") () (ELit (LString "RUnknownField"))) (arm (PCon "RUnknownInterface") () (ELit (LString "RUnknownInterface"))) (arm (PCon "RUnknownModule") () (ELit (LString "RUnknownModule"))) (arm (PCon "RUnknownType") () (ELit (LString "RUnknownType"))) (arm (PCon "TAbstractField") () (ELit (LString "TAbstractField"))) (arm (PCon "TAliasArity") () (ELit (LString "TAliasArity"))) (arm (PCon "TAmbiguousAliasMethod") () (ELit (LString "TAmbiguousAliasMethod"))) (arm (PCon "TAmbiguousField") () (ELit (LString "TAmbiguousField"))) (arm (PCon "TAmbiguousInstance") () (ELit (LString "TAmbiguousInstance"))) (arm (PCon "TAmbiguousMethod") () (ELit (LString "TAmbiguousMethod"))) (arm (PCon "TAmbiguousReexport") () (ELit (LString "TAmbiguousReexport"))) (arm (PCon "TAmbiguousShadowDecl") () (ELit (LString "TAmbiguousShadowDecl"))) (arm (PCon "TAuthority") () (ELit (LString "TAuthority"))) (arm (PCon "TAuthorityBinder") () (ELit (LString "TAuthorityBinder"))) (arm (PCon "TAuthorityDomain") () (ELit (LString "TAuthorityDomain"))) (arm (PCon "TAuthorityEscape") () (ELit (LString "TAuthorityEscape"))) (arm (PCon "TAuthorityExistentialScope") () (ELit (LString "TAuthorityExistentialScope"))) (arm (PCon "TAuthorityIndexMismatch") () (ELit (LString "TAuthorityIndexMismatch"))) (arm (PCon "TAuthorityKind") () (ELit (LString "TAuthorityKind"))) (arm (PCon "TAuthorityPattern") () (ELit (LString "TAuthorityPattern"))) (arm (PCon "TAuthorityPhantomExport") () (ELit (LString "TAuthorityPhantomExport"))) (arm (PCon "TBangOnBool") () (ELit (LString "TBangOnBool"))) (arm (PCon "TBindOutsideDo") () (ELit (LString "TBindOutsideDo"))) (arm (PCon "TConflictingImpl") () (ELit (LString "TConflictingImpl"))) (arm (PCon "TCyclicSuperinterface") () (ELit (LString "TCyclicSuperinterface"))) (arm (PCon "TDiscardedValue") () (ELit (LString "TDiscardedValue"))) (arm (PCon "TDoNotMonad") () (ELit (LString "TDoNotMonad"))) (arm (PCon "TEffectArgUncovered") () (ELit (LString "TEffectArgUncovered"))) (arm (PCon "TEffectIndexEager") () (ELit (LString "TEffectIndexEager"))) (arm (PCon "TEffectIndexMismatch") () (ELit (LString "TEffectIndexMismatch"))) (arm (PCon "TEffectKindMismatch") () (ELit (LString "TEffectKindMismatch"))) (arm (PCon "TEffectLaunder") () (ELit (LString "TEffectLaunder"))) (arm (PCon "TEffectLeak") () (ELit (LString "TEffectLeak"))) (arm (PCon "TEffectParam") () (ELit (LString "TEffectParam"))) (arm (PCon "TEffectParamVariance") () (ELit (LString "TEffectParamVariance"))) (arm (PCon "TEffectUndetermined") () (ELit (LString "TEffectUndetermined"))) (arm (PCon "TExportUnsolvedAuthority") () (ELit (LString "TExportUnsolvedAuthority"))) (arm (PCon "TFfiBuiltinBind") () (ELit (LString "TFfiBuiltinBind"))) (arm (PCon "TFfiBuiltinShadow") () (ELit (LString "TFfiBuiltinShadow"))) (arm (PCon "TFfiCatalogNarrow") () (ELit (LString "TFfiCatalogNarrow"))) (arm (PCon "TFfiCSymbol") () (ELit (LString "TFfiCSymbol"))) (arm (PCon "TFfiDuplicateHost") () (ELit (LString "TFfiDuplicateHost"))) (arm (PCon "TFfiJsName") () (ELit (LString "TFfiJsName"))) (arm (PCon "TFfiNoHost") () (ELit (LString "TFfiNoHost"))) (arm (PCon "TFfiNoncrossable") () (ELit (LString "TFfiNoncrossable"))) (arm (PCon "TFfiNullary") () (ELit (LString "TFfiNullary"))) (arm (PCon "TFfiReservedName") () (ELit (LString "TFfiReservedName"))) (arm (PCon "TFfiUnboundHost") () (ELit (LString "TFfiUnboundHost"))) (arm (PCon "TFfiUnknownHost") () (ELit (LString "TFfiUnknownHost"))) (arm (PCon "TFfiUnlabelled") () (ELit (LString "TFfiUnlabelled"))) (arm (PCon "TFieldNotInAllCtors") () (ELit (LString "TFieldNotInAllCtors"))) (arm (PCon "TFieldPositionDiffers") () (ELit (LString "TFieldPositionDiffers"))) (arm (PCon "TFieldTypeDiffers") () (ELit (LString "TFieldTypeDiffers"))) (arm (PCon "TFileBoundValue") () (ELit (LString "TFileBoundValue"))) (arm (PCon "TImplKindMismatch") () (ELit (LString "TImplKindMismatch"))) (arm (PCon "TImplMissingRequires") () (ELit (LString "TImplMissingRequires"))) (arm (PCon "TImplTooSpecific") () (ELit (LString "TImplTooSpecific"))) (arm (PCon "TIncompleteImpl") () (ELit (LString "TIncompleteImpl"))) (arm (PCon "TInfiniteType") () (ELit (LString "TInfiniteType"))) (arm (PCon "TInternalOrdinal") () (ELit (LString "TInternalOrdinal"))) (arm (PCon "TMainUsed") () (ELit (LString "TMainUsed"))) (arm (PCon "TManifestEntry") () (ELit (LString "TManifestEntry"))) (arm (PCon "TManifestInvalid") () (ELit (LString "TManifestInvalid"))) (arm (PCon "TManifestWrapper") () (ELit (LString "TManifestWrapper"))) (arm (PCon "TMethodMismatch") () (ELit (LString "TMethodMismatch"))) (arm (PCon "TMissingConstraint") () (ELit (LString "TMissingConstraint"))) (arm (PCon "TMissingField") () (ELit (LString "TMissingField"))) (arm (PCon "TMissingSuperImpl") () (ELit (LString "TMissingSuperImpl"))) (arm (PCon "TNoImpl") () (ELit (LString "TNoImpl"))) (arm (PCon "TNonrecValueLet") () (ELit (LString "TNonrecValueLet"))) (arm (PCon "TNotAFunction") () (ELit (LString "TNotAFunction"))) (arm (PCon "TOrPatternBinderTypes") () (ELit (LString "TOrPatternBinderTypes"))) (arm (PCon "TOrPatternTooMany") () (ELit (LString "TOrPatternTooMany"))) (arm (PCon "TPhantomMethod") () (ELit (LString "TPhantomMethod"))) (arm (PCon "TRecursiveAlias") () (ELit (LString "TRecursiveAlias"))) (arm (PCon "TRequiresCycle") () (ELit (LString "TRequiresCycle"))) (arm (PCon "TRequiresDepth") () (ELit (LString "TRequiresDepth"))) (arm (PCon "TRequiresUnrouted") () (ELit (LString "TRequiresUnrouted"))) (arm (PCon "TResidual") () (ELit (LString "TResidual"))) (arm (PCon "TSigOverExpansive") () (ELit (LString "TSigOverExpansive"))) (arm (PCon "TTargetCapability") () (ELit (LString "TTargetCapability"))) (arm (PCon "TTargetNoBinding") () (ELit (LString "TTargetNoBinding"))) (arm (PCon "TTargetNotProvided") () (ELit (LString "TTargetNotProvided"))) (arm (PCon "TTypeMismatch") () (ELit (LString "TTypeMismatch"))) (arm (PCon "TTypeTooGeneral") () (ELit (LString "TTypeTooGeneral"))) (arm (PCon "TUnbound") () (ELit (LString "TUnbound"))) (arm (PCon "TUnknownCtor") () (ELit (LString "TUnknownCtor"))) (arm (PCon "TUnknownField") () (ELit (LString "TUnknownField"))) (arm (PCon "TUnknownRecord") () (ELit (LString "TUnknownRecord"))) (arm (PCon "TUnroutedDispatch") () (ELit (LString "TUnroutedDispatch"))) (arm (PCon "TUpdateMultiCtor") () (ELit (LString "TUpdateMultiCtor"))) (arm (PCon "WGuardInexhaustive") () (ELit (LString "WGuardInexhaustive"))) (arm (PCon "WImportMethodShadow") () (ELit (LString "WImportMethodShadow"))) (arm (PCon "WIncomparableImpls") () (ELit (LString "WIncomparableImpls"))) (arm (PCon "WKeepIrFailed") () (ELit (LString "WKeepIrFailed"))) (arm (PCon "WMainMissing") () (ELit (LString "WMainMissing"))) (arm (PCon "WMainShape") () (ELit (LString "WMainShape"))) (arm (PCon "WNonexhaustive") () (ELit (LString "WNonexhaustive"))) (arm (PCon "WNonexhaustiveClauses") () (ELit (LString "WNonexhaustiveClauses"))) (arm (PCon "WPreludeMethodShadow") () (ELit (LString "WPreludeMethodShadow"))) (arm (PCon "WUnreachableAlt") () (ELit (LString "WUnreachableAlt"))) (arm (PCon "WUnreachableArm") () (ELit (LString "WUnreachableArm")))))))
(DTypeSig true "codeText" (TyFun (TyCon "DiagCode") (TyCon "String")))
(DFunDef false "codeText" ((PCon "EAmbiguousDispatch")) (ELit (LString "E-AMBIGUOUS-DISPATCH")))
(DFunDef false "codeText" ((PCon "ECyclicValue")) (ELit (LString "E-CYCLIC-VALUE")))
(DFunDef false "codeText" ((PCon "EDivZero")) (ELit (LString "E-DIV-ZERO")))
(DFunDef false "codeText" ((PCon "EIndexOob")) (ELit (LString "E-INDEX-OOB")))
(DFunDef false "codeText" ((PCon "EIntOverflow")) (ELit (LString "E-INT-OVERFLOW")))
(DFunDef false "codeText" ((PCon "ELetRefute")) (ELit (LString "E-LET-REFUTE")))
(DFunDef false "codeText" ((PCon "EMainAsyncPayload")) (ELit (LString "E-MAIN-ASYNC-PAYLOAD")))
(DFunDef false "codeText" ((PCon "EModZero")) (ELit (LString "E-MOD-ZERO")))
(DFunDef false "codeText" ((PCon "ENoMain")) (ELit (LString "E-NO-MAIN")))
(DFunDef false "codeText" ((PCon "ENonexhaustiveMatch")) (ELit (LString "E-NONEXHAUSTIVE-MATCH")))
(DFunDef false "codeText" ((PCon "ENotAFunction")) (ELit (LString "E-NOT-A-FUNCTION")))
(DFunDef false "codeText" ((PCon "EPanic")) (ELit (LString "E-PANIC")))
(DFunDef false "codeText" ((PCon "EPhysDuplicate")) (ELit (LString "E-PHYS-DUPLICATE")))
(DFunDef false "codeText" ((PCon "EPhysShape")) (ELit (LString "E-PHYS-SHAPE")))
(DFunDef false "codeText" ((PCon "EPhysUndeclaredFuncref")) (ELit (LString "E-PHYS-UNDECLARED-FUNCREF")))
(DFunDef false "codeText" ((PCon "EPhysUndeclaredType")) (ELit (LString "E-PHYS-UNDECLARED-TYPE")))
(DFunDef false "codeText" ((PCon "EPhysUndefined")) (ELit (LString "E-PHYS-UNDEFINED")))
(DFunDef false "codeText" ((PCon "ESliceOob")) (ELit (LString "E-SLICE-OOB")))
(DFunDef false "codeText" ((PCon "EStackOverflow")) (ELit (LString "E-STACK-OVERFLOW")))
(DFunDef false "codeText" ((PCon "EWasmNoBinding")) (ELit (LString "E-WASM-NO-BINDING")))
(DFunDef false "codeText" ((PCon "LBadByteLiteral")) (ELit (LString "L-BAD-BYTE-LITERAL")))
(DFunDef false "codeText" ((PCon "LBadChar")) (ELit (LString "L-BAD-CHAR")))
(DFunDef false "codeText" ((PCon "LBadCharLiteral")) (ELit (LString "L-BAD-CHAR-LITERAL")))
(DFunDef false "codeText" ((PCon "LBadEscape")) (ELit (LString "L-BAD-ESCAPE")))
(DFunDef false "codeText" ((PCon "LBadUnicodeEscape")) (ELit (LString "L-BAD-UNICODE-ESCAPE")))
(DFunDef false "codeText" ((PCon "LBareUnicodeEscape")) (ELit (LString "L-BARE-UNICODE-ESCAPE")))
(DFunDef false "codeText" ((PCon "LBlockcomment")) (ELit (LString "L-BLOCKCOMMENT")))
(DFunDef false "codeText" ((PCon "LByteLiteralIdent")) (ELit (LString "L-BYTE-LITERAL-IDENT")))
(DFunDef false "codeText" ((PCon "LByteNonAscii")) (ELit (LString "L-BYTE-NON-ASCII")))
(DFunDef false "codeText" ((PCon "LFloatOverflow")) (ELit (LString "L-FLOAT-OVERFLOW")))
(DFunDef false "codeText" ((PCon "LHsDollar")) (ELit (LString "L-HS-DOLLAR")))
(DFunDef false "codeText" ((PCon "LHsLambda")) (ELit (LString "L-HS-LAMBDA")))
(DFunDef false "codeText" ((PCon "LIntOverflow")) (ELit (LString "L-INT-OVERFLOW")))
(DFunDef false "codeText" ((PCon "LMalformedFloat")) (ELit (LString "L-MALFORMED-FLOAT")))
(DFunDef false "codeText" ((PCon "LMalformedRadix")) (ELit (LString "L-MALFORMED-RADIX")))
(DFunDef false "codeText" ((PCon "LNestedInterpolation")) (ELit (LString "L-NESTED-INTERPOLATION")))
(DFunDef false "codeText" ((PCon "LSemicolon")) (ELit (LString "L-SEMICOLON")))
(DFunDef false "codeText" ((PCon "LUnterminatedComment")) (ELit (LString "L-UNTERMINATED-COMMENT")))
(DFunDef false "codeText" ((PCon "LUnterminatedString")) (ELit (LString "L-UNTERMINATED-STRING")))
(DFunDef false "codeText" ((PCon "PBadNeq")) (ELit (LString "P-BAD-NEQ")))
(DFunDef false "codeText" ((PCon "PBraceBlock")) (ELit (LString "P-BRACE-BLOCK")))
(DFunDef false "codeText" ((PCon "PDefKeyword")) (ELit (LString "P-DEF-KEYWORD")))
(DFunDef false "codeText" ((PCon "PDoEndsInBinding")) (ELit (LString "P-DO-ENDS-IN-BINDING")))
(DFunDef false "codeText" ((PCon "PForWhile")) (ELit (LString "P-FOR-WHILE")))
(DFunDef false "codeText" ((PCon "PGuardBarInMatch")) (ELit (LString "P-GUARD-BAR-IN-MATCH")))
(DFunDef false "codeText" ((PCon "PGuardIfInEquation")) (ELit (LString "P-GUARD-IF-IN-EQUATION")))
(DFunDef false "codeText" ((PCon "PHsCase")) (ELit (LString "P-HS-CASE")))
(DFunDef false "codeText" ((PCon "PHsSig")) (ELit (LString "P-HS-SIG")))
(DFunDef false "codeText" ((PCon "PMissingWhere")) (ELit (LString "P-MISSING-WHERE")))
(DFunDef false "codeText" ((PCon "PNoPowOperator")) (ELit (LString "P-NO-POW-OPERATOR")))
(DFunDef false "codeText" ((PCon "POcamlMatchWith")) (ELit (LString "P-OCAML-MATCH-WITH")))
(DFunDef false "codeText" ((PCon "PParse")) (ELit (LString "P-PARSE")))
(DFunDef false "codeText" ((PCon "PRawStringAfterDot")) (ELit (LString "P-RAW-STRING-AFTER-DOT")))
(DFunDef false "codeText" ((PCon "PReservedKeyword")) (ELit (LString "P-RESERVED-KEYWORD")))
(DFunDef false "codeText" ((PCon "PUnexpectedEof")) (ELit (LString "P-UNEXPECTED-EOF")))
(DFunDef false "codeText" ((PCon "PWhereBodySameLine")) (ELit (LString "P-WHERE-BODY-SAME-LINE")))
(DFunDef false "codeText" ((PCon "RAbstractCtorImport")) (ELit (LString "R-ABSTRACT-CTOR-IMPORT")))
(DFunDef false "codeText" ((PCon "RAbstractField")) (ELit (LString "R-ABSTRACT-FIELD")))
(DFunDef false "codeText" ((PCon "RAmbiguousCtor")) (ELit (LString "R-AMBIGUOUS-CTOR")))
(DFunDef false "codeText" ((PCon "RAmbiguousEffect")) (ELit (LString "R-AMBIGUOUS-EFFECT")))
(DFunDef false "codeText" ((PCon "RAmbiguousInterface")) (ELit (LString "R-AMBIGUOUS-INTERFACE")))
(DFunDef false "codeText" ((PCon "RAmbiguousOccurrence")) (ELit (LString "R-AMBIGUOUS-OCCURRENCE")))
(DFunDef false "codeText" ((PCon "RAmbiguousType")) (ELit (LString "R-AMBIGUOUS-TYPE")))
(DFunDef false "codeText" ((PCon "RAsPatternMisplaced")) (ELit (LString "R-AS-PATTERN-MISPLACED")))
(DFunDef false "codeText" ((PCon "RBareCtorImport")) (ELit (LString "R-BARE-CTOR-IMPORT")))
(DFunDef false "codeText" ((PCon "RBuildFailed")) (ELit (LString "R-BUILD-FAILED")))
(DFunDef false "codeText" ((PCon "RCannotDerive")) (ELit (LString "R-CANNOT-DERIVE")))
(DFunDef false "codeText" ((PCon "RDupBinder")) (ELit (LString "R-DUP-BINDER")))
(DFunDef false "codeText" ((PCon "RDupBinding")) (ELit (LString "R-DUP-BINDING")))
(DFunDef false "codeText" ((PCon "RDuplicateBinding")) (ELit (LString "R-DUPLICATE-BINDING")))
(DFunDef false "codeText" ((PCon "RDuplicateDef")) (ELit (LString "R-DUPLICATE-DEF")))
(DFunDef false "codeText" ((PCon "RDuplicateIfaceMethod")) (ELit (LString "R-DUPLICATE-IFACE-METHOD")))
(DFunDef false "codeText" ((PCon "RDuplicateSignature")) (ELit (LString "R-DUPLICATE-SIGNATURE")))
(DFunDef false "codeText" ((PCon "REffectLabelNoMembers")) (ELit (LString "R-EFFECT-LABEL-NO-MEMBERS")))
(DFunDef false "codeText" ((PCon "RExternWithBody")) (ELit (LString "R-EXTERN-WITH-BODY")))
(DFunDef false "codeText" ((PCon "RFieldNotInRecord")) (ELit (LString "R-FIELD-NOT-IN-RECORD")))
(DFunDef false "codeText" ((PCon "RFileNotFound")) (ELit (LString "R-FILE-NOT-FOUND")))
(DFunDef false "codeText" ((PCon "RFileNotUtf8")) (ELit (LString "R-FILE-NOT-UTF8")))
(DFunDef false "codeText" ((PCon "RImmutableAssign")) (ELit (LString "R-IMMUTABLE-ASSIGN")))
(DFunDef false "codeText" ((PCon "RInternalExtern")) (ELit (LString "R-INTERNAL-EXTERN")))
(DFunDef false "codeText" ((PCon "RMethodNotInInterface")) (ELit (LString "R-METHOD-NOT-IN-INTERFACE")))
(DFunDef false "codeText" ((PCon "RMisplacedAuthorityBinder")) (ELit (LString "R-MISPLACED-AUTHORITY-BINDER")))
(DFunDef false "codeText" ((PCon "RModuleLoad")) (ELit (LString "R-MODULE-LOAD")))
(DFunDef false "codeText" ((PCon "RNewtypeCtorPrivate")) (ELit (LString "R-NEWTYPE-CTOR-PRIVATE")))
(DFunDef false "codeText" ((PCon "RNoExportedCtors")) (ELit (LString "R-NO-EXPORTED-CTORS")))
(DFunDef false "codeText" ((PCon "RNonrecValueLet")) (ELit (LString "R-NONREC-VALUE-LET")))
(DFunDef false "codeText" ((PCon "ROrPatternBinders")) (ELit (LString "R-OR-PATTERN-BINDERS")))
(DFunDef false "codeText" ((PCon "ROrPatternMisplaced")) (ELit (LString "R-OR-PATTERN-MISPLACED")))
(DFunDef false "codeText" ((PCon "ROrphanSignature")) (ELit (LString "R-ORPHAN-SIGNATURE")))
(DFunDef false "codeText" ((PCon "RPrivateName")) (ELit (LString "R-PRIVATE-NAME")))
(DFunDef false "codeText" ((PCon "RUnbound")) (ELit (LString "R-UNBOUND")))
(DFunDef false "codeText" ((PCon "RUnboundAuthority")) (ELit (LString "R-UNBOUND-AUTHORITY")))
(DFunDef false "codeText" ((PCon "RUnknownCtor")) (ELit (LString "R-UNKNOWN-CTOR")))
(DFunDef false "codeText" ((PCon "RUnknownEffect")) (ELit (LString "R-UNKNOWN-EFFECT")))
(DFunDef false "codeText" ((PCon "RUnknownField")) (ELit (LString "R-UNKNOWN-FIELD")))
(DFunDef false "codeText" ((PCon "RUnknownInterface")) (ELit (LString "R-UNKNOWN-INTERFACE")))
(DFunDef false "codeText" ((PCon "RUnknownModule")) (ELit (LString "R-UNKNOWN-MODULE")))
(DFunDef false "codeText" ((PCon "RUnknownType")) (ELit (LString "R-UNKNOWN-TYPE")))
(DFunDef false "codeText" ((PCon "TAbstractField")) (ELit (LString "T-ABSTRACT-FIELD")))
(DFunDef false "codeText" ((PCon "TAliasArity")) (ELit (LString "T-ALIAS-ARITY")))
(DFunDef false "codeText" ((PCon "TAmbiguousAliasMethod")) (ELit (LString "T-AMBIGUOUS-ALIAS-METHOD")))
(DFunDef false "codeText" ((PCon "TAmbiguousField")) (ELit (LString "T-AMBIGUOUS-FIELD")))
(DFunDef false "codeText" ((PCon "TAmbiguousInstance")) (ELit (LString "T-AMBIGUOUS-INSTANCE")))
(DFunDef false "codeText" ((PCon "TAmbiguousMethod")) (ELit (LString "T-AMBIGUOUS-METHOD")))
(DFunDef false "codeText" ((PCon "TAmbiguousReexport")) (ELit (LString "T-AMBIGUOUS-REEXPORT")))
(DFunDef false "codeText" ((PCon "TAmbiguousShadowDecl")) (ELit (LString "T-AMBIGUOUS-SHADOW-DECL")))
(DFunDef false "codeText" ((PCon "TAuthority")) (ELit (LString "T-AUTHORITY")))
(DFunDef false "codeText" ((PCon "TAuthorityBinder")) (ELit (LString "T-AUTHORITY-BINDER")))
(DFunDef false "codeText" ((PCon "TAuthorityDomain")) (ELit (LString "T-AUTHORITY-DOMAIN")))
(DFunDef false "codeText" ((PCon "TAuthorityEscape")) (ELit (LString "T-AUTHORITY-ESCAPE")))
(DFunDef false "codeText" ((PCon "TAuthorityExistentialScope")) (ELit (LString "T-AUTHORITY-EXISTENTIAL-SCOPE")))
(DFunDef false "codeText" ((PCon "TAuthorityIndexMismatch")) (ELit (LString "T-AUTHORITY-INDEX-MISMATCH")))
(DFunDef false "codeText" ((PCon "TAuthorityKind")) (ELit (LString "T-AUTHORITY-KIND")))
(DFunDef false "codeText" ((PCon "TAuthorityPattern")) (ELit (LString "T-AUTHORITY-PATTERN")))
(DFunDef false "codeText" ((PCon "TAuthorityPhantomExport")) (ELit (LString "T-AUTHORITY-PHANTOM-EXPORT")))
(DFunDef false "codeText" ((PCon "TBangOnBool")) (ELit (LString "T-BANG-ON-BOOL")))
(DFunDef false "codeText" ((PCon "TBindOutsideDo")) (ELit (LString "T-BIND-OUTSIDE-DO")))
(DFunDef false "codeText" ((PCon "TConflictingImpl")) (ELit (LString "T-CONFLICTING-IMPL")))
(DFunDef false "codeText" ((PCon "TCyclicSuperinterface")) (ELit (LString "T-CYCLIC-SUPERINTERFACE")))
(DFunDef false "codeText" ((PCon "TDiscardedValue")) (ELit (LString "T-DISCARDED-VALUE")))
(DFunDef false "codeText" ((PCon "TDoNotMonad")) (ELit (LString "T-DO-NOT-MONAD")))
(DFunDef false "codeText" ((PCon "TEffectArgUncovered")) (ELit (LString "T-EFFECT-ARG-UNCOVERED")))
(DFunDef false "codeText" ((PCon "TEffectIndexEager")) (ELit (LString "T-EFFECT-INDEX-EAGER")))
(DFunDef false "codeText" ((PCon "TEffectIndexMismatch")) (ELit (LString "T-EFFECT-INDEX-MISMATCH")))
(DFunDef false "codeText" ((PCon "TEffectKindMismatch")) (ELit (LString "T-EFFECT-KIND-MISMATCH")))
(DFunDef false "codeText" ((PCon "TEffectLaunder")) (ELit (LString "T-EFFECT-LAUNDER")))
(DFunDef false "codeText" ((PCon "TEffectLeak")) (ELit (LString "T-EFFECT-LEAK")))
(DFunDef false "codeText" ((PCon "TEffectParam")) (ELit (LString "T-EFFECT-PARAM")))
(DFunDef false "codeText" ((PCon "TEffectParamVariance")) (ELit (LString "T-EFFECT-PARAM-VARIANCE")))
(DFunDef false "codeText" ((PCon "TEffectUndetermined")) (ELit (LString "T-EFFECT-UNDETERMINED")))
(DFunDef false "codeText" ((PCon "TExportUnsolvedAuthority")) (ELit (LString "T-EXPORT-UNSOLVED-AUTHORITY")))
(DFunDef false "codeText" ((PCon "TFfiBuiltinBind")) (ELit (LString "T-FFI-BUILTIN-BIND")))
(DFunDef false "codeText" ((PCon "TFfiBuiltinShadow")) (ELit (LString "T-FFI-BUILTIN-SHADOW")))
(DFunDef false "codeText" ((PCon "TFfiCatalogNarrow")) (ELit (LString "T-FFI-CATALOG-NARROW")))
(DFunDef false "codeText" ((PCon "TFfiCSymbol")) (ELit (LString "T-FFI-C-SYMBOL")))
(DFunDef false "codeText" ((PCon "TFfiDuplicateHost")) (ELit (LString "T-FFI-DUPLICATE-HOST")))
(DFunDef false "codeText" ((PCon "TFfiJsName")) (ELit (LString "T-FFI-JS-NAME")))
(DFunDef false "codeText" ((PCon "TFfiNoHost")) (ELit (LString "T-FFI-NO-HOST")))
(DFunDef false "codeText" ((PCon "TFfiNoncrossable")) (ELit (LString "T-FFI-NONCROSSABLE")))
(DFunDef false "codeText" ((PCon "TFfiNullary")) (ELit (LString "T-FFI-NULLARY")))
(DFunDef false "codeText" ((PCon "TFfiReservedName")) (ELit (LString "T-FFI-RESERVED-NAME")))
(DFunDef false "codeText" ((PCon "TFfiUnboundHost")) (ELit (LString "T-FFI-UNBOUND-HOST")))
(DFunDef false "codeText" ((PCon "TFfiUnknownHost")) (ELit (LString "T-FFI-UNKNOWN-HOST")))
(DFunDef false "codeText" ((PCon "TFfiUnlabelled")) (ELit (LString "T-FFI-UNLABELLED")))
(DFunDef false "codeText" ((PCon "TFieldNotInAllCtors")) (ELit (LString "T-FIELD-NOT-IN-ALL-CTORS")))
(DFunDef false "codeText" ((PCon "TFieldPositionDiffers")) (ELit (LString "T-FIELD-POSITION-DIFFERS")))
(DFunDef false "codeText" ((PCon "TFieldTypeDiffers")) (ELit (LString "T-FIELD-TYPE-DIFFERS")))
(DFunDef false "codeText" ((PCon "TFileBoundValue")) (ELit (LString "T-FILE-BOUND-VALUE")))
(DFunDef false "codeText" ((PCon "TImplKindMismatch")) (ELit (LString "T-IMPL-KIND-MISMATCH")))
(DFunDef false "codeText" ((PCon "TImplMissingRequires")) (ELit (LString "T-IMPL-MISSING-REQUIRES")))
(DFunDef false "codeText" ((PCon "TImplTooSpecific")) (ELit (LString "T-IMPL-TOO-SPECIFIC")))
(DFunDef false "codeText" ((PCon "TIncompleteImpl")) (ELit (LString "T-INCOMPLETE-IMPL")))
(DFunDef false "codeText" ((PCon "TInfiniteType")) (ELit (LString "T-INFINITE-TYPE")))
(DFunDef false "codeText" ((PCon "TInternalOrdinal")) (ELit (LString "T-INTERNAL-ORDINAL")))
(DFunDef false "codeText" ((PCon "TMainUsed")) (ELit (LString "T-MAIN-USED")))
(DFunDef false "codeText" ((PCon "TManifestEntry")) (ELit (LString "T-MANIFEST-ENTRY")))
(DFunDef false "codeText" ((PCon "TManifestInvalid")) (ELit (LString "T-MANIFEST-INVALID")))
(DFunDef false "codeText" ((PCon "TManifestWrapper")) (ELit (LString "T-MANIFEST-WRAPPER")))
(DFunDef false "codeText" ((PCon "TMethodMismatch")) (ELit (LString "T-METHOD-MISMATCH")))
(DFunDef false "codeText" ((PCon "TMissingConstraint")) (ELit (LString "T-MISSING-CONSTRAINT")))
(DFunDef false "codeText" ((PCon "TMissingField")) (ELit (LString "T-MISSING-FIELD")))
(DFunDef false "codeText" ((PCon "TMissingSuperImpl")) (ELit (LString "T-MISSING-SUPER-IMPL")))
(DFunDef false "codeText" ((PCon "TNoImpl")) (ELit (LString "T-NO-IMPL")))
(DFunDef false "codeText" ((PCon "TNonrecValueLet")) (ELit (LString "T-NONREC-VALUE-LET")))
(DFunDef false "codeText" ((PCon "TNotAFunction")) (ELit (LString "T-NOT-A-FUNCTION")))
(DFunDef false "codeText" ((PCon "TOrPatternBinderTypes")) (ELit (LString "T-OR-PATTERN-BINDER-TYPES")))
(DFunDef false "codeText" ((PCon "TOrPatternTooMany")) (ELit (LString "T-OR-PATTERN-TOO-MANY")))
(DFunDef false "codeText" ((PCon "TPhantomMethod")) (ELit (LString "T-PHANTOM-METHOD")))
(DFunDef false "codeText" ((PCon "TRecursiveAlias")) (ELit (LString "T-RECURSIVE-ALIAS")))
(DFunDef false "codeText" ((PCon "TRequiresCycle")) (ELit (LString "T-REQUIRES-CYCLE")))
(DFunDef false "codeText" ((PCon "TRequiresDepth")) (ELit (LString "T-REQUIRES-DEPTH")))
(DFunDef false "codeText" ((PCon "TRequiresUnrouted")) (ELit (LString "T-REQUIRES-UNROUTED")))
(DFunDef false "codeText" ((PCon "TResidual")) (ELit (LString "T-RESIDUAL")))
(DFunDef false "codeText" ((PCon "TSigOverExpansive")) (ELit (LString "T-SIG-OVER-EXPANSIVE")))
(DFunDef false "codeText" ((PCon "TTargetCapability")) (ELit (LString "T-TARGET-CAPABILITY")))
(DFunDef false "codeText" ((PCon "TTargetNoBinding")) (ELit (LString "T-TARGET-NO-BINDING")))
(DFunDef false "codeText" ((PCon "TTargetNotProvided")) (ELit (LString "T-TARGET-NOT-PROVIDED")))
(DFunDef false "codeText" ((PCon "TTypeMismatch")) (ELit (LString "T-TYPE-MISMATCH")))
(DFunDef false "codeText" ((PCon "TTypeTooGeneral")) (ELit (LString "T-TYPE-TOO-GENERAL")))
(DFunDef false "codeText" ((PCon "TUnbound")) (ELit (LString "T-UNBOUND")))
(DFunDef false "codeText" ((PCon "TUnknownCtor")) (ELit (LString "T-UNKNOWN-CTOR")))
(DFunDef false "codeText" ((PCon "TUnknownField")) (ELit (LString "T-UNKNOWN-FIELD")))
(DFunDef false "codeText" ((PCon "TUnknownRecord")) (ELit (LString "T-UNKNOWN-RECORD")))
(DFunDef false "codeText" ((PCon "TUnroutedDispatch")) (ELit (LString "T-UNROUTED-DISPATCH")))
(DFunDef false "codeText" ((PCon "TUpdateMultiCtor")) (ELit (LString "T-UPDATE-MULTI-CTOR")))
(DFunDef false "codeText" ((PCon "WGuardInexhaustive")) (ELit (LString "W-GUARD-INEXHAUSTIVE")))
(DFunDef false "codeText" ((PCon "WImportMethodShadow")) (ELit (LString "W-IMPORT-METHOD-SHADOW")))
(DFunDef false "codeText" ((PCon "WIncomparableImpls")) (ELit (LString "W-INCOMPARABLE-IMPLS")))
(DFunDef false "codeText" ((PCon "WKeepIrFailed")) (ELit (LString "W-KEEP-IR-FAILED")))
(DFunDef false "codeText" ((PCon "WMainMissing")) (ELit (LString "W-MAIN-MISSING")))
(DFunDef false "codeText" ((PCon "WMainShape")) (ELit (LString "W-MAIN-SHAPE")))
(DFunDef false "codeText" ((PCon "WNonexhaustive")) (ELit (LString "W-NONEXHAUSTIVE")))
(DFunDef false "codeText" ((PCon "WNonexhaustiveClauses")) (ELit (LString "W-NONEXHAUSTIVE-CLAUSES")))
(DFunDef false "codeText" ((PCon "WPreludeMethodShadow")) (ELit (LString "W-PRELUDE-METHOD-SHADOW")))
(DFunDef false "codeText" ((PCon "WUnreachableAlt")) (ELit (LString "W-UNREACHABLE-ALT")))
(DFunDef false "codeText" ((PCon "WUnreachableArm")) (ELit (LString "W-UNREACHABLE-ARM")))
(DTypeSig true "kindText" (TyFun (TyCon "DiagKind") (TyCon "String")))
(DFunDef false "kindText" ((PCon "DkLex")) (ELit (LString "lex")))
(DFunDef false "kindText" ((PCon "DkParse")) (ELit (LString "parse")))
(DFunDef false "kindText" ((PCon "DkResolve")) (ELit (LString "resolve")))
(DFunDef false "kindText" ((PCon "DkType")) (ELit (LString "type")))
(DFunDef false "kindText" ((PCon "DkWarning")) (ELit (LString "warning")))
(DFunDef false "kindText" ((PCon "DkError")) (ELit (LString "error")))
(DTypeSig true "codeKind" (TyFun (TyCon "DiagCode") (TyCon "DiagKind")))
(DFunDef false "codeKind" ((PVar "c")) (EApp (EVar "kindOfText") (EApp (EVar "codeText") (EVar "c"))))
(DTypeSig false "kindOfText" (TyFun (TyCon "String") (TyCon "DiagKind")))
(DFunDef false "kindOfText" ((PVar "t")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "L-"))) (EVar "t")) (EVar "DkLex") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "P-"))) (EVar "t")) (EVar "DkParse") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "R-"))) (EVar "t")) (EVar "DkResolve") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "T-"))) (EVar "t")) (EVar "DkType") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "W-"))) (EVar "t")) (EVar "DkWarning") (EIf (EVar "otherwise") (EVar "DkError") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig true "allDiagCodes" (TyApp (TyCon "List") (TyCon "DiagCode")))
(DFunDef false "allDiagCodes" () (EListLit (EVar "EAmbiguousDispatch") (EVar "ECyclicValue") (EVar "EDivZero") (EVar "EIndexOob") (EVar "EIntOverflow") (EVar "ELetRefute") (EVar "EMainAsyncPayload") (EVar "EModZero") (EVar "ENoMain") (EVar "ENonexhaustiveMatch") (EVar "ENotAFunction") (EVar "EPanic") (EVar "EPhysDuplicate") (EVar "EPhysShape") (EVar "EPhysUndeclaredFuncref") (EVar "EPhysUndeclaredType") (EVar "EPhysUndefined") (EVar "ESliceOob") (EVar "EStackOverflow") (EVar "EWasmNoBinding") (EVar "LBadByteLiteral") (EVar "LBadChar") (EVar "LBadCharLiteral") (EVar "LBadEscape") (EVar "LBadUnicodeEscape") (EVar "LBareUnicodeEscape") (EVar "LBlockcomment") (EVar "LByteLiteralIdent") (EVar "LByteNonAscii") (EVar "LFloatOverflow") (EVar "LHsDollar") (EVar "LHsLambda") (EVar "LIntOverflow") (EVar "LMalformedFloat") (EVar "LMalformedRadix") (EVar "LNestedInterpolation") (EVar "LSemicolon") (EVar "LUnterminatedComment") (EVar "LUnterminatedString") (EVar "PBadNeq") (EVar "PBraceBlock") (EVar "PDefKeyword") (EVar "PDoEndsInBinding") (EVar "PForWhile") (EVar "PGuardBarInMatch") (EVar "PGuardIfInEquation") (EVar "PHsCase") (EVar "PHsSig") (EVar "PMissingWhere") (EVar "PNoPowOperator") (EVar "POcamlMatchWith") (EVar "PParse") (EVar "PRawStringAfterDot") (EVar "PReservedKeyword") (EVar "PUnexpectedEof") (EVar "PWhereBodySameLine") (EVar "RAbstractCtorImport") (EVar "RAbstractField") (EVar "RAmbiguousCtor") (EVar "RAmbiguousEffect") (EVar "RAmbiguousInterface") (EVar "RAmbiguousOccurrence") (EVar "RAmbiguousType") (EVar "RAsPatternMisplaced") (EVar "RBareCtorImport") (EVar "RBuildFailed") (EVar "RCannotDerive") (EVar "RDupBinder") (EVar "RDupBinding") (EVar "RDuplicateBinding") (EVar "RDuplicateDef") (EVar "RDuplicateIfaceMethod") (EVar "RDuplicateSignature") (EVar "REffectLabelNoMembers") (EVar "RExternWithBody") (EVar "RFieldNotInRecord") (EVar "RFileNotFound") (EVar "RFileNotUtf8") (EVar "RImmutableAssign") (EVar "RInternalExtern") (EVar "RMethodNotInInterface") (EVar "RMisplacedAuthorityBinder") (EVar "RModuleLoad") (EVar "RNewtypeCtorPrivate") (EVar "RNoExportedCtors") (EVar "RNonrecValueLet") (EVar "ROrPatternBinders") (EVar "ROrPatternMisplaced") (EVar "ROrphanSignature") (EVar "RPrivateName") (EVar "RUnbound") (EVar "RUnboundAuthority") (EVar "RUnknownCtor") (EVar "RUnknownEffect") (EVar "RUnknownField") (EVar "RUnknownInterface") (EVar "RUnknownModule") (EVar "RUnknownType") (EVar "TAbstractField") (EVar "TAliasArity") (EVar "TAmbiguousAliasMethod") (EVar "TAmbiguousField") (EVar "TAmbiguousInstance") (EVar "TAmbiguousMethod") (EVar "TAmbiguousReexport") (EVar "TAmbiguousShadowDecl") (EVar "TAuthority") (EVar "TAuthorityBinder") (EVar "TAuthorityDomain") (EVar "TAuthorityEscape") (EVar "TAuthorityExistentialScope") (EVar "TAuthorityIndexMismatch") (EVar "TAuthorityKind") (EVar "TAuthorityPattern") (EVar "TAuthorityPhantomExport") (EVar "TBangOnBool") (EVar "TBindOutsideDo") (EVar "TConflictingImpl") (EVar "TCyclicSuperinterface") (EVar "TDiscardedValue") (EVar "TDoNotMonad") (EVar "TEffectArgUncovered") (EVar "TEffectIndexEager") (EVar "TEffectIndexMismatch") (EVar "TEffectKindMismatch") (EVar "TEffectLaunder") (EVar "TEffectLeak") (EVar "TEffectParam") (EVar "TEffectParamVariance") (EVar "TEffectUndetermined") (EVar "TExportUnsolvedAuthority") (EVar "TFfiBuiltinBind") (EVar "TFfiBuiltinShadow") (EVar "TFfiCatalogNarrow") (EVar "TFfiCSymbol") (EVar "TFfiDuplicateHost") (EVar "TFfiJsName") (EVar "TFfiNoHost") (EVar "TFfiNoncrossable") (EVar "TFfiNullary") (EVar "TFfiReservedName") (EVar "TFfiUnboundHost") (EVar "TFfiUnknownHost") (EVar "TFfiUnlabelled") (EVar "TFieldNotInAllCtors") (EVar "TFieldPositionDiffers") (EVar "TFieldTypeDiffers") (EVar "TFileBoundValue") (EVar "TImplKindMismatch") (EVar "TImplMissingRequires") (EVar "TImplTooSpecific") (EVar "TIncompleteImpl") (EVar "TInfiniteType") (EVar "TInternalOrdinal") (EVar "TMainUsed") (EVar "TManifestEntry") (EVar "TManifestInvalid") (EVar "TManifestWrapper") (EVar "TMethodMismatch") (EVar "TMissingConstraint") (EVar "TMissingField") (EVar "TMissingSuperImpl") (EVar "TNoImpl") (EVar "TNonrecValueLet") (EVar "TNotAFunction") (EVar "TOrPatternBinderTypes") (EVar "TOrPatternTooMany") (EVar "TPhantomMethod") (EVar "TRecursiveAlias") (EVar "TRequiresCycle") (EVar "TRequiresDepth") (EVar "TRequiresUnrouted") (EVar "TResidual") (EVar "TSigOverExpansive") (EVar "TTargetCapability") (EVar "TTargetNoBinding") (EVar "TTargetNotProvided") (EVar "TTypeMismatch") (EVar "TTypeTooGeneral") (EVar "TUnbound") (EVar "TUnknownCtor") (EVar "TUnknownField") (EVar "TUnknownRecord") (EVar "TUnroutedDispatch") (EVar "TUpdateMultiCtor") (EVar "WGuardInexhaustive") (EVar "WImportMethodShadow") (EVar "WIncomparableImpls") (EVar "WKeepIrFailed") (EVar "WMainMissing") (EVar "WMainShape") (EVar "WNonexhaustive") (EVar "WNonexhaustiveClauses") (EVar "WPreludeMethodShadow") (EVar "WUnreachableAlt") (EVar "WUnreachableArm")))
(DTypeSig true "codeOfText" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "DiagCode"))))
(DFunDef false "codeOfText" ((PVar "t")) (EApp (EApp (EDictApp "find") (ELam ((PVar "c")) (EBinOp "==" (EApp (EVar "codeText") (EVar "c")) (EVar "t")))) (EVar "allDiagCodes")))
(DImpl false "Display" ((TyCon "DiagCode")) () ((im "display" () (EVar "codeText"))))
