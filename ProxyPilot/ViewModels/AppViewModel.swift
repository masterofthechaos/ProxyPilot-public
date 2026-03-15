import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class AppViewModel: ObservableObject {
    enum UpstreamProvider: String, CaseIterable, Identifiable, Sendable {
        case zAI = "zai"
        case openRouter = "openrouter"
        case openAI = "openai"
        case xAI = "xai"
        case chutes = "chutes"
        case groq = "groq"
        case google = "google"
        case miniMax = "minimax"
        case ollama = "ollama"
        case lmStudio = "lmstudio"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .zAI: return "z.ai"
            case .openRouter: return "OpenRouter"
            case .openAI: return "OpenAI"
            case .xAI: return "xAI (Grok)"
            case .chutes: return "Chutes"
            case .groq: return "Groq"
            case .google: return "Google (Gemini)"
            case .miniMax: return "MiniMax"
            case .ollama: return "Ollama"
            case .lmStudio: return "LM Studio"
            }
        }

        var defaultAPIBaseURL: String {
            switch self {
            case .zAI: return "https://api.z.ai/api/coding/paas/v4"
            case .openRouter: return "https://openrouter.ai/api/v1"
            case .openAI: return "https://api.openai.com/v1"
            case .xAI: return "https://api.x.ai/v1"
            case .chutes: return "https://llm.chutes.ai/v1"
            case .groq: return "https://api.groq.com/openai/v1"
            case .google: return "https://generativelanguage.googleapis.com/v1beta/openai"
            case .miniMax: return "https://api.minimaxi.com/v1"
            case .ollama: return "http://localhost:11434/v1"
            case .lmStudio: return "http://localhost:1234/v1"
            }
        }

        var modelsPath: String { "/models" }

        var chatCompletionsPath: String { "/chat/completions" }

        var unsupportedOpenAIParameters: [String] {
            switch self {
            case .google:
                return [
                    "logprobs",
                    "top_logprobs",
                    "logit_bias",
                    "seed",
                    "frequency_penalty",
                    "presence_penalty"
                ]
            default:
                return []
            }
        }

        /// Whether this provider runs on the local machine (no cloud API).
        var isLocal: Bool {
            switch self {
            case .ollama, .lmStudio: return true
            default: return false
            }
        }

        /// Whether this provider requires an API key for authentication.
        var requiresAPIKey: Bool { !isLocal }

        /// The URL for the provider's API key management page, if applicable.
        var apiKeyPageURL: URL? {
            switch self {
            case .zAI: return URL(string: "https://zai.chat")
            case .openRouter: return URL(string: "https://openrouter.ai/keys")
            case .openAI: return URL(string: "https://platform.openai.com/api-keys")
            case .xAI: return URL(string: "https://console.x.ai")
            case .chutes: return URL(string: "https://chutes.ai/app/api-keys")
            case .groq: return URL(string: "https://console.groq.com/keys")
            case .google: return URL(string: "https://aistudio.google.com/apikey")
            case .miniMax: return URL(string: "https://platform.minimaxi.com")
            case .ollama, .lmStudio: return nil
            }
        }

        var keychainKey: KeychainService.Key? {
            switch self {
            case .zAI: return .zaiAPIKey
            case .openRouter: return .openRouterAPIKey
            case .openAI: return .openAIAPIKey
            case .xAI: return .xAIAPIKey
            case .chutes: return .chutesAPIKey
            case .groq: return .groqAPIKey
            case .google: return .googleAPIKey
            case .miniMax: return .miniMaxAPIKey
            case .ollama, .lmStudio: return nil
            }
        }

    }

    private struct IssueError: LocalizedError {
        let issue: AppIssue

        var errorDescription: String? {
            issue.message
        }
    }

    private static let anthropicFallbackDefaultsKey = "proxypilot.anthropicTranslatorFallbackEnabled"
    private static let xcodeAgentModelLegacyDefaultsKey = "proxypilot.xcodeAgentModel"
    private static let xcodeAgentModelDefaultsKeyPrefix = "proxypilot.xcodeAgentModel."
    private static let upstreamProviderDefaultsKey = "proxypilot.upstreamProvider"
    private static let didCompleteOnboardingDefaultsKey = "proxypilot.didCompleteOnboarding"
    private static let telemetryOptInDefaultsKey = "proxypilot.telemetryOptIn"
    private static let autoRestartEnabledDefaultsKey = "proxypilot.autoRestartEnabled"
    private static let requireLocalAuthDefaultsKey = "proxypilot.requireLocalAuth"
    private static let preflightSnapshotDefaultsKey = "proxypilot.lastPreflightSnapshot"
    private static let showModelMetadataDefaultsKey = "proxypilot.showModelMetadata"
    private static let exactoFilterDefaultsKey = "proxypilot.openrouter.exactoFilter"
    private static let verifiedFilterDefaultsKey = "proxypilot.openrouter.verifiedFilter"
    private static let suppressKeychainPrimerDefaultsKey = "proxypilot.suppressKeychainPrimer"
    private static let xcodeDefaultsDomain = "com.apple.dt.Xcode"
    private static let xcodeAgentAPIKeyOverrideDefaultsKey = "IDEChatClaudeAgentAPIKeyOverride"
    private static let verifiedModelsRemoteURL = URL(string: "https://micah.chat/proxypilot/verified-models.json")!
    private static let defaultModelsKeyPrefix = "proxypilot.defaultModels."

    private static func defaultModelsKey(for provider: UpstreamProvider) -> String {
        defaultModelsKeyPrefix + provider.rawValue
    }

    private static let builtInProxyLogFileURL = URL(fileURLWithPath: "/tmp/proxypilot_builtin_proxy.log")
    private static let toolchainLogFileURL = URL(fileURLWithPath: "/tmp/proxypilot_toolchain.log")
    private static let sessionRequestTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let defaultUpstreamAPIBaseURL = UpstreamProvider.zAI.defaultAPIBaseURL

    private let defaults: UserDefaults
    private let proxyService: ProxyService
    private let localProxyServer: LocalProxyServer
    private let preflightService: PreflightService
    private let diagnosticsService: DiagnosticsService
    private let telemetryService: TelemetryService
    private let healthMonitor: HealthMonitor
    private let xcodeAgentConfigStateProvider: (() -> Bool)?
    private let xcodeDetectionService = XcodeDetectionService()
    private let cliExecutableResolver: CLIExecutableResolver?
    private let cliUpdateRunner: CLIUpdateRunner?

    typealias CLIExecutableResolver = () -> URL?
    typealias CLIUpdateRunner = (URL) async throws -> CLIUpdateExecutionResult

    struct CLIUpdateExecutionResult: Sendable {
        let terminationStatus: Int32
        let stdout: String
        let stderr: String
    }

    private struct CLIUpdateEnvelope: Decodable {
        let ok: Bool
        let data: CLIUpdateData?
        let error: CLIUpdateErrorPayload?
    }

    private struct CLIUpdateData: Decodable {
        let status: String?
        let version: String?
        let installed: String?
        let latest: String?
        let from: String?
        let to: String?
        let path: String?
    }

    private struct CLIUpdateErrorPayload: Decodable {
        let code: String
        let message: String
        let suggestion: String?
    }

    private var proxyStateCancellable: AnyCancellable?
    private var logRefreshTimer: Timer?
    private var expectedProxyRunning: Bool = false
    private var recoveryTask: Task<Void, Never>?
    private var hasTrackedFirstSuccessfulRequest = false
    private var isInitialized = false
    private var hasEvaluatedKeychainPrimerThisLaunch = false
    private static let preflightExpandedDefaultsKey = "proxypilot.preflightExpanded"

    @Published var proxyURLString: String = "http://127.0.0.1:4000"
    @Published var upstreamAPIBaseURLString: String = AppViewModel.defaultUpstreamAPIBaseURL {
        didSet {
            guard isInitialized else { return }
            let key = "proxypilot.upstreamAPIBaseURL.\(upstreamProvider.rawValue)"
            defaults.set(upstreamAPIBaseURLString, forKey: key)
        }
    }
    @Published var upstreamProvider: UpstreamProvider = .zAI {
        didSet {
            defaults.set(upstreamProvider.rawValue, forKey: Self.upstreamProviderDefaultsKey)
            let savedURL = defaults.string(forKey: "proxypilot.upstreamAPIBaseURL.\(upstreamProvider.rawValue)")
            upstreamAPIBaseURLString = savedURL ?? upstreamProvider.defaultAPIBaseURL
            upstreamModels = []
            selectedUpstreamModels = []
            selectedXcodeAgentModel = storedXcodeAgentModel(for: upstreamProvider)
            reconcileXcodeAgentModelSelection()
            clearIssue()
            if upstreamProvider == .openRouter {
                Task { await loadVerifiedModels() }
            }
        }
    }
    @Published var xcodeProviderConfirmed: Bool = false

    @Published var launchAtLogin: Bool = false

    var localProxyState: LocalProxyState { localProxyServer.state }
    var sessionReportCard: SessionReportCard { localProxyServer.reportCard }

    /// Reset session report card AND menu bar counters so both surfaces stay in sync.
    func resetSessionStats() {
        localProxyServer.reportCard.reset()
        localProxyServer.state.sessionRequestCount = 0
        localProxyServer.state.lastModelSeen = ""
        localProxyServer.state.lastUpstreamModelUsed = ""
    }

    @Published var xcodeInstallations: [XcodeInstallation] = []
    var hasCompatibleXcode: Bool { xcodeInstallations.contains { $0.supportsAgenticCoding } }

    var hasUpstreamKey: Bool {
        guard let key = upstreamProvider.keychainKey else { return true }
        return KeychainService.exists(key: key)
    }
    var hasMasterKey: Bool { KeychainService.exists(key: .litellmMasterKey) }
    var requiresMasterKey: Bool { !useBuiltInProxy || requireLocalAuth }
    var hasRequiredMasterKey: Bool { !requiresMasterKey || hasMasterKey }

    @Published var isRunning: Bool = false
    @Published var statusText: String = "Unknown"
    @Published var lastError: String?
    @Published var activeIssue: AppIssue?
    @Published var recentIssueCodes: [String] = []

    @Published var logText: String = ""
    @Published var modelsJSON: String = ""
    @Published var upstreamModels: [UpstreamModel] = []
    @Published var selectedUpstreamModels: Set<String> = []
    @Published var selectedXcodeAgentModel: String = "" {
        didSet {
            persistSelectedXcodeAgentModel()
        }
    }
    @Published var upstreamTestOutput: String = ""
    @Published var upstreamTestModelUsed: String = ""

    @Published var showingUpstreamKeyField: Bool = false
    @Published var showingMasterKeyField: Bool = false
    @Published var upstreamKeyDraft: String = ""
    @Published var masterKeyDraft: String = ""

    @Published var providerKeyDrafts: [UpstreamProvider: String] = [:]
    @Published var providerKeyEditing: [UpstreamProvider: Bool] = [:]
    @Published var providerKeyTestStates: [UpstreamProvider: KeyTestState] = [:]

    enum KeyTestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    func resetToFreshInstall() async {
        clearIssue()
        recoveryTask?.cancel()
        recoveryTask = nil
        expectedProxyRunning = false
        recoveryState = .idle

        await stopProxy()
        removeXcodeAgentConfig()

        for key in KeychainService.Key.allCases {
            try? KeychainService.delete(key: key)
        }

        defaults.removeObject(forKey: Self.upstreamProviderDefaultsKey)
        defaults.removeObject(forKey: Self.didCompleteOnboardingDefaultsKey)
        defaults.removeObject(forKey: Self.telemetryOptInDefaultsKey)
        defaults.removeObject(forKey: Self.autoRestartEnabledDefaultsKey)
        defaults.removeObject(forKey: Self.requireLocalAuthDefaultsKey)
        defaults.removeObject(forKey: Self.preflightSnapshotDefaultsKey)
        defaults.removeObject(forKey: Self.showModelMetadataDefaultsKey)
        defaults.removeObject(forKey: Self.exactoFilterDefaultsKey)
        defaults.removeObject(forKey: Self.verifiedFilterDefaultsKey)
        defaults.removeObject(forKey: Self.suppressKeychainPrimerDefaultsKey)
        defaults.removeObject(forKey: Self.anthropicFallbackDefaultsKey)
        defaults.removeObject(forKey: Self.xcodeAgentModelLegacyDefaultsKey)
        defaults.removeObject(forKey: Self.preflightExpandedDefaultsKey)

        for provider in UpstreamProvider.allCases {
            defaults.removeObject(forKey: "proxypilot.upstreamAPIBaseURL.\(provider.rawValue)")
            defaults.removeObject(forKey: Self.xcodeAgentModelDefaultsKey(for: provider))
            defaults.removeObject(forKey: Self.defaultModelsKey(for: provider))
        }

        if launchAtLogin {
            try? await SMAppService.mainApp.unregister()
        }

        let fm = FileManager.default
        let logURLs: [URL] = [
            Self.builtInProxyLogFileURL,
            Self.toolchainLogFileURL,
            proxyService.paths.logFile,
            proxyService.paths.pidFile
        ]
        for url in logURLs {
            try? fm.removeItem(at: url)
        }

        proxyURLString = "http://127.0.0.1:4000"
        useBuiltInProxy = true
        upstreamProvider = .zAI
        upstreamAPIBaseURLString = upstreamProvider.defaultAPIBaseURL
        upstreamModels = []
        selectedUpstreamModels = []
        selectedXcodeAgentModel = preferredXcodeAgentModel(from: savedDefaultModels, provider: upstreamProvider)
        reconcileXcodeAgentModelSelection()
        xcodeProviderConfirmed = false

        launchAtLogin = false
        anthropicTranslatorFallbackEnabled = false
        requireLocalAuth = false
        showModelMetadata = true
        exactoFilterEnabled = true
        verifiedFilterEnabled = false
        showOnboardingWizard = true
        telemetryOptIn = false
        showKeychainAccessPrimer = false
        suppressKeychainAccessPrimer = false
        autoRestartEnabled = true
        hasEvaluatedKeychainPrimerThisLaunch = false

        providerKeyDrafts = [:]
        providerKeyEditing = [:]
        showingUpstreamKeyField = false
        showingMasterKeyField = false
        upstreamKeyDraft = ""
        masterKeyDraft = ""

        modelsJSON = ""
        upstreamTestOutput = ""
        upstreamTestModelUsed = ""
        logText = ""
        diagnosticsArchivePath = ""
        supportSummary = ""
        xcodeInstallations = []
        agentConfigStatus = ""
        preflightResults = []
        preflightLastRun = nil
        recentIssueCodes = []
        activeIssue = nil
        lastError = nil

        resetSessionStats()
        refreshAgentConfigInstallationState()
        clearIssue()
    }

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
            applyIssue(AppIssue(
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
            applyIssue(AppIssue(
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

    @Published var useBuiltInProxy: Bool = true {
        didSet {
            refreshStatus()
        }
    }

    @Published var anthropicTranslatorFallbackEnabled: Bool = false {
        didSet {
            defaults.set(anthropicTranslatorFallbackEnabled, forKey: Self.anthropicFallbackDefaultsKey)
        }
    }

    @Published var requireLocalAuth: Bool = false {
        didSet {
            defaults.set(requireLocalAuth, forKey: Self.requireLocalAuthDefaultsKey)
        }
    }

    @Published var showModelMetadata: Bool = true {
        didSet {
            defaults.set(showModelMetadata, forKey: Self.showModelMetadataDefaultsKey)
        }
    }

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

    @Published var showOnboardingWizard: Bool = false
    @Published var preflightResults: [PreflightCheckResult] = []
    @Published var preflightLastRun: Date?

    @Published var telemetryOptIn: Bool = false {
        didSet {
            defaults.set(telemetryOptIn, forKey: Self.telemetryOptInDefaultsKey)
        }
    }

    @Published var showKeychainAccessPrimer: Bool = false
    @Published var suppressKeychainAccessPrimer: Bool = false {
        didSet {
            defaults.set(suppressKeychainAccessPrimer, forKey: Self.suppressKeychainPrimerDefaultsKey)
        }
    }

    @Published var autoRestartEnabled: Bool = true {
        didSet {
            defaults.set(autoRestartEnabled, forKey: Self.autoRestartEnabledDefaultsKey)
        }
    }

    @Published var recoveryState: RecoveryState = .idle

    @Published var diagnosticsArchivePath: String = ""
    @Published var supportSummary: String = ""
    @Published var isUpdatingCLITool: Bool = false
    @Published var cliUpdateStatusText: String = ""
    @Published var cliUpdateStatusIsError: Bool = false

    var anthropicTranslatorModeText: String {
        anthropicTranslatorFallbackEnabled ? String(localized: "Legacy Fallback") : String(localized: "Hardened")
    }

    var selectedUpstreamProviderDefaultAPIBaseURL: String {
        upstreamProvider.defaultAPIBaseURL
    }

    var currentLogSourcePath: String {
        useBuiltInProxy ? Self.builtInProxyLogFileURL.path : proxyService.paths.logFile.path
    }

    var masterKeyKeychainTitle: String {
        if requiresMasterKey {
            return String(localized: "Local Proxy Password (Master Key)")
        }
        return String(localized: "Local Proxy Password (Optional in Built-In Mode)")
    }

    var masterKeyChecklistTitle: String {
        if requiresMasterKey {
            return String(localized: "Local proxy password saved in Keychain")
        }
        return String(localized: "Local proxy password (optional when local auth is off)")
    }

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

    var sessionLatencySummary: SessionReportCard.LatencySummary? {
        sessionReportCard.latencySummary
    }

    var sessionModelLatencyBreakdown: [SessionReportCard.ModelLatencySummary] {
        sessionReportCard.modelLatencyBreakdown
    }

    var sessionEstimatedCostUSD: Double? {
        let costs = sessionReportCard.requests.compactMap { estimatedCostUSD(for: $0) }
        guard !costs.isEmpty else { return nil }
        return costs.reduce(0, +)
    }

    var sessionPricedRequestCount: Int {
        sessionReportCard.requests.filter { estimatedCostUSD(for: $0) != nil }.count
    }

    var sessionCostCoverageText: String {
        let total = sessionReportCard.totalRequests
        guard total > 0 else { return "" }

        let priced = sessionPricedRequestCount
        if priced == 0 {
            return String(localized: "No priced requests in current model catalog.")
        }
        if priced < total {
            return String(localized: "Estimated from") + " \(priced)/\(total) " + String(localized: "requests with pricing metadata.")
        }
        return String(localized: "Estimated from all") + " \(total) " + String(localized: "requests.")
    }

    func estimatedCostUSD(for record: SessionReportCard.RequestRecord) -> Double? {
        guard let model = upstreamModel(for: record.model) else { return nil }
        return model.estimatedCostUSD(
            promptTokens: record.promptTokens,
            completionTokens: record.completionTokens
        )
    }

    func estimatedRequestCostUSD(for model: UpstreamModel) -> Double? {
        guard let avgPrompt = sessionReportCard.averagePromptTokensPerRequest,
              let avgCompletion = sessionReportCard.averageCompletionTokensPerRequest else {
            return nil
        }
        return model.estimatedCostUSD(
            promptTokens: Int(avgPrompt.rounded()),
            completionTokens: Int(avgCompletion.rounded())
        )
    }

    func formatUSD(_ amount: Double?) -> String {
        guard let amount else { return "N/A" }
        if amount < 0.01 {
            return String(format: "$%.4f", amount)
        }
        if amount < 1 {
            return String(format: "$%.3f", amount)
        }
        return String(format: "$%.2f", amount)
    }

    func sessionRequestJSON(_ record: SessionReportCard.RequestRecord) -> String {
        let estimatedCost = estimatedCostUSD(for: record)
        let payload: [String: Any] = [
            "id": record.id.uuidString,
            "timestamp": Self.sessionRequestTimestampFormatter.string(from: record.timestamp),
            "model": record.model,
            "path": record.path,
            "streaming": record.wasStreaming,
            "prompt_tokens": record.promptTokens,
            "completion_tokens": record.completionTokens,
            "total_tokens": record.totalTokens,
            "duration_ms": Int((record.durationSeconds * 1000).rounded()),
            "estimated_cost_usd": estimatedCost ?? NSNull()
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    func sessionRequestsCSV() -> String {
        let header = [
            "timestamp",
            "model",
            "path",
            "streaming",
            "prompt_tokens",
            "completion_tokens",
            "total_tokens",
            "duration_ms",
            "estimated_cost_usd"
        ].joined(separator: ",")

        let rows = sessionReportCard.requests.map { record in
            [
                Self.csvEscaped(Self.sessionRequestTimestampFormatter.string(from: record.timestamp)),
                Self.csvEscaped(record.model),
                Self.csvEscaped(record.path),
                record.wasStreaming ? "true" : "false",
                "\(record.promptTokens)",
                "\(record.completionTokens)",
                "\(record.totalTokens)",
                "\(Int((record.durationSeconds * 1000).rounded()))",
                estimatedCostUSD(for: record).map { String(format: "%.6f", $0) } ?? ""
            ]
            .joined(separator: ",")
        }

        return ([header] + rows).joined(separator: "\n")
    }

    var savedDefaultModels: [String] {
        defaults.stringArray(forKey: Self.defaultModelsKey(for: upstreamProvider)) ?? []
    }

    var hasSavedDefaultModels: Bool { !savedDefaultModels.isEmpty }

    func saveSelectedModelsAsDefaults() {
        let models = Array(selectedUpstreamModels).sorted()
        defaults.set(models, forKey: Self.defaultModelsKey(for: upstreamProvider))
        objectWillChange.send()
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

    func selectAllUpstreamModels() {
        selectedUpstreamModels = Set(filteredUpstreamModels.map(\.id))
        reconcileXcodeAgentModelSelection()
    }

    func clearUpstreamModelSelection() {
        selectedUpstreamModels = []
        reconcileXcodeAgentModelSelection()
    }

    var checklistIsProxyURLValid: Bool {
        if case .success = preflightService.validateProxyURL(proxyURLString) {
            return true
        }
        return false
    }

    var preflightHasBlockingFailures: Bool {
        preflightResults.contains { $0.status == .fail }
    }

    var liteLLMScriptsExist: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: proxyService.paths.startScript.path)
            && fm.fileExists(atPath: proxyService.paths.stopScript.path)
            && fm.fileExists(atPath: proxyService.paths.restartScript.path)
    }

    init(
        defaults: UserDefaults = .standard,
        proxyService: ProxyService = ProxyService(),
        localProxyServer: LocalProxyServer = LocalProxyServer(),
        diagnosticsService: DiagnosticsService = DiagnosticsService(),
        telemetryService: TelemetryService = .shared,
        healthMonitor: HealthMonitor = HealthMonitor(),
        xcodeAgentConfigStateProvider: (() -> Bool)? = nil,
        cliExecutableResolver: CLIExecutableResolver? = nil,
        cliUpdateRunner: CLIUpdateRunner? = nil
    ) {
        self.defaults = defaults
        self.proxyService = proxyService
        self.localProxyServer = localProxyServer
        self.preflightService = PreflightService(proxyService: proxyService)
        self.diagnosticsService = diagnosticsService
        self.telemetryService = telemetryService
        self.healthMonitor = healthMonitor
        self.xcodeAgentConfigStateProvider = xcodeAgentConfigStateProvider
        self.cliExecutableResolver = cliExecutableResolver
        self.cliUpdateRunner = cliUpdateRunner

        if let rawProvider = defaults.string(forKey: Self.upstreamProviderDefaultsKey),
           let provider = UpstreamProvider(rawValue: rawProvider) {
            upstreamProvider = provider
        } else {
            upstreamProvider = .zAI
        }

        let savedURL = defaults.string(forKey: "proxypilot.upstreamAPIBaseURL.\(upstreamProvider.rawValue)")
        upstreamAPIBaseURLString = savedURL ?? upstreamProvider.defaultAPIBaseURL
        launchAtLogin = SMAppService.mainApp.status == .enabled
        anthropicTranslatorFallbackEnabled = defaults.bool(forKey: Self.anthropicFallbackDefaultsKey)
        selectedXcodeAgentModel = storedXcodeAgentModel(for: upstreamProvider)
        persistSelectedXcodeAgentModel()

        telemetryOptIn = defaults.bool(forKey: Self.telemetryOptInDefaultsKey)
        suppressKeychainAccessPrimer = defaults.bool(forKey: Self.suppressKeychainPrimerDefaultsKey)
        autoRestartEnabled = defaults.object(forKey: Self.autoRestartEnabledDefaultsKey) as? Bool ?? true
        requireLocalAuth = defaults.bool(forKey: Self.requireLocalAuthDefaultsKey)
        showModelMetadata = defaults.object(forKey: Self.showModelMetadataDefaultsKey) as? Bool ?? true
        exactoFilterEnabled = defaults.object(forKey: Self.exactoFilterDefaultsKey) as? Bool ?? true
        verifiedFilterEnabled = defaults.object(forKey: Self.verifiedFilterDefaultsKey) as? Bool ?? false

        showOnboardingWizard = !defaults.bool(forKey: Self.didCompleteOnboardingDefaultsKey)

        if let data = defaults.data(forKey: Self.preflightSnapshotDefaultsKey),
           let decoded = try? JSONDecoder().decode([PreflightCheckResult].self, from: data) {
            preflightResults = decoded
        }

        refreshAgentConfigInstallationState()

        let priorSessionLikelyCrashed = telemetryService.beginSession()
        telemetryService.track(
            name: "app_opened",
            payload: ["mode": useBuiltInProxy ? "builtin" : "litellm"],
            telemetryOptIn: telemetryOptIn
        )
        if priorSessionLikelyCrashed {
            telemetryService.track(name: "previous_session_may_have_crashed", telemetryOptIn: telemetryOptIn)
        }

        if showOnboardingWizard {
            telemetryService.track(name: "onboarding_started", telemetryOptIn: telemetryOptIn)
        }

        isInitialized = true
        runPreflightChecks(trackEvent: false)
        Task { await detectXcodeInstallations() }
        if upstreamProvider == .openRouter {
            Task { await loadVerifiedModels() }
        }

        // Bridge LocalProxyState → AppViewModel so the menu bar icon updates
        // immediately when the NWListener state changes, without waiting for
        // an explicit refreshStatus() call.
        proxyStateCancellable = localProxyServer.state.$isRunning
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] running in
                guard let self, self.useBuiltInProxy else { return }
                self.isRunning = running
                self.statusText = self.statusTextForState(isRunning: running)
            }
    }

    func applicationWillTerminate() {
        telemetryService.endSession()
        stopLogUpdates()
    }

    func shouldPromptBeforeQuit() -> Bool {
        refreshAgentConfigInstallationState()
        return agentConfigInstalled
    }

    func toggleLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
                launchAtLogin = false
            } else {
                try SMAppService.mainApp.register()
                launchAtLogin = true
            }
            clearIssue()
        } catch {
            applyIssue(AppIssue(
                code: .generic,
                title: String(localized: "Launch at Login Failed"),
                message: String(localized: "Launch at Login could not be updated:") + " " + error.localizedDescription,
                actions: [.openReadme]
            ))
        }
    }

    func refreshStatus() {
        refreshAgentConfigInstallationState()
        isRunning = useBuiltInProxy ? localProxyServer.state.isRunning : proxyService.isRunning()
        statusText = statusTextForState(isRunning: isRunning)
        refreshLogText()
    }

    func refreshAgentConfigInstallationState() {
        agentConfigInstalled = computeAgentConfigInstalledState()
    }

    func maybeShowKeychainAccessPrimerOnLaunch() {
        guard !hasEvaluatedKeychainPrimerThisLaunch else { return }
        hasEvaluatedKeychainPrimerThisLaunch = true

        guard !suppressKeychainAccessPrimer else { return }
        guard KeychainService.requiresAuthorizationForAnyStoredKey() else { return }
        showKeychainAccessPrimer = true
    }

    func dismissKeychainAccessPrimer() {
        showKeychainAccessPrimer = false
    }

    func startLogUpdates() {
        refreshLogText()
        logRefreshTimer?.invalidate()
        logRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refreshLogText()
            }
        }

        healthMonitor.start(
            isRunning: { [weak self] in
                guard let self else { return false }
                return self.useBuiltInProxy ? self.localProxyServer.state.isRunning : self.proxyService.isRunning()
            },
            onUnexpectedStop: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    await self.handleUnexpectedStop()
                }
            }
        )
    }

    func stopLogUpdates() {
        logRefreshTimer?.invalidate()
        logRefreshTimer = nil
        healthMonitor.stop()
    }

    func saveUpstreamKey() {
        guard let keychainKey = upstreamProvider.keychainKey else { return }
        do {
            try KeychainService.set(upstreamKeyDraft, forKey: keychainKey)
            upstreamKeyDraft = ""
            showingUpstreamKeyField = false
            clearIssue()
            objectWillChange.send()
        } catch {
            applyIssue(AppIssue(
                code: .missingUpstreamKey,
                title: String(localized: "Unable to Save Upstream API Key"),
                message: String(localized: "Could not save your upstream API key to Keychain:") + " " + error.localizedDescription,
                actions: [.openUpstreamKeyEditor]
            ))
        }
    }

    func deleteUpstreamKey() {
        guard let keychainKey = upstreamProvider.keychainKey else { return }
        do {
            try KeychainService.delete(key: keychainKey)
            clearIssue()
            objectWillChange.send()
        } catch {
            applyIssue(AppIssue(
                code: .missingUpstreamKey,
                title: String(localized: "Unable to Delete Upstream API Key"),
                message: String(localized: "Could not delete upstream API key:") + " " + error.localizedDescription,
                actions: [.openUpstreamKeyEditor]
            ))
        }
    }

    func saveMasterKey() {
        do {
            try KeychainService.set(masterKeyDraft, forKey: .litellmMasterKey)
            masterKeyDraft = ""
            showingMasterKeyField = false
            clearIssue()
            objectWillChange.send()
        } catch {
            applyIssue(AppIssue(
                code: .missingMasterKey,
                title: String(localized: "Unable to Save Local Proxy Password"),
                message: String(localized: "Could not save Local Proxy Password to Keychain:") + " " + error.localizedDescription,
                actions: [.openMasterKeyEditor]
            ))
        }
    }

    func deleteMasterKey() {
        do {
            try KeychainService.delete(key: .litellmMasterKey)
            clearIssue()
            objectWillChange.send()
        } catch {
            applyIssue(AppIssue(
                code: .missingMasterKey,
                title: String(localized: "Unable to Delete Local Proxy Password"),
                message: String(localized: "Could not delete Local Proxy Password:") + " " + error.localizedDescription,
                actions: [.openMasterKeyEditor]
            ))
        }
    }

    func performIssueAction(_ action: AppIssue.Action) {
        switch action {
        case .openMasterKeyEditor:
            showingMasterKeyField = true
        case .openUpstreamKeyEditor:
            showingUpstreamKeyField = true
        case .resetProxyURL:
            proxyURLString = "http://127.0.0.1:4000"
            clearIssue()
        case .setProxyURLTo4001:
            if let validated = try? validatedProxyURL(requireLocalhost: false) {
                let host = validated.host == "localhost" ? "localhost" : "127.0.0.1"
                proxyURLString = "http://\(host):4001"
            } else {
                proxyURLString = "http://127.0.0.1:4001"
            }
            clearIssue()
        case .useBuiltInProxy:
            useBuiltInProxy = true
            clearIssue()
        case .resetUpstreamURL:
            resetUpstreamAPIBaseURL()
        case .runPreflight:
            runPreflightChecks()
        case .retryStart:
            guard !isRunning else { return }
            Task { await startProxy() }
        case .exportDiagnostics:
            exportDiagnostics()
        case .openReadme:
            openReadme()
        case .openWebsite:
            openWebsite()
        }
    }

    func applyPreflightFixAction(_ action: PreflightFixAction) {
        switch action {
        case .openMasterKeyEditor:
            performIssueAction(.openMasterKeyEditor)
        case .openUpstreamKeyEditor:
            performIssueAction(.openUpstreamKeyEditor)
        case .resetProxyURL:
            performIssueAction(.resetProxyURL)
        case .switchToBuiltInProxy:
            performIssueAction(.useBuiltInProxy)
        case .resetUpstreamURL:
            performIssueAction(.resetUpstreamURL)
        case .usePort4001:
            performIssueAction(.setProxyURLTo4001)
        case .none:
            break
        }
        runPreflightChecks(trackEvent: false)
    }

    func runPreflightChecks(trackEvent: Bool = true) {
        let context = PreflightContext(
            proxyURLString: proxyURLString,
            useBuiltInProxy: useBuiltInProxy,
            requireLocalAuth: requireLocalAuth,
            upstreamAPIBaseURLString: upstreamAPIBaseURLString,
            fallbackUpstreamBaseURLString: selectedUpstreamProviderDefaultAPIBaseURL,
            hasMasterKey: hasMasterKey,
            hasUpstreamKey: hasUpstreamKey,
            liteLLMScriptsExist: liteLLMScriptsExist
        )

        let checks = preflightService.run(context: context)
        preflightResults = checks
        preflightLastRun = Date()

        if let encoded = try? JSONEncoder().encode(checks) {
            defaults.set(encoded, forKey: Self.preflightSnapshotDefaultsKey)
        }

        if trackEvent && checks.contains(where: { $0.status == .fail }) {
            telemetryService.track(name: "preflight_failed", telemetryOptIn: telemetryOptIn)
        }
    }

    func finishOnboarding(force: Bool) {
        runPreflightChecks(trackEvent: true)
        if preflightHasBlockingFailures && !force {
            applyIssue(AppIssue(
                code: .generic,
                title: String(localized: "Setup Incomplete"),
                message: String(localized: "Resolve the failing preflight checks or continue anyway."),
                actions: [.runPreflight, .openReadme]
            ))
            return
        }

        defaults.set(true, forKey: Self.didCompleteOnboardingDefaultsKey)
        showOnboardingWizard = false
        telemetryService.track(name: "onboarding_completed", telemetryOptIn: telemetryOptIn)
        clearIssue()
    }

    func startProxy() async {
        clearIssue()
        telemetryService.track(name: "proxy_start_clicked", payload: ["mode": useBuiltInProxy ? "builtin" : "litellm"], telemetryOptIn: telemetryOptIn)

        do {
            if useBuiltInProxy {
                try startBuiltInProxy()
                try await validateBuiltInProxyCameUp()
            } else {
                try await proxyService.start()
                try await validateProxyCameUp()
            }
            expectedProxyRunning = true
            recoveryState = .monitoring
            telemetryService.track(name: "proxy_start_succeeded", payload: ["mode": useBuiltInProxy ? "builtin" : "litellm"], telemetryOptIn: telemetryOptIn)
        } catch {
            expectedProxyRunning = false
            recoveryState = .idle
            let issue = issueFor(
                error,
                fallbackCode: .generic,
                fallbackTitle: String(localized: "Failed to Start Proxy"),
                fallbackActions: [.retryStart, .runPreflight, .exportDiagnostics]
            )
            applyIssue(issue)
            telemetryService.track(name: "proxy_start_failed", payload: ["code": issue.code.rawValue], telemetryOptIn: telemetryOptIn)
        }

        refreshStatus()
    }

    func restartProxy() async {
        clearIssue()
        recoveryTask?.cancel()
        recoveryTask = nil
        do {
            if useBuiltInProxy {
                try stopBuiltInProxyIfRunning()
                try startBuiltInProxy()
                try await validateBuiltInProxyCameUp()
            } else {
                try await proxyService.restart()
                try await validateProxyCameUp()
            }
            expectedProxyRunning = true
            recoveryState = .monitoring
        } catch {
            expectedProxyRunning = false
            let issue = issueFor(
                error,
                fallbackCode: .generic,
                fallbackTitle: String(localized: "Failed to Restart Proxy"),
                fallbackActions: [.retryStart, .exportDiagnostics]
            )
            applyIssue(issue)
        }
        refreshStatus()
    }

    func stopProxy() async {
        clearIssue()
        expectedProxyRunning = false
        recoveryState = .idle
        recoveryTask?.cancel()
        recoveryTask = nil

        do {
            if useBuiltInProxy {
                try stopBuiltInProxyIfRunning()
            } else {
                try await proxyService.stop()
            }
        } catch {
            let issue = issueFor(
                error,
                fallbackCode: .generic,
                fallbackTitle: String(localized: "Failed to Stop Proxy"),
                fallbackActions: [.exportDiagnostics]
            )
            applyIssue(issue)
        }

        refreshStatus()
    }

    func testModels() async {
        clearIssue()
        modelsJSON = ""

        let masterKey: String?
        if requiresMasterKey {
            guard let saved = KeychainService.get(key: .litellmMasterKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !saved.isEmpty else {
                applyIssue(AppIssue(
                    code: .missingMasterKey,
                    title: String(localized: "Local Proxy Password Missing"),
                    message: String(localized: "Set Local Proxy Password in Keys (Keychain), then try again."),
                    actions: [.openMasterKeyEditor]
                ))
                return
            }
            masterKey = saved
        } else {
            masterKey = nil
        }

        do {
            let baseURL = try validatedProxyURL(requireLocalhost: false).url
            modelsJSON = try await proxyService.fetchModels(baseURL: baseURL, masterKey: masterKey)
            markFirstSuccessfulRequestIfNeeded()
        } catch {
            applyIssue(issueFor(
                error,
                fallbackCode: .generic,
                fallbackTitle: String(localized: "Model Fetch Failed"),
                fallbackActions: [.runPreflight, .exportDiagnostics]
            ))
        }
    }

    func fetchUpstreamModels() async {
        clearIssue()
        upstreamModels = []
        selectedUpstreamModels = []

        let apiBase: URL
        do {
            apiBase = try validatedUpstreamBaseURL()
        } catch {
            applyIssue(issueFor(
                error,
                fallbackCode: .invalidProxyURL,
                fallbackTitle: String(localized: "Invalid Upstream Base URL"),
                fallbackActions: [.resetUpstreamURL]
            ))
            return
        }

        let apiKey: String
        if upstreamProvider.requiresAPIKey {
            guard let keychainKey = upstreamProvider.keychainKey,
                  let key = KeychainService.get(key: keychainKey), !key.isEmpty else {
                applyIssue(AppIssue(
                    code: .missingUpstreamKey,
                    title: String(localized: "Upstream API Key Missing"),
                    message: String(localized: "Set your upstream API key in Keys (Keychain)."),
                    actions: [.openUpstreamKeyEditor]
                ))
                return
            }
            apiKey = key
        } else {
            apiKey = ""
        }

        do {
            let models = try await proxyService.fetchUpstreamModels(
                apiBase: apiBase,
                apiKey: apiKey,
                provider: upstreamProvider
            )
            upstreamModels = models
            selectedUpstreamModels = []
            reconcileXcodeAgentModelSelection()
            markFirstSuccessfulRequestIfNeeded()
        } catch {
            applyIssue(issueFor(
                error,
                fallbackCode: .generic,
                fallbackTitle: String(localized: "Upstream Model Fetch Failed"),
                fallbackActions: [.openUpstreamKeyEditor, .resetUpstreamURL, .exportDiagnostics]
            ))
        }
    }

    func syncProxyModelsFromSelection() async {
        clearIssue()
        let models = proxySyncModelCandidates
        guard !models.isEmpty else {
            applyIssue(AppIssue(
                code: .generic,
                title: String(localized: "No Models Selected"),
                message: String(localized: "Select at least one model before syncing."),
                actions: []
            ))
            return
        }

        reconcileXcodeAgentModelSelection()

        do {
            try writeLiteLLMConfig(models: models)
            try await proxyService.restart()
        } catch {
            applyIssue(issueFor(
                error,
                fallbackCode: .generic,
                fallbackTitle: String(localized: "Sync Failed"),
                fallbackActions: [.exportDiagnostics]
            ))
        }

        refreshStatus()
    }

    func testUpstreamResponse() async {
        clearIssue()
        upstreamTestOutput = ""
        upstreamTestModelUsed = ""

        let apiBase: URL
        do {
            apiBase = try validatedUpstreamBaseURL()
        } catch {
            applyIssue(issueFor(
                error,
                fallbackCode: .invalidProxyURL,
                fallbackTitle: String(localized: "Invalid Upstream Base URL"),
                fallbackActions: [.resetUpstreamURL]
            ))
            return
        }

        let apiKey: String
        if upstreamProvider.requiresAPIKey {
            guard let keychainKey = upstreamProvider.keychainKey,
                  let key = KeychainService.get(key: keychainKey), !key.isEmpty else {
                applyIssue(AppIssue(
                    code: .missingUpstreamKey,
                    title: String(localized: "Upstream API Key Missing"),
                    message: String(localized: "Set your upstream API key in Keys (Keychain)."),
                    actions: [.openUpstreamKeyEditor]
                ))
                return
            }
            apiKey = key
        } else {
            apiKey = ""
        }

        let model = effectiveXcodeAgentModel

        do {
            let text = try await proxyService.testUpstreamChat(
                apiBase: apiBase,
                apiKey: apiKey,
                model: model,
                provider: upstreamProvider
            )
            upstreamTestModelUsed = model
            upstreamTestOutput = text.isEmpty ? "(empty response)" : text
            markFirstSuccessfulRequestIfNeeded()
        } catch {
            applyIssue(issueFor(
                error,
                fallbackCode: .generic,
                fallbackTitle: String(localized: "Upstream Test Failed"),
                fallbackActions: [.openUpstreamKeyEditor, .resetUpstreamURL, .exportDiagnostics]
            ))
        }
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

    func resetUpstreamAPIBaseURL() {
        defaults.removeObject(forKey: "proxypilot.upstreamAPIBaseURL.\(upstreamProvider.rawValue)")
        upstreamAPIBaseURLString = selectedUpstreamProviderDefaultAPIBaseURL
        clearIssue()
    }

    func exportDiagnostics() {
        let manifest = currentDiagnosticsManifest()
        let context = DiagnosticsExportContext(
            builtInLogURL: Self.builtInProxyLogFileURL,
            toolchainLogURL: Self.toolchainLogFileURL,
            liteLLMLogURL: proxyService.paths.logFile,
            manifest: manifest
        )

        Task {
            do {
                let archiveURL = try await diagnosticsService.exportBundle(context: context)
                diagnosticsArchivePath = archiveURL.path
                supportSummary = diagnosticsService.buildSupportSummary(
                    issueCodes: recentIssueCodes,
                    manifest: manifest,
                    diagnosticsURL: archiveURL
                )
                telemetryService.track(name: "diagnostics_exported", telemetryOptIn: telemetryOptIn)
                clearIssue()
            } catch {
                applyIssue(AppIssue(
                    code: .generic,
                    title: String(localized: "Diagnostics Export Failed"),
                    message: String(localized: "Could not export diagnostics:") + " " + error.localizedDescription,
                    actions: [.openReadme]
                ))
            }
        }
    }

    func copySupportSummaryToPasteboard() {
        let manifest = currentDiagnosticsManifest()
        if supportSummary.isEmpty {
            supportSummary = diagnosticsService.buildSupportSummary(
                issueCodes: recentIssueCodes,
                manifest: manifest,
                diagnosticsURL: diagnosticsArchivePath.isEmpty ? nil : URL(fileURLWithPath: diagnosticsArchivePath)
            )
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(supportSummary, forType: .string)
    }

    func openFeedbackDraft() {
        copySupportSummaryToPasteboard()

        guard let url = feedbackDraftURL() else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    func feedbackDraftURL() -> URL? {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "micah@micah.chat"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "ProxyPilot Feedback (v\(version))"),
            URLQueryItem(name: "body", value: feedbackDraftBody(version: version, build: build))
        ]
        return components.url
    }

    func updateCLITool() async {
        guard !isUpdatingCLITool else { return }

        isUpdatingCLITool = true
        cliUpdateStatusIsError = false
        cliUpdateStatusText = String(localized: "Checking for CLI updates...")

        defer { isUpdatingCLITool = false }

        guard let executableURL = resolveCLIExecutableURL() else {
            cliUpdateStatusIsError = true
            cliUpdateStatusText = String(localized: "ProxyPilot CLI was not found. Install it first, then retry update.")
            return
        }

        do {
            let execution = try await runCLIUpdater(executableURL: executableURL)
            applyCLIUpdateExecutionResult(execution, executableURL: executableURL)
        } catch {
            cliUpdateStatusIsError = true
            cliUpdateStatusText = String(localized: "Failed to run CLI updater:") + " " + error.localizedDescription
        }
    }

    func openReadme() {
        guard let url = URL(string: "https://github.com/masterofthechaos/Zai-ProxyPilot/blob/main/README.md") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openWebsite() {
        guard let url = URL(string: "https://micah.chat/Proxypilot") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func feedbackDraftBody(version: String, build: String) -> String {
        """
        Hi Micah,

        I'd like to share feedback about ProxyPilot.

        What I was trying to do:

        What happened:

        What I expected:

        Quick context:
        - App version: v\(version) (\(build))
        - Upstream provider: \(upstreamProvider.title)
        - Upstream base URL: \(upstreamAPIBaseURLString)
        - Proxy running: \(isRunning ? "Yes" : "No")

        A technical support summary has been copied to the clipboard if you need it.
        """
    }

    private func writeLiteLLMConfig(models: [String]) throws {
        let configURL = proxyService.paths.configFile
        let rawAPIBase = upstreamAPIBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackAPIBase = selectedUpstreamProviderDefaultAPIBaseURL
        let normalizedInput = rawAPIBase.isEmpty ? fallbackAPIBase : rawAPIBase

        guard let normalizedURL = proxyService.normalizedUpstreamAPIBase(from: normalizedInput) else {
            throw IssueError(issue: AppIssue(
                code: .invalidProxyURL,
                title: String(localized: "Invalid Upstream Base URL"),
                message: String(localized: "Upstream API base URL is invalid."),
                actions: [.resetUpstreamURL]
            ))
        }

        let apiBase = normalizedURL.absoluteString

        let header = """
# LiteLLM proxy config for an OpenAI-compatible upstream endpoint.
#
# IMPORTANT:
# - Do not put your API key in this file. Use env vars instead.
#
# Env vars:
# - ZAI_API_KEY (legacy variable name used as generic upstream key)
# - LITELLM_MASTER_KEY

"""

        var body = "model_list:\n"
        for model in models {
            body += """
  - model_name: \(model)
    litellm_params:
      custom_llm_provider: openai
      model: \(model)
      api_base: \(apiBase)
      api_key: os.environ/ZAI_API_KEY

"""
        }

        body += """
general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
"""

        try (header + body).write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func resolveCLIExecutableURL() -> URL? {
        if let cliExecutableResolver {
            return cliExecutableResolver()
        }
        return Self.defaultCLIExecutableURL()
    }

    private static func defaultCLIExecutableURL() -> URL? {
        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"], !path.isEmpty {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/proxypilot" })
        }

        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        candidates.append(contentsOf: [
            "/usr/local/bin/proxypilot",
            "/opt/homebrew/bin/proxypilot",
            "\(homePath)/.local/bin/proxypilot",
            "\(homePath)/bin/proxypilot",
        ])

        var seenPaths: Set<String> = []
        for candidate in candidates {
            let expandedPath = (candidate as NSString).expandingTildeInPath
            guard seenPaths.insert(expandedPath).inserted else { continue }
            if FileManager.default.isExecutableFile(atPath: expandedPath) {
                return URL(fileURLWithPath: expandedPath).standardizedFileURL.resolvingSymlinksInPath()
            }
        }

        return nil
    }

    private func runCLIUpdater(executableURL: URL) async throws -> CLIUpdateExecutionResult {
        if let cliUpdateRunner {
            return try await cliUpdateRunner(executableURL)
        }
        return try await Self.executeCLIUpdateProcess(executableURL: executableURL)
    }

    private static func executeCLIUpdateProcess(executableURL: URL) async throws -> CLIUpdateExecutionResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = executableURL
            process.arguments = ["update", "--json"]
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            try process.run()
            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            return CLIUpdateExecutionResult(
                terminationStatus: process.terminationStatus,
                stdout: String(decoding: stdoutData, as: UTF8.self),
                stderr: String(decoding: stderrData, as: UTF8.self)
            )
        }.value
    }

    private func applyCLIUpdateExecutionResult(_ execution: CLIUpdateExecutionResult, executableURL: URL) {
        let stdout = execution.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = execution.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = stdout.data(using: .utf8),
           let envelope = try? JSONDecoder().decode(CLIUpdateEnvelope.self, from: data) {
            if envelope.ok {
                cliUpdateStatusIsError = false
                cliUpdateStatusText = cliUpdateSuccessMessage(from: envelope.data, fallbackPath: executableURL.path)
                return
            }

            if let errorPayload = envelope.error {
                cliUpdateStatusIsError = true
                var message = "[\(errorPayload.code)] \(errorPayload.message)"
                if let suggestion = errorPayload.suggestion, !suggestion.isEmpty {
                    message += " " + suggestion
                }
                cliUpdateStatusText = message
                return
            }
        }

        if execution.terminationStatus == 0 {
            cliUpdateStatusIsError = false
            cliUpdateStatusText = stdout.isEmpty ? String(localized: "CLI update finished.") : stdout
            return
        }

        cliUpdateStatusIsError = true
        let detail = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: " ")
        if detail.isEmpty {
            cliUpdateStatusText = String(localized: "CLI update failed with exit code") + " \(execution.terminationStatus)."
        } else {
            cliUpdateStatusText = detail
        }
    }

    private func cliUpdateSuccessMessage(from data: CLIUpdateData?, fallbackPath: String) -> String {
        guard let data else { return String(localized: "CLI update finished.") }

        switch data.status {
        case "updated":
            let fromVersion = data.from ?? "?"
            let toVersion = data.to ?? "?"
            let path = data.path ?? fallbackPath
            return "Updated ProxyPilot CLI v\(fromVersion) -> v\(toVersion) at \(path)"
        case "up-to-date":
            let version = data.version ?? "?"
            return "ProxyPilot CLI is already up-to-date (v\(version))."
        case "ahead":
            let installed = data.installed ?? "?"
            let latest = data.latest ?? "?"
            return "Installed CLI (v\(installed)) is newer than manifest latest (v\(latest))."
        case "update-available":
            let installed = data.installed ?? "?"
            let latest = data.latest ?? "?"
            return "Update available: v\(installed) -> v\(latest)."
        default:
            return String(localized: "CLI update finished.")
        }
    }

    private func validatedProxyURL(requireLocalhost: Bool) throws -> ProxyURLValidation {
        let validationResult = preflightService.validateProxyURL(proxyURLString)
        switch validationResult {
        case .success(let validation):
            if requireLocalhost {
                if validation.host != "127.0.0.1" && validation.host != "localhost" {
                    throw IssueError(issue: AppIssue(
                        code: .invalidProxyURL,
                        title: String(localized: "Built-In Proxy Requires Localhost"),
                        message: String(localized: "Built-in proxy only supports http://127.0.0.1:<port> or http://localhost:<port>."),
                        actions: [.resetProxyURL]
                    ))
                }
            }
            return validation
        case .failure(let issue):
            throw IssueError(issue: issue)
        }
    }

    private func validatedUpstreamBaseURL() throws -> URL {
        if let validated = preflightService.validatedUpstreamBaseURL(upstreamAPIBaseURLString) {
            return validated
        }

        throw IssueError(issue: AppIssue(
            code: .invalidProxyURL,
            title: String(localized: "Invalid Upstream Base URL"),
            message: String(localized: "Upstream URL must be a full http(s) base URL, for example https://api.z.ai/api/coding/paas/v4."),
            actions: [.resetUpstreamURL]
        ))
    }

    private func validateProxyCameUp() async throws {
        let baseURL = try validatedProxyURL(requireLocalhost: false).url

        try? await Task.sleep(nanoseconds: 450_000_000)

        do {
            _ = try await proxyService.probe(baseURL: baseURL)
        } catch {
            let tail = proxyService.readLogTail()
            if tail.isEmpty {
                throw IssueError(issue: AppIssue(
                    code: .generic,
                    title: String(localized: "Proxy Did Not Start"),
                    message: String(localized: "Proxy did not respond on") + " " + baseURL.absoluteString + ".",
                    actions: [.runPreflight, .exportDiagnostics]
                ))
            }

            throw IssueError(issue: AppIssue(
                code: .generic,
                title: String(localized: "Proxy Did Not Start"),
                message: String(localized: "Proxy did not start. Check logs in the Log section for details."),
                actions: [.runPreflight, .exportDiagnostics]
            ))
        }
    }

    private func validateBuiltInProxyCameUp() async throws {
        let baseURL = try validatedProxyURL(requireLocalhost: true).url

        for _ in 0..<10 {
            if localProxyServer.state.isRunning { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        do {
            _ = try await proxyService.probe(baseURL: baseURL)
            localProxyServer.state.isRunning = true
        } catch {
            let status = localProxyServer.state.lastStatus
            if status.lowercased().contains("address already in use") {
                throw IssueError(issue: AppIssue(
                    code: .portInUse,
                    title: String(localized: "Proxy Port Already In Use"),
                    message: String(localized: "Port appears to be in use. Switch to 4001 or stop the process using the current port."),
                    actions: [.setProxyURLTo4001, .runPreflight]
                ))
            }

            if status.isEmpty {
                throw IssueError(issue: AppIssue(
                    code: .generic,
                    title: String(localized: "Built-In Proxy Did Not Start"),
                    message: String(localized: "Built-in proxy did not start (no listener on") + " " + baseURL.absoluteString + ").",
                    actions: [.runPreflight, .exportDiagnostics]
                ))
            }

            throw IssueError(issue: AppIssue(
                code: .generic,
                title: String(localized: "Built-In Proxy Did Not Start"),
                message: String(localized: "Built-in proxy did not start. Status:") + " " + status,
                actions: [.runPreflight, .exportDiagnostics]
            ))
        }
    }

    private func startBuiltInProxy() throws {
        let proxy = try validatedProxyURL(requireLocalhost: true)

        guard let port = UInt16(exactly: proxy.port), (1...65535).contains(proxy.port) else {
            throw IssueError(issue: AppIssue(
                code: .invalidPortRange,
                title: String(localized: "Invalid Proxy Port"),
                message: String(localized: "Proxy port must be between 1 and 65535."),
                actions: [.resetProxyURL]
            ))
        }

        let masterKey: String
        if requireLocalAuth {
            guard let configuredMasterKey = KeychainService.get(key: .litellmMasterKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !configuredMasterKey.isEmpty else {
                throw IssueError(issue: AppIssue(
                    code: .missingMasterKey,
                    title: String(localized: "Local Proxy Password Missing"),
                    message: String(localized: "Set Local Proxy Password in Keys (Keychain), then start the proxy again."),
                    actions: [.openMasterKeyEditor]
                ))
            }
            masterKey = configuredMasterKey
        } else {
            masterKey = "proxypilot-local-noauth"
        }

        let upstreamKey: String? = {
            guard let keychainKey = upstreamProvider.keychainKey else { return nil }
            let value = KeychainService.get(key: keychainKey)
            if let value, !value.isEmpty {
                return value
            }
            return nil
        }()

        var allowedModels: Set<String> = {
            if !selectedUpstreamModels.isEmpty { return selectedUpstreamModels }
            if !upstreamModels.isEmpty { return Set(upstreamModels.map(\.id)) }
            return Set(savedDefaultModels)
        }()
        let preferredModel = effectiveXcodeAgentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferredModel.isEmpty {
            allowedModels.insert(preferredModel)
        }

        guard let defaultUpstreamBase = URL(string: selectedUpstreamProviderDefaultAPIBaseURL) else {
            throw IssueError(issue: AppIssue(
                code: .invalidProxyURL,
                title: String(localized: "Invalid Upstream Provider Default"),
                message: String(localized: "Provider default upstream URL is invalid. Reset to a valid preset and retry."),
                actions: [.resetUpstreamURL]
            ))
        }

        let upstreamBase = proxyService.normalizedUpstreamAPIBase(from: upstreamAPIBaseURLString) ?? defaultUpstreamBase

        do {
            try localProxyServer.start(config: .init(
                host: proxy.host,
                port: port,
                masterKey: masterKey,
                upstreamProvider: upstreamProvider,
                upstreamAPIBase: upstreamBase,
                upstreamAPIKey: upstreamKey,
                allowedModels: allowedModels,
                requiresAuth: requireLocalAuth,
                anthropicTranslatorMode: anthropicTranslatorFallbackEnabled ? .legacyFallback : .hardened,
                preferredAnthropicUpstreamModel: preferredModel.isEmpty
                    ? preferredXcodeAgentModel(from: savedDefaultModels)
                    : preferredModel,
                googleThoughtSignatureStore: upstreamProvider == .google ? GoogleThoughtSignatureStore() : nil
            ))
        } catch {
            if let serverError = error as? LocalProxyServer.ServerError,
               case .bindFailed(let message) = serverError,
               message.lowercased().contains("address already in use") {
                throw IssueError(issue: AppIssue(
                    code: .portInUse,
                    title: String(localized: "Proxy Port Already In Use"),
                    message: String(localized: "Port") + " \(proxy.port) " + String(localized: "is already in use. Choose another port (for example 4001)."),
                    actions: [.setProxyURLTo4001, .runPreflight]
                ))
            }
            throw error
        }

        if upstreamKey == nil && upstreamProvider.requiresAPIKey {
            applyIssue(AppIssue(
                code: .missingUpstreamKey,
                title: String(localized: "Proxy Started Without Upstream Key"),
                message: String(localized: "Built-in proxy started, but upstream requests will fail until you set Upstream API Key."),
                actions: [.openUpstreamKeyEditor]
            ))
        }
    }

    private func preferredXcodeAgentModel(from models: [String], provider: UpstreamProvider? = nil) -> String {
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

    private func storedXcodeAgentModel(for provider: UpstreamProvider) -> String {
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

    private func persistSelectedXcodeAgentModel() {
        defaults.set(selectedXcodeAgentModel, forKey: Self.xcodeAgentModelDefaultsKey(for: upstreamProvider))
        defaults.set(selectedXcodeAgentModel, forKey: Self.xcodeAgentModelLegacyDefaultsKey)
    }

    private static func xcodeAgentModelDefaultsKey(for provider: UpstreamProvider) -> String {
        xcodeAgentModelDefaultsKeyPrefix + provider.rawValue
    }

    private func upstreamAPIBaseURL(for provider: UpstreamProvider) -> URL? {
        let defaultBase = provider.defaultAPIBaseURL
        let storedBase = defaults.string(forKey: "proxypilot.upstreamAPIBaseURL.\(provider.rawValue)")
        let raw = (provider == upstreamProvider ? upstreamAPIBaseURLString : storedBase) ?? defaultBase
        return proxyService.normalizedUpstreamAPIBase(from: raw) ?? URL(string: defaultBase)
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

    private func stopBuiltInProxyIfRunning() throws {
        if localProxyServer.state.isRunning {
            try localProxyServer.stop()
        }
    }

    private static func csvEscaped(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }

    private func refreshLogText() {
        if useBuiltInProxy {
            logText = proxyService.readLogTail(from: Self.builtInProxyLogFileURL)
        } else {
            logText = proxyService.readLogTail()
        }
    }

    func clearLog() {
        let logURL = useBuiltInProxy ? Self.builtInProxyLogFileURL : proxyService.paths.logFile
        try? FileManager.default.removeItem(at: logURL)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logText = ""
    }

    private func handleUnexpectedStop() async {
        refreshStatus()

        guard expectedProxyRunning else { return }
        guard autoRestartEnabled else {
            recoveryState = .degraded(reason: String(localized: "Proxy stopped unexpectedly and auto-restart is disabled."))
            applyIssue(AppIssue(
                code: .generic,
                title: String(localized: "Proxy Stopped Unexpectedly"),
                message: String(localized: "Auto-restart is disabled. Start the proxy manually or enable auto-restart."),
                actions: [.retryStart, .exportDiagnostics]
            ))
            return
        }

        guard recoveryTask == nil else { return }

        recoveryTask = Task { [weak self] in
            guard let self else { return }
            let recovered = await self.healthMonitor.attemptRecovery(onState: { state in
                self.recoveryState = state
            }, operation: { _ in
                do {
                    if self.useBuiltInProxy {
                        try self.stopBuiltInProxyIfRunning()
                        try self.startBuiltInProxy()
                        try await self.validateBuiltInProxyCameUp()
                    } else {
                        try await self.proxyService.restart()
                        try await self.validateProxyCameUp()
                    }
                    self.expectedProxyRunning = true
                    self.refreshStatus()
                    return true
                } catch {
                    self.refreshStatus()
                    return false
                }
            })

            if !recovered {
                self.applyIssue(AppIssue(
                    code: .generic,
                    title: String(localized: "Auto-Recovery Failed"),
                    message: String(localized: "Proxy stopped unexpectedly and automatic recovery exhausted all retries."),
                    actions: [.retryStart, .exportDiagnostics]
                ))
            }

            self.recoveryTask = nil
        }
    }

    private func statusTextForState(isRunning: Bool) -> String {
        if isRunning {
            return recoveryState == .recovered ? String(localized: "Running (Recovered)") : String(localized: "Running")
        }

        switch recoveryState {
        case .recovering(let attempt, _):
            return String(localized: "Recovering") + " (\(attempt))"
        case .degraded:
            return String(localized: "Degraded")
        default:
            return String(localized: "Stopped")
        }
    }

    private func markFirstSuccessfulRequestIfNeeded() {
        guard !hasTrackedFirstSuccessfulRequest else { return }
        hasTrackedFirstSuccessfulRequest = true
        telemetryService.track(name: "first_successful_request", telemetryOptIn: telemetryOptIn)
    }

    private func applyIssue(_ issue: AppIssue) {
        activeIssue = issue
        lastError = "[\(issue.code.rawValue)] \(issue.message)"
        appendIssueCode(issue.code)
    }

    private func clearIssue() {
        activeIssue = nil
        lastError = nil
    }

    private func appendIssueCode(_ code: AppIssue.Code) {
        let codeString = code.rawValue
        if let idx = recentIssueCodes.firstIndex(of: codeString) {
            recentIssueCodes.remove(at: idx)
        }
        recentIssueCodes.insert(codeString, at: 0)
        if recentIssueCodes.count > 20 {
            recentIssueCodes = Array(recentIssueCodes.prefix(20))
        }
    }

    private func issueFor(
        _ error: Error,
        fallbackCode: AppIssue.Code,
        fallbackTitle: String,
        fallbackActions: [AppIssue.Action]
    ) -> AppIssue {
        if let issueError = error as? IssueError {
            return issueError.issue
        }

        if let serviceError = error as? ProxyServiceError {
            switch serviceError {
            case .httpStatus(let status, let body):
                if status == 401 || status == 403 {
                    return AppIssue(
                        code: .upstreamUnauthorized,
                        title: String(localized: "Upstream Authorization Failed"),
                        message: String(localized: "Upstream provider returned HTTP") + " \(status). " + String(localized: "Verify your API key and provider URL."),
                        actions: [.openUpstreamKeyEditor, .resetUpstreamURL]
                    )
                }
                if status == 413 {
                    return AppIssue(
                        code: .requestTooLarge,
                        title: String(localized: "Request Too Large"),
                        message: String(localized: "Upstream provider rejected request size (HTTP 413)."),
                        actions: [.exportDiagnostics]
                    )
                }
                return AppIssue(
                    code: fallbackCode,
                    title: fallbackTitle,
                    message: body.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(body)",
                    actions: fallbackActions
                )
            default:
                break
            }
        }

        if let urlError = error as? URLError, urlError.code == .timedOut {
            return AppIssue(
                code: .upstreamTimeout,
                title: String(localized: "Request Timed Out"),
                message: String(localized: "The request timed out. Check network connectivity and upstream provider availability."),
                actions: [.retryStart, .exportDiagnostics]
            )
        }

        if let serverError = error as? LocalProxyServer.ServerError,
           case .bindFailed(let message) = serverError,
           message.lowercased().contains("address already in use") {
            return AppIssue(
                code: .portInUse,
                title: String(localized: "Proxy Port Already In Use"),
                message: String(localized: "Another process is using this port. Switch to 4001 or free the current port."),
                actions: [.setProxyURLTo4001, .runPreflight]
            )
        }

        let text = error.localizedDescription.lowercased()
        if text.contains("timed out") {
            return AppIssue(
                code: .upstreamTimeout,
                title: String(localized: "Request Timed Out"),
                message: String(localized: "The request timed out. Retry after checking your network and provider status."),
                actions: [.retryStart, .exportDiagnostics]
            )
        }

        if text.contains("unauthorized") {
            return AppIssue(
                code: .upstreamUnauthorized,
                title: String(localized: "Unauthorized"),
                message: String(localized: "Authorization failed. Verify credentials and provider settings."),
                actions: [.openUpstreamKeyEditor, .resetUpstreamURL]
            )
        }

        if text.contains("too large") {
            return AppIssue(
                code: .requestTooLarge,
                title: String(localized: "Request Too Large"),
                message: String(localized: "Request exceeded the configured size limits."),
                actions: [.exportDiagnostics]
            )
        }

        return AppIssue(
            code: fallbackCode,
            title: fallbackTitle,
            message: error.localizedDescription,
            actions: fallbackActions
        )
    }

    private func currentDiagnosticsManifest() -> DiagnosticsManifest {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"

        return DiagnosticsManifest(
            appVersion: version,
            buildNumber: build,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            mode: useBuiltInProxy ? "built-in" : "litellm",
            proxyURL: proxyURLString,
            upstreamBase: upstreamAPIBaseURLString,
            selectedModel: effectiveXcodeAgentModel,
            recentIssueCodes: recentIssueCodes,
            preflightSnapshot: preflightResults,
            timestamp: Date()
        )
    }

    // MARK: - Xcode Detection

    func detectXcodeInstallations() async {
        let installations = await xcodeDetectionService.detectInstallations()
        xcodeInstallations = installations
    }

    // MARK: - Xcode Agent Config

    @Published var agentConfigInstalled: Bool = false
    @Published var agentConfigStatus: String = ""

    private var xcodeAgentConfigDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig", isDirectory: true)
    }

    private var xcodeAgentConfigSettingsURL: URL {
        xcodeAgentConfigDirectoryURL.appendingPathComponent("settings.json")
    }

    private func computeAgentConfigInstalledState() -> Bool {
        if let xcodeAgentConfigStateProvider {
            return xcodeAgentConfigStateProvider()
        }

        let settingsExists = FileManager.default.fileExists(atPath: xcodeAgentConfigSettingsURL.path)
        let xcodeDefaults = UserDefaults.standard.persistentDomain(forName: Self.xcodeDefaultsDomain)
        let defaultsOverrideExists = xcodeDefaults?[Self.xcodeAgentAPIKeyOverrideDefaultsKey] != nil
        return settingsExists || defaultsOverrideExists
    }

    var recoveryCommands: String {
        """
        rm ~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/settings.json
        defaults delete com.apple.dt.Xcode IDEChatClaudeAgentAPIKeyOverride
        """
    }

    var diyInstallCommands: String {
        let proxyBase = proxyURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        # Install (route Xcode Agent through ProxyPilot):
        mkdir -p ~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig
        echo '{"env":{"ANTHROPIC_AUTH_TOKEN":"proxypilot","ANTHROPIC_BASE_URL":"\(proxyBase)"}}' \\
          > ~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/settings.json
        defaults write com.apple.dt.Xcode IDEChatClaudeAgentAPIKeyOverride " "

        # Revert (restore native Xcode Agent behavior):
        rm ~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/settings.json
        defaults delete com.apple.dt.Xcode IDEChatClaudeAgentAPIKeyOverride
        """
    }

    func installXcodeAgentConfig() {
        clearIssue()
        agentConfigStatus = ""

        do {
            try FileManager.default.createDirectory(at: xcodeAgentConfigDirectoryURL, withIntermediateDirectories: true)

            let proxyBase = proxyURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            let settingsContent = """
            {
              "env": {
                "ANTHROPIC_AUTH_TOKEN": "proxypilot",
                "ANTHROPIC_BASE_URL": "\(proxyBase)"
              }
            }
            """

            try settingsContent.write(to: xcodeAgentConfigSettingsURL, atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            process.arguments = ["write", "com.apple.dt.Xcode", "IDEChatClaudeAgentAPIKeyOverride", " "]
            try process.run()
            process.waitUntilExit()

            refreshAgentConfigInstallationState()
            agentConfigStatus = String(localized: "Wrote settings.json + set defaults. Restart Xcode to activate.")
        } catch {
            applyIssue(AppIssue(
                code: .generic,
                title: String(localized: "Failed to Install Xcode Agent Config"),
                message: error.localizedDescription,
                actions: [.exportDiagnostics]
            ))
        }
    }

    func removeXcodeAgentConfig() {
        clearIssue()
        agentConfigStatus = ""

        do {
            if FileManager.default.fileExists(atPath: xcodeAgentConfigSettingsURL.path) {
                try FileManager.default.removeItem(at: xcodeAgentConfigSettingsURL)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            process.arguments = ["delete", "com.apple.dt.Xcode", "IDEChatClaudeAgentAPIKeyOverride"]
            try process.run()
            process.waitUntilExit()

            refreshAgentConfigInstallationState()
            agentConfigStatus = String(localized: "Removed. Restart Xcode to revert.")
        } catch {
            applyIssue(AppIssue(
                code: .generic,
                title: String(localized: "Failed to Remove Xcode Agent Config"),
                message: error.localizedDescription,
                actions: [.exportDiagnostics]
            ))
        }
    }
}
