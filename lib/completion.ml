type item = { label : string; span : Source.span; shape : Analysis.structure }

let fields analysis byte =
  let syntax = Analysis.syntax analysis in
  let node i = syntax.Syntax.nodes.(i) in
  let text i = Syntax.text syntax i in
  let source = Analysis.source analysis in
  let receiver span =
    List.find_map
      (fun (o : Analysis.occurrence) ->
        if o.span = span then o.structure else None)
      (Analysis.occurrences analysis)
  in
  let suggestions shape span =
    let prefix = Source.slice source { span with Source.end_byte = byte } in
    List.filter_map
      (fun label ->
        if String.starts_with ~prefix label then Some { label; span; shape }
        else None)
      shape.Analysis.fields
  in
  let context = ref None in
  Array.iteri
    (fun i (n : Syntax.node) ->
      if n.span.start_byte < byte && byte <= n.span.end_byte then
        if n.kind = "identifier" then (
          let before = Source.slice source { n.span with end_byte = byte } in
          match String.rindex_opt before '.' with
          | None -> ()
          | Some dot ->
              let base = String.sub before 0 dot in
              (* Require the exact receiver occurrence: never borrow a shape from
               another lexical scope or from literal/quoted data. *)
              let receiver_span =
                {
                  Source.start_byte =
                    (n.span.start_byte
                    +
                    match String.rindex_opt base '.' with
                    | None -> 0
                    | Some d -> d + 1);
                  end_byte = n.span.start_byte + dot;
                }
              in
              let suffix =
                Source.slice source
                  { Source.start_byte = byte; end_byte = n.span.end_byte }
              in
              if not (String.contains suffix '.') then
                Option.iter
                  (fun shape ->
                    context :=
                      Some
                        ( shape,
                          {
                            Source.start_byte = n.span.start_byte + dot + 1;
                            end_byte = n.span.end_byte;
                          } ))
                  (receiver receiver_span))
        else if n.kind = "call" then
          match Syntax.named_children syntax i with
          | [ head; target; key ]
            when text head = "at"
                 && (node key).kind = "quoted_symbol"
                 && (node key).span.start_byte < byte
                 && byte <= (node key).span.end_byte ->
              let builtin =
                match Analysis.at analysis (node head).span.start_byte with
                | Some { resolution = Analysis.Builtin "at"; _ } -> true
                | _ -> false
              in
              if builtin then
                Option.iter
                  (fun shape ->
                    context :=
                      Some
                        ( shape,
                          {
                            (node key).span with
                            start_byte = (node key).span.start_byte + 1;
                          } ))
                  (receiver (node target).span)
          | _ -> ())
    syntax.nodes;
  match !context with
  | None -> []
  | Some (shape, span) -> suggestions shape span
