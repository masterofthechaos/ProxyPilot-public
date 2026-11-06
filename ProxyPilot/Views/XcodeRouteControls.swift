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
                if vm.hasPendingXcodeAgentModelChange { Label("Changes pending", systemImage: "clock").font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button(vm.isRunning ? "Apply & Restart" : "Start Proxy") {
                        if vm.isRunning { confirmRestart = true }
                        else { Task { await vm.startProxy() } }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.effectiveXcodeAgentModel.isEmpty || (vm.isRunning ? !vm.canRestartProxy : !vm.canStartProxy))
                    if vm.isRunning {
                        Button("Stop", role: .destructive) { Task { await vm.stopProxy() } }
                            .disabled(!vm.canStopProxy)
                    }
                    Spacer()
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
        FavoriteModelPickerContent(vm: vm, favorites: vm.modelFavorites)
    }
}

private struct FavoriteModelPickerContent: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var favorites: ModelFavoritesStore

    private var favoriteIDs: [String] { favorites.favorites(providerID: vm.selectedUpstreamSelection.id).sorted() }
    private var otherIDs: [String] {
        Set(vm.xcodeAgentModelCandidates + [vm.selectedXcodeAgentModel])
            .subtracting(favoriteIDs).filter { !$0.isEmpty }.sorted()
    }

    var body: some View {
        Picker("Xcode model", selection: Binding(get: { vm.selectedXcodeAgentModel }, set: {
            vm.useBrowserModel(.idOnly($0), selection: vm.selectedUpstreamSelection)
        })) {
            if vm.selectedXcodeAgentModel.isEmpty { Text("Choose a model…").tag("") }
            if !favoriteIDs.isEmpty {
                Section("Favorite Models") {
                    ForEach(favoriteIDs, id: \.self) { Text($0).tag($0) }
                }
            }
            Section("Available models") {
                ForEach(otherIDs, id: \.self) { Text($0).tag($0) }
            }
        }
        .task(id: vm.selectedUpstreamSelection) { vm.prepareBrowser(vm.selectedUpstreamSelection) }
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
            if vm.hasPendingXcodeAgentModelChange { Label("Changes pending", systemImage: "clock").font(.caption).foregroundStyle(.orange) }
            Text("Xcode · " + vm.upstreamProviderDisplayTitle).font(.headline)
            Text("Selected: " + (vm.effectiveXcodeAgentModel.isEmpty ? "Choose a model" : vm.effectiveXcodeAgentModel))
                .font(.caption).lineLimit(1).help(vm.effectiveXcodeAgentModel)
            Text("Running: " + (vm.isRunning ? vm.xcodeAgentAppliedModelText : "Proxy stopped"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).help(vm.xcodeAgentAppliedModelText)
        }
    }
    private var action: some View {
        Button(vm.isRunning ? "Apply & Restart" : "Start Proxy") {
            if vm.isRunning { confirmRestart = true } else { Task { await vm.startProxy() } }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!vm.hasSelectedProvider || vm.effectiveXcodeAgentModel.isEmpty || (vm.isRunning ? !vm.canRestartProxy : !vm.canStartProxy))
    }
}
