import Combine
import Foundation
import ProxyPilotCore

@MainActor
final class ProviderManager: ObservableObject {

    struct ModelSelectionRow: Identifiable, Equatable {
        let id: String
        let model: UpstreamModel?
        let isDefault: Bool
        let isLive: Bool
    }

    // MARK: - UserDefaults Keys

    static let upstreamProviderDefaultsKey = "proxypilot.upstreamProvider"
    static let defaultModelsKeyPrefix = "proxypilot.defaultModels."
    static let xcodeAgentModelLegacyDefaultsKey = "proxypilot.xcodeAgentModel"
    static let xcodeAgentModelDefaultsKeyPrefix = "proxypilot.xcodeAgentModel."
    static let upstreamModelCacheKeyPrefix = "proxypilot.upstreamModelCache."
    static let exactoFilterDefaultsKey = "proxypilot.openrouter.exactoFilter"
    static let verifiedFilterDefaultsKey = "proxypilot.openrouter.verifiedFilter"
    static let showModelMetadataDefaultsKey = "proxypilot.showModelMetadata"
    static let miniMaxRoutingModeDefaultsKey = "proxypilot.miniMaxRoutingMode"
    private static let verifiedModelsRemoteURL = URL(string: "https://micah.chat/proxypilot/verified-models.json")!

    static func defaultModelsKey(for provider: UpstreamProvider) -> String {
        defaultModelsKeyPrefix + provider.rawValue
    }

    static func xcodeAgentModelDefaultsKey(for provider: UpstreamProvider) -> String {
        xcodeAgentModelDefaultsKeyPrefix + provider.rawValue
    }

    static func upstreamModelCacheKey(for provider: UpstreamProvider) -> String {
        upstreamModelCacheKeyPrefix + provider.rawValue
    }

    // MARK: - Dependencies

    let defaults: UserDefaults
    let proxyService: ProxyService

    // MARK: - Published Properties

    @Published var upstreamProvider: UpstreamProvider = .zAI {
        didSet {
            defaults.set(upstreamProvider.rawValue, forKey: Self.upstreamProviderDefaultsKey)
            let savedURL = defaults.string(forKey: "proxypilot.upstreamAPIBaseURL.\(upstreamProvider.rawValue)")
            upstreamAPIBaseURLString = savedURL ?? upstreamProvider.defaultAPIBaseURL
            upstreamModels = Self.cachedUpstreamModels(from: defaults, provider: upstreamProvider)
            selectedUpstreamModels = []
            selectedXcodeAgentModel = storedXcodeAgentModel(for: upstreamProvider)
            selectedUpstreamModels.formUnion(savedDefaultModelSet)
            reconcileXcodeAgentModelSelection()
            onClearIssue?()
            if upstreamProvider == .openRouter {
                Task { await loadVerifiedModels() }
            }
        }
    }

    @Published var upstreamAPIBaseURLString: String = UpstreamProvider.zAI.defaultAPIBaseURL {
        didSet {
            guard isInitialized else { return }
            let key = "proxypilot.upstreamAPIBaseURL.\(upstreamProvider.rawValue)"
            defaults.set(upstreamAPIBaseURLString, forKey: key)
        }
    }

    @Published var upstreamModels: [UpstreamModel] = []
    @Published var selectedUpstreamModels: Set<String> = []

    @Published var selectedXcodeAgentModel: String = "" {
        didSet {
            persistSelectedXcodeAgentModel()
        }
    }

    @Published var providerKeyDrafts: [UpstreamProvider: String] = [:]
    @Published var providerKeyEditing: [UpstreamProvider: Bool] = [:]
    @Published var providerKeyTestStates: [UpstreamProvider: KeyTestState] = [:]

    @Published var exactoFilterEnabled: Bool = true {
        didSet {
            defaults.set(exactoFilterEnabled, forKey: Self.exactoFilterDefaultsKey)
        }
    }

    @Published var verifiedFilterEnabled: Bool = false {
        didSet {
            defaults.set(verifiedFilterEnabled, forKey: Self.verifiedFilterDefaultsKey)
        }
    }

    @Published var miniMaxRoutingMode: MiniMaxRoutingMode = .standard {
        didSet {
            defaults.set(miniMaxRoutingMode.rawValue, forKey: Self.miniMaxRoutingModeDefaultsKey)
        }
    }

    @Published var verifiedModels: VerifiedModels = VerifiedModels(entries: [])

    @Published var showModelMetadata: Bool = true {
        didSet {
            defaults.set(showModelMetadata, forKey: Self.showModelMetadataDefaultsKey)
        }
    }

    // MARK: - Callbacks (set by AppViewModel)

    var onClearIssue: (() -> Void)?
    var onApplyIssue: ((AppIssue) -> Void)?

    // MARK: - Internal State

    var isInitialized = false

    // MARK: - Key Test State

    enum KeyTestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    // MARK: - Init

    init(defaults: UserDefaults, proxyService: ProxyService) {
        self.defaults = defaults
        self.proxyService = proxyService

        if let rawProvider = defaults.string(forKey: Self.upstreamProviderDefaultsKey),
           let provider = UpstreamProvider(rawValue: rawProvider) {
            upstreamProvider = provider
        } else {
            upstreamProvider = .zAI
        }

        let savedURL = defaults.string(forKey: "proxypilot.upstreamAPIBaseURL.\(upstreamProvider.rawValue)")
        upstreamAPIBaseURLString = savedURL ?? upstreamProvider.defaultAPIBaseURL
        selectedXcodeAgentModel = storedXcodeAgentModel(for: upstreamProvider)

        exactoFilterEnabled = defaults.object(forKey: Self.exactoFilterDefaultsKey) as? Bool ?? true
        verifiedFilterEnabled = defaults.object(forKey: Self.verifiedFilterDefaultsKey) as? Bool ?? false
        showModelMetadata = defaults.object(forKey: Self.showModelMetadataDefaultsKey) as? Bool ?? true

        if let rawMode = defaults.string(forKey: Self.miniMaxRoutingModeDefaultsKey),
           let mode = MiniMaxRoutingMode(rawValue: rawMode) {
            miniMaxRoutingMode = mode
        }

        upstreamModels = Self.cachedUpstreamModels(from: defaults, provider: upstreamProvider)
        selectedUpstreamModels.formUnion(savedDefaultModelSet)
    }

    // MARK: - Computed Properties

    var selectedUpstreamProviderDefaultAPIBaseURL: String {
        upstreamProvider.defaultAPIBaseURL
    }

    var hasUpstreamKey: Bool {
        guard let key = upstreamProvider.keychainKey else { return true }
        return KeychainService.exists(key: key)
    }

    private var rawSavedDefaultModels: [String] {
        defaults.stringArray(forKey: Self.defaultModelsKey(for: upstreamProvider)) ?? []
    }

    var savedDefaultModels: [String] {
        effectiveSavedDefaultModels(
            from: rawSavedDefaultModels,
            provider: upstreamProvider,
            liveModelIDs: upstreamModels.map(\.id)
        )
    }

    var hasSavedDefaultModels: Bool { !savedDefaultModels.isEmpty }

    private var savedDefaultModelSet: Set<String> {
        Set(savedDefaultModels)
    }

    var xcodeAgentModelCandidates: [String] {
        let ids = upstreamModels.map(\.id)
        let selected = selectedUpstreamModels.isEmpty ? [] : selectedUpstreamModels.sorted()
        var candidates: [String]
        if upstreamProvider == .githubCopilot {
            candidates = githubCopilotModelCandidates(liveModelIDs: ids, selectedModelIDs: selected)
        } else if !selected.isEmpty {
            candidates = selected
        } else if !ids.isEmpty {
            candidates = ids.sorted()
        } else if let fallback = upstreamProvider.fallbackModelIDs {
            candidates = fallback
        } else {
            candidates = savedDefaultModels
        }

        let trimmedSelection = selectedXcodeAgentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSelection.isEmpty,
           shouldPreserveStoredXcodeAgentModel(trimmedSelection, candidates: candidates),
           !candidates.contains(where: { $0.caseInsensitiveCompare(trimmedSelection) == .orderedSame }) {
            candidates.insert(trimmedSelection, at: 0)
        }
        return candidates
    }

    var effectiveXcodeAgentModel: String {
        let candidates = xcodeAgentModelCandidates
        if candidates.contains(selectedXcodeAgentModel) {
            return selectedXcodeAgentModel
        }
        return preferredXcodeAgentModel(from: candidates)
    }

    var proxySyncModelCandidates: [String] {
        if upstreamProvider == .githubCopilot {
            return githubCopilotProxySyncModelCandidates()
        }

        if !upstreamModels.isEmpty {
            var candidates = Set(upstreamModels.map(\.id).filter { isModelSelected($0) })
            candidates.formUnion(savedDefaultModelSet)
            return candidates.sorted()
        }

        var fallbackModels = Set(savedDefaultModels)
        if fallbackModels.isEmpty, let providerFallback = upstreamProvider.fallbackModelIDs {
            fallbackModels.formUnion(providerFallback)
        }
        let trimmedSelection = selectedXcodeAgentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSelection.isEmpty {
            fallbackModels.insert(trimmedSelection)
        }
        return fallbackModels.sorted()
    }

    var canSyncProxyModels: Bool {
        !proxySyncModelCandidates.isEmpty
    }

    var filteredUpstreamModels: [UpstreamModel] {
        var models = upstreamModels

        if exactoFilterEnabled && upstreamProvider == .openRouter {
            var seen = Set<String>()
            models = models.compactMap { model in
                guard model.isExactoEligible else { return nil }
                let exacto = model.exactoVariant
                return seen.insert(exacto.id).inserted ? exacto : nil
            }
        }

        if verifiedFilterEnabled && upstreamProvider == .openRouter && !verifiedModels.isEmpty {
            models = models.filter { verifiedModels.contains($0.id) }
        }

        return models
    }

    var modelSelectionRows: [ModelSelectionRow] {
        let liveRows = filteredUpstreamModels.map { model in
            ModelSelectionRow(
                id: model.id,
                model: model,
                isDefault: isDefaultModel(model.id),
                isLive: true
            )
        }
        let liveIDs = Set(liveRows.map(\.id))
        let missingDefaultRows = savedDefaultModels
            .filter { !liveIDs.contains($0) }
            .map {
                ModelSelectionRow(
                    id: $0,
                    model: upstreamModel(for: $0),
                    isDefault: true,
                    isLive: false
                )
            }
        return missingDefaultRows + liveRows
    }

    var selectedModelRowCount: Int {
        modelSelectionRows.filter { isModelSelected($0.id) }.count
    }

    var allVisibleModelsSelected: Bool {
        let rows = modelSelectionRows
        return !rows.isEmpty && rows.allSatisfy { isModelSelected($0.id) }
    }

    var canClearModelSelection: Bool {
        selectedUpstreamModels.contains(where: { !isDefaultModel($0) })
    }

    var canSaveSelectedModelsAsDefaults: Bool {
        modelSelectionRows.contains { row in
            !row.isDefault && isModelSelected(row.id)
        }
    }

    // MARK: - Key Management

    func hasKey(for provider: UpstreamProvider) -> Bool {
        guard let key = provider.keychainKey else { return false }
        return KeychainService.exists(key: key)
    }

    @discardableResult
    func saveKey(for provider: UpstreamProvider) -> Bool {
        guard let keychainKey = provider.keychainKey else { return false }
        let draft = (providerKeyDrafts[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return false }
        if case let .failure(_, message) = APIKeyValidator.validate(draft, for: provider) {
            onApplyIssue?(AppIssue(
                code: .missingUpstreamKey,
                title: String(localized: "Invalid API Key"),
                message: message,
                actions: [.openUpstreamKeyEditor]
            ))
            return false
        }
        do {
            try KeychainService.set(draft, forKey: keychainKey)
            providerKeyDrafts[provider] = nil
            providerKeyEditing[provider] = nil
            providerKeyTestStates[provider] = .idle
            objectWillChange.send()
            return true
        } catch {
            onApplyIssue?(AppIssue(
                code: .missingUpstreamKey,
                title: String(localized: "Unable to Save API Key"),
                message: String(localized: "Could not save API key for") + " \(provider.title): " + error.localizedDescription,
                actions: [.openUpstreamKeyEditor]
            ))
            return false
        }
    }

    func deleteKey(for provider: UpstreamProvider) {
        guard let keychainKey = provider.keychainKey else { return }
        do {
            try KeychainService.delete(key: keychainKey)
            providerKeyTestStates[provider] = .idle
            objectWillChange.send()
        } catch {
            onApplyIssue?(AppIssue(
                code: .missingUpstreamKey,
                title: String(localized: "Unable to Delete API Key"),
                message: String(localized: "Could not delete API key for") + " \(provider.title): " + error.localizedDescription,
                actions: [.openUpstreamKeyEditor]
            ))
        }
    }

    func testKey(for provider: UpstreamProvider) async {
        guard let keychainKey = provider.keychainKey,
              let apiKey = KeychainService.get(key: keychainKey),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            providerKeyTestStates[provider] = .failure(String(localized: "Missing API key"))
            return
        }

        guard let apiBase = upstreamAPIBaseURL(for: provider) else {
            providerKeyTestStates[provider] = .failure(String(localized: "Invalid API base URL"))
            return
        }

        providerKeyTestStates[provider] = .testing
        do {
            let models = try await proxyService.fetchUpstreamModels(apiBase: apiBase, apiKey: apiKey, provider: provider)
            providerKeyTestStates[provider] = .success(String(localized: "OK") + " (\(models.count) " + String(localized: "models") + ")")
        } catch {
            providerKeyTestStates[provider] = .failure(error.localizedDescription)
        }
    }

    // MARK: - Model Management

    func selectAllUpstreamModels() {
        selectedUpstreamModels = Set(modelSelectionRows.map(\.id))
        reconcileXcodeAgentModelSelection()
    }

    func clearUpstreamModelSelection() {
        selectedUpstreamModels = savedDefaultModelSet
        reconcileXcodeAgentModelSelection()
    }

    func saveSelectedModelsAsDefaults() {
        let selectedVisibleModels = Set(modelSelectionRows.map(\.id).filter { id in
            !isDefaultModel(id) && isModelSelected(id)
        })
        let models = Array(savedDefaultModelSet.union(selectedVisibleModels)).sorted()
        defaults.set(models, forKey: Self.defaultModelsKey(for: upstreamProvider))
        selectedUpstreamModels.formUnion(models)
        objectWillChange.send()
    }

    func applyFetchedUpstreamModels(_ models: [UpstreamModel]) {
        upstreamModels = models
        cacheUpstreamModels(models)
        if upstreamProvider == .githubCopilot {
            let liveIDs = models.map(\.id)
            selectedUpstreamModels = Set(selectedUpstreamModels.compactMap {
                caseInsensitiveMatch(in: liveIDs, for: $0)
            })
            defaults.set(savedDefaultModels, forKey: Self.defaultModelsKey(for: upstreamProvider))
        }
        selectedUpstreamModels.formUnion(savedDefaultModelSet)
        reconcileXcodeAgentModelSelection()
    }

    func isDefaultModel(_ id: String) -> Bool {
        savedDefaultModelSet.contains(id)
    }

    func isModelSelected(_ id: String) -> Bool {
        isDefaultModel(id) || selectedUpstreamModels.contains(id)
    }

    func setModelSelected(_ id: String, isSelected: Bool) {
        if isDefaultModel(id) {
            selectedUpstreamModels.insert(id)
            reconcileXcodeAgentModelSelection()
            return
        }

        if isSelected {
            selectedUpstreamModels.insert(id)
        } else {
            selectedUpstreamModels.remove(id)
        }
        reconcileXcodeAgentModelSelection()
    }

    func removeDefaultModel(_ id: String) {
        let models = savedDefaultModels.filter { $0 != id }
        defaults.set(models, forKey: Self.defaultModelsKey(for: upstreamProvider))
        selectedUpstreamModels.remove(id)
        reconcileXcodeAgentModelSelection()
        objectWillChange.send()
    }

    func reconcileXcodeAgentModelSelection() {
        let candidates = xcodeAgentModelCandidates
        if !candidates.contains(selectedXcodeAgentModel) {
            selectedXcodeAgentModel = preferredXcodeAgentModel(from: candidates)
        }
    }

    func upstreamModel(for id: String) -> UpstreamModel? {
        if let direct = upstreamModels.first(where: { $0.id == id }) {
            return mergedKnownMetadata(for: direct)
        }
        if id.hasSuffix(":exacto"),
           let base = upstreamModels.first(where: { $0.id == String(id.dropLast(":exacto".count)) }) {
            return mergedKnownMetadata(for: base).exactoVariant
        }
        let lower = id.lowercased()
        if let caseInsensitive = upstreamModels.first(where: { $0.id.lowercased() == lower }) {
            return mergedKnownMetadata(for: caseInsensitive)
        }
        if lower.hasSuffix(":exacto") {
            let baseLower = String(lower.dropLast(":exacto".count))
            return upstreamModels.first { $0.id.lowercased() == baseLower }
                .map { mergedKnownMetadata(for: $0).exactoVariant }
        }
        return upstreamProvider.knownModelMetadata(for: id)
    }

    private func mergedKnownMetadata(for model: UpstreamModel) -> UpstreamModel {
        guard let known = upstreamProvider.knownModelMetadata(for: model.id) else {
            return model
        }
        return UpstreamModel(
            id: model.id,
            contextLength: model.contextLength ?? known.contextLength,
            promptPricePer1M: model.promptPricePer1M ?? known.promptPricePer1M,
            completionPricePer1M: model.completionPricePer1M ?? known.completionPricePer1M,
            promptCacheHitPricePer1M: model.promptCacheHitPricePer1M ?? known.promptCacheHitPricePer1M,
            promptCacheMissPricePer1M: model.promptCacheMissPricePer1M ?? known.promptCacheMissPricePer1M,
            supportedParameters: model.supportedParameters.isEmpty ? known.supportedParameters : model.supportedParameters
        )
    }

    func preferredXcodeAgentModel(from models: [String], provider: UpstreamProvider? = nil) -> String {
        let activeProvider = provider ?? upstreamProvider
        let liveModelIDs = activeProvider == upstreamProvider ? upstreamModels.map(\.id) : []
        let hints = effectiveSavedDefaultModels(
            from: defaults.stringArray(forKey: Self.defaultModelsKey(for: activeProvider)) ?? [],
            provider: activeProvider,
            liveModelIDs: liveModelIDs
        )
        let fallback = hints.first
            ?? activeProvider.fallbackModelIDs?.first
            ?? ""
        guard !models.isEmpty else { return fallback }
        let lowerToOriginal = Dictionary(uniqueKeysWithValues: models.map { ($0.lowercased(), $0) })
        for preferred in hints {
            if let match = lowerToOriginal[preferred.lowercased()] {
                return match
            }
        }
        return models.sorted().first ?? fallback
    }

    func storedXcodeAgentModel(for provider: UpstreamProvider) -> String {
        let providerScopedKey = Self.xcodeAgentModelDefaultsKey(for: provider)
        let providerDefaults = defaults.stringArray(forKey: Self.defaultModelsKey(for: provider)) ?? []

        if let providerStored = defaults.string(forKey: providerScopedKey),
           !providerStored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if provider == .githubCopilot {
                let candidates = githubCopilotStoredModelCandidates(from: providerDefaults)
                if let match = caseInsensitiveMatch(in: candidates, for: providerStored) {
                    return match
                }
            } else {
                return providerStored
            }
        }

        if provider == .githubCopilot {
            let candidates = githubCopilotStoredModelCandidates(from: providerDefaults)
            return preferredXcodeAgentModel(from: candidates, provider: provider)
        }

        if provider == .zAI,
           let legacyStored = defaults.string(forKey: Self.xcodeAgentModelLegacyDefaultsKey),
           !legacyStored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return legacyStored
        }

        return preferredXcodeAgentModel(from: providerDefaults, provider: provider)
    }

    func resetUpstreamAPIBaseURL() {
        defaults.removeObject(forKey: "proxypilot.upstreamAPIBaseURL.\(upstreamProvider.rawValue)")
        upstreamAPIBaseURLString = selectedUpstreamProviderDefaultAPIBaseURL
        onClearIssue?()
    }

    func loadVerifiedModels() async {
        let cacheDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ProxyPilot")
        let cacheURL = cacheDir?.appendingPathComponent("verified-models-cache.json")
        let bundleURL = Bundle.main.url(forResource: "verified-models", withExtension: "json")

        let remote = await VerifiedModels.fetchRemote(from: Self.verifiedModelsRemoteURL)
        if !remote.isEmpty {
            verifiedModels = VerifiedModels(entries: remote)
            if let cacheURL {
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                VerifiedModels.saveCache(entries: remote, to: cacheURL)
            }
        } else {
            let cached = VerifiedModels.loadCached(cacheURL: cacheURL, bundleURL: bundleURL)
            verifiedModels = VerifiedModels(entries: cached)
        }
    }

    func cacheUpstreamModels(_ models: [UpstreamModel]) {
        guard let data = try? JSONEncoder().encode(models) else { return }
        defaults.set(data, forKey: Self.upstreamModelCacheKey(for: upstreamProvider))
    }

    // MARK: - Internal Helpers

    static func cachedUpstreamModels(from defaults: UserDefaults, provider: UpstreamProvider) -> [UpstreamModel] {
        guard let data = defaults.data(forKey: upstreamModelCacheKey(for: provider)),
              let models = try? JSONDecoder().decode([UpstreamModel].self, from: data) else {
            return []
        }
        return models
    }

    func upstreamAPIBaseURL(for provider: UpstreamProvider) -> URL? {
        let defaultBase = provider.defaultAPIBaseURL
        let storedBase = defaults.string(forKey: "proxypilot.upstreamAPIBaseURL.\(provider.rawValue)")
        let raw = (provider == upstreamProvider ? upstreamAPIBaseURLString : storedBase) ?? defaultBase
        return proxyService.normalizedUpstreamAPIBase(from: raw) ?? URL(string: defaultBase)
    }

    private func githubCopilotModelCandidates(liveModelIDs: [String], selectedModelIDs: [String]) -> [String] {
        if !liveModelIDs.isEmpty {
            let selectedLiveModels = selectedModelIDs.compactMap {
                caseInsensitiveMatch(in: liveModelIDs, for: $0)
            }
            return selectedLiveModels.isEmpty
                ? liveModelIDs.sorted()
                : uniqueModelIDs(selectedLiveModels).sorted()
        }

        let fallback = UpstreamProvider.githubCopilot.fallbackModelIDs ?? []
        let selectedFallbackModels = selectedModelIDs.compactMap {
            caseInsensitiveMatch(in: fallback, for: $0)
        }
        if !selectedFallbackModels.isEmpty {
            return uniqueModelIDs(selectedFallbackModels).sorted()
        }

        return savedDefaultModels
    }

    private func githubCopilotProxySyncModelCandidates() -> [String] {
        let liveModelIDs = upstreamModels.map(\.id)
        if !liveModelIDs.isEmpty {
            var candidates = Set(selectedUpstreamModels.compactMap {
                caseInsensitiveMatch(in: liveModelIDs, for: $0)
            })
            let preferred = effectiveXcodeAgentModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if let preferredLiveModel = caseInsensitiveMatch(in: liveModelIDs, for: preferred) {
                candidates.insert(preferredLiveModel)
            }
            if candidates.isEmpty, let firstLiveModel = liveModelIDs.sorted().first {
                candidates.insert(firstLiveModel)
            }
            return candidates.sorted()
        }

        let fallback = UpstreamProvider.githubCopilot.fallbackModelIDs ?? []
        var candidates = Set(savedDefaultModels)
        candidates.formUnion(selectedUpstreamModels.compactMap {
            caseInsensitiveMatch(in: fallback, for: $0)
        })
        let selected = selectedXcodeAgentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if let selectedFallbackModel = caseInsensitiveMatch(in: fallback, for: selected) {
            candidates.insert(selectedFallbackModel)
        }
        if candidates.isEmpty, !fallback.isEmpty {
            candidates.formUnion(fallback)
        }
        return candidates.sorted()
    }

    private func githubCopilotStoredModelCandidates(from rawDefaults: [String]) -> [String] {
        let fallback = UpstreamProvider.githubCopilot.fallbackModelIDs ?? []
        let savedFallbackModels = rawDefaults.compactMap {
            caseInsensitiveMatch(in: fallback, for: $0)
        }
        return savedFallbackModels.isEmpty ? fallback : uniqueModelIDs(savedFallbackModels)
    }

    private func effectiveSavedDefaultModels(
        from rawModels: [String],
        provider: UpstreamProvider,
        liveModelIDs: [String]
    ) -> [String] {
        guard provider == .githubCopilot else { return rawModels }
        let allowedModelIDs = liveModelIDs.isEmpty
            ? (UpstreamProvider.githubCopilot.fallbackModelIDs ?? [])
            : liveModelIDs
        guard !allowedModelIDs.isEmpty else { return [] }
        return uniqueModelIDs(rawModels.compactMap {
            caseInsensitiveMatch(in: allowedModelIDs, for: $0)
        })
    }

    private func shouldPreserveStoredXcodeAgentModel(_ model: String, candidates: [String]) -> Bool {
        guard upstreamProvider == .githubCopilot else { return true }
        return caseInsensitiveMatch(in: candidates, for: model) != nil
    }

    private func caseInsensitiveMatch(in values: [String], for candidate: String) -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return values.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private func uniqueModelIDs(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let key = value.lowercased()
            if seen.insert(key).inserted {
                result.append(value)
            }
        }
        return result
    }

    private func persistSelectedXcodeAgentModel() {
        defaults.set(selectedXcodeAgentModel, forKey: Self.xcodeAgentModelDefaultsKey(for: upstreamProvider))
        if upstreamProvider == .zAI {
            defaults.set(selectedXcodeAgentModel, forKey: Self.xcodeAgentModelLegacyDefaultsKey)
        }
    }
}
