import XCTest
import ProxyPilotCore
@testable import ProxyPilot

@MainActor
final class HomeConnectionTargetTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) async throws -> Void) async rethrows {
        let name = "HomeConnectionTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(defaults)
    }
    func testHomeConnectionPersistsAndUnknownValueFallsBackToXcode() async {
        await withDefaults { defaults in
            let vm = AppViewModel(defaults: defaults, repoGPSRoutingFeatureEnabled: true, epiphyteFeatureEnabled: true)
            XCTAssertEqual(vm.homeConnectionTarget, .xcode)
            vm.homeConnectionTarget = .epiphyte
            XCTAssertEqual(defaults.string(forKey: AppViewModel.homeConnectionTargetDefaultsKey), "epiphyte")
            XCTAssertEqual(AppViewModel(defaults: defaults, repoGPSRoutingFeatureEnabled: true, epiphyteFeatureEnabled: true).homeConnectionTarget, .epiphyte)
            defaults.set("unsupported-old-target", forKey: AppViewModel.homeConnectionTargetDefaultsKey)
            XCTAssertEqual(AppViewModel(defaults: defaults, repoGPSRoutingFeatureEnabled: true, epiphyteFeatureEnabled: true).homeConnectionTarget, .xcode)
        }
    }
    func testSwitchingHomeModuleLeavesEveryRouteAndProxyStateUnchanged() async {
        await withDefaults { defaults in
            let vm = AppViewModel(defaults: defaults, repoGPSRoutingFeatureEnabled: true, epiphyteFeatureEnabled: true)
            vm.upstreamProvider = .openRouter
            vm.selectedXcodeAgentModel = "xcode-fixture"
            var cli = RouteControlService.Status()
            cli.selected = true; cli.provider = "openai"; cli.model = "repogps-fixture"
            vm.routeControl.apply(cli)
            let xcodeSelection = vm.selectedUpstreamSelection
            let xcodeModel = vm.selectedXcodeAgentModel
            let epiSelection = vm.epiphyteControl.status
            let runtime = vm.proxyRuntimeStatus
            var before = defaults.dictionaryRepresentation()
            before.removeValue(forKey: AppViewModel.homeConnectionTargetDefaultsKey)
            for target in HomeConnectionTarget.allCases { vm.homeConnectionTarget = target }
            XCTAssertEqual(vm.selectedUpstreamSelection, xcodeSelection)
            XCTAssertEqual(vm.selectedXcodeAgentModel, xcodeModel)
            XCTAssertEqual(vm.routeControl.status, cli)
            XCTAssertEqual(vm.epiphyteControl.status, epiSelection)
            XCTAssertEqual(vm.proxyRuntimeStatus, runtime)
            var after = defaults.dictionaryRepresentation()
            after.removeValue(forKey: AppViewModel.homeConnectionTargetDefaultsKey)
            XCTAssertEqual(NSDictionary(dictionary: before), NSDictionary(dictionary: after))
        }
    }
    func testQueuedModelSubmissionsKeepOriginalDestinationAndValuesAfterHomeSwitch() async {
        await withDefaults { defaults in
            let vm = AppViewModel(defaults: defaults, repoGPSRoutingFeatureEnabled: true, epiphyteFeatureEnabled: true)
            var provider = "openrouter", model = "original-epi"
            let epi = ConnectionModelSubmission.epiphyte(provider: provider, model: model)
            let cli = ConnectionModelSubmission.repoGPS(provider: "openai", model: "original-cli", port: 4000)
            provider = "google"; model = "later-edit"
            vm.homeConnectionTarget = .xcode
            var calls: [String] = []
            await epi.perform(repoGPS: { _, _, _ in XCTFail("Epiphyte save reached RepoGPS lifecycle") },
                epiphyte: { calls.append("epi:\($0)/\($1)") })
            vm.homeConnectionTarget = .epiphyte
            await cli.perform(repoGPS: { calls.append("cli:\($0)/\($1):\($2)") },
                epiphyte: { _, _ in XCTFail("RepoGPS apply reached Epiphyte selection") })
            XCTAssertEqual(calls, ["epi:openrouter/original-epi", "cli:openai/original-cli:4000"])
            XCTAssertEqual(provider, "google"); XCTAssertEqual(model, "later-edit")
        }
    }
}
