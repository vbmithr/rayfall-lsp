type t
(** A bounded, request-scoped snapshot of statically reachable source files.
    Open editor documents override disk content. No Rayfall is evaluated. *)

val create : roots:string list -> documents:Analysis.t list -> Analysis.t -> t
val source : t -> string -> Source.t option
val resolve : t -> Analysis.t -> Analysis.occurrence -> Analysis.resolution
val issues : t -> string list
