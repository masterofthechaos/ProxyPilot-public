import ArgumentParser
import Foundation
import ProxyPilotCore

enum CLIPromptCachingMode: String, CaseIterable, ExpressibleByArgument {
    case auto
    case observeOnly = "observe-only"
    case off

    init?(argument: String) {
        switch argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "auto":
            self = .auto
        case "observe-only", "observe_only", "observe":
            self = .observeOnly
        case "off", "disabled":
            self = .off
        default:
            return nil
        }
    }

    var configuration: PromptCachingConfiguration {
        switch self {
        case .auto:
            return .default
        case .observeOnly:
            return PromptCachingConfiguration(
                isEnabled: true,
                mode: .observeOnly,
                retention: .providerDefault,
                canonicalizeJSONForCache: false
            )
        case .off:
            return PromptCachingConfiguration(
                isEnabled: false,
                mode: .off,
                retention: .providerDefault,
                canonicalizeJSONForCache: false
            )
        }
    }
}
