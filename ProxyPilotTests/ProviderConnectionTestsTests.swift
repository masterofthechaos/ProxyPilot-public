import XCTest
@testable import ProxyPilot

@MainActor
final class ProviderConnectionTestsTests: XCTestCase {
    func testCredentialChangeDiscardsInflightResult() async {
        let store = ProviderConnectionTests()
        let identity = ProviderCatalogStore.Identity(providerID: "test", endpoint: "https://example.invalid/v1")
        var continuation: CheckedContinuation<String, Never>?
        let task = Task {
            await store.run(identity) {
                await withCheckedContinuation { continuation = $0 }
            }
        }
        while continuation == nil { await Task.yield() }
        XCTAssertTrue(store.running.contains(identity))
        store.invalidate(providerID: identity.providerID)
        continuation?.resume(returning: "Old credential worked")
        await task.value
        XCTAssertNil(store.results[identity])
        XCTAssertFalse(store.running.contains(identity))
    }

    func testChecksAreEndpointScopedAndFailureReplacesSuccess() async {
        let store = ProviderConnectionTests()
        let a = ProviderCatalogStore.Identity(providerID: "test", endpoint: "https://a.invalid/v1")
        let b = ProviderCatalogStore.Identity(providerID: "test", endpoint: "https://b.invalid/v1")
        await store.run(a) { "Catalog reachable" }
        XCTAssertEqual(store.results[a]?.succeeded, true)
        XCTAssertNil(store.results[b])
        await store.run(a) { throw URLError(.userAuthenticationRequired) }
        XCTAssertEqual(store.results[a]?.succeeded, false)
        XCTAssertFalse(store.running.contains(a))
    }

    func testEndpointSaveInvalidatesChecksWithoutChangingXcodeRoute() async throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let vm = AppViewModel(defaults: defaults)
        vm.useBrowserModel(.idOnly("existing-model"), selection: .builtIn(.ollama))
        let identity = vm.browserIdentity(.builtIn(.qwen))
        await vm.providerConnectionTests.run(identity) { "Old endpoint reachable" }
        XCTAssertTrue(vm.saveBrowserEndpoint(QwenAPIService.tokenPlanSingapore.endpoint!, selection: .builtIn(.qwen)))
        XCTAssertNil(vm.providerConnectionTests.results[identity])
        XCTAssertEqual(vm.selectedUpstreamSelection, .builtIn(.ollama))
        XCTAssertEqual(vm.selectedXcodeAgentModel, "existing-model")
        XCTAssertFalse(vm.isRunning)
    }
}
