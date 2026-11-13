import Combine
import Foundation

/// Explicit checks are separate from cached discovery and never persist as a health guarantee.
@MainActor
final class ProviderConnectionTests: ObservableObject {
    struct Result: Equatable {
        let message: String
        let succeeded: Bool
        let date: Date
    }
    @Published private(set) var results: [ProviderCatalogStore.Identity: Result] = [:]
    @Published private(set) var running: Set<ProviderCatalogStore.Identity> = []
    private var generations: [ProviderCatalogStore.Identity: UUID] = [:]

    func invalidate(providerID: String) {
        for identity in Array(generations.keys) where identity.providerID == providerID {
            generations.removeValue(forKey: identity)
            results.removeValue(forKey: identity)
            running.remove(identity)
        }
    }

    func run(_ identity: ProviderCatalogStore.Identity, operation: () async throws -> String) async {
        let generation = UUID()
        generations[identity] = generation
        running.insert(identity)
        results.removeValue(forKey: identity)
        let result: Result
        do { result = Result(message: try await operation(), succeeded: true, date: Date()) }
        catch { result = Result(message: error.localizedDescription, succeeded: false, date: Date()) }
        guard generations[identity] == generation else { return }
        running.remove(identity)
        results[identity] = result
    }
}
