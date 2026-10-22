module Names = Map.Make (String)

type binding_kind = Global | Local | Parameter
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

type t = {
  source : Source.t;
  syntax : Syntax.t;
  bindings : binding list;
  occurrences : occurrence list;
}

type value_info = { origins : location list; unknown : bool }

type env = {
  locals : binding Names.t list;
  globals : binding Names.t;
  deferred : bool;
  opaque : bool;
}

let unknown = { origins = []; unknown = true }

let builtin_names =
  [
    "set";
    "let";
    "fn";
    "do";
    "if";
    "while";
    "times";
    "try";
    "quote";
    "select";
    "update";
    "delete";
    "load";
    "eval";
    "resolve";
    "+";
    "-";
    "*";
    "/";
    "%";
    "==";
    "!=";
    "<";
    ">";
    "<=";
    ">=";
    "not";
    "and";
    "or";
    "as";
    "list";
    "dict";
    "table";
    "at";
    "get";
    "count";
    "sum";
    "min";
    "max";
    "til";
    "println";
    "print";
  ]

let local env name = List.find_map (Names.find_opt name) env.locals
let source t = t.source
let syntax t = t.syntax
let bindings t = t.bindings
let occurrences t = t.occurrences

let targets = function
  | Resolved b -> [ b ]
  | Candidates (bs, _) -> bs
  | _ -> []

let describe = function
  | Resolved b ->
      (match b.kind with
        | Parameter -> "Parameter"
        | Local -> "Local binding"
        | Global -> "Global assignment")
      ^ ": " ^ b.name
  | Candidates (_, why) -> "Candidate definitions: " ^ why
  | Runtime_dependent why -> "Runtime-dependent: " ^ why
  | Unresolved why -> "Unresolved: " ^ why
  | Builtin name -> "Builtin: " ^ name ^ " (source lookup unavailable)"

let at t byte =
  match
    List.find_opt
      (fun o -> o.span.start_byte <= byte && byte < o.span.end_byte)
      t.occurrences
  with
  | Some _ as o -> o
  | None -> List.find_opt (fun o -> o.span.end_byte = byte) t.occurrences

let analyze source =
  let syntax = Syntax.parse source in
  let bindings = ref []
  and pending = ref []
  and values = Hashtbl.create 32
  and next = ref 0 in
  let node i = syntax.nodes.(i)
  and text i = Syntax.text syntax i
  and children i = Syntax.named_children syntax i in
  let remember ?(declaration = false) i name resolution value =
    pending := (i, name, declaration, resolution, value) :: !pending
  in
  let add kind i name value =
    let b =
      {
        id = !next;
        name;
        location = { uri = Source.uri source; span = (node i).span };
        kind;
      }
    in
    incr next;
    bindings := b :: !bindings;
    Hashtbl.add values b.id value;
    remember ~declaration:true i name (`Known (Resolved b)) value;
    b
  in
  let value b = Option.value (Hashtbl.find_opt values b.id) ~default:unknown in
  let lookup env name =
    match local env name with
    | Some b -> (`Known (Resolved b), value b)
    | None when env.deferred || env.opaque -> (`Global name, unknown)
    | None -> (
        match Names.find_opt name env.globals with
        | Some b -> (`Known (Resolved b), value b)
        | None when List.mem name builtin_names ->
            (`Known (Builtin name), unknown)
        | None ->
            ( `Known (Unresolved ("no binding in this document for " ^ name)),
              unknown ))
  in
  let opaque i reason =
    let pending = ref [ i ] in
    while !pending <> [] do
      match !pending with
      | [] -> ()
      | i :: rest -> (
          pending := rest;
          match (node i).kind with
          | "identifier" ->
              remember i (text i) (`Known (Runtime_dependent reason)) unknown
          | "quoted_symbol" | "vector" | "string" | "comment" -> ()
          | "pair" -> (
              match List.rev (children i) with
              | v :: _ -> pending := v :: !pending
              | [] -> ())
          | _ -> pending := List.rev_append (children i) !pending)
    done
  in
  let rec walk depth env i =
    if depth > 256 then (
      opaque i "analysis nesting limit";
      (env, unknown))
    else
      match (node i).kind with
      | "identifier" ->
          let r, v = lookup env (text i) in
          remember i (text i) r v;
          (env, v)
      | "source_file" -> sequence depth env (children i)
      | "dictionary" | "vector" | "quoted_symbol" | "string" | "comment" ->
          (env, unknown)
      | "ERROR" ->
          opaque i "incomplete syntax";
          (env, unknown)
      | "call" -> (
          match children i with
          | [] -> (env, unknown)
          | head :: args ->
              let name = text head in
              let shadowed =
                local env name <> None || Names.mem name env.globals
              in
              let special = (node head).kind = "identifier" && not shadowed in
              let head_ref () =
                remember head name (`Known (Builtin name)) unknown
              in
              if special && name = "quote" then (
                head_ref ();
                (env, unknown))
              else if special && name = "if" then (
                head_ref ();
                (* Analyze each arm separately: lexical parameters remain in
                   scope, but branch writes cannot establish later globals. *)
                List.iter
                  (fun j ->
                    ignore (walk (depth + 1) { env with opaque = true } j))
                  args;
                ({ env with opaque = true }, unknown))
              else if
                special
                && List.mem name
                     [ "while"; "times"; "try"; "eval"; "resolve"; "load" ]
              then (
                head_ref ();
                List.iter
                  (fun j ->
                    opaque j
                      (name ^ " requires control-flow or runtime analysis"))
                  args;
                ({ env with opaque = true }, unknown))
              else if special && List.mem name [ "select"; "update"; "delete" ]
              then (
                head_ref ();
                List.iter
                  (fun j -> opaque j "query scopes are not implemented")
                  args;
                (env, unknown))
              else if special && name = "fn" then (
                head_ref ();
                match args with
                | params :: body when (node params).kind = "vector" ->
                    let scope =
                      List.fold_left
                        (fun scope p ->
                          if (node p).kind = "identifier" then
                            let b = add Parameter p (text p) unknown in
                            Names.add b.name b scope
                          else scope)
                        Names.empty (children params)
                    in
                    ignore
                      (sequence (depth + 1)
                         {
                           env with
                           locals = scope :: env.locals;
                           deferred = true;
                           opaque = env.opaque;
                         }
                         body);
                    ( env,
                      {
                        origins =
                          [ { uri = Source.uri source; span = (node i).span } ];
                        unknown = false;
                      } )
                | _ ->
                    opaque i "incomplete function parameters";
                    (env, unknown))
              else if special && name = "do" then (
                head_ref ();
                let inner, v =
                  sequence (depth + 1)
                    { env with locals = Names.empty :: env.locals }
                    args
                in
                ({ env with globals = inner.globals; opaque = inner.opaque }, v))
              else if special && List.mem name [ "set"; "let" ] then (
                head_ref ();
                match args with
                | [ label; rhs ] when (node label).kind = "identifier" -> (
                    let env, v = walk (depth + 1) env rhs in
                    let global = name = "set" || env.locals = [] in
                    let b =
                      add
                        (if global then Global else Local)
                        label (text label) v
                    in
                    if global then
                      ({ env with globals = Names.add b.name b env.globals }, v)
                    else
                      match env.locals with
                      | scope :: rest ->
                          ( {
                              env with
                              locals = Names.add b.name b scope :: rest;
                            },
                            v )
                      | [] -> assert false)
                | _ ->
                    List.iter (fun j -> opaque j "invalid binding form") args;
                    (env, unknown))
              else
                let env, _ = walk (depth + 1) env head in
                let env, _ = sequence (depth + 1) env args in
                let known_builtin = special && List.mem name builtin_names in
                ({ env with opaque = env.opaque || not known_builtin }, unknown)
          )
      | _ -> (env, unknown)
  and sequence depth env nodes =
    List.fold_left (fun (env, _) i -> walk depth env i) (env, unknown) nodes
  in
  ignore
    (walk 0
       { locals = []; globals = Names.empty; deferred = false; opaque = false }
       0);
  let bindings = List.rev !bindings in
  let occurrences =
    List.rev_map
      (fun (i, name, declaration, r, v) ->
        let resolution =
          match r with
          | `Known r -> r
          | `Global name ->
              let bs =
                List.filter (fun b -> b.kind = Global && b.name = name) bindings
              in
              if bs = [] then
                Runtime_dependent
                  "global lookup depends on the call/execution context"
              else
                Candidates
                  ( bs,
                    "global lookup depends on execution; document assignments \
                     are possible targets" )
        in
        {
          name;
          span = (node i).span;
          declaration;
          resolution;
          origins = v.origins;
          origin_unknown = v.unknown;
        })
      !pending
  in
  { source; syntax; bindings; occurrences }
