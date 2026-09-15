import Foundation

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case home
    case history
    case harnesses
    case proxy
    case routing
    case keys
    case advanced
    case customization

    var id: Self { self }

    static let sidebarSections: [SettingsSection] = [.home, .history, .proxy, .routing, .keys, .harnesses, .advanced, .customization]

    static let collapsedTabSections: [SettingsSection] = [.home, .history, .proxy, .routing, .keys, .harnesses, .advanced]

    static func availableSidebarSections(repoGPSRoutingEnabled: Bool) -> [SettingsSection] {
        sidebarSections.filter { repoGPSRoutingEnabled || $0 != .routing }
    }

    static func availableCollapsedTabSections(repoGPSRoutingEnabled: Bool) -> [SettingsSection] {
        collapsedTabSections.filter { repoGPSRoutingEnabled || $0 != .routing }
    }

    var title: String {
        switch self {
        case .home:
            return "Home"
        case .history:
            return "Session History"
        case .harnesses:
            return "RepoGPS"
        case .proxy:
            return "Xcode Setup"
        case .routing:
            return "Connections"
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
        case .harnesses:
            return "RepoGPS"
        case .proxy:
            return "Xcode Setup"
        case .routing:
            return "Connections"
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
        case .harnesses:
            return "Optional Terminal coding agent"
        case .proxy:
            return "Agent, providers and models"
        case .routing:
            return "Selected and running models"
        case .keys:
            return "API keys and local providers"
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
        case .harnesses:
            return "terminal"
        case .proxy:
            return "network"
        case .routing:
            return "arrow.triangle.branch"
        case .keys:
            return "key"
        case .advanced:
            return "gearshape"
        case .customization:
            return "paintpalette"
        }
    }
}

/// Launch-time feature gate for the internal RepoGPS routing surfaces.
///
/// Routing remains compiled into every build. It becomes navigable only on a
/// Mac with the independently installed RepoGPS command in the location used
/// by RepoGPS's own installer. The bundled ProxyPilot CLI is deliberately not
/// evidence of RepoGPS availability.
enum RepoGPSRoutingFeatureFlag {
    static let current = isEnabled()

    static func candidateExecutable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".local/bin/rgps")
    }

    static func isEnabled(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> Bool {
        isExecutable(candidateExecutable(home: home).path)
    }
}

enum LayoutModePreference: String, CaseIterable, Identifiable, Hashable {
    case automatic
    case sidebar
    case compact

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .sidebar:
            return "Sidebar"
        case .compact:
            return "Compact"
        }
    }

    var systemImage: String {
        switch self {
        case .automatic:
            return "rectangle.3.group"
        case .sidebar:
            return "sidebar.left"
        case .compact:
            return "rectangle.grid.1x2"
        }
    }
}

enum ProxySectionFocus: String, Identifiable, Hashable {
    case cacheSignals
    case models
    case agentRegistration

    var id: Self { self }

    var highlightDurationSeconds: TimeInterval {
        switch self {
        case .cacheSignals:
            return 4
        case .models:
            return 4
        case .agentRegistration:
            return 4
        }
    }
}
