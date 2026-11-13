import XCTest
@testable import ProxyPilot

private actor RouteTestRunner {
    var calls: [(String, [String])] = []
    let old: Bool
    let endpoint: String
    let checks: [String]
    let transport: String
    init(old: Bool = false, endpoint: String = "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1", checks: [String] = ["endpoint", "active_model_alias", "streaming", "tool_call", "tool_continuation"], transport: String = "running_shared_route") {
        self.old = old; self.endpoint = endpoint; self.checks = checks; self.transport = transport
    }
    func run(_ binary: URL, _ arguments: [String]) throws -> (Data, Int32) {
        calls.append((binary.path, arguments))
        let object: [String: Any]
        if arguments.first == "capabilities" { object = old ? [:] : ["route_test": 1] }
        else if arguments.prefix(2) == ["route", "status"] { object = ["provider": "qwen", "model": "qwen4-max-preview"] }
        else { object = ["ok": true, "data": ["provider": "qwen", "model": "qwen4-max-preview", "endpoint": endpoint, "transport": transport, "verifiedChecks": checks]] }
        return (try JSONSerialization.data(withJSONObject: object), 0)
    }
    func recorded() -> [(String, [String])] { calls }
}

@MainActor
final class RepoGPSRouteTestServiceTests: XCTestCase {
    let endpoint = "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"
    func testUsesSelectedRouteAndStableBinaryWithoutMutatingIt() async {
        let runner = RouteTestRunner()
        let service = RepoGPSRouteTestService(candidates: [URL(fileURLWithPath: "/usr/bin/true"), URL(fileURLWithPath: "/bin/echo")], runner: { try await runner.run($0, $1) })
        await service.check(timeout: 45, maxOutputTokens: 2048, expectedEndpoint: { $0 == "qwen" ? self.endpoint : nil })
        XCTAssertTrue(service.succeeded, service.result ?? "missing result")
        let calls = await runner.recorded()
        XCTAssertEqual(calls.count, 3)
        XCTAssertTrue(calls.allSatisfy { $0.0 == "/usr/bin/true" })
        XCTAssertEqual(calls.last?.1, ["route", "test", "--expected-provider", "qwen", "--expected-model", "qwen4-max-preview", "--expected-upstream-url", endpoint, "--timeout-seconds", "45.0", "--max-output-tokens", "2048", "--json"])
        XCTAssertTrue(service.result?.contains("running shared route") == true)
        service.invalidate()
        XCTAssertNil(service.result)
        XCTAssertFalse(service.succeeded)
    }
    func testOldStableBinaryFailsWithoutBundledFallbackOrInference() async {
        let runner = RouteTestRunner(old: true)
        let service = RepoGPSRouteTestService(candidates: [URL(fileURLWithPath: "/usr/bin/true"), URL(fileURLWithPath: "/bin/echo")], runner: { try await runner.run($0, $1) })
        await service.check(timeout: 45, maxOutputTokens: 2048, expectedEndpoint: { _ in self.endpoint })
        XCTAssertFalse(service.succeeded)
        XCTAssertTrue(service.result?.contains("too old") == true)
        let calls = await runner.recorded()
        XCTAssertEqual(calls.count, 1)
    }
    func testIncompleteOrWrongEndpointReceiptCannotPass() async {
        for runner in [RouteTestRunner(endpoint: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"), RouteTestRunner(checks: ["endpoint"])] {
            let service = RepoGPSRouteTestService(candidates: [URL(fileURLWithPath: "/usr/bin/true")], runner: { try await runner.run($0, $1) })
            await service.check(timeout: 45, maxOutputTokens: 2048, expectedEndpoint: { _ in self.endpoint })
            XCTAssertFalse(service.succeeded)
            XCTAssertTrue(service.result?.contains("did not prove") == true, service.result ?? "missing result")
        }
    }
    func testTemporaryProbeIsExplicitlyDistinguishedFromRunningRoute() async {
        let runner = RouteTestRunner(transport: "temporary_startup_probe")
        let service = RepoGPSRouteTestService(candidates: [URL(fileURLWithPath: "/usr/bin/true")], runner: { try await runner.run($0, $1) })
        await service.check(timeout: 45, maxOutputTokens: 2048, expectedEndpoint: { _ in self.endpoint })
        XCTAssertTrue(service.succeeded, service.result ?? "missing result")
        XCTAssertTrue(service.result?.contains("shared route remains stopped") == true)
    }
}
