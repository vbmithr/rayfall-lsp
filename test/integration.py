"""Exercise real framed LSP traffic, unsaved changes and UTF-16 positions."""
import json
import subprocess
import sys
import tempfile
from pathlib import Path


def packet(message):
    payload = json.dumps(message, ensure_ascii=False).encode()
    return f"Content-Length: {len(payload)}\r\n\r\n".encode() + payload


uri = "file:///unsaved.rfl"
source = '(set x 1) (set f (fn [x] (+ x 2)))'
messages = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
    {"jsonrpc": "2.0", "method": "initialized", "params": {}},
    {"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {"textDocument": {"uri": uri, "languageId": "rayfall", "version": 1, "text": source}}},
    {"jsonrpc": "2.0", "id": 2, "method": "textDocument/definition", "params": {"textDocument": {"uri": uri}, "position": {"line": 0, "character": source.index("x 2")}}},
    {"jsonrpc": "2.0", "method": "textDocument/didChange", "params": {"textDocument": {"uri": uri, "version": 2}, "contentChanges": [{"text": '; é😀\n' + source}]}},
    {"jsonrpc": "2.0", "id": 3, "method": "textDocument/definition", "params": {"textDocument": {"uri": uri}, "position": {"line": 1, "character": source.index("x 2")}}},
    {"jsonrpc": "2.0", "id": 4, "method": "shutdown"},
    {"jsonrpc": "2.0", "method": "exit"},
]
def run(messages):
    process = subprocess.run([sys.argv[1], "--stdio"], input=b"".join(map(packet, messages)), capture_output=True, timeout=10)
    assert process.returncode == 0, process.stderr.decode()
    raw = process.stdout
    replies = {}
    while raw:
        header, raw = raw.split(b"\r\n\r\n", 1)
        length = int(next(line.split(b":", 1)[1] for line in header.split(b"\r\n") if line.lower().startswith(b"content-length:")))
        body, raw = raw[:length], raw[length:]
        reply = json.loads(body)
        if "id" in reply:
            replies[reply["id"]] = reply
    return replies


replies = run(messages)
assert replies[1]["result"]["capabilities"]["positionEncoding"] == "utf-16"
for request, line in [(2, 0), (3, 1)]:
    result = replies[request]["result"]
    assert len(result) == 1, result
    assert result[0]["uri"] == uri
    assert result[0]["range"]["start"] == {"line": line, "character": source.index("[x]") + 1}, result
assert replies[4]["result"] is None
print("PASS: stdio LSP initialize, unsaved navigation, UTF-16 text, change, shutdown")

with tempfile.TemporaryDirectory(prefix="rayfall lsp ") as directory:
    root = Path(directory)
    (root / "strategies").mkdir()
    main = root / "strategies" / "main.rfl"
    helper = root / "strategies" / "helper.rfl"
    source = '(load "strategies/helper.rfl")\n(set f (fn [x] (helper x)))'
    main.write_text(source)
    helper.write_text('(set helper (fn [x] x))')
    uri, dependency = main.as_uri(), helper.as_uri()
    position = {"line": 1, "character": source.splitlines()[1].index("helper")}
    def request(identifier, method="textDocument/definition"):
        return {"jsonrpc": "2.0", "id": identifier, "method": method,
                "params": {"textDocument": {"uri": uri}, "position": position}}
    def notification(method, params):
        return {"jsonrpc": "2.0", "method": method, "params": params}
    messages = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"rootUri": root.as_uri()}},
        notification("initialized", {}),
        notification("textDocument/didOpen", {"textDocument": {"uri": uri, "version": 1, "languageId": "rayfall", "text": source}}),
        request(2),
        notification("textDocument/didOpen", {"textDocument": {"uri": dependency, "version": 1, "languageId": "rayfall", "text": '; é😀\n(set helper (fn [x] x))'}}),
        request(3),
        notification("textDocument/didChange", {"textDocument": {"uri": dependency, "version": 2}, "contentChanges": [{"text": '(set renamed 1)'}]}),
        request(4),
        notification("textDocument/didClose", {"textDocument": {"uri": dependency}}),
        request(5),
        request(6, "textDocument/hover"),
        {"jsonrpc": "2.0", "id": 7, "method": "shutdown"},
        notification("exit", {}),
    ]
    replies = run(messages)
    for identifier, line in [(2, 0), (3, 1), (5, 0)]:
        result = replies[identifier]["result"]
        assert len(result) == 1 and result[0]["uri"] == dependency, result
        assert result[0]["range"]["start"] == {"line": line, "character": 5}, result
    assert replies[4]["result"] == [], replies[4]
    assert "Candidate definitions" in replies[6]["result"]["contents"]["value"]
print("PASS: cross-file LSP ancestor paths, URI escaping, overlays, invalidation, close, hover")

with tempfile.TemporaryDirectory(prefix="rayfall entrypoint ") as directory:
    root = Path(directory)
    (root / "strategies").mkdir()
    (root / ".rayfall-lsp.json").write_text(json.dumps({"entrypoints": ["run.rfl"], "workingDirectory": "."}))
    runner = root / "run.rfl"
    runner.write_text('(load "bt.rfl") (load (strategy_path))')
    kernel = root / "bt.rfl"
    kernel.write_text('; é😀\n(set bt_strategy (fn [run] run))\n(set bt {})\n(set bt.cash0 42)')
    main = root / "strategies" / "trend.rfl"
    source = '(set trend (fn [ctx] ctx))\n(bt_strategy trend)\n(set report (fn [] bt.cash0))\n(set q (fn [t cutoff] (select {from: t where: (> price cutoff) value: (+ bt.cash0 cutoff)})))'
    uri = main.as_uri()
    position = {"line": 1, "character": 2}
    messages = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"rootUri": root.as_uri()}},
        notification("initialized", {}),
        notification("textDocument/didOpen", {"textDocument": {"uri": uri, "version": 1, "languageId": "rayfall", "text": source}}),
        request(2),
        notification("textDocument/didOpen", {"textDocument": {"uri": runner.as_uri(), "version": 1, "languageId": "rayfall", "text": '(load (strategy_path))'}}),
        request(3),
        notification("textDocument/didClose", {"textDocument": {"uri": runner.as_uri()}}),
        request(4),
        {"jsonrpc": "2.0", "id": 6, "method": "textDocument/definition", "params": {"textDocument": {"uri": uri}, "position": {"line": 2, "character": source.splitlines()[2].index("bt.cash0")}}},
        {"jsonrpc": "2.0", "id": 7, "method": "textDocument/definition", "params": {"textDocument": {"uri": uri}, "position": {"line": 2, "character": source.splitlines()[2].index("bt.cash0") + 3}}},
        {"jsonrpc": "2.0", "id": 8, "method": "textDocument/definition", "params": {"textDocument": {"uri": uri}, "position": {"line": 3, "character": source.splitlines()[3].index("cutoff)")}}},
        {"jsonrpc": "2.0", "id": 9, "method": "textDocument/definition", "params": {"textDocument": {"uri": uri}, "position": {"line": 3, "character": source.splitlines()[3].index("bt.cash0") + 3}}},
        {"jsonrpc": "2.0", "id": 10, "method": "textDocument/definition", "params": {"textDocument": {"uri": uri}, "position": {"line": 3, "character": source.splitlines()[3].index("price")}}},
        {"jsonrpc": "2.0", "id": 11, "method": "textDocument/hover", "params": {"textDocument": {"uri": uri}, "position": {"line": 3, "character": source.splitlines()[3].index("bt.cash0") + 3}}},
        {"jsonrpc": "2.0", "id": 5, "method": "shutdown"},
        notification("exit", {}),
    ]
    replies = run(messages)
    for identifier in [2, 4]:
        result = replies[identifier]["result"]
        assert len(result) == 1 and result[0]["uri"] == kernel.as_uri(), result
        assert result[0]["range"]["start"] == {"line": 1, "character": 5}, result
    assert replies[3]["result"] == [], replies[3]
    for identifier, line in [(6, 2), (7, 3)]:
        result = replies[identifier]["result"]
        assert len(result) == 1 and result[0]["uri"] == kernel.as_uri(), result
        assert result[0]["range"]["start"] == {"line": line, "character": 5}, result
    assert replies[8]["result"][0]["range"]["start"] == {"line": 3, "character": source.splitlines()[3].index("cutoff]")}, replies[8]
    assert replies[9]["result"][0]["uri"] == kernel.as_uri(), replies[9]
    assert replies[9]["result"][0]["range"]["start"] == {"line": 3, "character": 5}, replies[9]
    assert replies[10]["result"] == [], replies[10]
    assert "shadowed by a query column" in replies[11]["result"]["contents"]["value"], replies[11]
print("PASS: configured entrypoint LSP navigation, unsaved runner, close, dotted names, queries")

with tempfile.TemporaryDirectory(prefix="rayfall columns ") as directory:
    root = Path(directory)
    helper = root / "tables.rfl"
    header = '(set bt {})\n(set bt.positions (table [sym qty] (list [X] [1])))\n(set bt.qty [1])'
    helper.write_text(header)
    main = root / "report.rfl"
    source = '(load "tables.rfl")\n(set report (fn []\n  (let p (select {from: bt.positions units: qty}))\n  (select {from: p total: (sum units)})))\n(alter \'bt.qty set 0 2)'
    uri = main.as_uri()
    def query(identifier, line, token, offset=0, method="textDocument/definition"):
        return {"jsonrpc": "2.0", "id": identifier, "method": method,
                "params": {"textDocument": {"uri": uri}, "position": {"line": line, "character": source.splitlines()[line].index(token) + offset}}}
    messages = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"rootUri": root.as_uri()}},
        notification("initialized", {}),
        notification("textDocument/didOpen", {"textDocument": {"uri": uri, "version": 1, "languageId": "rayfall", "text": source}}),
        query(2, 2, "qty"),
        query(3, 3, "units"),
        query(4, 4, "bt.qty"),
        query(5, 4, "bt.qty", 3),
        query(6, 4, "set"),
        query(7, 3, "units", method="textDocument/hover"),
        notification("textDocument/didOpen", {"textDocument": {"uri": helper.as_uri(), "version": 1, "languageId": "rayfall", "text": header.replace("[sym qty]", "[sym size]")}}),
        query(8, 2, "qty"),
        notification("textDocument/didClose", {"textDocument": {"uri": helper.as_uri()}}),
        query(9, 2, "qty"),
        {"jsonrpc": "2.0", "id": 10, "method": "shutdown"},
        notification("exit", {}),
    ]
    replies = run(messages)
    for identifier in [2, 9]:
        result = replies[identifier]["result"]
        assert len(result) == 1 and result[0]["uri"] == helper.as_uri(), result
        assert result[0]["range"]["start"] == {"line": 1, "character": header.splitlines()[1].index("qty]")}, result
    result = replies[3]["result"]
    assert len(result) == 1 and result[0]["uri"] == uri, result
    assert result[0]["range"]["start"] == {"line": 2, "character": source.splitlines()[2].index("units:")}, result
    for identifier, line in [(4, 0), (5, 2)]:
        result = replies[identifier]["result"]
        assert len(result) == 1 and result[0]["uri"] == helper.as_uri(), result
        assert result[0]["range"]["start"] == {"line": line, "character": 5}, result
    assert replies[6]["result"] == [] and replies[8]["result"] == []
    assert replies[7]["result"]["contents"]["value"] == "Column: units"
print("PASS: imported column headers, aliases, alter symbols, dependency schema edits")

with tempfile.TemporaryDirectory(prefix="rayfall joins ") as directory:
    root = Path(directory)
    uri = (root / "report.rfl").as_uri()
    source = '''(do
(let t (table [sym qty] (list [X] [2])))
(let g (select {from: t by: [sym] amount: (sum qty)}))
(let r (table [sym fee] (list [X] [1])))
(let j (left-join [sym] (ungroup g) r))
(select {from: j total: (+ amount fee)}))'''
    messages = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"rootUri": root.as_uri()}},
        notification("initialized", {}),
        notification("textDocument/didOpen", {"textDocument": {"uri": uri, "version": 1, "languageId": "rayfall", "text": source}}),
        query(2, 5, "amount"), query(3, 5, "fee"), query(4, 4, "sym"),
        {"jsonrpc": "2.0", "id": 5, "method": "shutdown"}, notification("exit", {}),
    ]
    replies = run(messages)
    for identifier, line, label in [(2, 2, "amount:"), (3, 3, "fee]")]:
        result = replies[identifier]["result"]
        assert len(result) == 1 and result[0]["uri"] == uri, result
        assert result[0]["range"]["start"] == {"line": line, "character": source.splitlines()[line].index(label)}, result
    assert len(replies[4]["result"]) == 2, replies[4]
print("PASS: grouped aliases through ungroup and join, join-key origins")

with tempfile.TemporaryDirectory(prefix="rayfall references ") as directory:
    root = Path(directory)
    uri = (root / "refs.rfl").as_uri()
    source = '''(set x 0)
(set f (fn [x] (+ x x)))
(set g (fn [x] x))
(set h (fn [] x))
(do (let t (table [x] (list [1])))
(let q (select {from: t amount: x}))
(select {from: q result: amount}))'''
    def refs(identifier, line, character, include=False):
        return {"jsonrpc": "2.0", "id": identifier, "method": "textDocument/references",
                "params": {"textDocument": {"uri": uri}, "position": {"line": line, "character": character}, "context": {"includeDeclaration": include}}}
    parameter = source.splitlines()[1].index("[x]") + 1
    messages = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"rootUri": root.as_uri()}},
        notification("initialized", {}),
        notification("textDocument/didOpen", {"textDocument": {"uri": uri, "version": 1, "languageId": "rayfall", "text": source}}),
        refs(2, 1, parameter), refs(3, 1, parameter, True),
        refs(5, 3, source.splitlines()[3].index("x))")),
        refs(6, 0, 5), refs(8, 5, source.splitlines()[5].index("amount:")),
        notification("textDocument/didChange", {"textDocument": {"uri": uri, "version": 2}, "contentChanges": [{"text": '; é😀\n' + source}]}),
        refs(4, 2, parameter),
        {"jsonrpc": "2.0", "id": 9, "method": "shutdown"}, notification("exit", {}),
    ]
    replies = run(messages)
    assert replies[1]["result"]["capabilities"]["referencesProvider"] is True
    for identifier, line in [(2, 1), (4, 2)]:
        result = replies[identifier]["result"]
        assert len(result) == 2 and all(item["uri"] == uri and item["range"]["start"]["line"] == line for item in result), result
        assert [item["range"]["start"]["character"] for item in result] == [source.splitlines()[1].index("x x"), source.splitlines()[1].index("x x") + 2], result
    assert len(replies[3]["result"]) == 3, replies[3]
    assert replies[5]["error"]["code"] == -32803 and "ambiguous" in replies[5]["error"]["message"], replies[5]
    assert replies[6]["result"] == [], replies[6]
    assert replies[8]["result"] == [{"uri": uri, "range": {"start": {"line": 6, "character": source.splitlines()[6].index("amount")}, "end": {"line": 6, "character": source.splitlines()[6].index("amount") + len("amount")}}}], replies[8]
print("PASS: references distinguish shadowing, declarations, aliases, ambiguity, unsaved edits")

with tempfile.TemporaryDirectory(prefix="rayfall argument schemas ") as directory:
    root = Path(directory)
    helper = root / "helpers.rfl"
    runner = root / "run.rfl"
    (root / ".rayfall-lsp.json").write_text(json.dumps({"entrypoints": ["run.rfl"], "workingDirectory": "."}))
    source = '(set make (fn [] (table [sym qty] (list [X] [1]))))\n(set consume (fn [a] (select {from: a result: qty})))'
    helper.write_text(source)
    runner.write_text('(load "helpers.rfl")\n(set t (make))\n(consume t)')
    uri = helper.as_uri()
    position = {"line": 1, "character": source.splitlines()[1].index("qty")}
    messages = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"rootUri": root.as_uri()}},
        notification("initialized", {}),
        notification("textDocument/didOpen", {"textDocument": {"uri": uri, "version": 1, "languageId": "rayfall", "text": source}}),
        request(2), request(3, "textDocument/hover"),
        notification("textDocument/didOpen", {"textDocument": {"uri": runner.as_uri(), "version": 1, "languageId": "rayfall", "text": '(load "helpers.rfl") (consume (table [sym size] (list [X] [1])))'}}),
        request(4),
        notification("textDocument/didClose", {"textDocument": {"uri": runner.as_uri()}}),
        request(5),
        {"jsonrpc": "2.0", "id": 6, "method": "shutdown"}, notification("exit", {}),
    ]
    replies = run(messages)
    for identifier in [2, 5]:
        result = replies[identifier]["result"]
        assert len(result) == 1 and result[0]["uri"] == uri, result
        assert result[0]["range"]["start"] == {"line": 0, "character": source.splitlines()[0].index("qty]")}, result
    assert replies[4]["result"] == [], replies[4]
    assert "observed call sites" in replies[3]["result"]["contents"]["value"], replies[3]
print("PASS: return-to-argument schema hints, unknown callers, unsaved caller invalidation")

with tempfile.TemporaryDirectory(prefix="rayfall shape hover ") as directory:
    root = Path(directory)
    uri = (root / "shapes.rfl").as_uri()
    source = '''(set cfg {cash0: 100 period: 1D})
(set alias cfg)
(set t (table [sym qty] (list [X] [1])))
(set q (select {from: t amount: qty}))
alias
t
q'''
    messages = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"rootUri": root.as_uri()}},
        notification("initialized", {}),
        notification("textDocument/didOpen", {"textDocument": {"uri": uri, "version": 1, "languageId": "rayfall", "text": source}}),
        query(2, 4, "alias", method="textDocument/hover"),
        query(3, 5, "t", method="textDocument/hover"),
        query(4, 6, "q", method="textDocument/hover"),
        query(5, 0, "{", method="textDocument/hover"),
        notification("textDocument/didChange", {"textDocument": {"uri": uri, "version": 2}, "contentChanges": [{"text": source.replace("cash0:", "cash1:")}]}),
        query(6, 4, "alias", method="textDocument/hover"),
        {"jsonrpc": "2.0", "id": 7, "method": "shutdown"}, notification("exit", {}),
    ]
    replies = run(messages)
    assert "Dictionary fields (known): cash0, period" in replies[2]["result"]["contents"]["value"], replies[2]
    assert "Table fields (known): qty, sym" in replies[3]["result"]["contents"]["value"], replies[3]
    assert "Table fields (known): amount" in replies[4]["result"]["contents"]["value"], replies[4]
    assert replies[5]["result"]["contents"]["value"] == "Dictionary fields (known): cash0, period", replies[5]
    assert replies[5]["result"]["range"]["start"] == {"line": 0, "character": source.splitlines()[0].index("{")}, replies[5]
    assert "cash1, period" in replies[6]["result"]["contents"]["value"] and "cash0" not in replies[6]["result"]["contents"]["value"], replies[6]
print("PASS: dictionary/table hover, literals, aliases, derived columns, unsaved fields")

with tempfile.TemporaryDirectory(prefix="rayfall completion ") as directory:
    root = Path(directory)
    uri = (root / "main.rfl").as_uri()
    (root / "fields.rfl").write_text('(set bt {}) (set bt.cash 1) (set bt.period 2)')
    source = '''(load "fields.rfl")
(set cfg {cash: 1 period: 2})
(set bt.)
(at cfg 'ca)
(set f (fn [bt] bt.))
; 😀
cfg.ca'''
    def complete(identifier, line, character):
        return {"jsonrpc": "2.0", "id": identifier, "method": "textDocument/completion",
                "params": {"textDocument": {"uri": uri}, "position": {"line": line, "character": character}}}
    messages = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"rootUri": root.as_uri()}},
        notification("initialized", {}),
        notification("textDocument/didOpen", {"textDocument": {"uri": uri, "version": 1, "languageId": "rayfall", "text": source}}),
        complete(2, 2, 8), complete(3, 3, 11), complete(4, 4, source.splitlines()[4].index('bt.)') + 3),
        complete(5, 6, 6),
        notification("textDocument/didChange", {"textDocument": {"uri": uri, "version": 2}, "contentChanges": [{"text": source.replace('cash:', 'capital:')}]}),
        complete(6, 6, 6),
        {"jsonrpc": "2.0", "id": 7, "method": "shutdown"}, notification("exit", {}),
    ]
    replies = run(messages)
    assert '.' in replies[1]['result']['capabilities']['completionProvider']['triggerCharacters']
    assert [item['label'] for item in replies[2]['result']] == ['cash', 'period'], replies[2]
    assert all(item['detail'] == 'Candidate field' for item in replies[2]['result']), replies[2]
    for identifier, line, start, end in [(2, 2, 8, 8), (3, 3, 9, 11), (5, 6, 4, 6)]:
        item = replies[identifier]['result'][0]
        assert item['textEdit']['range'] == {'start': {'line': line, 'character': start}, 'end': {'line': line, 'character': end}}, item
        assert item['textEdit']['newText'] == 'cash', item
    assert replies[4]['result'] == [], replies[4]
    assert [item['label'] for item in replies[6]['result']] == ['capital'], replies[6]
print("PASS: field completion, imported namespaces, suffix edits, quoted keys, shadowing, unsaved changes")
