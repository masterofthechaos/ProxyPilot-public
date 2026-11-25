import Foundation

/// How long a proxy engine waits for a provider before giving up.
///
/// Both engines read their limits from here. A local model can take many
/// minutes to read a large prompt before its first token, so it gets a long
/// no-data limit and no total limit of ProxyPilot's own.
public struct UpstreamWaitPolicy: Sendable, Equatable {
    /// Longest wait without receiving any data.
    public let idle: TimeInterval
    /// Longest time for the whole response. Nil leaves the system default.
    public let total: TimeInterval?

    public init(idle: TimeInterval, total: TimeInterval?) {
        self.idle = idle
        self.total = total
    }

    /// A provider running on this machine, in either engine.
    public static let local = UpstreamWaitPolicy(idle: 1800, total: nil)
    /// A cloud provider through the app's built-in proxy.
    public static let appCloud = UpstreamWaitPolicy(idle: 120, total: nil)
    /// A cloud provider through the Core engine the CLI runs.
    public static let coreCloud = UpstreamWaitPolicy(idle: 30, total: 300)

    /// Whether the provider runs on this machine's hardware.
    public static func isLocal(provider: UpstreamProvider, baseURL: String) -> Bool {
        provider.isLocal || isLocalhostURL(baseURL)
    }
}
