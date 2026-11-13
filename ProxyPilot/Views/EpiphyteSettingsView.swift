import SwiftUI
import ProxyPilotCore

struct EpiphyteSettingsView: View {
    @EnvironmentObject private var vm: AppViewModel
    var embedded = false
    var onOpenModels: () -> Void = {}
    @State private var provider: UpstreamProvider?
    @State private var model = ""
    @State private var hasLoaded = false
    private var service: EpiphyteControlService { vm.epiphyteControl }

    var body: some View {
        Group {
            if embedded {
                VStack(alignment: .leading, spacing: 12) {
                    activitySummary
                    modelControls
                    modelFooter
                }
            } else {
                Form {
                    Section { activitySummary
                        Text("Epi asks ProxyPilot for independent page-copy proposals. Each request runs temporarily; the shared Xcode proxy may remain stopped.")
                            .font(.callout).foregroundStyle(.secondary)
                    } header: { Text("Epiphyte") }
                    Section { modelControls } header: { Text("Epi Model") } footer: { modelFooter }
                }.formStyle(.grouped)
            }
        }
        .task {
            await service.refresh()
            if !hasLoaded { loadSaved(); hasLoaded = true }
        }
        .task(id: provider) { if let provider { await vm.refreshBrowser(.builtIn(provider)) } }
        .onChange(of: provider) { old, new in
            if old != nil, new?.rawValue != service.status.provider { model = "" }
        }
        .onReceive(vm.providerCatalog.objectWillChange) { _ in vm.objectWillChange.send() }
    }
    private var activitySummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(service.badgeTitle, systemImage: service.activeRequests.isEmpty ? "leaf" : "leaf.fill")
                .foregroundStyle(service.activeRequests.isEmpty ? Color.secondary : Color.green)
            ForEach(service.activeRequests, id: \.sessionID) { request in
                LabeledContent("In flight", value: "\(request.provider) / \(request.model)")
                    .font(.caption).textSelection(.enabled)
            }
        }
    }
    private var modelControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .ready = service.availability {
                Picker("Epiphyte provider", selection: $provider) {
                    Text("Choose a provider…").tag(Optional<UpstreamProvider>.none)
                    ForEach(UpstreamProvider.allCases) { Text($0.title).tag(Optional($0)) }
                }
                Picker("Epiphyte model", selection: $model) {
                    Text("Choose a model…").tag("")
                    ForEach(choices, id: \.self) { Text($0).tag($0) }
                }
                TextField("Model ID", text: $model)
                    .help("Use a discovered model or enter an exact provider model ID.")
                LabeledContent("Saved model", value: service.selectionSummary)
                    .font(.caption).textSelection(.enabled)
                HStack {
                    Button("Save Model") {
                        // Freeze the authored provider/model before an async task
                        // can observe another edit or the Home target changing.
                        guard let submittedProvider = provider else { return }
                        let submission = ConnectionModelSubmission.epiphyte(provider: submittedProvider.rawValue, model: model)
                        Task {
                            await submission.apply(repoGPS: vm.routeControl, epiphyte: service)
                            if service.lastError == nil { loadSaved() }
                        }
                    }.disabled(provider == nil || model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !hasChanges || service.isSaving)
                    Button("Revert", action: loadSaved).disabled(!hasChanges || service.isSaving)
                    if service.isSaving { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Refresh") { Task { await service.refresh() } }
                }
            }
            if let error = service.lastError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Button("Browse Providers & Models", action: onOpenModels)
        }
    }
    private var modelFooter: some View {
        Text("Saved changes apply to Epiphyte's next request after Refresh Connection. They do not restart the proxy, interrupt an in-flight request, or change RepoGPS or Xcode. Provider credentials stay in ProxyPilot.")
            .font(.caption).foregroundStyle(.secondary)
    }
    private var hasChanges: Bool { provider?.rawValue != service.status.provider || model != (service.status.model ?? "") }
    private var choices: [String] {
        let selection = provider.map(UpstreamSelection.builtIn) ?? .none
        var values = Set(vm.browserModels(selection).map(\.id)).union(vm.modelFavorites.favorites(providerID: selection.id))
        if provider?.rawValue == service.status.provider, let saved = service.status.model { values.insert(saved) }
        if !model.isEmpty { values.insert(model) }
        return values.sorted()
    }
    private func loadSaved() {
        provider = service.status.provider.flatMap(UpstreamProvider.init(rawValue:))
        model = service.status.model ?? ""
    }
}
