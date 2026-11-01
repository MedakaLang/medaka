# META
source_lines=1148
stages=DESUGAR,MARK
# SOURCE
-- A module's export surface, built from its declarations and the surfaces of
-- the modules it re-exports.
--
-- `ModuleExports` is what an importer sees of a module.  `buildExportsWith`
-- computes it from the module's own decls plus the surfaces of the modules its
-- `export import`s name, and `coreExports` builds the prelude's.  A module's
-- test sibling sees its full view instead (`ExportView`, `fullExportsOf`), the
-- same type built by the full-view rule of every namespace.  This module
-- imports no resolver state: `frontend.resolve` imports it, never the reverse.
--
-- The typechecker and both interpreters (`evalModulesWith`, `cevalModules`) read
-- the same facets through `directIn` (decl lists), `declExportsIn`/
-- `declExportsCtors` (one decl) and `exportedValueNames`.  The one-decl
-- predicates do not unwrap `DAttrib`; the list readers do.

import frontend.ast.{
  variantName,
  letBindName,
  Loc(..),
  UseMember(..),
  UsePath(..),
  useMemberLocal,
  IfaceMethod(..),
  ImplMethod(..),
  DataVis(..),
  Field(..),
  ConPayload(..),
  Variant(..),
  Decl(..),
  ExternDecl(..),
}
import list.{head, last}
import support.ordmap.{
  OrdMap,
  omEmpty,
  omHasKey,
  omInsert,
  omLookup,
  omFromNames,
  omFromPairs,
}
import support.util.{
  contains,
  listLen,
  lookupAssoc,
  reverseL,
  initList,
  joinDot,
  filterList,
  dedup,
  isEmptyL,
  isNonEmptyL,
  selfBinding,
}

export
ifaceMethodsOf : String -> List (String, List String) -> List String
ifaceMethodsOf _ [] = []
ifaceMethodsOf iface ((i, ms) :: rest)
  | i == iface = ms
  | otherwise = ifaceMethodsOf iface rest

export
dataRecordNames : List Decl -> List String
dataRecordNames [] = []
dataRecordNames ((DData { dataName = n }) :: rest) = n :: dataRecordNames rest
dataRecordNames ((DTypeAlias { tyAliasName = n }) :: rest) =
  n :: dataRecordNames rest
dataRecordNames ((DNewtype { newtypeName = n }) :: rest) =
  n :: dataRecordNames rest
dataRecordNames ((DAttrib _ d) :: rest) = dataRecordNames (d :: rest)
dataRecordNames (_ :: rest) = dataRecordNames rest

-- user/platform effect labels declared with `effect Foo` (Phase 146 gap 2)
export
effectNames : List Decl -> List String
effectNames [] = []
effectNames ((DEffect _ n _ _ _ _) :: rest) = n :: effectNames rest
effectNames ((DAttrib _ d) :: rest) = effectNames (d :: rest)
effectNames (_ :: rest) = effectNames rest

export
ctorNames : List Decl -> List String
ctorNames [] = []
ctorNames ((DData { dataCtors = vs }) :: rest) =
  map variantName vs ++ ctorNames rest
ctorNames ((DNewtype { newtypeCtor = con }) :: rest) = con :: ctorNames rest
ctorNames ((DAttrib _ d) :: rest) = ctorNames (d :: rest)
ctorNames (_ :: rest) = ctorNames rest

export
ifaceMethodNm : IfaceMethod -> String
ifaceMethodNm (IfaceMethod n _ _ _) = n

implMethodNm : ImplMethod -> String
implMethodNm (ImplMethod n _ _) = n

export
interfaceList : List Decl -> List (String, List String)
interfaceList [] = []
interfaceList ((DInterface { name = n, methods, ... }) :: rest) =
  (n, map ifaceMethodNm methods) :: interfaceList rest
interfaceList (_ :: rest) = interfaceList rest

-- prelude value names (DFunDef/DTypeSig + DImpl & DInterface method names)
export
preludeValueNames : List Decl -> List String
preludeValueNames [] = []
preludeValueNames ((DFunDef _ n _ _ _ _) :: rest) = n :: preludeValueNames rest
preludeValueNames ((DTypeSig _ n _ _) :: rest) = n :: preludeValueNames rest
preludeValueNames ((DImpl { methods, ... }) :: rest) =
  map implMethodNm methods ++ preludeValueNames rest
preludeValueNames ((DInterface { methods, ... }) :: rest) =
  map ifaceMethodNm methods ++ preludeValueNames rest
preludeValueNames ((DAttrib _ d) :: rest) = preludeValueNames (d :: rest)
preludeValueNames (_ :: rest) = preludeValueNames rest

export
fieldOwnersOf : List Decl -> List (String, String)
fieldOwnersOf [] = []
fieldOwnersOf ((DData { dataCtors = vs }) :: rest) =
  flatMap variantFieldOwners vs ++ fieldOwnersOf rest
fieldOwnersOf (_ :: rest) = fieldOwnersOf rest

recordFieldOwner : String -> Field -> (String, String)
recordFieldOwner owner (Field fname _) = (fname, owner)

variantFieldOwners : Variant -> List (String, String)
variantFieldOwners (Variant cname (ConNamed fs _)) =
  map (recordFieldOwner cname) fs
variantFieldOwners (Variant _ (ConPos _)) = []

export
useModId : UsePath -> String
useModId (UseName ns) =
  if listLen ns > 1 then joinDot (initList ns) else optionOr "" (head ns)
useModId (UseGroup ns _) = joinDot ns
useModId (UseWild ns) = joinDot ns
useModId (UseAlias ns _) = joinDot ns

-- The module ids [prog] imports, `DAttrib`-wrapped imports included.
export
useModuleIds : List Decl -> List String
useModuleIds prog = flatMap declUseIds prog

export
declUseIds : Decl -> List String
declUseIds (DUse _ path _) = [useModId path]
declUseIds (DAttrib _ d) = declUseIds d
declUseIds _ = []

-- The public interface of a resolved module
-- (exp_fields is dropped — consumers only read field OWNERS).
public export data ModuleExports = ModuleExports {
  modId : String,
  expValues : List String,
  expTypes : List String,
  -- the `expTypes` members that are `export data` without `public`.  A type
  -- with no entry in `expTypeCtors` is not the same set: a `type` alias has no
  -- constructor family at all, so "exported abstractly" is not a thing that can
  -- be said about it, and no `public export` would give it constructors.
  expAbstractData : List String,
  expCtors : List String,
  expTypeCtors : List (String, List String),
  expFieldOwners : List (String, String),
  expInterfaces : List String,
  expIfaceMethods : List (String, List String),
  -- (interface name, DECLARING module) for every exported interface.  A name
  -- with two distinct declaring modules is two interfaces merged by a
  -- re-export; the importer's ambiguity check reads that here.
  expIfaceOrigins : List (String, String),
  -- (type name, DECLARING module) for every exported type, and the same for
  -- every exported constructor: the identities the importer's type and
  -- constructor ambiguity checks key on, as the interface check keys on
  -- `expIfaceOrigins`.  A re-export cannot rename a type or a constructor, so
  -- the exported name is the declared name.
  expTypeOrigins : List (String, String),
  expCtorOrigins : List (String, String),
  -- (value name, (DECLARING module, the name it is declared under there)) for
  -- every exported value, interface methods included.  The pair is the
  -- declaration's identity: an importer that reaches one declaration through
  -- two paths sees one value, not two.  The declared name is part of it
  -- because a member alias (`export import m.{a as b}`) re-exports `a` as `b`.
  expValueOrigins : List (String, (String, String)),
  expEffects : List String,  -- exported effect labels (Phase 146)
  -- (label, DECLARING module) for every exported label, the identity an
  -- importer's rows are stamped with and the provenance its ambiguity check
  -- keys on.  Carried whole across a wildcard re-export, as `expEffects` is.
  expEffectOrigins : List (String, String),
  -- (ctorName, typeName) pairs for `export newtype` decls (#1311) — a
  -- newtype's ctor is unconditionally module-private (typecheck's
  -- `publicDataDecls` never publishes it), so unlike `expCtors`/
  -- `expTypeCtors` this table exists ONLY to let the import path refuse it
  -- with a located, explanatory diagnostic instead of silently admitting it
  -- and leaving typecheck to fail with a bare `Unbound variable`.
  expNewtypeCtors : List (String, String),
  -- (ctorName, typeName) for the constructors of `export data` without
  -- `public`.  Like `expNewtypeCtors` it exists only so the import path can
  -- refuse a bare `import m.{Ctor}` with a diagnostic that says the ctor is
  -- withheld; it crosses no `export import` hop.
  expAbstractCtors : List (String, String),
  -- Derived indexes, not export namespaces: `nameSet` is every name the five
  -- membership lists above hold (what `isPubExp` asks), `ctorTypes` maps each
  -- exported constructor to its type (first type wins, as `expTypeCtors` is
  -- scanned).  Only `indexExports` fills them, and both constructors go through it.
  nameSet : OrdMap Unit,
  ctorTypes : OrdMap String,
}
-- public type → its exported ctors
-- (field, owner type/ctor)

-- iface → method names

-- ── small generic helpers ──────────────────────────────────────────────────
-- keep the elements of `names` that are members of `domain`, an OrdMap-backed
-- set: an export list grows with re-export depth, so a list scan per element
-- would be quadratic per module on an `export import m.*` chain.
export
filterInSet : OrdMap Unit -> List String -> List String
filterInSet _ [] = []
filterInSet domain (n :: rest)
  | omHasKey n domain = n :: filterInSet domain rest
  | otherwise = filterInSet domain rest

-- #926: `known` is now a Map keyed by module id (was a `List ModuleExports`
-- scanned linearly, O(N) per import → O(N^2) on a star import that resolves N
-- imports against an N-long list).  `omLookup` is O(log N).  Byte-identical: module
-- ids are unique across a module list, so the single keyed entry is exactly what the
-- old first-match scan returned; and even under a (spurious) duplicate id the driver's
-- `omInsert exp.modId exp known` is last-write-wins, matching the old `exp :: known`
-- prepend + front-to-back scan (both return the most-recently-added module).
export
findExports : String -> OrdMap ModuleExports -> Option ModuleExports
findExports mid known = omLookup mid known

-- exported under any value/type/ctor/interface/effect category (lib's
-- imported_names is_pub); `nameSet` is that union.
export
isPubExp : ModuleExports -> String -> Bool
isPubExp exp n = omHasKey n exp.nameSet

-- Fill the derived indexes from the export lists.  Every ModuleExports is built
-- through here (`coreExports`, `buildExportsWith`), so a consumer never sees an
-- empty index.  `expEffects` belongs in `nameSet` because `importedEffects`
-- installs every label `m` exports on ANY import of `m`: drop it and a
-- selective member list naming a label refuses a name the very same import
-- statement puts in scope, with a message that denies the export (#3293).
-- `ctorTypes` is built from the reversed pairs so the FIRST (type, ctor) pair
-- wins a duplicate constructor name, as a front-to-back scan of `expTypeCtors`
-- would.
indexExports : ModuleExports -> ModuleExports
indexExports exp = { exp |
  nameSet =
    omFromNames
      (exp.expValues
        ++ exp.expTypes
        ++ exp.expCtors
        ++ exp.expInterfaces
        ++ exp.expEffects)
      omEmpty,
  ctorTypes =
    omFromPairs
      (reverseL
        (flatMap ((ty, ctors) => map (c => (c, ty)) ctors) exp.expTypeCtors))
      omEmpty,
}

export
typeCtorsOf : String -> ModuleExports -> Option (List String)
typeCtorsOf name exp = lookupAssoc name exp.expTypeCtors

-- Reverse of typeCtorsOf: the type a constructor belongs to, if `name` is a
-- plain (non-newtype) constructor this module exports. Used to refuse a bare
-- `import m.{Ctor}` member (#3314) — the message needs the owning type's name
-- for the `T(..)` remedy it offers.
export
typeOfCtor : String -> ModuleExports -> Option String
typeOfCtor name exp = omLookup name exp.ctorTypes

-- newtype's type name, if `name` is that newtype's exported ctor (#1311).
export
newtypeTypeOfCtor : String -> ModuleExports -> Option String
newtypeTypeOfCtor name exp = lookupAssoc name exp.expNewtypeCtors

-- is `name` a `newtype` this module exports (checked by TYPE name, for `T(..)`)?
export
isNewtypeExport : String -> ModuleExports -> Bool
isNewtypeExport name exp = contains name (map snd exp.expNewtypeCtors)

-- Does a plain selective member's spelling name an export of this module in a
-- namespace OTHER than the constructor one — the type itself, an interface, or
-- an effect label?  A constructor spelling is not privileged over those, so
-- both ctor refusals below must stand down when one of them applies:
-- `import m.{Eq}` against a module exporting `interface Eq` and, in an
-- unrelated type, a ctor spelled `Eq` asks for the interface.  `expValues` is
-- absent by grammar, not by omission — a top-level binding cannot be
-- capitalized, so no value name can collide with a constructor spelling.
export
bindsNonCtorExport : ModuleExports -> String -> Bool
bindsNonCtorExport exp name =
  contains name exp.expTypes
    || contains name exp.expInterfaces
    || contains name exp.expEffects

export
pubUsePaths : List Decl -> List UsePath
pubUsePaths [] = []
pubUsePaths ((DUse True path _) :: rest) = path :: pubUsePaths rest
pubUsePaths (_ :: rest) = pubUsePaths rest

-- The paths of a module's plain imports, the complement of `pubUsePaths`: what
-- its full view carries beyond its exported one.
export
plainUsePaths : List Decl -> List UsePath
plainUsePaths [] = []
plainUsePaths ((DUse False path _) :: rest) = path :: plainUsePaths rest
plainUsePaths (_ :: rest) = plainUsePaths rest

-- expand_member: `T(..)` → the type plus its exported ctors; a plain member is
-- itself.  `T(..)` on an abstractly-exported type is a NoExportedConstructors.
-- Each expanded name carries the source member's own Loc (ctors expanded from
-- `T(..)` inherit T's member loc).
--
-- Each entry is (ORIGIN, LOCAL, loc).  They differ only under a member alias
-- (`import m.{a as b}` → origin `a`, local `b`): the privacy check must ask about the
-- ORIGIN (that is the name m exports), while scope binds the LOCAL.  Conflating the
-- two would make `import m.{privateThing as x}` silently legal.  Ctors expanded from
-- `T(..) as U` keep their OWN names — one alias cannot rename N constructors.
-- #1311: a `newtype`'s ctor is unconditionally module-private (typecheck's
-- `publicDataDecls` never publishes it, and `public newtype` is a parse
-- error — there is no spelling that exports it).  `expNewtypeCtors` still
-- lets resolve's OTHER tables (`expCtors`/`expTypeCtors`) see it, so both
-- arms below refuse it explicitly rather than let it fall through to the
-- generic paths, which would silently admit it exactly as #1311 found.
-- A plain member that names an exported TYPE binds that type, even when the
-- same spelling is also a `newtype`'s constructor (`newtype Bytes = Bytes
-- ByteBlock`): `import bytes.{Bytes}` asks for the type, exactly as `T(..)`
-- on a newtype keeps `T` bound below, and only a name that is a constructor
-- and NOTHING else this module exports is a ctor request to refuse (#3205,
-- #3314) — `bindsNonCtorExport` is that test.  The ctor half of a self-named
-- type is kept out of scope by `realImport`'s `iaCtors`.
export
expandMemberNames : ModuleExports -> UseMember -> List (String, String, Loc)
expandMemberNames exp (m@(UseMember name False loc _))
  | bindsNonCtorExport exp name = [(name, useMemberLocal m, loc)]
  | otherwise = match newtypeTypeOfCtor name exp
    -- the empty arms are the refusals; see expandMemberErrs
    Some _ => []
    None => match typeOfCtor name exp
      Some _ => []
      None => match lookupAssoc name exp.expAbstractCtors
        Some _ => []
        None => [(name, useMemberLocal m, loc)]
expandMemberNames exp (m@(UseMember name True loc _))
  | isNewtypeExport name exp =
    -- keep the TYPE name bound (mirrors abstract `data`: `NT` itself is
    -- still importable, only its ctor is refused) but do NOT expand to the ctor.
    [(name, useMemberLocal m, loc)]
  | contains name exp.expEffects =
    -- `Label(..)` on an effect label: a label has no members to bring, unlike
    -- a type — the empty arm is the refusal; see expandMemberErrs.
    []
  | otherwise = match typeCtorsOf name exp
    Some ctors => (name, useMemberLocal m, loc) :: map (c => (c, c, loc)) ctors
    None => [(name, useMemberLocal m, loc)]

-- ── core's export surface ──────────────────────────────────────────────────
-- The prelude, viewed as a ModuleExports, so a `core` use-path can be resolved
-- and VALIDATED exactly like any other module's (see overPubUse / coreUseErrors).
--
-- core is never in the driver's `known` list — it is prepended to every module,
-- not imported — so every `mid == "core"` site had to answer "what does core
-- export?" and none could.  They all answered "nothing", which is why an
-- `export import core.{…}` exported nothing AND said nothing.
--
-- Built from the SAME extractors `buildEnvMM` uses to seed prelude names into
-- scope (preludeValueNames / dataRecordNames / ctorNames / interfaceList / …), so
-- "what core exports" is by construction "what core puts in scope".  The prelude
-- ignores visibility markers — every core name is in scope in every module — so
-- its export surface is all of it.
export
coreExports : List Decl -> ModuleExports
coreExports preludeDecls = indexExports
  ModuleExports {
    modId = "core",
    expValues = preludeValueNames preludeDecls,
    expTypes = dataRecordNames preludeDecls,
    -- the prelude ignores visibility markers, so none of its types withholds
    -- constructors
    expAbstractData = [],
    expCtors = ctorNames preludeDecls,
    expTypeCtors = typeCtorsAllOf preludeDecls,
    expFieldOwners = fieldOwnersOf preludeDecls,
    expInterfaces = map fst (interfaceList preludeDecls),
    expIfaceMethods = interfaceList preludeDecls,
    expIfaceOrigins = map (i => (fst i, "core")) (interfaceList preludeDecls),
    expTypeOrigins = map (n => (n, "core")) (dataRecordNames preludeDecls),
    expCtorOrigins = map (n => (n, "core")) (ctorNames preludeDecls),
    expValueOrigins =
      map (n => (n, ("core", n))) (preludeValueNames preludeDecls),
    expEffects = effectNames preludeDecls,
    expEffectOrigins = map (n => (n, "core")) (effectNames preludeDecls),
    expAbstractCtors = [],
    expNewtypeCtors = [],  -- the prelude declares no `newtype` today; nothing to refuse
    nameSet = omEmpty,
    ctorTypes = omEmpty,
  }

-- type → its ctors, ignoring visibility (`nsTypeCtors`' vis-filtered direct rule
-- is for a real module's public surface; the prelude has no private names).  Feeds
-- `T(..)` expansion for `import core.{Option(..)}`.
typeCtorsAllOf : List Decl -> List (String, List String)
typeCtorsAllOf [] = []
typeCtorsAllOf ((DNewtype { newtypeName = n, newtypeCtor = con }) :: rest) =
  (n, [con]) :: typeCtorsAllOf rest
typeCtorsAllOf ((DData { dataName = n, dataCtors = vs }) :: rest) =
  (n, map variantName vs) :: typeCtorsAllOf rest
typeCtorsAllOf ((DAttrib _ d) :: rest) = typeCtorsAllOf (d :: rest)
typeCtorsAllOf (_ :: rest) = typeCtorsAllOf rest

-- ── the export-namespace table ─────────────────────────────────────────────
-- One descriptor per `ModuleExports` export-namespace field, stating in ONE
-- place the four rules that namespace has: how to PROJECT it out of a
-- `ModuleExports`, how to build it DIRECTLY from one of this module's own
-- decls (`nsDirectOf` for the exported view, `nsFullOf` for the full view a
-- test sibling gets), and what an `export import` hop CARRIES from a source
-- module.  A tenth namespace is a tenth descriptor, not a tenth member of
-- four separate per-namespace function families.
--
-- The descriptors cannot share one `List`: `ModuleExports`' fields carry
-- three different element types (`List String`, `List (String, List String)`,
-- `List (String, String)`), so each descriptor is parameterized by its own
-- element type and the table is one contiguous BLOCK rather than one list.
--
-- `ExpNs`, not `Ns`: `frontend/ast.mdk` publishes an unrelated `Ns` (the
-- `Ident` namespace tag).
public export data ExpNs a = ExpNs {
  nsGet : ModuleExports -> List a,
  nsDirectOf : Decl -> List a,
  nsFullOf : Decl -> List a,
  nsCarry : UsePath -> ModuleExports -> List a,
}

-- pub DTypeSig/DExtern/DFunDef, and the binders of a pub `let rec` group.  The
-- carriage rule is the only one that adds a SECOND source beside the re-exported
-- bindings themselves: a re-exported interface carries its value-bound methods
-- too (`carriedIfaceVals`).
export
nsValues : ExpNs String
nsValues = ExpNs {
  nsGet = exp => exp.expValues,
  nsDirectOf =
    d => match d
      DTypeSig True n _ _ => [n]
      DExtern (ExternDecl { edPub = True, edName = n, ... }) => [n]
      DFunDef True n _ _ _ _ => [n]
      DLetGroup True binds => map letBindName binds
      _ => [],
  nsFullOf =
    d => match d
      DTypeSig _ n _ _ => [n]
      DExtern (ExternDecl { edName = n, ... }) => [n]
      DFunDef _ n _ _ _ _ => [n]
      DLetGroup _ binds => map letBindName binds
      _ => [],
  nsCarry = path src => carriedValuesFrom src (reexportBindings path src),
}

-- pub newtype + VisPublic/VisAbstract data & record (the type name only)
export
nsTypes : ExpNs String
nsTypes = ExpNs {
  nsGet = exp => exp.expTypes,
  nsDirectOf =
    d => match d
      DNewtype { newtypePub = True, newtypeName = n } => [n]
      DData { dataVis = VisPublic, dataName = n } => [n]
      DData { dataVis = VisAbstract, dataName = n } => [n]
      DTypeAlias { tyAliasPub = True, tyAliasName = n } => [n]
      _ => [],
  nsFullOf =
    d => match d
      DNewtype { newtypeName = n } => [n]
      DData { dataName = n } => [n]
      DTypeAlias { tyAliasName = n } => [n]
      _ => [],
  nsCarry =
    path src => localsExportedFrom src.expTypes (reexportBindings path src),
}

-- VisAbstract data & record (the type name only) — the subset of `nsTypes`
-- whose constructors exist but are withheld.  Carriage mirrors `nsTypes`:
-- abstractness travels with the type name through an `export import` facade,
-- so a facade's consumer gets the same answer the defining module would give.
-- The full view withholds no constructor, so it has no abstract type.
export
nsAbstractData : ExpNs String
nsAbstractData = ExpNs {
  nsGet = exp => exp.expAbstractData,
  nsDirectOf =
    d => match d
      DData { dataVis = VisAbstract, dataName = n } => [n]
      _ => [],
  nsFullOf = _ => [],
  nsCarry =
    path src =>
      localsExportedFrom src.expAbstractData (reexportBindings path src),
}

-- pub newtype ctor + VisPublic data ctors (VisAbstract exports NO ctors)
export
nsCtors : ExpNs String
nsCtors = ExpNs {
  nsGet = exp => exp.expCtors,
  nsDirectOf =
    d => match d
      DNewtype { newtypePub = True, newtypeCtor = con } => [con]
      DData { dataVis = VisPublic, dataCtors = vs } => map variantName vs
      _ => [],
  nsFullOf =
    d => match d
      DNewtype { newtypeCtor = con } => [con]
      DData { dataCtors = vs } => map variantName vs
      _ => [],
  nsCarry =
    path src => localsExportedFrom src.expCtors (reexportBindings path src),
}

-- `expTypeCtors` is what `T(..)` expands through (`typeCtorsOf`), so a hop
-- whose carriage rule omitted this namespace would hand its consumer a type it
-- exports and no ctors to go with it — the consumer's `import facade.{T(..)}`
-- is then refused as abstract even though the facade wrote `export import
-- i.{T(..)}` (#2309).
export
nsTypeCtors : ExpNs (String, List String)
nsTypeCtors = ExpNs {
  nsGet = exp => exp.expTypeCtors,
  nsDirectOf =
    d => match d
      DNewtype { newtypePub = True, newtypeName = n, newtypeCtor = con } =>
        [(n, [con])]
      DData { dataVis = VisPublic, dataName = n, dataCtors = vs } =>
        [(n, map variantName vs)]
      _ => [],
  nsFullOf =
    d => match d
      DNewtype { newtypeName = n, newtypeCtor = con } => [(n, [con])]
      DData { dataName = n, dataCtors = vs } => [(n, map variantName vs)]
      _ => [],
  nsCarry = path src => carriedTypeCtorsFrom src (reexportOrigins path src),
}

-- field owners for PUBLIC data (named-field variants) + record.
--
-- `expFieldOwners` keys each field by its owning CONSTRUCTOR
-- (`variantFieldOwners`), which equals the type name only for a self-named
-- record — so a named-field VARIANT (`data RA = Dup { dx : Int } | ACount
-- Int`) owns its fields under `Dup`.  Testing the re-exported names against
-- `expTypes` alone therefore dropped every such field at the hop, and the
-- consumer saw `Unknown field: dx` on a field that is declared (#1373).
-- `expTypes ++ expCtors` is the same domain the consumer side already accepts
-- in `ownedFieldOwners`.
export
nsFieldOwners : ExpNs (String, String)
nsFieldOwners = ExpNs {
  nsGet = exp => exp.expFieldOwners,
  nsDirectOf =
    d => match d
      DData { dataVis = VisPublic, dataCtors = vs } =>
        flatMap variantFieldOwners vs
      _ => [],
  nsFullOf =
    d => match d
      DData { dataCtors = vs } => flatMap variantFieldOwners vs
      _ => [],
  nsCarry =
    path src =>
      ownersForTypes
        (omFromNames
          (filterInSet
            (omFromNames (src.expTypes ++ src.expCtors) omEmpty)
            (reexportOrigins path src))
          omEmpty)
        src.expFieldOwners,
}

export
nsInterfaces : ExpNs String
nsInterfaces = ExpNs {
  nsGet = exp => exp.expInterfaces,
  nsDirectOf =
    d => match d
      DInterface { pub = True, name = n, ... } => [n]
      _ => [],
  nsFullOf =
    d => match d
      DInterface { name = n, ... } => [n]
      _ => [],
  nsCarry =
    path src =>
      filterInSet
        (omFromNames src.expInterfaces omEmpty)
        (reexportOrigins path src),
}

export
nsIfaceMethods : ExpNs (String, List String)
nsIfaceMethods = ExpNs {
  nsGet = exp => exp.expIfaceMethods,
  nsDirectOf =
    d => match d
      DInterface { pub = True, name = n, methods, ... } =>
        [(n, map ifaceMethodNm methods)]
      _ => [],
  nsFullOf =
    d => match d
      DInterface { name = n, methods, ... } => [(n, map ifaceMethodNm methods)]
      _ => [],
  nsCarry =
    path src =>
      ifaceMethodPairs
        src
        (filterInSet
          (omFromNames src.expInterfaces omEmpty)
          (reexportOrigins path src)),
}

-- The identity-carrying twin of `nsInterfaces`: each carried interface name
-- keeps its declaring module.  No direct rule (`buildExports` has the id).
export
nsIfaceOrigins : ExpNs (String, String)
nsIfaceOrigins = ExpNs {
  nsGet = exp => exp.expIfaceOrigins,
  nsDirectOf = _ => [],
  nsFullOf = _ => [],
  nsCarry = path src => carriedOriginsFrom path src src.expIfaceOrigins,
}

-- The identity-carrying twins of `nsTypes` and `nsCtors`, with the same shape
-- as `nsIfaceOrigins`.
export
nsTypeOrigins : ExpNs (String, String)
nsTypeOrigins = ExpNs {
  nsGet = exp => exp.expTypeOrigins,
  nsDirectOf = _ => [],
  nsFullOf = _ => [],
  nsCarry = path src => carriedOriginsFrom path src src.expTypeOrigins,
}

export
nsCtorOrigins : ExpNs (String, String)
nsCtorOrigins = ExpNs {
  nsGet = exp => exp.expCtorOrigins,
  nsDirectOf = _ => [],
  nsFullOf = _ => [],
  nsCarry = path src => carriedOriginsFrom path src src.expCtorOrigins,
}

-- The (name, declaring module) rows of `origins` whose name this hop
-- re-exports.
carriedOriginsFrom : UsePath ->
  ModuleExports ->
  List (String, String) ->
  List (String, String)
carriedOriginsFrom path src origins =
  let carried = omFromNames (reexportOrigins path src) omEmpty
  filterList (o => omHasKey (fst o) carried) origins

-- The identity-carrying twin of `nsValues`: each carried value keeps the
-- declaration it names in the source module, under the local name this hop
-- re-exports it as.  Same carriage as `carriedValuesFrom`, pair for name.
nsValueOrigins : ExpNs (String, (String, String))
nsValueOrigins = ExpNs {
  nsGet = exp => exp.expValueOrigins,
  nsDirectOf = _ => [],
  nsFullOf = _ => [],
  nsCarry = path src => carriedValueOriginsFrom src (reexportBindings path src),
}

carriedValueOriginsFrom : ModuleExports ->
  List (String, String) ->
  List (String, (String, String))
carriedValueOriginsFrom src bindings =
  let decls = valueDeclsOf src
  let values = omFromNames src.expValues omEmpty
  map
      ((o, l) => (l, valueDeclOf src decls o))
      (filterList (b => omHasKey (fst b) values) bindings)
    ++ map
      (m => (m, valueDeclOf src decls m))
      (carriedIfaceVals src (map fst bindings))

-- A module's exported values keyed by name, first entry winning: its own
-- declarations precede everything its re-exports carry.
export
valueDeclsOf : ModuleExports -> OrdMap (String, String)
valueDeclsOf exp = omFromPairs (reverseL exp.expValueOrigins) omEmpty

-- The declaration an exported value name denotes.  A name with no recorded
-- origin is taken to be declared by the module that exports it.
export
valueDeclOf : ModuleExports ->
  OrdMap (String, String) ->
  String ->
  (String, String)
valueDeclOf exp decls n = match omLookup n decls
  Some d => d
  None => (exp.modId, n)

-- exported effect labels (Phase 146).  A hop carries a label by the same
-- binding rule as every other namespace: a wildcard carries every exported
-- label, a member list or a single name carries the labels it names, and an
-- alias carries nothing.
export
nsEffects : ExpNs String
nsEffects = ExpNs {
  nsGet = exp => exp.expEffects,
  nsDirectOf =
    d => match d
      DEffect True n _ _ _ _ => [n]
      _ => [],
  nsFullOf =
    d => match d
      DEffect _ n _ _ _ _ => [n]
      _ => [],
  nsCarry =
    path src => match path
      UseWild _ => src.expEffects
      _ => localsExportedFrom src.expEffects (reexportBindings path src),
}

-- The identity-carrying twin of `nsEffects`: no direct rule (the declaring
-- module is supplied by `buildExports`, which has the id), and the same
-- carriage, each carried label keeping its declaring module.
nsEffectOrigins : ExpNs (String, String)
nsEffectOrigins = ExpNs {
  nsGet = exp => exp.expEffectOrigins,
  nsDirectOf = _ => [],
  nsFullOf = _ => [],
  nsCarry =
    path src => match path
      UseWild _ => src.expEffectOrigins
      _ => carriedEffectOrigins src.expEffectOrigins (reexportBindings path src),
}

-- The (local, declaring module) pair of each re-exported label a hop's
-- (origin, local) bindings name.
carriedEffectOrigins : List (String, String) ->
  List (String, String) ->
  List (String, String)
carriedEffectOrigins _ [] = []
carriedEffectOrigins origins ((o, l) :: rest) = match lookupAssoc o origins
  Some m => (l, m) :: carriedEffectOrigins origins rest
  None => carriedEffectOrigins origins rest

-- pub `newtype` (ctorName, typeName) pairs — the deliberately module-private
-- constructors NoExportedConstructors' import path must refuse rather than
-- silently accept (#1311).  Gated on `newtypePub` exactly like `nsCtors` /
-- `nsTypeCtors` (an unexported newtype's ctor is simply not visible to import
-- at all, same as today).
--
-- `noCarry` is the table's statement that this namespace does not cross an
-- `export import` hop: a newtype's ctor is unconditionally module-private, so
-- there is nothing for a hop to re-export.  `buildExports` therefore builds
-- this row from `directIn` alone.  The full view refuses no constructor.
export
nsNewtypeCtors : ExpNs (String, String)
nsNewtypeCtors = ExpNs {
  nsGet = exp => exp.expNewtypeCtors,
  nsDirectOf =
    d => match d
      DNewtype { newtypePub = True, newtypeName = n, newtypeCtor = con } =>
        [(con, n)]
      _ => [],
  nsFullOf = _ => [],
  nsCarry = noCarry,
}

-- (ctorName, typeName) of every `export data` (no `public`) constructor; see
-- `expAbstractCtors`.  No carriage, as for `nsNewtypeCtors`.
nsAbstractCtors : ExpNs (String, String)
nsAbstractCtors = ExpNs {
  nsGet = exp => exp.expAbstractCtors,
  nsDirectOf =
    d => match d
      DData { dataVis = VisAbstract, dataName = n, dataCtors = vs } =>
        map (v => (variantName v, n)) vs
      _ => [],
  nsFullOf = _ => [],
  nsCarry = noCarry,
}

noCarry : UsePath -> ModuleExports -> List a
noCarry _ _ = []

-- ── the table's three generic readers ──────────────────────────────────────
export
exportsIn : ExpNs a -> ModuleExports -> List a
exportsIn ns exp = ns.nsGet exp

-- One namespace's contribution from this module's OWN decls.  `scanDecls`
-- owns the `DAttrib` unwrap, so no `nsDirectOf` needs an arm for it: an
-- `@attr`-wrapped decl still declares whatever it declares.
export
directIn : ExpNs a -> List Decl -> List a
directIn ns prog = scanDecls ns.nsDirectOf prog

-- Does this ONE decl declare something in namespace `ns`?  The decl is read
-- raw: `DAttrib` is not unwrapped, so an `@attr`-wrapped decl answers False.
-- Use `directIn` on a decl list when the wrapper must be looked through.
export
declExportsIn : ExpNs a -> Decl -> Bool
declExportsIn ns d = isNonEmptyL (ns.nsDirectOf d)

-- Does this decl export constructors that `T(..)` binds?  A `newtype`'s
-- constructor is always module-private, so `DNewtype` is False.  Raw decl,
-- as for `declExportsIn`.
export
declExportsCtors : Decl -> Bool
declExportsCtors d =
  declExportsIn nsTypeCtors d && not (declExportsIn nsNewtypeCtors d)

-- The exported value names of a module's own decls: direct values plus the
-- methods of every exported interface, in decl order, `DAttrib` looked through.
-- Resolve's `keepBoundMethods` filters the methods by `env.values`, but every method
-- of a module's own interface is bound there (shadowed ones included), so the filter
-- never drops a name this list admits.
export
exportedValueNames : List Decl -> List String
exportedValueNames prog = valueNamesUnder ExportedView prog

-- `exportedValueNames` under either view: the full view lists every top-level
-- value and every method of every interface the module declares.
export
valueNamesUnder : ExportView -> List Decl -> List String
valueNamesUnder view prog =
  scanDecls
    (d => ruleOf view nsValues d ++ flatMap snd (ruleOf view nsIfaceMethods d))
    prog

scanDecls : (Decl -> List a) -> List Decl -> List a
scanDecls _ [] = []
scanDecls f ((DAttrib _ d) :: rest) = scanDecls f (d :: rest)
scanDecls f (d :: rest) = f d ++ scanDecls f rest

-- ── the two views ──────────────────────────────────────────────────────────
-- What an importer sees of a module: the module's exports, or, for the
-- module's test sibling only, its whole top-level scope, the names it imports
-- included (`docs/design/TEST-SIBLING-ACCESS-DESIGN.md` §3.1).  The importer is
-- classified by the loader; this module never sees a path.
public export data ExportView = ExportedView | FullView

-- The view an importer whose test subject is [subject] gets of module [mid].
export
viewOf : Option String -> String -> ExportView
viewOf subject mid = if subject == Some mid then FullView else ExportedView

-- One namespace's own-decl rule under [view], for one decl and for a decl list.
ruleOf : ExportView -> ExpNs a -> Decl -> List a
ruleOf ExportedView ns d = ns.nsDirectOf d
ruleOf FullView ns d = ns.nsFullOf d

export
directUnder : ExportView -> ExpNs a -> List Decl -> List a
directUnder view ns prog = scanDecls (ruleOf view ns) prog

-- The use paths whose names a module carries under [view]: its `export
-- import`s, or every import for the full view.
export
carriedPaths : ExportView -> List Decl -> List UsePath
carriedPaths ExportedView prog = pubUsePaths prog
carriedPaths FullView prog = pubUsePaths prog ++ plainUsePaths prog

-- One namespace's contribution from a module's carried paths.
carriedIn : ExpNs a ->
  ModuleExports ->
  OrdMap ModuleExports ->
  List UsePath ->
  List a
carriedIn ns coreExp known paths =
  flatMap (overPubUse coreExp known ns.nsCarry) paths

-- `buildExports` given the public interface methods bound as values, the one
-- part of a module's exports that reads its resolved `Env`.
export
buildExportsWith : ModuleExports ->
  OrdMap ModuleExports ->
  String ->
  List Decl ->
  List String ->
  ModuleExports
buildExportsWith coreExp known modId prog ifaceVals =
  buildSurface ExportedView coreExp known modId prog ifaceVals

-- Module [modId]'s full view.  Every method of every interface it declares is
-- bound as a value in its own scope, so the full view needs no `Env`.
export
fullExportsOf : ModuleExports ->
  OrdMap ModuleExports ->
  String ->
  List Decl ->
  ModuleExports
fullExportsOf coreExp known modId prog =
  buildSurface
    FullView
    coreExp
    known
    modId
    prog
    (flatMap snd (directUnder FullView nsIfaceMethods prog))

-- [known] with [subject]'s exported view replaced by its full view, for the
-- imports of its test sibling.  [subject] is the subject's id and its decls;
-- `None` leaves [known] as it is.
export
withSubjectView : ModuleExports ->
  OrdMap ModuleExports ->
  Option (String, List Decl) ->
  OrdMap ModuleExports
withSubjectView _ known None = known
withSubjectView coreExp known (Some (mid, prog)) =
  omInsert mid (fullExportsOf coreExp known mid prog) known

buildSurface : ExportView ->
  ModuleExports ->
  OrdMap ModuleExports ->
  String ->
  List Decl ->
  List String ->
  ModuleExports
buildSurface view coreExp known modId prog ifaceVals =
  let paths = carriedPaths view prog
  let values = directUnder view nsValues prog
  let types = directUnder view nsTypes prog
  let ctors = directUnder view nsCtors prog
  let ifaces = directUnder view nsInterfaces prog
  let effects = directUnder view nsEffects prog
  indexExports ModuleExports {
    modId = modId,
    expValues = values ++ ifaceVals ++ carriedIn nsValues coreExp known paths,
    expTypes = types ++ carriedIn nsTypes coreExp known paths,
    expAbstractData =
      directUnder view nsAbstractData prog
        ++ carriedIn nsAbstractData coreExp known paths,
    expCtors = ctors ++ carriedIn nsCtors coreExp known paths,
    expTypeCtors =
      directUnder view nsTypeCtors prog
        ++ carriedIn nsTypeCtors coreExp known paths,
    expFieldOwners =
      directUnder view nsFieldOwners prog
        ++ carriedIn nsFieldOwners coreExp known paths,
    expInterfaces = ifaces ++ carriedIn nsInterfaces coreExp known paths,
    expIfaceMethods =
      directUnder view nsIfaceMethods prog
        ++ carriedIn nsIfaceMethods coreExp known paths,
    expIfaceOrigins =
      map (n => (n, modId)) ifaces
        ++ carriedIn nsIfaceOrigins coreExp known paths,
    expTypeOrigins =
      map (n => (n, modId)) types
        ++ carriedIn nsTypeOrigins coreExp known paths,
    expCtorOrigins =
      map (n => (n, modId)) ctors
        ++ carriedIn nsCtorOrigins coreExp known paths,
    expValueOrigins =
      map (n => (n, (modId, n))) (values ++ ifaceVals)
        ++ carriedIn nsValueOrigins coreExp known paths,
    expEffects = effects ++ carriedIn nsEffects coreExp known paths,
    expEffectOrigins =
      map (n => (n, modId)) effects
        ++ carriedIn nsEffectOrigins coreExp known paths,
    expNewtypeCtors = directUnder view nsNewtypeCtors prog,
    expAbstractCtors = directUnder view nsAbstractCtors prog,
    nameSet = omEmpty,
    ctorTypes = omEmpty,
  }

export
pubIfaceMethodSets : List Decl -> List (List String)
pubIfaceMethodSets [] = []
pubIfaceMethodSets ((DInterface { pub = True, methods, ... }) :: rest) =
  map ifaceMethodNm methods :: pubIfaceMethodSets rest
pubIfaceMethodSets ((DAttrib _ d) :: rest) = pubIfaceMethodSets (d :: rest)
pubIfaceMethodSets (_ :: rest) = pubIfaceMethodSets rest

-- ── pub-import re-export (export import …) — mirror lib's reexport_name ──────
-- The names a pub use-path re-exports from its source module (errors suppressed
-- here — they were already reported when the module imported them).
-- (ORIGIN, LOCAL) per re-exported name.  The origin is what the SOURCE module exports
-- (so it is what the membership guards below must test); the local is
-- the name THIS module re-exports it under.  They differ only for a member alias
-- (`export import m.{a as b}` re-exports m's `a` as `b`).
--
-- A whole-module alias is absent on purpose: `export import m as A` is rejected in the
-- parser.  Re-exporting `A.f` would export a name no importer could write without
-- knowing our private alias.
export
reexportBindings : UsePath -> ModuleExports -> List (String, String)
reexportBindings (UseName ns) _ =
  if listLen ns > 1 then
    let n = optionOr "" (last ns)
    [(n, n)]
  else
    []
reexportBindings (UseGroup _ members) src =
  map dropLocOfExpanded (flatMap (expandMemberNames src) members)
-- Deduplicated: a data type and its same-named constructor (`data D = D`) are
-- one name in two export lists, and every namespace's carriage rule tests each
-- binding against its own list, so a repeated binding is a repeated export.  A
-- wildcard chain would then double that name's copies at every hop.  Values
-- are left out of the dedup because a value name is never capitalized, so it
-- cannot repeat a type, constructor or interface name.
reexportBindings (UseWild _) src =
  map
    selfBinding
    (src.expValues ++ dedup (src.expTypes ++ src.expCtors ++ src.expInterfaces))
reexportBindings (UseAlias _ _) _ = []

dropLocOfExpanded : (String, String, Loc) -> (String, String)
dropLocOfExpanded (origin, local, _) = (origin, local)

-- The names hop [path] carries from its source's full view [full] and not from
-- the source's exported view [exported]: what a test sibling's `export import`
-- of its subject would hand on through its privilege.  A constructor the
-- subject withholds is caught in `nsCtors`, where `T(..)` on an abstract type
-- carries it only from the full view.
export
privilegedCarry : ModuleExports -> ModuleExports -> UsePath -> List String
privilegedCarry exported full path =
  dedup
    (flatMap
      (ns => carriedOnlyBy ns exported full path)
      [nsValues, nsTypes, nsCtors, nsInterfaces, nsEffects])

carriedOnlyBy : ExpNs String ->
  ModuleExports ->
  ModuleExports ->
  UsePath ->
  List String
carriedOnlyBy ns exported full path =
  let viaExports = omFromNames (ns.nsCarry path exported) omEmpty
  filterList (n => not (omHasKey n viaExports)) (ns.nsCarry path full)

-- the LOCAL names whose ORIGIN is one of `origins` (the source module's export list of
-- the relevant kind).  This is the aliased form of `filterInSet`.
localsExportedFrom : List String -> List (String, String) -> List String
localsExportedFrom origins bindings =
  -- #925: `origins` is the source module's export list, which GROWS with re-export
  -- depth; the old per-binding `contains` was O(len) each → O(depth^2) per module,
  -- cubic over an `export import m.*` chain.  Build the membership set once and test
  -- with `omHasKey` (uncounted, O(log len)) — same kept locals, same order.
  let dom = omFromNames origins omEmpty
  map snd (filterList (b => omHasKey (fst b) dom) bindings)

-- `nsValues`' carriage rule, given the hop's own (origin, local) bindings: the
-- re-exported locals the source module exports as values, plus the
-- value-bound methods of every interface the hop carries.
carriedValuesFrom : ModuleExports -> List (String, String) -> List String
carriedValuesFrom src bindings =
  localsExportedFrom src.expValues bindings
    ++ carriedIfaceVals src (map fst bindings)

-- The value-bound methods of every interface among `origins`, in order.  The
-- membership sets are built once per hop, because the source's export lists
-- grow with re-export depth, and the value set only when an interface is
-- carried at all.
carriedIfaceVals : ModuleExports -> List String -> List String
carriedIfaceVals src origins =
  match filterInSet (omFromNames src.expInterfaces omEmpty) origins
    [] => []
    carried =>
      let values = omFromNames src.expValues omEmpty
      flatMap
        (n => filterInSet values (ifaceMethodsOf n src.expIfaceMethods))
        carried

-- `nsTypeCtors`' carriage rule, given the hop's re-exported origins.
--
-- A type whose ctors this hop does NOT carry (a plain `T` member) gets no entry
-- rather than an empty one.  `Some []` would expand `T(..)` to the type alone and
-- raise no NoExportedConstructors, silently binding nothing where the abstract-export
-- refusal is the right answer.
carriedTypeCtorsFrom : ModuleExports ->
  List String ->
  List (String, List String)
carriedTypeCtorsFrom src carried =
  let carriedSet = omFromNames carried omEmpty
  carriedTypeCtors
    (omFromNames
      (filterInSet (omFromNames src.expTypes omEmpty) carried)
      omEmpty)
    carriedSet
    src.expTypeCtors

-- per re-exported type, the ctors this hop carries; a type carrying none is dropped.
carriedTypeCtors : OrdMap Unit ->
  OrdMap Unit ->
  List (String, List String) ->
  List (String, List String)
carriedTypeCtors _ _ [] = []
carriedTypeCtors types carried ((t, cs) :: rest)
  | not (omHasKey t types) = carriedTypeCtors types carried rest
  | otherwise =
    let kept = filterInSet carried cs
    if isEmptyL kept then
      carriedTypeCtors types carried rest
    else
      (t, kept) :: carriedTypeCtors types carried rest

-- Interfaces / types / ctors / field owners key off the ORIGIN name: only a VALUE
-- member can carry an alias (parser-enforced), so for these kinds origin == local and
-- the origin list is exactly the old behaviour.  Keying an interface by an alias would
-- be unsound anyway — impl coherence is resolved on the real interface name globally.
reexportOrigins : UsePath -> ModuleExports -> List String
reexportOrigins path src = map fst (reexportBindings path src)

ifaceMethodPairs : ModuleExports -> List String -> List (String, List String)
ifaceMethodPairs _ [] = []
ifaceMethodPairs src (i :: rest) =
  (i, ifaceMethodsOf i src.expIfaceMethods) :: ifaceMethodPairs src rest

ownersForTypes : OrdMap Unit -> List (String, String) -> List (String, String)
ownersForTypes _ [] = []
ownersForTypes types ((f, o) :: rest)
  | omHasKey o types = (f, o) :: ownersForTypes types rest
  | otherwise = ownersForTypes types rest

-- run `f` against a pub use-path's resolved source exports (skip unknown).
--
-- `core` resolves against `coreExp`, NOT against `known`: core is the IMPLICIT
-- prelude, so it is prepended to every module rather than imported, and it never
-- appears in the driver's `known` list.  This arm must not be `if mid == "core"
-- then []`, which silently drops every name an `export import core.{…}` names —
-- so `stdlib/list.mdk`'s `export import core.{Filterable, filter, filterMap}`
-- re-exports NOTHING and `import list.{filter}` fails with "Module 'list' has no
-- exported name 'filter'", while `medaka check stdlib/list.mdk` stays clean.
overPubUse : ModuleExports ->
  OrdMap ModuleExports ->
  (UsePath -> ModuleExports -> List b) ->
  UsePath ->
  List b
overPubUse coreExp known f path =
  let mid = useModId path
  if mid == "core" then
    f path coreExp
  else match findExports mid known
    None => []
    Some src => f path src
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "variantName" false) (mem "letBindName" false) (mem "Loc" true) (mem "UseMember" true) (mem "UsePath" true) (mem "useMemberLocal" false) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true) (mem "ExternDecl" true))))
(DUse false (UseGroup ("list") ((mem "head" false) (mem "last" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omFromNames" false) (mem "omFromPairs" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "reverseL" false) (mem "initList" false) (mem "joinDot" false) (mem "filterList" false) (mem "dedup" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "selfBinding" false))))
(DTypeSig true "ifaceMethodsOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ifaceMethodsOf" (PWild (PList)) (EListLit))
(DFunDef false "ifaceMethodsOf" ((PVar "iface") (PCons (PTuple (PVar "i") (PVar "ms")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "i") (EVar "iface")) (EVar "ms") (EIf (EVar "otherwise") (EApp (EApp (EVar "ifaceMethodsOf") (EVar "iface")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "dataRecordNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dataRecordNames" ((PList)) (EListLit))
(DFunDef false "dataRecordNames" ((PCons (PRec "DData" ((rf "dataName" (PVar "n"))) false) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "dataRecordNames") (EVar "rest"))))
(DFunDef false "dataRecordNames" ((PCons (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n"))) false) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "dataRecordNames") (EVar "rest"))))
(DFunDef false "dataRecordNames" ((PCons (PRec "DNewtype" ((rf "newtypeName" (PVar "n"))) false) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "dataRecordNames") (EVar "rest"))))
(DFunDef false "dataRecordNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "dataRecordNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "dataRecordNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "dataRecordNames") (EVar "rest")))
(DTypeSig true "effectNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "effectNames" ((PList)) (EListLit))
(DFunDef false "effectNames" ((PCons (PCon "DEffect" PWild (PVar "n") PWild PWild PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "effectNames") (EVar "rest"))))
(DFunDef false "effectNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "effectNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "effectNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "effectNames") (EVar "rest")))
(DTypeSig true "ctorNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ctorNames" ((PList)) (EListLit))
(DFunDef false "ctorNames" ((PCons (PRec "DData" ((rf "dataCtors" (PVar "vs"))) false) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "variantName")) (EVar "vs")) (EApp (EVar "ctorNames") (EVar "rest"))))
(DFunDef false "ctorNames" ((PCons (PRec "DNewtype" ((rf "newtypeCtor" (PVar "con"))) false) (PVar "rest"))) (EBinOp "::" (EVar "con") (EApp (EVar "ctorNames") (EVar "rest"))))
(DFunDef false "ctorNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "ctorNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "ctorNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "ctorNames") (EVar "rest")))
(DTypeSig true "ifaceMethodNm" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ifaceMethodNm" ((PCon "IfaceMethod" (PVar "n") PWild PWild PWild)) (EVar "n"))
(DTypeSig false "implMethodNm" (TyFun (TyCon "ImplMethod") (TyCon "String")))
(DFunDef false "implMethodNm" ((PCon "ImplMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig true "interfaceList" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "interfaceList" ((PList)) (EListLit))
(DFunDef false "interfaceList" ((PCons (PRec "DInterface" ((rf "name" (PVar "n")) (rf "methods" None)) true) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EVar "map") (EVar "ifaceMethodNm")) (EVar "methods"))) (EApp (EVar "interfaceList") (EVar "rest"))))
(DFunDef false "interfaceList" ((PCons PWild (PVar "rest"))) (EApp (EVar "interfaceList") (EVar "rest")))
(DTypeSig true "preludeValueNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "preludeValueNames" ((PList)) (EListLit))
(DFunDef false "preludeValueNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "preludeValueNames") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons (PCon "DTypeSig" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "preludeValueNames") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons (PRec "DImpl" ((rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "implMethodNm")) (EVar "methods")) (EApp (EVar "preludeValueNames") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons (PRec "DInterface" ((rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "ifaceMethodNm")) (EVar "methods")) (EApp (EVar "preludeValueNames") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "preludeValueNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "preludeValueNames") (EVar "rest")))
(DTypeSig true "fieldOwnersOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "fieldOwnersOf" ((PList)) (EListLit))
(DFunDef false "fieldOwnersOf" ((PCons (PRec "DData" ((rf "dataCtors" (PVar "vs"))) false) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "variantFieldOwners")) (EVar "vs")) (EApp (EVar "fieldOwnersOf") (EVar "rest"))))
(DFunDef false "fieldOwnersOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "fieldOwnersOf") (EVar "rest")))
(DTypeSig false "recordFieldOwner" (TyFun (TyCon "String") (TyFun (TyCon "Field") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "recordFieldOwner" ((PVar "owner") (PCon "Field" (PVar "fname") PWild)) (ETuple (EVar "fname") (EVar "owner")))
(DTypeSig false "variantFieldOwners" (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "variantFieldOwners" ((PCon "Variant" (PVar "cname") (PCon "ConNamed" (PVar "fs") PWild))) (EApp (EApp (EVar "map") (EApp (EVar "recordFieldOwner") (EVar "cname"))) (EVar "fs")))
(DFunDef false "variantFieldOwners" ((PCon "Variant" PWild (PCon "ConPos" PWild))) (EListLit))
(DTypeSig true "useModId" (TyFun (TyCon "UsePath") (TyCon "String")))
(DFunDef false "useModId" ((PCon "UseName" (PVar "ns"))) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EApp (EVar "joinDot") (EApp (EVar "initList") (EVar "ns"))) (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EVar "head") (EVar "ns")))))
(DFunDef false "useModId" ((PCon "UseGroup" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "useModId" ((PCon "UseWild" (PVar "ns"))) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "useModId" ((PCon "UseAlias" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DTypeSig true "useModuleIds" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "useModuleIds" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "declUseIds")) (EVar "prog")))
(DTypeSig true "declUseIds" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declUseIds" ((PCon "DUse" PWild (PVar "path") PWild)) (EListLit (EApp (EVar "useModId") (EVar "path"))))
(DFunDef false "declUseIds" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declUseIds") (EVar "d")))
(DFunDef false "declUseIds" (PWild) (EListLit))
(DData Public "ModuleExports" () ((variant "ModuleExports" (ConNamed (field "modId" (TyCon "String")) (field "expValues" (TyApp (TyCon "List") (TyCon "String"))) (field "expTypes" (TyApp (TyCon "List") (TyCon "String"))) (field "expAbstractData" (TyApp (TyCon "List") (TyCon "String"))) (field "expCtors" (TyApp (TyCon "List") (TyCon "String"))) (field "expTypeCtors" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "expFieldOwners" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "expInterfaces" (TyApp (TyCon "List") (TyCon "String"))) (field "expIfaceMethods" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "expIfaceOrigins" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "expTypeOrigins" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "expCtorOrigins" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "expValueOrigins" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))) (field "expEffects" (TyApp (TyCon "List") (TyCon "String"))) (field "expEffectOrigins" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "expNewtypeCtors" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "expAbstractCtors" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "nameSet" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "ctorTypes" (TyApp (TyCon "OrdMap") (TyCon "String")))))) ())
(DTypeSig true "filterInSet" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterInSet" (PWild (PList)) (EListLit))
(DFunDef false "filterInSet" ((PVar "domain") (PCons (PVar "n") (PVar "rest"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "domain")) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "filterInSet") (EVar "domain")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterInSet") (EVar "domain")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "findExports" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyApp (TyCon "Option") (TyCon "ModuleExports")))))
(DFunDef false "findExports" ((PVar "mid") (PVar "known")) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EVar "known")))
(DTypeSig true "isPubExp" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isPubExp" ((PVar "exp") (PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EVar "exp") "nameSet")))
(DTypeSig false "indexExports" (TyFun (TyCon "ModuleExports") (TyCon "ModuleExports")))
(DFunDef false "indexExports" ((PVar "exp")) (ERecordUpdate (EVar "exp") ((fa "nameSet" (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EFieldAccess (EVar "exp") "expValues") (EFieldAccess (EVar "exp") "expTypes")) (EFieldAccess (EVar "exp") "expCtors")) (EFieldAccess (EVar "exp") "expInterfaces")) (EFieldAccess (EVar "exp") "expEffects"))) (EVar "omEmpty"))) (fa "ctorTypes" (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PVar "ty") (PVar "ctors"))) (EApp (EApp (EVar "map") (ELam ((PVar "c")) (ETuple (EVar "c") (EVar "ty")))) (EVar "ctors")))) (EFieldAccess (EVar "exp") "expTypeCtors")))) (EVar "omEmpty"))))))
(DTypeSig true "typeCtorsOf" (TyFun (TyCon "String") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "typeCtorsOf" ((PVar "name") (PVar "exp")) (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EFieldAccess (EVar "exp") "expTypeCtors")))
(DTypeSig true "typeOfCtor" (TyFun (TyCon "String") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "typeOfCtor" ((PVar "name") (PVar "exp")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "exp") "ctorTypes")))
(DTypeSig true "newtypeTypeOfCtor" (TyFun (TyCon "String") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "newtypeTypeOfCtor" ((PVar "name") (PVar "exp")) (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EFieldAccess (EVar "exp") "expNewtypeCtors")))
(DTypeSig true "isNewtypeExport" (TyFun (TyCon "String") (TyFun (TyCon "ModuleExports") (TyCon "Bool"))))
(DFunDef false "isNewtypeExport" ((PVar "name") (PVar "exp")) (EApp (EApp (EVar "contains") (EVar "name")) (EApp (EApp (EVar "map") (EVar "snd")) (EFieldAccess (EVar "exp") "expNewtypeCtors"))))
(DTypeSig true "bindsNonCtorExport" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "bindsNonCtorExport" ((PVar "exp") (PVar "name")) (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "name")) (EFieldAccess (EVar "exp") "expTypes")) (EApp (EApp (EVar "contains") (EVar "name")) (EFieldAccess (EVar "exp") "expInterfaces"))) (EApp (EApp (EVar "contains") (EVar "name")) (EFieldAccess (EVar "exp") "expEffects"))))
(DTypeSig true "pubUsePaths" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "UsePath"))))
(DFunDef false "pubUsePaths" ((PList)) (EListLit))
(DFunDef false "pubUsePaths" ((PCons (PCon "DUse" (PCon "True") (PVar "path") PWild) (PVar "rest"))) (EBinOp "::" (EVar "path") (EApp (EVar "pubUsePaths") (EVar "rest"))))
(DFunDef false "pubUsePaths" ((PCons PWild (PVar "rest"))) (EApp (EVar "pubUsePaths") (EVar "rest")))
(DTypeSig true "plainUsePaths" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "UsePath"))))
(DFunDef false "plainUsePaths" ((PList)) (EListLit))
(DFunDef false "plainUsePaths" ((PCons (PCon "DUse" (PCon "False") (PVar "path") PWild) (PVar "rest"))) (EBinOp "::" (EVar "path") (EApp (EVar "plainUsePaths") (EVar "rest"))))
(DFunDef false "plainUsePaths" ((PCons PWild (PVar "rest"))) (EApp (EVar "plainUsePaths") (EVar "rest")))
(DTypeSig true "expandMemberNames" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Loc"))))))
(DFunDef false "expandMemberNames" ((PVar "exp") (PAs "m" (PCon "UseMember" (PVar "name") (PCon "False") (PVar "loc") PWild))) (EIf (EApp (EApp (EVar "bindsNonCtorExport") (EVar "exp")) (EVar "name")) (EListLit (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m")) (EVar "loc"))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "newtypeTypeOfCtor") (EVar "name")) (EVar "exp")) (arm (PCon "Some" PWild) () (EListLit)) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "typeOfCtor") (EVar "name")) (EVar "exp")) (arm (PCon "Some" PWild) () (EListLit)) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EFieldAccess (EVar "exp") "expAbstractCtors")) (arm (PCon "Some" PWild) () (EListLit)) (arm (PCon "None") () (EListLit (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m")) (EVar "loc"))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "expandMemberNames" ((PVar "exp") (PAs "m" (PCon "UseMember" (PVar "name") (PCon "True") (PVar "loc") PWild))) (EIf (EApp (EApp (EVar "isNewtypeExport") (EVar "name")) (EVar "exp")) (EListLit (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m")) (EVar "loc"))) (EIf (EApp (EApp (EVar "contains") (EVar "name")) (EFieldAccess (EVar "exp") "expEffects")) (EListLit) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "typeCtorsOf") (EVar "name")) (EVar "exp")) (arm (PCon "Some" (PVar "ctors")) () (EBinOp "::" (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m")) (EVar "loc")) (EApp (EApp (EVar "map") (ELam ((PVar "c")) (ETuple (EVar "c") (EVar "c") (EVar "loc")))) (EVar "ctors")))) (arm (PCon "None") () (EListLit (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m")) (EVar "loc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "coreExports" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "ModuleExports")))
(DFunDef false "coreExports" ((PVar "preludeDecls")) (EApp (EVar "indexExports") (ERecordCreate "ModuleExports" ((fa "modId" (ELit (LString "core"))) (fa "expValues" (EApp (EVar "preludeValueNames") (EVar "preludeDecls"))) (fa "expTypes" (EApp (EVar "dataRecordNames") (EVar "preludeDecls"))) (fa "expAbstractData" (EListLit)) (fa "expCtors" (EApp (EVar "ctorNames") (EVar "preludeDecls"))) (fa "expTypeCtors" (EApp (EVar "typeCtorsAllOf") (EVar "preludeDecls"))) (fa "expFieldOwners" (EApp (EVar "fieldOwnersOf") (EVar "preludeDecls"))) (fa "expInterfaces" (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "interfaceList") (EVar "preludeDecls")))) (fa "expIfaceMethods" (EApp (EVar "interfaceList") (EVar "preludeDecls"))) (fa "expIfaceOrigins" (EApp (EApp (EVar "map") (ELam ((PVar "i")) (ETuple (EApp (EVar "fst") (EVar "i")) (ELit (LString "core"))))) (EApp (EVar "interfaceList") (EVar "preludeDecls")))) (fa "expTypeOrigins" (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (ELit (LString "core"))))) (EApp (EVar "dataRecordNames") (EVar "preludeDecls")))) (fa "expCtorOrigins" (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (ELit (LString "core"))))) (EApp (EVar "ctorNames") (EVar "preludeDecls")))) (fa "expValueOrigins" (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (ETuple (ELit (LString "core")) (EVar "n"))))) (EApp (EVar "preludeValueNames") (EVar "preludeDecls")))) (fa "expEffects" (EApp (EVar "effectNames") (EVar "preludeDecls"))) (fa "expEffectOrigins" (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (ELit (LString "core"))))) (EApp (EVar "effectNames") (EVar "preludeDecls")))) (fa "expAbstractCtors" (EListLit)) (fa "expNewtypeCtors" (EListLit)) (fa "nameSet" (EVar "omEmpty")) (fa "ctorTypes" (EVar "omEmpty"))))))
(DTypeSig false "typeCtorsAllOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "typeCtorsAllOf" ((PList)) (EListLit))
(DFunDef false "typeCtorsAllOf" ((PCons (PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeCtor" (PVar "con"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EListLit (EVar "con"))) (EApp (EVar "typeCtorsAllOf") (EVar "rest"))))
(DFunDef false "typeCtorsAllOf" ((PCons (PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataCtors" (PVar "vs"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EVar "map") (EVar "variantName")) (EVar "vs"))) (EApp (EVar "typeCtorsAllOf") (EVar "rest"))))
(DFunDef false "typeCtorsAllOf" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "typeCtorsAllOf") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "typeCtorsAllOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "typeCtorsAllOf") (EVar "rest")))
(DData Public "ExpNs" ("a") ((variant "ExpNs" (ConNamed (field "nsGet" (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyVar "a")))) (field "nsDirectOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyVar "a")))) (field "nsFullOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyVar "a")))) (field "nsCarry" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyVar "a")))))))) ())
(DTypeSig true "nsValues" (TyApp (TyCon "ExpNs") (TyCon "String")))
(DFunDef false "nsValues" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expValues"))) (fa "nsDirectOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PCon "DTypeSig" (PCon "True") (PVar "n") PWild PWild) () (EListLit (EVar "n"))) (arm (PCon "DExtern" (PRec "ExternDecl" ((rf "edPub" (PCon "True")) (rf "edName" (PVar "n"))) true)) () (EListLit (EVar "n"))) (arm (PCon "DFunDef" (PCon "True") (PVar "n") PWild PWild PWild PWild) () (EListLit (EVar "n"))) (arm (PCon "DLetGroup" (PCon "True") (PVar "binds")) () (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds"))) (arm PWild () (EListLit))))) (fa "nsFullOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PCon "DTypeSig" PWild (PVar "n") PWild PWild) () (EListLit (EVar "n"))) (arm (PCon "DExtern" (PRec "ExternDecl" ((rf "edName" (PVar "n"))) true)) () (EListLit (EVar "n"))) (arm (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild) () (EListLit (EVar "n"))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds"))) (arm PWild () (EListLit))))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EApp (EApp (EVar "carriedValuesFrom") (EVar "src")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))))))
(DTypeSig true "nsTypes" (TyApp (TyCon "ExpNs") (TyCon "String")))
(DFunDef false "nsTypes" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expTypes"))) (fa "nsDirectOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DNewtype" ((rf "newtypePub" (PCon "True")) (rf "newtypeName" (PVar "n"))) false) () (EListLit (EVar "n"))) (arm (PRec "DData" ((rf "dataVis" (PCon "VisPublic")) (rf "dataName" (PVar "n"))) false) () (EListLit (EVar "n"))) (arm (PRec "DData" ((rf "dataVis" (PCon "VisAbstract")) (rf "dataName" (PVar "n"))) false) () (EListLit (EVar "n"))) (arm (PRec "DTypeAlias" ((rf "tyAliasPub" (PCon "True")) (rf "tyAliasName" (PVar "n"))) false) () (EListLit (EVar "n"))) (arm PWild () (EListLit))))) (fa "nsFullOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DNewtype" ((rf "newtypeName" (PVar "n"))) false) () (EListLit (EVar "n"))) (arm (PRec "DData" ((rf "dataName" (PVar "n"))) false) () (EListLit (EVar "n"))) (arm (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n"))) false) () (EListLit (EVar "n"))) (arm PWild () (EListLit))))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EApp (EApp (EVar "localsExportedFrom") (EFieldAccess (EVar "src") "expTypes")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))))))
(DTypeSig true "nsAbstractData" (TyApp (TyCon "ExpNs") (TyCon "String")))
(DFunDef false "nsAbstractData" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expAbstractData"))) (fa "nsDirectOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DData" ((rf "dataVis" (PCon "VisAbstract")) (rf "dataName" (PVar "n"))) false) () (EListLit (EVar "n"))) (arm PWild () (EListLit))))) (fa "nsFullOf" (ELam (PWild) (EListLit))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EApp (EApp (EVar "localsExportedFrom") (EFieldAccess (EVar "src") "expAbstractData")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))))))
(DTypeSig true "nsCtors" (TyApp (TyCon "ExpNs") (TyCon "String")))
(DFunDef false "nsCtors" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expCtors"))) (fa "nsDirectOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DNewtype" ((rf "newtypePub" (PCon "True")) (rf "newtypeCtor" (PVar "con"))) false) () (EListLit (EVar "con"))) (arm (PRec "DData" ((rf "dataVis" (PCon "VisPublic")) (rf "dataCtors" (PVar "vs"))) false) () (EApp (EApp (EVar "map") (EVar "variantName")) (EVar "vs"))) (arm PWild () (EListLit))))) (fa "nsFullOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DNewtype" ((rf "newtypeCtor" (PVar "con"))) false) () (EListLit (EVar "con"))) (arm (PRec "DData" ((rf "dataCtors" (PVar "vs"))) false) () (EApp (EApp (EVar "map") (EVar "variantName")) (EVar "vs"))) (arm PWild () (EListLit))))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EApp (EApp (EVar "localsExportedFrom") (EFieldAccess (EVar "src") "expCtors")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))))))
(DTypeSig true "nsTypeCtors" (TyApp (TyCon "ExpNs") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "nsTypeCtors" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expTypeCtors"))) (fa "nsDirectOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DNewtype" ((rf "newtypePub" (PCon "True")) (rf "newtypeName" (PVar "n")) (rf "newtypeCtor" (PVar "con"))) false) () (EListLit (ETuple (EVar "n") (EListLit (EVar "con"))))) (arm (PRec "DData" ((rf "dataVis" (PCon "VisPublic")) (rf "dataName" (PVar "n")) (rf "dataCtors" (PVar "vs"))) false) () (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "map") (EVar "variantName")) (EVar "vs"))))) (arm PWild () (EListLit))))) (fa "nsFullOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeCtor" (PVar "con"))) false) () (EListLit (ETuple (EVar "n") (EListLit (EVar "con"))))) (arm (PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataCtors" (PVar "vs"))) false) () (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "map") (EVar "variantName")) (EVar "vs"))))) (arm PWild () (EListLit))))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EApp (EApp (EVar "carriedTypeCtorsFrom") (EVar "src")) (EApp (EApp (EVar "reexportOrigins") (EVar "path")) (EVar "src"))))))))
(DTypeSig true "nsFieldOwners" (TyApp (TyCon "ExpNs") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "nsFieldOwners" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expFieldOwners"))) (fa "nsDirectOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DData" ((rf "dataVis" (PCon "VisPublic")) (rf "dataCtors" (PVar "vs"))) false) () (EApp (EApp (EVar "flatMap") (EVar "variantFieldOwners")) (EVar "vs"))) (arm PWild () (EListLit))))) (fa "nsFullOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DData" ((rf "dataCtors" (PVar "vs"))) false) () (EApp (EApp (EVar "flatMap") (EVar "variantFieldOwners")) (EVar "vs"))) (arm PWild () (EListLit))))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EApp (EApp (EVar "ownersForTypes") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "filterInSet") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EFieldAccess (EVar "src") "expTypes") (EFieldAccess (EVar "src") "expCtors"))) (EVar "omEmpty"))) (EApp (EApp (EVar "reexportOrigins") (EVar "path")) (EVar "src")))) (EVar "omEmpty"))) (EFieldAccess (EVar "src") "expFieldOwners")))))))
(DTypeSig true "nsInterfaces" (TyApp (TyCon "ExpNs") (TyCon "String")))
(DFunDef false "nsInterfaces" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expInterfaces"))) (fa "nsDirectOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DInterface" ((rf "pub" (PCon "True")) (rf "name" (PVar "n"))) true) () (EListLit (EVar "n"))) (arm PWild () (EListLit))))) (fa "nsFullOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DInterface" ((rf "name" (PVar "n"))) true) () (EListLit (EVar "n"))) (arm PWild () (EListLit))))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EApp (EApp (EVar "filterInSet") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "src") "expInterfaces")) (EVar "omEmpty"))) (EApp (EApp (EVar "reexportOrigins") (EVar "path")) (EVar "src"))))))))
(DTypeSig true "nsIfaceMethods" (TyApp (TyCon "ExpNs") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "nsIfaceMethods" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expIfaceMethods"))) (fa "nsDirectOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DInterface" ((rf "pub" (PCon "True")) (rf "name" (PVar "n")) (rf "methods" None)) true) () (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "map") (EVar "ifaceMethodNm")) (EVar "methods"))))) (arm PWild () (EListLit))))) (fa "nsFullOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DInterface" ((rf "name" (PVar "n")) (rf "methods" None)) true) () (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "map") (EVar "ifaceMethodNm")) (EVar "methods"))))) (arm PWild () (EListLit))))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EApp (EApp (EVar "ifaceMethodPairs") (EVar "src")) (EApp (EApp (EVar "filterInSet") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "src") "expInterfaces")) (EVar "omEmpty"))) (EApp (EApp (EVar "reexportOrigins") (EVar "path")) (EVar "src")))))))))
(DTypeSig true "nsIfaceOrigins" (TyApp (TyCon "ExpNs") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "nsIfaceOrigins" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expIfaceOrigins"))) (fa "nsDirectOf" (ELam (PWild) (EListLit))) (fa "nsFullOf" (ELam (PWild) (EListLit))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EApp (EApp (EApp (EVar "carriedOriginsFrom") (EVar "path")) (EVar "src")) (EFieldAccess (EVar "src") "expIfaceOrigins")))))))
(DTypeSig true "nsTypeOrigins" (TyApp (TyCon "ExpNs") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "nsTypeOrigins" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expTypeOrigins"))) (fa "nsDirectOf" (ELam (PWild) (EListLit))) (fa "nsFullOf" (ELam (PWild) (EListLit))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EApp (EApp (EApp (EVar "carriedOriginsFrom") (EVar "path")) (EVar "src")) (EFieldAccess (EVar "src") "expTypeOrigins")))))))
(DTypeSig true "nsCtorOrigins" (TyApp (TyCon "ExpNs") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "nsCtorOrigins" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expCtorOrigins"))) (fa "nsDirectOf" (ELam (PWild) (EListLit))) (fa "nsFullOf" (ELam (PWild) (EListLit))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EApp (EApp (EApp (EVar "carriedOriginsFrom") (EVar "path")) (EVar "src")) (EFieldAccess (EVar "src") "expCtorOrigins")))))))
(DTypeSig false "carriedOriginsFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "carriedOriginsFrom" ((PVar "path") (PVar "src") (PVar "origins")) (EBlock (DoLet false false (PVar "carried") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "reexportOrigins") (EVar "path")) (EVar "src"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "o")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "o"))) (EVar "carried")))) (EVar "origins")))))
(DTypeSig false "nsValueOrigins" (TyApp (TyCon "ExpNs") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "nsValueOrigins" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expValueOrigins"))) (fa "nsDirectOf" (ELam (PWild) (EListLit))) (fa "nsFullOf" (ELam (PWild) (EListLit))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EApp (EApp (EVar "carriedValueOriginsFrom") (EVar "src")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))))))
(DTypeSig false "carriedValueOriginsFrom" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "carriedValueOriginsFrom" ((PVar "src") (PVar "bindings")) (EBlock (DoLet false false (PVar "decls") (EApp (EVar "valueDeclsOf") (EVar "src"))) (DoLet false false (PVar "values") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "src") "expValues")) (EVar "omEmpty"))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "o") (PVar "l"))) (ETuple (EVar "l") (EApp (EApp (EApp (EVar "valueDeclOf") (EVar "src")) (EVar "decls")) (EVar "o"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "b"))) (EVar "values")))) (EVar "bindings"))) (EApp (EApp (EVar "map") (ELam ((PVar "m")) (ETuple (EVar "m") (EApp (EApp (EApp (EVar "valueDeclOf") (EVar "src")) (EVar "decls")) (EVar "m"))))) (EApp (EApp (EVar "carriedIfaceVals") (EVar "src")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "bindings"))))))))
(DTypeSig true "valueDeclsOf" (TyFun (TyCon "ModuleExports") (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "valueDeclsOf" ((PVar "exp")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EFieldAccess (EVar "exp") "expValueOrigins"))) (EVar "omEmpty")))
(DTypeSig true "valueDeclOf" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "valueDeclOf" ((PVar "exp") (PVar "decls") (PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "decls")) (arm (PCon "Some" (PVar "d")) () (EVar "d")) (arm (PCon "None") () (ETuple (EFieldAccess (EVar "exp") "modId") (EVar "n")))))
(DTypeSig true "nsEffects" (TyApp (TyCon "ExpNs") (TyCon "String")))
(DFunDef false "nsEffects" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expEffects"))) (fa "nsDirectOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PCon "DEffect" (PCon "True") (PVar "n") PWild PWild PWild PWild) () (EListLit (EVar "n"))) (arm PWild () (EListLit))))) (fa "nsFullOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PCon "DEffect" PWild (PVar "n") PWild PWild PWild PWild) () (EListLit (EVar "n"))) (arm PWild () (EListLit))))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EMatch (EVar "path") (arm (PCon "UseWild" PWild) () (EFieldAccess (EVar "src") "expEffects")) (arm PWild () (EApp (EApp (EVar "localsExportedFrom") (EFieldAccess (EVar "src") "expEffects")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))))))))
(DTypeSig false "nsEffectOrigins" (TyApp (TyCon "ExpNs") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "nsEffectOrigins" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expEffectOrigins"))) (fa "nsDirectOf" (ELam (PWild) (EListLit))) (fa "nsFullOf" (ELam (PWild) (EListLit))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EMatch (EVar "path") (arm (PCon "UseWild" PWild) () (EFieldAccess (EVar "src") "expEffectOrigins")) (arm PWild () (EApp (EApp (EVar "carriedEffectOrigins") (EFieldAccess (EVar "src") "expEffectOrigins")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))))))))
(DTypeSig false "carriedEffectOrigins" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "carriedEffectOrigins" (PWild (PList)) (EListLit))
(DFunDef false "carriedEffectOrigins" ((PVar "origins") (PCons (PTuple (PVar "o") (PVar "l")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "o")) (EVar "origins")) (arm (PCon "Some" (PVar "m")) () (EBinOp "::" (ETuple (EVar "l") (EVar "m")) (EApp (EApp (EVar "carriedEffectOrigins") (EVar "origins")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EVar "carriedEffectOrigins") (EVar "origins")) (EVar "rest")))))
(DTypeSig true "nsNewtypeCtors" (TyApp (TyCon "ExpNs") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "nsNewtypeCtors" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expNewtypeCtors"))) (fa "nsDirectOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DNewtype" ((rf "newtypePub" (PCon "True")) (rf "newtypeName" (PVar "n")) (rf "newtypeCtor" (PVar "con"))) false) () (EListLit (ETuple (EVar "con") (EVar "n")))) (arm PWild () (EListLit))))) (fa "nsFullOf" (ELam (PWild) (EListLit))) (fa "nsCarry" (EVar "noCarry")))))
(DTypeSig false "nsAbstractCtors" (TyApp (TyCon "ExpNs") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "nsAbstractCtors" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expAbstractCtors"))) (fa "nsDirectOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DData" ((rf "dataVis" (PCon "VisAbstract")) (rf "dataName" (PVar "n")) (rf "dataCtors" (PVar "vs"))) false) () (EApp (EApp (EVar "map") (ELam ((PVar "v")) (ETuple (EApp (EVar "variantName") (EVar "v")) (EVar "n")))) (EVar "vs"))) (arm PWild () (EListLit))))) (fa "nsFullOf" (ELam (PWild) (EListLit))) (fa "nsCarry" (EVar "noCarry")))))
(DTypeSig false "noCarry" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "noCarry" (PWild PWild) (EListLit))
(DTypeSig true "exportsIn" (TyFun (TyApp (TyCon "ExpNs") (TyVar "a")) (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "exportsIn" ((PVar "ns") (PVar "exp")) (EApp (EFieldAccess (EVar "ns") "nsGet") (EVar "exp")))
(DTypeSig true "directIn" (TyFun (TyApp (TyCon "ExpNs") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "directIn" ((PVar "ns") (PVar "prog")) (EApp (EApp (EVar "scanDecls") (EFieldAccess (EVar "ns") "nsDirectOf")) (EVar "prog")))
(DTypeSig true "declExportsIn" (TyFun (TyApp (TyCon "ExpNs") (TyVar "a")) (TyFun (TyCon "Decl") (TyCon "Bool"))))
(DFunDef false "declExportsIn" ((PVar "ns") (PVar "d")) (EApp (EVar "isNonEmptyL") (EApp (EFieldAccess (EVar "ns") "nsDirectOf") (EVar "d"))))
(DTypeSig true "declExportsCtors" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "declExportsCtors" ((PVar "d")) (EBinOp "&&" (EApp (EApp (EVar "declExportsIn") (EVar "nsTypeCtors")) (EVar "d")) (EApp (EVar "not") (EApp (EApp (EVar "declExportsIn") (EVar "nsNewtypeCtors")) (EVar "d")))))
(DTypeSig true "exportedValueNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "exportedValueNames" ((PVar "prog")) (EApp (EApp (EVar "valueNamesUnder") (EVar "ExportedView")) (EVar "prog")))
(DTypeSig true "valueNamesUnder" (TyFun (TyCon "ExportView") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "valueNamesUnder" ((PVar "view") (PVar "prog")) (EApp (EApp (EVar "scanDecls") (ELam ((PVar "d")) (EBinOp "++" (EApp (EApp (EApp (EVar "ruleOf") (EVar "view")) (EVar "nsValues")) (EVar "d")) (EApp (EApp (EVar "flatMap") (EVar "snd")) (EApp (EApp (EApp (EVar "ruleOf") (EVar "view")) (EVar "nsIfaceMethods")) (EVar "d")))))) (EVar "prog")))
(DTypeSig false "scanDecls" (TyFun (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "scanDecls" (PWild (PList)) (EListLit))
(DFunDef false "scanDecls" ((PVar "f") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "scanDecls") (EVar "f")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "scanDecls" ((PVar "f") (PCons (PVar "d") (PVar "rest"))) (EBinOp "++" (EApp (EVar "f") (EVar "d")) (EApp (EApp (EVar "scanDecls") (EVar "f")) (EVar "rest"))))
(DData Public "ExportView" () ((variant "ExportedView" (ConPos)) (variant "FullView" (ConPos))) ())
(DTypeSig true "viewOf" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "ExportView"))))
(DFunDef false "viewOf" ((PVar "subject") (PVar "mid")) (EIf (EBinOp "==" (EVar "subject") (EApp (EVar "Some") (EVar "mid"))) (EVar "FullView") (EVar "ExportedView")))
(DTypeSig false "ruleOf" (TyFun (TyCon "ExportView") (TyFun (TyApp (TyCon "ExpNs") (TyVar "a")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "ruleOf" ((PCon "ExportedView") (PVar "ns") (PVar "d")) (EApp (EFieldAccess (EVar "ns") "nsDirectOf") (EVar "d")))
(DFunDef false "ruleOf" ((PCon "FullView") (PVar "ns") (PVar "d")) (EApp (EFieldAccess (EVar "ns") "nsFullOf") (EVar "d")))
(DTypeSig true "directUnder" (TyFun (TyCon "ExportView") (TyFun (TyApp (TyCon "ExpNs") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "directUnder" ((PVar "view") (PVar "ns") (PVar "prog")) (EApp (EApp (EVar "scanDecls") (EApp (EApp (EVar "ruleOf") (EVar "view")) (EVar "ns"))) (EVar "prog")))
(DTypeSig true "carriedPaths" (TyFun (TyCon "ExportView") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "UsePath")))))
(DFunDef false "carriedPaths" ((PCon "ExportedView") (PVar "prog")) (EApp (EVar "pubUsePaths") (EVar "prog")))
(DFunDef false "carriedPaths" ((PCon "FullView") (PVar "prog")) (EBinOp "++" (EApp (EVar "pubUsePaths") (EVar "prog")) (EApp (EVar "plainUsePaths") (EVar "prog"))))
(DTypeSig false "carriedIn" (TyFun (TyApp (TyCon "ExpNs") (TyVar "a")) (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "UsePath")) (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "carriedIn" ((PVar "ns") (PVar "coreExp") (PVar "known") (PVar "paths")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "overPubUse") (EVar "coreExp")) (EVar "known")) (EFieldAccess (EVar "ns") "nsCarry"))) (EVar "paths")))
(DTypeSig true "buildExportsWith" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "ModuleExports")))))))
(DFunDef false "buildExportsWith" ((PVar "coreExp") (PVar "known") (PVar "modId") (PVar "prog") (PVar "ifaceVals")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "buildSurface") (EVar "ExportedView")) (EVar "coreExp")) (EVar "known")) (EVar "modId")) (EVar "prog")) (EVar "ifaceVals")))
(DTypeSig true "fullExportsOf" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "ModuleExports"))))))
(DFunDef false "fullExportsOf" ((PVar "coreExp") (PVar "known") (PVar "modId") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "buildSurface") (EVar "FullView")) (EVar "coreExp")) (EVar "known")) (EVar "modId")) (EVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "snd")) (EApp (EApp (EApp (EVar "directUnder") (EVar "FullView")) (EVar "nsIfaceMethods")) (EVar "prog")))))
(DTypeSig true "withSubjectView" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "OrdMap") (TyCon "ModuleExports"))))))
(DFunDef false "withSubjectView" (PWild (PVar "known") (PCon "None")) (EVar "known"))
(DFunDef false "withSubjectView" ((PVar "coreExp") (PVar "known") (PCon "Some" (PTuple (PVar "mid") (PVar "prog")))) (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (EApp (EApp (EApp (EApp (EVar "fullExportsOf") (EVar "coreExp")) (EVar "known")) (EVar "mid")) (EVar "prog"))) (EVar "known")))
(DTypeSig false "buildSurface" (TyFun (TyCon "ExportView") (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "ModuleExports"))))))))
(DFunDef false "buildSurface" ((PVar "view") (PVar "coreExp") (PVar "known") (PVar "modId") (PVar "prog") (PVar "ifaceVals")) (EBlock (DoLet false false (PVar "paths") (EApp (EApp (EVar "carriedPaths") (EVar "view")) (EVar "prog"))) (DoLet false false (PVar "values") (EApp (EApp (EApp (EVar "directUnder") (EVar "view")) (EVar "nsValues")) (EVar "prog"))) (DoLet false false (PVar "types") (EApp (EApp (EApp (EVar "directUnder") (EVar "view")) (EVar "nsTypes")) (EVar "prog"))) (DoLet false false (PVar "ctors") (EApp (EApp (EApp (EVar "directUnder") (EVar "view")) (EVar "nsCtors")) (EVar "prog"))) (DoLet false false (PVar "ifaces") (EApp (EApp (EApp (EVar "directUnder") (EVar "view")) (EVar "nsInterfaces")) (EVar "prog"))) (DoLet false false (PVar "effects") (EApp (EApp (EApp (EVar "directUnder") (EVar "view")) (EVar "nsEffects")) (EVar "prog"))) (DoExpr (EApp (EVar "indexExports") (ERecordCreate "ModuleExports" ((fa "modId" (EVar "modId")) (fa "expValues" (EBinOp "++" (EBinOp "++" (EVar "values") (EVar "ifaceVals")) (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsValues")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expTypes" (EBinOp "++" (EVar "types") (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsTypes")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expAbstractData" (EBinOp "++" (EApp (EApp (EApp (EVar "directUnder") (EVar "view")) (EVar "nsAbstractData")) (EVar "prog")) (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsAbstractData")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expCtors" (EBinOp "++" (EVar "ctors") (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsCtors")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expTypeCtors" (EBinOp "++" (EApp (EApp (EApp (EVar "directUnder") (EVar "view")) (EVar "nsTypeCtors")) (EVar "prog")) (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsTypeCtors")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expFieldOwners" (EBinOp "++" (EApp (EApp (EApp (EVar "directUnder") (EVar "view")) (EVar "nsFieldOwners")) (EVar "prog")) (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsFieldOwners")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expInterfaces" (EBinOp "++" (EVar "ifaces") (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsInterfaces")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expIfaceMethods" (EBinOp "++" (EApp (EApp (EApp (EVar "directUnder") (EVar "view")) (EVar "nsIfaceMethods")) (EVar "prog")) (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsIfaceMethods")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expIfaceOrigins" (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EVar "modId")))) (EVar "ifaces")) (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsIfaceOrigins")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expTypeOrigins" (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EVar "modId")))) (EVar "types")) (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsTypeOrigins")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expCtorOrigins" (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EVar "modId")))) (EVar "ctors")) (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsCtorOrigins")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expValueOrigins" (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (ETuple (EVar "modId") (EVar "n"))))) (EBinOp "++" (EVar "values") (EVar "ifaceVals"))) (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsValueOrigins")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expEffects" (EBinOp "++" (EVar "effects") (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsEffects")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expEffectOrigins" (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EVar "modId")))) (EVar "effects")) (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsEffectOrigins")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expNewtypeCtors" (EApp (EApp (EApp (EVar "directUnder") (EVar "view")) (EVar "nsNewtypeCtors")) (EVar "prog"))) (fa "expAbstractCtors" (EApp (EApp (EApp (EVar "directUnder") (EVar "view")) (EVar "nsAbstractCtors")) (EVar "prog"))) (fa "nameSet" (EVar "omEmpty")) (fa "ctorTypes" (EVar "omEmpty"))))))))
(DTypeSig true "pubIfaceMethodSets" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "pubIfaceMethodSets" ((PList)) (EListLit))
(DFunDef false "pubIfaceMethodSets" ((PCons (PRec "DInterface" ((rf "pub" (PCon "True")) (rf "methods" None)) true) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "map") (EVar "ifaceMethodNm")) (EVar "methods")) (EApp (EVar "pubIfaceMethodSets") (EVar "rest"))))
(DFunDef false "pubIfaceMethodSets" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "pubIfaceMethodSets") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "pubIfaceMethodSets" ((PCons PWild (PVar "rest"))) (EApp (EVar "pubIfaceMethodSets") (EVar "rest")))
(DTypeSig true "reexportBindings" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportBindings" ((PCon "UseName" (PVar "ns")) PWild) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EBlock (DoLet false false (PVar "n") (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EVar "last") (EVar "ns")))) (DoExpr (EListLit (ETuple (EVar "n") (EVar "n"))))) (EListLit)))
(DFunDef false "reexportBindings" ((PCon "UseGroup" PWild (PVar "members")) (PVar "src")) (EApp (EApp (EVar "map") (EVar "dropLocOfExpanded")) (EApp (EApp (EVar "flatMap") (EApp (EVar "expandMemberNames") (EVar "src"))) (EVar "members"))))
(DFunDef false "reexportBindings" ((PCon "UseWild" PWild) (PVar "src")) (EApp (EApp (EVar "map") (EVar "selfBinding")) (EBinOp "++" (EFieldAccess (EVar "src") "expValues") (EApp (EVar "dedup") (EBinOp "++" (EBinOp "++" (EFieldAccess (EVar "src") "expTypes") (EFieldAccess (EVar "src") "expCtors")) (EFieldAccess (EVar "src") "expInterfaces"))))))
(DFunDef false "reexportBindings" ((PCon "UseAlias" PWild PWild) PWild) (EListLit))
(DTypeSig false "dropLocOfExpanded" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Loc")) (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "dropLocOfExpanded" ((PTuple (PVar "origin") (PVar "local") PWild)) (ETuple (EVar "origin") (EVar "local")))
(DTypeSig true "privilegedCarry" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "ModuleExports") (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "privilegedCarry" ((PVar "exported") (PVar "full") (PVar "path")) (EApp (EVar "dedup") (EApp (EApp (EVar "flatMap") (ELam ((PVar "ns")) (EApp (EApp (EApp (EApp (EVar "carriedOnlyBy") (EVar "ns")) (EVar "exported")) (EVar "full")) (EVar "path")))) (EListLit (EVar "nsValues") (EVar "nsTypes") (EVar "nsCtors") (EVar "nsInterfaces") (EVar "nsEffects")))))
(DTypeSig false "carriedOnlyBy" (TyFun (TyApp (TyCon "ExpNs") (TyCon "String")) (TyFun (TyCon "ModuleExports") (TyFun (TyCon "ModuleExports") (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "carriedOnlyBy" ((PVar "ns") (PVar "exported") (PVar "full") (PVar "path")) (EBlock (DoLet false false (PVar "viaExports") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EFieldAccess (EVar "ns") "nsCarry") (EVar "path")) (EVar "exported"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "viaExports"))))) (EApp (EApp (EFieldAccess (EVar "ns") "nsCarry") (EVar "path")) (EVar "full"))))))
(DTypeSig false "localsExportedFrom" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "localsExportedFrom" ((PVar "origins") (PVar "bindings")) (EBlock (DoLet false false (PVar "dom") (EApp (EApp (EVar "omFromNames") (EVar "origins")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "b"))) (EVar "dom")))) (EVar "bindings"))))))
(DTypeSig false "carriedValuesFrom" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "carriedValuesFrom" ((PVar "src") (PVar "bindings")) (EBinOp "++" (EApp (EApp (EVar "localsExportedFrom") (EFieldAccess (EVar "src") "expValues")) (EVar "bindings")) (EApp (EApp (EVar "carriedIfaceVals") (EVar "src")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "bindings")))))
(DTypeSig false "carriedIfaceVals" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "carriedIfaceVals" ((PVar "src") (PVar "origins")) (EMatch (EApp (EApp (EVar "filterInSet") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "src") "expInterfaces")) (EVar "omEmpty"))) (EVar "origins")) (arm (PList) () (EListLit)) (arm (PVar "carried") () (EBlock (DoLet false false (PVar "values") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "src") "expValues")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "flatMap") (ELam ((PVar "n")) (EApp (EApp (EVar "filterInSet") (EVar "values")) (EApp (EApp (EVar "ifaceMethodsOf") (EVar "n")) (EFieldAccess (EVar "src") "expIfaceMethods"))))) (EVar "carried")))))))
(DTypeSig false "carriedTypeCtorsFrom" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "carriedTypeCtorsFrom" ((PVar "src") (PVar "carried")) (EBlock (DoLet false false (PVar "carriedSet") (EApp (EApp (EVar "omFromNames") (EVar "carried")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EVar "carriedTypeCtors") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "filterInSet") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "src") "expTypes")) (EVar "omEmpty"))) (EVar "carried"))) (EVar "omEmpty"))) (EVar "carriedSet")) (EFieldAccess (EVar "src") "expTypeCtors")))))
(DTypeSig false "carriedTypeCtors" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "carriedTypeCtors" (PWild PWild (PList)) (EListLit))
(DFunDef false "carriedTypeCtors" ((PVar "types") (PVar "carried") (PCons (PTuple (PVar "t") (PVar "cs")) (PVar "rest"))) (EIf (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "t")) (EVar "types"))) (EApp (EApp (EApp (EVar "carriedTypeCtors") (EVar "types")) (EVar "carried")) (EVar "rest")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "kept") (EApp (EApp (EVar "filterInSet") (EVar "carried")) (EVar "cs"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "kept")) (EApp (EApp (EApp (EVar "carriedTypeCtors") (EVar "types")) (EVar "carried")) (EVar "rest")) (EBinOp "::" (ETuple (EVar "t") (EVar "kept")) (EApp (EApp (EApp (EVar "carriedTypeCtors") (EVar "types")) (EVar "carried")) (EVar "rest")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reexportOrigins" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reexportOrigins" ((PVar "path") (PVar "src")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))
(DTypeSig false "ifaceMethodPairs" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ifaceMethodPairs" (PWild (PList)) (EListLit))
(DFunDef false "ifaceMethodPairs" ((PVar "src") (PCons (PVar "i") (PVar "rest"))) (EBinOp "::" (ETuple (EVar "i") (EApp (EApp (EVar "ifaceMethodsOf") (EVar "i")) (EFieldAccess (EVar "src") "expIfaceMethods"))) (EApp (EApp (EVar "ifaceMethodPairs") (EVar "src")) (EVar "rest"))))
(DTypeSig false "ownersForTypes" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "ownersForTypes" (PWild (PList)) (EListLit))
(DFunDef false "ownersForTypes" ((PVar "types") (PCons (PTuple (PVar "f") (PVar "o")) (PVar "rest"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "o")) (EVar "types")) (EBinOp "::" (ETuple (EVar "f") (EVar "o")) (EApp (EApp (EVar "ownersForTypes") (EVar "types")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "ownersForTypes") (EVar "types")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "overPubUse" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyVar "b")))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyVar "b")))))))
(DFunDef false "overPubUse" ((PVar "coreExp") (PVar "known") (PVar "f") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EApp (EApp (EVar "f") (EVar "path")) (EVar "coreExp")) (EMatch (EApp (EApp (EVar "findExports") (EVar "mid")) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EVar "f") (EVar "path")) (EVar "src"))))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "variantName" false) (mem "letBindName" false) (mem "Loc" true) (mem "UseMember" true) (mem "UsePath" true) (mem "useMemberLocal" false) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true) (mem "ExternDecl" true))))
(DUse false (UseGroup ("list") ((mem "head" false) (mem "last" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omFromNames" false) (mem "omFromPairs" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "reverseL" false) (mem "initList" false) (mem "joinDot" false) (mem "filterList" false) (mem "dedup" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "selfBinding" false))))
(DTypeSig true "ifaceMethodsOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ifaceMethodsOf" (PWild (PList)) (EListLit))
(DFunDef false "ifaceMethodsOf" ((PVar "iface") (PCons (PTuple (PVar "i") (PVar "ms")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "i") (EVar "iface")) (EVar "ms") (EIf (EVar "otherwise") (EApp (EApp (EVar "ifaceMethodsOf") (EVar "iface")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "dataRecordNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dataRecordNames" ((PList)) (EListLit))
(DFunDef false "dataRecordNames" ((PCons (PRec "DData" ((rf "dataName" (PVar "n"))) false) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "dataRecordNames") (EVar "rest"))))
(DFunDef false "dataRecordNames" ((PCons (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n"))) false) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "dataRecordNames") (EVar "rest"))))
(DFunDef false "dataRecordNames" ((PCons (PRec "DNewtype" ((rf "newtypeName" (PVar "n"))) false) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "dataRecordNames") (EVar "rest"))))
(DFunDef false "dataRecordNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "dataRecordNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "dataRecordNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "dataRecordNames") (EVar "rest")))
(DTypeSig true "effectNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "effectNames" ((PList)) (EListLit))
(DFunDef false "effectNames" ((PCons (PCon "DEffect" PWild (PVar "n") PWild PWild PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "effectNames") (EVar "rest"))))
(DFunDef false "effectNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "effectNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "effectNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "effectNames") (EVar "rest")))
(DTypeSig true "ctorNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ctorNames" ((PList)) (EListLit))
(DFunDef false "ctorNames" ((PCons (PRec "DData" ((rf "dataCtors" (PVar "vs"))) false) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "variantName")) (EVar "vs")) (EApp (EVar "ctorNames") (EVar "rest"))))
(DFunDef false "ctorNames" ((PCons (PRec "DNewtype" ((rf "newtypeCtor" (PVar "con"))) false) (PVar "rest"))) (EBinOp "::" (EVar "con") (EApp (EVar "ctorNames") (EVar "rest"))))
(DFunDef false "ctorNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "ctorNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "ctorNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "ctorNames") (EVar "rest")))
(DTypeSig true "ifaceMethodNm" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ifaceMethodNm" ((PCon "IfaceMethod" (PVar "n") PWild PWild PWild)) (EVar "n"))
(DTypeSig false "implMethodNm" (TyFun (TyCon "ImplMethod") (TyCon "String")))
(DFunDef false "implMethodNm" ((PCon "ImplMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig true "interfaceList" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "interfaceList" ((PList)) (EListLit))
(DFunDef false "interfaceList" ((PCons (PRec "DInterface" ((rf "name" (PVar "n")) (rf "methods" None)) true) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodNm")) (EVar "methods"))) (EApp (EVar "interfaceList") (EVar "rest"))))
(DFunDef false "interfaceList" ((PCons PWild (PVar "rest"))) (EApp (EVar "interfaceList") (EVar "rest")))
(DTypeSig true "preludeValueNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "preludeValueNames" ((PList)) (EListLit))
(DFunDef false "preludeValueNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "preludeValueNames") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons (PCon "DTypeSig" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "preludeValueNames") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons (PRec "DImpl" ((rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "implMethodNm")) (EVar "methods")) (EApp (EVar "preludeValueNames") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons (PRec "DInterface" ((rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodNm")) (EVar "methods")) (EApp (EVar "preludeValueNames") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "preludeValueNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "preludeValueNames") (EVar "rest")))
(DTypeSig true "fieldOwnersOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "fieldOwnersOf" ((PList)) (EListLit))
(DFunDef false "fieldOwnersOf" ((PCons (PRec "DData" ((rf "dataCtors" (PVar "vs"))) false) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "variantFieldOwners")) (EVar "vs")) (EApp (EVar "fieldOwnersOf") (EVar "rest"))))
(DFunDef false "fieldOwnersOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "fieldOwnersOf") (EVar "rest")))
(DTypeSig false "recordFieldOwner" (TyFun (TyCon "String") (TyFun (TyCon "Field") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "recordFieldOwner" ((PVar "owner") (PCon "Field" (PVar "fname") PWild)) (ETuple (EVar "fname") (EVar "owner")))
(DTypeSig false "variantFieldOwners" (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "variantFieldOwners" ((PCon "Variant" (PVar "cname") (PCon "ConNamed" (PVar "fs") PWild))) (EApp (EApp (EMethodRef "map") (EApp (EVar "recordFieldOwner") (EVar "cname"))) (EVar "fs")))
(DFunDef false "variantFieldOwners" ((PCon "Variant" PWild (PCon "ConPos" PWild))) (EListLit))
(DTypeSig true "useModId" (TyFun (TyCon "UsePath") (TyCon "String")))
(DFunDef false "useModId" ((PCon "UseName" (PVar "ns"))) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EApp (EVar "joinDot") (EApp (EVar "initList") (EVar "ns"))) (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EVar "head") (EVar "ns")))))
(DFunDef false "useModId" ((PCon "UseGroup" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "useModId" ((PCon "UseWild" (PVar "ns"))) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "useModId" ((PCon "UseAlias" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DTypeSig true "useModuleIds" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "useModuleIds" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "declUseIds")) (EVar "prog")))
(DTypeSig true "declUseIds" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declUseIds" ((PCon "DUse" PWild (PVar "path") PWild)) (EListLit (EApp (EVar "useModId") (EVar "path"))))
(DFunDef false "declUseIds" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declUseIds") (EVar "d")))
(DFunDef false "declUseIds" (PWild) (EListLit))
(DData Public "ModuleExports" () ((variant "ModuleExports" (ConNamed (field "modId" (TyCon "String")) (field "expValues" (TyApp (TyCon "List") (TyCon "String"))) (field "expTypes" (TyApp (TyCon "List") (TyCon "String"))) (field "expAbstractData" (TyApp (TyCon "List") (TyCon "String"))) (field "expCtors" (TyApp (TyCon "List") (TyCon "String"))) (field "expTypeCtors" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "expFieldOwners" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "expInterfaces" (TyApp (TyCon "List") (TyCon "String"))) (field "expIfaceMethods" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "expIfaceOrigins" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "expTypeOrigins" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "expCtorOrigins" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "expValueOrigins" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))) (field "expEffects" (TyApp (TyCon "List") (TyCon "String"))) (field "expEffectOrigins" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "expNewtypeCtors" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "expAbstractCtors" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "nameSet" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "ctorTypes" (TyApp (TyCon "OrdMap") (TyCon "String")))))) ())
(DTypeSig true "filterInSet" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterInSet" (PWild (PList)) (EListLit))
(DFunDef false "filterInSet" ((PVar "domain") (PCons (PVar "n") (PVar "rest"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "domain")) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "filterInSet") (EVar "domain")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterInSet") (EVar "domain")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "findExports" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyApp (TyCon "Option") (TyCon "ModuleExports")))))
(DFunDef false "findExports" ((PVar "mid") (PVar "known")) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EVar "known")))
(DTypeSig true "isPubExp" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isPubExp" ((PVar "exp") (PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EVar "exp") "nameSet")))
(DTypeSig false "indexExports" (TyFun (TyCon "ModuleExports") (TyCon "ModuleExports")))
(DFunDef false "indexExports" ((PVar "exp")) (ERecordUpdate (EVar "exp") ((fa "nameSet" (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EFieldAccess (EVar "exp") "expValues") (EFieldAccess (EVar "exp") "expTypes")) (EFieldAccess (EVar "exp") "expCtors")) (EFieldAccess (EVar "exp") "expInterfaces")) (EFieldAccess (EVar "exp") "expEffects"))) (EVar "omEmpty"))) (fa "ctorTypes" (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PVar "ty") (PVar "ctors"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (ETuple (EVar "c") (EVar "ty")))) (EVar "ctors")))) (EFieldAccess (EVar "exp") "expTypeCtors")))) (EVar "omEmpty"))))))
(DTypeSig true "typeCtorsOf" (TyFun (TyCon "String") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "typeCtorsOf" ((PVar "name") (PVar "exp")) (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EFieldAccess (EVar "exp") "expTypeCtors")))
(DTypeSig true "typeOfCtor" (TyFun (TyCon "String") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "typeOfCtor" ((PVar "name") (PVar "exp")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "exp") "ctorTypes")))
(DTypeSig true "newtypeTypeOfCtor" (TyFun (TyCon "String") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "newtypeTypeOfCtor" ((PVar "name") (PVar "exp")) (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EFieldAccess (EVar "exp") "expNewtypeCtors")))
(DTypeSig true "isNewtypeExport" (TyFun (TyCon "String") (TyFun (TyCon "ModuleExports") (TyCon "Bool"))))
(DFunDef false "isNewtypeExport" ((PVar "name") (PVar "exp")) (EApp (EApp (EVar "contains") (EVar "name")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EFieldAccess (EVar "exp") "expNewtypeCtors"))))
(DTypeSig true "bindsNonCtorExport" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "bindsNonCtorExport" ((PVar "exp") (PVar "name")) (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "name")) (EFieldAccess (EVar "exp") "expTypes")) (EApp (EApp (EVar "contains") (EVar "name")) (EFieldAccess (EVar "exp") "expInterfaces"))) (EApp (EApp (EVar "contains") (EVar "name")) (EFieldAccess (EVar "exp") "expEffects"))))
(DTypeSig true "pubUsePaths" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "UsePath"))))
(DFunDef false "pubUsePaths" ((PList)) (EListLit))
(DFunDef false "pubUsePaths" ((PCons (PCon "DUse" (PCon "True") (PVar "path") PWild) (PVar "rest"))) (EBinOp "::" (EVar "path") (EApp (EVar "pubUsePaths") (EVar "rest"))))
(DFunDef false "pubUsePaths" ((PCons PWild (PVar "rest"))) (EApp (EVar "pubUsePaths") (EVar "rest")))
(DTypeSig true "plainUsePaths" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "UsePath"))))
(DFunDef false "plainUsePaths" ((PList)) (EListLit))
(DFunDef false "plainUsePaths" ((PCons (PCon "DUse" (PCon "False") (PVar "path") PWild) (PVar "rest"))) (EBinOp "::" (EVar "path") (EApp (EVar "plainUsePaths") (EVar "rest"))))
(DFunDef false "plainUsePaths" ((PCons PWild (PVar "rest"))) (EApp (EVar "plainUsePaths") (EVar "rest")))
(DTypeSig true "expandMemberNames" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Loc"))))))
(DFunDef false "expandMemberNames" ((PVar "exp") (PAs "m" (PCon "UseMember" (PVar "name") (PCon "False") (PVar "loc") PWild))) (EIf (EApp (EApp (EVar "bindsNonCtorExport") (EVar "exp")) (EVar "name")) (EListLit (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m")) (EVar "loc"))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "newtypeTypeOfCtor") (EVar "name")) (EVar "exp")) (arm (PCon "Some" PWild) () (EListLit)) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "typeOfCtor") (EVar "name")) (EVar "exp")) (arm (PCon "Some" PWild) () (EListLit)) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EFieldAccess (EVar "exp") "expAbstractCtors")) (arm (PCon "Some" PWild) () (EListLit)) (arm (PCon "None") () (EListLit (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m")) (EVar "loc"))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "expandMemberNames" ((PVar "exp") (PAs "m" (PCon "UseMember" (PVar "name") (PCon "True") (PVar "loc") PWild))) (EIf (EApp (EApp (EVar "isNewtypeExport") (EVar "name")) (EVar "exp")) (EListLit (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m")) (EVar "loc"))) (EIf (EApp (EApp (EVar "contains") (EVar "name")) (EFieldAccess (EVar "exp") "expEffects")) (EListLit) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "typeCtorsOf") (EVar "name")) (EVar "exp")) (arm (PCon "Some" (PVar "ctors")) () (EBinOp "::" (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m")) (EVar "loc")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (ETuple (EVar "c") (EVar "c") (EVar "loc")))) (EVar "ctors")))) (arm (PCon "None") () (EListLit (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m")) (EVar "loc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "coreExports" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "ModuleExports")))
(DFunDef false "coreExports" ((PVar "preludeDecls")) (EApp (EVar "indexExports") (ERecordCreate "ModuleExports" ((fa "modId" (ELit (LString "core"))) (fa "expValues" (EApp (EVar "preludeValueNames") (EVar "preludeDecls"))) (fa "expTypes" (EApp (EVar "dataRecordNames") (EVar "preludeDecls"))) (fa "expAbstractData" (EListLit)) (fa "expCtors" (EApp (EVar "ctorNames") (EVar "preludeDecls"))) (fa "expTypeCtors" (EApp (EVar "typeCtorsAllOf") (EVar "preludeDecls"))) (fa "expFieldOwners" (EApp (EVar "fieldOwnersOf") (EVar "preludeDecls"))) (fa "expInterfaces" (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "interfaceList") (EVar "preludeDecls")))) (fa "expIfaceMethods" (EApp (EVar "interfaceList") (EVar "preludeDecls"))) (fa "expIfaceOrigins" (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (ETuple (EApp (EVar "fst") (EVar "i")) (ELit (LString "core"))))) (EApp (EVar "interfaceList") (EVar "preludeDecls")))) (fa "expTypeOrigins" (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (ELit (LString "core"))))) (EApp (EVar "dataRecordNames") (EVar "preludeDecls")))) (fa "expCtorOrigins" (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (ELit (LString "core"))))) (EApp (EVar "ctorNames") (EVar "preludeDecls")))) (fa "expValueOrigins" (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (ETuple (ELit (LString "core")) (EVar "n"))))) (EApp (EVar "preludeValueNames") (EVar "preludeDecls")))) (fa "expEffects" (EApp (EVar "effectNames") (EVar "preludeDecls"))) (fa "expEffectOrigins" (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (ELit (LString "core"))))) (EApp (EVar "effectNames") (EVar "preludeDecls")))) (fa "expAbstractCtors" (EListLit)) (fa "expNewtypeCtors" (EListLit)) (fa "nameSet" (EVar "omEmpty")) (fa "ctorTypes" (EVar "omEmpty"))))))
(DTypeSig false "typeCtorsAllOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "typeCtorsAllOf" ((PList)) (EListLit))
(DFunDef false "typeCtorsAllOf" ((PCons (PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeCtor" (PVar "con"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EListLit (EVar "con"))) (EApp (EVar "typeCtorsAllOf") (EVar "rest"))))
(DFunDef false "typeCtorsAllOf" ((PCons (PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataCtors" (PVar "vs"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EMethodRef "map") (EVar "variantName")) (EVar "vs"))) (EApp (EVar "typeCtorsAllOf") (EVar "rest"))))
(DFunDef false "typeCtorsAllOf" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "typeCtorsAllOf") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "typeCtorsAllOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "typeCtorsAllOf") (EVar "rest")))
(DData Public "ExpNs" ("a") ((variant "ExpNs" (ConNamed (field "nsGet" (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyVar "a")))) (field "nsDirectOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyVar "a")))) (field "nsFullOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyVar "a")))) (field "nsCarry" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyVar "a")))))))) ())
(DTypeSig true "nsValues" (TyApp (TyCon "ExpNs") (TyCon "String")))
(DFunDef false "nsValues" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expValues"))) (fa "nsDirectOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PCon "DTypeSig" (PCon "True") (PVar "n") PWild PWild) () (EListLit (EVar "n"))) (arm (PCon "DExtern" (PRec "ExternDecl" ((rf "edPub" (PCon "True")) (rf "edName" (PVar "n"))) true)) () (EListLit (EVar "n"))) (arm (PCon "DFunDef" (PCon "True") (PVar "n") PWild PWild PWild PWild) () (EListLit (EVar "n"))) (arm (PCon "DLetGroup" (PCon "True") (PVar "binds")) () (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds"))) (arm PWild () (EListLit))))) (fa "nsFullOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PCon "DTypeSig" PWild (PVar "n") PWild PWild) () (EListLit (EVar "n"))) (arm (PCon "DExtern" (PRec "ExternDecl" ((rf "edName" (PVar "n"))) true)) () (EListLit (EVar "n"))) (arm (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild) () (EListLit (EVar "n"))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds"))) (arm PWild () (EListLit))))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EApp (EApp (EVar "carriedValuesFrom") (EVar "src")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))))))
(DTypeSig true "nsTypes" (TyApp (TyCon "ExpNs") (TyCon "String")))
(DFunDef false "nsTypes" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expTypes"))) (fa "nsDirectOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DNewtype" ((rf "newtypePub" (PCon "True")) (rf "newtypeName" (PVar "n"))) false) () (EListLit (EVar "n"))) (arm (PRec "DData" ((rf "dataVis" (PCon "VisPublic")) (rf "dataName" (PVar "n"))) false) () (EListLit (EVar "n"))) (arm (PRec "DData" ((rf "dataVis" (PCon "VisAbstract")) (rf "dataName" (PVar "n"))) false) () (EListLit (EVar "n"))) (arm (PRec "DTypeAlias" ((rf "tyAliasPub" (PCon "True")) (rf "tyAliasName" (PVar "n"))) false) () (EListLit (EVar "n"))) (arm PWild () (EListLit))))) (fa "nsFullOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DNewtype" ((rf "newtypeName" (PVar "n"))) false) () (EListLit (EVar "n"))) (arm (PRec "DData" ((rf "dataName" (PVar "n"))) false) () (EListLit (EVar "n"))) (arm (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n"))) false) () (EListLit (EVar "n"))) (arm PWild () (EListLit))))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EApp (EApp (EVar "localsExportedFrom") (EFieldAccess (EVar "src") "expTypes")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))))))
(DTypeSig true "nsAbstractData" (TyApp (TyCon "ExpNs") (TyCon "String")))
(DFunDef false "nsAbstractData" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expAbstractData"))) (fa "nsDirectOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DData" ((rf "dataVis" (PCon "VisAbstract")) (rf "dataName" (PVar "n"))) false) () (EListLit (EVar "n"))) (arm PWild () (EListLit))))) (fa "nsFullOf" (ELam (PWild) (EListLit))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EApp (EApp (EVar "localsExportedFrom") (EFieldAccess (EVar "src") "expAbstractData")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))))))
(DTypeSig true "nsCtors" (TyApp (TyCon "ExpNs") (TyCon "String")))
(DFunDef false "nsCtors" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expCtors"))) (fa "nsDirectOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DNewtype" ((rf "newtypePub" (PCon "True")) (rf "newtypeCtor" (PVar "con"))) false) () (EListLit (EVar "con"))) (arm (PRec "DData" ((rf "dataVis" (PCon "VisPublic")) (rf "dataCtors" (PVar "vs"))) false) () (EApp (EApp (EMethodRef "map") (EVar "variantName")) (EVar "vs"))) (arm PWild () (EListLit))))) (fa "nsFullOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DNewtype" ((rf "newtypeCtor" (PVar "con"))) false) () (EListLit (EVar "con"))) (arm (PRec "DData" ((rf "dataCtors" (PVar "vs"))) false) () (EApp (EApp (EMethodRef "map") (EVar "variantName")) (EVar "vs"))) (arm PWild () (EListLit))))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EApp (EApp (EVar "localsExportedFrom") (EFieldAccess (EVar "src") "expCtors")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))))))
(DTypeSig true "nsTypeCtors" (TyApp (TyCon "ExpNs") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "nsTypeCtors" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expTypeCtors"))) (fa "nsDirectOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DNewtype" ((rf "newtypePub" (PCon "True")) (rf "newtypeName" (PVar "n")) (rf "newtypeCtor" (PVar "con"))) false) () (EListLit (ETuple (EVar "n") (EListLit (EVar "con"))))) (arm (PRec "DData" ((rf "dataVis" (PCon "VisPublic")) (rf "dataName" (PVar "n")) (rf "dataCtors" (PVar "vs"))) false) () (EListLit (ETuple (EVar "n") (EApp (EApp (EMethodRef "map") (EVar "variantName")) (EVar "vs"))))) (arm PWild () (EListLit))))) (fa "nsFullOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeCtor" (PVar "con"))) false) () (EListLit (ETuple (EVar "n") (EListLit (EVar "con"))))) (arm (PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataCtors" (PVar "vs"))) false) () (EListLit (ETuple (EVar "n") (EApp (EApp (EMethodRef "map") (EVar "variantName")) (EVar "vs"))))) (arm PWild () (EListLit))))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EApp (EApp (EVar "carriedTypeCtorsFrom") (EVar "src")) (EApp (EApp (EVar "reexportOrigins") (EVar "path")) (EVar "src"))))))))
(DTypeSig true "nsFieldOwners" (TyApp (TyCon "ExpNs") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "nsFieldOwners" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expFieldOwners"))) (fa "nsDirectOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DData" ((rf "dataVis" (PCon "VisPublic")) (rf "dataCtors" (PVar "vs"))) false) () (EApp (EApp (EDictApp "flatMap") (EVar "variantFieldOwners")) (EVar "vs"))) (arm PWild () (EListLit))))) (fa "nsFullOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DData" ((rf "dataCtors" (PVar "vs"))) false) () (EApp (EApp (EDictApp "flatMap") (EVar "variantFieldOwners")) (EVar "vs"))) (arm PWild () (EListLit))))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EApp (EApp (EVar "ownersForTypes") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "filterInSet") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EFieldAccess (EVar "src") "expTypes") (EFieldAccess (EVar "src") "expCtors"))) (EVar "omEmpty"))) (EApp (EApp (EVar "reexportOrigins") (EVar "path")) (EVar "src")))) (EVar "omEmpty"))) (EFieldAccess (EVar "src") "expFieldOwners")))))))
(DTypeSig true "nsInterfaces" (TyApp (TyCon "ExpNs") (TyCon "String")))
(DFunDef false "nsInterfaces" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expInterfaces"))) (fa "nsDirectOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DInterface" ((rf "pub" (PCon "True")) (rf "name" (PVar "n"))) true) () (EListLit (EVar "n"))) (arm PWild () (EListLit))))) (fa "nsFullOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DInterface" ((rf "name" (PVar "n"))) true) () (EListLit (EVar "n"))) (arm PWild () (EListLit))))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EApp (EApp (EVar "filterInSet") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "src") "expInterfaces")) (EVar "omEmpty"))) (EApp (EApp (EVar "reexportOrigins") (EVar "path")) (EVar "src"))))))))
(DTypeSig true "nsIfaceMethods" (TyApp (TyCon "ExpNs") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "nsIfaceMethods" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expIfaceMethods"))) (fa "nsDirectOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DInterface" ((rf "pub" (PCon "True")) (rf "name" (PVar "n")) (rf "methods" None)) true) () (EListLit (ETuple (EVar "n") (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodNm")) (EVar "methods"))))) (arm PWild () (EListLit))))) (fa "nsFullOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DInterface" ((rf "name" (PVar "n")) (rf "methods" None)) true) () (EListLit (ETuple (EVar "n") (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodNm")) (EVar "methods"))))) (arm PWild () (EListLit))))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EApp (EApp (EVar "ifaceMethodPairs") (EVar "src")) (EApp (EApp (EVar "filterInSet") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "src") "expInterfaces")) (EVar "omEmpty"))) (EApp (EApp (EVar "reexportOrigins") (EVar "path")) (EVar "src")))))))))
(DTypeSig true "nsIfaceOrigins" (TyApp (TyCon "ExpNs") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "nsIfaceOrigins" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expIfaceOrigins"))) (fa "nsDirectOf" (ELam (PWild) (EListLit))) (fa "nsFullOf" (ELam (PWild) (EListLit))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EApp (EApp (EApp (EVar "carriedOriginsFrom") (EVar "path")) (EVar "src")) (EFieldAccess (EVar "src") "expIfaceOrigins")))))))
(DTypeSig true "nsTypeOrigins" (TyApp (TyCon "ExpNs") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "nsTypeOrigins" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expTypeOrigins"))) (fa "nsDirectOf" (ELam (PWild) (EListLit))) (fa "nsFullOf" (ELam (PWild) (EListLit))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EApp (EApp (EApp (EVar "carriedOriginsFrom") (EVar "path")) (EVar "src")) (EFieldAccess (EVar "src") "expTypeOrigins")))))))
(DTypeSig true "nsCtorOrigins" (TyApp (TyCon "ExpNs") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "nsCtorOrigins" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expCtorOrigins"))) (fa "nsDirectOf" (ELam (PWild) (EListLit))) (fa "nsFullOf" (ELam (PWild) (EListLit))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EApp (EApp (EApp (EVar "carriedOriginsFrom") (EVar "path")) (EVar "src")) (EFieldAccess (EVar "src") "expCtorOrigins")))))))
(DTypeSig false "carriedOriginsFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "carriedOriginsFrom" ((PVar "path") (PVar "src") (PVar "origins")) (EBlock (DoLet false false (PVar "carried") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "reexportOrigins") (EVar "path")) (EVar "src"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "o")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "o"))) (EVar "carried")))) (EVar "origins")))))
(DTypeSig false "nsValueOrigins" (TyApp (TyCon "ExpNs") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "nsValueOrigins" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expValueOrigins"))) (fa "nsDirectOf" (ELam (PWild) (EListLit))) (fa "nsFullOf" (ELam (PWild) (EListLit))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EApp (EApp (EVar "carriedValueOriginsFrom") (EVar "src")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))))))
(DTypeSig false "carriedValueOriginsFrom" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "carriedValueOriginsFrom" ((PVar "src") (PVar "bindings")) (EBlock (DoLet false false (PVar "decls") (EApp (EVar "valueDeclsOf") (EVar "src"))) (DoLet false false (PVar "values") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "src") "expValues")) (EVar "omEmpty"))) (DoExpr (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "o") (PVar "l"))) (ETuple (EVar "l") (EApp (EApp (EApp (EVar "valueDeclOf") (EVar "src")) (EVar "decls")) (EVar "o"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "b"))) (EVar "values")))) (EVar "bindings"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (ETuple (EVar "m") (EApp (EApp (EApp (EVar "valueDeclOf") (EVar "src")) (EVar "decls")) (EVar "m"))))) (EApp (EApp (EVar "carriedIfaceVals") (EVar "src")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "bindings"))))))))
(DTypeSig true "valueDeclsOf" (TyFun (TyCon "ModuleExports") (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "valueDeclsOf" ((PVar "exp")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EFieldAccess (EVar "exp") "expValueOrigins"))) (EVar "omEmpty")))
(DTypeSig true "valueDeclOf" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "valueDeclOf" ((PVar "exp") (PVar "decls") (PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "decls")) (arm (PCon "Some" (PVar "d")) () (EVar "d")) (arm (PCon "None") () (ETuple (EFieldAccess (EVar "exp") "modId") (EVar "n")))))
(DTypeSig true "nsEffects" (TyApp (TyCon "ExpNs") (TyCon "String")))
(DFunDef false "nsEffects" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expEffects"))) (fa "nsDirectOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PCon "DEffect" (PCon "True") (PVar "n") PWild PWild PWild PWild) () (EListLit (EVar "n"))) (arm PWild () (EListLit))))) (fa "nsFullOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PCon "DEffect" PWild (PVar "n") PWild PWild PWild PWild) () (EListLit (EVar "n"))) (arm PWild () (EListLit))))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EMatch (EVar "path") (arm (PCon "UseWild" PWild) () (EFieldAccess (EVar "src") "expEffects")) (arm PWild () (EApp (EApp (EVar "localsExportedFrom") (EFieldAccess (EVar "src") "expEffects")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))))))))
(DTypeSig false "nsEffectOrigins" (TyApp (TyCon "ExpNs") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "nsEffectOrigins" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expEffectOrigins"))) (fa "nsDirectOf" (ELam (PWild) (EListLit))) (fa "nsFullOf" (ELam (PWild) (EListLit))) (fa "nsCarry" (ELam ((PVar "path") (PVar "src")) (EMatch (EVar "path") (arm (PCon "UseWild" PWild) () (EFieldAccess (EVar "src") "expEffectOrigins")) (arm PWild () (EApp (EApp (EVar "carriedEffectOrigins") (EFieldAccess (EVar "src") "expEffectOrigins")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))))))))
(DTypeSig false "carriedEffectOrigins" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "carriedEffectOrigins" (PWild (PList)) (EListLit))
(DFunDef false "carriedEffectOrigins" ((PVar "origins") (PCons (PTuple (PVar "o") (PVar "l")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "o")) (EVar "origins")) (arm (PCon "Some" (PVar "m")) () (EBinOp "::" (ETuple (EVar "l") (EVar "m")) (EApp (EApp (EVar "carriedEffectOrigins") (EVar "origins")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EVar "carriedEffectOrigins") (EVar "origins")) (EVar "rest")))))
(DTypeSig true "nsNewtypeCtors" (TyApp (TyCon "ExpNs") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "nsNewtypeCtors" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expNewtypeCtors"))) (fa "nsDirectOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DNewtype" ((rf "newtypePub" (PCon "True")) (rf "newtypeName" (PVar "n")) (rf "newtypeCtor" (PVar "con"))) false) () (EListLit (ETuple (EVar "con") (EVar "n")))) (arm PWild () (EListLit))))) (fa "nsFullOf" (ELam (PWild) (EListLit))) (fa "nsCarry" (EVar "noCarry")))))
(DTypeSig false "nsAbstractCtors" (TyApp (TyCon "ExpNs") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "nsAbstractCtors" () (ERecordCreate "ExpNs" ((fa "nsGet" (ELam ((PVar "exp")) (EFieldAccess (EVar "exp") "expAbstractCtors"))) (fa "nsDirectOf" (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PRec "DData" ((rf "dataVis" (PCon "VisAbstract")) (rf "dataName" (PVar "n")) (rf "dataCtors" (PVar "vs"))) false) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "v")) (ETuple (EApp (EVar "variantName") (EVar "v")) (EVar "n")))) (EVar "vs"))) (arm PWild () (EListLit))))) (fa "nsFullOf" (ELam (PWild) (EListLit))) (fa "nsCarry" (EVar "noCarry")))))
(DTypeSig false "noCarry" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "noCarry" (PWild PWild) (EListLit))
(DTypeSig true "exportsIn" (TyFun (TyApp (TyCon "ExpNs") (TyVar "a")) (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "exportsIn" ((PVar "ns") (PVar "exp")) (EApp (EFieldAccess (EVar "ns") "nsGet") (EVar "exp")))
(DTypeSig true "directIn" (TyFun (TyApp (TyCon "ExpNs") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "directIn" ((PVar "ns") (PVar "prog")) (EApp (EApp (EVar "scanDecls") (EFieldAccess (EVar "ns") "nsDirectOf")) (EVar "prog")))
(DTypeSig true "declExportsIn" (TyFun (TyApp (TyCon "ExpNs") (TyVar "a")) (TyFun (TyCon "Decl") (TyCon "Bool"))))
(DFunDef false "declExportsIn" ((PVar "ns") (PVar "d")) (EApp (EVar "isNonEmptyL") (EApp (EFieldAccess (EVar "ns") "nsDirectOf") (EVar "d"))))
(DTypeSig true "declExportsCtors" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "declExportsCtors" ((PVar "d")) (EBinOp "&&" (EApp (EApp (EVar "declExportsIn") (EVar "nsTypeCtors")) (EVar "d")) (EApp (EVar "not") (EApp (EApp (EVar "declExportsIn") (EVar "nsNewtypeCtors")) (EVar "d")))))
(DTypeSig true "exportedValueNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "exportedValueNames" ((PVar "prog")) (EApp (EApp (EVar "valueNamesUnder") (EVar "ExportedView")) (EVar "prog")))
(DTypeSig true "valueNamesUnder" (TyFun (TyCon "ExportView") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "valueNamesUnder" ((PVar "view") (PVar "prog")) (EApp (EApp (EVar "scanDecls") (ELam ((PVar "d")) (EBinOp "++" (EApp (EApp (EApp (EVar "ruleOf") (EVar "view")) (EVar "nsValues")) (EVar "d")) (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EApp (EApp (EApp (EVar "ruleOf") (EVar "view")) (EVar "nsIfaceMethods")) (EVar "d")))))) (EVar "prog")))
(DTypeSig false "scanDecls" (TyFun (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "scanDecls" (PWild (PList)) (EListLit))
(DFunDef false "scanDecls" ((PVar "f") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "scanDecls") (EVar "f")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "scanDecls" ((PVar "f") (PCons (PVar "d") (PVar "rest"))) (EBinOp "++" (EApp (EVar "f") (EVar "d")) (EApp (EApp (EVar "scanDecls") (EVar "f")) (EVar "rest"))))
(DData Public "ExportView" () ((variant "ExportedView" (ConPos)) (variant "FullView" (ConPos))) ())
(DTypeSig true "viewOf" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "ExportView"))))
(DFunDef false "viewOf" ((PVar "subject") (PVar "mid")) (EIf (EBinOp "==" (EVar "subject") (EApp (EVar "Some") (EVar "mid"))) (EVar "FullView") (EVar "ExportedView")))
(DTypeSig false "ruleOf" (TyFun (TyCon "ExportView") (TyFun (TyApp (TyCon "ExpNs") (TyVar "a")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "ruleOf" ((PCon "ExportedView") (PVar "ns") (PVar "d")) (EApp (EFieldAccess (EVar "ns") "nsDirectOf") (EVar "d")))
(DFunDef false "ruleOf" ((PCon "FullView") (PVar "ns") (PVar "d")) (EApp (EFieldAccess (EVar "ns") "nsFullOf") (EVar "d")))
(DTypeSig true "directUnder" (TyFun (TyCon "ExportView") (TyFun (TyApp (TyCon "ExpNs") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "directUnder" ((PVar "view") (PVar "ns") (PVar "prog")) (EApp (EApp (EVar "scanDecls") (EApp (EApp (EVar "ruleOf") (EVar "view")) (EVar "ns"))) (EVar "prog")))
(DTypeSig true "carriedPaths" (TyFun (TyCon "ExportView") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "UsePath")))))
(DFunDef false "carriedPaths" ((PCon "ExportedView") (PVar "prog")) (EApp (EVar "pubUsePaths") (EVar "prog")))
(DFunDef false "carriedPaths" ((PCon "FullView") (PVar "prog")) (EBinOp "++" (EApp (EVar "pubUsePaths") (EVar "prog")) (EApp (EVar "plainUsePaths") (EVar "prog"))))
(DTypeSig false "carriedIn" (TyFun (TyApp (TyCon "ExpNs") (TyVar "a")) (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "UsePath")) (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "carriedIn" ((PVar "ns") (PVar "coreExp") (PVar "known") (PVar "paths")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "overPubUse") (EVar "coreExp")) (EVar "known")) (EFieldAccess (EVar "ns") "nsCarry"))) (EVar "paths")))
(DTypeSig true "buildExportsWith" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "ModuleExports")))))))
(DFunDef false "buildExportsWith" ((PVar "coreExp") (PVar "known") (PVar "modId") (PVar "prog") (PVar "ifaceVals")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "buildSurface") (EVar "ExportedView")) (EVar "coreExp")) (EVar "known")) (EVar "modId")) (EVar "prog")) (EVar "ifaceVals")))
(DTypeSig true "fullExportsOf" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "ModuleExports"))))))
(DFunDef false "fullExportsOf" ((PVar "coreExp") (PVar "known") (PVar "modId") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "buildSurface") (EVar "FullView")) (EVar "coreExp")) (EVar "known")) (EVar "modId")) (EVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EApp (EApp (EApp (EVar "directUnder") (EVar "FullView")) (EVar "nsIfaceMethods")) (EVar "prog")))))
(DTypeSig true "withSubjectView" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "OrdMap") (TyCon "ModuleExports"))))))
(DFunDef false "withSubjectView" (PWild (PVar "known") (PCon "None")) (EVar "known"))
(DFunDef false "withSubjectView" ((PVar "coreExp") (PVar "known") (PCon "Some" (PTuple (PVar "mid") (PVar "prog")))) (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (EApp (EApp (EApp (EApp (EVar "fullExportsOf") (EVar "coreExp")) (EVar "known")) (EVar "mid")) (EVar "prog"))) (EVar "known")))
(DTypeSig false "buildSurface" (TyFun (TyCon "ExportView") (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "ModuleExports"))))))))
(DFunDef false "buildSurface" ((PVar "view") (PVar "coreExp") (PVar "known") (PVar "modId") (PVar "prog") (PVar "ifaceVals")) (EBlock (DoLet false false (PVar "paths") (EApp (EApp (EVar "carriedPaths") (EVar "view")) (EVar "prog"))) (DoLet false false (PVar "values") (EApp (EApp (EApp (EVar "directUnder") (EVar "view")) (EVar "nsValues")) (EVar "prog"))) (DoLet false false (PVar "types") (EApp (EApp (EApp (EVar "directUnder") (EVar "view")) (EVar "nsTypes")) (EVar "prog"))) (DoLet false false (PVar "ctors") (EApp (EApp (EApp (EVar "directUnder") (EVar "view")) (EVar "nsCtors")) (EVar "prog"))) (DoLet false false (PVar "ifaces") (EApp (EApp (EApp (EVar "directUnder") (EVar "view")) (EVar "nsInterfaces")) (EVar "prog"))) (DoLet false false (PVar "effects") (EApp (EApp (EApp (EVar "directUnder") (EVar "view")) (EVar "nsEffects")) (EVar "prog"))) (DoExpr (EApp (EVar "indexExports") (ERecordCreate "ModuleExports" ((fa "modId" (EVar "modId")) (fa "expValues" (EBinOp "++" (EBinOp "++" (EVar "values") (EVar "ifaceVals")) (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsValues")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expTypes" (EBinOp "++" (EVar "types") (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsTypes")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expAbstractData" (EBinOp "++" (EApp (EApp (EApp (EVar "directUnder") (EVar "view")) (EVar "nsAbstractData")) (EVar "prog")) (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsAbstractData")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expCtors" (EBinOp "++" (EVar "ctors") (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsCtors")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expTypeCtors" (EBinOp "++" (EApp (EApp (EApp (EVar "directUnder") (EVar "view")) (EVar "nsTypeCtors")) (EVar "prog")) (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsTypeCtors")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expFieldOwners" (EBinOp "++" (EApp (EApp (EApp (EVar "directUnder") (EVar "view")) (EVar "nsFieldOwners")) (EVar "prog")) (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsFieldOwners")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expInterfaces" (EBinOp "++" (EVar "ifaces") (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsInterfaces")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expIfaceMethods" (EBinOp "++" (EApp (EApp (EApp (EVar "directUnder") (EVar "view")) (EVar "nsIfaceMethods")) (EVar "prog")) (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsIfaceMethods")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expIfaceOrigins" (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EVar "modId")))) (EVar "ifaces")) (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsIfaceOrigins")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expTypeOrigins" (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EVar "modId")))) (EVar "types")) (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsTypeOrigins")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expCtorOrigins" (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EVar "modId")))) (EVar "ctors")) (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsCtorOrigins")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expValueOrigins" (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (ETuple (EVar "modId") (EVar "n"))))) (EBinOp "++" (EVar "values") (EVar "ifaceVals"))) (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsValueOrigins")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expEffects" (EBinOp "++" (EVar "effects") (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsEffects")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expEffectOrigins" (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EVar "modId")))) (EVar "effects")) (EApp (EApp (EApp (EApp (EVar "carriedIn") (EVar "nsEffectOrigins")) (EVar "coreExp")) (EVar "known")) (EVar "paths")))) (fa "expNewtypeCtors" (EApp (EApp (EApp (EVar "directUnder") (EVar "view")) (EVar "nsNewtypeCtors")) (EVar "prog"))) (fa "expAbstractCtors" (EApp (EApp (EApp (EVar "directUnder") (EVar "view")) (EVar "nsAbstractCtors")) (EVar "prog"))) (fa "nameSet" (EVar "omEmpty")) (fa "ctorTypes" (EVar "omEmpty"))))))))
(DTypeSig true "pubIfaceMethodSets" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "pubIfaceMethodSets" ((PList)) (EListLit))
(DFunDef false "pubIfaceMethodSets" ((PCons (PRec "DInterface" ((rf "pub" (PCon "True")) (rf "methods" None)) true) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodNm")) (EVar "methods")) (EApp (EVar "pubIfaceMethodSets") (EVar "rest"))))
(DFunDef false "pubIfaceMethodSets" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "pubIfaceMethodSets") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "pubIfaceMethodSets" ((PCons PWild (PVar "rest"))) (EApp (EVar "pubIfaceMethodSets") (EVar "rest")))
(DTypeSig true "reexportBindings" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportBindings" ((PCon "UseName" (PVar "ns")) PWild) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EBlock (DoLet false false (PVar "n") (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EVar "last") (EVar "ns")))) (DoExpr (EListLit (ETuple (EVar "n") (EVar "n"))))) (EListLit)))
(DFunDef false "reexportBindings" ((PCon "UseGroup" PWild (PVar "members")) (PVar "src")) (EApp (EApp (EMethodRef "map") (EVar "dropLocOfExpanded")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "expandMemberNames") (EVar "src"))) (EVar "members"))))
(DFunDef false "reexportBindings" ((PCon "UseWild" PWild) (PVar "src")) (EApp (EApp (EMethodRef "map") (EVar "selfBinding")) (EBinOp "++" (EFieldAccess (EVar "src") "expValues") (EApp (EVar "dedup") (EBinOp "++" (EBinOp "++" (EFieldAccess (EVar "src") "expTypes") (EFieldAccess (EVar "src") "expCtors")) (EFieldAccess (EVar "src") "expInterfaces"))))))
(DFunDef false "reexportBindings" ((PCon "UseAlias" PWild PWild) PWild) (EListLit))
(DTypeSig false "dropLocOfExpanded" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Loc")) (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "dropLocOfExpanded" ((PTuple (PVar "origin") (PVar "local") PWild)) (ETuple (EVar "origin") (EVar "local")))
(DTypeSig true "privilegedCarry" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "ModuleExports") (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "privilegedCarry" ((PVar "exported") (PVar "full") (PVar "path")) (EApp (EVar "dedup") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "ns")) (EApp (EApp (EApp (EApp (EVar "carriedOnlyBy") (EVar "ns")) (EVar "exported")) (EVar "full")) (EVar "path")))) (EListLit (EVar "nsValues") (EVar "nsTypes") (EVar "nsCtors") (EVar "nsInterfaces") (EVar "nsEffects")))))
(DTypeSig false "carriedOnlyBy" (TyFun (TyApp (TyCon "ExpNs") (TyCon "String")) (TyFun (TyCon "ModuleExports") (TyFun (TyCon "ModuleExports") (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "carriedOnlyBy" ((PVar "ns") (PVar "exported") (PVar "full") (PVar "path")) (EBlock (DoLet false false (PVar "viaExports") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EFieldAccess (EVar "ns") "nsCarry") (EVar "path")) (EVar "exported"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "viaExports"))))) (EApp (EApp (EFieldAccess (EVar "ns") "nsCarry") (EVar "path")) (EVar "full"))))))
(DTypeSig false "localsExportedFrom" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "localsExportedFrom" ((PVar "origins") (PVar "bindings")) (EBlock (DoLet false false (PVar "dom") (EApp (EApp (EVar "omFromNames") (EVar "origins")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "b"))) (EVar "dom")))) (EVar "bindings"))))))
(DTypeSig false "carriedValuesFrom" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "carriedValuesFrom" ((PVar "src") (PVar "bindings")) (EBinOp "++" (EApp (EApp (EVar "localsExportedFrom") (EFieldAccess (EVar "src") "expValues")) (EVar "bindings")) (EApp (EApp (EVar "carriedIfaceVals") (EVar "src")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "bindings")))))
(DTypeSig false "carriedIfaceVals" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "carriedIfaceVals" ((PVar "src") (PVar "origins")) (EMatch (EApp (EApp (EVar "filterInSet") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "src") "expInterfaces")) (EVar "omEmpty"))) (EVar "origins")) (arm (PList) () (EListLit)) (arm (PVar "carried") () (EBlock (DoLet false false (PVar "values") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "src") "expValues")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "n")) (EApp (EApp (EVar "filterInSet") (EVar "values")) (EApp (EApp (EVar "ifaceMethodsOf") (EVar "n")) (EFieldAccess (EVar "src") "expIfaceMethods"))))) (EVar "carried")))))))
(DTypeSig false "carriedTypeCtorsFrom" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "carriedTypeCtorsFrom" ((PVar "src") (PVar "carried")) (EBlock (DoLet false false (PVar "carriedSet") (EApp (EApp (EVar "omFromNames") (EVar "carried")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EVar "carriedTypeCtors") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "filterInSet") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "src") "expTypes")) (EVar "omEmpty"))) (EVar "carried"))) (EVar "omEmpty"))) (EVar "carriedSet")) (EFieldAccess (EVar "src") "expTypeCtors")))))
(DTypeSig false "carriedTypeCtors" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "carriedTypeCtors" (PWild PWild (PList)) (EListLit))
(DFunDef false "carriedTypeCtors" ((PVar "types") (PVar "carried") (PCons (PTuple (PVar "t") (PVar "cs")) (PVar "rest"))) (EIf (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "t")) (EVar "types"))) (EApp (EApp (EApp (EVar "carriedTypeCtors") (EVar "types")) (EVar "carried")) (EVar "rest")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "kept") (EApp (EApp (EVar "filterInSet") (EVar "carried")) (EVar "cs"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "kept")) (EApp (EApp (EApp (EVar "carriedTypeCtors") (EVar "types")) (EVar "carried")) (EVar "rest")) (EBinOp "::" (ETuple (EVar "t") (EVar "kept")) (EApp (EApp (EApp (EVar "carriedTypeCtors") (EVar "types")) (EVar "carried")) (EVar "rest")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reexportOrigins" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reexportOrigins" ((PVar "path") (PVar "src")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))
(DTypeSig false "ifaceMethodPairs" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ifaceMethodPairs" (PWild (PList)) (EListLit))
(DFunDef false "ifaceMethodPairs" ((PVar "src") (PCons (PVar "i") (PVar "rest"))) (EBinOp "::" (ETuple (EVar "i") (EApp (EApp (EVar "ifaceMethodsOf") (EVar "i")) (EFieldAccess (EVar "src") "expIfaceMethods"))) (EApp (EApp (EVar "ifaceMethodPairs") (EVar "src")) (EVar "rest"))))
(DTypeSig false "ownersForTypes" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "ownersForTypes" (PWild (PList)) (EListLit))
(DFunDef false "ownersForTypes" ((PVar "types") (PCons (PTuple (PVar "f") (PVar "o")) (PVar "rest"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "o")) (EVar "types")) (EBinOp "::" (ETuple (EVar "f") (EVar "o")) (EApp (EApp (EVar "ownersForTypes") (EVar "types")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "ownersForTypes") (EVar "types")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "overPubUse" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyVar "b")))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyVar "b")))))))
(DFunDef false "overPubUse" ((PVar "coreExp") (PVar "known") (PVar "f") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EApp (EApp (EVar "f") (EVar "path")) (EVar "coreExp")) (EMatch (EApp (EApp (EVar "findExports") (EVar "mid")) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EVar "f") (EVar "path")) (EVar "src"))))))))
