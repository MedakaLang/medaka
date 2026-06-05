(* dev/diagdump.ml — dump a canonical, location-stripped, sorted view of a
   pipeline stage's DIAGNOSTICS, so the self-hosted stage can be diffed against
   the OCaml reference (the resolve/exhaust analogue of astdump).

   Usage: diagdump (--resolve | --exhaust) <file.mdk>
          diagdump --resolve-modules <mod1.mdk> [mod2.mdk ...]
     --resolve : parse → Desugar → Resolve.resolve_program, dump the error list
                 as S-expressions (constructor + args; locations dropped).
     --exhaust : parse → Exhaust.check_guard_exhaustiveness (on the RAW,
                 pre-desugar AST), dump the warning strings verbatim.
     --resolve-modules : the MULTI-MODULE resolve path (Resolve.resolve_module).
                 Takes an ordered list of files (caller supplies dependency-first
                 order, like the loader would), threads resolve_module over them
                 accumulating each module's exports, and dumps the union of all
                 modules' errors as sorted S-expressions.  Module IDs are the file
                 basenames sans `.mdk` (flat layout), matching `import foo.{…}`.
                 This isolates resolve_module — imports validated against real
                 exports, privacy, abstract-type ctor exports — which the
                 single-file --resolve path stubs out.  (UnknownModule is
                 reachable here precisely because the oracle does NOT go through
                 the loader, which would fail first on a missing file.)

   Output is sorted so it's order-independent (the self-hosted stage need not
   discover diagnostics in the same order). Empty output = no diagnostics. *)

open Medaka_lib

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let buf = Bytes.create n in
  really_input ic buf 0 n;
  close_in ic;
  Bytes.to_string buf

(* Same minimal escaping as dev/astdump.ml's esc_str (so selfhost can match). *)
let esc_str s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter (fun c ->
    match c with
    | '\\' -> Buffer.add_string b "\\\\"
    | '"'  -> Buffer.add_string b "\\\""
    | '\n' -> Buffer.add_string b "\\n"
    | '\t' -> Buffer.add_string b "\\t"
    | '\r' -> Buffer.add_string b "\\r"
    | c    -> Buffer.add_char b c) s;
  Buffer.add_char b '"';
  Buffer.contents b

let node tag parts = "(" ^ String.concat " " (tag :: parts) ^ ")"

(* Canonical serialization of a Resolve.error (the loc is dropped on purpose:
   the self-hosted AST strips locations, so it can't reproduce them). *)
let sexp_error : Resolve.error -> string = function
  | Resolve.UnboundVariable n        -> node "UnboundVariable" [esc_str n]
  | Resolve.UnknownConstructor n     -> node "UnknownConstructor" [esc_str n]
  | Resolve.UnknownType n            -> node "UnknownType" [esc_str n]
  | Resolve.UnknownEffect n          -> node "UnknownEffect" [esc_str n]
  | Resolve.UnknownField n           -> node "UnknownField" [esc_str n]
  | Resolve.FieldNotInRecord (f, r)  -> node "FieldNotInRecord" [esc_str f; esc_str r]
  | Resolve.DuplicateDefinition (k, n) -> node "DuplicateDefinition" [esc_str k; esc_str n]
  | Resolve.UnknownInterface n       -> node "UnknownInterface" [esc_str n]
  | Resolve.MethodNotInInterface (m, i) -> node "MethodNotInInterface" [esc_str m; esc_str i]
  | Resolve.ExternWithBody n         -> node "ExternWithBody" [esc_str n]
  | Resolve.PrivateNameAccess (n, m) -> node "PrivateNameAccess" [esc_str n; esc_str m]
  | Resolve.NoExportedConstructors (n, m) -> node "NoExportedConstructors" [esc_str n; esc_str m]
  | Resolve.UnknownModule n          -> node "UnknownModule" [esc_str n]
  | Resolve.QuestionMisplaced        -> "QuestionMisplaced"
  | Resolve.AsPatternMisplaced       -> "AsPatternMisplaced"
  | Resolve.NonRecursiveValueLet n   -> node "NonRecursiveValueLet" [esc_str n]

type mode = Resolve_m | Exhaust_m | ResolveModules_m

(* parse a file into a (pre-desugar) program, failing loudly on a parse error *)
let parse_file path =
  let src = read_file path in
  Lexer.reset ();
  let lb = Lexing.from_string src in
  try Parser.program Lexer.token lb
  with Parser.Error ->
    let p = lb.Lexing.lex_curr_p in
    failwith (Printf.sprintf "%s: parse error %d:%d" path p.Lexing.pos_lnum
      (p.Lexing.pos_cnum - p.Lexing.pos_bol))

let module_id_of path = Filename.remove_extension (Filename.basename path)

let () =
  let mode = ref None and files = ref [] in
  Array.iteri (fun i a ->
    if i = 0 then ()
    else match a with
      | "--resolve"         -> mode := Some Resolve_m
      | "--exhaust"         -> mode := Some Exhaust_m
      | "--resolve-modules" -> mode := Some ResolveModules_m
      | _                   -> files := a :: !files) Sys.argv;
  let files = List.rev !files in
  let mode = match !mode with
    | Some m -> m
    | None -> prerr_endline "usage: diagdump (--resolve | --exhaust | --resolve-modules) <file...>"; exit 2 in
  (* The multi-module path consumes ALL files (in order); the single-file paths
     use the first (last-given) one. *)
  if mode = ResolveModules_m then begin
    let exports = ref [] in
    let lines = List.concat_map (fun path ->
      let prog = Desugar.desugar_program (parse_file path) in
      let mod_id = module_id_of path in
      let (exp, errs) = Resolve.resolve_module !exports mod_id prog in
      exports := exp :: !exports;
      List.map (fun (e, _loc) -> sexp_error e) errs
    ) files in
    print_string (String.concat "\n" (List.sort compare lines))
  end else begin
  let path = match files with
    | p :: _ -> p
    | [] -> prerr_endline "usage: diagdump (--resolve | --exhaust) <file>"; exit 2 in
  let prog = parse_file path in
  let lines = match mode with
    | ResolveModules_m -> assert false  (* handled above *)
    | Resolve_m ->
        let prog = Desugar.desugar_program prog in
        List.map (fun (e, _loc) -> sexp_error e) (Resolve.resolve_program prog)
    | Exhaust_m ->
        (* Strip the "file:line:col: " prefix (the self-hosted AST drops
           locations, so it can only match the message text). Every warning is
           "<loc>Warning: <msg>", so keep from the first "Warning:". *)
        let strip s =
          let needle = "Warning:" in
          let n = String.length s and m = String.length needle in
          let rec find i =
            if i + m > n then s
            else if String.sub s i m = needle then String.sub s i (n - i)
            else find (i + 1)
          in find 0
        in
        List.map strip (Exhaust.check_guard_exhaustiveness prog)
  in
  print_string (String.concat "\n" (List.sort compare lines))
  end