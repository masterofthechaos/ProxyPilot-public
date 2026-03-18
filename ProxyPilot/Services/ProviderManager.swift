import Combine
import Foundation
import ProxyPilotCore

@MainActor
final class ProviderManager: ObservableObject {

    // MARK: - UserDefaults Keys

    static let upstreamProviderDefaultsKey = "proxypilot.upstreamProvider"
    static let defaultModelsKeyPrefix = "proxypilot.defaultModels."
    static let xcodeAgentModelLegacyDefaultsKey = "proxypilot.xcodeAgentModel"
    static let xcodeAgentModelDefaultsKeyPrefix = "proxypilot.xcodeAgentModel."
    static let exactoFilterDefaultsKey = "proxypilot.openrouter.exactoFilter"
    static let verifiedFilterDefaultsKey = "proxypilot.openrouter.verifiedFilter"
    static let showModelMetadataDefaultsKey = "proxypilot.showModelMetadata"
    private static let verifiedModelsRemoteURL = URL(string: "https://micah.chat/proxypilot/verified-models.json")!

    static func defaultModelsKey(for provider: UpstreamProvider) -> String {
        defaultModelsKeyPrefix + provider.rawValue
    }

    static func xcodeAgentModelDefaultsKey(for provider: UpstreamProvider) -> String {
        xcodeAgentModelDefaultsKeyPrefix + provider.rawValue
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
            upstreamModels = []
            selectedUpstreamModels = []
            selectedXcodeAgentModel = storedXcodeAgentModel(for: upstreamProvider)
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
    }

    // MARK: - Computed Properties

    var selectedUpstreamProviderDefaultAPIBaseURL: String {
        upstreamProvider.defaultAPIBaseURL
    }

    var hasUpstreamKey: Bool {
        guard let key = upstreamProvider.keychainKey else { return true }
        return KeychainService.exists(key: key)
    }

    var savedDefaultModels: [String] {
        defaults.stringArray(forKey: Self.defaultModelsKey(for: upstreamProvider)) ?? []
    }

    var hasSavedDefaultModels: Bool { !savedDefaultModels.isEmpty }

    var xcodeAgentModelCandidates: [String] {
        let ids = upstreamModels.map(\.id)
        let selected = ids.filter { selectedUpstreamModels.contains($0) }
        var candidates: [String]
        if !selected.isEmpty {
            candidates = selected.sorted()
        } else if !ids.isEmpty {
            candidates = ids.sorted()
        } else {
            candidates = savedDefaultModels
        }

        let trimmedSelection = selectedXcodeAgentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSelection.isEmpty,
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
        if !upstreamModels.isEmpty {
            return upstreamModels.map(\.id).filter { selectedUpstreamModels.contains($0) }
        }

        var fallbackModels = Set(savedDefaultModels)
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
            models = models.filter { $0.id.contains(":exacto") }
        }

        if verifiedFilterEnabled && upstreamProvider == .openRouter && !verifiedModels.isEmpty {
            models = models.filter { verifiedModels.contains($0.id) }
        }

        return models
    }

    // MARK: - Key Management

    func hasKey(for provider: UpstreamProvider) -> Bool {
        guard let key = provider.keychainKey else { return false }
        return KeychainService.exists(key: key)
    }

    func saveKey(for provider: UpstreamProvider) {
        guard let keychainKey = provider.keychainKey else { return }
        let draft = (providerKeyDrafts[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        do {
            try KeychainService.set(draft, forKey: keychainKey)
            providerKeyDrafts[provider] = nil
            providerKeyEditing[provider] = nil
            providerKeyTestStates[provider] = .idle
            objectWillChange.send()
        } catch {
            onApplyIssue?(AppIssue(
                code: .missingUpstreamKey,
                title: String(localized: "Unable to Save API Key"),
                message: String(localized: "Could not save API key for") + " \(provider.title): " + error.localizedDescription,
                actions: [.openUpstreamKeyEditor]
            ))
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
        selectedUpstreamModels = Set(filteredUpstreamModels.map(\.id))
        reconcileXcodeAgentModelSelection()
    }

    func clearUpstreamModelSelection() {
        selectedUpstreamModels = []
        reconcileXcodeAgentModelSelection()
    }

    func saveSelectedModelsAsDefaults() {
        let models = Array(selectedUpstreamModels).sorted()
        defaults.set(models, forKey: Self.defaultModelsKey(for: upstreamProvider))
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
            return direct
        }
        let lower = id.lowercased()
        return upstreamModels.first { $0.id.lowercased() == lower }
    }

    func preferredXcodeAgentModel(from models: [String], provider: UpstreamProvider? = nil) -> String {
        let activeProvider = provider ?? upstreamProvider
        let hints = defaults.stringArray(forKey: Self.defaultModelsKey(for: activeProvider)) ?? []
        let fallback = hints.first ?? "gpt-4o"
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
        if let providerStored = defaults.string(forKey: providerScopedKey),
           !providerStored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return providerStored
        }

        if let legacyStored = defaults.string(forKey: Self.xcodeAgentModelLegacyDefaultsKey),
           !legacyStored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return legacyStored
        }

        let providerDefaults = defaults.stringArray(forKey: Self.defaultModelsKey(for: provider)) ?? []
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

    // MARK: - Internal Helpers

    func upstreamAPIBaseURL(for provider: UpstreamProvider) -> URL? {
        let defaultBase = provider.defaultAPIBaseURL
        let storedBase = defaults.string(forKey: "proxypilot.upstreamAPIBaseURL.\(provider.rawValue)")
        let raw = (provider == upstreamProvider ? upstreamAPIBaseURLString : storedBase) ?? defaultBase
        return proxyService.normalizedUpstreamAPIBase(from: raw) ?? URL(string: defaultBase)
    }

    private func persistSelectedXcodeAgentModel() {
        defaults.set(selectedXcodeAgentModel, forKey: Self.xcodeAgentModelDefaultsKey(for: upstreamProvider))
        defaults.set(selectedXcodeAgentModel, forKey: Self.xcodeAgentModelLegacyDefaultsKey)
    }
}
