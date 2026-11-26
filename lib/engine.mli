(** What the Rayforce engine says about a builtin.

    The engine is the only authority on its own builtins. The server asks it
    with [(.repl.signature 'name)], which evaluates and calls nothing, and never
    sends it project code. A missing, slow or older engine yields [None] and
    never an error: static navigation does not depend on it. *)

type signature = {
  kind : string;  (** [unary], [binary] or [vary]: the calling convention. *)
  builtin : string;
      (** The builtin's own name; differs from the name asked for when that name
          is an alias. *)
  special : bool;  (** A special form: its arguments are not evaluated. *)
  summary : string;
      (** What the builtin does, in one line, or [""] when undocumented. *)
  atomic : bool;
      (** Registered atomic: mapped over vectors and lists in every argument. *)
  aggregate : bool;  (** Registered as an aggregation that reduces a vector. *)
  elementwise : bool list;
      (** One flag per argument: whether it maps a vector element by element.
          [[]] when the engine does not describe the builtin, or predates the
          field. It describes one form of a builtin with several. *)
  usage : string;  (** Documented call forms, or [""] when undocumented. *)
}

type t

val valid_name : string -> bool
(** Only plain names reach the engine, never text interpolated into code. *)

val create : ?command:string -> ?timeout:float -> unit -> t
(** [command] is looked up on [PATH]. It defaults to [$RAYFALL_ENGINE], then
    ["rayforce"]. [timeout] bounds one lookup, in seconds (default 3). *)

val create_with : run:(string -> string option) -> t
(** An engine whose lookups are answered by [run input]; for tests. *)

val lookup : t -> string -> signature option
(** The signature of a builtin, [None] for any other name or no engine. Answers
    are cached for the life of [t], including negative ones. *)

val parse : string -> signature option
(** Parse the engine's reply to the query this module sends. *)

val describe : name:string -> signature -> string
(** Hover text for a builtin: a note when it is an alias or a special form, then
    its summary and usage. A builtin is always built in and its arity is in the
    usage, so the calling convention appears only when nothing else is known. *)
