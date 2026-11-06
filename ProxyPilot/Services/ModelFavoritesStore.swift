import Combine
import Foundation

/// Provider-scoped shortcuts. This store never changes route or advertised models.
@MainActor
final class ModelFavoritesStore: ObservableObject {
    @Published private(set) var revision = 0
    private let defaults: UserDefaults
    func reset() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("proxypilot.favorites.v1.") {
            defaults.removeObject(forKey: key)
        }
        revision += 1
    }
    init(defaults: UserDefaults) { self.defaults = defaults }

    func favorites(providerID: String) -> Set<String> {
        Set(defaults.stringArray(forKey: key(providerID)) ?? [])
    }

    func migrate(providerID: String, savedDefaults: [String]) {
        let marker = key(providerID) + ".migrated"
        guard !defaults.bool(forKey: marker) else { return }
        let merged = favorites(providerID: providerID).union(savedDefaults)
        defaults.set(merged.sorted(), forKey: key(providerID))
        defaults.set(true, forKey: marker)
        revision += 1
    }

    func setFavorite(_ id: String, providerID: String, enabled: Bool) {
        var values = favorites(providerID: providerID)
        if enabled { values.insert(id) } else { values.remove(id) }
        defaults.set(values.sorted(), forKey: key(providerID))
        revision += 1
    }

    private func key(_ provider: String) -> String { "proxypilot.favorites.v1." + provider }
}
