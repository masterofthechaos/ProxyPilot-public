import Combine
import Foundation
import CryptoKit
import ProxyPilotCore

/// Browsing state is deliberately independent from ProviderManager's active route.
@MainActor
final class ProviderCatalogStore: ObservableObject {
    struct Identity: Hashable {
        let providerID: String
        let endpoint: String
        var cacheKey: String {
            let bytes = Data((providerID + "\n" + endpoint).utf8)
            return "proxypilot.catalog.v1." + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
    }
    struct Snapshot: Codable {
        var models: [UpstreamModel]
        var fetchedAt: Date
    }
    @Published private(set) var snapshots: [Identity: Snapshot] = [:]
    @Published private(set) var loading: Set<Identity> = []
    @Published private(set) var errors: [Identity: String] = [:]
    private let defaults: UserDefaults
    private var generations: [Identity: UUID] = [:]
    func reset() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("proxypilot.catalog.v1.") {
            defaults.removeObject(forKey: key)
        }
        generations = [:]; snapshots = [:]; loading = []; errors = [:]
    }
    init(defaults: UserDefaults) { self.defaults = defaults }

    func hydrate(_ identity: Identity) {
        guard snapshots[identity] == nil,
              let data = defaults.data(forKey: identity.cacheKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        snapshots[identity] = snapshot
    }

    func invalidate(_ identity: Identity) {
        generations[identity] = UUID()
        loading.remove(identity)
        snapshots.removeValue(forKey: identity)
        errors.removeValue(forKey: identity)
        defaults.removeObject(forKey: identity.cacheKey)
    }

    func refresh(
        _ identity: Identity,
        force: Bool = false,
        now: Date = Date(),
        fetch: @escaping @MainActor () async throws -> [UpstreamModel]
    ) async {
        hydrate(identity)
        guard !loading.contains(identity) else { return }
        if !force, let snapshot = snapshots[identity], now.timeIntervalSince(snapshot.fetchedAt) < 3600 { return }
        let generation = UUID()
        generations[identity] = generation
        loading.insert(identity)
        errors.removeValue(forKey: identity)
        do {
            // A transient SwiftUI view cancellation must not abort the shared catalog fetch.
            let models = try await Task { try await fetch() }.value
            guard generations[identity] == generation else { return }
            let snapshot = Snapshot(models: models, fetchedAt: now)
            snapshots[identity] = snapshot
            if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: identity.cacheKey) }
        } catch {
            guard generations[identity] == generation else { return }
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                errors[identity] = error.localizedDescription
            }
        }
        loading.remove(identity)
    }
}
