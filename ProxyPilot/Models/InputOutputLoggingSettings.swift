import Foundation

enum InputOutputLoggingRetention: String, CaseIterable, Identifiable {
    case twentyFourHoursDefault
    case untilQuit
    case thirtyMinutes
    case oneHour
    case twoHours
    case sixHours
    case twelveHours
    case twentyFourHoursMaximum

    var id: Self { self }

    var title: String {
        switch self {
        case .twentyFourHoursDefault:
            return "24 hours (default)"
        case .untilQuit:
            return "Until I quit ProxyPilot"
        case .thirtyMinutes:
            return "30 minutes"
        case .oneHour:
            return "1 hour"
        case .twoHours:
            return "2 hours"
        case .sixHours:
            return "6 hours"
        case .twelveHours:
            return "12 hours"
        case .twentyFourHoursMaximum:
            return "24 hours (maximum)"
        }
    }

    var helperText: String {
        switch self {
        case .twentyFourHoursDefault:
            return "ProxyPilot will delete any saved inputs or outputs after 24 hours."
        case .untilQuit:
            return "ProxyPilot will delete any saved inputs or outputs when you close the app."
        case .thirtyMinutes:
            return "ProxyPilot will delete any saved inputs or outputs after 30 minutes."
        case .oneHour:
            return "ProxyPilot will delete any saved inputs or outputs after 1 hour."
        case .twoHours:
            return "ProxyPilot will delete any saved inputs or outputs after 2 hours."
        case .sixHours:
            return "ProxyPilot will delete any saved inputs or outputs after 6 hours."
        case .twelveHours:
            return "ProxyPilot will delete any saved inputs or outputs after 12 hours."
        case .twentyFourHoursMaximum:
            return "ProxyPilot will delete any saved inputs or outputs after 24 hours."
        }
    }
}
