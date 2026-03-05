# ProxyPilot CLI

Local AI proxy server for Xcode and agentic coding. Single binary, zero dependencies.

---

## Install

### Install Script

```sh
curl -fsSL https://micah.chat/downloads/proxypilot-cli-install.sh | bash
```

### Build from source

Requires Swift 6 and macOS 15+.

```sh
swift build -c release
cp .build/release/proxypilot /usr/local/bin/proxypilot
```

### Homebrew

```sh
brew install proxypilot   # coming soon
```

### GitHub Releases

Prebuilt binary available at the GitHub Releases page. Download, make executable, and move to your PATH.

```sh
# coming soon
```

---

## Quick Start

```sh
printf '%s\n' "$ZAI_API_KEY" | proxypilot setup xcode --provider zai --model glm-4.7 --key-stdin
curl http://127.0.0.1:4000/v1/models
proxypilot status --port 4000
```

Manual / advanced flow:

```sh
proxypilot auth set --provider zai --key "$ZAI_API_KEY"
proxypilot start --provider zai --model glm-4.7
proxypilot config install --port 4000
```

---

## Commands

### `setup`

Guided setup workflows. `setup xcode` stores the API key when provided, starts the daemon if needed, installs Xcode Agent routing, and verifies the local `/v1/models` endpoint.

```
proxypilot setup xcode [--port <port>] [--provider <provider>] [--upstream-url <upstream-url>] [--key <key>] [--key-stdin] [--model <model>] [--json]
```

| Flag | Default | Description |
|---|---|---|
| `--port`, `-p` | `4000` | Port to listen on / route Xcode to |
| `--provider` | `zai` | Upstream provider |
| `--upstream-url` | provider default | Override upstream API base URL |
| `--key` | — | Upstream API key value |
| `--key-stdin` | false | Read one API key line from stdin |
| `--model` | `glm-4.7` for `zai` | Preferred upstream model |
| `--json` | false | Emit JSON output |

---

### `start`

Start the proxy server. The process stays in the foreground and writes a PID file so `stop` and `status` can find it. Use `--daemon` to background it.

```
proxypilot start [--port <port>] [--provider <provider>] [--upstream-url <url>] [--key <key>] [--key-stdin] [--model <model[,model...]>] [--daemon] [--json]
```

| Flag | Default | Description |
|---|---|---|
| `--port`, `-p` | `4000` | Port to listen on |
| `--provider` | `openai` | Upstream provider. Valid: `openai`, `groq`, `zai`, `openrouter`, `xai`, `chutes`, `google`, `ollama`, `lmstudio` |
| `--upstream-url` | provider default | Override upstream API base URL |
| `--key` | — | Upstream API key. Falls back to environment variable, then keychain/secrets store |
| `--key-stdin` | false | Read one API key line from stdin |
| `--model` | — | Preferred upstream model(s), comma-separated |
| `--daemon` | false | Run in background and write PID file |
| `--json` | false | Emit JSON output instead of human-readable text |

Key resolution order: `--key` flag > environment variable > keychain (macOS) / `secrets.json` (Linux).

Environment variable names: `OPENAI_API_KEY`, `GROQ_API_KEY`, `ZAI_API_KEY`, `OPENROUTER_API_KEY`, `XAI_API_KEY`, `CHUTES_API_KEY`, `GOOGLE_API_KEY`.

---

### `stop`

Stop the running proxy server. Sends SIGTERM and waits up to 3 seconds for a clean exit; falls back to SIGKILL if the process does not exit. If the proxy is responding but the PID file is missing, `stop` reports that the instance is running unmanaged instead of incorrectly saying nothing is running.

```
proxypilot stop [--port <port>] [--json]
```

| Flag | Default | Description |
|---|---|---|
| `--port`, `-p` | `4000` | Port to probe when PID state is unavailable |
| `--json` | false | Emit JSON output |

---

### `status`

Check whether the proxy is running. Reads the PID file and probes `GET /v1/models` on the configured port. If the port responds but no PID file is present, status is reported as `running_unmanaged`.

```
proxypilot status [--port <port>] [--json]
```

| Flag | Default | Description |
|---|---|---|
| `--port`, `-p` | `4000` | Port to probe for health check |
| `--json` | false | Emit JSON output |

---

### `config install`

Install Xcode Agent config that routes Xcode through ProxyPilot (`ANTHROPIC_BASE_URL=http://127.0.0.1:<port>`).

```
proxypilot config install [--port <port>] [--json]
```

| Flag | Default | Description |
|---|---|---|
| `--port`, `-p` | `4000` | Port to route Xcode requests to |
| `--json` | false | Emit JSON output |

---

### `config remove`

Remove ProxyPilot's Xcode Agent config and restore direct Xcode routing.

```
proxypilot config remove [--json]
```

| Flag | Default | Description |
|---|---|---|
| `--json` | false | Emit JSON output |

---

### `config status`

Show whether ProxyPilot Xcode Agent config is installed, plus `settings.json` and defaults override state.

```
proxypilot config status [--json]
```

| Flag | Default | Description |
|---|---|---|
| `--json` | false | Emit JSON output |

---

### `auth set`

Store an API key for a cloud provider.

```
proxypilot auth set --provider <provider> [--key <value>] [--stdin] [--json]
```

| Flag | Default | Description |
|---|---|---|
| `--provider` | — | Required provider. Cloud only: `openai`, `groq`, `zai`, `openrouter`, `xai`, `chutes`, `google` |
| `--key` | — | Non-interactive key value (highest priority) |
| `--stdin` | false | Read one key line from stdin |
| `--json` | false | Emit JSON output |

If neither `--key` nor `--stdin` is passed, `auth set` prompts securely in a TTY.  
Local providers (`ollama`, `lmstudio`) are rejected with `E041`.

---

### `auth status`

Show whether keys are stored (presence only, never key values).

```
proxypilot auth status [--provider <provider>] [--json]
```

| Flag | Default | Description |
|---|---|---|
| `--provider` | all | Optional provider filter |
| `--json` | false | Emit JSON output |

Without `--provider`, all providers are listed and local providers are marked `not_required`.

---

### `auth remove`

Delete a stored provider key.

```
proxypilot auth remove --provider <provider> [--yes] [--json]
```

| Flag | Default | Description |
|---|---|---|
| `--provider` | — | Required provider |
| `--yes` | false | Skip confirmation prompt |
| `--json` | false | Emit JSON output |

---

### `launch`

Launch Xcode from the CLI (macOS only).

```
proxypilot launch [--xcode <path-or-name>] [--json]
```

| Flag | Default | Description |
|---|---|---|
| `--xcode` | `/Applications/Xcode.app` | Xcode app path or app name |
| `--json` | false | Emit JSON output |

---

### `models`

List available models from an upstream provider.

```
proxypilot models [--provider <provider>] [--url <base-url>] [--key <key>] [--filter <exacto|verified>] [--json]
```

| Flag | Default | Description |
|---|---|---|
| `--provider` | `openai` | Upstream provider |
| `--url` | provider default | Override upstream API base URL |
| `--key` | — | Upstream API key |
| `--filter` | — | Optional filter (`exacto`, `verified`) |
| `--json` | false | Emit JSON output |

---

### `logs`

Show recent proxy logs (with secret redaction).

```
proxypilot logs [--lines <n>] [--follow] [--json]
```

| Flag | Default | Description |
|---|---|---|
| `--lines`, `-l` | `75` | Number of lines to show |
| `--follow`, `-f` | false | Follow log output live |
| `--json` | false | Emit JSON output |

---

### `update`

First-class CLI update command. Downloads the latest binary and replaces the installed executable in-place.

```
proxypilot update [--check] [--version <x.y.z>] [--install-path <path>] [--no-prune] [--json]
```

| Flag | Default | Description |
|---|---|---|
| `--check` | false | Check for updates only (no install) |
| `--version` | latest | Install a specific version |
| `--install-path` | current binary path | Override install target path |
| `--no-prune` | false | Keep legacy `proxypilot-v*` binaries in install dir |
| `--json` | false | Emit JSON output |

If the target directory is not writable, run with `sudo` or choose a writable `--install-path`.

---

### `serve`

Run the proxy server in the foreground (default), or launch an MCP server over stdio (`--mcp`). In MCP mode, the proxy runs in-process; stdout is reserved for JSON-RPC and all diagnostics go to stderr.

```
proxypilot serve [--port <port>] [--provider <provider>] [--upstream-url <upstream-url>] [--key <key>] [--mcp] [--json]
```

| Flag | Default | Description |
|---|---|---|
| `--port`, `-p` | `4000` | Port to listen on |
| `--provider` | `openai` | Upstream provider |
| `--upstream-url` | provider default | Override upstream API base URL |
| `--key` | — | Upstream API key |
| `--mcp` | false | Run as MCP server over stdio instead of HTTP proxy |
| `--json` | false | Emit JSON output (ignored in MCP mode) |

MCP mode exposes 9 tools:
`proxy_start`, `proxy_stop`, `proxy_restart`, `proxy_status`,
`xcode_config_install`, `xcode_config_remove`, `list_upstream_models`,
`get_session_stats`, `proxy_logs`.

---

## MCP Configuration

Add to your MCP host config (Claude Code, Cursor, or any MCP-compatible client):

```json
{
  "mcpServers": {
    "proxypilot": {
      "command": "proxypilot",
      "args": ["serve", "--mcp"]
    }
  }
}
```

The server inherits `--provider` and `--key` defaults but tools can override both at call time.

---

## Providers

| Provider | Raw value | Base URL |
|---|---|---|
| OpenAI | `openai` | `https://api.openai.com/v1` |
| Groq | `groq` | `https://api.groq.com/openai/v1` |
| z.ai | `zai` | `https://api.z.ai/api/coding/paas/v4` |
| OpenRouter | `openrouter` | `https://openrouter.ai/api/v1` |
| xAI (Grok) | `xai` | `https://api.x.ai/v1` |
| Chutes | `chutes` | `https://llm.chutes.ai/v1` |
| Google (Gemini) | `google` | `https://generativelanguage.googleapis.com/v1beta/openai` |
| Ollama | `ollama` | `http://localhost:11434/v1` |
| LM Studio | `lmstudio` | `http://localhost:1234/v1` |

---

## API Endpoints

The proxy listens on `http://127.0.0.1:<port>` and exposes:

| Method | Path | Description |
|---|---|---|
| `GET` | `/v1/models` | Returns the provider model list in OpenAI format. Auth is skipped for this endpoint for Xcode compatibility. |
| `POST` | `/v1/chat/completions` | OpenAI chat completions. Forwarded verbatim to the upstream provider. Streaming (`"stream": true`) is supported. |
| `POST` | `/v1/messages` | Anthropic Messages API. Request is translated to OpenAI format, forwarded upstream, and the response is translated back to Anthropic format. Streaming is supported. |

Both `/v1/models` and `/models` (without the prefix) are accepted, as are `/v1/chat/completions` and `/chat/completions`.

---

## Configuration

### PID file

Written on `start` and `serve`, removed on clean exit.

```
~/.config/proxypilot/proxypilot.pid
```

Respects `$XDG_CONFIG_HOME` if set.

### Secrets

**macOS:** stored in Keychain under service name `proxypilot`, with automatic fallback to the same file-backed store used on Linux when Keychain is unavailable.

**Linux:** stored as JSON at:

```
~/.config/proxypilot/secrets.json
```

Respects `$XDG_CONFIG_HOME` if set. Format is a flat JSON object:

```json
{
  "OPENAI_API_KEY": "sk-...",
  "GROQ_API_KEY": "gsk_..."
}
```

Keys: `OPENAI_API_KEY`, `GROQ_API_KEY`, `ZAI_API_KEY`, `OPENROUTER_API_KEY`, `XAI_API_KEY`, `CHUTES_API_KEY`, `GOOGLE_API_KEY`.

Overrides:

- `PROXYPILOT_SECRETS_DIR` forces file backend (all platforms) and writes `secrets.json` in that directory.
- `PROXYPILOT_KEYCHAIN_SERVICE` overrides the Keychain service name on macOS when file override is not set.

---

## JSON Output

Pass `--json` to any command to get machine-readable output on stdout.

**Success:**

```json
{"ok": true, "data": {"status": "running", "port": "4000", "provider": "openai", "pid": "12345"}}
```

**Error:**

```json
{"ok": false, "error": {"code": "E001", "message": "Unknown provider: foo", "suggestion": "Valid: openai, groq, zai, openrouter, xai, chutes, google, ollama, lmstudio"}}
```

Error codes:

| Code | Trigger |
|---|---|
| `E001` | Unknown provider |
| `E002` | Server already running |
| `E003` | Failed to bind port |
| `E004` | Missing API key for selected provider |
| `E006` | Daemon spawn failed |
| `E010` | No running instance found (stop) |
| `E011` | SIGTERM delivery failed |
| `E012` | Daemon process exited during startup |
| `E013` | Proxy is live but running unmanaged (no PID file) |
| `E030` | Invalid port for `config install` |
| `E031` | Failed to install Xcode config |
| `E032` | Failed to remove Xcode config |
| `E033` | Failed to launch Xcode |
| `E034` | Command is macOS-only |
| `E020`-`E027` | Update command fetch/install/permission errors |

In `--json` mode, human-readable errors that would normally go to stderr are written to stdout instead, wrapped in the `{"ok": false, ...}` envelope.
