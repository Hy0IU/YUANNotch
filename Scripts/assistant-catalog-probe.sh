#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Sources/YUANNotch"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/assistant-catalog.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

# Exercise the real URLSession client without contacting a provider or loading an API key.
cat > "$OUT/probe.swift" <<'SWIFT'
import Foundation

@main enum Probe {
    @MainActor static func main() async throws {
        UserDefaults.standard.setVolatileDomain(["yuanNotch.assistantProvider": Data()], forName: UserDefaults.argumentDomain)
        let origin = CommandLine.arguments[1]
        func fetch(_ path: String, exact: Bool = false) async throws -> [String] {
            try await AssistantProvider.fetchModels(address: origin + path, format: .anthropic, exactURL: exact,
                                                    auth: .automatic, header: "", apiKey: "catalog-fixture")
        }
        let models = try await fetch("/relay/anthropic")
        precondition(models == ["deepseek-flash", "deepseek-v4-pro"])
        let exactURLModels = try await fetch("/exact/anthropic/v1/messages?api-version=preview", exact: true)
        precondition(exactURLModels == ["deepseek-flash", "deepseek-v4-pro"])
        for (mount, status) in [("auth", 401), ("page", 404)] {
            do {
                _ = try await fetch("/\(mount)/anthropic/v1")
                fatalError("Expected HTTP \(status) from \(mount)")
            } catch {
                precondition(error.localizedDescription.contains("HTTP \(status)"))
            }
        }
    }
}
SWIFT
xcrun swiftc -swift-version 6 -parse-as-library -o "$OUT/probe" \
  "$OUT/probe.swift" "$SRC/AssistantAPIFormat.swift" "$SRC/AssistantProvider.swift" "$SRC/AssistantStream.swift"

python3 - "$OUT/probe" <<'PY'
import http.server
import json
import subprocess
import sys
import threading

catalog = {"data": [{"id": "deepseek-v4-pro"}, {"id": "deepseek-flash"}]}
# Request order, auth encoding and stopping conditions are part of the behavior.
expected = [
    ("/relay/anthropic/models", "native", 404, None),
    ("/relay/v1/models", "bearer", 405, None),
    ("/relay/models", "bearer", 200, catalog),
    ("/exact/anthropic/v1/models?api-version=preview", "native", 404, None),
    ("/exact/v1/models?api-version=preview", "bearer", 200, catalog),
    ("/auth/anthropic/v1/models", "native", 401, None),
    ("/page/anthropic/v1/models", "native", 200,
     {"data": [{"id": "page-first"}], "has_more": True, "last_id": "page-first"}),
    ("/page/anthropic/v1/models?after_id=page-first", "native", 404, None),
]
seen = []

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        credentials = (self.headers.get("x-api-key"), self.headers.get("Authorization"))
        actual = {("catalog-fixture", None): "native", (None, "Bearer catalog-fixture"): "bearer"}.get(credentials)
        seen.append((self.path, actual))
        i = len(seen) - 1
        if i >= len(expected) or seen[i] != expected[i][:2]:
            self.send_error(500, "Unexpected request")
            return
        _, _, status, body = expected[i]
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass

with http.server.HTTPServer(("127.0.0.1", 0), Handler) as server:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    subprocess.run([sys.argv[1], f"http://127.0.0.1:{server.server_port}"], check=True, timeout=20)
    assert seen == [row[:2] for row in expected], seen
print("PASS Anthropic catalog fallback on 404/405; same-origin paths, protocol auth, exact URL, and no fallback on 401 or later pages")
PY
