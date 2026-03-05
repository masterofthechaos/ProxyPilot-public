import SwiftUI

private struct SessionStatsView: View {
    @ObservedObject var state: LocalProxyState
    @ObservedObject var reportCard: SessionReportCard
    let upstreamProviderTitle: String

    var body: some View {
        if state.sessionRequestCount > 0 {
            HStack(spacing: 4) {
                Text("\(state.sessionRequestCount) req")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if reportCard.totalTokens > 0 {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(reportCard.totalTokensFormatted) tok")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !state.lastModelSeen.isEmpty {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !state.lastUpstreamModelUsed.isEmpty && state.lastUpstreamModelUsed != state.lastModelSeen {
                        Text("\(state.lastModelSeen) → \(state.lastUpstreamModelUsed)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(state.lastModelSeen)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text("via \(upstreamProviderTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var vm: AppViewModel
    @EnvironmentObject private var updateService: SoftwareUpdateService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(vm.isRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(vm.isRunning ? "Proxy Running" : "Proxy Stopped")
                Text("Beta")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                    .foregroundStyle(.orange)
            }
            .accessibilityLabel(vm.isRunning ? "Proxy running" : "Proxy stopped")

            if vm.isRunning {
                SessionStatsView(state: vm.localProxyState, reportCard: vm.sessionReportCard, upstreamProviderTitle: vm.upstreamProvider.title)
            }

            Divider()

            Picker("Model", selection: Binding(
                get: { vm.selectedXcodeAgentModel },
                set: { vm.selectedXcodeAgentModel = $0 }
            )) {
                ForEach(vm.xcodeAgentModelCandidates, id: \.self) { model in
                    Text(model).tag(model)
                }
            }

            Divider()

            if vm.isRunning {
                Button("Stop Proxy") {
                    Task { await vm.stopProxy() }
                }
                .accessibilityLabel("Stop proxy")
                .accessibilityHint("Stops the local proxy server")

                Button("Restart Proxy") {
                    Task { await vm.restartProxy() }
                }
                .accessibilityLabel("Restart proxy")
                .accessibilityHint("Restarts the local proxy server")
            } else {
                Button("Start Proxy") {
                    Task { await vm.startProxy() }
                }
                .accessibilityLabel("Start proxy")
                .accessibilityHint("Starts the local proxy server")
            }

            Divider()

            Button("Open Settings...") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: .command)
            .accessibilityLabel("Open ProxyPilot settings")

            Button("Check for Updates...") {
                updateService.checkForUpdates()
            }
            .disabled(!updateService.canCheckForUpdates)
            .accessibilityLabel("Check for software updates")

            Divider()

            Button("Quit ProxyPilot") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
            .accessibilityLabel("Quit ProxyPilot")
        }
    }
}
