let () =
  let filename =
    if Array.length Sys.argv > 1 then Sys.argv.(1)
    else (print_endline "Usage: medaka <file.mdk>"; exit 1)
  in
  let ic = open_in filename in
  let lexbuf = Lexing.from_channel ic in
  lexbuf.Lexing.lex_curr_p <- { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = filename };
  Medaka_lib.Lexer.reset ();
  (try
    let program = Medaka_lib.Parser.program Medaka_lib.Lexer.token lexbuf in
    Printf.printf "Parsed %d top-level declarations:\n" (List.length program);
    List.iter (fun decl ->
      match decl with
      | Medaka_lib.Ast.DTypeSig (name, ty) ->
        Printf.printf "  %s : %s\n" name (Medaka_lib.Ast.pp_ty ty)
      | Medaka_lib.Ast.DFunDef (name, pats, body) ->
        Printf.printf "  %s %s = %s\n"
          name
          (String.concat " " (List.map Medaka_lib.Ast.pp_pat pats))
          (Medaka_lib.Ast.pp_expr body)
      | Medaka_lib.Ast.DData (name, params, _variants) ->
        Printf.printf "  data %s %s\n" name (String.concat " " params)
      | Medaka_lib.Ast.DRecord (name, params, _fields) ->
        Printf.printf "  record %s %s\n" name (String.concat " " params)
      | Medaka_lib.Ast.DInterface { iface_name; _ } ->
        Printf.printf "  interface %s\n" iface_name
      | Medaka_lib.Ast.DImpl { iface_name; _ } ->
        Printf.printf "  impl %s\n" iface_name
      | Medaka_lib.Ast.DUse (pub, _) ->
        Printf.printf "  %suse ...\n" (if pub then "pub " else "")
    ) program
  with
  | Failure msg ->
    Printf.eprintf "Error: %s\n" msg; exit 1
  | Medaka_lib.Parser.Error ->
    let pos = lexbuf.Lexing.lex_curr_p in
    Printf.eprintf "Parse error at %s:%d:%d\n"
      pos.Lexing.pos_fname pos.Lexing.pos_lnum
      (pos.Lexing.pos_cnum - pos.Lexing.pos_bol);
    exit 1
  );
  close_in ic
