import SwiftUI
import ProxyPilotCore

/// Shows ProxyPilot's two routes as peers.
///
/// They are genuinely independent and must stay that way: the Xcode / Claude
/// Agent route is served by the GUI's own proxy from the menu bar selection,
/// while the RepoGPS route is the CLI-owned `route.json` that `rgps` starts a
/// daemon against. Before this section existed the GUI showed CLI-daemon
/// traffic in Session History without offering any way to steer it, so the
/// menu bar appeared to control RepoGPS while having no effect on it.
///
/// Deliberately *not* a single merged picker — changing the model Xcode uses
/// must not change the model RepoGPS uses, and vice versa.
struct RoutingView: View {
    @EnvironmentObject private var vm: AppViewModel
    var onOpenXcodeSetup: () -> Void = {}

    /// Shared with Home and the menu bar via `AppViewModel`. Previously a
    /// view-local `@StateObject`, which left Home unable to see the CLI route
    /// at all.
    private var routeControl: RouteControlService { vm.routeControl }

    /// Pending RepoGPS selection. Held locally so the route only changes when
    /// the owner commits it — picking a model must not restart their daemon.
    @State private var pendingProvider: UpstreamProvider = .openRouter
    @State private var pendingModel: String = ""
    @State private var hasLoadedPending = false
    @State private var cliInstallError: String?

    var body: some View {
        Form {
            xcodeRouteSection
            repoGPSRouteSection
        }
        .formStyle(.grouped)
        .task {
            await vm.refreshRouteControlNow()
            loadPendingFromRouteIfNeeded()
        }
    }

    // MARK: - Xcode / Claude Agent

    private var xcodeRouteSection: some View {
        Section {
            LabeledContent("Provider") {
                Text(vm.upstreamProviderDisplayTitle)
                    .foregroundStyle(.secondary)
            }

            Picker("Model", selection: Binding(
                get: { vm.selectedXcodeAgentModel },
                set: { vm.selectedXcodeAgentModel = $0 }
            )) {
                ForEach(vm.xcodeAgentModelCandidates, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(.menu)

            Button("Open Xcode Setup", action: onOpenXcodeSetup)

            // Deliberately `vm.statusText` rather than a synthesized
            // "Serving on port N". `vm.isRunning` is true whenever *a* proxy
            // answers on the port — including a CLI daemon the GUI does not
            // own — so claiming the GUI is serving would reproduce, in this
            // very section, the misattribution the section exists to end.
            // `statusText` already distinguishes "Running" from
            // "Running (via CLI)".
            routeStatusRow(
                isLive: vm.isRunning,
                title: vm.statusText,
                caption: vm.xcodeAgentRoutingSummaryText
            )
        } header: {
            Text("Xcode")
        } footer: {
            Text("This is your Xcode selection. Use Xcode Setup to choose a provider, discover models, and apply changes. A background proxy may also serve other clients.")
                .font(.caption)
        }
    }

    // MARK: - RepoGPS

    @ViewBuilder
    private var repoGPSRouteSection: some View {
        Section {
            switch routeControl.availability {
            case .missing:
                cliDependencyRow(
                    message: "ProxyPilot CLI not found. Install it to route RepoGPS.",
                    actionTitle: "Install ProxyPilot CLI"
                )

            case .tooOld(let url):
                cliDependencyRow(
                    message: "The ProxyPilot CLI at \(url.path) predates route control. Update it to steer RepoGPS from here.",
                    actionTitle: "Update ProxyPilot CLI"
                )

            case .ready:
                Picker("Provider", selection: $pendingProvider) {
                    ForEach(UpstreamProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .pickerStyle(.menu)

                Picker("Model", selection: $pendingModel) {
                    if pendingModel.isEmpty {
                        Text("Select a model").tag("")
                    }
                    ForEach(modelChoices, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)

                routeStatusRow(
                    isLive: routeControl.status.isServing,
                    title: routeControl.status.summary,
                    caption: currentRouteCaption
                )

                if let error = routeControl.lastError {
                    Label(error, systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                HStack {
                    Button("Restart & Apply Changes") {
                        Task {
                            await routeControl.applyRoute(
                                provider: pendingProvider.rawValue,
                                model: pendingModel,
                                port: routeControl.status.port
                            )
                            loadPendingFromRoute()
                        }
                    }
                    .disabled(!canApply)

                    Button("Revert") { loadPendingFromRoute() }
                        .disabled(!hasPendingChange)

                    if routeControl.isApplying {
                        ProgressView().controlSize(.small)
                    }

                    Spacer()

                    Button("Refresh") { Task { await routeControl.refresh() } }
                        .font(.caption)
                }
            }
        } header: {
            Text("RepoGPS")
        } footer: {
            Text(
                "Applying changes restarts the background proxy and interrupts requests using it, "
                + "including Xcode requests if it shares this proxy. Wait for the current response to finish first."
            )
            .font(.caption)
        }
    }

    // MARK: - Shared pieces

    private func cliDependencyRow(message: String, actionTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)

                Spacer()

                Button(actionTitle) {
                    Task {
                        if await vm.repoGPS.installProxyPilotCLI() {
                            cliInstallError = nil
                            await routeControl.refresh()
                            loadPendingFromRoute()
                        } else {
                            cliInstallError = vm.repoGPS.lastError
                        }
                    }
                }
                .disabled(vm.repoGPS.isInstallingProxyPilotCLI)

                if vm.repoGPS.isInstallingProxyPilotCLI {
                    ProgressView().controlSize(.small)
                }
            }

            if let cliInstallError {
                Text(cliInstallError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func routeStatusRow(isLive: Bool, title: String, caption: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isLive ? "circle.fill" : "circle")
                .font(.caption2)
                .foregroundStyle(isLive ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The RepoGPS route may point at a provider whose models the GUI has not
    /// discovered. Keep the active model selectable so applying an unrelated
    /// change cannot silently retarget the route.
    private var modelChoices: [String] {
        var choices = vm.xcodeAgentModelCandidates
        if let current = routeControl.status.model, !current.isEmpty, !choices.contains(current) {
            choices.insert(current, at: 0)
        }
        if !pendingModel.isEmpty, !choices.contains(pendingModel) {
            choices.insert(pendingModel, at: 0)
        }
        return choices
    }

    private var currentRouteCaption: String {
        guard let provider = routeControl.status.provider,
              let model = routeControl.status.model else {
            return "No background model configured"
        }
        return "Background proxy · \(provider) / \(model)"
    }

    private var hasPendingChange: Bool {
        pendingProvider.rawValue != routeControl.status.provider
            || pendingModel != (routeControl.status.model ?? "")
    }

    private var canApply: Bool {
        !routeControl.isApplying && !pendingModel.isEmpty && hasPendingChange
    }

    /// Seed the pending selection once, so a background refresh cannot discard
    /// a choice the owner is midway through making.
    private func loadPendingFromRouteIfNeeded() {
        guard !hasLoadedPending else { return }
        hasLoadedPending = true
        loadPendingFromRoute()
    }

    private func loadPendingFromRoute() {
        if let provider = routeControl.status.provider,
           let match = UpstreamProvider(rawValue: provider) {
            pendingProvider = match
        }
        pendingModel = routeControl.status.model ?? ""
    }
}
