type item = { label : string; span : Source.span; shape : Analysis.structure }

val fields : Analysis.t -> int -> item list
(** Complete only a syntactic member access or a literal key of builtin [at].
    Suggestions preserve the certainty of the receiver's static shape. *)
