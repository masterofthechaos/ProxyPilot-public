import Foundation

public enum ProxyEngineError: Error, Sendable {
    case bindFailed
    case alreadyRunning
    case notRunning
}
