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

    enum AgentMode: String, CaseIterable, Identifiable {
        case claudeAgent
        case proxyPilotAgent

        var id: String { rawValue }
        var title: String {
            switch self {
            case .claudeAgent: "Claude Agent"
            case .proxyPilotAgent: "ProxyPilot Agent"
            }
        }
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
    static let dockTileInteractiveEnabledDefaultsKey = "proxypilot.dockTileInteractiveEnabled"
    private static let inputOutputLoggingEnabledDefaultsKey = "proxypilot.inputOutputLogging.enabled"
    private static let inputOutputLoggingRecordInputsDefaultsKey = "proxypilot.inputOutputLogging.recordInputs"
    private static let inputOutputLoggingRecordOutputsDefaultsKey = "proxypilot.inputOutputLogging.recordOutputs"
    private static let inputOutputLoggingCLIEnabledDefaultsKey = "proxypilot.inputOutputLogging.cliEnabled"
    private static let inputOutputLoggingRetentionDefaultsKey = "proxypilot.inputOutputLogging.retention"
    private static let inputOutputLoggingExternalStorageDefaultsKey = "proxypilot.inputOutputLogging.externalStorage"
    private static let inputOutputLoggingExternalStoragePathDefaultsKey = "proxypilot.inputOutputLogging.externalStoragePath"
    private static let promptCachingModeDefaultsKey = "proxypilot.promptCaching.mode"
    private static let contextCompactionEnabledDefaultsKey = "proxypilot.contextCompaction.enabled"
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
    static let didMigrateNineRouterVisibleProviderDefaultsKey = "proxypilot.customization.didMigrateNineRouterVisibleProvider"
    // autoRestartEnabled defaults key: kept here for resetToFreshInstall cleanup
    private static let autoRestartEnabledDefaultsKey = "proxypilot.autoRestartEnabled"
    private static let requireLocalAuthDefaultsKey = "proxypilot.requireLocalAuth"
    private static let runInBackgroundDefaultsKey = "proxypilot.runInBackground"
    private static let preflightSnapshotDefaultsKey = "proxypilot.lastPreflightSnapshot"
    private static let suppressKeychainPrimerDefaultsKey = "proxypilot.suppressKeychainPrimer"
    private static let analyticsPromptShownVersionKey = "proxypilot.analyticsPromptShownVersion"
    /// Records the version whose first open auto-presented the harness tour. Gated on
    /// *presence*, unlike the analytics prompt above, which re-asks every version by design:
    /// a one-time tour that reappeared on each bump would read as nagging.
    private static let harnessOnboardingPresentedVersionKey = "proxypilot.harnessOnboarding.presentedVersion"
    /// Set only when the tour is actually finished. Skipping leaves this nil so the sidebar
    /// pill survives as the way back.
    private static let harnessOnboardingCompletedVersionKey = "proxypilot.harnessOnboarding.completedVersion"
    private static let xcodeDefaultsDomain = "com.apple.dt.Xcode"
    private static let xcodeAgentAPIKeyOverrideDefaultsKey = "IDEChatClaudeAgentAPIKeyOverride"
    private static let selectedAgentModeDefaultsKey = "proxypilot.agentModes.selectedMode"

    static func shouldRunLaunchBackgroundWork(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] == nil
    }

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

    /// The one route reader every surface shares.
    ///
    /// `RoutingView` and `MenuBarView` each held their own `@StateObject`, which
    /// worked for them and left Home with none — so Home had no way to know what
    /// a CLI daemon was serving and fell back to the GUI's Xcode selection. Two
    /// independent readers of the same `route.json` is also just a second source
    /// of truth waiting to disagree with the first.
    let routeControl = RouteControlService()
    let repoGPS = RepoGPSService()

    private let defaults: UserDefaults
    private let proxyService: ProxyService
    private let localProxyServer: LocalProxyServer
    private let preflightService: PreflightService
    private let diagnosticsService: DiagnosticsService
    private let telemetryService: TelemetryService
    private let healthMonitor: HealthMonitor
    private let xcodeAgentConfigStateProvider: (() -> Bool)?
    private let xcodeDetectionService = XcodeDetectionService()
    private let agentRuntimeManager: AgentRuntimeManager
    private let agentLinkManager: AgentExecutableLinkManager
    private let agentRegistrationManager: ACPRegistrationManager
    private let agentRuntimeInstaller: AgentRuntimeInstaller
    private let agentHelperResolver: AgentHelperResolver
    private let cliExecutableResolver: CLIExecutableResolver?
    private let cliUpdateRunner: CLIUpdateRunner?
    private let cliAuthStatusRunner: CLIAuthStatusRunner?
    private let cliStopRunner: CLIStopRunner?
    private let inputOutputLoggingPreferencesStore: InputOutputLoggingPreferencesStore?

    typealias CLIExecutableResolver = () -> URL?
    typealias CLIUpdateRunner = (URL) async throws -> CLIUpdateExecutionResult
    typealias CLIAuthStatusRunner = (URL, UpstreamProvider) async throws -> CLIUpdateExecutionResult
    typealias CLIStopRunner = (URL, UInt16) async throws -> CLIUpdateExecutionResult
    typealias AgentRuntimeInstaller = @Sendable (AgentRuntimeManager) async throws -> AgentRuntimeManifest
    typealias AgentHelperResolver = () -> (launcher: URL, cli: URL)?

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
    private var routeControlCancellable: AnyCancellable?
    private var repoGPSCancellable: AnyCancellable?
    /// Throttles the route poll. `RouteControlService.refresh()` spawns two
    /// short-lived processes, and the value it reads only changes when someone
    /// runs `route set` — so polling it on the 10s status timer would be two
    /// process spawns every ten seconds to observe something that changes by
    /// the hour. The live-updating half of the serving identity comes from
    /// observed traffic, which needs no subprocess at all.
    private var lastRouteControlRefresh: Date?
    private var logRefreshTimer: Timer?
    private var statusAutoRefreshTimer: Timer?
    private var statusRefreshSequence = 0
    private let sessionReportURL: URL
    private var importedExternalSessionEventIDs: Set<UUID> = []
    private var importedExternalSessionIDs: Set<String> = []
    private var suppressedExternalSessionIDs: Set<String> = []
    private var sessionReportImportGeneration = 0
    private var sessionReportImportInFlight = false
    private var sessionReportImportNeedsRetry = false
    private var lastImportedSessionReportFingerprint: SessionReportImportFingerprint?
    private var hasTrackedFirstSuccessfulRequest = false
    private var hasEvaluatedKeychainPrimerThisLaunch = false
    private static let preflightExpandedDefaultsKey = "proxypilot.preflightExpanded"
    private static let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    private static let buildNumber: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    private static let publicRepositoryURLString = "https://github.com/masterofthechaos/ProxyPilot-public"
    private static let readmeURLString = "https://github.com/masterofthechaos/ProxyPilot-public/blob/main/README.md"
    static let defaultProxyURLString = "http://127.0.0.1:4000"
    static let refreshProxyStatusHelpText = "Refresh proxy status now. ProxyPilot also checks this automatically every 10 seconds while this window is open."
    private static let activeCustomProviderIDDefaultsKey = "proxypilot.activeCustomProviderID"
    private static let customProviderDefaultModelsKeyPrefix = "proxypilot.customProvider.defaultModels."
    private static let customProviderModelCacheKeyPrefix = "proxypilot.customProvider.upstreamModelCache."
    private static let customProviderXcodeAgentModelKeyPrefix = "proxypilot.customProvider.xcodeAgentModel."

    private static func customProviderDefaultModelsKey(for id: UUID) -> String {
        customProviderDefaultModelsKeyPrefix + id.uuidString
    }

    private static func customProviderModelCacheKey(for id: UUID) -> String {
        customProviderModelCacheKeyPrefix + id.uuidString
    }

    private static func customProviderXcodeAgentModelKey(for id: UUID) -> String {
        customProviderXcodeAgentModelKeyPrefix + id.uuidString
    }

    @Published var proxyURLString: String = AppViewModel.defaultProxyURLString {
        didSet { persistAgentLaunchSettings() }
    }

    var upstreamAPIBaseURLString: String {
        get { activeCustomProvider?.apiBaseURL ?? providerManager.upstreamAPIBaseURLString }
        set {
            if var provider = activeCustomProvider {
                provider.apiBaseURL = newValue
                customProviderStorage.update(provider)
                objectWillChange.send()
            } else {
                providerManager.upstreamAPIBaseURLString = newValue
            }
            persistAgentLaunchSettings()
        }
    }

    var upstreamProvider: UpstreamProvider {
        get { providerManager.upstreamProvider }
        set {
            setActiveCustomProviderID(nil)
            providerManager.upstreamProvider = newValue
            persistAgentLaunchSettings()
        }
    }

    var miniMaxRoutingMode: MiniMaxRoutingMode {
        get { providerManager.miniMaxRoutingMode }
        set { providerManager.miniMaxRoutingMode = newValue }
    }

    // MARK: - Custom Providers

    @Published private(set) var activeCustomProviderID: UUID?
    @Published private var activeCustomUpstreamModels: [UpstreamModel] = []
    @Published private var activeCustomSelectedUpstreamModels: Set<String> = []
    @Published private var activeCustomXcodeAgentModel: String = ""

    var customProviders: [CustomProvider] { customProviderStorage.providers }
    var activeCustomProvider: CustomProvider? {
        guard let activeCustomProviderID else { return nil }
        return customProviders.first { $0.id == activeCustomProviderID }
    }
    var hasActiveCustomProvider: Bool { activeCustomProvider != nil }
    var selectedUpstreamSelection: UpstreamSelection {
        get {
            if let provider = activeCustomProvider {
                return .custom(provider.id)
            }
            return .builtIn(upstreamProvider)
        }
        set {
            switch newValue {
            case .builtIn(let provider):
                selectBuiltInUpstreamProvider(provider)
            case .custom(let id):
                guard let provider = customProviders.first(where: { $0.id == id }) else { return }
                activateCustomProvider(provider)
            }
        }
    }
    var upstreamProviderDisplayTitle: String {
        activeCustomProvider?.name ?? upstreamProvider.title
    }
    var selectedUpstreamProviderForNetworking: UpstreamProvider {
        hasActiveCustomProvider ? .openAI : upstreamProvider
    }
    var selectedUpstreamRequiresAPIKey: Bool {
        hasActiveCustomProvider || selectedUpstreamProviderForNetworking.requiresAPIKey
    }
    var selectedUpstreamIsPreview: Bool {
        !hasActiveCustomProvider && upstreamProvider.isPreview
    }
    var selectedUpstreamUsesGoogleDirect: Bool {
        !hasActiveCustomProvider && upstreamProvider == .google
    }
    var selectedUpstreamUsesMiniMaxRouting: Bool {
        !hasActiveCustomProvider && upstreamProvider.isMiniMax
    }
    var selectedUpstreamUsesOpenRouterControls: Bool {
        !hasActiveCustomProvider && upstreamProvider == .openRouter
    }

    func addCustomProvider(name: String, apiBaseURL: String, apiKey: String) {
        let normalizedURL = proxyService.normalizedUpstreamAPIBase(from: apiBaseURL)?.absoluteString ?? apiBaseURL
        let provider = CustomProvider(name: name, apiBaseURL: normalizedURL)
        customProviderStorage.add(provider, apiKey: apiKey)
        objectWillChange.send()
    }

    func deleteCustomProvider(_ provider: CustomProvider) {
        if activeCustomProviderID == provider.id {
            selectBuiltInUpstreamProvider(.zAI)
        }
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

    func isCustomProviderActive(_ provider: CustomProvider) -> Bool {
        activeCustomProviderID == provider.id
    }

    func activateCustomProvider(_ provider: CustomProvider) {
        setActiveCustomProviderID(provider.id)
        runPreflightChecks(trackEvent: false)
        objectWillChange.send()
    }

    func selectBuiltInUpstreamProvider(_ provider: UpstreamProvider) {
        setActiveCustomProviderID(nil)
        providerManager.upstreamProvider = provider
        runPreflightChecks(trackEvent: false)
        objectWillChange.send()
    }

    func saveCustomProviderKey(_ key: String, for provider: CustomProvider) {
        customProviderStorage.saveAPIKey(key, for: provider)
        objectWillChange.send()
    }

    func deleteCustomProviderKey(for provider: CustomProvider) {
        try? KeychainService.delete(account: provider.keychainAccountName)
        objectWillChange.send()
    }

    @Published var launchAtLogin: Bool = false
    @Published private(set) var sessionHistorySessions: [SessionHistorySession] = []
    @Published private(set) var allTimeUsage: AllTimeUsage = .empty
    @Published private(set) var sessionHistoryLoadError: String?

    var localProxyState: LocalProxyState { localProxyServer.state }
    var sessionReportCard: SessionReportCard { localProxyServer.reportCard }

    /// Reset session report card AND menu bar counters so both surfaces stay in sync.
    func resetSessionStats() {
        localProxyServer.reportCard.reset()
        localProxyServer.state.resetSessionTracking()
        localProxyServer.state.lastModelSeen = ""
        localProxyServer.state.lastUpstreamModelUsed = ""
        localProxyServer.state.lastXcodeAgentRequestModel = ""
        localProxyServer.state.lastXcodeAgentRequestStatus = nil
        localProxyServer.state.lastXcodeAgentRequestAt = nil
        suppressedExternalSessionIDs.formUnion(importedExternalSessionIDs)
        importedExternalSessionEventIDs.removeAll()
        importedExternalSessionIDs.removeAll()
        sessionReportImportGeneration &+= 1
        sessionReportImportNeedsRetry = false
        lastImportedSessionReportFingerprint = nil
    }

    @discardableResult
    func importExternalSessionReportEvents() -> Task<Void, Never>? {
        guard let fingerprint = currentSessionReportFingerprint() else { return nil }
        guard fingerprint != lastImportedSessionReportFingerprint else { return nil }

        if sessionReportImportInFlight {
            sessionReportImportNeedsRetry = true
            return nil
        }

        sessionReportImportInFlight = true
        let generation = sessionReportImportGeneration
        let sessionReportURL = sessionReportURL

        return Task.detached(priority: .userInitiated) { [sessionReportURL, fingerprint] in
            let events = try? SessionReportStore.readEvents(from: sessionReportURL)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.sessionReportImportInFlight = false
                defer {
                    if generation == self.sessionReportImportGeneration,
                       self.sessionReportImportNeedsRetry {
                        self.sessionReportImportNeedsRetry = false
                        self.importExternalSessionReportEvents()
                    } else if generation != self.sessionReportImportGeneration {
                        self.sessionReportImportNeedsRetry = false
                    }
                }

                guard generation == self.sessionReportImportGeneration else {
                    if let events {
                        self.suppressedExternalSessionIDs.formUnion(events.map(\.sessionID))
                    }
                    return
                }
                guard let events else { return }
                self.lastImportedSessionReportFingerprint = fingerprint
                self.telemetryService.trackSessionReportEvents(events, telemetryOptIn: self.telemetryOptIn)
                self.applyExternalSessionReportEvents(events)
            }
        }
    }

    func refreshSessionHistory() async {
        do {
            let sessionReportURL = sessionReportURL
            let result = try await Task.detached(priority: .userInitiated) {
                let events = try SessionReportStore.readEvents(from: sessionReportURL)
                return (
                    sessions: SessionHistorySession.build(from: events),
                    allTimeUsage: AllTimeUsage.build(from: events)
                )
            }.value
            let sessions = result.sessions
            sessionHistorySessions = sessions
            allTimeUsage = result.allTimeUsage
            sessionHistoryLoadError = nil
        } catch {
            sessionHistorySessions = []
            allTimeUsage = .empty
            sessionHistoryLoadError = error.localizedDescription
        }
    }

    @Published var xcodeInstallations: [XcodeInstallation] = []
    var hasCompatibleXcode: Bool { xcodeInstallations.contains { $0.supportsAgenticCoding } }
    @Published private(set) var agentModesCapability = XcodeDetectionService.agentModesCapability(for: [])
    /// Routing is a permanent product surface. Managed, external, missing, and
    /// incompatible RepoGPS states belong inside that surface as actionable
    /// status; they must not make the navigation destination disappear.
    var repoGPSRoutingFeatureEnabled: Bool { true }
    @Published private(set) var agentRuntimeStatus: AgentRuntimeStatus = .notInstalled
    @Published private(set) var proxyPilotAgentRegistrationStatus: ACPRegistrationManager.Status?
    @Published private(set) var proxyPilotAgentStatusText = "Not installed"
    @Published private(set) var isInstallingProxyPilotAgent = false
    @Published var selectedAgentMode: AgentMode = .claudeAgent {
        didSet { defaults.set(selectedAgentMode.rawValue, forKey: Self.selectedAgentModeDefaultsKey) }
    }

    var showsAgentModeChoice: Bool {
        agentModesCapability.proxyPilotAgent.showsProxyPilotAgentControls
    }

    var proxyPilotAgentUsesManualRegistration: Bool {
        if case .manualRegistration = agentModesCapability.proxyPilotAgent { return true }
        return false
    }

    var proxyPilotAgentCapabilityText: String {
        switch agentModesCapability.proxyPilotAgent {
        case .hidden:
            return "Claude Agent remains available on this Mac."
        case .automaticRegistration(let xcode):
            return "Automatic setup is proven for Xcode \(xcode.versionString), build \(xcode.build ?? "unknown")."
        case .manualRegistration(let xcode, let reason):
            switch reason {
            case .buildNotDetected:
                return "Xcode \(xcode.versionString) supports Agent Modes, but its build could not be verified. ProxyPilot will prepare the runtime and guide manual registration."
            case .buildNotProven(let build):
                return "Xcode \(xcode.versionString) build \(build) is not yet proven for automatic registration. ProxyPilot will prepare the runtime and guide manual registration."
            }
        }
    }

    var hasUpstreamKey: Bool {
        if let provider = activeCustomProvider {
            return customProviderHasKey(provider)
        }
        return providerManager.hasUpstreamKey
    }
    var hasMasterKey: Bool { KeychainService.exists(key: .litellmMasterKey) }
    /// External proxy backends still need a user-supplied key. The built-in
    /// server creates its own client capability when authentication is needed.
    var requiresMasterKey: Bool { !useBuiltInProxy }
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

    enum ToolbarProxyStatusKind: Equatable {
        case stopped
        case gui
        case cli
        case repoGPS
        case issue
    }

    struct ToolbarProxyStatus: Equatable {
        var kind: ToolbarProxyStatusKind
        var compactText: String
        var fullText: String

        var isRunning: Bool {
            switch kind {
            case .gui, .cli, .repoGPS:
                return true
            case .stopped, .issue:
                return false
            }
        }
    }

    static func toolbarProxyStatus(
        for runtimeStatus: ProxyRuntimeStatus,
        repoGPSActive: Bool,
        repoGPSLeasePresent: Bool = false
    ) -> ToolbarProxyStatus {
        if repoGPSActive {
            return ToolbarProxyStatus(
                kind: .repoGPS,
                compactText: "RepoGPS",
                fullText: String(localized: "RepoGPS in flight")
            )
        }

        if repoGPSLeasePresent, runtimeStatus == .runningExternal {
            return ToolbarProxyStatus(
                kind: .repoGPS,
                compactText: "RepoGPS",
                fullText: String(localized: "RepoGPS route ready")
            )
        }

        switch runtimeStatus {
        case .stopped:
            return ToolbarProxyStatus(
                kind: .stopped,
                compactText: String(localized: "Stopped"),
                fullText: String(localized: "Stopped")
            )
        case .runningInApp:
            return ToolbarProxyStatus(
                kind: .gui,
                compactText: "GUI",
                fullText: String(localized: "Running (GUI)")
            )
        case .runningExternal:
            return ToolbarProxyStatus(
                kind: .cli,
                compactText: "CLI",
                fullText: String(localized: "Running (CLI)")
            )
        case .portOccupied(let statusCode):
            let text = String(localized: "Port occupied by another service") + " (HTTP \(statusCode))"
            return ToolbarProxyStatus(
                kind: .issue,
                compactText: String(localized: "Conflict"),
                fullText: text
            )
        }
    }

    var toolbarProxyStatus: ToolbarProxyStatus {
        Self.toolbarProxyStatus(
            for: proxyRuntimeStatus,
            repoGPSActive: repoGPS.session.active,
            repoGPSLeasePresent: repoGPS.session.lease != nil
        )
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
        var visible = Set(stored.compactMap(MenuBarSection.init(rawValue:)))

        // A section missing from the stored *order* did not exist when these
        // preferences were written, so the user has never been offered the
        // chance to hide it. Default those to visible.
        //
        // Without this, every section added after a user customizes their menu
        // bar is invisible to exactly the users who customize — the visible set
        // is stored as an explicit allowlist, so a new case is absent from it
        // and silently never renders. Hiding stays intact because a section the
        // user actually hid is still present in the stored order; that is what
        // keeps "deliberately hidden" and "did not exist yet" distinguishable.
        let storedOrder = Set(
            (defaults.stringArray(forKey: menuBarSectionOrderDefaultsKey) ?? [])
                .compactMap(MenuBarSection.init(rawValue:))
        )
        if !storedOrder.isEmpty {
            visible.formUnion(MenuBarSection.allCases.filter { !storedOrder.contains($0) })
        }
        return visible
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
            defaults.set(
                KeysProviderViewItem.defaultOrder
                    .filter { decoded.contains($0) }
                    .map(\.rawValue),
                forKey: visibleKeysProvidersDefaultsKey
            )
            defaults.set(true, forKey: didMigrateQwenVisibleProviderDefaultsKey)
        }
        let didMigrateNineRouter = defaults.bool(forKey: didMigrateNineRouterVisibleProviderDefaultsKey)
        if !didMigrateNineRouter && storedOrderRawValues?.contains(KeysProviderViewItem.nineRouter.rawValue) != true {
            decoded.insert(.nineRouter)
            defaults.set(true, forKey: didMigrateNineRouterVisibleProviderDefaultsKey)
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
        keysProviderOrder = KeysProviderViewItem.defaultOrder
        visibleKeysProviders = Set(KeysProviderViewItem.defaultOrder)
    }

    func resetAllViewCustomizations() {
        appearancePreference = .system
        proxyPilotAccentHex = ProxyPilotAccentColor.defaultHex
        liquidGlassEnabled = true
        dockTileInteractiveEnabled = false
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
        get { hasActiveCustomProvider ? activeCustomUpstreamModels : providerManager.upstreamModels }
        set {
            if let id = activeCustomProviderID {
                activeCustomUpstreamModels = newValue
                cacheCustomUpstreamModels(newValue, providerID: id)
            } else {
                providerManager.upstreamModels = newValue
            }
        }
    }

    var selectedUpstreamModels: Set<String> {
        get { hasActiveCustomProvider ? activeCustomSelectedUpstreamModels : providerManager.selectedUpstreamModels }
        set {
            if hasActiveCustomProvider {
                activeCustomSelectedUpstreamModels = newValue
                reconcileCustomXcodeAgentModelSelection()
            } else {
                providerManager.selectedUpstreamModels = newValue
            }
        }
    }

    var selectedXcodeAgentModel: String {
        get { hasActiveCustomProvider ? activeCustomXcodeAgentModel : providerManager.selectedXcodeAgentModel }
        set {
            if let id = activeCustomProviderID {
                activeCustomXcodeAgentModel = newValue
                defaults.set(newValue, forKey: Self.customProviderXcodeAgentModelKey(for: id))
            } else {
                providerManager.selectedXcodeAgentModel = newValue
            }
            persistAgentLaunchSettings()
        }
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
        removeXcodeAgentConfig()

        for key in KeychainService.Key.allCases {
            try? KeychainService.delete(key: key)
        }
        customProviderStorage.removeAll()
        telemetryService.resetForFreshInstall()

        defaults.removeObject(forKey: ProviderManager.upstreamProviderDefaultsKey)
        defaults.removeObject(forKey: Self.didCompleteOnboardingDefaultsKey)
        defaults.removeObject(forKey: Self.telemetryOptInDefaultsKey)
        defaults.removeObject(forKey: Self.liquidGlassEnabledDefaultsKey)
        defaults.removeObject(forKey: Self.dockTileInteractiveEnabledDefaultsKey)
        defaults.removeObject(forKey: Self.inputOutputLoggingEnabledDefaultsKey)
        defaults.removeObject(forKey: Self.inputOutputLoggingRecordInputsDefaultsKey)
        defaults.removeObject(forKey: Self.inputOutputLoggingRecordOutputsDefaultsKey)
        defaults.removeObject(forKey: Self.inputOutputLoggingCLIEnabledDefaultsKey)
        defaults.removeObject(forKey: Self.inputOutputLoggingRetentionDefaultsKey)
        defaults.removeObject(forKey: Self.inputOutputLoggingExternalStorageDefaultsKey)
        defaults.removeObject(forKey: Self.inputOutputLoggingExternalStoragePathDefaultsKey)
        defaults.removeObject(forKey: Self.promptCachingModeDefaultsKey)
        defaults.removeObject(forKey: Self.contextCompactionEnabledDefaultsKey)
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
        defaults.removeObject(forKey: Self.didMigrateNineRouterVisibleProviderDefaultsKey)
        defaults.removeObject(forKey: Self.autoRestartEnabledDefaultsKey)
        defaults.removeObject(forKey: Self.requireLocalAuthDefaultsKey)
        defaults.removeObject(forKey: Self.runInBackgroundDefaultsKey)
        defaults.removeObject(forKey: Self.preflightSnapshotDefaultsKey)
        defaults.removeObject(forKey: ProviderManager.showModelMetadataDefaultsKey)
        defaults.removeObject(forKey: ProviderManager.exactoFilterDefaultsKey)
        defaults.removeObject(forKey: ProviderManager.verifiedFilterDefaultsKey)
        defaults.removeObject(forKey: Self.suppressKeychainPrimerDefaultsKey)
        defaults.removeObject(forKey: Self.analyticsPromptShownVersionKey)
        defaults.removeObject(forKey: Self.harnessOnboardingPresentedVersionKey)
        defaults.removeObject(forKey: Self.harnessOnboardingCompletedVersionKey)
        defaults.removeObject(forKey: Self.anthropicFallbackDefaultsKey)
        defaults.removeObject(forKey: ProviderManager.xcodeAgentModelLegacyDefaultsKey)
        defaults.removeObject(forKey: Self.preflightExpandedDefaultsKey)
        defaults.removeObject(forKey: Self.activeCustomProviderIDDefaultsKey)

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
            Self.toolchainLogFileURL
        ]
        for url in logURLs {
            try? fm.removeItem(at: url)
        }

        proxyURLString = Self.defaultProxyURLString
        useBuiltInProxy = true
        setActiveCustomProviderID(nil)
        upstreamProvider = .zAI
        upstreamAPIBaseURLString = upstreamProvider.defaultAPIBaseURL
        upstreamModels = []
        selectedUpstreamModels = []
        selectedXcodeAgentModel = providerManager.preferredXcodeAgentModel(from: savedDefaultModels, provider: upstreamProvider)
        providerManager.reconcileXcodeAgentModelSelection()
        launchAtLogin = false
        anthropicTranslatorFallbackEnabled = false
        requireLocalAuth = false
        showModelMetadata = true
        exactoFilterEnabled = true
        verifiedFilterEnabled = false
        showOnboardingWizard = true
        telemetryOptIn = false
        liquidGlassEnabled = true
        dockTileInteractiveEnabled = false
        inputOutputLoggingEnabled = false
        inputOutputLoggingRecordInputs = false
        inputOutputLoggingRecordOutputs = false
        inputOutputLoggingCLIEnabled = false
        inputOutputLoggingRetention = .twentyFourHoursDefault
        inputOutputLoggingExternalStorageEnabled = false
        inputOutputLoggingExternalStoragePath = nil
        promptCachingMode = .computeCacheHints
        contextCompactionEnabled = false
        appearancePreference = .system
        proxyPilotAccentHex = ProxyPilotAccentColor.defaultHex
        showMenuBarExtra = true
        runInBackground = false
        menuBarSectionOrder = MenuBarSection.defaultOrder
        visibleMenuBarSections = Set(MenuBarSection.defaultOrder)
        visibleHomeDashboardSections = Set(HomeDashboardSection.allCases)
        defaultSettingsSection = .home
        keysProviderOrder = KeysProviderViewItem.defaultOrder
        visibleKeysProviders = Set(KeysProviderViewItem.defaultOrder)
        showKeychainAccessPrimer = false
        suppressKeychainAccessPrimer = false
        autoRestartEnabled = true
        hasEvaluatedKeychainPrimerThisLaunch = false
        showHarnessOnboarding = false
        harnessOnboardingBadgeVisible = true

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
        selectedAgentMode = .claudeAgent
        agentModesCapability = XcodeDetectionService.agentModesCapability(for: [])
        agentRuntimeStatus = .notInstalled
        proxyPilotAgentRegistrationStatus = nil
        proxyPilotAgentStatusText = "Not installed"
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

    @Published var useBuiltInProxy: Bool = true {
        didSet {
            proxyLifecycle.useBuiltInProxy = useBuiltInProxy
            refreshStatus()
            if providerManager.isInitialized, oldValue != useBuiltInProxy {
                trackFeatureUsed("proxy_runtime", action: "changed", mode: useBuiltInProxy ? "builtin" : "external")
            }
        }
    }

    @Published var anthropicTranslatorFallbackEnabled: Bool = false {
        didSet {
            defaults.set(anthropicTranslatorFallbackEnabled, forKey: Self.anthropicFallbackDefaultsKey)
            if providerManager.isInitialized, oldValue != anthropicTranslatorFallbackEnabled {
                trackFeatureUsed(
                    "anthropic_translation",
                    action: "mode_changed",
                    mode: anthropicTranslatorFallbackEnabled ? "legacy_fallback" : "hardened"
                )
            }
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

    func setTelemetryOptIn(_ enabled: Bool, surface: String) {
        guard telemetryOptIn != enabled else { return }
        telemetryOptIn = enabled
        if enabled {
            telemetryService.track(
                name: "analytics_enabled",
                payload: [
                    "consent_contract_version": "2",
                    "surface": surface
                ],
                telemetryOptIn: true
            )
        }
    }

    @Published var liquidGlassEnabled: Bool = true {
        didSet {
            defaults.set(liquidGlassEnabled, forKey: Self.liquidGlassEnabledDefaultsKey)
        }
    }

    /// The animated LED model marquee/activity ring on the Dock icon. Off by default —
    /// unlike `liquidGlassEnabled`, enabling this changes system chrome outside the app
    /// window, so it opts in rather than opts out.
    @Published var dockTileInteractiveEnabled: Bool = false {
        didSet {
            defaults.set(dockTileInteractiveEnabled, forKey: Self.dockTileInteractiveEnabledDefaultsKey)
        }
    }

    /// Use from Appearance settings instead of assigning `dockTileInteractiveEnabled` directly —
    /// this is the only path that fires the PostHog enablement event, so loading a persisted
    /// `true` value at launch doesn't re-fire it on every relaunch.
    func setDockTileInteractiveEnabled(_ enabled: Bool) {
        guard enabled != dockTileInteractiveEnabled else { return }
        dockTileInteractiveEnabled = enabled
        if enabled {
            telemetryService.track(name: "dock_tile_interactive_enabled", telemetryOptIn: telemetryOptIn)
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

    @Published var inputOutputLoggingExternalStoragePath: String? {
        didSet {
            defaults.set(inputOutputLoggingExternalStoragePath, forKey: Self.inputOutputLoggingExternalStoragePathDefaultsKey)
            persistSharedInputOutputLoggingPreferences()
        }
    }

    /// `false` when a configured external storage location is currently unreachable
    /// (unmounted volume, revoked permission) and new records will fall back to
    /// Application Support. Re-evaluated on read, not cached.
    var isInputOutputLoggingExternalStorageReachable: Bool {
        ProxyPilotCore.InputOutputLogStore.isExternalStorageOverrideReachable(
            preferences: ProxyPilotCore.InputOutputLoggingPreferences(
                externalStorageEnabled: inputOutputLoggingExternalStorageEnabled,
                externalStoragePath: inputOutputLoggingExternalStoragePath
            )
        )
    }

    @Published var promptCachingMode: PromptCachingMode = .computeCacheHints {
        didSet {
            defaults.set(promptCachingMode.rawValue, forKey: Self.promptCachingModeDefaultsKey)
            persistAgentLaunchSettings()
            if providerManager.isInitialized, oldValue != promptCachingMode {
                trackFeatureUsed("prompt_caching", action: "mode_changed", mode: promptCachingMode.rawValue)
            }
        }
    }

    @Published var contextCompactionEnabled: Bool = false {
        didSet {
            defaults.set(contextCompactionEnabled, forKey: Self.contextCompactionEnabledDefaultsKey)
            persistAgentLaunchSettings()
            if providerManager.isInitialized, oldValue != contextCompactionEnabled {
                trackFeatureUsed(
                    "context_compaction",
                    action: contextCompactionEnabled ? "enabled" : "disabled",
                    mode: contextCompactionEnabled ? "enabled" : "disabled"
                )
            }
        }
    }

    var contextCompactionConfiguration: ContextCompactionConfiguration {
        // Feature-gated until the production ruleset ships MVP functionality;
        // the persisted preference is kept intact so an early opt-in survives
        // the gate opening.
        ContextCompactionConfiguration(
            isEnabled: contextCompactionEnabled && ContextCompactionFeatureGate.isAvailable
        )
    }

    var promptCachingConfiguration: PromptCachingConfiguration {
        PromptCachingConfiguration(
            isEnabled: promptCachingMode != .off,
            mode: promptCachingMode,
            retention: .providerDefault,
            canonicalizeJSONForCache: promptCachingMode == .computeCacheHints
        )
    }

    var selectedPromptCachingConfiguration: PromptCachingConfiguration {
        if hasActiveCustomProvider && promptCachingMode == .computeCacheHints {
            return PromptCachingConfiguration(
                isEnabled: true,
                mode: .observeOnly,
                retention: .providerDefault,
                canonicalizeJSONForCache: false
            )
        }
        return promptCachingConfiguration
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
            if hasActiveCustomProvider {
                return "Custom OpenAI-compatible providers are observed only; ProxyPilot does not mutate outbound cache fields."
            }
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
            case .ollama, .lmStudio:
                return "Auto removes volatile Claude billing metadata from translated system prompts so local prefix caching can be reused."
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
            if hasActiveCustomProvider {
                return "Caching observed"
            }
            if upstreamProvider == .google {
                return "Caching guarded"
            }
            return "Caching auto"
        case .explicitReferenceCache:
            return "Caching observed"
        }
    }

    var liquidGlassPreferenceTitle: String {
        String(localized: "Use Liquid Glass for navigation and controls")
    }

    var liquidGlassPreferenceDescription: String {
        String(localized: "Applies Liquid Glass to ProxyPilot's window-bounded sidebar and custom compact control strips. Native toolbar, sheets, and menus continue to follow macOS.")
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

    /// Enables/disables the external save location override. Enabling without a
    /// previously chosen folder is a no-op; use `chooseInputOutputLoggingExternalStorageFolder()`
    /// to set the path first.
    func setInputOutputLoggingExternalStorageEnabled(_ enabled: Bool) {
        guard !enabled || inputOutputLoggingExternalStoragePath != nil else { return }
        inputOutputLoggingExternalStorageEnabled = enabled
    }

    /// Presents an NSOpenPanel for the user to choose a folder, stores it, and
    /// enables the override.
    func chooseInputOutputLoggingExternalStorageFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Input & Output Log Storage Location"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        inputOutputLoggingExternalStoragePath = url.path
        inputOutputLoggingExternalStorageEnabled = true
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

    func inputOutputLoggingRecords(sessionID: String) async throws -> [InputOutputLogRecord] {
        guard let recorder = try InputOutputLoggingRecorder.productionIfKeyExists(source: "gui") else {
            return []
        }
        try await recorder.pruneExpired()
        return try await recorder.readRecords(matchingSessionID: sessionID)
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
        if inputOutputLoggingEnabled && !inputOutputLoggingRecordInputs && !inputOutputLoggingRecordOutputs {
            inputOutputLoggingRecordInputs = true
            inputOutputLoggingRecordOutputs = true
        }

        if !inputOutputLoggingEnabled {
            inputOutputLoggingRecordInputs = false
            inputOutputLoggingRecordOutputs = false
            inputOutputLoggingCLIEnabled = false
            inputOutputLoggingExternalStorageEnabled = false
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
            externalStorageEnabled: inputOutputLoggingExternalStorageEnabled,
            externalStoragePath: inputOutputLoggingExternalStoragePath
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
            if runInBackground && !showMenuBarExtra {
                showMenuBarExtra = true
                return
            }
            defaults.set(showMenuBarExtra, forKey: Self.showMenuBarExtraDefaultsKey)
        }
    }

    @Published var runInBackground: Bool = false {
        didSet {
            defaults.set(runInBackground, forKey: Self.runInBackgroundDefaultsKey)
            if runInBackground && !showMenuBarExtra {
                showMenuBarExtra = true
            }
            applyBackgroundActivationPolicy()
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

    @Published var showKeychainAccessPrimer: Bool = false
    @Published var showAnalyticsPrompt: Bool = false
    @Published var showHarnessOnboarding: Bool = false
    /// Drives the sidebar-footer pill. Visible until the tour is completed, including
    /// after a skip, so the invitation outlives the one sheet presentation.
    @Published var harnessOnboardingBadgeVisible: Bool = false

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
        // Preserve the lifecycle's existing visibility contract: tests and
        // recovery transitions may publish status copy just before the typed
        // runtime state catches up. RepoGPS has an independent lease signal.
        if repoGPS.session.active || statusText != Self.statusText(for: .stopped) {
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
        activeCustomProvider?.apiBaseURL ?? providerManager.selectedUpstreamProviderDefaultAPIBaseURL
    }

    var currentLogSourcePath: String {
        Self.builtInProxyLogFileURL.path
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
        return String(localized: "Local Proxy Credential (Managed Automatically)")
    }

    var masterKeyChecklistTitle: String {
        if requiresMasterKey {
            return String(localized: "Local proxy password saved in Keychain")
        }
        return String(localized: "Automatic local proxy credential available in Keychain")
    }

    var xcodeAgentModelCandidates: [String] {
        if hasActiveCustomProvider {
            return customXcodeAgentModelCandidates
        }
        return providerManager.xcodeAgentModelCandidates
    }

    var effectiveXcodeAgentModel: String {
        if hasActiveCustomProvider {
            return effectiveCustomXcodeAgentModel
        }
        return providerManager.effectiveXcodeAgentModel
    }

    var xcodeAgentRoutingSummaryText: String {
        let model = effectiveXcodeAgentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty {
            return String(localized: "No model selected. Fetch or save a model for") + " \(upstreamProviderDisplayTitle) " + String(localized: "before routing Xcode Agent traffic.")
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

    /// Mode-aware caveat about *when* a model change reaches the agent. Both modes are
    /// routed by the same proxy-side remap, so the proxy-restart rule is shared — but
    /// the ProxyPilot Agent launcher additionally exports `ANTHROPIC_MODEL` as a hint
    /// baked at agent-session exec time (`AgentLauncherRuntime.buildLaunchPlan`), so a
    /// session already running in Xcode keeps the model it launched with even after the
    /// proxy has moved on. Stale hints are harmless — the proxy still remaps — but the
    /// distinction matters to anyone reading the route state and wondering why a
    /// running session looks unchanged.
    var xcodeAgentRouteScopeNote: String {
        if showsAgentModeChoice && selectedAgentMode == .proxyPilotAgent {
            return String(localized: "The proxy applies the selected model to new requests. An agent session already running in Xcode keeps the model hint it launched with — start a new agent session to pick up a change.")
        }
        return String(localized: "Xcode picks up the selected model on its next request, once the proxy is running it.")
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

    // MARK: - Serving route identity

    /// The model that actually went upstream, as opposed to one that is merely
    /// configured. `lastUpstreamModelUsed` is the post-remap name and therefore
    /// the real answer; `lastModelSeen` is the client's requested name, which
    /// for RepoGPS is the opaque `proxypilot-active` alias until the CLI session
    /// import replaces it with the concrete model the daemon recorded.
    var observedUpstreamModel: String? {
        let upstream = localProxyServer.state.lastUpstreamModelUsed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !upstream.isEmpty { return upstream }
        let seen = localProxyServer.state.lastModelSeen.trimmingCharacters(in: .whitespacesAndNewlines)
        return seen.isEmpty ? nil : seen
    }

    /// Identity of the route that produced the traffic the Home card is showing.
    ///
    /// Every metric on that card — requests, tokens, cache, cost, latency — is
    /// observed traffic, so its provider and model must describe the same
    /// traffic. They used to read `upstreamProviderDisplayTitle` and
    /// `effectiveXcodeAgentModel`, which are the GUI's *configured Xcode* route.
    /// Whenever a CLI daemon owns the proxy those describe a different route
    /// entirely, and the card reported RepoGPS request counts beside the Xcode
    /// model name. The provider agreed only by coincidence, because both routes
    /// happened to point at OpenRouter.
    ///
    /// `nil` when nothing is serving — there is no honest identity to show for a
    /// stopped proxy, and inventing one is how the original defect started.
    struct ServingRoute: Equatable {
        enum Owner: Equatable {
            /// The GUI's own `LocalProxyServer`, driven by the Xcode selection.
            case app
            /// A CLI daemon, driven by `route.json`. Serves RepoGPS.
            case cli
        }

        var owner: Owner
        var providerTitle: String
        var model: String
        /// True when `model` reflects what the running proxy is actually using
        /// — traffic off the wire for a CLI daemon, the live start-time config
        /// for the app's own proxy — rather than a selection not yet in effect.
        /// A selection states an intention; the running proxy is evidence. They
        /// diverge exactly when something is wrong, so the distinction is kept
        /// rather than flattened.
        var isModelObserved: Bool
    }

    var servingRoute: ServingRoute? {
        switch proxyRuntimeStatus {
        case .stopped, .portOccupied:
            return nil

        case .runningInApp:
            // The GUI's own proxy. `activeXcodeAgentModel` is set from the
            // config it was started with (`LocalProxyServer:247`) — the model it
            // will actually remap to — so it is the live answer by construction
            // and needs no traffic to have flowed.
            //
            // Deliberately *not* `observedUpstreamModel` here. That falls back
            // to `lastModelSeen`, which is the **client-requested** name: for
            // Xcode an Anthropic model id, set at `beginRequest` before the
            // remap resolves. Preferring it would make this badge report what
            // Xcode asked for instead of what ProxyPilot served — the same
            // confusion this type exists to end, pointed the other way.
            let active = activeXcodeAgentModel
            let selected = effectiveXcodeAgentModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let model = active.isEmpty ? (selected.isEmpty ? nil : selected) : active else { return nil }
            return ServingRoute(
                owner: .app,
                providerTitle: upstreamProviderDisplayTitle,
                model: model,
                isModelObserved: !active.isEmpty
            )

        case .runningExternal:
            // A CLI daemon owns the port. `route.json` is what it was told to
            // serve; observed traffic is what it did serve. Prefer the evidence.
            let observed = observedUpstreamModel
            let routeModel = routeControl.status.model?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let model = observed ?? routeModel.flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
            return ServingRoute(
                owner: .cli,
                providerTitle: Self.routeProviderTitle(routeControl.status.provider),
                model: model,
                isModelObserved: observed != nil
            )
        }
    }

    /// Maps a `route.json` provider identifier to a display title. Falls back to
    /// the raw identifier rather than to the GUI's configured provider — naming
    /// the wrong provider confidently is worse than showing `openrouter` in
    /// lowercase, and silently substituting the GUI's own selection here would
    /// reintroduce the exact defect this type exists to fix.
    static func routeProviderTitle(_ identifier: String?) -> String {
        guard let identifier, !identifier.isEmpty else {
            return String(localized: "Unknown provider")
        }
        return UpstreamProvider(rawValue: identifier)?.title ?? identifier
    }

    /// Badge text for the serving route: `provider / model`.
    var servingRouteBadgeTitle: String? {
        guard let route = servingRoute else { return nil }
        return "\(route.providerTitle) / \(route.model)"
    }

    var servingRouteBadgeHelpText: String {
        guard let route = servingRoute else {
            return String(localized: "No proxy is serving. Start ProxyPilot, or run a CLI route, to see live route identity.")
        }
        let source = route.isModelObserved
            ? String(localized: "Observed on the most recent request.")
            : String(localized: "From the route configuration; no request has been served yet.")
        switch route.owner {
        case .app:
            return String(localized: "The ProxyPilot-owned proxy is serving this route, from the Xcode selection.") + " " + source
        case .cli:
            return String(localized: "A CLI daemon owns the proxy and is serving this route from route.json. This is the RepoGPS route, not the Xcode one.") + " " + source
        }
    }

    // MARK: - Xcode route badge

    var homeAgentModelBadgeTitle: String {
        if hasPendingXcodeAgentModelChange {
            return activeXcodeAgentModel
        }
        return effectiveXcodeAgentModel
    }

    /// Always names the route. An unqualified model name in a row of observed
    /// traffic reads as "this is what served your requests", which is false the
    /// moment a CLI daemon owns the proxy.
    var homeAgentModelBadgeLabel: String {
        String(localized: "Xcode") + ": " + homeAgentModelBadgeTitle
    }

    /// True when the Xcode selection is a selection only — nothing is serving it.
    /// Drives the badge's de-emphasis so it cannot be mistaken for live state.
    var isXcodeRouteIdle: Bool {
        servingRoute?.owner != .app
    }

    var homeAgentModelBadgeHelpText: String {
        if hasPendingXcodeAgentModelChange {
            return "Active model. Restart ProxyPilot to apply selected model \(effectiveXcodeAgentModel)."
        }
        if proxyRuntimeStatus == .runningInApp || localProxyServer.state.isRunning {
            return "Live model for the running ProxyPilot-owned proxy."
        }
        // The branch that was missing, and the reason the badge could sit beside
        // CLI traffic claiming to be live. `xcodeAgentRoutingSummaryText` has had
        // this case since the Routing section shipped; this one did not.
        if proxyRuntimeStatus == .runningExternal {
            return String(localized: "Selected Xcode Agent model. The running proxy is CLI-owned and is not serving this route — the session metrics above are its traffic, not Xcode's.")
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
            return "Inactive — external CLI owns the proxy"
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
        if requireLocalAuth {
            return "Required for inference"
        }
        if hasUpstreamKey {
            return "Automatic for credential-backed inference"
        }
        return "Off for credential-free local inference"
    }

    var localProxyWhoCanConnectText: String {
        if useBuiltInProxy {
            return "Built-in mode accepts native loopback clients only. Browser-origin and LAN requests are rejected; cloud-backed inference also requires ProxyPilot's generated local credential."
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
        if let provider = activeCustomProvider {
            return "\(provider.name) is a custom OpenAI-compatible provider. Fetch Live Models calls \(provider.apiBaseURL)/models, and Test Upstream Response sends a minimal completion request that may consume credits or quota."
        }
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
            return "Alpha builds keep health and diagnostics events on this Mac; remote PostHog delivery is disabled. Prompts, completions, API keys, URLs, raw errors, repository names, device identifiers, and specific model names are never sent."
        }

        return "Always-on health reporting sends only app-open, app-version, and build-number data to PostHog. When enabled, optional analytics add provider usage, bucketed request/token/performance/cache summaries, client surface, feature modes, setup progress, and normalized failures. Prompts, completions, API keys, URLs, raw errors, repository names, device identifiers, and specific model names are never sent."
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
        env.ANTHROPIC_AUTH_TOKEN = [generated local credential]
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
        case .nineRouter, .ollama, .lmStudio:
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
        case .nineRouter:
            return "Start 9Router, configure its dashboard providers, then use its local OpenAI-compatible endpoint."
        default:
            return ""
        }
    }

    var proxySyncModelCandidates: [String] {
        hasActiveCustomProvider ? customProxySyncModelCandidates : providerManager.proxySyncModelCandidates
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
            promptCacheMissTokens: record.promptCacheMissTokens,
            promptCacheWriteTokens: record.promptCacheWriteTokens
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
        if hasActiveCustomProvider {
            return customSavedDefaultModels
        }
        return providerManager.savedDefaultModels
    }

    var hasSavedDefaultModels: Bool { !savedDefaultModels.isEmpty }

    func saveSelectedModelsAsDefaults() {
        if hasActiveCustomProvider {
            saveSelectedCustomModelsAsDefaults()
        } else {
            providerManager.saveSelectedModelsAsDefaults()
        }
    }

    var filteredUpstreamModels: [UpstreamModel] {
        hasActiveCustomProvider ? activeCustomUpstreamModels : providerManager.filteredUpstreamModels
    }

    var modelSelectionRows: [ProviderManager.ModelSelectionRow] {
        if hasActiveCustomProvider {
            return customModelSelectionRows
        }
        return providerManager.modelSelectionRows
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

    func selectAllUpstreamModels() {
        if hasActiveCustomProvider {
            activeCustomSelectedUpstreamModels.formUnion(modelSelectionRows.map(\.id))
            reconcileCustomXcodeAgentModelSelection()
        } else {
            providerManager.selectAllUpstreamModels()
        }
    }

    func clearUpstreamModelSelection() {
        if hasActiveCustomProvider {
            activeCustomSelectedUpstreamModels = []
            reconcileCustomXcodeAgentModelSelection()
        } else {
            providerManager.clearUpstreamModelSelection()
        }
    }

    func isDefaultModel(_ id: String) -> Bool {
        if hasActiveCustomProvider {
            return Set(customSavedDefaultModels).contains(id)
        }
        return providerManager.isDefaultModel(id)
    }

    func isModelSelected(_ id: String) -> Bool {
        if hasActiveCustomProvider {
            return isDefaultModel(id) || activeCustomSelectedUpstreamModels.contains(id)
        }
        return providerManager.isModelSelected(id)
    }

    func setModelSelected(_ id: String, isSelected: Bool) {
        if hasActiveCustomProvider {
            if isDefaultModel(id) {
                activeCustomSelectedUpstreamModels.insert(id)
            } else if isSelected {
                activeCustomSelectedUpstreamModels.insert(id)
            } else {
                activeCustomSelectedUpstreamModels.remove(id)
            }
            reconcileCustomXcodeAgentModelSelection()
        } else {
            providerManager.setModelSelected(id, isSelected: isSelected)
        }
    }

    func removeDefaultModel(_ id: String) {
        if let providerID = activeCustomProviderID {
            let models = customSavedDefaultModels.filter { $0 != id }
            defaults.set(models, forKey: Self.customProviderDefaultModelsKey(for: providerID))
            activeCustomSelectedUpstreamModels.remove(id)
            reconcileCustomXcodeAgentModelSelection()
            objectWillChange.send()
        } else {
            providerManager.removeDefaultModel(id)
        }
    }

    private var customSavedDefaultModels: [String] {
        guard let providerID = activeCustomProviderID else { return [] }
        return defaults.stringArray(forKey: Self.customProviderDefaultModelsKey(for: providerID)) ?? []
    }

    private var customSavedDefaultModelSet: Set<String> {
        Set(customSavedDefaultModels)
    }

    private var customXcodeAgentModelCandidates: [String] {
        let selected = activeCustomSelectedUpstreamModels.sorted()
        var candidates: [String]
        if !selected.isEmpty {
            candidates = selected
        } else if !activeCustomUpstreamModels.isEmpty {
            candidates = activeCustomUpstreamModels.map(\.id).sorted()
        } else {
            candidates = customSavedDefaultModels
        }

        let trimmedSelection = activeCustomXcodeAgentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSelection.isEmpty,
           !candidates.contains(where: { $0.caseInsensitiveCompare(trimmedSelection) == .orderedSame }) {
            candidates.insert(trimmedSelection, at: 0)
        }
        return candidates
    }

    private var effectiveCustomXcodeAgentModel: String {
        let candidates = customXcodeAgentModelCandidates
        if candidates.contains(activeCustomXcodeAgentModel) {
            return activeCustomXcodeAgentModel
        }
        return candidates.sorted().first ?? customSavedDefaultModels.first ?? ""
    }

    private var customProxySyncModelCandidates: [String] {
        if !activeCustomUpstreamModels.isEmpty {
            var candidates = Set(activeCustomUpstreamModels.map(\.id).filter { isModelSelected($0) })
            candidates.formUnion(customSavedDefaultModelSet)
            return candidates.sorted()
        }

        var candidates = customSavedDefaultModelSet
        let selected = activeCustomXcodeAgentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty {
            candidates.insert(selected)
        }
        return candidates.sorted()
    }

    private var customModelSelectionRows: [ProviderManager.ModelSelectionRow] {
        let liveRows = activeCustomUpstreamModels.map { model in
            ProviderManager.ModelSelectionRow(
                id: model.id,
                model: model,
                isDefault: isDefaultModel(model.id),
                isLive: true
            )
        }
        let liveIDs = Set(liveRows.map(\.id))
        let missingDefaultRows = customSavedDefaultModels
            .filter { !liveIDs.contains($0) }
            .map {
                ProviderManager.ModelSelectionRow(
                    id: $0,
                    model: customUpstreamModel(for: $0),
                    isDefault: true,
                    isLive: false
                )
            }
        return missingDefaultRows + liveRows
    }

    private func customUpstreamModel(for id: String) -> UpstreamModel? {
        if let direct = activeCustomUpstreamModels.first(where: { $0.id == id }) {
            return direct
        }
        let lower = id.lowercased()
        return activeCustomUpstreamModels.first { $0.id.lowercased() == lower }
    }

    private func saveSelectedCustomModelsAsDefaults() {
        guard let providerID = activeCustomProviderID else { return }
        let selectedVisibleModels = Set(modelSelectionRows.map(\.id).filter { id in
            !isDefaultModel(id) && isModelSelected(id)
        })
        let models = Array(customSavedDefaultModelSet.union(selectedVisibleModels)).sorted()
        defaults.set(models, forKey: Self.customProviderDefaultModelsKey(for: providerID))
        activeCustomSelectedUpstreamModels.formUnion(models)
        objectWillChange.send()
    }

    private func cacheCustomUpstreamModels(_ models: [UpstreamModel], providerID: UUID) {
        guard let data = try? JSONEncoder().encode(models) else { return }
        defaults.set(data, forKey: Self.customProviderModelCacheKey(for: providerID))
    }

    private static func cachedCustomUpstreamModels(from defaults: UserDefaults, providerID: UUID) -> [UpstreamModel] {
        guard let data = defaults.data(forKey: customProviderModelCacheKey(for: providerID)),
              let models = try? JSONDecoder().decode([UpstreamModel].self, from: data) else {
            return []
        }
        return models
    }

    private func applyFetchedCustomUpstreamModels(_ models: [UpstreamModel], providerID: UUID) {
        activeCustomUpstreamModels = models
        cacheCustomUpstreamModels(models, providerID: providerID)
        activeCustomSelectedUpstreamModels.formUnion(customSavedDefaultModelSet)
        if let apiBase = activeCustomProvider?.apiBaseURL, isLocalhostURL(apiBase) {
            activeCustomSelectedUpstreamModels.formUnion(models.map(\.id))
        }
        reconcileCustomXcodeAgentModelSelection()
    }

    private func reconcileCustomXcodeAgentModelSelection() {
        let candidates = customXcodeAgentModelCandidates
        if !candidates.contains(activeCustomXcodeAgentModel) {
            selectedXcodeAgentModel = candidates.sorted().first ?? customSavedDefaultModels.first ?? ""
        }
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

    init(
        defaults: UserDefaults = .standard,
        proxyService: ProxyService = ProxyService(),
        localProxyServer: LocalProxyServer = LocalProxyServer(),
        diagnosticsService: DiagnosticsService = DiagnosticsService(),
        telemetryService: TelemetryService = .shared,
        healthMonitor: HealthMonitor = HealthMonitor(),
        xcodeAgentConfigStateProvider: (() -> Bool)? = nil,
        cliExecutableResolver: CLIExecutableResolver? = nil,
        cliUpdateRunner: CLIUpdateRunner? = nil,
        cliAuthStatusRunner: CLIAuthStatusRunner? = nil,
        cliStopRunner: CLIStopRunner? = nil,
        agentRuntimeManager: AgentRuntimeManager = AgentRuntimeManager(),
        agentLinkManager: AgentExecutableLinkManager = AgentExecutableLinkManager(),
        agentRegistrationManager: ACPRegistrationManager = ACPRegistrationManager(),
        agentRuntimeInstaller: @escaping AgentRuntimeInstaller = { try await $0.install() },
        agentHelperResolver: AgentHelperResolver? = nil,
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
        self.xcodeAgentConfigStateProvider = xcodeAgentConfigStateProvider
        self.cliExecutableResolver = cliExecutableResolver
        self.cliUpdateRunner = cliUpdateRunner
        self.cliAuthStatusRunner = cliAuthStatusRunner
        self.cliStopRunner = cliStopRunner
        self.agentRuntimeManager = agentRuntimeManager
        self.agentLinkManager = agentLinkManager
        self.agentRegistrationManager = agentRegistrationManager
        self.agentRuntimeInstaller = agentRuntimeInstaller
        self.agentHelperResolver = agentHelperResolver ?? Self.bundledAgentHelpers
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
        dockTileInteractiveEnabled = defaults.object(forKey: Self.dockTileInteractiveEnabledDefaultsKey) as? Bool ?? false
        inputOutputLoggingEnabled = defaults.bool(forKey: Self.inputOutputLoggingEnabledDefaultsKey)
        inputOutputLoggingRecordInputs = defaults.bool(forKey: Self.inputOutputLoggingRecordInputsDefaultsKey)
        inputOutputLoggingRecordOutputs = defaults.bool(forKey: Self.inputOutputLoggingRecordOutputsDefaultsKey)
        inputOutputLoggingCLIEnabled = defaults.bool(forKey: Self.inputOutputLoggingCLIEnabledDefaultsKey)
        inputOutputLoggingRetention = InputOutputLoggingRetention(
            rawValue: defaults.string(forKey: Self.inputOutputLoggingRetentionDefaultsKey) ?? ""
        ) ?? .twentyFourHoursDefault
        inputOutputLoggingExternalStorageEnabled = defaults.bool(forKey: Self.inputOutputLoggingExternalStorageDefaultsKey)
        inputOutputLoggingExternalStoragePath = defaults.string(forKey: Self.inputOutputLoggingExternalStoragePathDefaultsKey)
        promptCachingMode = PromptCachingMode(
            rawValue: defaults.string(forKey: Self.promptCachingModeDefaultsKey) ?? ""
        ) ?? .computeCacheHints
        contextCompactionEnabled = defaults.bool(forKey: Self.contextCompactionEnabledDefaultsKey)
        selectedAgentMode = AgentMode(
            rawValue: defaults.string(forKey: Self.selectedAgentModeDefaultsKey) ?? ""
        ) ?? .claudeAgent
        if let rawActiveCustomProviderID = defaults.string(forKey: Self.activeCustomProviderIDDefaultsKey),
           let activeCustomProviderID = UUID(uuidString: rawActiveCustomProviderID) {
            if customProviderStorage.providers.contains(where: { $0.id == activeCustomProviderID }) {
                setActiveCustomProviderID(activeCustomProviderID)
            } else {
                defaults.removeObject(forKey: Self.activeCustomProviderIDDefaultsKey)
            }
        }
        reconcileStoredInputOutputLoggingState()
        persistSharedInputOutputLoggingPreferences()
        appearancePreference = AppAppearancePreference(
            rawValue: defaults.string(forKey: Self.appearancePreferenceDefaultsKey) ?? ""
        ) ?? .system
        proxyPilotAccentHex = ProxyPilotAccentColor.normalizedHex(
            defaults.string(forKey: Self.proxyPilotAccentHexDefaultsKey) ?? ""
        ) ?? ProxyPilotAccentColor.defaultHex
        showMenuBarExtra = defaults.object(forKey: Self.showMenuBarExtraDefaultsKey) as? Bool ?? true
        runInBackground = defaults.bool(forKey: Self.runInBackgroundDefaultsKey)
        // Both decode from the *stored* values before either is assigned.
        // Assigning `menuBarSectionOrder` persists its normalized form, which
        // backfills every known section — so decoding the visible set
        // afterwards would see a complete order and never recognise a section
        // as new. Reading both first keeps that signal intact.
        let storedMenuBarOrder = Self.decodedMenuBarSectionOrder(from: defaults)
        let storedVisibleMenuBarSections = Self.decodedVisibleMenuBarSections(from: defaults)
        menuBarSectionOrder = storedMenuBarOrder
        visibleMenuBarSections = storedVisibleMenuBarSections
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
        suppressKeychainAccessPrimer = defaults.bool(forKey: Self.suppressKeychainPrimerDefaultsKey)
        requireLocalAuth = defaults.bool(forKey: Self.requireLocalAuthDefaultsKey)

        showOnboardingWizard = !defaults.bool(forKey: Self.didCompleteOnboardingDefaultsKey)
        harnessOnboardingBadgeVisible = defaults.string(forKey: Self.harnessOnboardingCompletedVersionKey) == nil

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
        localProxyServer.telemetryTracker = { [weak self] name, payload in
            guard let self else { return }
            self.telemetryService.track(name: name, payload: payload, telemetryOptIn: self.telemetryOptIn)
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
                self?.persistAgentLaunchSettings()
            }

        // Forward ProxyLifecycleManager changes → AppViewModel objectWillChange
        lifecycleManagerCancellable = proxyLifecycle.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }

        // Forward RouteControlService changes → AppViewModel objectWillChange.
        // Nested ObservableObjects do not propagate on their own, and every
        // route-aware surface observes `vm` rather than the service directly.
        routeControlCancellable = routeControl.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }

        repoGPSCancellable = repoGPS.objectWillChange
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
        if Self.shouldRunLaunchBackgroundWork() {
            repoGPS.startMonitoring()
            Task { await detectXcodeInstallations() }
            if upstreamProvider == .openRouter {
                Task { await providerManager.loadVerifiedModels() }
            }
            Task { await hydrateCurrentProviderModelCacheIfNeeded() }
        }

        applyBackgroundActivationPolicy()
    }

    func applicationWillTerminate() async {
        telemetryService.endSession()
        stopLogUpdates()
        await pruneInputOutputLogsForQuit()
    }

    private func pruneInputOutputLogsForQuit() async {
        guard let recorder = try? InputOutputLoggingRecorder.productionIfKeyExists(source: "gui") else {
            return
        }
        try? await recorder.pruneExpired(includeUntilQuit: true)
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

    private func applyBackgroundActivationPolicy() {
        // Skip under XCTest: mutating the test host's activation policy destabilizes the suite.
        guard Self.shouldRunLaunchBackgroundWork() else { return }
        let policy: NSApplication.ActivationPolicy = runInBackground ? .accessory : .regular
        guard NSApp != nil, NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if !runInBackground {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func refreshStatus() {
        importExternalSessionReportEvents()
        refreshAgentConfigInstallationState()
        statusRefreshSequence += 1
        let sequence = statusRefreshSequence
        let locallyRunning = localProxyServer.state.isRunning
        applyProxyRuntimeStatus(locallyRunning ? .runningInApp : .stopped)
        refreshLogText()
        Task { await refreshReachableProxyStatus(sequence: sequence, locallyRunning: locallyRunning) }
        Task { await refreshRouteControlIfStale() }
    }

    /// Reloads the CLI route, at most once every 30 seconds.
    ///
    /// Only meaningful when the GUI does not own the proxy: if it does, the
    /// serving route is the GUI's own and `route.json` has no bearing on what
    /// Home shows. Skipping that case keeps the app from spawning subprocesses
    /// on a timer for an answer it already has.
    func refreshRouteControlIfStale(now: Date = Date(), minimumInterval: TimeInterval = 30) async {
        guard proxyRuntimeStatus != .runningInApp else { return }
        if let last = lastRouteControlRefresh, now.timeIntervalSince(last) < minimumInterval { return }
        lastRouteControlRefresh = now
        await routeControl.refresh()
    }

    /// Forces a route reload regardless of throttle — for explicit user intent
    /// (opening a route surface, pressing Refresh) where staleness is visible.
    func refreshRouteControlNow() async {
        lastRouteControlRefresh = Date()
        await routeControl.refresh()
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
        maybeShowAnalyticsPrompt()
        maybeShowHarnessOnboarding()
    }

    // MARK: - Analytics Opt-In Prompt

    func maybeShowAnalyticsPrompt() {
        guard Self.analyticsPromptAvailable else { return }
        guard defaults.string(forKey: Self.analyticsPromptShownVersionKey) != Self.appVersion else { return }
        guard !showOnboardingWizard, !showKeychainAccessPrimer, !showHarnessOnboarding else { return }
        showAnalyticsPrompt = true
    }

    func dismissAnalyticsPrompt(optIn: Bool) {
        setTelemetryOptIn(optIn, surface: "follow_up_prompt")
        markAnalyticsPromptHandledForCurrentVersion()
        showAnalyticsPrompt = false
        maybeShowHarnessOnboarding()
    }

    private func markAnalyticsPromptHandledForCurrentVersion() {
        defaults.set(Self.appVersion, forKey: Self.analyticsPromptShownVersionKey)
    }

    // MARK: - Coding Harness Tour

    /// Auto-presents the RepoGPS tour once, on the first open of a version that ships it.
    /// Deliberately last in the launch sheet chain: the analytics decision comes first, so
    /// the tour itself can be attributed for anyone who opted in.
    func maybeShowHarnessOnboarding() {
        guard defaults.string(forKey: Self.harnessOnboardingPresentedVersionKey) == nil else { return }
        guard !showOnboardingWizard, !showKeychainAccessPrimer, !showAnalyticsPrompt else { return }

        defaults.set(Self.appVersion, forKey: Self.harnessOnboardingPresentedVersionKey)
        presentHarnessOnboarding(surface: "first_open_after_update")
    }

    /// Manual re-entry from the sidebar pill or the Coding Harnesses tab. Ignores both
    /// persisted keys so the tour is always available on request.
    func openHarnessOnboarding(surface: String) {
        guard !showOnboardingWizard, !showKeychainAccessPrimer, !showAnalyticsPrompt else { return }
        presentHarnessOnboarding(surface: surface)
    }

    private func presentHarnessOnboarding(surface: String) {
        showHarnessOnboarding = true
        telemetryService.track(
            name: "feature_used",
            payload: ["feature": "harness_onboarding", "action": "started", "mode": surface],
            telemetryOptIn: telemetryOptIn
        )
    }

    /// `completed: false` is a skip: the sheet closes but the sidebar pill stays, so the
    /// invitation survives without a second interruption.
    func finishHarnessOnboarding(completed: Bool) {
        showHarnessOnboarding = false
        defaults.set(Self.appVersion, forKey: Self.harnessOnboardingPresentedVersionKey)

        if completed {
            defaults.set(Self.appVersion, forKey: Self.harnessOnboardingCompletedVersionKey)
            harnessOnboardingBadgeVisible = false
        }

        telemetryService.track(
            name: "feature_used",
            payload: [
                "feature": "harness_onboarding",
                "action": completed ? "completed" : "skipped"
            ],
            telemetryOptIn: telemetryOptIn
        )
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

    private struct SessionReportImportFingerprint: Sendable, Equatable {
        let fileSize: Int64?
        let modificationDate: Date?
    }

    private func currentSessionReportFingerprint() -> SessionReportImportFingerprint? {
        guard FileManager.default.fileExists(atPath: sessionReportURL.path) else { return nil }
        guard let resourceValues = try? sessionReportURL.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey
        ]) else { return nil }

        return SessionReportImportFingerprint(
            fileSize: resourceValues.fileSize.map(Int64.init),
            modificationDate: resourceValues.contentModificationDate
        )
    }

    private func applyExternalSessionReportEvents(_ events: [SessionReportEvent]) {
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
        let newSessionEvents = externalEvents.filter {
            $0.sessionID == latestSessionID && !importedExternalSessionEventIDs.contains($0.id)
        }
        guard !newSessionEvents.isEmpty else { return }

        for event in newSessionEvents {
            importedExternalSessionEventIDs.insert(event.id)
            importedExternalSessionIDs.insert(event.sessionID)
        }

        localProxyServer.reportCard.record(newSessionEvents.map(\.record))
        let lastModel = newSessionEvents.last(where: { !$0.record.model.isEmpty })?.record.model
        localProxyServer.state.importCompletedRequests(
            count: localProxyServer.reportCard.totalRequests,
            lastModel: lastModel
        )
    }

    func stopLogUpdates() {
        logRefreshTimer?.invalidate()
        logRefreshTimer = nil
        statusAutoRefreshTimer?.invalidate()
        statusAutoRefreshTimer = nil
        proxyLifecycle.stopHealthMonitor()
    }

    private func setActiveCustomProviderID(_ id: UUID?) {
        activeCustomProviderID = id
        if let id {
            defaults.set(id.uuidString, forKey: Self.activeCustomProviderIDDefaultsKey)
            activeCustomUpstreamModels = Self.cachedCustomUpstreamModels(from: defaults, providerID: id)
            activeCustomSelectedUpstreamModels = Set(customSavedDefaultModels)
            activeCustomXcodeAgentModel = defaults.string(forKey: Self.customProviderXcodeAgentModelKey(for: id)) ?? ""
            reconcileCustomXcodeAgentModelSelection()
        } else {
            defaults.removeObject(forKey: Self.activeCustomProviderIDDefaultsKey)
            activeCustomUpstreamModels = []
            activeCustomSelectedUpstreamModels = []
            activeCustomXcodeAgentModel = ""
        }
        persistAgentLaunchSettings()
    }

    private func selectedUpstreamAPIKey() -> String? {
        if let provider = activeCustomProvider {
            return customProviderStorage.apiKey(for: provider)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let keychainKey = selectedUpstreamProviderForNetworking.keychainKey else { return nil }
        return KeychainService.get(key: keychainKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func saveUpstreamKey() {
        let provider = selectedUpstreamProviderForNetworking
        if case let .failure(_, message) = APIKeyValidator.validate(upstreamKeyDraft, for: provider) {
            applyIssue(AppIssue(
                code: .missingUpstreamKey,
                title: String(localized: "Invalid API Key"),
                message: message,
                actions: [.openUpstreamKeyEditor]
            ))
            return
        }
        do {
            if let customProvider = activeCustomProvider {
                try KeychainService.set(upstreamKeyDraft, forAccount: customProvider.keychainAccountName)
            } else if let keychainKey = provider.keychainKey {
                try KeychainService.set(upstreamKeyDraft, forKey: keychainKey)
            } else {
                return
            }
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
        do {
            if let customProvider = activeCustomProvider {
                try KeychainService.delete(account: customProvider.keychainAccountName)
            } else if let keychainKey = selectedUpstreamProviderForNetworking.keychainKey {
                try KeychainService.delete(key: keychainKey)
            } else {
                return
            }
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
        case .resetProxyURL:
            performIssueAction(.resetProxyURL)
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
        let provider = selectedUpstreamProviderForNetworking
        let context = PreflightContext(
            proxyURLString: proxyURLString,
            useBuiltInProxy: useBuiltInProxy,
            requireLocalAuth: requireLocalAuth,
            upstreamProvider: provider,
            upstreamAPIBaseURLString: upstreamAPIBaseURLString,
            fallbackUpstreamBaseURLString: selectedUpstreamProviderDefaultAPIBaseURL,
            hasMasterKey: hasMasterKey,
            hasUpstreamKey: hasUpstreamKey
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
                    upstreamProvider: provider
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
        maybeShowAnalyticsPrompt()
        maybeShowHarnessOnboarding()
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
        if useBuiltInProxy {
            masterKey = try? LocalProxyCredential.resolveOrCreate(
                using: SecretsProviderFactory.make()
            )
        } else if requiresMasterKey {
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
            trackSuccessfulEngagement("proxy_models_fetch_succeeded")
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
        if useBuiltInProxy {
            masterKey = try? LocalProxyCredential.resolveOrCreate(
                using: SecretsProviderFactory.make()
            )
        } else if requiresMasterKey {
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
        let provider = selectedUpstreamProviderForNetworking
        let customProviderID = activeCustomProviderID

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
        if selectedUpstreamRequiresAPIKey {
            guard let key = selectedUpstreamAPIKey(), !key.isEmpty else {
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
                provider: provider
            )
            if let customProviderID {
                guard activeCustomProviderID == customProviderID else { return }
                applyFetchedCustomUpstreamModels(models, providerID: customProviderID)
            } else {
                guard selectedUpstreamProviderForNetworking == provider else { return }
                providerManager.applyFetchedUpstreamModels(models)
                providerManager.reconcileXcodeAgentModelSelection()
            }
            trackSuccessfulEngagement("provider_models_fetch_succeeded")
        } catch {
            let issue = upstreamIssueFor(
                error,
                fallbackCode: .generic,
                fallbackTitle: String(localized: "Upstream Model Fetch Failed"),
                fallbackActions: upstreamFallbackActions,
                provider: provider,
                apiBase: apiBase,
                path: provider.modelsPath,
                operation: .modelFetch
            )
            applyIssue(issue)
            trackProviderEndpointFailure(provider: provider, operation: .modelFetch, issue: issue)
        }
    }

    func hydrateCurrentProviderModelCacheIfNeeded() async {
        guard upstreamModels.isEmpty else { return }
        let provider = selectedUpstreamProviderForNetworking
        let customProviderID = activeCustomProviderID
        guard selectedUpstreamRequiresAPIKey,
              let apiKey = selectedUpstreamAPIKey(),
              !apiKey.isEmpty else {
            return
        }

        let apiBase: URL
        do {
            apiBase = try validatedUpstreamBaseURL()
        } catch {
            return
        }

        do {
            let models = try await proxyService.fetchUpstreamModels(
                apiBase: apiBase,
                apiKey: apiKey,
                provider: provider
            )
            guard selectedUpstreamProviderForNetworking == provider, upstreamModels.isEmpty else { return }
            if let customProviderID {
                guard activeCustomProviderID == customProviderID else { return }
                applyFetchedCustomUpstreamModels(models, providerID: customProviderID)
            } else {
                providerManager.applyFetchedUpstreamModels(models)
                providerManager.reconcileXcodeAgentModelSelection()
            }
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

        reconcileXcodeAgentModelSelection()

        await proxyLifecycle.restartProxy()

        refreshStatus()
    }

    func testUpstreamResponse() async {
        clearIssue()
        upstreamTestOutput = ""
        upstreamTestModelUsed = ""
        let provider = selectedUpstreamProviderForNetworking

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
        if selectedUpstreamRequiresAPIKey {
            guard let key = selectedUpstreamAPIKey(), !key.isEmpty else {
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
                provider: provider
            )
            upstreamTestModelUsed = model
            upstreamTestOutput = text.isEmpty ? "(empty response)" : text
            trackSuccessfulEngagement("upstream_test_succeeded")
        } catch {
            let issue = upstreamIssueFor(
                error,
                fallbackCode: .generic,
                fallbackTitle: String(localized: "Upstream Test Failed"),
                fallbackActions: upstreamFallbackActions,
                provider: provider,
                apiBase: apiBase,
                path: provider.chatCompletionsPath,
                operation: .upstreamTest
            )
            applyIssue(issue)
            trackProviderEndpointFailure(provider: provider, operation: .upstreamTest, issue: issue)
        }
    }

    func loadVerifiedModels() async {
        await providerManager.loadVerifiedModels()
    }

    func resetUpstreamAPIBaseURL() {
        if let provider = activeCustomProvider {
            upstreamAPIBaseURLString = provider.apiBaseURL
        } else {
            providerManager.resetUpstreamAPIBaseURL()
        }
    }

    func exportDiagnostics() {
        let manifest = currentDiagnosticsManifest()
        let context = DiagnosticsExportContext(
            builtInLogURL: Self.builtInProxyLogFileURL,
            toolchainLogURL: Self.toolchainLogFileURL,
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
        - Upstream provider: \(upstreamProviderDisplayTitle)
        - Upstream base URL: \(upstreamAPIBaseURLString)
        - Proxy running: \(isRunning ? "Yes" : "No")

        A technical support summary has been copied to the clipboard if you need it.
        """
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
        let provider = selectedUpstreamProviderForNetworking
        var ids: Set<String> = []
        ids.formUnion(selectedUpstreamModels)
        ids.formUnion(upstreamModels.map(\.id))
        ids.formUnion(savedDefaultModels)
        if let fallback = provider.fallbackModelIDs {
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
        let provider = selectedUpstreamProviderForNetworking
        let proxy = try validatedProxyURL(requireLocalhost: true)

        guard let port = UInt16(exactly: proxy.port), (1...65535).contains(proxy.port) else {
            throw IssueError(issue: AppIssue(
                code: .invalidPortRange,
                title: String(localized: "Invalid Proxy Port"),
                message: String(localized: "Proxy port must be between 1 and 65535."),
                actions: [.resetProxyURL]
            ))
        }

        let upstreamKey = selectedUpstreamAPIKey()
        let protectedRoutesRequireAuth = LocalProxyCredential.requiresAuthentication(
            explicitlyRequired: requireLocalAuth,
            upstreamAPIKey: upstreamKey
        )
        let masterKey: String
        if protectedRoutesRequireAuth {
            do {
                masterKey = try LocalProxyCredential.resolveOrCreate(
                    using: SecretsProviderFactory.make()
                )
                try synchronizeManagedXcodeAgentCredentialIfInstalled(masterKey)
            } catch {
                throw IssueError(issue: AppIssue(
                    code: .missingMasterKey,
                    title: String(localized: "Local Proxy Credential Unavailable"),
                    message: String(localized: "ProxyPilot could not create or load the local client credential needed to protect your upstream account."),
                    actions: [.openMasterKeyEditor, .exportDiagnostics]
                ))
            }
        } else {
            masterKey = "proxypilot-local-noauth"
        }

        let hasFetchedModels = !upstreamModels.isEmpty
        let allowedModels: Set<String> = {
            if hasActiveCustomProvider { return selectedUpstreamModels.union(savedDefaultModels) }
            if !selectedUpstreamModels.isEmpty {
                let visibleIDs = Set(providerManager.modelSelectionRows.map(\.id))
                return selectedUpstreamModels.intersection(visibleIDs)
                    .union(savedDefaultModels.filter { visibleIDs.contains($0) })
            }
            if hasFetchedModels { return Set(savedDefaultModels) }
            if let fallback = provider.fallbackModelIDs { return Set(fallback) }
            return Set(savedDefaultModels)
        }()
        let preferredModel = effectiveXcodeAgentModel.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let inputOutputLoggerProvider: (@Sendable () -> InputOutputLoggingRecorder?)? =
            inputOutputLoggingPreferencesStore.map { preferencesStore in
                let cache = InputOutputLoggerSessionCache()
                return {
                    cache.recorder(
                        source: "gui",
                        sessionID: sessionID,
                        preferencesStore: preferencesStore
                    )
                }
            }
        let config = LocalProxyServer.Config(
            host: proxy.host,
            port: port,
            sessionID: sessionID,
            masterKey: masterKey,
            upstreamProvider: provider,
            analyticsProviderIdentifier: hasActiveCustomProvider ? "custom" : provider.rawValue,
            upstreamAPIBase: upstreamBase,
            upstreamAPIKey: upstreamKey,
            allowedModels: allowedModels,
            denyRequestsWhenAllowlistEmpty: true,
            requiresAuth: protectedRoutesRequireAuth,
            anthropicTranslatorMode: anthropicTranslatorFallbackEnabled ? .legacyFallback : .hardened,
            miniMaxRoutingMode: providerManager.miniMaxRoutingMode,
            preferredAnthropicUpstreamModel: preferredModel.isEmpty
                ? preferredXcodeAgentModel(from: savedDefaultModels)
                : preferredModel,
            googleThoughtSignatureStore: provider == .google ? GoogleThoughtSignatureStore() : nil,
            inputOutputLoggerProvider: inputOutputLoggerProvider,
            promptCaching: selectedPromptCachingConfiguration,
            contextCompaction: contextCompactionConfiguration
        )

        if upstreamKey == nil && selectedUpstreamRequiresAPIKey {
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
        if hasActiveCustomProvider {
            reconcileCustomXcodeAgentModelSelection()
        } else {
            providerManager.reconcileXcodeAgentModelSelection()
        }
    }

    func upstreamModel(for id: String) -> UpstreamModel? {
        hasActiveCustomProvider ? customUpstreamModel(for: id) : providerManager.upstreamModel(for: id)
    }

    private func preferredXcodeAgentModel(from models: [String]) -> String {
        if hasActiveCustomProvider {
            return models.sorted().first ?? ""
        }
        return providerManager.preferredXcodeAgentModel(from: models)
    }

    private static func csvEscaped(_ value: String) -> String {
        let formulaSafeValue: String
        switch value.unicodeScalars.first {
        case "=", "+", "-", "@", "\t", "\r", "\n":
            formulaSafeValue = "'" + value
        default:
            formulaSafeValue = value
        }

        if formulaSafeValue.contains(",") || formulaSafeValue.contains("\"") || formulaSafeValue.contains("\n") || formulaSafeValue.contains("\r") {
            let escaped = formulaSafeValue.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return formulaSafeValue
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
        logText = proxyService.readLogTail(from: Self.builtInProxyLogFileURL)
    }

    func clearLog() {
        let logURL = Self.builtInProxyLogFileURL
        try? FileManager.default.removeItem(at: logURL)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logText = ""
    }

    private func trackSuccessfulEngagement(_ eventName: String) {
        telemetryService.track(name: eventName, telemetryOptIn: telemetryOptIn)
        guard !hasTrackedFirstSuccessfulRequest else { return }
        hasTrackedFirstSuccessfulRequest = true
        telemetryService.track(name: "first_successful_request", telemetryOptIn: telemetryOptIn)
    }

    private func trackFeatureUsed(_ feature: String, action: String, mode: String) {
        telemetryService.track(
            name: "feature_used",
            payload: ["feature": feature, "action": action, "mode": mode],
            telemetryOptIn: telemetryOptIn
        )
    }

    private func trackProviderEndpointFailure(
        provider: UpstreamProvider,
        operation: UpstreamIssueOperation,
        issue: AppIssue?
    ) {
        let activeEndpoint = hasActiveCustomProvider
            ? proxyService.normalizedUpstreamAPIBase(from: upstreamAPIBaseURLString)
            : providerManager.upstreamAPIBaseURL(for: provider)
        telemetryService.track(
            name: "provider_endpoint_failed",
            payload: Self.telemetryPayloadForProviderEndpointFailure(
                provider: provider,
                operation: operation,
                issue: issue,
                usesDefaultEndpoint: activeEndpoint?.absoluteString == provider.defaultAPIBaseURL
            ),
            telemetryOptIn: telemetryOptIn
        )
    }

    private func refreshReachableProxyStatus(sequence: Int, locallyRunning: Bool) async {
        guard let baseURL = try? validatedProxyURL(requireLocalhost: false).url else { return }

        do {
            let probe = try await proxyService.probe(baseURL: baseURL)
            guard sequence == statusRefreshSequence else { return }
            if probe.statusCode == 200 && probe.isProxyPilot {
                applyProxyRuntimeStatus(locallyRunning ? .runningInApp : .runningExternal)
            } else {
                applyProxyRuntimeStatus(.portOccupied(statusCode: probe.statusCode))
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
            "local_auth_required": String(requireLocalAuth),
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
        "builtin"
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
        if selectedUpstreamRequiresAPIKey {
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
        case .nineRouter:
            return String(localized: "Start 9Router, confirm its dashboard is configured, or change the base URL.")
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
            mode: "built-in",
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
        agentModesCapability = XcodeDetectionService.agentModesCapability(for: installations)
        if !showsAgentModeChoice {
            selectedAgentMode = .claudeAgent
        }
        await refreshProxyPilotAgentState()
    }

    func refreshProxyPilotAgentState() async {
        let runtimeManager = agentRuntimeManager
        agentRuntimeStatus = await Task.detached(priority: .utility) {
            runtimeManager.status()
        }.value
        proxyPilotAgentRegistrationStatus = agentRegistrationManager.status(
            xcodeBuild: selectedProxyPilotAgentXcode?.build
        )
        proxyPilotAgentStatusText = makeProxyPilotAgentStatusText()
    }

    func installProxyPilotAgent() async {
        guard showsAgentModeChoice else { return }
        isInstallingProxyPilotAgent = true
        proxyPilotAgentStatusText = "Installing managed runtime..."
        clearIssue()
        defer { isInstallingProxyPilotAgent = false }

        do {
            persistAgentLaunchSettings()
            _ = try await agentRuntimeInstaller(agentRuntimeManager)
            guard let helpers = agentHelperResolver() else {
                throw AgentRuntimeManagerError.installedRuntimeInvalid(
                    "ProxyPilot Agent helper executables are missing from this app build."
                )
            }
            try agentLinkManager.install(launcherSource: helpers.launcher, cliSource: helpers.cli)

            switch agentModesCapability.proxyPilotAgent {
            case .automaticRegistration(let xcode):
                _ = try agentRegistrationManager.register(xcodeBuild: xcode.build)
                proxyPilotAgentStatusText = "Installed and registered. Reopen Xcode Intelligence settings if it does not appear immediately."
            case .manualRegistration:
                proxyPilotAgentStatusText = "Runtime installed. Complete the manual registration shown below, then reopen Xcode Intelligence settings."
            case .hidden:
                return
            }
            telemetryService.track(
                name: "proxy_pilot_agent_installed",
                payload: ["registration": proxyPilotAgentUsesManualRegistration ? "manual" : "automatic"],
                telemetryOptIn: telemetryOptIn
            )
            await refreshProxyPilotAgentState()
        } catch {
            proxyPilotAgentStatusText = error.localizedDescription
            applyIssue(AppIssue(
                code: .generic,
                title: "ProxyPilot Agent Setup Failed",
                message: error.localizedDescription,
                actions: [.exportDiagnostics]
            ))
        }
    }

    func removeProxyPilotAgent() async {
        clearIssue()
        do {
            _ = try agentRegistrationManager.remove(xcodeBuild: selectedProxyPilotAgentXcode?.build)
            try agentLinkManager.remove()
            try agentRuntimeManager.remove()
            proxyPilotAgentStatusText = "Removed. Reopen Xcode Intelligence settings if the entry remains visible."
            trackFeatureUsed("proxy_pilot_agent", action: "removed", mode: "managed")
            await refreshProxyPilotAgentState()
        } catch {
            proxyPilotAgentStatusText = error.localizedDescription
            applyIssue(AppIssue(
                code: .generic,
                title: "Could Not Remove ProxyPilot Agent",
                message: error.localizedDescription,
                actions: [.exportDiagnostics]
            ))
        }
    }

    var proxyPilotAgentManualRegistrationCommands: String {
        """
        Name: ProxyPilot
        Executable: \(ACPRegistrationManager.defaultExecutablePath())
        Interpreter: leave blank
        Arguments: leave blank
        Environment: leave empty
        """
    }

    private var selectedProxyPilotAgentXcode: AgentModesCapabilityPolicy.Xcode? {
        switch agentModesCapability.proxyPilotAgent {
        case .automaticRegistration(let xcode), .manualRegistration(let xcode, _): xcode
        case .hidden: nil
        }
    }

    private func makeProxyPilotAgentStatusText() -> String {
        switch (agentRuntimeStatus, proxyPilotAgentRegistrationStatus?.state) {
        case (.ready, .registered):
            return "Runtime ready and registered with Xcode."
        case (.ready, .stalePath):
            return "Runtime ready, but Xcode points to a stale launcher path. Reinstall to repair it."
        case (.ready, _):
            return proxyPilotAgentUsesManualRegistration
                ? "Runtime ready. Manual registration is required in Xcode."
                : "Runtime ready but not registered with Xcode."
        case (.stale(let reason, _), _):
            return "Runtime update required: \(reason)"
        case (.corrupt(let reason, _), _):
            return "Runtime repair required: \(reason)"
        case (.notInstalled, _):
            return "Not installed"
        }
    }

    private func persistAgentLaunchSettings() {
        guard providerManager.isInitialized else { return }
        let port = URL(string: proxyURLString)?.port.flatMap(UInt16.init(exactly:))
            ?? ProxyPilotDefaults.defaultPort
        let cacheMode: AgentLaunchSettings.PromptCachingMode = switch promptCachingMode {
        case .off: .off
        case .observeOnly, .explicitReferenceCache: .observeOnly
        case .computeCacheHints: .auto
        }
        let settings = AgentLaunchSettings(
            port: port,
            modelID: effectiveXcodeAgentModel,
            upstreamLabel: upstreamProviderDisplayTitle,
            providerID: hasActiveCustomProvider ? UpstreamProvider.openAI.rawValue : upstreamProvider.rawValue,
            upstreamURL: upstreamAPIBaseURLString,
            credentialKey: activeCustomProvider?.keychainAccountName,
            promptCachingMode: cacheMode,
            contextCompactionEnabled: contextCompactionEnabled
        )
        try? settings.save()
    }

    private static func bundledAgentHelpers() -> (launcher: URL, cli: URL)? {
        let directory = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let launcher = directory.appendingPathComponent("proxypilot-agent")
        let cli = directory.appendingPathComponent("proxypilot")
        guard FileManager.default.isExecutableFile(atPath: launcher.path),
              FileManager.default.isExecutableFile(atPath: cli.path) else {
            return nil
        }
        return (launcher, cli)
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
        let localCredential = (try? LocalProxyCredential.resolveOrCreate(
            using: SecretsProviderFactory.make()
        )) ?? "LOCAL_CREDENTIAL_UNAVAILABLE"
        let settingsObject: [String: Any] = [
            "env": [
                "ANTHROPIC_AUTH_TOKEN": localCredential,
                "ANTHROPIC_BASE_URL": proxyBase
            ]
        ]
        let settingsData = try? JSONSerialization.data(withJSONObject: settingsObject, options: [.sortedKeys])
        let settingsJSON = settingsData.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let quotedSettings = ShellArgumentEscaper.singleQuote(settingsJSON)
        return """
        # Install (route Xcode Agent through ProxyPilot):
        mkdir -p ~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig
        printf '%s\\n' \(quotedSettings) \\
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
            let localCredential = try LocalProxyCredential.resolveOrCreate(
                using: SecretsProviderFactory.make()
            )
            let settingsObject: [String: Any] = [
                "env": [
                    "ANTHROPIC_AUTH_TOKEN": localCredential,
                    "ANTHROPIC_BASE_URL": proxyBase
                ]
            ]
            let settingsData = try JSONSerialization.data(
                withJSONObject: settingsObject,
                options: [.prettyPrinted, .sortedKeys]
            )
            try settingsData.write(to: xcodeAgentConfigSettingsURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: xcodeAgentConfigSettingsURL.path
            )

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

    /// Refreshes only ProxyPilot's managed auth value and preserves any unknown
    /// keys a newer Xcode or user customization added to the settings object.
    private func synchronizeManagedXcodeAgentCredentialIfInstalled(_ credential: String) throws {
        guard FileManager.default.fileExists(atPath: xcodeAgentConfigSettingsURL.path) else {
            return
        }
        let data = try Data(contentsOf: xcodeAgentConfigSettingsURL)
        guard let updated = try LocalProxyCredential.updatingManagedXcodeSettings(
            data,
            credential: credential
        ) else {
            return
        }
        try updated.write(to: xcodeAgentConfigSettingsURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: xcodeAgentConfigSettingsURL.path
        )
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
