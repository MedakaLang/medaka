(* Phase 34 — collect parse / resolve / typecheck errors from a single source
   buffer into a list of diagnostics, without ever exiting the process.

   The driver in bin/main.ml exits on the first error; this module exists so
   the LSP server (and future `check --json`) can keep going and report
   everything they can. *)

type severity = Error | Warning

type diagnostic = {
  severity : severity;
  loc      : Ast.loc;
  message  : string;
}

(* Synthesise a loc when nothing better is available.  Used for typecheck
   warnings (exhaustiveness etc.) which currently have no location. *)
let dummy_loc ~file = {
  Ast.file;
  line     = 1;
  col      = 0;
  end_line = 1;
  end_col  = 0;
}

(* Convert an Ast.loc option into a concrete loc, falling back to dummy_loc. *)
let loc_or_dummy ~file = function
  | Some l -> l
  | None   -> dummy_loc ~file

let pp_resolve_error = Resolve.pp_error
let pp_type_error    = Typecheck.pp_error

(* Capture a Lexing.position as a one-character range starting at that
   position.  The LSP spec requires a Range; lexer errors don't have a
   span, so we underline a single column. *)
let loc_of_lex_pos (p : Lexing.position) : Ast.loc =
  let col = p.pos_cnum - p.pos_bol in
  {
    Ast.file = p.pos_fname;
    line     = p.pos_lnum;
    col;
    end_line = p.pos_lnum;
    end_col  = col + 1;
  }

let analyze ~(file : string) ~(source : string) : diagnostic list =
  let diags = ref [] in
  let push d = diags := d :: !diags in

  let lexbuf = Lexing.from_string source in
  lexbuf.Lexing.lex_curr_p <-
    { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = file };
  Lexer.reset ();

  let program_opt =
    try Some (Parser.program Lexer.token lexbuf) with
    | Parser.Error ->
      push {
        severity = Error;
        loc      = loc_of_lex_pos lexbuf.lex_curr_p;
        message  = "Parse error";
      };
      None
    | Failure msg ->
      push {
        severity = Error;
        loc      = loc_of_lex_pos lexbuf.lex_curr_p;
        message  = msg;
      };
      None
  in
  match program_opt with
  | None -> List.rev !diags
  | Some prog ->
    let prog = Desugar.desugar_program prog in

    (* `use` declarations require the multi-file loader, which is out of
       scope for v1 of the LSP.  Flag them rather than silently producing
       confusing later errors. *)
    let has_use =
      List.exists (function Ast.DUse _ -> true | _ -> false) prog
    in
    if has_use then begin
      push {
        severity = Warning;
        loc      = dummy_loc ~file;
        message  = "Cross-file `use` declarations are not yet supported by the language server.";
      }
    end;

    let resolve_errs = Resolve.resolve_program prog in
    List.iter (fun (err, loc_opt) ->
      push {
        severity = Error;
        loc      = loc_or_dummy ~file loc_opt;
        message  = pp_resolve_error err;
      }
    ) resolve_errs;

    (* Only run typecheck if resolve had no errors — typecheck calls into
       env state that resolve populates, and running it on an inconsistent
       AST can produce nonsense errors. *)
    if resolve_errs = [] then begin
      try
        let (_env, warnings) = Typecheck.check_program prog in
        List.iter (fun msg ->
          push { severity = Warning; loc = dummy_loc ~file; message = msg }
        ) warnings
      with Typecheck.Type_error (e, loc_opt) ->
        push {
          severity = Error;
          loc      = loc_or_dummy ~file loc_opt;
          message  = pp_type_error e;
        }
    end;

    List.rev !diags

(* Render a diagnostic the way tests print it on failure. *)
let pp_diagnostic d =
  let sev = match d.severity with Error -> "error" | Warning -> "warning" in
  Printf.sprintf "%s:%d:%d-%d:%d: %s: %s"
    d.loc.file d.loc.line d.loc.col d.loc.end_line d.loc.end_col
    sev d.message
