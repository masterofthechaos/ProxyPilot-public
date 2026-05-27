import CryptoKit
import Foundation

public enum PromptCacheSessionKey {
    /// Derives a stable, opaque cache key for a session.
    /// Never includes raw prompt text, API keys, local file paths, or user message content.
    public static func make(
        provider: String,
        model: String,
        sessionID: String,
        route: String
    ) -> String {
        let seed = "proxypilot:\(provider):\(model):\(sessionID):\(route)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(24).description
    }

    /// Returns a bucket-rotated key to stay under provider ~15 RPM overflow thresholds.
    /// Spreads load across buckets while preserving per-session locality.
    public static func bucketed(
        provider: String,
        model: String,
        sessionID: String,
        route: String,
        bucketCount: Int = 3
    ) -> String {
        let base = make(provider: provider, model: model, sessionID: sessionID, route: route)
        let bucketSeed = Int(base.suffix(2), radix: 16) ?? 0
        let bucket = bucketSeed % max(bucketCount, 1) + 1
        return "\(base)_\(bucket)"
    }
}
