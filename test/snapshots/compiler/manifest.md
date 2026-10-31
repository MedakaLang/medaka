# META
source_lines=153
stages=DESUGAR,MARK
# SOURCE
{- manifest.mdk — typed accessors for `medaka.toml`'s own schema.

   `medaka.toml`'s field layout is the COMPILER's business, not the standard
   library's (I-1): a user reading `docs/stdlib/toml.md` should find a general
   TOML reader, not four functions about a file format they may never write.
   These accessors live here rather than in `stdlib/toml.mdk`, and must
   not move back.

   The ruling that put them here is "manifest-schema accessors do not live in
   a general TOML module", so this file stays correct whichever general module
   supplies `Toml`/`getString`/`getArray` — `stdlib/toml.mdk` today, `parsec`
   if #2240 retires it.

   Note that `compiler/driver/loader.mdk` still reads `medaka.toml`'s
   `[foreign-libraries]` with its own line scanner rather than through this
   module; that is deliberate (the loader is on the hot path and importing
   `toml` would drag the `Toml` type and its impls into dispatch scope for
   every compile — [T-STDLIB-IMPORT]), not an oversight. -}

import toml.{Toml(..), TomlValue(..), getString, getArray, parse}
import list.{lookup}
import string.{startsWith, lines}

{- | `name` from a parsed `[package]` section, or `None` when it is absent.

   > packageName (okDoc "[package]\nname = \"my-project\"\nversion = \"0.1.0\"")
   Some "my-project"

   > packageName (okDoc "[package]\nversion = \"0.1.0\"")
   None -}
export
packageName : Toml -> Option String
packageName doc = getString "package.name" doc

{- | `version` from a parsed `[package]` section, or `None` when it is absent.

   > packageVersion (okDoc "[package]\nname = \"x\"\nversion = \"2.3.4\"")
   Some "2.3.4"

   > packageVersion (okDoc "[package]\nname = \"x\"")
   None -}
export
packageVersion : Toml -> Option String
packageVersion doc = getString "package.version" doc

{- | `entry` from a parsed `[package]` section, or `None` when it is absent.

   > packageEntry (okDoc "[package]\nname = \"x\"\nentry = \"src/main.mdk\"")
   Some "src/main.mdk"

   > packageEntry (okDoc "[package]\nname = \"x\"")
   None -}
export
packageEntry : Toml -> Option String
packageEntry doc = getString "package.entry" doc

{- | `members` from a parsed `[workspace]` section, or `None` when there is no
   `[workspace]` section.

   > workspaceMembers (okDoc "[workspace]\nmembers = [\"pkgs/core\", \"pkgs/net\"]")
   Some ["pkgs/core", "pkgs/net"]

   > workspaceMembers (okDoc "[package]\nname = \"x\"")
   None -}
export
workspaceMembers : Toml -> Option (List String)
workspaceMembers doc = getArray "workspace.members" doc

{- | `profile` from a parsed `[target]` section, `Ok None` when the manifest
   states no `[target]` key at all, and `Err` with the reason when it states
   one but no profile can be read from it.  A target that cannot be read is
   never treated as no target.

   > targetProfile (okDoc "[target]\nprofile = \"wasmgc/edge\"")
   Ok (Some "wasmgc/edge")

   > targetProfile (okDoc "[package]\nname = \"x\"")
   Ok None

   > targetProfile (okDoc "[target]\nprofile = 42")
   Err "`profile` is not a string; write a profile name, such as `profile = \"wasmgc/node\"`"

   > targetProfile (okDoc "[target]\nprofil = \"wasmgc/node\"")
   Err "it states no `profile`; write one, such as `profile = \"wasmgc/node\"`" -}
export
targetProfile : Toml -> Result String (Option String)
targetProfile (Toml kvs) =
  match filter (kv => startsWith "target." (fst kv)) kvs
    [] => Ok None
    stated => match lookup "target.profile" stated
      Some (TString p) => Ok (Some p)
      Some _ =>
        Err
          "`profile` is not a string; write a profile name, such as `profile = \"wasmgc/node\"`"
      None =>
        Err
          "it states no `profile`; write one, such as `profile = \"wasmgc/node\"`"

{- | True if the manifest text has a `[target]` header line.  A manifest the
   TOML subset reader rejects is only a `[target]` refusal when it states one;
   otherwise its other readers (`allow-internal`, the loader's scanner) keep
   their own verdicts on it.

   > statesTargetSection "[package]\nname = \"x\"\n[target]\nprofile = \"a\""
   True

   > statesTargetSection "[package]\nname = \"x\"\nallow-internal = true-ish"
   False

   > statesTargetSection "[target.extra]\nk = 1"
   True -}
export
statesTargetSection : String -> Bool
statesTargetSection text =
  any (l => startsWith "[target" (asciiTrim l)) (lines text)

-- Doctest helper: parse a known-good TOML source.  A parse failure here would
-- be a bug in the fixture, not in the accessor under test, so it panics rather
-- than degrading the doctest to a `None` that looks like an absent key.
okDoc : String -> Toml
okDoc src = match parse src
  Ok doc => doc
  Err e =>
    panic (stringConcat ["manifest doctest fixture failed to parse: ", e])

-- Trims ASCII whitespace only. medaka.toml is TOML, whose whitespace is tab and space.
-- A non-ASCII space such as U+00A0 is data here, so `string.trim` (which strips
-- it) would be wrong.
asciiTrim : String -> String
-- The same few lines live in each package that needs a spec-bound trim; the
-- packages share no module that could host them, and string must not export it.
-- lint-disable-next-line rule-stdlib-reimpl, rule-duplicate-body
asciiTrim s =
  let chars = stringToChars s
  let n = arrayLength chars
  let lo = asciiTrimFront chars 0 n
  stringSlice lo (asciiTrimBack chars (n - 1) lo + 1) s

asciiTrimFront : Array Char -> Int -> Int -> Int
-- Part of asciiTrim, duplicated with it for the same reason.
-- lint-disable-next-line rule-duplicate-body
asciiTrimFront chars i n
  | i >= n = n
  | charIsSpace chars[i] = asciiTrimFront chars (i + 1) n
  | otherwise = i

asciiTrimBack : Array Char -> Int -> Int -> Int
-- Part of asciiTrim, duplicated with it for the same reason.
-- lint-disable-next-line rule-duplicate-body
asciiTrimBack chars i lo
  | i < lo = lo - 1
  | charIsSpace chars[i] = asciiTrimBack chars (i - 1) lo
  | otherwise = i
# DESUGAR
(DUse false (UseGroup ("toml") ((mem "Toml" true) (mem "TomlValue" true) (mem "getString" false) (mem "getArray" false) (mem "parse" false))))
(DUse false (UseGroup ("list") ((mem "lookup" false))))
(DUse false (UseGroup ("string") ((mem "startsWith" false) (mem "lines" false))))
(DTypeSig true "packageName" (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "packageName" ((PVar "doc")) (EApp (EApp (EVar "getString") (ELit (LString "package.name"))) (EVar "doc")))
(DTypeSig true "packageVersion" (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "packageVersion" ((PVar "doc")) (EApp (EApp (EVar "getString") (ELit (LString "package.version"))) (EVar "doc")))
(DTypeSig true "packageEntry" (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "packageEntry" ((PVar "doc")) (EApp (EApp (EVar "getString") (ELit (LString "package.entry"))) (EVar "doc")))
(DTypeSig true "workspaceMembers" (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "workspaceMembers" ((PVar "doc")) (EApp (EApp (EVar "getArray") (ELit (LString "workspace.members"))) (EVar "doc")))
(DTypeSig true "targetProfile" (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "targetProfile" ((PCon "Toml" (PVar "kvs"))) (EMatch (EApp (EApp (EVar "filter") (ELam ((PVar "kv")) (EApp (EApp (EVar "startsWith") (ELit (LString "target."))) (EApp (EVar "fst") (EVar "kv"))))) (EVar "kvs")) (arm (PList) () (EApp (EVar "Ok") (EVar "None"))) (arm (PVar "stated") () (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "target.profile"))) (EVar "stated")) (arm (PCon "Some" (PCon "TString" (PVar "p"))) () (EApp (EVar "Ok") (EApp (EVar "Some") (EVar "p")))) (arm (PCon "Some" PWild) () (EApp (EVar "Err") (ELit (LString "`profile` is not a string; write a profile name, such as `profile = \"wasmgc/node\"`")))) (arm (PCon "None") () (EApp (EVar "Err") (ELit (LString "it states no `profile`; write one, such as `profile = \"wasmgc/node\"`"))))))))
(DTypeSig true "statesTargetSection" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "statesTargetSection" ((PVar "text")) (EApp (EApp (EVar "any") (ELam ((PVar "l")) (EApp (EApp (EVar "startsWith") (ELit (LString "[target"))) (EApp (EVar "asciiTrim") (EVar "l"))))) (EApp (EVar "lines") (EVar "text"))))
(DTypeSig false "okDoc" (TyFun (TyCon "String") (TyCon "Toml")))
(DFunDef false "okDoc" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Ok" (PVar "doc")) () (EVar "doc")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "panic") (EApp (EVar "stringConcat") (EListLit (ELit (LString "manifest doctest fixture failed to parse: ")) (EVar "e")))))))
(DTypeSig false "asciiTrim" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "asciiTrim" ((PVar "s")) (EBlock (DoLet false false (PVar "chars") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "chars"))) (DoLet false false (PVar "lo") (EApp (EApp (EApp (EVar "asciiTrimFront") (EVar "chars")) (ELit (LInt 0))) (EVar "n"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (EVar "lo")) (EBinOp "+" (EApp (EApp (EApp (EVar "asciiTrimBack") (EVar "chars")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "lo")) (ELit (LInt 1)))) (EVar "s")))))
(DTypeSig false "asciiTrimFront" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "asciiTrimFront" ((PVar "chars") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "n") (EIf (EApp (EVar "charIsSpace") (EApp (EApp (EVar "index") (EVar "chars")) (EVar "i"))) (EApp (EApp (EApp (EVar "asciiTrimFront") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "asciiTrimBack" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "asciiTrimBack" ((PVar "chars") (PVar "i") (PVar "lo")) (EIf (EBinOp "<" (EVar "i") (EVar "lo")) (EBinOp "-" (EVar "lo") (ELit (LInt 1))) (EIf (EApp (EVar "charIsSpace") (EApp (EApp (EVar "index") (EVar "chars")) (EVar "i"))) (EApp (EApp (EApp (EVar "asciiTrimBack") (EVar "chars")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "lo")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
# MARK
(DUse false (UseGroup ("toml") ((mem "Toml" true) (mem "TomlValue" true) (mem "getString" false) (mem "getArray" false) (mem "parse" false))))
(DUse false (UseGroup ("list") ((mem "lookup" false))))
(DUse false (UseGroup ("string") ((mem "startsWith" false) (mem "lines" false))))
(DTypeSig true "packageName" (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "packageName" ((PVar "doc")) (EApp (EApp (EVar "getString") (ELit (LString "package.name"))) (EVar "doc")))
(DTypeSig true "packageVersion" (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "packageVersion" ((PVar "doc")) (EApp (EApp (EVar "getString") (ELit (LString "package.version"))) (EVar "doc")))
(DTypeSig true "packageEntry" (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "packageEntry" ((PVar "doc")) (EApp (EApp (EVar "getString") (ELit (LString "package.entry"))) (EVar "doc")))
(DTypeSig true "workspaceMembers" (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "workspaceMembers" ((PVar "doc")) (EApp (EApp (EVar "getArray") (ELit (LString "workspace.members"))) (EVar "doc")))
(DTypeSig true "targetProfile" (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "targetProfile" ((PCon "Toml" (PVar "kvs"))) (EMatch (EApp (EApp (EMethodRef "filter") (ELam ((PVar "kv")) (EApp (EApp (EVar "startsWith") (ELit (LString "target."))) (EApp (EVar "fst") (EVar "kv"))))) (EVar "kvs")) (arm (PList) () (EApp (EVar "Ok") (EVar "None"))) (arm (PVar "stated") () (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "target.profile"))) (EVar "stated")) (arm (PCon "Some" (PCon "TString" (PVar "p"))) () (EApp (EVar "Ok") (EApp (EVar "Some") (EVar "p")))) (arm (PCon "Some" PWild) () (EApp (EVar "Err") (ELit (LString "`profile` is not a string; write a profile name, such as `profile = \"wasmgc/node\"`")))) (arm (PCon "None") () (EApp (EVar "Err") (ELit (LString "it states no `profile`; write one, such as `profile = \"wasmgc/node\"`"))))))))
(DTypeSig true "statesTargetSection" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "statesTargetSection" ((PVar "text")) (EApp (EApp (EDictApp "any") (ELam ((PVar "l")) (EApp (EApp (EVar "startsWith") (ELit (LString "[target"))) (EApp (EVar "asciiTrim") (EVar "l"))))) (EApp (EVar "lines") (EVar "text"))))
(DTypeSig false "okDoc" (TyFun (TyCon "String") (TyCon "Toml")))
(DFunDef false "okDoc" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Ok" (PVar "doc")) () (EVar "doc")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "panic") (EApp (EVar "stringConcat") (EListLit (ELit (LString "manifest doctest fixture failed to parse: ")) (EVar "e")))))))
(DTypeSig false "asciiTrim" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "asciiTrim" ((PVar "s")) (EBlock (DoLet false false (PVar "chars") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "chars"))) (DoLet false false (PVar "lo") (EApp (EApp (EApp (EVar "asciiTrimFront") (EVar "chars")) (ELit (LInt 0))) (EVar "n"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (EVar "lo")) (EBinOp "+" (EApp (EApp (EApp (EVar "asciiTrimBack") (EVar "chars")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "lo")) (ELit (LInt 1)))) (EVar "s")))))
(DTypeSig false "asciiTrimFront" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "asciiTrimFront" ((PVar "chars") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "n") (EIf (EApp (EVar "charIsSpace") (EApp (EApp (EMethodRef "index") (EVar "chars")) (EVar "i"))) (EApp (EApp (EApp (EVar "asciiTrimFront") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "asciiTrimBack" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "asciiTrimBack" ((PVar "chars") (PVar "i") (PVar "lo")) (EIf (EBinOp "<" (EVar "i") (EVar "lo")) (EBinOp "-" (EVar "lo") (ELit (LInt 1))) (EIf (EApp (EVar "charIsSpace") (EApp (EApp (EMethodRef "index") (EVar "chars")) (EVar "i"))) (EApp (EApp (EApp (EVar "asciiTrimBack") (EVar "chars")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "lo")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
