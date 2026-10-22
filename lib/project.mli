type t
(** A bounded, request-scoped snapshot of statically reachable source files.
    Open editor documents override disk content. No Rayfall is evaluated. *)

val create : roots:string list -> documents:Analysis.t list -> Analysis.t -> t

val analysis : t -> Analysis.t
(** The current document enriched with column origins from dependencies. *)

val source : t -> string -> Source.t option
val resolve : t -> Analysis.t -> Analysis.occurrence -> Analysis.resolution
val issues : t -> string list

type reference_result = {
  definite : Analysis.location list;
  possible : Analysis.location list;
}

val references :
  t -> include_declaration:bool -> Analysis.binding -> reference_result
(** Search the current bounded load graph, separating definite references from
    possible matches. Locations, names and kinds identify bindings across
    parses. *)
