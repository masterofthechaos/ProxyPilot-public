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
PROXY_PID=""
AUTH_SECRETS_DIR=""

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
            wait "$PROXY_PID" 2>/dev/null || true
        fi
    fi
    if [[ -n "$AUTH_SECRETS_DIR" && -d "$AUTH_SECRETS_DIR" ]]; then
        rm -rf "$AUTH_SECRETS_DIR"
    fi
    # Also clean up any stale PID file that might be left from a crashed run
    rm -f "$HOME/.config/proxypilot/proxypilot.pid"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Ensure we start clean — remove any stale PID file from prior runs
# ---------------------------------------------------------------------------
rm -f "$HOME/.config/proxypilot/proxypilot.pid"

# Pick a free TCP port for this run.
while lsof -iTCP:"$SMOKE_PORT" -sTCP:LISTEN >/dev/null 2>&1; do
    SMOKE_PORT=$((15000 + RANDOM % 20000))
done

echo ""
echo -e "${BOLD}==========================================${RESET}"
echo -e "${BOLD}  ProxyPilot CLI Smoke Tests${RESET}"
echo -e "${BOLD}  Binary: $BINARY${RESET}"
echo -e "${BOLD}  Port:   $SMOKE_PORT${RESET}"
echo -e "${BOLD}==========================================${RESET}"

# ===========================================================================
# TEST 1 — Build
# ===========================================================================
run_test "Build CLI binary (swift build)"

cd "$PROJECT_DIR"
if env \
    CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-module-cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/swiftpm-module-cache" \
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

# ===========================================================================
# TEST 4 — status --port <smoke-port> --json reports stopped (no server running)
# ===========================================================================
run_test "status --json reports stopped before start"

STATUS_JSON="$("$BINARY" status --port "$SMOKE_PORT" --json 2>&1)"
STOPPED_STATUS="$(python3 -c "
import sys, json
try:
    d = json.loads('$STATUS_JSON')
    print(d.get('data', {}).get('status', 'MISSING'))
except Exception as e:
    print('PARSE_ERROR: ' + str(e))
")"

if [[ "$STOPPED_STATUS" == "stopped" ]]; then
    pass "status reports stopped: $STATUS_JSON"
else
    fail "status reports stopped" "Got status='$STOPPED_STATUS' from: $STATUS_JSON"
fi

# ===========================================================================
# TEST 5 — Start the proxy in the background
# ===========================================================================
run_test "Start proxy on port $SMOKE_PORT"

"$BINARY" start --provider ollama --port "$SMOKE_PORT" --json &
PROXY_PID=$!

# Wait up to 5 seconds for the PID file and port to appear
STARTED=0
for i in $(seq 1 10); do
    sleep 0.5
    if [[ -f "$HOME/.config/proxypilot/proxypilot.pid" ]]; then
        STARTED=1
        break
    fi
done

if [[ "$STARTED" -eq 1 ]]; then
    pass "Proxy started (PID $PROXY_PID, PID file present)"
else
    fail "Proxy started within 5 seconds" "PID file never appeared at ~/.config/proxypilot/proxypilot.pid"
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
RUNNING_STATUS="$(python3 -c "
import sys, json
try:
    d = json.loads('$STATUS2_JSON')
    print(d.get('data', {}).get('status', 'MISSING'))
except Exception as e:
    print('PARSE_ERROR: ' + str(e))
")"

if [[ "$RUNNING_STATUS" == "running" ]]; then
    pass "status reports running: $STATUS2_JSON"
else
    fail "status reports running" "Got status='$RUNNING_STATUS' from: $STATUS2_JSON"
fi

# ===========================================================================
# TEST 8 — status reports running_unmanaged when PID file is missing
# ===========================================================================
run_test "status --port $SMOKE_PORT --json reports running_unmanaged without PID file"

rm -f "$HOME/.config/proxypilot/proxypilot.pid"

STATUS_UNMANAGED_JSON="$("$BINARY" status --port "$SMOKE_PORT" --json 2>&1)"
UNMANAGED_STATUS="$(python3 -c "
import sys, json
try:
    d = json.loads('$STATUS_UNMANAGED_JSON')
    print(d.get('data', {}).get('status', 'MISSING'))
except Exception as e:
    print('PARSE_ERROR: ' + str(e))
")"

if [[ "$UNMANAGED_STATUS" == "running_unmanaged" ]]; then
    pass "status reports running_unmanaged: $STATUS_UNMANAGED_JSON"
else
    fail "status reports running_unmanaged" "Got status='$UNMANAGED_STATUS' from: $STATUS_UNMANAGED_JSON"
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
run_test "Stop the proxy (kill background process)"

if [[ -n "$PROXY_PID" ]]; then
    kill "$PROXY_PID" 2>/dev/null || true
    wait "$PROXY_PID" 2>/dev/null || true
    PROXY_PID=""  # mark as handled so cleanup doesn't double-kill
    sleep 0.5
    pass "kill signal sent to proxy process"
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
FINAL_STATUS="$(python3 -c "
import sys, json
try:
    d = json.loads('$STATUS3_JSON')
    print(d.get('data', {}).get('status', 'MISSING'))
except Exception as e:
    print('PARSE_ERROR: ' + str(e))
")"

if [[ "$FINAL_STATUS" == "stopped" ]]; then
    pass "status reports stopped after proxy kill: $STATUS3_JSON"
else
    fail "status reports stopped after kill" "Got status='$FINAL_STATUS' from: $STATUS3_JSON"
fi

# ===========================================================================
# TEST 13 — auth status --json (all providers)
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
    expected = {"openai", "groq", "zai", "openrouter", "xai", "chutes", "google", "ollama", "lmstudio"}
    if expected.issubset(set(status.keys())) and status.get("ollama") == "not_required" and status.get("lmstudio") == "not_required":
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
# TEST 14 — auth set --provider openai --key <value>
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

# ===========================================================================
# TEST 15 — auth status --provider openai shows stored:true
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
# TEST 16 — auth remove --provider openai --yes
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
# TEST 17 — auth status --provider openai shows stored:false
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
# TEST 18 — auth set rejects local providers (E041)
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

# ===========================================================================
# TEST 19 — auth set rejects empty keys (E040)
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
