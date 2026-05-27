open Ast

let run_bench eval_env (decl : decl) =
  match decl with
  | DBench { bench_name; bench_body; _ } ->
    Printf.printf "bench %S ... %!" bench_name;
    let base_frame = List.map (fun (k, v) -> (k, ref v)) eval_env in
    let env = [base_frame] in
    (* warm-up *)
    for _ = 1 to 10 do
      ignore (Eval.eval env bench_body)
    done;
    (* timed run *)
    let iters = 1000 in
    let times = Array.init iters (fun _ ->
      let t0 = Unix.gettimeofday () in
      ignore (Eval.eval env bench_body);
      Unix.gettimeofday () -. t0
    ) in
    let mean = Array.fold_left ( +. ) 0.0 times /. float_of_int iters in
    let variance = Array.fold_left (fun acc t ->
      let d = t -. mean in acc +. d *. d
    ) 0.0 times /. float_of_int iters in
    let stddev = sqrt variance in
    let throughput = if mean > 0.0 then 1.0 /. mean else Float.infinity in
    let pct = if mean > 0.0 then stddev /. mean *. 100.0 else 0.0 in
    if throughput >= 1_000_000.0 then
      Printf.printf "%.2f Miter/s  (±%.1f%%)\n%!" (throughput /. 1_000_000.0) pct
    else if throughput >= 1_000.0 then
      Printf.printf "%.2f kiter/s  (±%.1f%%)\n%!" (throughput /. 1_000.0) pct
    else
      Printf.printf "%.2f iter/s  (±%.1f%%)\n%!" throughput pct
  | _ -> ()

let run_all eval_env program =
  let benches = List.filter (function DBench _ -> true | _ -> false) program in
  if benches = [] then
    Printf.printf "(no benchmarks found)\n%!"
  else begin
    Printf.printf "running %d benchmark%s\n%!"
      (List.length benches)
      (if List.length benches = 1 then "" else "s");
    List.iter (run_bench eval_env) benches
  end
