import XCTest
@testable import ProxyPilot
import ProxyPilotCore

final class ModelBrowserTests: XCTestCase {
    private func model(_ id: String, lab: String?, date: Double? = nil) -> UpstreamModel {
        UpstreamModel(id: id, contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil,
                      lab: lab, catalogAddedAt: date.map(Date.init(timeIntervalSince1970:)))
    }
    func testLabsCombineWithSearchAndFavorites() {
        let models = [model("a/code", lab: "A"), model("b/code", lab: "B"), model("c/code", lab: "C"), model("a/chat", lab: "A")]
        var query = ModelBrowserQuery()
        query.search = "code"
        query.labs = ["A", "B"]
        query.favoritesOnly = true
        XCTAssertEqual(query.results(models, favorites: ["a/code", "b/code", "c/code", "a/chat"]).map(\.id), ["a/code", "b/code"])
    }
    func testNewestKeepsUnknownLastAndUsesStableTieBreak() {
        var query = ModelBrowserQuery()
        query.sort = .newest
        XCTAssertEqual(query.results([model("unknown", lab: nil), model("old", lab: nil, date: 1), model("b", lab: nil, date: 2), model("a", lab: nil, date: 2)], favorites: []).map(\.id), ["a", "b", "old", "unknown"])
    }
    @MainActor func testFavoritesMigrationPreservesExactIDsAndDoesNotReintroduceRemovedFavorites() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ModelFavoritesStore(defaults: defaults)
        store.migrate(providerID: "openrouter", savedDefaults: ["lab/model:exacto"])
        XCTAssertEqual(store.favorites(providerID: "openrouter"), ["lab/model:exacto"])
        store.setFavorite("lab/model:exacto", providerID: "openrouter", enabled: false)
        store.migrate(providerID: "openrouter", savedDefaults: ["lab/model:exacto"])
        XCTAssertTrue(store.favorites(providerID: "openrouter").isEmpty)
    }
    @MainActor func testCatalogRefreshFailureRetainsCachedModels() async {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ProviderCatalogStore(defaults: defaults)
        let identity = ProviderCatalogStore.Identity(providerID: "test", endpoint: "https://example.invalid/v1")
        await store.refresh(identity) { [.idOnly("model")] }
        await store.refresh(identity, force: true) { throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(store.snapshots[identity]?.models.map(\.id), ["model"])
        XCTAssertNotNil(store.errors[identity])
        XCTAssertFalse(store.loading.contains(identity))
    }
    @MainActor func testBrowsingAndFavoritingDoNotChangeXcodeSelectionOrAdvertisedModels() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("openrouter", forKey: ProviderManager.upstreamProviderDefaultsKey)
        defaults.set(["lab/old:exacto"], forKey: ProviderManager.defaultModelsKey(for: .openRouter))
        let vm = AppViewModel(defaults: defaults)
        let before = vm.selectedUpstreamSelection
        let oldModel = vm.selectedXcodeAgentModel
        vm.prepareBrowser(.builtIn(.google))
        vm.modelFavorites.setFavorite("other", providerID: UpstreamSelection.builtIn(.google).id, enabled: true)
        XCTAssertEqual(vm.selectedUpstreamSelection, before)
        XCTAssertEqual(vm.selectedXcodeAgentModel, oldModel)
        XCTAssertEqual(vm.browserSavedModels(.builtIn(.openRouter)), ["lab/old:exacto"])
        XCTAssertTrue(vm.browserSavedModels(.builtIn(.google)).isEmpty)
        vm.useBrowserModel(.idOnly("new-model"), selection: .builtIn(.google))
        XCTAssertEqual(vm.selectedUpstreamSelection, .builtIn(.google))
        XCTAssertEqual(vm.selectedXcodeAgentModel, "new-model")
        XCTAssertTrue(vm.selectedUpstreamModels.contains("new-model"))
        XCTAssertFalse(vm.isRunning)
    }

    @MainActor func testExplicitModelSurvivesRelaunchWithoutChangingAdvertisedDefaults() throws {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let vm = AppViewModel(defaults: defaults)
        vm.useBrowserModel(.idOnly("chosen:exacto"), selection: .builtIn(.ollama))
        let restored = AppViewModel(defaults: defaults)
        XCTAssertEqual(restored.selectedXcodeAgentModel, "chosen:exacto")
        XCTAssertTrue(restored.browserSavedModels(.builtIn(.ollama)).isEmpty)
        XCTAssertTrue(try restored.buildBuiltInProxyConfig().allowedModels.contains("chosen:exacto"))
    }

    @MainActor func testCatalogFreshnessEndpointIsolationAndInvalidation() async {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ProviderCatalogStore(defaults: defaults)
        let a = ProviderCatalogStore.Identity(providerID: "test", endpoint: "https://a.invalid")
        let b = ProviderCatalogStore.Identity(providerID: "test", endpoint: "https://b.invalid")
        var calls = 0
        let now = Date()
        await store.refresh(a, now: now) { calls += 1; return [.idOnly("a")] }
        await store.refresh(a, now: now.addingTimeInterval(60)) { calls += 1; return [] }
        XCTAssertEqual(calls, 1)
        XCTAssertNil(store.snapshots[b])
        let reloaded = ProviderCatalogStore(defaults: defaults)
        reloaded.hydrate(a)
        XCTAssertEqual(reloaded.snapshots[a]?.models.map(\.id), ["a"])
        store.invalidate(a)
        await store.refresh(a) { calls += 1; return [.idOnly("replacement")] }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(store.snapshots[a]?.models.map(\.id), ["replacement"])
    }

    @MainActor func testCancelledRefreshDoesNotBecomeProviderFailure() async {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ProviderCatalogStore(defaults: defaults)
        let id = ProviderCatalogStore.Identity(providerID: "test", endpoint: "https://example.invalid")
        await store.refresh(id) { throw URLError(.cancelled) }
        XCTAssertNil(store.errors[id])
        XCTAssertFalse(store.loading.contains(id))
        await store.refresh(id) { [.idOnly("recovered")] }
        XCTAssertEqual(store.snapshots[id]?.models.first?.id, "recovered")
    }

    func testNegativeCatalogPricesRemainUnknownIncludingCachedModels() throws {
        let model = UpstreamModel(id: "router", contextLength: nil, promptPricePer1M: -1, completionPricePer1M: -1)
        XCTAssertNil(model.promptPricePer1M)
        XCTAssertEqual(model.pricingTier, .unknown)
        let cached = Data(#"{"id":"router","promptPricePer1M":-1000000,"completionPricePer1M":-1000000}"#.utf8)
        let restored = try JSONDecoder().decode(UpstreamModel.self, from: cached)
        XCTAssertNil(restored.pricingPerMillionLabel)
        XCTAssertEqual(restored.pricingTier, .unknown)
    }

    func testOldModelCacheDecodesWithoutNewMetadata() throws {
        let old = Data(#"{"id":"old","supportedParameters":[]}"#.utf8)
        let model = try JSONDecoder().decode(UpstreamModel.self, from: old)
        XCTAssertNil(model.catalogAddedAt)
        XCTAssertNil(model.lab)
        XCTAssertEqual(model.id, "old")
    }

}
