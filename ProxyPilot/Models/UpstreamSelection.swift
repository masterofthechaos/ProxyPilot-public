import Foundation
import ProxyPilotCore

enum UpstreamSelection: Hashable, Identifiable {
    /// No provider chosen yet. ProxyPilot has no default provider.
    case none
    case builtIn(UpstreamProvider)
    case custom(UUID)

    var id: String {
        switch self {
        case .none:
            return "none"
        case .builtIn(let provider):
            return "builtin:\(provider.rawValue)"
        case .custom(let id):
            return "custom:\(id.uuidString)"
        }
    }
}
