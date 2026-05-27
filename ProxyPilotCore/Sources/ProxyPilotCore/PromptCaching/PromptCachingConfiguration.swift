import Foundation

public struct PromptCachingConfiguration: Sendable, Codable, Equatable {
    public var isEnabled: Bool
    public var mode: PromptCachingMode
    public var retention: PromptCacheRetention
    public var canonicalizeJSONForCache: Bool

    public init(
        isEnabled: Bool = true,
        mode: PromptCachingMode = .computeCacheHints,
        retention: PromptCacheRetention = .providerDefault,
        canonicalizeJSONForCache: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.mode = mode
        self.retention = retention
        self.canonicalizeJSONForCache = canonicalizeJSONForCache
    }

    public static let `default` = PromptCachingConfiguration()

    public var recordsProviderCacheTelemetry: Bool {
        isEnabled && mode != .off
    }
}

public enum PromptCachingMode: String, Sendable, Codable, CaseIterable, Hashable {
    case off
    case observeOnly
    case computeCacheHints
    case explicitReferenceCache
}

public enum PromptCacheRetention: String, Sendable, Codable, CaseIterable {
    case providerDefault
    case short
    case oneHour
    case twentyFourHours
}
