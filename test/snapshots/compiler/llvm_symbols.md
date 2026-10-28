# META
source_lines=327
stages=DESUGAR,MARK
# SOURCE
-- The physical symbols of one LLVM module under emission: each function and
-- global variable the emitter declares or defines, the prototype it gave, and the
-- binding whose emission wrote it.  A definition, declaration or direct call
-- that contradicts the registry is a `SymbolDefect`, which the emitter returns
-- to its driver instead of a module text.
--
-- LLVM has one namespace for functions and global variables, and its text format
-- refuses a name written twice, even as two identical `declare`s.  So a second
-- definition of a name, or a declaration of a name already defined, is a defect.
-- A declaration repeated with the same signature is the one thing the registry
-- accepts twice; the emitter writes it once.
--
-- A function may be called before it is defined (`@mdk_program_main` is emitted
-- before every function it calls), so a call to a name with no entry yet waits,
-- and so does a use of a name's address: a call is judged against the prototype
-- when that arrives, and whatever still waits
-- once the module is complete is `unresolved`.  A whole module (no prelude
-- object) is the only Medaka code in its link, so there a generated symbol that is
-- only declared is unresolved too; a module half declares the other half's.

import support.diag_codes.{DiagCode(..)}
import support.ordmap.{
  OrdMap, omDelete, omEmpty, omHasKey, omInsert, omKeys, omLookup
}
import support.symbol_origin.{SymbolOrigin, bindingOf, placeOf}
import support.util.{joinWith, reverseL}

-- A global name, without its `@`.  `Generated` is a symbol the emitter writes a
-- definition for, in this emission or in the other half of a prelude-object
-- build; `Foreign` is one the link supplies (the runtime, a user FFI symbol, a
-- site-trap entry, an `llvm.*` intrinsic).  Neither is a failure, so `Result`
-- would misread it.
-- lint-disable-next-line rule-clone-type
public export data LlvmSymbol =
  | Generated String
  | Foreign String
  deriving (Eq, Debug)

-- One parameter: its LLVM type and its register name ("" where a `declare`
-- names none).
public export data LlvmParam = LlvmParam String String deriving (Eq, Debug)

-- What a declaration or definition says the symbol is: a function with its
-- return type, parameters and the attributes written after its parameter list
-- (` noinline`, ` noreturn`, or ""), or a global variable of a value type.
public export data Prototype =
  | FuncProto String (List LlvmParam) String
  | DataProto String
  deriving (Eq, Debug)

-- A direct call: the return type it expects and the types of its operands.
public export data CallShape =
  CallShape String (List String)
  deriving (Eq, Debug)

-- Whether the module is the only Medaka code in its link.
public export data ModuleScope = WholeModule | ModuleHalf deriving (Eq, Debug)

public export data SymbolDefect =
  | DuplicateDefinition String SymbolOrigin SymbolOrigin  -- the name, where it was written again, where it was first written
  -- the name, the prototype written again, the one written first, where each was
  -- written
  | PrototypeConflict String Prototype Prototype SymbolOrigin SymbolOrigin
  -- the function, the call's shape, the prototype, the call, the declaration
  | ShapeMismatch String CallShape Prototype SymbolOrigin SymbolOrigin
  -- a function some call names, or a generated symbol a whole module only
  -- declares, that nothing in the module defines
  | UndefinedReference String SymbolOrigin
  deriving (Eq, Debug)

data Binding = Declared | Defined deriving (Eq)

data Entry = Entry Binding LlvmSymbol Prototype SymbolOrigin

-- a call, with its shape, or a reference to an address, still waiting for its
-- symbol
data Waiting = Waiting (Option CallShape) SymbolOrigin

export data SymbolRegistry = SymbolRegistry {
  scope : ModuleScope,
  entries : OrdMap Entry,
  waiting : OrdMap (List Waiting),
  excused : OrdMap Unit,
}

export
emptyRegistry : ModuleScope -> SymbolRegistry
emptyRegistry scope = SymbolRegistry {
  scope = scope,
  entries = omEmpty,
  waiting = omEmpty,
  excused = omEmpty,
}

-- the global name, without its `@`
export
symbolName : LlvmSymbol -> String
symbolName (Generated n) = n
symbolName (Foreign n) = n

-- A symbol the module receives rather than defines: an `external` global, or a
-- function `declare`.
export
declareSymbol : LlvmSymbol ->
  Prototype ->
  SymbolOrigin ->
  SymbolRegistry ->
  Result SymbolDefect SymbolRegistry
declareSymbol sym proto origin reg =
  let name = symbolName sym
  match omLookup name reg.entries
    None => settle name (Entry Declared sym proto origin) reg
    Some (Entry Declared _ first at) =>
      if sameSignature proto first then
        Ok reg
      else
        Err (PrototypeConflict name proto first origin at)
    Some (Entry Defined _ first at) =>
      Err (secondWrite name proto origin first at)

-- A function the emitter writes a body for, or a global variable it gives
-- storage.
export
defineSymbol : LlvmSymbol ->
  Prototype ->
  SymbolOrigin ->
  SymbolRegistry ->
  Result SymbolDefect SymbolRegistry
defineSymbol sym proto origin reg = writeOnce Defined sym proto origin reg

-- A declaration the module writes each time it is registered (a row of the
-- runtime preamble), so an earlier entry for its name, however compatible, is a
-- second write.
export
declareOnce : LlvmSymbol ->
  Prototype ->
  SymbolOrigin ->
  SymbolRegistry ->
  Result SymbolDefect SymbolRegistry
declareOnce sym proto origin reg = writeOnce Declared sym proto origin reg

writeOnce : Binding ->
  LlvmSymbol ->
  Prototype ->
  SymbolOrigin ->
  SymbolRegistry ->
  Result SymbolDefect SymbolRegistry
writeOnce binding sym proto origin reg =
  let name = symbolName sym
  match omLookup name reg.entries
    None => settle name (Entry binding sym proto origin) reg
    Some (Entry _ _ first at) => Err (secondWrite name proto origin first at)

-- The defect of writing [name] again with [proto] where [first] was written: a
-- function and a global variable are two things under one name, and so are two
-- of either alike; two of either that disagree contradict each other.
secondWrite : String ->
  Prototype ->
  SymbolOrigin ->
  Prototype ->
  SymbolOrigin ->
  SymbolDefect
secondWrite name proto origin first at =
  if sameKind proto first && not (sameSignature proto first) then
    PrototypeConflict name proto first origin at
  else
    DuplicateDefinition name origin at

sameKind : Prototype -> Prototype -> Bool
sameKind (FuncProto _ _ _) (FuncProto _ _ _) = True
sameKind (DataProto _) (DataProto _) = True
sameKind _ _ = False

-- Two prototypes name the same LLVM type: register names and attributes aside.
sameSignature : Prototype -> Prototype -> Bool
sameSignature (FuncProto r1 ps1 _) (FuncProto r2 ps2 _) =
  r1 == r2 && map paramType ps1 == map paramType ps2
sameSignature (DataProto t1) (DataProto t2) = t1 == t2
sameSignature _ _ = False

paramType : LlvmParam -> String
paramType (LlvmParam t _) = t

-- record [entry] for [name], then judge every call that waited for it
settle : String -> Entry -> SymbolRegistry -> Result SymbolDefect SymbolRegistry
settle name entry reg =
  let reg2 = { reg |
    entries = omInsert name entry reg.entries,
    waiting = omDelete name reg.waiting,
  }
  match omLookup name reg.waiting
    None => Ok reg2
    Some calls => judgeWaiting name entry (reverseL calls) reg2

judgeWaiting : String ->
  Entry ->
  List Waiting ->
  SymbolRegistry ->
  Result SymbolDefect SymbolRegistry
judgeWaiting _ _ [] reg = Ok reg
judgeWaiting name entry ((Waiting (Some shape) at) :: rest) reg =
  match callDefect name shape at entry
    Some d => Err d
    None => judgeWaiting name entry rest reg
judgeWaiting name entry ((Waiting None _) :: rest) reg =
  judgeWaiting name entry rest reg

callDefect : String -> CallShape -> SymbolOrigin -> Entry -> Option SymbolDefect
callDefect name (shape@(CallShape ret operands)) at (Entry _ _ proto declared) =
  match proto
    FuncProto r ps _ =>
      if r == ret && map paramType ps == operands then
        None
      else
        Some (ShapeMismatch name shape proto at declared)
    DataProto _ => Some (ShapeMismatch name shape proto at declared)

-- A direct call of a function with [shape].
export
checkCall : LlvmSymbol ->
  CallShape ->
  SymbolOrigin ->
  SymbolRegistry ->
  Result SymbolDefect SymbolRegistry
checkCall sym shape origin reg =
  let name = symbolName sym
  match omLookup name reg.entries
    Some entry => match callDefect name shape origin entry
      Some d => Err d
      None => Ok reg
    None => Ok (wait name (Waiting (Some shape) origin) reg)

-- A use of [sym]'s address: a load or store of a global variable, or a
-- function taken as a code pointer.  Any entry answers it; with none yet, it
-- waits like a call.
export
checkRef : LlvmSymbol ->
  SymbolOrigin ->
  SymbolRegistry ->
  Result SymbolDefect SymbolRegistry
checkRef sym origin reg =
  let name = symbolName sym
  if omHasKey name reg.entries then
    Ok reg
  else
    Ok (wait name (Waiting None origin) reg)

wait : String -> Waiting -> SymbolRegistry -> SymbolRegistry
wait name w reg =
  let earlier = optionOr [] (omLookup name reg.waiting)
  { reg | waiting = omInsert name (w :: earlier) reg.waiting }

-- [sym]'s definer recorded a gap instead of defining it, so a call of it is the
-- gap's to report, not the registry's.
export
excuseSymbol : LlvmSymbol -> SymbolRegistry -> SymbolRegistry
excuseSymbol sym reg =
  { reg | excused = omInsert (symbolName sym) () reg.excused }

-- Once the module is complete: one defect for each name some call or reference
-- still waits for, at its first use, in name order; then, in a whole module, one for each
-- generated symbol it only declares.
export
unresolved : SymbolRegistry -> List SymbolDefect
unresolved reg =
  flatMap (unresolvedAt reg) (omKeys reg.waiting)
    ++ (match reg.scope
      WholeModule => flatMap (declaredOnly reg) (omKeys reg.entries)
      ModuleHalf => [])

unresolvedAt : SymbolRegistry -> String -> List SymbolDefect
unresolvedAt reg name =
  if omHasKey name reg.excused then
    []
  else match omLookup name reg.waiting
    None => []
    Some calls => match reverseL calls
      [] => []
      (Waiting _ at) :: _ => [UndefinedReference name at]

declaredOnly : SymbolRegistry -> String -> List SymbolDefect
declaredOnly reg name = match omLookup name reg.entries
  Some (Entry Declared (Generated _) _ at) => [UndefinedReference name at]
  _ => []

-- ── rendering ───────────────────────────────────────────────────────────────

-- `<ret> @<name>(<params>)<attrs>`: a function's head as `define` and `declare`
-- both write it.
export
prototypeText : String -> Prototype -> String
prototypeText name (FuncProto ret ps attrs) =
  "\{ret} @\{name}(\{joinWith ", " (map paramText ps)})\{attrs}"
prototypeText name (DataProto t) = "@\{name} : \{t}"

paramText : LlvmParam -> String
paramText (LlvmParam t "") = t
paramText (LlvmParam t r) = "\{t} \{r}"

export
defectCode : SymbolDefect -> DiagCode
defectCode (DuplicateDefinition _ _ _) = EPhysDuplicate
defectCode (PrototypeConflict _ _ _ _ _) = EPhysShape
defectCode (ShapeMismatch _ _ _ _ _) = EPhysShape
defectCode (UndefinedReference _ _) = EPhysUndefined

-- The binding and position the defect is reported at.
export
defectOrigin : SymbolDefect -> SymbolOrigin
defectOrigin (DuplicateDefinition _ at _) = at
defectOrigin (PrototypeConflict _ _ _ at _) = at
defectOrigin (ShapeMismatch _ _ _ at _) = at
defectOrigin (UndefinedReference _ at) = at

export
defectMessage : SymbolDefect -> String
defectMessage (DuplicateDefinition name at first) =
  "in \{bindingOf at}: the LLVM module would write `@\{name}` twice, here and in \{placeOf first}; a module may declare or define a name once"
defectMessage (PrototypeConflict name proto first at earlier) =
  "in \{bindingOf at}: `@\{name}` is written here as `\{prototypeText name proto}`, but \{placeOf earlier} wrote it as `\{prototypeText name first}`"
defectMessage (ShapeMismatch name shape proto at declared) =
  "in \{bindingOf at}: a call of `@\{name}` has shape `\{shapeText shape}`, but \{placeOf declared} gives it `\{prototypeText name proto}`"
defectMessage (UndefinedReference name at) =
  "in \{bindingOf at}: the LLVM module refers to `@\{name}`, which nothing in it defines"

shapeText : CallShape -> String
shapeText (CallShape ret operands) = "\{ret} (\{joinWith ", " operands})"
# DESUGAR
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omDelete" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omKeys" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "symbol_origin") ((mem "SymbolOrigin" false) (mem "bindingOf" false) (mem "placeOf" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "reverseL" false))))
(DData Public "LlvmSymbol" () ((variant "Generated" (ConPos (TyCon "String"))) (variant "Foreign" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "LlvmSymbol")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Generated" (PVar "__a0")) (PCon "Generated" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "Foreign" (PVar "__a0")) (PCon "Foreign" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "LlvmSymbol")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Generated" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Generated ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "Foreign" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Foreign ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))))))))
(DData Public "LlvmParam" () ((variant "LlvmParam" (ConPos (TyCon "String") (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "LlvmParam")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "LlvmParam" (PVar "__a0") (PVar "__a1")) (PCon "LlvmParam" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))))))))
(DImpl true "Debug" ((TyCon "LlvmParam")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "LlvmParam" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "LlvmParam ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))))))))
(DData Public "Prototype" () ((variant "FuncProto" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "LlvmParam")) (TyCon "String"))) (variant "DataProto" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "Prototype")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "FuncProto" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "FuncProto" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple (PCon "DataProto" (PVar "__a0")) (PCon "DataProto" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Prototype")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "FuncProto" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FuncProto ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a2"))))) (arm (PCon "DataProto" (PVar "__a0")) () (EBinOp "++" (ELit (LString "DataProto ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))))))))
(DData Public "CallShape" () ((variant "CallShape" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) ())
(DImpl true "Eq" ((TyCon "CallShape")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "CallShape" (PVar "__a0") (PVar "__a1")) (PCon "CallShape" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))))))))
(DImpl true "Debug" ((TyCon "CallShape")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "CallShape" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "CallShape ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))))))))
(DData Public "ModuleScope" () ((variant "WholeModule" (ConPos)) (variant "ModuleHalf" (ConPos))) ())
(DImpl true "Eq" ((TyCon "ModuleScope")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "WholeModule") (PCon "WholeModule")) () (EVar "True")) (arm (PTuple (PCon "ModuleHalf") (PCon "ModuleHalf")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "ModuleScope")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "WholeModule") () (ELit (LString "WholeModule"))) (arm (PCon "ModuleHalf") () (ELit (LString "ModuleHalf")))))))
(DData Public "SymbolDefect" () ((variant "DuplicateDefinition" (ConPos (TyCon "String") (TyCon "SymbolOrigin") (TyCon "SymbolOrigin"))) (variant "PrototypeConflict" (ConPos (TyCon "String") (TyCon "Prototype") (TyCon "Prototype") (TyCon "SymbolOrigin") (TyCon "SymbolOrigin"))) (variant "ShapeMismatch" (ConPos (TyCon "String") (TyCon "CallShape") (TyCon "Prototype") (TyCon "SymbolOrigin") (TyCon "SymbolOrigin"))) (variant "UndefinedReference" (ConPos (TyCon "String") (TyCon "SymbolOrigin")))) ())
(DImpl true "Eq" ((TyCon "SymbolDefect")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "DuplicateDefinition" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "DuplicateDefinition" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple (PCon "PrototypeConflict" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3") (PVar "__a4")) (PCon "PrototypeConflict" (PVar "__b0") (PVar "__b1") (PVar "__b2") (PVar "__b3") (PVar "__b4"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EVar "eq") (EVar "__a4")) (EVar "__b4")))) (arm (PTuple (PCon "ShapeMismatch" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3") (PVar "__a4")) (PCon "ShapeMismatch" (PVar "__b0") (PVar "__b1") (PVar "__b2") (PVar "__b3") (PVar "__b4"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EVar "eq") (EVar "__a4")) (EVar "__b4")))) (arm (PTuple (PCon "UndefinedReference" (PVar "__a0") (PVar "__a1")) (PCon "UndefinedReference" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "SymbolDefect")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "DuplicateDefinition" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "DuplicateDefinition ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a2"))))) (arm (PCon "PrototypeConflict" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3") (PVar "__a4")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "PrototypeConflict ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a3")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a4"))))) (arm (PCon "ShapeMismatch" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3") (PVar "__a4")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ShapeMismatch ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a3")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a4"))))) (arm (PCon "UndefinedReference" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "UndefinedReference ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))))))))
(DData Private "Binding" () ((variant "Declared" (ConPos)) (variant "Defined" (ConPos))) ())
(DImpl true "Eq" ((TyCon "Binding")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Declared") (PCon "Declared")) () (EVar "True")) (arm (PTuple (PCon "Defined") (PCon "Defined")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Private "Entry" () ((variant "Entry" (ConPos (TyCon "Binding") (TyCon "LlvmSymbol") (TyCon "Prototype") (TyCon "SymbolOrigin")))) ())
(DData Private "Waiting" () ((variant "Waiting" (ConPos (TyApp (TyCon "Option") (TyCon "CallShape")) (TyCon "SymbolOrigin")))) ())
(DData Abstract "SymbolRegistry" () ((variant "SymbolRegistry" (ConNamed (field "scope" (TyCon "ModuleScope")) (field "entries" (TyApp (TyCon "OrdMap") (TyCon "Entry"))) (field "waiting" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Waiting")))) (field "excused" (TyApp (TyCon "OrdMap") (TyCon "Unit")))))) ())
(DTypeSig true "emptyRegistry" (TyFun (TyCon "ModuleScope") (TyCon "SymbolRegistry")))
(DFunDef false "emptyRegistry" ((PVar "scope")) (ERecordCreate "SymbolRegistry" ((fa "scope" (EVar "scope")) (fa "entries" (EVar "omEmpty")) (fa "waiting" (EVar "omEmpty")) (fa "excused" (EVar "omEmpty")))))
(DTypeSig true "symbolName" (TyFun (TyCon "LlvmSymbol") (TyCon "String")))
(DFunDef false "symbolName" ((PCon "Generated" (PVar "n"))) (EVar "n"))
(DFunDef false "symbolName" ((PCon "Foreign" (PVar "n"))) (EVar "n"))
(DTypeSig true "declareSymbol" (TyFun (TyCon "LlvmSymbol") (TyFun (TyCon "Prototype") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry")))))))
(DFunDef false "declareSymbol" ((PVar "sym") (PVar "proto") (PVar "origin") (PVar "reg")) (EBlock (DoLet false false (PVar "name") (EApp (EVar "symbolName") (EVar "sym"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "reg") "entries")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "settle") (EVar "name")) (EApp (EApp (EApp (EApp (EVar "Entry") (EVar "Declared")) (EVar "sym")) (EVar "proto")) (EVar "origin"))) (EVar "reg"))) (arm (PCon "Some" (PCon "Entry" (PCon "Declared") PWild (PVar "first") (PVar "at"))) () (EIf (EApp (EApp (EVar "sameSignature") (EVar "proto")) (EVar "first")) (EApp (EVar "Ok") (EVar "reg")) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PrototypeConflict") (EVar "name")) (EVar "proto")) (EVar "first")) (EVar "origin")) (EVar "at"))))) (arm (PCon "Some" (PCon "Entry" (PCon "Defined") PWild (PVar "first") (PVar "at"))) () (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "secondWrite") (EVar "name")) (EVar "proto")) (EVar "origin")) (EVar "first")) (EVar "at"))))))))
(DTypeSig true "defineSymbol" (TyFun (TyCon "LlvmSymbol") (TyFun (TyCon "Prototype") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry")))))))
(DFunDef false "defineSymbol" ((PVar "sym") (PVar "proto") (PVar "origin") (PVar "reg")) (EApp (EApp (EApp (EApp (EApp (EVar "writeOnce") (EVar "Defined")) (EVar "sym")) (EVar "proto")) (EVar "origin")) (EVar "reg")))
(DTypeSig true "declareOnce" (TyFun (TyCon "LlvmSymbol") (TyFun (TyCon "Prototype") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry")))))))
(DFunDef false "declareOnce" ((PVar "sym") (PVar "proto") (PVar "origin") (PVar "reg")) (EApp (EApp (EApp (EApp (EApp (EVar "writeOnce") (EVar "Declared")) (EVar "sym")) (EVar "proto")) (EVar "origin")) (EVar "reg")))
(DTypeSig false "writeOnce" (TyFun (TyCon "Binding") (TyFun (TyCon "LlvmSymbol") (TyFun (TyCon "Prototype") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry"))))))))
(DFunDef false "writeOnce" ((PVar "binding") (PVar "sym") (PVar "proto") (PVar "origin") (PVar "reg")) (EBlock (DoLet false false (PVar "name") (EApp (EVar "symbolName") (EVar "sym"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "reg") "entries")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "settle") (EVar "name")) (EApp (EApp (EApp (EApp (EVar "Entry") (EVar "binding")) (EVar "sym")) (EVar "proto")) (EVar "origin"))) (EVar "reg"))) (arm (PCon "Some" (PCon "Entry" PWild PWild (PVar "first") (PVar "at"))) () (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "secondWrite") (EVar "name")) (EVar "proto")) (EVar "origin")) (EVar "first")) (EVar "at"))))))))
(DTypeSig false "secondWrite" (TyFun (TyCon "String") (TyFun (TyCon "Prototype") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "Prototype") (TyFun (TyCon "SymbolOrigin") (TyCon "SymbolDefect")))))))
(DFunDef false "secondWrite" ((PVar "name") (PVar "proto") (PVar "origin") (PVar "first") (PVar "at")) (EIf (EBinOp "&&" (EApp (EApp (EVar "sameKind") (EVar "proto")) (EVar "first")) (EApp (EVar "not") (EApp (EApp (EVar "sameSignature") (EVar "proto")) (EVar "first")))) (EApp (EApp (EApp (EApp (EApp (EVar "PrototypeConflict") (EVar "name")) (EVar "proto")) (EVar "first")) (EVar "origin")) (EVar "at")) (EApp (EApp (EApp (EVar "DuplicateDefinition") (EVar "name")) (EVar "origin")) (EVar "at"))))
(DTypeSig false "sameKind" (TyFun (TyCon "Prototype") (TyFun (TyCon "Prototype") (TyCon "Bool"))))
(DFunDef false "sameKind" ((PCon "FuncProto" PWild PWild PWild) (PCon "FuncProto" PWild PWild PWild)) (EVar "True"))
(DFunDef false "sameKind" ((PCon "DataProto" PWild) (PCon "DataProto" PWild)) (EVar "True"))
(DFunDef false "sameKind" (PWild PWild) (EVar "False"))
(DTypeSig false "sameSignature" (TyFun (TyCon "Prototype") (TyFun (TyCon "Prototype") (TyCon "Bool"))))
(DFunDef false "sameSignature" ((PCon "FuncProto" (PVar "r1") (PVar "ps1") PWild) (PCon "FuncProto" (PVar "r2") (PVar "ps2") PWild)) (EBinOp "&&" (EBinOp "==" (EVar "r1") (EVar "r2")) (EBinOp "==" (EApp (EApp (EVar "map") (EVar "paramType")) (EVar "ps1")) (EApp (EApp (EVar "map") (EVar "paramType")) (EVar "ps2")))))
(DFunDef false "sameSignature" ((PCon "DataProto" (PVar "t1")) (PCon "DataProto" (PVar "t2"))) (EBinOp "==" (EVar "t1") (EVar "t2")))
(DFunDef false "sameSignature" (PWild PWild) (EVar "False"))
(DTypeSig false "paramType" (TyFun (TyCon "LlvmParam") (TyCon "String")))
(DFunDef false "paramType" ((PCon "LlvmParam" (PVar "t") PWild)) (EVar "t"))
(DTypeSig false "settle" (TyFun (TyCon "String") (TyFun (TyCon "Entry") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry"))))))
(DFunDef false "settle" ((PVar "name") (PVar "entry") (PVar "reg")) (EBlock (DoLet false false (PVar "reg2") (ERecordUpdate (EVar "reg") ((fa "entries" (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "entry")) (EFieldAccess (EVar "reg") "entries"))) (fa "waiting" (EApp (EApp (EVar "omDelete") (EVar "name")) (EFieldAccess (EVar "reg") "waiting")))))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "reg") "waiting")) (arm (PCon "None") () (EApp (EVar "Ok") (EVar "reg2"))) (arm (PCon "Some" (PVar "calls")) () (EApp (EApp (EApp (EApp (EVar "judgeWaiting") (EVar "name")) (EVar "entry")) (EApp (EVar "reverseL") (EVar "calls"))) (EVar "reg2")))))))
(DTypeSig false "judgeWaiting" (TyFun (TyCon "String") (TyFun (TyCon "Entry") (TyFun (TyApp (TyCon "List") (TyCon "Waiting")) (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry")))))))
(DFunDef false "judgeWaiting" (PWild PWild (PList) (PVar "reg")) (EApp (EVar "Ok") (EVar "reg")))
(DFunDef false "judgeWaiting" ((PVar "name") (PVar "entry") (PCons (PCon "Waiting" (PCon "Some" (PVar "shape")) (PVar "at")) (PVar "rest")) (PVar "reg")) (EMatch (EApp (EApp (EApp (EApp (EVar "callDefect") (EVar "name")) (EVar "shape")) (EVar "at")) (EVar "entry")) (arm (PCon "Some" (PVar "d")) () (EApp (EVar "Err") (EVar "d"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "judgeWaiting") (EVar "name")) (EVar "entry")) (EVar "rest")) (EVar "reg")))))
(DFunDef false "judgeWaiting" ((PVar "name") (PVar "entry") (PCons (PCon "Waiting" (PCon "None") PWild) (PVar "rest")) (PVar "reg")) (EApp (EApp (EApp (EApp (EVar "judgeWaiting") (EVar "name")) (EVar "entry")) (EVar "rest")) (EVar "reg")))
(DTypeSig false "callDefect" (TyFun (TyCon "String") (TyFun (TyCon "CallShape") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "Entry") (TyApp (TyCon "Option") (TyCon "SymbolDefect")))))))
(DFunDef false "callDefect" ((PVar "name") (PAs "shape" (PCon "CallShape" (PVar "ret") (PVar "operands"))) (PVar "at") (PCon "Entry" PWild PWild (PVar "proto") (PVar "declared"))) (EMatch (EVar "proto") (arm (PCon "FuncProto" (PVar "r") (PVar "ps") PWild) () (EIf (EBinOp "&&" (EBinOp "==" (EVar "r") (EVar "ret")) (EBinOp "==" (EApp (EApp (EVar "map") (EVar "paramType")) (EVar "ps")) (EVar "operands"))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "ShapeMismatch") (EVar "name")) (EVar "shape")) (EVar "proto")) (EVar "at")) (EVar "declared"))))) (arm (PCon "DataProto" PWild) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "ShapeMismatch") (EVar "name")) (EVar "shape")) (EVar "proto")) (EVar "at")) (EVar "declared"))))))
(DTypeSig true "checkCall" (TyFun (TyCon "LlvmSymbol") (TyFun (TyCon "CallShape") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry")))))))
(DFunDef false "checkCall" ((PVar "sym") (PVar "shape") (PVar "origin") (PVar "reg")) (EBlock (DoLet false false (PVar "name") (EApp (EVar "symbolName") (EVar "sym"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "reg") "entries")) (arm (PCon "Some" (PVar "entry")) () (EMatch (EApp (EApp (EApp (EApp (EVar "callDefect") (EVar "name")) (EVar "shape")) (EVar "origin")) (EVar "entry")) (arm (PCon "Some" (PVar "d")) () (EApp (EVar "Err") (EVar "d"))) (arm (PCon "None") () (EApp (EVar "Ok") (EVar "reg"))))) (arm (PCon "None") () (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "wait") (EVar "name")) (EApp (EApp (EVar "Waiting") (EApp (EVar "Some") (EVar "shape"))) (EVar "origin"))) (EVar "reg"))))))))
(DTypeSig true "checkRef" (TyFun (TyCon "LlvmSymbol") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry"))))))
(DFunDef false "checkRef" ((PVar "sym") (PVar "origin") (PVar "reg")) (EBlock (DoLet false false (PVar "name") (EApp (EVar "symbolName") (EVar "sym"))) (DoExpr (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "reg") "entries")) (EApp (EVar "Ok") (EVar "reg")) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "wait") (EVar "name")) (EApp (EApp (EVar "Waiting") (EVar "None")) (EVar "origin"))) (EVar "reg")))))))
(DTypeSig false "wait" (TyFun (TyCon "String") (TyFun (TyCon "Waiting") (TyFun (TyCon "SymbolRegistry") (TyCon "SymbolRegistry")))))
(DFunDef false "wait" ((PVar "name") (PVar "w") (PVar "reg")) (EBlock (DoLet false false (PVar "earlier") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "reg") "waiting")))) (DoExpr (ERecordUpdate (EVar "reg") ((fa "waiting" (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EBinOp "::" (EVar "w") (EVar "earlier"))) (EFieldAccess (EVar "reg") "waiting"))))))))
(DTypeSig true "excuseSymbol" (TyFun (TyCon "LlvmSymbol") (TyFun (TyCon "SymbolRegistry") (TyCon "SymbolRegistry"))))
(DFunDef false "excuseSymbol" ((PVar "sym") (PVar "reg")) (ERecordUpdate (EVar "reg") ((fa "excused" (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "symbolName") (EVar "sym"))) (ELit LUnit)) (EFieldAccess (EVar "reg") "excused"))))))
(DTypeSig true "unresolved" (TyFun (TyCon "SymbolRegistry") (TyApp (TyCon "List") (TyCon "SymbolDefect"))))
(DFunDef false "unresolved" ((PVar "reg")) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EVar "unresolvedAt") (EVar "reg"))) (EApp (EVar "omKeys") (EFieldAccess (EVar "reg") "waiting"))) (EMatch (EFieldAccess (EVar "reg") "scope") (arm (PCon "WholeModule") () (EApp (EApp (EVar "flatMap") (EApp (EVar "declaredOnly") (EVar "reg"))) (EApp (EVar "omKeys") (EFieldAccess (EVar "reg") "entries")))) (arm (PCon "ModuleHalf") () (EListLit)))))
(DTypeSig false "unresolvedAt" (TyFun (TyCon "SymbolRegistry") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "SymbolDefect")))))
(DFunDef false "unresolvedAt" ((PVar "reg") (PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "reg") "excused")) (EListLit) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "reg") "waiting")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "calls")) () (EMatch (EApp (EVar "reverseL") (EVar "calls")) (arm (PList) () (EListLit)) (arm (PCons (PCon "Waiting" PWild (PVar "at")) PWild) () (EListLit (EApp (EApp (EVar "UndefinedReference") (EVar "name")) (EVar "at")))))))))
(DTypeSig false "declaredOnly" (TyFun (TyCon "SymbolRegistry") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "SymbolDefect")))))
(DFunDef false "declaredOnly" ((PVar "reg") (PVar "name")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "reg") "entries")) (arm (PCon "Some" (PCon "Entry" (PCon "Declared") (PCon "Generated" PWild) PWild (PVar "at"))) () (EListLit (EApp (EApp (EVar "UndefinedReference") (EVar "name")) (EVar "at")))) (arm PWild () (EListLit))))
(DTypeSig true "prototypeText" (TyFun (TyCon "String") (TyFun (TyCon "Prototype") (TyCon "String"))))
(DFunDef false "prototypeText" ((PVar "name") (PCon "FuncProto" (PVar "ret") (PVar "ps") (PVar "attrs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "ret"))) (ELit (LString " @"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "("))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "paramText")) (EVar "ps"))))) (ELit (LString ")"))) (EApp (EVar "display") (EVar "attrs"))) (ELit (LString ""))))
(DFunDef false "prototypeText" ((PVar "name") (PCon "DataProto" (PVar "t"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "@")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " : "))) (EApp (EVar "display") (EVar "t"))) (ELit (LString ""))))
(DTypeSig false "paramText" (TyFun (TyCon "LlvmParam") (TyCon "String")))
(DFunDef false "paramText" ((PCon "LlvmParam" (PVar "t") (PLit (LString "")))) (EVar "t"))
(DFunDef false "paramText" ((PCon "LlvmParam" (PVar "t") (PVar "r"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "t"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "r"))) (ELit (LString ""))))
(DTypeSig true "defectCode" (TyFun (TyCon "SymbolDefect") (TyCon "DiagCode")))
(DFunDef false "defectCode" ((PCon "DuplicateDefinition" PWild PWild PWild)) (EVar "EPhysDuplicate"))
(DFunDef false "defectCode" ((PCon "PrototypeConflict" PWild PWild PWild PWild PWild)) (EVar "EPhysShape"))
(DFunDef false "defectCode" ((PCon "ShapeMismatch" PWild PWild PWild PWild PWild)) (EVar "EPhysShape"))
(DFunDef false "defectCode" ((PCon "UndefinedReference" PWild PWild)) (EVar "EPhysUndefined"))
(DTypeSig true "defectOrigin" (TyFun (TyCon "SymbolDefect") (TyCon "SymbolOrigin")))
(DFunDef false "defectOrigin" ((PCon "DuplicateDefinition" PWild (PVar "at") PWild)) (EVar "at"))
(DFunDef false "defectOrigin" ((PCon "PrototypeConflict" PWild PWild PWild (PVar "at") PWild)) (EVar "at"))
(DFunDef false "defectOrigin" ((PCon "ShapeMismatch" PWild PWild PWild (PVar "at") PWild)) (EVar "at"))
(DFunDef false "defectOrigin" ((PCon "UndefinedReference" PWild (PVar "at"))) (EVar "at"))
(DTypeSig true "defectMessage" (TyFun (TyCon "SymbolDefect") (TyCon "String")))
(DFunDef false "defectMessage" ((PCon "DuplicateDefinition" (PVar "name") (PVar "at") (PVar "first"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "in ")) (EApp (EVar "display") (EApp (EVar "bindingOf") (EVar "at")))) (ELit (LString ": the LLVM module would write `@"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` twice, here and in "))) (EApp (EVar "display") (EApp (EVar "placeOf") (EVar "first")))) (ELit (LString "; a module may declare or define a name once"))))
(DFunDef false "defectMessage" ((PCon "PrototypeConflict" (PVar "name") (PVar "proto") (PVar "first") (PVar "at") (PVar "earlier"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "in ")) (EApp (EVar "display") (EApp (EVar "bindingOf") (EVar "at")))) (ELit (LString ": `@"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` is written here as `"))) (EApp (EVar "display") (EApp (EApp (EVar "prototypeText") (EVar "name")) (EVar "proto")))) (ELit (LString "`, but "))) (EApp (EVar "display") (EApp (EVar "placeOf") (EVar "earlier")))) (ELit (LString " wrote it as `"))) (EApp (EVar "display") (EApp (EApp (EVar "prototypeText") (EVar "name")) (EVar "first")))) (ELit (LString "`"))))
(DFunDef false "defectMessage" ((PCon "ShapeMismatch" (PVar "name") (PVar "shape") (PVar "proto") (PVar "at") (PVar "declared"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "in ")) (EApp (EVar "display") (EApp (EVar "bindingOf") (EVar "at")))) (ELit (LString ": a call of `@"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` has shape `"))) (EApp (EVar "display") (EApp (EVar "shapeText") (EVar "shape")))) (ELit (LString "`, but "))) (EApp (EVar "display") (EApp (EVar "placeOf") (EVar "declared")))) (ELit (LString " gives it `"))) (EApp (EVar "display") (EApp (EApp (EVar "prototypeText") (EVar "name")) (EVar "proto")))) (ELit (LString "`"))))
(DFunDef false "defectMessage" ((PCon "UndefinedReference" (PVar "name") (PVar "at"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "in ")) (EApp (EVar "display") (EApp (EVar "bindingOf") (EVar "at")))) (ELit (LString ": the LLVM module refers to `@"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "`, which nothing in it defines"))))
(DTypeSig false "shapeText" (TyFun (TyCon "CallShape") (TyCon "String")))
(DFunDef false "shapeText" ((PCon "CallShape" (PVar "ret") (PVar "operands"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "ret"))) (ELit (LString " ("))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "operands")))) (ELit (LString ")"))))
# MARK
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omDelete" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omKeys" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "symbol_origin") ((mem "SymbolOrigin" false) (mem "bindingOf" false) (mem "placeOf" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "reverseL" false))))
(DData Public "LlvmSymbol" () ((variant "Generated" (ConPos (TyCon "String"))) (variant "Foreign" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "LlvmSymbol")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Generated" (PVar "__a0")) (PCon "Generated" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "Foreign" (PVar "__a0")) (PCon "Foreign" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "LlvmSymbol")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Generated" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Generated ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "Foreign" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Foreign ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))))))))
(DData Public "LlvmParam" () ((variant "LlvmParam" (ConPos (TyCon "String") (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "LlvmParam")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "LlvmParam" (PVar "__a0") (PVar "__a1")) (PCon "LlvmParam" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))))))))
(DImpl true "Debug" ((TyCon "LlvmParam")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "LlvmParam" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "LlvmParam ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))))))))
(DData Public "Prototype" () ((variant "FuncProto" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "LlvmParam")) (TyCon "String"))) (variant "DataProto" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "Prototype")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "FuncProto" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "FuncProto" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple (PCon "DataProto" (PVar "__a0")) (PCon "DataProto" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Prototype")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "FuncProto" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FuncProto ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a2"))))) (arm (PCon "DataProto" (PVar "__a0")) () (EBinOp "++" (ELit (LString "DataProto ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))))))))
(DData Public "CallShape" () ((variant "CallShape" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) ())
(DImpl true "Eq" ((TyCon "CallShape")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "CallShape" (PVar "__a0") (PVar "__a1")) (PCon "CallShape" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))))))))
(DImpl true "Debug" ((TyCon "CallShape")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "CallShape" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "CallShape ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))))))))
(DData Public "ModuleScope" () ((variant "WholeModule" (ConPos)) (variant "ModuleHalf" (ConPos))) ())
(DImpl true "Eq" ((TyCon "ModuleScope")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "WholeModule") (PCon "WholeModule")) () (EVar "True")) (arm (PTuple (PCon "ModuleHalf") (PCon "ModuleHalf")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "ModuleScope")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "WholeModule") () (ELit (LString "WholeModule"))) (arm (PCon "ModuleHalf") () (ELit (LString "ModuleHalf")))))))
(DData Public "SymbolDefect" () ((variant "DuplicateDefinition" (ConPos (TyCon "String") (TyCon "SymbolOrigin") (TyCon "SymbolOrigin"))) (variant "PrototypeConflict" (ConPos (TyCon "String") (TyCon "Prototype") (TyCon "Prototype") (TyCon "SymbolOrigin") (TyCon "SymbolOrigin"))) (variant "ShapeMismatch" (ConPos (TyCon "String") (TyCon "CallShape") (TyCon "Prototype") (TyCon "SymbolOrigin") (TyCon "SymbolOrigin"))) (variant "UndefinedReference" (ConPos (TyCon "String") (TyCon "SymbolOrigin")))) ())
(DImpl true "Eq" ((TyCon "SymbolDefect")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "DuplicateDefinition" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "DuplicateDefinition" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple (PCon "PrototypeConflict" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3") (PVar "__a4")) (PCon "PrototypeConflict" (PVar "__b0") (PVar "__b1") (PVar "__b2") (PVar "__b3") (PVar "__b4"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EMethodRef "eq") (EVar "__a4")) (EVar "__b4")))) (arm (PTuple (PCon "ShapeMismatch" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3") (PVar "__a4")) (PCon "ShapeMismatch" (PVar "__b0") (PVar "__b1") (PVar "__b2") (PVar "__b3") (PVar "__b4"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EMethodRef "eq") (EVar "__a4")) (EVar "__b4")))) (arm (PTuple (PCon "UndefinedReference" (PVar "__a0") (PVar "__a1")) (PCon "UndefinedReference" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "SymbolDefect")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "DuplicateDefinition" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "DuplicateDefinition ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a2"))))) (arm (PCon "PrototypeConflict" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3") (PVar "__a4")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "PrototypeConflict ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a3")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a4"))))) (arm (PCon "ShapeMismatch" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3") (PVar "__a4")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ShapeMismatch ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a3")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a4"))))) (arm (PCon "UndefinedReference" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "UndefinedReference ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))))))))
(DData Private "Binding" () ((variant "Declared" (ConPos)) (variant "Defined" (ConPos))) ())
(DImpl true "Eq" ((TyCon "Binding")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Declared") (PCon "Declared")) () (EVar "True")) (arm (PTuple (PCon "Defined") (PCon "Defined")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Private "Entry" () ((variant "Entry" (ConPos (TyCon "Binding") (TyCon "LlvmSymbol") (TyCon "Prototype") (TyCon "SymbolOrigin")))) ())
(DData Private "Waiting" () ((variant "Waiting" (ConPos (TyApp (TyCon "Option") (TyCon "CallShape")) (TyCon "SymbolOrigin")))) ())
(DData Abstract "SymbolRegistry" () ((variant "SymbolRegistry" (ConNamed (field "scope" (TyCon "ModuleScope")) (field "entries" (TyApp (TyCon "OrdMap") (TyCon "Entry"))) (field "waiting" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Waiting")))) (field "excused" (TyApp (TyCon "OrdMap") (TyCon "Unit")))))) ())
(DTypeSig true "emptyRegistry" (TyFun (TyCon "ModuleScope") (TyCon "SymbolRegistry")))
(DFunDef false "emptyRegistry" ((PVar "scope")) (ERecordCreate "SymbolRegistry" ((fa "scope" (EVar "scope")) (fa "entries" (EVar "omEmpty")) (fa "waiting" (EVar "omEmpty")) (fa "excused" (EVar "omEmpty")))))
(DTypeSig true "symbolName" (TyFun (TyCon "LlvmSymbol") (TyCon "String")))
(DFunDef false "symbolName" ((PCon "Generated" (PVar "n"))) (EVar "n"))
(DFunDef false "symbolName" ((PCon "Foreign" (PVar "n"))) (EVar "n"))
(DTypeSig true "declareSymbol" (TyFun (TyCon "LlvmSymbol") (TyFun (TyCon "Prototype") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry")))))))
(DFunDef false "declareSymbol" ((PVar "sym") (PVar "proto") (PVar "origin") (PVar "reg")) (EBlock (DoLet false false (PVar "name") (EApp (EVar "symbolName") (EVar "sym"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "reg") "entries")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "settle") (EVar "name")) (EApp (EApp (EApp (EApp (EVar "Entry") (EVar "Declared")) (EVar "sym")) (EVar "proto")) (EVar "origin"))) (EVar "reg"))) (arm (PCon "Some" (PCon "Entry" (PCon "Declared") PWild (PVar "first") (PVar "at"))) () (EIf (EApp (EApp (EVar "sameSignature") (EVar "proto")) (EVar "first")) (EApp (EVar "Ok") (EVar "reg")) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PrototypeConflict") (EVar "name")) (EVar "proto")) (EVar "first")) (EVar "origin")) (EVar "at"))))) (arm (PCon "Some" (PCon "Entry" (PCon "Defined") PWild (PVar "first") (PVar "at"))) () (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "secondWrite") (EVar "name")) (EVar "proto")) (EVar "origin")) (EVar "first")) (EVar "at"))))))))
(DTypeSig true "defineSymbol" (TyFun (TyCon "LlvmSymbol") (TyFun (TyCon "Prototype") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry")))))))
(DFunDef false "defineSymbol" ((PVar "sym") (PVar "proto") (PVar "origin") (PVar "reg")) (EApp (EApp (EApp (EApp (EApp (EVar "writeOnce") (EVar "Defined")) (EVar "sym")) (EVar "proto")) (EVar "origin")) (EVar "reg")))
(DTypeSig true "declareOnce" (TyFun (TyCon "LlvmSymbol") (TyFun (TyCon "Prototype") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry")))))))
(DFunDef false "declareOnce" ((PVar "sym") (PVar "proto") (PVar "origin") (PVar "reg")) (EApp (EApp (EApp (EApp (EApp (EVar "writeOnce") (EVar "Declared")) (EVar "sym")) (EVar "proto")) (EVar "origin")) (EVar "reg")))
(DTypeSig false "writeOnce" (TyFun (TyCon "Binding") (TyFun (TyCon "LlvmSymbol") (TyFun (TyCon "Prototype") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry"))))))))
(DFunDef false "writeOnce" ((PVar "binding") (PVar "sym") (PVar "proto") (PVar "origin") (PVar "reg")) (EBlock (DoLet false false (PVar "name") (EApp (EVar "symbolName") (EVar "sym"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "reg") "entries")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "settle") (EVar "name")) (EApp (EApp (EApp (EApp (EVar "Entry") (EVar "binding")) (EVar "sym")) (EVar "proto")) (EVar "origin"))) (EVar "reg"))) (arm (PCon "Some" (PCon "Entry" PWild PWild (PVar "first") (PVar "at"))) () (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "secondWrite") (EVar "name")) (EVar "proto")) (EVar "origin")) (EVar "first")) (EVar "at"))))))))
(DTypeSig false "secondWrite" (TyFun (TyCon "String") (TyFun (TyCon "Prototype") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "Prototype") (TyFun (TyCon "SymbolOrigin") (TyCon "SymbolDefect")))))))
(DFunDef false "secondWrite" ((PVar "name") (PVar "proto") (PVar "origin") (PVar "first") (PVar "at")) (EIf (EBinOp "&&" (EApp (EApp (EVar "sameKind") (EVar "proto")) (EVar "first")) (EApp (EVar "not") (EApp (EApp (EVar "sameSignature") (EVar "proto")) (EVar "first")))) (EApp (EApp (EApp (EApp (EApp (EVar "PrototypeConflict") (EVar "name")) (EVar "proto")) (EVar "first")) (EVar "origin")) (EVar "at")) (EApp (EApp (EApp (EVar "DuplicateDefinition") (EVar "name")) (EVar "origin")) (EVar "at"))))
(DTypeSig false "sameKind" (TyFun (TyCon "Prototype") (TyFun (TyCon "Prototype") (TyCon "Bool"))))
(DFunDef false "sameKind" ((PCon "FuncProto" PWild PWild PWild) (PCon "FuncProto" PWild PWild PWild)) (EVar "True"))
(DFunDef false "sameKind" ((PCon "DataProto" PWild) (PCon "DataProto" PWild)) (EVar "True"))
(DFunDef false "sameKind" (PWild PWild) (EVar "False"))
(DTypeSig false "sameSignature" (TyFun (TyCon "Prototype") (TyFun (TyCon "Prototype") (TyCon "Bool"))))
(DFunDef false "sameSignature" ((PCon "FuncProto" (PVar "r1") (PVar "ps1") PWild) (PCon "FuncProto" (PVar "r2") (PVar "ps2") PWild)) (EBinOp "&&" (EBinOp "==" (EVar "r1") (EVar "r2")) (EBinOp "==" (EApp (EApp (EMethodRef "map") (EVar "paramType")) (EVar "ps1")) (EApp (EApp (EMethodRef "map") (EVar "paramType")) (EVar "ps2")))))
(DFunDef false "sameSignature" ((PCon "DataProto" (PVar "t1")) (PCon "DataProto" (PVar "t2"))) (EBinOp "==" (EVar "t1") (EVar "t2")))
(DFunDef false "sameSignature" (PWild PWild) (EVar "False"))
(DTypeSig false "paramType" (TyFun (TyCon "LlvmParam") (TyCon "String")))
(DFunDef false "paramType" ((PCon "LlvmParam" (PVar "t") PWild)) (EVar "t"))
(DTypeSig false "settle" (TyFun (TyCon "String") (TyFun (TyCon "Entry") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry"))))))
(DFunDef false "settle" ((PVar "name") (PVar "entry") (PVar "reg")) (EBlock (DoLet false false (PVar "reg2") (ERecordUpdate (EVar "reg") ((fa "entries" (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "entry")) (EFieldAccess (EVar "reg") "entries"))) (fa "waiting" (EApp (EApp (EVar "omDelete") (EVar "name")) (EFieldAccess (EVar "reg") "waiting")))))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "reg") "waiting")) (arm (PCon "None") () (EApp (EVar "Ok") (EVar "reg2"))) (arm (PCon "Some" (PVar "calls")) () (EApp (EApp (EApp (EApp (EVar "judgeWaiting") (EVar "name")) (EVar "entry")) (EApp (EVar "reverseL") (EVar "calls"))) (EVar "reg2")))))))
(DTypeSig false "judgeWaiting" (TyFun (TyCon "String") (TyFun (TyCon "Entry") (TyFun (TyApp (TyCon "List") (TyCon "Waiting")) (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry")))))))
(DFunDef false "judgeWaiting" (PWild PWild (PList) (PVar "reg")) (EApp (EVar "Ok") (EVar "reg")))
(DFunDef false "judgeWaiting" ((PVar "name") (PVar "entry") (PCons (PCon "Waiting" (PCon "Some" (PVar "shape")) (PVar "at")) (PVar "rest")) (PVar "reg")) (EMatch (EApp (EApp (EApp (EApp (EVar "callDefect") (EVar "name")) (EVar "shape")) (EVar "at")) (EVar "entry")) (arm (PCon "Some" (PVar "d")) () (EApp (EVar "Err") (EVar "d"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "judgeWaiting") (EVar "name")) (EVar "entry")) (EVar "rest")) (EVar "reg")))))
(DFunDef false "judgeWaiting" ((PVar "name") (PVar "entry") (PCons (PCon "Waiting" (PCon "None") PWild) (PVar "rest")) (PVar "reg")) (EApp (EApp (EApp (EApp (EVar "judgeWaiting") (EVar "name")) (EVar "entry")) (EVar "rest")) (EVar "reg")))
(DTypeSig false "callDefect" (TyFun (TyCon "String") (TyFun (TyCon "CallShape") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "Entry") (TyApp (TyCon "Option") (TyCon "SymbolDefect")))))))
(DFunDef false "callDefect" ((PVar "name") (PAs "shape" (PCon "CallShape" (PVar "ret") (PVar "operands"))) (PVar "at") (PCon "Entry" PWild PWild (PVar "proto") (PVar "declared"))) (EMatch (EVar "proto") (arm (PCon "FuncProto" (PVar "r") (PVar "ps") PWild) () (EIf (EBinOp "&&" (EBinOp "==" (EVar "r") (EVar "ret")) (EBinOp "==" (EApp (EApp (EMethodRef "map") (EVar "paramType")) (EVar "ps")) (EVar "operands"))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "ShapeMismatch") (EVar "name")) (EVar "shape")) (EVar "proto")) (EVar "at")) (EVar "declared"))))) (arm (PCon "DataProto" PWild) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "ShapeMismatch") (EVar "name")) (EVar "shape")) (EVar "proto")) (EVar "at")) (EVar "declared"))))))
(DTypeSig true "checkCall" (TyFun (TyCon "LlvmSymbol") (TyFun (TyCon "CallShape") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry")))))))
(DFunDef false "checkCall" ((PVar "sym") (PVar "shape") (PVar "origin") (PVar "reg")) (EBlock (DoLet false false (PVar "name") (EApp (EVar "symbolName") (EVar "sym"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "reg") "entries")) (arm (PCon "Some" (PVar "entry")) () (EMatch (EApp (EApp (EApp (EApp (EVar "callDefect") (EVar "name")) (EVar "shape")) (EVar "origin")) (EVar "entry")) (arm (PCon "Some" (PVar "d")) () (EApp (EVar "Err") (EVar "d"))) (arm (PCon "None") () (EApp (EVar "Ok") (EVar "reg"))))) (arm (PCon "None") () (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "wait") (EVar "name")) (EApp (EApp (EVar "Waiting") (EApp (EVar "Some") (EVar "shape"))) (EVar "origin"))) (EVar "reg"))))))))
(DTypeSig true "checkRef" (TyFun (TyCon "LlvmSymbol") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "SymbolRegistry") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "SymbolRegistry"))))))
(DFunDef false "checkRef" ((PVar "sym") (PVar "origin") (PVar "reg")) (EBlock (DoLet false false (PVar "name") (EApp (EVar "symbolName") (EVar "sym"))) (DoExpr (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "reg") "entries")) (EApp (EVar "Ok") (EVar "reg")) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "wait") (EVar "name")) (EApp (EApp (EVar "Waiting") (EVar "None")) (EVar "origin"))) (EVar "reg")))))))
(DTypeSig false "wait" (TyFun (TyCon "String") (TyFun (TyCon "Waiting") (TyFun (TyCon "SymbolRegistry") (TyCon "SymbolRegistry")))))
(DFunDef false "wait" ((PVar "name") (PVar "w") (PVar "reg")) (EBlock (DoLet false false (PVar "earlier") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "reg") "waiting")))) (DoExpr (ERecordUpdate (EVar "reg") ((fa "waiting" (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EBinOp "::" (EVar "w") (EVar "earlier"))) (EFieldAccess (EVar "reg") "waiting"))))))))
(DTypeSig true "excuseSymbol" (TyFun (TyCon "LlvmSymbol") (TyFun (TyCon "SymbolRegistry") (TyCon "SymbolRegistry"))))
(DFunDef false "excuseSymbol" ((PVar "sym") (PVar "reg")) (ERecordUpdate (EVar "reg") ((fa "excused" (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "symbolName") (EVar "sym"))) (ELit LUnit)) (EFieldAccess (EVar "reg") "excused"))))))
(DTypeSig true "unresolved" (TyFun (TyCon "SymbolRegistry") (TyApp (TyCon "List") (TyCon "SymbolDefect"))))
(DFunDef false "unresolved" ((PVar "reg")) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EVar "unresolvedAt") (EVar "reg"))) (EApp (EVar "omKeys") (EFieldAccess (EVar "reg") "waiting"))) (EMatch (EFieldAccess (EVar "reg") "scope") (arm (PCon "WholeModule") () (EApp (EApp (EDictApp "flatMap") (EApp (EVar "declaredOnly") (EVar "reg"))) (EApp (EVar "omKeys") (EFieldAccess (EVar "reg") "entries")))) (arm (PCon "ModuleHalf") () (EListLit)))))
(DTypeSig false "unresolvedAt" (TyFun (TyCon "SymbolRegistry") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "SymbolDefect")))))
(DFunDef false "unresolvedAt" ((PVar "reg") (PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "reg") "excused")) (EListLit) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "reg") "waiting")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "calls")) () (EMatch (EApp (EVar "reverseL") (EVar "calls")) (arm (PList) () (EListLit)) (arm (PCons (PCon "Waiting" PWild (PVar "at")) PWild) () (EListLit (EApp (EApp (EVar "UndefinedReference") (EVar "name")) (EVar "at")))))))))
(DTypeSig false "declaredOnly" (TyFun (TyCon "SymbolRegistry") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "SymbolDefect")))))
(DFunDef false "declaredOnly" ((PVar "reg") (PVar "name")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "reg") "entries")) (arm (PCon "Some" (PCon "Entry" (PCon "Declared") (PCon "Generated" PWild) PWild (PVar "at"))) () (EListLit (EApp (EApp (EVar "UndefinedReference") (EVar "name")) (EVar "at")))) (arm PWild () (EListLit))))
(DTypeSig true "prototypeText" (TyFun (TyCon "String") (TyFun (TyCon "Prototype") (TyCon "String"))))
(DFunDef false "prototypeText" ((PVar "name") (PCon "FuncProto" (PVar "ret") (PVar "ps") (PVar "attrs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "ret"))) (ELit (LString " @"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "("))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "paramText")) (EVar "ps"))))) (ELit (LString ")"))) (EApp (EMethodRef "display") (EVar "attrs"))) (ELit (LString ""))))
(DFunDef false "prototypeText" ((PVar "name") (PCon "DataProto" (PVar "t"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "@")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EVar "t"))) (ELit (LString ""))))
(DTypeSig false "paramText" (TyFun (TyCon "LlvmParam") (TyCon "String")))
(DFunDef false "paramText" ((PCon "LlvmParam" (PVar "t") (PLit (LString "")))) (EVar "t"))
(DFunDef false "paramText" ((PCon "LlvmParam" (PVar "t") (PVar "r"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "t"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "r"))) (ELit (LString ""))))
(DTypeSig true "defectCode" (TyFun (TyCon "SymbolDefect") (TyCon "DiagCode")))
(DFunDef false "defectCode" ((PCon "DuplicateDefinition" PWild PWild PWild)) (EVar "EPhysDuplicate"))
(DFunDef false "defectCode" ((PCon "PrototypeConflict" PWild PWild PWild PWild PWild)) (EVar "EPhysShape"))
(DFunDef false "defectCode" ((PCon "ShapeMismatch" PWild PWild PWild PWild PWild)) (EVar "EPhysShape"))
(DFunDef false "defectCode" ((PCon "UndefinedReference" PWild PWild)) (EVar "EPhysUndefined"))
(DTypeSig true "defectOrigin" (TyFun (TyCon "SymbolDefect") (TyCon "SymbolOrigin")))
(DFunDef false "defectOrigin" ((PCon "DuplicateDefinition" PWild (PVar "at") PWild)) (EVar "at"))
(DFunDef false "defectOrigin" ((PCon "PrototypeConflict" PWild PWild PWild (PVar "at") PWild)) (EVar "at"))
(DFunDef false "defectOrigin" ((PCon "ShapeMismatch" PWild PWild PWild (PVar "at") PWild)) (EVar "at"))
(DFunDef false "defectOrigin" ((PCon "UndefinedReference" PWild (PVar "at"))) (EVar "at"))
(DTypeSig true "defectMessage" (TyFun (TyCon "SymbolDefect") (TyCon "String")))
(DFunDef false "defectMessage" ((PCon "DuplicateDefinition" (PVar "name") (PVar "at") (PVar "first"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "in ")) (EApp (EMethodRef "display") (EApp (EVar "bindingOf") (EVar "at")))) (ELit (LString ": the LLVM module would write `@"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` twice, here and in "))) (EApp (EMethodRef "display") (EApp (EVar "placeOf") (EVar "first")))) (ELit (LString "; a module may declare or define a name once"))))
(DFunDef false "defectMessage" ((PCon "PrototypeConflict" (PVar "name") (PVar "proto") (PVar "first") (PVar "at") (PVar "earlier"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "in ")) (EApp (EMethodRef "display") (EApp (EVar "bindingOf") (EVar "at")))) (ELit (LString ": `@"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` is written here as `"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "prototypeText") (EVar "name")) (EVar "proto")))) (ELit (LString "`, but "))) (EApp (EMethodRef "display") (EApp (EVar "placeOf") (EVar "earlier")))) (ELit (LString " wrote it as `"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "prototypeText") (EVar "name")) (EVar "first")))) (ELit (LString "`"))))
(DFunDef false "defectMessage" ((PCon "ShapeMismatch" (PVar "name") (PVar "shape") (PVar "proto") (PVar "at") (PVar "declared"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "in ")) (EApp (EMethodRef "display") (EApp (EVar "bindingOf") (EVar "at")))) (ELit (LString ": a call of `@"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` has shape `"))) (EApp (EMethodRef "display") (EApp (EVar "shapeText") (EVar "shape")))) (ELit (LString "`, but "))) (EApp (EMethodRef "display") (EApp (EVar "placeOf") (EVar "declared")))) (ELit (LString " gives it `"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "prototypeText") (EVar "name")) (EVar "proto")))) (ELit (LString "`"))))
(DFunDef false "defectMessage" ((PCon "UndefinedReference" (PVar "name") (PVar "at"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "in ")) (EApp (EMethodRef "display") (EApp (EVar "bindingOf") (EVar "at")))) (ELit (LString ": the LLVM module refers to `@"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "`, which nothing in it defines"))))
(DTypeSig false "shapeText" (TyFun (TyCon "CallShape") (TyCon "String")))
(DFunDef false "shapeText" ((PCon "CallShape" (PVar "ret") (PVar "operands"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "ret"))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "operands")))) (ELit (LString ")"))))
