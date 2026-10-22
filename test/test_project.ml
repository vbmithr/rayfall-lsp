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
  let files = ref [] in
  let file name text =
    let p = Filename.concat dir name in
    files := p :: !files;
    write p text;
    p
  in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun p -> if Sys.file_exists p then Sys.remove p) !files;
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
