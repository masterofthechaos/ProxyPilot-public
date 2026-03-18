import Foundation
import MCP
import ProxyPilotCore

/// MCP server implementation for ProxyPilot.
/// Exposes proxy_start, proxy_stop, proxy_restart, proxy_status as MCP tools over stdio.
///
/// All logging MUST go to stderr — stdout is reserved for JSON-RPC.
enum MCPServerSetup {

    /// Shared mutable state for the in-process proxy server.
    private actor ProxyState {
        var server: NIOProxyServer?
        var config: ProxyConfiguration?
        var boundPort: UInt16?
        let sessionStats = SessionStats()

        func isRunning() -> Bool { server != nil }
        func currentPort() -> UInt16? { boundPort }
        func currentProvider() -> String? { config?.upstreamProvider.rawValue }
        func currentModel() -> String? {
            let m = config?.preferredAnthropicUpstreamModel ?? ""
            return m.isEmpty ? nil : m
        }

        func start(config: ProxyConfiguration) async throws -> UInt16 {
            if server != nil {
                throw ProxyEngineError.alreadyRunning
            }
            let s = NIOProxyServer()
            let port = try await s.start(config: config)
            self.server = s
            self.config = config
            self.boundPort = port
            return port
        }

        func stop() async throws {
            guard let s = server else {
                throw ProxyEngineError.notRunning
            }
            try await s.stop()
            server = nil
            config = nil
            boundPort = nil
        }
    }

    // MARK: - JSON Schema helpers (Value-based)

    /// Build a JSON Schema object with properties, as a Value.
    private static func jsonSchemaObject(properties: [String: Value]) -> Value {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
        ])
    }

    /// An empty JSON Schema object.
    private static var emptySchema: Value {
        .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    }

    /// A JSON Schema string property with a description.
    private static func stringProp(_ desc: String) -> Value {
        .object(["type": .string("string"), "description": .string(desc)])
    }

    /// A JSON Schema integer property with a description.
    private static func intProp(_ desc: String) -> Value {
        .object(["type": .string("integer"), "description": .string(desc)])
    }

    static func run(port: UInt16, provider: String, key: String?, upstreamURL: String? = nil) async throws {
        let state = ProxyState()

        let server = Server(
            name: "proxypilot",
            version: "1.4.9",
            title: "ProxyPilot",
            instructions: """
            ProxyPilot routes Xcode Agent Mode requests through alternative AI providers.

            Typical workflow:
            1. list_upstream_models — discover available models (optional)
            2. proxy_start — start the local proxy (required first)
            3. xcode_config_install — point Xcode at the proxy (required second)
            4. Tell the user to quit and relaunch Xcode

            To tear down: xcode_config_remove, then proxy_stop.
            proxy_status, get_session_stats, and proxy_logs are safe to call at any time.
            """,
            capabilities: .init(tools: .init(listChanged: false))
        )

        // Register tool listing
        await server.withMethodHandler(ListTools.self) { _ in
            return .init(tools: [
                Tool(
                    name: "proxy_start",
                    title: "Start Proxy",
                    description: "Start the ProxyPilot local AI proxy server on a specified port with an upstream provider and model.",
                    inputSchema: jsonSchemaObject(properties: [
                        "port": intProp("Port to listen on (default 4000, range 1024-65535)"),
                        "provider": stringProp("Upstream provider: openai, groq, zai, openrouter, xai, chutes, google, deepseek, mistral, minimax, ollama, lmstudio"),
                        "model": stringProp("Upstream model(s) to route requests to, comma-separated (e.g. 'gpt-4o,claude-3-opus'). First model is preferred for Anthropic translation. If omitted, all models are allowed."),
                        "key": stringProp("Upstream API key (optional, falls back to secrets store)"),
                        "url": stringProp("Upstream API base URL override (e.g. http://localhost:11434/v1)"),
                    ]),
                    annotations: .init(
                        readOnlyHint: false,
                        destructiveHint: false,
                        idempotentHint: false,
                        openWorldHint: true
                    )
                ),
                Tool(
                    name: "proxy_stop",
                    title: "Stop Proxy",
                    description: "Stop the running ProxyPilot proxy server.",
                    inputSchema: emptySchema,
                    annotations: .init(
                        readOnlyHint: false,
                        destructiveHint: true,
                        idempotentHint: true,
                        openWorldHint: false
                    )
                ),
                Tool(
                    name: "proxy_restart",
                    title: "Restart Proxy",
                    description: "Restart the ProxyPilot proxy server with the same or new configuration.",
                    inputSchema: jsonSchemaObject(properties: [
                        "port": intProp("Port to listen on (range 1024-65535)"),
                        "provider": stringProp("Upstream provider: openai, groq, zai, openrouter, xai, chutes, google, deepseek, mistral, minimax, ollama, lmstudio"),
                        "model": stringProp("Upstream model(s) to route requests to, comma-separated (e.g. 'gpt-4o,claude-3-opus'). First model is preferred for Anthropic translation."),
                        "key": stringProp("Upstream API key"),
                        "url": stringProp("Upstream API base URL override (e.g. http://localhost:11434/v1)"),
                    ]),
                    annotations: .init(
                        readOnlyHint: false,
                        destructiveHint: false,
                        idempotentHint: false,
                        openWorldHint: true
                    )
                ),
                Tool(
                    name: "proxy_status",
                    title: "Check Proxy Status",
                    description: "Check whether the ProxyPilot proxy server is running, and on which port/provider/model.",
                    inputSchema: emptySchema,
                    annotations: .init(
                        readOnlyHint: true,
                        destructiveHint: false,
                        idempotentHint: true,
                        openWorldHint: false
                    )
                ),
                Tool(
                    name: "xcode_config_install",
                    title: "Install Xcode Config",
                    description: "Write Xcode Agent Mode configuration so Xcode routes requests through ProxyPilot. Writes settings.json and sets the API key override. Call this after proxy_start.",
                    inputSchema: jsonSchemaObject(properties: [
                        "port": intProp("ProxyPilot port to point Xcode at (default 4000, range 1024-65535)"),
                    ]),
                    annotations: .init(
                        readOnlyHint: false,
                        destructiveHint: false,
                        idempotentHint: true,
                        openWorldHint: false
                    )
                ),
                Tool(
                    name: "xcode_config_remove",
                    title: "Remove Xcode Config",
                    description: "Remove Xcode Agent Mode configuration, restoring Xcode to use Anthropic's servers directly.",
                    inputSchema: emptySchema,
                    annotations: .init(
                        readOnlyHint: false,
                        destructiveHint: true,
                        idempotentHint: true,
                        openWorldHint: false
                    )
                ),
                Tool(
                    name: "list_upstream_models",
                    title: "List Upstream Models",
                    description: "Fetch available models from an upstream provider's /v1/models endpoint.",
                    inputSchema: jsonSchemaObject(properties: [
                        "provider": stringProp("Upstream provider (default: current proxy provider). Options: openai, groq, zai, openrouter, xai, chutes, google, deepseek, mistral, minimax, ollama, lmstudio"),
                        "key": stringProp("API key (optional, falls back to secrets store)"),
                        "url": stringProp("Override base URL"),
                        "filter": stringProp("Filter: 'exacto' for OpenRouter :exacto models, 'verified' for ProxyPilot Verified models"),
                    ]),
                    annotations: .init(
                        readOnlyHint: true,
                        destructiveHint: false,
                        idempotentHint: true,
                        openWorldHint: true
                    )
                ),
                Tool(
                    name: "get_session_stats",
                    title: "Get Session Statistics",
                    description: "Get request count, token usage, model distribution, and average latency for the current proxy session.",
                    inputSchema: emptySchema,
                    annotations: .init(
                        readOnlyHint: true,
                        destructiveHint: false,
                        idempotentHint: true,
                        openWorldHint: false
                    )
                ),
                Tool(
                    name: "proxy_logs",
                    title: "Read Proxy Logs",
                    description: "Read recent proxy log lines with secrets redacted.",
                    inputSchema: jsonSchemaObject(properties: [
                        "lines": intProp("Number of lines to return (default 75)"),
                    ]),
                    annotations: .init(
                        readOnlyHint: true,
                        destructiveHint: false,
                        idempotentHint: true,
                        openWorldHint: false
                    )
                ),
            ])
        }

        // Register tool handler
        await server.withMethodHandler(CallTool.self) { params in
            switch params.name {

            case "proxy_start":
                let reqPort = (params.arguments?["port"]?.intValue).flatMap { UInt16($0) } ?? port
                guard reqPort == 0 || (reqPort >= 1024 && reqPort <= 65535) else {
                    return .init(content: [.text("Invalid port \(reqPort). Use 1024-65535, or 0 for auto-assign.")], isError: true)
                }
                let reqProvider = params.arguments?["provider"]?.stringValue ?? provider
                let reqKey = params.arguments?["key"]?.stringValue ?? key
                let reqURL = params.arguments?["url"]?.stringValue ?? upstreamURL
                let reqModel = params.arguments?["model"]?.stringValue

                guard let upstream = UpstreamProvider(rawValue: reqProvider) else {
                    return .init(content: [.text("Unknown provider: \(reqProvider). Valid providers: \(UpstreamProvider.allCases.map(\.rawValue).joined(separator: ", ")).")], isError: true)
                }

                let secrets = SecretsProviderFactory.make()
                let secretKeyName = secretKeyForProvider(upstream)
                let apiKey: String? = if let reqKey {
                    reqKey
                } else if let secretKeyName {
                    ProcessInfo.processInfo.environment[secretKeyName]
                        ?? (try? secrets.get(key: secretKeyName))
                } else {
                    nil
                }

                // Allow nil API key for local providers or localhost URLs
                let effectiveBaseURL = reqURL ?? upstream.defaultAPIBaseURL
                if apiKey == nil && !upstream.isLocal && !isLocalhostURL(effectiveBaseURL) {
                    return .init(content: [.text("No API key found for provider \(upstream.rawValue). Pass a 'key' parameter, set the provider env var, or store it in the secrets store.")], isError: true)
                }

                let modelList = reqModel?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
                let allowedModels: Set<String> = modelList.isEmpty ? [] : Set(modelList)
                let config = ProxyConfiguration(
                    port: reqPort,
                    upstreamProvider: upstream,
                    upstreamAPIBaseURL: reqURL,
                    upstreamAPIKey: apiKey,
                    allowedModels: allowedModels,
                    preferredAnthropicUpstreamModel: modelList.first ?? "",
                    sessionStats: state.sessionStats,
                    googleThoughtSignatureStore: upstream == .google ? GoogleThoughtSignatureStore() : nil
                )

                do {
                    let boundPort = try await state.start(config: config)
                    let modelInfo = reqModel.map { " [\($0)]" } ?? ""
                    return .init(content: [.text("ProxyPilot started on port \(boundPort) -> \(upstream.title)\(modelInfo).\nXcode is NOT yet configured. Call xcode_config_install (port: \(boundPort)) to route Xcode through ProxyPilot.")])
                } catch ProxyEngineError.alreadyRunning {
                    let p = await state.currentPort() ?? 0
                    let prov = await state.currentProvider() ?? "unknown"
                    let m = await state.currentModel().map { " [\($0)]" } ?? ""
                    return .init(content: [.text("ProxyPilot is already running on port \(p) -> \(prov)\(m). To change configuration, call proxy_restart with new parameters.")], isError: true)
                } catch {
                    return .init(content: [.text("Failed to start: \(error). Check if port \(reqPort) is already in use.")], isError: true)
                }

            case "proxy_stop":
                do {
                    try await state.stop()
                    return .init(content: [.text("ProxyPilot stopped. Xcode config is still installed — call xcode_config_remove if you want to restore direct Anthropic routing.")])
                } catch ProxyEngineError.notRunning {
                    return .init(content: [.text("ProxyPilot is not running. Nothing to stop.")], isError: true)
                } catch {
                    return .init(content: [.text("Failed to stop: \(error)")], isError: true)
                }

            case "proxy_restart":
                // Stop if running (ignore error if not running)
                try? await state.stop()

                let reqPort = (params.arguments?["port"]?.intValue).flatMap { UInt16($0) } ?? port
                guard reqPort == 0 || (reqPort >= 1024 && reqPort <= 65535) else {
                    return .init(content: [.text("Invalid port \(reqPort). Use 1024-65535, or 0 for auto-assign.")], isError: true)
                }
                let reqProvider = params.arguments?["provider"]?.stringValue ?? provider
                let reqKey = params.arguments?["key"]?.stringValue ?? key
                let reqURL = params.arguments?["url"]?.stringValue ?? upstreamURL
                let reqModel = params.arguments?["model"]?.stringValue

                guard let upstream = UpstreamProvider(rawValue: reqProvider) else {
                    return .init(content: [.text("Unknown provider: \(reqProvider). Valid providers: \(UpstreamProvider.allCases.map(\.rawValue).joined(separator: ", ")).")], isError: true)
                }

                let secrets = SecretsProviderFactory.make()
                let secretKeyName = secretKeyForProvider(upstream)
                let apiKey: String? = if let reqKey {
                    reqKey
                } else if let secretKeyName {
                    ProcessInfo.processInfo.environment[secretKeyName]
                        ?? (try? secrets.get(key: secretKeyName))
                } else {
                    nil
                }

                // Allow nil API key for local providers or localhost URLs
                let effectiveBaseURL = reqURL ?? upstream.defaultAPIBaseURL
                if apiKey == nil && !upstream.isLocal && !isLocalhostURL(effectiveBaseURL) {
                    return .init(content: [.text("No API key found for provider \(upstream.rawValue). Pass a 'key' parameter, set the provider env var, or store it in the secrets store.")], isError: true)
                }

                let modelList = reqModel?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
                let allowedModels: Set<String> = modelList.isEmpty ? [] : Set(modelList)
                let config = ProxyConfiguration(
                    port: reqPort,
                    upstreamProvider: upstream,
                    upstreamAPIBaseURL: reqURL,
                    upstreamAPIKey: apiKey,
                    allowedModels: allowedModels,
                    preferredAnthropicUpstreamModel: modelList.first ?? "",
                    sessionStats: state.sessionStats,
                    googleThoughtSignatureStore: upstream == .google ? GoogleThoughtSignatureStore() : nil
                )

                do {
                    let boundPort = try await state.start(config: config)
                    let modelInfo = reqModel.map { " [\($0)]" } ?? ""
                    return .init(content: [.text("ProxyPilot restarted on port \(boundPort) -> \(upstream.title)\(modelInfo).\nCall xcode_config_install (port: \(boundPort)) to update Xcode routing.")])
                } catch {
                    return .init(content: [.text("Failed to restart: \(error). Check if port \(reqPort) is already in use.")], isError: true)
                }

            case "proxy_status":
                let running = await state.isRunning()
                let p = await state.currentPort() ?? port
                var parts: [String] = []

                if running {
                    let prov = await state.currentProvider() ?? "unknown"
                    let modelInfo = await state.currentModel().map { " [\($0)]" } ?? ""
                    parts.append("ProxyPilot is running on port \(p) -> \(prov)\(modelInfo).")
                } else {
                    parts.append("ProxyPilot is not running (in-process).")
                }

                // HTTP health probe
                do {
                    let probeURL = URL(string: "http://127.0.0.1:\(p)/v1/models")!
                    let (data, response) = try await URLSession.shared.data(from: probeURL)
                    if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let models = parsed["data"] as? [[String: Any]] {
                            parts.append("Health check: OK (\(models.count) models)")
                        } else {
                            parts.append("Health check: OK")
                        }
                    }
                } catch {
                    if !running {
                        parts.append("Health check: no response on port \(p)")
                    }
                }

                return .init(content: [.text(parts.joined(separator: "\n"))])

            case "xcode_config_install":
                let configPort = (params.arguments?["port"]?.intValue).flatMap { UInt16($0) } ?? port
                guard configPort >= 1024 else {
                    return .init(content: [.text("Invalid port \(configPort) for Xcode config. Use 1024-65535.")], isError: true)
                }
                // Warn if proxy is running on a different port
                let proxyRunning = await state.isRunning()
                let proxyPort = await state.currentPort()
                var warning = ""
                if !proxyRunning {
                    warning = "\nWARNING: No ProxyPilot proxy is currently running. Start one with proxy_start before Xcode tries to connect."
                } else if let rp = proxyPort, rp != configPort {
                    warning = "\nWARNING: Proxy is running on port \(rp) but config points at port \(configPort). Consider using port \(rp) instead."
                }

                let home = FileManager.default.homeDirectoryForCurrentUser
                let configDir = home.appendingPathComponent(
                    "Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig",
                    isDirectory: true
                )
                do {
                    try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
                    let settingsContent = """
                    {
                      "env": {
                        "ANTHROPIC_AUTH_TOKEN": "proxypilot",
                        "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(configPort)"
                      }
                    }
                    """
                    let settingsFile = configDir.appendingPathComponent("settings.json")
                    try settingsContent.write(to: settingsFile, atomically: true, encoding: .utf8)

                    // Set Xcode defaults to bypass Anthropic login
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
                    process.arguments = ["write", "com.apple.dt.Xcode", "IDEChatClaudeAgentAPIKeyOverride", " "]
                    try process.run()
                    process.waitUntilExit()

                    return .init(content: [.text("Xcode config installed. Routing: 127.0.0.1:\(configPort).\(warning)\nIf Xcode is open, the user MUST quit and relaunch Xcode for changes to take effect.")])
                } catch {
                    return .init(content: [.text("Failed to write Xcode config: \(error). Check that ~/Library/Developer/Xcode/CodingAssistant/ is writable.")], isError: true)
                }

            case "xcode_config_remove":
                let home = FileManager.default.homeDirectoryForCurrentUser
                let settingsFile = home.appendingPathComponent(
                    "Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/settings.json"
                )
                let existed = FileManager.default.fileExists(atPath: settingsFile.path)
                do {
                    if existed {
                        try FileManager.default.removeItem(at: settingsFile)
                    }

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
                    process.arguments = ["delete", "com.apple.dt.Xcode", "IDEChatClaudeAgentAPIKeyOverride"]
                    try process.run()
                    // defaults delete exits non-zero if key absent; that's fine — desired state achieved
                    process.waitUntilExit()

                    if existed {
                        return .init(content: [.text("Xcode config removed. Xcode will route to Anthropic directly.\nIf Xcode is open, the user MUST quit and relaunch Xcode for changes to take effect.")])
                    } else {
                        return .init(content: [.text("Xcode config was not installed (settings.json not found). No action taken.")])
                    }
                } catch {
                    return .init(content: [.text("Failed to remove Xcode config: \(error)")], isError: true)
                }

            case "list_upstream_models":
                let reqProvider = params.arguments?["provider"]?.stringValue ?? provider
                let reqKey = params.arguments?["key"]?.stringValue ?? key
                let reqURL = params.arguments?["url"]?.stringValue
                let reqFilter = params.arguments?["filter"]?.stringValue

                guard let upstream = UpstreamProvider(rawValue: reqProvider) else {
                    return .init(content: [.text("Unknown provider: \(reqProvider)")], isError: true)
                }

                let secrets = SecretsProviderFactory.make()
                let secretKeyName = secretKeyForProvider(upstream)
                let apiKey: String? = if let reqKey {
                    reqKey
                } else if let secretKeyName {
                    ProcessInfo.processInfo.environment[secretKeyName]
                        ?? (try? secrets.get(key: secretKeyName))
                } else {
                    nil
                }

                let baseURL = reqURL ?? upstream.defaultAPIBaseURL

                do {
                    var models = try await ModelDiscovery.fetchModels(
                        provider: upstream,
                        baseURL: baseURL,
                        apiKey: apiKey
                    )

                    if reqFilter == "exacto" {
                        models = ModelDiscovery.filterExacto(models)
                    } else if reqFilter == "verified" {
                        let verifiedURL = URL(string: "https://micah.chat/proxypilot/verified-models.json")!
                        let entries = await VerifiedModels.fetchRemote(from: verifiedURL)
                        let verified = VerifiedModels(entries: entries)
                        models = ModelDiscovery.filterVerified(models, verified: verified)
                    }

                    let list = models.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
                    return .init(content: [.text("\(models.count) models available:\n\(list)")])
                } catch {
                    return .init(content: [.text("Failed to fetch models: \(error)")], isError: true)
                }

            case "get_session_stats":
                let snapshot = await state.sessionStats.snapshot()
                let dist = snapshot.modelDistribution.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
                let latency = snapshot.avgLatencyMs.map { "\($0)ms" } ?? "n/a"
                let text = """
                Session Stats:
                  Requests: \(snapshot.totalRequests)
                  Tokens: \(snapshot.totalTokens) (prompt: \(snapshot.totalPromptTokens), completion: \(snapshot.totalCompletionTokens))
                  Avg Latency: \(latency)
                  Uptime: \(snapshot.uptimeSeconds)s
                  Models: \(dist.isEmpty ? "none" : dist)
                """
                return .init(content: [.text(text)])

            case "proxy_logs":
                let lineCount = (params.arguments?["lines"]?.intValue) ?? 75
                let logLines = LogReader.tail(url: LogReader.defaultLogURL, lines: lineCount, redact: true)
                if logLines.isEmpty {
                    return .init(content: [.text("No log output yet. Start the proxy first.")])
                }
                return .init(content: [.text(logLines.joined(separator: "\n"))])

            default:
                return .init(content: [.text("Unknown tool: \(params.name)")], isError: true)
            }
        }

        // Log to stderr (stdout is reserved for JSON-RPC)
        FileHandle.standardError.write(Data("ProxyPilot MCP server starting on stdio...\n".utf8))

        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    // MARK: - Helpers

    private static func secretKeyForProvider(_ provider: UpstreamProvider) -> String? {
        provider.secretKey
    }
}
