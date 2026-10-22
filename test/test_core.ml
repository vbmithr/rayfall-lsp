open Rayfall

let analyze s =
  Analysis.analyze (Source.create ~uri:"file:///test.rfl" ~version:1 s)

let find s needle =
  let rec loop i =
    if i + String.length needle > String.length s then failwith needle
    else if String.sub s i (String.length needle) = needle then i
    else loop (i + 1)
  in
  loop 0

let occurrence a byte = Option.get (Analysis.at a byte)

let target a byte =
  match (occurrence a byte).resolution with
  | Analysis.Resolved b -> b
  | r -> failwith (Analysis.describe r)

let check_int = Alcotest.(check int)

let tests =
  [
    ( "dotted assignment separates namespace reference and field declaration",
      fun () ->
        let s = "(set bt {}) (set bt.buy_policy 'REJECT)" in
        let a = analyze s in
        let byte = find s "bt.buy_policy" in
        let root = occurrence a byte and field = occurrence a (byte + 3) in
        Alcotest.(check bool) "namespace is a reference" false root.declaration;
        Alcotest.(check bool) "field is a declaration" true field.declaration;
        check_int "namespace assignment" (find s "bt {}")
          (target a byte).location.span.start_byte;
        check_int "field assignment is itself" byte
          (target a (byte + 3)).location.span.start_byte );
    ( "dotted assignment respects lexical namespace shadowing",
      fun () ->
        let s = "(set bt {}) (set f (fn [bt] (set bt.buy_policy 'SCALE)))" in
        let a = analyze s in
        check_int "namespace parameter"
          (find s "[bt]" + 1)
          (target a (find s "bt.buy_policy")).location.span.start_byte );
    ( "dotted access distinguishes namespace and field",
      fun () ->
        let s = "(set bt {}) (set bt.cash0 42) (set report (fn [] bt.cash0))" in
        let a = analyze s in
        let byte = find s "bt.cash0))" in
        let root = occurrence a byte and field = occurrence a (byte + 3) in
        Alcotest.(check string) "namespace" "bt" root.name;
        Alcotest.(check string) "field" "bt.cash0" field.name;
        check_int "namespace assignment" (find s "bt {}")
          (List.hd (Analysis.targets root.resolution)).location.span.start_byte;
        check_int "field assignment" (find s "bt.cash0 42")
          (List.hd (Analysis.targets field.resolution)).location.span.start_byte
    );
    ( "local dotted root shadows global namespace",
      fun () ->
        let s = "(set bt {}) (set bt.cash0 42) (set f (fn [bt] bt.cash0))" in
        let a = analyze s in
        let byte = find s "bt.cash0))" in
        check_int "local namespace parameter"
          (find s "[bt]" + 1)
          (target a byte).location.span.start_byte;
        check_int "field must not resolve to global namespace" 0
          (List.length (Analysis.targets (occurrence a (byte + 3)).resolution))
    );
    ( "backtester nested map captures ctx and a local",
      fun () ->
        let s =
          "(load \"common.rfl\") (set lots (fn [ctx] (let buffer (at ctx \
           'buffer)) (map (fn [i] (* (at (at ctx 'mark) i) buffer)) (til 3))))"
        in
        let a = analyze s in
        check_int "captured context"
          (find s "[ctx]" + 1)
          (target a (find s "ctx 'mark")).location.span.start_byte;
        check_int "captured local" (find s "buffer (at")
          (target a (find s " buffer))" + 1)).location.span.start_byte;
        check_int "nested index"
          (find s "[i]" + 1)
          (target a (find s "i) buffer")).location.span.start_byte );
    ( "nested parameter shadows outer context",
      fun () ->
        let s = "(set f (fn [ctx] (map (fn [ctx] (+ ctx 1)) (list ctx))))" in
        let a = analyze s in
        check_int "inner context"
          (find s "(fn [ctx] (+" + 5)
          (target a (find s "ctx 1")).location.span.start_byte;
        check_int "outer context"
          (find s "[ctx]" + 1)
          (target a (find s "ctx))))")).location.span.start_byte );
    ( "strategy conditional keeps captured params",
      fun () ->
        let s =
          "(set trend (fn [ctx] (let p (at ctx 'params)) (if (ready ctx) (do \
           (let syms (at ctx 'syms)) (map (fn [i] (at p 'buffer)) syms)) \
           ctx)))"
        in
        let a = analyze s in
        check_int "captured params in branch" (find s "p (at")
          (target a (find s "p 'buffer")).location.span.start_byte;
        check_int "branch local" (find s "syms (at")
          (target a (find s " syms))" + 1)).location.span.start_byte;
        check_int "else context"
          (find s "[ctx]" + 1)
          (target a (find s "ctx)))")).location.span.start_byte );
    ( "parameter shadowing",
      fun () ->
        let s = "(set x 1) (set f (fn [x] (+ x 2)))" in
        let a = analyze s in
        check_int "parameter"
          (find s "[x]" + 1)
          (target a (find s "x 2")).location.span.start_byte );
    ( "parameters after load and inside conditional",
      fun () ->
        let s =
          "(load \"helpers.rfl\") (set f (fn [ctx] (if (ready ctx) 0 (do (let \
           y (at ctx 'k)) (+ y 1)))))"
        in
        let a = analyze s in
        let parameter = find s "[ctx]" + 1 in
        check_int "condition parameter" parameter
          (target a (find s "ctx) 0")).location.span.start_byte;
        check_int "branch parameter" parameter
          (target a (find s "ctx 'k")).location.span.start_byte;
        check_int "branch local" (find s "y (at")
          (target a (find s "y 1")).location.span.start_byte );
    ( "parameters after unknown calls",
      fun () ->
        let s = "(custom_setup) (set f (fn [x] (custom x) (+ x 1)))" in
        let a = analyze s in
        check_int "parameter survives unknown calls"
          (find s "[x]" + 1)
          (target a (find s "x 1")).location.span.start_byte );
    ( "local and do scope",
      fun () ->
        let s = "(set x 1) (do (let x 2) (+ x 1)) (+ x 3)" in
        let a = analyze s in
        check_int "local" (find s "x 2")
          (target a (find s "x 1))")).location.span.start_byte;
        check_int "global" (find s "x 1)")
          (target a (find s "x 3")).location.span.start_byte );
    ( "literal symbols and dictionaries",
      fun () ->
        let a = analyze "(set x 1) 'x [x] {key: x}" in
        check_int "only declaration" 1
          (List.length
             (List.filter
                (fun (o : Analysis.occurrence) -> o.name = "x")
                (Analysis.occurrences a))) );
    ( "alias retains function origin",
      fun () ->
        let s = "(set f (fn [x] x)) (set alias f) (set f 4) alias" in
        let a = analyze s in
        let o = occurrence a (String.length s - 3) in
        check_int "old lambda" (find s "(fn")
          (List.hd o.origins).span.start_byte );
    ( "special form shadow",
      fun () ->
        let s = "(set f (fn [set x] (set x 2)))" in
        let a = analyze s in
        check_int "set is a parameter"
          (find s "[set" + 1)
          (target a (find s "(set x" + 1)).location.span.start_byte );
    ( "deferred globals are candidates",
      fun () ->
        let s = "(set x 1) (set f (fn [] x)) (set x 2)" in
        let a = analyze s in
        match (occurrence a (find s "x))")).resolution with
        | Analysis.Candidates (bs, _) ->
            check_int "two assignments" 2 (List.length bs)
        | _ -> failwith "must not guess call-time global" );
    ( "incomplete form",
      fun () ->
        let s = "(set f (fn [x] (+ x 1)" in
        let a = analyze s in
        check_int "parameter"
          (find s "[x]" + 1)
          (target a (find s "x 1")).location.span.start_byte;
        Alcotest.(check bool)
          "syntax diagnostic" true
          (Syntax.diagnostics (Analysis.syntax a) <> []) );
    ( "UTF-16 and CRLF",
      fun () ->
        let s = Source.create ~uri:"file:///u" ~version:1 "é😀x\r\ny" in
        check_int "astral width" 3 (Source.position s 6).character;
        check_int "inverse" 6 (Source.offset s { line = 0; character = 3 });
        check_int "second line" 9 (Source.offset s { line = 1; character = 0 });
        Alcotest.check_raises "no split surrogate"
          (Invalid_argument "Position splits a UTF-16 character or exceeds line")
          (fun () -> ignore (Source.offset s { line = 0; character = 2 })) );
    ( "unknown query scope",
      fun () ->
        let s = "(set x 1) (select {from: t x: x})" in
        let a = analyze s in
        match (occurrence a (String.length s - 3)).resolution with
        | Analysis.Runtime_dependent _ -> ()
        | _ -> failwith "query column cannot be assumed global" );
    ( "GC lifetime",
      fun () ->
        let a = analyze "(set x 1) x" in
        Gc.full_major ();
        check_int "detached syntax snapshot" 5
          (target a 10).location.span.start_byte );
  ]

let () =
  Alcotest.run "Rayfall semantic core"
    [
      ( "resolution",
        List.map (fun (name, f) -> Alcotest.test_case name `Quick f) tests );
    ]
