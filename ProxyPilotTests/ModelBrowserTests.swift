import XCTest
@testable import ProxyPilot
import ProxyPilotCore

private actor RequestedURLs {
    private(set) var urls: [URL] = []
    func append(_ url: URL) { urls.append(url) }
}

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
    @MainActor func testXcodeModelMenuOffersFetchedCatalogWithoutASubset() async {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("lmstudio", forKey: ProviderManager.upstreamProviderDefaultsKey)
        let vm = AppViewModel(defaults: defaults)
        XCTAssertFalse(vm.xcodeModelMenuCandidates.contains("essentialai/rnj-1"))
        await vm.providerCatalog.refresh(vm.browserIdentity(vm.selectedUpstreamSelection)) { [.idOnly("essentialai/rnj-1")] }
        XCTAssertTrue(vm.xcodeModelMenuCandidates.contains("essentialai/rnj-1"))
        XCTAssertTrue(vm.selectedXcodeAgentModel.isEmpty, "Offering a model must not select it")
        vm.useBrowserModel(.idOnly("essentialai/rnj-1"), selection: vm.selectedUpstreamSelection)
        XCTAssertEqual(vm.effectiveXcodeAgentModel, "essentialai/rnj-1")
    }
    @MainActor func testXcodeModelMenuKeepsAChosenSubset() async {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("lmstudio", forKey: ProviderManager.upstreamProviderDefaultsKey)
        let vm = AppViewModel(defaults: defaults)
        vm.selectedUpstreamModels = ["kept"]
        await vm.providerCatalog.refresh(vm.browserIdentity(vm.selectedUpstreamSelection)) { [.idOnly("kept"), .idOnly("other")] }
        XCTAssertFalse(vm.xcodeModelMenuCandidates.contains("other"))
    }
    @MainActor func testXcodeModelMenuRefreshReportsUnreachableLocalServerAndRetries() async {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("lmstudio", forKey: ProviderManager.upstreamProviderDefaultsKey)
        // Port 9 (discard) is closed on loopback, so the fetch fails at once.
        defaults.set("http://127.0.0.1:9/v1", forKey: "proxypilot.upstreamAPIBaseURL.lmstudio")
        let vm = AppViewModel(defaults: defaults)
        let identity = vm.browserIdentity(vm.selectedUpstreamSelection)
        await vm.refreshXcodeModelMenu()
        XCTAssertNotNil(vm.providerCatalog.errors[identity])
        let message = vm.xcodeModelMenuEmptyMessage(error: vm.providerCatalog.errors[identity])
        XCTAssertTrue(message.contains("LM Studio"))
        XCTAssertTrue(message.contains("http://127.0.0.1:9/v1"))
        XCTAssertTrue(vm.xcodeModelMenuEmptyMessage(error: nil).contains("reported no models"))
        // A local provider is asked again even inside the one-hour catalog window.
        await vm.providerCatalog.refresh(identity, force: true) { [] }
        XCTAssertNil(vm.providerCatalog.errors[identity])
        await vm.refreshXcodeModelMenu()
        XCTAssertNotNil(vm.providerCatalog.errors[identity])
    }
    @MainActor func testXcodeModelLoadStateComesFromLMStudioAndClearsForOtherProviders() async {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("lmstudio", forKey: ProviderManager.upstreamProviderDefaultsKey)
        let vm = AppViewModel(defaults: defaults)
        vm.useBrowserModel(.idOnly("prism-ml/bonsai-27b"), selection: vm.selectedUpstreamSelection)
        let requested = RequestedURLs()
        vm.localModelStateFetcher = { url in
            await requested.append(url)
            return Data(#"{"data":[{"id":"prism-ml/bonsai-27b","state":"not-loaded","max_context_length":262144}]}"#.utf8)
        }
        await vm.refreshXcodeModelLoadState()
        let urls = await requested.urls
        XCTAssertEqual(urls.map(\.absoluteString), ["http://localhost:1234/api/v0/models"])
        XCTAssertEqual(vm.xcodeModelLoadState,
                       LocalModelLoadState(modelID: "prism-ml/bonsai-27b", isLoaded: false, maxContextLength: 262144))

        vm.localModelStateFetcher = { _ in
            Data(#"{"data":[{"id":"prism-ml/bonsai-27b","state":"loaded","max_context_length":262144,"loaded_context_length":40192}]}"#.utf8)
        }
        await vm.refreshXcodeModelLoadState()
        XCTAssertEqual(vm.xcodeModelLoadState?.loadedContextLength, 40192)

        vm.localModelStateFetcher = { _ in throw URLError(.cannotConnectToHost) }
        await vm.refreshXcodeModelLoadState()
        XCTAssertNil(vm.xcodeModelLoadState, "an unreachable server is unknown, not unloaded")

        // Start from a known state, so switching provider has something to clear.
        vm.localModelStateFetcher = { _ in
            Data(#"{"data":[{"id":"prism-ml/bonsai-27b","state":"loaded","max_context_length":262144,"loaded_context_length":40192}]}"#.utf8)
        }
        await vm.refreshXcodeModelLoadState()
        XCTAssertNotNil(vm.xcodeModelLoadState)
        vm.localModelStateFetcher = { _ in XCTFail("only LM Studio is asked"); return Data() }
        vm.selectedUpstreamSelection = .builtIn(.ollama)
        await vm.refreshXcodeModelLoadState()
        XCTAssertNil(vm.xcodeModelLoadState)
    }

    /// A slow answer must not overwrite the answer to a later request.
    @MainActor func testOlderLoadStateAnswerDoesNotOverwriteANewerOne() async {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("lmstudio", forKey: ProviderManager.upstreamProviderDefaultsKey)
        let vm = AppViewModel(defaults: defaults)
        vm.useBrowserModel(.idOnly("prism-ml/bonsai-27b"), selection: vm.selectedUpstreamSelection)
        vm.localModelStateFetcher = { _ in
            try await Task.sleep(for: .milliseconds(300))
            return Data(#"{"data":[{"id":"prism-ml/bonsai-27b","state":"not-loaded","max_context_length":262144}]}"#.utf8)
        }
        let slow = Task { await vm.refreshXcodeModelLoadState() }
        try? await Task.sleep(for: .milliseconds(50))
        vm.localModelStateFetcher = { _ in
            Data(#"{"data":[{"id":"prism-ml/bonsai-27b","state":"loaded","max_context_length":262144,"loaded_context_length":40192}]}"#.utf8)
        }
        await vm.refreshXcodeModelLoadState()
        await slow.value
        XCTAssertEqual(vm.xcodeModelLoadState?.isLoaded, true)
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
