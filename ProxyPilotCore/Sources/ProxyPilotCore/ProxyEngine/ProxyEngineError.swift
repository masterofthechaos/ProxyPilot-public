import Foundation

public enum ProxyEngineError: Error, CustomStringConvertible, LocalizedError, Sendable {
    case bindFailed(String)
    case alreadyRunning
    case notRunning
    case invalidUpstreamURL

    public var description: String {
        errorDescription ?? String(describing: self)
    }

    public var errorDescription: String? {
        switch self {
        case .bindFailed(let message):
            "Bind failed: \(message)"
        case .alreadyRunning:
            "Proxy is already running."
        case .notRunning:
            "Proxy is not running."
        case .invalidUpstreamURL:
            "Invalid upstream URL."
        }
    }
}
