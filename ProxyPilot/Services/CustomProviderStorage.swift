import Foundation

/// Manages CRUD operations for user-defined custom providers.
/// Provider metadata persisted in UserDefaults; API keys in Keychain.
@MainActor
final class CustomProviderStorage: ObservableObject {
    static let defaultsKey = "proxypilot.customProviders"

    @Published private(set) var providers: [CustomProvider] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - CRUD

    func add(_ provider: CustomProvider, apiKey: String) {
        providers.append(provider)
        persist()
        try? KeychainService.set(apiKey, forAccount: provider.keychainAccountName)
    }

    func update(_ provider: CustomProvider) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[index] = provider
        persist()
    }

    func delete(_ provider: CustomProvider) {
        providers.removeAll { $0.id == provider.id }
        persist()
        try? KeychainService.delete(account: provider.keychainAccountName)
    }

    // MARK: - Key Access

    func apiKey(for provider: CustomProvider) -> String? {
        KeychainService.get(account: provider.keychainAccountName)
    }

    func saveAPIKey(_ key: String, for provider: CustomProvider) {
        try? KeychainService.set(key, forAccount: provider.keychainAccountName)
    }

    func hasAPIKey(for provider: CustomProvider) -> Bool {
        KeychainService.exists(account: provider.keychainAccountName)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([CustomProvider].self, from: data) else {
            return
        }
        providers = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(providers) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
