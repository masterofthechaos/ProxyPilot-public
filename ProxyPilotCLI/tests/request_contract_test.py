#!/usr/bin/env python3
import http.server
import json
import os
import pathlib
import subprocess
import tempfile
import threading


class Provider(http.server.BaseHTTPRequestHandler):
    received = None

    def log_message(self, *_):
        pass

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        Provider.received = json.loads(self.rfile.read(length))
        body = json.dumps({
            "id": "fixture",
            "model": "fixture-returned",
            "choices": [{"message": {"role": "assistant", "content": "advice"}}],
            "usage": {"prompt_tokens": 7, "completion_tokens": 3, "total_tokens": 10, "cost": 0.004},
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


with tempfile.TemporaryDirectory(prefix="proxypilot-request-") as directory:
    root = pathlib.Path(directory)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    env = os.environ.copy()
    env["XDG_CONFIG_HOME"] = str(root / "config")
    env["PROXYPILOT_SESSION_REPORT_PATH"] = str(root / "session.jsonl")
    binary = pathlib.Path(
        os.environ.get(
            "PROXYPILOT_BIN",
            pathlib.Path(__file__).parents[1] / ".build" / "debug" / "proxypilot",
        )
    )
    session_id = "00000000-0000-0000-0000-000000000138"
    command = [
        str(binary), "request", "--provider", "ollama", "--model", "fixture-requested",
        "--url", f"http://127.0.0.1:{server.server_port}/v1", "--session-id", session_id,
        "--role", "navigator", "--max-output-tokens", "2048", "--json",
    ]
    result = subprocess.run(
        command,
        input=json.dumps({"schema_version": 1, "messages": [{"role": "user", "content": "bounded"}]}),
        text=True,
        capture_output=True,
        env=env,
        timeout=20,
        check=True,
    )
    output = json.loads(result.stdout)
    data = output["data"]
    assert data["requested_model"] == "fixture-requested", data
    assert data["returned_model"] == "fixture-returned", data
    assert data["role"] == "navigator", data
    assert data["provider_reported_cost_usd"] == 0.004, data
    assert data["runtime"] == "ephemeral_loopback", data
    assert Provider.received["max_tokens"] == 2048, Provider.received
    assert not (root / "config" / "proxypilot" / "route.json").exists()
    events = [json.loads(line) for line in (root / "session.jsonl").read_text().splitlines()]
    assert events[-1]["role"] == "navigator", events[-1]
    assert events[-1]["record"]["model"] == "fixture-returned", events[-1]
    # Do not consult the owner's stored cloud key: the empty environment value
    # short-circuits credential lookup and keeps this loopback fixture key-free.
    env["OPENAI_API_KEY"] = ""
    for model in ["gpt-5", "o1", "o3", "o4-mini"]:
        capped = command.copy()
        capped[capped.index("--provider") + 1] = "openai"
        capped[capped.index("--model") + 1] = model
        capped[capped.index("--max-output-tokens") + 1] = "128"
        result = subprocess.run(capped, input=json.dumps({
            "schema_version": 1, "max_tokens": 9999, "max_completion_tokens": 16384,
            "messages": [{"role": "user", "content": "fixture only"}],
        }), text=True, capture_output=True, env=env, timeout=20, check=True)
        assert Provider.received["max_completion_tokens"] == 128, Provider.received
        assert "max_tokens" not in Provider.received, Provider.received

    rejected = command.copy()
    rejected[rejected.index("--url") + 1] = "http://127.attacker.example/v1"
    result = subprocess.run(rejected, input="", text=True, capture_output=True,
                            env=env, timeout=20)
    assert result.returncode != 0, result.stdout
    assert json.loads(result.stdout)["error"]["code"] == "E036", result.stdout
    server.shutdown()
    print("ProxyPilot independent request contract passed: attribution, conflicting caps, DNS lookalike rejection")
