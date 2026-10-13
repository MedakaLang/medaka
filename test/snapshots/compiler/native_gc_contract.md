# META
source_lines=294
stages=DESUGAR,MARK
# SOURCE
-- Native producer observations under Boehm; this report is not a root map.

import frontend.ast.{BinderId(..)}
import types.runtime_types.{BinderRow(..), runtimeTypeName}
import support.util.{joinNl, joinWith, reverseL, escStr, listLen}

public export data StorageKind =
  | TaggedWord
  | RawScalar
  | CodeAddress
  | PackedBytes
  | StackAddress
  | NoValue
  | UnknownStorage
  deriving (Eq, Debug)

public export data LayoutKind =
  | ConstructorCell
  | ClosureCell
  | WordArray
  | DynamicWordArray
  | AtomicBox
  | AtomicByteBlock
  deriving (Eq, Debug)

public export data CallEffect =
  | NoManagedCollection
  | MayCollect
  | MayCollectAndReenter
  | UnknownEffect
  deriving (Eq, Debug)

public export data NativeEvent =
  | Allocation String LayoutKind String String String (List StorageKind) (List String) String
  | Call String String String (List String) (List StorageKind) StorageKind CallEffect
  | Operand String String StorageKind
  | Store String String Int String StorageKind
  | Derived String String String String
  | Uncovered String String
  deriving (Debug)

public export data NativeLog = NativeLog {
  events : Ref (List NativeEvent),
  scope : Ref String,
  nextScope : Ref Int,
}

export
newLog : Unit -> NativeLog
newLog _ =
  NativeLog { events = Ref [], scope = Ref "module", nextScope = Ref 0 }

export
enterScope : NativeLog -> String -> Unit
enterScope log module_ =
  let n = !log.nextScope
  log.nextScope := n + 1
  log.scope := "\{module_}/define\{n}"

export
restoreScope : NativeLog -> String -> Unit
restoreScope log saved = log.scope := saved

export
currentScope : NativeLog -> String
currentScope log = !log.scope

export
recordEvent : NativeLog -> NativeEvent -> Unit
recordEvent log event = log.events := event :: !log.events

export
logEvents : NativeLog -> List NativeEvent
logEvents log = reverseL !log.events

export
taggedSlots : Int -> List StorageKind
taggedSlots n = if n <= 0 then [] else TaggedWord :: taggedSlots (n - 1)

export
constructorSlots : Int -> List StorageKind
constructorSlots n = RawScalar :: taggedSlots n

export
closureSlots : Int -> List StorageKind
closureSlots n = RawScalar :: CodeAddress :: taggedSlots n

-- These are C ABI contracts, not classifications inferred from LLVM i64.
export
helperContract : String -> (List StorageKind, StorageKind, CallEffect)
helperContract "mdk_byteblock_make" = ([TaggedWord], TaggedWord, MayCollect)
helperContract "mdk_byteblock_copy" =
  ([TaggedWord, TaggedWord], TaggedWord, MayCollect)
helperContract "mdk_byteblock_length" =
  ([TaggedWord], TaggedWord, NoManagedCollection)
helperContract "mdk_byteblock_get" =
  ([TaggedWord, TaggedWord], TaggedWord, NoManagedCollection)
helperContract "mdk_byteblock_set" =
  ([TaggedWord, TaggedWord, TaggedWord], NoValue, NoManagedCollection)
helperContract "mdk_byteblock_blit" = (
  [TaggedWord, TaggedWord, TaggedWord, TaggedWord, TaggedWord],
  NoValue,
  NoManagedCollection,
)
helperContract "mdk_bit_and" =
  ([RawScalar, RawScalar], RawScalar, NoManagedCollection)
helperContract "mdk_bit_or" =
  ([RawScalar, RawScalar], RawScalar, NoManagedCollection)
helperContract "mdk_bit_xor" =
  ([RawScalar, RawScalar], RawScalar, NoManagedCollection)
helperContract "mdk_shift_left" =
  ([RawScalar, RawScalar], RawScalar, MayCollectAndReenter)
helperContract "mdk_shift_right" =
  ([RawScalar, RawScalar], RawScalar, MayCollectAndReenter)
helperContract "mdk_bit_not" = ([RawScalar], RawScalar, NoManagedCollection)
helperContract _ = ([], UnknownStorage, UnknownEffect)

export
runtimeCall : String -> String -> String -> List String -> NativeEvent
runtimeCall scope name result args =
  let (kinds, output, callEffect) = helperContract name
  Call scope name result args kinds output callEffect

allTagged : List StorageKind -> Bool
allTagged [] = True
allTagged (TaggedWord :: rest) = allTagged rest
allTagged _ = False

validSlots : LayoutKind -> List StorageKind -> Bool
validSlots ConstructorCell (RawScalar :: fields) = allTagged fields
validSlots ClosureCell (RawScalar :: CodeAddress :: captures) =
  allTagged captures
validSlots WordArray (RawScalar :: fields) = allTagged fields
validSlots DynamicWordArray [RawScalar, TaggedWord] = True
validSlots AtomicBox [RawScalar, RawScalar] = True
validSlots AtomicByteBlock [RawScalar, RawScalar, PackedBytes] = True
validSlots _ _ = False

export
validateEvent : NativeEvent -> List String
validateEvent (Allocation _ layout _ _ extent slots _ _) =
  if extent == "" then
    ["allocation has no extent"]
  else if validSlots layout slots then
    []
  else
    ["allocation storage disagrees with its native layout"]
validateEvent (Call _ name _ args kinds output callEffect) =
  let (expected, expectedOutput, expectedEffect) = helperContract name
  if expectedEffect == UnknownEffect then
    if callEffect == UnknownEffect || callEffect == MayCollectAndReenter then
      []
    else
      ["unclassified call was declared collection-free"]
  else if kinds == expected
    && output == expectedOutput
    && callEffect == expectedEffect
    && listLen args == listLen kinds then
    []
  else
    ["runtime call disagrees with its native ABI contract"]
validateEvent (Store _ _ _ _ TaggedWord) = []
validateEvent (Store _ _ _ _ _) =
  ["Ref mutation must store a tagged value word"]
validateEvent _ = []

storageName : StorageKind -> String
storageName TaggedWord = "tagged-value-word"
storageName RawScalar = "raw-scalar"
storageName CodeAddress = "code-address"
storageName PackedBytes = "packed-raw-bytes"
storageName StackAddress = "stack-address"
storageName NoValue = "void"
storageName UnknownStorage = "unknown"

layoutName : LayoutKind -> String
layoutName ConstructorCell = "constructor"
layoutName ClosureCell = "closure"
layoutName WordArray = "word-array"
layoutName DynamicWordArray = "word-array-repeated-tagged-elements"
layoutName AtomicBox = "atomic-box"
layoutName AtomicByteBlock = "atomic-byte-block"

callEffectName : CallEffect -> String
callEffectName NoManagedCollection = "no-managed-collection-no-callback"
callEffectName MayCollect = "may-collect-no-callback"
callEffectName MayCollectAndReenter = "may-collect-and-reenter"
callEffectName UnknownEffect = "unknown-may-collect-and-reenter"

node : String -> List String -> String
node tag fields = "(" ++ joinWith " " (tag :: fields) ++ ")"

strings : List String -> String
strings xs = node "operands" (map escStr xs)

slotsText : List StorageKind -> String
slotsText xs = node "storage" (map storageName xs)

eventText : NativeEvent -> String
eventText (Allocation scope kind pointer word extent slots inputs init) = node
  "allocation"
  [
    escStr scope,
    layoutName kind,
    escStr pointer,
    escStr word,
    escStr extent,
    slotsText slots,
    strings inputs,
    escStr init,
  ]
eventText (Call scope name result args kinds output callEffect) = node "call" [
  escStr scope,
  escStr name,
  escStr result,
  strings args,
  slotsText kinds,
  storageName output,
  callEffectName callEffect,
]
eventText (Operand scope word kind) =
  node "operand" [escStr scope, escStr word, storageName kind]
eventText (Store scope owner offset word kind) = node "store" [
  escStr scope,
  escStr owner,
  intToString offset,
  escStr word,
  storageName kind,
]
eventText (Derived scope address base offset) =
  node "derived" [escStr scope, escStr address, escStr base, escStr offset]
eventText (Uncovered scope producer) =
  node "uncovered" [escStr scope, escStr producer]

binderText : BinderRow -> String
binderText row = match row.brId
  BinderId module_ ordinal => node "semantic-binder" [
    escStr module_,
    intToString ordinal,
    escStr row.brName,
    runtimeTypeName row.brType,
    match row.brReturns
      Some t => runtimeTypeName t
      None => "no-return-fact",
  ]

eventGaps : NativeEvent -> List String
eventGaps (Call scope name _ _ _ _ UnknownEffect) =
  ["unknown call contract: \{scope}: \{name}"]
eventGaps (Derived scope _ _ _) =
  ["heap-derived address requires relocation proof: \{scope}"]
eventGaps (Uncovered scope producer) =
  ["uncovered producer: \{scope}: \{producer}"]
eventGaps (Allocation scope _ _ _ _ _ _ "deferred-backpatch") =
  ["deferred initialization requires publication proof: \{scope}"]
eventGaps _ = []

export
renderContract : List BinderRow -> List NativeEvent -> Result String String
renderContract binders events =
  let faults = flatMap validateEvent events
  if listLen faults > 0 then
    Err (joinNl faults)
  else
    let gaps =
      [
          "partial producer inventory: runtime families outside ByteBlock/bit and unhooked call paths are not covered",
          "root liveness, temporary roots and reloads are not produced",
          "C helper roots, uintptr_t root-slot ABI and allocating callback reentry are not established",
          "static/global ownership and barriers are not established",
          "tagged value words identify storage, not scalar types or membership in the managed heap",
        ]
        ++ flatMap eventGaps events
    Ok
      (joinNl
          ([
              node "native-contract" [
                "v1", "boehm", "incomplete", "moving-safe=false"
              ],
              node "foreign-layout-obligation" [
                "mdk_gc_byteblock_atomic_v1", "runtime-owned-extent",
                "atomic-mask-zero", "experimental-only"
              ],
              node "foreign-root-obligation" [
                "mdk_byteblock_copy", "source-argument=1",
                "Word-slot-before-allocation",
                "reload-before-source-derivation",
                "caller-reuse-needs-caller-roots"
              ],
            ]
            ++ map binderText binders
            ++ map eventText events
            ++ map (gap => node "gap" [escStr gap]) gaps)
        ++ "\n")
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "BinderId" true))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderRow" true) (mem "runtimeTypeName" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "joinWith" false) (mem "reverseL" false) (mem "escStr" false) (mem "listLen" false))))
(DData Public "StorageKind" () ((variant "TaggedWord" (ConPos)) (variant "RawScalar" (ConPos)) (variant "CodeAddress" (ConPos)) (variant "PackedBytes" (ConPos)) (variant "StackAddress" (ConPos)) (variant "NoValue" (ConPos)) (variant "UnknownStorage" (ConPos))) ())
(DImpl true "Eq" ((TyCon "StorageKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "TaggedWord") (PCon "TaggedWord")) () (EVar "True")) (arm (PTuple (PCon "RawScalar") (PCon "RawScalar")) () (EVar "True")) (arm (PTuple (PCon "CodeAddress") (PCon "CodeAddress")) () (EVar "True")) (arm (PTuple (PCon "PackedBytes") (PCon "PackedBytes")) () (EVar "True")) (arm (PTuple (PCon "StackAddress") (PCon "StackAddress")) () (EVar "True")) (arm (PTuple (PCon "NoValue") (PCon "NoValue")) () (EVar "True")) (arm (PTuple (PCon "UnknownStorage") (PCon "UnknownStorage")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "StorageKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "TaggedWord") () (ELit (LString "TaggedWord"))) (arm (PCon "RawScalar") () (ELit (LString "RawScalar"))) (arm (PCon "CodeAddress") () (ELit (LString "CodeAddress"))) (arm (PCon "PackedBytes") () (ELit (LString "PackedBytes"))) (arm (PCon "StackAddress") () (ELit (LString "StackAddress"))) (arm (PCon "NoValue") () (ELit (LString "NoValue"))) (arm (PCon "UnknownStorage") () (ELit (LString "UnknownStorage")))))))
(DData Public "LayoutKind" () ((variant "ConstructorCell" (ConPos)) (variant "ClosureCell" (ConPos)) (variant "WordArray" (ConPos)) (variant "DynamicWordArray" (ConPos)) (variant "AtomicBox" (ConPos)) (variant "AtomicByteBlock" (ConPos))) ())
(DImpl true "Eq" ((TyCon "LayoutKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ConstructorCell") (PCon "ConstructorCell")) () (EVar "True")) (arm (PTuple (PCon "ClosureCell") (PCon "ClosureCell")) () (EVar "True")) (arm (PTuple (PCon "WordArray") (PCon "WordArray")) () (EVar "True")) (arm (PTuple (PCon "DynamicWordArray") (PCon "DynamicWordArray")) () (EVar "True")) (arm (PTuple (PCon "AtomicBox") (PCon "AtomicBox")) () (EVar "True")) (arm (PTuple (PCon "AtomicByteBlock") (PCon "AtomicByteBlock")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "LayoutKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "ConstructorCell") () (ELit (LString "ConstructorCell"))) (arm (PCon "ClosureCell") () (ELit (LString "ClosureCell"))) (arm (PCon "WordArray") () (ELit (LString "WordArray"))) (arm (PCon "DynamicWordArray") () (ELit (LString "DynamicWordArray"))) (arm (PCon "AtomicBox") () (ELit (LString "AtomicBox"))) (arm (PCon "AtomicByteBlock") () (ELit (LString "AtomicByteBlock")))))))
(DData Public "CallEffect" () ((variant "NoManagedCollection" (ConPos)) (variant "MayCollect" (ConPos)) (variant "MayCollectAndReenter" (ConPos)) (variant "UnknownEffect" (ConPos))) ())
(DImpl true "Eq" ((TyCon "CallEffect")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "NoManagedCollection") (PCon "NoManagedCollection")) () (EVar "True")) (arm (PTuple (PCon "MayCollect") (PCon "MayCollect")) () (EVar "True")) (arm (PTuple (PCon "MayCollectAndReenter") (PCon "MayCollectAndReenter")) () (EVar "True")) (arm (PTuple (PCon "UnknownEffect") (PCon "UnknownEffect")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "CallEffect")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "NoManagedCollection") () (ELit (LString "NoManagedCollection"))) (arm (PCon "MayCollect") () (ELit (LString "MayCollect"))) (arm (PCon "MayCollectAndReenter") () (ELit (LString "MayCollectAndReenter"))) (arm (PCon "UnknownEffect") () (ELit (LString "UnknownEffect")))))))
(DData Public "NativeEvent" () ((variant "Allocation" (ConPos (TyCon "String") (TyCon "LayoutKind") (TyCon "String") (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "StorageKind")) (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))) (variant "Call" (ConPos (TyCon "String") (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "StorageKind")) (TyCon "StorageKind") (TyCon "CallEffect"))) (variant "Operand" (ConPos (TyCon "String") (TyCon "String") (TyCon "StorageKind"))) (variant "Store" (ConPos (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "StorageKind"))) (variant "Derived" (ConPos (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "String"))) (variant "Uncovered" (ConPos (TyCon "String") (TyCon "String")))) ())
(DImpl true "Debug" ((TyCon "NativeEvent")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Allocation" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3") (PVar "__a4") (PVar "__a5") (PVar "__a6") (PVar "__a7")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Allocation ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a3")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a4")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a5")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a6")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a7"))))) (arm (PCon "Call" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3") (PVar "__a4") (PVar "__a5") (PVar "__a6")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Call ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a3")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a4")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a5")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a6"))))) (arm (PCon "Operand" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Operand ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a2"))))) (arm (PCon "Store" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3") (PVar "__a4")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Store ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a3")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a4"))))) (arm (PCon "Derived" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Derived ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a3"))))) (arm (PCon "Uncovered" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Uncovered ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))))))))
(DData Public "NativeLog" () ((variant "NativeLog" (ConNamed (field "events" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "NativeEvent")))) (field "scope" (TyApp (TyCon "Ref") (TyCon "String"))) (field "nextScope" (TyApp (TyCon "Ref") (TyCon "Int")))))) ())
(DTypeSig true "newLog" (TyFun (TyCon "Unit") (TyCon "NativeLog")))
(DFunDef false "newLog" (PWild) (ERecordCreate "NativeLog" ((fa "events" (EApp (EVar "Ref") (EListLit))) (fa "scope" (EApp (EVar "Ref") (ELit (LString "module")))) (fa "nextScope" (EApp (EVar "Ref") (ELit (LInt 0)))))))
(DTypeSig true "enterScope" (TyFun (TyCon "NativeLog") (TyFun (TyCon "String") (TyCon "Unit"))))
(DFunDef false "enterScope" ((PVar "log") (PVar "module_")) (EBlock (DoLet false false (PVar "n") (EUnOp "!" (EFieldAccess (EVar "log") "nextScope"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "log") "nextScope")) (EBinOp "+" (EVar "n") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "log") "scope")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "module_"))) (ELit (LString "/define"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "")))))))
(DTypeSig true "restoreScope" (TyFun (TyCon "NativeLog") (TyFun (TyCon "String") (TyCon "Unit"))))
(DFunDef false "restoreScope" ((PVar "log") (PVar "saved")) (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "log") "scope")) (EVar "saved")))
(DTypeSig true "currentScope" (TyFun (TyCon "NativeLog") (TyCon "String")))
(DFunDef false "currentScope" ((PVar "log")) (EUnOp "!" (EFieldAccess (EVar "log") "scope")))
(DTypeSig true "recordEvent" (TyFun (TyCon "NativeLog") (TyFun (TyCon "NativeEvent") (TyCon "Unit"))))
(DFunDef false "recordEvent" ((PVar "log") (PVar "event")) (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "log") "events")) (EBinOp "::" (EVar "event") (EUnOp "!" (EFieldAccess (EVar "log") "events")))))
(DTypeSig true "logEvents" (TyFun (TyCon "NativeLog") (TyApp (TyCon "List") (TyCon "NativeEvent"))))
(DFunDef false "logEvents" ((PVar "log")) (EApp (EVar "reverseL") (EUnOp "!" (EFieldAccess (EVar "log") "events"))))
(DTypeSig true "taggedSlots" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "StorageKind"))))
(DFunDef false "taggedSlots" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EBinOp "::" (EVar "TaggedWord") (EApp (EVar "taggedSlots") (EBinOp "-" (EVar "n") (ELit (LInt 1)))))))
(DTypeSig true "constructorSlots" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "StorageKind"))))
(DFunDef false "constructorSlots" ((PVar "n")) (EBinOp "::" (EVar "RawScalar") (EApp (EVar "taggedSlots") (EVar "n"))))
(DTypeSig true "closureSlots" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "StorageKind"))))
(DFunDef false "closureSlots" ((PVar "n")) (EBinOp "::" (EVar "RawScalar") (EBinOp "::" (EVar "CodeAddress") (EApp (EVar "taggedSlots") (EVar "n")))))
(DTypeSig true "helperContract" (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "StorageKind")) (TyCon "StorageKind") (TyCon "CallEffect"))))
(DFunDef false "helperContract" ((PLit (LString "mdk_byteblock_make"))) (ETuple (EListLit (EVar "TaggedWord")) (EVar "TaggedWord") (EVar "MayCollect")))
(DFunDef false "helperContract" ((PLit (LString "mdk_byteblock_copy"))) (ETuple (EListLit (EVar "TaggedWord") (EVar "TaggedWord")) (EVar "TaggedWord") (EVar "MayCollect")))
(DFunDef false "helperContract" ((PLit (LString "mdk_byteblock_length"))) (ETuple (EListLit (EVar "TaggedWord")) (EVar "TaggedWord") (EVar "NoManagedCollection")))
(DFunDef false "helperContract" ((PLit (LString "mdk_byteblock_get"))) (ETuple (EListLit (EVar "TaggedWord") (EVar "TaggedWord")) (EVar "TaggedWord") (EVar "NoManagedCollection")))
(DFunDef false "helperContract" ((PLit (LString "mdk_byteblock_set"))) (ETuple (EListLit (EVar "TaggedWord") (EVar "TaggedWord") (EVar "TaggedWord")) (EVar "NoValue") (EVar "NoManagedCollection")))
(DFunDef false "helperContract" ((PLit (LString "mdk_byteblock_blit"))) (ETuple (EListLit (EVar "TaggedWord") (EVar "TaggedWord") (EVar "TaggedWord") (EVar "TaggedWord") (EVar "TaggedWord")) (EVar "NoValue") (EVar "NoManagedCollection")))
(DFunDef false "helperContract" ((PLit (LString "mdk_bit_and"))) (ETuple (EListLit (EVar "RawScalar") (EVar "RawScalar")) (EVar "RawScalar") (EVar "NoManagedCollection")))
(DFunDef false "helperContract" ((PLit (LString "mdk_bit_or"))) (ETuple (EListLit (EVar "RawScalar") (EVar "RawScalar")) (EVar "RawScalar") (EVar "NoManagedCollection")))
(DFunDef false "helperContract" ((PLit (LString "mdk_bit_xor"))) (ETuple (EListLit (EVar "RawScalar") (EVar "RawScalar")) (EVar "RawScalar") (EVar "NoManagedCollection")))
(DFunDef false "helperContract" ((PLit (LString "mdk_shift_left"))) (ETuple (EListLit (EVar "RawScalar") (EVar "RawScalar")) (EVar "RawScalar") (EVar "MayCollectAndReenter")))
(DFunDef false "helperContract" ((PLit (LString "mdk_shift_right"))) (ETuple (EListLit (EVar "RawScalar") (EVar "RawScalar")) (EVar "RawScalar") (EVar "MayCollectAndReenter")))
(DFunDef false "helperContract" ((PLit (LString "mdk_bit_not"))) (ETuple (EListLit (EVar "RawScalar")) (EVar "RawScalar") (EVar "NoManagedCollection")))
(DFunDef false "helperContract" (PWild) (ETuple (EListLit) (EVar "UnknownStorage") (EVar "UnknownEffect")))
(DTypeSig true "runtimeCall" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "NativeEvent"))))))
(DFunDef false "runtimeCall" ((PVar "scope") (PVar "name") (PVar "result") (PVar "args")) (EBlock (DoLet false false (PTuple (PVar "kinds") (PVar "output") (PVar "callEffect")) (EApp (EVar "helperContract") (EVar "name"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Call") (EVar "scope")) (EVar "name")) (EVar "result")) (EVar "args")) (EVar "kinds")) (EVar "output")) (EVar "callEffect")))))
(DTypeSig false "allTagged" (TyFun (TyApp (TyCon "List") (TyCon "StorageKind")) (TyCon "Bool")))
(DFunDef false "allTagged" ((PList)) (EVar "True"))
(DFunDef false "allTagged" ((PCons (PCon "TaggedWord") (PVar "rest"))) (EApp (EVar "allTagged") (EVar "rest")))
(DFunDef false "allTagged" (PWild) (EVar "False"))
(DTypeSig false "validSlots" (TyFun (TyCon "LayoutKind") (TyFun (TyApp (TyCon "List") (TyCon "StorageKind")) (TyCon "Bool"))))
(DFunDef false "validSlots" ((PCon "ConstructorCell") (PCons (PCon "RawScalar") (PVar "fields"))) (EApp (EVar "allTagged") (EVar "fields")))
(DFunDef false "validSlots" ((PCon "ClosureCell") (PCons (PCon "RawScalar") (PCons (PCon "CodeAddress") (PVar "captures")))) (EApp (EVar "allTagged") (EVar "captures")))
(DFunDef false "validSlots" ((PCon "WordArray") (PCons (PCon "RawScalar") (PVar "fields"))) (EApp (EVar "allTagged") (EVar "fields")))
(DFunDef false "validSlots" ((PCon "DynamicWordArray") (PList (PCon "RawScalar") (PCon "TaggedWord"))) (EVar "True"))
(DFunDef false "validSlots" ((PCon "AtomicBox") (PList (PCon "RawScalar") (PCon "RawScalar"))) (EVar "True"))
(DFunDef false "validSlots" ((PCon "AtomicByteBlock") (PList (PCon "RawScalar") (PCon "RawScalar") (PCon "PackedBytes"))) (EVar "True"))
(DFunDef false "validSlots" (PWild PWild) (EVar "False"))
(DTypeSig true "validateEvent" (TyFun (TyCon "NativeEvent") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateEvent" ((PCon "Allocation" PWild (PVar "layout") PWild PWild (PVar "extent") (PVar "slots") PWild PWild)) (EIf (EBinOp "==" (EVar "extent") (ELit (LString ""))) (EListLit (ELit (LString "allocation has no extent"))) (EIf (EApp (EApp (EVar "validSlots") (EVar "layout")) (EVar "slots")) (EListLit) (EListLit (ELit (LString "allocation storage disagrees with its native layout"))))))
(DFunDef false "validateEvent" ((PCon "Call" PWild (PVar "name") PWild (PVar "args") (PVar "kinds") (PVar "output") (PVar "callEffect"))) (EBlock (DoLet false false (PTuple (PVar "expected") (PVar "expectedOutput") (PVar "expectedEffect")) (EApp (EVar "helperContract") (EVar "name"))) (DoExpr (EIf (EBinOp "==" (EVar "expectedEffect") (EVar "UnknownEffect")) (EIf (EBinOp "||" (EBinOp "==" (EVar "callEffect") (EVar "UnknownEffect")) (EBinOp "==" (EVar "callEffect") (EVar "MayCollectAndReenter"))) (EListLit) (EListLit (ELit (LString "unclassified call was declared collection-free")))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "kinds") (EVar "expected")) (EBinOp "==" (EVar "output") (EVar "expectedOutput"))) (EBinOp "==" (EVar "callEffect") (EVar "expectedEffect"))) (EBinOp "==" (EApp (EVar "listLen") (EVar "args")) (EApp (EVar "listLen") (EVar "kinds")))) (EListLit) (EListLit (ELit (LString "runtime call disagrees with its native ABI contract"))))))))
(DFunDef false "validateEvent" ((PCon "Store" PWild PWild PWild PWild (PCon "TaggedWord"))) (EListLit))
(DFunDef false "validateEvent" ((PCon "Store" PWild PWild PWild PWild PWild)) (EListLit (ELit (LString "Ref mutation must store a tagged value word"))))
(DFunDef false "validateEvent" (PWild) (EListLit))
(DTypeSig false "storageName" (TyFun (TyCon "StorageKind") (TyCon "String")))
(DFunDef false "storageName" ((PCon "TaggedWord")) (ELit (LString "tagged-value-word")))
(DFunDef false "storageName" ((PCon "RawScalar")) (ELit (LString "raw-scalar")))
(DFunDef false "storageName" ((PCon "CodeAddress")) (ELit (LString "code-address")))
(DFunDef false "storageName" ((PCon "PackedBytes")) (ELit (LString "packed-raw-bytes")))
(DFunDef false "storageName" ((PCon "StackAddress")) (ELit (LString "stack-address")))
(DFunDef false "storageName" ((PCon "NoValue")) (ELit (LString "void")))
(DFunDef false "storageName" ((PCon "UnknownStorage")) (ELit (LString "unknown")))
(DTypeSig false "layoutName" (TyFun (TyCon "LayoutKind") (TyCon "String")))
(DFunDef false "layoutName" ((PCon "ConstructorCell")) (ELit (LString "constructor")))
(DFunDef false "layoutName" ((PCon "ClosureCell")) (ELit (LString "closure")))
(DFunDef false "layoutName" ((PCon "WordArray")) (ELit (LString "word-array")))
(DFunDef false "layoutName" ((PCon "DynamicWordArray")) (ELit (LString "word-array-repeated-tagged-elements")))
(DFunDef false "layoutName" ((PCon "AtomicBox")) (ELit (LString "atomic-box")))
(DFunDef false "layoutName" ((PCon "AtomicByteBlock")) (ELit (LString "atomic-byte-block")))
(DTypeSig false "callEffectName" (TyFun (TyCon "CallEffect") (TyCon "String")))
(DFunDef false "callEffectName" ((PCon "NoManagedCollection")) (ELit (LString "no-managed-collection-no-callback")))
(DFunDef false "callEffectName" ((PCon "MayCollect")) (ELit (LString "may-collect-no-callback")))
(DFunDef false "callEffectName" ((PCon "MayCollectAndReenter")) (ELit (LString "may-collect-and-reenter")))
(DFunDef false "callEffectName" ((PCon "UnknownEffect")) (ELit (LString "unknown-may-collect-and-reenter")))
(DTypeSig false "node" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "node" ((PVar "tag") (PVar "fields")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "tag") (EVar "fields")))) (ELit (LString ")"))))
(DTypeSig false "strings" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "strings" ((PVar "xs")) (EApp (EApp (EVar "node") (ELit (LString "operands"))) (EApp (EApp (EVar "map") (EVar "escStr")) (EVar "xs"))))
(DTypeSig false "slotsText" (TyFun (TyApp (TyCon "List") (TyCon "StorageKind")) (TyCon "String")))
(DFunDef false "slotsText" ((PVar "xs")) (EApp (EApp (EVar "node") (ELit (LString "storage"))) (EApp (EApp (EVar "map") (EVar "storageName")) (EVar "xs"))))
(DTypeSig false "eventText" (TyFun (TyCon "NativeEvent") (TyCon "String")))
(DFunDef false "eventText" ((PCon "Allocation" (PVar "scope") (PVar "kind") (PVar "pointer") (PVar "word") (PVar "extent") (PVar "slots") (PVar "inputs") (PVar "init"))) (EApp (EApp (EVar "node") (ELit (LString "allocation"))) (EListLit (EApp (EVar "escStr") (EVar "scope")) (EApp (EVar "layoutName") (EVar "kind")) (EApp (EVar "escStr") (EVar "pointer")) (EApp (EVar "escStr") (EVar "word")) (EApp (EVar "escStr") (EVar "extent")) (EApp (EVar "slotsText") (EVar "slots")) (EApp (EVar "strings") (EVar "inputs")) (EApp (EVar "escStr") (EVar "init")))))
(DFunDef false "eventText" ((PCon "Call" (PVar "scope") (PVar "name") (PVar "result") (PVar "args") (PVar "kinds") (PVar "output") (PVar "callEffect"))) (EApp (EApp (EVar "node") (ELit (LString "call"))) (EListLit (EApp (EVar "escStr") (EVar "scope")) (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "escStr") (EVar "result")) (EApp (EVar "strings") (EVar "args")) (EApp (EVar "slotsText") (EVar "kinds")) (EApp (EVar "storageName") (EVar "output")) (EApp (EVar "callEffectName") (EVar "callEffect")))))
(DFunDef false "eventText" ((PCon "Operand" (PVar "scope") (PVar "word") (PVar "kind"))) (EApp (EApp (EVar "node") (ELit (LString "operand"))) (EListLit (EApp (EVar "escStr") (EVar "scope")) (EApp (EVar "escStr") (EVar "word")) (EApp (EVar "storageName") (EVar "kind")))))
(DFunDef false "eventText" ((PCon "Store" (PVar "scope") (PVar "owner") (PVar "offset") (PVar "word") (PVar "kind"))) (EApp (EApp (EVar "node") (ELit (LString "store"))) (EListLit (EApp (EVar "escStr") (EVar "scope")) (EApp (EVar "escStr") (EVar "owner")) (EApp (EVar "intToString") (EVar "offset")) (EApp (EVar "escStr") (EVar "word")) (EApp (EVar "storageName") (EVar "kind")))))
(DFunDef false "eventText" ((PCon "Derived" (PVar "scope") (PVar "address") (PVar "base") (PVar "offset"))) (EApp (EApp (EVar "node") (ELit (LString "derived"))) (EListLit (EApp (EVar "escStr") (EVar "scope")) (EApp (EVar "escStr") (EVar "address")) (EApp (EVar "escStr") (EVar "base")) (EApp (EVar "escStr") (EVar "offset")))))
(DFunDef false "eventText" ((PCon "Uncovered" (PVar "scope") (PVar "producer"))) (EApp (EApp (EVar "node") (ELit (LString "uncovered"))) (EListLit (EApp (EVar "escStr") (EVar "scope")) (EApp (EVar "escStr") (EVar "producer")))))
(DTypeSig false "binderText" (TyFun (TyCon "BinderRow") (TyCon "String")))
(DFunDef false "binderText" ((PVar "row")) (EMatch (EFieldAccess (EVar "row") "brId") (arm (PCon "BinderId" (PVar "module_") (PVar "ordinal")) () (EApp (EApp (EVar "node") (ELit (LString "semantic-binder"))) (EListLit (EApp (EVar "escStr") (EVar "module_")) (EApp (EVar "intToString") (EVar "ordinal")) (EApp (EVar "escStr") (EFieldAccess (EVar "row") "brName")) (EApp (EVar "runtimeTypeName") (EFieldAccess (EVar "row") "brType")) (EMatch (EFieldAccess (EVar "row") "brReturns") (arm (PCon "Some" (PVar "t")) () (EApp (EVar "runtimeTypeName") (EVar "t"))) (arm (PCon "None") () (ELit (LString "no-return-fact")))))))))
(DTypeSig false "eventGaps" (TyFun (TyCon "NativeEvent") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "eventGaps" ((PCon "Call" (PVar "scope") (PVar "name") PWild PWild PWild PWild (PCon "UnknownEffect"))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "unknown call contract: ")) (EApp (EVar "display") (EVar "scope"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "")))))
(DFunDef false "eventGaps" ((PCon "Derived" (PVar "scope") PWild PWild PWild)) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "heap-derived address requires relocation proof: ")) (EApp (EVar "display") (EVar "scope"))) (ELit (LString "")))))
(DFunDef false "eventGaps" ((PCon "Uncovered" (PVar "scope") (PVar "producer"))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "uncovered producer: ")) (EApp (EVar "display") (EVar "scope"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "producer"))) (ELit (LString "")))))
(DFunDef false "eventGaps" ((PCon "Allocation" (PVar "scope") PWild PWild PWild PWild PWild PWild (PLit (LString "deferred-backpatch")))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "deferred initialization requires publication proof: ")) (EApp (EVar "display") (EVar "scope"))) (ELit (LString "")))))
(DFunDef false "eventGaps" (PWild) (EListLit))
(DTypeSig true "renderContract" (TyFun (TyApp (TyCon "List") (TyCon "BinderRow")) (TyFun (TyApp (TyCon "List") (TyCon "NativeEvent")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "renderContract" ((PVar "binders") (PVar "events")) (EBlock (DoLet false false (PVar "faults") (EApp (EApp (EVar "flatMap") (EVar "validateEvent")) (EVar "events"))) (DoExpr (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "faults")) (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EVar "joinNl") (EVar "faults"))) (EBlock (DoLet false false (PVar "gaps") (EBinOp "++" (EListLit (ELit (LString "partial producer inventory: runtime families outside ByteBlock/bit and unhooked call paths are not covered")) (ELit (LString "root liveness, temporary roots and reloads are not produced")) (ELit (LString "C helper roots, uintptr_t root-slot ABI and allocating callback reentry are not established")) (ELit (LString "static/global ownership and barriers are not established")) (ELit (LString "tagged value words identify storage, not scalar types or membership in the managed heap"))) (EApp (EApp (EVar "flatMap") (EVar "eventGaps")) (EVar "events")))) (DoExpr (EApp (EVar "Ok") (EBinOp "++" (EApp (EVar "joinNl") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EApp (EApp (EVar "node") (ELit (LString "native-contract"))) (EListLit (ELit (LString "v1")) (ELit (LString "boehm")) (ELit (LString "incomplete")) (ELit (LString "moving-safe=false")))) (EApp (EApp (EVar "node") (ELit (LString "foreign-layout-obligation"))) (EListLit (ELit (LString "mdk_gc_byteblock_atomic_v1")) (ELit (LString "runtime-owned-extent")) (ELit (LString "atomic-mask-zero")) (ELit (LString "experimental-only")))) (EApp (EApp (EVar "node") (ELit (LString "foreign-root-obligation"))) (EListLit (ELit (LString "mdk_byteblock_copy")) (ELit (LString "source-argument=1")) (ELit (LString "Word-slot-before-allocation")) (ELit (LString "reload-before-source-derivation")) (ELit (LString "caller-reuse-needs-caller-roots"))))) (EApp (EApp (EVar "map") (EVar "binderText")) (EVar "binders"))) (EApp (EApp (EVar "map") (EVar "eventText")) (EVar "events"))) (EApp (EApp (EVar "map") (ELam ((PVar "gap")) (EApp (EApp (EVar "node") (ELit (LString "gap"))) (EListLit (EApp (EVar "escStr") (EVar "gap")))))) (EVar "gaps")))) (ELit (LString "\n"))))))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "BinderId" true))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderRow" true) (mem "runtimeTypeName" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "joinWith" false) (mem "reverseL" false) (mem "escStr" false) (mem "listLen" false))))
(DData Public "StorageKind" () ((variant "TaggedWord" (ConPos)) (variant "RawScalar" (ConPos)) (variant "CodeAddress" (ConPos)) (variant "PackedBytes" (ConPos)) (variant "StackAddress" (ConPos)) (variant "NoValue" (ConPos)) (variant "UnknownStorage" (ConPos))) ())
(DImpl true "Eq" ((TyCon "StorageKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "TaggedWord") (PCon "TaggedWord")) () (EVar "True")) (arm (PTuple (PCon "RawScalar") (PCon "RawScalar")) () (EVar "True")) (arm (PTuple (PCon "CodeAddress") (PCon "CodeAddress")) () (EVar "True")) (arm (PTuple (PCon "PackedBytes") (PCon "PackedBytes")) () (EVar "True")) (arm (PTuple (PCon "StackAddress") (PCon "StackAddress")) () (EVar "True")) (arm (PTuple (PCon "NoValue") (PCon "NoValue")) () (EVar "True")) (arm (PTuple (PCon "UnknownStorage") (PCon "UnknownStorage")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "StorageKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "TaggedWord") () (ELit (LString "TaggedWord"))) (arm (PCon "RawScalar") () (ELit (LString "RawScalar"))) (arm (PCon "CodeAddress") () (ELit (LString "CodeAddress"))) (arm (PCon "PackedBytes") () (ELit (LString "PackedBytes"))) (arm (PCon "StackAddress") () (ELit (LString "StackAddress"))) (arm (PCon "NoValue") () (ELit (LString "NoValue"))) (arm (PCon "UnknownStorage") () (ELit (LString "UnknownStorage")))))))
(DData Public "LayoutKind" () ((variant "ConstructorCell" (ConPos)) (variant "ClosureCell" (ConPos)) (variant "WordArray" (ConPos)) (variant "DynamicWordArray" (ConPos)) (variant "AtomicBox" (ConPos)) (variant "AtomicByteBlock" (ConPos))) ())
(DImpl true "Eq" ((TyCon "LayoutKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ConstructorCell") (PCon "ConstructorCell")) () (EVar "True")) (arm (PTuple (PCon "ClosureCell") (PCon "ClosureCell")) () (EVar "True")) (arm (PTuple (PCon "WordArray") (PCon "WordArray")) () (EVar "True")) (arm (PTuple (PCon "DynamicWordArray") (PCon "DynamicWordArray")) () (EVar "True")) (arm (PTuple (PCon "AtomicBox") (PCon "AtomicBox")) () (EVar "True")) (arm (PTuple (PCon "AtomicByteBlock") (PCon "AtomicByteBlock")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "LayoutKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "ConstructorCell") () (ELit (LString "ConstructorCell"))) (arm (PCon "ClosureCell") () (ELit (LString "ClosureCell"))) (arm (PCon "WordArray") () (ELit (LString "WordArray"))) (arm (PCon "DynamicWordArray") () (ELit (LString "DynamicWordArray"))) (arm (PCon "AtomicBox") () (ELit (LString "AtomicBox"))) (arm (PCon "AtomicByteBlock") () (ELit (LString "AtomicByteBlock")))))))
(DData Public "CallEffect" () ((variant "NoManagedCollection" (ConPos)) (variant "MayCollect" (ConPos)) (variant "MayCollectAndReenter" (ConPos)) (variant "UnknownEffect" (ConPos))) ())
(DImpl true "Eq" ((TyCon "CallEffect")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "NoManagedCollection") (PCon "NoManagedCollection")) () (EVar "True")) (arm (PTuple (PCon "MayCollect") (PCon "MayCollect")) () (EVar "True")) (arm (PTuple (PCon "MayCollectAndReenter") (PCon "MayCollectAndReenter")) () (EVar "True")) (arm (PTuple (PCon "UnknownEffect") (PCon "UnknownEffect")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "CallEffect")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "NoManagedCollection") () (ELit (LString "NoManagedCollection"))) (arm (PCon "MayCollect") () (ELit (LString "MayCollect"))) (arm (PCon "MayCollectAndReenter") () (ELit (LString "MayCollectAndReenter"))) (arm (PCon "UnknownEffect") () (ELit (LString "UnknownEffect")))))))
(DData Public "NativeEvent" () ((variant "Allocation" (ConPos (TyCon "String") (TyCon "LayoutKind") (TyCon "String") (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "StorageKind")) (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))) (variant "Call" (ConPos (TyCon "String") (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "StorageKind")) (TyCon "StorageKind") (TyCon "CallEffect"))) (variant "Operand" (ConPos (TyCon "String") (TyCon "String") (TyCon "StorageKind"))) (variant "Store" (ConPos (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "StorageKind"))) (variant "Derived" (ConPos (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "String"))) (variant "Uncovered" (ConPos (TyCon "String") (TyCon "String")))) ())
(DImpl true "Debug" ((TyCon "NativeEvent")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Allocation" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3") (PVar "__a4") (PVar "__a5") (PVar "__a6") (PVar "__a7")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Allocation ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a3")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a4")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a5")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a6")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a7"))))) (arm (PCon "Call" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3") (PVar "__a4") (PVar "__a5") (PVar "__a6")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Call ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a3")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a4")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a5")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a6"))))) (arm (PCon "Operand" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Operand ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a2"))))) (arm (PCon "Store" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3") (PVar "__a4")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Store ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a3")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a4"))))) (arm (PCon "Derived" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Derived ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a3"))))) (arm (PCon "Uncovered" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Uncovered ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))))))))
(DData Public "NativeLog" () ((variant "NativeLog" (ConNamed (field "events" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "NativeEvent")))) (field "scope" (TyApp (TyCon "Ref") (TyCon "String"))) (field "nextScope" (TyApp (TyCon "Ref") (TyCon "Int")))))) ())
(DTypeSig true "newLog" (TyFun (TyCon "Unit") (TyCon "NativeLog")))
(DFunDef false "newLog" (PWild) (ERecordCreate "NativeLog" ((fa "events" (EApp (EVar "Ref") (EListLit))) (fa "scope" (EApp (EVar "Ref") (ELit (LString "module")))) (fa "nextScope" (EApp (EVar "Ref") (ELit (LInt 0)))))))
(DTypeSig true "enterScope" (TyFun (TyCon "NativeLog") (TyFun (TyCon "String") (TyCon "Unit"))))
(DFunDef false "enterScope" ((PVar "log") (PVar "module_")) (EBlock (DoLet false false (PVar "n") (EUnOp "!" (EFieldAccess (EVar "log") "nextScope"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "log") "nextScope")) (EBinOp "+" (EVar "n") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "log") "scope")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "module_"))) (ELit (LString "/define"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "")))))))
(DTypeSig true "restoreScope" (TyFun (TyCon "NativeLog") (TyFun (TyCon "String") (TyCon "Unit"))))
(DFunDef false "restoreScope" ((PVar "log") (PVar "saved")) (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "log") "scope")) (EVar "saved")))
(DTypeSig true "currentScope" (TyFun (TyCon "NativeLog") (TyCon "String")))
(DFunDef false "currentScope" ((PVar "log")) (EUnOp "!" (EFieldAccess (EVar "log") "scope")))
(DTypeSig true "recordEvent" (TyFun (TyCon "NativeLog") (TyFun (TyCon "NativeEvent") (TyCon "Unit"))))
(DFunDef false "recordEvent" ((PVar "log") (PVar "event")) (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "log") "events")) (EBinOp "::" (EVar "event") (EUnOp "!" (EFieldAccess (EVar "log") "events")))))
(DTypeSig true "logEvents" (TyFun (TyCon "NativeLog") (TyApp (TyCon "List") (TyCon "NativeEvent"))))
(DFunDef false "logEvents" ((PVar "log")) (EApp (EVar "reverseL") (EUnOp "!" (EFieldAccess (EVar "log") "events"))))
(DTypeSig true "taggedSlots" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "StorageKind"))))
(DFunDef false "taggedSlots" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EBinOp "::" (EVar "TaggedWord") (EApp (EVar "taggedSlots") (EBinOp "-" (EVar "n") (ELit (LInt 1)))))))
(DTypeSig true "constructorSlots" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "StorageKind"))))
(DFunDef false "constructorSlots" ((PVar "n")) (EBinOp "::" (EVar "RawScalar") (EApp (EVar "taggedSlots") (EVar "n"))))
(DTypeSig true "closureSlots" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "StorageKind"))))
(DFunDef false "closureSlots" ((PVar "n")) (EBinOp "::" (EVar "RawScalar") (EBinOp "::" (EVar "CodeAddress") (EApp (EVar "taggedSlots") (EVar "n")))))
(DTypeSig true "helperContract" (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "StorageKind")) (TyCon "StorageKind") (TyCon "CallEffect"))))
(DFunDef false "helperContract" ((PLit (LString "mdk_byteblock_make"))) (ETuple (EListLit (EVar "TaggedWord")) (EVar "TaggedWord") (EVar "MayCollect")))
(DFunDef false "helperContract" ((PLit (LString "mdk_byteblock_copy"))) (ETuple (EListLit (EVar "TaggedWord") (EVar "TaggedWord")) (EVar "TaggedWord") (EVar "MayCollect")))
(DFunDef false "helperContract" ((PLit (LString "mdk_byteblock_length"))) (ETuple (EListLit (EVar "TaggedWord")) (EVar "TaggedWord") (EVar "NoManagedCollection")))
(DFunDef false "helperContract" ((PLit (LString "mdk_byteblock_get"))) (ETuple (EListLit (EVar "TaggedWord") (EVar "TaggedWord")) (EVar "TaggedWord") (EVar "NoManagedCollection")))
(DFunDef false "helperContract" ((PLit (LString "mdk_byteblock_set"))) (ETuple (EListLit (EVar "TaggedWord") (EVar "TaggedWord") (EVar "TaggedWord")) (EVar "NoValue") (EVar "NoManagedCollection")))
(DFunDef false "helperContract" ((PLit (LString "mdk_byteblock_blit"))) (ETuple (EListLit (EVar "TaggedWord") (EVar "TaggedWord") (EVar "TaggedWord") (EVar "TaggedWord") (EVar "TaggedWord")) (EVar "NoValue") (EVar "NoManagedCollection")))
(DFunDef false "helperContract" ((PLit (LString "mdk_bit_and"))) (ETuple (EListLit (EVar "RawScalar") (EVar "RawScalar")) (EVar "RawScalar") (EVar "NoManagedCollection")))
(DFunDef false "helperContract" ((PLit (LString "mdk_bit_or"))) (ETuple (EListLit (EVar "RawScalar") (EVar "RawScalar")) (EVar "RawScalar") (EVar "NoManagedCollection")))
(DFunDef false "helperContract" ((PLit (LString "mdk_bit_xor"))) (ETuple (EListLit (EVar "RawScalar") (EVar "RawScalar")) (EVar "RawScalar") (EVar "NoManagedCollection")))
(DFunDef false "helperContract" ((PLit (LString "mdk_shift_left"))) (ETuple (EListLit (EVar "RawScalar") (EVar "RawScalar")) (EVar "RawScalar") (EVar "MayCollectAndReenter")))
(DFunDef false "helperContract" ((PLit (LString "mdk_shift_right"))) (ETuple (EListLit (EVar "RawScalar") (EVar "RawScalar")) (EVar "RawScalar") (EVar "MayCollectAndReenter")))
(DFunDef false "helperContract" ((PLit (LString "mdk_bit_not"))) (ETuple (EListLit (EVar "RawScalar")) (EVar "RawScalar") (EVar "NoManagedCollection")))
(DFunDef false "helperContract" (PWild) (ETuple (EListLit) (EVar "UnknownStorage") (EVar "UnknownEffect")))
(DTypeSig true "runtimeCall" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "NativeEvent"))))))
(DFunDef false "runtimeCall" ((PVar "scope") (PVar "name") (PVar "result") (PVar "args")) (EBlock (DoLet false false (PTuple (PVar "kinds") (PVar "output") (PVar "callEffect")) (EApp (EVar "helperContract") (EVar "name"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Call") (EVar "scope")) (EVar "name")) (EVar "result")) (EVar "args")) (EVar "kinds")) (EVar "output")) (EVar "callEffect")))))
(DTypeSig false "allTagged" (TyFun (TyApp (TyCon "List") (TyCon "StorageKind")) (TyCon "Bool")))
(DFunDef false "allTagged" ((PList)) (EVar "True"))
(DFunDef false "allTagged" ((PCons (PCon "TaggedWord") (PVar "rest"))) (EApp (EVar "allTagged") (EVar "rest")))
(DFunDef false "allTagged" (PWild) (EVar "False"))
(DTypeSig false "validSlots" (TyFun (TyCon "LayoutKind") (TyFun (TyApp (TyCon "List") (TyCon "StorageKind")) (TyCon "Bool"))))
(DFunDef false "validSlots" ((PCon "ConstructorCell") (PCons (PCon "RawScalar") (PVar "fields"))) (EApp (EVar "allTagged") (EVar "fields")))
(DFunDef false "validSlots" ((PCon "ClosureCell") (PCons (PCon "RawScalar") (PCons (PCon "CodeAddress") (PVar "captures")))) (EApp (EVar "allTagged") (EVar "captures")))
(DFunDef false "validSlots" ((PCon "WordArray") (PCons (PCon "RawScalar") (PVar "fields"))) (EApp (EVar "allTagged") (EVar "fields")))
(DFunDef false "validSlots" ((PCon "DynamicWordArray") (PList (PCon "RawScalar") (PCon "TaggedWord"))) (EVar "True"))
(DFunDef false "validSlots" ((PCon "AtomicBox") (PList (PCon "RawScalar") (PCon "RawScalar"))) (EVar "True"))
(DFunDef false "validSlots" ((PCon "AtomicByteBlock") (PList (PCon "RawScalar") (PCon "RawScalar") (PCon "PackedBytes"))) (EVar "True"))
(DFunDef false "validSlots" (PWild PWild) (EVar "False"))
(DTypeSig true "validateEvent" (TyFun (TyCon "NativeEvent") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateEvent" ((PCon "Allocation" PWild (PVar "layout") PWild PWild (PVar "extent") (PVar "slots") PWild PWild)) (EIf (EBinOp "==" (EVar "extent") (ELit (LString ""))) (EListLit (ELit (LString "allocation has no extent"))) (EIf (EApp (EApp (EVar "validSlots") (EVar "layout")) (EVar "slots")) (EListLit) (EListLit (ELit (LString "allocation storage disagrees with its native layout"))))))
(DFunDef false "validateEvent" ((PCon "Call" PWild (PVar "name") PWild (PVar "args") (PVar "kinds") (PVar "output") (PVar "callEffect"))) (EBlock (DoLet false false (PTuple (PVar "expected") (PVar "expectedOutput") (PVar "expectedEffect")) (EApp (EVar "helperContract") (EVar "name"))) (DoExpr (EIf (EBinOp "==" (EVar "expectedEffect") (EVar "UnknownEffect")) (EIf (EBinOp "||" (EBinOp "==" (EVar "callEffect") (EVar "UnknownEffect")) (EBinOp "==" (EVar "callEffect") (EVar "MayCollectAndReenter"))) (EListLit) (EListLit (ELit (LString "unclassified call was declared collection-free")))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "kinds") (EVar "expected")) (EBinOp "==" (EVar "output") (EVar "expectedOutput"))) (EBinOp "==" (EVar "callEffect") (EVar "expectedEffect"))) (EBinOp "==" (EApp (EVar "listLen") (EVar "args")) (EApp (EVar "listLen") (EVar "kinds")))) (EListLit) (EListLit (ELit (LString "runtime call disagrees with its native ABI contract"))))))))
(DFunDef false "validateEvent" ((PCon "Store" PWild PWild PWild PWild (PCon "TaggedWord"))) (EListLit))
(DFunDef false "validateEvent" ((PCon "Store" PWild PWild PWild PWild PWild)) (EListLit (ELit (LString "Ref mutation must store a tagged value word"))))
(DFunDef false "validateEvent" (PWild) (EListLit))
(DTypeSig false "storageName" (TyFun (TyCon "StorageKind") (TyCon "String")))
(DFunDef false "storageName" ((PCon "TaggedWord")) (ELit (LString "tagged-value-word")))
(DFunDef false "storageName" ((PCon "RawScalar")) (ELit (LString "raw-scalar")))
(DFunDef false "storageName" ((PCon "CodeAddress")) (ELit (LString "code-address")))
(DFunDef false "storageName" ((PCon "PackedBytes")) (ELit (LString "packed-raw-bytes")))
(DFunDef false "storageName" ((PCon "StackAddress")) (ELit (LString "stack-address")))
(DFunDef false "storageName" ((PCon "NoValue")) (ELit (LString "void")))
(DFunDef false "storageName" ((PCon "UnknownStorage")) (ELit (LString "unknown")))
(DTypeSig false "layoutName" (TyFun (TyCon "LayoutKind") (TyCon "String")))
(DFunDef false "layoutName" ((PCon "ConstructorCell")) (ELit (LString "constructor")))
(DFunDef false "layoutName" ((PCon "ClosureCell")) (ELit (LString "closure")))
(DFunDef false "layoutName" ((PCon "WordArray")) (ELit (LString "word-array")))
(DFunDef false "layoutName" ((PCon "DynamicWordArray")) (ELit (LString "word-array-repeated-tagged-elements")))
(DFunDef false "layoutName" ((PCon "AtomicBox")) (ELit (LString "atomic-box")))
(DFunDef false "layoutName" ((PCon "AtomicByteBlock")) (ELit (LString "atomic-byte-block")))
(DTypeSig false "callEffectName" (TyFun (TyCon "CallEffect") (TyCon "String")))
(DFunDef false "callEffectName" ((PCon "NoManagedCollection")) (ELit (LString "no-managed-collection-no-callback")))
(DFunDef false "callEffectName" ((PCon "MayCollect")) (ELit (LString "may-collect-no-callback")))
(DFunDef false "callEffectName" ((PCon "MayCollectAndReenter")) (ELit (LString "may-collect-and-reenter")))
(DFunDef false "callEffectName" ((PCon "UnknownEffect")) (ELit (LString "unknown-may-collect-and-reenter")))
(DTypeSig false "node" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "node" ((PVar "tag") (PVar "fields")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "tag") (EVar "fields")))) (ELit (LString ")"))))
(DTypeSig false "strings" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "strings" ((PVar "xs")) (EApp (EApp (EVar "node") (ELit (LString "operands"))) (EApp (EApp (EMethodRef "map") (EVar "escStr")) (EVar "xs"))))
(DTypeSig false "slotsText" (TyFun (TyApp (TyCon "List") (TyCon "StorageKind")) (TyCon "String")))
(DFunDef false "slotsText" ((PVar "xs")) (EApp (EApp (EVar "node") (ELit (LString "storage"))) (EApp (EApp (EMethodRef "map") (EVar "storageName")) (EVar "xs"))))
(DTypeSig false "eventText" (TyFun (TyCon "NativeEvent") (TyCon "String")))
(DFunDef false "eventText" ((PCon "Allocation" (PVar "scope") (PVar "kind") (PVar "pointer") (PVar "word") (PVar "extent") (PVar "slots") (PVar "inputs") (PVar "init"))) (EApp (EApp (EVar "node") (ELit (LString "allocation"))) (EListLit (EApp (EVar "escStr") (EVar "scope")) (EApp (EVar "layoutName") (EVar "kind")) (EApp (EVar "escStr") (EVar "pointer")) (EApp (EVar "escStr") (EVar "word")) (EApp (EVar "escStr") (EVar "extent")) (EApp (EVar "slotsText") (EVar "slots")) (EApp (EVar "strings") (EVar "inputs")) (EApp (EVar "escStr") (EVar "init")))))
(DFunDef false "eventText" ((PCon "Call" (PVar "scope") (PVar "name") (PVar "result") (PVar "args") (PVar "kinds") (PVar "output") (PVar "callEffect"))) (EApp (EApp (EVar "node") (ELit (LString "call"))) (EListLit (EApp (EVar "escStr") (EVar "scope")) (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "escStr") (EVar "result")) (EApp (EVar "strings") (EVar "args")) (EApp (EVar "slotsText") (EVar "kinds")) (EApp (EVar "storageName") (EVar "output")) (EApp (EVar "callEffectName") (EVar "callEffect")))))
(DFunDef false "eventText" ((PCon "Operand" (PVar "scope") (PVar "word") (PVar "kind"))) (EApp (EApp (EVar "node") (ELit (LString "operand"))) (EListLit (EApp (EVar "escStr") (EVar "scope")) (EApp (EVar "escStr") (EVar "word")) (EApp (EVar "storageName") (EVar "kind")))))
(DFunDef false "eventText" ((PCon "Store" (PVar "scope") (PVar "owner") (PVar "offset") (PVar "word") (PVar "kind"))) (EApp (EApp (EVar "node") (ELit (LString "store"))) (EListLit (EApp (EVar "escStr") (EVar "scope")) (EApp (EVar "escStr") (EVar "owner")) (EApp (EVar "intToString") (EVar "offset")) (EApp (EVar "escStr") (EVar "word")) (EApp (EVar "storageName") (EVar "kind")))))
(DFunDef false "eventText" ((PCon "Derived" (PVar "scope") (PVar "address") (PVar "base") (PVar "offset"))) (EApp (EApp (EVar "node") (ELit (LString "derived"))) (EListLit (EApp (EVar "escStr") (EVar "scope")) (EApp (EVar "escStr") (EVar "address")) (EApp (EVar "escStr") (EVar "base")) (EApp (EVar "escStr") (EVar "offset")))))
(DFunDef false "eventText" ((PCon "Uncovered" (PVar "scope") (PVar "producer"))) (EApp (EApp (EVar "node") (ELit (LString "uncovered"))) (EListLit (EApp (EVar "escStr") (EVar "scope")) (EApp (EVar "escStr") (EVar "producer")))))
(DTypeSig false "binderText" (TyFun (TyCon "BinderRow") (TyCon "String")))
(DFunDef false "binderText" ((PVar "row")) (EMatch (EFieldAccess (EVar "row") "brId") (arm (PCon "BinderId" (PVar "module_") (PVar "ordinal")) () (EApp (EApp (EVar "node") (ELit (LString "semantic-binder"))) (EListLit (EApp (EVar "escStr") (EVar "module_")) (EApp (EVar "intToString") (EVar "ordinal")) (EApp (EVar "escStr") (EFieldAccess (EVar "row") "brName")) (EApp (EVar "runtimeTypeName") (EFieldAccess (EVar "row") "brType")) (EMatch (EFieldAccess (EVar "row") "brReturns") (arm (PCon "Some" (PVar "t")) () (EApp (EVar "runtimeTypeName") (EVar "t"))) (arm (PCon "None") () (ELit (LString "no-return-fact")))))))))
(DTypeSig false "eventGaps" (TyFun (TyCon "NativeEvent") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "eventGaps" ((PCon "Call" (PVar "scope") (PVar "name") PWild PWild PWild PWild (PCon "UnknownEffect"))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "unknown call contract: ")) (EApp (EMethodRef "display") (EVar "scope"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "")))))
(DFunDef false "eventGaps" ((PCon "Derived" (PVar "scope") PWild PWild PWild)) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "heap-derived address requires relocation proof: ")) (EApp (EMethodRef "display") (EVar "scope"))) (ELit (LString "")))))
(DFunDef false "eventGaps" ((PCon "Uncovered" (PVar "scope") (PVar "producer"))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "uncovered producer: ")) (EApp (EMethodRef "display") (EVar "scope"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "producer"))) (ELit (LString "")))))
(DFunDef false "eventGaps" ((PCon "Allocation" (PVar "scope") PWild PWild PWild PWild PWild PWild (PLit (LString "deferred-backpatch")))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "deferred initialization requires publication proof: ")) (EApp (EMethodRef "display") (EVar "scope"))) (ELit (LString "")))))
(DFunDef false "eventGaps" (PWild) (EListLit))
(DTypeSig true "renderContract" (TyFun (TyApp (TyCon "List") (TyCon "BinderRow")) (TyFun (TyApp (TyCon "List") (TyCon "NativeEvent")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "renderContract" ((PVar "binders") (PVar "events")) (EBlock (DoLet false false (PVar "faults") (EApp (EApp (EDictApp "flatMap") (EVar "validateEvent")) (EVar "events"))) (DoExpr (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "faults")) (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EVar "joinNl") (EVar "faults"))) (EBlock (DoLet false false (PVar "gaps") (EBinOp "++" (EListLit (ELit (LString "partial producer inventory: runtime families outside ByteBlock/bit and unhooked call paths are not covered")) (ELit (LString "root liveness, temporary roots and reloads are not produced")) (ELit (LString "C helper roots, uintptr_t root-slot ABI and allocating callback reentry are not established")) (ELit (LString "static/global ownership and barriers are not established")) (ELit (LString "tagged value words identify storage, not scalar types or membership in the managed heap"))) (EApp (EApp (EDictApp "flatMap") (EVar "eventGaps")) (EVar "events")))) (DoExpr (EApp (EVar "Ok") (EBinOp "++" (EApp (EVar "joinNl") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EApp (EApp (EVar "node") (ELit (LString "native-contract"))) (EListLit (ELit (LString "v1")) (ELit (LString "boehm")) (ELit (LString "incomplete")) (ELit (LString "moving-safe=false")))) (EApp (EApp (EVar "node") (ELit (LString "foreign-layout-obligation"))) (EListLit (ELit (LString "mdk_gc_byteblock_atomic_v1")) (ELit (LString "runtime-owned-extent")) (ELit (LString "atomic-mask-zero")) (ELit (LString "experimental-only")))) (EApp (EApp (EVar "node") (ELit (LString "foreign-root-obligation"))) (EListLit (ELit (LString "mdk_byteblock_copy")) (ELit (LString "source-argument=1")) (ELit (LString "Word-slot-before-allocation")) (ELit (LString "reload-before-source-derivation")) (ELit (LString "caller-reuse-needs-caller-roots"))))) (EApp (EApp (EMethodRef "map") (EVar "binderText")) (EVar "binders"))) (EApp (EApp (EMethodRef "map") (EVar "eventText")) (EVar "events"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "gap")) (EApp (EApp (EVar "node") (ELit (LString "gap"))) (EListLit (EApp (EVar "escStr") (EVar "gap")))))) (EVar "gaps")))) (ELit (LString "\n"))))))))))
