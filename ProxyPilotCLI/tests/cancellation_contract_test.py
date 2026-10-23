#!/usr/bin/env python3
"""Prove downstream disconnect cancels actual upstream work, without inference.

Exercise buffered/streaming Chat, translated Messages, and native Messages.
The stub keeps responding until the proxy closes its upstream connection.
"""
import http.client
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    opened = None
    disconnected = None
    release = None

    def log_message(self, *_):
        pass

    def handle(self):
        try:
            super().handle()
        except ConnectionResetError:
            pass  # Expected when a canceled pooled upstream socket is reset.

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if request["model"] == "complete-fixture":
            if self.path.endswith("/messages"):
                response = {"id": "fixture", "type": "message", "role": "assistant",
                            "model": "complete-fixture", "content": [{"type": "text", "text": "ok"}],
                            "stop_reason": "end_turn", "usage": {"input_tokens": 1, "output_tokens": 1}}
            else:
                response = {"id": "fixture", "model": "complete-fixture",
                            "choices": [{"message": {"role": "assistant", "content": "ok"}}],
                            "usage": {"prompt_tokens": 1, "completion_tokens": 1}}
            body = json.dumps(response).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream" if request["stream"] else "application/json")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        type(self).opened.set()
        time.sleep(0.1)  # Make before-first-body disconnect deterministic.
        if self.path.endswith("/messages"):
            chunk = b'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"fixture"}}\n\n'
        else:
            chunk = b'data: {"id":"fixture","choices":[{"delta":{"content":"fixture"}}]}\n\n'
        if not request["stream"]:
            chunk = b" "  # A buffered body that intentionally never completes.
        try:
            while not type(self).release.is_set():
                self.wfile.write(("%x\r\n" % len(chunk)).encode() + chunk + b"\r\n")
                self.wfile.flush()
                time.sleep(0.02)
        except OSError:
            type(self).disconnected.set()


binary = Path(os.environ.get("PROXYPILOT_BIN", Path(__file__).parents[1] / ".build/debug/proxypilot"))
for provider, path in [("ollama", "/v1/chat/completions"), ("ollama", "/v1/messages"),
                       ("deepseek", "/v1/messages")]:
    for streaming, read_first in [(False, False), (True, False), (True, True)]:
        with tempfile.TemporaryDirectory(prefix="proxypilot-cancel-") as directory:
            root = Path(directory)
            Provider.opened = threading.Event()
            Provider.disconnected = threading.Event()
            Provider.release = threading.Event()
            upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
            upstream.daemon_threads = True
            threading.Thread(target=upstream.serve_forever, daemon=True).start()
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]
            env = os.environ.copy()
            env.update(XDG_CONFIG_HOME=str(root / "config"), PROXYPILOT_SECRETS_DIR=str(root / "secrets"),
                       PROXYPILOT_SESSION_REPORT_PATH=str(root / "sessions.jsonl"))
            # The resolver deliberately withholds stored keys on unofficial
            # loopback overrides. These stub routes need no provider secrets.
            with (root / "proxy.log").open("w") as log:
                proxy = subprocess.Popen([str(binary), "serve", "--provider", provider, "--port", str(port),
                    "--upstream-url", f"http://127.0.0.1:{upstream.server_port}/v1",
                    "--context-compaction", "off"], env=env, stdout=log, stderr=log)
                try:
                    deadline = time.monotonic() + 15
                    while True:
                        try:
                            client = socket.create_connection(("127.0.0.1", port), timeout=2)
                            break
                        except OSError:
                            assert time.monotonic() < deadline and proxy.poll() is None, "proxy failed to start"
                            time.sleep(0.05)
                    body = json.dumps({"model": "fixture", "stream": streaming, "max_tokens": 128,
                                       "messages": [{"role": "user", "content": "fixture only"}]}).encode()
                    client.sendall((f"POST {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
                        f"Content-Type: application/json\r\nContent-Length: {len(body)}\r\n\r\n").encode() + body)
                    assert Provider.opened.wait(3), "upstream request not received"
                    if read_first:
                        data = b""
                        while b"data:" not in data:
                            part = client.recv(65536)
                            assert part, "proxy closed before first SSE data"
                            data += part
                    client.shutdown(socket.SHUT_RDWR)
                    client.close()
                    assert Provider.disconnected.wait(2), f"upstream continued: {provider} {path} stream={streaming}"

                    # Cancellation must be local to one request/channel and must
                    # not record an abandoned request as a successful completion.
                    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
                    for _ in range(2):  # Sequential requests on the same keep-alive socket.
                        connection.request("POST", path, json.dumps({"model": "complete-fixture", "max_tokens": 128,
                            "messages": [{"role": "user", "content": "fixture only"}]}), {"Content-Type": "application/json"})
                        response = connection.getresponse()
                        assert response.status == 200, response.read()
                        response.read()
                    connection.close()
                    journal = root / "sessions.jsonl"
                    events = [json.loads(line) for line in journal.read_text().splitlines()]
                    assert len(events) == 2, "canceled work was recorded as a completed request"
                    assert events[0]["record"]["model"] == "complete-fixture", events
                    print(f"PASS disconnect cancels {provider} {path} stream={streaming} after_first_chunk={read_first}; sequential keep-alive succeeds")
                finally:
                    Provider.release.set()
                    proxy.terminate()
                    proxy.wait(timeout=5)
                    upstream.shutdown()
