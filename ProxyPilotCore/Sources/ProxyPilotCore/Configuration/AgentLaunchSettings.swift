import Foundation

/// Persisted snapshot of the user's current proxy selection, shared between
/// the GUI app, the CLI, and the headless ACP launcher (`proxypilot-agent`).
///
/// The launcher is argument-free by design (its Xcode registration must never
/// go stale), so it cannot receive the port or model via flags. Instead, the
/// GUI/CLI write this file whenever the user's selection changes, and the
/// launcher reads it at spawn time. The proxy daemon itself remains the source
/// of truth for live upstream routing; this file only carries what the
/// launcher needs before the daemon is reachable.
///
/// Stored at `$XDG_CONFIG_HOME/proxypilot/current-selection.json`
/// (or `~/.config/proxypilot/current-selection.json`), beside the CLI's
/// PID file. Unknown JSON keys are ignored on read so newer writers can add
/// fields without breaking older readers.
public struct AgentLaunchSettings: Codable, Equatable, Sendable {
    public enum PromptCachingMode: String, Codable, Equatable, Sendable {
        case auto
        case observeOnly = "observe-only"
        case off
    }

    /// Schema version for forward compatibility. Bump on breaking change.
    public var schema: Int
    /// Local proxy port the launcher should probe/start and route to.
    public var port: UInt16
    /// Selected model hint for launch telemetry. The engine uses the active-route alias.
    /// Stale values are harmless: live model routing happens at the proxy.
    public var modelID: String?
    /// Human-readable upstream label, for launch telemetry/logging only.
    /// Never used for routing decisions.
    public var upstreamLabel: String?
    /// Built-in provider identifier used when a cold launcher must start the CLI daemon.
    public var providerID: String?
    /// Optional upstream base override used for daemon cold starts.
    public var upstreamURL: String?
    /// Keychain account reference used for custom-provider cold starts.
    /// The credential itself is never written to this file.
    public var credentialKey: String?
    public var promptCachingMode: PromptCachingMode
    /// Whether Active Context Compaction is enabled. Added as an optional
    /// key without a schema bump: older readers ignore unknown keys, and a
    /// schema bump would make them reject the whole file (`resolve()`
    /// requires `schema <= currentSchema`).
    public var contextCompactionEnabled: Bool
    /// Advertised capabilities for the selected model; absent in older saved settings.
    public var modelMetadata: UpstreamModel?

    public static let currentSchema = 3

    public init(
        schema: Int = AgentLaunchSettings.currentSchema,
        port: UInt16 = ProxyPilotDefaults.defaultPort,
        modelID: String? = nil,
        upstreamLabel: String? = nil,
        providerID: String? = nil,
        upstreamURL: String? = nil,
        credentialKey: String? = nil,
        promptCachingMode: PromptCachingMode = .auto,
        contextCompactionEnabled: Bool = false,
        modelMetadata: UpstreamModel? = nil
    ) {
        self.schema = schema
        self.port = port
        self.modelID = modelID
        self.upstreamLabel = upstreamLabel
        self.providerID = providerID
        self.upstreamURL = upstreamURL
        self.credentialKey = credentialKey
        self.promptCachingMode = promptCachingMode
        self.contextCompactionEnabled = contextCompactionEnabled
        self.modelMetadata = modelMetadata
    }

    private enum CodingKeys: String, CodingKey {
        case schema, port, modelID, upstreamLabel, providerID, upstreamURL, credentialKey
        case promptCachingMode
        case contextCompactionEnabled, modelMetadata
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        modelMetadata = try values.decodeIfPresent(UpstreamModel.self, forKey: .modelMetadata)
        schema = try values.decode(Int.self, forKey: .schema)
        port = try values.decode(UInt16.self, forKey: .port)
        modelID = try values.decodeIfPresent(String.self, forKey: .modelID)
        upstreamLabel = try values.decodeIfPresent(String.self, forKey: .upstreamLabel)
        providerID = try values.decodeIfPresent(String.self, forKey: .providerID)
        upstreamURL = try values.decodeIfPresent(String.self, forKey: .upstreamURL)
        credentialKey = try values.decodeIfPresent(String.self, forKey: .credentialKey)
        promptCachingMode = try values.decodeIfPresent(
            PromptCachingMode.self,
            forKey: .promptCachingMode
        ) ?? .auto
        contextCompactionEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .contextCompactionEnabled
        ) ?? false
    }

    // MARK: - Storage location

    /// Directory resolution mirrors `PidFile` in the CLI: honor
    /// `XDG_CONFIG_HOME`, fall back to `~/.config`.
    public static func storageURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let configDir: URL
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            configDir = URL(fileURLWithPath: xdg).appendingPathComponent("proxypilot")
        } else {
            configDir = home
                .appendingPathComponent(".config")
                .appendingPathComponent("proxypilot")
        }
        return configDir.appendingPathComponent("current-selection.json")
    }

    // MARK: - Read

    /// Reads the persisted selection, falling back to defaults when the file
    /// is missing, unreadable, or from an incompatible schema. Never throws:
    /// the launcher must always be able to start with sane defaults.
    public static func resolve(from url: URL? = nil) -> AgentLaunchSettings {
        let location = url ?? storageURL()
        guard let data = try? Data(contentsOf: location),
              let decoded = try? JSONDecoder().decode(AgentLaunchSettings.self, from: data),
              decoded.schema <= currentSchema,
              decoded.port > 0
        else {
            return AgentLaunchSettings()
        }
        return decoded
    }

    // MARK: - Write

    /// Atomically persists the selection, creating the directory if needed.
    /// File is owner-only: it may carry a model identifier, and the config
    /// directory convention (PID file, daemon logs) is already 0600/0700-style.
    public func save(to url: URL? = nil) throws {
        let location = url ?? Self.storageURL()
        let directory = location.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: location, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: location.path
        )
    }
}
