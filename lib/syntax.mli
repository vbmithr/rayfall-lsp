type node = {
  kind : string;
  span : Source.span;
  named : bool;
  error : bool;
  missing : bool;
  children : int list;
}

type t = { source : Source.t; nodes : node array }

val parse : Source.t -> t
val named_children : t -> int -> int list
val text : t -> int -> string
val diagnostics : t -> (Source.span * string) list
