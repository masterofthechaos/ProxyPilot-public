import XCTest
import ProxyPilotCore
@testable import ProxyPilot

/// Pins the Home hero card's route attribution.
///
/// The card's metrics — requests, tokens, cache, cost, latency — are all
/// observed traffic. Its provider and model badges read the GUI's *configured
/// Xcode* route, which is a different route entirely whenever a CLI daemon owns
/// the proxy. The owner-reported symptom: the Session Report Card listed
/// `openai/gpt-5.6-luna` and `openai/gpt-5.6-luna-pro` from real RepoGPS
/// traffic while the badge beside "Cache working" read `qwen/qwen3.6-flash`,
/// the Xcode selection, which had served none of it.
@MainActor
final class ServingRouteAttributionTests: XCTestCase {

    private func makeViewModel() -> AppViewModel {
        let defaults = UserDefaults(suiteName: "ServingRouteAttributionTests-\(UUID().uuidString)")!
        return AppViewModel(defaults: defaults)
    }

    /// Reproduces the reported configuration exactly: a CLI daemon serving
    /// luna on port 4000 while the GUI's Xcode selection is qwen.
    private func makeReportedState() -> AppViewModel {
        let vm = makeViewModel()
        vm.applyProxyRuntimeStatus(.runningExternal)
        vm.localProxyState.lastModelSeen = "openai/gpt-5.6-luna"
        vm.localProxyState.lastUpstreamModelUsed = "openai/gpt-5.6-luna"

        var status = RouteControlService.Status()
        status.selected = true
        status.applied = true
        status.reachable = true
        status.owner = "cli"
        status.provider = "openrouter"
        status.model = "openai/gpt-5.6-luna"
        vm.routeControl.apply(status)

        return vm
    }

    // MARK: - The reported defect

    func testServingBadgeNamesTheCLIRouteNotTheXcodeSelection() throws {
        let vm = makeReportedState()

        // XCTUnwrap rather than a force-unwrap: when this pin regresses the
        // badge goes nil, and `!` would abort the whole test process instead of
        // reporting one failure.
        let badge = try XCTUnwrap(
            vm.servingRouteBadgeTitle,
            "A CLI daemon is serving observed traffic, so there is a route to name."
        )

        XCTAssertTrue(
            badge.contains("openai/gpt-5.6-luna"),
            "The serving badge must name the model that produced the session's traffic. Got: \(badge)"
        )
        XCTAssertFalse(
            badge.contains("qwen"),
            "The serving badge must not name the Xcode selection while a CLI daemon owns the proxy. Got: \(badge)"
        )
    }

    func testServingRouteIsAttributedToTheCLIWhenADaemonOwnsTheProxy() {
        let vm = makeReportedState()

        XCTAssertEqual(vm.servingRoute?.owner, .cli)
        XCTAssertEqual(vm.servingRoute?.model, "openai/gpt-5.6-luna")
        XCTAssertTrue(
            vm.servingRoute?.isModelObserved == true,
            "Traffic was recorded, so the model is evidence rather than configuration."
        )
    }

    /// The Xcode selection does not disappear — it is labelled, so it can still
    /// be read but can no longer be mistaken for what is serving.
    func testXcodeBadgeAlwaysNamesItsRoute() {
        let vm = makeReportedState()

        XCTAssertTrue(
            vm.homeAgentModelBadgeLabel.hasPrefix("Xcode"),
            "An unqualified model name in a row of observed traffic reads as live. Got: \(vm.homeAgentModelBadgeLabel)"
        )
        XCTAssertTrue(
            vm.isXcodeRouteIdle,
            "Nothing is serving the Xcode route while a CLI daemon owns the proxy."
        )
    }

    /// `xcodeAgentRoutingSummaryText` has had a `.runningExternal` branch since
    /// the Routing section shipped; the badge help text did not, and so claimed
    /// the selection merely awaited a restart while a CLI daemon was serving.
    func testHelpTextDistinguishesACLIOwnedProxyFromAStoppedOne() {
        let external = makeReportedState()
        let stopped = makeViewModel()
        stopped.applyProxyRuntimeStatus(.stopped)

        XCTAssertNotEqual(
            external.homeAgentModelBadgeHelpText,
            stopped.homeAgentModelBadgeHelpText,
            "A CLI-owned proxy and a stopped proxy are different situations and must not share help text."
        )
        XCTAssertTrue(external.homeAgentModelBadgeHelpText.contains("may serve Xcode"))
    }

    // MARK: - Honest fallbacks

    func testNothingIsServingWhenTheProxyIsStopped() {
        let vm = makeViewModel()
        vm.applyProxyRuntimeStatus(.stopped)

        XCTAssertNil(vm.servingRoute, "A stopped proxy serves no route; inventing one is the original defect.")
        XCTAssertNil(vm.servingRouteBadgeTitle)
    }

    /// Before the first request there is no observed model, so the route
    /// configuration is the best available answer — but it is marked as such.
    func testFallsBackToRouteConfigurationBeforeAnyTrafficIsSeen() {
        let vm = makeViewModel()
        vm.applyProxyRuntimeStatus(.runningExternal)

        var status = RouteControlService.Status()
        status.selected = true
        status.applied = true
        status.provider = "openrouter"
        status.model = "openai/gpt-5.6-luna"
        vm.routeControl.apply(status)

        XCTAssertEqual(vm.servingRoute?.model, "openai/gpt-5.6-luna")
        XCTAssertFalse(
            vm.servingRoute?.isModelObserved ?? true,
            "No request has been served, so the model is a claim rather than evidence."
        )
        XCTAssertTrue(vm.servingRouteBadgeHelpText.contains("no request has been served"))
    }

    /// Observed traffic beats route configuration when they disagree — the
    /// disagreement is exactly the case worth reporting accurately.
    func testObservedTrafficOutranksRouteConfiguration() {
        let vm = makeViewModel()
        vm.applyProxyRuntimeStatus(.runningExternal)
        vm.localProxyState.lastUpstreamModelUsed = "openai/gpt-5.6-luna-pro"

        var status = RouteControlService.Status()
        status.selected = true
        status.provider = "openrouter"
        status.model = "openai/gpt-5.6-luna"
        vm.routeControl.apply(status)

        XCTAssertEqual(vm.servingRoute?.model, "openai/gpt-5.6-luna-pro")
        XCTAssertTrue(vm.servingRoute?.isModelObserved == true)
    }

    /// A CLI daemon with neither traffic nor a readable route yields no badge
    /// rather than a borrowed one.
    func testNoBadgeWhenNeitherTrafficNorRouteIsKnown() {
        let vm = makeViewModel()
        vm.applyProxyRuntimeStatus(.runningExternal)

        XCTAssertNil(
            vm.servingRoute,
            "With nothing observed and no route readable, the GUI must say nothing rather than substitute its own selection."
        )
    }

    // MARK: - Provider naming

    /// `route.json` stores the provider as `UpstreamProvider`'s *raw value*,
    /// which is lowercase (`"openrouter"`), not the Swift case name
    /// (`openRouter`). Verified against a live route file. Pinned because the
    /// two differ only in one character's case and the mapping fails silently
    /// to the raw identifier when it is wrong.
    func testRouteProviderTitleMapsKnownProvidersAndPreservesUnknownOnes() {
        XCTAssertEqual(UpstreamProvider.openRouter.rawValue, "openrouter")
        XCTAssertEqual(
            AppViewModel.routeProviderTitle("openrouter"),
            UpstreamProvider.openRouter.title
        )
        // An unrecognised identifier is shown verbatim. Falling back to the
        // GUI's configured provider here would silently reintroduce the defect.
        XCTAssertEqual(AppViewModel.routeProviderTitle("some-future-provider"), "some-future-provider")
        XCTAssertFalse(AppViewModel.routeProviderTitle(nil).isEmpty)
    }

    // MARK: - App-owned proxy still reports itself

    func testAppOwnedProxyIsAttributedToTheApp() {
        let vm = makeViewModel()
        vm.applyProxyRuntimeStatus(.runningInApp)
        // Set from the config the proxy started with (`LocalProxyServer:247`).
        vm.localProxyState.activeXcodeAgentModel = "qwen/qwen3.6-flash"

        XCTAssertEqual(vm.servingRoute?.owner, .app)
        XCTAssertEqual(vm.servingRoute?.model, "qwen/qwen3.6-flash")
        XCTAssertTrue(vm.servingRoute?.isModelObserved == true)
        XCTAssertFalse(vm.isXcodeRouteIdle, "The Xcode route is the one being served here.")
    }

    /// Guards a regression this fix could have introduced on the *primary*
    /// journey rather than the reported one.
    ///
    /// `lastModelSeen` is the client-**requested** model, set at `beginRequest`
    /// before the remap resolves. For Xcode that is an Anthropic model id. If
    /// the app-owned branch preferred observed traffic the way the CLI branch
    /// does, this badge would report what Xcode asked for instead of what
    /// ProxyPilot served — inverting the very confusion the badge exists to end,
    /// on the path most users are on.
    func testAppOwnedRouteReportsTheUpstreamItServesNotTheModelXcodeAskedFor() {
        let vm = makeViewModel()
        vm.applyProxyRuntimeStatus(.runningInApp)
        vm.localProxyState.activeXcodeAgentModel = "qwen/qwen3.6-flash"
        vm.localProxyState.lastModelSeen = "claude-sonnet-4-5"

        XCTAssertEqual(
            vm.servingRoute?.model,
            "qwen/qwen3.6-flash",
            "The app-owned badge must name the upstream ProxyPilot remaps to, not the Anthropic id Xcode requested."
        )
        XCTAssertNotEqual(vm.servingRoute?.model, "claude-sonnet-4-5")
    }

    /// The CLI branch keeps preferring observed traffic — there the client
    /// requests the opaque `proxypilot-active` alias, and the session import
    /// replaces `lastModelSeen` with the concrete model the daemon recorded, so
    /// the wire is the better source. The two branches differ on purpose.
    func testCLIAndAppBranchesResolveTheirModelDifferentlyOnPurpose() {
        let cli = makeViewModel()
        cli.applyProxyRuntimeStatus(.runningExternal)
        cli.localProxyState.lastModelSeen = "openai/gpt-5.6-luna"
        cli.localProxyState.activeXcodeAgentModel = "qwen/qwen3.6-flash"

        XCTAssertEqual(
            cli.servingRoute?.model,
            "openai/gpt-5.6-luna",
            "A CLI daemon's traffic is the evidence; the app's Xcode config says nothing about it."
        )
    }

    // MARK: - Polling cost

    /// The route poll must not run on the status timer while the GUI owns the
    /// proxy: `refresh()` spawns two processes and the answer is already known.
    func testRouteRefreshIsSkippedWhileTheAppOwnsTheProxy() async {
        let vm = makeViewModel()
        vm.applyProxyRuntimeStatus(.runningInApp)
        let before = vm.routeControl.status

        await vm.refreshRouteControlIfStale()

        XCTAssertEqual(vm.routeControl.status, before)
    }
}
