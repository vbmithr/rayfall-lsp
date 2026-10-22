type position = { line : int; character : int }
type span = { start_byte : int; end_byte : int }

type t = {
  uri : string;
  version : int;
  text : string;
  boundaries : (int * position) array;
  lines : int array;
}

let create ~uri ~version text =
  if String.length text > 4 * 1024 * 1024 then
    invalid_arg "Rayfall source exceeds the 4 MiB prototype limit";
  let boundaries = ref [ (0, { line = 0; character = 0 }) ]
  and line = ref 0
  and character = ref 0
  and lines = ref [ 0 ] in
  Uutf.String.fold_utf_8
    (fun () byte -> function
      | `Malformed _ -> invalid_arg "Document must be valid UTF-8"
      | `Uchar u ->
          let cp = Uchar.to_int u in
          let width =
            if cp < 0x80 then 1
            else if cp < 0x800 then 2
            else if cp < 0x10000 then 3
            else 4
          in
          let next = byte + width in
          if cp = 10 then (
            incr line;
            character := 0;
            lines := next :: !lines)
          else character := !character + if cp > 0xffff then 2 else 1;
          boundaries :=
            (next, { line = !line; character = !character }) :: !boundaries)
    () text;
  {
    uri;
    version;
    text;
    boundaries = Array.of_list (List.rev !boundaries);
    lines = Array.of_list (List.rev !lines);
  }

let text t = t.text
let uri t = t.uri
let version t = t.version
let length t = String.length t.text
let slice t s = String.sub t.text s.start_byte (s.end_byte - s.start_byte)

let position t byte =
  if byte < 0 || byte > length t then invalid_arg "Byte offset outside document";
  let rec find lo hi =
    if lo > hi then invalid_arg "Byte offset splits UTF-8 character"
    else
      let mid = (lo + hi) / 2 in
      let b, p = t.boundaries.(mid) in
      if b = byte then p
      else if b < byte then find (mid + 1) hi
      else find lo (mid - 1)
  in
  find 0 (Array.length t.boundaries - 1)

let offset t p =
  if p.line < 0 || p.line >= Array.length t.lines || p.character < 0 then
    invalid_arg "Position outside document";
  let start = t.lines.(p.line) in
  let limit =
    if p.line + 1 < Array.length t.lines then t.lines.(p.line + 1) - 1
    else length t
  in
  let limit =
    if limit > start && t.text.[limit - 1] = '\r' then limit - 1 else limit
  in
  let rec find lo hi =
    if lo > hi then
      invalid_arg "Position splits a UTF-16 character or exceeds line"
    else
      let mid = (lo + hi) / 2 in
      let b, q = t.boundaries.(mid) in
      let c = compare (q.line, q.character) (p.line, p.character) in
      if c = 0 && b <= limit then b
      else if c < 0 then find (mid + 1) hi
      else find lo (mid - 1)
  in
  find 0 (Array.length t.boundaries - 1)

let position_json p =
  `Assoc [ ("line", `Int p.line); ("character", `Int p.character) ]

let range_json t s =
  `Assoc
    [
      ("start", position_json (position t s.start_byte));
      ("end", position_json (position t s.end_byte));
    ]
