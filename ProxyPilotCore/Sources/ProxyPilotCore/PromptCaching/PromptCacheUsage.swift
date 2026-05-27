import Foundation

public struct PromptCacheUsage: Sendable, Equatable {
    public var cacheHitTokens: Int
    public var cacheMissTokens: Int
    public var cacheWriteTokens: Int

    public init(
        cacheHitTokens: Int = 0,
        cacheMissTokens: Int = 0,
        cacheWriteTokens: Int = 0
    ) {
        self.cacheHitTokens = cacheHitTokens
        self.cacheMissTokens = cacheMissTokens
        self.cacheWriteTokens = cacheWriteTokens
    }

    public var totalCachedTokens: Int { cacheHitTokens }
    public var hitRate: Double? {
        let total = cacheHitTokens + cacheMissTokens
        guard total > 0 else { return nil }
        return Double(cacheHitTokens) / Double(total)
    }
}
