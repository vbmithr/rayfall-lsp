"""Compare definition latency over a persistent, framed LSP connection."""

import argparse
import json
import statistics
import subprocess
import time
from pathlib import Path

parser = argparse.ArgumentParser(
    description="Measure cold and repeated stdio definition requests."
)
parser.add_argument("--root", required=True, type=Path)
parser.add_argument("--file", required=True, type=Path)
parser.add_argument("--symbol", required=True)
parser.add_argument("binaries", nargs="+")
args = parser.parse_args()
path = args.file.resolve()
text = path.read_text()
offset = text.index(args.symbol)
line = text[:offset].count("\n")
char = len(text[text.rfind("\n", 0, offset) + 1 : offset].encode("utf-16-le")) // 2
for binary in args.binaries:
    p = subprocess.Popen(
        [binary, "--stdio"], stdin=subprocess.PIPE, stdout=subprocess.PIPE
    )

    def send(method, params, ident=None):
        msg = {"jsonrpc": "2.0", "method": method, "params": params}
        if ident is not None:
            msg["id"] = ident
        data = json.dumps(msg).encode()
        p.stdin.write(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)
        p.stdin.flush()

    def reply(ident):
        while True:
            headers = {}
            while line := p.stdout.readline().strip():
                k, v = line.split(b":", 1)
                headers[k.lower()] = v.strip()
            result = json.loads(p.stdout.read(int(headers[b"content-length"])))
            if result.get("id") == ident:
                return result

    send("initialize", {"rootUri": args.root.resolve().as_uri()}, 1)
    reply(1)
    send("initialized", {})
    send(
        "textDocument/didOpen",
        {
            "textDocument": {
                "uri": path.as_uri(),
                "languageId": "rayfall",
                "version": 1,
                "text": text,
            }
        },
    )
    durations = []
    for ident in range(2, 13):
        start = time.perf_counter()
        send(
            "textDocument/definition",
            {
                "textDocument": {"uri": path.as_uri()},
                "position": {"line": line, "character": char},
            },
            ident,
        )
        result = reply(ident)
        durations.append(1000 * (time.perf_counter() - start))
        assert "error" not in result, result
    print(
        binary,
        "first_ms",
        round(durations[0], 2),
        "repeat_median_ms",
        round(statistics.median(durations[1:]), 2),
        "repeat_max_ms",
        round(max(durations[1:]), 2),
        flush=True,
    )
    send("shutdown", {}, 99)
    reply(99)
    send("exit", {})
    p.wait(timeout=5)
