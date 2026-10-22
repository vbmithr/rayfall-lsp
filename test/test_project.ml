open Rayfall

let write path text =
  let ch = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr ch)
    (fun () -> output_string ch text)

let analyze path text =
  Analysis.analyze
    (Source.create
       ~uri:(Lsp.Uri.to_string (Lsp.Uri.of_path path))
       ~version:1 text)

let with_project f =
  let dir = Filename.temp_file "rayfall lsp " "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let files = ref [] and dirs = ref [] in
  let rec ensure_dir path =
    if not (Sys.file_exists path) then (
      ensure_dir (Filename.dirname path);
      Unix.mkdir path 0o700;
      dirs := path :: !dirs)
  in
  let file name text =
    let p = Filename.concat dir name in
    ensure_dir (Filename.dirname p);
    files := p :: !files;
    write p text;
    p
  in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun p -> if Sys.file_exists p then Sys.remove p) !files;
      List.iter Unix.rmdir !dirs;
      Unix.rmdir dir)
    (fun () -> f dir file)

let reference a name =
  List.find
    (fun (o : Analysis.occurrence) -> o.name = name && not o.declaration)
    (List.rev (Analysis.occurrences a))

let targets project a name =
  Analysis.targets (Project.resolve project a (reference a name))

let count = Alcotest.(check int)

let tests =
  [
    ( "imported table headers and local projection aliases",
      fun () ->
        with_project (fun dir file ->
            let helper =
              file "helper.rfl"
                "(set bt {}) (set bt.positions (table [sym qty] (list [X] \
                 [1])))"
            in
            let text =
              "(load \"helper.rfl\") (set f (fn [] (let p (select {from: \
               bt.positions units: qty})) (select {from: p result: units})))"
            in
            let entry = file "main.rfl" text in
            let a = analyze entry text in
            let p = Project.create ~roots:[ dir ] ~documents:[] a in
            let a = Project.analysis p in
            let bs = targets p a "qty" in
            count "imported header" 1 (List.length bs);
            Alcotest.(check string)
              "header URI" helper
              (Lsp.Uri.to_path (Lsp.Uri.of_string (List.hd bs).location.uri));
            Alcotest.(check bool) "column kind" true ((List.hd bs).kind = Column);
            let bs = targets p a "units" in
            count "alias definition" 1 (List.length bs);
            Alcotest.(check string)
              "alias URI"
              (Source.uri (Analysis.source a))
              (List.hd bs).location.uri;
            let overlay =
              analyze helper
                "(set bt {}) (set bt.positions (table [sym size] (list [X] \
                 [1])))"
            in
            let p = Project.create ~roots:[ dir ] ~documents:[ overlay ] a in
            count "removed header does not stay cached" 0
              (List.length (targets p (Project.analysis p) "qty"))) );
    ( "global table reassignments retain candidate column origins",
      fun () ->
        with_project (fun dir file ->
            let text =
              "(set t (table [x] (list [1]))) (set f (fn [] (select {from: t \
               result: x}))) (set t (table [x] (list [2])))"
            in
            let entry = file "main.rfl" text in
            let a = analyze entry text in
            let p = Project.create ~roots:[ dir ] ~documents:[] a in
            let a = Project.analysis p in
            match Project.resolve p a (reference a "x") with
            | Analysis.Candidates (bs, _) ->
                count "both column declarations" 2 (List.length bs)
            | _ ->
                Alcotest.fail "call-time table mutation must remain uncertain")
    );
    ( "query imports retain column ambiguity",
      fun () ->
        with_project (fun dir file ->
            ignore (file "helper.rfl" "(set x 1) (set bt {}) (set bt.cash0 42)");
            let text =
              "(load \"helper.rfl\") (select {from: t result: x c: bt.cash0})"
            in
            let entry = file "main.rfl" text in
            let a = analyze entry text in
            let p = Project.create ~roots:[ dir ] ~documents:[] a in
            count "bare column must not bind imported global" 0
              (List.length (targets p a "x"));
            match Project.resolve p a (reference a "bt.cash0") with
            | Analysis.Candidates ([ _ ], why) ->
                Alcotest.(check bool)
                  "keep schema uncertainty" true
                  (String.starts_with ~prefix:"global lookup may be shadowed"
                     why)
            | _ ->
                Alcotest.fail "qualified field must be an uncertain candidate")
    );
    ( "working directory and nearest config select the right file",
      fun () ->
        with_project (fun dir file ->
            ignore (file ".rayfall-lsp.json" "{\"workingDirectory\":\".\"}");
            let root_helper = file "helper.rfl" "(set x 1)" in
            let local_helper = file "sub/helper.rfl" "(set x 2)" in
            let text = "(load \"helper.rfl\") x" in
            let entry = file "sub/main.rfl" text in
            let a = analyze entry text in
            let check expected =
              let p = Project.create ~roots:[ dir ] ~documents:[] a in
              let bs = targets p a "x" in
              count "single configured target" 1 (List.length bs);
              Alcotest.(check string)
                "configured source" expected
                (Lsp.Uri.to_path (Lsp.Uri.of_string (List.hd bs).location.uri))
            in
            check root_helper;
            ignore (file "sub/.rayfall-lsp.json" "{\"workingDirectory\":\".\"}");
            check local_helper) );
    ( "entrypoint exposes sibling kernel to a dynamic strategy",
      fun () ->
        with_project (fun dir file ->
            ignore
              (file ".rayfall-lsp.json"
                 "{\"entrypoints\":[\"run.rfl\"],\"workingDirectory\":\".\"}");
            ignore (file "run.rfl" "(load \"bt.rfl\") (load (strategy_path))");
            let kernel =
              file "bt.rfl"
                "(set bt_strategy (fn [name params run prepare] run))"
            in
            let text =
              "(set trend (fn [ctx] ctx)) (bt_strategy 'trend {} trend 0Nl)"
            in
            let entry = file "trend.rfl" text in
            let a = analyze entry text in
            let p = Project.create ~roots:[ dir ] ~documents:[] a in
            let bs = targets p a "bt_strategy" in
            count "kernel definition" 1 (List.length bs);
            Alcotest.(check string)
              "kernel URI" kernel
              (Lsp.Uri.to_path (Lsp.Uri.of_string (List.hd bs).location.uri));
            Alcotest.(check bool)
              "dynamic load stays explicit" true
              (List.mem "Dynamic load path cannot be followed statically"
                 (Project.issues p))) );
    ( "entrypoint overlay and config refresh",
      fun () ->
        with_project (fun dir file ->
            let config =
              file ".rayfall-lsp.json" "{\"entrypoints\":[\"run.rfl\"]}"
            in
            let runner = file "run.rfl" "(set from_runner 1)" in
            let text = "(set f (fn [] from_runner))" in
            let entry = file "strategy.rfl" text in
            let a = analyze entry text in
            let overlay = analyze runner "; unsaved\n(set from_runner 2)" in
            let p = Project.create ~roots:[ dir ] ~documents:[ overlay ] a in
            let b = List.hd (targets p a "from_runner") in
            let src = Option.get (Project.source p b.location.uri) in
            count "unsaved runner" 1
              (Source.position src b.location.span.start_byte).line;
            write config "{\"entrypoints\":[]}";
            let p = Project.create ~roots:[ dir ] ~documents:[ overlay ] a in
            count "removed entrypoint" 0
              (List.length (targets p a "from_runner"))) );
    ( "invalid config keeps direct loads usable",
      fun () ->
        with_project (fun dir file ->
            ignore (file ".rayfall-lsp.json" "{\"entrypoint\":42}");
            ignore (file "helper.rfl" "(set x 1)");
            let text = "(load \"helper.rfl\") x" in
            let entry = file "main.rfl" text in
            let a = analyze entry text in
            let p = Project.create ~roots:[ dir ] ~documents:[] a in
            count "direct dependency" 1 (List.length (targets p a "x"));
            count "configuration issue" 1 (List.length (Project.issues p))) );
    ( "transitive loads and cycles",
      fun () ->
        with_project (fun dir file ->
            let entry =
              file "main.rfl" "(load \"helper.rfl\") (set f (fn [] imported))"
            in
            ignore (file "helper.rfl" "(load \"nested.rfl\")");
            let nested =
              file "nested.rfl" "(load \"main.rfl\") (set imported 42)"
            in
            let a =
              analyze entry "(load \"helper.rfl\") (set f (fn [] imported))"
            in
            let p = Project.create ~roots:[ dir ] ~documents:[] a in
            let bs = targets p a "imported" in
            count "one target" 1 (List.length bs);
            Alcotest.(check string)
              "nested source" nested
              (Lsp.Uri.to_path (Lsp.Uri.of_string (List.hd bs).location.uri));
            count "no cycle issue" 0 (List.length (Project.issues p))) );
    ( "unsaved overlays and disk refresh",
      fun () ->
        with_project (fun dir file ->
            let entry = file "main.rfl" "(load \"helper.rfl\") imported" in
            let helper = file "helper.rfl" "(set imported 1)" in
            let a = analyze entry "(load \"helper.rfl\") imported" in
            let overlay = analyze helper "; é😀\n(set imported 2)" in
            let p = Project.create ~roots:[ dir ] ~documents:[ overlay ] a in
            let b = List.hd (targets p a "imported") in
            let source = Option.get (Project.source p b.location.uri) in
            count "overlay line" 1
              (Source.position source b.location.span.start_byte).line;
            write helper "(set replacement 3)";
            let p = Project.create ~roots:[ dir ] ~documents:[] a in
            count "fresh disk" 0 (List.length (targets p a "imported"))) );
    ( "missing and dynamic loads",
      fun () ->
        with_project (fun dir file ->
            let text = "(load \"missing.rfl\") (load path) unknown" in
            let entry = file "main.rfl" text in
            let a = analyze entry text in
            let p = Project.create ~roots:[ dir ] ~documents:[] a in
            count "two issues" 2 (List.length (Project.issues p));
            count "no guessed target" 0 (List.length (targets p a "unknown")))
    );
    ( "multiple assignments remain candidates",
      fun () ->
        with_project (fun dir file ->
            let text = "(load \"a.rfl\") (load \"b.rfl\") (set f (fn [] x))" in
            let entry = file "main.rfl" text in
            ignore (file "a.rfl" "(set x 1)");
            ignore (file "b.rfl" "(set x 2)");
            let a = analyze entry text in
            let p = Project.create ~roots:[ dir ] ~documents:[] a in
            match Project.resolve p a (reference a "x") with
            | Analysis.Candidates (bs, _) ->
                count "both assignments" 2 (List.length bs)
            | _ -> Alcotest.fail "must retain ambiguity") );
    ( "lexical shadowing beats imports",
      fun () ->
        with_project (fun dir file ->
            let text = "(load \"helper.rfl\") (set f (fn [x] x))" in
            let entry = file "main.rfl" text in
            ignore (file "helper.rfl" "(set x 1)");
            let a = analyze entry text in
            let p = Project.create ~roots:[ dir ] ~documents:[] a in
            match Project.resolve p a (reference a "x") with
            | Analysis.Resolved b when b.kind = Parameter -> ()
            | _ -> Alcotest.fail "parameter must remain precise") );
    ( "shadowed load is not followed",
      fun () ->
        with_project (fun dir file ->
            let text = "(set f (fn [load] (load \"helper.rfl\")))" in
            let entry = file "main.rfl" text in
            let a = analyze entry text in
            let p = Project.create ~roots:[ dir ] ~documents:[] a in
            count "not a core load" 0 (List.length (Analysis.loads a));
            count "no missing import" 0 (List.length (Project.issues p))) );
  ]

let () =
  Alcotest.run "Rayfall project"
    [
      ( "load graph",
        List.map (fun (name, f) -> Alcotest.test_case name `Quick f) tests );
    ]
