import Foundation
import ProxyPilotCore

@MainActor
final class EpiphyteControlService: ObservableObject {
    struct Status: Equatable {
        var provider: String?
        var model: String?
        var selected: Bool { provider != nil && model != nil }
    }
    @Published private(set) var status = Status()
    @Published private(set) var availability: RouteControlService.Availability = .missing
    @Published private(set) var activeRequests: [IndependentRequestActivity] = []
    @Published private(set) var isSaving = false
    @Published private(set) var lastError: String?
    private var hasRefreshed = false

    var badgeTitle: String {
        if activeRequests.count > 1 { return "Epiphyte: \(activeRequests.count) requests" }
        return activeRequests.isEmpty ? "Epiphyte idle" : "Epiphyte in flight"
    }
    var selectionSummary: String {
        guard let provider = status.provider, let model = status.model else { return "Choose a model for Epiphyte" }
        return "\(AppViewModel.routeProviderTitle(provider)) / \(model)"
    }
    nonisolated static func supportsEpiphyteRoute(_ data: Data) -> Bool {
        let values = try? JSONSerialization.jsonObject(with: data) as? [String: Int]
        return (values?["epiphyte_route"] ?? 0) >= 1
    }
    nonisolated static func parseStatus(_ data: Data) -> Status? {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["client"] as? String == "epiphyte", value["transport"] as? String == "independent" else { return nil }
        return .init(provider: value["provider"] as? String, model: value["selected_model"] as? String)
    }
    nonisolated private static func command(_ binary: URL, _ args: [String]) -> (Data, Int32)? {
        let process = Process(); process.executableURL = binary; process.arguments = args
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (data, process.terminationStatus)
    }
    func refreshIfNeeded() async {
        guard !hasRefreshed else { return }
        hasRefreshed = true
        await refresh()
    }
    func refreshActivity() {
        let current = EpiphyteRequestLease.active()
        if current != activeRequests { activeRequests = current }
    }
    func refresh() async {
        refreshActivity()
        let candidates = RouteControlService.candidateBinaries()
        let resolved = await Task.detached {
            var old: URL?
            for binary in candidates where FileManager.default.isExecutableFile(atPath: binary.path) {
                if let (data, code) = Self.command(binary, ["capabilities", "--json"]), code == 0, Self.supportsEpiphyteRoute(data) {
                    return RouteControlService.Availability.ready(binary)
                }
                if old == nil { old = binary }
            }
            return old.map(RouteControlService.Availability.tooOld) ?? .missing
        }.value
        availability = resolved
        guard case .ready(let binary) = resolved else {
            status = Status(); lastError = "Install the supporting ProxyPilot CLI to configure Epiphyte."; return
        }
        let result = await Task.detached { Self.command(binary, ["route", "status", "--client", "epiphyte", "--json"]) }.value
        guard let (data, code) = result, code == 0, let parsed = Self.parseStatus(data) else {
            lastError = "Could not read Epiphyte's independent model selection."; return
        }
        status = parsed; lastError = nil
    }
    func save(provider: String, model: String) async {
        guard !isSaving, case .ready(let binary) = availability else { return }
        isSaving = true; defer { isSaving = false }
        let result = await Task.detached { Self.command(binary, ["route", "set", "--client", "epiphyte", "--provider", provider, "--model", model, "--json"]) }.value
        guard let (data, code) = result, code == 0, let parsed = Self.parseStatus(data) else {
            lastError = result.map { RouteControlService.failureMessage(from: $0.0) } ?? "Could not save the Epiphyte model."
            return
        }
        status = parsed; lastError = nil
    }
}
