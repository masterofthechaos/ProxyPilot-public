import Foundation

public enum ProxyPilotDefaults {
    public static let defaultCLIProvider: UpstreamProvider = .openAI
    public static let defaultXcodeProvider: UpstreamProvider = .zAI
    public static let defaultPort: UInt16 = 4000

    public static var providerOptionsDescription: String {
        UpstreamProvider.allCases.map(\.rawValue).joined(separator: ", ")
    }
}

public extension UpstreamProvider {
    var defaultAgentModel: String? {
        switch self {
        case .zAI:
            return "glm-4.7"
        case .githubCopilot, .miniMax, .miniMaxCN:
            return fallbackModelIDs?.first
        default:
            return nil
        }
    }

    static var cliOptionsDescription: String {
        ProxyPilotDefaults.providerOptionsDescription
    }
}
