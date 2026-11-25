import SwiftUI
import ProxyPilotCore

/// Every consumer edits the same Xcode selection and invokes the same lifecycle.
struct XcodeRouteControls: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var confirmRestart = false
    var showsProvider = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsProvider {
                Picker("Xcode provider", selection: Binding(get: { vm.selectedUpstreamSelection }, set: { vm.selectedUpstreamSelection = $0 })) {
                    Text("Choose a provider…").tag(UpstreamSelection.none)
                    ForEach(UpstreamProvider.allCases) { provider in
                        Text(provider.title).tag(UpstreamSelection.builtIn(provider))
                    }
                    ForEach(vm.customProviders) { provider in
                        Text(provider.name).tag(UpstreamSelection.custom(provider.id))
                    }
                }
            }
            if vm.hasSelectedProvider {
                FavoriteModelPicker()
                LabeledContent("Selected", value: vm.effectiveXcodeAgentModel.isEmpty ? "Choose a model" : vm.effectiveXcodeAgentModel)
                LabeledContent("Running", value: vm.isRunning ? vm.xcodeAgentAppliedModelText : "Proxy stopped")
                if let loadState = vm.xcodeModelLoadState {
                    Label(
                        loadState.summary(providerTitle: vm.upstreamProviderDisplayTitle),
                        systemImage: loadState.isLoaded ? "checkmark.circle" : "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(loadState.isLoaded ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if vm.hasPendingXcodeRouteChange { Label("Changes pending", systemImage: "clock").font(.caption).foregroundStyle(.orange) }
                switch vm.menuBarProxyOwnership.xcodeSectionControls {
                case .repoGPSRouteServing(let port):
                    // Applying here would stop the RepoGPS route and start the
                    // Xcode proxy on the same port. Offer only the route's own
                    // stop, with its confirmation, as the menu does.
                    XcodeSectionRepoGPSRouteNotice(port: port)
                case .xcode(let stopTitle):
                    HStack {
                        Button(vm.isRunning ? "Apply & Restart" : "Start Xcode Proxy") {
                            if vm.isRunning { confirmRestart = true }
                            else { Task { await vm.startProxy() } }
                        }
                        .xcodeRouteActionProminence(vm)
                        .disabled(vm.effectiveXcodeAgentModel.isEmpty || (vm.isRunning ? !vm.canRestartProxy : !vm.canStartProxy))
                        if let stopTitle {
                            Button(stopTitle, role: .destructive) { Task { await vm.stopProxy() } }
                                .disabled(!vm.canStopProxy)
                        }
                        Spacer()
                    }
                }
                Text("Selection is shared across ProxyPilot. A running route changes only when you apply it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Apply selection and restart the proxy?", isPresented: $confirmRestart) {
            Button("Apply & Restart", role: .destructive) { Task { await vm.restartProxy() } }
        } message: {
            Text("Restarting interrupts requests using this proxy, including other clients. Continue only when you are ready to interrupt them.")
        }
    }
}

struct FavoriteModelPicker: View {
    @EnvironmentObject private var vm: AppViewModel
    var body: some View {
        FavoriteModelPickerContent(vm: vm, favorites: vm.modelFavorites, catalog: vm.providerCatalog)
    }
}

private struct FavoriteModelPickerContent: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var favorites: ModelFavoritesStore
    @ObservedObject var catalog: ProviderCatalogStore

    private var identity: ProviderCatalogStore.Identity { vm.browserIdentity(vm.selectedUpstreamSelection) }
    private var favoriteIDs: [String] { favorites.favorites(providerID: vm.selectedUpstreamSelection.id).sorted() }
    private var otherIDs: [String] {
        Set(vm.xcodeModelMenuCandidates + [vm.selectedXcodeAgentModel])
            .subtracting(favoriteIDs).filter { !$0.isEmpty }.sorted()
    }
    private var hasChoices: Bool { !favoriteIDs.isEmpty || !otherIDs.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Xcode model", selection: Binding(get: { vm.selectedXcodeAgentModel }, set: {
                vm.useBrowserModel(.idOnly($0), selection: vm.selectedUpstreamSelection)
            })) {
                if vm.selectedXcodeAgentModel.isEmpty { Text("Choose a model…").tag("") }
                if !favoriteIDs.isEmpty {
                    Section("Favorite Models") {
                        ForEach(favoriteIDs, id: \.self) { Text($0).tag($0) }
                    }
                }
                if !otherIDs.isEmpty {
                    Section("Available models") {
                        ForEach(otherIDs, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            .disabled(!hasChoices)
            if !hasChoices {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if catalog.loading.contains(identity) {
                        ProgressView().controlSize(.small)
                        Text("Loading models…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(vm.xcodeModelMenuEmptyMessage(error: catalog.errors[identity]))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Refresh Models") { Task { await vm.refreshXcodeModelMenu(force: true) } }
                            .controlSize(.small)
                    }
                }
            }
        }
        .task(id: vm.selectedUpstreamSelection) { await vm.refreshXcodeModelMenu() }
        .task(id: vm.effectiveXcodeAgentModel) { await vm.refreshXcodeModelLoadState() }
    }
}

/// Always-visible compact application bar in the model browser.
struct XcodeRouteActionBar: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var confirmRestart = false
    var body: some View {
        ViewThatFits {
            HStack(spacing: 12) { summary; Spacer(); action }
            VStack(alignment: .leading, spacing: 8) { summary; action }
        }
        .confirmationDialog("Apply selection and restart?", isPresented: $confirmRestart) {
            Button("Apply & Restart", role: .destructive) { Task { await vm.restartProxy() } }
        } message: { Text("Restarting interrupts requests using this proxy, including other clients.") }
    }
    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            if vm.hasPendingXcodeRouteChange { Label("Changes pending", systemImage: "clock").font(.caption).foregroundStyle(.orange) }
            Text("Xcode · " + vm.upstreamProviderDisplayTitle).font(.headline)
            Text("Selected: " + (vm.effectiveXcodeAgentModel.isEmpty ? "Choose a model" : vm.effectiveXcodeAgentModel))
                .font(.caption).lineLimit(1).help(vm.effectiveXcodeAgentModel)
            Text("Running: " + (vm.isRunning ? vm.xcodeAgentAppliedModelText : "Proxy stopped"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).help(vm.xcodeAgentAppliedModelText)
        }
    }
    @ViewBuilder
    private var action: some View {
        switch vm.menuBarProxyOwnership.xcodeSectionControls {
        case .repoGPSRouteServing(let port):
            XcodeSectionRepoGPSRouteNotice(port: port)
        case .xcode:
            Button(vm.isRunning ? "Apply & Restart" : "Start Xcode Proxy") {
                if vm.isRunning { confirmRestart = true } else { Task { await vm.startProxy() } }
            }
            .xcodeRouteActionProminence(vm)
            .disabled(!vm.hasSelectedProvider || vm.effectiveXcodeAgentModel.isEmpty || (vm.isRunning ? !vm.canRestartProxy : !vm.canStartProxy))
        }
    }
}

/// Shown in Xcode sections while the RepoGPS route is what serves the port.
private struct XcodeSectionRepoGPSRouteNotice: View {
    @EnvironmentObject private var vm: AppViewModel
    let port: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The RepoGPS route is serving port \(port). Starting the Xcode proxy here would replace it; stop the route first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(MenuBarProxyOwnership.Action.stopRepoGPSRoute.title, role: .destructive) {
                ProxyControlActionRunner.run(.stopRepoGPSRoute, vm: vm)
            }
            .disabled(vm.isStoppingCLIProxy)
        }
    }
}

private extension View {
    /// Start is the primary action when the proxy is stopped. While it runs,
    /// Apply & Restart stays available but is emphasized only when the
    /// selection differs from what is being served.
    @ViewBuilder
    @MainActor
    func xcodeRouteActionProminence(_ vm: AppViewModel) -> some View {
        if !vm.isRunning || vm.hasPendingXcodeRouteChange {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}
