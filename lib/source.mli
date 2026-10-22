type position = { line : int; character : int }
type span = { start_byte : int; end_byte : int }
type t

val create : uri:string -> version:int -> string -> t
val text : t -> string
val uri : t -> string
val version : t -> int
val length : t -> int
val slice : t -> span -> string
val position : t -> int -> position
val offset : t -> position -> int
val position_json : position -> Yojson.Safe.t
val range_json : t -> span -> Yojson.Safe.t
