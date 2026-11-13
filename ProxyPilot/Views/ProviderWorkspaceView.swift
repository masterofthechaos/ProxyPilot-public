import AppKit
import SwiftUI
import ProxyPilotCore

struct ProviderWorkspaceView: View {
    @EnvironmentObject private var vm: AppViewModel
    var compact = false
    var body: some View {
        ProviderWorkspaceContent(vm: vm, catalog: vm.providerCatalog, favorites: vm.modelFavorites, checks: vm.providerConnectionTests, compact: compact)
    }
}

private struct ComparedModel: Identifiable {
    let provider: UpstreamSelection
    let providerTitle: String
    let model: UpstreamModel
    var id: String { provider.id + "/" + model.id }
}

private struct ProviderWorkspaceContent: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var catalog: ProviderCatalogStore
    @ObservedObject var favorites: ModelFavoritesStore
    @ObservedObject var checks: ProviderConnectionTests
    var compact: Bool
    @State private var manageProvidersExpanded = false
    @State private var showHiddenProviders = false
    @State private var testModelID = ""
    @State private var rowTestModelID: String?
    @State private var credentialPresence: [UpstreamSelection: Bool] = [:]
    @State private var browsing: UpstreamSelection = .none
    @State private var query = ModelBrowserQuery()
    @State private var configurationExpanded = false
    @State private var endpointDraft = ""
    @State private var keyDraft = ""
    @State private var manualID = ""
    @State private var message: String?
    @State private var showAddProvider = false
    @State private var confirmDeleteKey = false
    @State private var confirmDeleteProvider = false
    @State private var showComparison = false
    @State private var compared: [ComparedModel] = []

    private var browsableProviders: [UpstreamProvider] {
        vm.keysProviderOrder.map(\.provider).filter {
            showHiddenProviders || vm.isKeysProviderVisible($0) || browsing == .builtIn($0)
        }
    }
    private var identity: ProviderCatalogStore.Identity { vm.browserIdentity(browsing) }
    private var favoriteIDs: Set<String> { favorites.favorites(providerID: browsing.id) }
    private var liveModels: [UpstreamModel] { vm.browserModels(browsing) }
    private var models: [UpstreamModel] {
        let known = Set(liveModels.map(\.id))
        let saved = favoriteIDs.union(vm.browserSavedModels(browsing))
        return liveModels + saved.subtracting(known).sorted().map(UpstreamModel.idOnly)
    }
    private var results: [UpstreamModel] { query.results(models, favorites: favoriteIDs) }
    private var labs: [String] { Array(Set(models.map { $0.lab ?? "Unknown" })).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
          HStack(alignment: .top, spacing: 14) {
           if !compact {
               ScrollView { providerOverview.padding(6) }
                   .fixedSize(horizontal: true, vertical: false)
               Divider()
           }
          ScrollView {
           VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Providers & Models").font(.title2.bold())
                Spacer()
                Button("Add Provider", systemImage: "plus") { showAddProvider = true }
            }
            if compact {
                DisclosureGroup("Manage providers · " + vm.browserTitle(browsing), isExpanded: $manageProvidersExpanded) {
                    providerOverview.padding(.top, 8)
                }
            } else {
                Text(vm.browserTitle(browsing)).font(.headline)
            }
            Text("Explore providers without changing your Xcode selection.")
                .font(.caption).foregroundStyle(.secondary)
            if browsing == .none {
                ContentUnavailableView("Choose a provider", systemImage: "square.stack.3d.up",
                    description: Text("Configure credentials, browse models and build your favorites here."))
            } else {
                configuration
                connectionChecks
                filters
                HStack {
                    Text("\(results.count) models").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if catalog.loading.contains(identity) { ProgressView().controlSize(.small) }
                    if let date = catalog.snapshots[identity]?.fetchedAt {
                        Text("Updated \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await vm.refreshBrowser(browsing, force: true) } }
                        .disabled(catalog.loading.contains(identity))
                }
                if let error = catalog.errors[identity] {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    Text("Previously loaded models remain available.").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Enter a model ID manually") {
                HStack {
                    TextField("Enter a model ID", text: $manualID).textFieldStyle(.roundedBorder)
                    Button("Use for Xcode") {
                        vm.useBrowserModel(.idOnly(manualID.trimmingCharacters(in: .whitespacesAndNewlines)), selection: browsing)
                        manualID = ""
                    }.disabled(manualID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                        if results.isEmpty {
                            ContentUnavailableView("No matching models", systemImage: "magnifyingglass",
                                description: Text(vm.browserRequiresKey(browsing) && !hasKey(browsing)
                                    ? "Save a provider key to load its catalog, or enter a model ID."
                                    : "Clear filters, refresh the catalog, or enter a model ID."))
                        }
                        ForEach(results) { model in modelRow(model); Divider() }
                }
                .frame(minHeight: 160)

            }
           }
           .padding(6) // Keep native keyboard focus rings inside the scroll viewport.
          }
          }
            Divider()
            if !compared.isEmpty {
                HStack {
                    Button("Compare (\(compared.count)/3)") { showComparison = true }.disabled(compared.count < 2)
                    Button("Clear comparison") { compared = [] }
                    Spacer()
                }
            }
            XcodeRouteActionBar()
        }
        .padding(24)
        .task {
            refreshCredentialPresence()
            if browsing == .none { browsing = vm.selectedUpstreamSelection }
        }
        .task(id: browsing) {
            if credentialPresence.isEmpty { refreshCredentialPresence() }
            endpointDraft = vm.browserEndpoint(browsing)
            keyDraft = ""
            configurationExpanded = true
            testModelID = vm.browserModels(browsing).first?.id ?? ""
            rowTestModelID = nil
            query = ModelBrowserQuery()
            message = nil
            await vm.refreshBrowser(browsing)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshCredentialPresence()
        }
        .onChange(of: vm.customProviders.map(\.id)) { _, _ in refreshCredentialPresence() }
        .onChange(of: liveModels.map(\.id), initial: true) { _, ids in
            if !ids.contains(testModelID) { testModelID = ids.first ?? "" }
        }
        .onChange(of: vm.providerWorkspaceShowsConfiguration) { _, expanded in
            if expanded { configurationExpanded = true }
        }
        .sheet(isPresented: $showAddProvider) {
            AddCustomProviderView { name, url, key in
                vm.addCustomProvider(name: name, apiBaseURL: url, apiKey: key)
                refreshCredentialPresence()
                if let added = vm.customProviders.last { browsing = .custom(added.id) }
            }
        }
        .sheet(isPresented: $showComparison) { comparison }
        .confirmationDialog("Remove the stored provider key?", isPresented: $confirmDeleteKey) {
            Button("Remove Key", role: .destructive) { vm.deleteBrowserKey(browsing); refreshCredentialPresence() }
        } message: { Text("Future requests may fail until you supply another key.") }
        .confirmationDialog("Remove this custom provider?", isPresented: $confirmDeleteProvider) {
            Button("Remove Provider", role: .destructive) {
                if case .custom(let id) = browsing, let provider = vm.customProviders.first(where: { $0.id == id }) {
                    vm.deleteCustomProvider(provider)
                    browsing = .none
                }
            }
        }
    }

    private func hasKey(_ selection: UpstreamSelection) -> Bool {
        credentialPresence[selection] ?? false
    }

    private func refreshCredentialPresence() {
        let providers = UpstreamProvider.allCases.map(UpstreamSelection.builtIn)
            + vm.customProviders.map { UpstreamSelection.custom($0.id) }
        credentialPresence = Dictionary(uniqueKeysWithValues: providers.map { ($0, vm.browserHasKey($0)) })
    }

    private var providerOverview: some View {
        let providers = (browsableProviders.map(UpstreamSelection.builtIn)
            + vm.customProviders.map { UpstreamSelection.custom($0.id) }).sorted {
                let order = vm.browserTitle($0).localizedStandardCompare(vm.browserTitle($1))
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
        let saved = providers.filter { hasKey($0) }
        let remaining = providers.filter { !hasKey($0) }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Providers").font(.headline)
            Text("Credential status · saved ≠ tested").font(.caption).foregroundStyle(.secondary)
            if !saved.isEmpty {
                Text("Saved keys").font(.subheadline.bold()).padding(.top, 8)
                ForEach(saved, id: \.id) { providerButton($0) }
            }
            if !remaining.isEmpty {
                if !saved.isEmpty { Divider().padding(.vertical, 6) }
                Text("Other providers").font(.subheadline.bold()).padding(.top, 8)
                ForEach(remaining, id: \.id) { providerButton($0) }
            }
            Toggle("Show hidden providers", isOn: $showHiddenProviders).toggleStyle(.checkbox).font(.caption)
        }
    }

    private func providerButton(_ selection: UpstreamSelection) -> some View {
        Button {
            browsing = selection
        } label: {
            HStack {
                Image(systemName: hasKey(selection) ? "key.fill" : "key")
                VStack(alignment: .leading, spacing: 3) {
                    Text(vm.browserTitle(selection)).fontWeight(browsing == selection ? .semibold : .regular)
                    Text(hasKey(selection) ? "Key saved" : (vm.browserRequiresKey(selection) ? "Not configured" : "Key optional"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if browsing == selection { Image(systemName: "chevron.right") }
            }.padding(6).contentShape(Rectangle())
                .background(browsing == selection ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
            .accessibilityAddTraits(browsing == selection ? .isSelected : [])
    }

    private var connectionChecks: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Test Catalog Access") {
                    let selection = browsing
                    rowTestModelID = nil
                    Task { await vm.testBrowserConnection(selection) }
                }
                    .disabled(checks.running.contains(identity) || (vm.browserRequiresKey(browsing) && !hasKey(browsing)))
                if checks.running.contains(identity) { ProgressView().controlSize(.small) }
            }
            Text("Checks the saved endpoint's model catalog. It does not prove that a key can run inference.")
                .font(.caption).foregroundStyle(.secondary)
            if vm.repoGPSRoutingFeatureEnabled { RepoGPSRouteTestView() }
            DisclosureGroup("Test a direct model response") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sends a small real request using your saved endpoint and key; provider charges or plan quota may apply. Uses the existing 256-token test limit and 20-second timeout.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Picker("Model to test", selection: $testModelID) {
                            Text("Choose a model…").tag("")
                            ForEach(models.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }) { model in
                                Text(model.displayName ?? model.id).tag(model.id)
                            }
                            if !testModelID.isEmpty && !models.contains(where: { $0.id == testModelID }) {
                                Text(testModelID).tag(testModelID)
                            }
                        }
                        .disabled(models.isEmpty)

                        Button("Test Direct Response") {
                            let model = testModelID.trimmingCharacters(in: .whitespacesAndNewlines)
                            let selection = browsing
                            rowTestModelID = nil
                            Task { await vm.testBrowserConnection(selection, model: model) }
                        }.disabled(testModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checks.running.contains(identity) || (vm.browserRequiresKey(browsing) && !hasKey(browsing)))
                    }
                    if models.isEmpty {
                        Text("Refresh the catalog to choose a model, or use the optional unlisted-model entry.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Test an unlisted model") {
                        TextField("Exact model ID", text: $testModelID).textFieldStyle(.roundedBorder)
                            .padding(6)
                    }
                }
            }
            if let result = checks.results[identity] {
                Label(result.message, systemImage: result.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption).textSelection(.enabled)
                Text("Last check: \(result.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var configuration: some View {
        DisclosureGroup("Provider configuration · \(hasKey(browsing) ? "Key saved" : (vm.browserRequiresKey(browsing) ? "Key needed" : "Key optional"))", isExpanded: $configurationExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if browsing == .builtIn(.qwen) {
                    Picker("Qwen service", selection: Binding(
                        get: { QwenAPIService(apiBaseURL: URL(string: endpointDraft)) },
                        set: { service in
                            if let endpoint = service.endpoint { endpointDraft = endpoint }
                            message = "Choose Save Endpoint to apply this service."
                        }
                    )) {
                        ForEach(QwenAPIService.allCases.filter { $0 != .custom }) { Text($0.title).tag($0) }
                        if QwenAPIService(apiBaseURL: URL(string: endpointDraft)) == .custom {
                            Text("Custom endpoint").tag(QwenAPIService.custom)
                        }
                    }
                    Text(QwenAPIService(apiBaseURL: URL(string: endpointDraft)).keyHint)
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Qwen stores one key. When changing services, save the matching key. Endpoint changes apply when the route is next started or applied.")
                        .font(.caption).foregroundStyle(.secondary)
                    if QwenAPIService(apiBaseURL: URL(string: endpointDraft)).isTokenPlan {
                        Text("For Qwen4 preview, enter qwen4-max-preview below if it is absent from the catalog.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    TextField("API endpoint", text: $endpointDraft).textFieldStyle(.roundedBorder)
                    Button("Save Endpoint") {
                        message = vm.saveBrowserEndpoint(endpointDraft, selection: browsing) ? "Endpoint saved." : "Enter a valid HTTP or HTTPS endpoint without embedded credentials."
                        Task { await vm.refreshBrowser(browsing) }
                    }
                }
                HStack {
                    SecureField("API key", text: $keyDraft).textFieldStyle(.roundedBorder)
                    Button("Save Key") {
                        let saved = vm.saveBrowserKey(keyDraft, selection: browsing)
                        refreshCredentialPresence()
                        if saved { keyDraft = "" }
                        message = saved ? "Key saved." : "Key was not saved. Check its format and try again."
                        Task { await vm.refreshBrowser(browsing, force: true) }
                    }.disabled(keyDraft.isEmpty)
                }
                HStack {
                    if hasKey(browsing) { Button("Remove Key", role: .destructive) { confirmDeleteKey = true } }
                    if case .custom = browsing { Button("Remove Provider", role: .destructive) { confirmDeleteProvider = true } }
                    if case .builtIn(let provider) = browsing,
                       let url = provider.apiKeyPageURL(apiBaseURL: URL(string: endpointDraft)) {
                        Link(provider == .qwen && QwenAPIService(apiBaseURL: URL(string: endpointDraft)).isTokenPlan
                             ? "Get a Token Plan key" : "Get an API key", destination: url)
                    }
                    if browsing == .builtIn(.qwen), QwenAPIService(apiBaseURL: URL(string: endpointDraft)).isTokenPlan {
                        Link("Token Plan setup", destination: URL(string: "https://www.alibabacloud.com/help/en/model-studio/token-plan-team-quickstart")!)
                    }
                }
                if case .builtIn(let provider) = browsing {
                    if provider != .qwen, let hint = provider.apiKeyRegionHint(apiBaseURL: URL(string: endpointDraft)) {
                        Text(hint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if provider.isLocal {
                        Text(vm.localProviderSetupHint(for: provider)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if case .builtIn(let provider) = browsing, provider.isMiniMax {
                    Picker("MiniMax protocol", selection: $vm.miniMaxRoutingMode) {
                        Text("OpenAI compatible").tag(MiniMaxRoutingMode.standard)
                        Text("Anthropic passthrough").tag(MiniMaxRoutingMode.anthropicPassthrough)
                    }
                    Text("Applies to MiniMax routes when next started or applied.").font(.caption).foregroundStyle(.secondary)
                }
                if let message { Text(message).font(.caption) }
                Text("Catalog refresh reads model metadata. It does not send an inference request.").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Models available to clients") {
                    Text("Separate from favorites. Changes take effect when you start or apply the Xcode route.").font(.caption)
                    ScrollView {
                      LazyVStack(alignment: .leading) {
                      ForEach(models) { model in
                        Toggle(model.id, isOn: Binding(get: {
                            vm.browserSavedModels(browsing).contains(model.id)
                        }, set: { vm.setBrowserAdvertised(model.id, selection: browsing, enabled: $0) }))
                      }
                      }
                    }.frame(maxHeight: 160)
                }
            }.padding(.top, 8)
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search models", text: $query.search).textFieldStyle(.roundedBorder)
            ViewThatFits {
                HStack { filterControls }
                VStack(alignment: .leading) { filterControls }
            }
            if !query.labs.isEmpty {
                HStack {
                    ForEach(query.labs.sorted(), id: \.self) { lab in
                        Button { query.labs.remove(lab) } label: { Label(lab, systemImage: "xmark.circle.fill") }
                            .buttonStyle(.borderless).font(.caption)
                    }
                }
            }
        }
    }

    @ViewBuilder private var filterControls: some View {
        Menu("Labs\(query.labs.isEmpty ? "" : " (\(query.labs.count))")") {
            ForEach(labs, id: \.self) { lab in
                Toggle(lab, isOn: Binding(get: { query.labs.contains(lab) }, set: {
                    if $0 { query.labs.insert(lab) } else { query.labs.remove(lab) }
                }))
            }
        }
        Toggle("Favorites", isOn: $query.favoritesOnly).toggleStyle(.checkbox)
        Picker("Price", selection: $query.priceTier) {
            Text("All prices").tag(PricingTier.unknown)
            Text("Free").tag(PricingTier.free)
            Text("Budget").tag(PricingTier.budget)
            Text("Standard").tag(PricingTier.standard)
            Text("Premium").tag(PricingTier.premium)
        }
        Picker("Sort", selection: $query.sort) {
            ForEach(ModelBrowserQuery.Sort.allCases) { Text($0.rawValue).tag($0) }
        }
        Button("Clear Filters") { query = ModelBrowserQuery() }
    }

    private func modelRow(_ model: UpstreamModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Button {
                    favorites.setFavorite(model.id, providerID: browsing.id, enabled: !favoriteIDs.contains(model.id))
                } label: {
                    Image(systemName: favoriteIDs.contains(model.id) ? "star.fill" : "star")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(favoriteIDs.contains(model.id) ? "Remove favorite" : "Favorite") \(model.id)")
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.displayName ?? model.id).fontWeight(.medium).textSelection(.enabled)
                    if model.displayName != nil { Text(model.id).font(.caption).foregroundStyle(.secondary) }
                    Text("\(model.contextFormatted ?? "Unknown") context · \(model.pricingPerMillionLabel ?? "Price unknown")")
                        .font(.caption).foregroundStyle(.secondary)
                    if let date = model.catalogAddedAt { Text("Catalog added \(date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
                    if !liveModels.contains(where: { $0.id == model.id }) {
                        Text("Saved model · not present in this catalog").font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Button("Use for Xcode") { vm.useBrowserModel(model, selection: browsing) }
                    Button("Test Direct Response") {
                        rowTestModelID = model.id
                        let selection = browsing
                        Task { await vm.testBrowserConnection(selection, model: model.id) }
                    }
                    .help("Test only this direct provider endpoint. Use Test RepoGPS Route to check session compatibility. Provider quota may apply.")
                    .accessibilityLabel("Test response from \(model.id)")
                    .disabled(checks.running.contains(identity) || (vm.browserRequiresKey(browsing) && !hasKey(browsing)))
                    Button(compared.contains(where: { $0.id == browsing.id + "/" + model.id }) ? "Remove comparison" : "Compare") {
                        let item = ComparedModel(provider: browsing, providerTitle: vm.browserTitle(browsing), model: model)
                        if compared.contains(where: { $0.id == item.id }) { compared.removeAll { $0.id == item.id } }
                        else if compared.count < 3 { compared.append(item) }
                    }.disabled(compared.count == 3 && !compared.contains(where: { $0.id == browsing.id + "/" + model.id }))
                }
            }
            if rowTestModelID == model.id {
                if checks.running.contains(identity) {
                    ProgressView("Testing response…").controlSize(.small)
                } else if let result = checks.results[identity] {
                    Label(result.message, systemImage: result.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.caption).textSelection(.enabled)
                }
            }
        }.padding(.vertical, 12)
    }

    private var comparison: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Compare Models").font(.title2.bold()); Spacer(); Button("Done") { showComparison = false } }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(compared) { item in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(item.model.displayName ?? item.model.id).font(.headline)
                            Text(item.providerTitle).foregroundStyle(.secondary)
                            Text("Context: \(item.model.contextFormatted ?? "Unknown")")
                            Text(item.model.pricingPerMillionLabel ?? "Price unknown")
                            Text("Reported parameters: " + (item.model.supportedParameters.isEmpty ? "Unknown" : item.model.supportedParameters.sorted().joined(separator: ", ")))
                            Text("Catalog added: " + (item.model.catalogAddedAt?.formatted(date: .abbreviated, time: .omitted) ?? "Unknown"))
                            Button("Use for Xcode") { vm.useBrowserModel(item.model, selection: item.provider) }
                        }.frame(width: 240, alignment: .topLeading)
                    }
                }
            }
        }.padding(24).frame(minWidth: 580, minHeight: 300)
    }
}
