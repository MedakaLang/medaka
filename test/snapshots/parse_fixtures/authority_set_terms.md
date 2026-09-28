# META
source_lines=7
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
-- A set in a qualifier or an index, written as the checker prints one: a
-- join of literals, of a literal and a name, or a single literal (#3464).
data K (p : Authority FileRead) = K (String @("cfg/*" | p)) (String @"tmp/*")

openEither : Bool -> <Net "a.com/x", Net "b.com/y"> Result String (Socket ("a.com/x" | "b.com/y"))

useSock : Socket ("a.com/*" | h) -> <Net "a.com/*", Net h> Int
# PARSE
(DData Private "K" ("p") ((variant "K" (ConPos (TyQual (TyCon "String") (lit "cfg/*") "p") (TyQual (TyCon "String") (lit "tmp/*"))))) ())
(DTypeSig false "openEither" (TyFun (TyCon "Bool") (TyEffect ((atom "Net" "a.com/x") (atom "Net" "b.com/y")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Socket") (TyAuth "a.com/x" "b.com/y"))))))
(DTypeSig false "useSock" (TyFun (TyApp (TyCon "Socket") (TyAuth "a.com/*" (name "h"))) (TyEffect ((atom "Net" "a.com/*") (atom "Net" (name "h"))) None (TyCon "Int"))))
# PRINTER
data K (p : Authority FileRead) = K (String @("cfg/*" | p)) (String @"tmp/*")
openEither : Bool ->
  <Net "a.com/x", Net "b.com/y"> Result String (Socket ("a.com/x" | "b.com/y"))
useSock : Socket ("a.com/*" | h) -> <Net "a.com/*", Net h> Int
# DESUGAR
(DData Private "K" ("p") ((variant "K" (ConPos (TyQual (TyCon "String") (lit "cfg/*") "p") (TyQual (TyCon "String") (lit "tmp/*"))))) ())
(DTypeSig false "openEither" (TyFun (TyCon "Bool") (TyEffect ((atom "Net" "a.com/x") (atom "Net" "b.com/y")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Socket") (TyAuth "a.com/x" "b.com/y"))))))
(DTypeSig false "useSock" (TyFun (TyApp (TyCon "Socket") (TyAuth "a.com/*" (name "h"))) (TyEffect ((atom "Net" "a.com/*") (atom "Net" (name "h"))) None (TyCon "Int"))))
# MARK
(DData Private "K" ("p") ((variant "K" (ConPos (TyQual (TyCon "String") (lit "cfg/*") "p") (TyQual (TyCon "String") (lit "tmp/*"))))) ())
(DTypeSig false "openEither" (TyFun (TyCon "Bool") (TyEffect ((atom "Net" "a.com/x") (atom "Net" "b.com/y")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Socket") (TyAuth "a.com/x" "b.com/y"))))))
(DTypeSig false "useSock" (TyFun (TyApp (TyCon "Socket") (TyAuth "a.com/*" (name "h"))) (TyEffect ((atom "Net" "a.com/*") (atom "Net" (name "h"))) None (TyCon "Int"))))
