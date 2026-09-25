# META
source_lines=58
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
-- Declared type-parameter kinds on declaration heads
-- (docs/spec/EFFECTS-SEMANTICS.md §6.1-§6.3).  Also enrolled in
-- diff_compiler_fmt.sh via test/parse_fixtures/*.mdk, so declared_kinds.fmt.golden
-- pins the byte-for-byte round trip: dropping an annotation here would DELETE a
-- kind from the user's source, which is why the golden covers every head form.

-- all four heads, atomic `Effect`, PARTIALLY annotated (`a` stays bare)
data Async (e : Effect) a = Done a | Suspend (Unit -> Async e a)

newtype Box (e : Effect) = MkBox Int

type LaterInt (e : Effect) = Async e Int

interface DeferredThenable (f : Effect -> Type -> Type) where
  deferThen : f e a -> f e b

-- the arrow associates RIGHT, so this head re-prints with no parentheses at all
interface Chained (f : Effect -> Effect -> Type -> Type) where
  chained : f e d a

-- a LEFT-nested arrow: the one place parentheses survive the round trip
data Fixed (g : (Type -> Type) -> Type) = MkFixed Int

-- every parameter annotated, mixed kinds, and an `Effect` in an arrow's DOMAIN
interface Mixed (g : (Type -> Type) -> Type) (h : Effect) (a : Type) where
  mixed : g h a

-- `Type` and `Effect` are NOT keywords: they are ordinary capitalised
-- identifiers recognised only in kind position, so both remain usable as
-- ordinary type and constructor names.
data Type = Type Int

data Effect = Effect Int

-- no annotation anywhere: the pre-existing shape, unchanged
data Wrap f a = W (f a)

-- `Authority L` kinds (EFFECTS-SEMANTICS §4.1, §6.1): a head parameter, its
-- field qualifier, an index argument spelled by a name, a literal and `*`,
-- and a constructor's existential binder — every spelling the formatter
-- must hand back unchanged.
data Handle (p : Authority FileRead) = Handle (String @p)

data AnyHandle = AnyHandle (p : Authority FileRead) (Handle p)

data Conf (p : Authority FileRead) = Conf { path : String @p, retries : Int }

newtype Boxed (p : Authority FileRead) = MkBoxed (Handle p)

type Cfg = Handle "config/*"

type AnyH = Handle *

open : (path : String) -> Handle path
open path = Handle path

readIt : Handle p -> <FileRead p> Result String String
readIt (Handle s) = readFile s
# PARSE
(DData Private "Async" ("e" "a") ((variant "Done" (ConPos (TyVar "a"))) (variant "Suspend" (ConPos (TyFun (TyCon "Unit") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")))))) ())
(DNewtype false "Box" ("e") "MkBox" (TyCon "Int") ())
(DTypeAlias false "LaterInt" ("e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Int")))
(DInterface false false "DeferredThenable" ("f") () ((imethod "deferThen" (TyFun (TyApp (TyApp (TyVar "f") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyVar "f") (TyVar "e")) (TyVar "b"))) None)))
(DInterface false false "Chained" ("f") () ((imethod "chained" (TyApp (TyApp (TyApp (TyVar "f") (TyVar "e")) (TyVar "d")) (TyVar "a")) None)))
(DData Private "Fixed" ("g") ((variant "MkFixed" (ConPos (TyCon "Int")))) ())
(DInterface false false "Mixed" ("g" "h" "a") () ((imethod "mixed" (TyApp (TyApp (TyVar "g") (TyVar "h")) (TyVar "a")) None)))
(DData Private "Type" () ((variant "Type" (ConPos (TyCon "Int")))) ())
(DData Private "Effect" () ((variant "Effect" (ConPos (TyCon "Int")))) ())
(DData Private "Wrap" ("f" "a") ((variant "W" (ConPos (TyApp (TyVar "f") (TyVar "a"))))) ())
(DData Private "Handle" ("p") ((variant "Handle" (ConPos (TyQual (TyCon "String") "p")))) ())
(DData Private "AnyHandle" () ((variant "AnyHandle" (ConPos (TyApp (TyCon "Handle") (TyVar "p"))))) ())
(DData Private "Conf" ("p") ((variant "Conf" (ConNamed (field "path" (TyQual (TyCon "String") "p")) (field "retries" (TyCon "Int"))))) ())
(DNewtype false "Boxed" ("p") "MkBoxed" (TyApp (TyCon "Handle") (TyVar "p")) ())
(DTypeAlias false "Cfg" () (TyApp (TyCon "Handle") (TyAuth "config/*")))
(DTypeAlias false "AnyH" () (TyApp (TyCon "Handle") (TyAuth None)))
(DTypeSig false "open" (TyFun (TyNamed "path" (TyCon "String")) (TyApp (TyCon "Handle") (TyVar "path"))))
(DFunDef false "open" ((PVar "path")) (EApp (EVar "Handle") (EVar "path")))
(DTypeSig false "readIt" (TyFun (TyApp (TyCon "Handle") (TyVar "p")) (TyEffect ((atom "FileRead" (name "p"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "readIt" ((PCon "Handle" (PVar "s"))) (EApp (EVar "readFile") (EVar "s")))
# PRINTER
data Async (e : Effect) a = Done a | Suspend (Unit -> Async e a)
newtype Box (e : Effect) = MkBox Int
type LaterInt (e : Effect) = Async e Int
interface DeferredThenable (f : Effect -> Type -> Type) where
  deferThen : f e a -> f e b
interface Chained (f : Effect -> Effect -> Type -> Type) where
  chained : f e d a
data Fixed (g : (Type -> Type) -> Type) = MkFixed Int
interface Mixed (g : (Type -> Type) -> Type) (h : Effect) (a : Type) where
  mixed : g h a
data Type = Type Int
data Effect = Effect Int
data Wrap f a = W (f a)
data Handle (p : Authority FileRead) = Handle (String @p)
data AnyHandle = AnyHandle (p : Authority FileRead) (Handle p)
data Conf (p : Authority FileRead) = Conf { path : String @p, retries : Int }
newtype Boxed (p : Authority FileRead) = MkBoxed (Handle p)
type Cfg = Handle "config/*"
type AnyH = Handle *
open : (path : String) -> Handle path
open path = Handle path
readIt : Handle p -> <FileRead p> Result String String
readIt (Handle s) = readFile s
# DESUGAR
(DData Private "Async" ("e" "a") ((variant "Done" (ConPos (TyVar "a"))) (variant "Suspend" (ConPos (TyFun (TyCon "Unit") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")))))) ())
(DNewtype false "Box" ("e") "MkBox" (TyCon "Int") ())
(DTypeAlias false "LaterInt" ("e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Int")))
(DInterface false false "DeferredThenable" ("f") () ((imethod "deferThen" (TyFun (TyApp (TyApp (TyVar "f") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyVar "f") (TyVar "e")) (TyVar "b"))) None)))
(DInterface false false "Chained" ("f") () ((imethod "chained" (TyApp (TyApp (TyApp (TyVar "f") (TyVar "e")) (TyVar "d")) (TyVar "a")) None)))
(DData Private "Fixed" ("g") ((variant "MkFixed" (ConPos (TyCon "Int")))) ())
(DInterface false false "Mixed" ("g" "h" "a") () ((imethod "mixed" (TyApp (TyApp (TyVar "g") (TyVar "h")) (TyVar "a")) None)))
(DData Private "Type" () ((variant "Type" (ConPos (TyCon "Int")))) ())
(DData Private "Effect" () ((variant "Effect" (ConPos (TyCon "Int")))) ())
(DData Private "Wrap" ("f" "a") ((variant "W" (ConPos (TyApp (TyVar "f") (TyVar "a"))))) ())
(DData Private "Handle" ("p") ((variant "Handle" (ConPos (TyQual (TyCon "String") "p")))) ())
(DData Private "AnyHandle" () ((variant "AnyHandle" (ConPos (TyApp (TyCon "Handle") (TyVar "p"))))) ())
(DData Private "Conf" ("p") ((variant "Conf" (ConNamed (field "path" (TyQual (TyCon "String") "p")) (field "retries" (TyCon "Int"))))) ())
(DNewtype false "Boxed" ("p") "MkBoxed" (TyApp (TyCon "Handle") (TyVar "p")) ())
(DTypeAlias false "Cfg" () (TyApp (TyCon "Handle") (TyAuth "config/*")))
(DTypeAlias false "AnyH" () (TyApp (TyCon "Handle") (TyAuth None)))
(DTypeSig false "open" (TyFun (TyNamed "path" (TyCon "String")) (TyApp (TyCon "Handle") (TyVar "path"))))
(DFunDef false "open" ((PVar "path")) (EApp (EVar "Handle") (EVar "path")))
(DTypeSig false "readIt" (TyFun (TyApp (TyCon "Handle") (TyVar "p")) (TyEffect ((atom "FileRead" (name "p"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "readIt" ((PCon "Handle" (PVar "s"))) (EApp (EVar "readFile") (EVar "s")))
# MARK
(DData Private "Async" ("e" "a") ((variant "Done" (ConPos (TyVar "a"))) (variant "Suspend" (ConPos (TyFun (TyCon "Unit") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")))))) ())
(DNewtype false "Box" ("e") "MkBox" (TyCon "Int") ())
(DTypeAlias false "LaterInt" ("e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Int")))
(DInterface false false "DeferredThenable" ("f") () ((imethod "deferThen" (TyFun (TyApp (TyApp (TyVar "f") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyVar "f") (TyVar "e")) (TyVar "b"))) None)))
(DInterface false false "Chained" ("f") () ((imethod "chained" (TyApp (TyApp (TyApp (TyVar "f") (TyVar "e")) (TyVar "d")) (TyVar "a")) None)))
(DData Private "Fixed" ("g") ((variant "MkFixed" (ConPos (TyCon "Int")))) ())
(DInterface false false "Mixed" ("g" "h" "a") () ((imethod "mixed" (TyApp (TyApp (TyVar "g") (TyVar "h")) (TyVar "a")) None)))
(DData Private "Type" () ((variant "Type" (ConPos (TyCon "Int")))) ())
(DData Private "Effect" () ((variant "Effect" (ConPos (TyCon "Int")))) ())
(DData Private "Wrap" ("f" "a") ((variant "W" (ConPos (TyApp (TyVar "f") (TyVar "a"))))) ())
(DData Private "Handle" ("p") ((variant "Handle" (ConPos (TyQual (TyCon "String") "p")))) ())
(DData Private "AnyHandle" () ((variant "AnyHandle" (ConPos (TyApp (TyCon "Handle") (TyVar "p"))))) ())
(DData Private "Conf" ("p") ((variant "Conf" (ConNamed (field "path" (TyQual (TyCon "String") "p")) (field "retries" (TyCon "Int"))))) ())
(DNewtype false "Boxed" ("p") "MkBoxed" (TyApp (TyCon "Handle") (TyVar "p")) ())
(DTypeAlias false "Cfg" () (TyApp (TyCon "Handle") (TyAuth "config/*")))
(DTypeAlias false "AnyH" () (TyApp (TyCon "Handle") (TyAuth None)))
(DTypeSig false "open" (TyFun (TyNamed "path" (TyCon "String")) (TyApp (TyCon "Handle") (TyVar "path"))))
(DFunDef false "open" ((PVar "path")) (EApp (EVar "Handle") (EVar "path")))
(DTypeSig false "readIt" (TyFun (TyApp (TyCon "Handle") (TyVar "p")) (TyEffect ((atom "FileRead" (name "p"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "readIt" ((PCon "Handle" (PVar "s"))) (EApp (EVar "readFile") (EVar "s")))
