import XCTest
@testable import ProxyPilot

final class InstalledClientNavigationTests: XCTestCase {
    @MainActor func testEveryInstallationCombinationFiltersSidebarCompactDefaultAndHomeChoices() throws {
        for repoGPS in [false, true] {
            for epiphyte in [false, true] {
                let name = "InstalledClientNavigationTests." + UUID().uuidString
                let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
                defer { defaults.removePersistentDomain(forName: name) }
                let vm = AppViewModel(defaults: defaults, repoGPSRoutingFeatureEnabled: repoGPS, epiphyteFeatureEnabled: epiphyte)
                let sidebar = SettingsSection.availableSidebarSections(repoGPSRoutingEnabled: repoGPS, epiphyteInstalled: epiphyte)
                let compact = SettingsSection.availableCollapsedTabSections(repoGPSRoutingEnabled: repoGPS, epiphyteInstalled: epiphyte)
                XCTAssertEqual(sidebar, compact)
                XCTAssertEqual(sidebar.contains(.harnesses), repoGPS)
                XCTAssertEqual(sidebar.contains(.epiphyte), epiphyte)
                XCTAssertTrue(sidebar.contains(.home))
                XCTAssertTrue(sidebar.contains(.models))
                XCTAssertEqual(vm.availableHomeConnectionTargets.contains(.repoGPS), repoGPS)
                XCTAssertEqual(vm.availableHomeConnectionTargets.contains(.epiphyte), epiphyte)
                XCTAssertTrue(vm.availableHomeConnectionTargets.contains(.xcode))
            }
        }
    }

    @MainActor func testSavedMissingClientFallsBackToXcodeWithoutChangingSavedRoutes() throws {
        for missingTarget in [HomeConnectionTarget.repoGPS, .epiphyte] {
            let name = "InstalledClientFallbackTests." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(missingTarget.rawValue, forKey: AppViewModel.homeConnectionTargetDefaultsKey)
            let vm = AppViewModel(defaults: defaults, repoGPSRoutingFeatureEnabled: false, epiphyteFeatureEnabled: false)
            XCTAssertEqual(vm.homeConnectionTarget, .xcode)
            let xcode = vm.selectedUpstreamSelection
            let epi = vm.epiphyteControl.status
            let repoGPS = vm.routeControl.status
            vm.homeConnectionTarget = missingTarget
            XCTAssertEqual(vm.homeConnectionTarget, .xcode)
            XCTAssertEqual(defaults.string(forKey: AppViewModel.homeConnectionTargetDefaultsKey), "xcode")
            XCTAssertEqual(vm.selectedUpstreamSelection, xcode)
            XCTAssertEqual(vm.epiphyteControl.status, epi)
            XCTAssertEqual(vm.routeControl.status, repoGPS)
        }
    }

    func testEpiphyteRequiresRegisteredRunnableAppNotOnlySharedProxyPilotHelper() {
        XCTAssertFalse(EpiphyteFeatureFlag.isEnabled(applicationURL: nil) { _ in true })
        let app = URL(fileURLWithPath: "/Applications/Epiphyte.app")
        XCTAssertTrue(EpiphyteFeatureFlag.isEnabled(applicationURL: app) { $0 == "/Applications/Epiphyte.app/Contents/MacOS/Epiphyte" })
        XCTAssertFalse(EpiphyteFeatureFlag.isEnabled(applicationURL: app) { _ in false })
        XCTAssertFalse(EpiphyteFeatureFlag.isEnabled(applicationURL: URL(fileURLWithPath: "/usr/local/bin/proxypilot")) { _ in true })
        let developerApp = URL(fileURLWithPath: "/Users/example/Projects/Epiphyte/dist/Epiphyte.app")
        XCTAssertTrue(EpiphyteFeatureFlag.isEnabled(applicationURL: developerApp) { $0.hasSuffix("Contents/MacOS/Epiphyte") })
    }
}
