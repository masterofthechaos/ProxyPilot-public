import Foundation

/// A single proxy request record for session tracking.
public struct RequestRecord: Sendable, Codable, Equatable {
    public let timestamp: Date
    public let model: String
    public let promptTokens: Int
    public let completionTokens: Int
    public let promptCacheHitTokens: Int?
    public let promptCacheMissTokens: Int?
    public let durationSeconds: TimeInterval
    public let path: String
    public let wasStreaming: Bool

    public init(
        timestamp: Date = Date(),
        model: String,
        promptTokens: Int,
        completionTokens: Int,
        promptCacheHitTokens: Int? = nil,
        promptCacheMissTokens: Int? = nil,
        durationSeconds: TimeInterval,
        path: String,
        wasStreaming: Bool
    ) {
        self.timestamp = timestamp
        self.model = model
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.promptCacheHitTokens = promptCacheHitTokens
        self.promptCacheMissTokens = promptCacheMissTokens
        self.durationSeconds = durationSeconds
        self.path = path
        self.wasStreaming = wasStreaming
    }
}
