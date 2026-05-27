import SwiftUI
import ProxyPilotCore

enum AppAppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

enum HomeDashboardSection: String, CaseIterable, Identifiable {
    case sessionSummary
    case workflowControls
    case xcodeAgentRouting
    case sessionReportCard

    var id: Self { self }

    var title: String {
        switch self {
        case .sessionSummary:
            return "Current session"
        case .workflowControls:
            return "Workflow controls"
        case .xcodeAgentRouting:
            return "Xcode Agent routing"
        case .sessionReportCard:
            return "Session report card"
        }
    }

    var detail: String {
        switch self {
        case .sessionSummary:
            return "Provider, model, readiness, and session metrics."
        case .workflowControls:
            return "Start, stop, refresh, and keys shortcuts."
        case .xcodeAgentRouting:
            return "Agent model and config controls."
        case .sessionReportCard:
            return "CSV export, reset, and request history."
        }
    }
}

enum MenuBarSection: String, CaseIterable, Identifiable {
    case statusDetails
    case modelPicker
    case sessionStats
    case quickActions
    case updates

    var id: Self { self }

    static let defaultOrder: [MenuBarSection] = [
        .statusDetails,
        .modelPicker,
        .sessionStats,
        .quickActions,
        .updates
    ]

    var title: String {
        switch self {
        case .statusDetails:
            return "Proxy status"
        case .modelPicker:
            return "Agent model picker"
        case .sessionStats:
            return "Session metrics"
        case .quickActions:
            return "Quick actions"
        case .updates:
            return "Software updates"
        }
    }

    var detail: String {
        switch self {
        case .statusDetails:
            return "Running or stopped state in the dropdown."
        case .modelPicker:
            return "Choose the Xcode Agent upstream model."
        case .sessionStats:
            return "Requests, tokens, and latest model."
        case .quickActions:
            return "Start, stop, and restart controls."
        case .updates:
            return "Check for app updates."
        }
    }
}

enum KeysProviderViewItem: String, CaseIterable, Identifiable {
    case zAI = "zai"
    case openRouter = "openrouter"
    case openAI = "openai"
    case xAI = "xai"
    case chutes = "chutes"
    case groq = "groq"
    case google = "google"
    case deepSeek = "deepseek"
    case mistral = "mistral"
    case miniMax = "minimax"
    case miniMaxCN = "minimax-cn"
    case qwen = "qwen"
    case githubCopilot = "github-copilot"
    case ollama = "ollama"
    case lmStudio = "lmstudio"

    var id: Self { self }

    static let defaultOrder: [KeysProviderViewItem] = UpstreamProvider.allCases.compactMap(Self.init(provider:))

    init?(provider: UpstreamProvider) {
        self.init(rawValue: provider.rawValue)
    }

    var provider: UpstreamProvider {
        UpstreamProvider(rawValue: rawValue) ?? .zAI
    }

    var title: String {
        provider.title
    }

    var detail: String {
        switch provider {
        case .githubCopilot:
            return "Copilot sidecar setup and no-key local provider row."
        case .ollama, .lmStudio:
            return "Local provider setup row. No ProxyPilot API key required."
        default:
            return "Provider API key row."
        }
    }
}

enum ProxyPilotAccentColor {
    static let defaultHex = "#BD5CFF"

    static func normalizedHex(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard raw.count == 6,
              raw.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#\(raw.uppercased())"
    }
}

extension Color {
    init(proxyPilotHex hex: String) {
        let normalized = ProxyPilotAccentColor.normalizedHex(hex) ?? ProxyPilotAccentColor.defaultHex
        let raw = String(normalized.dropFirst())
        let scanner = Scanner(string: raw)
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)

        let red = Double((value & 0xFF0000) >> 16) / 255.0
        let green = Double((value & 0x00FF00) >> 8) / 255.0
        let blue = Double(value & 0x0000FF) / 255.0
        self.init(red: red, green: green, blue: blue)
    }
}
