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
        let sessionID: String
        let sessionStats: SessionStats

        init() {
            let sessionID = UUID().uuidString
            self.sessionID = sessionID
            self.sessionStats = SessionStats(
                sessionReportURL: SessionReportStore.defaultURL,
                sessionSource: "mcp",
                sessionID: sessionID
            )
        }

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

    private static func boolProp(_ desc: String) -> Value {
        .object(["type": .string("boolean"), "description": .string(desc)])
    }

    private static func toolSuccess<T: Encodable>(
        tool: String,
        data: T,
        text: String,
        nextActions: [NextAction] = []
    ) -> CallTool.Result {
        let envelope = AgentEnvelope(tool: tool, data: data, nextActions: nextActions)
        let json = (try? AgentJSON.encode(envelope)) ?? "{\"ok\":false,\"schema_version\":1}"
        return .init(content: [
            .text(text: json, annotations: nil, _meta: nil),
            .text(text: text, annotations: nil, _meta: nil),
        ])
    }

    private static func toolError(
        tool: String,
        code: String,
        message: String,
        suggestion: String? = nil,
        nextActions: [NextAction] = []
    ) -> CallTool.Result {
        let envelope = AgentErrorEnvelope(
            tool: tool,
            error: AgentError(code: code, message: message, suggestion: suggestion, recoverable: !nextActions.isEmpty),
            nextActions: nextActions
        )
        let json = (try? AgentJSON.encode(envelope)) ?? "{\"ok\":false,\"schema_version\":1}"
        return .init(content: [
            .text(text: json, annotations: nil, _meta: nil),
            .text(text: message, annotations: nil, _meta: nil),
        ], isError: true)
    }

    private static func portArgument(
        _ arguments: [String: Value]?,
        name: String = "port",
        default defaultPort: UInt16,
        tool: String,
        allowZero: Bool = true
    ) -> (port: UInt16?, error: CallTool.Result?) {
        switch MCPArgumentValidator.port(arguments?[name], default: defaultPort, tool: tool, allowZero: allowZero) {
        case .success(let port):
            return (port, nil)
        case .failure(let code, let message):
            return (nil, toolError(tool: tool, code: code, message: message))
        }
    }

    private static func stringArgument(
        _ arguments: [String: Value]?,
        name: String,
        default defaultValue: String?,
        tool: String
    ) -> (value: String?, error: CallTool.Result?) {
        switch MCPArgumentValidator.string(arguments?[name], default: defaultValue, name: name, tool: tool) {
        case .success(let value):
            return (value, nil)
        case .failure(let code, let message):
            return (nil, toolError(tool: tool, code: code, message: message))
        }
    }

    private static func promptCachingArgument(
        _ value: Value?,
        default defaultValue: CLIPromptCachingMode,
        tool: String
    ) -> (value: CLIPromptCachingMode, error: CallTool.Result?) {
        guard let value else { return (defaultValue, nil) }
        guard let raw = value.stringValue,
              let parsed = CLIPromptCachingMode(argument: raw) else {
            return (
                defaultValue,
                toolError(
                    tool: tool,
                    code: "E050",
                    message: "Invalid prompt_caching value.",
                    suggestion: "Use auto, observe-only, or off."
                )
            )
        }
        return (parsed, nil)
    }

    static func run(
        port: UInt16,
        provider: String?,
        key: String?,
        upstreamURL: String? = nil,
        promptCaching: CLIPromptCachingMode = .auto
    ) async throws {
        let state = ProxyState()
        let lifecycleGate = LifecycleGate()

        let server = Server(
            name: "proxypilot",
            version: ProxyPilotCommand.configuration.version,
            title: "ProxyPilot",
            instructions: """
            ProxyPilot routes Xcode Agent Mode requests through alternative AI providers.

            Typical workflow:
            1. preflight — inspect auth, proxy, Xcode config, blockers, and next_actions
            2. auth_set — only when preflight reports missing auth and the user supplied a key; requires allow_secret_write: true
            3. proxy_start or proxy_restart — start or update the local proxy
            4. xcode_config_install — point Xcode at the proxy after proxy startup succeeds
            5. verify_routing — confirm local /v1/models and Xcode config state
            6. Tell the user to quit and relaunch Xcode

            Important:
            - proxy_stop does not remove Xcode config. Call xcode_config_remove if the user wants direct Anthropic routing restored.
            - Use proxy_restart instead of proxy_start when changing provider/model on an already running proxy.
            - Xcode config changes require quitting and relaunching Xcode.
            - verify_routing v1 is local-only and never sends a real upstream completion request.
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
                        "provider": stringProp("Upstream provider: \(UpstreamProvider.cliOptionsDescription). Omit to select from configured provider keys."),
                        "model": stringProp("Upstream model(s) to route requests to, comma-separated (e.g. 'gpt-4o,claude-3-opus'). First model is preferred for Anthropic translation. If omitted, provider fallback models are used when available."),
                        "key": stringProp("Upstream API key (optional, falls back to secrets store)"),
                        "url": stringProp("Upstream API base URL override (e.g. http://localhost:11434/v1)"),
                        "prompt_caching": stringProp("Prompt caching mode: auto, observe-only, or off."),
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
                        "provider": stringProp("Upstream provider: \(UpstreamProvider.cliOptionsDescription). Omit to keep the current provider or select from configured provider keys."),
                        "model": stringProp("Upstream model(s) to route requests to, comma-separated (e.g. 'gpt-4o,claude-3-opus'). First model is preferred for Anthropic translation."),
                        "key": stringProp("Upstream API key"),
                        "url": stringProp("Upstream API base URL override (e.g. http://localhost:11434/v1)"),
                        "prompt_caching": stringProp("Prompt caching mode: auto, observe-only, or off."),
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
                    inputSchema: jsonSchemaObject(properties: [
                        "port": intProp("Port to inspect (default 4000)"),
                    ]),
                    annotations: .init(
                        readOnlyHint: true,
                        destructiveHint: false,
                        idempotentHint: true,
                        openWorldHint: false
                    )
                ),
                Tool(
                    name: "preflight",
                    title: "Preflight",
                    description: "Inspect ProxyPilot agent readiness and return blockers plus next_actions. Recommended first call.",
                    inputSchema: jsonSchemaObject(properties: [
                        "port": intProp("Port to inspect (default 4000)"),
                        "provider": stringProp("Upstream provider to plan for"),
                        "model": stringProp("Preferred upstream model"),
                    ]),
                    annotations: .init(
                        readOnlyHint: true,
                        destructiveHint: false,
                        idempotentHint: true,
                        openWorldHint: false
                    )
                ),
                Tool(
                    name: "auth_status",
                    title: "Auth Status",
                    description: "Report whether API keys are stored for one provider or all providers without reading secret values.",
                    inputSchema: jsonSchemaObject(properties: [
                        "provider": stringProp("Provider to inspect. Omit for all providers."),
                    ]),
                    annotations: .init(
                        readOnlyHint: true,
                        destructiveHint: false,
                        idempotentHint: true,
                        openWorldHint: false
                    )
                ),
                Tool(
                    name: "auth_set",
                    title: "Store API Key",
                    description: "Store a provider API key. Requires allow_secret_write: true because this writes to the user's secrets store.",
                    inputSchema: jsonSchemaObject(properties: [
                        "provider": stringProp("Cloud provider to store auth for"),
                        "key": stringProp("API key value to store"),
                        "allow_secret_write": boolProp("Must be true to store the key in the user's secrets store"),
                    ]),
                    annotations: .init(
                        readOnlyHint: false,
                        destructiveHint: false,
                        idempotentHint: true,
                        openWorldHint: false
                    )
                ),
                Tool(
                    name: "verify_routing",
                    title: "Verify Routing",
                    description: "Run local-only routing checks against /v1/models and Xcode config state. Does not send an upstream completion request.",
                    inputSchema: jsonSchemaObject(properties: [
                        "port": intProp("Port to verify (default 4000)"),
                    ]),
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
                        "provider": stringProp("Upstream provider (default: current proxy provider). Options: \(UpstreamProvider.cliOptionsDescription)"),
                        "key": stringProp("API key (optional, falls back to secrets store)"),
                        "url": stringProp("Override base URL"),
                        "filter": stringProp("Filter: exacto, verified, tool-calling, or chat"),
                        "metadata": boolProp("Return model metadata objects instead of just IDs"),
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

            case "preflight":
                let parsedPort = portArgument(params.arguments, default: port, tool: "preflight")
                if let error = parsedPort.error { return error }
                let reqPort = parsedPort.port ?? port
                let parsedProvider = MCPArgumentValidator.provider(
                    params.arguments?["provider"],
                    default: provider ?? ProxyPilotDefaults.defaultCLIProvider.rawValue,
                    tool: "preflight"
                )
                guard case .success(let upstream) = parsedProvider else {
                    let message: String
                    if case .failure(_, let failureMessage) = parsedProvider {
                        message = failureMessage
                    } else {
                        message = "Invalid provider argument."
                    }
                    return toolError(
                        tool: "preflight",
                        code: "E001",
                        message: message,
                        suggestion: "Valid providers: \(UpstreamProvider.cliOptionsDescription)"
                    )
                }
                let reqProvider = upstream.rawValue
                let parsedModel = stringArgument(params.arguments, name: "model", default: nil, tool: "preflight")
                if let error = parsedModel.error { return error }
                let reqModel = parsedModel.value
                let (payload, actions) = await AgentPreflightService.report(
                    port: reqPort,
                    provider: reqProvider,
                    model: reqModel
                )
                return toolSuccess(
                    tool: "preflight",
                    data: payload,
                    text: payload.ready ? "ProxyPilot is ready." : "ProxyPilot needs setup actions.",
                    nextActions: actions
                )

            case "verify_routing":
                let parsedPort = portArgument(params.arguments, default: port, tool: "verify_routing")
                if let error = parsedPort.error { return error }
                let reqPort = parsedPort.port ?? port
                return await lifecycleGate.withLock {
                    let (payload, actions) = await RoutingVerificationService.verify(port: reqPort)
                    return toolSuccess(
                        tool: "verify_routing",
                        data: payload,
                        text: payload.localModelsReachable ? "Local routing probe passed." : "Local routing probe failed.",
                        nextActions: actions
                    )
                }

            case "auth_status":
                let secrets = SecretsProviderFactory.make()
                let backend = authBackendInfo(for: secrets)
                let providerValidation = MCPArgumentValidator.optionalProvider(params.arguments?["provider"], tool: "auth_status")
                switch providerValidation {
                case .success(let upstream?):
                    let payload = authPayload(for: upstream, secrets: secrets, backend: backend, includePath: true)
                    return toolSuccess(
                        tool: "auth_status",
                        data: payload,
                        text: "\(payload.provider): \(payload.status) (\(payload.backend))"
                    )
                case .success(nil):
                    let providers = UpstreamProvider.allCases.map {
                        authPayload(for: $0, secrets: secrets, backend: backend, includePath: false)
                    }
                    return toolSuccess(
                        tool: "auth_status",
                        data: ProvidersAuthPayload(providers: providers, path: backend.filePath),
                        text: "Auth status returned for \(providers.count) providers."
                    )
                case .failure(_, let message):
                        return toolError(
                            tool: "auth_status",
                            code: "E001",
                            message: message,
                            suggestion: "Valid providers: \(UpstreamProvider.cliOptionsDescription)"
                        )
                }

            case "auth_set":
                guard params.arguments?["allow_secret_write"]?.boolValue == true else {
                    return toolError(
                        tool: "auth_set",
                        code: "E045_SECRET_WRITE_NOT_ALLOWED",
                        message: "auth_set writes to the user's secrets store and requires allow_secret_write: true.",
                        suggestion: "Ask the user for permission, then retry with allow_secret_write: true."
                    )
                }
                guard let providerArg = params.arguments?["provider"]?.stringValue,
                      let upstream = UpstreamProvider(rawValue: providerArg) else {
                    return toolError(
                        tool: "auth_set",
                        code: "E001",
                        message: "Unknown or missing provider.",
                        suggestion: "Valid providers: \(UpstreamProvider.cliOptionsDescription)"
                    )
                }
                guard upstream.requiresAPIKey, let secretKeyName = upstream.secretKey else {
                    return toolError(
                        tool: "auth_set",
                        code: "E041",
                        message: "Provider \(upstream.rawValue) does not require an API key.",
                        suggestion: "Local/helper providers do not need auth setup."
                    )
                }
                let parsedKey = stringArgument(params.arguments, name: "key", default: nil, tool: "auth_set")
                if let error = parsedKey.error { return error }
                let rawKey = parsedKey.value ?? ""
                let trimmedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedKey.isEmpty else {
                    return toolError(
                        tool: "auth_set",
                        code: "E040",
                        message: "API key is empty or whitespace-only.",
                        suggestion: "Retry with a non-empty key."
                    )
                }
                if case let .failure(code, message) = APIKeyValidator.validate(trimmedKey, for: upstream) {
                    return toolError(
                        tool: "auth_set",
                        code: code,
                        message: message,
                        suggestion: "Re-enter the full Z.ai API key."
                    )
                }

                let secrets = SecretsProviderFactory.make()
                do {
                    try secrets.set(key: secretKeyName, value: trimmedKey)
                } catch {
                    return toolError(
                        tool: "auth_set",
                        code: "E043",
                        message: "Failed to write API key for provider \(upstream.rawValue): \(error.localizedDescription)",
                        suggestion: "Verify secrets store permissions and retry."
                    )
                }

                let backend = authBackendInfo(for: secrets)
                let payload = ProviderAuthPayload(
                    provider: upstream.rawValue,
                    status: "stored",
                    stored: true,
                    backend: backend.label,
                    path: backend.filePath
                )
                return toolSuccess(
                    tool: "auth_set",
                    data: payload,
                    text: "Stored API key for \(upstream.rawValue) in \(backend.label) backend."
                )

            case "proxy_start":
                let parsedPort = portArgument(params.arguments, default: port, tool: "proxy_start")
                if let error = parsedPort.error { return error }
                let reqPort = parsedPort.port ?? port
                let parsedProvider = MCPArgumentValidator.optionalProvider(params.arguments?["provider"], tool: "proxy_start")
                let parsedKey = stringArgument(params.arguments, name: "key", default: key, tool: "proxy_start")
                if let error = parsedKey.error { return error }
                let parsedURL = stringArgument(params.arguments, name: "url", default: upstreamURL, tool: "proxy_start")
                if let error = parsedURL.error { return error }
                let parsedModel = stringArgument(params.arguments, name: "model", default: nil, tool: "proxy_start")
                if let error = parsedModel.error { return error }
                let parsedPromptCaching = promptCachingArgument(
                    params.arguments?["prompt_caching"],
                    default: promptCaching,
                    tool: "proxy_start"
                )
                if let error = parsedPromptCaching.error { return error }
                let reqKey = parsedKey.value
                let reqURL = parsedURL.value
                let reqModel = parsedModel.value
                let reqPromptCaching = parsedPromptCaching.value

                let requestedProvider: UpstreamProvider?
                switch parsedProvider {
                case .success(let upstream):
                    requestedProvider = upstream
                case .failure(_, let message):
                    return toolError(
                        tool: "proxy_start",
                        code: "E001",
                        message: message,
                        suggestion: "Valid providers: \(UpstreamProvider.cliOptionsDescription)"
                    )
                }

                let secrets = SecretsProviderFactory.make()
                let resolvedCredential = resolveMCPProviderCredential(
                    tool: "proxy_start",
                    rawProvider: requestedProvider?.rawValue ?? provider,
                    explicitKey: reqKey,
                    upstreamURL: reqURL,
                    secrets: secrets,
                    port: reqPort,
                    model: reqModel
                )
                if let error = resolvedCredential.error {
                    return error
                }
                guard let credential = resolvedCredential.credential else {
                    return toolError(
                        tool: "proxy_start",
                        code: "E047",
                        message: "Choose which configured provider ProxyPilot should use."
                    )
                }
                let upstream = credential.provider
                let apiKey = credential.apiKey

                let modelResolution = await resolveProxyModelList(
                    tool: "proxy_start",
                    rawModels: reqModel,
                    provider: upstream,
                    upstreamURL: reqURL,
                    apiKey: apiKey
                )
                if let error = modelResolution.error {
                    return error
                }
                guard let resolvedModels = modelResolution.resolution else {
                    return toolError(
                        tool: "proxy_start",
                        code: "E049",
                        message: "No models could be resolved for \(upstream.rawValue)."
                    )
                }

                await state.sessionStats.reset(clearReportStore: false)
                let modelList = resolvedModels.models
                let allowedModels: Set<String> = modelList.isEmpty ? [] : Set(modelList)
                let config = ProxyConfiguration(
                    port: reqPort,
                    upstreamProvider: upstream,
                    upstreamAPIBaseURL: reqURL,
                    upstreamAPIKey: apiKey,
                    allowedModels: allowedModels,
                    preferredAnthropicUpstreamModel: modelList.first ?? "",
                    sessionStats: state.sessionStats,
                    googleThoughtSignatureStore: upstream == .google ? GoogleThoughtSignatureStore() : nil,
                    inputOutputLogger: try? InputOutputLoggingRecorder.productionIfConfigured(source: "mcp", sessionID: state.sessionID),
                    promptCaching: reqPromptCaching.configuration
                )

                do {
                    return try await lifecycleGate.withLock {
                        let boundPort = try await state.start(config: config)
                        let modelInfo = reqModel.map { " [\($0)]" }
                            ?? (resolvedModels.wasDiscoveredFromUpstream ? " [\(modelList.count) discovered model(s)]" : "")
                        let selectionInfo = credential.selectedFromStoredCredentials ? " (selected from stored provider keys)" : ""
                        return toolSuccess(
                            tool: "proxy_start",
                            data: ProxyLifecyclePayload(
                                status: "started",
                                port: Int(boundPort),
                                provider: upstream.rawValue,
                                model: reqModel
                            ),
                            text: "ProxyPilot started on port \(boundPort) -> \(upstream.title)\(modelInfo)\(selectionInfo).\nXcode is NOT yet configured. Call xcode_config_install (port: \(boundPort)) to route Xcode through ProxyPilot.",
                            nextActions: [
                                NextAction(
                                    id: "install_xcode_config",
                                    kind: .mcpTool,
                                    tool: "xcode_config_install",
                                    arguments: ["port": .int(Int(boundPort))],
                                    destructive: false
                                ),
                            ]
                        )
                    }
                } catch ProxyEngineError.alreadyRunning {
                    let p = await state.currentPort() ?? 0
                    let prov = await state.currentProvider() ?? "unknown"
                    let m = await state.currentModel().map { " [\($0)]" } ?? ""
                    return toolError(
                        tool: "proxy_start",
                        code: "E002",
                        message: "ProxyPilot is already running on port \(p) -> \(prov)\(m).",
                        suggestion: "Call proxy_restart with new parameters to change configuration.",
                        nextActions: [
                            NextAction(id: "restart_proxy", kind: .mcpTool, tool: "proxy_restart", destructive: false),
                        ]
                    )
                } catch {
                    return toolError(
                        tool: "proxy_start",
                        code: "E003",
                        message: "Failed to start: \(error).",
                        suggestion: CLIProxyRuntime.bindFailureSuggestion(port: reqPort, error: error)
                    )
                }

            case "proxy_stop":
                do {
                    return try await lifecycleGate.withLock {
                        try await state.stop()
                        let configStatus = XcodeConfigManager.status()
                        let plan = MCPStopResponsePlanner.plan(configInstalled: configStatus.isInstalled)
                        return toolSuccess(
                            tool: "proxy_stop",
                            data: SimpleToolStatusPayload(status: "stopped"),
                            text: plan.text,
                            nextActions: plan.nextActions
                        )
                    }
                } catch ProxyEngineError.notRunning {
                    return toolError(tool: "proxy_stop", code: "E010", message: "ProxyPilot is not running. Nothing to stop.")
                } catch {
                    return toolError(tool: "proxy_stop", code: "E011", message: "Failed to stop: \(error)")
                }

            case "proxy_restart":
                let parsedPort = portArgument(params.arguments, default: port, tool: "proxy_restart")
                if let error = parsedPort.error { return error }
                let reqPort = parsedPort.port ?? port
                let parsedProvider = MCPArgumentValidator.optionalProvider(params.arguments?["provider"], tool: "proxy_restart")
                let parsedKey = stringArgument(params.arguments, name: "key", default: key, tool: "proxy_restart")
                if let error = parsedKey.error { return error }
                let parsedURL = stringArgument(params.arguments, name: "url", default: upstreamURL, tool: "proxy_restart")
                if let error = parsedURL.error { return error }
                let parsedModel = stringArgument(params.arguments, name: "model", default: nil, tool: "proxy_restart")
                if let error = parsedModel.error { return error }
                let parsedPromptCaching = promptCachingArgument(
                    params.arguments?["prompt_caching"],
                    default: promptCaching,
                    tool: "proxy_restart"
                )
                if let error = parsedPromptCaching.error { return error }
                let reqKey = parsedKey.value
                let reqURL = parsedURL.value
                let reqModel = parsedModel.value
                let reqPromptCaching = parsedPromptCaching.value

                let requestedProvider: UpstreamProvider?
                switch parsedProvider {
                case .success(let upstream):
                    requestedProvider = upstream
                case .failure(_, let message):
                    return toolError(
                        tool: "proxy_restart",
                        code: "E001",
                        message: message,
                        suggestion: "Valid providers: \(UpstreamProvider.cliOptionsDescription)"
                    )
                }

                let currentProvider = await state.currentProvider()
                let secrets = SecretsProviderFactory.make()
                let resolvedCredential = resolveMCPProviderCredential(
                    tool: "proxy_restart",
                    rawProvider: requestedProvider?.rawValue ?? provider ?? currentProvider,
                    explicitKey: reqKey,
                    upstreamURL: reqURL,
                    secrets: secrets,
                    port: reqPort,
                    model: reqModel
                )
                if let error = resolvedCredential.error {
                    return error
                }
                guard let credential = resolvedCredential.credential else {
                    return toolError(
                        tool: "proxy_restart",
                        code: "E047",
                        message: "Choose which configured provider ProxyPilot should use."
                    )
                }
                let upstream = credential.provider
                let apiKey = credential.apiKey

                let modelResolution = await resolveProxyModelList(
                    tool: "proxy_restart",
                    rawModels: reqModel,
                    provider: upstream,
                    upstreamURL: reqURL,
                    apiKey: apiKey
                )
                if let error = modelResolution.error {
                    return error
                }
                guard let resolvedModels = modelResolution.resolution else {
                    return toolError(
                        tool: "proxy_restart",
                        code: "E049",
                        message: "No models could be resolved for \(upstream.rawValue)."
                    )
                }

                let modelList = resolvedModels.models
                let allowedModels: Set<String> = modelList.isEmpty ? [] : Set(modelList)
                let config = ProxyConfiguration(
                    port: reqPort,
                    upstreamProvider: upstream,
                    upstreamAPIBaseURL: reqURL,
                    upstreamAPIKey: apiKey,
                    allowedModels: allowedModels,
                    preferredAnthropicUpstreamModel: modelList.first ?? "",
                    sessionStats: state.sessionStats,
                    googleThoughtSignatureStore: upstream == .google ? GoogleThoughtSignatureStore() : nil,
                    inputOutputLogger: try? InputOutputLoggingRecorder.productionIfConfigured(source: "mcp", sessionID: state.sessionID),
                    promptCaching: reqPromptCaching.configuration
                )

                do {
                    return try await lifecycleGate.withLock {
                        // Stop if running (ignore error if not running)
                        try? await state.stop()
                        let boundPort = try await state.start(config: config)
                        let modelInfo = reqModel.map { " [\($0)]" }
                            ?? (resolvedModels.wasDiscoveredFromUpstream ? " [\(modelList.count) discovered model(s)]" : "")
                        let selectionInfo = credential.selectedFromStoredCredentials ? " (selected from stored provider keys)" : ""
                        return toolSuccess(
                            tool: "proxy_restart",
                            data: ProxyLifecyclePayload(
                                status: "restarted",
                                port: Int(boundPort),
                                provider: upstream.rawValue,
                                model: reqModel
                            ),
                            text: "ProxyPilot restarted on port \(boundPort) -> \(upstream.title)\(modelInfo)\(selectionInfo).\nCall xcode_config_install (port: \(boundPort)) to update Xcode routing.",
                            nextActions: [
                                NextAction(
                                    id: "install_xcode_config",
                                    kind: .mcpTool,
                                    tool: "xcode_config_install",
                                    arguments: ["port": .int(Int(boundPort))],
                                    destructive: false
                                ),
                            ]
                        )
                    }
                } catch {
                    return toolError(
                        tool: "proxy_restart",
                        code: "E003",
                        message: "Failed to restart: \(error).",
                        suggestion: CLIProxyRuntime.bindFailureSuggestion(port: reqPort, error: error)
                    )
                }

            case "proxy_status":
                let parsedPort = portArgument(params.arguments, default: port, tool: "proxy_status")
                if let error = parsedPort.error { return error }
                let requestedPort = parsedPort.port ?? port
                return await lifecycleGate.withLock {
                    let running = await state.isRunning()
                    let currentPort = await state.currentPort()
                    let p = MCPStatusPortResolver.probePort(
                        currentPort: currentPort,
                        requestedPort: requestedPort
                    )
                    let probe = await CLIProxyRuntime.probeProxy(on: p)
                    let effectiveStatus: String
                    if running && probe.reachable {
                        effectiveStatus = "running"
                    } else if running {
                        effectiveStatus = "running_unhealthy"
                    } else if probe.reachable {
                        effectiveStatus = "running_unmanaged"
                    } else {
                        effectiveStatus = "stopped"
                    }
                    let owner: String
                    if running {
                        owner = "mcp"
                    } else if probe.reachable {
                        owner = "external_or_gui"
                    } else {
                        owner = "none"
                    }
                    let payload = StatusPayload(
                        running: effectiveStatus != "stopped",
                        process: .init(managed: running, pid: nil, owner: owner),
                        http: .init(reachable: probe.reachable, port: Int(p), modelsCount: probe.modelCount, errorMessage: probe.errorMessage),
                        effectiveStatus: effectiveStatus
                    )
                    return toolSuccess(
                        tool: "proxy_status",
                        data: payload,
                        text: "ProxyPilot status: \(effectiveStatus)."
                    )
                }

            case "xcode_config_install":
                let parsedPort = portArgument(params.arguments, default: port, tool: "xcode_config_install", allowZero: false)
                if let error = parsedPort.error { return error }
                let configPort = parsedPort.port ?? port
                // Warn if proxy is running on a different port
                let proxyRunning = await state.isRunning()
                let proxyPort = await state.currentPort()
                var warning = ""
                if !proxyRunning {
                    warning = "\nWARNING: No ProxyPilot proxy is currently running. Start one with proxy_start before Xcode tries to connect."
                } else if let rp = proxyPort, rp != configPort {
                    warning = "\nWARNING: Proxy is running on port \(rp) but config points at port \(configPort). Consider using port \(rp) instead."
                }

                do {
                    let status = try XcodeConfigManager.install(port: configPort)
                    let nextActions: [NextAction] = proxyRunning ? [] : [
                        NextAction(
                            id: "start_proxy",
                            kind: .mcpTool,
                            tool: "proxy_start",
                            arguments: ["port": .int(Int(configPort))],
                            destructive: false
                        ),
                    ]
                    return toolSuccess(
                        tool: "xcode_config_install",
                        data: XcodeConfigToolPayload(
                            status: "installed",
                            installed: status.isInstalled,
                            port: Int(configPort),
                            settingsPath: XcodeConfigManager.settingsFileURL.path,
                            settingsFilePresent: status.settingsExists,
                            defaultsOverridePresent: status.defaultsOverrideExists,
                            baseURL: status.configuredBaseURL
                        ),
                        text: "Xcode config installed. Routing: 127.0.0.1:\(configPort).\(warning)\nIf Xcode is open, the user MUST quit and relaunch Xcode for changes to take effect.",
                        nextActions: nextActions
                    )
                } catch {
                    return toolError(
                        tool: "xcode_config_install",
                        code: "E031",
                        message: "Failed to write Xcode config: \(error).",
                        suggestion: "Check that ~/Library/Developer/Xcode/CodingAssistant/ is writable."
                    )
                }

            case "xcode_config_remove":
                do {
                    let removal = try XcodeConfigManager.remove()
                    let changed = removal.settingsRemoved || removal.defaultsOverrideRemoved
                    return toolSuccess(
                        tool: "xcode_config_remove",
                        data: XcodeConfigRemoveToolPayload(
                            status: changed ? "removed" : "not-installed",
                            installed: removal.status.isInstalled,
                            settingsRemoved: removal.settingsRemoved,
                            defaultsOverrideRemoved: removal.defaultsOverrideRemoved,
                            settingsPath: XcodeConfigManager.settingsFileURL.path
                        ),
                        text: changed
                            ? "Xcode config removed. Xcode will route to Anthropic directly.\nIf Xcode is open, the user MUST quit and relaunch Xcode for changes to take effect."
                            : "Xcode config was not installed. No action taken."
                    )
                } catch {
                    return toolError(tool: "xcode_config_remove", code: "E032", message: "Failed to remove Xcode config: \(error)")
                }

            case "list_upstream_models":
                let parsedProvider = MCPArgumentValidator.provider(
                    params.arguments?["provider"],
                    default: provider ?? ProxyPilotDefaults.defaultCLIProvider.rawValue,
                    tool: "list_upstream_models"
                )
                let parsedKey = stringArgument(params.arguments, name: "key", default: key, tool: "list_upstream_models")
                if let error = parsedKey.error { return error }
                let parsedURL = stringArgument(params.arguments, name: "url", default: nil, tool: "list_upstream_models")
                if let error = parsedURL.error { return error }
                let reqKey = parsedKey.value
                let reqURL = parsedURL.value
                let filterValidation = MCPArgumentValidator.modelFilter(params.arguments?["filter"], tool: "list_upstream_models")
                guard case .success(let validatedFilter) = filterValidation else {
                    if case .failure(let code, let message) = filterValidation {
                        return toolError(tool: "list_upstream_models", code: code, message: message)
                    }
                    return toolError(tool: "list_upstream_models", code: "E034", message: "Invalid model filter.")
                }
                let metadataValidation = MCPArgumentValidator.bool(
                    params.arguments?["metadata"],
                    default: false,
                    name: "metadata",
                    tool: "list_upstream_models"
                )
                guard case .success(let reqMetadata) = metadataValidation else {
                    if case .failure(let code, let message) = metadataValidation {
                        return toolError(tool: "list_upstream_models", code: code, message: message)
                    }
                    return toolError(tool: "list_upstream_models", code: "E035", message: "Invalid metadata argument.")
                }

                guard case .success(let upstream) = parsedProvider else {
                    let message: String
                    if case .failure(_, let failureMessage) = parsedProvider {
                        message = failureMessage
                    } else {
                        message = "Invalid provider argument."
                    }
                    return toolError(
                        tool: "list_upstream_models",
                        code: "E001",
                        message: message,
                        suggestion: "Valid providers: \(UpstreamProvider.cliOptionsDescription)"
                    )
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

                    let needsVerified = reqMetadata || validatedFilter == "verified"
                    let verified: VerifiedModels
                    if needsVerified {
                        let verifiedURL = URL(string: "https://micah.chat/proxypilot/verified-models.json")!
                        let entries = await VerifiedModels.fetchRemote(from: verifiedURL)
                        verified = VerifiedModels(entries: entries)
                    } else {
                        verified = VerifiedModels(entries: [])
                    }

                    let summaries = ModelSummaryBuilder.summaries(ids: models, verified: verified)
                    let filtered = ModelSummaryBuilder.apply(filter: validatedFilter, ids: models, summaries: summaries, verified: verified)
                    models = filtered.0
                    let modelSummaries = filtered.1
                    let list = models.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
                    return toolSuccess(
                        tool: "list_upstream_models",
                        data: ModelsToolPayload(
                            provider: upstream.rawValue,
                            count: reqMetadata ? modelSummaries.count : models.count,
                            models: reqMetadata ? nil : models,
                            modelSummaries: reqMetadata ? modelSummaries : nil
                        ),
                        text: "\(reqMetadata ? modelSummaries.count : models.count) models available:\n\(list)"
                    )
                } catch {
                    return toolError(
                        tool: "list_upstream_models",
                        code: "E005",
                        message: "Failed to fetch models: \(error)",
                        suggestion: "Check your API key and provider URL."
                    )
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
                return toolSuccess(
                    tool: "get_session_stats",
                    data: SessionStatsToolPayload(
                        requests: snapshot.totalRequests,
                        totalTokens: snapshot.totalTokens,
                        promptTokens: snapshot.totalPromptTokens,
                        completionTokens: snapshot.totalCompletionTokens,
                        averageLatencyMs: snapshot.avgLatencyMs,
                        uptimeSeconds: snapshot.uptimeSeconds,
                        models: snapshot.modelDistribution,
                        promptCacheHitTokens: snapshot.totalPromptCacheHitTokens,
                        promptCacheMissTokens: snapshot.totalPromptCacheMissTokens,
                        promptCacheWriteTokens: snapshot.totalPromptCacheWriteTokens,
                        cacheHitRate: snapshot.cacheHitRate,
                        cacheAccountingAvailable: snapshot.cacheAccountingAvailable
                    ),
                    text: text
                )

            case "proxy_logs":
                let lineCount = (params.arguments?["lines"]?.intValue) ?? 75
                let logLines = LogReader.tail(url: LogReader.defaultLogURL, lines: lineCount, redact: true)
                if logLines.isEmpty {
                    return .init(content: [.text(text: "No log output yet. Start the proxy first.", annotations: nil, _meta: nil)])
                }
                return .init(content: [.text(text: logLines.joined(separator: "\n"), annotations: nil, _meta: nil)])

            default:
                return .init(content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)], isError: true)
            }
        }

        // Log to stderr (stdout is reserved for JSON-RPC)
        FileHandle.standardError.write(Data("ProxyPilot MCP server starting on stdio...\n".utf8))

        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    // MARK: - Helpers

    private static func resolveMCPProviderCredential(
        tool: String,
        rawProvider: String?,
        explicitKey: String?,
        upstreamURL: String?,
        secrets: any SecretsProvider,
        port: UInt16,
        model: String?
    ) -> (credential: ResolvedProviderCredential?, error: CallTool.Result?) {
        let resolution = ProviderCredentialResolver.resolve(
            rawProvider: rawProvider,
            explicitKey: explicitKey,
            upstreamURL: upstreamURL,
            secrets: secrets
        )

        switch resolution {
        case .resolved(let credential):
            return (credential, nil)
        case .unknownProvider(let raw):
            return (nil, toolError(
                tool: tool,
                code: "E001",
                message: "Unknown provider: \(raw).",
                suggestion: "Valid providers: \(UpstreamProvider.cliOptionsDescription)"
            ))
        case .missingAPIKey(let provider, let secretKeyName):
            return (nil, toolError(
                tool: tool,
                code: "E004",
                message: "No API key found for provider \(provider.rawValue).",
                suggestion: "Pass a key parameter, set \(secretKeyName ?? "the provider env var"), or store it with auth_set.",
                nextActions: [
                    NextAction(
                        id: "auth_set_\(provider.rawValue)",
                        kind: .mcpTool,
                        tool: "auth_set",
                        arguments: [
                            "provider": .string(provider.rawValue),
                            "allow_secret_write": .bool(true),
                        ],
                        destructive: false
                    ),
                ]
            ))
        case .selectionRequired(let prompt):
            let message = prompt.availableProviders.isEmpty
                ? "No configured provider API keys were found."
                : "Choose which configured provider ProxyPilot should use."
            return (nil, toolError(
                tool: tool,
                code: "E047",
                message: message,
                suggestion: prompt.humanList,
                nextActions: mcpProviderSelectionNextActions(
                    tool: tool,
                    prompt: prompt,
                    port: port,
                    model: model,
                    upstreamURL: upstreamURL
                )
            ))
        }
    }

    private static func mcpProviderSelectionNextActions(
        tool: String,
        prompt: ProviderSelectionPrompt,
        port: UInt16,
        model: String?,
        upstreamURL: String?
    ) -> [NextAction] {
        var actions = prompt.availableProviders.map { choice in
            var arguments: [String: NextActionValue] = [
                "provider": .string(choice.provider),
                "port": .int(Int(port)),
            ]
            if let model {
                arguments["model"] = .string(model)
            }
            if let upstreamURL {
                arguments["url"] = .string(upstreamURL)
            }
            return NextAction(
                id: "\(tool)_with_\(choice.provider)",
                kind: .mcpTool,
                tool: tool,
                arguments: arguments,
                destructive: false
            )
        }

        actions.append(NextAction(
            id: "auth_set",
            kind: .user,
            message: "Choose a provider, then call auth_set with provider, key, and allow_secret_write: true.",
            destructive: false
        ))
        actions.append(NextAction(
            id: "add_provider",
            kind: .user,
            message: "Add custom providers in the ProxyPilot app before starting the proxy from MCP.",
            destructive: false
        ))
        return actions
    }

    private static func secretKeyForProvider(_ provider: UpstreamProvider) -> String? {
        provider.secretKey
    }

    private static func authPayload(
        for provider: UpstreamProvider,
        secrets: any SecretsProvider,
        backend: AuthBackendInfo,
        includePath: Bool
    ) -> ProviderAuthPayload {
        guard provider.requiresAPIKey, let secretKey = provider.secretKey else {
            return ProviderAuthPayload(
                provider: provider.rawValue,
                status: "not_required",
                stored: false,
                backend: "none",
                path: nil
            )
        }

        let exists = (try? secrets.exists(key: secretKey)) ?? false
        return ProviderAuthPayload(
            provider: provider.rawValue,
            status: exists ? "stored" : "not_set",
            stored: exists,
            backend: backend.label,
            path: includePath ? backend.filePath : nil
        )
    }

    private static func resolveProxyModelList(
        tool: String,
        rawModels: String?,
        provider: UpstreamProvider,
        upstreamURL: String?,
        apiKey: String?
    ) async -> (resolution: CLIStartModelResolution?, error: CallTool.Result?) {
        do {
            let resolution = try await CLIStartModelResolver.resolve(
                rawModels: rawModels,
                provider: provider,
                upstreamURL: upstreamURL,
                apiKey: apiKey
            )
            return (resolution, nil)
        } catch let error as CLIStartModelResolver.ResolutionError {
            return (nil, toolError(
                tool: tool,
                code: "E049",
                message: error.localizedDescription,
                suggestion: error.recoverySuggestion
            ))
        } catch {
            return (nil, toolError(
                tool: tool,
                code: "E005",
                message: "Failed to discover upstream models for \(provider.rawValue): \(error)",
                suggestion: "Check the upstream URL, verify the server is reachable, or pass model explicitly."
            ))
        }
    }

    private struct ModelsToolPayload: Encodable {
        let provider: String
        let count: Int
        let models: [String]?
        let modelSummaries: [ModelSummary]?

        enum CodingKeys: String, CodingKey {
            case provider
            case count
            case models
            case modelSummaries = "model_summaries"
        }
    }

    private struct ProxyLifecyclePayload: Encodable {
        let status: String
        let port: Int
        let provider: String
        let model: String?
    }

    private struct SimpleToolStatusPayload: Encodable {
        let status: String
    }

    private struct XcodeConfigToolPayload: Encodable {
        let status: String
        let installed: Bool
        let port: Int
        let settingsPath: String
        let settingsFilePresent: Bool
        let defaultsOverridePresent: Bool
        let baseURL: String?

        enum CodingKeys: String, CodingKey {
            case status
            case installed
            case port
            case settingsPath = "settings_path"
            case settingsFilePresent = "settings_file_present"
            case defaultsOverridePresent = "defaults_override_present"
            case baseURL = "base_url"
        }
    }

    private struct XcodeConfigRemoveToolPayload: Encodable {
        let status: String
        let installed: Bool
        let settingsRemoved: Bool
        let defaultsOverrideRemoved: Bool
        let settingsPath: String

        enum CodingKeys: String, CodingKey {
            case status
            case installed
            case settingsRemoved = "settings_removed"
            case defaultsOverrideRemoved = "defaults_override_removed"
            case settingsPath = "settings_path"
        }
    }

}
