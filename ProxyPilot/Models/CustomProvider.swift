import Foundation

/// A user-defined upstream provider with custom API base URL and key.
struct CustomProvider: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var name: String
    var apiBaseURL: String

    /// Keychain account name for this provider's API key.
    var keychainAccountName: String { "CUSTOM_\(id.uuidString)" }

    init(id: UUID = UUID(), name: String, apiBaseURL: String) {
        self.id = id
        self.name = name
        self.apiBaseURL = apiBaseURL
    }
}
