open Medaka_lib

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let with_tmp_file contents f =
  let path = Filename.temp_file "test_coverage" ".mdk" in
  let oc = open_out path in
  output_string oc contents;
  close_out oc;
  let result = (try f path with e -> Sys.remove path; raise e) in
  Sys.remove path;
  result

let parse_and_desugar src filename =
  Lexer.reset ();
  let lexbuf = Lexing.from_string src in
  lexbuf.Lexing.lex_curr_p <- { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = filename };
  let decls = Parser.program Lexer.token lexbuf in
  Desugar.desugar_program decls

let capture_stdout f =
  let (pipe_r, pipe_w) = Unix.pipe () in
  let old_stdout = Unix.dup Unix.stdout in
  Unix.dup2 pipe_w Unix.stdout;
  Unix.close pipe_w;
  (try f () with e ->
    Unix.dup2 old_stdout Unix.stdout;
    Unix.close old_stdout;
    Unix.close pipe_r;
    raise e);
  flush stdout;
  Unix.dup2 old_stdout Unix.stdout;
  Unix.close old_stdout;
  let buf = Buffer.create 256 in
  let tmp = Bytes.create 4096 in
  let rec drain () =
    match Unix.read pipe_r tmp 0 4096 with
    | 0 -> ()
    | n -> Buffer.add_subbytes buf tmp 0 n; drain ()
    | exception Unix.Unix_error (Unix.EAGAIN, _, _) -> ()
    | exception Unix.Unix_error (Unix.EBADF, _, _) -> ()
  in
  drain ();
  Unix.close pipe_r;
  Buffer.contents buf

let contains s sub =
  let slen = String.length s and sublen = String.length sub in
  if sublen = 0 then true
  else if sublen > slen then false
  else begin
    let found = ref false in
    for i = 0 to slen - sublen do
      if not !found &&
         String.sub s i sublen = sub then found := true
    done;
    !found
  end

(* ── collect_executable ─────────────────────────────────────────────────── *)

let t_collect_empty () =
  let exec = Coverage.collect_executable [] in
  if exec <> [] then
    failwith (Printf.sprintf "expected empty list, got %d entries" (List.length exec))

let t_collect_fun_body () =
  with_tmp_file "f x = x + 1\n" (fun path ->
    let prog = parse_and_desugar "f x = x + 1\n" path in
    let exec = Coverage.collect_executable prog in
    if exec = [] then
      failwith "expected at least one executable line from DFunDef body"
  )

let t_collect_prop_body () =
  let src = {|prop "always" (x : Int) = x == x
|} in
  with_tmp_file src (fun path ->
    let prog = parse_and_desugar src path in
    let exec = Coverage.collect_executable prog in
    if exec = [] then
      failwith "expected at least one executable line from DProp body"
  )

let t_collect_type_sig_skipped () =
  (* DTypeSig has no expression body — collect_executable must not crash *)
  with_tmp_file "f : Int -> Int\nf x = x\n" (fun path ->
    let prog = parse_and_desugar "f : Int -> Int\nf x = x\n" path in
    let _exec = Coverage.collect_executable prog in
    ()
  )

(* ── record_hit / enabled ────────────────────────────────────────────────── *)

let t_disabled_by_default () =
  Coverage.reset ();
  Coverage.record_hit "foo.mdk" 5;
  (* hit table should remain empty since coverage is not enabled *)
  let hit_count = Hashtbl.length Coverage.hit in
  if hit_count <> 0 then
    failwith (Printf.sprintf "expected 0 hits when disabled, got %d" hit_count)

let t_enable_records_hit () =
  Coverage.reset ();
  Coverage.enable ();
  Coverage.record_hit "foo.mdk" 5;
  Coverage.record_hit "foo.mdk" 10;
  let hit_count = Hashtbl.length Coverage.hit in
  Coverage.reset ();
  if hit_count <> 2 then
    failwith (Printf.sprintf "expected 2 hits, got %d" hit_count)

let t_reset_clears_hits () =
  Coverage.reset ();
  Coverage.enable ();
  Coverage.record_hit "foo.mdk" 1;
  Coverage.reset ();
  let hit_count = Hashtbl.length Coverage.hit in
  if hit_count <> 0 then
    failwith (Printf.sprintf "expected 0 hits after reset, got %d" hit_count)

(* ── eval integration ────────────────────────────────────────────────────── *)

let t_hits_accumulate_during_eval () =
  Coverage.reset ();
  Coverage.enable ();
  with_tmp_file "f x = x + 1\nmain = f 5\n" (fun path ->
    let prog = parse_and_desugar "f x = x + 1\nmain = f 5\n" path in
    Eval.output_hook := (fun _ -> ());
    (try ignore (Eval.eval_program prog) with _ -> ());
    Eval.output_hook := print_string;
    let exec = Coverage.collect_executable prog in
    let hits_for_file = List.filter (fun (file, line) ->
      file = path && Hashtbl.mem Coverage.hit (file, line)
    ) exec in
    Coverage.reset ();
    if hits_for_file = [] then
      failwith "expected at least one hit line after evaluating a program"
  )

(* ── pp_report format ────────────────────────────────────────────────────── *)

let t_report_all_covered () =
  Coverage.reset ();
  Coverage.enable ();
  Coverage.record_hit "f.mdk" 1;
  Coverage.record_hit "f.mdk" 2;
  let exec = [("f.mdk", 1); ("f.mdk", 2)] in
  let out = capture_stdout (fun () -> Coverage.pp_report exec) in
  Coverage.reset ();
  if not (contains out "coverage:") then
    failwith (Printf.sprintf "expected report to start with 'coverage:', got: %S" out);
  if contains out "uncovered" then
    failwith "expected no 'uncovered' line when all lines are covered"

let t_report_partial_coverage () =
  Coverage.reset ();
  Coverage.enable ();
  Coverage.record_hit "g.mdk" 1;
  (* line 3 not hit *)
  let exec = [("g.mdk", 1); ("g.mdk", 3)] in
  let out = capture_stdout (fun () -> Coverage.pp_report exec) in
  Coverage.reset ();
  if not (contains out "uncovered") then
    failwith (Printf.sprintf "expected 'uncovered lines' in partial coverage report, got: %S" out);
  if not (contains out "3") then
    failwith (Printf.sprintf "expected line 3 in uncovered list, got: %S" out)

let t_report_empty_exec () =
  Coverage.reset ();
  let out = capture_stdout (fun () -> Coverage.pp_report []) in
  if out <> "" then
    failwith (Printf.sprintf "expected empty output for empty exec list, got: %S" out)

let t_report_percentage_shown () =
  Coverage.reset ();
  Coverage.enable ();
  Coverage.record_hit "h.mdk" 1;
  Coverage.record_hit "h.mdk" 2;
  let exec = [("h.mdk", 1); ("h.mdk", 2); ("h.mdk", 3); ("h.mdk", 4)] in
  let out = capture_stdout (fun () -> Coverage.pp_report exec) in
  Coverage.reset ();
  (* 2/4 = 50.0% *)
  if not (contains out "50.0%") then
    failwith (Printf.sprintf "expected '50.0%%' in report, got: %S" out)

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "coverage" [
    "collect_executable", [
      Alcotest.test_case "empty program"          `Quick t_collect_empty;
      Alcotest.test_case "fun body"               `Quick t_collect_fun_body;
      Alcotest.test_case "prop body"              `Quick t_collect_prop_body;
      Alcotest.test_case "type sig skipped"       `Quick t_collect_type_sig_skipped;
    ];
    "record_hit", [
      Alcotest.test_case "disabled by default"    `Quick t_disabled_by_default;
      Alcotest.test_case "enable records hit"     `Quick t_enable_records_hit;
      Alcotest.test_case "reset clears hits"      `Quick t_reset_clears_hits;
    ];
    "eval_integration", [
      Alcotest.test_case "hits accumulate"        `Quick t_hits_accumulate_during_eval;
    ];
    "pp_report", [
      Alcotest.test_case "all covered"            `Quick t_report_all_covered;
      Alcotest.test_case "partial coverage"       `Quick t_report_partial_coverage;
      Alcotest.test_case "empty exec list"        `Quick t_report_empty_exec;
      Alcotest.test_case "percentage shown"       `Quick t_report_percentage_shown;
    ];
  ]
