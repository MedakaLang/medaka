(* Phase 69 marker pass.  Runs after resolve / desugar and before typecheck,
   on the tree shared by both typecheck and eval.  Rewrites every interface-
   method occurrence `EVar m` into `EMethodRef (ref None, m)` so the typechecker
   can record (in place) which impl each call site resolves to, and eval can
   route VMulti dispatch by that choice — fixing return-position and multi-param
   dispatch.  The ref is filled in place during typechecking; because the marked
   tree is the same value eval runs, no return-threading is needed.

   Phase 69.x extends this: every occurrence of a *constrained function* (one
   whose signature carries `=>`) becomes `EDictApp (ref None, f)`, the dual node
   for dictionary passing.  Typecheck fills its routes (one per constraint) and
   eval applies the resolved dictionaries as leading arguments — the dicts that
   dict_pass prepends as parameters on the function's definition.  Only
   *user-defined* constrained functions are wrapped (mirroring Phase 69's
   user-code-only scope); references to prelude constrained functions stay bare
   and use arg-tag dispatch as before. *)

open Ast

(* Collect the names of all interface methods declared across the given
   programs (e.g. the prelude plus the user program).  Method names are global
   identifiers in Medaka, so a flat name set is enough to identify occurrences. *)
let interface_method_names (programs : program list) : (ident, unit) Hashtbl.t =
  let tbl = Hashtbl.create 64 in
  let scan_decl d =
    match inner_decl d with
    | DInterface { methods; _ } ->
      List.iter (fun m -> Hashtbl.replace tbl m.method_name ()) methods
    | _ -> ()
  in
  List.iter (fun prog -> List.iter scan_decl prog) programs;
  tbl

(* Collect the names of functions whose declared signature carries a constraint
   (`Foo a => …`).  These are exactly the functions typecheck records in
   `fun_constraints` and dict_pass gives dictionary parameters, so their
   occurrences must be wrapped in EDictApp.  Scoped to the program(s) given —
   callers pass the user program only, so prelude constrained functions are not
   wrapped. *)
let constrained_fn_names (programs : program list) : (ident, unit) Hashtbl.t =
  let tbl = Hashtbl.create 32 in
  let is_constrained = function
    | TyConstrained _ -> true
    | _ -> false
  in
  let scan_decl d =
    match inner_decl d with
    | DTypeSig (_, name, ty) when is_constrained ty -> Hashtbl.replace tbl name ()
    | _ -> ()
  in
  List.iter (fun prog -> List.iter scan_decl prog) programs;
  tbl

(* Rewrite a single expression node: a bare method-name variable becomes an
   EMethodRef carrying a fresh, unfilled ref; a constrained-function-name
   variable becomes an EDictApp.  `@Name` hint vars start with '@' and are
   neither, so they pass through untouched.  Method names take precedence (a
   name is never both an interface method and a constrained top-level fn). *)
let mark_node (methods : (ident, unit) Hashtbl.t)
              (constrained : (ident, unit) Hashtbl.t) = function
  | EVar x when Hashtbl.mem methods x     -> EMethodRef (ref None, x)
  | EVar x when Hashtbl.mem constrained x -> EDictApp (ref None, x)
  | e -> e

(* Map over every expression in a declaration.  Desugar.map_decl skips
   DLetGroup and DBench bodies (its catch-all), so we handle those here and
   delegate the rest — including interface defaults and impl method bodies —
   to Desugar.map_decl, whose expr recursion is complete. *)
let rec mark_decl methods constrained d =
  let f = mark_node methods constrained in
  match d with
  | DLetGroup (pub, groups) ->
    DLetGroup (pub, List.map (fun (n, clauses) ->
      (n, List.map (fun (ps, body) -> (ps, Desugar.map_expr f body)) clauses))
      groups)
  | DBench b -> DBench { b with bench_body = Desugar.map_expr f b.bench_body }
  | DAttrib (attrs, inner) -> DAttrib (attrs, mark_decl methods constrained inner)
  | other -> Desugar.map_decl f other

let mark_program (methods : (ident, unit) Hashtbl.t)
                 (constrained : (ident, unit) Hashtbl.t) (prog : program) : program =
  List.map (mark_decl methods constrained) prog

(* Phase 69.x-c: the prelude, marked against its own interface methods and
   constrained functions, computed once.  typecheck prepends *this* tree (so it
   fills each prelude EMethodRef/EDictApp ref in place) and the typed eval
   drivers prepend the same value before dict_pass, so a prelude function like
   `when b m = if b then m else pure ()` routes its return-position `pure`
   through the dictionary mechanism instead of the legacy monad-tag workaround.
   Structurally identical to `Prelude.program` (same decls), so impl/iface/type
   scans are unaffected; only expression bodies carry the marker nodes.  Its
   body refs are refilled idempotently on each typecheck (prelude resolution is
   program-independent), and dict_pass never mutates it in place. *)
let marked_prelude : program =
  let methods = interface_method_names [Prelude.program] in
  let constrained = constrained_fn_names [Prelude.program] in
  mark_program methods constrained Prelude.program

(* Convenience: mark a user program against the prelude's interface methods
   plus its own, and against the prelude's *and* its own constrained functions
   (so a user reference to a prelude constrained fn like `when` becomes an
   EDictApp that supplies its dictionaries).  Used by the single-file drivers. *)
let mark_with_prelude (prog : program) : program =
  let methods = interface_method_names [Prelude.program; prog] in
  let constrained = constrained_fn_names [Prelude.program; prog] in
  mark_program methods constrained prog

(* Mark a single repl item against a pre-built method-name set (the session's
   known interface methods plus any the item itself declares) and a
   constrained-function-name set.  The repl can't use the program-list helpers
   because interfaces and signatures accrue across inputs. *)
let mark_repl_item (methods : (ident, unit) Hashtbl.t)
                   (constrained : (ident, unit) Hashtbl.t) (item : repl_item) : repl_item =
  match item with
  | ReplDecl decls -> ReplDecl (mark_program methods constrained decls)
  | ReplExpr e -> ReplExpr (Desugar.map_expr (mark_node methods constrained) e)
