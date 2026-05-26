(* Phase 34 — Minimal LSP server.

   Capabilities advertised in v1:
   - textDocumentSync = Full (we re-analyze the entire document on every
     change; incremental sync is deferred until performance demands it).

   No hover, completion, go-to-definition, or workspace operations yet —
   diagnostics-only.  Document handling: keep the latest text per URI in a
   Hashtbl, run Diagnostics.analyze, publish back to the client. *)

open Lsp
open Lsp.Types

(* ── Identity monad for synchronous I/O ───────────────────── *)

module Identity = struct
  type 'a t = 'a
  let return x = x
  let raise = Stdlib.raise
  module O = struct
    let ( let+ ) x f = f x
    let ( let* ) x f = f x
  end
end

module Chan = struct
  type input = in_channel
  type output = out_channel

  let read_line ic =
    try Some (input_line ic)
    with End_of_file -> None

  let read_exactly ic n =
    let buf = Bytes.create n in
    try
      really_input ic buf 0 n;
      Some (Bytes.unsafe_to_string buf)
    with End_of_file -> None

  let write oc parts =
    List.iter (output_string oc) parts;
    flush oc
end

module Rpc_io = Io.Make (Identity) (Chan)

(* ── Document store ────────────────────────────────────────── *)

let docs : (string, string) Hashtbl.t = Hashtbl.create 8

(* ── Diagnostic conversion ─────────────────────────────────── *)

let range_of_loc (l : Ast.loc) : Range.t =
  let start = Position.create ~line:(l.line - 1) ~character:l.col in
  let end_  = Position.create ~line:(l.end_line - 1) ~character:l.end_col in
  Range.create ~start ~end_

let severity_of (s : Diagnostics.severity) : DiagnosticSeverity.t =
  match s with
  | Diagnostics.Error   -> DiagnosticSeverity.Error
  | Diagnostics.Warning -> DiagnosticSeverity.Warning

let lsp_diag_of (d : Diagnostics.diagnostic) : Diagnostic.t =
  Diagnostic.create
    ~message:(`String d.message)
    ~range:(range_of_loc d.loc)
    ~severity:(severity_of d.severity)
    ~source:"medaka"
    ()

let publish_diagnostics ~uri =
  let file = DocumentUri.to_path uri in
  let source =
    try Hashtbl.find docs (DocumentUri.to_string uri)
    with Not_found -> ""
  in
  let medaka_diags = Diagnostics.analyze ~file ~source in
  let lsp_diags = List.map lsp_diag_of medaka_diags in
  let params = PublishDiagnosticsParams.create
    ~diagnostics:lsp_diags ~uri ()
  in
  let notif = Server_notification.PublishDiagnostics params in
  let jsonrpc_notif = Server_notification.to_jsonrpc notif in
  Rpc_io.write stdout (Jsonrpc.Packet.Notification jsonrpc_notif)

(* ── Handlers ──────────────────────────────────────────────── *)

let handle_initialize (_p : InitializeParams.t) : InitializeResult.t =
  let sync = TextDocumentSyncKind.Full in
  let caps = ServerCapabilities.create
    ~textDocumentSync:(`TextDocumentSyncKind sync)
    ()
  in
  let info = InitializeResult.create_serverInfo
    ~name:"medaka-lsp" ~version:"0.1.0" ()
  in
  InitializeResult.create ~capabilities:caps ~serverInfo:info ()

let handle_notification (n : Client_notification.t) =
  match n with
  | Client_notification.TextDocumentDidOpen p ->
    let uri_str = DocumentUri.to_string p.textDocument.uri in
    Hashtbl.replace docs uri_str p.textDocument.text;
    publish_diagnostics ~uri:p.textDocument.uri
  | Client_notification.TextDocumentDidChange p ->
    let uri_str = DocumentUri.to_string p.textDocument.uri in
    (* Full sync: each change has no range and replaces the whole document.
       If the client misbehaves and sends an incremental change, we skip
       it (text without a range is still treated as full-replacement). *)
    let final_text =
      List.fold_left (fun _acc (ch : TextDocumentContentChangeEvent.t) ->
        match ch.range with
        | None   -> ch.text
        | Some _ ->
          (* Incremental edit — shouldn't happen with our advertised sync,
             but be defensive: keep the cached text unchanged. *)
          (try Hashtbl.find docs uri_str with Not_found -> ch.text)
      ) "" p.contentChanges
    in
    Hashtbl.replace docs uri_str final_text;
    publish_diagnostics ~uri:p.textDocument.uri
  | Client_notification.TextDocumentDidClose p ->
    let uri_str = DocumentUri.to_string p.textDocument.uri in
    Hashtbl.remove docs uri_str;
    (* Clear any squiggles the client might still be showing. *)
    let params = PublishDiagnosticsParams.create
      ~diagnostics:[] ~uri:p.textDocument.uri ()
    in
    let notif = Server_notification.PublishDiagnostics params in
    Rpc_io.write stdout
      (Jsonrpc.Packet.Notification (Server_notification.to_jsonrpc notif))
  | _ -> ()

let handle_request (req : Jsonrpc.Request.t) : Jsonrpc.Response.t =
  match Client_request.of_jsonrpc req with
  | Error msg ->
    Jsonrpc.Response.error req.id
      (Jsonrpc.Response.Error.make
        ~code:Jsonrpc.Response.Error.Code.InvalidRequest
        ~message:msg ())
  | Ok (Client_request.E r) ->
    (match r with
     | Client_request.Initialize p ->
       let result = handle_initialize p in
       Jsonrpc.Response.ok req.id (InitializeResult.yojson_of_t result)
     | Client_request.Shutdown ->
       Jsonrpc.Response.ok req.id `Null
     | _ ->
       Jsonrpc.Response.error req.id
         (Jsonrpc.Response.Error.make
           ~code:Jsonrpc.Response.Error.Code.MethodNotFound
           ~message:(Printf.sprintf "method %s not implemented" req.method_)
           ()))

(* ── Main loop ─────────────────────────────────────────────── *)

let run () =
  set_binary_mode_in  stdin  true;
  set_binary_mode_out stdout true;
  let continue = ref true in
  while !continue do
    match Rpc_io.read stdin with
    | None -> continue := false
    | Some (Jsonrpc.Packet.Request req) ->
      let resp = handle_request req in
      Rpc_io.write stdout (Jsonrpc.Packet.Response resp)
    | Some (Jsonrpc.Packet.Notification jsonrpc_notif) ->
      (match Client_notification.of_jsonrpc jsonrpc_notif with
       | Ok Client_notification.Exit -> continue := false
       | Ok n -> handle_notification n
       | Error _ -> ())
    | Some _ -> ()  (* Responses/batches not expected from clients we target. *)
  done
