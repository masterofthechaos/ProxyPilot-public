import XCTest
@testable import ProxyPilot

@MainActor
final class RouteControlServiceTests: XCTestCase {

    // MARK: - Binary resolution

    /// The GUI must never reach the RepoGPS route through a PATH lookup. A
    /// stale `~/.local/bin/proxypilot` (v1.10.3 was found in the wild) has no
    /// `route` subcommand at all, so PATH resolution fails silently.
    func testCandidateBinariesPreferSharedRuntimeAndExcludePATH() {
        let home = URL(fileURLWithPath: "/Users/example")
        let relocatedApp = URL(fileURLWithPath: "/private/tmp/Relocated ProxyPilot.app")
        let candidates = RouteControlService.candidateBinaries(
            home: home,
            applicationBundleURL: relocatedApp
        )

        XCTAssertEqual(candidates.first?.path, "/Users/example/.proxypilot/bin/proxypilot")
        XCTAssertEqual(
            candidates.dropFirst().first?.path,
            "/private/tmp/Relocated ProxyPilot.app/Contents/Helpers/proxypilot"
        )
        XCTAssertTrue(candidates.contains { $0.path.hasPrefix("/Applications/ProxyPilot.app") })
        XCTAssertFalse(candidates.contains { $0.path.contains(".local/bin") })
    }

    // MARK: - Capability gate

    func testRouteControlRequiresTheAdvertisedCapability() {
        let supported = Data(#"{"route_control":1,"active_model_aliasing":1}"#.utf8)
        let unsupported = Data(#"{"active_model_aliasing":1}"#.utf8)
        let explicitZero = Data(#"{"route_control":0}"#.utf8)

        XCTAssertTrue(RouteControlService.supportsRouteControl(supported))
        XCTAssertFalse(RouteControlService.supportsRouteControl(unsupported))
        XCTAssertFalse(RouteControlService.supportsRouteControl(explicitZero))
        XCTAssertFalse(RouteControlService.supportsRouteControl(Data("not json".utf8)))
    }

    // MARK: - Status parsing

    func testParsesLiveRouteStatus() {
        let payload = Data(#"""
        {"applied":true,"model":"google/gemini-3.5-flash","owner":"cli","port":4000,
         "provider":"openrouter","reachable":true,"selected":true,
         "verification_state":"models_ready"}
        """#.utf8)

        let status = RouteControlService.parseStatus(payload)

        XCTAssertEqual(status?.provider, "openrouter")
        XCTAssertEqual(status?.model, "google/gemini-3.5-flash")
        XCTAssertEqual(status?.owner, "cli")
        XCTAssertEqual(status?.port, 4000)
        XCTAssertEqual(status?.verificationState, "models_ready")
        XCTAssertTrue(status?.isServing == true)
    }

    /// `route status` reports null provider/model when nothing is selected —
    /// that must read as "no route", never as a route to an empty model.
    func testParsesUnselectedRouteWithoutInventingAModel() {
        let payload = Data(#"""
        {"applied":false,"model":null,"owner":"none","port":4000,"provider":null,
         "reachable":false,"selected":false,"verification_state":"stopped"}
        """#.utf8)

        let status = RouteControlService.parseStatus(payload)

        XCTAssertNil(status?.provider)
        XCTAssertNil(status?.model)
        XCTAssertFalse(status?.isServing == true)
        XCTAssertEqual(status?.summary, "No route selected")
    }

    func testNonObjectOutputIsTreatedAsUnavailableRatherThanAnEmptyRoute() {
        XCTAssertNil(RouteControlService.parseStatus(Data("Error: unexpected argument".utf8)))
        XCTAssertNil(RouteControlService.parseStatus(Data("[]".utf8)))
    }

    // MARK: - Summary wording

    /// `selected` only means `route.json` records a preference. Only `applied`
    /// means the daemon is serving it, and the difference is the whole reason
    /// the menu bar used to look authoritative over RepoGPS while being inert.
    func testSummaryDistinguishesSelectedFromActuallyServing() {
        var status = RouteControlService.Status()
        status.selected = true

        status.applied = false
        status.reachable = false
        XCTAssertEqual(status.summary, "Selected, not running")

        status.reachable = true
        XCTAssertEqual(status.summary, "Proxy reachable, serving a different route")

        status.applied = true
        status.port = 4477
        XCTAssertEqual(status.summary, "Serving on port 4477")
    }

    // MARK: - Start affordance

    /// The menu's "Start RepoGPS Proxy" item exists for exactly one state: a
    /// route is recorded but not served. Unselected has nothing to start, and
    /// a serving route must not offer a second start.
    func testStartAffordanceShowsOnlyForSelectedButNotAppliedRoutes() {
        var status = RouteControlService.Status()
        XCTAssertFalse(status.needsStart, "nothing selected")

        status.selected = true
        XCTAssertTrue(status.needsStart, "selected, daemon down")

        status.reachable = true
        XCTAssertTrue(status.needsStart, "selected, another listener on the port")

        status.applied = true
        XCTAssertFalse(status.needsStart, "selected and serving")

        status.selected = false
        XCTAssertFalse(status.needsStart, "applied without selection is not startable")
    }

    // MARK: - Failure reporting

    func testFailureMessagePrefersStructuredErrorThenRawText() {
        let structured = Data(#"{"ok":false,"error":{"message":"Another route switch is in progress"}}"#.utf8)
        XCTAssertEqual(
            RouteControlService.failureMessage(from: structured),
            "Another route switch is in progress"
        )

        let plain = Data("Error: Could not stop CLI-owned route\n".utf8)
        XCTAssertEqual(
            RouteControlService.failureMessage(from: plain),
            "Error: Could not stop CLI-owned route"
        )

        XCTAssertEqual(RouteControlService.failureMessage(from: Data()), "Route change failed.")
    }

    /// `route set` failures are ArgumentParser `ValidationError`s: empty
    /// stdout, `Error: <message>` plus usage on stderr.
    func testFailureMessageFallsBackToFirstStandardErrorLine() {
        let stderr = Data("""
        Error: Port 4000 is owned by the GUI or an unmanaged listener; refusing to stop it
        Usage: proxypilot route set --provider <provider> --model <model> [--port <port>] [--json]
        """.utf8)
        XCTAssertEqual(
            RouteControlService.failureMessage(from: Data(), errors: stderr),
            "Port 4000 is owned by the GUI or an unmanaged listener; refusing to stop it"
        )

        let structured = Data(#"{"ok":false,"error":{"message":"Another route switch is in progress"}}"#.utf8)
        XCTAssertEqual(
            RouteControlService.failureMessage(from: structured, errors: stderr),
            "Another route switch is in progress",
            "a message on stdout still wins"
        )
        XCTAssertEqual(RouteControlService.failureMessage(from: Data(), errors: Data("\n".utf8)), "Route change failed.")

        // Observed from a real `route ensure` whose daemon could not bind.
        let nestedStart = Data(#"""
        Error: {"command":"start","error":{"code":"E012","message":"Daemon process failed to become ready.","recoverable":true},"ok":false,"schema_version":1}

        Usage: proxypilot <subcommand>
        """#.utf8)
        XCTAssertEqual(
            RouteControlService.failureMessage(from: Data(), errors: nestedStart),
            "Daemon process failed to become ready."
        )
    }

    // MARK: - ensureRoute

    /// Never reaches a process: the default availability is `.missing`, and
    /// this test deliberately does not `refresh()`, because resolution falls
    /// through to the real `/Applications/ProxyPilot.app` CLI.
    func testEnsureRouteWithoutRouteCapableCLIReportsAndDoesNotApply() async {
        let service = RouteControlService(home: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        await service.ensureRoute()
        XCTAssertEqual(service.lastError, "ProxyPilot CLI with route support was not found.")
        XCTAssertFalse(service.isApplying)
    }

    func testEnsureRouteStartsTheSelectedRouteWithEnsureNotSet() async throws {
        let cli = try FakeRouteCLI()
        try cli.setStatus(selected: true, applied: false, reachable: false)
        try cli.onEnsure(becomes: (selected: true, applied: true, reachable: true))
        let service = cli.service()
        await service.refresh()
        XCTAssertTrue(service.status.needsStart)

        await service.ensureRoute()

        XCTAssertEqual(try cli.calls().filter { $0.hasPrefix("route ensure") || $0.hasPrefix("route set") },
                       ["route ensure --json"])
        XCTAssertTrue(service.status.isServing)
        XCTAssertFalse(service.status.needsStart)
        XCTAssertNil(service.lastError)
        XCTAssertFalse(service.isApplying)
    }

    func testEnsureRouteRefusesWithoutASelectedRoute() async throws {
        let cli = try FakeRouteCLI()
        try cli.setStatus(selected: false, applied: false, reachable: false)
        let service = cli.service()
        await service.refresh()

        await service.ensureRoute()

        XCTAssertEqual(service.lastError, "Pick a RepoGPS model before starting the route.")
        XCTAssertFalse(try cli.calls().contains { $0.hasPrefix("route ensure") })
    }

    /// The failure must survive the refresh that follows it — and the next
    /// refresh, which is what reopening the menu does.
    func testEnsureRouteFailureSurfacesStandardErrorAndSurvivesRefresh() async throws {
        let cli = try FakeRouteCLI()
        try cli.setStatus(selected: true, applied: false, reachable: false)
        try cli.onEnsure(exitCode: 1, stderr: "Error: Another route switch is in progress\nUsage: proxypilot route set\n")
        let service = cli.service()
        await service.refresh()

        await service.ensureRoute()
        XCTAssertEqual(service.lastError, "Another route switch is in progress")
        XCTAssertFalse(service.isApplying)

        await service.refresh()
        XCTAssertEqual(service.lastError, "Another route switch is in progress")
    }

    /// `route ensure` exits 0 without starting anything when another listener
    /// already answers on the port. That must read as a failure.
    func testEnsureRouteExitZeroWithoutApplyingIsReportedAsNotStarted() async throws {
        let cli = try FakeRouteCLI()
        try cli.setStatus(selected: true, applied: false, reachable: true)
        let service = cli.service()
        await service.refresh()

        await service.ensureRoute()

        XCTAssertFalse(service.status.isServing)
        XCTAssertEqual(
            service.lastError,
            "Port 4000 is already served by another proxy, so the RepoGPS route was not started. Stop that proxy first."
        )

        try cli.setStatus(selected: true, applied: false, reachable: false)
        await service.ensureRoute()
        XCTAssertEqual(service.lastError, "The RepoGPS route did not start.")
    }

    func testEnsureRouteClearsAnEarlierErrorOnceTheRouteServes() async throws {
        let cli = try FakeRouteCLI()
        try cli.setStatus(selected: true, applied: false, reachable: false)
        try cli.onEnsure(exitCode: 1, stderr: "Error: Could not stop CLI-owned route\n")
        let service = cli.service()
        await service.refresh()
        await service.ensureRoute()
        XCTAssertEqual(service.lastError, "Could not stop CLI-owned route")

        try cli.onEnsure(becomes: (selected: true, applied: true, reachable: true))
        await service.ensureRoute()
        XCTAssertNil(service.lastError)
        XCTAssertTrue(service.status.isServing)
    }

    /// `applyRoute` had the same erasure: its error was set, then wiped by the
    /// refresh that followed.
    func testApplyRouteFailureSurvivesTheFollowingRefresh() async throws {
        let cli = try FakeRouteCLI()
        try cli.setStatus(selected: true, applied: false, reachable: false)
        try cli.onSet(exitCode: 64, stderr: "Error: Port 4000 is owned by the GUI or an unmanaged listener; refusing to stop it\n")
        let service = cli.service()
        await service.refresh()

        await service.applyRoute(provider: "openrouter", model: "other/model", port: 4000)

        XCTAssertEqual(service.lastError, "Port 4000 is owned by the GUI or an unmanaged listener; refusing to stop it")
        XCTAssertEqual(try cli.calls().filter { $0.hasPrefix("route set") },
                       ["route set --provider openrouter --model other/model --port 4000 --json"])
    }
}

/// A stand-in `proxypilot` at `<temp home>/.proxypilot/bin/proxypilot`, the
/// first candidate `RouteControlService` resolves. Every test that refreshes
/// or mutates must use one: otherwise resolution falls through to the real
/// installed CLI, and `route ensure` would start a real daemon.
private struct FakeRouteCLI {
    let home: URL
    let bin: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("RouteControlServiceTests-\(UUID().uuidString)")
        bin = home.appendingPathComponent(".proxypilot/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        dir="$(cd "$(dirname "$0")" && pwd)"
        echo "$*" >> "$dir/calls.log"
        case "$1 $2" in
          "capabilities --json") echo '{"route_control":1}' ;;
          "route status") cat "$dir/status.json" ;;
          "route ensure"|"route set")
            verb="$2"
            [ -f "$dir/$verb.stderr" ] && cat "$dir/$verb.stderr" >&2
            code="$(cat "$dir/$verb.code" 2>/dev/null || echo 0)"
            if [ "$code" = "0" ]; then
              [ -f "$dir/$verb.after.json" ] && cp "$dir/$verb.after.json" "$dir/status.json"
              cat "$dir/status.json"
            fi
            exit "$code" ;;
          *) exit 2 ;;
        esac
        """
        let url = bin.appendingPathComponent("proxypilot")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @MainActor
    func service() -> RouteControlService {
        RouteControlService(home: home, bundle: Bundle(for: RouteControlServiceTests.self))
    }

    private static func statusJSON(selected: Bool, applied: Bool, reachable: Bool) -> String {
        let model = selected ? #""openrouter/fixture""# : "null"
        let provider = selected ? #""openrouter""# : "null"
        return """
        {"applied":\(applied),"model":\(model),"owner":"\(applied ? "cli" : "none")","port":4000,\
        "provider":\(provider),"reachable":\(reachable),"selected":\(selected),\
        "verification_state":"\(applied ? "models_ready" : (reachable ? "mismatched" : "stopped"))"}
        """
    }

    private func write(_ text: String, _ name: String) throws {
        try text.write(to: bin.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func remove(_ name: String) {
        try? FileManager.default.removeItem(at: bin.appendingPathComponent(name))
    }

    func setStatus(selected: Bool, applied: Bool, reachable: Bool) throws {
        try write(Self.statusJSON(selected: selected, applied: applied, reachable: reachable), "status.json")
        remove("ensure.after.json")
    }

    func onEnsure(becomes state: (selected: Bool, applied: Bool, reachable: Bool)) throws {
        remove("ensure.code"); remove("ensure.stderr")
        try write(Self.statusJSON(selected: state.selected, applied: state.applied, reachable: state.reachable), "ensure.after.json")
    }

    func onEnsure(exitCode: Int32, stderr: String) throws {
        remove("ensure.after.json")
        try write(String(exitCode), "ensure.code")
        try write(stderr, "ensure.stderr")
    }

    func onSet(exitCode: Int32, stderr: String) throws {
        try write(String(exitCode), "set.code")
        try write(stderr, "set.stderr")
    }

    func calls() throws -> [String] {
        let log = bin.appendingPathComponent("calls.log")
        guard FileManager.default.fileExists(atPath: log.path) else { return [] }
        return try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }
}
