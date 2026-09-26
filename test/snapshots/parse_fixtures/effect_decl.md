# META
source_lines=11
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
effect KV
export effect Fetch

get : String -> <KV> String
get k = k

-- a Product label declares its axis schema, in the order written: the first
-- axis is the one a bare literal lifts into
effect Fetch Product (Host : Prefix, Method : Set)

export effect Db Product (Table : Prefix, Op : Set)
# PARSE
(DEffect false "KV" None ())
(DEffect true "Fetch" None ())
(DTypeSig false "get" (TyFun (TyCon "String") (TyEffect ("KV") None (TyCon "String"))))
(DFunDef false "get" ((PVar "k")) (EVar "k"))
(DEffect false "Fetch" (Some "Product") ((axis "Host" "Prefix") (axis "Method" "Set")))
(DEffect true "Db" (Some "Product") ((axis "Table" "Prefix") (axis "Op" "Set")))
# PRINTER
effect KV
export effect Fetch
get : String -> <KV> String
get k = k
effect Fetch Product (Host : Prefix, Method : Set)
export effect Db Product (Table : Prefix, Op : Set)
# DESUGAR
(DEffect false "KV" None ())
(DEffect true "Fetch" None ())
(DTypeSig false "get" (TyFun (TyCon "String") (TyEffect ("KV") None (TyCon "String"))))
(DFunDef false "get" ((PVar "k")) (EVar "k"))
(DEffect false "Fetch" (Some "Product") ((axis "Host" "Prefix") (axis "Method" "Set")))
(DEffect true "Db" (Some "Product") ((axis "Table" "Prefix") (axis "Op" "Set")))
# MARK
(DEffect false "KV" None ())
(DEffect true "Fetch" None ())
(DTypeSig false "get" (TyFun (TyCon "String") (TyEffect ("KV") None (TyCon "String"))))
(DFunDef false "get" ((PVar "k")) (EVar "k"))
(DEffect false "Fetch" (Some "Product") ((axis "Host" "Prefix") (axis "Method" "Set")))
(DEffect true "Db" (Some "Product") ((axis "Table" "Prefix") (axis "Op" "Set")))
