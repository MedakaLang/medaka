# META
source_lines=13
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
import async.{Async}

-- #997: a row/grade written directly in a type-ARGUMENT slot
-- (`parseTyAtom`'s `TLt` arm) — not just the pre-existing prefix
-- position (`tyFor`, `<Stdout> Unit -> Int`).
bare : Async <Stdout> Unit
bareParam : Async <Net "a.com/*"> Unit
bareMulti : Async <Stdout, Rand> Unit
bareTailVar : Async <Stdout | e> Unit
bareEmpty : Async <> Unit
bareTailOnly : Async <e> Unit
degenerateStillWorks : Async (<Stdout> Unit) Unit
prefixStillWorks : String -> <Stdout> Unit
# PARSE
(DUse false (UseGroup ("async") ((mem "Async" false))))
(DTypeSig false "bare" (TyApp (TyApp (TyCon "Async") (TyEffect ("Stdout") None (TyCon "Unit"))) (TyCon "Unit")))
(DTypeSig false "bareParam" (TyApp (TyApp (TyCon "Async") (TyEffect ((atom "Net" "a.com/*")) None (TyCon "Unit"))) (TyCon "Unit")))
(DTypeSig false "bareMulti" (TyApp (TyApp (TyCon "Async") (TyEffect ("Stdout" "Rand") None (TyCon "Unit"))) (TyCon "Unit")))
(DTypeSig false "bareTailVar" (TyApp (TyApp (TyCon "Async") (TyEffect ("Stdout") (Some "e") (TyCon "Unit"))) (TyCon "Unit")))
(DTypeSig false "bareEmpty" (TyApp (TyApp (TyCon "Async") (TyEffect () None (TyCon "Unit"))) (TyCon "Unit")))
(DTypeSig false "bareTailOnly" (TyApp (TyApp (TyCon "Async") (TyEffect () (Some "e") (TyCon "Unit"))) (TyCon "Unit")))
(DTypeSig false "degenerateStillWorks" (TyApp (TyApp (TyCon "Async") (TyEffect ("Stdout") None (TyCon "Unit"))) (TyCon "Unit")))
(DTypeSig false "prefixStillWorks" (TyFun (TyCon "String") (TyEffect ("Stdout") None (TyCon "Unit"))))
# PRINTER
import async.{Async}
bare : Async (<Stdout> Unit) Unit
bareParam : Async (<Net "a.com/*"> Unit) Unit
bareMulti : Async (<Stdout, Rand> Unit) Unit
bareTailVar : Async (<Stdout | e> Unit) Unit
bareEmpty : Async (<> Unit) Unit
bareTailOnly : Async (<e> Unit) Unit
degenerateStillWorks : Async (<Stdout> Unit) Unit
prefixStillWorks : String -> <Stdout> Unit
# DESUGAR
(DUse false (UseGroup ("async") ((mem "Async" false))))
(DTypeSig false "bare" (TyApp (TyApp (TyCon "Async") (TyEffect ("Stdout") None (TyCon "Unit"))) (TyCon "Unit")))
(DTypeSig false "bareParam" (TyApp (TyApp (TyCon "Async") (TyEffect ((atom "Net" "a.com/*")) None (TyCon "Unit"))) (TyCon "Unit")))
(DTypeSig false "bareMulti" (TyApp (TyApp (TyCon "Async") (TyEffect ("Stdout" "Rand") None (TyCon "Unit"))) (TyCon "Unit")))
(DTypeSig false "bareTailVar" (TyApp (TyApp (TyCon "Async") (TyEffect ("Stdout") (Some "e") (TyCon "Unit"))) (TyCon "Unit")))
(DTypeSig false "bareEmpty" (TyApp (TyApp (TyCon "Async") (TyEffect () None (TyCon "Unit"))) (TyCon "Unit")))
(DTypeSig false "bareTailOnly" (TyApp (TyApp (TyCon "Async") (TyEffect () (Some "e") (TyCon "Unit"))) (TyCon "Unit")))
(DTypeSig false "degenerateStillWorks" (TyApp (TyApp (TyCon "Async") (TyEffect ("Stdout") None (TyCon "Unit"))) (TyCon "Unit")))
(DTypeSig false "prefixStillWorks" (TyFun (TyCon "String") (TyEffect ("Stdout") None (TyCon "Unit"))))
# MARK
(DUse false (UseGroup ("async") ((mem "Async" false))))
(DTypeSig false "bare" (TyApp (TyApp (TyCon "Async") (TyEffect ("Stdout") None (TyCon "Unit"))) (TyCon "Unit")))
(DTypeSig false "bareParam" (TyApp (TyApp (TyCon "Async") (TyEffect ((atom "Net" "a.com/*")) None (TyCon "Unit"))) (TyCon "Unit")))
(DTypeSig false "bareMulti" (TyApp (TyApp (TyCon "Async") (TyEffect ("Stdout" "Rand") None (TyCon "Unit"))) (TyCon "Unit")))
(DTypeSig false "bareTailVar" (TyApp (TyApp (TyCon "Async") (TyEffect ("Stdout") (Some "e") (TyCon "Unit"))) (TyCon "Unit")))
(DTypeSig false "bareEmpty" (TyApp (TyApp (TyCon "Async") (TyEffect () None (TyCon "Unit"))) (TyCon "Unit")))
(DTypeSig false "bareTailOnly" (TyApp (TyApp (TyCon "Async") (TyEffect () (Some "e") (TyCon "Unit"))) (TyCon "Unit")))
(DTypeSig false "degenerateStillWorks" (TyApp (TyApp (TyCon "Async") (TyEffect ("Stdout") None (TyCon "Unit"))) (TyCon "Unit")))
(DTypeSig false "prefixStillWorks" (TyFun (TyCon "String") (TyEffect ("Stdout") None (TyCon "Unit"))))
