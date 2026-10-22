module Names = Map.Make (String)

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

type schema = {
  columns : binding list Names.t;
  complete : bool;
  certain : bool;
}

type t = {
  source : Source.t;
  syntax : Syntax.t;
  bindings : binding list;
  occurrences : occurrence list;
  loads : load list;
  exports : (string * schema option) list;
}

type value_info = {
  origins : location list;
  unknown : bool;
  schema : schema option;
}

type env = {
  locals : binding Names.t list;
  globals : binding Names.t;
  deferred : bool;
  opaque : bool;
  query : bool;
  columns : schema option;
}

let unknown = { origins = []; unknown = true; schema = None }

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
    "xasc";
    "xdesc";
    "ungroup";
    "left-join";
    "inner-join";
    "full-join";
    "alter";
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
let loads t = t.loads

let targets = function
  | Resolved b -> [ b ]
  | Candidates (bs, _) -> bs
  | _ -> []

let describe = function
  | Resolved b ->
      (match b.kind with
        | Parameter -> "Parameter"
        | Local -> "Local binding"
        | Global -> "Global assignment"
        | Column -> "Column")
      ^ ": " ^ b.name
  | Candidates (_, why) -> "Candidate definitions: " ^ why
  | Runtime_dependent why -> "Runtime-dependent: " ^ why
  | Unresolved why -> "Unresolved: " ^ why
  | Builtin name -> "Builtin: " ^ name ^ " (source lookup unavailable)"

let at t byte =
  match
    List.find_opt
      (fun (o : occurrence) ->
        o.span.start_byte <= byte && byte < o.span.end_byte)
      t.occurrences
  with
  | Some _ as o -> o
  | None ->
      List.find_opt
        (fun (o : occurrence) -> o.span.end_byte = byte)
        t.occurrences

let analyze ?(imports = []) source =
  let syntax = Syntax.parse source in
  let loads = ref [] in
  let bindings = ref []
  and pending = ref []
  and values = Hashtbl.create 32
  and next = ref 0 in
  let node i = syntax.nodes.(i)
  and text i = Syntax.text syntax i
  and children i = Syntax.named_children syntax i in
  let remember ?(declaration = false) ?span i name resolution value =
    let span = Option.value span ~default:(node i).span in
    pending := (span, name, declaration, resolution, value) :: !pending
  in
  let add ?(record = true) kind i name value =
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
    if record then remember ~declaration:true i name (`Known (Resolved b)) value;
    b
  in
  let value b = Option.value (Hashtbl.find_opt values b.id) ~default:unknown in
  let merge_schemas schemas =
    let known = List.filter_map Fun.id schemas in
    match known with
    | [] -> None
    | _ ->
        let columns =
          List.fold_left
            (fun acc (schema : schema) ->
              Names.union
                (fun _ left right ->
                  Some
                    (List.sort_uniq
                       (fun a b ->
                         compare
                           ( a.location.uri,
                             a.location.span.start_byte,
                             a.location.span.end_byte )
                           ( b.location.uri,
                             b.location.span.start_byte,
                             b.location.span.end_byte ))
                       (left @ right)))
                acc schema.columns)
            Names.empty known
        in
        Some { columns; complete = false; certain = false }
  in
  let global_schema name =
    let own =
      List.filter_map
        (fun b ->
          if b.kind = Global && b.name = name then Some (value b).schema
          else None)
        !bindings
    in
    let imported =
      List.concat_map
        (fun a ->
          List.filter_map
            (fun (n, s) -> if n = name then Some s else None)
            a.exports)
        imports
    in
    merge_schemas (own @ imported)
  in
  let rec lookup env name =
    match local env name with
    | Some b -> (`Known (Resolved b), value b)
    | None when env.query -> (
        match
          Option.bind env.columns (fun (schema : schema) ->
              Names.find_opt name schema.columns)
        with
        | Some [ b ]
          when Option.fold ~none:false ~some:(fun s -> s.certain) env.columns ->
            (`Known (Resolved b), unknown)
        | Some bs ->
            ( `Known
                (Candidates
                   (bs, "column origins depend on the source table assignment")),
              unknown )
        | None
          when Option.fold ~none:false
                 ~some:(fun (schema : schema) -> schema.complete)
                 env.columns ->
            lookup { env with query = false } name
        | None ->
            ( `Known
                (Runtime_dependent
                   "query name may be a column; source schema is unknown"),
              unknown ))
    | None when env.deferred || env.opaque ->
        (`Global name, { unknown with schema = global_schema name })
    | None -> (
        match Names.find_opt name env.globals with
        | Some b -> (`Known (Resolved b), value b)
        | None when List.mem name builtin_names ->
            (`Known (Builtin name), unknown)
        | None ->
            ( `Known (Unresolved ("no binding in this document for " ^ name)),
              { unknown with schema = global_schema name } ))
  in
  let remember_name ?definition ?name:given_name env i =
    let name = Option.value given_name ~default:(text i) in
    let parts = String.split_on_char '.' name in
    let root = List.hd parts in
    let resolve prefix =
      match definition with
      | Some b when prefix = name -> (`Known (Resolved b), value b)
      | _
        when prefix <> root && local env root <> None && local env prefix = None
        ->
          ( `Known
              (Runtime_dependent "member lookup depends on the lexical value"),
            unknown )
      | _
        when env.query && prefix = root
             && Option.fold ~none:false
                  ~some:(fun (schema : schema) -> Names.mem root schema.columns)
                  env.columns ->
          lookup env prefix
      | _
        when env.query && prefix <> root
             && Option.fold ~none:false
                  ~some:(fun (schema : schema) -> Names.mem root schema.columns)
                  env.columns ->
          ( `Known
              (Runtime_dependent
                 "member of a query column requires type analysis"),
            unknown )
      | _
        when env.query
             && List.length parts > 1
             && root <> ""
             && Option.fold ~none:false
                  ~some:(fun (schema : schema) -> schema.complete)
                  env.columns ->
          lookup { env with query = false } prefix
      | _ when env.query && List.length parts > 1 && root <> "" -> (
          let r, v =
            lookup { env with query = false; deferred = true } prefix
          in
          match r with `Global name -> (`Query_global name, v) | _ -> (r, v))
      | _ -> lookup env prefix
    in
    let emit ?span prefix =
      let r, v = resolve prefix in
      remember
        ~declaration:(Option.is_some definition && prefix = name)
        ?span i prefix r v;
      v
    in
    match parts with
    | root :: (_ :: _ as fields)
      when root <> "" && List.for_all (( <> ) "") fields ->
        let start = (node i).span.end_byte - String.length name in
        ignore
          (emit
             ~span:
               {
                 Source.start_byte = start;
                 end_byte = start + String.length root;
               }
             root);
        let _, _, v =
          List.fold_left
            (fun (prefix, offset, _) field ->
              let prefix = prefix ^ "." ^ field and offset = offset + 1 in
              let v =
                emit
                  ~span:
                    {
                      Source.start_byte = start + offset;
                      end_byte = start + offset + String.length field;
                    }
                  prefix
              in
              (prefix, offset + String.length field, v))
            (root, String.length root, unknown)
            fields
        in
        v
    | _ ->
        emit
          ~span:
            {
              Source.start_byte = (node i).span.end_byte - String.length name;
              end_byte = (node i).span.end_byte;
            }
          name
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
      | "identifier" -> (env, remember_name env i)
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
                (if name = "load" then
                   let path =
                     match args with
                     | [ arg ] when (node arg).kind = "string" -> (
                         try
                           match Yojson.Safe.from_string (text arg) with
                           | `String s -> Some s
                           | _ -> None
                         with Yojson.Json_error _ -> None)
                     | _ -> None
                   in
                   loads := { path; span = (node i).span } :: !loads);
                List.iter
                  (fun j ->
                    opaque j
                      (name ^ " requires control-flow or runtime analysis"))
                  args;
                ({ env with opaque = true }, unknown))
              else if special && List.mem name [ "select"; "update"; "delete" ]
              then (
                head_ref ();
                query depth env name args)
              else if special && name = "table" then (
                head_ref ();
                let env, _ = sequence (depth + 1) env args in
                let schema =
                  match args with
                  | [ names; _ ]
                    when (node names).kind = "vector"
                         && List.for_all
                              (fun i -> (node i).kind = "identifier")
                              (children names) ->
                      let columns =
                        List.fold_left
                          (fun acc i ->
                            let b = add Column i (text i) unknown in
                            Names.add b.name [ b ] acc)
                          Names.empty (children names)
                      in
                      Some { columns; complete = true; certain = true }
                  | _ -> None
                in
                (env, { unknown with schema }))
              else if special && List.mem name [ "xasc"; "xdesc"; "ungroup" ]
              then (
                head_ref ();
                match args with
                | first :: rest ->
                    let env, v = walk (depth + 1) env first in
                    let env, _ = sequence (depth + 1) env rest in
                    (env, v)
                | [] -> (env, unknown))
              else if
                special
                && List.mem name [ "left-join"; "inner-join"; "full-join" ]
              then (
                head_ref ();
                let env, values =
                  List.fold_left
                    (fun (env, vs) arg ->
                      let env, v = walk (depth + 1) env arg in
                      (env, (arg, v) :: vs))
                    (env, []) args
                in
                let inputs =
                  match List.rev values with
                  | [ (keys, _); (_, left); (_, right) ]
                    when (node keys).kind = "vector" ->
                      Some (keys, left, right)
                  | [ (_, left); (_, right); (keys, _) ]
                    when (node keys).kind = "vector" ->
                      Some (keys, left, right)
                  | _ -> None
                in
                let schema =
                  Option.bind inputs (fun (keys, left, right) ->
                      let key_nodes = children keys in
                      if
                        key_nodes = []
                        || not
                             (List.for_all
                                (fun i -> (node i).kind = "identifier")
                                key_nodes)
                      then None
                      else
                        match (left.schema, right.schema) with
                        | Some l, Some r
                          when List.for_all
                                 (fun key ->
                                   Names.mem (text key) l.columns
                                   && Names.mem (text key) r.columns)
                                 key_nodes ->
                            let distinct bs =
                              List.sort_uniq
                                (fun a b ->
                                  compare
                                    ( a.location.uri,
                                      a.location.span.start_byte,
                                      a.location.span.end_byte )
                                    ( b.location.uri,
                                      b.location.span.start_byte,
                                      b.location.span.end_byte ))
                                bs
                            in
                            let names = List.map text key_nodes in
                            List.iter
                              (fun key ->
                                let bs =
                                  distinct
                                    (Names.find (text key) l.columns
                                    @ Names.find (text key) r.columns)
                                in
                                remember key (text key)
                                  (`Known
                                     (Candidates
                                        ( bs,
                                          "join key refers to both input tables"
                                        )))
                                  unknown)
                              key_nodes;
                            let columns =
                              Names.union
                                (fun key left right ->
                                  if List.mem key names && name = "full-join"
                                  then Some (distinct (left @ right))
                                  else Some left)
                                l.columns
                                (Names.filter
                                   (fun key _ ->
                                     (not (List.mem key names))
                                     || name = "full-join")
                                   r.columns)
                            in
                            Some
                              {
                                columns;
                                complete = l.complete && r.complete;
                                certain =
                                  l.certain && r.certain && l.complete
                                  && r.complete;
                              }
                        | _ -> None)
                in
                (env, { unknown with schema }))
              else if special && name = "alter" then (
                head_ref ();
                match args with
                | target :: op :: rest ->
                    if (node target).kind = "quoted_symbol" then
                      let target_name =
                        String.sub (text target) 1
                          (String.length (text target) - 1)
                      in
                      let root =
                        List.hd (String.split_on_char '.' target_name)
                      in
                      if local env root <> None then
                        remember target target_name
                          (`Known
                             (Runtime_dependent "alter rejects lexical targets"))
                          unknown
                      else
                        ignore
                          (remember_name ~name:target_name
                             { env with query = false } target)
                    else ignore (walk (depth + 1) env target);
                    (* The operation name is unevaluated data, not the set/concat function. *)
                    ignore op;
                    let env, _ = sequence (depth + 1) env rest in
                    ({ env with opaque = true }, unknown)
                | _ ->
                    List.iter (fun j -> opaque j "incomplete alter") args;
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
                        schema = None;
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
                      add ~record:false
                        (if global then Global else Local)
                        label (text label) v
                    in
                    ignore (remember_name ~definition:b env label);
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
  and query depth env verb args =
    match args with
    | [ dict ] when (node dict).kind = "dictionary" ->
        let clauses =
          List.filter_map
            (fun pair ->
              match children pair with
              | [ key; expr ] ->
                  let name =
                    if (node key).kind = "string" then
                      try
                        Yojson.Safe.Util.to_string
                          (Yojson.Safe.from_string (text key))
                      with
                      | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ ->
                        text key
                    else text key
                  in
                  Some (name, key, expr)
              | _ ->
                  opaque pair "incomplete query clause";
                  None)
            (children dict)
        in
        let source_value =
          match List.find_opt (fun (key, _, _) -> key = "from") clauses with
          | Some (_, _, expr) -> snd (walk (depth + 1) env expr)
          | None -> unknown
        in
        let qenv = { env with query = true; columns = source_value.schema } in
        let outputs = ref Names.empty
        and projections = ref 0
        and grouped = ref false
        and grouping_known = ref true
        and deletion = ref false in
        let output key name expr =
          ignore (walk (depth + 1) qenv expr);
          let b = add Column key name unknown in
          outputs := Names.add name [ b ] !outputs
        in
        List.iter
          (fun (key, key_node, expr) ->
            if key = "from" then ()
            else if key = "where" then ignore (walk (depth + 1) qenv expr)
            else if key = "by" then (
              grouped := true;
              if (node expr).kind = "dictionary" then
                List.iter
                  (fun pair ->
                    match children pair with
                    | [ label; value ] when (node label).kind = "dictionary_key"
                      ->
                        output label (text label) value
                    | _ ->
                        grouping_known := false;
                        opaque pair "grouping schema is unknown")
                  (children expr)
              else if (node expr).kind = "identifier" then (
                ignore (walk (depth + 1) qenv expr);
                let b = add ~record:false Column expr (text expr) unknown in
                outputs := Names.add b.name [ b ] !outputs)
              else if
                (node expr).kind = "vector"
                && List.for_all
                     (fun j -> (node j).kind = "identifier")
                     (children expr)
              then (
                if children expr = [] then grouped := false;
                List.iter
                  (fun j ->
                    let column =
                      Option.bind source_value.schema (fun (schema : schema) ->
                          Names.find_opt (text j) schema.columns)
                    in
                    let resolution =
                      match column with
                      | Some bs ->
                          Candidates (bs, "grouping vector names source columns")
                      | None ->
                          Runtime_dependent "grouping column schema is unknown"
                    in
                    remember j (text j) (`Known resolution) unknown;
                    let b = add ~record:false Column j (text j) unknown in
                    outputs := Names.add b.name [ b ] !outputs)
                  (children expr))
              else (
                grouping_known := false;
                ignore (walk (depth + 1) qenv expr)))
            else if List.mem key [ "asc"; "desc"; "take"; "nearest" ] then
              opaque expr "query ordering and control clauses are not analyzed"
            else if verb = "delete" then (
              deletion := true;
              opaque expr "delete column names require schema analysis")
            else (
              incr projections;
              output key_node key expr))
          clauses;
        let schema =
          if verb = "delete" then
            if !deletion then None else source_value.schema
          else if verb = "select" && !projections = 0 && not !grouped then
            source_value.schema
          else if verb = "select" && !projections = 0 then
            let base =
              Option.value source_value.schema
                ~default:
                  { columns = Names.empty; complete = false; certain = true }
            in
            Some
              {
                base with
                columns =
                  Names.union
                    (fun _ _ newer -> Some newer)
                    base.columns !outputs;
                complete = base.complete && !grouping_known;
              }
          else if verb = "select" then
            Some
              { columns = !outputs; complete = !grouping_known; certain = true }
          else if !grouped then None
          else
            let base =
              Option.value source_value.schema
                ~default:
                  { columns = Names.empty; complete = false; certain = true }
            in
            Some
              {
                base with
                columns =
                  Names.union
                    (fun _ _ newer -> Some newer)
                    base.columns !outputs;
              }
        in
        (env, { unknown with schema })
    | _ ->
        List.iter
          (fun j -> opaque j "query dictionary is not statically known")
          args;
        (env, unknown)
  and sequence depth env nodes =
    List.fold_left (fun (env, _) i -> walk depth env i) (env, unknown) nodes
  in
  ignore
    (walk 0
       {
         locals = [];
         globals = Names.empty;
         deferred = false;
         opaque = false;
         query = false;
         columns = None;
       }
       0);
  let bindings = List.rev !bindings in
  let occurrences =
    List.rev_map
      (fun (span, name, declaration, r, v) ->
        let resolution =
          match r with
          | `Known r -> r
          | `Global name | `Query_global name ->
              let query = match r with `Query_global _ -> true | _ -> false in
              let reason =
                if query then
                  "global lookup may be shadowed by a query column; source \
                   schema is unknown"
                else "global lookup depends on the call/execution context"
              in
              let bs =
                List.filter (fun b -> b.kind = Global && b.name = name) bindings
              in
              if bs = [] then Runtime_dependent reason
              else
                Candidates
                  ( bs,
                    if query then reason
                    else
                      "global lookup depends on execution; document \
                       assignments are possible targets" )
        in
        {
          name;
          span;
          declaration;
          resolution;
          origins = v.origins;
          origin_unknown = v.unknown;
        })
      !pending
  in
  let exports =
    List.filter_map
      (fun b ->
        if b.kind = Global then Some (b.name, (value b).schema) else None)
      bindings
  in
  { source; syntax; bindings; occurrences; loads = List.rev !loads; exports }
