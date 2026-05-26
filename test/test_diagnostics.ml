open Medaka_lib
open Diagnostics

let analyze src = analyze ~file:"<test>" ~source:src

let pp_diags ds =
  String.concat "\n  " (List.map pp_diagnostic ds)

(* ── Assertion helpers ─────────────────────────── *)

let assert_clean src () =
  let ds = analyze src in
  if ds <> [] then
    failwith (Printf.sprintf
      "Expected no diagnostics, got:\n  %s\n\nSource:\n%s"
      (pp_diags ds) src)

let assert_any pred src () =
  let ds = analyze src in
  if not (List.exists pred ds) then
    failwith (Printf.sprintf
      "Expected matching diagnostic, got:\n  %s\n\nSource:\n%s"
      (pp_diags ds) src)

let has_substr needle hay =
  let n = String.length needle and h = String.length hay in
  if n > h then false
  else
    let rec loop i =
      if i + n > h then false
      else if String.sub hay i n = needle then true
      else loop (i + 1)
    in loop 0

let msg_contains needle d = has_substr needle d.message
let is_error d = d.severity = Error
let is_warning d = d.severity = Warning

(* ── Tests ─────────────────────────────────────── *)

let t_clean_ok = assert_clean
  "f x = x + 1\nmain = f 5\n"

let t_parse_error = assert_any
  (fun d -> is_error d && msg_contains "Parse" d)
  "f x = x +\n"

let t_unbound_var = assert_any
  (fun d -> is_error d && msg_contains "Unbound" d)
  "f = nope\n"

let t_type_mismatch = assert_any
  (fun d -> is_error d && msg_contains "Type mismatch" d)
  "f : Int -> String\nf x = x + 1\n"

let t_multiple_resolve_errors () =
  let ds = analyze "f = nope1\ng = nope2\nh = nope3\n" in
  let errs = List.filter (fun d ->
    is_error d && msg_contains "Unbound" d) ds in
  if List.length errs < 3 then
    failwith (Printf.sprintf
      "Expected at least 3 unbound errors, got %d:\n  %s"
      (List.length errs) (pp_diags ds))

let t_use_decl_warning = assert_any
  (fun d -> is_warning d && msg_contains "use" d)
  "import other.mod\nmain = 0\n"

let t_loc_has_end () =
  let ds = analyze "f = nope\n" in
  match List.find_opt (fun d ->
    is_error d && msg_contains "Unbound" d) ds
  with
  | None -> failwith "Expected an Unbound error"
  | Some d ->
    if d.loc.end_line < d.loc.line ||
       (d.loc.end_line = d.loc.line && d.loc.end_col < d.loc.col) then
      failwith (Printf.sprintf
        "Diagnostic end position (%d:%d) precedes start (%d:%d)"
        d.loc.end_line d.loc.end_col d.loc.line d.loc.col)

(* ── Runner ─────────────────────────────────── *)

let () =
  let open Alcotest in
  run "Diagnostics" [
    "valid", [
      test_case "clean source"        `Quick t_clean_ok;
    ];
    "errors", [
      test_case "parse error"         `Quick t_parse_error;
      test_case "unbound variable"    `Quick t_unbound_var;
      test_case "type mismatch"       `Quick t_type_mismatch;
      test_case "multiple resolve"    `Quick t_multiple_resolve_errors;
      test_case "loc has end pos"     `Quick t_loc_has_end;
    ];
    "warnings", [
      test_case "use rejected"        `Quick t_use_decl_warning;
    ];
  ]
