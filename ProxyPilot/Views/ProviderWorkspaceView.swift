import SwiftUI
import ProxyPilotCore

struct ProviderWorkspaceView: View {
    @EnvironmentObject private var vm: AppViewModel
    var body: some View {
        ProviderWorkspaceContent(vm: vm, catalog: vm.providerCatalog, favorites: vm.modelFavorites)
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
            vm.isKeysProviderVisible($0) || browsing == .builtIn($0)
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
          ScrollView {
           VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Providers & Models").font(.title2.bold())
                Spacer()
                Button("Add Provider", systemImage: "plus") { showAddProvider = true }
            }
            Picker("Browse provider", selection: $browsing) {
                Text("Choose a provider…").tag(UpstreamSelection.none)
                ForEach(browsableProviders) { Text($0.title).tag(UpstreamSelection.builtIn($0)) }
                ForEach(vm.customProviders) { Text($0.name + " (Custom)").tag(UpstreamSelection.custom($0.id)) }
            }
            Text("Explore providers without changing your Xcode selection.")
                .font(.caption).foregroundStyle(.secondary)
            if browsing == .none {
                ContentUnavailableView("Choose a provider", systemImage: "square.stack.3d.up",
                    description: Text("Configure credentials, browse models and build your favorites here."))
            } else {
                ScrollView { configuration }.frame(maxHeight: configurationExpanded ? 180 : 24)
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
                                description: Text(vm.browserRequiresKey(browsing) && !vm.browserHasKey(browsing)
                                    ? "Save a provider key to load its catalog, or enter a model ID."
                                    : "Clear filters, refresh the catalog, or enter a model ID."))
                        }
                        ForEach(results) { model in modelRow(model); Divider() }
                }
                .frame(minHeight: 160)

            }
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
            if browsing == .none { browsing = vm.selectedUpstreamSelection }
        }
        .task(id: browsing) {
            endpointDraft = vm.browserEndpoint(browsing)
            keyDraft = ""
            configurationExpanded = vm.providerWorkspaceShowsConfiguration || (vm.browserRequiresKey(browsing) && !vm.browserHasKey(browsing))
            query = ModelBrowserQuery()
            message = nil
            await vm.refreshBrowser(browsing)
        }
        .onChange(of: vm.providerWorkspaceShowsConfiguration) { _, expanded in
            if expanded { configurationExpanded = true }
        }
        .sheet(isPresented: $showAddProvider) {
            AddCustomProviderView { name, url, key in
                vm.addCustomProvider(name: name, apiBaseURL: url, apiKey: key)
                if let added = vm.customProviders.last { browsing = .custom(added.id) }
            }
        }
        .sheet(isPresented: $showComparison) { comparison }
        .confirmationDialog("Remove the stored provider key?", isPresented: $confirmDeleteKey) {
            Button("Remove Key", role: .destructive) { vm.deleteBrowserKey(browsing) }
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

    private var configuration: some View {
        DisclosureGroup("Provider configuration · \(vm.browserHasKey(browsing) ? "Key saved" : (vm.browserRequiresKey(browsing) ? "Key needed" : "Key optional"))", isExpanded: $configurationExpanded) {
            VStack(alignment: .leading, spacing: 10) {
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
                        if saved { keyDraft = "" }
                        message = saved ? "Key saved." : "Key was not saved. Check its format and try again."
                        Task { await vm.refreshBrowser(browsing, force: true) }
                    }.disabled(keyDraft.isEmpty)
                }
                HStack {
                    if vm.browserHasKey(browsing) { Button("Remove Key", role: .destructive) { confirmDeleteKey = true } }
                    if case .custom = browsing { Button("Remove Provider", role: .destructive) { confirmDeleteProvider = true } }
                    if case .builtIn(let provider) = browsing, let url = vm.apiKeyPageURL(for: provider) {
                        Link("Get an API key", destination: url)
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
                    Button(compared.contains(where: { $0.id == browsing.id + "/" + model.id }) ? "Remove comparison" : "Compare") {
                        let item = ComparedModel(provider: browsing, providerTitle: vm.browserTitle(browsing), model: model)
                        if compared.contains(where: { $0.id == item.id }) { compared.removeAll { $0.id == item.id } }
                        else if compared.count < 3 { compared.append(item) }
                    }.disabled(compared.count == 3 && !compared.contains(where: { $0.id == browsing.id + "/" + model.id }))
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
