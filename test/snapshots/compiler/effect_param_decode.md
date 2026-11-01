# META
source_lines=224
stages=DESUGAR,MARK
# SOURCE
-- Written effect parameters decoded against declared domains, without inference state.
import frontend.ast.{EffParamTy(..)}
import types.effect_domain.{
  Param(..), canonParam, subTopOf, lookupAxis, productPrimaryLift, productOver
}
import types.effect_rows.{
  EffLabel, Atom, labelKey, builtinLabel, atomWith, effLabelName
}
import support.util.{sortUniqS, filterList, reverseL, contains, joinWith}

lookupDomain : String -> List (String, Param) -> Param
lookupDomain _ [] = PUnit
lookupDomain l ((k, p) :: rest) = if l == k then p else lookupDomain l rest

-- `dtopFor` over the effect domains [domains] a drive left (`doEffectDomains`).
export
dtopIn : List (String, Param) -> EffLabel -> Param
dtopIn domains label = match lookupDomain (labelKey label) domains
  PPrefix None => PPrefix None
  PPath None => PPath None
  PSet None => PSet None
  p@(PProduct _) => p
  _ => PUnit

-- lift one of the language's own labels to its ⊤-param atom, under the effect
-- domains [domains] (`doEffectDomains` of the drive that registered them; `[]`
-- before any drive)
export
atomOfLabel : List (String, Param) -> String -> Atom
atomOfLabel domains l =
  atomWith (builtinLabel l) (dtopIn domains (builtinLabel l))

export
writtenParam : Param -> EffParamTy -> Param
writtenParam top EPTop = top
writtenParam (PPrefix None) (EPLit s) = canonParam (PPrefix (Some s))
writtenParam (PPath None) (EPLit s) = canonParam (PPath (Some s))
writtenParam (PSet None) (EPLit s) = PSet (Some [s])
writtenParam (PSet None) (EPSet xs) = PSet (Some (sortUniqS xs))
writtenParam (PProduct schema) (EPLit s) = productPrimaryLift schema s
writtenParam (PProduct schema) (EPProduct axes) =
  productOver schema (map writtenAxis axes)
writtenParam top _ = top

-- An axis as the schema check reads it: a named argument stands for any
-- value of its axis, and its binder is checked where it is bound.
checkedAxis : List (String, Param) -> (String, EffParamTy) -> (String, Param)
checkedAxis schema (name, EPName _) = match lookupAxis name schema
  Some top => (name, subTopOf top)
  None => (name, PUnit)
checkedAxis _ a = writtenAxis a

export
writtenAxis : (String, EffParamTy) -> (String, Param)
writtenAxis (name, EPLit s) = (name, PPrefix (Some s))
writtenAxis (name, EPSet xs) = (name, PSet (Some (sortUniqS xs)))
writtenAxis (name, _) = (name, PUnit)

-- A Set-domain written param is carried in the `Option String` carrier as a
-- brace-delimited, comma-separated literal `{a,b,c}` (the parser's `effParamFor`
-- TLBrace clause builds exactly this).  Decode it back to the element list.
-- (Keeps the carrier type `Option String`, so no AST `TyEffect` ripple.)
export
decodeSetParam : String -> List String
decodeSetParam s =
  let n = stringLength s
  if n >= 2 && stringSlice 0 1 s == "{" && stringSlice (n - 1) n s == "}" then
    sortUniqS (filterList (/= "") (splitOnComma (stringSlice 1 (n - 1) s)))
  else
    sortUniqS (filterList (/= "") (splitOnComma s))

-- split a string on ',' (Set-element separator; authority tokens contain none)
splitOnComma : String -> List String
splitOnComma s = splitOnCommaGo s 0 0 []

splitOnCommaGo : String -> Int -> Int -> List String -> List String
splitOnCommaGo s start i acc =
  let n = stringLength s
  if i >= n then
    reverseL (stringSlice start n s :: acc)
  else if stringSlice i (i + 1) s == "," then
    splitOnCommaGo s (i + 1) (i + 1) (stringSlice start i s :: acc)
  else
    splitOnCommaGo s start (i + 1) acc

-- A written Prefix element is any non-empty string.  A trailing `*` makes it a
-- pattern; without one it is an exact element and admits only itself, so no
-- delimiter is needed to keep a sibling host or path out.  The empty string is
-- the prefix of everything and would silently mean the whole domain.
prefixPatternOk : String -> Bool
prefixPatternOk s = stringLength s > 0

-- v2 Stage 2a: diagnostic for a rejected written effect param.
export
effectParamMsg : String -> String -> String
effectParamMsg label why = "invalid effect parameter on <\{label}>: \{why}"

-- The refusal for an empty Prefix element, parameterized by the noun (`pattern`
-- for a top-level Prefix param, `<axis> pattern` for a product axis).
prefixPatternErrMsg : String -> String
prefixPatternErrMsg noun =
  "\{noun} is empty; name the element, or write the bare label for the whole domain"

-- The problems a written parameter has as an element of the domain whose top
-- is [top], each a message; empty when it is an element.  One rule for every
-- consumer: the typechecker reports them at the atom, and `check-policy`
-- refuses an `--allow` entry that has any, so a policy is read exactly as a
-- source atom is.
export
effectParamProblems : String -> Param -> EffParamTy -> List String
effectParamProblems l PUnit (EPName _) = [atomicLabelParamText l]
effectParamProblems _ _ (EPName _) = []
effectParamProblems _ _ EPTop = []
effectParamProblems l (PPrefix None) (EPLit pat) = prefixLiteralProblems l pat
effectParamProblems l (PPath None) (EPLit pat) = prefixLiteralProblems l pat
effectParamProblems _ (PSet None) (EPLit _) = []
-- A bare literal on a Product label lifts into the first axis as the
-- domain does (`productPrimaryLift`): a prefix pattern for a Prefix axis, a
-- one-element set for a Set axis.
effectParamProblems _l (PProduct schema) (EPLit pat) =
  primaryLiteralProblems schema pat
    ++ productAxesProblems schema (productPrimaryLift schema pat)
effectParamProblems l _ (EPLit _) = [atomicLabelParamText l]
-- A set's size is a bound's business (`writtenSetProblem`), checked with the
-- other elements its label writes.
effectParamProblems _ (PSet None) (EPSet _) = []
effectParamProblems l (PPrefix None) (EPSet _) =
  ["label `\{l}` takes a prefix pattern, not a set"]
effectParamProblems l (PPath None) (EPSet _) =
  ["label `\{l}` takes a prefix pattern, not a set"]
effectParamProblems l (PProduct _) (EPSet _) = [
  "label `\{l}` takes named axes such as `Host=... Method=...`, not a bare set",
]
effectParamProblems l _ (EPSet _) = [atomicLabelParamText l]
effectParamProblems _ (PProduct schema) (EPProduct axes) =
  map repeatedAxisText (repeatedNames (map fst axes) [])
    ++ productAxesProblems schema (PProduct (map (checkedAxis schema) axes))
effectParamProblems l PUnit (EPProduct _) = [atomicLabelParamText l]
effectParamProblems l _ (EPProduct _) =
  ["label `\{l}` is not a product domain and takes no axes"]

-- A written parameter as an element of [label]'s declared domain, or the
-- first problem that keeps it from being one (`effectParamMsg`'s wording).
-- Never the domain's top for a malformed parameter: a consumer reading an
-- allowance would otherwise widen it.
export
decodeWrittenParam : List (String, Param) ->
  EffLabel ->
  EffParamTy ->
  Result String Param
decodeWrittenParam domains label p =
  let top = dtopIn domains label
  match effectParamProblems (effLabelName label) top p
    [] => Ok (writtenParam top p)
    m :: _ => Err (effectParamMsg (effLabelName label) m)

-- An FFI parameter names a LIBRARY, not a host or path.  `<FFI "libcurl">`
-- read as a prefix is what the author meant, and `prefixConcrete` strips a
-- trailing `*`, so `dsub` cannot tell the two spellings apart.  FFI keeps its
-- own empty-string message, which names a library.
prefixLiteralProblems : String -> String -> List String
prefixLiteralProblems l pat =
  if l == "FFI" then
    if stringLength pat > 0 then
      []
    else
      ["the library pattern is empty; name the library, `<FFI \"curl\">`"]
  else if prefixPatternOk pat then
    []
  else
    [prefixPatternErrMsg "pattern"]

export
atomicLabelParamText : String -> String
atomicLabelParamText l =
  "label `\{l}` is atomic and takes no parameter; declare it `effect \{l} Prefix` to parameterize it"

-- A bare literal is checked as the first axis's value BEFORE it is lifted:
-- the lift canonicalises it, and an empty pattern canonicalises to the top.
primaryLiteralProblems : List (String, Param) -> String -> List String
primaryLiteralProblems ((name, PPrefix _) :: _) pat =
  if prefixPatternOk pat then [] else [prefixPatternErrMsg "\{name} pattern"]
primaryLiteralProblems _ _ = []

-- A written product's axes against the label's declared schema: every axis
-- must be declared, a Prefix axis takes a non-empty pattern or exact element, a Set
-- axis a set.
productAxesProblems : List (String, Param) -> Param -> List String
productAxesProblems schema (PProduct axes) =
  flatMap (a => axisProblems schema (fst a) (snd a)) axes
productAxesProblems _ _ = []

-- One element of a Product has one value on each axis; two values are two
-- elements, written as two.
repeatedAxisText : String -> String
repeatedAxisText name =
  "axis `\{name}` is written twice; write each value as its own element"

-- The names that occur more than once, each once, in first-occurrence order.
export
repeatedNames : List String -> List String -> List String
repeatedNames [] _ = []
repeatedNames (n :: rest) seen
  | contains n seen = repeatedNames rest seen
  | contains n rest = n :: repeatedNames rest (n :: seen)
  | otherwise = repeatedNames rest seen

axisProblems : List (String, Param) -> String -> Param -> List String
axisProblems schema name p = match lookupAxis name schema
  None => [
    "unknown product axis `\{name}`; declared axes: \{joinWith ", " (map fst schema)}",
  ]
  Some (PPrefix _) => match p
    PPrefix (Some pat) =>
      if prefixPatternOk pat then
        []
      else
        [prefixPatternErrMsg "\{name} pattern"]
    PPrefix None => []
    _ => ["axis `\{name}` takes a prefix pattern, not a set"]
  Some (PSet _) => match p
    PSet _ => []
    _ => ["axis `\{name}` takes a set, not a pattern"]
  Some _ => []
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "EffParamTy" true))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true) (mem "canonParam" false) (mem "subTopOf" false) (mem "lookupAxis" false) (mem "productPrimaryLift" false) (mem "productOver" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffLabel" false) (mem "Atom" false) (mem "labelKey" false) (mem "builtinLabel" false) (mem "atomWith" false) (mem "effLabelName" false))))
(DUse false (UseGroup ("support" "util") ((mem "sortUniqS" false) (mem "filterList" false) (mem "reverseL" false) (mem "contains" false) (mem "joinWith" false))))
(DTypeSig false "lookupDomain" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "Param"))))
(DFunDef false "lookupDomain" (PWild (PList)) (EVar "PUnit"))
(DFunDef false "lookupDomain" ((PVar "l") (PCons (PTuple (PVar "k") (PVar "p")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "l") (EVar "k")) (EVar "p") (EApp (EApp (EVar "lookupDomain") (EVar "l")) (EVar "rest"))))
(DTypeSig true "dtopIn" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "EffLabel") (TyCon "Param"))))
(DFunDef false "dtopIn" ((PVar "domains") (PVar "label")) (EMatch (EApp (EApp (EVar "lookupDomain") (EApp (EVar "labelKey") (EVar "label"))) (EVar "domains")) (arm (PCon "PPrefix" (PCon "None")) () (EApp (EVar "PPrefix") (EVar "None"))) (arm (PCon "PPath" (PCon "None")) () (EApp (EVar "PPath") (EVar "None"))) (arm (PCon "PSet" (PCon "None")) () (EApp (EVar "PSet") (EVar "None"))) (arm (PAs "p" (PCon "PProduct" PWild)) () (EVar "p")) (arm PWild () (EVar "PUnit"))))
(DTypeSig true "atomOfLabel" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "String") (TyCon "Atom"))))
(DFunDef false "atomOfLabel" ((PVar "domains") (PVar "l")) (EApp (EApp (EVar "atomWith") (EApp (EVar "builtinLabel") (EVar "l"))) (EApp (EApp (EVar "dtopIn") (EVar "domains")) (EApp (EVar "builtinLabel") (EVar "l")))))
(DTypeSig true "writtenParam" (TyFun (TyCon "Param") (TyFun (TyCon "EffParamTy") (TyCon "Param"))))
(DFunDef false "writtenParam" ((PVar "top") (PCon "EPTop")) (EVar "top"))
(DFunDef false "writtenParam" ((PCon "PPrefix" (PCon "None")) (PCon "EPLit" (PVar "s"))) (EApp (EVar "canonParam") (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s")))))
(DFunDef false "writtenParam" ((PCon "PPath" (PCon "None")) (PCon "EPLit" (PVar "s"))) (EApp (EVar "canonParam") (EApp (EVar "PPath") (EApp (EVar "Some") (EVar "s")))))
(DFunDef false "writtenParam" ((PCon "PSet" (PCon "None")) (PCon "EPLit" (PVar "s"))) (EApp (EVar "PSet") (EApp (EVar "Some") (EListLit (EVar "s")))))
(DFunDef false "writtenParam" ((PCon "PSet" (PCon "None")) (PCon "EPSet" (PVar "xs"))) (EApp (EVar "PSet") (EApp (EVar "Some") (EApp (EVar "sortUniqS") (EVar "xs")))))
(DFunDef false "writtenParam" ((PCon "PProduct" (PVar "schema")) (PCon "EPLit" (PVar "s"))) (EApp (EApp (EVar "productPrimaryLift") (EVar "schema")) (EVar "s")))
(DFunDef false "writtenParam" ((PCon "PProduct" (PVar "schema")) (PCon "EPProduct" (PVar "axes"))) (EApp (EApp (EVar "productOver") (EVar "schema")) (EApp (EApp (EVar "map") (EVar "writtenAxis")) (EVar "axes"))))
(DFunDef false "writtenParam" ((PVar "top") PWild) (EVar "top"))
(DTypeSig false "checkedAxis" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyTuple (TyCon "String") (TyCon "EffParamTy")) (TyTuple (TyCon "String") (TyCon "Param")))))
(DFunDef false "checkedAxis" ((PVar "schema") (PTuple (PVar "name") (PCon "EPName" PWild))) (EMatch (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "schema")) (arm (PCon "Some" (PVar "top")) () (ETuple (EVar "name") (EApp (EVar "subTopOf") (EVar "top")))) (arm (PCon "None") () (ETuple (EVar "name") (EVar "PUnit")))))
(DFunDef false "checkedAxis" (PWild (PVar "a")) (EApp (EVar "writtenAxis") (EVar "a")))
(DTypeSig true "writtenAxis" (TyFun (TyTuple (TyCon "String") (TyCon "EffParamTy")) (TyTuple (TyCon "String") (TyCon "Param"))))
(DFunDef false "writtenAxis" ((PTuple (PVar "name") (PCon "EPLit" (PVar "s")))) (ETuple (EVar "name") (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s")))))
(DFunDef false "writtenAxis" ((PTuple (PVar "name") (PCon "EPSet" (PVar "xs")))) (ETuple (EVar "name") (EApp (EVar "PSet") (EApp (EVar "Some") (EApp (EVar "sortUniqS") (EVar "xs"))))))
(DFunDef false "writtenAxis" ((PTuple (PVar "name") PWild)) (ETuple (EVar "name") (EVar "PUnit")))
(DTypeSig true "decodeSetParam" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "decodeSetParam" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (ELit (LString "{")))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "s")) (ELit (LString "}")))) (EApp (EVar "sortUniqS") (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (ELit (LString ""))))) (EApp (EVar "splitOnComma") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "s"))))) (EApp (EVar "sortUniqS") (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (ELit (LString ""))))) (EApp (EVar "splitOnComma") (EVar "s"))))))))
(DTypeSig false "splitOnComma" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitOnComma" ((PVar "s")) (EApp (EApp (EApp (EApp (EVar "splitOnCommaGo") (EVar "s")) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)))
(DTypeSig false "splitOnCommaGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "splitOnCommaGo" ((PVar "s") (PVar "start") (PVar "i") (PVar "acc")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "reverseL") (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EVar "n")) (EVar "s")) (EVar "acc"))) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "s")) (ELit (LString ","))) (EApp (EApp (EApp (EApp (EVar "splitOnCommaGo") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EVar "i")) (EVar "s")) (EVar "acc"))) (EApp (EApp (EApp (EApp (EVar "splitOnCommaGo") (EVar "s")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")))))))
(DTypeSig false "prefixPatternOk" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "prefixPatternOk" ((PVar "s")) (EBinOp ">" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 0))))
(DTypeSig true "effectParamMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "effectParamMsg" ((PVar "label") (PVar "why")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "invalid effect parameter on <")) (EApp (EVar "display") (EVar "label"))) (ELit (LString ">: "))) (EApp (EVar "display") (EVar "why"))) (ELit (LString ""))))
(DTypeSig false "prefixPatternErrMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "prefixPatternErrMsg" ((PVar "noun")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "noun"))) (ELit (LString " is empty; name the element, or write the bare label for the whole domain"))))
(DTypeSig true "effectParamProblems" (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyFun (TyCon "EffParamTy") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "effectParamProblems" ((PVar "l") (PCon "PUnit") (PCon "EPName" PWild)) (EListLit (EApp (EVar "atomicLabelParamText") (EVar "l"))))
(DFunDef false "effectParamProblems" (PWild PWild (PCon "EPName" PWild)) (EListLit))
(DFunDef false "effectParamProblems" (PWild PWild (PCon "EPTop")) (EListLit))
(DFunDef false "effectParamProblems" ((PVar "l") (PCon "PPrefix" (PCon "None")) (PCon "EPLit" (PVar "pat"))) (EApp (EApp (EVar "prefixLiteralProblems") (EVar "l")) (EVar "pat")))
(DFunDef false "effectParamProblems" ((PVar "l") (PCon "PPath" (PCon "None")) (PCon "EPLit" (PVar "pat"))) (EApp (EApp (EVar "prefixLiteralProblems") (EVar "l")) (EVar "pat")))
(DFunDef false "effectParamProblems" (PWild (PCon "PSet" (PCon "None")) (PCon "EPLit" PWild)) (EListLit))
(DFunDef false "effectParamProblems" ((PVar "_l") (PCon "PProduct" (PVar "schema")) (PCon "EPLit" (PVar "pat"))) (EBinOp "++" (EApp (EApp (EVar "primaryLiteralProblems") (EVar "schema")) (EVar "pat")) (EApp (EApp (EVar "productAxesProblems") (EVar "schema")) (EApp (EApp (EVar "productPrimaryLift") (EVar "schema")) (EVar "pat")))))
(DFunDef false "effectParamProblems" ((PVar "l") PWild (PCon "EPLit" PWild)) (EListLit (EApp (EVar "atomicLabelParamText") (EVar "l"))))
(DFunDef false "effectParamProblems" (PWild (PCon "PSet" (PCon "None")) (PCon "EPSet" PWild)) (EListLit))
(DFunDef false "effectParamProblems" ((PVar "l") (PCon "PPrefix" (PCon "None")) (PCon "EPSet" PWild)) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "label `")) (EApp (EVar "display") (EVar "l"))) (ELit (LString "` takes a prefix pattern, not a set")))))
(DFunDef false "effectParamProblems" ((PVar "l") (PCon "PPath" (PCon "None")) (PCon "EPSet" PWild)) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "label `")) (EApp (EVar "display") (EVar "l"))) (ELit (LString "` takes a prefix pattern, not a set")))))
(DFunDef false "effectParamProblems" ((PVar "l") (PCon "PProduct" PWild) (PCon "EPSet" PWild)) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "label `")) (EApp (EVar "display") (EVar "l"))) (ELit (LString "` takes named axes such as `Host=... Method=...`, not a bare set")))))
(DFunDef false "effectParamProblems" ((PVar "l") PWild (PCon "EPSet" PWild)) (EListLit (EApp (EVar "atomicLabelParamText") (EVar "l"))))
(DFunDef false "effectParamProblems" (PWild (PCon "PProduct" (PVar "schema")) (PCon "EPProduct" (PVar "axes"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "repeatedAxisText")) (EApp (EApp (EVar "repeatedNames") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "axes"))) (EListLit))) (EApp (EApp (EVar "productAxesProblems") (EVar "schema")) (EApp (EVar "PProduct") (EApp (EApp (EVar "map") (EApp (EVar "checkedAxis") (EVar "schema"))) (EVar "axes"))))))
(DFunDef false "effectParamProblems" ((PVar "l") (PCon "PUnit") (PCon "EPProduct" PWild)) (EListLit (EApp (EVar "atomicLabelParamText") (EVar "l"))))
(DFunDef false "effectParamProblems" ((PVar "l") PWild (PCon "EPProduct" PWild)) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "label `")) (EApp (EVar "display") (EVar "l"))) (ELit (LString "` is not a product domain and takes no axes")))))
(DTypeSig true "decodeWrittenParam" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "EffLabel") (TyFun (TyCon "EffParamTy") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Param"))))))
(DFunDef false "decodeWrittenParam" ((PVar "domains") (PVar "label") (PVar "p")) (EBlock (DoLet false false (PVar "top") (EApp (EApp (EVar "dtopIn") (EVar "domains")) (EVar "label"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "effectParamProblems") (EApp (EVar "effLabelName") (EVar "label"))) (EVar "top")) (EVar "p")) (arm (PList) () (EApp (EVar "Ok") (EApp (EApp (EVar "writtenParam") (EVar "top")) (EVar "p")))) (arm (PCons (PVar "m") PWild) () (EApp (EVar "Err") (EApp (EApp (EVar "effectParamMsg") (EApp (EVar "effLabelName") (EVar "label"))) (EVar "m"))))))))
(DTypeSig false "prefixLiteralProblems" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "prefixLiteralProblems" ((PVar "l") (PVar "pat")) (EIf (EBinOp "==" (EVar "l") (ELit (LString "FFI"))) (EIf (EBinOp ">" (EApp (EVar "stringLength") (EVar "pat")) (ELit (LInt 0))) (EListLit) (EListLit (ELit (LString "the library pattern is empty; name the library, `<FFI \"curl\">`")))) (EIf (EApp (EVar "prefixPatternOk") (EVar "pat")) (EListLit) (EListLit (EApp (EVar "prefixPatternErrMsg") (ELit (LString "pattern")))))))
(DTypeSig true "atomicLabelParamText" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "atomicLabelParamText" ((PVar "l")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "label `")) (EApp (EVar "display") (EVar "l"))) (ELit (LString "` is atomic and takes no parameter; declare it `effect "))) (EApp (EVar "display") (EVar "l"))) (ELit (LString " Prefix` to parameterize it"))))
(DTypeSig false "primaryLiteralProblems" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "primaryLiteralProblems" ((PCons (PTuple (PVar "name") (PCon "PPrefix" PWild)) PWild) (PVar "pat")) (EIf (EApp (EVar "prefixPatternOk") (EVar "pat")) (EListLit) (EListLit (EApp (EVar "prefixPatternErrMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " pattern")))))))
(DFunDef false "primaryLiteralProblems" (PWild PWild) (EListLit))
(DTypeSig false "productAxesProblems" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "Param") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "productAxesProblems" ((PVar "schema") (PCon "PProduct" (PVar "axes"))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "a")) (EApp (EApp (EApp (EVar "axisProblems") (EVar "schema")) (EApp (EVar "fst") (EVar "a"))) (EApp (EVar "snd") (EVar "a"))))) (EVar "axes")))
(DFunDef false "productAxesProblems" (PWild PWild) (EListLit))
(DTypeSig false "repeatedAxisText" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "repeatedAxisText" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "axis `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` is written twice; write each value as its own element"))))
(DTypeSig true "repeatedNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "repeatedNames" ((PList) PWild) (EListLit))
(DFunDef false "repeatedNames" ((PCons (PVar "n") (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "seen")) (EApp (EApp (EVar "repeatedNames") (EVar "rest")) (EVar "seen")) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "rest")) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "repeatedNames") (EVar "rest")) (EBinOp "::" (EVar "n") (EVar "seen")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "repeatedNames") (EVar "rest")) (EVar "seen")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "axisProblems" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "axisProblems" ((PVar "schema") (PVar "name") (PVar "p")) (EMatch (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "schema")) (arm (PCon "None") () (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "unknown product axis `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "`; declared axes: "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "schema"))))) (ELit (LString ""))))) (arm (PCon "Some" (PCon "PPrefix" PWild)) () (EMatch (EVar "p") (arm (PCon "PPrefix" (PCon "Some" (PVar "pat"))) () (EIf (EApp (EVar "prefixPatternOk") (EVar "pat")) (EListLit) (EListLit (EApp (EVar "prefixPatternErrMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " pattern"))))))) (arm (PCon "PPrefix" (PCon "None")) () (EListLit)) (arm PWild () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "axis `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` takes a prefix pattern, not a set"))))))) (arm (PCon "Some" (PCon "PSet" PWild)) () (EMatch (EVar "p") (arm (PCon "PSet" PWild) () (EListLit)) (arm PWild () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "axis `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` takes a set, not a pattern"))))))) (arm (PCon "Some" PWild) () (EListLit))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "EffParamTy" true))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true) (mem "canonParam" false) (mem "subTopOf" false) (mem "lookupAxis" false) (mem "productPrimaryLift" false) (mem "productOver" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffLabel" false) (mem "Atom" false) (mem "labelKey" false) (mem "builtinLabel" false) (mem "atomWith" false) (mem "effLabelName" false))))
(DUse false (UseGroup ("support" "util") ((mem "sortUniqS" false) (mem "filterList" false) (mem "reverseL" false) (mem "contains" false) (mem "joinWith" false))))
(DTypeSig false "lookupDomain" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "Param"))))
(DFunDef false "lookupDomain" (PWild (PList)) (EVar "PUnit"))
(DFunDef false "lookupDomain" ((PVar "l") (PCons (PTuple (PVar "k") (PVar "p")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "l") (EVar "k")) (EVar "p") (EApp (EApp (EVar "lookupDomain") (EVar "l")) (EVar "rest"))))
(DTypeSig true "dtopIn" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "EffLabel") (TyCon "Param"))))
(DFunDef false "dtopIn" ((PVar "domains") (PVar "label")) (EMatch (EApp (EApp (EVar "lookupDomain") (EApp (EVar "labelKey") (EVar "label"))) (EVar "domains")) (arm (PCon "PPrefix" (PCon "None")) () (EApp (EVar "PPrefix") (EVar "None"))) (arm (PCon "PPath" (PCon "None")) () (EApp (EVar "PPath") (EVar "None"))) (arm (PCon "PSet" (PCon "None")) () (EApp (EVar "PSet") (EVar "None"))) (arm (PAs "p" (PCon "PProduct" PWild)) () (EVar "p")) (arm PWild () (EVar "PUnit"))))
(DTypeSig true "atomOfLabel" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "String") (TyCon "Atom"))))
(DFunDef false "atomOfLabel" ((PVar "domains") (PVar "l")) (EApp (EApp (EVar "atomWith") (EApp (EVar "builtinLabel") (EVar "l"))) (EApp (EApp (EVar "dtopIn") (EVar "domains")) (EApp (EVar "builtinLabel") (EVar "l")))))
(DTypeSig true "writtenParam" (TyFun (TyCon "Param") (TyFun (TyCon "EffParamTy") (TyCon "Param"))))
(DFunDef false "writtenParam" ((PVar "top") (PCon "EPTop")) (EVar "top"))
(DFunDef false "writtenParam" ((PCon "PPrefix" (PCon "None")) (PCon "EPLit" (PVar "s"))) (EApp (EVar "canonParam") (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s")))))
(DFunDef false "writtenParam" ((PCon "PPath" (PCon "None")) (PCon "EPLit" (PVar "s"))) (EApp (EVar "canonParam") (EApp (EVar "PPath") (EApp (EVar "Some") (EVar "s")))))
(DFunDef false "writtenParam" ((PCon "PSet" (PCon "None")) (PCon "EPLit" (PVar "s"))) (EApp (EVar "PSet") (EApp (EVar "Some") (EListLit (EVar "s")))))
(DFunDef false "writtenParam" ((PCon "PSet" (PCon "None")) (PCon "EPSet" (PVar "xs"))) (EApp (EVar "PSet") (EApp (EVar "Some") (EApp (EVar "sortUniqS") (EVar "xs")))))
(DFunDef false "writtenParam" ((PCon "PProduct" (PVar "schema")) (PCon "EPLit" (PVar "s"))) (EApp (EApp (EVar "productPrimaryLift") (EVar "schema")) (EVar "s")))
(DFunDef false "writtenParam" ((PCon "PProduct" (PVar "schema")) (PCon "EPProduct" (PVar "axes"))) (EApp (EApp (EVar "productOver") (EVar "schema")) (EApp (EApp (EMethodRef "map") (EVar "writtenAxis")) (EVar "axes"))))
(DFunDef false "writtenParam" ((PVar "top") PWild) (EVar "top"))
(DTypeSig false "checkedAxis" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyTuple (TyCon "String") (TyCon "EffParamTy")) (TyTuple (TyCon "String") (TyCon "Param")))))
(DFunDef false "checkedAxis" ((PVar "schema") (PTuple (PVar "name") (PCon "EPName" PWild))) (EMatch (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "schema")) (arm (PCon "Some" (PVar "top")) () (ETuple (EVar "name") (EApp (EVar "subTopOf") (EVar "top")))) (arm (PCon "None") () (ETuple (EVar "name") (EVar "PUnit")))))
(DFunDef false "checkedAxis" (PWild (PVar "a")) (EApp (EVar "writtenAxis") (EVar "a")))
(DTypeSig true "writtenAxis" (TyFun (TyTuple (TyCon "String") (TyCon "EffParamTy")) (TyTuple (TyCon "String") (TyCon "Param"))))
(DFunDef false "writtenAxis" ((PTuple (PVar "name") (PCon "EPLit" (PVar "s")))) (ETuple (EVar "name") (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s")))))
(DFunDef false "writtenAxis" ((PTuple (PVar "name") (PCon "EPSet" (PVar "xs")))) (ETuple (EVar "name") (EApp (EVar "PSet") (EApp (EVar "Some") (EApp (EVar "sortUniqS") (EVar "xs"))))))
(DFunDef false "writtenAxis" ((PTuple (PVar "name") PWild)) (ETuple (EVar "name") (EVar "PUnit")))
(DTypeSig true "decodeSetParam" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "decodeSetParam" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (ELit (LString "{")))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "s")) (ELit (LString "}")))) (EApp (EVar "sortUniqS") (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (ELit (LString ""))))) (EApp (EVar "splitOnComma") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "s"))))) (EApp (EVar "sortUniqS") (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (ELit (LString ""))))) (EApp (EVar "splitOnComma") (EVar "s"))))))))
(DTypeSig false "splitOnComma" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitOnComma" ((PVar "s")) (EApp (EApp (EApp (EApp (EVar "splitOnCommaGo") (EVar "s")) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)))
(DTypeSig false "splitOnCommaGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "splitOnCommaGo" ((PVar "s") (PVar "start") (PVar "i") (PVar "acc")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "reverseL") (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EVar "n")) (EVar "s")) (EVar "acc"))) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "s")) (ELit (LString ","))) (EApp (EApp (EApp (EApp (EVar "splitOnCommaGo") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EVar "i")) (EVar "s")) (EVar "acc"))) (EApp (EApp (EApp (EApp (EVar "splitOnCommaGo") (EVar "s")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")))))))
(DTypeSig false "prefixPatternOk" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "prefixPatternOk" ((PVar "s")) (EBinOp ">" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 0))))
(DTypeSig true "effectParamMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "effectParamMsg" ((PVar "label") (PVar "why")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "invalid effect parameter on <")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString ">: "))) (EApp (EMethodRef "display") (EVar "why"))) (ELit (LString ""))))
(DTypeSig false "prefixPatternErrMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "prefixPatternErrMsg" ((PVar "noun")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "noun"))) (ELit (LString " is empty; name the element, or write the bare label for the whole domain"))))
(DTypeSig true "effectParamProblems" (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyFun (TyCon "EffParamTy") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "effectParamProblems" ((PVar "l") (PCon "PUnit") (PCon "EPName" PWild)) (EListLit (EApp (EVar "atomicLabelParamText") (EVar "l"))))
(DFunDef false "effectParamProblems" (PWild PWild (PCon "EPName" PWild)) (EListLit))
(DFunDef false "effectParamProblems" (PWild PWild (PCon "EPTop")) (EListLit))
(DFunDef false "effectParamProblems" ((PVar "l") (PCon "PPrefix" (PCon "None")) (PCon "EPLit" (PVar "pat"))) (EApp (EApp (EVar "prefixLiteralProblems") (EVar "l")) (EVar "pat")))
(DFunDef false "effectParamProblems" ((PVar "l") (PCon "PPath" (PCon "None")) (PCon "EPLit" (PVar "pat"))) (EApp (EApp (EVar "prefixLiteralProblems") (EVar "l")) (EVar "pat")))
(DFunDef false "effectParamProblems" (PWild (PCon "PSet" (PCon "None")) (PCon "EPLit" PWild)) (EListLit))
(DFunDef false "effectParamProblems" ((PVar "_l") (PCon "PProduct" (PVar "schema")) (PCon "EPLit" (PVar "pat"))) (EBinOp "++" (EApp (EApp (EVar "primaryLiteralProblems") (EVar "schema")) (EVar "pat")) (EApp (EApp (EVar "productAxesProblems") (EVar "schema")) (EApp (EApp (EVar "productPrimaryLift") (EVar "schema")) (EVar "pat")))))
(DFunDef false "effectParamProblems" ((PVar "l") PWild (PCon "EPLit" PWild)) (EListLit (EApp (EVar "atomicLabelParamText") (EVar "l"))))
(DFunDef false "effectParamProblems" (PWild (PCon "PSet" (PCon "None")) (PCon "EPSet" PWild)) (EListLit))
(DFunDef false "effectParamProblems" ((PVar "l") (PCon "PPrefix" (PCon "None")) (PCon "EPSet" PWild)) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "label `")) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString "` takes a prefix pattern, not a set")))))
(DFunDef false "effectParamProblems" ((PVar "l") (PCon "PPath" (PCon "None")) (PCon "EPSet" PWild)) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "label `")) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString "` takes a prefix pattern, not a set")))))
(DFunDef false "effectParamProblems" ((PVar "l") (PCon "PProduct" PWild) (PCon "EPSet" PWild)) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "label `")) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString "` takes named axes such as `Host=... Method=...`, not a bare set")))))
(DFunDef false "effectParamProblems" ((PVar "l") PWild (PCon "EPSet" PWild)) (EListLit (EApp (EVar "atomicLabelParamText") (EVar "l"))))
(DFunDef false "effectParamProblems" (PWild (PCon "PProduct" (PVar "schema")) (PCon "EPProduct" (PVar "axes"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "repeatedAxisText")) (EApp (EApp (EVar "repeatedNames") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "axes"))) (EListLit))) (EApp (EApp (EVar "productAxesProblems") (EVar "schema")) (EApp (EVar "PProduct") (EApp (EApp (EMethodRef "map") (EApp (EVar "checkedAxis") (EVar "schema"))) (EVar "axes"))))))
(DFunDef false "effectParamProblems" ((PVar "l") (PCon "PUnit") (PCon "EPProduct" PWild)) (EListLit (EApp (EVar "atomicLabelParamText") (EVar "l"))))
(DFunDef false "effectParamProblems" ((PVar "l") PWild (PCon "EPProduct" PWild)) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "label `")) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString "` is not a product domain and takes no axes")))))
(DTypeSig true "decodeWrittenParam" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "EffLabel") (TyFun (TyCon "EffParamTy") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Param"))))))
(DFunDef false "decodeWrittenParam" ((PVar "domains") (PVar "label") (PVar "p")) (EBlock (DoLet false false (PVar "top") (EApp (EApp (EVar "dtopIn") (EVar "domains")) (EVar "label"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "effectParamProblems") (EApp (EVar "effLabelName") (EVar "label"))) (EVar "top")) (EVar "p")) (arm (PList) () (EApp (EVar "Ok") (EApp (EApp (EVar "writtenParam") (EVar "top")) (EVar "p")))) (arm (PCons (PVar "m") PWild) () (EApp (EVar "Err") (EApp (EApp (EVar "effectParamMsg") (EApp (EVar "effLabelName") (EVar "label"))) (EVar "m"))))))))
(DTypeSig false "prefixLiteralProblems" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "prefixLiteralProblems" ((PVar "l") (PVar "pat")) (EIf (EBinOp "==" (EVar "l") (ELit (LString "FFI"))) (EIf (EBinOp ">" (EApp (EVar "stringLength") (EVar "pat")) (ELit (LInt 0))) (EListLit) (EListLit (ELit (LString "the library pattern is empty; name the library, `<FFI \"curl\">`")))) (EIf (EApp (EVar "prefixPatternOk") (EVar "pat")) (EListLit) (EListLit (EApp (EVar "prefixPatternErrMsg") (ELit (LString "pattern")))))))
(DTypeSig true "atomicLabelParamText" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "atomicLabelParamText" ((PVar "l")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "label `")) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString "` is atomic and takes no parameter; declare it `effect "))) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString " Prefix` to parameterize it"))))
(DTypeSig false "primaryLiteralProblems" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "primaryLiteralProblems" ((PCons (PTuple (PVar "name") (PCon "PPrefix" PWild)) PWild) (PVar "pat")) (EIf (EApp (EVar "prefixPatternOk") (EVar "pat")) (EListLit) (EListLit (EApp (EVar "prefixPatternErrMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " pattern")))))))
(DFunDef false "primaryLiteralProblems" (PWild PWild) (EListLit))
(DTypeSig false "productAxesProblems" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "Param") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "productAxesProblems" ((PVar "schema") (PCon "PProduct" (PVar "axes"))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "a")) (EApp (EApp (EApp (EVar "axisProblems") (EVar "schema")) (EApp (EVar "fst") (EVar "a"))) (EApp (EVar "snd") (EVar "a"))))) (EVar "axes")))
(DFunDef false "productAxesProblems" (PWild PWild) (EListLit))
(DTypeSig false "repeatedAxisText" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "repeatedAxisText" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "axis `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` is written twice; write each value as its own element"))))
(DTypeSig true "repeatedNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "repeatedNames" ((PList) PWild) (EListLit))
(DFunDef false "repeatedNames" ((PCons (PVar "n") (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "seen")) (EApp (EApp (EVar "repeatedNames") (EVar "rest")) (EVar "seen")) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "rest")) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "repeatedNames") (EVar "rest")) (EBinOp "::" (EVar "n") (EVar "seen")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "repeatedNames") (EVar "rest")) (EVar "seen")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "axisProblems" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "axisProblems" ((PVar "schema") (PVar "name") (PVar "p")) (EMatch (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "schema")) (arm (PCon "None") () (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "unknown product axis `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "`; declared axes: "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "schema"))))) (ELit (LString ""))))) (arm (PCon "Some" (PCon "PPrefix" PWild)) () (EMatch (EVar "p") (arm (PCon "PPrefix" (PCon "Some" (PVar "pat"))) () (EIf (EApp (EVar "prefixPatternOk") (EVar "pat")) (EListLit) (EListLit (EApp (EVar "prefixPatternErrMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " pattern"))))))) (arm (PCon "PPrefix" (PCon "None")) () (EListLit)) (arm PWild () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "axis `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` takes a prefix pattern, not a set"))))))) (arm (PCon "Some" (PCon "PSet" PWild)) () (EMatch (EVar "p") (arm (PCon "PSet" PWild) () (EListLit)) (arm PWild () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "axis `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` takes a set, not a pattern"))))))) (arm (PCon "Some" PWild) () (EListLit))))
