import AppKit
import Combine
import Foundation
import ProxyPilotCore
import ServiceManagement
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {

    private typealias IssueError = AppIssueError

    enum ProxyRuntimeStatus: Equatable {
        case stopped
        case runningInApp
        case runningExternal
        case portOccupied(statusCode: Int)
    }

    enum XcodeVisibleModelsSource: String, Equatable {
        case notChecked
        case runningProxy
        case pendingSettings
    }

    enum ProviderCLIAuthStatus: Equatable {
        case notChecked
        case checking
        case visible
        case notVisible(String)
        case cliMissing
        case failed(String)
    }

    struct XcodeVisibleModelsSnapshot: Equatable {
        var modelIDs: [String] = []
        var checkedAt: Date?
        var source: XcodeVisibleModelsSource = .notChecked
        var errorMessage: String?

        var reflectsRunningProxy: Bool {
            source == .runningProxy && errorMessage == nil
        }
    }

    private static let anthropicFallbackDefaultsKey = "proxypilot.anthropicTranslatorFallbackEnabled"
    private static let didCompleteOnboardingDefaultsKey = "proxypilot.didCompleteOnboarding"
    private static let telemetryOptInDefaultsKey = "proxypilot.telemetryOptIn"
    private static let liquidGlassEnabledDefaultsKey = "proxypilot.liquidGlassEnabled"
    private static let inputOutputLoggingEnabledDefaultsKey = "proxypilot.inputOutputLogging.enabled"
    private static let inputOutputLoggingRecordInputsDefaultsKey = "proxypilot.inputOutputLogging.recordInputs"
    private static let inputOutputLoggingRecordOutputsDefaultsKey = "proxypilot.inputOutputLogging.recordOutputs"
    private static let inputOutputLoggingCLIEnabledDefaultsKey = "proxypilot.inputOutputLogging.cliEnabled"
    private static let inputOutputLoggingRetentionDefaultsKey = "proxypilot.inputOutputLogging.retention"
    private static let inputOutputLoggingExternalStorageDefaultsKey = "proxypilot.inputOutputLogging.externalStorage"
    private static let promptCachingModeDefaultsKey = "proxypilot.promptCaching.mode"
    static let appearancePreferenceDefaultsKey = "proxypilot.customization.appearance"
    static let proxyPilotAccentHexDefaultsKey = "proxypilot.customization.accentHex"
    static let showMenuBarExtraDefaultsKey = "proxypilot.customization.showMenuBarExtra"
    static let menuBarSectionOrderDefaultsKey = "proxypilot.customization.menuBarSectionOrder"
    static let visibleMenuBarSectionsDefaultsKey = "proxypilot.customization.visibleMenuBarSections"
    static let visibleHomeDashboardSectionsDefaultsKey = "proxypilot.customization.visibleHomeDashboardSections"
    static let defaultSettingsSectionDefaultsKey = "proxypilot.customization.defaultSettingsSection"
    static let keysProviderOrderDefaultsKey = "proxypilot.customization.keysProviderOrder"
    static let visibleKeysProvidersDefaultsKey = "proxypilot.customization.visibleKeysProviders"
    static let didMigrateQwenVisibleProviderDefaultsKey = "proxypilot.customization.didMigrateQwenVisibleProvider"
    static let copilotSidecarExpandedDefaultsKey = "proxypilot.customization.copilotSidecarExpanded"
    // autoRestartEnabled defaults key: kept here for resetToFreshInstall cleanup
    private static let autoRestartEnabledDefaultsKey = "proxypilot.autoRestartEnabled"
    private static let requireLocalAuthDefaultsKey = "proxypilot.requireLocalAuth"
    private static let preflightSnapshotDefaultsKey = "proxypilot.lastPreflightSnapshot"
    private static let suppressKeychainPrimerDefaultsKey = "proxypilot.suppressKeychainPrimer"
    private static let analyticsPromptShownVersionKey = "proxypilot.analyticsPromptShownVersion"
    private static let xcodeDefaultsDomain = "com.apple.dt.Xcode"
    private static let xcodeAgentAPIKeyOverrideDefaultsKey = "IDEChatClaudeAgentAPIKeyOverride"

    private static let builtInProxyLogFileURL = URL(fileURLWithPath: "/tmp/proxypilot_builtin_proxy.log")
    private static let toolchainLogFileURL = URL(fileURLWithPath: "/tmp/proxypilot_toolchain.log")
    private static let sessionRequestTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let defaultUpstreamAPIBaseURL = UpstreamProvider.zAI.defaultAPIBaseURL

    let providerManager: ProviderManager
    let proxyLifecycle: ProxyLifecycleManager
    let customProviderStorage: CustomProviderStorage

    private let defaults: UserDefaults
    private let proxyService: ProxyService
    private let localProxyServer: LocalProxyServer
    private let preflightService: PreflightService
    private let diagnosticsService: DiagnosticsService
    private let telemetryService: TelemetryService
    private let healthMonitor: HealthMonitor
    private let copilotSidecarService: CopilotSidecarService
    private let xcodeAgentConfigStateProvider: (() -> Bool)?
    private let xcodeDetectionService = XcodeDetectionService()
    private let cliExecutableResolver: CLIExecutableResolver?
    private let cliUpdateRunner: CLIUpdateRunner?
    private let cliAuthStatusRunner: CLIAuthStatusRunner?
    private let cliStopRunner: CLIStopRunner?
    private let inputOutputLoggingPreferencesStore: InputOutputLoggingPreferencesStore?

    typealias CLIExecutableResolver = () -> URL?
    typealias CLIUpdateRunner = (URL) async throws -> CLIUpdateExecutionResult
    typealias CLIAuthStatusRunner = (URL, UpstreamProvider) async throws -> CLIUpdateExecutionResult
    typealias CLIStopRunner = (URL, UInt16) async throws -> CLIUpdateExecutionResult

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

    private struct CLIAuthStatusEnvelope: Decodable {
        let ok: Bool
        let data: CLIAuthStatusData?
        let error: CLIUpdateErrorPayload?
    }

    private struct CLIAuthStatusData: Decodable {
        let provider: String
        let status: String
        let stored: Bool
        let backend: String?
    }

    private var providerManagerCancellable: AnyCancellable?
    private var lifecycleManagerCancellable: AnyCancellable?
    private var logRefreshTimer: Timer?
    private var statusAutoRefreshTimer: Timer?
    private var statusRefreshSequence = 0
    private let sessionReportURL: URL
    private var importedExternalSessionEventIDs: Set<UUID> = []
    private var importedExternalSessionIDs: Set<String> = []
    private var suppressedExternalSessionIDs: Set<String> = []
    private var hasTrackedFirstSuccessfulRequest = false
    private var hasEvaluatedKeychainPrimerThisLaunch = false
    private static let preflightExpandedDefaultsKey = "proxypilot.preflightExpanded"
    private static let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    private static let buildNumber: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    private static let publicRepositoryURLString = "https://github.com/masterofthechaos/ProxyPilot-public"
    private static let readmeURLString = "https://github.com/masterofthechaos/ProxyPilot-public/blob/main/README.md"
    static let defaultProxyURLString = "http://127.0.0.1:4000"
    static let refreshProxyStatusHelpText = "Refresh proxy status now. ProxyPilot also checks this automatically every 10 seconds while this window is open."

    @Published var proxyURLString: String = AppViewModel.defaultProxyURLString

    var upstreamAPIBaseURLString: String {
        get { providerManager.upstreamAPIBaseURLString }
        set { providerManager.upstreamAPIBaseURLString = newValue }
    }

    var upstreamProvider: UpstreamProvider {
        get { providerManager.upstreamProvider }
        set { providerManager.upstreamProvider = newValue }
    }

    var miniMaxRoutingMode: MiniMaxRoutingMode {
        get { providerManager.miniMaxRoutingMode }
        set { providerManager.miniMaxRoutingMode = newValue }
    }

    // MARK: - Custom Providers

    var customProviders: [CustomProvider] { customProviderStorage.providers }

    func addCustomProvider(name: String, apiBaseURL: String, apiKey: String) {
        let provider = CustomProvider(name: name, apiBaseURL: apiBaseURL)
        customProviderStorage.add(provider, apiKey: apiKey)
        objectWillChange.send()
    }

    func deleteCustomProvider(_ provider: CustomProvider) {
        customProviderStorage.delete(provider)
        objectWillChange.send()
    }

    func updateCustomProvider(_ provider: CustomProvider) {
        customProviderStorage.update(provider)
        objectWillChange.send()
    }

    func customProviderHasKey(_ provider: CustomProvider) -> Bool {
        customProviderStorage.hasAPIKey(for: provider)
    }

    func saveCustomProviderKey(_ key: String, for provider: CustomProvider) {
        customProviderStorage.saveAPIKey(key, for: provider)
        objectWillChange.send()
    }

    func deleteCustomProviderKey(for provider: CustomProvider) {
        try? KeychainService.delete(account: provider.keychainAccountName)
        objectWillChange.send()
    }

    @Published var copilotSidecarStatusText: String = ""
    @Published var copilotSidecarExecutablePath: String = ""
    @Published var copilotSidecarSupportsLaunchAgent: Bool = false
    @Published var isCopilotSidecarAgentInstalled: Bool = false
    @Published var isCopilotSidecarEndpointResponding: Bool = false
    @Published var isCopilotSidecarExternal: Bool = false
    @Published var isCopilotSidecarDirectProcessRunning: Bool = false
    @Published var isCopilotSidecarRunning: Bool = false
    @Published var isCopilotSidecarManaged: Bool = false
    @Published var isStartingCopilotSidecar: Bool = false
    @Published var copilotSidecarLoginCommand: String = ""
    @Published var copilotSidecarLoginDescription: String = ""
    @Published var isCopilotSidecarGitHubAuthenticated: Bool = false
    @Published var copilotSidecarGitHubAccount: String = ""
    @Published var isTestingCopilotToolCall: Bool = false
    @Published var copilotToolCallTestOutput: String = ""
    @Published var copilotToolCallTestModelUsed: String = ""
    @Published var copilotToolCallTestSucceeded: Bool?
    @Published var isCopilotSidecarLogVisible: Bool = false
    @Published var copilotSidecarLogText: String = ""
    @Published var copilotSidecarLogStatusText: String = ""

    @Published var launchAtLogin: Bool = false
    @Published private(set) var sessionHistorySessions: [SessionHistorySession] = []
    @Published private(set) var sessionHistoryInputOutputRecords: [InputOutputLogRecord] = []
    @Published private(set) var sessionHistoryLoadError: String?

    var localProxyState: LocalProxyState { localProxyServer.state }
    var sessionReportCard: SessionReportCard { localProxyServer.reportCard }

    /// Reset session report card AND menu bar counters so both surfaces stay in sync.
    func resetSessionStats() {
        localProxyServer.reportCard.reset()
        localProxyServer.state.sessionRequestCount = 0
        localProxyServer.state.lastModelSeen = ""
        localProxyServer.state.lastUpstreamModelUsed = ""
        localProxyServer.state.lastXcodeAgentRequestModel = ""
        localProxyServer.state.lastXcodeAgentRequestStatus = nil
        localProxyServer.state.lastXcodeAgentRequestAt = nil
        suppressedExternalSessionIDs.formUnion(importedExternalSessionIDs)
        importedExternalSessionEventIDs.removeAll()
        importedExternalSessionIDs.removeAll()
    }

    func importExternalSessionReportEvents() {
        guard let events = try? SessionReportStore.readEvents(from: sessionReportURL) else { return }
        let latestGUIEventTimestamp = events
            .filter { $0.source == "gui" }
            .map(\.record.timestamp)
            .max()
        let externalEvents = events.filter { $0.source != "gui" && !suppressedExternalSessionIDs.contains($0.sessionID) }
        guard let latestExternalEvent = externalEvents.max(by: {
            $0.record.timestamp < $1.record.timestamp
        }) else { return }

        if let latestGUIEventTimestamp,
           latestExternalEvent.record.timestamp < latestGUIEventTimestamp {
            return
        }

        let latestSessionID = latestExternalEvent.sessionID

        for event in externalEvents where event.sessionID == latestSessionID && !importedExternalSessionEventIDs.contains(event.id) {
            importedExternalSessionEventIDs.insert(event.id)
            importedExternalSessionIDs.insert(event.sessionID)
            localProxyServer.reportCard.record(event.record)
            localProxyServer.state.sessionRequestCount = localProxyServer.reportCard.totalRequests
            if !event.record.model.isEmpty {
                localProxyServer.state.lastModelSeen = event.record.model
            }
        }
    }

    func refreshSessionHistory() async {
        do {
            let events = try SessionReportStore.readEvents(from: sessionReportURL)
            sessionHistorySessions = SessionHistorySession.build(from: events)
            sessionHistoryLoadError = nil
        } catch {
            sessionHistorySessions = []
            sessionHistoryLoadError = error.localizedDescription
        }

        do {
            sessionHistoryInputOutputRecords = try await inputOutputLoggingRecords()
        } catch {
            sessionHistoryInputOutputRecords = []
            sessionHistoryLoadError = sessionHistoryLoadError ?? error.localizedDescription
        }
    }

    @Published var xcodeInstallations: [XcodeInstallation] = []
    var hasCompatibleXcode: Bool { xcodeInstallations.contains { $0.supportsAgenticCoding } }

    var hasUpstreamKey: Bool { providerManager.hasUpstreamKey }
    var hasMasterKey: Bool { KeychainService.exists(key: .litellmMasterKey) }
    var requiresMasterKey: Bool { !useBuiltInProxy || requireLocalAuth }
    var hasRequiredMasterKey: Bool { !requiresMasterKey || hasMasterKey }

    var isRunning: Bool {
        get { proxyLifecycle.isRunning }
        set { proxyLifecycle.isRunning = newValue }
    }

    var statusText: String {
        get { proxyLifecycle.statusText }
        set { proxyLifecycle.statusText = newValue }
    }

    @Published private(set) var proxyRuntimeStatus: ProxyRuntimeStatus = .stopped

    var canStartProxy: Bool { proxyRuntimeStatus == .stopped }
    var canStopProxy: Bool { Self.canStopProxy(for: proxyRuntimeStatus, isStoppingCLIProxy: isStoppingCLIProxy) }
    var canRestartProxy: Bool { proxyRuntimeStatus == .runningInApp }

    static func canStopProxy(for status: ProxyRuntimeStatus, isStoppingCLIProxy: Bool = false) -> Bool {
        guard !isStoppingCLIProxy else { return false }
        return status == .runningInApp || status == .runningExternal
    }

    static func statusText(for status: ProxyRuntimeStatus) -> String {
        switch status {
        case .stopped:
            return String(localized: "Stopped")
        case .runningInApp:
            return String(localized: "Running")
        case .runningExternal:
            return String(localized: "Running (via CLI)")
        case .portOccupied(let statusCode):
            return String(localized: "Port occupied by another service") + " (HTTP \(statusCode))"
        }
    }

    private static func httpReasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        default: return "HTTP"
        }
    }

    static func normalizedMenuBarSectionOrder(_ order: [MenuBarSection]) -> [MenuBarSection] {
        var seen = Set<MenuBarSection>()
        var normalized: [MenuBarSection] = []

        for section in order where !seen.contains(section) {
            normalized.append(section)
            seen.insert(section)
        }

        for section in MenuBarSection.defaultOrder where !seen.contains(section) {
            normalized.append(section)
            seen.insert(section)
        }

        return normalized
    }

    static func decodedMenuBarSectionOrder(from defaults: UserDefaults) -> [MenuBarSection] {
        let stored = defaults.stringArray(forKey: menuBarSectionOrderDefaultsKey) ?? []
        let decoded = stored.compactMap(MenuBarSection.init(rawValue:))
        return normalizedMenuBarSectionOrder(decoded)
    }

    static func decodedVisibleMenuBarSections(from defaults: UserDefaults) -> Set<MenuBarSection> {
        guard let stored = defaults.stringArray(forKey: visibleMenuBarSectionsDefaultsKey) else {
            return Set(MenuBarSection.defaultOrder)
        }
        return Set(stored.compactMap(MenuBarSection.init(rawValue:)))
    }

    static func decodedVisibleHomeDashboardSections(from defaults: UserDefaults) -> Set<HomeDashboardSection> {
        guard let stored = defaults.stringArray(forKey: visibleHomeDashboardSectionsDefaultsKey) else {
            return Set(HomeDashboardSection.allCases)
        }
        return Set(stored.compactMap(HomeDashboardSection.init(rawValue:)))
    }

    static func normalizedKeysProviderOrder(_ order: [KeysProviderViewItem]) -> [KeysProviderViewItem] {
        var seen = Set<KeysProviderViewItem>()
        var normalized: [KeysProviderViewItem] = []

        for item in order where !seen.contains(item) {
            normalized.append(item)
            seen.insert(item)
        }

        for item in KeysProviderViewItem.defaultOrder where !seen.contains(item) {
            normalized.append(item)
            seen.insert(item)
        }

        return normalized
    }

    static func decodedKeysProviderOrder(from defaults: UserDefaults) -> [KeysProviderViewItem] {
        let stored = defaults.stringArray(forKey: keysProviderOrderDefaultsKey) ?? []
        let decoded = stored.compactMap(KeysProviderViewItem.init(rawValue:))
        return normalizedKeysProviderOrder(decoded)
    }

    static func decodedVisibleKeysProviders(
        from defaults: UserDefaults,
        storedOrderRawValues: [String]?
    ) -> Set<KeysProviderViewItem> {
        guard let stored = defaults.stringArray(forKey: visibleKeysProvidersDefaultsKey) else {
            return Set(KeysProviderViewItem.defaultOrder)
        }
        var decoded = Set(stored.compactMap(KeysProviderViewItem.init(rawValue:)))
        let didMigrateQwen = defaults.bool(forKey: didMigrateQwenVisibleProviderDefaultsKey)
        if !didMigrateQwen && storedOrderRawValues?.contains(KeysProviderViewItem.qwen.rawValue) != true {
            decoded.insert(.qwen)
            defaults.set(true, forKey: didMigrateQwenVisibleProviderDefaultsKey)
        }
        return decoded
    }

    func isHomeDashboardSectionVisible(_ section: HomeDashboardSection) -> Bool {
        visibleHomeDashboardSections.contains(section)
    }

    func setHomeDashboardSection(_ section: HomeDashboardSection, isVisible: Bool) {
        if isVisible {
            visibleHomeDashboardSections.insert(section)
        } else {
            visibleHomeDashboardSections.remove(section)
        }
    }

    func setMenuBarSection(_ section: MenuBarSection, isVisible: Bool) {
        if isVisible {
            visibleMenuBarSections.insert(section)
        } else {
            visibleMenuBarSections.remove(section)
        }
    }

    func moveMenuBarSection(_ section: MenuBarSection, up: Bool) {
        guard let index = menuBarSectionOrder.firstIndex(of: section) else { return }
        let destination = up ? index - 1 : index + 1
        guard menuBarSectionOrder.indices.contains(destination) else { return }
        menuBarSectionOrder.swapAt(index, destination)
    }

    func resetMenuBarCustomization() {
        showMenuBarExtra = true
        menuBarSectionOrder = MenuBarSection.defaultOrder
        visibleMenuBarSections = Set(MenuBarSection.defaultOrder)
    }

    func isKeysProviderVisible(_ provider: UpstreamProvider) -> Bool {
        guard let item = KeysProviderViewItem(provider: provider) else { return false }
        return visibleKeysProviders.contains(item)
    }

    func apiKeyPageURL(for provider: UpstreamProvider) -> URL? {
        provider.apiKeyPageURL(apiBaseURL: providerManager.upstreamAPIBaseURL(for: provider))
    }

    func apiKeyRegionHint(for provider: UpstreamProvider) -> String? {
        provider.apiKeyRegionHint(apiBaseURL: providerManager.upstreamAPIBaseURL(for: provider))
    }

    func setKeysProvider(_ provider: UpstreamProvider, isVisible: Bool) {
        guard let item = KeysProviderViewItem(provider: provider) else { return }
        if isVisible {
            visibleKeysProviders.insert(item)
        } else {
            visibleKeysProviders.remove(item)
        }
    }

    func moveKeysProviderItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        var order = keysProviderOrder
        order.move(fromOffsets: source, toOffset: destination)
        keysProviderOrder = order
    }

    func moveKeysProvider(_ provider: UpstreamProvider, up: Bool) {
        guard let item = KeysProviderViewItem(provider: provider),
              let index = keysProviderOrder.firstIndex(of: item) else { return }
        let destination = up ? index - 1 : index + 1
        guard keysProviderOrder.indices.contains(destination) else { return }
        keysProviderOrder.swapAt(index, destination)
    }

    func resetKeysProvidersCustomization() {
        copilotSidecarExpanded = true
        keysProviderOrder = KeysProviderViewItem.defaultOrder
        visibleKeysProviders = Set(KeysProviderViewItem.defaultOrder)
    }

    func resetAllViewCustomizations() {
        appearancePreference = .system
        proxyPilotAccentHex = ProxyPilotAccentColor.defaultHex
        liquidGlassEnabled = true
        defaultSettingsSection = .home
        visibleHomeDashboardSections = Set(HomeDashboardSection.allCases)
        resetMenuBarCustomization()
        resetKeysProvidersCustomization()
    }

    @Published var lastError: String?
    @Published var activeIssue: AppIssue?
    @Published var recentIssueCodes: [String] = []

    @Published var logText: String = ""
    @Published var modelsJSON: String = ""
    @Published var xcodeVisibleModelsSnapshot = XcodeVisibleModelsSnapshot()
    @Published var isRefreshingXcodeVisibleModels: Bool = false

    var upstreamModels: [UpstreamModel] {
        get { providerManager.upstreamModels }
        set { providerManager.upstreamModels = newValue }
    }

    var selectedUpstreamModels: Set<String> {
        get { providerManager.selectedUpstreamModels }
        set { providerManager.selectedUpstreamModels = newValue }
    }

    var selectedXcodeAgentModel: String {
        get { providerManager.selectedXcodeAgentModel }
        set { providerManager.selectedXcodeAgentModel = newValue }
    }

    @Published var upstreamTestOutput: String = ""
    @Published var upstreamTestModelUsed: String = ""

    @Published var showingUpstreamKeyField: Bool = false
    @Published var showingMasterKeyField: Bool = false
    @Published var upstreamKeyDraft: String = ""
    @Published var masterKeyDraft: String = ""

    var providerKeyDrafts: [UpstreamProvider: String] {
        get { providerManager.providerKeyDrafts }
        set { providerManager.providerKeyDrafts = newValue }
    }

    var providerKeyEditing: [UpstreamProvider: Bool] {
        get { providerManager.providerKeyEditing }
        set { providerManager.providerKeyEditing = newValue }
    }

    var providerKeyTestStates: [UpstreamProvider: ProviderManager.KeyTestState] {
        get { providerManager.providerKeyTestStates }
        set { providerManager.providerKeyTestStates = newValue }
    }

    typealias KeyTestState = ProviderManager.KeyTestState

    func resetToFreshInstall() async {
        clearIssue()
        proxyLifecycle.resetForFreshInstall()

        await stopProxy()
        await stopCopilotSidecar()
        removeXcodeAgentConfig()

        for key in KeychainService.Key.allCases {
            try? KeychainService.delete(key: key)
        }

        defaults.removeObject(forKey: ProviderManager.upstreamProviderDefaultsKey)
        defaults.removeObject(forKey: Self.didCompleteOnboardingDefaultsKey)
        defaults.removeObject(forKey: Self.telemetryOptInDefaultsKey)
        defaults.removeObject(forKey: Self.liquidGlassEnabledDefaultsKey)
        defaults.removeObject(forKey: Self.inputOutputLoggingEnabledDefaultsKey)
        defaults.removeObject(forKey: Self.inputOutputLoggingRecordInputsDefaultsKey)
        defaults.removeObject(forKey: Self.inputOutputLoggingRecordOutputsDefaultsKey)
        defaults.removeObject(forKey: Self.inputOutputLoggingCLIEnabledDefaultsKey)
        defaults.removeObject(forKey: Self.inputOutputLoggingRetentionDefaultsKey)
        defaults.removeObject(forKey: Self.inputOutputLoggingExternalStorageDefaultsKey)
        defaults.removeObject(forKey: Self.promptCachingModeDefaultsKey)
        defaults.removeObject(forKey: Self.appearancePreferenceDefaultsKey)
        defaults.removeObject(forKey: Self.proxyPilotAccentHexDefaultsKey)
        defaults.removeObject(forKey: Self.showMenuBarExtraDefaultsKey)
        defaults.removeObject(forKey: Self.menuBarSectionOrderDefaultsKey)
        defaults.removeObject(forKey: Self.visibleMenuBarSectionsDefaultsKey)
        defaults.removeObject(forKey: Self.visibleHomeDashboardSectionsDefaultsKey)
        defaults.removeObject(forKey: Self.defaultSettingsSectionDefaultsKey)
        defaults.removeObject(forKey: Self.keysProviderOrderDefaultsKey)
        defaults.removeObject(forKey: Self.visibleKeysProvidersDefaultsKey)
        defaults.removeObject(forKey: Self.didMigrateQwenVisibleProviderDefaultsKey)
        defaults.removeObject(forKey: Self.copilotSidecarExpandedDefaultsKey)
        defaults.removeObject(forKey: Self.autoRestartEnabledDefaultsKey)
        defaults.removeObject(forKey: Self.requireLocalAuthDefaultsKey)
        defaults.removeObject(forKey: Self.preflightSnapshotDefaultsKey)
        defaults.removeObject(forKey: ProviderManager.showModelMetadataDefaultsKey)
        defaults.removeObject(forKey: ProviderManager.exactoFilterDefaultsKey)
        defaults.removeObject(forKey: ProviderManager.verifiedFilterDefaultsKey)
        defaults.removeObject(forKey: Self.suppressKeychainPrimerDefaultsKey)
        defaults.removeObject(forKey: Self.analyticsPromptShownVersionKey)
        defaults.removeObject(forKey: Self.anthropicFallbackDefaultsKey)
        defaults.removeObject(forKey: ProviderManager.xcodeAgentModelLegacyDefaultsKey)
        defaults.removeObject(forKey: Self.preflightExpandedDefaultsKey)

        for provider in UpstreamProvider.allCases {
            defaults.removeObject(forKey: "proxypilot.upstreamAPIBaseURL.\(provider.rawValue)")
            defaults.removeObject(forKey: ProviderManager.xcodeAgentModelDefaultsKey(for: provider))
            defaults.removeObject(forKey: ProviderManager.defaultModelsKey(for: provider))
            defaults.removeObject(forKey: ProviderManager.upstreamModelCacheKey(for: provider))
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

        proxyURLString = Self.defaultProxyURLString
        useBuiltInProxy = true
        upstreamProvider = .zAI
        upstreamAPIBaseURLString = upstreamProvider.defaultAPIBaseURL
        upstreamModels = []
        selectedUpstreamModels = []
        selectedXcodeAgentModel = providerManager.preferredXcodeAgentModel(from: savedDefaultModels, provider: upstreamProvider)
        providerManager.reconcileXcodeAgentModelSelection()
        copilotSidecarStatusText = ""
        copilotSidecarExecutablePath = ""
        isCopilotSidecarRunning = false
        isCopilotSidecarManaged = false
        isStartingCopilotSidecar = false
        copilotSidecarLoginCommand = ""
        copilotSidecarLoginDescription = ""
        isCopilotSidecarGitHubAuthenticated = false
        copilotSidecarGitHubAccount = ""
        isTestingCopilotToolCall = false
        copilotToolCallTestOutput = ""
        copilotToolCallTestModelUsed = ""
        copilotToolCallTestSucceeded = nil
        isCopilotSidecarLogVisible = false
        copilotSidecarLogText = ""
        copilotSidecarLogStatusText = ""

        launchAtLogin = false
        anthropicTranslatorFallbackEnabled = false
        requireLocalAuth = false
        showModelMetadata = true
        exactoFilterEnabled = true
        verifiedFilterEnabled = false
        showOnboardingWizard = true
        telemetryOptIn = false
        liquidGlassEnabled = true
        inputOutputLoggingEnabled = false
        inputOutputLoggingRecordInputs = false
        inputOutputLoggingRecordOutputs = false
        inputOutputLoggingCLIEnabled = false
        inputOutputLoggingRetention = .twentyFourHoursDefault
        inputOutputLoggingExternalStorageEnabled = false
        promptCachingMode = .computeCacheHints
        appearancePreference = .system
        proxyPilotAccentHex = ProxyPilotAccentColor.defaultHex
        showMenuBarExtra = true
        menuBarSectionOrder = MenuBarSection.defaultOrder
        visibleMenuBarSections = Set(MenuBarSection.defaultOrder)
        visibleHomeDashboardSections = Set(HomeDashboardSection.allCases)
        defaultSettingsSection = .home
        keysProviderOrder = KeysProviderViewItem.defaultOrder
        visibleKeysProviders = Set(KeysProviderViewItem.defaultOrder)
        copilotSidecarExpanded = true
        showKeychainAccessPrimer = false
        suppressKeychainAccessPrimer = false
        autoRestartEnabled = true
        hasEvaluatedKeychainPrimerThisLaunch = false

        providerKeyDrafts = [:]
        providerKeyEditing = [:]
        providerCLIAuthStatuses = [:]
        showingUpstreamKeyField = false
        showingMasterKeyField = false
        upstreamKeyDraft = ""
        masterKeyDraft = ""

        modelsJSON = ""
        xcodeVisibleModelsSnapshot = XcodeVisibleModelsSnapshot()
        isRefreshingXcodeVisibleModels = false
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
        providerManager.hasKey(for: provider)
    }

    func saveKey(for provider: UpstreamProvider) {
        guard providerManager.saveKey(for: provider) else { return }
        providerCLIAuthStatuses[provider] = .checking
        Task { await verifyProviderKeyCLIVisibility(for: provider) }
    }

    func deleteKey(for provider: UpstreamProvider) {
        providerManager.deleteKey(for: provider)
        providerCLIAuthStatuses[provider] = .notChecked
    }

    func providerCLIAuthStatusText(for provider: UpstreamProvider) -> String? {
        switch providerCLIAuthStatuses[provider] ?? .notChecked {
        case .notChecked:
            return nil
        case .checking:
            return String(localized: "Checking whether the installed CLI can see this key...")
        case .visible:
            return String(localized: "Installed CLI can see this provider key.")
        case .notVisible(let message):
            return message
        case .cliMissing:
            return String(localized: "ProxyPilot CLI was not found. Keychain save succeeded, but CLI visibility was not checked.")
        case .failed(let message):
            return String(localized: "Could not verify installed CLI key visibility:") + " " + message
        }
    }

    func providerCLIAuthStatusIsWarning(for provider: UpstreamProvider) -> Bool {
        switch providerCLIAuthStatuses[provider] ?? .notChecked {
        case .notVisible, .cliMissing, .failed:
            return true
        case .notChecked, .checking, .visible:
            return false
        }
    }

    func verifyProviderKeyCLIVisibility(for provider: UpstreamProvider) async {
        guard let executableURL = resolveCLIExecutableURL() else {
            providerCLIAuthStatuses[provider] = .cliMissing
            return
        }

        do {
            let execution = try await runCLIAuthStatus(executableURL: executableURL, provider: provider)
            providerCLIAuthStatuses[provider] = Self.providerCLIAuthStatus(from: execution, provider: provider)
        } catch {
            providerCLIAuthStatuses[provider] = .failed(error.localizedDescription)
        }
    }

    func testKey(for provider: UpstreamProvider) async {
        await providerManager.testKey(for: provider)
        if case .failure = providerManager.providerKeyTestStates[provider] {
            trackProviderEndpointFailure(provider: provider, operation: .keyTest, issue: nil)
        }
    }

    func refreshCopilotSidecarStatus() async {
        let status = await copilotSidecarService.status()
        copilotSidecarExecutablePath = status.executablePath ?? ""
        copilotSidecarSupportsLaunchAgent = status.supportsLaunchAgent
        isCopilotSidecarAgentInstalled = status.isLaunchAgentInstalled
        isCopilotSidecarEndpointResponding = status.endpointResponding
        isCopilotSidecarExternal = status.isExternal
        isCopilotSidecarDirectProcessRunning = status.isDirectProcessRunning
        isCopilotSidecarRunning = status.isRunning
        isCopilotSidecarManaged = status.isManaged
        copilotSidecarStatusText = status.message
        copilotSidecarLoginCommand = status.loginCommand ?? ""
        copilotSidecarLoginDescription = status.loginCommandDescription
        isCopilotSidecarGitHubAuthenticated = status.isGitHubAuthenticated
        copilotSidecarGitHubAccount = status.githubAccount ?? ""
    }

    func startCopilotSidecar() async {
        isStartingCopilotSidecar = true
        defer { isStartingCopilotSidecar = false }
        do {
            try await copilotSidecarService.installOrStart()
            upstreamProvider = .githubCopilot
            upstreamAPIBaseURLString = UpstreamProvider.githubCopilot.defaultAPIBaseURL
            await refreshCopilotSidecarStatus()
        } catch {
            copilotSidecarStatusText = error.localizedDescription
            isCopilotSidecarAgentInstalled = false
            isCopilotSidecarEndpointResponding = false
            isCopilotSidecarExternal = false
            isCopilotSidecarDirectProcessRunning = false
            isCopilotSidecarRunning = false
            isCopilotSidecarManaged = false
        }
    }

    func stopCopilotSidecar() async {
        do {
            try await copilotSidecarService.uninstallOrStop()
            await refreshCopilotSidecarStatus()
            if !isCopilotSidecarAgentInstalled && !isCopilotSidecarEndpointResponding && !isCopilotSidecarDirectProcessRunning {
                copilotSidecarStatusText = "Copilot helper stopped."
            }
        } catch {
            copilotSidecarStatusText = error.localizedDescription
        }
    }

    func openCopilotSidecarLog() {
        let snapshot = copilotSidecarService.logSnapshot()
        copilotSidecarLogText = snapshot.text
        copilotSidecarLogStatusText = snapshot.summary
        isCopilotSidecarLogVisible = true
    }

    func openCopilotLoginTerminal() async {
        guard !copilotSidecarLoginCommand.isEmpty else { return }
        await copilotSidecarService.openLoginTerminal(command: copilotSidecarLoginCommand)
    }

    func openCopilotSidecarProject() {
        if let url = URL(string: "https://github.com/theblixguy/xcode-copilot-server") {
            NSWorkspace.shared.open(url)
        }
    }

    func testCopilotToolCall() async {
        clearIssue()
        isTestingCopilotToolCall = true
        copilotToolCallTestOutput = "Testing Copilot tool-call endpoint..."
        copilotToolCallTestModelUsed = ""
        copilotToolCallTestSucceeded = nil
        defer { isTestingCopilotToolCall = false }

        let apiBase: URL
        if upstreamProvider == .githubCopilot {
            do {
                apiBase = try validatedUpstreamBaseURL()
            } catch {
                let issue = issueFor(
                    error,
                    fallbackCode: .invalidProxyURL,
                    fallbackTitle: String(localized: "Invalid Copilot Sidecar URL"),
                    fallbackActions: [.resetUpstreamURL]
                )
                copilotToolCallTestSucceeded = false
                copilotToolCallTestOutput = "Tool-call test failed: \(issue.message)"
                applyIssue(issue)
                return
            }
        } else {
            guard let defaultBase = URL(string: UpstreamProvider.githubCopilot.defaultAPIBaseURL) else {
                let issue = AppIssue(
                    code: .invalidProxyURL,
                    title: String(localized: "Invalid Copilot Sidecar URL"),
                    message: String(localized: "ProxyPilot's GitHub Copilot sidecar URL is invalid."),
                    actions: [.exportDiagnostics]
                )
                copilotToolCallTestSucceeded = false
                copilotToolCallTestOutput = "Tool-call test failed: \(issue.message)"
                applyIssue(issue)
                return
            }
            apiBase = defaultBase
        }

        var selectedModel = upstreamProvider == .githubCopilot ? effectiveXcodeAgentModel : ""
        if selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                let models = try await proxyService.fetchUpstreamModels(
                    apiBase: apiBase,
                    apiKey: "",
                    provider: .githubCopilot
                )
                providerManager.applyFetchedUpstreamModels(models)
                providerManager.reconcileXcodeAgentModelSelection()
                selectedModel = effectiveXcodeAgentModel
            } catch {
                let issue = upstreamIssueFor(
                    error,
                    fallbackCode: .generic,
                    fallbackTitle: String(localized: "Copilot Model Fetch Failed"),
                    fallbackActions: [.resetUpstreamURL, .exportDiagnostics],
                    provider: .githubCopilot,
                    apiBase: apiBase,
                    path: UpstreamProvider.githubCopilot.modelsPath,
                    operation: .modelFetch
                )
                copilotToolCallTestSucceeded = false
                copilotToolCallTestOutput = "Tool-call test failed: \(issue.message)"
                applyIssue(issue)
                return
            }
        }

        let model = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            let issue = AppIssue(
                code: .generic,
                title: String(localized: "No Copilot Models Available"),
                message: String(localized: "ProxyPilot could not get a model list from the GitHub Copilot sidecar. Sign in, refresh models, then try the tool-call test again."),
                actions: [.openCopilotLogin, .exportDiagnostics]
            )
            copilotToolCallTestSucceeded = false
            copilotToolCallTestOutput = "Tool-call test failed: \(issue.message)"
            applyIssue(issue)
            return
        }

        do {
            let result = try await proxyService.testGitHubCopilotToolCall(apiBase: apiBase, model: model)
            copilotToolCallTestModelUsed = model
            copilotToolCallTestSucceeded = result.sawToolCall
            copilotToolCallTestOutput = result.summary
            if result.sawToolCall {
                markFirstSuccessfulRequestIfNeeded()
            }
        } catch {
            let issue = upstreamIssueFor(
                error,
                fallbackCode: .generic,
                fallbackTitle: String(localized: "Copilot Tool-Call Test Failed"),
                fallbackActions: [.resetUpstreamURL, .exportDiagnostics],
                provider: .githubCopilot,
                apiBase: apiBase,
                path: UpstreamProvider.githubCopilot.chatCompletionsPath,
                operation: .upstreamTest
            )
            copilotToolCallTestModelUsed = model
            copilotToolCallTestSucceeded = false
            copilotToolCallTestOutput = "Tool-call test failed: \(issue.message)"
            applyIssue(issue)
        }
    }

    @Published var useBuiltInProxy: Bool = true {
        didSet {
            proxyLifecycle.useBuiltInProxy = useBuiltInProxy
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

    var showModelMetadata: Bool {
        get { providerManager.showModelMetadata }
        set { providerManager.showModelMetadata = newValue }
    }

    var exactoFilterEnabled: Bool {
        get { providerManager.exactoFilterEnabled }
        set { providerManager.exactoFilterEnabled = newValue }
    }

    var verifiedFilterEnabled: Bool {
        get { providerManager.verifiedFilterEnabled }
        set { providerManager.verifiedFilterEnabled = newValue }
    }

    var verifiedModels: VerifiedModels {
        get { providerManager.verifiedModels }
        set { providerManager.verifiedModels = newValue }
    }

    @Published var showOnboardingWizard: Bool = false
    @Published var preflightResults: [PreflightCheckResult] = []
    @Published var preflightLastRun: Date?

    @Published var telemetryOptIn: Bool = false {
        didSet {
            defaults.set(telemetryOptIn, forKey: Self.telemetryOptInDefaultsKey)
        }
    }

    @Published var liquidGlassEnabled: Bool = true {
        didSet {
            defaults.set(liquidGlassEnabled, forKey: Self.liquidGlassEnabledDefaultsKey)
        }
    }

    @Published var inputOutputLoggingEnabled: Bool = false {
        didSet {
            defaults.set(inputOutputLoggingEnabled, forKey: Self.inputOutputLoggingEnabledDefaultsKey)
            persistSharedInputOutputLoggingPreferences()
        }
    }

    @Published var inputOutputLoggingRecordInputs: Bool = false {
        didSet {
            defaults.set(inputOutputLoggingRecordInputs, forKey: Self.inputOutputLoggingRecordInputsDefaultsKey)
            persistSharedInputOutputLoggingPreferences()
        }
    }

    @Published var inputOutputLoggingRecordOutputs: Bool = false {
        didSet {
            defaults.set(inputOutputLoggingRecordOutputs, forKey: Self.inputOutputLoggingRecordOutputsDefaultsKey)
            persistSharedInputOutputLoggingPreferences()
        }
    }

    @Published var inputOutputLoggingCLIEnabled: Bool = false {
        didSet {
            defaults.set(inputOutputLoggingCLIEnabled, forKey: Self.inputOutputLoggingCLIEnabledDefaultsKey)
            persistSharedInputOutputLoggingPreferences()
        }
    }

    @Published var inputOutputLoggingRetention: InputOutputLoggingRetention = .twentyFourHoursDefault {
        didSet {
            defaults.set(inputOutputLoggingRetention.rawValue, forKey: Self.inputOutputLoggingRetentionDefaultsKey)
            persistSharedInputOutputLoggingPreferences()
        }
    }

    @Published var inputOutputLoggingExternalStorageEnabled: Bool = false {
        didSet {
            defaults.set(inputOutputLoggingExternalStorageEnabled, forKey: Self.inputOutputLoggingExternalStorageDefaultsKey)
            persistSharedInputOutputLoggingPreferences()
        }
    }

    @Published var promptCachingMode: PromptCachingMode = .computeCacheHints {
        didSet {
            defaults.set(promptCachingMode.rawValue, forKey: Self.promptCachingModeDefaultsKey)
        }
    }

    var promptCachingConfiguration: PromptCachingConfiguration {
        PromptCachingConfiguration(
            isEnabled: promptCachingMode != .off,
            mode: promptCachingMode,
            retention: .providerDefault,
            canonicalizeJSONForCache: promptCachingMode == .computeCacheHints
        )
    }

    var promptCachingProviderStatusText: String {
        switch promptCachingMode {
        case .off:
            return "Cache signals and provider cache accounting are disabled."
        case .observeOnly:
            return "ProxyPilot records provider cache telemetry without changing outbound requests."
        case .explicitReferenceCache:
            return "Reference-cache objects are deferred; ProxyPilot will observe telemetry only."
        case .computeCacheHints:
            switch upstreamProvider {
            case .openAI, .mistral:
                return "Auto sends a stable prompt_cache_key for OpenAI-compatible cache routing."
            case .xAI:
                return "Auto sends a stable x-grok-conv-id for Grok chat completions."
            case .zAI:
                return "Auto canonicalizes JSON for steadier z.ai automatic-cache prefixes."
            case .deepSeek:
                return "Auto keeps DeepSeek telemetry-only and refuses cost guesses without provider cache splits."
            case .miniMax, .miniMaxCN:
                if miniMaxRoutingMode == .anthropicPassthrough {
                    return "Auto adds Anthropic cache_control on MiniMax passthrough requests."
                }
                return "MiniMax cache_control applies when Anthropic Passthrough routing is selected."
            case .google:
                return "Gemini direct cache mutation is blocked to protect thought_signature compatibility."
            default:
                return "This provider is observed, but no cache request mutation is enabled."
            }
        }
    }

    var promptCachingHomeStatusTitle: String {
        if sessionReportCard.totalPromptCacheHitTokens > 0 {
            return "Cache working"
        }
        if sessionReportCard.cacheAccountingAvailable {
            return "Cache reported"
        }
        switch promptCachingMode {
        case .off:
            return "Caching off"
        case .observeOnly:
            return "Caching observed"
        case .computeCacheHints:
            if upstreamProvider == .google {
                return "Caching guarded"
            }
            return "Caching auto"
        case .explicitReferenceCache:
            return "Caching observed"
        }
    }

    var liquidGlassPreferenceTitle: String {
        String(localized: "Use Liquid Glass for control strips")
    }

    var liquidGlassPreferenceDescription: String {
        String(localized: "This only affects ProxyPilot's custom compact control strips and preview. Native sidebar, toolbar, sheets, and menus follow macOS automatically.")
    }

    func confirmInputOutputLoggingEnabled() {
        inputOutputLoggingEnabled = true
        if !inputOutputLoggingRecordInputs && !inputOutputLoggingRecordOutputs {
            inputOutputLoggingRecordInputs = true
            inputOutputLoggingRecordOutputs = true
        }
    }

    func disableInputOutputLogging() {
        inputOutputLoggingEnabled = false
        inputOutputLoggingRecordInputs = false
        inputOutputLoggingRecordOutputs = false
        inputOutputLoggingCLIEnabled = false
        inputOutputLoggingExternalStorageEnabled = false
    }

    func setInputOutputRecordInputs(_ enabled: Bool) {
        inputOutputLoggingRecordInputs = enabled
        reconcileInputOutputLoggingSelection()
    }

    func setInputOutputRecordOutputs(_ enabled: Bool) {
        inputOutputLoggingRecordOutputs = enabled
        reconcileInputOutputLoggingSelection()
    }

    func inputOutputLoggingSavedRecordCount() async throws -> Int {
        guard let recorder = try InputOutputLoggingRecorder.productionIfKeyExists(source: "gui") else {
            return 0
        }
        return try await recorder.recordCount()
    }

    func inputOutputLoggingExportJSONL() async throws -> String {
        guard let recorder = try InputOutputLoggingRecorder.productionIfKeyExists(source: "gui") else {
            return ""
        }
        return try await recorder.exportJSONL()
    }

    func inputOutputLoggingRecords() async throws -> [InputOutputLogRecord] {
        guard let recorder = try InputOutputLoggingRecorder.productionIfKeyExists(source: "gui") else {
            return []
        }
        try await recorder.pruneExpired()
        return try await recorder.readRecords()
    }

    func deleteInputOutputLoggingRecords() async throws {
        guard let recorder = try InputOutputLoggingRecorder.productionIfKeyExists(source: "gui") else {
            return
        }
        try await recorder.resetRecords()
    }

    private func reconcileInputOutputLoggingSelection() {
        if inputOutputLoggingEnabled && !inputOutputLoggingRecordInputs && !inputOutputLoggingRecordOutputs {
            inputOutputLoggingEnabled = false
            inputOutputLoggingCLIEnabled = false
            inputOutputLoggingExternalStorageEnabled = false
        }
    }

    private func reconcileStoredInputOutputLoggingState() {
        inputOutputLoggingExternalStorageEnabled = false

        if inputOutputLoggingEnabled && !inputOutputLoggingRecordInputs && !inputOutputLoggingRecordOutputs {
            inputOutputLoggingRecordInputs = true
            inputOutputLoggingRecordOutputs = true
        }

        if !inputOutputLoggingEnabled {
            inputOutputLoggingRecordInputs = false
            inputOutputLoggingRecordOutputs = false
            inputOutputLoggingCLIEnabled = false
        }
    }

    private func persistSharedInputOutputLoggingPreferences() {
        guard let inputOutputLoggingPreferencesStore else { return }

        let coreRetention = ProxyPilotCore.InputOutputLoggingRetention(rawValue: inputOutputLoggingRetention.rawValue)
            ?? .twentyFourHoursDefault
        let preferences = InputOutputLoggingPreferences(
            enabled: inputOutputLoggingEnabled,
            recordInputs: inputOutputLoggingRecordInputs,
            recordOutputs: inputOutputLoggingRecordOutputs,
            cliEnabled: inputOutputLoggingCLIEnabled,
            retention: coreRetention,
            externalStorageEnabled: inputOutputLoggingExternalStorageEnabled
        )

        try? inputOutputLoggingPreferencesStore.save(preferences)
    }

    @Published var appearancePreference: AppAppearancePreference = .system {
        didSet {
            defaults.set(appearancePreference.rawValue, forKey: Self.appearancePreferenceDefaultsKey)
        }
    }

    @Published var proxyPilotAccentHex: String = ProxyPilotAccentColor.defaultHex {
        didSet {
            guard let normalized = ProxyPilotAccentColor.normalizedHex(proxyPilotAccentHex) else {
                proxyPilotAccentHex = oldValue
                return
            }
            if normalized != proxyPilotAccentHex {
                proxyPilotAccentHex = normalized
                return
            }
            defaults.set(normalized, forKey: Self.proxyPilotAccentHexDefaultsKey)
        }
    }

    @Published var showMenuBarExtra: Bool = true {
        didSet {
            defaults.set(showMenuBarExtra, forKey: Self.showMenuBarExtraDefaultsKey)
        }
    }

    @Published var menuBarSectionOrder: [MenuBarSection] = MenuBarSection.defaultOrder {
        didSet {
            let normalized = Self.normalizedMenuBarSectionOrder(menuBarSectionOrder)
            if normalized != menuBarSectionOrder {
                menuBarSectionOrder = normalized
                return
            }
            defaults.set(normalized.map(\.rawValue), forKey: Self.menuBarSectionOrderDefaultsKey)
        }
    }

    @Published var visibleMenuBarSections: Set<MenuBarSection> = Set(MenuBarSection.defaultOrder) {
        didSet {
            let normalized = visibleMenuBarSections.intersection(Set(MenuBarSection.allCases))
            if normalized != visibleMenuBarSections {
                visibleMenuBarSections = normalized
                return
            }
            let orderedRawValues = MenuBarSection.defaultOrder
                .filter { normalized.contains($0) }
                .map(\.rawValue)
            defaults.set(orderedRawValues, forKey: Self.visibleMenuBarSectionsDefaultsKey)
        }
    }

    @Published var visibleHomeDashboardSections: Set<HomeDashboardSection> = Set(HomeDashboardSection.allCases) {
        didSet {
            let normalized = visibleHomeDashboardSections.intersection(Set(HomeDashboardSection.allCases))
            if normalized != visibleHomeDashboardSections {
                visibleHomeDashboardSections = normalized
                return
            }
            let orderedRawValues = HomeDashboardSection.allCases
                .filter { normalized.contains($0) }
                .map(\.rawValue)
            defaults.set(orderedRawValues, forKey: Self.visibleHomeDashboardSectionsDefaultsKey)
        }
    }

    @Published var defaultSettingsSection: SettingsSection = .home {
        didSet {
            defaults.set(defaultSettingsSection.rawValue, forKey: Self.defaultSettingsSectionDefaultsKey)
        }
    }

    @Published var keysProviderOrder: [KeysProviderViewItem] = KeysProviderViewItem.defaultOrder {
        didSet {
            let normalized = Self.normalizedKeysProviderOrder(keysProviderOrder)
            if normalized != keysProviderOrder {
                keysProviderOrder = normalized
                return
            }
            defaults.set(normalized.map(\.rawValue), forKey: Self.keysProviderOrderDefaultsKey)
        }
    }

    @Published var visibleKeysProviders: Set<KeysProviderViewItem> = Set(KeysProviderViewItem.defaultOrder) {
        didSet {
            let normalized = visibleKeysProviders.intersection(Set(KeysProviderViewItem.allCases))
            if normalized != visibleKeysProviders {
                visibleKeysProviders = normalized
                return
            }
            let orderedRawValues = KeysProviderViewItem.defaultOrder
                .filter { normalized.contains($0) }
                .map(\.rawValue)
            defaults.set(orderedRawValues, forKey: Self.visibleKeysProvidersDefaultsKey)
        }
    }

    @Published var copilotSidecarExpanded: Bool = true {
        didSet {
            defaults.set(copilotSidecarExpanded, forKey: Self.copilotSidecarExpandedDefaultsKey)
        }
    }

    @Published var showKeychainAccessPrimer: Bool = false
    @Published var showAnalyticsPrompt: Bool = false

    @Published var suppressKeychainAccessPrimer: Bool = false {
        didSet {
            defaults.set(suppressKeychainAccessPrimer, forKey: Self.suppressKeychainPrimerDefaultsKey)
        }
    }

    var autoRestartEnabled: Bool {
        get { proxyLifecycle.autoRestartEnabled }
        set { proxyLifecycle.autoRestartEnabled = newValue }
    }

    var recoveryState: RecoveryState { proxyLifecycle.recoveryState }

    var proxyPilotAccentColor: Color {
        Color(proxyPilotHex: proxyPilotAccentHex)
    }

    var shouldShowToolbarStatus: Bool {
        if statusText != Self.statusText(for: .stopped) {
            return true
        }

        switch recoveryState {
        case .recovering, .degraded:
            return true
        default:
            return false
        }
    }

    @Published var diagnosticsArchivePath: String = ""
    @Published var supportSummary: String = ""
    @Published var isUpdatingCLITool: Bool = false
    @Published var isStoppingCLIProxy: Bool = false
    @Published var cliUpdateStatusText: String = ""
    @Published var cliUpdateStatusIsError: Bool = false
    @Published var providerCLIAuthStatuses: [UpstreamProvider: ProviderCLIAuthStatus] = [:]

    var anthropicTranslatorModeText: String {
        anthropicTranslatorFallbackEnabled ? String(localized: "Legacy Fallback") : String(localized: "Hardened")
    }

    var selectedUpstreamProviderDefaultAPIBaseURL: String {
        providerManager.selectedUpstreamProviderDefaultAPIBaseURL
    }

    var currentLogSourcePath: String {
        useBuiltInProxy ? Self.builtInProxyLogFileURL.path : proxyService.paths.logFile.path
    }

    var xcodeLocallyHostedPortText: String {
        URLComponents(string: proxyURLString)?.port.map(String.init) ?? "4000"
    }

    var proxyModelsEndpointText: String {
        proxyURLString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/models"
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
        providerManager.xcodeAgentModelCandidates
    }

    var effectiveXcodeAgentModel: String {
        providerManager.effectiveXcodeAgentModel
    }

    var xcodeAgentRoutingSummaryText: String {
        let model = effectiveXcodeAgentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty {
            return String(localized: "No model selected. Fetch or save a model for") + " \(upstreamProvider.title) " + String(localized: "before routing Xcode Agent traffic.")
        }
        if hasPendingXcodeAgentModelChange {
            return String(localized: "Live route still uses") + " \(activeXcodeAgentModel). " + String(localized: "Selected model") + " \(model) " + String(localized: "is pending restart.")
        }
        if proxyRuntimeStatus == .runningInApp || localProxyServer.state.isRunning {
            return String(localized: "Live route uses") + " \(model)."
        }
        if proxyRuntimeStatus == .runningExternal {
            return String(localized: "Selected model") + " \(model) " + String(localized: "is configured here, but the running proxy is external. Refresh live models to verify what Xcode sees.")
        }
        return String(localized: "Selected model") + " \(model) " + String(localized: "will apply the next time ProxyPilot starts or restarts the proxy.")
    }

    var activeXcodeAgentModel: String {
        localProxyServer.state.activeXcodeAgentModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasPendingXcodeAgentModelChange: Bool {
        guard isRunning || localProxyServer.state.isRunning else { return false }
        let active = activeXcodeAgentModel
        let selected = effectiveXcodeAgentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !active.isEmpty, !selected.isEmpty else { return false }
        return active.caseInsensitiveCompare(selected) != .orderedSame
    }

    var homeAgentModelBadgeTitle: String {
        if hasPendingXcodeAgentModelChange {
            return activeXcodeAgentModel
        }
        return effectiveXcodeAgentModel
    }

    var homeAgentModelBadgeHelpText: String {
        if hasPendingXcodeAgentModelChange {
            return "Active model. Restart ProxyPilot to apply selected model \(effectiveXcodeAgentModel)."
        }
        if proxyRuntimeStatus == .runningInApp || localProxyServer.state.isRunning {
            return "Live model for the running ProxyPilot-owned proxy."
        }
        return "Selected Xcode Agent model. Start or restart ProxyPilot before treating it as live."
    }

    var xcodeAgentSelectedModelText: String {
        let selected = selectedXcodeAgentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return selected.isEmpty ? "None selected" : selected
    }

    var xcodeAgentPendingModelText: String {
        let pending = effectiveXcodeAgentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return pending.isEmpty ? "None ready" : pending
    }

    var xcodeAgentAppliedModelText: String {
        let active = activeXcodeAgentModel
        if proxyRuntimeStatus == .runningInApp || localProxyServer.state.isRunning {
            return active.isEmpty ? "Running, no applied model recorded" : active
        }
        if proxyRuntimeStatus == .runningExternal {
            return "External proxy - unknown to GUI"
        }
        return "Not applied until proxy start"
    }

    var xcodeAgentLiveRouteText: String {
        if xcodeVisibleModelsSnapshot.reflectsRunningProxy {
            return "\(xcodeVisibleModelsSnapshot.modelIDs.count) model(s) from running proxy"
        }
        if let error = xcodeVisibleModelsSnapshot.errorMessage {
            return "Live check failed: \(error)"
        }
        if xcodeVisibleModelsSnapshot.source == .pendingSettings {
            return "\(xcodeVisibleModelsSnapshot.modelIDs.count) model(s) from pending settings"
        }
        return "Not checked"
    }

    var xcodeAgentLiveProofText: String {
        let model = localProxyState.lastXcodeAgentRequestModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let status = localProxyState.lastXcodeAgentRequestStatus,
              let timestamp = localProxyState.lastXcodeAgentRequestAt,
              !model.isEmpty else {
            return "No Xcode Agent request observed in this ProxyPilot session yet."
        }
        return "Last Xcode Agent request: \(model), \(status) \(Self.httpReasonPhrase(status)), \(timestamp.formatted(date: .abbreviated, time: .standard))."
    }

    var localProxyBindAddressText: String {
        validatedProxySummary.host
    }

    var localProxyPortText: String {
        String(validatedProxySummary.port)
    }

    var localProxyAuthStateText: String {
        requireLocalAuth ? "Required" : "Disabled for local Xcode compatibility"
    }

    var localProxyWhoCanConnectText: String {
        if useBuiltInProxy {
            return "Built-in mode accepts loopback clients only. LAN clients are rejected before request parsing."
        }
        if isLoopbackHost(validatedProxySummary.host) {
            return "Loopback URL: only apps on this Mac should connect."
        }
        return "Non-loopback URL: network clients may be able to connect; require auth before using this mode."
    }

    var xcodeVisibleModelsSourceText: String {
        switch xcodeVisibleModelsSnapshot.source {
        case .notChecked:
            return "Not checked"
        case .runningProxy:
            return "Running proxy"
        case .pendingSettings:
            return "Pending settings"
        }
    }

    var xcodeVisibleModelsTimestampText: String {
        guard let checkedAt = xcodeVisibleModelsSnapshot.checkedAt else { return "Never" }
        return checkedAt.formatted(date: .abbreviated, time: .standard)
    }

    var xcodeVisibleModelsStatusText: String {
        if let error = xcodeVisibleModelsSnapshot.errorMessage {
            return "Failed: \(error)"
        }
        switch xcodeVisibleModelsSnapshot.source {
        case .runningProxy:
            return "This is live evidence from GET /v1/models."
        case .pendingSettings:
            return "Proxy is not running; this is the model set ProxyPilot would expose after start."
        case .notChecked:
            return "Refresh to see what Xcode can validate right now."
        }
    }

    var xcodeVisibleModelsListText: String {
        if xcodeVisibleModelsSnapshot.modelIDs.isEmpty {
            return "(no model IDs)"
        }
        return xcodeVisibleModelsSnapshot.modelIDs.joined(separator: "\n")
    }

    var cloudProviderActionDisclosureText: String {
        if upstreamProvider.isLocal {
            return "\(upstreamProvider.title) is local/helper-backed. Fetching or testing checks a local endpoint and does not create cloud-provider billing from ProxyPilot."
        }
        return "\(upstreamProvider.title) requests leave this Mac for \(upstreamAPIBaseURLString). Fetch Live Models calls the provider's models endpoint. Test Upstream Response sends a minimal completion request and may consume credits or quota."
    }

    var diagnosticsPreviewText: String {
        DiagnosticsService.exportPreviewText
    }

    var alwaysOnTelemetryDisclosureText: String {
        if Self.isAlphaBuild {
            return "Alpha builds always send coarse failure-mode analytics for preflight failures, proxy start failures, and crash markers when a remote analytics key is bundled. Prompts, completions, API keys, provider keys, model outputs, URLs, provider names, and system details are not sent."
        }

        return "Always-on health reporting sends only `app_opened`, `app_version`, and `build_number` to PostHog at https://us.i.posthog.com/capture/ so update health can be counted. Optional analytics add session/proxy events only when this toggle is enabled. Prompts, completions, API keys, provider keys, model outputs, and system details are not sent."
    }

    var contextualTerminologyHelpText: String {
        """
        Proxy: the local server on this Mac that Xcode connects to.
        Upstream: the provider or local model server ProxyPilot forwards requests to.
        OpenAI-compatible: an API shape used by many providers and local servers; it does not mean OpenAI receives the request.
        /v1/models: the local model-list endpoint Xcode checks to decide which model IDs are visible right now.
        Anthropic translator mode: the Xcode Agent compatibility layer that converts Claude-style /v1/messages requests into the selected upstream provider's chat format.
        """
    }

    var xcodeAgentConfigPreviewText: String {
        let proxyBase = proxyURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Settings file:
        \(xcodeAgentConfigSettingsURL.path)

        JSON keys written:
        env.ANTHROPIC_AUTH_TOKEN = proxypilot
        env.ANTHROPIC_BASE_URL = \(proxyBase)

        Defaults write:
        domain = \(Self.xcodeDefaultsDomain)
        key = \(Self.xcodeAgentAPIKeyOverrideDefaultsKey)
        value = " "

        Remove deletes the settings file and runs:
        defaults delete \(Self.xcodeDefaultsDomain) \(Self.xcodeAgentAPIKeyOverrideDefaultsKey)
        """
    }

    func localProviderStatusText(for provider: UpstreamProvider) -> String {
        switch provider {
        case .githubCopilot:
            if isCopilotSidecarEndpointResponding { return "Responding on \(provider.defaultAPIBaseURL)" }
            if isCopilotSidecarAgentInstalled { return "Background helper installed; refresh or start to confirm endpoint response." }
            return "Helper not confirmed running."
        case .ollama, .lmStudio:
            guard let base = URL(string: provider.defaultAPIBaseURL) else {
                return "Default URL could not be parsed."
            }
            let port = base.port ?? (base.scheme?.lowercased() == "https" ? 443 : 80)
            let occupied = preflightService.isPortAvailable(port) == false
            return occupied
                ? "A local service appears to be listening at \(provider.defaultAPIBaseURL)."
                : "No local service detected at \(provider.defaultAPIBaseURL)."
        default:
            return "Not a local provider."
        }
    }

    func localProviderSetupHint(for provider: UpstreamProvider) -> String {
        switch provider {
        case .ollama:
            return "Start with `ollama serve`, then pull a model such as `ollama pull qwen2.5-coder:0.5b`."
        case .lmStudio:
            return "Open LM Studio, load a model, and start the Local Server with OpenAI-compatible mode enabled."
        case .githubCopilot:
            return "Install or start the Copilot helper above; ProxyPilot uses your existing GitHub Copilot account."
        default:
            return ""
        }
    }

    var proxySyncModelCandidates: [String] {
        providerManager.proxySyncModelCandidates
    }

    var canSyncProxyModels: Bool {
        providerManager.canSyncProxyModels
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

    private enum SessionCostSource {
        case calculated
        case openRouterEstimate
    }

    private var sessionCostSource: SessionCostSource? {
        guard sessionPricedRequestCount > 0 else { return nil }
        return upstreamProvider == .openRouter ? .openRouterEstimate : .calculated
    }

    var sessionCostMetricLabel: String {
        switch sessionCostSource {
        case .openRouterEstimate:
            return String(localized: "OpenRouter Est.")
        case .calculated:
            return String(localized: "Calculated Cost")
        case nil:
            return String(localized: "Cost")
        }
    }

    var sessionRequestCostLabel: String {
        switch sessionCostSource {
        case .openRouterEstimate:
            return String(localized: "OpenRouter Estimate")
        case .calculated:
            return String(localized: "Calculated Cost")
        case nil:
            return String(localized: "Cost")
        }
    }

    var sessionMenuCostText: String? {
        guard let amount = sessionEstimatedCostUSD else { return nil }
        switch sessionCostSource {
        case .openRouterEstimate:
            return "OR est \(formatUSD(amount))"
        case .calculated:
            return "calc \(formatUSD(amount))"
        case nil:
            return formatUSD(amount)
        }
    }

    var sessionCostCoverageText: String {
        let total = sessionReportCard.totalRequests
        guard total > 0 else { return "" }

        let priced = sessionPricedRequestCount
        let dashboardNote = String(localized: "Check your API account dashboard for authoritative billing.")
        if priced == 0 {
            return String(localized: "No priced requests in current model catalog.") + " " + dashboardNote
        }

        let sourceText: String
        switch sessionCostSource {
        case .openRouterEstimate:
            sourceText = String(localized: "OpenRouter estimate extrapolated from response token usage and catalog pricing")
        case .calculated:
            sourceText = String(localized: "Calculated from response token usage and model pricing")
        case nil:
            sourceText = String(localized: "Cost unavailable")
        }

        if priced < total {
            return sourceText + " " + String(localized: "for") + " \(priced)/\(total) " + String(localized: "requests with pricing metadata.") + " " + dashboardNote
        }
        return sourceText + " " + String(localized: "for all") + " \(total) " + String(localized: "requests.") + " " + dashboardNote
    }

    var sessionCacheTelemetryText: String {
        if sessionReportCard.cacheAccountingAvailable {
            var parts = [
                "\(Self.compactInteger(sessionReportCard.totalPromptCacheHitTokens)) cached",
                "\(Self.compactInteger(sessionReportCard.totalPromptCacheMissTokens)) uncached"
            ]
            if sessionReportCard.totalPromptCacheWriteTokens > 0 {
                parts.append("\(Self.compactInteger(sessionReportCard.totalPromptCacheWriteTokens)) written")
            }
            var summary = "Provider reported " + parts.joined(separator: ", ")
            if let hitRate = sessionReportCard.cacheHitRate {
                summary += String(format: " · %.0f%% hit rate", hitRate * 100)
            }
            if promptCachingMode == .off {
                summary += String(localized: ". Caching is off for future requests.")
            }
            return summary
        }

        if promptCachingMode == .off {
            return String(localized: "Cache signals and provider cache accounting are disabled for the current session.")
        }

        if upstreamProvider.promptCacheCapabilities.supportsProviderCacheTelemetry {
            return String(localized: "No provider cache counters have been observed yet. Send a repeated long-context request to confirm whether the current provider is returning cached-token telemetry.")
        }

        if upstreamProvider.promptCacheCapabilities.supportsAutomaticProviderCaching {
            return String(localized: "This provider may cache upstream context, but ProxyPilot does not yet receive compatible cached-token counters from it.")
        }

        return String(localized: "The current provider does not advertise cache telemetry in ProxyPilot yet.")
    }

    var sessionCacheMetricLabel: String {
        if sessionReportCard.totalPromptCacheHitTokens > 0 {
            return String(localized: "Cached")
        }
        if sessionReportCard.cacheAccountingAvailable {
            return String(localized: "Cache Reported")
        }
        return String(localized: "Cache")
    }

    var sessionCacheMetricValue: String {
        guard sessionReportCard.cacheAccountingAvailable else { return "No counters" }
        if sessionReportCard.totalPromptCacheHitTokens > 0 {
            return Self.compactInteger(sessionReportCard.totalPromptCacheHitTokens)
        }
        if sessionReportCard.totalPromptCacheWriteTokens > 0 {
            return "\(Self.compactInteger(sessionReportCard.totalPromptCacheWriteTokens)) written"
        }
        return "\(Self.compactInteger(sessionReportCard.totalPromptCacheMissTokens)) uncached"
    }

    func estimatedCostUSD(for record: SessionReportCard.RequestRecord) -> Double? {
        guard let model = upstreamModel(for: record.model) else { return nil }
        return model.estimatedCostUSD(
            promptTokens: record.promptTokens,
            completionTokens: record.completionTokens,
            promptCacheHitTokens: record.promptCacheHitTokens,
            promptCacheMissTokens: record.promptCacheMissTokens
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
            "prompt_cache_hit_tokens": record.promptCacheHitTokens ?? NSNull(),
            "prompt_cache_miss_tokens": record.promptCacheMissTokens ?? NSNull(),
            "prompt_cache_write_tokens": record.promptCacheWriteTokens ?? NSNull(),
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
        guard !sessionReportCard.requests.isEmpty else { return "" }

        let header = [
            "timestamp",
            "model",
            "path",
            "streaming",
            "prompt_tokens",
            "completion_tokens",
            "total_tokens",
            "prompt_cache_hit_tokens",
            "prompt_cache_miss_tokens",
            "prompt_cache_write_tokens",
            "duration_ms",
            "estimated_cost_usd"
        ].joined(separator: ",")

        let rows = sessionReportCard.requests.map { record in
            let durationMilliseconds = Int((record.durationSeconds * 1000).rounded())
            let estimatedCost = estimatedCostUSD(for: record).map { String(format: "%.6f", $0) } ?? ""
            let fields: [String] = [
                Self.csvEscaped(Self.sessionRequestTimestampFormatter.string(from: record.timestamp)),
                Self.csvEscaped(record.model),
                Self.csvEscaped(record.path),
                record.wasStreaming ? "true" : "false",
                "\(record.promptTokens)",
                "\(record.completionTokens)",
                "\(record.totalTokens)",
                record.promptCacheHitTokens.map(String.init) ?? "",
                record.promptCacheMissTokens.map(String.init) ?? "",
                record.promptCacheWriteTokens.map(String.init) ?? "",
                "\(durationMilliseconds)",
                estimatedCost
            ]
            return fields.joined(separator: ",")
        }

        return ([header] + rows).joined(separator: "\n")
    }

    var savedDefaultModels: [String] {
        providerManager.savedDefaultModels
    }

    var hasSavedDefaultModels: Bool { providerManager.hasSavedDefaultModels }

    func saveSelectedModelsAsDefaults() {
        providerManager.saveSelectedModelsAsDefaults()
    }

    var filteredUpstreamModels: [UpstreamModel] {
        providerManager.filteredUpstreamModels
    }

    var modelSelectionRows: [ProviderManager.ModelSelectionRow] {
        providerManager.modelSelectionRows
    }

    var selectedModelRowCount: Int {
        providerManager.selectedModelRowCount
    }

    var allVisibleModelsSelected: Bool {
        providerManager.allVisibleModelsSelected
    }

    var canClearModelSelection: Bool {
        providerManager.canClearModelSelection
    }

    var canSaveSelectedModelsAsDefaults: Bool {
        providerManager.canSaveSelectedModelsAsDefaults
    }

    func selectAllUpstreamModels() {
        providerManager.selectAllUpstreamModels()
    }

    func clearUpstreamModelSelection() {
        providerManager.clearUpstreamModelSelection()
    }

    func isDefaultModel(_ id: String) -> Bool {
        providerManager.isDefaultModel(id)
    }

    func isModelSelected(_ id: String) -> Bool {
        providerManager.isModelSelected(id)
    }

    func setModelSelected(_ id: String, isSelected: Bool) {
        providerManager.setModelSelected(id, isSelected: isSelected)
    }

    func removeDefaultModel(_ id: String) {
        providerManager.removeDefaultModel(id)
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
        copilotSidecarService: CopilotSidecarService = CopilotSidecarService(),
        xcodeAgentConfigStateProvider: (() -> Bool)? = nil,
        cliExecutableResolver: CLIExecutableResolver? = nil,
        cliUpdateRunner: CLIUpdateRunner? = nil,
        cliAuthStatusRunner: CLIAuthStatusRunner? = nil,
        cliStopRunner: CLIStopRunner? = nil,
        sessionReportURL: URL = SessionReportStore.defaultURL,
        inputOutputLoggingPreferencesStore: InputOutputLoggingPreferencesStore? = nil
    ) {
        self.defaults = defaults
        self.proxyService = proxyService
        self.localProxyServer = localProxyServer
        self.preflightService = PreflightService(proxyService: proxyService)
        self.diagnosticsService = diagnosticsService
        self.telemetryService = telemetryService
        self.healthMonitor = healthMonitor
        self.copilotSidecarService = copilotSidecarService
        self.xcodeAgentConfigStateProvider = xcodeAgentConfigStateProvider
        self.cliExecutableResolver = cliExecutableResolver
        self.cliUpdateRunner = cliUpdateRunner
        self.cliAuthStatusRunner = cliAuthStatusRunner
        self.cliStopRunner = cliStopRunner
        self.sessionReportURL = sessionReportURL
        self.inputOutputLoggingPreferencesStore = inputOutputLoggingPreferencesStore
            ?? (defaults === UserDefaults.standard ? InputOutputLoggingPreferencesStore() : nil)

        self.providerManager = ProviderManager(defaults: defaults, proxyService: proxyService)
        self.customProviderStorage = CustomProviderStorage(defaults: defaults)
        self.proxyLifecycle = ProxyLifecycleManager(
            defaults: defaults,
            localProxyServer: localProxyServer,
            proxyService: proxyService,
            healthMonitor: healthMonitor
        )

        launchAtLogin = SMAppService.mainApp.status == .enabled
        anthropicTranslatorFallbackEnabled = defaults.bool(forKey: Self.anthropicFallbackDefaultsKey)

        telemetryOptIn = defaults.bool(forKey: Self.telemetryOptInDefaultsKey)
        liquidGlassEnabled = defaults.object(forKey: Self.liquidGlassEnabledDefaultsKey) as? Bool ?? true
        inputOutputLoggingEnabled = defaults.bool(forKey: Self.inputOutputLoggingEnabledDefaultsKey)
        inputOutputLoggingRecordInputs = defaults.bool(forKey: Self.inputOutputLoggingRecordInputsDefaultsKey)
        inputOutputLoggingRecordOutputs = defaults.bool(forKey: Self.inputOutputLoggingRecordOutputsDefaultsKey)
        inputOutputLoggingCLIEnabled = defaults.bool(forKey: Self.inputOutputLoggingCLIEnabledDefaultsKey)
        inputOutputLoggingRetention = InputOutputLoggingRetention(
            rawValue: defaults.string(forKey: Self.inputOutputLoggingRetentionDefaultsKey) ?? ""
        ) ?? .twentyFourHoursDefault
        inputOutputLoggingExternalStorageEnabled = defaults.bool(forKey: Self.inputOutputLoggingExternalStorageDefaultsKey)
        promptCachingMode = PromptCachingMode(
            rawValue: defaults.string(forKey: Self.promptCachingModeDefaultsKey) ?? ""
        ) ?? .computeCacheHints
        reconcileStoredInputOutputLoggingState()
        persistSharedInputOutputLoggingPreferences()
        appearancePreference = AppAppearancePreference(
            rawValue: defaults.string(forKey: Self.appearancePreferenceDefaultsKey) ?? ""
        ) ?? .system
        proxyPilotAccentHex = ProxyPilotAccentColor.normalizedHex(
            defaults.string(forKey: Self.proxyPilotAccentHexDefaultsKey) ?? ""
        ) ?? ProxyPilotAccentColor.defaultHex
        showMenuBarExtra = defaults.object(forKey: Self.showMenuBarExtraDefaultsKey) as? Bool ?? true
        menuBarSectionOrder = Self.decodedMenuBarSectionOrder(from: defaults)
        visibleMenuBarSections = Self.decodedVisibleMenuBarSections(from: defaults)
        visibleHomeDashboardSections = Self.decodedVisibleHomeDashboardSections(from: defaults)
        defaultSettingsSection = SettingsSection(
            rawValue: defaults.string(forKey: Self.defaultSettingsSectionDefaultsKey) ?? ""
        ) ?? .home
        let storedKeysProviderOrderRawValues = defaults.stringArray(forKey: Self.keysProviderOrderDefaultsKey)
        keysProviderOrder = Self.decodedKeysProviderOrder(from: defaults)
        visibleKeysProviders = Self.decodedVisibleKeysProviders(
            from: defaults,
            storedOrderRawValues: storedKeysProviderOrderRawValues
        )
        copilotSidecarExpanded = defaults.object(forKey: Self.copilotSidecarExpandedDefaultsKey) as? Bool ?? true
        suppressKeychainAccessPrimer = defaults.bool(forKey: Self.suppressKeychainPrimerDefaultsKey)
        requireLocalAuth = defaults.bool(forKey: Self.requireLocalAuthDefaultsKey)

        showOnboardingWizard = !defaults.bool(forKey: Self.didCompleteOnboardingDefaultsKey)

        if let data = defaults.data(forKey: Self.preflightSnapshotDefaultsKey),
           let decoded = try? JSONDecoder().decode([PreflightCheckResult].self, from: data) {
            preflightResults = decoded
        }

        refreshAgentConfigInstallationState()

        // Wire ProviderManager callbacks
        providerManager.onClearIssue = { [weak self] in self?.clearIssue() }
        providerManager.onApplyIssue = { [weak self] issue in self?.applyIssue(issue) }

        // Wire ProxyLifecycleManager callbacks
        proxyLifecycle.onClearIssue = { [weak self] in self?.clearIssue() }
        proxyLifecycle.onApplyIssue = { [weak self] issue in self?.applyIssue(issue) }
        proxyLifecycle.onRefreshStatus = { [weak self] in self?.refreshStatus() }
        proxyLifecycle.telemetryTracker = { [weak self] name, payload in
            guard let self else { return }
            let enrichedPayload: [String: String]
            if name == "proxy_start_failed", let issue = self.activeIssue {
                enrichedPayload = Self.telemetryPayloadForProxyStartFailure(
                    issue: issue,
                    useBuiltInProxy: self.useBuiltInProxy,
                    preflightResults: self.preflightResults
                )
            } else {
                enrichedPayload = payload
            }
            self.telemetryService.track(name: name, payload: enrichedPayload, telemetryOptIn: self.telemetryOptIn)
        }
        proxyLifecycle.proxyURLValidator = { [weak self] requireLocalhost in
            guard let self else { throw ProxyLifecycleManager.IssueError(issue: AppIssue(
                code: .generic,
                title: "Internal Error",
                message: "View model deallocated.",
                actions: []
            )) }
            return try self.validatedProxyURL(requireLocalhost: requireLocalhost)
        }
        proxyLifecycle.builtInProxyConfigBuilder = { [weak self] in
            guard let self else { throw ProxyLifecycleManager.IssueError(issue: AppIssue(
                code: .generic,
                title: "Internal Error",
                message: "View model deallocated.",
                actions: []
            )) }
            return try self.buildBuiltInProxyConfig()
        }

        // Forward ProviderManager changes → AppViewModel objectWillChange
        providerManagerCancellable = providerManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }

        // Forward ProxyLifecycleManager changes → AppViewModel objectWillChange
        lifecycleManagerCancellable = proxyLifecycle.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }

        let priorSessionLikelyCrashed = telemetryService.beginSession()
        telemetryService.trackCoreHealthAppOpen(
            appVersion: Self.appVersion,
            buildNumber: Self.buildNumber
        )
        if priorSessionLikelyCrashed {
            telemetryService.track(
                name: "previous_session_may_have_crashed",
                payload: Self.telemetryPayloadForPreviousSessionCrash(
                    useBuiltInProxy: useBuiltInProxy,
                    upstreamProvider: upstreamProvider
                ),
                telemetryOptIn: telemetryOptIn
            )
        }

        if showOnboardingWizard {
            telemetryService.track(name: "onboarding_started", telemetryOptIn: telemetryOptIn)
        }

        providerManager.isInitialized = true
        runPreflightChecks(trackEvent: false)
        Task { await detectXcodeInstallations() }
        if upstreamProvider == .openRouter {
            Task { await providerManager.loadVerifiedModels() }
        }
        Task { await hydrateCurrentProviderModelCacheIfNeeded() }
    }

    func applicationWillTerminate() {
        telemetryService.endSession()
        stopLogUpdates()
        pruneInputOutputLogsForQuit()
    }

    private func pruneInputOutputLogsForQuit() {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }
            guard let recorder = try? InputOutputLoggingRecorder.productionIfConfigured(source: "gui") else {
                return
            }
            try? await recorder.pruneExpired(includeUntilQuit: true)
        }
        _ = semaphore.wait(timeout: .now() + 2)
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
        importExternalSessionReportEvents()
        refreshAgentConfigInstallationState()
        statusRefreshSequence += 1
        let sequence = statusRefreshSequence
        let locallyRunning = useBuiltInProxy ? localProxyServer.state.isRunning : proxyService.isRunning()
        applyProxyRuntimeStatus(locallyRunning ? .runningInApp : .stopped)
        refreshLogText()
        Task { await refreshReachableProxyStatus(sequence: sequence, locallyRunning: locallyRunning) }
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

    // MARK: - Analytics Opt-In Prompt

    func maybeShowAnalyticsPrompt() {
        guard Self.analyticsPromptAvailable else { return }
        guard defaults.string(forKey: Self.analyticsPromptShownVersionKey) != Self.appVersion else { return }
        guard !showOnboardingWizard else { return }
        showAnalyticsPrompt = true
    }

    func dismissAnalyticsPrompt(optIn: Bool) {
        telemetryOptIn = optIn
        markAnalyticsPromptHandledForCurrentVersion()
        showAnalyticsPrompt = false
    }

    private func markAnalyticsPromptHandledForCurrentVersion() {
        defaults.set(Self.appVersion, forKey: Self.analyticsPromptShownVersionKey)
    }

    private static var isAlphaBuild: Bool {
        AppBuildBadge.isAlphaBundle(Bundle.main.bundleIdentifier)
    }

    private static var analyticsPromptAvailable: Bool {
        guard !isAlphaBuild else { return false }
        let apiKey = Bundle.main.object(forInfoDictionaryKey: "POSTHOG_API_KEY") as? String
        return !(apiKey?.isEmpty ?? true)
    }

    func startLogUpdates() {
        importExternalSessionReportEvents()
        refreshLogText()
        logRefreshTimer?.invalidate()
        logRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.importExternalSessionReportEvents()
                self.refreshLogText()
            }
        }

        statusAutoRefreshTimer?.invalidate()
        statusAutoRefreshTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refreshStatus()
            }
        }

        proxyLifecycle.startHealthMonitor()
    }

    func stopLogUpdates() {
        logRefreshTimer?.invalidate()
        logRefreshTimer = nil
        statusAutoRefreshTimer?.invalidate()
        statusAutoRefreshTimer = nil
        proxyLifecycle.stopHealthMonitor()
    }

    func saveUpstreamKey() {
        guard let keychainKey = upstreamProvider.keychainKey else { return }
        if case let .failure(_, message) = APIKeyValidator.validate(upstreamKeyDraft, for: upstreamProvider) {
            applyIssue(AppIssue(
                code: .missingUpstreamKey,
                title: String(localized: "Invalid API Key"),
                message: message,
                actions: [.openUpstreamKeyEditor]
            ))
            return
        }
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
            resetProxyURLToDefault()
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
        case .openCopilotLogin:
            Task { await openCopilotLoginTerminal() }
        case .openReadme:
            openReadme()
        case .openWebsite:
            openWebsite()
        }
    }

    func resetProxyURLToDefault() {
        proxyURLString = Self.defaultProxyURLString
        clearIssue()
    }

    func applyPreflightFixAction(_ action: PreflightFixAction) {
        switch action {
        case .openMasterKeyEditor:
            performIssueAction(.openMasterKeyEditor)
        case .openUpstreamKeyEditor:
            performIssueAction(.openUpstreamKeyEditor)
        case .openCopilotLogin:
            Task { await openCopilotLoginTerminal() }
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
            upstreamProvider: upstreamProvider,
            upstreamAPIBaseURLString: upstreamAPIBaseURLString,
            fallbackUpstreamBaseURLString: selectedUpstreamProviderDefaultAPIBaseURL,
            hasMasterKey: hasMasterKey,
            hasUpstreamKey: hasUpstreamKey,
            liteLLMScriptsExist: liteLLMScriptsExist,
            isCopilotSidecarInstalled: !copilotSidecarExecutablePath.isEmpty,
            isCopilotGitHubAuthenticated: isCopilotSidecarGitHubAuthenticated
        )

        let checks = preflightService.run(context: context)
        preflightResults = checks
        preflightLastRun = Date()

        if let encoded = try? JSONEncoder().encode(checks) {
            defaults.set(encoded, forKey: Self.preflightSnapshotDefaultsKey)
        }

        if trackEvent && checks.contains(where: { $0.status == .fail }) {
            telemetryService.track(
                name: "preflight_failed",
                payload: Self.telemetryPayloadForPreflightFailure(
                    checks: checks,
                    useBuiltInProxy: useBuiltInProxy,
                    requireLocalAuth: requireLocalAuth,
                    upstreamProvider: upstreamProvider
                ),
                telemetryOptIn: telemetryOptIn
            )
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
        if telemetryOptIn {
            markAnalyticsPromptHandledForCurrentVersion()
        }
        showOnboardingWizard = false
        telemetryService.track(name: "onboarding_completed", telemetryOptIn: telemetryOptIn)
        clearIssue()
    }

    func startProxy() async {
        await proxyLifecycle.startProxy()
    }

    func restartProxy() async {
        await proxyLifecycle.restartProxy()
    }

    func stopProxy() async {
        if proxyRuntimeStatus == .runningExternal {
            await stopExternalCLIProxy()
            return
        }

        await proxyLifecycle.stopProxy()
    }

    private func stopExternalCLIProxy() async {
        guard !isStoppingCLIProxy else { return }

        guard let executableURL = resolveCLIExecutableURL() else {
            applyIssue(AppIssue(
                code: .generic,
                title: String(localized: "CLI Proxy Stop Failed"),
                message: String(localized: "ProxyPilot CLI was not found. Install the CLI tool, then retry stopping the CLI proxy."),
                actions: [.openReadme]
            ))
            return
        }

        let port: UInt16
        do {
            let validation = try validatedProxyURL(requireLocalhost: false)
            guard let validatedPort = UInt16(exactly: validation.port) else {
                throw IssueError(issue: AppIssue(
                    code: .invalidProxyURL,
                    title: String(localized: "Invalid Proxy URL"),
                    message: String(localized: "Proxy URL port is outside the supported range."),
                    actions: [.resetProxyURL]
                ))
            }
            port = validatedPort
        } catch let issueError as IssueError {
            applyIssue(issueError.issue)
            return
        } catch {
            applyIssue(AppIssue(
                code: .invalidProxyURL,
                title: String(localized: "Invalid Proxy URL"),
                message: error.localizedDescription,
                actions: [.resetProxyURL]
            ))
            return
        }

        isStoppingCLIProxy = true
        defer { isStoppingCLIProxy = false }

        do {
            let execution = try await runCLIStop(executableURL: executableURL, port: port)
            guard Self.cliStopSucceeded(execution) else {
                applyIssue(AppIssue(
                    code: .generic,
                    title: String(localized: "CLI Proxy Stop Failed"),
                    message: Self.cliExecutionFailureMessage(execution, fallback: String(localized: "Installed CLI could not stop the CLI proxy.")),
                    actions: [.openReadme]
                ))
                return
            }

            clearIssue()
            applyProxyRuntimeStatus(.stopped)
            importExternalSessionReportEvents()
        } catch {
            applyIssue(AppIssue(
                code: .generic,
                title: String(localized: "CLI Proxy Stop Failed"),
                message: String(localized: "Failed to run installed CLI stop:") + " " + error.localizedDescription,
                actions: [.openReadme]
            ))
        }
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

    func refreshXcodeVisibleModels() async {
        clearIssue()
        isRefreshingXcodeVisibleModels = true
        defer { isRefreshingXcodeVisibleModels = false }

        let running = proxyRuntimeStatus == .runningInApp
            || proxyRuntimeStatus == .runningExternal
            || isRunning
            || localProxyServer.state.isRunning

        guard running else {
            xcodeVisibleModelsSnapshot = XcodeVisibleModelsSnapshot(
                modelIDs: pendingProxyModelIDs(),
                checkedAt: Date(),
                source: .pendingSettings,
                errorMessage: nil
            )
            return
        }

        let masterKey: String?
        if requiresMasterKey {
            masterKey = KeychainService.get(key: .litellmMasterKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            masterKey = nil
        }

        do {
            let baseURL = try validatedProxyURL(requireLocalhost: false).url
            let rawJSON = try await proxyService.fetchModels(baseURL: baseURL, masterKey: masterKey)
            let ids = try ModelDiscovery.parseModelIDs(from: Data(rawJSON.utf8))
            xcodeVisibleModelsSnapshot = XcodeVisibleModelsSnapshot(
                modelIDs: ids,
                checkedAt: Date(),
                source: .runningProxy,
                errorMessage: nil
            )
        } catch {
            xcodeVisibleModelsSnapshot = XcodeVisibleModelsSnapshot(
                modelIDs: [],
                checkedAt: Date(),
                source: .runningProxy,
                errorMessage: error.localizedDescription
            )
        }
    }

    func fetchUpstreamModels() async {
        clearIssue()

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
            providerManager.applyFetchedUpstreamModels(models)
            providerManager.reconcileXcodeAgentModelSelection()
            markFirstSuccessfulRequestIfNeeded()
        } catch {
            let issue = upstreamIssueFor(
                error,
                fallbackCode: .generic,
                fallbackTitle: String(localized: "Upstream Model Fetch Failed"),
                fallbackActions: upstreamFallbackActions,
                provider: upstreamProvider,
                apiBase: apiBase,
                path: upstreamProvider.modelsPath,
                operation: .modelFetch
            )
            applyIssue(issue)
            trackProviderEndpointFailure(provider: upstreamProvider, operation: .modelFetch, issue: issue)
        }
    }

    func hydrateCurrentProviderModelCacheIfNeeded() async {
        guard upstreamModels.isEmpty else { return }
        let provider = upstreamProvider
        guard provider.requiresAPIKey,
              let keychainKey = provider.keychainKey,
              let apiKey = KeychainService.get(key: keychainKey),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let apiBase = providerManager.upstreamAPIBaseURL(for: provider) else {
            return
        }

        do {
            let models = try await proxyService.fetchUpstreamModels(
                apiBase: apiBase,
                apiKey: apiKey,
                provider: provider
            )
            guard upstreamProvider == provider, upstreamModels.isEmpty else { return }
            providerManager.applyFetchedUpstreamModels(models)
            providerManager.reconcileXcodeAgentModelSelection()
        } catch {
            // Pricing cache hydration is opportunistic; explicit Fetch Live Models remains user-visible.
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

        providerManager.reconcileXcodeAgentModelSelection()

        if useBuiltInProxy {
            await proxyLifecycle.restartProxy()
        } else {
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
            let issue = upstreamIssueFor(
                error,
                fallbackCode: .generic,
                fallbackTitle: String(localized: "Upstream Test Failed"),
                fallbackActions: upstreamFallbackActions,
                provider: upstreamProvider,
                apiBase: apiBase,
                path: upstreamProvider.chatCompletionsPath,
                operation: .upstreamTest
            )
            applyIssue(issue)
            trackProviderEndpointFailure(provider: upstreamProvider, operation: .upstreamTest, issue: issue)
        }
    }

    func loadVerifiedModels() async {
        await providerManager.loadVerifiedModels()
    }

    func resetUpstreamAPIBaseURL() {
        providerManager.resetUpstreamAPIBaseURL()
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

    func openGitHubBugReport() {
        copySupportSummaryToPasteboard()

        let issueCode = activeIssue?.code.rawValue ?? recentIssueCodes.first
        guard let url = Self.gitHubBugReportURL(
            appVersion: Self.appVersion,
            buildNumber: Self.buildNumber,
            statusText: statusText,
            activeIssueCode: issueCode
        ) else {
            openPublicRepository()
            return
        }

        NSWorkspace.shared.open(url)
    }

    static func gitHubBugReportURL(
        appVersion: String,
        buildNumber: String,
        statusText: String,
        activeIssueCode: String?
    ) -> URL? {
        var components = URLComponents(string: "\(publicRepositoryURLString)/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: "ProxyPilot bug report"),
            URLQueryItem(name: "body", value: gitHubBugReportBody(
                appVersion: appVersion,
                buildNumber: buildNumber,
                statusText: statusText,
                activeIssueCode: activeIssueCode
            ))
        ]
        return components?.url
    }

    private static func gitHubBugReportBody(
        appVersion: String,
        buildNumber: String,
        statusText: String,
        activeIssueCode: String?
    ) -> String {
        """
        ## What happened

        ## What you expected

        ## Steps to reproduce

        1.
        2.
        3.

        ## ProxyPilot context

        - App version: \(appVersion) (\(buildNumber))
        - Proxy status: \(statusText)
        - Issue code: \(activeIssueCode ?? "none")

        A technical support summary was copied to the clipboard from ProxyPilot. Review it before attaching so no private project details are included.
        """
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
        NSWorkspace.shared.open(readmeURL)
    }

    var publicRepositoryURL: URL {
        URL(string: Self.publicRepositoryURLString)!
    }

    var readmeURL: URL {
        URL(string: Self.readmeURLString)!
    }

    func openPublicRepository() {
        NSWorkspace.shared.open(publicRepositoryURL)
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

    private func runCLIAuthStatus(executableURL: URL, provider: UpstreamProvider) async throws -> CLIUpdateExecutionResult {
        if let cliAuthStatusRunner {
            return try await cliAuthStatusRunner(executableURL, provider)
        }
        return try await Self.executeCLIAuthStatusProcess(executableURL: executableURL, provider: provider)
    }

    private func runCLIStop(executableURL: URL, port: UInt16) async throws -> CLIUpdateExecutionResult {
        if let cliStopRunner {
            return try await cliStopRunner(executableURL, port)
        }
        return try await Self.executeCLIStopProcess(executableURL: executableURL, port: port)
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

    private static func executeCLIStopProcess(executableURL: URL, port: UInt16) async throws -> CLIUpdateExecutionResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = executableURL
            process.arguments = ["stop", "--port", String(port), "--json"]
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

    private static func executeCLIAuthStatusProcess(executableURL: URL, provider: UpstreamProvider) async throws -> CLIUpdateExecutionResult {
        let providerName = provider.rawValue
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = executableURL
            process.arguments = ["auth", "status", "--provider", providerName, "--json"]
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

    private static func providerCLIAuthStatus(from execution: CLIUpdateExecutionResult, provider: UpstreamProvider) -> ProviderCLIAuthStatus {
        let stdout = execution.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = execution.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = stdout.data(using: .utf8),
           let envelope = try? JSONDecoder().decode(CLIAuthStatusEnvelope.self, from: data) {
            if envelope.ok, let authData = envelope.data {
                guard authData.provider == provider.rawValue else {
                    return .notVisible(
                        String(localized: "Installed CLI returned auth status for")
                            + " \(authData.provider), "
                            + String(localized: "not")
                            + " \(provider.rawValue)."
                    )
                }

                if authData.stored && authData.status == "stored" {
                    return .visible
                }

                var message = String(localized: "Installed CLI reports")
                    + " \(provider.rawValue) "
                    + String(localized: "auth")
                    + " \(authData.status)."
                if let backend = authData.backend, !backend.isEmpty {
                    message += " " + String(localized: "Backend:") + " \(backend)."
                }
                return .notVisible(message)
            }

            if let errorPayload = envelope.error {
                var message = "[\(errorPayload.code)] \(errorPayload.message)"
                if let suggestion = errorPayload.suggestion, !suggestion.isEmpty {
                    message += " " + suggestion
                }
                return .failed(message)
            }
        }

        if execution.terminationStatus == 0 {
            return stdout.isEmpty ? .failed(String(localized: "CLI returned an empty response.")) : .failed(stdout)
        }

        let detail = stderr.isEmpty ? stdout : stderr
        if detail.isEmpty {
            return .failed(String(localized: "CLI exited with code") + " \(execution.terminationStatus).")
        }
        return .failed(detail)
    }

    private static func cliStopSucceeded(_ execution: CLIUpdateExecutionResult) -> Bool {
        let stdout = execution.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = stdout.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(CLIUpdateEnvelope.self, from: data) else {
            return execution.terminationStatus == 0
        }
        return execution.terminationStatus == 0 && envelope.ok
    }

    private static func cliExecutionFailureMessage(_ execution: CLIUpdateExecutionResult, fallback: String) -> String {
        let stdout = execution.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = execution.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = stdout.data(using: .utf8),
           let envelope = try? JSONDecoder().decode(CLIUpdateEnvelope.self, from: data),
           let errorPayload = envelope.error {
            var message = "[\(errorPayload.code)] \(errorPayload.message)"
            if let suggestion = errorPayload.suggestion, !suggestion.isEmpty {
                message += " " + suggestion
            }
            return message
        }

        let detail = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: " ")
        if !detail.isEmpty { return detail }
        if execution.terminationStatus != 0 {
            return String(localized: "CLI exited with code") + " \(execution.terminationStatus)."
        }
        return fallback
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

    private var validatedProxySummary: (host: String, port: Int) {
        if case .success(let validation) = preflightService.validateProxyURL(proxyURLString) {
            return (validation.host, validation.port)
        }
        return ("invalid", 4000)
    }

    private func isLoopbackHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return lowered == "localhost" || lowered == "::1" || lowered.hasPrefix("127.")
    }

    private func pendingProxyModelIDs() -> [String] {
        var ids: Set<String> = []
        ids.formUnion(upstreamProvider == .githubCopilot ? proxySyncModelCandidates : Array(selectedUpstreamModels))
        ids.formUnion(upstreamModels.map(\.id))
        ids.formUnion(savedDefaultModels)
        if let fallback = upstreamProvider.fallbackModelIDs {
            ids.formUnion(fallback)
        }
        let preferred = effectiveXcodeAgentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferred.isEmpty {
            ids.insert(preferred)
        }
        return ids.sorted()
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

    /// Builds a `LocalProxyServer.Config` from current AppViewModel state.
    /// Called by `ProxyLifecycleManager` via the `builtInProxyConfigBuilder` closure.
    func buildBuiltInProxyConfig() throws -> LocalProxyServer.Config {
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
            if upstreamProvider == .githubCopilot { return Set(proxySyncModelCandidates) }
            if !selectedUpstreamModels.isEmpty { return selectedUpstreamModels }
            if !upstreamModels.isEmpty { return Set(upstreamModels.map(\.id)) }
            if let fallback = upstreamProvider.fallbackModelIDs { return Set(fallback) }
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

        let sessionID = UUID().uuidString
        let config = LocalProxyServer.Config(
            host: proxy.host,
            port: port,
            sessionID: sessionID,
            masterKey: masterKey,
            upstreamProvider: upstreamProvider,
            upstreamAPIBase: upstreamBase,
            upstreamAPIKey: upstreamKey,
            allowedModels: allowedModels,
            requiresAuth: requireLocalAuth,
            anthropicTranslatorMode: anthropicTranslatorFallbackEnabled ? .legacyFallback : .hardened,
            miniMaxRoutingMode: providerManager.miniMaxRoutingMode,
            preferredAnthropicUpstreamModel: preferredModel.isEmpty
                ? providerManager.preferredXcodeAgentModel(from: savedDefaultModels)
                : preferredModel,
            googleThoughtSignatureStore: upstreamProvider == .google ? GoogleThoughtSignatureStore() : nil,
            inputOutputLogger: try? InputOutputLoggingRecorder.productionIfConfigured(source: "gui", sessionID: sessionID),
            promptCaching: promptCachingConfiguration
        )

        if upstreamKey == nil && upstreamProvider.requiresAPIKey {
            applyIssue(AppIssue(
                code: .missingUpstreamKey,
                title: String(localized: "Proxy Started Without Upstream Key"),
                message: String(localized: "Built-in proxy started, but upstream requests will fail until you set Upstream API Key."),
                actions: [.openUpstreamKeyEditor]
            ))
        }

        return config
    }

    func reconcileXcodeAgentModelSelection() {
        providerManager.reconcileXcodeAgentModelSelection()
    }

    func upstreamModel(for id: String) -> UpstreamModel? {
        providerManager.upstreamModel(for: id)
    }

    private static func csvEscaped(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }

    private static func compactInteger(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
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

    private func markFirstSuccessfulRequestIfNeeded() {
        guard !hasTrackedFirstSuccessfulRequest else { return }
        hasTrackedFirstSuccessfulRequest = true
        telemetryService.track(name: "first_successful_request", telemetryOptIn: telemetryOptIn)
    }

    private func trackProviderEndpointFailure(
        provider: UpstreamProvider,
        operation: UpstreamIssueOperation,
        issue: AppIssue?
    ) {
        telemetryService.track(
            name: "provider_endpoint_failed",
            payload: Self.telemetryPayloadForProviderEndpointFailure(
                provider: provider,
                operation: operation,
                issue: issue,
                usesDefaultEndpoint: providerManager.upstreamAPIBaseURL(for: provider)?.absoluteString == provider.defaultAPIBaseURL
            ),
            telemetryOptIn: telemetryOptIn
        )
    }

    private func refreshReachableProxyStatus(sequence: Int, locallyRunning: Bool) async {
        guard let baseURL = try? validatedProxyURL(requireLocalhost: false).url else { return }

        do {
            let statusCode = try await proxyService.probe(baseURL: baseURL)
            guard sequence == statusRefreshSequence else { return }
            if statusCode == 200 {
                applyProxyRuntimeStatus(locallyRunning ? .runningInApp : .runningExternal)
            } else {
                applyProxyRuntimeStatus(.portOccupied(statusCode: statusCode))
            }
        } catch {
            guard sequence == statusRefreshSequence else { return }
            applyProxyRuntimeStatus(.stopped)
        }
    }

    func applyProxyRuntimeStatus(_ status: ProxyRuntimeStatus) {
        proxyRuntimeStatus = status
        switch status {
        case .stopped:
            isRunning = false
            statusText = Self.statusText(for: status)
        case .runningInApp:
            isRunning = true
            statusText = Self.statusText(for: status)
        case .runningExternal:
            isRunning = true
            statusText = Self.statusText(for: status)
        case .portOccupied(let statusCode):
            isRunning = false
            statusText = Self.statusText(for: .portOccupied(statusCode: statusCode))
        }
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

    static func telemetryPayloadForPreflightFailure(
        checks: [PreflightCheckResult],
        useBuiltInProxy: Bool,
        requireLocalAuth: Bool,
        upstreamProvider: UpstreamProvider
    ) -> [String: String] {
        let failures = checks.filter { $0.status == .fail }
        let warnings = checks.filter { $0.status == .warning }
        let fixActions = failures
            .map(\.fixAction.rawValue)
            .filter { $0 != PreflightFixAction.none.rawValue }

        return compactTelemetryPayload([
            "failure_count": String(failures.count),
            "warning_count": String(warnings.count),
            "failure_ids": joinedTelemetryValues(failures.map(\.id)),
            "warning_ids": joinedTelemetryValues(warnings.map(\.id)),
            "fix_actions": joinedTelemetryValues(fixActions),
            "mode": proxyModeTelemetryValue(useBuiltInProxy: useBuiltInProxy),
            "provider_class": providerClassTelemetryValue(upstreamProvider),
            "local_auth_required": String(!useBuiltInProxy || requireLocalAuth),
            "upstream_key_required": String(upstreamProvider.requiresAPIKey)
        ])
    }

    static func telemetryPayloadForProxyStartFailure(
        issue: AppIssue,
        useBuiltInProxy: Bool,
        preflightResults: [PreflightCheckResult]
    ) -> [String: String] {
        let failures = preflightResults.filter { $0.status == .fail }
        return compactTelemetryPayload([
            "code": issue.code.rawValue,
            "mode": proxyModeTelemetryValue(useBuiltInProxy: useBuiltInProxy),
            "issue_actions": joinedTelemetryValues(issue.actions.map(\.rawValue)),
            "preflight_failure_count": String(failures.count),
            "preflight_failure_ids": joinedTelemetryValues(failures.map(\.id))
        ])
    }

    static func telemetryPayloadForPreviousSessionCrash(
        useBuiltInProxy: Bool,
        upstreamProvider: UpstreamProvider
    ) -> [String: String] {
        [
            "mode": proxyModeTelemetryValue(useBuiltInProxy: useBuiltInProxy),
            "provider_class": providerClassTelemetryValue(upstreamProvider)
        ]
    }

    static func telemetryPayloadForProviderEndpointFailure(
        provider: UpstreamProvider,
        operation: UpstreamIssueOperation,
        issue: AppIssue?,
        usesDefaultEndpoint: Bool
    ) -> [String: String] {
        compactTelemetryPayload([
            "operation": operation.rawValue,
            "code": issue?.code.rawValue,
            "provider_class": providerClassTelemetryValue(provider),
            "provider_release_stage": providerReleaseStageTelemetryValue(provider),
            "default_endpoint": String(usesDefaultEndpoint),
            "upstream_key_required": String(provider.requiresAPIKey)
        ])
    }

    private static func compactTelemetryPayload(_ payload: [String: String?]) -> [String: String] {
        payload.compactMapValues { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
    }

    private static func joinedTelemetryValues(_ values: [String]) -> String? {
        let normalized = Set(values.filter { !$0.isEmpty })
        guard !normalized.isEmpty else { return nil }
        return normalized.sorted().joined(separator: ",")
    }

    private static func proxyModeTelemetryValue(useBuiltInProxy: Bool) -> String {
        useBuiltInProxy ? "builtin" : "litellm"
    }

    private static func providerClassTelemetryValue(_ provider: UpstreamProvider) -> String {
        provider.isLocal ? "local" : "cloud"
    }

    private static func providerReleaseStageTelemetryValue(_ provider: UpstreamProvider) -> String {
        if provider == .qwen { return "new_beta" }
        if provider.isPreview { return "beta" }
        return "stable"
    }

    enum UpstreamIssueOperation: String {
        case modelFetch
        case upstreamTest
        case keyTest
    }

    private var upstreamFallbackActions: [AppIssue.Action] {
        if upstreamProvider.requiresAPIKey {
            return [.openUpstreamKeyEditor, .resetUpstreamURL, .exportDiagnostics]
        }
        return [.resetUpstreamURL, .exportDiagnostics]
    }

    private func upstreamIssueFor(
        _ error: Error,
        fallbackCode: AppIssue.Code,
        fallbackTitle: String,
        fallbackActions: [AppIssue.Action],
        provider: UpstreamProvider,
        apiBase: URL,
        path: String,
        operation: UpstreamIssueOperation
    ) -> AppIssue {
        guard !provider.requiresAPIKey else {
            return issueFor(
                error,
                fallbackCode: fallbackCode,
                fallbackTitle: fallbackTitle,
                fallbackActions: fallbackActions
            )
        }

        let endpoint = upstreamEndpoint(base: apiBase, path: path)
        let actions = fallbackActions.filter { $0 != .openUpstreamKeyEditor }
        let text = error.localizedDescription.lowercased()

        if provider == .ollama,
           operation == .modelFetch,
           text.contains("missing") || text.contains("data couldn") || text.contains("invalidjson") {
            return AppIssue(
                code: fallbackCode,
                title: fallbackTitle,
                message: String(localized: "Ollama is running but returned no models. Pull one locally, for example: ollama pull qwen2.5-coder:0.5b."),
                actions: actions
            )
        }

        if let urlError = error as? URLError {
            if urlError.code == .timedOut {
                let message: String
                if provider == .ollama && operation == .upstreamTest {
                    message = String(localized: "Ollama did not respond at") + " \(endpoint) " + String(localized: "before the timeout. Local models can take 10-30 seconds to cold-start; try again after the model finishes loading.")
                } else {
                    message = provider.title + " " + String(localized: "did not respond at") + " \(endpoint). " + localProviderRecoveryHint(for: provider)
                }
                return AppIssue(
                    code: .upstreamTimeout,
                    title: String(localized: "Request Timed Out"),
                    message: message,
                    actions: [.retryStart, .exportDiagnostics]
                )
            }

            return AppIssue(
                code: fallbackCode,
                title: fallbackTitle,
                message: provider.title + " " + String(localized: "is not reachable at") + " \(endpoint). " + localProviderRecoveryHint(for: provider),
                actions: actions
            )
        }

        if let serviceError = error as? ProxyServiceError,
           case .httpStatus(let status, let body) = serviceError {
            if let entitlementMessage = LocalProxyServerHelpers.githubCopilotEntitlementMessage(
                statusCode: status,
                body: body,
                provider: provider
            ) {
                return AppIssue(
                    code: .upstreamUnauthorized,
                    title: String(localized: "GitHub Copilot Access Required"),
                    message: entitlementMessage,
                    actions: [.exportDiagnostics, .openReadme]
                )
            }

            return AppIssue(
                code: fallbackCode,
                title: fallbackTitle,
                message: provider.title + " " + String(localized: "returned HTTP") + " \(status) " + String(localized: "from") + " \(endpoint)." + (body.isEmpty ? "" : " \(body)"),
                actions: actions
            )
        }

        return AppIssue(
            code: fallbackCode,
            title: fallbackTitle,
            message: provider.title + " " + String(localized: "failed at") + " \(endpoint): " + error.localizedDescription,
            actions: actions
        )
    }

    private func upstreamEndpoint(base: URL, path: String) -> String {
        let normalized = ProxyService.normalizedUpstreamAPIBase(base).absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.hasPrefix("/") ? path : "/" + path
        return normalized + suffix
    }

    private func localProviderRecoveryHint(for provider: UpstreamProvider) -> String {
        switch provider {
        case .lmStudio:
            return String(localized: "Start LM Studio's local server or change the base URL.")
        case .ollama:
            return String(localized: "Start Ollama with ollama serve, check the base URL, or pull a model locally.")
        case .githubCopilot:
            return String(localized: "Sign in with the Copilot or GitHub CLI, confirm the account has Copilot access, then start or reinstall the helper.")
        default:
            return String(localized: "Check the local provider and base URL.")
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
