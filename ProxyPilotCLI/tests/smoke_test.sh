#!/usr/bin/env bash
# smoke_test.sh — End-to-end smoke tests for the ProxyPilot CLI.
# Run from the ProxyPilotCLI directory: bash tests/smoke_test.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY="$PROJECT_DIR/.build/debug/proxypilot"
SMOKE_PORT=$((15000 + RANDOM % 20000))
MCP_SMOKE_PORT=$((35000 + RANDOM % 20000))
DISCOVERY_SMOKE_PORT=$((35000 + RANDOM % 20000))
VALID_UPSTREAM_PORT=$((15000 + RANDOM % 20000))
VALID_PROXY_PORT=$((15000 + RANDOM % 20000))
PROXY_PID=""
DISCOVERY_PROXY_PID=""
VALID_UPSTREAM_PID=""
VALID_PROXY_PID=""
AUTH_SECRETS_DIR=""
SMOKE_CONFIG_HOME="$(mktemp -d)"
SMOKE_MODULE_CACHE="$(mktemp -d)"
export XDG_CONFIG_HOME="$SMOKE_CONFIG_HOME"
PID_FILE="$XDG_CONFIG_HOME/proxypilot/proxypilot.pid"

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
pass() {
    local name="$1"
    echo -e "  ${GREEN}[PASS]${RESET} $name"
    PASS=$((PASS + 1))
}

fail() {
    local name="$1"
    local detail="${2:-}"
    echo -e "  ${RED}[FAIL]${RESET} $name"
    if [[ -n "$detail" ]]; then
        echo -e "         ${YELLOW}Detail:${RESET} $detail"
    fi
    FAIL=$((FAIL + 1))
}

run_test() {
    local name="$1"
    echo -e "\n${BOLD}TEST:${RESET} $name"
}

# ---------------------------------------------------------------------------
# Cleanup — runs on EXIT (including set -e failures)
# ---------------------------------------------------------------------------
cleanup() {
    if [[ -n "$PROXY_PID" ]]; then
        if kill -0 "$PROXY_PID" 2>/dev/null; then
            kill "$PROXY_PID" 2>/dev/null || true
            sleep 0.2
            if kill -0 "$PROXY_PID" 2>/dev/null; then
                kill -9 "$PROXY_PID" 2>/dev/null || true
            fi
            wait "$PROXY_PID" 2>/dev/null || true
        fi
    fi
    if [[ -n "$DISCOVERY_PROXY_PID" ]]; then
        if kill -0 "$DISCOVERY_PROXY_PID" 2>/dev/null; then
            kill "$DISCOVERY_PROXY_PID" 2>/dev/null || true
        fi
    fi
    if [[ -n "$VALID_PROXY_PID" ]]; then
        if kill -0 "$VALID_PROXY_PID" 2>/dev/null; then
            kill "$VALID_PROXY_PID" 2>/dev/null || true
        fi
    fi
    if [[ -n "$VALID_UPSTREAM_PID" ]]; then
        if kill -0 "$VALID_UPSTREAM_PID" 2>/dev/null; then
            kill "$VALID_UPSTREAM_PID" 2>/dev/null || true
        fi
    fi
    if [[ -n "$AUTH_SECRETS_DIR" && -d "$AUTH_SECRETS_DIR" ]]; then
        rm -rf "$AUTH_SECRETS_DIR"
    fi
    if [[ -n "$SMOKE_CONFIG_HOME" && -d "$SMOKE_CONFIG_HOME" ]]; then
        rm -rf "$SMOKE_CONFIG_HOME"
    fi
    if [[ -n "$SMOKE_MODULE_CACHE" && -d "$SMOKE_MODULE_CACHE" ]]; then
        rm -rf "$SMOKE_MODULE_CACHE"
    fi
    # Also clean up any stale PID file that might be left from a crashed run
    rm -f "$PID_FILE"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Ensure we start clean — remove any stale PID file from prior runs
# ---------------------------------------------------------------------------
rm -f "$PID_FILE"

# Pick a free TCP port for this run.
while lsof -iTCP:"$SMOKE_PORT" -sTCP:LISTEN >/dev/null 2>&1; do
    SMOKE_PORT=$((15000 + RANDOM % 20000))
done
while lsof -iTCP:"$MCP_SMOKE_PORT" -sTCP:LISTEN >/dev/null 2>&1; do
    MCP_SMOKE_PORT=$((35000 + RANDOM % 20000))
done
while lsof -iTCP:"$DISCOVERY_SMOKE_PORT" -sTCP:LISTEN >/dev/null 2>&1; do
    DISCOVERY_SMOKE_PORT=$((35000 + RANDOM % 20000))
done
while lsof -iTCP:"$VALID_UPSTREAM_PORT" -sTCP:LISTEN >/dev/null 2>&1; do
    VALID_UPSTREAM_PORT=$((15000 + RANDOM % 20000))
done
while lsof -iTCP:"$VALID_PROXY_PORT" -sTCP:LISTEN >/dev/null 2>&1 || [[ "$VALID_PROXY_PORT" == "$VALID_UPSTREAM_PORT" ]]; do
    VALID_PROXY_PORT=$((15000 + RANDOM % 20000))
done

echo ""
echo -e "${BOLD}==========================================${RESET}"
echo -e "${BOLD}  ProxyPilot CLI Smoke Tests${RESET}"
echo -e "${BOLD}  Binary: $BINARY${RESET}"
echo -e "${BOLD}  Port:   $SMOKE_PORT${RESET}"
echo -e "${BOLD}  MCP:    $MCP_SMOKE_PORT${RESET}"
echo -e "${BOLD}  Disc:   $DISCOVERY_SMOKE_PORT${RESET}"
echo -e "${BOLD}  Valid:  $VALID_PROXY_PORT -> $VALID_UPSTREAM_PORT${RESET}"
echo -e "${BOLD}==========================================${RESET}"

# ===========================================================================
# TEST 1 — Build
# ===========================================================================
run_test "Build CLI binary (swift build)"

cd "$PROJECT_DIR"
if env \
    CLANG_MODULE_CACHE_PATH="$SMOKE_MODULE_CACHE/clang" \
    SWIFTPM_MODULECACHE_OVERRIDE="$SMOKE_MODULE_CACHE/swiftpm" \
    swift build >/tmp/proxypilot_smoke_build.log 2>&1; then
    pass "swift build succeeded"
else
    fail "swift build" "Build did not complete successfully (see /tmp/proxypilot_smoke_build.log)"
fi

# Verify binary exists
if [[ -x "$BINARY" ]]; then
    pass "Binary is executable at .build/debug/proxypilot"
else
    fail "Binary exists and is executable" "Not found: $BINARY"
    echo -e "\n${RED}Cannot continue without binary. Aborting.${RESET}"
    exit 1
fi

# ===========================================================================
# TEST 2 — --version
# ===========================================================================
run_test "--version outputs a version string"

VERSION_OUTPUT="$("$BINARY" --version 2>&1)"
if echo "$VERSION_OUTPUT" | grep -qE '[0-9]+\.[0-9]+'; then
    pass "--version contains a version number: '$VERSION_OUTPUT'"
else
    fail "--version" "Output did not contain a version number: '$VERSION_OUTPUT'"
fi

# ===========================================================================
# TEST 3 — --help shows subcommands
# ===========================================================================
run_test "--help shows expected subcommands"

HELP_OUTPUT="$("$BINARY" --help 2>&1)"

for subcmd in start stop status models logs config auth setup launch update serve; do
    if echo "$HELP_OUTPUT" | grep -q "$subcmd"; then
        pass "--help lists subcommand: $subcmd"
    else
        fail "--help lists subcommand: $subcmd" "Not found in help output"
    fi
done

run_test "start and serve help document prompt caching mode"

START_HELP="$("$BINARY" start --help 2>&1)"
if echo "$START_HELP" | grep -q -- "--prompt-caching" && echo "$START_HELP" | grep -q "observe-only"; then
    pass "start --help documents --prompt-caching modes"
else
    fail "start --help documents --prompt-caching" "$START_HELP"
fi

SERVE_HELP="$("$BINARY" serve --help 2>&1)"
if echo "$SERVE_HELP" | grep -q -- "--prompt-caching" && echo "$SERVE_HELP" | grep -q "observe-only"; then
    pass "serve --help documents --prompt-caching modes"
else
    fail "serve --help documents --prompt-caching" "$SERVE_HELP"
fi

# ===========================================================================
# TEST 4 — status --port <smoke-port> --json reports stopped (no server running)
# ===========================================================================
run_test "status --json reports stopped before start"

STATUS_JSON="$("$BINARY" status --port "$SMOKE_PORT" --json 2>&1)"
STOPPED_STATUS="$(python3 - "$STATUS_JSON" <<'PY'
import sys, json
try:
    d = json.loads(sys.argv[1])
    assert d.get("schema_version") == 1
    assert d.get("command") == "status"
    assert isinstance(d["data"]["http"]["port"], int)
    print(d.get("data", {}).get("effective_status", "MISSING"))
except Exception as e:
    print("PARSE_ERROR: " + str(e))
PY
)"

if [[ "$STOPPED_STATUS" == "stopped" ]]; then
    pass "status reports stopped: $STATUS_JSON"
else
    fail "status reports stopped" "Got status='$STOPPED_STATUS' from: $STATUS_JSON"
fi

run_test "status --require-running exits 3 when stopped"

set +e
REQUIRE_JSON="$("$BINARY" status --port "$SMOKE_PORT" --json --require-running 2>&1)"
REQUIRE_CODE=$?
set -e
REQUIRE_CHECK="$(python3 - "$REQUIRE_JSON" <<'PY'
import sys, json
try:
    d = json.loads(sys.argv[1])
    assert d.get("schema_version") == 1
    assert d.get("ok") is False
    assert d.get("error", {}).get("code") == "E020_PROXY_STOPPED"
    print("PASS")
except Exception as e:
    print("PARSE_ERROR:" + str(e))
PY
)"
if [[ "$REQUIRE_CODE" -eq 3 && "$REQUIRE_CHECK" == "PASS" ]]; then
    pass "status --require-running exits 3 with structured error"
else
    fail "status --require-running stopped gate" "code=$REQUIRE_CODE check=$REQUIRE_CHECK json=$REQUIRE_JSON"
fi

# ===========================================================================
# TEST 5 — Start the proxy in the background
# ===========================================================================
run_test "Start proxy on port $SMOKE_PORT"

set +e
START_JSON="$("$BINARY" start --provider ollama --port "$SMOKE_PORT" --model smoke-model --json --daemon 2>&1)"
START_CODE=$?
set -e
START_CHECK="$(python3 - "$START_JSON" <<'PY'
import sys, json
try:
    d = json.loads(sys.argv[1])
    if d.get("ok") is True and d.get("data", {}).get("status") == "started":
        print("PASS")
    else:
        print(f"FAIL:{d}")
except Exception as e:
    print(f"PARSE_ERROR:{e}")
PY
)"
if [[ "$START_CODE" -eq 0 && "$START_CHECK" == "PASS" ]]; then
    PROXY_PID="$(python3 - "$START_JSON" <<'PY'
import sys, json
try:
    d = json.loads(sys.argv[1])
    print(d.get("data", {}).get("pid", ""))
except Exception:
    print("")
PY
)"
else
    fail "Proxy daemon start" "code=$START_CODE check=$START_CHECK json=$START_JSON"
fi

# Wait up to 5 seconds for the PID file and port to appear
STARTED=0
for i in $(seq 1 10); do
    sleep 0.5
    if [[ -f "$PID_FILE" ]]; then
        STARTED=1
        break
    fi
done

if [[ "$STARTED" -eq 1 ]]; then
    pass "Proxy started (PID $PROXY_PID, PID file present)"
else
    fail "Proxy started within 5 seconds" "PID file never appeared at $PID_FILE"
fi

# Give the server another half-second to bind fully
sleep 0.5

# ===========================================================================
# TEST 6 — GET /v1/models returns valid JSON with object:"list"
# ===========================================================================
run_test "GET /v1/models returns valid JSON with object:\"list\""

MODELS_HTTP_CODE="$(curl -s -o /tmp/pp_models.json -w "%{http_code}" \
    http://127.0.0.1:${SMOKE_PORT}/v1/models 2>&1 || true)"
MODELS_BODY="$(cat /tmp/pp_models.json 2>/dev/null || echo '')"

if [[ "$MODELS_HTTP_CODE" == "200" ]]; then
    MODELS_OBJECT="$(python3 -c "
import json, sys
try:
    d = json.loads(open('/tmp/pp_models.json').read())
    print(d.get('object', 'MISSING'))
except Exception as e:
    print('PARSE_ERROR: ' + str(e))
")"
    if [[ "$MODELS_OBJECT" == "list" ]]; then
        pass "GET /v1/models → 200, object=list"
    else
        fail "GET /v1/models JSON has object:list" "object='$MODELS_OBJECT', body=$MODELS_BODY"
    fi
else
    fail "GET /v1/models → 200" "HTTP $MODELS_HTTP_CODE, body=$MODELS_BODY"
fi

# ===========================================================================
# TEST 7 — status --port <port> --json reports running
# ===========================================================================
run_test "status --port $SMOKE_PORT --json reports running"

STATUS2_JSON="$("$BINARY" status --port "$SMOKE_PORT" --json 2>&1)"
RUNNING_STATUS="$(python3 - "$STATUS2_JSON" <<'PY'
import sys, json
try:
    d = json.loads(sys.argv[1])
    assert d.get("schema_version") == 1
    assert isinstance(d["data"]["http"]["models_count"], int)
    print(d.get("data", {}).get("effective_status", "MISSING"))
except Exception as e:
    print("PARSE_ERROR: " + str(e))
PY
)"

if [[ "$RUNNING_STATUS" == "running" ]]; then
    pass "status reports running: $STATUS2_JSON"
else
    fail "status reports running" "Got status='$RUNNING_STATUS' from: $STATUS2_JSON"
fi

# ===========================================================================
# TEST 8 — status discovers CLI-owned process when PID file is missing
# ===========================================================================
run_test "status --port $SMOKE_PORT --json discovers CLI process without PID file"

rm -f "$PID_FILE"

STATUS_UNMANAGED_JSON="$("$BINARY" status --port "$SMOKE_PORT" --json 2>&1)"
UNMANAGED_STATUS="$(python3 - "$STATUS_UNMANAGED_JSON" <<'PY'
import sys, json
try:
    d = json.loads(sys.argv[1])
    assert d.get("schema_version") == 1
    data = d.get("data", {})
    process = data.get("process", {})
    if data.get("effective_status") == "running_discovered" and process.get("owner") == "cli_discovered":
        print("PASS")
    else:
        print(f"FAIL:{d}")
except Exception as e:
    print("PARSE_ERROR: " + str(e))
PY
)"

if [[ "$UNMANAGED_STATUS" == "PASS" ]]; then
    pass "status discovers CLI process without PID file: $STATUS_UNMANAGED_JSON"
else
    fail "status discovers CLI process without PID file" "$UNMANAGED_STATUS :: $STATUS_UNMANAGED_JSON"
fi

# ===========================================================================
# TEST 9 — POST /v1/chat/completions — server responds (not crash)
# ===========================================================================
run_test "POST /v1/chat/completions — proxy responds (no crash)"

CHAT_HTTP_CODE="$(curl -s -o /tmp/pp_chat.json -w "%{http_code}" \
    -X POST http://127.0.0.1:${SMOKE_PORT}/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"ping"}]}' \
    2>&1 || true)"
CHAT_BODY="$(cat /tmp/pp_chat.json 2>/dev/null || echo '')"

# Acceptable codes: 401 (upstream rejected no-key), 502 (proxy-level upstream error),
# or any 4xx/5xx that is NOT a connection-refused (which would mean the proxy crashed).
if [[ "$CHAT_HTTP_CODE" =~ ^[0-9]+$ ]] && [[ "$CHAT_HTTP_CODE" -ge 200 ]]; then
    pass "POST /v1/chat/completions → HTTP $CHAT_HTTP_CODE (proxy alive, not crashed)"
else
    fail "POST /v1/chat/completions — proxy responds" "Got code='$CHAT_HTTP_CODE', body=$CHAT_BODY"
fi

# Verify the proxy process is still running after the request
if kill -0 "$PROXY_PID" 2>/dev/null; then
    pass "Proxy process still alive after /v1/chat/completions request"
else
    fail "Proxy process still alive after /v1/chat/completions" "PID $PROXY_PID is gone"
    PROXY_PID=""  # already dead, don't try to kill in cleanup
fi

# ===========================================================================
# TEST 10 — POST /v1/messages (Anthropic format) — returns 502, not crash
# ===========================================================================
run_test "POST /v1/messages (Anthropic format) — returns 502, not crash"

MSGS_HTTP_CODE="$(curl -s -o /tmp/pp_messages.json -w "%{http_code}" \
    -X POST http://127.0.0.1:${SMOKE_PORT}/v1/messages \
    -H "Content-Type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -d '{"model":"claude-3-haiku-20240307","max_tokens":10,"messages":[{"role":"user","content":"ping"}]}' \
    2>&1 || true)"
MSGS_BODY="$(cat /tmp/pp_messages.json 2>/dev/null || echo '')"

# Acceptable: 401, 502 — any HTTP response means the proxy did not crash
if [[ "$MSGS_HTTP_CODE" =~ ^[0-9]+$ ]] && [[ "$MSGS_HTTP_CODE" -ge 200 ]]; then
    pass "POST /v1/messages → HTTP $MSGS_HTTP_CODE (proxy alive)"
    if [[ "$MSGS_HTTP_CODE" == "502" ]]; then
        pass "POST /v1/messages returned expected 502 (upstream auth error surfaced)"
    fi
else
    fail "POST /v1/messages — proxy responds" "Got code='$MSGS_HTTP_CODE', body=$MSGS_BODY"
fi

# Verify the proxy process is still running
if kill -0 "$PROXY_PID" 2>/dev/null; then
    pass "Proxy process still alive after /v1/messages request"
else
    fail "Proxy process still alive after /v1/messages" "PID $PROXY_PID is gone"
    PROXY_PID=""
fi

# ===========================================================================
# TEST 11 — Stop the proxy
# ===========================================================================
run_test "Stop the proxy through proxypilot stop"

if [[ -n "$PROXY_PID" ]]; then
    STOP_JSON="$("$BINARY" stop --port "$SMOKE_PORT" --json 2>&1)"
    STOP_CHECK="$(python3 - "$STOP_JSON" <<'PY'
import sys, json
try:
    d = json.loads(sys.argv[1])
    status = d.get("data", {}).get("status")
    if d.get("ok") is True and status in ("stopped", "killed", "stopped_discovered"):
        print("PASS")
    else:
        print(f"FAIL:{d}")
except Exception as e:
    print(f"PARSE_ERROR:{e}")
PY
)"
    if [[ "$STOP_CHECK" == "PASS" ]]; then
        PROXY_PID=""  # mark as handled so cleanup doesn't double-kill
        sleep 0.5
        pass "proxypilot stop stopped the proxy: $STOP_JSON"
    else
        fail "Stop proxy" "$STOP_CHECK :: $STOP_JSON"
    fi
else
    fail "Stop proxy" "PROXY_PID was empty — proxy may have already exited"
fi

# ===========================================================================
# TEST 12 — status --port <smoke-port> --json reports stopped after kill
# ===========================================================================
run_test "status --json reports stopped after proxy is killed"

# The PID file may linger briefly; give it a moment then check
sleep 0.5

STATUS3_JSON="$("$BINARY" status --port "$SMOKE_PORT" --json 2>&1)"
FINAL_STATUS="$(python3 - "$STATUS3_JSON" <<'PY'
import sys, json
try:
    d = json.loads(sys.argv[1])
    assert d.get("schema_version") == 1
    print(d.get("data", {}).get("effective_status", "MISSING"))
except Exception as e:
    print("PARSE_ERROR: " + str(e))
PY
)"

if [[ "$FINAL_STATUS" == "stopped" ]]; then
    pass "status reports stopped after proxy kill: $STATUS3_JSON"
else
    fail "status reports stopped after kill" "Got status='$FINAL_STATUS' from: $STATUS3_JSON"
fi

# ===========================================================================
# TEST 13 — valid upstream returns usable chat/messages envelopes
# ===========================================================================
run_test "Start local OpenAI-compatible stub for valid response checks"

python3 - "$VALID_UPSTREAM_PORT" >/tmp/proxypilot_smoke_stub.log 2>&1 <<'PY' &
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port = int(sys.argv[1])

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        return

    def _read_json(self):
        length = int(self.headers.get("content-length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        return json.loads(raw.decode("utf-8") or "{}")

    def _send(self, status, body, content_type="application/json"):
        payload = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/v1/models":
            self._send(200, json.dumps({
                "object": "list",
                "data": [{"id": "smoke-model", "object": "model"}]
            }))
        else:
            self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        try:
            body = self._read_json()
        except Exception:
            self._send(400, json.dumps({"error": "invalid json"}))
            return

        if self.path != "/v1/chat/completions":
            self._send(404, json.dumps({"error": "not found"}))
            return

        if body.get("stream") is True:
            chunks = (
                'data: {"id":"chatcmpl-smoke","object":"chat.completion.chunk","model":"smoke-model","choices":[{"index":0,"delta":{"content":"stub pong"},"finish_reason":null}]}\n\n'
                'data: {"id":"chatcmpl-smoke","object":"chat.completion.chunk","model":"smoke-model","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}\n\n'
                'data: [DONE]\n\n'
            )
            self._send(200, chunks, "text/event-stream")
            return

        self._send(200, json.dumps({
            "id": "chatcmpl-smoke",
            "object": "chat.completion",
            "model": "smoke-model",
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": "stub pong"},
                "finish_reason": "stop"
            }],
            "usage": {"prompt_tokens": 3, "completion_tokens": 2, "total_tokens": 5}
        }))

server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
server.serve_forever()
PY
VALID_UPSTREAM_PID=$!

VALID_UPSTREAM_READY=0
for i in $(seq 1 20); do
    sleep 0.2
    if curl -fsS "http://127.0.0.1:${VALID_UPSTREAM_PORT}/v1/models" >/tmp/pp_valid_models.json 2>/dev/null; then
        VALID_UPSTREAM_READY=1
        break
    fi
done

if [[ "$VALID_UPSTREAM_READY" -eq 1 ]]; then
    pass "Local OpenAI-compatible stub is ready"
else
    fail "Local OpenAI-compatible stub is ready" "see /tmp/proxypilot_smoke_stub.log"
fi

run_test "Start proxy against local stub on port $VALID_PROXY_PORT"

VALID_START_JSON="$("$BINARY" start --provider openai --upstream-url "http://127.0.0.1:${VALID_UPSTREAM_PORT}/v1" --key smoke-key --port "$VALID_PROXY_PORT" --model smoke-model --json --daemon 2>&1)"
VALID_START_CHECK="$(python3 - "$VALID_START_JSON" <<'PY'
import json
import sys
try:
    d = json.loads(sys.argv[1])
    if d.get("ok") is True and d.get("data", {}).get("status") == "started":
        print("PASS")
    else:
        print(f"FAIL:{d}")
except Exception as e:
    print(f"PARSE_ERROR:{e}")
PY
)"
if [[ "$VALID_START_CHECK" == "PASS" ]]; then
    VALID_PROXY_PID="$(python3 - "$VALID_START_JSON" <<'PY'
import json
import sys
try:
    d = json.loads(sys.argv[1])
    print(d.get("data", {}).get("pid", ""))
except Exception:
    print("")
PY
)"
    pass "valid-response proxy started"
else
    fail "valid-response proxy start" "$VALID_START_CHECK :: $VALID_START_JSON"
fi

sleep 0.5

run_test "POST /v1/chat/completions returns assistant content from stub"

VALID_CHAT_HTTP_CODE="$(curl -s -o /tmp/pp_valid_chat.json -w "%{http_code}" \
    -X POST http://127.0.0.1:${VALID_PROXY_PORT}/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"smoke-model","messages":[{"role":"user","content":"ping"}]}' \
    2>&1 || true)"
VALID_CHAT_CHECK="$(python3 - "$VALID_CHAT_HTTP_CODE" /tmp/pp_valid_chat.json <<'PY'
import json
import sys
code = sys.argv[1]
path = sys.argv[2]
try:
    d = json.load(open(path))
    content = d["choices"][0]["message"]["content"]
    if code == "200" and content:
        print("PASS")
    else:
        print(f"FAIL:code={code} content={content!r} body={d}")
except Exception as e:
    print(f"PARSE_ERROR:{e}")
PY
)"
if [[ "$VALID_CHAT_CHECK" == "PASS" ]]; then
    pass "chat completions returned 200 with non-empty assistant content"
else
    fail "chat completions valid response" "$VALID_CHAT_CHECK :: $(cat /tmp/pp_valid_chat.json 2>/dev/null || true)"
fi

run_test "POST /v1/messages returns Anthropic JSON content from stub"

VALID_MSGS_HTTP_CODE="$(curl -s -o /tmp/pp_valid_messages.json -w "%{http_code}" \
    -X POST http://127.0.0.1:${VALID_PROXY_PORT}/v1/messages \
    -H "Content-Type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -d '{"model":"claude-3-haiku-20240307","max_tokens":10,"messages":[{"role":"user","content":"ping"}]}' \
    2>&1 || true)"
VALID_MSGS_CHECK="$(python3 - "$VALID_MSGS_HTTP_CODE" /tmp/pp_valid_messages.json <<'PY'
import json
import sys
code = sys.argv[1]
path = sys.argv[2]
try:
    d = json.load(open(path))
    content = d["content"][0]["text"]
    if code == "200" and d.get("type") == "message" and content:
        print("PASS")
    else:
        print(f"FAIL:code={code} content={content!r} body={d}")
except Exception as e:
    print(f"PARSE_ERROR:{e}")
PY
)"
if [[ "$VALID_MSGS_CHECK" == "PASS" ]]; then
    pass "messages returned 200 with non-empty Anthropic content"
else
    fail "messages valid response" "$VALID_MSGS_CHECK :: $(cat /tmp/pp_valid_messages.json 2>/dev/null || true)"
fi

run_test "Streaming /v1/messages returns Anthropic SSE events from stub"

VALID_STREAM_HTTP_CODE="$(curl -s -o /tmp/pp_valid_messages_stream.txt -w "%{http_code}" \
    -X POST http://127.0.0.1:${VALID_PROXY_PORT}/v1/messages \
    -H "Content-Type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -d '{"model":"claude-3-haiku-20240307","max_tokens":10,"stream":true,"messages":[{"role":"user","content":"ping"}]}' \
    2>&1 || true)"
VALID_STREAM_CHECK="$(python3 - "$VALID_STREAM_HTTP_CODE" /tmp/pp_valid_messages_stream.txt <<'PY'
import sys
code = sys.argv[1]
body = open(sys.argv[2]).read()
if code == "200" and "event: content_block_delta" in body and '"text":"stub pong"' in body and "event: message_stop" in body:
    print("PASS")
else:
    print(f"FAIL:code={code} body={body[:500]}")
PY
)"
if [[ "$VALID_STREAM_CHECK" == "PASS" ]]; then
    pass "streaming messages returned 200 with Anthropic SSE text delta"
else
    fail "streaming messages valid SSE" "$VALID_STREAM_CHECK"
fi

if [[ -n "$VALID_PROXY_PID" ]]; then
    VALID_STOP_JSON="$("$BINARY" stop --port "$VALID_PROXY_PORT" --json 2>&1)"
    VALID_STOP_CHECK="$(python3 - "$VALID_STOP_JSON" <<'PY'
import json
import sys
try:
    d = json.loads(sys.argv[1])
    if d.get("ok") is True and d.get("data", {}).get("status") in ("stopped", "killed", "stopped_discovered"):
        print("PASS")
    else:
        print(f"FAIL:{d}")
except Exception as e:
    print(f"PARSE_ERROR:{e}")
PY
)"
    if [[ "$VALID_STOP_CHECK" == "PASS" ]]; then
        VALID_PROXY_PID=""
        pass "valid-response proxy stopped"
    else
        fail "valid-response proxy stop" "$VALID_STOP_CHECK :: $VALID_STOP_JSON"
    fi
fi

if [[ -n "$VALID_UPSTREAM_PID" ]]; then
    kill "$VALID_UPSTREAM_PID" 2>/dev/null || true
    wait "$VALID_UPSTREAM_PID" 2>/dev/null || true
    VALID_UPSTREAM_PID=""
fi

# ===========================================================================
# TEST 14 — stop discovers CLI-started process when PID file is missing
# ===========================================================================
run_test "stop --port discovers CLI-started process when PID file is missing"

DISCOVERY_START_JSON="$("$BINARY" start --provider ollama --port "$DISCOVERY_SMOKE_PORT" --model discovery-smoke --json --daemon 2>&1)"
DISCOVERY_START_CHECK="$(python3 - "$DISCOVERY_START_JSON" <<'PY'
import json
import sys
try:
    d = json.loads(sys.argv[1])
    if d.get("ok") is True and d.get("data", {}).get("status") == "started":
        print("PASS")
    else:
        print(f"FAIL:{d}")
except Exception as e:
    print(f"PARSE_ERROR:{e}")
PY
)"
if [[ "$DISCOVERY_START_CHECK" == "PASS" ]]; then
    DISCOVERY_PROXY_PID="$(python3 - "$DISCOVERY_START_JSON" <<'PY'
import json
import sys
try:
    d = json.loads(sys.argv[1])
    print(d.get("data", {}).get("pid", ""))
except Exception:
    print("")
PY
)"
    pass "daemon start for discovery smoke succeeds"
else
    fail "daemon start for discovery smoke" "$DISCOVERY_START_CHECK :: $DISCOVERY_START_JSON"
fi

rm -f "$PID_FILE"
sleep 0.5

DISCOVERY_STATUS_JSON="$("$BINARY" status --port "$DISCOVERY_SMOKE_PORT" --json 2>&1)"
DISCOVERY_STATUS_CHECK="$(python3 - "$DISCOVERY_STATUS_JSON" <<'PY'
import json
import sys
try:
    d = json.loads(sys.argv[1])
    data = d.get("data", {})
    process = data.get("process", {})
    if data.get("effective_status") in ("running_discovered", "running_unhealthy_discovered") and process.get("owner") == "cli_discovered":
        print("PASS")
    else:
        print(f"FAIL:{d}")
except Exception as e:
    print(f"PARSE_ERROR:{e}")
PY
)"
if [[ "$DISCOVERY_STATUS_CHECK" == "PASS" ]]; then
    pass "status discovers CLI process without PID file"
else
    fail "status discovers CLI process without PID file" "$DISCOVERY_STATUS_CHECK :: $DISCOVERY_STATUS_JSON"
fi

DISCOVERY_STOP_JSON="$("$BINARY" stop --port "$DISCOVERY_SMOKE_PORT" --json 2>&1)"
DISCOVERY_STOP_CHECK="$(python3 - "$DISCOVERY_STOP_JSON" <<'PY'
import json
import sys
try:
    d = json.loads(sys.argv[1])
    if d.get("ok") is True and d.get("data", {}).get("status") == "stopped_discovered":
        print("PASS")
    else:
        print(f"FAIL:{d}")
except Exception as e:
    print(f"PARSE_ERROR:{e}")
PY
)"
if [[ "$DISCOVERY_STOP_CHECK" == "PASS" ]]; then
    DISCOVERY_PROXY_PID=""
    pass "stop --port stops discovered CLI process"
else
    fail "stop --port stops discovered CLI process" "$DISCOVERY_STOP_CHECK :: $DISCOVERY_STOP_JSON"
fi

# ===========================================================================
# TEST 14 — auth status --json (all providers)
# ===========================================================================
run_test "auth status --json lists all providers and local not_required"

AUTH_SECRETS_DIR="$(mktemp -d)"
AUTH_STATUS_JSON="$(PROXYPILOT_SECRETS_DIR="$AUTH_SECRETS_DIR" "$BINARY" auth status --json 2>&1)"
AUTH_STATUS_CHECK="$(python3 - "$AUTH_STATUS_JSON" <<'PY'
import json
import sys
raw = sys.argv[1]
try:
    d = json.loads(raw)
    if not d.get("ok", False):
        print("FAIL:not_ok")
        raise SystemExit(0)
    providers = d.get("data", {}).get("providers", [])
    status = {p.get("provider"): p.get("status") for p in providers}
    expected = {"openai", "groq", "zai", "openrouter", "xai", "chutes", "google", "deepseek", "mistral", "minimax", "minimax-cn", "qwen", "github-copilot", "ollama", "lmstudio"}
    if expected.issubset(set(status.keys())) and status.get("github-copilot") == "not_required" and status.get("ollama") == "not_required" and status.get("lmstudio") == "not_required":
        print("PASS")
    else:
        print(f"FAIL:providers={status}")
except Exception as e:
    print(f"PARSE_ERROR:{e}")
PY
)"
if [[ "$AUTH_STATUS_CHECK" == "PASS" ]]; then
    pass "auth status --json lists expected providers with local not_required"
else
    fail "auth status --json lists expected providers" "$AUTH_STATUS_CHECK :: $AUTH_STATUS_JSON"
fi

# ===========================================================================
# TEST 15 — auth set --provider openai --key <value>
# ===========================================================================
run_test "auth set stores key for openai"

AUTH_SET_JSON="$(PROXYPILOT_SECRETS_DIR="$AUTH_SECRETS_DIR" "$BINARY" auth set --provider openai --key test-key-123 --json 2>&1)"
AUTH_SET_CHECK="$(python3 - "$AUTH_SET_JSON" <<'PY'
import json
import sys
raw = sys.argv[1]
try:
    d = json.loads(raw)
    ok = d.get("ok") is True
    data = d.get("data", {})
    if ok and data.get("provider") == "openai" and data.get("status") == "stored":
        print("PASS")
    else:
        print(f"FAIL:{d}")
except Exception as e:
    print(f"PARSE_ERROR:{e}")
PY
)"
if [[ "$AUTH_SET_CHECK" == "PASS" ]]; then
    pass "auth set --provider openai --key test-key-123 --json succeeds"
else
    fail "auth set openai" "$AUTH_SET_CHECK :: $AUTH_SET_JSON"
fi

run_test "auth set help prefers stdin and warns about shell history"

AUTH_SET_HELP="$("$BINARY" auth set --help 2>&1)"
if echo "$AUTH_SET_HELP" | grep -qi -- "--stdin" && echo "$AUTH_SET_HELP" | grep -qi "shell history"; then
    pass "auth set --help warns that --key can be retained in shell history"
else
    fail "auth set help shell-history warning" "$AUTH_SET_HELP"
fi

# ===========================================================================
# TEST 16 — auth status --provider openai shows stored:true
# ===========================================================================
run_test "auth status --provider openai reports stored true"

AUTH_STATUS_OPENAI_JSON="$(PROXYPILOT_SECRETS_DIR="$AUTH_SECRETS_DIR" "$BINARY" auth status --provider openai --json 2>&1)"
AUTH_STATUS_OPENAI_CHECK="$(python3 - "$AUTH_STATUS_OPENAI_JSON" <<'PY'
import json
import sys
raw = sys.argv[1]
try:
    d = json.loads(raw)
    ok = d.get("ok") is True
    data = d.get("data", {})
    if ok and data.get("provider") == "openai" and data.get("stored") is True and data.get("status") == "stored":
        print("PASS")
    else:
        print(f"FAIL:{d}")
except Exception as e:
    print(f"PARSE_ERROR:{e}")
PY
)"
if [[ "$AUTH_STATUS_OPENAI_CHECK" == "PASS" ]]; then
    pass "auth status --provider openai --json shows stored true"
else
    fail "auth status --provider openai stored true" "$AUTH_STATUS_OPENAI_CHECK :: $AUTH_STATUS_OPENAI_JSON"
fi

# ===========================================================================
# TEST 17 — auth remove --provider openai --yes
# ===========================================================================
run_test "auth remove removes key for openai"

AUTH_REMOVE_JSON="$(PROXYPILOT_SECRETS_DIR="$AUTH_SECRETS_DIR" "$BINARY" auth remove --provider openai --yes --json 2>&1)"
AUTH_REMOVE_CHECK="$(python3 - "$AUTH_REMOVE_JSON" <<'PY'
import json
import sys
raw = sys.argv[1]
try:
    d = json.loads(raw)
    ok = d.get("ok") is True
    data = d.get("data", {})
    if ok and data.get("provider") == "openai" and data.get("status") == "removed":
        print("PASS")
    else:
        print(f"FAIL:{d}")
except Exception as e:
    print(f"PARSE_ERROR:{e}")
PY
)"
if [[ "$AUTH_REMOVE_CHECK" == "PASS" ]]; then
    pass "auth remove --provider openai --yes --json succeeds"
else
    fail "auth remove openai" "$AUTH_REMOVE_CHECK :: $AUTH_REMOVE_JSON"
fi

# ===========================================================================
# TEST 18 — auth status --provider openai shows stored:false
# ===========================================================================
run_test "auth status --provider openai reports stored false after remove"

AUTH_STATUS_OPENAI_AFTER_JSON="$(PROXYPILOT_SECRETS_DIR="$AUTH_SECRETS_DIR" "$BINARY" auth status --provider openai --json 2>&1)"
AUTH_STATUS_OPENAI_AFTER_CHECK="$(python3 - "$AUTH_STATUS_OPENAI_AFTER_JSON" <<'PY'
import json
import sys
raw = sys.argv[1]
try:
    d = json.loads(raw)
    ok = d.get("ok") is True
    data = d.get("data", {})
    if ok and data.get("provider") == "openai" and data.get("stored") is False and data.get("status") == "not_set":
        print("PASS")
    else:
        print(f"FAIL:{d}")
except Exception as e:
    print(f"PARSE_ERROR:{e}")
PY
)"
if [[ "$AUTH_STATUS_OPENAI_AFTER_CHECK" == "PASS" ]]; then
    pass "auth status --provider openai --json shows stored false"
else
    fail "auth status --provider openai stored false" "$AUTH_STATUS_OPENAI_AFTER_CHECK :: $AUTH_STATUS_OPENAI_AFTER_JSON"
fi

# ===========================================================================
# TEST 19 — auth set rejects local providers (E041)
# ===========================================================================
run_test "auth set rejects local provider ollama (E041)"

AUTH_SET_OLLAMA_JSON="$(PROXYPILOT_SECRETS_DIR="$AUTH_SECRETS_DIR" "$BINARY" auth set --provider ollama --json 2>&1 || true)"
AUTH_SET_OLLAMA_CHECK="$(python3 - "$AUTH_SET_OLLAMA_JSON" <<'PY'
import json
import sys
raw = sys.argv[1]
try:
    d = json.loads(raw)
    if d.get("ok") is False and d.get("error", {}).get("code") == "E041":
        print("PASS")
    else:
        print(f"FAIL:{d}")
except Exception as e:
    print(f"PARSE_ERROR:{e}")
PY
)"
if [[ "$AUTH_SET_OLLAMA_CHECK" == "PASS" ]]; then
    pass "auth set --provider ollama --json returns E041"
else
    fail "auth set ollama rejects local provider" "$AUTH_SET_OLLAMA_CHECK :: $AUTH_SET_OLLAMA_JSON"
fi

run_test "auth set rejects helper provider github-copilot (E041)"

AUTH_SET_COPILOT_JSON="$(PROXYPILOT_SECRETS_DIR="$AUTH_SECRETS_DIR" "$BINARY" auth set --provider github-copilot --json 2>&1 || true)"
AUTH_SET_COPILOT_CHECK="$(python3 - "$AUTH_SET_COPILOT_JSON" <<'PY'
import json
import sys
raw = sys.argv[1]
try:
    d = json.loads(raw)
    if d.get("ok") is False and d.get("error", {}).get("code") == "E041":
        print("PASS")
    else:
        print(f"FAIL:{d}")
except Exception as e:
    print(f"PARSE_ERROR:{e}")
PY
)"
if [[ "$AUTH_SET_COPILOT_CHECK" == "PASS" ]]; then
    pass "auth set --provider github-copilot --json returns E041"
else
    fail "auth set github-copilot rejects helper provider" "$AUTH_SET_COPILOT_CHECK :: $AUTH_SET_COPILOT_JSON"
fi

# ===========================================================================
# TEST 20 — auth set rejects empty keys (E040)
# ===========================================================================
run_test "auth set rejects whitespace key (E040)"

AUTH_SET_EMPTY_JSON="$(PROXYPILOT_SECRETS_DIR="$AUTH_SECRETS_DIR" "$BINARY" auth set --provider openai --key "  " --json 2>&1 || true)"
AUTH_SET_EMPTY_CHECK="$(python3 - "$AUTH_SET_EMPTY_JSON" <<'PY'
import json
import sys
raw = sys.argv[1]
try:
    d = json.loads(raw)
    if d.get("ok") is False and d.get("error", {}).get("code") == "E040":
        print("PASS")
    else:
        print(f"FAIL:{d}")
except Exception as e:
    print(f"PARSE_ERROR:{e}")
PY
)"
if [[ "$AUTH_SET_EMPTY_CHECK" == "PASS" ]]; then
    pass "auth set --provider openai --key '  ' --json returns E040"
else
    fail "auth set rejects empty key" "$AUTH_SET_EMPTY_CHECK :: $AUTH_SET_EMPTY_JSON"
fi

run_test "auth set rejects short z.ai key (E046)"

AUTH_SET_SHORT_ZAI_JSON="$(PROXYPILOT_SECRETS_DIR="$AUTH_SECRETS_DIR" "$BINARY" auth set --provider zai --key short-zai-key --json 2>&1 || true)"
AUTH_SET_SHORT_ZAI_CHECK="$(python3 - "$AUTH_SET_SHORT_ZAI_JSON" <<'PY'
import json
import sys
raw = sys.argv[1]
try:
    d = json.loads(raw)
    if d.get("ok") is False and d.get("error", {}).get("code") == "E046":
        print("PASS")
    else:
        print(f"FAIL:{d}")
except Exception as e:
    print(f"PARSE_ERROR:{e}")
PY
)"
if [[ "$AUTH_SET_SHORT_ZAI_CHECK" == "PASS" ]]; then
    pass "auth set --provider zai --key short-zai-key --json returns E046"
else
    fail "auth set rejects short z.ai key" "$AUTH_SET_SHORT_ZAI_CHECK :: $AUTH_SET_SHORT_ZAI_JSON"
fi

# ===========================================================================
# TEST 21 — models command exposes metadata/filter contract
# ===========================================================================
run_test "models command exposes metadata and tool-calling filter"

MODELS_HELP="$("$BINARY" models --help 2>&1)"
if echo "$MODELS_HELP" | grep -q -- "--metadata" && echo "$MODELS_HELP" | grep -q "tool-calling"; then
    pass "models --help documents --metadata and tool-calling filter"
else
    fail "models metadata/filter help" "$MODELS_HELP"
fi

if grep -q "model_summaries" "$PROJECT_DIR/Sources/Commands/ModelsCommand.swift"; then
    pass "models command emits model_summaries in metadata mode"
else
    fail "models command emits model_summaries" "Expected model_summaries coding key"
fi

# ===========================================================================
# TEST 22 — MCP agent-first tools are registered
# ===========================================================================
run_test "MCP registers agent-first recovery tools"

for tool in preflight auth_status auth_set verify_routing; do
    if grep -q "name: \"$tool\"" "$PROJECT_DIR/Sources/MCP/MCPServerSetup.swift"; then
        pass "MCP registers tool: $tool"
    else
        fail "MCP registers tool: $tool"
    fi
done

if grep -q "allow_secret_write" "$PROJECT_DIR/Sources/MCP/MCPServerSetup.swift"; then
    pass "MCP auth_set documents allow_secret_write"
else
    fail "MCP auth_set documents allow_secret_write"
fi

if grep -q "prompt_caching" "$PROJECT_DIR/Sources/MCP/MCPServerSetup.swift"; then
    pass "MCP proxy lifecycle tools document prompt_caching"
else
    fail "MCP proxy lifecycle tools document prompt_caching"
fi

# ===========================================================================
# TEST 23 — MCP validates agent inputs and returns structured stats
# ===========================================================================
run_test "MCP validates malformed agent calls and keeps stats structured"

MCP_CONTRACT_OUTPUT="$(python3 - "$BINARY" "$MCP_SMOKE_PORT" <<'PY'
import json
import select
import subprocess
import sys

binary = sys.argv[1]
port = int(sys.argv[2])

process = subprocess.Popen(
    [binary, "serve", "--mcp"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
)

def send(message):
    process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
    process.stdin.flush()

def read_response(timeout=5):
    ready, _, _ = select.select([process.stdout], [], [], timeout)
    if not ready:
        return None
    line = process.stdout.readline().strip()
    try:
        return json.loads(line)
    except json.JSONDecodeError as exc:
        print(f"FAIL:non_json:{exc}:{line}")
        process.kill()
        raise SystemExit(0)

def content_text(response):
    return "\n".join(part.get("text", "") for part in response.get("result", {}).get("content", []))

def envelope(response):
    text = content_text(response)
    first = text.splitlines()[0] if text else ""
    try:
        return json.loads(first)
    except json.JSONDecodeError:
        return None

try:
    send({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"proxypilot-smoke","version":"1"}}})
    read_response()
    send({"jsonrpc":"2.0","method":"notifications/initialized","params":{}})
    requests = [
        {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"preflight","arguments":{"provider":"not-a-provider","port":port}}},
        {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"proxy_start","arguments":{"provider":"ollama","port":str(port),"url":"http://127.0.0.1:11434/v1","model":"string-port"}}},
        {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_session_stats","arguments":{}}},
        {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"proxy_status","arguments":{"port":port}}},
        {"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"proxy_stop","arguments":{}}},
        {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"list_upstream_models","arguments":{"provider":"ollama","url":"http://127.0.0.1:9/v1","filter":"not-a-filter","metadata":True}}},
        {"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"preflight","arguments":{"provider":123,"port":port}}},
        {"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"list_upstream_models","arguments":{"provider":"ollama","url":"http://127.0.0.1:9/v1","filter":123}}},
        {"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"list_upstream_models","arguments":{"provider":"ollama","url":"http://127.0.0.1:9/v1","metadata":"true"}}},
        {"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"auth_set","arguments":{"provider":"zai","key":"short-zai-key","allow_secret_write":True}}},
    ]
    responses = {}
    for request in requests:
        send(request)
        response = read_response()
        if response is None:
            print(f"FAIL:timeout:{request['id']}")
            raise SystemExit(0)
        responses[response.get("id")] = response

    preflight = envelope(responses.get(2, {}))
    string_port = envelope(responses.get(3, {}))
    stats = envelope(responses.get(4, {}))
    status = envelope(responses.get(5, {}))
    stop = envelope(responses.get(6, {}))
    bad_filter = envelope(responses.get(7, {}))
    numeric_provider = envelope(responses.get(8, {}))
    numeric_filter = envelope(responses.get(9, {}))
    string_metadata = envelope(responses.get(10, {}))
    short_zai_key = envelope(responses.get(11, {}))

    checks = []
    checks.append(preflight and preflight.get("ok") is False and preflight.get("error", {}).get("code") == "E001")
    checks.append(string_port and string_port.get("ok") is False and string_port.get("error", {}).get("code") == "E030")
    checks.append(stats and stats.get("ok") is True and stats.get("data", {}).get("requests") == 0 and isinstance(stats.get("data", {}).get("models"), dict))
    checks.append(status and status.get("ok") is True and status.get("data", {}).get("http", {}).get("port") == port)
    checks.append(stop and stop.get("ok") is False and stop.get("error", {}).get("code") == "E010")
    checks.append(bad_filter and bad_filter.get("ok") is False and bad_filter.get("error", {}).get("code") == "E034")
    checks.append(numeric_provider and numeric_provider.get("ok") is False and numeric_provider.get("error", {}).get("code") == "E001")
    checks.append(numeric_filter and numeric_filter.get("ok") is False and numeric_filter.get("error", {}).get("code") == "E034")
    checks.append(string_metadata and string_metadata.get("ok") is False and string_metadata.get("error", {}).get("code") == "E035")
    checks.append(short_zai_key and short_zai_key.get("ok") is False and short_zai_key.get("error", {}).get("code") == "E046")

    if all(checks):
        print("PASS")
    else:
        print("FAIL:" + json.dumps({
            "preflight": preflight,
            "string_port": string_port,
            "stats": stats,
            "status": status,
            "stop": stop,
            "bad_filter": bad_filter,
            "numeric_provider": numeric_provider,
            "numeric_filter": numeric_filter,
            "string_metadata": string_metadata,
            "short_zai_key": short_zai_key,
            "port": port,
        }, sort_keys=True))
finally:
    process.terminate()
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=2)
PY
)"
if [[ "$MCP_CONTRACT_OUTPUT" == "PASS" ]]; then
    pass "MCP rejects bad provider/string port/filter/type inputs, short z.ai keys, and returns structured stats"
else
    fail "MCP validates malformed agent calls" "$MCP_CONTRACT_OUTPUT"
fi

# ===========================================================================
# Summary
# ===========================================================================
TOTAL=$((PASS + FAIL))
echo ""
echo -e "${BOLD}==========================================${RESET}"
echo -e "${BOLD}  Results: $PASS/$TOTAL passed${RESET}"
if [[ "$FAIL" -gt 0 ]]; then
    echo -e "  ${RED}$FAIL test(s) FAILED${RESET}"
fi
echo -e "${BOLD}==========================================${RESET}"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
