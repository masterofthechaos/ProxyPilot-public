import Foundation
import AppKit

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case home
    case history
    case harnesses
    case epiphyte
    case proxy
    case models
    case routing
    case keys
    case advanced
    case customization

    var id: Self { self }

    static let sidebarSections: [SettingsSection] = [.home, .models, .proxy, .history, .harnesses, .epiphyte, .advanced]

    static let collapsedTabSections: [SettingsSection] = [.home, .models, .proxy, .history, .harnesses, .epiphyte, .advanced]

    static func availableSidebarSections(repoGPSRoutingEnabled: Bool, epiphyteInstalled: Bool = false) -> [SettingsSection] {
        sidebarSections.filter {
            (repoGPSRoutingEnabled || ($0 != .routing && $0 != .harnesses))
                && (epiphyteInstalled || $0 != .epiphyte)
        }
    }

    static func availableCollapsedTabSections(repoGPSRoutingEnabled: Bool, epiphyteInstalled: Bool = false) -> [SettingsSection] {
        collapsedTabSections.filter {
            (repoGPSRoutingEnabled || ($0 != .routing && $0 != .harnesses))
                && (epiphyteInstalled || $0 != .epiphyte)
        }
    }

    var title: String {
        switch self {
        case .home:
            return "Home"
        case .history:
            return "Sessions"
        case .epiphyte:
            return "Epiphyte"
        case .harnesses:
            return "RepoGPS"
        case .proxy:
            return "Xcode"
        case .models:
            return "Providers & Models"
        case .routing:
            return "Connections"
        case .keys:
            return "Keys & Providers"
        case .advanced:
            return "Settings"
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
        case .epiphyte:
            return "Epiphyte"
        case .harnesses:
            return "RepoGPS"
        case .proxy:
            return "Xcode"
        case .models:
            return "Providers & Models"
        case .routing:
            return "Connections"
        case .keys:
            return "Keys & Providers"
        case .advanced:
            return "Settings"
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
        case .epiphyte:
            return "Page agent model and activity"
        case .harnesses:
            return "Optional Terminal coding agent"
        case .proxy:
            return "Agent registration and setup"
        case .models:
            return "Browse, favorite and choose models"
        case .routing:
            return "Selected and running models"
        case .keys:
            return "API keys and local providers"
        case .advanced:
            return "Appearance, connection and privacy"
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
        case .epiphyte:
            return "leaf"
        case .harnesses:
            return "terminal"
        case .proxy:
            return "network"
        case .models:
            return "square.stack.3d.up"
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

/// A registered app with a runnable executable counts, including a developer's
/// app outside /Applications. Stale Launch Services records do not enable it.
enum EpiphyteFeatureFlag {
    static let bundleIdentifier = "chat.micah.epiphyte"

    @MainActor static var current: Bool {
        isEnabled(applicationURL: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier))
    }

    static func isEnabled(
        applicationURL: URL?,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> Bool {
        guard let applicationURL, applicationURL.pathExtension.lowercased() == "app" else { return false }
        return isExecutable(applicationURL.appendingPathComponent("Contents/MacOS/Epiphyte").path)
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

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General", appearance = "Appearance", connection = "Connection"
    case privacy = "Privacy & Logging", support = "Updates & Support"
    var id: Self { self }
}

struct AppNavigationTarget: Equatable {
    let section: SettingsSection
    var category: SettingsCategory? = nil
    var focus: ProxySectionFocus? = nil

    static func migrated(_ section: SettingsSection) -> Self {
        switch section {
        case .keys: return .init(section: .models)
        case .routing: return .init(section: .harnesses)
        case .customization: return .init(section: .advanced, category: .appearance)
        case .advanced: return .init(section: .advanced, category: .connection)
        default: return .init(section: section)
        }
    }
}
