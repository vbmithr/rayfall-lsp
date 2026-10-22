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
