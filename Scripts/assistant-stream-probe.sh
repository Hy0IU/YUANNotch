#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Sources/YUANNotch"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/assistant-stream.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

cat > "$OUT/probe.swift" <<'SWIFT'
import Foundation

@main enum Probe {
    @MainActor static func main() async throws {
        let origin = CommandLine.arguments[1]
        let signal = URL(fileURLWithPath: CommandLine.arguments[2])
        let session = URLSession(configuration: .ephemeral)
        func run(_ format: AssistantAPIFormat, route: String, onDelta: @MainActor (String) -> Void) async throws -> String {
            let endpoint = try format.resolve(address: origin + route + "/v1", model: "fixture", exactURL: false)
            let request = try format.request(endpoint: endpoint, model: "fixture", auth: .none, header: "", key: nil,
                                             system: "Test", user: "Hello", stream: true)
            return try await AssistantStream.complete(session: session, request: request, format: format, onDelta: onDelta)
        }
        for format in AssistantAPIFormat.allCases {
            var received = ""
            let ack = signal.appendingPathComponent(format.rawValue)
            let complete = try await run(format, route: "/\(format.rawValue)") { delta in
                received += delta
                if received == "第一段" { try! Data().write(to: ack) }
            }
            precondition(received == "第一段第二段" && complete == received, "Incorrect \(format) stream: \(received)")
        }
        var partial = ""
        do {
            _ = try await run(.chat, route: "/interrupted") { partial += $0 }
            fatalError("Missing stream end promoted a partial reply to a final answer")
        } catch {
            precondition(partial == "第一段")
        }
        let nonStreaming = try await run(.chat, route: "/json") { _ in }
        precondition(nonStreaming == "Buffered gateway reply")
    }
}
SWIFT
xcrun swiftc -swift-version 6 -parse-as-library -o "$OUT/probe" \
  "$OUT/probe.swift" "$SRC/AssistantAPIFormat.swift" "$SRC/AssistantStream.swift"

python3 - "$OUT/probe" "$OUT" <<'PY'
import http.server
import json
from pathlib import Path
import subprocess
import sys
import threading
import time

out = Path(sys.argv[2])
A, B = "第一段", "第二段"

def sse(obj):
    text = obj if isinstance(obj, str) else json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    return f"data: {text}\r\n\r\n".encode()

def completion(**choice):
    return sse({"choices": [{"index": 0, **choice}]})

def response(kind, **fields):
    return sse({"type": kind, **fields})

def candidate(part, **fields):
    return sse({"candidates": [{"index": 0, "content": {"role": "model", "parts": [part]}, **fields}]})

message = {"type": "message", "role": "assistant", "phase": "final_answer", "content": []}
chatFirst = completion(delta={"reasoning_content": "hidden"}) + completion(delta={"content": A})
streams = {
    "chat": (chatFirst, completion(delta={"content": B}) + completion(delta={}, finish_reason="stop") + sse("[DONE]")),
    "responses": (
        response("response.output_item.added", output_index=0, item={**message, "phase": "commentary"})
        + response("response.output_text.delta", output_index=0, item_id="commentary", delta="hidden")
        + response("response.output_item.added", output_index=1, item={**message, "id": "final"})
        + response("response.output_text.delta", output_index=1, item_id="final", delta=A),
        response("response.output_text.delta", output_index=1, item_id="final", delta=B)
        + response("response.completed", response={"status": "completed", "output": [
            {**message, "status": "completed", "content": [{"type": "output_text", "text": A+B}]}]})),
    "anthropic": (
        response("message_start", message={"type": "message", "role": "assistant", "content": []})
        + response("content_block_start", index=0, content_block={"type": "thinking", "thinking": ""})
        + response("content_block_delta", index=0, delta={"type": "thinking_delta", "thinking": "hidden"})
        + response("content_block_stop", index=0)
        + response("content_block_start", index=1, content_block={"type": "text", "text": ""})
        + response("content_block_delta", index=1, delta={"type": "text_delta", "text": A}),
        response("content_block_delta", index=1, delta={"type": "text_delta", "text": B})
        + response("content_block_stop", index=1)
        + response("message_delta", delta={"stop_reason": "end_turn"}) + response("message_stop")),
    "gemini": (candidate({"thought": True, "text": "hidden"}) + candidate({"text": A}),
               candidate({"text": B}, finishReason="STOP")),
}
expected_paths = {"chat": "/v1/chat/completions", "responses": "/v1/responses", "anthropic": "/v1/messages",
                  "gemini": "/v1/models/fixture:streamGenerateContent?alt=sse"}
seen = []

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        route = self.path.split("/", 2)[1]
        seen.append(route)
        self.close_connection = True
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        expected = expected_paths[route if route in streams else "chat"]
        if self.path != f"/{route}{expected}" or (route != "gemini" and body.get("stream") is not True):
            self.send_error(400, "Incorrect streaming request")
            return
        media = "text/event-stream"
        if route == "json":
            media = "application/json"
            first = json.dumps({"choices": [{"finish_reason": "stop", "message": {"content": "Buffered gateway reply"}}]}).encode()
            rest = b""
        elif route == "interrupted":
            first, rest = chatFirst, b""
        else:
            first, rest = streams[route]
        self.send_response(200)
        self.send_header("Content-Type", media)
        self.send_header("Content-Length", str(len(first) + len(rest)))
        self.end_headers()
        self.wfile.write(first)
        self.wfile.flush()
        if rest:
            # Prove the first callback runs before the server even sends completion.
            limit = time.monotonic() + 5
            while not (out / route).exists() and time.monotonic() < limit:
                time.sleep(0.01)
            if (out / route).exists():
                self.wfile.write(rest)

    def log_message(self, *_):
        pass

with http.server.HTTPServer(("127.0.0.1", 0), Handler) as server:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    subprocess.run([sys.argv[1], f"http://127.0.0.1:{server.server_port}", sys.argv[2]], check=True, timeout=35)
    assert seen == [*streams, "interrupted", "json"], seen
print("PASS real early UTF-8 deltas for four formats; nonvisible reasoning discarded; incomplete stream rejected; single-request JSON compatibility")
PY
