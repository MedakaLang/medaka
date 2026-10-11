# META
source_lines=602
stages=DESUGAR,MARK
# SOURCE
-- Checks a lowered program must pass before an emitter writes any of it.  Each
-- check reads only the `CProgram` the emitter received and the extern catalog,
-- so every build entry reports a refusal from one place, and before either
-- emitter has produced text.
--
-- The record check: every record node carries each field's declared ordinal,
-- stamped by `core_ir_lower`, and an emitter stores and loads by it.  A node
-- with an unstamped (negative) ordinal, a record literal whose ordinals are not
-- its positions, or an update whose ordinals are not strictly ascending is
-- refused: the emitters keep no field-order table to fall back on.
--
-- The call check: every application carries the mode its head's defined arity
-- gives it (`core_ir_lower.definedArityOf`, the helper the lowering's stamp
-- reads).  A known head's defined arity is the pattern count of the clause it
-- names (a top-level or let-group binding, the entry an `RKey` route selects,
-- the binding an `RLocal` route or a `CDict` names, less the dictionaries the
-- occurrence supplies) or a constructor's field count; any other head is
-- dynamic.  An application with no arguments, or whose head is itself an
-- application, is refused too: a spine is one node.  So are impl entries of
-- one method and route word that take different value arities: they are the
-- clauses of one define.
--
-- The extern check: a runtime extern whose catalog row gives the backend no
-- lowering (`NotProvided`) is refused wherever the program references it
-- freely.  A reference is free when no local binder in scope and no top-level
-- binding or constructor of the program has the extern's name; those names
-- shadow the extern in both emitters' application ladders, so the emitter
-- would not lower the extern there.  The program checked is the one the
-- emitter received, after any reachability filter its entry ran.

import ir.core_ir.{
  CExpr(..),
  CField(..),
  CArm(..),
  CGuard(..),
  CStmt(..),
  CBind(..),
  CClause(..),
  CImplEntry(..),
  CImplBody(..),
  CProgram(..),
  CallMode(..),
  CallSite(..),
}
import ir.core_ir_lower.{
  ArityEnv,
  CallScope,
  bindGroupScope,
  bindLetScope,
  bindPatScope,
  bindPatsScope,
  callModeFor,
  definedArityOf,
  entryArityRow,
  programArities,
}
import ir.core_ir_sexp.{callModeSexp}
import backend.extern_catalog.{
  Disposition(..),
  GapKind,
  catalogRow,
  gapKindName,
  rowLlvm,
  rowWasm,
}
import support.ordmap.{OrdMap, omEmpty, omInsert, omHasKey, omLookup}
import support.util.{isNonEmptyL, joinWith, listLen, reverseL}

public export data Backend = LlvmBackend | WasmBackend

export
backendName : Backend -> String
backendName LlvmBackend = "llvm"
backendName WasmBackend = "wasm"

-- A free reference to a runtime extern the backend does not lower: the extern,
-- the backend, the row's gap kind and reason, and the top-level binding the
-- first reference sits in.
public export data ExternFinding =
  | ExternFinding String Backend GapKind String String

export
findingExtern : ExternFinding -> String
findingExtern (ExternFinding name _ _ _ _) = name

export
findingBinding : ExternFinding -> String
findingBinding (ExternFinding _ _ _ _ binding) = binding

-- The gap kind and reason when `backend` does not lower runtime extern `name`,
-- or `None` for an extern it lowers and for a name that is not a runtime extern.
export
unprovidedOn : Backend -> String -> Option (GapKind, String)
unprovidedOn LlvmBackend name = match catalogRow name
  Some r => notProvidedOf (rowLlvm r)
  None => None
unprovidedOn WasmBackend name = match catalogRow name
  Some r => notProvidedOf (rowWasm r)
  None => None

notProvidedOf : Disposition f -> Option (GapKind, String)
notProvidedOf (NotProvided kind why) = Some (kind, why)
notProvidedOf _ = None

export
isUnprovidedOn : Backend -> String -> Bool
isUnprovidedOn backend name = isSome (unprovidedOn backend name)

-- Every free reference to a runtime extern `backend` does not lower, one
-- finding per distinct extern, in the order of first reference.
-- `runtimeExterns` names the externs the entry declared from
-- `stdlib/runtime.mdk`; a name among them with no catalog row is an internal
-- error, raised before the program is read.
export
validateExterns : Backend -> List String -> CProgram -> List ExternFinding
validateExterns backend runtimeExterns prog =
  let _ = refuseMissingRows runtimeExterns
  match walkProgram backend prog
    Walk _ found _ _ => reverseL found

-- One line per record node whose ordinals the emitters cannot trust, in
-- program order; empty for a well-stamped program.
export
validateRecords : CProgram -> List String
validateRecords prog = match walkProgram LlvmBackend prog
  Walk _ _ bad _ => reverseL bad

export
renderRecordRefusal : List String -> String
renderRecordRefusal bad = joinWith "\n" bad

-- One line per application whose mode its head's defined arity contradicts, in
-- program order; empty for a well-stamped program.
export
validateCalls : CProgram -> List String
validateCalls (prog@(CProgram _ _ _ impls)) = match walkProgram LlvmBackend prog
  Walk _ _ _ bad => reverseL bad ++ splitGroupFaults impls omEmpty []

-- The entries of one method and route word are the clauses of one define, which
-- takes one parameter count, so an entry whose value arity differs from the
-- first entry of its group is refused.
splitGroupFaults : List CImplEntry -> OrdMap Int -> List String -> List String
splitGroupFaults [] _ acc = reverseL acc
splitGroupFaults ((ent@(CImplEntry method _ _ body)) :: rest) seen acc =
  let (key, n) = entryArityRow ent
  match omLookup key seen
    Some k =>
      if k == n then
        splitGroupFaults rest seen acc
      else
        splitGroupFaults
          rest
          seen
          ("call: impl entry takes \{intToString n} value parameters, the first entry of its group \{intToString k} [in impl \{method}@\{implBodyTag body}]"
            :: acc)
    None => splitGroupFaults rest (omInsert key n seen) acc

implBodyTag : CImplBody -> String
implBodyTag (CImplTagged tag _ _ _ _ _) = tag
implBodyTag (CImplDefault _ tag _ _ _ _) = tag

export
renderCallRefusal : List String -> String
renderCallRefusal bad = joinWith "\n" bad

-- The names in `names` that have no extern catalog row.
export
missingCatalogRows : List String -> List String
missingCatalogRows names = filter (n => isNone (catalogRow n)) names

export
missingRowsMessage : List String -> String
missingRowsMessage missing =
  let names = joinWith ", " (map quoteName missing)
  "internal error: runtime extern \{names} has no row in the extern catalog (compiler/backend/extern_catalog.mdk)"

quoteName : String -> String
quoteName n = "'" ++ n ++ "'"

refuseMissingRows : List String -> Unit
refuseMissingRows names = match missingCatalogRows names
  [] => ()
  missing => panic (missingRowsMessage missing)

-- One line per finding: what the build refuses, and why the backend does not
-- lower the extern.
export
renderExternFinding : ExternFinding -> String
renderExternFinding (ExternFinding name backend kind why binding) =
  "\{backendName backend}: runtime extern '\{name}' is not available on the \{backendName backend} backend (\{gapKindName kind}: \{why}) [in \{binding}]"

export
renderExternRefusal : List ExternFinding -> String
renderExternRefusal findings = joinWith "\n" (map renderExternFinding findings)

-- The panic of an emitter that meets an extern `validateExterns` refuses: the
-- validator runs first on every emission, so reaching one means the two
-- disagree about which references are free.
export
unrefusedExternMessage : Backend -> String -> String
unrefusedExternMessage backend name =
  "internal error: the \{backendName backend} emitter reached runtime extern '\{name}', which it does not lower, without a refusal from validateExterns (compiler/backend/core_validate.mdk)"

-- The top-level bindings and constructors of the program.
programNames : List CBind -> List (String, Int) -> OrdMap Unit -> OrdMap Unit
programNames [] [] acc = acc
programNames [] ((ctor, _) :: rest) acc =
  programNames [] rest (omInsert ctor () acc)
programNames ((CBind name _ _) :: rest) ctors acc =
  programNames rest ctors (omInsert name () acc)

-- A reference is the program's own when a top-level binding has its name, or
-- the `core__` name a bare prelude reference resolves to in both emitters
-- (`canonFn`, `canonFnName`).
isProgramName : OrdMap Unit -> String -> Bool
isProgramName top x = omHasKey x top || omHasKey ("core__" ++ x) top

-- The walk's state: the externs already found, the extern findings, the record
-- nodes with untrustworthy ordinals, and the applications with a wrong mode,
-- each newest first.
data Walk = Walk (OrdMap Unit) (List ExternFinding) (List String) (List String)

noFindings : Walk
noFindings = Walk omEmpty [] [] []

-- The backend, the program's own names, its defined arities, and the top-level
-- binding being read.
data Ctx = Ctx Backend (OrdMap Unit) ArityEnv String

walkProgram : Backend -> CProgram -> Walk
walkProgram backend (prog@(CProgram groups ctors _ impls)) =
  let top = programNames groups ctors omEmpty
  let env = programArities prog
  walkImpls backend top env impls (walkBinds backend top env groups noFindings)

walkBinds : Backend -> OrdMap Unit -> ArityEnv -> List CBind -> Walk -> Walk
walkBinds _ _ _ [] w = w
walkBinds backend top env ((CBind name clauses _) :: rest) w =
  walkBinds
    backend
    top
    env
    rest
    (walkClauses (Ctx backend top env name) omEmpty clauses w)

walkImpls : Backend ->
  OrdMap Unit ->
  ArityEnv ->
  List CImplEntry ->
  Walk ->
  Walk
walkImpls _ _ _ [] w = w
walkImpls backend top env ((CImplEntry method _ _ body) :: rest) w =
  walkImpls
    backend
    top
    env
    rest
    (walkImplBody (Ctx backend top env "impl \{method}") body w)

walkImplBody : Ctx -> CImplBody -> Walk -> Walk
walkImplBody (Ctx backend top env binding) (CImplTagged tag _ _ _ pats body) w =
  walkE
    (Ctx backend top env "\{binding}@\{tag}")
    (bindPatsScope pats omEmpty)
    body
    w
walkImplBody (Ctx backend top env binding) (CImplDefault _ tag _ _ pats body) w =
  walkE
    (Ctx backend top env "\{binding}@\{tag}")
    (bindPatsScope pats omEmpty)
    body
    w

walkClauses : Ctx -> CallScope -> List CClause -> Walk -> Walk
walkClauses _ _ [] w = w
walkClauses ctx scope ((CClause pats body) :: rest) w =
  walkClauses ctx scope rest (walkE ctx (bindPatsScope pats scope) body w)

-- Every constructor is listed, with no catch-all arm, so a new expression form
-- must decide where its binders scope.
walkE : Ctx -> CallScope -> CExpr -> Walk -> Walk
walkE ctx scope (CVar x _) w = noteVar ctx scope x w
walkE _ _ (CLit _) w = w
walkE ctx scope (CApp f args site) w =
  walkList ctx scope args (walkE ctx scope f (noteCall ctx scope f args site w))
walkE ctx scope (CLam pats body) w = walkE ctx (bindPatsScope pats scope) body w
walkE ctx scope (CLet recF pat rhs body) w =
  let inner = bindLetScope pat rhs scope
  walkE ctx inner body (walkE ctx (if recF then inner else scope) rhs w)
walkE ctx scope (CLetGroup binds body) w =
  let inner = bindGroupScope binds scope
  walkE ctx inner body (walkLocalBinds ctx inner binds w)
walkE ctx scope (CMatch scrut arms) w =
  walkArms ctx scope arms (walkE ctx scope scrut w)
walkE ctx scope (CDecision scrut arms _) w =
  walkArms ctx scope arms (walkE ctx scope scrut w)
walkE ctx scope (CIf c t f) w = walkList ctx scope [c, t, f] w
walkE ctx scope (CBinPrim _ l r _ _) w = walkList ctx scope [l, r] w
walkE ctx scope (CUnOp _ x) w = walkE ctx scope x w
walkE ctx scope (CTuple es) w = walkList ctx scope es w
walkE ctx scope (CList es) w = walkList ctx scope es w
walkE ctx scope (CRecord name fields) w =
  walkFields ctx scope fields (noteRecord ctx "CRecord" name True fields w)
walkE ctx scope (CFieldAccess x label name ord) w =
  walkE ctx scope x (noteAccess ctx label name ord w)
walkE ctx scope (CRecordUpdate name base fields) w =
  walkFields
    ctx
    scope
    fields
    (walkE ctx scope base (noteRecord ctx "CRecordUpdate" name False fields w))
walkE ctx scope (CVariantUpdate con base fields) w =
  walkFields
    ctx
    scope
    fields
    (walkE ctx scope base (noteRecord ctx "CVariantUpdate" con False fields w))
walkE ctx scope (CArray es) w = walkList ctx scope es w
walkE ctx scope (CRangeList lo hi _) w = walkList ctx scope [lo, hi] w
walkE ctx scope (CRangeArray lo hi _) w = walkList ctx scope [lo, hi] w
walkE ctx scope (CIndex a i) w = walkList ctx scope [a, i] w
walkE ctx scope (CSlice a lo hi _) w = walkList ctx scope [a, lo, hi] w
walkE ctx scope (CStringIndex a i) w = walkList ctx scope [a, i] w
walkE ctx scope (CStringSlice a lo hi _) w = walkList ctx scope [a, lo, hi] w
walkE ctx scope (CListIndex a i) w = walkList ctx scope [a, i] w
walkE ctx scope (CListSlice a lo hi _) w = walkList ctx scope [a, lo, hi] w
walkE ctx scope (CBlock stmts) w = walkStmts ctx scope stmts w
walkE _ _ (CMethod _ _ _ _ _ _) w = w
walkE _ _ (CDict _ _) w = w

-- A field access is stamped, or reads a `Ref` cell through `.value`.
noteAccess : Ctx -> String -> String -> Int -> Walk -> Walk
noteAccess ctx label name ord w =
  if ord >= 0 || label == "value" then
    w
  else
    noteRecordBad
      ctx
      "CFieldAccess"
      "\{name}.\{label}: unstamped field ordinal"
      w

-- `literal`: the ordinals must be the field positions (declared order).
noteRecord : Ctx -> String -> String -> Bool -> List CField -> Walk -> Walk
noteRecord ctx node name literal fields w =
  if ordinalsOk literal 0 (-1) fields then
    w
  else
    noteRecordBad
      ctx
      node
      "\{name}: field ordinals [\{joinWith ", " (map fieldOrdinalText fields)}] are not \{if literal then "the declared positions" else "strictly ascending"}"
      w

ordinalsOk : Bool -> Int -> Int -> List CField -> Bool
ordinalsOk _ _ _ [] = True
ordinalsOk literal pos prev ((CField _ o _) :: rest) =
  o >= 0
    && (if literal then o == pos else o > prev)
    && ordinalsOk literal (pos + 1) o rest

fieldOrdinalText : CField -> String
fieldOrdinalText (CField k o _) = "\{k}@\{intToString o}"

noteRecordBad : Ctx -> String -> String -> Walk -> Walk
noteRecordBad (Ctx _ _ _ binding) node why (Walk seen found bad calls) =
  Walk seen found ("record: \{node} \{why} [in \{binding}]" :: bad) calls

-- The mode the head's defined arity gives the arguments, or the shape fault.
noteCall : Ctx -> CallScope -> CExpr -> List CExpr -> CallSite -> Walk -> Walk
noteCall ctx _ _ [] _ w = noteCallBad ctx "application with no arguments" w
noteCall ctx _ (CApp _ _ _) _ _ w =
  noteCallBad ctx "application whose head is an application" w
noteCall (ctx@(Ctx _ _ env _)) scope hd args (CallSite mode _) w =
  let n = listLen args
  let arity = definedArityOf env scope hd
  if sameMode (callModeFor arity n) mode then
    w
  else match arity
    Some k =>
      noteCallBad
        ctx
        "\{headText hd} applied to \{intToString n} of \{intToString k}, stamped \{callModeSexp mode}"
        w
    None =>
      noteCallBad
        ctx
        "\{headText hd} has no static arity, stamped \{callModeSexp mode}"
        w

sameMode : CallMode -> CallMode -> Bool
sameMode CallExact CallExact = True
sameMode (CallPartial a) (CallPartial b) = a == b
sameMode (CallOver a) (CallOver b) = a == b
sameMode CallDynamic CallDynamic = True
sameMode _ _ = False

noteCallBad : Ctx -> String -> Walk -> Walk
noteCallBad (Ctx _ _ _ binding) why (Walk seen found bad calls) =
  Walk seen found bad ("call: \{why} [in \{binding}]" :: calls)

headText : CExpr -> String
headText (CVar x _) = x
headText (CMethod name _ _ _ _ _) = "method \{name}"
headText (CDict name _) = "\{name} (constrained)"
headText (CLam _ _) = "a lambda"
headText _ = "an expression"

noteVar : Ctx -> CallScope -> String -> Walk -> Walk
noteVar (Ctx backend top _ binding) scope x (w@(Walk seen found bad calls)) =
  if omHasKey x scope || omHasKey x seen then
    w
  else match unprovidedOn backend x
    None => w
    Some (kind, why) =>
      if isProgramName top x then
        w
      else
        Walk
          (omInsert x () seen)
          (ExternFinding x backend kind why binding :: found)
          bad
          calls

walkList : Ctx -> CallScope -> List CExpr -> Walk -> Walk
walkList _ _ [] w = w
walkList ctx scope (e :: rest) w = walkList ctx scope rest (walkE ctx scope e w)

walkFields : Ctx -> CallScope -> List CField -> Walk -> Walk
walkFields _ _ [] w = w
walkFields ctx scope ((CField _ _ e) :: rest) w =
  walkFields ctx scope rest (walkE ctx scope e w)

walkLocalBinds : Ctx -> CallScope -> List CBind -> Walk -> Walk
walkLocalBinds _ _ [] w = w
walkLocalBinds ctx scope ((CBind _ clauses _) :: rest) w =
  walkLocalBinds ctx scope rest (walkClauses ctx scope clauses w)

-- An arm's pattern scopes over its guards and body; a `Pat <- e` guard's
-- pattern scopes over the guards after it and the body.
walkArms : Ctx -> CallScope -> List CArm -> Walk -> Walk
walkArms _ _ [] w = w
walkArms ctx scope ((CArm pat guards body) :: rest) w =
  walkArms
    ctx
    scope
    rest
    (walkGuarded ctx (bindPatScope pat scope) guards body w)

walkGuarded : Ctx -> CallScope -> List CGuard -> CExpr -> Walk -> Walk
walkGuarded ctx scope [] body w = walkE ctx scope body w
walkGuarded ctx scope ((CGBool c) :: rest) body w =
  walkGuarded ctx scope rest body (walkE ctx scope c w)
walkGuarded ctx scope ((CGBind pat e) :: rest) body w =
  walkGuarded ctx (bindPatScope pat scope) rest body (walkE ctx scope e w)

walkStmts : Ctx -> CallScope -> List CStmt -> Walk -> Walk
walkStmts _ _ [] w = w
walkStmts ctx scope ((CSExpr e) :: rest) w =
  walkStmts ctx scope rest (walkE ctx scope e w)
walkStmts ctx scope ((CSLet recF pat e) :: rest) w =
  let inner = bindLetScope pat e scope
  walkStmts ctx inner rest (walkE ctx (if recF then inner else scope) e w)
walkStmts ctx scope ((CSAssign _ e) :: rest) w =
  walkStmts ctx scope rest (walkE ctx scope e w)

-- ── the tail check ───────────────────────────────────────────────────────────
-- One line per application whose tail flag disagrees with its position, in
-- program order; empty for a program `core_ir_lower.markTailSites` flagged.
-- The walk states the position rules itself rather than calling the pass that
-- applies them, so the two can disagree.  Tail position starts at the body of a
-- clause with a parameter and of a lambda, and passes through the branches of
-- an `if`, the arms of a match, the body of a `let` or let-group and the last
-- statement of a block.
export
validateTails : CProgram -> List String
validateTails (CProgram groups _ _ impls) =
  reverseL (tailImpls impls (tailBinds groups []))

export
renderTailRefusal : List String -> String
renderTailRefusal bad = joinWith "\n" bad

tailBinds : List CBind -> List String -> List String
tailBinds [] acc = acc
tailBinds ((CBind name clauses _) :: rest) acc =
  tailBinds rest (tailClauses name clauses acc)

tailClauses : String -> List CClause -> List String -> List String
tailClauses _ [] acc = acc
tailClauses b ((CClause pats body) :: rest) acc =
  tailClauses b rest (tailE b (isNonEmptyL pats) body acc)

tailImpls : List CImplEntry -> List String -> List String
tailImpls [] acc = acc
tailImpls ((CImplEntry method _ _ body) :: rest) acc =
  tailImpls rest (tailImplBody "impl \{method}" body acc)

tailImplBody : String -> CImplBody -> List String -> List String
tailImplBody b (CImplTagged tag _ _ _ pats body) acc =
  tailE "\{b}@\{tag}" (isNonEmptyL pats) body acc
tailImplBody b (CImplDefault _ tag _ _ pats body) acc =
  tailE "\{b}@\{tag}" (isNonEmptyL pats) body acc

-- `b` is the top-level binding being read; `tl` is whether `e` is in tail
-- position.  No catch-all arm.
tailE : String -> Bool -> CExpr -> List String -> List String
tailE b tl (CApp f args (CallSite mode flag)) acc =
  tailList b args (tailE b False f (tailCallNote b tl f mode flag acc))
tailE _ _ (CVar _ _) acc = acc
tailE _ _ (CLit _) acc = acc
tailE b _ (CLam _ body) acc = tailE b True body acc
tailE b tl (CLet _ _ rhs body) acc = tailE b tl body (tailE b False rhs acc)
tailE b tl (CLetGroup binds body) acc =
  tailE b tl body (tailLocalBinds b binds acc)
tailE b tl (CMatch scrut arms) acc =
  tailArms b tl arms (tailE b False scrut acc)
tailE b tl (CDecision scrut arms _) acc =
  tailArms b tl arms (tailE b False scrut acc)
tailE b tl (CIf c t f) acc = tailE b tl f (tailE b tl t (tailE b False c acc))
tailE b _ (CBinPrim _ l r _ _) acc = tailList b [l, r] acc
tailE b _ (CUnOp _ x) acc = tailE b False x acc
tailE b _ (CTuple es) acc = tailList b es acc
tailE b _ (CList es) acc = tailList b es acc
tailE b _ (CRecord _ fields) acc = tailFields b fields acc
tailE b _ (CFieldAccess x _ _ _) acc = tailE b False x acc
tailE b _ (CRecordUpdate _ base fields) acc =
  tailFields b fields (tailE b False base acc)
tailE b _ (CVariantUpdate _ base fields) acc =
  tailFields b fields (tailE b False base acc)
tailE b _ (CArray es) acc = tailList b es acc
tailE b _ (CRangeList lo hi _) acc = tailList b [lo, hi] acc
tailE b _ (CRangeArray lo hi _) acc = tailList b [lo, hi] acc
tailE b _ (CIndex a i) acc = tailList b [a, i] acc
tailE b _ (CSlice a lo hi _) acc = tailList b [a, lo, hi] acc
tailE b _ (CStringIndex a i) acc = tailList b [a, i] acc
tailE b _ (CStringSlice a lo hi _) acc = tailList b [a, lo, hi] acc
tailE b _ (CListIndex a i) acc = tailList b [a, i] acc
tailE b _ (CListSlice a lo hi _) acc = tailList b [a, lo, hi] acc
tailE b tl (CBlock stmts) acc = tailStmts b tl stmts acc
tailE _ _ (CMethod _ _ _ _ _ _) acc = acc
tailE _ _ (CDict _ _) acc = acc

tailCallNote : String ->
  Bool ->
  CExpr ->
  CallMode ->
  Bool ->
  List String ->
  List String
tailCallNote b tl hd mode flag acc =
  if flag && not tl then
    "tail: \{headText hd} is flagged as a tail call outside tail position [in \{b}]"
      :: acc
  else if flag && isPartialCall mode then
    "tail: \{headText hd} is flagged as a tail call but is a partial application \{callModeSexp mode} [in \{b}]"
      :: acc
  else if tl && not flag && not (isPartialCall mode) then
    "tail: \{headText hd} is in tail position, stamped \{callModeSexp mode}, but not flagged [in \{b}]"
      :: acc
  else
    acc

isPartialCall : CallMode -> Bool
isPartialCall (CallPartial _) = True
isPartialCall _ = False

tailList : String -> List CExpr -> List String -> List String
tailList _ [] acc = acc
tailList b (e :: rest) acc = tailList b rest (tailE b False e acc)

tailFields : String -> List CField -> List String -> List String
tailFields _ [] acc = acc
tailFields b ((CField _ _ e) :: rest) acc =
  tailFields b rest (tailE b False e acc)

tailLocalBinds : String -> List CBind -> List String -> List String
tailLocalBinds _ [] acc = acc
tailLocalBinds b ((CBind _ clauses _) :: rest) acc =
  tailLocalBinds b rest (tailClauses b clauses acc)

tailArms : String -> Bool -> List CArm -> List String -> List String
tailArms _ _ [] acc = acc
tailArms b tl ((CArm _ guards body) :: rest) acc =
  tailArms b tl rest (tailE b tl body (tailGuards b guards acc))

tailGuards : String -> List CGuard -> List String -> List String
tailGuards _ [] acc = acc
tailGuards b ((CGBool c) :: rest) acc = tailGuards b rest (tailE b False c acc)
tailGuards b ((CGBind _ e) :: rest) acc =
  tailGuards b rest (tailE b False e acc)

tailStmts : String -> Bool -> List CStmt -> List String -> List String
tailStmts _ _ [] acc = acc
tailStmts b tl [CSExpr e] acc = tailE b tl e acc
tailStmts b tl (st :: rest) acc = tailStmts b tl rest (tailStmt b st acc)

tailStmt : String -> CStmt -> List String -> List String
tailStmt b (CSExpr e) acc = tailE b False e acc
tailStmt b (CSLet _ _ e) acc = tailE b False e acc
tailStmt b (CSAssign _ e) acc = tailE b False e acc
# DESUGAR
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "CField" true) (mem "CArm" true) (mem "CGuard" true) (mem "CStmt" true) (mem "CBind" true) (mem "CClause" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CProgram" true) (mem "CallMode" true) (mem "CallSite" true))))
(DUse false (UseGroup ("ir" "core_ir_lower") ((mem "ArityEnv" false) (mem "CallScope" false) (mem "bindGroupScope" false) (mem "bindLetScope" false) (mem "bindPatScope" false) (mem "bindPatsScope" false) (mem "callModeFor" false) (mem "definedArityOf" false) (mem "entryArityRow" false) (mem "programArities" false))))
(DUse false (UseGroup ("ir" "core_ir_sexp") ((mem "callModeSexp" false))))
(DUse false (UseGroup ("backend" "extern_catalog") ((mem "Disposition" true) (mem "GapKind" false) (mem "catalogRow" false) (mem "gapKindName" false) (mem "rowLlvm" false) (mem "rowWasm" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omHasKey" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "isNonEmptyL" false) (mem "joinWith" false) (mem "listLen" false) (mem "reverseL" false))))
(DData Public "Backend" () ((variant "LlvmBackend" (ConPos)) (variant "WasmBackend" (ConPos))) ())
(DTypeSig true "backendName" (TyFun (TyCon "Backend") (TyCon "String")))
(DFunDef false "backendName" ((PCon "LlvmBackend")) (ELit (LString "llvm")))
(DFunDef false "backendName" ((PCon "WasmBackend")) (ELit (LString "wasm")))
(DData Public "ExternFinding" () ((variant "ExternFinding" (ConPos (TyCon "String") (TyCon "Backend") (TyCon "GapKind") (TyCon "String") (TyCon "String")))) ())
(DTypeSig true "findingExtern" (TyFun (TyCon "ExternFinding") (TyCon "String")))
(DFunDef false "findingExtern" ((PCon "ExternFinding" (PVar "name") PWild PWild PWild PWild)) (EVar "name"))
(DTypeSig true "findingBinding" (TyFun (TyCon "ExternFinding") (TyCon "String")))
(DFunDef false "findingBinding" ((PCon "ExternFinding" PWild PWild PWild PWild (PVar "binding"))) (EVar "binding"))
(DTypeSig true "unprovidedOn" (TyFun (TyCon "Backend") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "GapKind") (TyCon "String"))))))
(DFunDef false "unprovidedOn" ((PCon "LlvmBackend") (PVar "name")) (EMatch (EApp (EVar "catalogRow") (EVar "name")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "notProvidedOf") (EApp (EVar "rowLlvm") (EVar "r")))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "unprovidedOn" ((PCon "WasmBackend") (PVar "name")) (EMatch (EApp (EVar "catalogRow") (EVar "name")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "notProvidedOf") (EApp (EVar "rowWasm") (EVar "r")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "notProvidedOf" (TyFun (TyApp (TyCon "Disposition") (TyVar "f")) (TyApp (TyCon "Option") (TyTuple (TyCon "GapKind") (TyCon "String")))))
(DFunDef false "notProvidedOf" ((PCon "NotProvided" (PVar "kind") (PVar "why"))) (EApp (EVar "Some") (ETuple (EVar "kind") (EVar "why"))))
(DFunDef false "notProvidedOf" (PWild) (EVar "None"))
(DTypeSig true "isUnprovidedOn" (TyFun (TyCon "Backend") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isUnprovidedOn" ((PVar "backend") (PVar "name")) (EApp (EVar "isSome") (EApp (EApp (EVar "unprovidedOn") (EVar "backend")) (EVar "name"))))
(DTypeSig true "validateExterns" (TyFun (TyCon "Backend") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "ExternFinding"))))))
(DFunDef false "validateExterns" ((PVar "backend") (PVar "runtimeExterns") (PVar "prog")) (EBlock (DoLet false false PWild (EApp (EVar "refuseMissingRows") (EVar "runtimeExterns"))) (DoExpr (EMatch (EApp (EApp (EVar "walkProgram") (EVar "backend")) (EVar "prog")) (arm (PCon "Walk" PWild (PVar "found") PWild PWild) () (EApp (EVar "reverseL") (EVar "found")))))))
(DTypeSig true "validateRecords" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateRecords" ((PVar "prog")) (EMatch (EApp (EApp (EVar "walkProgram") (EVar "LlvmBackend")) (EVar "prog")) (arm (PCon "Walk" PWild PWild (PVar "bad") PWild) () (EApp (EVar "reverseL") (EVar "bad")))))
(DTypeSig true "renderRecordRefusal" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "renderRecordRefusal" ((PVar "bad")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "bad")))
(DTypeSig true "validateCalls" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateCalls" ((PAs "prog" (PCon "CProgram" PWild PWild PWild (PVar "impls")))) (EMatch (EApp (EApp (EVar "walkProgram") (EVar "LlvmBackend")) (EVar "prog")) (arm (PCon "Walk" PWild PWild PWild (PVar "bad")) () (EBinOp "++" (EApp (EVar "reverseL") (EVar "bad")) (EApp (EApp (EApp (EVar "splitGroupFaults") (EVar "impls")) (EVar "omEmpty")) (EListLit))))))
(DTypeSig false "splitGroupFaults" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "splitGroupFaults" ((PList) PWild (PVar "acc")) (EApp (EVar "reverseL") (EVar "acc")))
(DFunDef false "splitGroupFaults" ((PCons (PAs "ent" (PCon "CImplEntry" (PVar "method") PWild PWild (PVar "body"))) (PVar "rest")) (PVar "seen") (PVar "acc")) (EBlock (DoLet false false (PTuple (PVar "key") (PVar "n")) (EApp (EVar "entryArityRow") (EVar "ent"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "seen")) (arm (PCon "Some" (PVar "k")) () (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EApp (EApp (EApp (EVar "splitGroupFaults") (EVar "rest")) (EVar "seen")) (EVar "acc")) (EApp (EApp (EApp (EVar "splitGroupFaults") (EVar "rest")) (EVar "seen")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "call: impl entry takes ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " value parameters, the first entry of its group "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString " [in impl "))) (EApp (EVar "display") (EVar "method"))) (ELit (LString "@"))) (EApp (EVar "display") (EApp (EVar "implBodyTag") (EVar "body")))) (ELit (LString "]"))) (EVar "acc"))))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "splitGroupFaults") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "n")) (EVar "seen"))) (EVar "acc")))))))
(DTypeSig false "implBodyTag" (TyFun (TyCon "CImplBody") (TyCon "String")))
(DFunDef false "implBodyTag" ((PCon "CImplTagged" (PVar "tag") PWild PWild PWild PWild PWild)) (EVar "tag"))
(DFunDef false "implBodyTag" ((PCon "CImplDefault" PWild (PVar "tag") PWild PWild PWild PWild)) (EVar "tag"))
(DTypeSig true "renderCallRefusal" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "renderCallRefusal" ((PVar "bad")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "bad")))
(DTypeSig true "missingCatalogRows" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "missingCatalogRows" ((PVar "names")) (EApp (EApp (EVar "filter") (ELam ((PVar "n")) (EApp (EVar "isNone") (EApp (EVar "catalogRow") (EVar "n"))))) (EVar "names")))
(DTypeSig true "missingRowsMessage" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "missingRowsMessage" ((PVar "missing")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "quoteName")) (EVar "missing")))) (DoExpr (EBinOp "++" (EBinOp "++" (ELit (LString "internal error: runtime extern ")) (EApp (EVar "display") (EVar "names"))) (ELit (LString " has no row in the extern catalog (compiler/backend/extern_catalog.mdk)"))))))
(DTypeSig false "quoteName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "quoteName" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EVar "n")) (ELit (LString "'"))))
(DTypeSig false "refuseMissingRows" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))
(DFunDef false "refuseMissingRows" ((PVar "names")) (EMatch (EApp (EVar "missingCatalogRows") (EVar "names")) (arm (PList) () (ELit LUnit)) (arm (PVar "missing") () (EApp (EVar "panic") (EApp (EVar "missingRowsMessage") (EVar "missing"))))))
(DTypeSig true "renderExternFinding" (TyFun (TyCon "ExternFinding") (TyCon "String")))
(DFunDef false "renderExternFinding" ((PCon "ExternFinding" (PVar "name") (PVar "backend") (PVar "kind") (PVar "why") (PVar "binding"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "backendName") (EVar "backend")))) (ELit (LString ": runtime extern '"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "' is not available on the "))) (EApp (EVar "display") (EApp (EVar "backendName") (EVar "backend")))) (ELit (LString " backend ("))) (EApp (EVar "display") (EApp (EVar "gapKindName") (EVar "kind")))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "why"))) (ELit (LString ") [in "))) (EApp (EVar "display") (EVar "binding"))) (ELit (LString "]"))))
(DTypeSig true "renderExternRefusal" (TyFun (TyApp (TyCon "List") (TyCon "ExternFinding")) (TyCon "String")))
(DFunDef false "renderExternRefusal" ((PVar "findings")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EVar "map") (EVar "renderExternFinding")) (EVar "findings"))))
(DTypeSig true "unrefusedExternMessage" (TyFun (TyCon "Backend") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "unrefusedExternMessage" ((PVar "backend") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "internal error: the ")) (EApp (EVar "display") (EApp (EVar "backendName") (EVar "backend")))) (ELit (LString " emitter reached runtime extern '"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "', which it does not lower, without a refusal from validateExterns (compiler/backend/core_validate.mdk)"))))
(DTypeSig false "programNames" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "programNames" ((PList) (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "programNames" ((PList) (PCons (PTuple (PVar "ctor") PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "programNames") (EListLit)) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "ctor")) (ELit LUnit)) (EVar "acc"))))
(DFunDef false "programNames" ((PCons (PCon "CBind" (PVar "name") PWild PWild) (PVar "rest")) (PVar "ctors") (PVar "acc")) (EApp (EApp (EApp (EVar "programNames") (EVar "rest")) (EVar "ctors")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EVar "acc"))))
(DTypeSig false "isProgramName" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isProgramName" ((PVar "top") (PVar "x")) (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "top")) (EApp (EApp (EVar "omHasKey") (EBinOp "++" (ELit (LString "core__")) (EVar "x"))) (EVar "top"))))
(DData Private "Walk" () ((variant "Walk" (ConPos (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "ExternFinding")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))) ())
(DTypeSig false "noFindings" (TyCon "Walk"))
(DFunDef false "noFindings" () (EApp (EApp (EApp (EApp (EVar "Walk") (EVar "omEmpty")) (EListLit)) (EListLit)) (EListLit)))
(DData Private "Ctx" () ((variant "Ctx" (ConPos (TyCon "Backend") (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "ArityEnv") (TyCon "String")))) ())
(DTypeSig false "walkProgram" (TyFun (TyCon "Backend") (TyFun (TyCon "CProgram") (TyCon "Walk"))))
(DFunDef false "walkProgram" ((PVar "backend") (PAs "prog" (PCon "CProgram" (PVar "groups") (PVar "ctors") PWild (PVar "impls")))) (EBlock (DoLet false false (PVar "top") (EApp (EApp (EApp (EVar "programNames") (EVar "groups")) (EVar "ctors")) (EVar "omEmpty"))) (DoLet false false (PVar "env") (EApp (EVar "programArities") (EVar "prog"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "walkImpls") (EVar "backend")) (EVar "top")) (EVar "env")) (EVar "impls")) (EApp (EApp (EApp (EApp (EApp (EVar "walkBinds") (EVar "backend")) (EVar "top")) (EVar "env")) (EVar "groups")) (EVar "noFindings"))))))
(DTypeSig false "walkBinds" (TyFun (TyCon "Backend") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "ArityEnv") (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyCon "Walk") (TyCon "Walk")))))))
(DFunDef false "walkBinds" (PWild PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkBinds" ((PVar "backend") (PVar "top") (PVar "env") (PCons (PCon "CBind" (PVar "name") (PVar "clauses") PWild) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EApp (EVar "walkBinds") (EVar "backend")) (EVar "top")) (EVar "env")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkClauses") (EApp (EApp (EApp (EApp (EVar "Ctx") (EVar "backend")) (EVar "top")) (EVar "env")) (EVar "name"))) (EVar "omEmpty")) (EVar "clauses")) (EVar "w"))))
(DTypeSig false "walkImpls" (TyFun (TyCon "Backend") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "ArityEnv") (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "Walk") (TyCon "Walk")))))))
(DFunDef false "walkImpls" (PWild PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkImpls" ((PVar "backend") (PVar "top") (PVar "env") (PCons (PCon "CImplEntry" (PVar "method") PWild PWild (PVar "body")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EApp (EVar "walkImpls") (EVar "backend")) (EVar "top")) (EVar "env")) (EVar "rest")) (EApp (EApp (EApp (EVar "walkImplBody") (EApp (EApp (EApp (EApp (EVar "Ctx") (EVar "backend")) (EVar "top")) (EVar "env")) (EBinOp "++" (EBinOp "++" (ELit (LString "impl ")) (EApp (EVar "display") (EVar "method"))) (ELit (LString ""))))) (EVar "body")) (EVar "w"))))
(DTypeSig false "walkImplBody" (TyFun (TyCon "Ctx") (TyFun (TyCon "CImplBody") (TyFun (TyCon "Walk") (TyCon "Walk")))))
(DFunDef false "walkImplBody" ((PCon "Ctx" (PVar "backend") (PVar "top") (PVar "env") (PVar "binding")) (PCon "CImplTagged" (PVar "tag") PWild PWild PWild (PVar "pats") (PVar "body")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EApp (EApp (EApp (EApp (EVar "Ctx") (EVar "backend")) (EVar "top")) (EVar "env")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "binding"))) (ELit (LString "@"))) (EApp (EVar "display") (EVar "tag"))) (ELit (LString ""))))) (EApp (EApp (EVar "bindPatsScope") (EVar "pats")) (EVar "omEmpty"))) (EVar "body")) (EVar "w")))
(DFunDef false "walkImplBody" ((PCon "Ctx" (PVar "backend") (PVar "top") (PVar "env") (PVar "binding")) (PCon "CImplDefault" PWild (PVar "tag") PWild PWild (PVar "pats") (PVar "body")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EApp (EApp (EApp (EApp (EVar "Ctx") (EVar "backend")) (EVar "top")) (EVar "env")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "binding"))) (ELit (LString "@"))) (EApp (EVar "display") (EVar "tag"))) (ELit (LString ""))))) (EApp (EApp (EVar "bindPatsScope") (EVar "pats")) (EVar "omEmpty"))) (EVar "body")) (EVar "w")))
(DTypeSig false "walkClauses" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkClauses" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkClauses" ((PVar "ctx") (PVar "scope") (PCons (PCon "CClause" (PVar "pats") (PVar "body")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkClauses") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EApp (EApp (EVar "bindPatsScope") (EVar "pats")) (EVar "scope"))) (EVar "body")) (EVar "w"))))
(DTypeSig false "walkE" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyCon "CExpr") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CVar" (PVar "x") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "noteVar") (EVar "ctx")) (EVar "scope")) (EVar "x")) (EVar "w")))
(DFunDef false "walkE" (PWild PWild (PCon "CLit" PWild) (PVar "w")) (EVar "w"))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CApp" (PVar "f") (PVar "args") (PVar "site")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "args")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "f")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteCall") (EVar "ctx")) (EVar "scope")) (EVar "f")) (EVar "args")) (EVar "site")) (EVar "w")))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CLam" (PVar "pats") (PVar "body")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EApp (EApp (EVar "bindPatsScope") (EVar "pats")) (EVar "scope"))) (EVar "body")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CLet" (PVar "recF") (PVar "pat") (PVar "rhs") (PVar "body")) (PVar "w")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EApp (EVar "bindLetScope") (EVar "pat")) (EVar "rhs")) (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "inner")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EIf (EVar "recF") (EVar "inner") (EVar "scope"))) (EVar "rhs")) (EVar "w"))))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CLetGroup" (PVar "binds") (PVar "body")) (PVar "w")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindGroupScope") (EVar "binds")) (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "inner")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "walkLocalBinds") (EVar "ctx")) (EVar "inner")) (EVar "binds")) (EVar "w"))))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CMatch" (PVar "scrut") (PVar "arms")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "ctx")) (EVar "scope")) (EVar "arms")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "scrut")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "ctx")) (EVar "scope")) (EVar "arms")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "scrut")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "c") (EVar "t") (EVar "f"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CBinPrim" PWild (PVar "l") (PVar "r") PWild PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "l") (EVar "r"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CUnOp" PWild (PVar "x")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "x")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CTuple" (PVar "es")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "es")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CList" (PVar "es")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "es")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CRecord" (PVar "name") (PVar "fields")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "ctx")) (EVar "scope")) (EVar "fields")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteRecord") (EVar "ctx")) (ELit (LString "CRecord"))) (EVar "name")) (EVar "True")) (EVar "fields")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CFieldAccess" (PVar "x") (PVar "label") (PVar "name") (PVar "ord")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "x")) (EApp (EApp (EApp (EApp (EApp (EVar "noteAccess") (EVar "ctx")) (EVar "label")) (EVar "name")) (EVar "ord")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "ctx")) (EVar "scope")) (EVar "fields")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "base")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteRecord") (EVar "ctx")) (ELit (LString "CRecordUpdate"))) (EVar "name")) (EVar "False")) (EVar "fields")) (EVar "w")))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "ctx")) (EVar "scope")) (EVar "fields")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "base")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteRecord") (EVar "ctx")) (ELit (LString "CVariantUpdate"))) (EVar "con")) (EVar "False")) (EVar "fields")) (EVar "w")))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CArray" (PVar "es")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "es")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CIndex" (PVar "a") (PVar "i")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "i"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CStringIndex" (PVar "a") (PVar "i")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "i"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CListIndex" (PVar "a") (PVar "i")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "i"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CBlock" (PVar "stmts")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "ctx")) (EVar "scope")) (EVar "stmts")) (EVar "w")))
(DFunDef false "walkE" (PWild PWild (PCon "CMethod" PWild PWild PWild PWild PWild PWild) (PVar "w")) (EVar "w"))
(DFunDef false "walkE" (PWild PWild (PCon "CDict" PWild PWild) (PVar "w")) (EVar "w"))
(DTypeSig false "noteAccess" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Walk") (TyCon "Walk")))))))
(DFunDef false "noteAccess" ((PVar "ctx") (PVar "label") (PVar "name") (PVar "ord") (PVar "w")) (EIf (EBinOp "||" (EBinOp ">=" (EVar "ord") (ELit (LInt 0))) (EBinOp "==" (EVar "label") (ELit (LString "value")))) (EVar "w") (EApp (EApp (EApp (EApp (EVar "noteRecordBad") (EVar "ctx")) (ELit (LString "CFieldAccess"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "."))) (EApp (EVar "display") (EVar "label"))) (ELit (LString ": unstamped field ordinal")))) (EVar "w"))))
(DTypeSig false "noteRecord" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))))
(DFunDef false "noteRecord" ((PVar "ctx") (PVar "node") (PVar "name") (PVar "literal") (PVar "fields") (PVar "w")) (EIf (EApp (EApp (EApp (EApp (EVar "ordinalsOk") (EVar "literal")) (ELit (LInt 0))) (EUnOp "-" (ELit (LInt 1)))) (EVar "fields")) (EVar "w") (EApp (EApp (EApp (EApp (EVar "noteRecordBad") (EVar "ctx")) (EVar "node")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString ": field ordinals ["))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "fieldOrdinalText")) (EVar "fields"))))) (ELit (LString "] are not "))) (EApp (EVar "display") (EIf (EVar "literal") (ELit (LString "the declared positions")) (ELit (LString "strictly ascending"))))) (ELit (LString "")))) (EVar "w"))))
(DTypeSig false "ordinalsOk" (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyCon "Bool"))))))
(DFunDef false "ordinalsOk" (PWild PWild PWild (PList)) (EVar "True"))
(DFunDef false "ordinalsOk" ((PVar "literal") (PVar "pos") (PVar "prev") (PCons (PCon "CField" PWild (PVar "o") PWild) (PVar "rest"))) (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "o") (ELit (LInt 0))) (EIf (EVar "literal") (EBinOp "==" (EVar "o") (EVar "pos")) (EBinOp ">" (EVar "o") (EVar "prev")))) (EApp (EApp (EApp (EApp (EVar "ordinalsOk") (EVar "literal")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "o")) (EVar "rest"))))
(DTypeSig false "fieldOrdinalText" (TyFun (TyCon "CField") (TyCon "String")))
(DFunDef false "fieldOrdinalText" ((PCon "CField" (PVar "k") (PVar "o") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "k"))) (ELit (LString "@"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "o")))) (ELit (LString ""))))
(DTypeSig false "noteRecordBad" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "noteRecordBad" ((PCon "Ctx" PWild PWild PWild (PVar "binding")) (PVar "node") (PVar "why") (PCon "Walk" (PVar "seen") (PVar "found") (PVar "bad") (PVar "calls"))) (EApp (EApp (EApp (EApp (EVar "Walk") (EVar "seen")) (EVar "found")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "record: ")) (EApp (EVar "display") (EVar "node"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "why"))) (ELit (LString " [in "))) (EApp (EVar "display") (EVar "binding"))) (ELit (LString "]"))) (EVar "bad"))) (EVar "calls")))
(DTypeSig false "noteCall" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyCon "CExpr") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyFun (TyCon "CallSite") (TyFun (TyCon "Walk") (TyCon "Walk"))))))))
(DFunDef false "noteCall" ((PVar "ctx") PWild PWild (PList) PWild (PVar "w")) (EApp (EApp (EApp (EVar "noteCallBad") (EVar "ctx")) (ELit (LString "application with no arguments"))) (EVar "w")))
(DFunDef false "noteCall" ((PVar "ctx") PWild (PCon "CApp" PWild PWild PWild) PWild PWild (PVar "w")) (EApp (EApp (EApp (EVar "noteCallBad") (EVar "ctx")) (ELit (LString "application whose head is an application"))) (EVar "w")))
(DFunDef false "noteCall" ((PAs "ctx" (PCon "Ctx" PWild PWild (PVar "env") PWild)) (PVar "scope") (PVar "hd") (PVar "args") (PCon "CallSite" (PVar "mode") PWild) (PVar "w")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "listLen") (EVar "args"))) (DoLet false false (PVar "arity") (EApp (EApp (EApp (EVar "definedArityOf") (EVar "env")) (EVar "scope")) (EVar "hd"))) (DoExpr (EIf (EApp (EApp (EVar "sameMode") (EApp (EApp (EVar "callModeFor") (EVar "arity")) (EVar "n"))) (EVar "mode")) (EVar "w") (EMatch (EVar "arity") (arm (PCon "Some" (PVar "k")) () (EApp (EApp (EApp (EVar "noteCallBad") (EVar "ctx")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "headText") (EVar "hd")))) (ELit (LString " applied to "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " of "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString ", stamped "))) (EApp (EVar "display") (EApp (EVar "callModeSexp") (EVar "mode")))) (ELit (LString "")))) (EVar "w"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "noteCallBad") (EVar "ctx")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "headText") (EVar "hd")))) (ELit (LString " has no static arity, stamped "))) (EApp (EVar "display") (EApp (EVar "callModeSexp") (EVar "mode")))) (ELit (LString "")))) (EVar "w"))))))))
(DTypeSig false "sameMode" (TyFun (TyCon "CallMode") (TyFun (TyCon "CallMode") (TyCon "Bool"))))
(DFunDef false "sameMode" ((PCon "CallExact") (PCon "CallExact")) (EVar "True"))
(DFunDef false "sameMode" ((PCon "CallPartial" (PVar "a")) (PCon "CallPartial" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "sameMode" ((PCon "CallOver" (PVar "a")) (PCon "CallOver" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "sameMode" ((PCon "CallDynamic") (PCon "CallDynamic")) (EVar "True"))
(DFunDef false "sameMode" (PWild PWild) (EVar "False"))
(DTypeSig false "noteCallBad" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "Walk") (TyCon "Walk")))))
(DFunDef false "noteCallBad" ((PCon "Ctx" PWild PWild PWild (PVar "binding")) (PVar "why") (PCon "Walk" (PVar "seen") (PVar "found") (PVar "bad") (PVar "calls"))) (EApp (EApp (EApp (EApp (EVar "Walk") (EVar "seen")) (EVar "found")) (EVar "bad")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "call: ")) (EApp (EVar "display") (EVar "why"))) (ELit (LString " [in "))) (EApp (EVar "display") (EVar "binding"))) (ELit (LString "]"))) (EVar "calls"))))
(DTypeSig false "headText" (TyFun (TyCon "CExpr") (TyCon "String")))
(DFunDef false "headText" ((PCon "CVar" (PVar "x") PWild)) (EVar "x"))
(DFunDef false "headText" ((PCon "CMethod" (PVar "name") PWild PWild PWild PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "method ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "headText" ((PCon "CDict" (PVar "name") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " (constrained)"))))
(DFunDef false "headText" ((PCon "CLam" PWild PWild)) (ELit (LString "a lambda")))
(DFunDef false "headText" (PWild) (ELit (LString "an expression")))
(DTypeSig false "noteVar" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyCon "String") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "noteVar" ((PCon "Ctx" (PVar "backend") (PVar "top") PWild (PVar "binding")) (PVar "scope") (PVar "x") (PAs "w" (PCon "Walk" (PVar "seen") (PVar "found") (PVar "bad") (PVar "calls")))) (EIf (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "scope")) (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "seen"))) (EVar "w") (EMatch (EApp (EApp (EVar "unprovidedOn") (EVar "backend")) (EVar "x")) (arm (PCon "None") () (EVar "w")) (arm (PCon "Some" (PTuple (PVar "kind") (PVar "why"))) () (EIf (EApp (EApp (EVar "isProgramName") (EVar "top")) (EVar "x")) (EVar "w") (EApp (EApp (EApp (EApp (EVar "Walk") (EApp (EApp (EApp (EVar "omInsert") (EVar "x")) (ELit LUnit)) (EVar "seen"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "ExternFinding") (EVar "x")) (EVar "backend")) (EVar "kind")) (EVar "why")) (EVar "binding")) (EVar "found"))) (EVar "bad")) (EVar "calls")))))))
(DTypeSig false "walkList" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkList" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkList" ((PVar "ctx") (PVar "scope") (PCons (PVar "e") (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DTypeSig false "walkFields" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkFields" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkFields" ((PVar "ctx") (PVar "scope") (PCons (PCon "CField" PWild PWild (PVar "e")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DTypeSig false "walkLocalBinds" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkLocalBinds" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkLocalBinds" ((PVar "ctx") (PVar "scope") (PCons (PCon "CBind" PWild (PVar "clauses") PWild) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkLocalBinds") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkClauses") (EVar "ctx")) (EVar "scope")) (EVar "clauses")) (EVar "w"))))
(DTypeSig false "walkArms" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkArms" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkArms" ((PVar "ctx") (PVar "scope") (PCons (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "ctx")) (EApp (EApp (EVar "bindPatScope") (EVar "pat")) (EVar "scope"))) (EVar "guards")) (EVar "body")) (EVar "w"))))
(DTypeSig false "walkGuarded" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyFun (TyCon "CExpr") (TyFun (TyCon "Walk") (TyCon "Walk")))))))
(DFunDef false "walkGuarded" ((PVar "ctx") (PVar "scope") (PList) (PVar "body") (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "body")) (EVar "w")))
(DFunDef false "walkGuarded" ((PVar "ctx") (PVar "scope") (PCons (PCon "CGBool" (PVar "c")) (PVar "rest")) (PVar "body") (PVar "w")) (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "c")) (EVar "w"))))
(DFunDef false "walkGuarded" ((PVar "ctx") (PVar "scope") (PCons (PCon "CGBind" (PVar "pat") (PVar "e")) (PVar "rest")) (PVar "body") (PVar "w")) (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "ctx")) (EApp (EApp (EVar "bindPatScope") (EVar "pat")) (EVar "scope"))) (EVar "rest")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DTypeSig false "walkStmts" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkStmts" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkStmts" ((PVar "ctx") (PVar "scope") (PCons (PCon "CSExpr" (PVar "e")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DFunDef false "walkStmts" ((PVar "ctx") (PVar "scope") (PCons (PCon "CSLet" (PVar "recF") (PVar "pat") (PVar "e")) (PVar "rest")) (PVar "w")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EApp (EVar "bindLetScope") (EVar "pat")) (EVar "e")) (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "ctx")) (EVar "inner")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EIf (EVar "recF") (EVar "inner") (EVar "scope"))) (EVar "e")) (EVar "w"))))))
(DFunDef false "walkStmts" ((PVar "ctx") (PVar "scope") (PCons (PCon "CSAssign" PWild (PVar "e")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DTypeSig true "validateTails" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateTails" ((PCon "CProgram" (PVar "groups") PWild PWild (PVar "impls"))) (EApp (EVar "reverseL") (EApp (EApp (EVar "tailImpls") (EVar "impls")) (EApp (EApp (EVar "tailBinds") (EVar "groups")) (EListLit)))))
(DTypeSig true "renderTailRefusal" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "renderTailRefusal" ((PVar "bad")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "bad")))
(DTypeSig false "tailBinds" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tailBinds" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailBinds" ((PCons (PCon "CBind" (PVar "name") (PVar "clauses") PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "tailBinds") (EVar "rest")) (EApp (EApp (EApp (EVar "tailClauses") (EVar "name")) (EVar "clauses")) (EVar "acc"))))
(DTypeSig false "tailClauses" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailClauses" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailClauses" ((PVar "b") (PCons (PCon "CClause" (PVar "pats") (PVar "body")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailClauses") (EVar "b")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EApp (EVar "isNonEmptyL") (EVar "pats"))) (EVar "body")) (EVar "acc"))))
(DTypeSig false "tailImpls" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tailImpls" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailImpls" ((PCons (PCon "CImplEntry" (PVar "method") PWild PWild (PVar "body")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "tailImpls") (EVar "rest")) (EApp (EApp (EApp (EVar "tailImplBody") (EBinOp "++" (EBinOp "++" (ELit (LString "impl ")) (EApp (EVar "display") (EVar "method"))) (ELit (LString "")))) (EVar "body")) (EVar "acc"))))
(DTypeSig false "tailImplBody" (TyFun (TyCon "String") (TyFun (TyCon "CImplBody") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailImplBody" ((PVar "b") (PCon "CImplTagged" (PVar "tag") PWild PWild PWild (PVar "pats") (PVar "body")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "b"))) (ELit (LString "@"))) (EApp (EVar "display") (EVar "tag"))) (ELit (LString "")))) (EApp (EVar "isNonEmptyL") (EVar "pats"))) (EVar "body")) (EVar "acc")))
(DFunDef false "tailImplBody" ((PVar "b") (PCon "CImplDefault" PWild (PVar "tag") PWild PWild (PVar "pats") (PVar "body")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "b"))) (ELit (LString "@"))) (EApp (EVar "display") (EVar "tag"))) (ELit (LString "")))) (EApp (EVar "isNonEmptyL") (EVar "pats"))) (EVar "body")) (EVar "acc")))
(DTypeSig false "tailE" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "CExpr") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CApp" (PVar "f") (PVar "args") (PCon "CallSite" (PVar "mode") (PVar "flag"))) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EVar "args")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "f")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailCallNote") (EVar "b")) (EVar "tl")) (EVar "f")) (EVar "mode")) (EVar "flag")) (EVar "acc")))))
(DFunDef false "tailE" (PWild PWild (PCon "CVar" PWild PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailE" (PWild PWild (PCon "CLit" PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CLam" PWild (PVar "body")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "True")) (EVar "body")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CLet" PWild PWild (PVar "rhs") (PVar "body")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "tl")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "rhs")) (EVar "acc"))))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CLetGroup" (PVar "binds") (PVar "body")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "tl")) (EVar "body")) (EApp (EApp (EApp (EVar "tailLocalBinds") (EVar "b")) (EVar "binds")) (EVar "acc"))))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CMatch" (PVar "scrut") (PVar "arms")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailArms") (EVar "b")) (EVar "tl")) (EVar "arms")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "scrut")) (EVar "acc"))))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailArms") (EVar "b")) (EVar "tl")) (EVar "arms")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "scrut")) (EVar "acc"))))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "tl")) (EVar "f")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "tl")) (EVar "t")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "c")) (EVar "acc")))))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CBinPrim" PWild (PVar "l") (PVar "r") PWild PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "l") (EVar "r"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CUnOp" PWild (PVar "x")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "x")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CTuple" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EVar "es")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CList" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EVar "es")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CRecord" PWild (PVar "fields")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailFields") (EVar "b")) (EVar "fields")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CFieldAccess" (PVar "x") PWild PWild PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "x")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CRecordUpdate" PWild (PVar "base") (PVar "fields")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailFields") (EVar "b")) (EVar "fields")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "base")) (EVar "acc"))))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CVariantUpdate" PWild (PVar "base") (PVar "fields")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailFields") (EVar "b")) (EVar "fields")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "base")) (EVar "acc"))))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CArray" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EVar "es")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "lo") (EVar "hi"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "lo") (EVar "hi"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CIndex" (PVar "a") (PVar "i")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "a") (EVar "i"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CStringIndex" (PVar "a") (PVar "i")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "a") (EVar "i"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CListIndex" (PVar "a") (PVar "i")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "a") (EVar "i"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CBlock" (PVar "stmts")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailStmts") (EVar "b")) (EVar "tl")) (EVar "stmts")) (EVar "acc")))
(DFunDef false "tailE" (PWild PWild (PCon "CMethod" PWild PWild PWild PWild PWild PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailE" (PWild PWild (PCon "CDict" PWild PWild) (PVar "acc")) (EVar "acc"))
(DTypeSig false "tailCallNote" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "CExpr") (TyFun (TyCon "CallMode") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "tailCallNote" ((PVar "b") (PVar "tl") (PVar "hd") (PVar "mode") (PVar "flag") (PVar "acc")) (EIf (EBinOp "&&" (EVar "flag") (EApp (EVar "not") (EVar "tl"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "tail: ")) (EApp (EVar "display") (EApp (EVar "headText") (EVar "hd")))) (ELit (LString " is flagged as a tail call outside tail position [in "))) (EApp (EVar "display") (EVar "b"))) (ELit (LString "]"))) (EVar "acc")) (EIf (EBinOp "&&" (EVar "flag") (EApp (EVar "isPartialCall") (EVar "mode"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "tail: ")) (EApp (EVar "display") (EApp (EVar "headText") (EVar "hd")))) (ELit (LString " is flagged as a tail call but is a partial application "))) (EApp (EVar "display") (EApp (EVar "callModeSexp") (EVar "mode")))) (ELit (LString " [in "))) (EApp (EVar "display") (EVar "b"))) (ELit (LString "]"))) (EVar "acc")) (EIf (EBinOp "&&" (EBinOp "&&" (EVar "tl") (EApp (EVar "not") (EVar "flag"))) (EApp (EVar "not") (EApp (EVar "isPartialCall") (EVar "mode")))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "tail: ")) (EApp (EVar "display") (EApp (EVar "headText") (EVar "hd")))) (ELit (LString " is in tail position, stamped "))) (EApp (EVar "display") (EApp (EVar "callModeSexp") (EVar "mode")))) (ELit (LString ", but not flagged [in "))) (EApp (EVar "display") (EVar "b"))) (ELit (LString "]"))) (EVar "acc")) (EVar "acc")))))
(DTypeSig false "isPartialCall" (TyFun (TyCon "CallMode") (TyCon "Bool")))
(DFunDef false "isPartialCall" ((PCon "CallPartial" PWild)) (EVar "True"))
(DFunDef false "isPartialCall" (PWild) (EVar "False"))
(DTypeSig false "tailList" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailList" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailList" ((PVar "b") (PCons (PVar "e") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "tailFields" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailFields" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailFields" ((PVar "b") (PCons (PCon "CField" PWild PWild (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailFields") (EVar "b")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "tailLocalBinds" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailLocalBinds" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailLocalBinds" ((PVar "b") (PCons (PCon "CBind" PWild (PVar "clauses") PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailLocalBinds") (EVar "b")) (EVar "rest")) (EApp (EApp (EApp (EVar "tailClauses") (EVar "b")) (EVar "clauses")) (EVar "acc"))))
(DTypeSig false "tailArms" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "tailArms" (PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailArms" ((PVar "b") (PVar "tl") (PCons (PCon "CArm" PWild (PVar "guards") (PVar "body")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailArms") (EVar "b")) (EVar "tl")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "tl")) (EVar "body")) (EApp (EApp (EApp (EVar "tailGuards") (EVar "b")) (EVar "guards")) (EVar "acc")))))
(DTypeSig false "tailGuards" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailGuards" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailGuards" ((PVar "b") (PCons (PCon "CGBool" (PVar "c")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailGuards") (EVar "b")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "c")) (EVar "acc"))))
(DFunDef false "tailGuards" ((PVar "b") (PCons (PCon "CGBind" PWild (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailGuards") (EVar "b")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "tailStmts" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "tailStmts" (PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailStmts" ((PVar "b") (PVar "tl") (PList (PCon "CSExpr" (PVar "e"))) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "tl")) (EVar "e")) (EVar "acc")))
(DFunDef false "tailStmts" ((PVar "b") (PVar "tl") (PCons (PVar "st") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailStmts") (EVar "b")) (EVar "tl")) (EVar "rest")) (EApp (EApp (EApp (EVar "tailStmt") (EVar "b")) (EVar "st")) (EVar "acc"))))
(DTypeSig false "tailStmt" (TyFun (TyCon "String") (TyFun (TyCon "CStmt") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailStmt" ((PVar "b") (PCon "CSExpr" (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "e")) (EVar "acc")))
(DFunDef false "tailStmt" ((PVar "b") (PCon "CSLet" PWild PWild (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "e")) (EVar "acc")))
(DFunDef false "tailStmt" ((PVar "b") (PCon "CSAssign" PWild (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "e")) (EVar "acc")))
# MARK
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "CField" true) (mem "CArm" true) (mem "CGuard" true) (mem "CStmt" true) (mem "CBind" true) (mem "CClause" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CProgram" true) (mem "CallMode" true) (mem "CallSite" true))))
(DUse false (UseGroup ("ir" "core_ir_lower") ((mem "ArityEnv" false) (mem "CallScope" false) (mem "bindGroupScope" false) (mem "bindLetScope" false) (mem "bindPatScope" false) (mem "bindPatsScope" false) (mem "callModeFor" false) (mem "definedArityOf" false) (mem "entryArityRow" false) (mem "programArities" false))))
(DUse false (UseGroup ("ir" "core_ir_sexp") ((mem "callModeSexp" false))))
(DUse false (UseGroup ("backend" "extern_catalog") ((mem "Disposition" true) (mem "GapKind" false) (mem "catalogRow" false) (mem "gapKindName" false) (mem "rowLlvm" false) (mem "rowWasm" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omHasKey" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "isNonEmptyL" false) (mem "joinWith" false) (mem "listLen" false) (mem "reverseL" false))))
(DData Public "Backend" () ((variant "LlvmBackend" (ConPos)) (variant "WasmBackend" (ConPos))) ())
(DTypeSig true "backendName" (TyFun (TyCon "Backend") (TyCon "String")))
(DFunDef false "backendName" ((PCon "LlvmBackend")) (ELit (LString "llvm")))
(DFunDef false "backendName" ((PCon "WasmBackend")) (ELit (LString "wasm")))
(DData Public "ExternFinding" () ((variant "ExternFinding" (ConPos (TyCon "String") (TyCon "Backend") (TyCon "GapKind") (TyCon "String") (TyCon "String")))) ())
(DTypeSig true "findingExtern" (TyFun (TyCon "ExternFinding") (TyCon "String")))
(DFunDef false "findingExtern" ((PCon "ExternFinding" (PVar "name") PWild PWild PWild PWild)) (EVar "name"))
(DTypeSig true "findingBinding" (TyFun (TyCon "ExternFinding") (TyCon "String")))
(DFunDef false "findingBinding" ((PCon "ExternFinding" PWild PWild PWild PWild (PVar "binding"))) (EVar "binding"))
(DTypeSig true "unprovidedOn" (TyFun (TyCon "Backend") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "GapKind") (TyCon "String"))))))
(DFunDef false "unprovidedOn" ((PCon "LlvmBackend") (PVar "name")) (EMatch (EApp (EVar "catalogRow") (EVar "name")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "notProvidedOf") (EApp (EVar "rowLlvm") (EVar "r")))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "unprovidedOn" ((PCon "WasmBackend") (PVar "name")) (EMatch (EApp (EVar "catalogRow") (EVar "name")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "notProvidedOf") (EApp (EVar "rowWasm") (EVar "r")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "notProvidedOf" (TyFun (TyApp (TyCon "Disposition") (TyVar "f")) (TyApp (TyCon "Option") (TyTuple (TyCon "GapKind") (TyCon "String")))))
(DFunDef false "notProvidedOf" ((PCon "NotProvided" (PVar "kind") (PVar "why"))) (EApp (EVar "Some") (ETuple (EVar "kind") (EVar "why"))))
(DFunDef false "notProvidedOf" (PWild) (EVar "None"))
(DTypeSig true "isUnprovidedOn" (TyFun (TyCon "Backend") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isUnprovidedOn" ((PVar "backend") (PVar "name")) (EApp (EVar "isSome") (EApp (EApp (EVar "unprovidedOn") (EVar "backend")) (EVar "name"))))
(DTypeSig true "validateExterns" (TyFun (TyCon "Backend") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "ExternFinding"))))))
(DFunDef false "validateExterns" ((PVar "backend") (PVar "runtimeExterns") (PVar "prog")) (EBlock (DoLet false false PWild (EApp (EVar "refuseMissingRows") (EVar "runtimeExterns"))) (DoExpr (EMatch (EApp (EApp (EVar "walkProgram") (EVar "backend")) (EVar "prog")) (arm (PCon "Walk" PWild (PVar "found") PWild PWild) () (EApp (EVar "reverseL") (EVar "found")))))))
(DTypeSig true "validateRecords" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateRecords" ((PVar "prog")) (EMatch (EApp (EApp (EVar "walkProgram") (EVar "LlvmBackend")) (EVar "prog")) (arm (PCon "Walk" PWild PWild (PVar "bad") PWild) () (EApp (EVar "reverseL") (EVar "bad")))))
(DTypeSig true "renderRecordRefusal" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "renderRecordRefusal" ((PVar "bad")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "bad")))
(DTypeSig true "validateCalls" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateCalls" ((PAs "prog" (PCon "CProgram" PWild PWild PWild (PVar "impls")))) (EMatch (EApp (EApp (EVar "walkProgram") (EVar "LlvmBackend")) (EVar "prog")) (arm (PCon "Walk" PWild PWild PWild (PVar "bad")) () (EBinOp "++" (EApp (EVar "reverseL") (EVar "bad")) (EApp (EApp (EApp (EVar "splitGroupFaults") (EVar "impls")) (EVar "omEmpty")) (EListLit))))))
(DTypeSig false "splitGroupFaults" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "splitGroupFaults" ((PList) PWild (PVar "acc")) (EApp (EVar "reverseL") (EVar "acc")))
(DFunDef false "splitGroupFaults" ((PCons (PAs "ent" (PCon "CImplEntry" (PVar "method") PWild PWild (PVar "body"))) (PVar "rest")) (PVar "seen") (PVar "acc")) (EBlock (DoLet false false (PTuple (PVar "key") (PVar "n")) (EApp (EVar "entryArityRow") (EVar "ent"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "seen")) (arm (PCon "Some" (PVar "k")) () (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EApp (EApp (EApp (EVar "splitGroupFaults") (EVar "rest")) (EVar "seen")) (EVar "acc")) (EApp (EApp (EApp (EVar "splitGroupFaults") (EVar "rest")) (EVar "seen")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "call: impl entry takes ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " value parameters, the first entry of its group "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString " [in impl "))) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EApp (EVar "implBodyTag") (EVar "body")))) (ELit (LString "]"))) (EVar "acc"))))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "splitGroupFaults") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "n")) (EVar "seen"))) (EVar "acc")))))))
(DTypeSig false "implBodyTag" (TyFun (TyCon "CImplBody") (TyCon "String")))
(DFunDef false "implBodyTag" ((PCon "CImplTagged" (PVar "tag") PWild PWild PWild PWild PWild)) (EVar "tag"))
(DFunDef false "implBodyTag" ((PCon "CImplDefault" PWild (PVar "tag") PWild PWild PWild PWild)) (EVar "tag"))
(DTypeSig true "renderCallRefusal" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "renderCallRefusal" ((PVar "bad")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "bad")))
(DTypeSig true "missingCatalogRows" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "missingCatalogRows" ((PVar "names")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "n")) (EApp (EVar "isNone") (EApp (EVar "catalogRow") (EVar "n"))))) (EVar "names")))
(DTypeSig true "missingRowsMessage" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "missingRowsMessage" ((PVar "missing")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "quoteName")) (EVar "missing")))) (DoExpr (EBinOp "++" (EBinOp "++" (ELit (LString "internal error: runtime extern ")) (EApp (EMethodRef "display") (EVar "names"))) (ELit (LString " has no row in the extern catalog (compiler/backend/extern_catalog.mdk)"))))))
(DTypeSig false "quoteName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "quoteName" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EVar "n")) (ELit (LString "'"))))
(DTypeSig false "refuseMissingRows" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))
(DFunDef false "refuseMissingRows" ((PVar "names")) (EMatch (EApp (EVar "missingCatalogRows") (EVar "names")) (arm (PList) () (ELit LUnit)) (arm (PVar "missing") () (EApp (EVar "panic") (EApp (EVar "missingRowsMessage") (EVar "missing"))))))
(DTypeSig true "renderExternFinding" (TyFun (TyCon "ExternFinding") (TyCon "String")))
(DFunDef false "renderExternFinding" ((PCon "ExternFinding" (PVar "name") (PVar "backend") (PVar "kind") (PVar "why") (PVar "binding"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "backendName") (EVar "backend")))) (ELit (LString ": runtime extern '"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "' is not available on the "))) (EApp (EMethodRef "display") (EApp (EVar "backendName") (EVar "backend")))) (ELit (LString " backend ("))) (EApp (EMethodRef "display") (EApp (EVar "gapKindName") (EVar "kind")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "why"))) (ELit (LString ") [in "))) (EApp (EMethodRef "display") (EVar "binding"))) (ELit (LString "]"))))
(DTypeSig true "renderExternRefusal" (TyFun (TyApp (TyCon "List") (TyCon "ExternFinding")) (TyCon "String")))
(DFunDef false "renderExternRefusal" ((PVar "findings")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EMethodRef "map") (EVar "renderExternFinding")) (EVar "findings"))))
(DTypeSig true "unrefusedExternMessage" (TyFun (TyCon "Backend") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "unrefusedExternMessage" ((PVar "backend") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "internal error: the ")) (EApp (EMethodRef "display") (EApp (EVar "backendName") (EVar "backend")))) (ELit (LString " emitter reached runtime extern '"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "', which it does not lower, without a refusal from validateExterns (compiler/backend/core_validate.mdk)"))))
(DTypeSig false "programNames" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "programNames" ((PList) (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "programNames" ((PList) (PCons (PTuple (PVar "ctor") PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "programNames") (EListLit)) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "ctor")) (ELit LUnit)) (EVar "acc"))))
(DFunDef false "programNames" ((PCons (PCon "CBind" (PVar "name") PWild PWild) (PVar "rest")) (PVar "ctors") (PVar "acc")) (EApp (EApp (EApp (EVar "programNames") (EVar "rest")) (EVar "ctors")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EVar "acc"))))
(DTypeSig false "isProgramName" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isProgramName" ((PVar "top") (PVar "x")) (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "top")) (EApp (EApp (EVar "omHasKey") (EBinOp "++" (ELit (LString "core__")) (EVar "x"))) (EVar "top"))))
(DData Private "Walk" () ((variant "Walk" (ConPos (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "ExternFinding")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))) ())
(DTypeSig false "noFindings" (TyCon "Walk"))
(DFunDef false "noFindings" () (EApp (EApp (EApp (EApp (EVar "Walk") (EVar "omEmpty")) (EListLit)) (EListLit)) (EListLit)))
(DData Private "Ctx" () ((variant "Ctx" (ConPos (TyCon "Backend") (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "ArityEnv") (TyCon "String")))) ())
(DTypeSig false "walkProgram" (TyFun (TyCon "Backend") (TyFun (TyCon "CProgram") (TyCon "Walk"))))
(DFunDef false "walkProgram" ((PVar "backend") (PAs "prog" (PCon "CProgram" (PVar "groups") (PVar "ctors") PWild (PVar "impls")))) (EBlock (DoLet false false (PVar "top") (EApp (EApp (EApp (EVar "programNames") (EVar "groups")) (EVar "ctors")) (EVar "omEmpty"))) (DoLet false false (PVar "env") (EApp (EVar "programArities") (EVar "prog"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "walkImpls") (EVar "backend")) (EVar "top")) (EVar "env")) (EVar "impls")) (EApp (EApp (EApp (EApp (EApp (EVar "walkBinds") (EVar "backend")) (EVar "top")) (EVar "env")) (EVar "groups")) (EVar "noFindings"))))))
(DTypeSig false "walkBinds" (TyFun (TyCon "Backend") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "ArityEnv") (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyCon "Walk") (TyCon "Walk")))))))
(DFunDef false "walkBinds" (PWild PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkBinds" ((PVar "backend") (PVar "top") (PVar "env") (PCons (PCon "CBind" (PVar "name") (PVar "clauses") PWild) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EApp (EVar "walkBinds") (EVar "backend")) (EVar "top")) (EVar "env")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkClauses") (EApp (EApp (EApp (EApp (EVar "Ctx") (EVar "backend")) (EVar "top")) (EVar "env")) (EVar "name"))) (EVar "omEmpty")) (EVar "clauses")) (EVar "w"))))
(DTypeSig false "walkImpls" (TyFun (TyCon "Backend") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "ArityEnv") (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "Walk") (TyCon "Walk")))))))
(DFunDef false "walkImpls" (PWild PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkImpls" ((PVar "backend") (PVar "top") (PVar "env") (PCons (PCon "CImplEntry" (PVar "method") PWild PWild (PVar "body")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EApp (EVar "walkImpls") (EVar "backend")) (EVar "top")) (EVar "env")) (EVar "rest")) (EApp (EApp (EApp (EVar "walkImplBody") (EApp (EApp (EApp (EApp (EVar "Ctx") (EVar "backend")) (EVar "top")) (EVar "env")) (EBinOp "++" (EBinOp "++" (ELit (LString "impl ")) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString ""))))) (EVar "body")) (EVar "w"))))
(DTypeSig false "walkImplBody" (TyFun (TyCon "Ctx") (TyFun (TyCon "CImplBody") (TyFun (TyCon "Walk") (TyCon "Walk")))))
(DFunDef false "walkImplBody" ((PCon "Ctx" (PVar "backend") (PVar "top") (PVar "env") (PVar "binding")) (PCon "CImplTagged" (PVar "tag") PWild PWild PWild (PVar "pats") (PVar "body")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EApp (EApp (EApp (EApp (EVar "Ctx") (EVar "backend")) (EVar "top")) (EVar "env")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "binding"))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString ""))))) (EApp (EApp (EVar "bindPatsScope") (EVar "pats")) (EVar "omEmpty"))) (EVar "body")) (EVar "w")))
(DFunDef false "walkImplBody" ((PCon "Ctx" (PVar "backend") (PVar "top") (PVar "env") (PVar "binding")) (PCon "CImplDefault" PWild (PVar "tag") PWild PWild (PVar "pats") (PVar "body")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EApp (EApp (EApp (EApp (EVar "Ctx") (EVar "backend")) (EVar "top")) (EVar "env")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "binding"))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString ""))))) (EApp (EApp (EVar "bindPatsScope") (EVar "pats")) (EVar "omEmpty"))) (EVar "body")) (EVar "w")))
(DTypeSig false "walkClauses" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkClauses" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkClauses" ((PVar "ctx") (PVar "scope") (PCons (PCon "CClause" (PVar "pats") (PVar "body")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkClauses") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EApp (EApp (EVar "bindPatsScope") (EVar "pats")) (EVar "scope"))) (EVar "body")) (EVar "w"))))
(DTypeSig false "walkE" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyCon "CExpr") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CVar" (PVar "x") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "noteVar") (EVar "ctx")) (EVar "scope")) (EVar "x")) (EVar "w")))
(DFunDef false "walkE" (PWild PWild (PCon "CLit" PWild) (PVar "w")) (EVar "w"))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CApp" (PVar "f") (PVar "args") (PVar "site")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "args")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "f")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteCall") (EVar "ctx")) (EVar "scope")) (EVar "f")) (EVar "args")) (EVar "site")) (EVar "w")))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CLam" (PVar "pats") (PVar "body")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EApp (EApp (EVar "bindPatsScope") (EVar "pats")) (EVar "scope"))) (EVar "body")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CLet" (PVar "recF") (PVar "pat") (PVar "rhs") (PVar "body")) (PVar "w")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EApp (EVar "bindLetScope") (EVar "pat")) (EVar "rhs")) (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "inner")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EIf (EVar "recF") (EVar "inner") (EVar "scope"))) (EVar "rhs")) (EVar "w"))))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CLetGroup" (PVar "binds") (PVar "body")) (PVar "w")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindGroupScope") (EVar "binds")) (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "inner")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "walkLocalBinds") (EVar "ctx")) (EVar "inner")) (EVar "binds")) (EVar "w"))))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CMatch" (PVar "scrut") (PVar "arms")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "ctx")) (EVar "scope")) (EVar "arms")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "scrut")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "ctx")) (EVar "scope")) (EVar "arms")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "scrut")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "c") (EVar "t") (EVar "f"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CBinPrim" PWild (PVar "l") (PVar "r") PWild PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "l") (EVar "r"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CUnOp" PWild (PVar "x")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "x")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CTuple" (PVar "es")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "es")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CList" (PVar "es")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "es")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CRecord" (PVar "name") (PVar "fields")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "ctx")) (EVar "scope")) (EVar "fields")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteRecord") (EVar "ctx")) (ELit (LString "CRecord"))) (EVar "name")) (EVar "True")) (EVar "fields")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CFieldAccess" (PVar "x") (PVar "label") (PVar "name") (PVar "ord")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "x")) (EApp (EApp (EApp (EApp (EApp (EVar "noteAccess") (EVar "ctx")) (EVar "label")) (EVar "name")) (EVar "ord")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "ctx")) (EVar "scope")) (EVar "fields")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "base")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteRecord") (EVar "ctx")) (ELit (LString "CRecordUpdate"))) (EVar "name")) (EVar "False")) (EVar "fields")) (EVar "w")))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "ctx")) (EVar "scope")) (EVar "fields")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "base")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteRecord") (EVar "ctx")) (ELit (LString "CVariantUpdate"))) (EVar "con")) (EVar "False")) (EVar "fields")) (EVar "w")))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CArray" (PVar "es")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "es")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CIndex" (PVar "a") (PVar "i")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "i"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CStringIndex" (PVar "a") (PVar "i")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "i"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CListIndex" (PVar "a") (PVar "i")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "i"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CBlock" (PVar "stmts")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "ctx")) (EVar "scope")) (EVar "stmts")) (EVar "w")))
(DFunDef false "walkE" (PWild PWild (PCon "CMethod" PWild PWild PWild PWild PWild PWild) (PVar "w")) (EVar "w"))
(DFunDef false "walkE" (PWild PWild (PCon "CDict" PWild PWild) (PVar "w")) (EVar "w"))
(DTypeSig false "noteAccess" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Walk") (TyCon "Walk")))))))
(DFunDef false "noteAccess" ((PVar "ctx") (PVar "label") (PVar "name") (PVar "ord") (PVar "w")) (EIf (EBinOp "||" (EBinOp ">=" (EVar "ord") (ELit (LInt 0))) (EBinOp "==" (EVar "label") (ELit (LString "value")))) (EVar "w") (EApp (EApp (EApp (EApp (EVar "noteRecordBad") (EVar "ctx")) (ELit (LString "CFieldAccess"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "."))) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString ": unstamped field ordinal")))) (EVar "w"))))
(DTypeSig false "noteRecord" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))))
(DFunDef false "noteRecord" ((PVar "ctx") (PVar "node") (PVar "name") (PVar "literal") (PVar "fields") (PVar "w")) (EIf (EApp (EApp (EApp (EApp (EVar "ordinalsOk") (EVar "literal")) (ELit (LInt 0))) (EUnOp "-" (ELit (LInt 1)))) (EVar "fields")) (EVar "w") (EApp (EApp (EApp (EApp (EVar "noteRecordBad") (EVar "ctx")) (EVar "node")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ": field ordinals ["))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "fieldOrdinalText")) (EVar "fields"))))) (ELit (LString "] are not "))) (EApp (EMethodRef "display") (EIf (EVar "literal") (ELit (LString "the declared positions")) (ELit (LString "strictly ascending"))))) (ELit (LString "")))) (EVar "w"))))
(DTypeSig false "ordinalsOk" (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyCon "Bool"))))))
(DFunDef false "ordinalsOk" (PWild PWild PWild (PList)) (EVar "True"))
(DFunDef false "ordinalsOk" ((PVar "literal") (PVar "pos") (PVar "prev") (PCons (PCon "CField" PWild (PVar "o") PWild) (PVar "rest"))) (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "o") (ELit (LInt 0))) (EIf (EVar "literal") (EBinOp "==" (EVar "o") (EVar "pos")) (EBinOp ">" (EVar "o") (EVar "prev")))) (EApp (EApp (EApp (EApp (EVar "ordinalsOk") (EVar "literal")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "o")) (EVar "rest"))))
(DTypeSig false "fieldOrdinalText" (TyFun (TyCon "CField") (TyCon "String")))
(DFunDef false "fieldOrdinalText" ((PCon "CField" (PVar "k") (PVar "o") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "k"))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "o")))) (ELit (LString ""))))
(DTypeSig false "noteRecordBad" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "noteRecordBad" ((PCon "Ctx" PWild PWild PWild (PVar "binding")) (PVar "node") (PVar "why") (PCon "Walk" (PVar "seen") (PVar "found") (PVar "bad") (PVar "calls"))) (EApp (EApp (EApp (EApp (EVar "Walk") (EVar "seen")) (EVar "found")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "record: ")) (EApp (EMethodRef "display") (EVar "node"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "why"))) (ELit (LString " [in "))) (EApp (EMethodRef "display") (EVar "binding"))) (ELit (LString "]"))) (EVar "bad"))) (EVar "calls")))
(DTypeSig false "noteCall" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyCon "CExpr") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyFun (TyCon "CallSite") (TyFun (TyCon "Walk") (TyCon "Walk"))))))))
(DFunDef false "noteCall" ((PVar "ctx") PWild PWild (PList) PWild (PVar "w")) (EApp (EApp (EApp (EVar "noteCallBad") (EVar "ctx")) (ELit (LString "application with no arguments"))) (EVar "w")))
(DFunDef false "noteCall" ((PVar "ctx") PWild (PCon "CApp" PWild PWild PWild) PWild PWild (PVar "w")) (EApp (EApp (EApp (EVar "noteCallBad") (EVar "ctx")) (ELit (LString "application whose head is an application"))) (EVar "w")))
(DFunDef false "noteCall" ((PAs "ctx" (PCon "Ctx" PWild PWild (PVar "env") PWild)) (PVar "scope") (PVar "hd") (PVar "args") (PCon "CallSite" (PVar "mode") PWild) (PVar "w")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "listLen") (EVar "args"))) (DoLet false false (PVar "arity") (EApp (EApp (EApp (EVar "definedArityOf") (EVar "env")) (EVar "scope")) (EVar "hd"))) (DoExpr (EIf (EApp (EApp (EVar "sameMode") (EApp (EApp (EVar "callModeFor") (EVar "arity")) (EVar "n"))) (EVar "mode")) (EVar "w") (EMatch (EVar "arity") (arm (PCon "Some" (PVar "k")) () (EApp (EApp (EApp (EVar "noteCallBad") (EVar "ctx")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "headText") (EVar "hd")))) (ELit (LString " applied to "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " of "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString ", stamped "))) (EApp (EMethodRef "display") (EApp (EVar "callModeSexp") (EVar "mode")))) (ELit (LString "")))) (EVar "w"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "noteCallBad") (EVar "ctx")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "headText") (EVar "hd")))) (ELit (LString " has no static arity, stamped "))) (EApp (EMethodRef "display") (EApp (EVar "callModeSexp") (EVar "mode")))) (ELit (LString "")))) (EVar "w"))))))))
(DTypeSig false "sameMode" (TyFun (TyCon "CallMode") (TyFun (TyCon "CallMode") (TyCon "Bool"))))
(DFunDef false "sameMode" ((PCon "CallExact") (PCon "CallExact")) (EVar "True"))
(DFunDef false "sameMode" ((PCon "CallPartial" (PVar "a")) (PCon "CallPartial" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "sameMode" ((PCon "CallOver" (PVar "a")) (PCon "CallOver" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "sameMode" ((PCon "CallDynamic") (PCon "CallDynamic")) (EVar "True"))
(DFunDef false "sameMode" (PWild PWild) (EVar "False"))
(DTypeSig false "noteCallBad" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "Walk") (TyCon "Walk")))))
(DFunDef false "noteCallBad" ((PCon "Ctx" PWild PWild PWild (PVar "binding")) (PVar "why") (PCon "Walk" (PVar "seen") (PVar "found") (PVar "bad") (PVar "calls"))) (EApp (EApp (EApp (EApp (EVar "Walk") (EVar "seen")) (EVar "found")) (EVar "bad")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "call: ")) (EApp (EMethodRef "display") (EVar "why"))) (ELit (LString " [in "))) (EApp (EMethodRef "display") (EVar "binding"))) (ELit (LString "]"))) (EVar "calls"))))
(DTypeSig false "headText" (TyFun (TyCon "CExpr") (TyCon "String")))
(DFunDef false "headText" ((PCon "CVar" (PVar "x") PWild)) (EVar "x"))
(DFunDef false "headText" ((PCon "CMethod" (PVar "name") PWild PWild PWild PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "method ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "headText" ((PCon "CDict" (PVar "name") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " (constrained)"))))
(DFunDef false "headText" ((PCon "CLam" PWild PWild)) (ELit (LString "a lambda")))
(DFunDef false "headText" (PWild) (ELit (LString "an expression")))
(DTypeSig false "noteVar" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyCon "String") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "noteVar" ((PCon "Ctx" (PVar "backend") (PVar "top") PWild (PVar "binding")) (PVar "scope") (PVar "x") (PAs "w" (PCon "Walk" (PVar "seen") (PVar "found") (PVar "bad") (PVar "calls")))) (EIf (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "scope")) (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "seen"))) (EVar "w") (EMatch (EApp (EApp (EVar "unprovidedOn") (EVar "backend")) (EVar "x")) (arm (PCon "None") () (EVar "w")) (arm (PCon "Some" (PTuple (PVar "kind") (PVar "why"))) () (EIf (EApp (EApp (EVar "isProgramName") (EVar "top")) (EVar "x")) (EVar "w") (EApp (EApp (EApp (EApp (EVar "Walk") (EApp (EApp (EApp (EVar "omInsert") (EVar "x")) (ELit LUnit)) (EVar "seen"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "ExternFinding") (EVar "x")) (EVar "backend")) (EVar "kind")) (EVar "why")) (EVar "binding")) (EVar "found"))) (EVar "bad")) (EVar "calls")))))))
(DTypeSig false "walkList" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkList" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkList" ((PVar "ctx") (PVar "scope") (PCons (PVar "e") (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DTypeSig false "walkFields" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkFields" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkFields" ((PVar "ctx") (PVar "scope") (PCons (PCon "CField" PWild PWild (PVar "e")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DTypeSig false "walkLocalBinds" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkLocalBinds" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkLocalBinds" ((PVar "ctx") (PVar "scope") (PCons (PCon "CBind" PWild (PVar "clauses") PWild) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkLocalBinds") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkClauses") (EVar "ctx")) (EVar "scope")) (EVar "clauses")) (EVar "w"))))
(DTypeSig false "walkArms" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkArms" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkArms" ((PVar "ctx") (PVar "scope") (PCons (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "ctx")) (EApp (EApp (EVar "bindPatScope") (EVar "pat")) (EVar "scope"))) (EVar "guards")) (EVar "body")) (EVar "w"))))
(DTypeSig false "walkGuarded" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyFun (TyCon "CExpr") (TyFun (TyCon "Walk") (TyCon "Walk")))))))
(DFunDef false "walkGuarded" ((PVar "ctx") (PVar "scope") (PList) (PVar "body") (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "body")) (EVar "w")))
(DFunDef false "walkGuarded" ((PVar "ctx") (PVar "scope") (PCons (PCon "CGBool" (PVar "c")) (PVar "rest")) (PVar "body") (PVar "w")) (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "c")) (EVar "w"))))
(DFunDef false "walkGuarded" ((PVar "ctx") (PVar "scope") (PCons (PCon "CGBind" (PVar "pat") (PVar "e")) (PVar "rest")) (PVar "body") (PVar "w")) (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "ctx")) (EApp (EApp (EVar "bindPatScope") (EVar "pat")) (EVar "scope"))) (EVar "rest")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DTypeSig false "walkStmts" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkStmts" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkStmts" ((PVar "ctx") (PVar "scope") (PCons (PCon "CSExpr" (PVar "e")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DFunDef false "walkStmts" ((PVar "ctx") (PVar "scope") (PCons (PCon "CSLet" (PVar "recF") (PVar "pat") (PVar "e")) (PVar "rest")) (PVar "w")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EApp (EVar "bindLetScope") (EVar "pat")) (EVar "e")) (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "ctx")) (EVar "inner")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EIf (EVar "recF") (EVar "inner") (EVar "scope"))) (EVar "e")) (EVar "w"))))))
(DFunDef false "walkStmts" ((PVar "ctx") (PVar "scope") (PCons (PCon "CSAssign" PWild (PVar "e")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DTypeSig true "validateTails" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateTails" ((PCon "CProgram" (PVar "groups") PWild PWild (PVar "impls"))) (EApp (EVar "reverseL") (EApp (EApp (EVar "tailImpls") (EVar "impls")) (EApp (EApp (EVar "tailBinds") (EVar "groups")) (EListLit)))))
(DTypeSig true "renderTailRefusal" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "renderTailRefusal" ((PVar "bad")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "bad")))
(DTypeSig false "tailBinds" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tailBinds" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailBinds" ((PCons (PCon "CBind" (PVar "name") (PVar "clauses") PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "tailBinds") (EVar "rest")) (EApp (EApp (EApp (EVar "tailClauses") (EVar "name")) (EVar "clauses")) (EVar "acc"))))
(DTypeSig false "tailClauses" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailClauses" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailClauses" ((PVar "b") (PCons (PCon "CClause" (PVar "pats") (PVar "body")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailClauses") (EVar "b")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EApp (EVar "isNonEmptyL") (EVar "pats"))) (EVar "body")) (EVar "acc"))))
(DTypeSig false "tailImpls" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tailImpls" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailImpls" ((PCons (PCon "CImplEntry" (PVar "method") PWild PWild (PVar "body")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "tailImpls") (EVar "rest")) (EApp (EApp (EApp (EVar "tailImplBody") (EBinOp "++" (EBinOp "++" (ELit (LString "impl ")) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString "")))) (EVar "body")) (EVar "acc"))))
(DTypeSig false "tailImplBody" (TyFun (TyCon "String") (TyFun (TyCon "CImplBody") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailImplBody" ((PVar "b") (PCon "CImplTagged" (PVar "tag") PWild PWild PWild (PVar "pats") (PVar "body")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString "")))) (EApp (EVar "isNonEmptyL") (EVar "pats"))) (EVar "body")) (EVar "acc")))
(DFunDef false "tailImplBody" ((PVar "b") (PCon "CImplDefault" PWild (PVar "tag") PWild PWild (PVar "pats") (PVar "body")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString "")))) (EApp (EVar "isNonEmptyL") (EVar "pats"))) (EVar "body")) (EVar "acc")))
(DTypeSig false "tailE" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "CExpr") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CApp" (PVar "f") (PVar "args") (PCon "CallSite" (PVar "mode") (PVar "flag"))) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EVar "args")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "f")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailCallNote") (EVar "b")) (EVar "tl")) (EVar "f")) (EVar "mode")) (EVar "flag")) (EVar "acc")))))
(DFunDef false "tailE" (PWild PWild (PCon "CVar" PWild PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailE" (PWild PWild (PCon "CLit" PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CLam" PWild (PVar "body")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "True")) (EVar "body")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CLet" PWild PWild (PVar "rhs") (PVar "body")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "tl")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "rhs")) (EVar "acc"))))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CLetGroup" (PVar "binds") (PVar "body")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "tl")) (EVar "body")) (EApp (EApp (EApp (EVar "tailLocalBinds") (EVar "b")) (EVar "binds")) (EVar "acc"))))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CMatch" (PVar "scrut") (PVar "arms")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailArms") (EVar "b")) (EVar "tl")) (EVar "arms")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "scrut")) (EVar "acc"))))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailArms") (EVar "b")) (EVar "tl")) (EVar "arms")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "scrut")) (EVar "acc"))))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "tl")) (EVar "f")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "tl")) (EVar "t")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "c")) (EVar "acc")))))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CBinPrim" PWild (PVar "l") (PVar "r") PWild PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "l") (EVar "r"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CUnOp" PWild (PVar "x")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "x")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CTuple" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EVar "es")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CList" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EVar "es")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CRecord" PWild (PVar "fields")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailFields") (EVar "b")) (EVar "fields")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CFieldAccess" (PVar "x") PWild PWild PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "x")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CRecordUpdate" PWild (PVar "base") (PVar "fields")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailFields") (EVar "b")) (EVar "fields")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "base")) (EVar "acc"))))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CVariantUpdate" PWild (PVar "base") (PVar "fields")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailFields") (EVar "b")) (EVar "fields")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "base")) (EVar "acc"))))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CArray" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EVar "es")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "lo") (EVar "hi"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "lo") (EVar "hi"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CIndex" (PVar "a") (PVar "i")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "a") (EVar "i"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CStringIndex" (PVar "a") (PVar "i")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "a") (EVar "i"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CListIndex" (PVar "a") (PVar "i")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "a") (EVar "i"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CBlock" (PVar "stmts")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailStmts") (EVar "b")) (EVar "tl")) (EVar "stmts")) (EVar "acc")))
(DFunDef false "tailE" (PWild PWild (PCon "CMethod" PWild PWild PWild PWild PWild PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailE" (PWild PWild (PCon "CDict" PWild PWild) (PVar "acc")) (EVar "acc"))
(DTypeSig false "tailCallNote" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "CExpr") (TyFun (TyCon "CallMode") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "tailCallNote" ((PVar "b") (PVar "tl") (PVar "hd") (PVar "mode") (PVar "flag") (PVar "acc")) (EIf (EBinOp "&&" (EVar "flag") (EApp (EVar "not") (EVar "tl"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "tail: ")) (EApp (EMethodRef "display") (EApp (EVar "headText") (EVar "hd")))) (ELit (LString " is flagged as a tail call outside tail position [in "))) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString "]"))) (EVar "acc")) (EIf (EBinOp "&&" (EVar "flag") (EApp (EVar "isPartialCall") (EVar "mode"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "tail: ")) (EApp (EMethodRef "display") (EApp (EVar "headText") (EVar "hd")))) (ELit (LString " is flagged as a tail call but is a partial application "))) (EApp (EMethodRef "display") (EApp (EVar "callModeSexp") (EVar "mode")))) (ELit (LString " [in "))) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString "]"))) (EVar "acc")) (EIf (EBinOp "&&" (EBinOp "&&" (EVar "tl") (EApp (EVar "not") (EVar "flag"))) (EApp (EVar "not") (EApp (EVar "isPartialCall") (EVar "mode")))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "tail: ")) (EApp (EMethodRef "display") (EApp (EVar "headText") (EVar "hd")))) (ELit (LString " is in tail position, stamped "))) (EApp (EMethodRef "display") (EApp (EVar "callModeSexp") (EVar "mode")))) (ELit (LString ", but not flagged [in "))) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString "]"))) (EVar "acc")) (EVar "acc")))))
(DTypeSig false "isPartialCall" (TyFun (TyCon "CallMode") (TyCon "Bool")))
(DFunDef false "isPartialCall" ((PCon "CallPartial" PWild)) (EVar "True"))
(DFunDef false "isPartialCall" (PWild) (EVar "False"))
(DTypeSig false "tailList" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailList" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailList" ((PVar "b") (PCons (PVar "e") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "tailFields" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailFields" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailFields" ((PVar "b") (PCons (PCon "CField" PWild PWild (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailFields") (EVar "b")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "tailLocalBinds" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailLocalBinds" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailLocalBinds" ((PVar "b") (PCons (PCon "CBind" PWild (PVar "clauses") PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailLocalBinds") (EVar "b")) (EVar "rest")) (EApp (EApp (EApp (EVar "tailClauses") (EVar "b")) (EVar "clauses")) (EVar "acc"))))
(DTypeSig false "tailArms" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "tailArms" (PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailArms" ((PVar "b") (PVar "tl") (PCons (PCon "CArm" PWild (PVar "guards") (PVar "body")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailArms") (EVar "b")) (EVar "tl")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "tl")) (EVar "body")) (EApp (EApp (EApp (EVar "tailGuards") (EVar "b")) (EVar "guards")) (EVar "acc")))))
(DTypeSig false "tailGuards" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailGuards" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailGuards" ((PVar "b") (PCons (PCon "CGBool" (PVar "c")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailGuards") (EVar "b")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "c")) (EVar "acc"))))
(DFunDef false "tailGuards" ((PVar "b") (PCons (PCon "CGBind" PWild (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailGuards") (EVar "b")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "tailStmts" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "tailStmts" (PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailStmts" ((PVar "b") (PVar "tl") (PList (PCon "CSExpr" (PVar "e"))) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "tl")) (EVar "e")) (EVar "acc")))
(DFunDef false "tailStmts" ((PVar "b") (PVar "tl") (PCons (PVar "st") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailStmts") (EVar "b")) (EVar "tl")) (EVar "rest")) (EApp (EApp (EApp (EVar "tailStmt") (EVar "b")) (EVar "st")) (EVar "acc"))))
(DTypeSig false "tailStmt" (TyFun (TyCon "String") (TyFun (TyCon "CStmt") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailStmt" ((PVar "b") (PCon "CSExpr" (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "e")) (EVar "acc")))
(DFunDef false "tailStmt" ((PVar "b") (PCon "CSLet" PWild PWild (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "e")) (EVar "acc")))
(DFunDef false "tailStmt" ((PVar "b") (PCon "CSAssign" PWild (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "e")) (EVar "acc")))
