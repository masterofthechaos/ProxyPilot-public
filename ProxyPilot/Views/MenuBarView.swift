import SwiftUI
import ProxyPilotCore

private struct SessionStatsView: View {
    @ObservedObject var state: LocalProxyState
    @ObservedObject var reportCard: SessionReportCard
    let upstreamProviderTitle: String
    let estimatedCostText: String?

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
                if let estimatedCostText {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(estimatedCostText)
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
    /// Shared with Home and the Routing section via `AppViewModel`.
    ///
    /// This was a view-local `@StateObject` on the reasoning that two readers of
    /// the same `route.json` agree anyway. They do — but Home had no reader at
    /// all, so it had nothing to show for a CLI-owned route and fell back to the
    /// Xcode selection. One owner fixes that and removes the second source of
    /// truth in the same move.
    private var routeControl: RouteControlService { vm.routeControl }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(visibleOrderedSections.enumerated()), id: \.element) { index, section in
                if index > 0 {
                    Divider()
                }
                menuBarSection(section)
            }

            if !visibleOrderedSections.isEmpty {
                Divider()
            }

            Button("Settings…") {
                DashboardNavigation.openSettings(viewModel: vm, openWindow: openWindow)
            }
            .keyboardShortcut(",", modifiers: .command)
            .accessibilityLabel("Open ProxyPilot settings")

            Divider()

            Button("Quit ProxyPilot") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
            .accessibilityLabel("Quit ProxyPilot")
        }
        .onAppear {
            vm.importExternalSessionReportEvents()
        }
        .task {
            await vm.refreshRouteControlNow()
        }
    }

    private var visibleOrderedSections: [MenuBarSection] {
        vm.menuBarSectionOrder.filter {
            vm.visibleMenuBarSections.contains($0)
                && (vm.repoGPSRoutingFeatureEnabled || $0 != .repoGPSRoute)
        }
    }

    /// The RepoGPS route, settable from the third surface.
    ///
    /// Picking here goes through the same `proxypilot route set` the Routing
    /// settings section uses, so the CLI stays the single writer of
    /// `route.json` and its `route.lock` still serializes every switch. The
    /// label carries the restart because applying a route stops and respawns
    /// the daemon, ending any RepoGPS request in flight — a menu has nowhere
    /// good to put a confirmation, so the warning goes in the name.
    @ViewBuilder
    private var repoGPSRoutePicker: some View {
        switch routeControl.availability {
        case .missing:
            Text("RepoGPS route unavailable — ProxyPilot CLI not found")
        case .tooOld:
            Text("RepoGPS route unavailable — CLI predates route control")
        case .ready:
            Picker("RepoGPS Model (restarts proxy)", selection: Binding(
                get: { routeControl.status.model ?? "" },
                set: { newModel in
                    guard !newModel.isEmpty, newModel != routeControl.status.model else { return }
                    guard let provider = routeControl.status.provider
                        ?? (vm.hasSelectedProvider && !vm.hasActiveCustomProvider ? vm.upstreamProvider.rawValue : nil)
                    else { return }
                    guard RouteInterruptionConfirmation.confirm(route: "the RepoGPS proxy") else { return }
                    Task {
                        await routeControl.applyRoute(
                            provider: provider,
                            model: newModel,
                            port: routeControl.status.port
                        )
                    }
                }
            )) {
                if routeControl.status.model == nil {
                    Text("No route selected").tag("")
                }
                ForEach(repoGPSModelChoices, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .disabled(routeControl.isApplying)
        }
    }

    /// Keeps the route's current model selectable even when the GUI has not
    /// discovered it, so opening the menu cannot silently retarget the route.
    private var repoGPSModelChoices: [String] {
        let selection = routeControl.status.provider.flatMap(UpstreamProvider.init(rawValue:)).map(UpstreamSelection.builtIn) ?? .none
        var choices = Array(Set(vm.browserModels(selection).map(\.id))
            .union(vm.modelFavorites.favorites(providerID: selection.id))).sorted()
        if let current = routeControl.status.model, !current.isEmpty, !choices.contains(current) {
            choices.insert(current, at: 0)
        }
        return choices
    }

    @ViewBuilder
    private func menuBarSection(_ section: MenuBarSection) -> some View {
        switch section {
        case .statusDetails:
            HStack(spacing: 6) {
                Circle()
                    .fill(vm.isRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(vm.isRunning ? "Proxy Running" : "Proxy Stopped")
                if let badge = AppBuildBadge.current {
                    Text(badge.text)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(badge.tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(badge.tint)
                }
            }
            .accessibilityLabel(vm.isRunning ? "Proxy running" : "Proxy stopped")
        case .modelPicker:
            // Named for its route. An unqualified "Model" read as though it
            // governed everything the proxy serves, when it only ever set the
            // Xcode / Claude Agent route — RepoGPS has its own, below.
            FavoriteModelPicker()
        case .repoGPSRoute:
            repoGPSRoutePicker
        case .sessionStats:
            if vm.isRunning || vm.localProxyState.sessionRequestCount > 0 {
                SessionStatsView(
                    state: vm.localProxyState,
                    reportCard: vm.sessionReportCard,
                    // The serving provider, not the configured one. The model
                    // beside it has always been observed traffic, so pairing it
                    // with the GUI's Xcode provider produced a sentence whose
                    // two halves described different routes — correct only
                    // while both happened to point at the same provider.
                    upstreamProviderTitle: vm.sessionMenuProviderTitle,
                    estimatedCostText: vm.sessionMenuCostText
                )
            } else {
                Text("No session activity")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .quickActions:
            if vm.canStopProxy {
                Button("Stop Proxy") {
                    Task { await vm.stopProxy() }
                }
                .accessibilityLabel("Stop proxy")
                .accessibilityHint("Stops the local proxy server")

                Button("Apply & Restart") {
                    guard RouteInterruptionConfirmation.confirm(route: "the Xcode proxy") else { return }
                    Task { await vm.restartProxy() }
                }
                .accessibilityLabel("Restart proxy")
                .accessibilityHint("Restarts the local proxy server")
            } else if vm.canStartProxy {
                Button("Start Proxy") {
                    Task { await vm.startProxy() }
                }
                .accessibilityLabel("Start proxy")
                .accessibilityHint("Starts the local proxy server")
            } else {
                Text(vm.statusText)
                    .foregroundStyle(.secondary)
            }
        case .updates:
            Button("Check for Updates...") {
                updateService.checkForUpdates()
            }
            .disabled(!updateService.canCheckForUpdates)
            .accessibilityLabel("Check for software updates")
        }
    }
}
