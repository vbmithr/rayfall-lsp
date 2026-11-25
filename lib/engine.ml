type signature = {
  kind : string;
  builtin : string;
  special : bool;
  summary : string;
  usage : string;
}

type t = {
  run : string -> string option;
  cache : (string, signature option) Hashtbl.t;
}

let name_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' -> true
  | '_' | '.' | '?' | '!' | '+' | '*' | '/' | '<' | '=' | '>' | '%' | '~' | '#'
  | '$' | '&' | ':' | '^' | '|' | '-' ->
      true
  | _ -> false

let valid_name name =
  name <> "" && String.length name <= 128 && String.for_all name_char name

let fields = [ "kind"; "builtin"; "special"; "summary"; "usage" ]

(* One field per line: the summary is one line, usage comes last because it
   may be empty or contain anything. *)
let query name =
  List.map
    (fun field ->
      Printf.sprintf "(println (at (.repl.signature (quote %s)) (quote %s)))\n"
        name field)
    fields
  |> String.concat ""

let strip_quote s =
  let s = String.trim s in
  if String.starts_with ~prefix:"'" s then String.sub s 1 (String.length s - 1)
  else s

let is_calling_convention = function
  | "unary" | "binary" | "vary" -> true
  | _ -> false

let drop_final_newline output =
  if String.ends_with ~suffix:"\r\n" output then
    String.sub output 0 (String.length output - 2)
  else if String.ends_with ~suffix:"\n" output then
    String.sub output 0 (String.length output - 1)
  else output

let parse output =
  match String.split_on_char '\n' (drop_final_newline output) with
  | kind :: builtin :: special :: summary :: usage ->
      let kind = strip_quote kind and builtin = strip_quote builtin in
      if is_calling_convention kind && builtin <> "" then
        Some
          {
            kind;
            builtin;
            special = String.trim special = "true";
            summary = String.trim summary;
            usage = String.trim (String.concat "\n" usage);
          }
      else None
  | _ -> None

let read_all fd ~deadline =
  let buffer = Buffer.create 256 and chunk = Bytes.create 4096 in
  let rec loop () =
    let remaining = deadline -. Unix.gettimeofday () in
    if remaining <= 0. || Buffer.length buffer > 65536 then false
    else
      match Unix.select [ fd ] [] [] remaining with
      | [], _, _ -> false
      | _ -> (
          match Unix.read fd chunk 0 (Bytes.length chunk) with
          | 0 -> true
          | n ->
              Buffer.add_subbytes buffer chunk 0 n;
              loop ()
          | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ())
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
  in
  let finished = loop () in
  (finished, Buffer.contents buffer)

let close fd = try Unix.close fd with Unix.Unix_error _ -> ()

let spawn_and_read ~command ~deadline input =
  let stdin_r, stdin_w = Unix.pipe ~cloexec:true () in
  let stdout_r, stdout_w = Unix.pipe ~cloexec:true () in
  let null = Unix.openfile "/dev/null" [ Unix.O_WRONLY; Unix.O_CLOEXEC ] 0 in
  match Unix.create_process command [| command |] stdin_r stdout_w null with
  | exception e ->
      List.iter close [ stdin_r; stdin_w; stdout_r; stdout_w; null ];
      raise e
  | pid ->
      List.iter close [ stdin_r; stdout_w; null ];
      (try ignore (Unix.write_substring stdin_w input 0 (String.length input))
       with Unix.Unix_error _ -> ());
      close stdin_w;
      let finished, output = read_all stdout_r ~deadline in
      close stdout_r;
      (if not finished then try Unix.kill pid Sys.sigkill with _ -> ());
      (try ignore (Unix.waitpid [] pid) with Unix.Unix_error _ -> ());
      if finished then Some output else None

let run_process ~command ~timeout input =
  let deadline = Unix.gettimeofday () +. timeout in
  (* The child may exit before reading its input. *)
  let sigpipe = Sys.signal Sys.sigpipe Sys.Signal_ignore in
  Fun.protect ~finally:(fun () -> Sys.set_signal Sys.sigpipe sigpipe)
  @@ fun () ->
  try spawn_and_read ~command ~deadline input with Unix.Unix_error _ -> None

let create_with ~run = { run; cache = Hashtbl.create 64 }

let default_command () =
  match Sys.getenv_opt "RAYFALL_ENGINE" with
  | Some c when c <> "" -> c
  | _ -> "rayforce"

let create ?command ?(timeout = 3.) () =
  let command = match command with Some c -> c | None -> default_command () in
  create_with ~run:(run_process ~command ~timeout)

let lookup t name =
  if not (valid_name name) then None
  else
    match Hashtbl.find_opt t.cache name with
    | Some answer -> answer
    | None ->
        let answer = Option.bind (t.run (query name)) parse in
        Hashtbl.replace t.cache name answer;
        answer

let describe ~name s =
  let notes =
    (if s.builtin = name then [] else [ "alias of " ^ s.builtin ])
    @ if s.special then [ "special form" ] else []
  in
  let note =
    if notes = [] then "" else name ^ ": " ^ String.concat ", " notes
  in
  match List.filter (fun t -> t <> "") [ note; s.summary; s.usage ] with
  | [] -> Printf.sprintf "%s: builtin (%s)" name s.kind
  | parts -> String.concat "\n" parts
