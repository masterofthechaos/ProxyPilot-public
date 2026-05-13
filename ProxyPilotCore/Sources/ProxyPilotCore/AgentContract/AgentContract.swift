import Foundation

public struct AgentEnvelope<Payload: Encodable>: Encodable {
    public let ok: Bool
    public let schemaVersion: Int
    public let command: String?
    public let tool: String?
    public let data: Payload?
    public let error: AgentError?
    public let nextActions: [NextAction]

    enum CodingKeys: String, CodingKey {
        case ok
        case schemaVersion = "schema_version"
        case command
        case tool
        case data
        case error
        case nextActions = "next_actions"
    }

    public init(command: String, data: Payload, nextActions: [NextAction] = []) {
        self.ok = true
        self.schemaVersion = 1
        self.command = command
        self.tool = nil
        self.data = data
        self.error = nil
        self.nextActions = nextActions
    }

    public init(tool: String, data: Payload, nextActions: [NextAction] = []) {
        self.ok = true
        self.schemaVersion = 1
        self.command = nil
        self.tool = tool
        self.data = data
        self.error = nil
        self.nextActions = nextActions
    }
}

public struct AgentErrorEnvelope: Encodable {
    public let ok: Bool
    public let schemaVersion: Int
    public let command: String?
    public let tool: String?
    public let error: AgentError
    public let nextActions: [NextAction]

    enum CodingKeys: String, CodingKey {
        case ok
        case schemaVersion = "schema_version"
        case command
        case tool
        case error
        case nextActions = "next_actions"
    }

    public init(command: String, error: AgentError, nextActions: [NextAction] = []) {
        self.ok = false
        self.schemaVersion = 1
        self.command = command
        self.tool = nil
        self.error = error
        self.nextActions = nextActions
    }

    public init(tool: String, error: AgentError, nextActions: [NextAction] = []) {
        self.ok = false
        self.schemaVersion = 1
        self.command = nil
        self.tool = tool
        self.error = error
        self.nextActions = nextActions
    }
}

public struct AgentError: Encodable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let suggestion: String?
    public let recoverable: Bool

    public init(code: String, message: String, suggestion: String? = nil, recoverable: Bool) {
        self.code = code
        self.message = message
        self.suggestion = suggestion
        self.recoverable = recoverable
    }
}

public struct NextAction: Encodable, Equatable, Sendable {
    public enum Kind: String, Encodable, Sendable {
        case cli
        case mcpTool = "mcp_tool"
        case user
    }

    public let id: String
    public let kind: Kind
    public let command: String?
    public let tool: String?
    public let arguments: [String: NextActionValue]?
    public let message: String?
    public let destructive: Bool

    public init(
        id: String,
        kind: Kind,
        command: String? = nil,
        tool: String? = nil,
        arguments: [String: NextActionValue]? = nil,
        message: String? = nil,
        destructive: Bool
    ) {
        self.id = id
        self.kind = kind
        self.command = command
        self.tool = tool
        self.arguments = arguments
        self.message = message
        self.destructive = destructive
    }
}

public enum NextActionValue: Encodable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        }
    }
}

public enum AgentJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

public struct StatusPayload: Encodable, Equatable, Sendable {
    public struct ProcessState: Encodable, Equatable, Sendable {
        public let managed: Bool
        public let pid: Int?
        public let owner: String?

        public init(managed: Bool, pid: Int?, owner: String? = nil) {
            self.managed = managed
            self.pid = pid
            self.owner = owner
        }
    }

    public struct HTTPState: Encodable, Equatable, Sendable {
        public let reachable: Bool
        public let port: Int
        public let modelsCount: Int?
        public let errorMessage: String?

        enum CodingKeys: String, CodingKey {
            case reachable
            case port
            case modelsCount = "models_count"
            case errorMessage = "error"
        }

        public init(reachable: Bool, port: Int, modelsCount: Int?, errorMessage: String? = nil) {
            self.reachable = reachable
            self.port = port
            self.modelsCount = modelsCount
            self.errorMessage = errorMessage
        }
    }

    public let running: Bool
    public let process: ProcessState
    public let http: HTTPState
    public let effectiveStatus: String

    enum CodingKeys: String, CodingKey {
        case running
        case process
        case http
        case effectiveStatus = "effective_status"
    }

    public init(running: Bool, process: ProcessState, http: HTTPState, effectiveStatus: String) {
        self.running = running
        self.process = process
        self.http = http
        self.effectiveStatus = effectiveStatus
    }
}

public struct ProviderAuthPayload: Encodable, Equatable, Sendable {
    public let provider: String
    public let status: String
    public let stored: Bool
    public let backend: String
    public let path: String?
    public let verified: Bool?
    public let verificationStatus: String?
    public let verificationError: String?
    public let modelCount: Int?

    enum CodingKeys: String, CodingKey {
        case provider
        case status
        case stored
        case backend
        case path
        case verified
        case verificationStatus = "verification_status"
        case verificationError = "verification_error"
        case modelCount = "model_count"
    }

    public init(
        provider: String,
        status: String,
        stored: Bool,
        backend: String,
        path: String? = nil,
        verified: Bool? = nil,
        verificationStatus: String? = nil,
        verificationError: String? = nil,
        modelCount: Int? = nil
    ) {
        self.provider = provider
        self.status = status
        self.stored = stored
        self.backend = backend
        self.path = path
        self.verified = verified
        self.verificationStatus = verificationStatus
        self.verificationError = verificationError
        self.modelCount = modelCount
    }
}

public struct ProvidersAuthPayload: Encodable, Equatable, Sendable {
    public let providers: [ProviderAuthPayload]
    public let path: String?

    public init(providers: [ProviderAuthPayload], path: String? = nil) {
        self.providers = providers
        self.path = path
    }
}

public struct ModelSummary: Encodable, Equatable, Sendable {
    public struct CapabilityConfidence: Encodable, Equatable, Sendable {
        public let supported: Bool
        public let confidence: String

        public init(supported: Bool, confidence: String) {
            self.supported = supported
            self.confidence = confidence
        }
    }

    public let id: String
    public let contextLength: Int?
    public let pricingTier: String
    public let capabilities: [String]
    public let verified: Bool
    public let exactoEligible: Bool
    public let recommendedForXcodeAgent: Bool
    public let toolCalling: CapabilityConfidence

    enum CodingKeys: String, CodingKey {
        case id
        case contextLength = "context_length"
        case pricingTier = "pricing_tier"
        case capabilities
        case verified
        case exactoEligible = "exacto_eligible"
        case recommendedForXcodeAgent = "recommended_for_xcode_agent"
        case toolCalling = "tool_calling"
    }

    public init(
        id: String,
        contextLength: Int?,
        pricingTier: String,
        capabilities: [String],
        verified: Bool,
        exactoEligible: Bool,
        recommendedForXcodeAgent: Bool,
        toolCalling: CapabilityConfidence
    ) {
        self.id = id
        self.contextLength = contextLength
        self.pricingTier = pricingTier
        self.capabilities = capabilities
        self.verified = verified
        self.exactoEligible = exactoEligible
        self.recommendedForXcodeAgent = recommendedForXcodeAgent
        self.toolCalling = toolCalling
    }
}

public struct AgentPreflightPayload: Encodable, Equatable, Sendable {
    public struct AuthState: Encodable, Equatable, Sendable {
        public let required: Bool
        public let stored: Bool
        public let provider: String

        public init(required: Bool, stored: Bool, provider: String) {
            self.required = required
            self.stored = stored
            self.provider = provider
        }
    }

    public struct ProxyState: Encodable, Equatable, Sendable {
        public let running: Bool
        public let port: Int
        public let effectiveStatus: String
        public let errorMessage: String?

        enum CodingKeys: String, CodingKey {
            case running
            case port
            case effectiveStatus = "effective_status"
            case errorMessage = "error"
        }

        public init(running: Bool, port: Int, effectiveStatus: String, errorMessage: String? = nil) {
            self.running = running
            self.port = port
            self.effectiveStatus = effectiveStatus
            self.errorMessage = errorMessage
        }
    }

    public struct XcodeConfigState: Encodable, Equatable, Sendable {
        public let installed: Bool
        public let baseURL: String?
        public let requiresXcodeRestart: Bool

        enum CodingKeys: String, CodingKey {
            case installed
            case baseURL = "base_url"
            case requiresXcodeRestart = "requires_xcode_restart"
        }

        public init(installed: Bool, baseURL: String?, requiresXcodeRestart: Bool) {
            self.installed = installed
            self.baseURL = baseURL
            self.requiresXcodeRestart = requiresXcodeRestart
        }
    }

    public let ready: Bool
    public let provider: String
    public let model: String?
    public let auth: AuthState
    public let proxy: ProxyState
    public let xcodeConfig: XcodeConfigState
    public let blockers: [AgentError]

    enum CodingKeys: String, CodingKey {
        case ready
        case provider
        case model
        case auth
        case proxy
        case xcodeConfig = "xcode_config"
        case blockers
    }

    public init(
        ready: Bool,
        provider: String,
        model: String?,
        auth: AuthState,
        proxy: ProxyState,
        xcodeConfig: XcodeConfigState,
        blockers: [AgentError]
    ) {
        self.ready = ready
        self.provider = provider
        self.model = model
        self.auth = auth
        self.proxy = proxy
        self.xcodeConfig = xcodeConfig
        self.blockers = blockers
    }
}

public struct RoutingVerificationPayload: Encodable, Equatable, Sendable {
    public let localModelsReachable: Bool
    public let modelsCount: Int?
    public let localModelsError: String?
    public let xcodeConfigInstalled: Bool
    public let configuredBaseURL: String?
    public let portMatchesConfig: Bool
    public let upstreamProbePerformed: Bool

    enum CodingKeys: String, CodingKey {
        case localModelsReachable = "local_models_reachable"
        case modelsCount = "models_count"
        case localModelsError = "local_models_error"
        case xcodeConfigInstalled = "xcode_config_installed"
        case configuredBaseURL = "configured_base_url"
        case portMatchesConfig = "port_matches_config"
        case upstreamProbePerformed = "upstream_probe_performed"
    }

    public init(
        localModelsReachable: Bool,
        modelsCount: Int?,
        localModelsError: String? = nil,
        xcodeConfigInstalled: Bool,
        configuredBaseURL: String?,
        portMatchesConfig: Bool,
        upstreamProbePerformed: Bool
    ) {
        self.localModelsReachable = localModelsReachable
        self.modelsCount = modelsCount
        self.localModelsError = localModelsError
        self.xcodeConfigInstalled = xcodeConfigInstalled
        self.configuredBaseURL = configuredBaseURL
        self.portMatchesConfig = portMatchesConfig
        self.upstreamProbePerformed = upstreamProbePerformed
    }
}
