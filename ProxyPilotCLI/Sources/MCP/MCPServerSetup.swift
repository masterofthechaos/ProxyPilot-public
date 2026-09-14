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
        func currentConfiguration() -> ProxyConfiguration? { config }
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
    private static func jsonSchemaObject(properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty { schema["required"] = .array(required.map(Value.string)) }
        return .object(schema)
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
        promptCaching: CLIPromptCachingMode = .auto,
        contextCompaction: CLIContextCompactionMode = .auto
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
            4. Ask the user before changing Xcode Agent routing. MCP Xcode config writes are disabled unless the user starts MCP with PROXYPILOT_MCP_ALLOW_XCODE_CONFIG=1.
            5. xcode_config_install — only after the user explicitly confirms the persistent routing change and the call includes allow_xcode_config_write: true
            6. verify_routing — confirm local /v1/models and Xcode config state
            7. Tell the user to quit and relaunch Xcode

            Important:
            - proxy_stop does not remove Xcode config. Use xcode_config_remove only after the user explicitly confirms they want direct Anthropic routing restored.
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
                    name: "proxy_route_set",
                    title: "Set Active Route",
                    description: "Transactionally select a ProxyPilot provider/model route for an active RepoGPS session. The downstream model remains proxypilot-active.",
                    inputSchema: jsonSchemaObject(properties: [
                        "port": intProp("Port to listen on (default 4000)"),
                        "provider": stringProp("Required upstream provider ID"),
                        "model": stringProp("Required upstream model ID"),
                    ], required: ["provider", "model"]),
                    annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true)
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
                    ], required: ["provider", "key", "allow_secret_write"]),
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
                    description: "Write Xcode Agent Mode configuration so Xcode routes requests through ProxyPilot. Disabled unless MCP was launched with PROXYPILOT_MCP_ALLOW_XCODE_CONFIG=1 and this call includes allow_xcode_config_write: true after explicit user confirmation.",
                    inputSchema: jsonSchemaObject(properties: [
                        "port": intProp("ProxyPilot port to point Xcode at (default 4000, range 1024-65535)"),
                        "allow_xcode_config_write": boolProp("Must be true after the user explicitly consents to this persistent Xcode routing change"),
                    ], required: ["allow_xcode_config_write"]),
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
                    description: "Remove Xcode Agent Mode configuration, restoring Xcode to use Anthropic's servers directly. Disabled unless MCP was launched with PROXYPILOT_MCP_ALLOW_XCODE_CONFIG=1 and this call includes allow_xcode_config_write: true after explicit user confirmation.",
                    inputSchema: jsonSchemaObject(properties: [
                        "allow_xcode_config_write": boolProp("Must be true after the user explicitly consents to this persistent Xcode routing change"),
                    ], required: ["allow_xcode_config_write"]),
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
                        "url": stringProp("Approved provider base URL override; arbitrary origins are rejected"),
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
                    description: "Get request count, token usage, model distribution, and average latency. When the harness exports a client session, this reports that session's usage aggregated from the durable session report; otherwise it reports only a proxy running inside this MCP process. The payload names its own scope.",
                    inputSchema: emptySchema,
                    annotations: .init(
                        readOnlyHint: true,
                        destructiveHint: false,
                        idempotentHint: true,
                        openWorldHint: false
                    )
                ),
                Tool(
                    name: "get_session_history",
                    title: "Get Session History",
                    description: "List recorded proxy sessions, or show one session's request history and (optionally) its decrypted input/output logs. Omit session_id to list all recorded sessions.",
                    inputSchema: jsonSchemaObject(properties: [
                        "session_id": stringProp("Session ID to show details for. Omit to list all recorded sessions."),
                        "include_logs": boolProp("When session_id is provided, also include decrypted input/output log records if input & output logging is enabled (default: false). Requires \(MCPIOSessionLogConsent.environmentVariable)=1 on the MCP server and allow_io_log_read: true on this call."),
                        "allow_io_log_read": boolProp("Must be true after the user explicitly consents to exposing decrypted prompts and outputs for this session."),
                    ]),
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
                    description: "Read recent lines from the GUI built-in proxy log with secrets redacted. This file is shared and never scoped to a session, so it may contain stale or unrelated entries; do not infer the active route or model from it. Use get_session_stats for attributed usage.",
                    inputSchema: jsonSchemaObject(properties: [
                        "lines": intProp("Number of lines to return (default 75, range 1-1000)"),
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
                guard let secretKeyName = upstream.secretKey else {
                    return toolError(
                        tool: "auth_set",
                        code: "E041",
                        message: "Provider \(upstream.rawValue) does not require an API key.",
                        suggestion: "Choose a cloud provider, or 9router when its endpoint requires a bearer token."
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
                let localProxyCredential = LocalProxyCredential.requiresAuthentication(
                    explicitlyRequired: false,
                    upstreamAPIKey: apiKey
                ) ? try LocalProxyCredential.resolveOrCreate(using: secrets) : nil
                if let localProxyCredential {
                    try XcodeConfigManager.synchronizeLocalProxyCredentialIfInstalled(localProxyCredential)
                }
                // Resolved per request, not frozen here: enabling MCP capture
                // while the proxy is already running must take effect without a
                // restart.
                let inputOutputLoggerCache = InputOutputLoggerSessionCache()
                let config = ProxyConfiguration(
                    port: reqPort,
                    upstreamProvider: upstream,
                    upstreamAPIBaseURL: reqURL,
                    upstreamAPIKey: apiKey,
                    masterKey: localProxyCredential,
                    allowedModels: allowedModels,
                    requiresAuth: localProxyCredential != nil,
                    preferredAnthropicUpstreamModel: modelList.first ?? "",
                    sessionStats: state.sessionStats,
                    googleThoughtSignatureStore: upstream == .google ? GoogleThoughtSignatureStore() : nil,
                    inputOutputLoggerProvider: inputOutputLoggerCache.provider(source: "mcp", sessionID: state.sessionID),
                    promptCaching: reqPromptCaching.configuration,
                    contextCompaction: contextCompaction.configuration()
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
                            nextActions: [MCPXcodeConfigConsent.installNextAction(port: boundPort)]
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

            case "proxy_restart", "proxy_route_set":
                let routeTool = params.name == "proxy_route_set" ? "proxy_route_set" : "proxy_restart"
                let isRouteSet = routeTool == "proxy_route_set"
                // proxy_route_set advertises only port/provider/model, but shares this
                // handler with proxy_restart, which also declares key/url/prompt_caching.
                // An MCP client renders its consent prompt from the declared schema, so
                // honoring those here would let a route change redirect proxied traffic —
                // and the stored upstream key — to a host the user never saw. The route
                // path therefore takes them from the server's own configuration only.
                let privilegedArguments = isRouteSet ? nil : params.arguments
                let parsedPort = portArgument(params.arguments, default: port, tool: routeTool)
                if let error = parsedPort.error { return error }
                let reqPort = parsedPort.port ?? port
                let parsedProvider = MCPArgumentValidator.optionalProvider(params.arguments?["provider"], tool: routeTool)
                let parsedKey = stringArgument(privilegedArguments, name: "key", default: key, tool: routeTool)
                if let error = parsedKey.error { return error }
                let parsedURL = stringArgument(privilegedArguments, name: "url", default: upstreamURL, tool: routeTool)
                if let error = parsedURL.error { return error }
                let parsedModel = stringArgument(params.arguments, name: "model", default: nil, tool: routeTool)
                if let error = parsedModel.error { return error }
                let parsedPromptCaching = promptCachingArgument(
                    privilegedArguments?["prompt_caching"],
                    default: promptCaching,
                    tool: routeTool
                )
                if let error = parsedPromptCaching.error { return error }
                let reqKey = parsedKey.value
                let reqURL = parsedURL.value
                let reqModel = parsedModel.value
                let reqPromptCaching = parsedPromptCaching.value
                if isRouteSet, reqModel == nil {
                    return toolError(tool: routeTool, code: "E049", message: "model is required")
                }

                let requestedProvider: UpstreamProvider?
                switch parsedProvider {
                case .success(let upstream):
                    requestedProvider = upstream
                case .failure(_, let message):
                    return toolError(
                        tool: routeTool,
                        code: "E001",
                        message: message,
                        suggestion: "Valid providers: \(UpstreamProvider.cliOptionsDescription)"
                    )
                }

                // The schema marks provider required; enforce it rather than falling
                // back to the ambient or current provider, so a route is never set to
                // a provider the caller did not name.
                if isRouteSet, requestedProvider == nil {
                    return toolError(
                        tool: routeTool,
                        code: "E049",
                        message: "provider is required",
                        suggestion: "Valid providers: \(UpstreamProvider.cliOptionsDescription)"
                    )
                }

                let currentProvider = await state.currentProvider()
                let secrets = SecretsProviderFactory.make()
                let resolvedCredential = resolveMCPProviderCredential(
                    tool: routeTool,
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
                        tool: routeTool,
                        code: "E047",
                        message: "Choose which configured provider ProxyPilot should use."
                    )
                }
                let upstream = credential.provider
                let apiKey = credential.apiKey

                let modelResolution = await resolveProxyModelList(
                    tool: routeTool,
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
                        tool: routeTool,
                        code: "E049",
                        message: "No models could be resolved for \(upstream.rawValue)."
                    )
                }

                let modelList = resolvedModels.models
                let allowedModels: Set<String> = modelList.isEmpty ? [] : Set(modelList)
                let localProxyCredential = LocalProxyCredential.requiresAuthentication(
                    explicitlyRequired: false,
                    upstreamAPIKey: apiKey
                ) ? try LocalProxyCredential.resolveOrCreate(using: secrets) : nil
                if let localProxyCredential {
                    try XcodeConfigManager.synchronizeLocalProxyCredentialIfInstalled(localProxyCredential)
                }
                // Resolved per request, not frozen here: enabling MCP capture
                // while the proxy is already running must take effect without a
                // restart.
                let inputOutputLoggerCache = InputOutputLoggerSessionCache()
                let config = ProxyConfiguration(
                    port: reqPort,
                    upstreamProvider: upstream,
                    upstreamAPIBaseURL: reqURL,
                    upstreamAPIKey: apiKey,
                    masterKey: localProxyCredential,
                    allowedModels: allowedModels,
                    requiresAuth: localProxyCredential != nil,
                    preferredAnthropicUpstreamModel: modelList.first ?? "",
                    sessionStats: state.sessionStats,
                    googleThoughtSignatureStore: upstream == .google ? GoogleThoughtSignatureStore() : nil,
                    inputOutputLoggerProvider: inputOutputLoggerCache.provider(source: "mcp", sessionID: state.sessionID),
                    promptCaching: reqPromptCaching.configuration,
                    contextCompaction: contextCompaction.configuration()
                )

                let applyRoute: () async throws -> CallTool.Result = {
                    try await lifecycleGate.withLock {
                        let previousConfig = await state.currentConfiguration()
                        // Stop if running (ignore error if not running)
                        try? await state.stop()
                        let boundPort: UInt16
                        do {
                            boundPort = try await state.start(config: config)
                        } catch {
                            if let previousConfig {
                                _ = try? await state.start(config: previousConfig)
                            }
                            throw error
                        }
                        // Record the selection in the CLI-owned route store. Without
                        // this, `route status` keeps reporting the superseded route and
                        // `route ensure` restarts the daemon on it, silently reverting
                        // the change made here.
                        if isRouteSet, let selectedModel = reqModel {
                            do {
                                try RouteStateStore.save(
                                    RouteSelection(
                                        provider: upstream.rawValue,
                                        model: selectedModel,
                                        port: boundPort,
                                        updatedAt: Date()
                                    )
                                )
                            } catch {
                                return toolError(
                                    tool: routeTool,
                                    code: "E058",
                                    message: "Proxy restarted on \(upstream.rawValue) [\(selectedModel)], but the route could not be recorded: \(error).",
                                    suggestion: "Check that \(RouteStateStore.directory.path) is writable; otherwise `route ensure` may revert to the previous route."
                                )
                            }
                        }
                        let modelInfo = reqModel.map { " [\($0)]" }
                            ?? (resolvedModels.wasDiscoveredFromUpstream ? " [\(modelList.count) discovered model(s)]" : "")
                        let selectionInfo = credential.selectedFromStoredCredentials ? " (selected from stored provider keys)" : ""
                        let text = isRouteSet
                            ? "Route set to \(upstream.title)\(modelInfo) on port \(boundPort)\(selectionInfo). The downstream model remains \(ActiveModelAlias.id)."
                            : "ProxyPilot restarted on port \(boundPort) -> \(upstream.title)\(modelInfo)\(selectionInfo).\nCall xcode_config_install (port: \(boundPort)) to update Xcode routing."
                        return toolSuccess(
                            tool: routeTool,
                            data: ProxyLifecyclePayload(
                                status: "restarted",
                                port: Int(boundPort),
                                provider: upstream.rawValue,
                                model: reqModel
                            ),
                            text: text,
                            nextActions: [MCPXcodeConfigConsent.installNextAction(port: boundPort)]
                        )
                    }
                }

                do {
                    // Route changes additionally take the cross-process route.lock so a
                    // concurrent `proxypilot route set` (including the GUI, which shells
                    // out to it) cannot interleave with this one.
                    if isRouteSet {
                        return try await RouteStateStore.withExclusiveLock(applyRoute)
                    }
                    return try await applyRoute()
                } catch is RouteLockUnavailable {
                    return toolError(
                        tool: routeTool,
                        code: "E059",
                        message: "Another route switch is in progress.",
                        suggestion: "Retry once the in-flight route change completes."
                    )
                } catch {
                    return toolError(
                        tool: routeTool,
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
                guard MCPXcodeConfigConsent.environmentAllowsWrites else {
                    return toolError(
                        tool: "xcode_config_install",
                        code: "E052_XCODE_CONFIG_WRITE_NOT_ALLOWED",
                        message: "MCP Xcode config writes are disabled for this server session.",
                        suggestion: "Ask the user to run `proxypilot config install` themselves, or restart MCP with \(MCPXcodeConfigConsent.environmentVariable)=1 before retrying."
                    )
                }
                guard params.arguments?[MCPXcodeConfigConsent.argumentName]?.boolValue == true else {
                    return toolError(
                        tool: "xcode_config_install",
                        code: "E053_XCODE_CONFIG_WRITE_NOT_ALLOWED",
                        message: "xcode_config_install requires explicit per-call confirmation.",
                        suggestion: "After the user confirms this persistent Xcode routing change, retry with \(MCPXcodeConfigConsent.argumentName): true."
                    )
                }
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
                    let localProxyCredential = try LocalProxyCredential.resolveOrCreate(
                        using: SecretsProviderFactory.make()
                    )
                    let status = try XcodeConfigManager.install(
                        port: configPort,
                        localProxyCredential: localProxyCredential
                    )
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
                guard MCPXcodeConfigConsent.environmentAllowsWrites else {
                    return toolError(
                        tool: "xcode_config_remove",
                        code: "E052_XCODE_CONFIG_WRITE_NOT_ALLOWED",
                        message: "MCP Xcode config writes are disabled for this server session.",
                        suggestion: "Ask the user to run `proxypilot config remove` themselves, or restart MCP with \(MCPXcodeConfigConsent.environmentVariable)=1 before retrying."
                    )
                }
                guard params.arguments?[MCPXcodeConfigConsent.argumentName]?.boolValue == true else {
                    return toolError(
                        tool: "xcode_config_remove",
                        code: "E053_XCODE_CONFIG_WRITE_NOT_ALLOWED",
                        message: "xcode_config_remove requires explicit per-call confirmation.",
                        suggestion: "After the user confirms restoring direct Anthropic routing, retry with \(MCPXcodeConfigConsent.argumentName): true."
                    )
                }
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

                let baseURLValidation = MCPArgumentValidator.modelDiscoveryBaseURL(
                    reqURL,
                    provider: upstream,
                    tool: "list_upstream_models"
                )
                guard case .success(let baseURL) = baseURLValidation else {
                    if case .failure(let code, let message) = baseURLValidation {
                        return toolError(
                            tool: "list_upstream_models",
                            code: code,
                            message: message,
                            suggestion: "Omit url to use \(upstream.defaultAPIBaseURL), or choose an approved provider endpoint."
                        )
                    }
                    return toolError(tool: "list_upstream_models", code: "E036", message: "Invalid url argument.")
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

                // `state.sessionStats` only counts traffic served by a proxy running inside this
                // process. Whenever the proxy is a daemon or the GUI — the usual case — it stays
                // at zero. When the harness tells us which session we serve, aggregate the shared
                // session report instead, which every proxy writes to regardless of owner.
                if let attribution = ClientSessionEnvironment.attribution() {
                    let events = (try? SessionReportStore.readEvents()) ?? []
                    let telemetry = AttributedSessionTelemetry.aggregate(events: events, matching: attribution)
                    let dist = telemetry.models.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
                    let latency = telemetry.averageLatencyMs.map { "\($0)ms" } ?? "n/a"
                    let text = """
                    Session Stats (\(attribution.client) session \(attribution.sessionID)):
                      Requests: \(telemetry.requests)
                      Tokens: \(telemetry.totalTokens) (prompt: \(telemetry.promptTokens), completion: \(telemetry.completionTokens))
                      Avg Latency: \(latency)
                      Models: \(dist.isEmpty ? "none" : dist)
                    """
                    return toolSuccess(
                        tool: "get_session_stats",
                        data: SessionStatsToolPayload(
                            requests: telemetry.requests,
                            totalTokens: telemetry.totalTokens,
                            promptTokens: telemetry.promptTokens,
                            completionTokens: telemetry.completionTokens,
                            averageLatencyMs: telemetry.averageLatencyMs,
                            uptimeSeconds: snapshot.uptimeSeconds,
                            models: telemetry.models,
                            promptCacheHitTokens: telemetry.promptCacheHitTokens,
                            promptCacheMissTokens: telemetry.promptCacheMissTokens,
                            promptCacheWriteTokens: telemetry.promptCacheWriteTokens,
                            cacheHitRate: telemetry.cacheHitRate,
                            cacheAccountingAvailable: telemetry.cacheAccountingAvailable,
                            scope: .attributedSession,
                            attributed: true,
                            sessionID: attribution.sessionID,
                            source: attribution.client,
                            firstRequestAt: telemetry.firstRequestAt,
                            lastRequestAt: telemetry.lastRequestAt
                        ),
                        text: text
                    )
                }

                let dist = snapshot.modelDistribution.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
                let latency = snapshot.avgLatencyMs.map { "\($0)ms" } ?? "n/a"
                let text = """
                Session Stats (proxy running in this MCP process only):
                  Requests: \(snapshot.totalRequests)
                  Tokens: \(snapshot.totalTokens) (prompt: \(snapshot.totalPromptTokens), completion: \(snapshot.totalCompletionTokens))
                  Avg Latency: \(latency)
                  Uptime: \(snapshot.uptimeSeconds)s
                  Models: \(dist.isEmpty ? "none" : dist)
                """
                // Zero here means "nothing was served by this process", which is not the same as
                // "no traffic". Point the caller at the tool that can tell the difference.
                let unattributedNextActions: [NextAction] = snapshot.totalRequests == 0
                    ? [NextAction(
                        id: "list_recorded_sessions",
                        kind: .mcpTool,
                        tool: "get_session_history",
                        message: "This process serves no proxy, so these counters stay at zero. Use get_session_history to see recorded sessions and their real usage.",
                        destructive: false
                      )]
                    : []
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
                        cacheAccountingAvailable: snapshot.cacheAccountingAvailable,
                        scope: .inProcessProxy,
                        attributed: false,
                        sessionID: nil,
                        source: nil,
                        firstRequestAt: nil,
                        lastRequestAt: nil
                    ),
                    text: text,
                    nextActions: unattributedNextActions
                )

            case "get_session_history":
                let sessionIDArgument = stringArgument(params.arguments, name: "session_id", default: nil, tool: "get_session_history")
                if let error = sessionIDArgument.error { return error }

                let includeLogsValidation = MCPArgumentValidator.bool(
                    params.arguments?["include_logs"],
                    default: false,
                    name: "include_logs",
                    tool: "get_session_history"
                )
                guard case .success(let includeLogs) = includeLogsValidation else {
                    if case .failure(let code, let message) = includeLogsValidation {
                        return toolError(tool: "get_session_history", code: code, message: message)
                    }
                    return toolError(tool: "get_session_history", code: "E035", message: "Invalid include_logs argument.")
                }

                let sessionEvents = (try? SessionReportStore.readEvents()) ?? []

                if let sessionID = sessionIDArgument.value {
                    // Case-insensitive: stored IDs are mixed-case (daemon vs.
                    // attributed sessions), same as `sessions show`.
                    let matching = sessionEvents.filter { $0.sessionID.caseInsensitiveCompare(sessionID) == .orderedSame }
                    guard let summary = SessionSummaryPayload.build(from: matching).first else {
                        return toolError(
                            tool: "get_session_history",
                            code: "E060",
                            message: "No recorded session found with ID '\(sessionID)'.",
                            suggestion: "Call get_session_history without session_id to see recorded session IDs."
                        )
                    }
                    let requests = matching.sorted { $0.record.timestamp < $1.record.timestamp }.map(\.record)

                    var logs: [InputOutputLogRecord]?
                    if includeLogs {
                        guard MCPIOSessionLogConsent.environmentAllowsReads else {
                            return toolError(
                                tool: "get_session_history",
                                code: "E061_IO_LOG_READ_NOT_ALLOWED",
                                message: "MCP input/output log reads are disabled for this server session.",
                                suggestion: "Ask the user to export logs from the ProxyPilot app or CLI, or restart MCP with \(MCPIOSessionLogConsent.environmentVariable)=1 before retrying with explicit per-call consent."
                            )
                        }
                        guard params.arguments?[MCPIOSessionLogConsent.argumentName]?.boolValue == true else {
                            return toolError(
                                tool: "get_session_history",
                                code: "E062_IO_LOG_READ_NOT_ALLOWED",
                                message: "get_session_history include_logs requires explicit per-call confirmation.",
                                suggestion: "After the user confirms exposing decrypted prompts and outputs for this session, retry with \(MCPIOSessionLogConsent.argumentName): true."
                            )
                        }
                        if let recorder = try? InputOutputLoggingRecorder.productionIfKeyExists(source: "mcp") {
                            try? await recorder.pruneExpired()
                            logs = (try? await recorder.readRecords(matchingSessionID: sessionID)) ?? []
                        } else {
                            logs = []
                        }
                    }

                    let logsSuffix = logs.map { ", \($0.count) input/output log record(s)" } ?? ""
                    return toolSuccess(
                        tool: "get_session_history",
                        data: SessionDetailPayload(summary: summary, requests: requests, logs: logs),
                        text: "Session \(summary.id): \(summary.requestCount) request(s), \(summary.totalTokens) tokens\(logsSuffix)"
                    )
                } else {
                    let summaries = SessionSummaryPayload.build(from: sessionEvents)
                    return toolSuccess(
                        tool: "get_session_history",
                        data: SessionsListPayload(sessions: summaries),
                        text: summaries.isEmpty ? "No recorded sessions yet." : "\(summaries.count) recorded session(s)."
                    )
                }

            case "proxy_logs":
                let lineCountValidation = MCPArgumentValidator.lineCount(
                    params.arguments?["lines"],
                    default: 75,
                    name: "lines",
                    tool: "proxy_logs"
                )
                guard case .success(let lineCount) = lineCountValidation else {
                    if case .failure(let code, let message) = lineCountValidation {
                        return toolError(tool: "proxy_logs", code: code, message: message)
                    }
                    return toolError(tool: "proxy_logs", code: "E036", message: "Invalid lines argument.")
                }
                let logURL = LogReader.defaultLogURL
                let logLines = LogReader.tail(url: logURL, lines: lineCount, redact: true)

                // This file is written only by the GUI's built-in proxy, and it is never rotated
                // per session — a CLI daemon or a test run leaves lines here that belong to
                // neither the caller nor the present moment. Ship provenance with the lines so a
                // reader cannot mistake someone else's stale entries for its own live route.
                let lastModified = try? logURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let ageSeconds = lastModified.map { Int(Date().timeIntervalSince($0)) }
                let attribution = ClientSessionEnvironment.attribution()

                var provenance = "Source: \(logURL.path) (written by the GUI built-in proxy only)."
                if let ageSeconds {
                    provenance += " Last written \(ageSeconds)s ago."
                }
                if let attribution {
                    provenance += " These lines are NOT scoped to \(attribution.client) session \(attribution.sessionID);"
                        + " use get_session_stats for this session's actual usage."
                }

                var nextActions: [NextAction] = []
                if attribution != nil {
                    nextActions.append(NextAction(
                        id: "attributed_session_stats",
                        kind: .mcpTool,
                        tool: "get_session_stats",
                        message: "Report this session's real model usage instead of inferring it from shared log lines.",
                        destructive: false
                    ))
                }

                if logLines.isEmpty {
                    return toolSuccess(
                        tool: "proxy_logs",
                        data: ProxyLogsToolPayload(
                            lines: [],
                            path: logURL.path,
                            lastModified: lastModified,
                            ageSeconds: ageSeconds,
                            writtenBy: "gui_builtin_proxy",
                            coversCurrentSession: false
                        ),
                        text: "No log output from the GUI built-in proxy. \(provenance)",
                        nextActions: nextActions
                    )
                }

                return toolSuccess(
                    tool: "proxy_logs",
                    data: ProxyLogsToolPayload(
                        lines: logLines,
                        path: logURL.path,
                        lastModified: lastModified,
                        ageSeconds: ageSeconds,
                        writtenBy: "gui_builtin_proxy",
                        coversCurrentSession: false
                    ),
                    text: provenance + "\n\n" + logLines.joined(separator: "\n"),
                    nextActions: nextActions
                )

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
        case .invalidUpstreamURL(let provider, let url, let reason):
            return (nil, toolError(
                tool: tool,
                code: "E050",
                message: "Invalid upstream URL override for provider \(provider.rawValue): \(url)",
                suggestion: reason
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
        guard let secretKey = provider.secretKey else {
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
            status: exists ? "stored" : (provider.requiresAPIKey ? "not_set" : "optional"),
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
