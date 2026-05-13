import Foundation

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case home
    case proxy
    case keys
    case advanced
    case customization

    var id: Self { self }

    static let collapsedTabSections: [SettingsSection] = [.home, .proxy, .keys, .advanced]

    var title: String {
        switch self {
        case .home:
            return "Home"
        case .proxy:
            return "Proxy"
        case .keys:
            return "Keys & Providers"
        case .advanced:
            return "Advanced"
        case .customization:
            return "Customization"
        }
    }

    var compactTitle: String {
        switch self {
        case .home:
            return "Home"
        case .proxy:
            return "Proxy"
        case .keys:
            return "Keys & Providers"
        case .advanced:
            return "Advanced"
        case .customization:
            return "Customization"
        }
    }

    var detail: String {
        switch self {
        case .home:
            return "Session overview"
        case .proxy:
            return "Routing and models"
        case .keys:
            return "Secrets and helpers"
        case .advanced:
            return "App preferences"
        case .customization:
            return "Appearance and menu bar"
        }
    }

    var systemImage: String {
        switch self {
        case .home:
            return "house"
        case .proxy:
            return "network"
        case .keys:
            return "key"
        case .advanced:
            return "gearshape"
        case .customization:
            return "paintpalette"
        }
    }
}

enum ProxySectionFocus: String, Identifiable, Hashable {
    case models

    var id: Self { self }

    var highlightDurationSeconds: TimeInterval {
        switch self {
        case .models:
            return 4
        }
    }
}
