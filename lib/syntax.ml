type tree

external parse_tree : string -> tree = "rayfall_parse"

external raw_nodes : tree -> (string * int * int * int * int) array
  = "rayfall_tree_nodes"

external release_tree : tree -> unit = "rayfall_tree_release"

type node = {
  kind : string;
  span : Source.span;
  named : bool;
  error : bool;
  missing : bool;
  children : int list;
}

type t = { source : Source.t; nodes : node array }

let parse source =
  let tree = parse_tree (Source.text source) in
  let raw =
    Fun.protect
      ~finally:(fun () -> release_tree tree)
      (fun () -> raw_nodes tree)
  in
  let children = Array.make (Array.length raw) [] in
  Array.iteri
    (fun i (_, _, _, parent, _) ->
      if parent >= 0 then children.(parent) <- i :: children.(parent))
    raw;
  let nodes =
    Array.mapi
      (fun i (kind, start_byte, end_byte, _, flags) ->
        {
          kind;
          span = { Source.start_byte; end_byte };
          named = flags land 1 <> 0;
          error = flags land 2 <> 0;
          missing = flags land 4 <> 0;
          children = List.rev children.(i);
        })
      raw
  in
  { source; nodes }

let named_children t i =
  List.filter
    (fun j -> t.nodes.(j).named && t.nodes.(j).kind <> "comment")
    t.nodes.(i).children

let text t i = Source.slice t.source t.nodes.(i).span

let diagnostics t =
  Array.fold_right
    (fun n acc ->
      if n.error then
        (n.span, "Unrecognized or incomplete Rayfall syntax") :: acc
      else if n.missing then (n.span, "Missing " ^ n.kind) :: acc
      else acc)
    t.nodes []
