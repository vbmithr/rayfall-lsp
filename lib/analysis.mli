type binding_kind = Global | Local | Parameter | Column
type location = { uri : string; span : Source.span }

type binding = {
  id : int;
  name : string;
  location : location;
  kind : binding_kind;
}

type resolution =
  | Resolved of binding
  | Candidates of binding list * string
  | Runtime_dependent of string
  | Unresolved of string
  | Builtin of string

type occurrence = {
  name : string;
  span : Source.span;
  declaration : bool;
  resolution : resolution;
  origins : location list;
  origin_unknown : bool;
}

type load = { path : string option; span : Source.span }
type t

val analyze : ?imports:t list -> Source.t -> t
(** Imported analyses contribute uncertain schema hints, never proof of runtime
    execution order or a final global value. *)

val loads : t -> load list
val source : t -> Source.t
val syntax : t -> Syntax.t
val bindings : t -> binding list
val at : t -> int -> occurrence option
val occurrences : t -> occurrence list
val targets : resolution -> binding list
val describe : resolution -> string
