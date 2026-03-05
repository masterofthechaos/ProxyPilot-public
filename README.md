# ProxyPilot

macOS utility that makes Xcode Intelligence and Agent Mode work with non-native LLM providers via a local OpenAI-compatible proxy.

## What It Does

Xcode's built-in Intelligence features only support a handful of providers natively. ProxyPilot runs a local proxy on your Mac that translates requests, letting you use **any OpenAI-compatible provider** (or Anthropic's API) with Xcode Intelligence and Agent Mode.

## Prerequisites

- macOS 15+
- Xcode with Intelligence enabled

## Build from Source

> **First-time setup:** Before building, read **[BUILDING.md](BUILDING.md)** to configure bundle identifiers and optional integrations (Sparkle, PostHog). The project ships with placeholder values that you'll need to replace.

ProxyPilot uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate its Xcode project.

```bash
# Install XcodeGen if you don't have it
brew install xcodegen

# Generate Xcode project
zsh scripts/update_xcodeproj.sh

# Open in Xcode
open ProxyPilot.xcodeproj
```

Build and run the `ProxyPilot-macOS` scheme.

### Build + Install (Optional)

Build a Release app bundle and install to `/Applications/ProxyPilot.app`:

```bash
zsh scripts/build_and_install.sh
```

### CLI

ProxyPilot also ships a CLI for headless/agent workflows:

```bash
cd ProxyPilotCLI
swift build -c release

# One-command Xcode Agent setup
.build/release/proxypilot setup xcode
```

See `ProxyPilotCLI/README.md` for full CLI documentation.

## Xcode Setup

1. In ProxyPilot, set your upstream provider and API key, then click **Start**
2. In Xcode -> Settings -> Intelligence -> Add a Model Provider:
   - Choose **Locally Hosted**
   - Port: `4000`
   - Description: any label (e.g. `ProxyPilot`)

Xcode validates by calling `GET /v1/models` on the local proxy.

## Features

- **Menu bar mode** -- persistent status icon, Start/Stop proxy, Open Settings, Quit
- **First-run onboarding + preflight** -- guided setup checks with one-click fix actions
- **Diagnostics bundle export** -- redacted logs + environment manifest + copyable support summary
- **Watchdog auto-recovery** -- detects unexpected stops and retries startup with backoff
- **Auto-start on login** -- register via SMAppService (toggle in Settings)
- **SSE streaming** -- full `stream: true` support for `/v1/chat/completions`
- **Multi-provider** -- 9 upstream providers including direct Google Gemini support
- **Anthropic API translation** -- `POST /v1/messages` translated to OpenAI format, supports both buffered and streaming responses
- **Xcode Agent config** -- one-click install for Claude Agent in Xcode routing through ProxyPilot
- **Safety limits** -- request/concurrency caps with explicit `413`/`429` responses

## Supported Providers

| Provider | Type | API Key Required |
|----------|------|-----------------|
| z.ai | Cloud | Yes |
| OpenRouter | Cloud | Yes |
| OpenAI | Cloud | Yes |
| Google (Gemini) | Cloud | Yes |
| xAI | Cloud | Yes |
| Chutes | Cloud | Yes |
| Groq | Cloud | Yes |
| Ollama | Local | No |
| LM Studio | Local | No |

## Supported Routes

| Method | Path | Format | Description |
|--------|------|--------|-------------|
| GET | `/v1/models` | OpenAI | Model list (always unauthenticated) |
| POST | `/v1/chat/completions` | OpenAI | Chat completions (buffered + streaming) |
| POST | `/v1/messages` | Anthropic | Translated to OpenAI upstream (buffered + streaming) |

## Architecture

```
ProxyPilot/              # macOS SwiftUI app
ProxyPilotCore/          # Cross-platform Swift package (shared proxy engine)
ProxyPilotCLI/           # CLI + MCP server
ProxyPilotTests/         # GUI test suite
```

### ProxyPilotCore

Shared library used by both the GUI app and CLI:

- **ProxyEngine** -- SwiftNIO-based cross-platform proxy server
- **Translation** -- Anthropic-to-OpenAI request/response translation
- **Models** -- Upstream model metadata, provider definitions, model discovery
- **Secrets** -- SecretsProvider protocol with Keychain (macOS) and file-based implementations
- **HTTPParsing** -- Request parsing, auth validation, model filtering

### GUI App

SwiftUI menu bar app with:
- `LocalProxyServer` using Network framework (`NWListener`)
- Sparkle for auto-updates
- Keychain-backed API key storage
- Per-provider configurable default models

### CLI

ArgumentParser-based CLI with MCP server mode:
- `proxypilot start`, `stop`, `status`, `models`, `logs`
- `proxypilot setup xcode` -- one-command Xcode Agent routing
- `proxypilot serve --mcp` -- MCP server for AI agent integration

## License

This project is licensed under the **GNU Affero General Public License v3.0** (AGPL-3.0).

This means you are free to use, modify, and distribute this software, including over a network, as long as you:

1. Make your source code available under the same license
2. Include the original copyright and license notice
3. State any changes you made

See [LICENSE](LICENSE) for the full text.

## Contributing

Contributions are welcome! Please open an issue or pull request.

When contributing, please note:
- Run `zsh scripts/update_xcodeproj.sh` after adding or removing Swift files
- The project targets macOS 15+ with Swift 6
- ProxyPilotCore has its own test suite: `cd ProxyPilotCore && swift test`
