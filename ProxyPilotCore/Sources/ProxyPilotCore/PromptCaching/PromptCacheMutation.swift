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
