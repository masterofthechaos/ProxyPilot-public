import XCTest
@testable import ProxyPilot

@MainActor
final class MenuBarProxyOwnershipTests: XCTestCase {
    /// The live state this exists for: CLI daemon serving the RepoGPS route on
    /// the GUI's own port, GUI proxy not running.
    private func servingRoute(port: Int = 4000) -> RouteControlService.Status {
        var status = RouteControlService.Status()
        status.selected = true
        status.applied = true
        status.reachable = true
        status.owner = "cli"
        status.provider = "openrouter"
        status.model = "google/gemini-4-argon"
        status.port = port
        status.verificationState = "models_ready"
        return status
    }

    private func classify(
        _ runtime: AppViewModel.ProxyRuntimeStatus,
        route: RouteControlService.Status = .init(),
        guiPort: Int? = 4000,
        repoGPS: Bool = true
    ) -> MenuBarProxyOwnership {
        MenuBarProxyOwnership.classify(runtime: runtime, route: route, guiPort: guiPort, repoGPSRoutingEnabled: repoGPS)
    }

    // MARK: - Classification

    func testInAppProxyIsTheXcodeProxyEvenWhenTheRouteLooksApplied() {
        let ownership = classify(.runningInApp, route: servingRoute())
        XCTAssertEqual(ownership, .inApp)
        XCTAssertEqual(ownership.statusTitle, "Xcode Proxy Running")
    }

    func testExternalProxyServingTheRepoGPSRouteIsNamedForIt() {
        let ownership = classify(.runningExternal, route: servingRoute())
        XCTAssertEqual(ownership, .repoGPSRoute(port: 4000))
        XCTAssertEqual(ownership.statusTitle, "RepoGPS Route Running · port 4000")
        XCTAssertTrue(ownership.isRunning)
    }

    func testExternalProxyIsGenericUnlessTheRouteIsProvablyTheListener() {
        var notApplied = servingRoute()
        notApplied.applied = false
        XCTAssertEqual(classify(.runningExternal, route: notApplied), .external, "route not serving")

        var notCLI = servingRoute()
        notCLI.owner = "none"
        XCTAssertEqual(classify(.runningExternal, route: notCLI), .external, "no CLI-owned PID")

        XCTAssertEqual(classify(.runningExternal, route: servingRoute(port: 4477)), .external,
                       "route on another port is not what the GUI probed")
        XCTAssertEqual(classify(.runningExternal, route: servingRoute(), guiPort: nil), .external,
                       "unparseable GUI proxy URL")
        XCTAssertEqual(classify(.runningExternal, route: .init()), .external, "no route at all")
        XCTAssertEqual(classify(.runningExternal).statusTitle, "Proxy Running")
    }

    /// RepoGPS routing is hidden unless RepoGPS is installed; such installs keep
    /// today's generic wording and actions.
    func testRepoGPSWordingRequiresTheRoutingFeature() {
        XCTAssertEqual(classify(.runningExternal, route: servingRoute(), repoGPS: false), .external)
    }

    func testStoppedAndPortOccupied() {
        XCTAssertEqual(classify(.stopped, route: servingRoute()), .stopped)
        XCTAssertEqual(classify(.stopped).statusTitle, "Proxy Stopped")
        XCTAssertFalse(classify(.stopped).isRunning)

        let occupied = classify(.portOccupied(statusCode: 404))
        XCTAssertEqual(occupied, .portOccupied)
        XCTAssertEqual(occupied.statusTitle, "Proxy Stopped")
        XCTAssertFalse(occupied.isRunning)
    }

    // MARK: - Action sets

    func testActionsNameTheRouteTheyActOn() {
        XCTAssertEqual(MenuBarProxyOwnership.stopped.actions(isStoppingCLIProxy: false), [.startXcodeProxy])
        XCTAssertEqual(MenuBarProxyOwnership.inApp.actions(isStoppingCLIProxy: false),
                       [.stopXcodeProxy, .restartXcodeProxy])
        XCTAssertEqual(MenuBarProxyOwnership.external.actions(isStoppingCLIProxy: false),
                       [.stopExternalProxy, .restartExternalProxy])
        XCTAssertEqual(MenuBarProxyOwnership.portOccupied.actions(isStoppingCLIProxy: false), [])
    }

    /// The Xcode restart would stop the route daemon and start the built-in
    /// proxy on the same port — replacing the RepoGPS route — so it is not
    /// offered while the RepoGPS route is what is running.
    func testRepoGPSRouteOffersOnlyItsOwnStop() {
        let actions = MenuBarProxyOwnership.repoGPSRoute(port: 4000).actions(isStoppingCLIProxy: false)
        XCTAssertEqual(actions, [.stopRepoGPSRoute])
        XCTAssertFalse(actions.contains(.restartXcodeProxy))
        XCTAssertFalse(actions.contains(.restartExternalProxy))
    }

    func testStopInFlightHidesStopAndRestartActions() {
        XCTAssertEqual(MenuBarProxyOwnership.inApp.actions(isStoppingCLIProxy: true), [])
        XCTAssertEqual(MenuBarProxyOwnership.repoGPSRoute(port: 4000).actions(isStoppingCLIProxy: true), [])
        XCTAssertEqual(MenuBarProxyOwnership.external.actions(isStoppingCLIProxy: true), [])
    }

    // MARK: - View model wiring

    /// The view model classifies against its own proxy URL port and feature
    /// flag, using the shared route status. Deliberately leaves
    /// `proxyURLString` at its default: assigning it persists launch settings.
    func testViewModelUsesItsProxyPortAndFeatureFlag() {
        let name = "MenuBarProxyOwnershipTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let vm = AppViewModel(defaults: defaults, repoGPSRoutingFeatureEnabled: true, epiphyteFeatureEnabled: false)
        XCTAssertEqual(vm.proxyURLString, AppViewModel.defaultProxyURLString)
        vm.routeControl.apply(servingRoute(port: 4000))
        vm.applyProxyRuntimeStatus(.runningExternal)
        XCTAssertEqual(vm.menuBarProxyOwnership, .repoGPSRoute(port: 4000))

        vm.routeControl.apply(servingRoute(port: 4001))
        XCTAssertEqual(vm.menuBarProxyOwnership, .external)

        let disabled = AppViewModel(defaults: defaults, repoGPSRoutingFeatureEnabled: false, epiphyteFeatureEnabled: false)
        disabled.routeControl.apply(servingRoute(port: 4000))
        disabled.applyProxyRuntimeStatus(.runningExternal)
        XCTAssertEqual(disabled.menuBarProxyOwnership, .external)
    }

    // MARK: - Quit

    func testQuitStopsOnlyTheInAppProxy() {
        XCTAssertEqual(classify(.runningInApp).quitCleanup, .stopInAppProxy)
        XCTAssertEqual(classify(.runningExternal, route: servingRoute()).quitCleanup, .leaveExternalRunning,
                       "RepoGPS route")
        XCTAssertEqual(classify(.runningExternal).quitCleanup, .leaveExternalRunning,
                       "other external: the app cannot prove it started it")
        XCTAssertEqual(classify(.runningExternal, route: servingRoute(), repoGPS: false).quitCleanup,
                       .leaveExternalRunning, "RepoGPS routing off")
        XCTAssertEqual(classify(.stopped).quitCleanup, .nothingToStop)
        XCTAssertEqual(classify(.portOccupied(statusCode: 404)).quitCleanup, .nothingToStop)
    }

    /// The quit path must never run the CLI stop. Both the resolver and the
    /// runner are injected: the default proxy URL is 127.0.0.1:4000, so an
    /// uninjected stop would reach a real daemon on this machine.
    func testQuitNeverRunsTheCLIStopForAnExternalProxy() async {
        for (label, route, repoGPS) in [
            ("RepoGPS route", servingRoute(), true),
            ("other external", RouteControlService.Status(), true),
            ("RepoGPS routing off", servingRoute(), false),
        ] {
            let name = "MenuBarProxyOwnershipQuit-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            var stops = 0
            let vm = AppViewModel(
                defaults: defaults,
                cliExecutableResolver: { URL(fileURLWithPath: "/test/proxypilot") },
                cliStopRunner: { _, _ in
                    stops += 1
                    return AppViewModel.CLIUpdateExecutionResult(terminationStatus: 0, stdout: "", stderr: "")
                },
                repoGPSRoutingFeatureEnabled: repoGPS,
                epiphyteFeatureEnabled: false
            )
            vm.routeControl.apply(route)
            vm.applyProxyRuntimeStatus(.runningExternal)

            let cleanup = await vm.stopOwnedProxyForQuit()

            XCTAssertEqual(cleanup, .leaveExternalRunning, label)
            XCTAssertEqual(stops, 0, label)
        }
    }

    /// The explicit Stop keeps its existing behaviour: it does stop a
    /// background proxy through the CLI.
    func testExplicitStopStillStopsAnExternalProxy() async {
        let name = "MenuBarProxyOwnershipStop-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var stops = 0
        let vm = AppViewModel(
            defaults: defaults,
            cliExecutableResolver: { URL(fileURLWithPath: "/test/proxypilot") },
            cliStopRunner: { _, _ in
                stops += 1
                return AppViewModel.CLIUpdateExecutionResult(terminationStatus: 0, stdout: "", stderr: "")
            },
            repoGPSRoutingFeatureEnabled: true,
            epiphyteFeatureEnabled: false
        )
        vm.routeControl.apply(servingRoute())
        vm.applyProxyRuntimeStatus(.runningExternal)

        await vm.stopProxy()

        XCTAssertEqual(stops, 1)
    }

    // MARK: - Shared presentation (every surface)

    func testActionVocabularyAndConfirmationsMatchTheMenu() {
        typealias A = MenuBarProxyOwnership.Action
        XCTAssertEqual(A.startXcodeProxy.title, "Start Xcode Proxy")
        XCTAssertEqual(A.stopXcodeProxy.title, "Stop Xcode Proxy")
        XCTAssertEqual(A.restartXcodeProxy.title, "Apply & Restart")
        XCTAssertEqual(A.restartExternalProxy.title, "Apply & Restart")
        XCTAssertEqual(A.stopRepoGPSRoute.title, "Stop RepoGPS Route")
        XCTAssertEqual(A.stopExternalProxy.title, "Stop Proxy")
        XCTAssertEqual(A.stopRepoGPSRoute.compactTitle, "Stop RepoGPS")
        XCTAssertEqual(A.startXcodeProxy.compactTitle, "Start Xcode")

        XCTAssertEqual(A.restartXcodeProxy.confirmation, .restart(route: "the Xcode proxy"))
        XCTAssertEqual(A.restartExternalProxy.confirmation, .restart(route: "the Xcode proxy"))
        XCTAssertEqual(A.stopRepoGPSRoute.confirmation, .stop(route: "the RepoGPS proxy"))
        XCTAssertNil(A.startXcodeProxy.confirmation)
        XCTAssertNil(A.stopXcodeProxy.confirmation)
        XCTAssertNil(A.stopExternalProxy.confirmation)

        XCTAssertTrue(A.stopRepoGPSRoute.isDestructive)
        XCTAssertFalse(A.restartXcodeProxy.isDestructive)
    }

    /// Xcode sections apply the Xcode selection; in the RepoGPS-route state
    /// that would replace the route, so they offer only the route's stop.
    func testXcodeSectionControlsPerState() {
        XCTAssertEqual(MenuBarProxyOwnership.repoGPSRoute(port: 4000).xcodeSectionControls, .repoGPSRouteServing(port: 4000))
        XCTAssertEqual(MenuBarProxyOwnership.inApp.xcodeSectionControls, .xcode(stopTitle: "Stop Xcode Proxy"))
        XCTAssertEqual(MenuBarProxyOwnership.external.xcodeSectionControls, .xcode(stopTitle: "Stop Proxy"))
        XCTAssertEqual(MenuBarProxyOwnership.stopped.xcodeSectionControls, .xcode(stopTitle: nil))
        XCTAssertEqual(MenuBarProxyOwnership.portOccupied.xcodeSectionControls, .xcode(stopTitle: nil))
    }

    func testToolbarStatusUsesTheMenuWordingPerOwner() {
        func status(_ runtime: AppViewModel.ProxyRuntimeStatus, _ ownership: MenuBarProxyOwnership) -> AppViewModel.ToolbarProxyStatus {
            AppViewModel.toolbarProxyStatus(for: runtime, repoGPSActive: false, ownership: ownership)
        }
        XCTAssertEqual(status(.runningInApp, .inApp), .init(kind: .gui, compactText: "Xcode", fullText: "Xcode Proxy Running"))
        XCTAssertEqual(status(.runningExternal, .repoGPSRoute(port: 4000)),
                       .init(kind: .cli, compactText: "RepoGPS", fullText: "RepoGPS Route Running · port 4000"))
        XCTAssertEqual(status(.runningExternal, .external), .init(kind: .cli, compactText: "Running", fullText: "Proxy Running"))
        XCTAssertEqual(status(.stopped, .stopped), .init(kind: .stopped, compactText: "Stopped", fullText: "Proxy Stopped"))
        XCTAssertEqual(status(.portOccupied(statusCode: 418), .portOccupied).kind, .issue, "keeps the specific conflict text")
        // A RepoGPS session in flight still takes precedence.
        XCTAssertEqual(AppViewModel.toolbarProxyStatus(for: .runningExternal, repoGPSActive: true,
                                                       ownership: .repoGPSRoute(port: 4000)).fullText, "RepoGPS in flight")
    }

    func testStartRepoGPSOfferedOnlyForASelectedIdleRouteWithRouteControl() {
        let ready = RouteControlService.Availability.ready(URL(fileURLWithPath: "/test/proxypilot"))
        var idle = RouteControlService.Status()
        idle.selected = true
        XCTAssertTrue(AppViewModel.offersRepoGPSRouteStart(routingEnabled: true, availability: ready, route: idle))
        XCTAssertFalse(AppViewModel.offersRepoGPSRouteStart(routingEnabled: false, availability: ready, route: idle), "feature off")
        XCTAssertFalse(AppViewModel.offersRepoGPSRouteStart(routingEnabled: true, availability: .missing, route: idle), "no CLI")
        XCTAssertFalse(AppViewModel.offersRepoGPSRouteStart(routingEnabled: true, availability: ready, route: servingRoute()), "already serving")
        XCTAssertFalse(AppViewModel.offersRepoGPSRouteStart(routingEnabled: true, availability: ready, route: .init()), "nothing selected")
    }

    /// The view model's toolbar status follows its own ownership.
    func testViewModelToolbarStatusNamesTheRepoGPSRoute() {
        let name = "MenuBarProxyOwnershipToolbar-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let vm = AppViewModel(defaults: defaults, repoGPSRoutingFeatureEnabled: true, epiphyteFeatureEnabled: false)
        vm.routeControl.apply(servingRoute(port: 4000))
        vm.applyProxyRuntimeStatus(.runningExternal)
        XCTAssertEqual(vm.toolbarProxyStatus.fullText, "RepoGPS Route Running · port 4000")
        XCTAssertEqual(vm.menuBarProxyOwnership.actions(isStoppingCLIProxy: false), [.stopRepoGPSRoute])
    }
}
