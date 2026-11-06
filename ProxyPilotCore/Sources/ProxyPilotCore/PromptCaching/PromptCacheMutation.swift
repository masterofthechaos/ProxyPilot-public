import Foundation

public struct PromptCacheMutation: Sendable {
    public var body: Data
    public var headers: [(String, String)]
    public var applied: Bool
    public var strategy: String
    public var notes: [String]

    public init(
        body: Data,
        headers: [(String, String)] = [],
        applied: Bool,
        strategy: String,
        notes: [String] = []
    ) {
        self.body = body
        self.headers = headers
        self.applied = applied
        self.strategy = strategy
        self.notes = notes
    }

    public static func passThrough(body: Data, headers: [(String, String)] = []) -> PromptCacheMutation {
        PromptCacheMutation(body: body, headers: headers, applied: false, strategy: "none")
    }
}

/// Request-scoped observation shared by the forwarding and accounting paths.
/// Holds only adapter metadata, never prompt bodies or credentials.
public final class PromptCacheRequestContext: @unchecked Sendable {
    @TaskLocal public static var current: PromptCacheRequestContext?
    public let incomingSessionHeader: String?
    private let lock = NSLock()
    private var recordedOutcome: (strategy: String, applied: Bool)?

    public init(incomingSessionHeader: String? = nil) {
        self.incomingSessionHeader = incomingSessionHeader
    }

    public var outcome: (strategy: String, applied: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        return recordedOutcome
    }

    public func record(_ mutation: PromptCacheMutation) {
        lock.lock()
        defer { lock.unlock() }
        recordedOutcome = (mutation.strategy, mutation.applied)
    }

    public static func sessionID(fallback: String) -> String {
        RequestAttributionContext.current?.sessionID ?? fallback
    }
}
