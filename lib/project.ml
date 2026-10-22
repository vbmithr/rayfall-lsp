module Paths = Set.Make (String)

type t = {
  entry : Analysis.t;
  analyses : Analysis.t list;
  sources : (string, Source.t) Hashtbl.t;
  issues : string list;
}

let path_of_uri uri =
  if String.starts_with ~prefix:"file:///" uri then
    Some (Lsp.Uri.to_path (Lsp.Uri.of_string uri))
  else None

let canonical path =
  try Unix.realpath path
  with Unix.Unix_error _ ->
    let absolute =
      if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
      else path
    in
    let parts =
      List.fold_left
        (fun acc -> function
          | "" | "." -> acc
          | ".." -> ( match acc with [] -> [] | _ :: xs -> xs)
          | x -> x :: acc)
        []
        (String.split_on_char '/' absolute)
    in
    "/" ^ String.concat "/" (List.rev parts)

let within root path =
  root = "/" || path = root || String.starts_with ~prefix:(root ^ "/") path

let create ~roots ~documents entry =
  let roots = List.map canonical roots in
  let overlays = Hashtbl.create 16 in
  List.iter
    (fun a ->
      match path_of_uri (Source.uri (Analysis.source a)) with
      | None -> ()
      | Some p -> Hashtbl.replace overlays (canonical p) a)
    documents;
  let sources = Hashtbl.create 16
  and visited = ref Paths.empty
  and scheduled = ref Paths.empty
  and analyses = ref []
  and problems = ref []
  and bytes = ref (Source.length (Analysis.source entry))
  and count = ref 0 in
  let issue s = if List.length !problems < 20 then problems := s :: !problems in
  let directories importer =
    let dir = Filename.dirname importer in
    let boundaries = List.filter (fun root -> within root dir) roots in
    let boundary =
      match
        List.sort
          (fun a b -> compare (String.length b) (String.length a))
          boundaries
      with
      | root :: _ -> root
      | [] -> dir
    in
    let rec loop acc dir =
      let acc = dir :: acc in
      if dir = boundary || dir = Filename.dirname dir then List.rev acc
      else loop acc (Filename.dirname dir)
    in
    loop [] dir
  in
  (* Configuration is data only: no commands or project code are executed. *)
  let entrypoints, working_directory =
    let config =
      match path_of_uri (Source.uri (Analysis.source entry)) with
      | None -> None
      | Some importer ->
          List.find_opt Sys.file_exists
            (List.map
               (fun dir -> Filename.concat dir ".rayfall-lsp.json")
               (directories (canonical importer)))
    in
    match config with
    | None -> ([], None)
    | Some path -> (
        try
          if (Unix.stat path).Unix.st_kind <> Unix.S_REG then
            invalid_arg "configuration is not a regular file";
          let ch = open_in_bin path in
          let json =
            Fun.protect
              ~finally:(fun () -> close_in_noerr ch)
              (fun () ->
                let size = in_channel_length ch in
                if size > 65536 then invalid_arg "configuration exceeds 64 KiB";
                Yojson.Safe.from_string (really_input_string ch size))
          in
          let fields =
            match json with
            | `Assoc fields -> fields
            | _ -> invalid_arg "configuration must be an object"
          in
          List.iter
            (fun (key, _) ->
              if not (List.mem key [ "entrypoints"; "workingDirectory" ]) then
                invalid_arg ("unknown configuration field: " ^ key))
            fields;
          let base = Filename.dirname path in
          let resolve = function
            | `String s when s <> "" ->
                canonical
                  (if Filename.is_relative s then Filename.concat base s else s)
            | _ -> invalid_arg "configuration paths must be nonempty strings"
          in
          let entrypoints =
            match List.assoc_opt "entrypoints" fields with
            | None -> []
            | Some (`List xs) when List.length xs <= 16 ->
                List.sort_uniq String.compare (List.map resolve xs)
            | _ ->
                invalid_arg "entrypoints must be an array of at most 16 paths"
          in
          let cwd =
            Option.map resolve (List.assoc_opt "workingDirectory" fields)
          in
          (entrypoints, cwd)
        with
        | Sys_error message
        | Invalid_argument message
        | Failure message
        | Yojson.Json_error message ->
            issue ("Invalid " ^ path ^ ": " ^ message);
            ([], None)
        | Unix.Unix_error (error, _, _) ->
            issue ("Cannot read " ^ path ^ ": " ^ Unix.error_message error);
            ([], None))
  in
  let load_paths importer path =
    let paths =
      if Filename.is_relative path then
        List.map
          (fun dir -> canonical (Filename.concat dir path))
          (match working_directory with
          | Some dir -> [ dir ]
          | None -> directories importer)
      else [ canonical path ]
    in
    List.sort_uniq String.compare paths
    |> List.filter (fun p -> Hashtbl.mem overlays p || Sys.file_exists p)
  in
  let read path =
    match Hashtbl.find_opt overlays path with
    | Some a ->
        let size = Source.length (Analysis.source a) in
        if !bytes + size > 16 * 1024 * 1024 then (
          issue "Cross-file source size limit reached";
          None)
        else (
          bytes := !bytes + size;
          Some a)
    | None -> (
        try
          if (Unix.stat path).Unix.st_kind <> Unix.S_REG then
            invalid_arg "Loaded source is not a regular file";
          let ch = open_in_bin path in
          let text =
            Fun.protect
              ~finally:(fun () -> close_in_noerr ch)
              (fun () ->
                let size = in_channel_length ch in
                if size > 4 * 1024 * 1024 || !bytes + size > 16 * 1024 * 1024
                then invalid_arg "cross-file source size limit";
                bytes := !bytes + size;
                really_input_string ch size)
          in
          let uri = Lsp.Uri.to_string (Lsp.Uri.of_path path) in
          Some (Analysis.analyze (Source.create ~uri ~version:0 text))
        with
        | Sys_error _ | Unix.Unix_error _ | Invalid_argument _ | Failure _ ->
          issue ("Cannot analyze loaded file: " ^ path);
          None)
  in
  let queue = Queue.create () in
  let add depth a = Queue.add (depth, a) queue in
  add 0 entry;
  List.iter
    (fun path ->
      let current =
        Option.map canonical (path_of_uri (Source.uri (Analysis.source entry)))
      in
      if Some path <> current then (
        scheduled := Paths.add path !scheduled;
        match read path with None -> () | Some a -> add 0 a))
    entrypoints;
  while not (Queue.is_empty queue) do
    let depth, a = Queue.take queue in
    let src = Analysis.source a in
    let key =
      match path_of_uri (Source.uri src) with
      | Some p -> canonical p
      | None -> Source.uri src
    in
    if not (Paths.mem key !visited) then (
      visited := Paths.add key !visited;
      if !count >= 128 || depth > 32 then
        issue "Cross-file analysis limit reached"
      else (
        incr count;
        analyses := a :: !analyses;
        Hashtbl.replace sources (Source.uri src) src;
        match path_of_uri (Source.uri src) with
        | None -> ()
        | Some importer ->
            List.iter
              (fun (load : Analysis.load) ->
                match load.path with
                | None ->
                    issue "Dynamic load path cannot be followed statically"
                | Some path ->
                    let paths = load_paths (canonical importer) path in
                    if paths = [] then issue ("Loaded file not found: " ^ path);
                    List.iter
                      (fun path ->
                        if
                          (not (Paths.mem path !visited))
                          && (not (Paths.mem path !scheduled))
                          && depth < 32
                          && !count + Queue.length queue < 128
                        then (
                          scheduled := Paths.add path !scheduled;
                          match read path with
                          | None -> ()
                          | Some a -> add (depth + 1) a)
                        else if
                          not
                            (Paths.mem path !visited
                           || Paths.mem path !scheduled)
                        then issue "Cross-file analysis limit reached")
                      paths)
              (Analysis.loads a)))
  done;
  let analyses = List.rev !analyses in
  let entry = Analysis.analyze ~imports:analyses (Analysis.source entry) in
  { entry; analyses; sources; issues = List.rev !problems }

let analysis t = t.entry
let source t uri = Hashtbl.find_opt t.sources uri
let issues t = t.issues

let resolve t analysis (o : Analysis.occurrence) =
  let imported () =
    List.concat_map
      (fun a ->
        if
          Source.uri (Analysis.source a) = Source.uri (Analysis.source analysis)
        then []
        else
          List.filter
            (fun (b : Analysis.binding) -> b.kind = Global && b.name = o.name)
            (Analysis.bindings a))
      t.analyses
  in
  let candidates own =
    match own @ imported () with
    | [] -> o.resolution
    | bs ->
        Analysis.Candidates
          ( bs,
            let context =
              "assignments in this document, configured entrypoints, and \
               literal-load dependencies; runtime execution order is not \
               proven"
            in
            match o.resolution with
            | (Analysis.Candidates (_, why) | Analysis.Runtime_dependent why)
              when String.starts_with ~prefix:"global lookup may be shadowed"
                     why ->
                why ^ "; " ^ context
            | _ -> context )
  in
  match o.resolution with
  | Analysis.Candidates (bs, _)
    when List.exists (fun (b : Analysis.binding) -> b.kind = Column) bs ->
      o.resolution
  | Analysis.Candidates (bs, _) -> candidates bs
  | Analysis.Unresolved _ -> candidates []
  | Analysis.Runtime_dependent why
    when String.starts_with ~prefix:"global lookup" why ->
      candidates []
  | _ -> o.resolution
