import Foundation

/// Uses the stable CLI RGPS resolves, rather than substituting a newer bundled helper.
@MainActor
final class RepoGPSRouteTestService: ObservableObject {
    typealias Runner = @Sendable (URL, [String]) async throws -> (Data, Int32)
    @Published private(set) var running = false
    @Published private(set) var result: String?
    @Published private(set) var succeeded = false
    @Published private(set) var checkedAt: Date?
    private var generation = UUID()
    private let candidates: [URL]
    private let runner: Runner

    init(candidates: [URL]? = nil, runner: Runner? = nil) {
        self.candidates = candidates ?? RouteControlService.candidateBinaries()
        self.runner = runner ?? Self.execute
    }

    func invalidate() {
        generation = UUID(); result = nil; succeeded = false; checkedAt = nil
    }

    func check(timeout: Double, maxOutputTokens: Int, expectedEndpoint: (String) -> String?) async {
        guard !running else { return }
        running = true; result = nil; succeeded = false
        let ticket = UUID(); generation = ticket
        defer { running = false }
        do {
            guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
                throw Self.failure("Install the ProxyPilot CLI used by RepoGPS first.")
            }
            let (capData, capCode) = try await runner(binary, ["capabilities", "--json"])
            let capabilities = try? JSONSerialization.jsonObject(with: capData) as? [String: Int]
            guard capCode == 0, (capabilities?["route_test"] ?? 0) >= 1 else {
                throw Self.failure("RepoGPS's CLI is too old for route testing. Update that CLI before launching a session.")
            }
            let (statusData, statusCode) = try await runner(binary, ["route", "status", "--json"])
            guard statusCode == 0, let status = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any],
                  let provider = status["provider"] as? String, let model = status["model"] as? String,
                  let endpoint = expectedEndpoint(provider), !model.isEmpty else {
                throw Self.failure("Choose a built-in RepoGPS provider and model before testing.")
            }
            let (data, code) = try await runner(binary, ["route", "test", "--expected-provider", provider,
                "--expected-model", model, "--expected-upstream-url", endpoint,
                "--timeout-seconds", String(timeout), "--max-output-tokens", String(maxOutputTokens), "--json"])
            guard code == 0 else { throw Self.failure(RouteControlService.failureMessage(from: data)) }
            guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  envelope["ok"] as? Bool == true, let receipt = envelope["data"] as? [String: Any],
                  receipt["provider"] as? String == provider, receipt["model"] as? String == model,
                  Self.sameEndpoint(receipt["endpoint"] as? String, endpoint),
                  Set(receipt["verifiedChecks"] as? [String] ?? []).isSuperset(of: ["endpoint", "active_model_alias", "streaming", "tool_call", "tool_continuation"]),
                  let transport = receipt["transport"] as? String,
                  ["running_shared_route", "temporary_startup_probe"].contains(transport) else {
                throw Self.failure("The CLI did not prove this route's endpoint, streaming and tool continuation. Update it and test again.")
            }
            guard ticket == generation else { return }
            let mode = transport == "running_shared_route" ? "running shared route" : "temporary startup probe; shared route remains stopped"
            result = "RepoGPS verified: \(provider) / \(model) · \(endpoint). Endpoint, active-model alias, streaming and tool continuation passed (\(mode))."
            succeeded = true; checkedAt = Date()
        } catch {
            guard ticket == generation else { return }
            result = error.localizedDescription; checkedAt = Date()
        }
    }

    private static func sameEndpoint(_ actual: String?, _ expected: String) -> Bool {
        guard let actual else { return false }
        return actual.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == expected.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "RepoGPSRouteTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private nonisolated static func execute(_ binary: URL, _ arguments: [String]) async throws -> (Data, Int32) {
        try await Task.detached(priority: .userInitiated) {
            let process = Process(), output = Pipe()
            process.executableURL = binary; process.arguments = arguments
            process.standardOutput = output; process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (data, process.terminationStatus)
        }.value
    }
}
