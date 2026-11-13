import SwiftUI
import ProxyPilotCore

struct RepoGPSRouteTestView: View {
    @EnvironmentObject private var vm: AppViewModel
    var body: some View {
        RepoGPSRouteTestControls(service: vm.repoGPSRouteTest, expectedEndpoint: { raw in
            guard let provider = UpstreamProvider(rawValue: raw) else { return nil }
            return vm.browserEndpoint(.builtIn(provider))
        })
    }
}

private struct RepoGPSRouteTestControls: View {
    @ObservedObject var service: RepoGPSRouteTestService
    let expectedEndpoint: (String) -> String?
    // Reuse the established independent-request defaults and CLI validation range.
    @AppStorage("proxypilot.rgpsTest.timeout") private var timeout = 45.0
    @AppStorage("proxypilot.rgpsTest.outputTokens") private var maxOutputTokens = 2048
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Test RepoGPS Route") {
                    Task { await service.check(timeout: timeout, maxOutputTokens: maxOutputTokens, expectedEndpoint: expectedEndpoint) }
                }.disabled(service.running || !timeout.isFinite || timeout <= 0 || !(128...16384).contains(maxOutputTokens))
                if service.running { ProgressView().controlSize(.small) }
            }
            Text("Tests RepoGPS's selected provider and model through its CLI: endpoint, streaming and a tool round trip. Uses provider quota. A stopped route is probed temporarily; running sessions are not restarted.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Route test limits") {
                VStack {
                    LabeledContent("Timeout per request (seconds)") {
                        TextField("Seconds", value: $timeout, format: .number).frame(width: 90)
                    }
                    LabeledContent("Maximum output tokens per request") {
                        TextField("Tokens", value: $maxOutputTokens, format: .number).frame(width: 90)
                    }
                    if !timeout.isFinite || timeout <= 0 || !(128...16384).contains(maxOutputTokens) {
                        Text("Use a positive timeout and 128–16384 output tokens.").foregroundStyle(.secondary)
                    }
                }.textFieldStyle(.roundedBorder).padding(6)
            }.font(.caption)
            if let result = service.result {
                Label(result, systemImage: service.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption).textSelection(.enabled)
                if let date = service.checkedAt {
                    Text("Last route check: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
