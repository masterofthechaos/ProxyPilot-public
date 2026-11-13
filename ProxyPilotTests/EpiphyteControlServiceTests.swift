import XCTest
@testable import ProxyPilot

@MainActor
final class EpiphyteControlServiceTests: XCTestCase {
    func testRequiresIsolatedEpiphyteCapabilityAndIdentity() {
        XCTAssertTrue(EpiphyteControlService.supportsEpiphyteRoute(Data(#"{"epiphyte_route":1}"#.utf8)))
        XCTAssertFalse(EpiphyteControlService.supportsEpiphyteRoute(Data(#"{"page_agent_copy":1,"route_control":2}"#.utf8)))
        let scoped = Data(#"{"client":"epiphyte","transport":"independent","provider":"openrouter","selected_model":"epi-model"}"#.utf8)
        XCTAssertEqual(EpiphyteControlService.parseStatus(scoped)?.model, "epi-model")
        XCTAssertNil(EpiphyteControlService.parseStatus(Data(#"{"client":"repogps","transport":"shared_proxy","selected_model":"other-model"}"#.utf8)))
        XCTAssertNil(EpiphyteControlService.parseStatus(Data(#"{"client":"epiphyte","transport":"shared_proxy"}"#.utf8)))
    }
    func testEpiphyteAndConcurrentClientStatusNeverClaimsSharedListenerStarted() {
        let epi = AppViewModel.toolbarProxyStatus(for: .stopped, repoGPSActive: false, epiphyteActive: true)
        XCTAssertEqual(epi.kind, .epiphyte)
        XCTAssertEqual(epi.fullText, "Epiphyte in flight")
        XCTAssertEqual(AppViewModel.statusText(for: .stopped), "Stopped")
        let both = AppViewModel.toolbarProxyStatus(for: .runningInApp, repoGPSActive: true, epiphyteActive: true)
        XCTAssertEqual(both.kind, .independentClients)
        XCTAssertEqual(both.fullText, "RepoGPS and Epiphyte in flight")
        XCTAssertEqual(AppViewModel.toolbarProxyStatus(for: .stopped, repoGPSActive: false, epiphyteActive: false).kind, .stopped)
    }
}
