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
    ( "parameter shadowing",
      fun () ->
        let s = "(set x 1) (set f (fn [x] (+ x 2)))" in
        let a = analyze s in
        check_int "parameter"
          (find s "[x]" + 1)
          (target a (find s "x 2")).location.span.start_byte );
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
