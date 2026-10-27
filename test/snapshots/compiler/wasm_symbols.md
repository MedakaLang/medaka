# META
source_lines=309
stages=DESUGAR,MARK
# SOURCE
-- The physical identities of one WasmGC module under emission: each function,
-- type, global and element-declared function reference the emitter writes, the
-- shape it was given, and the binding whose emission wrote it.  A definition,
-- call or reference that contradicts the registry is a `SymbolDefect`, which the
-- emitter returns to its driver instead of a module text.
--
-- When an identity is judged depends on when its set is closed, not on its name.
-- Types and globals are declared before any body is emitted, so a use of an
-- undeclared one is a defect at the use.  A function may be called before it is
-- defined (force functions and coded-trap helpers follow every body), so a call
-- to a function not yet defined waits: it is judged against the definition when
-- that arrives, and whatever still waits once the module is complete is
-- `unresolved`.  An element reference (`ref.func`) waits the same way for the
-- `(elem declare func …)` entry that makes it valid.
--
-- A WebAssembly module may not name one function, type or global twice, so a
-- second declaration or definition of an identity is a defect whichever of the
-- two declared it.  Only an element entry may repeat: the element list is a set.

import support.ordmap.{
  OrdMap, omDelete, omEmpty, omHasKey, omInsert, omKeys, omLookup
}
import support.util.{reverseL}

-- A physical name, without its `$`.
public export data WasmSymbol =
  | WasmFunc String
  | WasmType String
  | WasmGlobal String
  | WasmElem String
  deriving (Eq, Debug)

-- What a declaration or definition says the identity is.  A function's shape is
-- the operand count a direct `call` must supply: written inline (`FuncParams`),
-- or through a declared function type (`FuncOfType`, the type and its count).  An
-- imported function's signature is the host plan's, so no count is recorded.
public export data WasmShape =
  | FuncParams Int
  | FuncOfType String Int
  | FuncImported
  | TypeDecl
  | GlobalDecl
  | ElemDecl
  deriving (Eq, Debug)

-- Where an identity was written or used: the source binding whose emission did
-- it, and that binding's file, line and column ("" and 0 when it has none).
public export data SymbolOrigin =
  SymbolOrigin String String Int Int
  deriving (Eq, Debug)

public export data SymbolDefect =
  | DuplicateDefinition WasmSymbol SymbolOrigin SymbolOrigin  -- the identity, where it was written again, where it was first written
  -- the function, its parameter count, the operands the call supplies, the
  -- call, the definition
  | ShapeMismatch String Int Int SymbolOrigin SymbolOrigin
  -- a function some call or `ref.func` names, or a global some access names,
  -- that nothing defined
  | UndefinedReference WasmSymbol SymbolOrigin
  -- the type, the identity whose declaration uses it, the use
  | UndeclaredType String String SymbolOrigin
  -- a function taken by `ref.func` that no element declaration lists
  | UndeclaredFuncRef String SymbolOrigin
  deriving (Eq, Debug)

data Entry = Entry WasmShape SymbolOrigin

-- a use still waiting for its identity: the operand count of a call, or None
-- for a reference
data Waiting = Waiting WasmSymbol (Option Int) SymbolOrigin

export data SymbolRegistry = SymbolRegistry {
  entries : OrdMap Entry,
  waiting : OrdMap (List Waiting),
  excused : OrdMap Unit,
  elems : List String,
}

export
emptyRegistry : SymbolRegistry
emptyRegistry = SymbolRegistry {
  entries = omEmpty,
  waiting = omEmpty,
  excused = omEmpty,
  elems = [],
}

-- One key space per identity kind: a function and a global may share a name.
symbolKey : WasmSymbol -> String
symbolKey (WasmFunc n) = "f:" ++ n
symbolKey (WasmType n) = "t:" ++ n
symbolKey (WasmGlobal n) = "g:" ++ n
symbolKey (WasmElem n) = "e:" ++ n

symbolName : WasmSymbol -> String
symbolName (WasmFunc n) = n
symbolName (WasmType n) = n
symbolName (WasmGlobal n) = n
symbolName (WasmElem n) = n

paramCount : WasmShape -> Option Int
paramCount (FuncParams n) = Some n
paramCount (FuncOfType _ n) = Some n
paramCount _ = None

-- An identity the module receives rather than generates: an import, a type, a
-- global, or an element entry.
export
declareSymbol : WasmSymbol ->
  WasmShape ->
  SymbolOrigin ->
  SymbolRegistry ->
  Result SymbolDefect SymbolRegistry
declareSymbol sym shape origin reg = admit sym shape origin reg

-- A function the emitter generates a body for.
export
defineSymbol : WasmSymbol ->
  WasmShape ->
  SymbolOrigin ->
  SymbolRegistry ->
  Result SymbolDefect SymbolRegistry
defineSymbol sym shape origin reg = admit sym shape origin reg

admit : WasmSymbol ->
  WasmShape ->
  SymbolOrigin ->
  SymbolRegistry ->
  Result SymbolDefect SymbolRegistry
admit (WasmElem n) _ origin reg =
  if omHasKey (symbolKey (WasmElem n)) reg.entries then
    Ok reg
  else
    settle (WasmElem n) (Entry ElemDecl origin) { reg | elems = n :: reg.elems }
admit sym shape origin reg = match omLookup (symbolKey sym) reg.entries
  Some (Entry _ first) => Err (DuplicateDefinition sym origin first)
  None => settle sym (Entry shape origin) reg

-- record [entry] for [sym], then judge every use that waited for it
settle : WasmSymbol ->
  Entry ->
  SymbolRegistry ->
  Result SymbolDefect SymbolRegistry
settle sym entry reg =
  let key = symbolKey sym
  let reg2 = { reg |
    entries = omInsert key entry reg.entries,
    waiting = omDelete key reg.waiting,
  }
  match omLookup key reg.waiting
    None => Ok reg2
    Some uses => judgeWaiting entry (reverseL uses) reg2

judgeWaiting : Entry ->
  List Waiting ->
  SymbolRegistry ->
  Result SymbolDefect SymbolRegistry
judgeWaiting _ [] reg = Ok reg
judgeWaiting entry ((Waiting sym operands at) :: rest) reg =
  match callDefect sym operands at entry
    Some d => Err d
    None => judgeWaiting entry rest reg

callDefect : WasmSymbol ->
  Option Int ->
  SymbolOrigin ->
  Entry ->
  Option SymbolDefect
callDefect sym operands at (Entry shape defined) = match (
  operands,
  paramCount shape,
)
  (Some n, Some m) =>
    if n == m then
      None
    else
      Some (ShapeMismatch (symbolName sym) m n at defined)
  _ => None

-- A direct call of a function, supplying [operands] operands.
export
checkCall : WasmSymbol ->
  Int ->
  SymbolOrigin ->
  SymbolRegistry ->
  Result SymbolDefect SymbolRegistry
checkCall sym operands origin reg = match omLookup (symbolKey sym) reg.entries
  Some entry => match callDefect sym (Some operands) origin entry
    Some d => Err d
    None => Ok reg
  None => Ok (wait (Waiting sym (Some operands) origin) reg)

-- A use of an identity by name alone: a type use, a global access, or a
-- `ref.func` (whose function and element entry both have to exist).
export
checkRef : WasmSymbol ->
  SymbolOrigin ->
  SymbolRegistry ->
  Result SymbolDefect SymbolRegistry
checkRef (WasmType t) origin reg = checkTypeUse t t origin reg
checkRef (WasmGlobal g) origin reg =
  if omHasKey (symbolKey (WasmGlobal g)) reg.entries then
    Ok reg
  else
    Err (UndefinedReference (WasmGlobal g) origin)
checkRef sym origin reg =
  if omHasKey (symbolKey sym) reg.entries then
    Ok reg
  else
    Ok (wait (Waiting sym None origin) reg)

-- [user]'s declaration says `(type $<t>)`; the type section must declare it.
export
checkTypeUse : String ->
  String ->
  SymbolOrigin ->
  SymbolRegistry ->
  Result SymbolDefect SymbolRegistry
checkTypeUse t user origin reg =
  if omHasKey (symbolKey (WasmType t)) reg.entries then
    Ok reg
  else
    Err (UndeclaredType t user origin)

wait : Waiting -> SymbolRegistry -> SymbolRegistry
wait (w@(Waiting sym _ _)) reg =
  let key = symbolKey sym
  let earlier = match omLookup key reg.waiting
    Some uses => uses
    None => []
  { reg | waiting = omInsert key (w :: earlier) reg.waiting }

-- [sym]'s definer recorded a gap instead of defining it, so a use of it is the
-- gap's to report, not the registry's.
export
excuseSymbol : WasmSymbol -> SymbolRegistry -> SymbolRegistry
excuseSymbol sym reg =
  { reg | excused = omInsert (symbolKey sym) () reg.excused }

-- Once the module is complete: one defect for each identity some use still
-- waits for, at its first use, in key order.
export
unresolved : SymbolRegistry -> List SymbolDefect
unresolved reg = flatMap (unresolvedAt reg) (omKeys reg.waiting)

unresolvedAt : SymbolRegistry -> String -> List SymbolDefect
unresolvedAt reg key =
  if omHasKey key reg.excused then
    []
  else match omLookup key reg.waiting
    None => []
    Some uses => match reverseL uses
      [] => []
      (Waiting sym _ at) :: _ => [missingDefect sym at]

missingDefect : WasmSymbol -> SymbolOrigin -> SymbolDefect
missingDefect (WasmElem n) at = UndeclaredFuncRef n at
missingDefect sym at = UndefinedReference sym at

-- The element-declared functions, in the order they were first declared.
export
elemNames : SymbolRegistry -> List String
elemNames reg = reverseL reg.elems

-- ── rendering ───────────────────────────────────────────────────────────────

export
defectCode : SymbolDefect -> String
defectCode (DuplicateDefinition _ _ _) = "E-PHYS-DUPLICATE"
defectCode (ShapeMismatch _ _ _ _ _) = "E-PHYS-SHAPE"
defectCode (UndefinedReference _ _) = "E-PHYS-UNDEFINED"
defectCode (UndeclaredType _ _ _) = "E-PHYS-UNDECLARED-TYPE"
defectCode (UndeclaredFuncRef _ _) = "E-PHYS-UNDECLARED-FUNCREF"

-- The binding and position the defect is reported at.
export
defectOrigin : SymbolDefect -> SymbolOrigin
defectOrigin (DuplicateDefinition _ at _) = at
defectOrigin (ShapeMismatch _ _ _ at _) = at
defectOrigin (UndefinedReference _ at) = at
defectOrigin (UndeclaredType _ _ at) = at
defectOrigin (UndeclaredFuncRef _ at) = at

export
defectMessage : SymbolDefect -> String
defectMessage (DuplicateDefinition sym at first) =
  "in \{bindingOf at}: the WebAssembly module would define \{describe sym} twice, here and in \{placeOf first}; a module may name it once"
defectMessage (ShapeMismatch f params operands at defined) =
  "in \{bindingOf at}: a call of function `$\{f}` supplies \{intToString operands} operand(s), but its definition in \{placeOf defined} takes \{intToString params}"
defectMessage (UndefinedReference sym at) =
  "in \{bindingOf at}: the WebAssembly module refers to \{describe sym}, which nothing in it defines"
defectMessage (UndeclaredType t user at) =
  "in \{bindingOf at}: `$\{user}` is declared with type `$\{t}`, which this module's type section does not declare"
defectMessage (UndeclaredFuncRef f at) =
  "in \{bindingOf at}: `ref.func $\{f}` names a function no element declaration lists"

describe : WasmSymbol -> String
describe (WasmFunc n) = "function `$\{n}`"
describe (WasmType n) = "type `$\{n}`"
describe (WasmGlobal n) = "global `$\{n}`"
describe (WasmElem n) = "element entry `$\{n}`"

bindingOf : SymbolOrigin -> String
bindingOf (SymbolOrigin b _ _ _) = "`\{b}`"

placeOf : SymbolOrigin -> String
placeOf (SymbolOrigin b "" _ _) = "`\{b}`"
placeOf (SymbolOrigin b file line col) =
  "`\{b}` (\{file}:\{intToString line}:\{intToString col})"
# DESUGAR
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omDelete" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omKeys" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false))))
(DData Public "WasmSymbol" () ((variant "WasmFunc" (ConPos (TyCon "String"))) (variant "WasmType" (ConPos (TyCon "String"))) (variant "WasmGlobal" (ConPos (TyCon "String"))) (variant "WasmElem" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "WasmSymbol")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "WasmFunc" (PVar "__a0")) (PCon "WasmFunc" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "WasmType" (PVar "__a0")) (PCon "WasmType" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "WasmGlobal" (PVar "__a0")) (PCon "WasmGlobal" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "WasmElem" (PVar "__a0")) (PCon "WasmElem" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "WasmSymbol")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "WasmFunc" (PVar "__a0")) () (EBinOp "++" (ELit (LString "WasmFunc ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "WasmType" (PVar "__a0")) () (EBinOp "++" (ELit (LString "WasmType ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "WasmGlobal" (PVar "__a0")) () (EBinOp "++" (ELit (LString "WasmGlobal ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "WasmElem" (PVar "__a0")) () (EBinOp "++" (ELit (LString "WasmElem ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))))))))
(DData Public "WasmShape" () ((variant "FuncParams" (ConPos (TyCon "Int"))) (variant "FuncOfType" (ConPos (TyCon "String") (TyCon "Int"))) (variant "FuncImported" (ConPos)) (variant "TypeDecl" (ConPos)) (variant "GlobalDecl" (ConPos)) (variant "ElemDecl" (ConPos))) ())
(DImpl true "Eq" ((TyCon "WasmShape")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "FuncParams" (PVar "__a0")) (PCon "FuncParams" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "FuncOfType" (PVar "__a0") (PVar "__a1")) (PCon "FuncOfType" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "FuncImported") (PCon "FuncImported")) () (EVar "True")) (arm (PTuple (PCon "TypeDecl") (PCon "TypeDecl")) () (EVar "True")) (arm (PTuple (PCon "GlobalDecl") (PCon "GlobalDecl")) () (EVar "True")) (arm (PTuple (PCon "ElemDecl") (PCon "ElemDecl")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "WasmShape")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "FuncParams" (PVar "__a0")) () (EBinOp "++" (ELit (LString "FuncParams ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "FuncOfType" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FuncOfType ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1"))))) (arm (PCon "FuncImported") () (ELit (LString "FuncImported"))) (arm (PCon "TypeDecl") () (ELit (LString "TypeDecl"))) (arm (PCon "GlobalDecl") () (ELit (LString "GlobalDecl"))) (arm (PCon "ElemDecl") () (ELit (LString "ElemDecl")))))))
(DData Public "SymbolOrigin" () ((variant "SymbolOrigin" (ConPos (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "SymbolOrigin")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "SymbolOrigin" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) (PCon "SymbolOrigin" (PVar "__b0") (PVar "__b1") (PVar "__b2") (PVar "__b3"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "SymbolOrigin")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "SymbolOrigin" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "SymbolOrigin ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a3")))))))))
(DData Public "SymbolDefect" () ((variant "DuplicateDefinition" (ConPos (TyCon "WasmSymbol") (TyCon "SymbolOrigin") (TyCon "SymbolOrigin"))) (variant "ShapeMismatch" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Int") (TyCon "SymbolOrigin") (TyCon "SymbolOrigin"))) (variant "UndefinedReference" (ConPos (TyCon "WasmSymbol") (TyCon "SymbolOrigin"))) (variant "UndeclaredType" (ConPos (TyCon "String") (TyCon "String") (TyCon "SymbolOrigin"))) (variant "UndeclaredFuncRef" (ConPos (TyCon "String") (TyCon "SymbolOrigin")))) ())
(DImpl true "Eq" ((TyCon "SymbolDefect")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "DuplicateDefinition" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "DuplicateDefinition" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple (PCon "ShapeMismatch" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3") (PVar "__a4")) (PCon "ShapeMismatch" (PVar "__b0") (PVar "__b1") (PVar "__b2") (PVar "__b3") (PVar "__b4"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EVar "eq") (EVar "__a4")) (EVar "__b4")))) (arm (PTuple (PCon "UndefinedReference" (PVar "__a0") (PVar "__a1")) (PCon "UndefinedReference" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "UndeclaredType" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "UndeclaredType" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple (PCon "UndeclaredFuncRef" (PVar "__a0") (PVar "__a1")) (PCon "UndeclaredFuncRef" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "SymbolDefect")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "DuplicateDefinition" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "DuplicateDefinition ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a2"))))) (arm (PCon "ShapeMismatch" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3") (PVar "__a4")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ShapeMismatch ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a3")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a4"))))) (arm (PCon "UndefinedReference" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "UndefinedReference ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1"))))) (arm (PCon "UndeclaredType" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "UndeclaredType ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a2"))))) (arm (PCon "UndeclaredFuncRef" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "UndeclaredFuncRef ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))))))))
(DData Private "Entry" () ((variant "Entry" (ConPos (TyCon "WasmShape") (TyCon "SymbolOrigin")))) ())
(DData Private "Waiting" () ((variant "Waiting" (ConPos (TyCon "WasmSymbol") (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "SymbolOrigin")))) ())
(DData Abstract "SymbolRegistry" () ((variant "SymbolRegistry" (ConNamed (field "entries" (TyApp (TyCon "OrdMap") (TyCon "Entry"))) (field "waiting" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Waiting")))) (field "excused" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "elems" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig true "emptyRegistry" (TyCon "SymbolRegistry"))
(DFunDef false "emptyRegistry" () (ERecordCreate "SymbolRegistry" ((fa "entries" (EVar "omEmpty")) (fa "waiting" (EVar "omEmpty")) (fa "excused" (EVar "omEmpty")) (fa "elems" (EListLit)))))
(DTypeSig false "symbolKey" (TyFun (TyCon "WasmSymbol") (TyCon "String")))
(DFunDef false "symbolKey" ((PCon "WasmFunc" (PVar "n"))) (EBinOp "++" (ELit (LString "f:")) (EVar "n")))
(DFunDef false "symbolKey" ((PCon "WasmType" (PVar "n"))) (EBinOp "++" (ELit (LString "t:")) (EVar "n")))
(DFunDef false "symbolKey" ((PCon "WasmGlobal" (PVar "n"))) (EBinOp "++" (ELit (LString "g:")) (EVar "n")))
(DFunDef false "symbolKey" ((PCon "WasmElem" (PVar "n"))) (EBinOp "++" (ELit (LString "e:")) (EVar "n")))
(DTypeSig false "symbolName" (TyFun (TyCon "WasmSymbol") (TyCon "String")))
(DFunDef false "symbolName" ((PCon "WasmFunc" (PVar "n"))) (EVar "n"))
(DFunDef false "symbolName" ((PCon "WasmType" (PVar "n"))) (EVar "n"))
(DFunDef false "symbolName" ((PCon "WasmGlobal" (PVar "n"))) (EVar "n"))
(DFunDef false "symbolName" ((PCon "WasmElem" (PVar "n"))) (EVar "n"))
(DTypeSig false "paramCount" (TyFun (TyCon "WasmShape") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "paramCount" ((PCon "FuncParams" (PVar "n"))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "paramCount" ((PCon "FuncOfType" PWild (PVar "n"))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "paramCount" (PWild) (EVar "None"))
(DTypeSig true "declareSymbol" (TyFun (TyCon "WasmSymbol") (TyFun (TyCon "WasmShape") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry")))))))
(DFunDef false "declareSymbol" ((PVar "sym") (PVar "shape") (PVar "origin") (PVar "reg")) (EApp (EApp (EApp (EApp (EVar "admit") (EVar "sym")) (EVar "shape")) (EVar "origin")) (EVar "reg")))
(DTypeSig true "defineSymbol" (TyFun (TyCon "WasmSymbol") (TyFun (TyCon "WasmShape") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry")))))))
(DFunDef false "defineSymbol" ((PVar "sym") (PVar "shape") (PVar "origin") (PVar "reg")) (EApp (EApp (EApp (EApp (EVar "admit") (EVar "sym")) (EVar "shape")) (EVar "origin")) (EVar "reg")))
(DTypeSig false "admit" (TyFun (TyCon "WasmSymbol") (TyFun (TyCon "WasmShape") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry")))))))
(DFunDef false "admit" ((PCon "WasmElem" (PVar "n")) PWild (PVar "origin") (PVar "reg")) (EIf (EApp (EApp (EVar "omHasKey") (EApp (EVar "symbolKey") (EApp (EVar "WasmElem") (EVar "n")))) (EFieldAccess (EVar "reg") "entries")) (EApp (EVar "Ok") (EVar "reg")) (EApp (EApp (EApp (EVar "settle") (EApp (EVar "WasmElem") (EVar "n"))) (EApp (EApp (EVar "Entry") (EVar "ElemDecl")) (EVar "origin"))) (ERecordUpdate (EVar "reg") ((fa "elems" (EBinOp "::" (EVar "n") (EFieldAccess (EVar "reg") "elems"))))))))
(DFunDef false "admit" ((PVar "sym") (PVar "shape") (PVar "origin") (PVar "reg")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "symbolKey") (EVar "sym"))) (EFieldAccess (EVar "reg") "entries")) (arm (PCon "Some" (PCon "Entry" PWild (PVar "first"))) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "DuplicateDefinition") (EVar "sym")) (EVar "origin")) (EVar "first")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "settle") (EVar "sym")) (EApp (EApp (EVar "Entry") (EVar "shape")) (EVar "origin"))) (EVar "reg")))))
(DTypeSig false "settle" (TyFun (TyCon "WasmSymbol") (TyFun (TyCon "Entry") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry"))))))
(DFunDef false "settle" ((PVar "sym") (PVar "entry") (PVar "reg")) (EBlock (DoLet false false (PVar "key") (EApp (EVar "symbolKey") (EVar "sym"))) (DoLet false false (PVar "reg2") (ERecordUpdate (EVar "reg") ((fa "entries" (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "entry")) (EFieldAccess (EVar "reg") "entries"))) (fa "waiting" (EApp (EApp (EVar "omDelete") (EVar "key")) (EFieldAccess (EVar "reg") "waiting")))))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EVar "reg") "waiting")) (arm (PCon "None") () (EApp (EVar "Ok") (EVar "reg2"))) (arm (PCon "Some" (PVar "uses")) () (EApp (EApp (EApp (EVar "judgeWaiting") (EVar "entry")) (EApp (EVar "reverseL") (EVar "uses"))) (EVar "reg2")))))))
(DTypeSig false "judgeWaiting" (TyFun (TyCon "Entry") (TyFun (TyApp (TyCon "List") (TyCon "Waiting")) (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry"))))))
(DFunDef false "judgeWaiting" (PWild (PList) (PVar "reg")) (EApp (EVar "Ok") (EVar "reg")))
(DFunDef false "judgeWaiting" ((PVar "entry") (PCons (PCon "Waiting" (PVar "sym") (PVar "operands") (PVar "at")) (PVar "rest")) (PVar "reg")) (EMatch (EApp (EApp (EApp (EApp (EVar "callDefect") (EVar "sym")) (EVar "operands")) (EVar "at")) (EVar "entry")) (arm (PCon "Some" (PVar "d")) () (EApp (EVar "Err") (EVar "d"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "judgeWaiting") (EVar "entry")) (EVar "rest")) (EVar "reg")))))
(DTypeSig false "callDefect" (TyFun (TyCon "WasmSymbol") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "Entry") (TyApp (TyCon "Option") (TyCon "SymbolDefect")))))))
(DFunDef false "callDefect" ((PVar "sym") (PVar "operands") (PVar "at") (PCon "Entry" (PVar "shape") (PVar "defined"))) (EMatch (ETuple (EVar "operands") (EApp (EVar "paramCount") (EVar "shape"))) (arm (PTuple (PCon "Some" (PVar "n")) (PCon "Some" (PVar "m"))) () (EIf (EBinOp "==" (EVar "n") (EVar "m")) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "ShapeMismatch") (EApp (EVar "symbolName") (EVar "sym"))) (EVar "m")) (EVar "n")) (EVar "at")) (EVar "defined"))))) (arm PWild () (EVar "None"))))
(DTypeSig true "checkCall" (TyFun (TyCon "WasmSymbol") (TyFun (TyCon "Int") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry")))))))
(DFunDef false "checkCall" ((PVar "sym") (PVar "operands") (PVar "origin") (PVar "reg")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "symbolKey") (EVar "sym"))) (EFieldAccess (EVar "reg") "entries")) (arm (PCon "Some" (PVar "entry")) () (EMatch (EApp (EApp (EApp (EApp (EVar "callDefect") (EVar "sym")) (EApp (EVar "Some") (EVar "operands"))) (EVar "origin")) (EVar "entry")) (arm (PCon "Some" (PVar "d")) () (EApp (EVar "Err") (EVar "d"))) (arm (PCon "None") () (EApp (EVar "Ok") (EVar "reg"))))) (arm (PCon "None") () (EApp (EVar "Ok") (EApp (EApp (EVar "wait") (EApp (EApp (EApp (EVar "Waiting") (EVar "sym")) (EApp (EVar "Some") (EVar "operands"))) (EVar "origin"))) (EVar "reg"))))))
(DTypeSig true "checkRef" (TyFun (TyCon "WasmSymbol") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry"))))))
(DFunDef false "checkRef" ((PCon "WasmType" (PVar "t")) (PVar "origin") (PVar "reg")) (EApp (EApp (EApp (EApp (EVar "checkTypeUse") (EVar "t")) (EVar "t")) (EVar "origin")) (EVar "reg")))
(DFunDef false "checkRef" ((PCon "WasmGlobal" (PVar "g")) (PVar "origin") (PVar "reg")) (EIf (EApp (EApp (EVar "omHasKey") (EApp (EVar "symbolKey") (EApp (EVar "WasmGlobal") (EVar "g")))) (EFieldAccess (EVar "reg") "entries")) (EApp (EVar "Ok") (EVar "reg")) (EApp (EVar "Err") (EApp (EApp (EVar "UndefinedReference") (EApp (EVar "WasmGlobal") (EVar "g"))) (EVar "origin")))))
(DFunDef false "checkRef" ((PVar "sym") (PVar "origin") (PVar "reg")) (EIf (EApp (EApp (EVar "omHasKey") (EApp (EVar "symbolKey") (EVar "sym"))) (EFieldAccess (EVar "reg") "entries")) (EApp (EVar "Ok") (EVar "reg")) (EApp (EVar "Ok") (EApp (EApp (EVar "wait") (EApp (EApp (EApp (EVar "Waiting") (EVar "sym")) (EVar "None")) (EVar "origin"))) (EVar "reg")))))
(DTypeSig true "checkTypeUse" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry")))))))
(DFunDef false "checkTypeUse" ((PVar "t") (PVar "user") (PVar "origin") (PVar "reg")) (EIf (EApp (EApp (EVar "omHasKey") (EApp (EVar "symbolKey") (EApp (EVar "WasmType") (EVar "t")))) (EFieldAccess (EVar "reg") "entries")) (EApp (EVar "Ok") (EVar "reg")) (EApp (EVar "Err") (EApp (EApp (EApp (EVar "UndeclaredType") (EVar "t")) (EVar "user")) (EVar "origin")))))
(DTypeSig false "wait" (TyFun (TyCon "Waiting") (TyFun (TyCon "SymbolRegistry") (TyCon "SymbolRegistry"))))
(DFunDef false "wait" ((PAs "w" (PCon "Waiting" (PVar "sym") PWild PWild)) (PVar "reg")) (EBlock (DoLet false false (PVar "key") (EApp (EVar "symbolKey") (EVar "sym"))) (DoLet false false (PVar "earlier") (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EVar "reg") "waiting")) (arm (PCon "Some" (PVar "uses")) () (EVar "uses")) (arm (PCon "None") () (EListLit)))) (DoExpr (ERecordUpdate (EVar "reg") ((fa "waiting" (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (EVar "w") (EVar "earlier"))) (EFieldAccess (EVar "reg") "waiting"))))))))
(DTypeSig true "excuseSymbol" (TyFun (TyCon "WasmSymbol") (TyFun (TyCon "SymbolRegistry") (TyCon "SymbolRegistry"))))
(DFunDef false "excuseSymbol" ((PVar "sym") (PVar "reg")) (ERecordUpdate (EVar "reg") ((fa "excused" (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "symbolKey") (EVar "sym"))) (ELit LUnit)) (EFieldAccess (EVar "reg") "excused"))))))
(DTypeSig true "unresolved" (TyFun (TyCon "SymbolRegistry") (TyApp (TyCon "List") (TyCon "SymbolDefect"))))
(DFunDef false "unresolved" ((PVar "reg")) (EApp (EApp (EVar "flatMap") (EApp (EVar "unresolvedAt") (EVar "reg"))) (EApp (EVar "omKeys") (EFieldAccess (EVar "reg") "waiting"))))
(DTypeSig false "unresolvedAt" (TyFun (TyCon "SymbolRegistry") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "SymbolDefect")))))
(DFunDef false "unresolvedAt" ((PVar "reg") (PVar "key")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "key")) (EFieldAccess (EVar "reg") "excused")) (EListLit) (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EVar "reg") "waiting")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "uses")) () (EMatch (EApp (EVar "reverseL") (EVar "uses")) (arm (PList) () (EListLit)) (arm (PCons (PCon "Waiting" (PVar "sym") PWild (PVar "at")) PWild) () (EListLit (EApp (EApp (EVar "missingDefect") (EVar "sym")) (EVar "at")))))))))
(DTypeSig false "missingDefect" (TyFun (TyCon "WasmSymbol") (TyFun (TyCon "SymbolOrigin") (TyCon "SymbolDefect"))))
(DFunDef false "missingDefect" ((PCon "WasmElem" (PVar "n")) (PVar "at")) (EApp (EApp (EVar "UndeclaredFuncRef") (EVar "n")) (EVar "at")))
(DFunDef false "missingDefect" ((PVar "sym") (PVar "at")) (EApp (EApp (EVar "UndefinedReference") (EVar "sym")) (EVar "at")))
(DTypeSig true "elemNames" (TyFun (TyCon "SymbolRegistry") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "elemNames" ((PVar "reg")) (EApp (EVar "reverseL") (EFieldAccess (EVar "reg") "elems")))
(DTypeSig true "defectCode" (TyFun (TyCon "SymbolDefect") (TyCon "String")))
(DFunDef false "defectCode" ((PCon "DuplicateDefinition" PWild PWild PWild)) (ELit (LString "E-PHYS-DUPLICATE")))
(DFunDef false "defectCode" ((PCon "ShapeMismatch" PWild PWild PWild PWild PWild)) (ELit (LString "E-PHYS-SHAPE")))
(DFunDef false "defectCode" ((PCon "UndefinedReference" PWild PWild)) (ELit (LString "E-PHYS-UNDEFINED")))
(DFunDef false "defectCode" ((PCon "UndeclaredType" PWild PWild PWild)) (ELit (LString "E-PHYS-UNDECLARED-TYPE")))
(DFunDef false "defectCode" ((PCon "UndeclaredFuncRef" PWild PWild)) (ELit (LString "E-PHYS-UNDECLARED-FUNCREF")))
(DTypeSig true "defectOrigin" (TyFun (TyCon "SymbolDefect") (TyCon "SymbolOrigin")))
(DFunDef false "defectOrigin" ((PCon "DuplicateDefinition" PWild (PVar "at") PWild)) (EVar "at"))
(DFunDef false "defectOrigin" ((PCon "ShapeMismatch" PWild PWild PWild (PVar "at") PWild)) (EVar "at"))
(DFunDef false "defectOrigin" ((PCon "UndefinedReference" PWild (PVar "at"))) (EVar "at"))
(DFunDef false "defectOrigin" ((PCon "UndeclaredType" PWild PWild (PVar "at"))) (EVar "at"))
(DFunDef false "defectOrigin" ((PCon "UndeclaredFuncRef" PWild (PVar "at"))) (EVar "at"))
(DTypeSig true "defectMessage" (TyFun (TyCon "SymbolDefect") (TyCon "String")))
(DFunDef false "defectMessage" ((PCon "DuplicateDefinition" (PVar "sym") (PVar "at") (PVar "first"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "in ")) (EApp (EVar "display") (EApp (EVar "bindingOf") (EVar "at")))) (ELit (LString ": the WebAssembly module would define "))) (EApp (EVar "display") (EApp (EVar "describe") (EVar "sym")))) (ELit (LString " twice, here and in "))) (EApp (EVar "display") (EApp (EVar "placeOf") (EVar "first")))) (ELit (LString "; a module may name it once"))))
(DFunDef false "defectMessage" ((PCon "ShapeMismatch" (PVar "f") (PVar "params") (PVar "operands") (PVar "at") (PVar "defined"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "in ")) (EApp (EVar "display") (EApp (EVar "bindingOf") (EVar "at")))) (ELit (LString ": a call of function `$"))) (EApp (EVar "display") (EVar "f"))) (ELit (LString "` supplies "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "operands")))) (ELit (LString " operand(s), but its definition in "))) (EApp (EVar "display") (EApp (EVar "placeOf") (EVar "defined")))) (ELit (LString " takes "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "params")))) (ELit (LString ""))))
(DFunDef false "defectMessage" ((PCon "UndefinedReference" (PVar "sym") (PVar "at"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "in ")) (EApp (EVar "display") (EApp (EVar "bindingOf") (EVar "at")))) (ELit (LString ": the WebAssembly module refers to "))) (EApp (EVar "display") (EApp (EVar "describe") (EVar "sym")))) (ELit (LString ", which nothing in it defines"))))
(DFunDef false "defectMessage" ((PCon "UndeclaredType" (PVar "t") (PVar "user") (PVar "at"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "in ")) (EApp (EVar "display") (EApp (EVar "bindingOf") (EVar "at")))) (ELit (LString ": `$"))) (EApp (EVar "display") (EVar "user"))) (ELit (LString "` is declared with type `$"))) (EApp (EVar "display") (EVar "t"))) (ELit (LString "`, which this module's type section does not declare"))))
(DFunDef false "defectMessage" ((PCon "UndeclaredFuncRef" (PVar "f") (PVar "at"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "in ")) (EApp (EVar "display") (EApp (EVar "bindingOf") (EVar "at")))) (ELit (LString ": `ref.func $"))) (EApp (EVar "display") (EVar "f"))) (ELit (LString "` names a function no element declaration lists"))))
(DTypeSig false "describe" (TyFun (TyCon "WasmSymbol") (TyCon "String")))
(DFunDef false "describe" ((PCon "WasmFunc" (PVar "n"))) (EBinOp "++" (EBinOp "++" (ELit (LString "function `$")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "`"))))
(DFunDef false "describe" ((PCon "WasmType" (PVar "n"))) (EBinOp "++" (EBinOp "++" (ELit (LString "type `$")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "`"))))
(DFunDef false "describe" ((PCon "WasmGlobal" (PVar "n"))) (EBinOp "++" (EBinOp "++" (ELit (LString "global `$")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "`"))))
(DFunDef false "describe" ((PCon "WasmElem" (PVar "n"))) (EBinOp "++" (EBinOp "++" (ELit (LString "element entry `$")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "`"))))
(DTypeSig false "bindingOf" (TyFun (TyCon "SymbolOrigin") (TyCon "String")))
(DFunDef false "bindingOf" ((PCon "SymbolOrigin" (PVar "b") PWild PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "b"))) (ELit (LString "`"))))
(DTypeSig false "placeOf" (TyFun (TyCon "SymbolOrigin") (TyCon "String")))
(DFunDef false "placeOf" ((PCon "SymbolOrigin" (PVar "b") (PLit (LString "")) PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "b"))) (ELit (LString "`"))))
(DFunDef false "placeOf" ((PCon "SymbolOrigin" (PVar "b") (PVar "file") (PVar "line") (PVar "col"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "b"))) (ELit (LString "` ("))) (EApp (EVar "display") (EVar "file"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "col")))) (ELit (LString ")"))))
# MARK
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omDelete" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omKeys" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false))))
(DData Public "WasmSymbol" () ((variant "WasmFunc" (ConPos (TyCon "String"))) (variant "WasmType" (ConPos (TyCon "String"))) (variant "WasmGlobal" (ConPos (TyCon "String"))) (variant "WasmElem" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "WasmSymbol")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "WasmFunc" (PVar "__a0")) (PCon "WasmFunc" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "WasmType" (PVar "__a0")) (PCon "WasmType" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "WasmGlobal" (PVar "__a0")) (PCon "WasmGlobal" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "WasmElem" (PVar "__a0")) (PCon "WasmElem" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "WasmSymbol")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "WasmFunc" (PVar "__a0")) () (EBinOp "++" (ELit (LString "WasmFunc ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "WasmType" (PVar "__a0")) () (EBinOp "++" (ELit (LString "WasmType ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "WasmGlobal" (PVar "__a0")) () (EBinOp "++" (ELit (LString "WasmGlobal ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "WasmElem" (PVar "__a0")) () (EBinOp "++" (ELit (LString "WasmElem ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))))))))
(DData Public "WasmShape" () ((variant "FuncParams" (ConPos (TyCon "Int"))) (variant "FuncOfType" (ConPos (TyCon "String") (TyCon "Int"))) (variant "FuncImported" (ConPos)) (variant "TypeDecl" (ConPos)) (variant "GlobalDecl" (ConPos)) (variant "ElemDecl" (ConPos))) ())
(DImpl true "Eq" ((TyCon "WasmShape")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "FuncParams" (PVar "__a0")) (PCon "FuncParams" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "FuncOfType" (PVar "__a0") (PVar "__a1")) (PCon "FuncOfType" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "FuncImported") (PCon "FuncImported")) () (EVar "True")) (arm (PTuple (PCon "TypeDecl") (PCon "TypeDecl")) () (EVar "True")) (arm (PTuple (PCon "GlobalDecl") (PCon "GlobalDecl")) () (EVar "True")) (arm (PTuple (PCon "ElemDecl") (PCon "ElemDecl")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "WasmShape")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "FuncParams" (PVar "__a0")) () (EBinOp "++" (ELit (LString "FuncParams ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "FuncOfType" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FuncOfType ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1"))))) (arm (PCon "FuncImported") () (ELit (LString "FuncImported"))) (arm (PCon "TypeDecl") () (ELit (LString "TypeDecl"))) (arm (PCon "GlobalDecl") () (ELit (LString "GlobalDecl"))) (arm (PCon "ElemDecl") () (ELit (LString "ElemDecl")))))))
(DData Public "SymbolOrigin" () ((variant "SymbolOrigin" (ConPos (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "SymbolOrigin")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "SymbolOrigin" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) (PCon "SymbolOrigin" (PVar "__b0") (PVar "__b1") (PVar "__b2") (PVar "__b3"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "SymbolOrigin")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "SymbolOrigin" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "SymbolOrigin ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a3")))))))))
(DData Public "SymbolDefect" () ((variant "DuplicateDefinition" (ConPos (TyCon "WasmSymbol") (TyCon "SymbolOrigin") (TyCon "SymbolOrigin"))) (variant "ShapeMismatch" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Int") (TyCon "SymbolOrigin") (TyCon "SymbolOrigin"))) (variant "UndefinedReference" (ConPos (TyCon "WasmSymbol") (TyCon "SymbolOrigin"))) (variant "UndeclaredType" (ConPos (TyCon "String") (TyCon "String") (TyCon "SymbolOrigin"))) (variant "UndeclaredFuncRef" (ConPos (TyCon "String") (TyCon "SymbolOrigin")))) ())
(DImpl true "Eq" ((TyCon "SymbolDefect")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "DuplicateDefinition" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "DuplicateDefinition" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple (PCon "ShapeMismatch" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3") (PVar "__a4")) (PCon "ShapeMismatch" (PVar "__b0") (PVar "__b1") (PVar "__b2") (PVar "__b3") (PVar "__b4"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EMethodRef "eq") (EVar "__a4")) (EVar "__b4")))) (arm (PTuple (PCon "UndefinedReference" (PVar "__a0") (PVar "__a1")) (PCon "UndefinedReference" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "UndeclaredType" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "UndeclaredType" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple (PCon "UndeclaredFuncRef" (PVar "__a0") (PVar "__a1")) (PCon "UndeclaredFuncRef" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "SymbolDefect")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "DuplicateDefinition" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "DuplicateDefinition ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a2"))))) (arm (PCon "ShapeMismatch" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3") (PVar "__a4")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ShapeMismatch ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a3")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a4"))))) (arm (PCon "UndefinedReference" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "UndefinedReference ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1"))))) (arm (PCon "UndeclaredType" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "UndeclaredType ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a2"))))) (arm (PCon "UndeclaredFuncRef" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "UndeclaredFuncRef ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))))))))
(DData Private "Entry" () ((variant "Entry" (ConPos (TyCon "WasmShape") (TyCon "SymbolOrigin")))) ())
(DData Private "Waiting" () ((variant "Waiting" (ConPos (TyCon "WasmSymbol") (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "SymbolOrigin")))) ())
(DData Abstract "SymbolRegistry" () ((variant "SymbolRegistry" (ConNamed (field "entries" (TyApp (TyCon "OrdMap") (TyCon "Entry"))) (field "waiting" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Waiting")))) (field "excused" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "elems" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig true "emptyRegistry" (TyCon "SymbolRegistry"))
(DFunDef false "emptyRegistry" () (ERecordCreate "SymbolRegistry" ((fa "entries" (EVar "omEmpty")) (fa "waiting" (EVar "omEmpty")) (fa "excused" (EVar "omEmpty")) (fa "elems" (EListLit)))))
(DTypeSig false "symbolKey" (TyFun (TyCon "WasmSymbol") (TyCon "String")))
(DFunDef false "symbolKey" ((PCon "WasmFunc" (PVar "n"))) (EBinOp "++" (ELit (LString "f:")) (EVar "n")))
(DFunDef false "symbolKey" ((PCon "WasmType" (PVar "n"))) (EBinOp "++" (ELit (LString "t:")) (EVar "n")))
(DFunDef false "symbolKey" ((PCon "WasmGlobal" (PVar "n"))) (EBinOp "++" (ELit (LString "g:")) (EVar "n")))
(DFunDef false "symbolKey" ((PCon "WasmElem" (PVar "n"))) (EBinOp "++" (ELit (LString "e:")) (EVar "n")))
(DTypeSig false "symbolName" (TyFun (TyCon "WasmSymbol") (TyCon "String")))
(DFunDef false "symbolName" ((PCon "WasmFunc" (PVar "n"))) (EVar "n"))
(DFunDef false "symbolName" ((PCon "WasmType" (PVar "n"))) (EVar "n"))
(DFunDef false "symbolName" ((PCon "WasmGlobal" (PVar "n"))) (EVar "n"))
(DFunDef false "symbolName" ((PCon "WasmElem" (PVar "n"))) (EVar "n"))
(DTypeSig false "paramCount" (TyFun (TyCon "WasmShape") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "paramCount" ((PCon "FuncParams" (PVar "n"))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "paramCount" ((PCon "FuncOfType" PWild (PVar "n"))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "paramCount" (PWild) (EVar "None"))
(DTypeSig true "declareSymbol" (TyFun (TyCon "WasmSymbol") (TyFun (TyCon "WasmShape") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry")))))))
(DFunDef false "declareSymbol" ((PVar "sym") (PVar "shape") (PVar "origin") (PVar "reg")) (EApp (EApp (EApp (EApp (EVar "admit") (EVar "sym")) (EVar "shape")) (EVar "origin")) (EVar "reg")))
(DTypeSig true "defineSymbol" (TyFun (TyCon "WasmSymbol") (TyFun (TyCon "WasmShape") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry")))))))
(DFunDef false "defineSymbol" ((PVar "sym") (PVar "shape") (PVar "origin") (PVar "reg")) (EApp (EApp (EApp (EApp (EVar "admit") (EVar "sym")) (EVar "shape")) (EVar "origin")) (EVar "reg")))
(DTypeSig false "admit" (TyFun (TyCon "WasmSymbol") (TyFun (TyCon "WasmShape") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry")))))))
(DFunDef false "admit" ((PCon "WasmElem" (PVar "n")) PWild (PVar "origin") (PVar "reg")) (EIf (EApp (EApp (EVar "omHasKey") (EApp (EVar "symbolKey") (EApp (EVar "WasmElem") (EVar "n")))) (EFieldAccess (EVar "reg") "entries")) (EApp (EVar "Ok") (EVar "reg")) (EApp (EApp (EApp (EVar "settle") (EApp (EVar "WasmElem") (EVar "n"))) (EApp (EApp (EVar "Entry") (EVar "ElemDecl")) (EVar "origin"))) (ERecordUpdate (EVar "reg") ((fa "elems" (EBinOp "::" (EVar "n") (EFieldAccess (EVar "reg") "elems"))))))))
(DFunDef false "admit" ((PVar "sym") (PVar "shape") (PVar "origin") (PVar "reg")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "symbolKey") (EVar "sym"))) (EFieldAccess (EVar "reg") "entries")) (arm (PCon "Some" (PCon "Entry" PWild (PVar "first"))) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "DuplicateDefinition") (EVar "sym")) (EVar "origin")) (EVar "first")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "settle") (EVar "sym")) (EApp (EApp (EVar "Entry") (EVar "shape")) (EVar "origin"))) (EVar "reg")))))
(DTypeSig false "settle" (TyFun (TyCon "WasmSymbol") (TyFun (TyCon "Entry") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry"))))))
(DFunDef false "settle" ((PVar "sym") (PVar "entry") (PVar "reg")) (EBlock (DoLet false false (PVar "key") (EApp (EVar "symbolKey") (EVar "sym"))) (DoLet false false (PVar "reg2") (ERecordUpdate (EVar "reg") ((fa "entries" (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "entry")) (EFieldAccess (EVar "reg") "entries"))) (fa "waiting" (EApp (EApp (EVar "omDelete") (EVar "key")) (EFieldAccess (EVar "reg") "waiting")))))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EVar "reg") "waiting")) (arm (PCon "None") () (EApp (EVar "Ok") (EVar "reg2"))) (arm (PCon "Some" (PVar "uses")) () (EApp (EApp (EApp (EVar "judgeWaiting") (EVar "entry")) (EApp (EVar "reverseL") (EVar "uses"))) (EVar "reg2")))))))
(DTypeSig false "judgeWaiting" (TyFun (TyCon "Entry") (TyFun (TyApp (TyCon "List") (TyCon "Waiting")) (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry"))))))
(DFunDef false "judgeWaiting" (PWild (PList) (PVar "reg")) (EApp (EVar "Ok") (EVar "reg")))
(DFunDef false "judgeWaiting" ((PVar "entry") (PCons (PCon "Waiting" (PVar "sym") (PVar "operands") (PVar "at")) (PVar "rest")) (PVar "reg")) (EMatch (EApp (EApp (EApp (EApp (EVar "callDefect") (EVar "sym")) (EVar "operands")) (EVar "at")) (EVar "entry")) (arm (PCon "Some" (PVar "d")) () (EApp (EVar "Err") (EVar "d"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "judgeWaiting") (EVar "entry")) (EVar "rest")) (EVar "reg")))))
(DTypeSig false "callDefect" (TyFun (TyCon "WasmSymbol") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "Entry") (TyApp (TyCon "Option") (TyCon "SymbolDefect")))))))
(DFunDef false "callDefect" ((PVar "sym") (PVar "operands") (PVar "at") (PCon "Entry" (PVar "shape") (PVar "defined"))) (EMatch (ETuple (EVar "operands") (EApp (EVar "paramCount") (EVar "shape"))) (arm (PTuple (PCon "Some" (PVar "n")) (PCon "Some" (PVar "m"))) () (EIf (EBinOp "==" (EVar "n") (EVar "m")) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "ShapeMismatch") (EApp (EVar "symbolName") (EVar "sym"))) (EVar "m")) (EVar "n")) (EVar "at")) (EVar "defined"))))) (arm PWild () (EVar "None"))))
(DTypeSig true "checkCall" (TyFun (TyCon "WasmSymbol") (TyFun (TyCon "Int") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry")))))))
(DFunDef false "checkCall" ((PVar "sym") (PVar "operands") (PVar "origin") (PVar "reg")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "symbolKey") (EVar "sym"))) (EFieldAccess (EVar "reg") "entries")) (arm (PCon "Some" (PVar "entry")) () (EMatch (EApp (EApp (EApp (EApp (EVar "callDefect") (EVar "sym")) (EApp (EVar "Some") (EVar "operands"))) (EVar "origin")) (EVar "entry")) (arm (PCon "Some" (PVar "d")) () (EApp (EVar "Err") (EVar "d"))) (arm (PCon "None") () (EApp (EVar "Ok") (EVar "reg"))))) (arm (PCon "None") () (EApp (EVar "Ok") (EApp (EApp (EVar "wait") (EApp (EApp (EApp (EVar "Waiting") (EVar "sym")) (EApp (EVar "Some") (EVar "operands"))) (EVar "origin"))) (EVar "reg"))))))
(DTypeSig true "checkRef" (TyFun (TyCon "WasmSymbol") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry"))))))
(DFunDef false "checkRef" ((PCon "WasmType" (PVar "t")) (PVar "origin") (PVar "reg")) (EApp (EApp (EApp (EApp (EVar "checkTypeUse") (EVar "t")) (EVar "t")) (EVar "origin")) (EVar "reg")))
(DFunDef false "checkRef" ((PCon "WasmGlobal" (PVar "g")) (PVar "origin") (PVar "reg")) (EIf (EApp (EApp (EVar "omHasKey") (EApp (EVar "symbolKey") (EApp (EVar "WasmGlobal") (EVar "g")))) (EFieldAccess (EVar "reg") "entries")) (EApp (EVar "Ok") (EVar "reg")) (EApp (EVar "Err") (EApp (EApp (EVar "UndefinedReference") (EApp (EVar "WasmGlobal") (EVar "g"))) (EVar "origin")))))
(DFunDef false "checkRef" ((PVar "sym") (PVar "origin") (PVar "reg")) (EIf (EApp (EApp (EVar "omHasKey") (EApp (EVar "symbolKey") (EVar "sym"))) (EFieldAccess (EVar "reg") "entries")) (EApp (EVar "Ok") (EVar "reg")) (EApp (EVar "Ok") (EApp (EApp (EVar "wait") (EApp (EApp (EApp (EVar "Waiting") (EVar "sym")) (EVar "None")) (EVar "origin"))) (EVar "reg")))))
(DTypeSig true "checkTypeUse" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry")))))))
(DFunDef false "checkTypeUse" ((PVar "t") (PVar "user") (PVar "origin") (PVar "reg")) (EIf (EApp (EApp (EVar "omHasKey") (EApp (EVar "symbolKey") (EApp (EVar "WasmType") (EVar "t")))) (EFieldAccess (EVar "reg") "entries")) (EApp (EVar "Ok") (EVar "reg")) (EApp (EVar "Err") (EApp (EApp (EApp (EVar "UndeclaredType") (EVar "t")) (EVar "user")) (EVar "origin")))))
(DTypeSig false "wait" (TyFun (TyCon "Waiting") (TyFun (TyCon "SymbolRegistry") (TyCon "SymbolRegistry"))))
(DFunDef false "wait" ((PAs "w" (PCon "Waiting" (PVar "sym") PWild PWild)) (PVar "reg")) (EBlock (DoLet false false (PVar "key") (EApp (EVar "symbolKey") (EVar "sym"))) (DoLet false false (PVar "earlier") (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EVar "reg") "waiting")) (arm (PCon "Some" (PVar "uses")) () (EVar "uses")) (arm (PCon "None") () (EListLit)))) (DoExpr (ERecordUpdate (EVar "reg") ((fa "waiting" (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (EVar "w") (EVar "earlier"))) (EFieldAccess (EVar "reg") "waiting"))))))))
(DTypeSig true "excuseSymbol" (TyFun (TyCon "WasmSymbol") (TyFun (TyCon "SymbolRegistry") (TyCon "SymbolRegistry"))))
(DFunDef false "excuseSymbol" ((PVar "sym") (PVar "reg")) (ERecordUpdate (EVar "reg") ((fa "excused" (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "symbolKey") (EVar "sym"))) (ELit LUnit)) (EFieldAccess (EVar "reg") "excused"))))))
(DTypeSig true "unresolved" (TyFun (TyCon "SymbolRegistry") (TyApp (TyCon "List") (TyCon "SymbolDefect"))))
(DFunDef false "unresolved" ((PVar "reg")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "unresolvedAt") (EVar "reg"))) (EApp (EVar "omKeys") (EFieldAccess (EVar "reg") "waiting"))))
(DTypeSig false "unresolvedAt" (TyFun (TyCon "SymbolRegistry") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "SymbolDefect")))))
(DFunDef false "unresolvedAt" ((PVar "reg") (PVar "key")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "key")) (EFieldAccess (EVar "reg") "excused")) (EListLit) (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EVar "reg") "waiting")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "uses")) () (EMatch (EApp (EVar "reverseL") (EVar "uses")) (arm (PList) () (EListLit)) (arm (PCons (PCon "Waiting" (PVar "sym") PWild (PVar "at")) PWild) () (EListLit (EApp (EApp (EVar "missingDefect") (EVar "sym")) (EVar "at")))))))))
(DTypeSig false "missingDefect" (TyFun (TyCon "WasmSymbol") (TyFun (TyCon "SymbolOrigin") (TyCon "SymbolDefect"))))
(DFunDef false "missingDefect" ((PCon "WasmElem" (PVar "n")) (PVar "at")) (EApp (EApp (EVar "UndeclaredFuncRef") (EVar "n")) (EVar "at")))
(DFunDef false "missingDefect" ((PVar "sym") (PVar "at")) (EApp (EApp (EVar "UndefinedReference") (EVar "sym")) (EVar "at")))
(DTypeSig true "elemNames" (TyFun (TyCon "SymbolRegistry") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "elemNames" ((PVar "reg")) (EApp (EVar "reverseL") (EFieldAccess (EVar "reg") "elems")))
(DTypeSig true "defectCode" (TyFun (TyCon "SymbolDefect") (TyCon "String")))
(DFunDef false "defectCode" ((PCon "DuplicateDefinition" PWild PWild PWild)) (ELit (LString "E-PHYS-DUPLICATE")))
(DFunDef false "defectCode" ((PCon "ShapeMismatch" PWild PWild PWild PWild PWild)) (ELit (LString "E-PHYS-SHAPE")))
(DFunDef false "defectCode" ((PCon "UndefinedReference" PWild PWild)) (ELit (LString "E-PHYS-UNDEFINED")))
(DFunDef false "defectCode" ((PCon "UndeclaredType" PWild PWild PWild)) (ELit (LString "E-PHYS-UNDECLARED-TYPE")))
(DFunDef false "defectCode" ((PCon "UndeclaredFuncRef" PWild PWild)) (ELit (LString "E-PHYS-UNDECLARED-FUNCREF")))
(DTypeSig true "defectOrigin" (TyFun (TyCon "SymbolDefect") (TyCon "SymbolOrigin")))
(DFunDef false "defectOrigin" ((PCon "DuplicateDefinition" PWild (PVar "at") PWild)) (EVar "at"))
(DFunDef false "defectOrigin" ((PCon "ShapeMismatch" PWild PWild PWild (PVar "at") PWild)) (EVar "at"))
(DFunDef false "defectOrigin" ((PCon "UndefinedReference" PWild (PVar "at"))) (EVar "at"))
(DFunDef false "defectOrigin" ((PCon "UndeclaredType" PWild PWild (PVar "at"))) (EVar "at"))
(DFunDef false "defectOrigin" ((PCon "UndeclaredFuncRef" PWild (PVar "at"))) (EVar "at"))
(DTypeSig true "defectMessage" (TyFun (TyCon "SymbolDefect") (TyCon "String")))
(DFunDef false "defectMessage" ((PCon "DuplicateDefinition" (PVar "sym") (PVar "at") (PVar "first"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "in ")) (EApp (EMethodRef "display") (EApp (EVar "bindingOf") (EVar "at")))) (ELit (LString ": the WebAssembly module would define "))) (EApp (EMethodRef "display") (EApp (EVar "describe") (EVar "sym")))) (ELit (LString " twice, here and in "))) (EApp (EMethodRef "display") (EApp (EVar "placeOf") (EVar "first")))) (ELit (LString "; a module may name it once"))))
(DFunDef false "defectMessage" ((PCon "ShapeMismatch" (PVar "f") (PVar "params") (PVar "operands") (PVar "at") (PVar "defined"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "in ")) (EApp (EMethodRef "display") (EApp (EVar "bindingOf") (EVar "at")))) (ELit (LString ": a call of function `$"))) (EApp (EMethodRef "display") (EVar "f"))) (ELit (LString "` supplies "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "operands")))) (ELit (LString " operand(s), but its definition in "))) (EApp (EMethodRef "display") (EApp (EVar "placeOf") (EVar "defined")))) (ELit (LString " takes "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "params")))) (ELit (LString ""))))
(DFunDef false "defectMessage" ((PCon "UndefinedReference" (PVar "sym") (PVar "at"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "in ")) (EApp (EMethodRef "display") (EApp (EVar "bindingOf") (EVar "at")))) (ELit (LString ": the WebAssembly module refers to "))) (EApp (EMethodRef "display") (EApp (EVar "describe") (EVar "sym")))) (ELit (LString ", which nothing in it defines"))))
(DFunDef false "defectMessage" ((PCon "UndeclaredType" (PVar "t") (PVar "user") (PVar "at"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "in ")) (EApp (EMethodRef "display") (EApp (EVar "bindingOf") (EVar "at")))) (ELit (LString ": `$"))) (EApp (EMethodRef "display") (EVar "user"))) (ELit (LString "` is declared with type `$"))) (EApp (EMethodRef "display") (EVar "t"))) (ELit (LString "`, which this module's type section does not declare"))))
(DFunDef false "defectMessage" ((PCon "UndeclaredFuncRef" (PVar "f") (PVar "at"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "in ")) (EApp (EMethodRef "display") (EApp (EVar "bindingOf") (EVar "at")))) (ELit (LString ": `ref.func $"))) (EApp (EMethodRef "display") (EVar "f"))) (ELit (LString "` names a function no element declaration lists"))))
(DTypeSig false "describe" (TyFun (TyCon "WasmSymbol") (TyCon "String")))
(DFunDef false "describe" ((PCon "WasmFunc" (PVar "n"))) (EBinOp "++" (EBinOp "++" (ELit (LString "function `$")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "`"))))
(DFunDef false "describe" ((PCon "WasmType" (PVar "n"))) (EBinOp "++" (EBinOp "++" (ELit (LString "type `$")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "`"))))
(DFunDef false "describe" ((PCon "WasmGlobal" (PVar "n"))) (EBinOp "++" (EBinOp "++" (ELit (LString "global `$")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "`"))))
(DFunDef false "describe" ((PCon "WasmElem" (PVar "n"))) (EBinOp "++" (EBinOp "++" (ELit (LString "element entry `$")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "`"))))
(DTypeSig false "bindingOf" (TyFun (TyCon "SymbolOrigin") (TyCon "String")))
(DFunDef false "bindingOf" ((PCon "SymbolOrigin" (PVar "b") PWild PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString "`"))))
(DTypeSig false "placeOf" (TyFun (TyCon "SymbolOrigin") (TyCon "String")))
(DFunDef false "placeOf" ((PCon "SymbolOrigin" (PVar "b") (PLit (LString "")) PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString "`"))))
(DFunDef false "placeOf" ((PCon "SymbolOrigin" (PVar "b") (PVar "file") (PVar "line") (PVar "col"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString "` ("))) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "col")))) (ELit (LString ")"))))
