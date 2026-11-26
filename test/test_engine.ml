open Rayfall

let check = Alcotest.(check bool)

let reply =
  "'unary\n\
   'min\n\
   false\n\
   Smallest element of a vector, or the lesser of two values\n\
   false\n\
   false\n\
   [false]\n\
   (min <x: vector, atom or list>) or (min <a: num> <b: num>)\n"

let signature =
  Alcotest.testable
    (fun ppf (s : Engine.signature) ->
      Format.fprintf ppf "%s/%s/%b/%S/%S" s.kind s.builtin s.special s.summary
        s.usage)
    ( = )

let option_signature = Alcotest.option signature

let parses () =
  Alcotest.check option_signature "documented builtin"
    (Some
       {
         kind = "unary";
         builtin = "min";
         special = false;
         summary = "Smallest element of a vector, or the lesser of two values";
         atomic = false;
         aggregate = false;
         elementwise = [ false ];
         usage = "(min <x: vector, atom or list>) or (min <a: num> <b: num>)";
       })
    (Engine.parse reply);
  Alcotest.check option_signature "undocumented builtin keeps its empty usage"
    (Some
       {
         kind = "vary";
         builtin = ".ipc.open";
         special = false;
         summary = "";
         atomic = false;
         aggregate = false;
         elementwise = [];
         usage = "";
       })
    (Engine.parse "'vary\n'.ipc.open\nfalse\n\n0Nl\n0Nl\n0Nl\n\n");
  Alcotest.check option_signature "special form and CRLF"
    (Some
       {
         kind = "vary";
         builtin = "if";
         special = true;
         summary = "Conditional";
         atomic = false;
         aggregate = false;
         elementwise = [ true; true ];
         usage = "(if ...)";
       })
    (Engine.parse
       "'vary\r\n\
        'if\r\n\
        true\r\n\
        Conditional\r\n\
        false\r\n\
        false\r\n\
        [true true]\r\n\
        (if ...)\r\n");
  List.iter
    (fun noise ->
      Alcotest.check option_signature noise None (Engine.parse noise))
    [
      "";
      "'missing\n";
      "'missing\n''\nfalse\n\n";
      "error: boom\n\n\n\n\n\n\n\n";
      "'value\n''\nfalse\n\n";
    ]

let describes () =
  let s = Option.get (Engine.parse reply) in
  Alcotest.(check string)
    "builtin"
    "Smallest element of a vector, or the lesser of two values\n\
     (min <x: vector, atom or list>) or (min <a: num> <b: num>)"
    (Engine.describe ~name:"min" s);
  Alcotest.(check string)
    "alias"
    "m: alias of min\n\
     Smallest element of a vector, or the lesser of two values\n\
     (min <x: vector, atom or list>) or (min <a: num> <b: num>)"
    (Engine.describe ~name:"m" s);
  Alcotest.(check string)
    "nothing documented" ".ipc.open: builtin (vary)"
    (Engine.describe ~name:".ipc.open"
       {
         kind = "vary";
         builtin = ".ipc.open";
         special = false;
         summary = "";
         atomic = false;
         aggregate = false;
         elementwise = [];
         usage = "";
       });
  Alcotest.(check string)
    "special" "if: special form"
    (Engine.describe ~name:"if"
       {
         kind = "vary";
         builtin = "if";
         special = true;
         summary = "";
         atomic = false;
         aggregate = false;
         elementwise = [];
         usage = "";
       })

let mapping_text () =
  let describe s = Engine.describe ~name:"f" s in
  let base =
    {
      Engine.kind = "binary";
      builtin = "f";
      special = false;
      summary = "";
      atomic = false;
      aggregate = false;
      elementwise = [];
      usage = "(f x)";
    }
  in
  Alcotest.(check string)
    "atomic is said once" "atomic\n(f x)"
    (describe { base with atomic = true; elementwise = [ true; true ] });
  Alcotest.(check string)
    "aggregate" "aggregate\n(f x)"
    (describe { base with aggregate = true; elementwise = [ false ] });
  Alcotest.(check string)
    "every argument" "element-wise\n(f x)"
    (describe { base with elementwise = [ true; true ] });
  Alcotest.(check string)
    "one argument" "element-wise in argument 1\n(f x)"
    (describe { base with elementwise = [ true; false ] });
  Alcotest.(check string)
    "several arguments" "element-wise in arguments 1, 3\n(f x)"
    (describe { base with elementwise = [ true; false; true ] });
  Alcotest.(check string)
    "nothing known" "(f x)"
    (describe { base with elementwise = [ false ] })

let validates_names () =
  List.iter
    (fun n -> check n true (Engine.valid_name n))
    [ "min"; ".ipc.open"; "nil?"; "fold-left"; "+"; "<=" ];
  List.iter
    (fun n -> check n false (Engine.valid_name n))
    [ ""; "min) (exit"; "a b"; "a\nb"; "'x"; "\"x"; "(x"; String.make 129 'a' ]

let never_sends_odd_names () =
  let sent = ref [] in
  let engine =
    Engine.create_with ~run:(fun input ->
        sent := input :: !sent;
        None)
  in
  List.iter
    (fun n -> Alcotest.check option_signature n None (Engine.lookup engine n))
    [ "min) (exit"; ""; "a b" ];
  Alcotest.(check int) "engine never asked" 0 (List.length !sent)

let caches_answers () =
  let calls = ref 0 in
  let engine =
    Engine.create_with ~run:(fun input ->
        incr calls;
        Alcotest.(check bool)
          "asks .repl.signature only" true
          (String.length input > 0
          && String.split_on_char '\n' input
             |> List.for_all (fun l ->
                 l = ""
                 || String.starts_with
                      ~prefix:"(println (at (.repl.signature (quote min))" l));
        Some reply)
  in
  for _ = 1 to 3 do
    Alcotest.check Alcotest.bool "found" true
      (Option.is_some (Engine.lookup engine "min"))
  done;
  Alcotest.(check int) "one engine run" 1 !calls;
  let failing =
    Engine.create_with ~run:(fun _ ->
        incr calls;
        None)
  in
  ignore (Engine.lookup failing "min");
  ignore (Engine.lookup failing "min");
  Alcotest.(check int) "failure cached too" 2 !calls

let missing_engine_is_none () =
  let engine = Engine.create ~command:"rayfall-no-such-engine-binary" () in
  Alcotest.check option_signature "no engine" None (Engine.lookup engine "min")

let slow_engine_is_cut_off () =
  let engine = Engine.create ~command:"sleep" ~timeout:0.3 () in
  let started = Unix.gettimeofday () in
  Alcotest.check option_signature "timed out" None (Engine.lookup engine "min");
  check "returned promptly" true (Unix.gettimeofday () -. started < 2.)

let real_engine () =
  let on_path =
    Sys.getenv_opt "PATH" |> Option.value ~default:""
    |> String.split_on_char ':'
    |> List.exists (fun d -> Sys.file_exists (Filename.concat d "rayforce"))
  in
  if not on_path then Alcotest.skip ()
  else
    let engine = Engine.create () in
    (match Engine.lookup engine "min" with
    | Some s ->
        Alcotest.(check string) "min" "min" s.builtin;
        check "usage documented" true (s.usage <> "");
        check "summary documented" true (s.summary <> "");
        ()
    | None -> Alcotest.fail "min is a builtin");
    (match Engine.lookup engine "+" with
    | Some s ->
        check "+ is atomic" true s.atomic;
        Alcotest.(check (list bool)) "+ maps both" [ true; true ] s.elementwise
    | None -> Alcotest.fail "+ is a builtin");
    (match Engine.lookup engine "sum" with
    | Some s -> check "sum aggregates" true s.aggregate
    | None -> Alcotest.fail "sum is a builtin");
    (match Engine.lookup engine ".ipc.open" with
    | Some s -> Alcotest.(check string) "dotted" ".ipc.open" s.builtin
    | None -> Alcotest.fail ".ipc.open is a builtin");
    Alcotest.check option_signature "not a builtin" None
      (Engine.lookup engine "no-such-name-anywhere")

let () =
  Alcotest.run "Rayfall engine lookup"
    [
      ( "engine",
        List.map
          (fun (n, f) -> Alcotest.test_case n `Quick f)
          [
            ("parse", parses);
            ("describe", describes);
            ("vector mapping", mapping_text);
            ("names are validated", validates_names);
            ("odd names never reach the engine", never_sends_odd_names);
            ("answers are cached", caches_answers);
            ("missing engine", missing_engine_is_none);
            ("slow engine", slow_engine_is_cut_off);
            ("real engine", real_engine);
          ] );
    ]
