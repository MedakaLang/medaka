(* Loader: parse a program's transitive file dependencies and return them
   in topological (dependency-first) order.

   Module ID derivation: given project_dir and a file path, strip the
   project_dir prefix and the .mdk suffix, then replace / with dots.
   Example: project_dir=/p/src, file=/p/src/list/core.mdk → "list.core" *)

type load_error =
  | FileNotFound     of string          (* file path *)
  | CyclicDependency of string list     (* module path forming the cycle *)
  | UnknownModule    of { mod_id: string; importer_file: string option }

exception LoadError of load_error

(* ── Path / module-ID utilities ───────────────────── *)

let normalize_path p =
  (* Remove trailing slash from directory *)
  if String.length p > 0 && p.[String.length p - 1] = '/' then
    String.sub p 0 (String.length p - 1)
  else p

let module_id_of_path project_dir file_path =
  let project_dir = normalize_path project_dir in
  let file_path   = normalize_path file_path in
  let prefix = project_dir ^ "/" in
  let rel =
    if String.length file_path > String.length prefix
       && String.sub file_path 0 (String.length prefix) = prefix
    then String.sub file_path (String.length prefix)
           (String.length file_path - String.length prefix)
    else Filename.basename file_path
  in
  (* Strip .mdk suffix *)
  let rel =
    if Filename.check_suffix rel ".mdk"
    then Filename.chop_suffix rel ".mdk"
    else rel
  in
  (* Replace path separators with dots *)
  String.concat "." (String.split_on_char '/' rel)

let file_of_module_id project_dir mod_id =
  let project_dir = normalize_path project_dir in
  let rel = String.concat "/" (String.split_on_char '.' mod_id) ^ ".mdk" in
  project_dir ^ "/" ^ rel

(* ── Parsing ──────────────────────────────────────── *)

(* read_file ~read path: try the buffer-override callback first; if it
   returns Some s use that, else fall back to disk.  The LSP injects
   `read` to surface unsaved buffer content; the CLI passes None. *)
let read_file ?(read : (string -> string option) option) path =
  let buffered =
    match read with
    | Some f -> f path
    | None   -> None
  in
  match buffered with
  | Some s -> s
  | None ->
    if not (Sys.file_exists path) then raise (LoadError (FileNotFound path));
    let ic = open_in path in
    let n = in_channel_length ic in
    let s = Bytes.create n in
    really_input ic s 0 n;
    close_in ic;
    Bytes.to_string s

let parse_file ?read path =
  let source = read_file ?read path in
  let lexbuf = Lexing.from_string source in
  lexbuf.Lexing.lex_curr_p <-
    { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = path };
  Lexer.reset ();
  try Parser.program Lexer.token lexbuf
  with
  | Parser.Error ->
    let pos = lexbuf.Lexing.lex_curr_p in
    failwith (Printf.sprintf "%s:%d:%d: Parse error"
                pos.Lexing.pos_fname pos.Lexing.pos_lnum
                (pos.Lexing.pos_cnum - pos.Lexing.pos_bol))

(* ── Dependency extraction ────────────────────────── *)

(* "core" is the implicit prelude — its declarations are prepended automatically
   by the type-checker and evaluator.  An `import core.{...}` is a no-op
   (the names are already in scope); the loader must skip "core" so it doesn't
   end up duplicating the prelude when a user file imports from it. *)
let is_prelude_module = function
  | "core" -> true
  | _      -> false

(* Extract the module IDs that a program directly imports via `use` *)
let direct_imports (prog : Ast.program) : string list =
  List.filter_map (function
    | Ast.DUse (_, path) ->
      let parts = match path with
        | Ast.UseName  ns      -> ns
        | Ast.UseGroup (ns, _) -> ns
        | Ast.UseWild  ns      -> ns
        | Ast.UseAlias (ns, _) -> ns
      in
      (* Module ID is the dotted path minus the last segment when UseName
         refers to a specific name rather than a module. For all other forms
         the path IS the module, so take it directly. *)
      let mid =
        match path with
        | Ast.UseName ns when List.length ns > 1 ->
          (* use foo.bar → module is "foo", name is "bar" *)
          String.concat "." (List.rev (List.tl (List.rev ns)))
        | Ast.UseName [single] ->
          (* use foo → module is "foo" *)
          single
        | _ ->
          String.concat "." parts
      in
      if is_prelude_module mid then None else Some mid
    | _ -> None
  ) prog

(* ── Topological sort (DFS) ──────────────────────── *)

type node_state = Unvisited | InStack | Done

(* A file is "available" if the buffer override has content for it OR
   the file exists on disk.  Used when discovering a dependency. *)
let file_available ?read path =
  let buffered =
    match read with
    | Some f -> f path
    | None   -> None
  in
  match buffered with
  | Some _ -> true
  | None   -> Sys.file_exists path

(* Returns modules in dependency-first order (leaves before roots) *)
let topo_sort
    ?read
    (project_dir : string)
    (root_id     : string)
    (root_path   : string)
    (root_prog   : Ast.program)
  : (string * string * Ast.program) list =
  (* module_id → (file_path, program) *)
  let loaded : (string, string * Ast.program) Hashtbl.t = Hashtbl.create 8 in
  let state  : (string, node_state) Hashtbl.t = Hashtbl.create 8 in
  let result : (string * string * Ast.program) list ref = ref [] in

  Hashtbl.replace loaded root_id (root_path, root_prog);

  let rec visit ~stack ~importer mod_id =
    match Hashtbl.find_opt state mod_id with
    | Some Done -> ()
    | Some InStack ->
      (* Cycle: collect everything on the stack back to the repeated node *)
      let rec take_until acc = function
        | [] -> List.rev acc
        | m :: _ when m = mod_id -> List.rev (m :: acc)
        | m :: rest -> take_until (m :: acc) rest
      in
      let cycle = take_until [mod_id] stack in
      raise (LoadError (CyclicDependency cycle))
    | None | Some Unvisited ->
      Hashtbl.replace state mod_id InStack;
      let (file_path, prog) =
        match Hashtbl.find_opt loaded mod_id with
        | Some p -> p
        | None ->
          let path = file_of_module_id project_dir mod_id in
          if not (file_available ?read path) then
            raise (LoadError (UnknownModule { mod_id; importer_file = importer }));
          let prog = parse_file ?read path in
          Hashtbl.replace loaded mod_id (path, prog);
          (path, prog)
      in
      List.iter (fun dep_id ->
        visit ~stack:(mod_id :: stack) ~importer:(Some file_path) dep_id
      ) (direct_imports prog);
      Hashtbl.replace state mod_id Done;
      result := (mod_id, file_path, prog) :: !result
  in
  visit ~stack:[] ~importer:None root_id;
  List.rev !result

(* ── Public entry point ───────────────────────────── *)

(* Load a root .mdk file and all its transitive dependencies.
   project_dir is the directory used to resolve module IDs to file paths.
   Returns (module_id, file_path, program) list in dependency-first order. *)
let load_program ?read root_file project_dir =
  let root_id   = module_id_of_path project_dir root_file in
  let root_prog = parse_file ?read root_file in
  topo_sort ?read project_dir root_id root_file root_prog
