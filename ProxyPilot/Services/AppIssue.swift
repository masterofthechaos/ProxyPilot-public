import Foundation

struct AppIssue: Identifiable, Equatable, Error {
    enum Code: String, Codable {
        case missingMasterKey = "E001"
        case missingUpstreamKey = "E002"
        case invalidProxyURL = "E003"
        case invalidPortRange = "E004"
        case portInUse = "E005"
        case upstreamUnauthorized = "E006"
        case upstreamTimeout = "E007"
        case requestTooLarge = "E008"
        case generic = "E999"
    }

    enum Action: String, Identifiable, Codable, CaseIterable {
        case openMasterKeyEditor
        case openUpstreamKeyEditor
        case resetProxyURL
        case setProxyURLTo4001
        case useBuiltInProxy
        case resetUpstreamURL
        case runPreflight
        case retryStart
        case exportDiagnostics
        case openReadme
        case openWebsite

        var id: String { rawValue }

        var title: String {
            switch self {
            case .openMasterKeyEditor:
                return String(localized: "Set Local Proxy Password")
            case .openUpstreamKeyEditor:
                return String(localized: "Set Upstream API Key")
            case .resetProxyURL:
                return String(localized: "Reset Proxy URL")
            case .setProxyURLTo4001:
                return String(localized: "Use Port 4001")
            case .useBuiltInProxy:
                return String(localized: "Use Built-In Proxy")
            case .resetUpstreamURL:
                return String(localized: "Reset Upstream URL")
            case .runPreflight:
                return String(localized: "Run Preflight")
            case .retryStart:
                return String(localized: "Retry Start")
            case .exportDiagnostics:
                return String(localized: "Export Diagnostics")
            case .openReadme:
                return String(localized: "Open README")
            case .openWebsite:
                return String(localized: "Open micah.chat")
            }
        }
    }

    let code: Code
    let title: String
    let message: String
    let actions: [Action]

    var id: String {
        "\(code.rawValue)-\(title)-\(message)"
    }
}
