import Foundation

/// A single proxy request record for session tracking.
public struct RequestRecord: Sendable, Codable, Equatable {
    public let timestamp: Date
    public let model: String
    public let requestedModel: String?
    public let providerReportedCostUSD: Double?
    public let promptTokens: Int
    public let completionTokens: Int
    public let promptCacheHitTokens: Int?
    public let promptCacheMissTokens: Int?
    public let promptCacheWriteTokens: Int?
    public let durationSeconds: TimeInterval
    public let path: String
    public let wasStreaming: Bool
    /// Provider identity is intentionally stored separately from `model` so
    /// privacy-preserving analytics can inventory provider pathways without
    /// ever transmitting a specific model slug.
    public let providerIdentifier: String?
    public let promptCachingMode: String?
    public let contextCompactionEnabled: Bool?
    public let translationMode: String?

    public init(
        timestamp: Date = Date(),
        model: String,
        requestedModel: String? = nil,
        providerReportedCostUSD: Double? = nil,
        promptTokens: Int,
        completionTokens: Int,
        promptCacheHitTokens: Int? = nil,
        promptCacheMissTokens: Int? = nil,
        promptCacheWriteTokens: Int? = nil,
        durationSeconds: TimeInterval,
        path: String,
        wasStreaming: Bool,
        providerIdentifier: String? = nil,
        promptCachingMode: String? = nil,
        contextCompactionEnabled: Bool? = nil,
        translationMode: String? = nil
    ) {
        self.timestamp = timestamp
        self.model = model
        self.requestedModel = requestedModel
        self.providerReportedCostUSD = providerReportedCostUSD
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.promptCacheHitTokens = promptCacheHitTokens
        self.promptCacheMissTokens = promptCacheMissTokens
        self.promptCacheWriteTokens = promptCacheWriteTokens
        self.durationSeconds = durationSeconds
        self.path = path
        self.wasStreaming = wasStreaming
        self.providerIdentifier = providerIdentifier
        self.promptCachingMode = promptCachingMode
        self.contextCompactionEnabled = contextCompactionEnabled
        self.translationMode = translationMode
    }
}
