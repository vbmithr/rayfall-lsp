open Rayfall
module Json = Yojson.Safe.Util

module Io = struct
  type 'a t = 'a

  let return x = x
  let raise = raise

  module O = struct
    let ( let* ) x f = f x
    let ( let+ ) x f = f x
  end
end

module Channels = struct
  type input = in_channel
  type output = out_channel

  let read_line ch = try Some (input_line ch) with End_of_file -> None

  let read_exactly ch n =
    if n < 0 || n > 8 * 1024 * 1024 then invalid_arg "LSP message exceeds 8 MiB";
    try Some (really_input_string ch n) with End_of_file -> None

  let write ch chunks =
    List.iter (output_string ch) chunks;
    flush ch
end

module Wire = Lsp.Io.Make (Io) (Channels)

let member key j = Json.member key j
let str j = Json.to_string j
let int j = Json.to_int j
let obj xs = `Assoc xs
let string s = `String s
let docs : (string, Analysis.t) Hashtbl.t = Hashtbl.create 16
let roots = ref []
let initialized = ref false
let stopped = ref false

let notify method_ params =
  Wire.write stdout
    (Jsonrpc.Packet.Notification
       (Jsonrpc.Notification.create ~method_ ~params ()))

let diagnostics uri version items =
  notify "textDocument/publishDiagnostics"
    (`Assoc
       [
         ("uri", string uri);
         ("version", `Int version);
         ("diagnostics", `List items);
       ])

let open_document uri version text =
  (* A failed update invalidates the old snapshot: never navigate stale text. *)
  Hashtbl.remove docs uri;
  try
    let source = Source.create ~uri ~version text in
    let analysis = Analysis.analyze source in
    Hashtbl.replace docs uri analysis;
    diagnostics uri version
      (List.map
         (fun (span, message) ->
           obj
             [
               ("range", Source.range_json source span);
               ("severity", `Int 1);
               ("source", string "rayfall-lsp");
               ("message", string message);
             ])
         (Syntax.diagnostics (Analysis.syntax analysis)))
  with Invalid_argument message | Failure message ->
    diagnostics uri version
      [
        obj
          [
            ( "range",
              obj
                [
                  ("start", Source.position_json { line = 0; character = 0 });
                  ("end", Source.position_json { line = 0; character = 0 });
                ] );
            ("severity", `Int 1);
            ("message", string message);
          ];
      ]

let location project (l : Analysis.location) =
  match Project.source project l.uri with
  | None -> invalid_arg "Definition snapshot is unavailable"
  | Some source ->
      obj [ ("uri", string l.uri); ("range", Source.range_json source l.span) ]

let params_json = function None -> obj [] | Some p -> (p :> Yojson.Safe.t)

let document_at params =
  let uri = str (member "uri" (member "textDocument" params)) in
  let analysis = Hashtbl.find docs uri in
  let p = member "position" params in
  let byte =
    Source.offset (Analysis.source analysis)
      { line = int (member "line" p); character = int (member "character" p) }
  in
  let project =
    Project.create ~roots:!roots
      ~documents:(Hashtbl.fold (fun _ a xs -> a :: xs) docs [])
      analysis
  in
  let analysis = Project.analysis project in
  (project, analysis, Analysis.at analysis byte)

let handle_request method_ params =
  if method_ = "initialize" then (
    if !initialized then invalid_arg "Already initialized";
    let root_uris =
      match member "workspaceFolders" params with
      | `List folders ->
          List.filter_map
            (fun f ->
              match member "uri" f with `String u -> Some u | _ -> None)
            folders
      | _ -> (
          match member "rootUri" params with `String u -> [ u ] | _ -> [])
    in
    roots :=
      List.filter_map
        (fun uri ->
          if String.starts_with ~prefix:"file:///" uri then
            Some (Lsp.Uri.to_path (Lsp.Uri.of_string uri))
          else None)
        root_uris;
    initialized := true;
    obj
      [
        ( "serverInfo",
          obj
            [ ("name", string "rayfall-lsp"); ("version", string "0.1.0-dev") ]
        );
        ( "capabilities",
          obj
            [
              ("positionEncoding", string "utf-16");
              ( "textDocumentSync",
                obj [ ("openClose", `Bool true); ("change", `Int 1) ] );
              ("definitionProvider", `Bool true);
              ("referencesProvider", `Bool true);
              ("hoverProvider", `Bool true);
            ] );
      ])
  else if not !initialized then
    Jsonrpc.Response.Error.raise
      (Jsonrpc.Response.Error.make ~code:ServerNotInitialized
         ~message:"Initialize first" ())
  else if method_ = "shutdown" then (
    stopped := true;
    `Null)
  else if !stopped then invalid_arg "Server has shut down"
  else
    match method_ with
    | "textDocument/definition" ->
        let project, a, o = document_at params in
        `List
          (match o with
          | None -> []
          | Some o ->
              List.map
                (fun (b : Analysis.binding) -> location project b.location)
                (Analysis.targets (Project.resolve project a o)))
    | "textDocument/references" -> (
        let project, a, occurrence = document_at params in
        match occurrence with
        | None -> `List []
        | Some o -> (
            match Project.resolve project a o with
            | Analysis.Resolved binding ->
                let include_declaration =
                  Json.to_bool
                    (member "includeDeclaration" (member "context" params))
                in
                let refs =
                  Project.references project ~include_declaration binding
                in
                notify "window/logMessage"
                  (`Assoc
                     [
                       ("type", `Int 3);
                       ( "message",
                         string
                           (Printf.sprintf
                              "Reference search covers this load graph and \
                               returns definite matches only; %d possible \
                               matches excluded. Dynamic uses may be absent."
                              (List.length refs.possible)) );
                     ]);
                `List (List.map (location project) refs.definite)
            | Analysis.Candidates _ | Analysis.Runtime_dependent _ ->
                Jsonrpc.Response.Error.raise
                  (Jsonrpc.Response.Error.make ~code:RequestFailed
                     ~message:
                       "Reference target is runtime-dependent or ambiguous. \
                        Select a declaration to search its definite \
                        references; possible matches are excluded."
                     ())
            | Analysis.Unresolved _ | Analysis.Builtin _ -> `List []))
    | "textDocument/hover" -> (
        let project, a, o = document_at params in
        match o with
        | None -> `Null
        | Some o ->
            obj
              [
                ( "contents",
                  obj
                    [
                      ("kind", string "plaintext");
                      ( "value",
                        string
                          (Analysis.describe (Project.resolve project a o)
                          ^
                          match Project.issues project with
                          | [] -> ""
                          | xs -> "\n" ^ String.concat "\n" xs) );
                    ] );
                ("range", Source.range_json (Analysis.source a) o.span);
              ])
    | "rayfall/followValue" -> (
        let project, _a, o = document_at params in
        match o with
        | None ->
            obj [ ("status", string "unresolved"); ("locations", `List []) ]
        | Some o ->
            obj
              [
                ( "status",
                  string
                    (if o.origin_unknown then "runtime-dependent"
                     else "resolved") );
                ("locations", `List (List.map (location project) o.origins));
              ])
    | _ ->
        Jsonrpc.Response.Error.raise
          (Jsonrpc.Response.Error.make ~code:MethodNotFound
             ~message:("Unsupported method: " ^ method_)
             ())

let handle_notification method_ params =
  match method_ with
  | "exit" -> exit (if !stopped then 0 else 1)
  | _ when (not !initialized) || !stopped -> ()
  | "textDocument/didOpen" ->
      let d = member "textDocument" params in
      open_document
        (str (member "uri" d))
        (int (member "version" d))
        (str (member "text" d))
  | "textDocument/didChange" -> (
      let d = member "textDocument" params in
      let uri = str (member "uri" d) and version = int (member "version" d) in
      let newer =
        match Hashtbl.find_opt docs uri with
        | None -> true
        | Some a -> version > Source.version (Analysis.source a)
      in
      if newer then
        match Json.to_list (member "contentChanges" params) with
        | [] -> ()
        | changes ->
            if List.exists (fun c -> member "range" c <> `Null) changes then
              invalid_arg "Server negotiated full document synchronization";
            open_document uri version
              (str (member "text" (List.hd (List.rev changes)))))
  | "textDocument/didClose" ->
      let uri = str (member "uri" (member "textDocument" params)) in
      Hashtbl.remove docs uri;
      notify "textDocument/publishDiagnostics"
        (`Assoc [ ("uri", string uri); ("diagnostics", `List []) ])
  | _ -> ()

let error_of_exception = function
  | Jsonrpc.Response.Error.E error -> error
  | exn ->
      Jsonrpc.Response.Error.make ~code:InvalidParams
        ~message:(Printexc.to_string exn) ()

let run () =
  set_binary_mode_in stdin true;
  set_binary_mode_out stdout true;
  let rec loop () =
    match Wire.read stdin with
    | None -> ()
    | Some (Jsonrpc.Packet.Request request) ->
        let response =
          try
            Jsonrpc.Response.ok request.id
              (handle_request request.method_ (params_json request.params))
          with exn ->
            Jsonrpc.Response.error request.id (error_of_exception exn)
        in
        Wire.write stdout (Jsonrpc.Packet.Response response);
        loop ()
    | Some (Notification notification) ->
        (try
           handle_notification notification.method_
             (params_json notification.params)
         with exn -> prerr_endline ("rayfall-lsp: " ^ Printexc.to_string exn));
        loop ()
    | Some _ -> loop ()
  in
  try loop ()
  with exn ->
    prerr_endline ("rayfall-lsp transport: " ^ Printexc.to_string exn);
    exit 1

let () =
  match Array.to_list Sys.argv with
  | [ _ ] | [ _; "--stdio" ] -> run ()
  | [ _; "--version" ] -> print_endline "rayfall-lsp 0.1.0-dev"
  | _ ->
      prerr_endline "Usage: rayfall-lsp [--stdio | --version]";
      exit 2
