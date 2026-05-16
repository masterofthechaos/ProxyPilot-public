import Foundation

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case home
    case history
    case proxy
    case keys
    case advanced
    case customization

    var id: Self { self }

    static let sidebarSections: [SettingsSection] = [.home, .history, .proxy, .keys, .advanced, .customization]

    static let collapsedTabSections: [SettingsSection] = [.home, .history, .proxy, .keys, .advanced]

    var title: String {
        switch self {
        case .home:
            return "Home"
        case .history:
            return "Session History"
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
        case .history:
            return "History"
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
        case .history:
            return "Past sessions"
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
        case .history:
            return "clock.arrow.circlepath"
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
