type t
(** A bounded snapshot of statically reachable source files. Open editor
    documents override disk content. No Rayfall is evaluated. *)

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

type snapshot = t

module Cache : sig
  type t

  val create : unit -> t
  (** Retain at most four recent entry-document snapshots. *)

  val get :
    t ->
    roots:string list ->
    documents:Analysis.t list ->
    Analysis.t ->
    snapshot
  (** Reuse only while roots and open-document identities match and every
      observed disk path has the same identity, size, modification and change
      times. Missing load/configuration candidates are observed too. *)
end
