import XCTest
import Darwin
import SwiftUI
import ProxyPilotCore
@testable import ProxyPilot

@MainActor
final class AppViewModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    private var analyticsPromptAvailableInTestHost: Bool {
        let isAlpha = AppBuildBadge.isAlphaBundle(Bundle.main.bundleIdentifier)
        let apiKey = Bundle.main.object(forInfoDictionaryKey: "POSTHOG_API_KEY") as? String
        return !isAlpha && !(apiKey?.isEmpty ?? true)
    }

    override func setUp() {
        super.setUp()
        suiteName = "AppViewModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        setenv("PROXYPILOT_KEYCHAIN_SERVICE", "proxypilot.tests.\(suiteName!)", 1)
        setenv("PROXYPILOT_LEGACY_KEYCHAIN_SERVICE", "proxypilot.tests.legacy.\(suiteName!)", 1)
    }

    override func tearDown() {
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        unsetenv("PROXYPILOT_KEYCHAIN_SERVICE")
        unsetenv("PROXYPILOT_LEGACY_KEYCHAIN_SERVICE")
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testChecklistRejectsProxyURLWithoutHTTPScheme() {
        let vm = AppViewModel(defaults: defaults)
        vm.proxyURLString = "127.0.0.1:4000"
        XCTAssertFalse(vm.checklistIsProxyURLValid)
    }

    func testStartProxyOutOfRangePortReturnsE004() async {
        let vm = AppViewModel(defaults: defaults)
        vm.proxyURLString = "http://127.0.0.1:99999"

        await vm.startProxy()

        XCTAssertEqual(vm.activeIssue?.code, .invalidPortRange)
        XCTAssertTrue(vm.activeIssue?.actions.contains(.resetProxyURL) == true)
    }

    func testInvalidUpstreamBaseProvidesResetAction() async {
        let vm = AppViewModel(defaults: defaults)
        vm.upstreamAPIBaseURLString = "not-a-valid-upstream-url"

        await vm.fetchUpstreamModels()

        XCTAssertEqual(vm.activeIssue?.code, .invalidProxyURL)
        XCTAssertTrue(vm.activeIssue?.actions.contains(.resetUpstreamURL) == true)
    }

    func testResetUpstreamURLRemovesOverrideAndKeepsEffectiveDefault() {
        let vm = AppViewModel(defaults: defaults)
        vm.selectBuiltInUpstreamProvider(.openAI)
        let key = "proxypilot.upstreamAPIBaseURL.\(UpstreamProvider.openAI.rawValue)"
        vm.upstreamAPIBaseURLString = "https://example.com/v1"
        XCTAssertEqual(defaults.string(forKey: key), "https://example.com/v1")

        vm.resetUpstreamAPIBaseURL()

        XCTAssertNil(defaults.object(forKey: key))
        XCTAssertEqual(vm.upstreamAPIBaseURLString, UpstreamProvider.openAI.defaultAPIBaseURL)

        let relaunched = AppViewModel(defaults: defaults)
        XCTAssertEqual(relaunched.upstreamProvider, .openAI)
        XCTAssertEqual(relaunched.upstreamAPIBaseURLString, UpstreamProvider.openAI.defaultAPIBaseURL)
    }

    func testLiquidGlassAppearanceDefaultsOn() {
        let vm = AppViewModel(defaults: defaults)

        XCTAssertTrue(vm.liquidGlassEnabled)
    }

    func testLiquidGlassAppearancePreferencePersists() {
        var vm: AppViewModel? = AppViewModel(defaults: defaults)
        vm?.liquidGlassEnabled = false
        vm = nil

        let relaunched = AppViewModel(defaults: defaults)

        XCTAssertFalse(relaunched.liquidGlassEnabled)
    }

    func testDockTileInteractiveDefaultsOff() {
        let vm = AppViewModel(defaults: defaults)

        XCTAssertFalse(vm.dockTileInteractiveEnabled)
    }

    func testDockTileInteractivePreferencePersists() {
        var vm: AppViewModel? = AppViewModel(defaults: defaults)
        vm?.setDockTileInteractiveEnabled(true)
        vm = nil

        let relaunched = AppViewModel(defaults: defaults)

        XCTAssertTrue(relaunched.dockTileInteractiveEnabled)
    }

    func testSetDockTileInteractiveEnabledFiresPostHogEventOnlyOnEnableTransition() {
        var capturedEvents: [(name: String, properties: [String: String])] = []
        let telemetryService = TelemetryService(
            defaults: defaults,
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true),
            postHogDeliveryEnabled: false,
            protectedInternalMarkerURL: nil,
            remoteCaptureHook: { name, properties in
                capturedEvents.append((name: name, properties: properties))
            }
        )
        let vm = AppViewModel(defaults: defaults, telemetryService: telemetryService)
        vm.telemetryOptIn = true

        vm.setDockTileInteractiveEnabled(true)
        XCTAssertEqual(capturedEvents.filter { $0.name == "dock_tile_interactive_enabled" }.count, 1)

        // Re-enabling while already on, and disabling, must not fire the event again.
        vm.setDockTileInteractiveEnabled(true)
        vm.setDockTileInteractiveEnabled(false)
        XCTAssertEqual(capturedEvents.filter { $0.name == "dock_tile_interactive_enabled" }.count, 1)
    }

    func testDockTileInteractiveEnabledLoadedFromDefaultsDoesNotFireTelemetry() {
        defaults.set(true, forKey: "proxypilot.dockTileInteractiveEnabled")
        var capturedEvents: [(name: String, properties: [String: String])] = []
        let telemetryService = TelemetryService(
            defaults: defaults,
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true),
            postHogDeliveryEnabled: false,
            protectedInternalMarkerURL: nil,
            remoteCaptureHook: { name, properties in
                capturedEvents.append((name: name, properties: properties))
            }
        )
        let vm = AppViewModel(defaults: defaults, telemetryService: telemetryService)
        vm.telemetryOptIn = true

        XCTAssertTrue(vm.dockTileInteractiveEnabled)
        XCTAssertFalse(capturedEvents.contains { $0.name == "dock_tile_interactive_enabled" })
    }

    func testResetToFreshInstallResetsDockTileInteractivePreference() async {
        let vm = AppViewModel(defaults: defaults)
        vm.setDockTileInteractiveEnabled(true)

        await vm.resetToFreshInstall()

        XCTAssertFalse(vm.dockTileInteractiveEnabled)
    }

    func testPromptCachingModeDefaultsToAutoAndPersists() {
        var vm: AppViewModel? = AppViewModel(defaults: defaults)

        XCTAssertEqual(vm?.promptCachingMode, .computeCacheHints)
        XCTAssertEqual(vm?.promptCachingConfiguration.mode, .computeCacheHints)
        XCTAssertTrue(vm?.promptCachingConfiguration.canonicalizeJSONForCache == true)

        vm?.promptCachingMode = .observeOnly
        vm = nil

        let relaunched = AppViewModel(defaults: defaults)

        XCTAssertEqual(relaunched.promptCachingMode, .observeOnly)
        XCTAssertEqual(relaunched.promptCachingConfiguration.mode, .observeOnly)
        XCTAssertFalse(relaunched.promptCachingConfiguration.canonicalizeJSONForCache)
    }

    func testContextCompactionDefaultsOffAndPersists() {
        var vm: AppViewModel? = AppViewModel(defaults: defaults)

        XCTAssertFalse(vm?.contextCompactionEnabled ?? true)
        XCTAssertFalse(vm?.contextCompactionConfiguration.isEnabled ?? true)

        vm?.contextCompactionEnabled = true
        vm = nil

        // The preference persists so an early opt-in survives the feature
        // gate opening later; the *effective* configuration is asserted in
        // testContextCompactionConfigurationIsFeatureGated.
        let relaunched = AppViewModel(defaults: defaults)
        XCTAssertTrue(relaunched.contextCompactionEnabled)
    }

    func testContextCompactionConfigurationIsFeatureGated() throws {
        // Ruleset v2 (2026-07-14 Xcode-wall capture) opens the MVP feature
        // gate, so the effective configuration follows the user preference.
        XCTAssertTrue(ContextCompactionFeatureGate.isAvailable)

        let vm = AppViewModel(defaults: defaults)
        vm.proxyURLString = "http://127.0.0.1:4000"

        vm.contextCompactionEnabled = true
        XCTAssertTrue(vm.contextCompactionConfiguration.isEnabled)
        XCTAssertTrue(try vm.buildBuiltInProxyConfig().contextCompaction.isEnabled)

        vm.contextCompactionEnabled = false
        XCTAssertFalse(vm.contextCompactionConfiguration.isEnabled)
        XCTAssertFalse(try vm.buildBuiltInProxyConfig().contextCompaction.isEnabled)
    }

    func testAgentModeDefaultsToClaudeAndPersistsProxyPilotSelection() {
        var vm: AppViewModel? = AppViewModel(defaults: defaults)

        XCTAssertEqual(vm?.selectedAgentMode, .claudeAgent)
        vm?.selectedAgentMode = .proxyPilotAgent
        vm = nil

        let relaunched = AppViewModel(defaults: defaults)
        XCTAssertEqual(relaunched.selectedAgentMode, .proxyPilotAgent)
    }

    func testAgentModelSelectionIsSharedAcrossBothAgentModes() {
        // Parity pin: there is no separate ProxyPilot-Agent model state. Both modes are
        // routed by the same effectiveXcodeAgentModel, so a model chosen in one mode
        // must survive a switch to the other. If this ever diverges, the two cards need
        // separate pickers rather than the shared one they render today.
        let vm = AppViewModel(defaults: defaults)
        vm.selectedAgentMode = .claudeAgent
        vm.selectedXcodeAgentModel = "google/gemini-3.5-flash"

        vm.selectedAgentMode = .proxyPilotAgent
        XCTAssertEqual(vm.selectedXcodeAgentModel, "google/gemini-3.5-flash")
        XCTAssertEqual(vm.effectiveXcodeAgentModel, "google/gemini-3.5-flash")

        vm.selectedXcodeAgentModel = "anthropic/claude-opus-5"
        vm.selectedAgentMode = .claudeAgent
        XCTAssertEqual(vm.selectedXcodeAgentModel, "anthropic/claude-opus-5")
    }

    func testAgentRouteScopeNoteWarnsAboutLaunchTimeHintOnlyInProxyPilotAgentMode() {
        // The ProxyPilot Agent launcher bakes ANTHROPIC_MODEL at exec time, so a running
        // agent session keeps its launch-time model even after the proxy moves on. The
        // Claude path has no such session-scoped hint and must not claim one.
        let vm = AppViewModel(defaults: defaults)

        vm.selectedAgentMode = .claudeAgent
        XCTAssertFalse(vm.xcodeAgentRouteScopeNote.contains("already running"))

        vm.selectedAgentMode = .proxyPilotAgent
        if vm.showsAgentModeChoice {
            XCTAssertTrue(vm.xcodeAgentRouteScopeNote.contains("already running"))
        } else {
            // No qualifying Xcode on this host: the mode choice is hidden, so the note
            // correctly stays on the Claude wording regardless of the stored selection.
            XCTAssertFalse(vm.xcodeAgentRouteScopeNote.contains("already running"))
        }
    }

    func testAgentRuntimeRefreshReportsNotInstalledForEmptyManagedRoot() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxypilot-agent-vm-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = AgentRuntimeManager(
            layout: ManagedAgentRuntimeLayout(
                root: root.appendingPathComponent("runtime"),
                claudeConfigDirectory: root.appendingPathComponent("claude-config")
            )
        )
        let registration = ACPRegistrationManager(
            acpDirectoryURL: root.appendingPathComponent("registrations"),
            executablePath: root.appendingPathComponent("bin/proxypilot-agent").path
        )
        let vm = AppViewModel(
            defaults: defaults,
            agentRuntimeManager: runtime,
            agentRegistrationManager: registration
        )

        await vm.refreshProxyPilotAgentState()

        XCTAssertEqual(vm.agentRuntimeStatus, .notInstalled)
        XCTAssertEqual(vm.proxyPilotAgentStatusText, "Not installed")
    }

    func testBuiltInProxyConfigCarriesPromptCachingMode() throws {
        let vm = AppViewModel(defaults: defaults)
        vm.promptCachingMode = .off

        let config = try vm.buildBuiltInProxyConfig()

        XCTAssertEqual(config.promptCaching.mode, .off)
        XCTAssertFalse(config.promptCaching.recordsProviderCacheTelemetry)
    }

    func testLocalProvidersDescribeAutomaticBillingMetadataRemoval() {
        let vm = AppViewModel(defaults: defaults)
        vm.promptCachingMode = .computeCacheHints

        for provider in [UpstreamProvider.ollama, .lmStudio] {
            vm.upstreamProvider = provider
            XCTAssertTrue(vm.promptCachingProviderStatusText.contains("removes volatile Claude billing metadata"))
        }
    }

    func testBuiltInProxyConfigAutomaticallyProtectsStoredUpstreamKey() throws {
        try KeychainService.set("sk-test", forKey: .zaiAPIKey)
        let vm = AppViewModel(defaults: defaults)
        vm.requireLocalAuth = false

        let config = try vm.buildBuiltInProxyConfig()

        XCTAssertEqual(config.upstreamAPIKey, "sk-test")
        XCTAssertTrue(config.requiresAuth)
        XCTAssertTrue(config.requiresAuthForProtectedRoutes)
        XCTAssertTrue(config.masterKey.hasPrefix(LocalProxyCredential.generatedPrefix))
        XCTAssertEqual(KeychainService.get(key: .litellmMasterKey), config.masterKey)
    }

    func testBuiltInProxyConfigUsesExistingLocalCredentialForStoredUpstreamKey() throws {
        try KeychainService.set("sk-test", forKey: .zaiAPIKey)
        try KeychainService.set("local-secret", forKey: .litellmMasterKey)
        let vm = AppViewModel(defaults: defaults)
        vm.requireLocalAuth = false

        let config = try vm.buildBuiltInProxyConfig()

        XCTAssertEqual(config.upstreamAPIKey, "sk-test")
        XCTAssertTrue(config.requiresAuth)
        XCTAssertEqual(config.masterKey, "local-secret")
        XCTAssertTrue(config.requiresAuthForProtectedRoutes)
        XCTAssertTrue(config.denyRequestsWhenAllowlistEmpty)
    }

    func testBuiltInProxyConfigGeneratesCredentialWhenLocalAuthEnabled() throws {
        try KeychainService.set("sk-test", forKey: .zaiAPIKey)
        let vm = AppViewModel(defaults: defaults)
        vm.requireLocalAuth = true

        let config = try vm.buildBuiltInProxyConfig()

        XCTAssertTrue(config.requiresAuthForProtectedRoutes)
        XCTAssertTrue(config.masterKey.hasPrefix(LocalProxyCredential.generatedPrefix))
    }

    func testBuiltInProxyConfigDoesNotAllowAllFetchedModelsWhenSelectionIsEmpty() throws {
        let vm = AppViewModel(defaults: defaults)
        vm.upstreamProvider = .ollama
        vm.upstreamModels = [
            UpstreamModel(id: "cheap-allowed", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
            UpstreamModel(id: "expensive-policy-disallowed", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
        ]
        vm.selectedUpstreamModels = []
        vm.selectedXcodeAgentModel = ""

        let config = try vm.buildBuiltInProxyConfig()

        XCTAssertTrue(config.allowedModels.isEmpty)
    }

    func testBuiltInProxyConfigUsesOnlySelectedAndSavedDefaultsWithFetchedModels() throws {
        defaults.set(["saved-default"], forKey: ProviderManager.defaultModelsKey(for: .ollama))
        let vm = AppViewModel(defaults: defaults)
        vm.upstreamProvider = .ollama
        vm.upstreamModels = [
            UpstreamModel(id: "selected-live", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
            UpstreamModel(id: "unselected-live", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
            UpstreamModel(id: "saved-default", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
        ]
        vm.selectedUpstreamModels = ["selected-live"]
        vm.selectedXcodeAgentModel = "unselected-live"

        let config = try vm.buildBuiltInProxyConfig()

        XCTAssertEqual(config.allowedModels, ["saved-default", "selected-live"])
    }

    func testInputOutputLoggingDefaultsOffWithDefaultRetention() {
        let vm = AppViewModel(defaults: defaults)

        XCTAssertFalse(vm.inputOutputLoggingEnabled)
        XCTAssertFalse(vm.inputOutputLoggingRecordInputs)
        XCTAssertFalse(vm.inputOutputLoggingRecordOutputs)
        XCTAssertFalse(vm.inputOutputLoggingCLIEnabled)
        XCTAssertEqual(vm.inputOutputLoggingRetention, .twentyFourHoursDefault)
        XCTAssertFalse(vm.inputOutputLoggingExternalStorageEnabled)
    }

    func testInputOutputLoggingPreferencesPersistAcrossRelaunch() {
        var vm: AppViewModel? = AppViewModel(defaults: defaults)
        vm?.confirmInputOutputLoggingEnabled()
        vm?.setInputOutputRecordInputs(false)
        vm?.inputOutputLoggingCLIEnabled = true
        vm?.inputOutputLoggingRetention = .sixHours
        vm?.inputOutputLoggingExternalStoragePath = "/Volumes/External/ProxyPilotLogs"
        vm?.inputOutputLoggingExternalStorageEnabled = true
        vm = nil

        let relaunched = AppViewModel(defaults: defaults)

        XCTAssertTrue(relaunched.inputOutputLoggingEnabled)
        XCTAssertFalse(relaunched.inputOutputLoggingRecordInputs)
        XCTAssertTrue(relaunched.inputOutputLoggingRecordOutputs)
        XCTAssertTrue(relaunched.inputOutputLoggingCLIEnabled)
        XCTAssertEqual(relaunched.inputOutputLoggingRetention, .sixHours)
        XCTAssertTrue(relaunched.inputOutputLoggingExternalStorageEnabled)
        XCTAssertEqual(relaunched.inputOutputLoggingExternalStoragePath, "/Volumes/External/ProxyPilotLogs")
    }

    func testSetInputOutputLoggingExternalStorageEnabledRequiresPathFirst() {
        let vm = AppViewModel(defaults: defaults)
        vm.confirmInputOutputLoggingEnabled()

        vm.setInputOutputLoggingExternalStorageEnabled(true)
        XCTAssertFalse(vm.inputOutputLoggingExternalStorageEnabled, "Enabling without a chosen folder should be a no-op")

        vm.inputOutputLoggingExternalStoragePath = "/Volumes/External/ProxyPilotLogs"
        vm.setInputOutputLoggingExternalStorageEnabled(true)
        XCTAssertTrue(vm.inputOutputLoggingExternalStorageEnabled)

        vm.setInputOutputLoggingExternalStorageEnabled(false)
        XCTAssertFalse(vm.inputOutputLoggingExternalStorageEnabled)
        XCTAssertEqual(vm.inputOutputLoggingExternalStoragePath, "/Volumes/External/ProxyPilotLogs", "Disabling should not forget the chosen folder")
    }

    func testInputOutputLoggingExternalStorageReachabilityReflectsDirectoryExistence() throws {
        let vm = AppViewModel(defaults: defaults)
        vm.confirmInputOutputLoggingEnabled()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        vm.inputOutputLoggingExternalStoragePath = directory.path
        vm.setInputOutputLoggingExternalStorageEnabled(true)
        XCTAssertTrue(vm.isInputOutputLoggingExternalStorageReachable)

        try FileManager.default.removeItem(at: directory)
        XCTAssertFalse(vm.isInputOutputLoggingExternalStorageReachable)
    }

    func testInputOutputLoggingWritesSharedCorePreferencesWhenStoreProvided() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = InputOutputLoggingPreferencesStore(
            url: directory.appendingPathComponent("settings.json")
        )
        let vm = AppViewModel(
            defaults: defaults,
            inputOutputLoggingPreferencesStore: store
        )

        vm.confirmInputOutputLoggingEnabled()
        vm.inputOutputLoggingCLIEnabled = true
        vm.inputOutputLoggingRetention = .sixHours

        let preferences = try store.load()
        XCTAssertTrue(preferences.enabled)
        XCTAssertTrue(preferences.recordInputs)
        XCTAssertTrue(preferences.recordOutputs)
        XCTAssertTrue(preferences.cliEnabled)
        XCTAssertEqual(preferences.retention, .sixHours)
    }

    func testInputOutputLoggingDisablesWhenInputsAndOutputsAreOff() {
        let vm = AppViewModel(defaults: defaults)

        vm.confirmInputOutputLoggingEnabled()
        vm.setInputOutputRecordInputs(false)
        vm.setInputOutputRecordOutputs(false)

        XCTAssertFalse(vm.inputOutputLoggingEnabled)
        XCTAssertFalse(vm.inputOutputLoggingCLIEnabled)
        XCTAssertFalse(vm.inputOutputLoggingExternalStorageEnabled)
    }

    func testRefreshSessionHistoryLoadsAllTimeUsage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let reportURL = directory.appendingPathComponent("session-report.jsonl")
        try SessionReportStore.append(
            SessionReportEvent(
                source: "gui",
                sessionID: "session-a",
                record: RequestRecord(
                    timestamp: Date(timeIntervalSince1970: 100),
                    model: "gpt-4o",
                    promptTokens: 10,
                    completionTokens: 5,
                    durationSeconds: 1.0,
                    path: "/v1/chat/completions",
                    wasStreaming: false
                )
            ),
            to: reportURL
        )
        try SessionReportStore.append(
            SessionReportEvent(
                source: "cli",
                sessionID: "session-b",
                record: RequestRecord(
                    timestamp: Date(timeIntervalSince1970: 200),
                    model: "claude-3.5",
                    promptTokens: 20,
                    completionTokens: 10,
                    durationSeconds: 2.0,
                    path: "/v1/messages",
                    wasStreaming: true
                )
            ),
            to: reportURL
        )

        let vm = AppViewModel(defaults: defaults, sessionReportURL: reportURL)
        await vm.refreshSessionHistory()

        XCTAssertEqual(vm.sessionHistorySessions.count, 2)
        XCTAssertEqual(vm.allTimeUsage.requestCount, 2)
        XCTAssertEqual(vm.allTimeUsage.sessionCount, 2)
        XCTAssertEqual(vm.allTimeUsage.totalTokens, 45)
        XCTAssertEqual(vm.allTimeUsage.sourceShares.map(\.source), ["cli", "gui"])
    }

    func testCustomizationDefaultsPreserveCurrentExperience() {
        let vm = AppViewModel(defaults: defaults)

        XCTAssertEqual(vm.appearancePreference, .system)
        XCTAssertEqual(vm.proxyPilotAccentHex, ProxyPilotAccentColor.defaultHex)
        XCTAssertTrue(vm.showMenuBarExtra)
        XCTAssertEqual(vm.menuBarSectionOrder, MenuBarSection.defaultOrder)
        XCTAssertEqual(vm.visibleMenuBarSections, Set(MenuBarSection.defaultOrder))
        XCTAssertEqual(vm.visibleHomeDashboardSections, Set(HomeDashboardSection.allCases))
        XCTAssertEqual(vm.defaultSettingsSection, .home)
        XCTAssertEqual(vm.keysProviderOrder, KeysProviderViewItem.defaultOrder)
        XCTAssertEqual(vm.visibleKeysProviders, Set(KeysProviderViewItem.defaultOrder))
    }

    func testRunInBackgroundDefaultsToFalse() {
        let vm = AppViewModel(defaults: defaults)

        XCTAssertFalse(vm.runInBackground)
    }

    func testRunInBackgroundPreferencePersists() {
        var vm: AppViewModel? = AppViewModel(defaults: defaults)
        vm?.runInBackground = true
        vm = nil

        let relaunched = AppViewModel(defaults: defaults)

        XCTAssertTrue(relaunched.runInBackground)
    }

    func testEnablingRunInBackgroundForcesMenuBarExtraOn() {
        let vm = AppViewModel(defaults: defaults)
        vm.showMenuBarExtra = false
        vm.runInBackground = true

        XCTAssertTrue(vm.showMenuBarExtra)
        XCTAssertTrue(vm.runInBackground)
    }

    func testDisablingMenuBarExtraWhileRunningInBackgroundKeepsItEnabled() {
        let vm = AppViewModel(defaults: defaults)
        vm.runInBackground = true
        vm.showMenuBarExtra = false

        XCTAssertTrue(vm.runInBackground)
        XCTAssertTrue(vm.showMenuBarExtra)
        XCTAssertEqual(defaults.object(forKey: AppViewModel.showMenuBarExtraDefaultsKey) as? Bool, true)
    }

    func testBackgroundModeRestoresMenuBarExtraDuringInitialization() {
        defaults.set(true, forKey: "proxypilot.runInBackground")
        defaults.set(false, forKey: AppViewModel.showMenuBarExtraDefaultsKey)

        let vm = AppViewModel(defaults: defaults)

        XCTAssertTrue(vm.runInBackground)
        XCTAssertTrue(vm.showMenuBarExtra)
        XCTAssertEqual(defaults.object(forKey: AppViewModel.showMenuBarExtraDefaultsKey) as? Bool, true)
    }

    func testToolbarStatusHidesPlainStoppedStateOnly() {
        let vm = AppViewModel(defaults: defaults)

        vm.statusText = AppViewModel.statusText(for: .stopped)
        XCTAssertFalse(vm.shouldShowToolbarStatus)

        vm.statusText = AppViewModel.statusText(for: .runningExternal)
        XCTAssertTrue(vm.shouldShowToolbarStatus)

        vm.statusText = AppViewModel.statusText(for: .portOccupied(statusCode: 401))
        XCTAssertTrue(vm.shouldShowToolbarStatus)
    }

    func testRepoGPSRoutingRemainsNavigableBeforeManagedInstallation() {
        let vm = AppViewModel(defaults: defaults)

        XCTAssertTrue(vm.repoGPSRoutingFeatureEnabled)
        XCTAssertTrue(
            SettingsSection.availableSidebarSections(
                repoGPSRoutingEnabled: vm.repoGPSRoutingFeatureEnabled
            ).contains(.routing)
        )
    }

    func testCustomizationPreferencesPersistAcrossRelaunch() {
        var vm: AppViewModel? = AppViewModel(defaults: defaults)
        vm?.appearancePreference = .dark
        vm?.proxyPilotAccentHex = "#FF2D55"
        vm?.showMenuBarExtra = false
        vm?.menuBarSectionOrder = [.quickActions, .statusDetails, .updates, .modelPicker, .sessionStats]
        vm?.visibleMenuBarSections = [.statusDetails, .quickActions]
        vm?.visibleHomeDashboardSections = [.sessionSummary, .sessionReportCard]
        vm?.defaultSettingsSection = .customization
        vm?.keysProviderOrder = [.openAI, .zAI, .openRouter, .xAI, .chutes, .groq, .google, .deepSeek, .mistral, .miniMax, .miniMaxCN, .qwen, .nineRouter, .ollama, .lmStudio]
        vm?.visibleKeysProviders = [.openAI, .zAI]
        vm = nil

        let relaunched = AppViewModel(defaults: defaults)

        XCTAssertEqual(relaunched.appearancePreference, .dark)
        XCTAssertEqual(relaunched.proxyPilotAccentHex, "#FF2D55")
        XCTAssertFalse(relaunched.showMenuBarExtra)
        // The stored order predates `.repoGPSRoute`, so normalization appends
        // it rather than dropping a section the user has never seen.
        XCTAssertEqual(relaunched.menuBarSectionOrder, [.quickActions, .statusDetails, .updates, .modelPicker, .sessionStats, .repoGPSRoute])
        // Assigning `menuBarSectionOrder` above persisted its normalized form,
        // which already names every section — so nothing here reads as new and
        // the user's hidden sections stay hidden.
        XCTAssertEqual(relaunched.visibleMenuBarSections, [.statusDetails, .quickActions])
        XCTAssertEqual(relaunched.visibleHomeDashboardSections, [.sessionSummary, .sessionReportCard])
        XCTAssertEqual(relaunched.defaultSettingsSection, .customization)
        XCTAssertEqual(relaunched.keysProviderOrder.first, .openAI)
        XCTAssertEqual(relaunched.keysProviderOrder.dropFirst().first, .zAI)
        XCTAssertEqual(relaunched.visibleKeysProviders, [.openAI, .zAI])
    }

    func testCustomizationResetRestoresDefaults() async {
        let vm = AppViewModel(defaults: defaults)
        vm.appearancePreference = .dark
        vm.proxyPilotAccentHex = "#FF2D55"
        vm.showMenuBarExtra = false
        vm.menuBarSectionOrder = [.quickActions, .statusDetails, .updates, .modelPicker, .sessionStats]
        vm.visibleMenuBarSections = [.statusDetails, .quickActions]
        vm.visibleHomeDashboardSections = [.sessionSummary]
        vm.defaultSettingsSection = .customization
        vm.keysProviderOrder = [.openAI, .zAI, .openRouter, .xAI, .chutes, .groq, .google, .deepSeek, .mistral, .miniMax, .miniMaxCN, .qwen, .nineRouter, .ollama, .lmStudio]
        vm.visibleKeysProviders = [.openAI]

        await vm.resetToFreshInstall()

        XCTAssertEqual(vm.appearancePreference, .system)
        XCTAssertEqual(vm.proxyPilotAccentHex, ProxyPilotAccentColor.defaultHex)
        XCTAssertTrue(vm.showMenuBarExtra)
        XCTAssertEqual(vm.menuBarSectionOrder, MenuBarSection.defaultOrder)
        XCTAssertEqual(vm.visibleMenuBarSections, Set(MenuBarSection.defaultOrder))
        XCTAssertEqual(vm.visibleHomeDashboardSections, Set(HomeDashboardSection.allCases))
        XCTAssertEqual(vm.defaultSettingsSection, .home)
        XCTAssertEqual(vm.keysProviderOrder, KeysProviderViewItem.defaultOrder)
        XCTAssertEqual(vm.visibleKeysProviders, Set(KeysProviderViewItem.defaultOrder))
    }

    /// The real upgrade path: preferences written by a build that predates
    /// `.repoGPSRoute`. The new section must arrive visible, or the RepoGPS
    /// route control is invisible to exactly the users who customized their
    /// menu bar — and it is one of the three surfaces that route is meant to
    /// be settable from.
    func testSectionAddedAfterPreferencesWereWrittenArrivesVisible() {
        let legacySections: [MenuBarSection] = [.statusDetails, .modelPicker, .sessionStats, .quickActions, .updates]
        defaults.set(
            legacySections.map(\.rawValue),
            forKey: AppViewModel.menuBarSectionOrderDefaultsKey
        )
        defaults.set(
            [MenuBarSection.statusDetails.rawValue, MenuBarSection.modelPicker.rawValue].map { $0 },
            forKey: AppViewModel.visibleMenuBarSectionsDefaultsKey
        )

        let vm = AppViewModel(defaults: defaults)

        XCTAssertTrue(vm.visibleMenuBarSections.contains(.repoGPSRoute))
        // Sections the user hid in the old build stay hidden.
        XCTAssertFalse(vm.visibleMenuBarSections.contains(.sessionStats))
        XCTAssertFalse(vm.visibleMenuBarSections.contains(.quickActions))
        XCTAssertTrue(vm.visibleMenuBarSections.contains(.statusDetails))
        XCTAssertTrue(vm.menuBarSectionOrder.contains(.repoGPSRoute))
    }

    /// A section the user deliberately hid must stay hidden across a version
    /// that adds new sections — the "new sections arrive visible" rule keys off
    /// absence from the stored *order*, not absence from the visible list.
    func testDeliberatelyHiddenSectionsStayHiddenWhenNewSectionsAppear() {
        defaults.set(
            MenuBarSection.allCases.map(\.rawValue),
            forKey: AppViewModel.menuBarSectionOrderDefaultsKey
        )
        defaults.set(
            [MenuBarSection.quickActions.rawValue],
            forKey: AppViewModel.visibleMenuBarSectionsDefaultsKey
        )

        let vm = AppViewModel(defaults: defaults)

        // Every section is present in the stored order, so nothing is new and
        // nothing is force-shown.
        XCTAssertEqual(vm.visibleMenuBarSections, [.quickActions])
        XCTAssertFalse(vm.visibleMenuBarSections.contains(.repoGPSRoute))
    }

    func testMenuBarCustomizationNormalizesStoredUnknownMissingAndDuplicateSections() {
        defaults.set(
            [
                MenuBarSection.quickActions.rawValue,
                "unknown",
                MenuBarSection.quickActions.rawValue,
                MenuBarSection.statusDetails.rawValue
            ],
            forKey: AppViewModel.menuBarSectionOrderDefaultsKey
        )
        defaults.set(
            [
                MenuBarSection.quickActions.rawValue,
                "unknown",
                MenuBarSection.quickActions.rawValue
            ],
            forKey: AppViewModel.visibleMenuBarSectionsDefaultsKey
        )

        let vm = AppViewModel(defaults: defaults)

        // Unknown entries dropped, duplicates collapsed, and every section the
        // stored order omits — including the newly added `.repoGPSRoute` —
        // restored in `defaultOrder` position.
        XCTAssertEqual(vm.menuBarSectionOrder, [.quickActions, .statusDetails, .modelPicker, .repoGPSRoute, .sessionStats, .updates])
        // The stored order names only `quickActions` and `statusDetails`, so
        // every other section reads as postdating these preferences and comes
        // back visible. `statusDetails` remains hidden: it is in the stored
        // order but not the stored visible list, which is a real hide.
        XCTAssertEqual(
            vm.visibleMenuBarSections,
            [.quickActions, .modelPicker, .repoGPSRoute, .sessionStats, .updates]
        )
    }

    func testKeysProviderCustomizationNormalizesStoredUnknownMissingAndDuplicateProviders() {
        defaults.set(
            [
                KeysProviderViewItem.openAI.rawValue,
                "unknown",
                KeysProviderViewItem.openAI.rawValue,
                "github-copilot"
            ],
            forKey: AppViewModel.keysProviderOrderDefaultsKey
        )
        defaults.set(
            [
                KeysProviderViewItem.openAI.rawValue,
                "unknown",
                KeysProviderViewItem.openAI.rawValue
            ],
            forKey: AppViewModel.visibleKeysProvidersDefaultsKey
        )

        let vm = AppViewModel(defaults: defaults)

        XCTAssertEqual(vm.keysProviderOrder.first, .openAI)
        XCTAssertFalse(vm.keysProviderOrder.map(\.rawValue).contains("github-copilot"))
        XCTAssertEqual(vm.keysProviderOrder.count, KeysProviderViewItem.defaultOrder.count)
        XCTAssertEqual(vm.visibleKeysProviders, [.openAI, .qwen, .nineRouter])
    }

    func testKeysProviderCustomizationMigratesQwenIntoLegacyVisibleProvidersOnce() {
        defaults.set(
            [
                KeysProviderViewItem.openAI.rawValue,
                "github-copilot",
                KeysProviderViewItem.zAI.rawValue
            ],
            forKey: AppViewModel.keysProviderOrderDefaultsKey
        )
        defaults.set(
            [
                KeysProviderViewItem.openAI.rawValue
            ],
            forKey: AppViewModel.visibleKeysProvidersDefaultsKey
        )

        let vm = AppViewModel(defaults: defaults)

        XCTAssertTrue(vm.keysProviderOrder.contains(.qwen))
        XCTAssertTrue(vm.visibleKeysProviders.contains(.qwen))
        XCTAssertTrue(vm.visibleKeysProviders.contains(.openAI))
        XCTAssertFalse(vm.visibleKeysProviders.contains(.zAI))
        XCTAssertTrue(defaults.bool(forKey: AppViewModel.didMigrateQwenVisibleProviderDefaultsKey))
        XCTAssertTrue(defaults.stringArray(forKey: AppViewModel.visibleKeysProvidersDefaultsKey)?.contains(KeysProviderViewItem.qwen.rawValue) == true)
    }

    func testQwenVisibilityMigrationPersistsTheVisibleArrayBeforeItsMarker() {
        defaults.set(
            [KeysProviderViewItem.openAI.rawValue],
            forKey: AppViewModel.visibleKeysProvidersDefaultsKey
        )

        let visible = AppViewModel.decodedVisibleKeysProviders(
            from: defaults,
            storedOrderRawValues: [KeysProviderViewItem.openAI.rawValue]
        )

        XCTAssertTrue(visible.contains(.qwen))
        XCTAssertTrue(defaults.stringArray(forKey: AppViewModel.visibleKeysProvidersDefaultsKey)?.contains(KeysProviderViewItem.qwen.rawValue) == true)
        XCTAssertTrue(defaults.bool(forKey: AppViewModel.didMigrateQwenVisibleProviderDefaultsKey))
    }

    func testKeysProviderCustomizationMigrates9RouterIntoLegacyVisibleProvidersOnce() {
        defaults.set(
            [
                KeysProviderViewItem.openAI.rawValue,
                "github-copilot",
                KeysProviderViewItem.qwen.rawValue
            ],
            forKey: AppViewModel.keysProviderOrderDefaultsKey
        )
        defaults.set(
            [
                KeysProviderViewItem.openAI.rawValue
            ],
            forKey: AppViewModel.visibleKeysProvidersDefaultsKey
        )
        defaults.set(true, forKey: AppViewModel.didMigrateQwenVisibleProviderDefaultsKey)

        let vm = AppViewModel(defaults: defaults)

        XCTAssertTrue(vm.keysProviderOrder.contains(.nineRouter))
        XCTAssertTrue(vm.visibleKeysProviders.contains(.nineRouter))
        XCTAssertTrue(vm.visibleKeysProviders.contains(.openAI))
        XCTAssertFalse(vm.visibleKeysProviders.map(\.rawValue).contains("github-copilot"))
        XCTAssertTrue(defaults.bool(forKey: AppViewModel.didMigrateNineRouterVisibleProviderDefaultsKey))
    }

    func testKeysProviderCustomizationMigratesQwenIntoLegacyVisibilityOnlyCustomization() {
        defaults.set(
            [
                KeysProviderViewItem.openAI.rawValue
            ],
            forKey: AppViewModel.visibleKeysProvidersDefaultsKey
        )

        let vm = AppViewModel(defaults: defaults)

        XCTAssertTrue(vm.keysProviderOrder.contains(.qwen))
        XCTAssertEqual(vm.visibleKeysProviders, [.openAI, .qwen, .nineRouter])
        XCTAssertTrue(defaults.bool(forKey: AppViewModel.didMigrateQwenVisibleProviderDefaultsKey))
    }

    func testKeysProviderCustomizationRespectsQwenHiddenAfterMigration() {
        defaults.set(
            [
                KeysProviderViewItem.openAI.rawValue,
                KeysProviderViewItem.qwen.rawValue,
                "github-copilot"
            ],
            forKey: AppViewModel.keysProviderOrderDefaultsKey
        )
        defaults.set(
            [
                KeysProviderViewItem.openAI.rawValue
            ],
            forKey: AppViewModel.visibleKeysProvidersDefaultsKey
        )
        defaults.set(true, forKey: AppViewModel.didMigrateQwenVisibleProviderDefaultsKey)
        defaults.set(true, forKey: AppViewModel.didMigrateNineRouterVisibleProviderDefaultsKey)

        let vm = AppViewModel(defaults: defaults)

        XCTAssertTrue(vm.keysProviderOrder.contains(.qwen))
        XCTAssertFalse(vm.visibleKeysProviders.contains(.qwen))
        XCTAssertEqual(vm.visibleKeysProviders, [.openAI])
    }

    func testKeysProviderCustomizationRespectsQwenHiddenAfterVisibilityOnlyMigration() {
        defaults.set(
            [
                KeysProviderViewItem.openAI.rawValue
            ],
            forKey: AppViewModel.visibleKeysProvidersDefaultsKey
        )
        defaults.set(true, forKey: AppViewModel.didMigrateQwenVisibleProviderDefaultsKey)
        defaults.set(true, forKey: AppViewModel.didMigrateNineRouterVisibleProviderDefaultsKey)

        let vm = AppViewModel(defaults: defaults)

        XCTAssertTrue(vm.keysProviderOrder.contains(.qwen))
        XCTAssertFalse(vm.visibleKeysProviders.contains(.qwen))
        XCTAssertEqual(vm.visibleKeysProviders, [.openAI])
    }


    func testMoveKeysProviderReordersRowsWithBounds() {
        let vm = AppViewModel(defaults: defaults)

        vm.moveKeysProvider(.qwen, up: true)

        guard let qwenIndex = vm.keysProviderOrder.firstIndex(of: .qwen),
              let miniMaxCNIndex = vm.keysProviderOrder.firstIndex(of: .miniMaxCN) else {
            XCTFail("Expected Qwen and MiniMax CN in provider customization order")
            return
        }
        XCTAssertLessThan(qwenIndex, miniMaxCNIndex)

        let first = vm.keysProviderOrder.first
        if let firstProvider = first?.provider {
            vm.moveKeysProvider(firstProvider, up: true)
        }
        XCTAssertEqual(vm.keysProviderOrder.first, first)
    }

    func testQwenUsesInternationalModelStudioAPIKeyPageURLByDefault() throws {
        let url = try XCTUnwrap(UpstreamProvider.qwen.apiKeyPageURL)

        XCTAssertEqual(url.absoluteString, "https://modelstudio.console.alibabacloud.com/?tab=api#/api-key")
    }

    func testQwenAPIKeyPageURLFollowsSelectedEndpointRegion() throws {
        let vm = AppViewModel(defaults: defaults)

        XCTAssertEqual(
            vm.apiKeyPageURL(for: .qwen)?.absoluteString,
            "https://modelstudio.console.alibabacloud.com/?tab=api#/api-key"
        )
        XCTAssertEqual(
            vm.apiKeyRegionHint(for: .qwen),
            "International DashScope endpoint selected. Use an Alibaba Cloud Model Studio key from Singapore or another matching non-China region."
        )

        defaults.set(
            "https://dashscope.aliyuncs.com/compatible-mode/v1",
            forKey: "proxypilot.upstreamAPIBaseURL.\(UpstreamProvider.qwen.rawValue)"
        )

        XCTAssertEqual(
            vm.apiKeyPageURL(for: .qwen)?.absoluteString,
            "https://dashscope.console.aliyun.com/apiKey"
        )
        XCTAssertEqual(
            vm.apiKeyRegionHint(for: .qwen),
            "China (Beijing) DashScope endpoint selected. Use a China-region Model Studio API key."
        )
    }

    func testResetAllViewCustomizationsRestoresViewDefaultsWithoutNuclearReset() {
        let vm = AppViewModel(defaults: defaults)
        vm.appearancePreference = .dark
        vm.proxyPilotAccentHex = "#FF2D55"
        vm.liquidGlassEnabled = false
        vm.dockTileInteractiveEnabled = true
        vm.showMenuBarExtra = false
        vm.menuBarSectionOrder = [.quickActions, .statusDetails, .updates, .modelPicker, .sessionStats]
        vm.visibleMenuBarSections = [.statusDetails]
        vm.visibleHomeDashboardSections = [.sessionSummary]
        vm.defaultSettingsSection = .customization
        vm.keysProviderOrder = [.openAI, .zAI, .openRouter, .xAI, .chutes, .groq, .google, .deepSeek, .mistral, .miniMax, .miniMaxCN, .qwen, .nineRouter, .ollama, .lmStudio]
        vm.visibleKeysProviders = [.openAI]

        vm.resetAllViewCustomizations()

        XCTAssertEqual(vm.appearancePreference, .system)
        XCTAssertEqual(vm.proxyPilotAccentHex, ProxyPilotAccentColor.defaultHex)
        XCTAssertTrue(vm.liquidGlassEnabled)
        XCTAssertFalse(vm.dockTileInteractiveEnabled)
        XCTAssertTrue(vm.showMenuBarExtra)
        XCTAssertEqual(vm.menuBarSectionOrder, MenuBarSection.defaultOrder)
        XCTAssertEqual(vm.visibleMenuBarSections, Set(MenuBarSection.defaultOrder))
        XCTAssertEqual(vm.visibleHomeDashboardSections, Set(HomeDashboardSection.allCases))
        XCTAssertEqual(vm.defaultSettingsSection, .home)
        XCTAssertEqual(vm.keysProviderOrder, KeysProviderViewItem.defaultOrder)
        XCTAssertEqual(vm.visibleKeysProviders, Set(KeysProviderViewItem.defaultOrder))
    }

    func testLocalProviderFetchFailureDoesNotOfferAPIKeyAction() async {
        let vm = AppViewModel(defaults: defaults)
        vm.upstreamProvider = .lmStudio
        vm.upstreamAPIBaseURLString = "http://127.0.0.1:59999/v1"

        await vm.fetchUpstreamModels()

        XCTAssertEqual(vm.activeIssue?.title, "Upstream Model Fetch Failed")
        XCTAssertTrue(vm.activeIssue?.message.contains("LM Studio") == true)
        XCTAssertTrue(vm.activeIssue?.message.contains("http://127.0.0.1:59999/v1/models") == true)
        XCTAssertFalse(vm.activeIssue?.actions.contains(.openUpstreamKeyEditor) == true)
        XCTAssertTrue(vm.activeIssue?.actions.contains(.resetUpstreamURL) == true)
    }

    func testSyncProxyModelsFromLocalSelectionUsesBuiltInRestartPath() async {
        let vm = AppViewModel(defaults: defaults)
        vm.proxyURLString = "http://127.0.0.1:41017"
        vm.upstreamProvider = .ollama
        vm.upstreamModels = [
            UpstreamModel(id: "qwen2.5-coder:0.5b", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil)
        ]
        vm.selectedUpstreamModels = ["qwen2.5-coder:0.5b"]

        await vm.syncProxyModelsFromSelection()

        XCTAssertNil(vm.activeIssue)
        XCTAssertTrue(vm.isRunning)
        await vm.stopProxy()
    }

    func testStoredOpenRouterModelIsUsedWithoutLiveFetch() {
        defaults.set(
            UpstreamProvider.openRouter.rawValue,
            forKey: "proxypilot.upstreamProvider"
        )
        defaults.set(
            "qwen/qwen-2.5-coder-32b-instruct",
            forKey: "proxypilot.xcodeAgentModel.openrouter"
        )

        let vm = AppViewModel(defaults: defaults)

        XCTAssertEqual(vm.upstreamProvider, .openRouter)
        XCTAssertEqual(vm.effectiveXcodeAgentModel, "qwen/qwen-2.5-coder-32b-instruct")
        XCTAssertTrue(vm.xcodeAgentModelCandidates.contains("qwen/qwen-2.5-coder-32b-instruct"))
        XCTAssertTrue(vm.proxySyncModelCandidates.contains("qwen/qwen-2.5-coder-32b-instruct"))
        XCTAssertTrue(vm.canSyncProxyModels)
    }

    func testXcodeAgentModelSelectionIsStoredPerProvider() {
        let vm = AppViewModel(defaults: defaults)
        vm.selectedXcodeAgentModel = "glm-4.7"

        vm.upstreamProvider = .openRouter
        vm.selectedXcodeAgentModel = "qwen/qwen-2.5-coder-32b-instruct"

        vm.upstreamProvider = .zAI
        XCTAssertEqual(vm.selectedXcodeAgentModel, "glm-4.7")

        vm.upstreamProvider = .openRouter
        XCTAssertEqual(vm.selectedXcodeAgentModel, "qwen/qwen-2.5-coder-32b-instruct")
    }

    func testLocalProviderWithoutModelsDoesNotInheritLegacyCloudAgentModel() {
        defaults.set("glm-5.1", forKey: ProviderManager.xcodeAgentModelLegacyDefaultsKey)
        let vm = AppViewModel(defaults: defaults)

        vm.upstreamProvider = .lmStudio

        XCTAssertTrue(vm.xcodeAgentModelCandidates.isEmpty)
        XCTAssertEqual(vm.effectiveXcodeAgentModel, "")
    }

    func testHomeAgentModelBadgeUsesActiveRunningModelWhenSelectionChanges() {
        let vm = AppViewModel(defaults: defaults)
        vm.selectedXcodeAgentModel = "glm-5.1"
        vm.localProxyState.isRunning = true
        vm.localProxyState.activeXcodeAgentModel = "glm-4.5"

        XCTAssertTrue(vm.hasPendingXcodeAgentModelChange)
        XCTAssertEqual(vm.homeAgentModelBadgeTitle, "glm-4.5")
        XCTAssertTrue(vm.homeAgentModelBadgeHelpText.contains("glm-5.1"))
        XCTAssertTrue(vm.xcodeAgentRoutingSummaryText.contains("Live route still uses glm-4.5"))
        XCTAssertEqual(vm.xcodeAgentSelectedModelText, "glm-5.1")
        XCTAssertEqual(vm.xcodeAgentPendingModelText, "glm-5.1")
        XCTAssertEqual(vm.xcodeAgentAppliedModelText, "glm-4.5")
    }

    func testHomeAgentModelBadgeUsesSelectedModelWhenStopped() {
        let vm = AppViewModel(defaults: defaults)
        vm.selectedXcodeAgentModel = "glm-5.1"
        vm.localProxyState.isRunning = false
        vm.localProxyState.activeXcodeAgentModel = "glm-4.5"

        XCTAssertFalse(vm.hasPendingXcodeAgentModelChange)
        XCTAssertEqual(vm.homeAgentModelBadgeTitle, "glm-5.1")
        XCTAssertEqual(vm.xcodeAgentAppliedModelText, "Not applied until proxy start")
        XCTAssertTrue(vm.xcodeAgentRoutingSummaryText.contains("will apply the next time ProxyPilot starts or restarts"))
    }

    func testXcodeAgentLiveProofTextShowsLastRequestModelStatusAndTime() {
        let vm = AppViewModel(defaults: defaults)
        vm.localProxyState.lastXcodeAgentRequestModel = "qwen2.5-coder:0.5b"
        vm.localProxyState.lastXcodeAgentRequestStatus = 200
        vm.localProxyState.lastXcodeAgentRequestAt = Date(timeIntervalSince1970: 1_778_544_228)

        XCTAssertTrue(vm.xcodeAgentLiveProofText.contains("qwen2.5-coder:0.5b"))
        XCTAssertTrue(vm.xcodeAgentLiveProofText.contains("200 OK"))
        XCTAssertTrue(vm.xcodeAgentLiveProofText.contains("Last Xcode Agent request"))
    }

    func testXcodeAgentLiveProofTextHasEmptyState() {
        let vm = AppViewModel(defaults: defaults)

        XCTAssertEqual(vm.xcodeAgentLiveProofText, "No Xcode Agent request observed in this ProxyPilot session yet.")
    }

    func testContextualTerminologyHelpExplainsDenseTerms() {
        let vm = AppViewModel(defaults: defaults)

        XCTAssertTrue(vm.contextualTerminologyHelpText.contains("Proxy:"))
        XCTAssertTrue(vm.contextualTerminologyHelpText.contains("Upstream:"))
        XCTAssertTrue(vm.contextualTerminologyHelpText.contains("OpenAI-compatible:"))
        XCTAssertTrue(vm.contextualTerminologyHelpText.contains("/v1/models:"))
        XCTAssertTrue(vm.contextualTerminologyHelpText.contains("Anthropic translator mode:"))
    }

    func testXcodeVisibleModelsUsesPendingSettingsWhenProxyStopped() async {
        let vm = AppViewModel(defaults: defaults)
        vm.selectedUpstreamModels = ["model-b", "model-a"]
        vm.selectedXcodeAgentModel = "model-c"
        vm.localProxyState.isRunning = false

        await vm.refreshXcodeVisibleModels()

        XCTAssertEqual(vm.xcodeVisibleModelsSnapshot.source, .pendingSettings)
        XCTAssertEqual(vm.xcodeVisibleModelsSnapshot.modelIDs, ["model-a", "model-b", "model-c"])
        XCTAssertFalse(vm.xcodeVisibleModelsSnapshot.reflectsRunningProxy)
        XCTAssertTrue(vm.xcodeVisibleModelsStatusText.contains("Proxy is not running"))
    }

    func testProxyRuntimeStatusCopyDistinguishesOnlyExternalCLI() {
        XCTAssertEqual(AppViewModel.statusText(for: .runningInApp), "Running")
        XCTAssertEqual(AppViewModel.statusText(for: .runningExternal), "Running in background")
        XCTAssertEqual(AppViewModel.statusText(for: .stopped), "Stopped")
        XCTAssertEqual(AppViewModel.statusText(for: .portOccupied(statusCode: 418)), "Port occupied by another service (HTTP 418)")
    }

    func testToolbarProxyStatusDistinguishesGUICLIAndRepoGPSOwnership() {
        XCTAssertEqual(
            AppViewModel.toolbarProxyStatus(for: .runningInApp, repoGPSActive: false),
            .init(kind: .gui, compactText: "Running", fullText: "Proxy running in app")
        )
        XCTAssertEqual(
            AppViewModel.toolbarProxyStatus(for: .runningExternal, repoGPSActive: false),
            .init(kind: .cli, compactText: "Running", fullText: "Proxy running in background")
        )
        XCTAssertEqual(
            AppViewModel.toolbarProxyStatus(for: .runningExternal, repoGPSActive: true),
            .init(kind: .repoGPS, compactText: "RepoGPS", fullText: "RepoGPS in flight")
        )
        XCTAssertEqual(
            AppViewModel.toolbarProxyStatus(
                for: .runningExternal,
                repoGPSActive: false,
                repoGPSLeasePresent: true
            ),
            .init(kind: .cli, compactText: "Running", fullText: "Proxy running in background")
        )
    }

    func testToolbarProxyStatusCoversStoppedAndConflictStates() {
        XCTAssertEqual(
            AppViewModel.toolbarProxyStatus(for: .stopped, repoGPSActive: false),
            .init(kind: .stopped, compactText: "Stopped", fullText: "Stopped")
        )
        XCTAssertEqual(
            AppViewModel.toolbarProxyStatus(for: .portOccupied(statusCode: 418), repoGPSActive: false),
            .init(kind: .issue, compactText: "Conflict", fullText: "Port occupied by another service (HTTP 418)")
        )
    }

    func testExternalCLIProxyScopesXcodeRouteAsInactive() {
        let vm = AppViewModel(defaults: defaults)

        vm.applyProxyRuntimeStatus(.runningExternal)

        XCTAssertEqual(vm.xcodeAgentAppliedModelText, "Not verified — proxy is running in background")
    }

    func testExternalCLIProxyCanBeStoppedFromGUI() {
        XCTAssertTrue(AppViewModel.canStopProxy(for: .runningExternal))
        XCTAssertTrue(AppViewModel.canStopProxy(for: .runningInApp))
        XCTAssertFalse(AppViewModel.canStopProxy(for: .runningExternal, isStoppingCLIProxy: true))
        XCTAssertFalse(AppViewModel.canStopProxy(for: .stopped))
    }

    func testStartRecoversAfterPortConflictWithoutRelaunch() async throws {
        let occupied = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(occupied, 0)
        var isOpen = true
        defer { if isOpen { close(occupied) } }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(occupied, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(occupied, 1), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(occupied, $0, &length)
            }
        }
        let port = UInt16(bigEndian: address.sin_port)
        let vm = AppViewModel(defaults: defaults)
        vm.proxyURLString = "http://127.0.0.1:\(port)"
        vm.upstreamProvider = .ollama
        vm.selectedXcodeAgentModel = "test-model"
        await vm.startProxy()
        XCTAssertEqual(vm.activeIssue?.code, .portInUse)
        close(occupied)
        isOpen = false
        await vm.startProxy()
        XCTAssertNil(vm.activeIssue)
        XCTAssertTrue(vm.isRunning)
        await vm.stopProxy()
    }

    func testRestartDoesNotReplaceBackgroundProxyWhenStopFails() async {
        var stops = 0
        let vm = AppViewModel(
            defaults: defaults,
            cliExecutableResolver: { URL(fileURLWithPath: "/test/proxypilot") },
            cliStopRunner: { _, _ in
                stops += 1
                return AppViewModel.CLIUpdateExecutionResult(
                    terminationStatus: 1, stdout: "", stderr: "Cannot stop owned process"
                )
            }
        )
        vm.applyProxyRuntimeStatus(.runningExternal)
        XCTAssertTrue(vm.canRestartProxy)
        await vm.restartProxy()
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(vm.proxyRuntimeStatus, .runningExternal)
        XCTAssertEqual(vm.statusText, "Running in background")
    }

    func testStopProxyRunsInstalledCLIWhenExternalProxyIsRunning() async {
        let cliURL = URL(fileURLWithPath: "/usr/local/bin/proxypilot")
        var requestedPort: UInt16?
        var requestedURL: URL?
        let vm = AppViewModel(
            defaults: defaults,
            cliExecutableResolver: { cliURL },
            cliStopRunner: { executableURL, port in
                requestedURL = executableURL
                requestedPort = port
                return AppViewModel.CLIUpdateExecutionResult(
                    terminationStatus: 0,
                    stdout: #"{"ok":true,"data":{"status":"stopped_discovered","pid":1234}}"#,
                    stderr: ""
                )
            }
        )
        vm.proxyURLString = "http://127.0.0.1:45123"
        vm.applyProxyRuntimeStatus(.runningExternal)

        await vm.stopProxy()

        XCTAssertEqual(requestedURL, cliURL)
        XCTAssertEqual(requestedPort, 45123)
        XCTAssertEqual(vm.proxyRuntimeStatus, .stopped)
        XCTAssertEqual(vm.statusText, "Stopped")
        XCTAssertFalse(vm.isStoppingCLIProxy)
    }

    func testPreflightUsesAutomaticCredentialWhenUpstreamCredentialStored() {
        let preflight = PreflightService()
        let context = PreflightContext(
            proxyURLString: "http://127.0.0.1:4000",
            useBuiltInProxy: true,
            requireLocalAuth: false,
            upstreamProvider: .zAI,
            upstreamAPIBaseURLString: "https://api.z.ai/api/coding/paas/v4",
            fallbackUpstreamBaseURLString: "https://api.z.ai/api/coding/paas/v4",
            hasMasterKey: false,
            hasUpstreamKey: true
        )

        let results = preflight.run(context: context)
        let masterKeyCheck = results.first { $0.id == "master_key" }

        XCTAssertEqual(masterKeyCheck?.status, .info)
        XCTAssertEqual(masterKeyCheck?.fixAction, PreflightFixAction.none)
        XCTAssertEqual(
            masterKeyCheck?.detail,
            "ProxyPilot will create an automatic local client credential when the proxy starts."
        )
    }

    func testPreflightLocalProviderDoesNotRequireAPIKey() {
        let preflight = PreflightService()
        let context = PreflightContext(
            proxyURLString: "http://127.0.0.1:4000",
            useBuiltInProxy: true,
            requireLocalAuth: false,
            upstreamProvider: .ollama,
            upstreamAPIBaseURLString: "http://localhost:11434/v1",
            fallbackUpstreamBaseURLString: "http://localhost:11434/v1",
            hasMasterKey: false,
            hasUpstreamKey: false
        )

        let results = preflight.run(context: context)
        let keyCheck = results.first { $0.id == "upstream_key" }
        let reachability = results.first { $0.id == "local_provider_reachability" }

        XCTAssertEqual(keyCheck?.status, .info)
        XCTAssertEqual(keyCheck?.fixAction, PreflightFixAction.none)
        XCTAssertNotNil(reachability)
        XCTAssertTrue(reachability?.detail.contains("Ollama") == true)
    }

    func testPreflight9RouterShowsReachabilityHintWithoutRequiredKey() {
        let preflight = PreflightService()
        let context = PreflightContext(
            proxyURLString: "http://127.0.0.1:4000",
            useBuiltInProxy: true,
            requireLocalAuth: false,
            upstreamProvider: .nineRouter,
            upstreamAPIBaseURLString: "http://127.0.0.1:59999/v1",
            fallbackUpstreamBaseURLString: "http://localhost:20128/v1",
            hasMasterKey: false,
            hasUpstreamKey: false
        )

        let results = preflight.run(context: context)
        let keyCheck = results.first { $0.id == "upstream_key" }
        let reachability = results.first { $0.id == "local_provider_reachability" }

        XCTAssertEqual(keyCheck?.status, .info)
        XCTAssertEqual(keyCheck?.fixAction, PreflightFixAction.none)
        XCTAssertEqual(reachability?.status, .warning)
        XCTAssertTrue(reachability?.detail.contains("9Router is not listening") == true)
    }

    // MARK: - Saved Default Models

    func testSavedDefaultModelsEmptyOnFirstLaunch() {
        let vm = AppViewModel(defaults: defaults)
        XCTAssertTrue(vm.savedDefaultModels.isEmpty)
        XCTAssertFalse(vm.hasSavedDefaultModels)
    }

    func testSaveSelectedModelsAsDefaults() {
        let vm = AppViewModel(defaults: defaults)
        vm.upstreamModels = [
            UpstreamModel(id: "model-c", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
            UpstreamModel(id: "model-a", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
        ]
        vm.selectedUpstreamModels = ["model-a", "model-c"]

        vm.saveSelectedModelsAsDefaults()

        let saved = defaults.stringArray(forKey: "proxypilot.defaultModels.zai") ?? []
        XCTAssertEqual(saved, ["model-a", "model-c"])
        XCTAssertTrue(vm.hasSavedDefaultModels)
    }

    func testSavedDefaultModelsLoadPerProvider() {
        defaults.set(["glm-5"], forKey: "proxypilot.defaultModels.zai")
        defaults.set(["grok-3"], forKey: "proxypilot.defaultModels.xai")

        let vm = AppViewModel(defaults: defaults)
        XCTAssertEqual(vm.savedDefaultModels, ["glm-5"])

        vm.upstreamProvider = .xAI
        XCTAssertEqual(vm.savedDefaultModels, ["grok-3"])
    }

    func testSelectAllAndClearSelection() {
        let vm = AppViewModel(defaults: defaults)
        vm.upstreamModels = [
            UpstreamModel(id: "a", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
            UpstreamModel(id: "b", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
            UpstreamModel(id: "c", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
        ]
        vm.selectedUpstreamModels = []

        vm.selectAllUpstreamModels()
        XCTAssertEqual(vm.selectedUpstreamModels, ["a", "b", "c"])

        vm.clearUpstreamModelSelection()
        XCTAssertTrue(vm.selectedUpstreamModels.isEmpty)
    }

    func testFetchedModelsKeepSavedDefaultsPinnedAndVisible() {
        defaults.set(["default-live", "default-missing"], forKey: ProviderManager.defaultModelsKey(for: .zAI))
        let manager = makeProviderManager()

        manager.applyFetchedUpstreamModels([
            UpstreamModel(id: "default-live", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
            UpstreamModel(id: "live-extra", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
        ])

        XCTAssertTrue(manager.isDefaultModel("default-live"))
        XCTAssertTrue(manager.isDefaultModel("default-missing"))
        XCTAssertTrue(manager.isModelSelected("default-live"))
        XCTAssertTrue(manager.isModelSelected("default-missing"))
        XCTAssertTrue(manager.modelSelectionRows.contains { $0.id == "default-missing" && !$0.isLive && $0.isDefault })
    }

    func testDefaultRowsCannotBeDeselected() {
        defaults.set(["pinned-model"], forKey: ProviderManager.defaultModelsKey(for: .zAI))
        let manager = makeProviderManager()
        manager.applyFetchedUpstreamModels([
            UpstreamModel(id: "pinned-model", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
        ])

        manager.setModelSelected("pinned-model", isSelected: false)

        XCTAssertTrue(manager.isModelSelected("pinned-model"))
        XCTAssertTrue(manager.selectedUpstreamModels.contains("pinned-model"))
    }

    func testClearSelectionKeepsDefaultModels() {
        defaults.set(["pinned-model"], forKey: ProviderManager.defaultModelsKey(for: .zAI))
        let manager = makeProviderManager()
        manager.applyFetchedUpstreamModels([
            UpstreamModel(id: "pinned-model", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
            UpstreamModel(id: "optional-model", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
        ])
        manager.setModelSelected("optional-model", isSelected: true)

        manager.clearUpstreamModelSelection()

        XCTAssertTrue(manager.isModelSelected("pinned-model"))
        XCTAssertFalse(manager.isModelSelected("optional-model"))
        XCTAssertEqual(manager.selectedUpstreamModels, ["pinned-model"])
    }

    func testLocalProviderAutoSelectsAllFetchedModelsOnFetch() {
        let manager = makeProviderManager()
        manager.upstreamProvider = .ollama

        manager.applyFetchedUpstreamModels([
            UpstreamModel(id: "llama3:8b", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
            UpstreamModel(id: "qwen2.5-coder:7b", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
        ])

        XCTAssertTrue(manager.isModelSelected("llama3:8b"))
        XCTAssertTrue(manager.isModelSelected("qwen2.5-coder:7b"))
        XCTAssertEqual(manager.selectedUpstreamModels, ["llama3:8b", "qwen2.5-coder:7b"])
    }

    func testCloudProviderDoesNotAutoSelectFetchedModels() {
        let manager = makeProviderManager()
        // defaults to .zAI — cloud provider, requiresAPIKey=true, isLocal=false

        manager.applyFetchedUpstreamModels([
            UpstreamModel(id: "expensive-cloud-a", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
            UpstreamModel(id: "expensive-cloud-b", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
        ])

        XCTAssertTrue(manager.selectedUpstreamModels.isEmpty)
    }

    func testSaveDefaultsPromotesSelectedVisibleModels() {
        defaults.set(["existing-default"], forKey: ProviderManager.defaultModelsKey(for: .zAI))
        let manager = makeProviderManager()
        manager.applyFetchedUpstreamModels([
            UpstreamModel(id: "existing-default", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
            UpstreamModel(id: "new-default", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
        ])
        manager.setModelSelected("new-default", isSelected: true)

        manager.saveSelectedModelsAsDefaults()

        XCTAssertEqual(defaults.stringArray(forKey: ProviderManager.defaultModelsKey(for: .zAI)), ["existing-default", "new-default"])
        XCTAssertTrue(manager.isDefaultModel("new-default"))
    }

    func testRemoveDefaultModelExplicitlyUnpinsAndDeselects() {
        defaults.set(["pinned-model"], forKey: ProviderManager.defaultModelsKey(for: .zAI))
        let manager = makeProviderManager()
        manager.applyFetchedUpstreamModels([
            UpstreamModel(id: "pinned-model", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
        ])

        manager.removeDefaultModel("pinned-model")

        XCTAssertFalse(manager.isDefaultModel("pinned-model"))
        XCTAssertFalse(manager.isModelSelected("pinned-model"))
        XCTAssertEqual(defaults.stringArray(forKey: ProviderManager.defaultModelsKey(for: .zAI)), [])
    }

    func testDefaultModelPinsAreProviderScoped() {
        defaults.set(["zai-default"], forKey: ProviderManager.defaultModelsKey(for: .zAI))
        defaults.set(["openrouter-default"], forKey: ProviderManager.defaultModelsKey(for: .openRouter))
        let manager = makeProviderManager()

        XCTAssertTrue(manager.isDefaultModel("zai-default"))
        XCTAssertFalse(manager.isDefaultModel("openrouter-default"))

        manager.upstreamProvider = .openRouter

        XCTAssertFalse(manager.isDefaultModel("zai-default"))
        XCTAssertTrue(manager.isDefaultModel("openrouter-default"))
    }

    func testExactoFilterShowsToolCapableModelsAsExactoVariantsForOpenRouter() {
        let vm = AppViewModel(defaults: defaults)
        vm.upstreamProvider = .openRouter
        vm.upstreamModels = [
            UpstreamModel(id: "anthropic/claude-opus-4", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil, supportedParameters: ["tools"]),
            UpstreamModel(id: "meta/llama-3", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
            UpstreamModel(id: "google/gemini-3.1-pro:exacto", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
        ]
        vm.exactoFilterEnabled = true

        XCTAssertEqual(vm.filteredUpstreamModels.count, 2)
        XCTAssertEqual(vm.filteredUpstreamModels.map(\.id), [
            "anthropic/claude-opus-4:exacto",
            "google/gemini-3.1-pro:exacto"
        ])
    }

    func testExactoFilterDisabledShowsAllModels() {
        let vm = AppViewModel(defaults: defaults)
        vm.upstreamProvider = .openRouter
        vm.upstreamModels = [
            UpstreamModel(id: "anthropic/claude-opus-4:exacto", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
            UpstreamModel(id: "anthropic/claude-opus-4", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
        ]
        vm.exactoFilterEnabled = false

        XCTAssertEqual(vm.filteredUpstreamModels.count, 2)
    }

    func testExactoFilterIgnoredForNonOpenRouterProviders() {
        let vm = AppViewModel(defaults: defaults)
        vm.upstreamProvider = .zAI
        vm.upstreamModels = [
            UpstreamModel(id: "model-a", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
            UpstreamModel(id: "model-b", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
        ]
        vm.exactoFilterEnabled = true

        XCTAssertEqual(vm.filteredUpstreamModels.count, 2)
    }

    func testSelectAllRespectsExactoFilter() {
        let vm = AppViewModel(defaults: defaults)
        vm.upstreamProvider = .openRouter
        vm.upstreamModels = [
            UpstreamModel(id: "anthropic/claude-opus-4", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil, supportedParameters: ["tools"]),
            UpstreamModel(id: "meta/llama-3", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
        ]
        vm.exactoFilterEnabled = true
        vm.selectedUpstreamModels = []

        vm.selectAllUpstreamModels()
        XCTAssertEqual(vm.selectedUpstreamModels, ["anthropic/claude-opus-4:exacto"])
        XCTAssertEqual(vm.effectiveXcodeAgentModel, "anthropic/claude-opus-4:exacto")
    }

    func testExactoFilterPersistence() {
        defaults.set(false, forKey: "proxypilot.openrouter.exactoFilter")
        let vm = AppViewModel(defaults: defaults)
        XCTAssertFalse(vm.exactoFilterEnabled)
    }

    func testProxySyncFallsBackToSavedDefaults() {
        defaults.set(["saved-model-1", "saved-model-2"], forKey: "proxypilot.defaultModels.zai")
        let vm = AppViewModel(defaults: defaults)

        XCTAssertTrue(vm.proxySyncModelCandidates.contains("saved-model-1"))
        XCTAssertTrue(vm.proxySyncModelCandidates.contains("saved-model-2"))
    }

    func testProxySyncPreservesSelectedVirtualExactoIdentity() {
        defaults.set(UpstreamProvider.openRouter.rawValue, forKey: ProviderManager.upstreamProviderDefaultsKey)
        let vm = AppViewModel(defaults: defaults)
        vm.exactoFilterEnabled = true
        vm.upstreamModels = [
            UpstreamModel(
                id: "anthropic/claude:foo",
                contextLength: nil,
                promptPricePer1M: nil,
                completionPricePer1M: nil,
                supportedParameters: ["tools"]
            )
        ]
        vm.selectedUpstreamModels = ["anthropic/claude:foo:exacto"]

        XCTAssertEqual(vm.proxySyncModelCandidates, ["anthropic/claude:foo:exacto"])
        XCTAssertTrue(vm.canSyncProxyModels)
    }

    func testProxySyncKeepsDefaultsWhilePreservingVirtualExactoSelection() {
        defaults.set(UpstreamProvider.openRouter.rawValue, forKey: ProviderManager.upstreamProviderDefaultsKey)
        defaults.set(
            ["saved-default"],
            forKey: ProviderManager.defaultModelsKey(for: .openRouter)
        )
        let vm = AppViewModel(defaults: defaults)
        vm.exactoFilterEnabled = true
        vm.upstreamModels = [
            UpstreamModel(
                id: "anthropic/claude:foo",
                contextLength: nil,
                promptPricePer1M: nil,
                completionPricePer1M: nil,
                supportedParameters: ["tools"]
            )
        ]
        vm.selectedUpstreamModels = ["anthropic/claude:foo:exacto", "saved-default"]

        XCTAssertEqual(
            Set(vm.proxySyncModelCandidates),
            ["anthropic/claude:foo:exacto", "saved-default"]
        )
        XCTAssertFalse(vm.proxySyncModelCandidates.contains("anthropic/claude:foo"))
    }

    func testProxySyncPreservesExplicitExactoCatalogIdentity() {
        defaults.set(UpstreamProvider.openRouter.rawValue, forKey: ProviderManager.upstreamProviderDefaultsKey)
        let vm = AppViewModel(defaults: defaults)
        vm.exactoFilterEnabled = true
        vm.upstreamModels = [
            UpstreamModel(
                id: "openai/gpt:exacto",
                contextLength: nil,
                promptPricePer1M: nil,
                completionPricePer1M: nil,
                supportedParameters: ["tools"]
            )
        ]
        vm.selectedUpstreamModels = ["openai/gpt:exacto"]

        XCTAssertEqual(vm.proxySyncModelCandidates, ["openai/gpt:exacto"])
    }

    func testCanSyncFalseWithNoModelsConfigured() {
        let vm = AppViewModel(defaults: defaults)
        vm.selectedXcodeAgentModel = ""
        XCTAssertFalse(vm.canSyncProxyModels)
    }

    func testNoGenericGPTFallbackWithoutSavedOrProviderFallbackModels() {
        let vm = AppViewModel(defaults: defaults)

        XCTAssertEqual(vm.upstreamProvider, .zAI)
        XCTAssertEqual(vm.effectiveXcodeAgentModel, "")
        XCTAssertTrue(vm.xcodeAgentModelCandidates.isEmpty)
        XCTAssertFalse(vm.canSyncProxyModels)
    }

    func testMiniMaxFallsBackToKnownProviderModelsWithoutLiveFetch() {
        defaults.set(
            UpstreamProvider.miniMax.rawValue,
            forKey: "proxypilot.upstreamProvider"
        )

        let vm = AppViewModel(defaults: defaults)

        XCTAssertEqual(vm.upstreamProvider, .miniMax)
        XCTAssertEqual(vm.effectiveXcodeAgentModel, "MiniMax-M2.7")
        XCTAssertTrue(vm.xcodeAgentModelCandidates.contains("MiniMax-M2.7"))
        XCTAssertTrue(vm.proxySyncModelCandidates.contains("MiniMax-M2.7"))
        XCTAssertTrue(vm.canSyncProxyModels)
    }

    func testMiniMaxCNFallsBackToKnownProviderModelsWithoutLiveFetch() {
        defaults.set(
            UpstreamProvider.miniMaxCN.rawValue,
            forKey: "proxypilot.upstreamProvider"
        )

        let vm = AppViewModel(defaults: defaults)

        XCTAssertEqual(vm.upstreamProvider, .miniMaxCN)
        XCTAssertEqual(vm.effectiveXcodeAgentModel, "MiniMax-M2.7")
        XCTAssertTrue(vm.xcodeAgentModelCandidates.contains("MiniMax-M2.7"))
        XCTAssertTrue(vm.proxySyncModelCandidates.contains("MiniMax-M2.7"))
        XCTAssertTrue(vm.canSyncProxyModels)
    }

    func testRetiredProviderStoredSelectionFallsBackToDefault() {
        defaults.set("github-copilot", forKey: ProviderManager.upstreamProviderDefaultsKey)

        let vm = AppViewModel(defaults: defaults)

        XCTAssertEqual(vm.upstreamProvider, .zAI)
        XCTAssertEqual(defaults.string(forKey: ProviderManager.upstreamProviderDefaultsKey), UpstreamProvider.zAI.rawValue)
    }

    // MARK: - MiniMax Routing Mode (v1.4.16)

    func testMiniMaxRoutingModeDefaultsToStandard() {
        let vm = AppViewModel(defaults: defaults)
        XCTAssertEqual(vm.miniMaxRoutingMode, .standard)
    }

    func testMiniMaxRoutingModePersistsAcrossInit() {
        defaults.set(
            MiniMaxRoutingMode.anthropicPassthrough.rawValue,
            forKey: ProviderManager.miniMaxRoutingModeDefaultsKey
        )
        let vm = AppViewModel(defaults: defaults)
        XCTAssertEqual(vm.miniMaxRoutingMode, .anthropicPassthrough)
    }

    // MARK: - Analytics Opt-In Prompt (v1.4.19)

    func testAnalyticsPromptShowsOnFirstLaunchAfterOnboarding() {
        // Simulate completed onboarding so the prompt isn't suppressed
        defaults.set(true, forKey: "proxypilot.didCompleteOnboarding")
        let vm = AppViewModel(defaults: defaults)
        XCTAssertFalse(vm.showOnboardingWizard)
        vm.maybeShowAnalyticsPrompt()
        XCTAssertEqual(vm.showAnalyticsPrompt, analyticsPromptAvailableInTestHost)
    }

    func testAnalyticsPromptDoesNotRepeatForSameVersion() {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        defaults.set(currentVersion, forKey: "proxypilot.analyticsPromptShownVersion")
        let vm = AppViewModel(defaults: defaults)
        vm.maybeShowAnalyticsPrompt()
        XCTAssertFalse(vm.showAnalyticsPrompt)
    }

    func testOnboardingTelemetryChoiceSuppressesFollowUpAnalyticsPrompt() {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        var vm: AppViewModel? = AppViewModel(defaults: defaults)
        XCTAssertTrue(vm?.showOnboardingWizard == true)

        vm?.telemetryOptIn = true
        vm?.finishOnboarding(force: true)
        XCTAssertEqual(defaults.string(forKey: "proxypilot.analyticsPromptShownVersion"), currentVersion)
        vm = nil

        let relaunched = AppViewModel(defaults: defaults)
        XCTAssertFalse(relaunched.showOnboardingWizard)
        relaunched.maybeShowAnalyticsPrompt()
        XCTAssertFalse(relaunched.showAnalyticsPrompt)
    }

    func testOnboardingTelemetryOptOutAllowsFollowUpAnalyticsPrompt() {
        var vm: AppViewModel? = AppViewModel(defaults: defaults)
        XCTAssertTrue(vm?.showOnboardingWizard == true)

        vm?.telemetryOptIn = false
        vm?.finishOnboarding(force: true)
        XCTAssertNil(defaults.string(forKey: "proxypilot.analyticsPromptShownVersion"))
        vm = nil

        let relaunched = AppViewModel(defaults: defaults)
        XCTAssertFalse(relaunched.showOnboardingWizard)
        relaunched.maybeShowAnalyticsPrompt()
        XCTAssertEqual(relaunched.showAnalyticsPrompt, analyticsPromptAvailableInTestHost)
    }

    func testAnalyticsPromptOptInSetsFlag() {
        let vm = AppViewModel(defaults: defaults)
        XCTAssertFalse(vm.telemetryOptIn)
        vm.dismissAnalyticsPrompt(optIn: true)
        XCTAssertTrue(vm.telemetryOptIn)
        XCTAssertFalse(vm.showAnalyticsPrompt)
        XCTAssertNotNil(defaults.string(forKey: "proxypilot.analyticsPromptShownVersion"))
    }

    func testAnalyticsPromptOptOutLeavesDisabled() {
        let vm = AppViewModel(defaults: defaults)
        vm.dismissAnalyticsPrompt(optIn: false)
        XCTAssertFalse(vm.telemetryOptIn)
        XCTAssertFalse(vm.showAnalyticsPrompt)
        XCTAssertNotNil(defaults.string(forKey: "proxypilot.analyticsPromptShownVersion"))
    }

    func testAnalyticsPromptSuppressedDuringOnboarding() {
        // Onboarding not completed → showOnboardingWizard = true → suppress analytics prompt
        let vm = AppViewModel(defaults: defaults)
        XCTAssertTrue(vm.showOnboardingWizard) // fresh defaults, onboarding not done
        vm.maybeShowAnalyticsPrompt()
        XCTAssertFalse(vm.showAnalyticsPrompt)
    }

    func testAppOpenedHealthHeartbeatIsSentWithoutAnalyticsOptIn() {
        var capturedEvents: [(name: String, properties: [String: String])] = []
        var attemptedPostHogRequests = 0
        let telemetryService = TelemetryService(
            defaults: defaults,
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true),
            postHogDeliveryEnabled: false,
            protectedInternalMarkerURL: nil,
            remoteCaptureHook: { name, properties in
                capturedEvents.append((name: name, properties: properties))
            },
            postHogRequestHook: { _ in
                attemptedPostHogRequests += 1
            }
        )

        _ = AppViewModel(defaults: defaults, telemetryService: telemetryService)

        XCTAssertEqual(capturedEvents.count, 1)
        XCTAssertEqual(capturedEvents[0].name, "app_opened")
        XCTAssertEqual(Set(capturedEvents[0].properties.keys), ["app_version", "build_number"])
        XCTAssertNotNil(capturedEvents[0].properties["app_version"])
        XCTAssertNotNil(capturedEvents[0].properties["build_number"])
        XCTAssertEqual(attemptedPostHogRequests, 0)
    }

    func testAppOpenedHealthHeartbeatMarksMicahInternalInstallWhenConfigured() {
        defaults.set(true, forKey: "proxypilot.telemetry.isMicah")
        var capturedEvents: [(name: String, properties: [String: String])] = []
        var attemptedPostHogRequests = 0
        let telemetryService = TelemetryService(
            defaults: defaults,
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true),
            postHogDeliveryEnabled: false,
            protectedInternalMarkerURL: nil,
            remoteCaptureHook: { name, properties in
                capturedEvents.append((name: name, properties: properties))
            },
            postHogRequestHook: { _ in
                attemptedPostHogRequests += 1
            }
        )

        _ = AppViewModel(defaults: defaults, telemetryService: telemetryService)

        XCTAssertEqual(capturedEvents.count, 1)
        XCTAssertEqual(capturedEvents[0].name, "app_opened")
        XCTAssertEqual(capturedEvents[0].properties["is_micah"], "true")
        XCTAssertNotNil(capturedEvents[0].properties["app_version"])
        XCTAssertNotNil(capturedEvents[0].properties["build_number"])
        XCTAssertEqual(attemptedPostHogRequests, 0)
    }

    func testAppOpenedHealthHeartbeatMarksMicahInternalInstallFromProtectedMarker() throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let markerURL = baseDirectory.appendingPathComponent("internal-telemetry-marker")
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try "is_micah=true\n".write(to: markerURL, atomically: true, encoding: .utf8)

        var capturedEvents: [(name: String, properties: [String: String])] = []
        let telemetryService = TelemetryService(
            defaults: defaults,
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true),
            postHogDeliveryEnabled: false,
            protectedInternalMarkerURL: markerURL,
            remoteCaptureHook: { name, properties in
                capturedEvents.append((name: name, properties: properties))
            }
        )

        _ = AppViewModel(defaults: defaults, telemetryService: telemetryService)

        XCTAssertEqual(capturedEvents.count, 1)
        XCTAssertEqual(capturedEvents[0].name, "app_opened")
        XCTAssertEqual(capturedEvents[0].properties["is_micah"], "true")
    }

    func testAppOpenedHealthHeartbeatBuildsPostHogCaptureRequestWhenStableKeyIsBundled() throws {
        var capturedRequests: [URLRequest] = []
        let telemetryService = TelemetryService(
            defaults: defaults,
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true),
            postHogDeliveryEnabled: true,
            protectedInternalMarkerURL: nil,
            postHogAPIKeyProvider: { "test-posthog-key" },
            postHogRequestHook: { request in
                capturedRequests.append(request)
            }
        )

        telemetryService.trackCoreHealthAppOpen(appVersion: "1.8.1", buildNumber: "103")

        let request = try XCTUnwrap(capturedRequests.first)
        XCTAssertEqual(capturedRequests.count, 1)
        XCTAssertEqual(request.url?.absoluteString, "https://us.i.posthog.com/capture/")
        XCTAssertEqual(request.httpMethod, "POST")

        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["event"] as? String, "app_opened")
        XCTAssertNotNil(body["distinct_id"])
        XCTAssertNotNil(body["timestamp"])
        XCTAssertNotNil(body["api_key"])

        let properties = try XCTUnwrap(body["properties"] as? [String: String])
        XCTAssertEqual(properties, [
            "app_version": "1.8.1",
            "build_number": "103"
        ])
    }

    func testInternalTelemetrySuppressesAllDeliveryAndSurvivesReset() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let marker = base.appendingPathComponent("internal-telemetry-marker")
        var requests: [URLRequest] = []
        let telemetry = TelemetryService(
            defaults: defaults,
            baseDirectory: base,
            postHogDeliveryEnabled: true,
            protectedInternalMarkerURL: marker,
            postHogAPIKeyProvider: { "test-posthog-key" },
            postHogRequestHook: { requests.append($0) }
        )
        func captureBoth() {
            telemetry.trackCoreHealthAppOpen(appVersion: "1.16.2", buildNumber: "145")
            telemetry.track(name: "onboarding_started", telemetryOptIn: true)
            telemetry.track(name: "proxy_start_failed", payload: ["code": "E001"], telemetryOptIn: true)
        }

        // An unmarked public install still sends health and opted-in analytics.
        captureBoth()
        XCTAssertEqual(requests.count, 3)
        let originalID = telemetry.installID
        requests.removeAll()

        // The legacy preference blocks every delivery kind too.
        defaults.set(true, forKey: "proxypilot.telemetry.isMicah")
        captureBoth()
        XCTAssertTrue(requests.isEmpty)
        defaults.removeObject(forKey: "proxypilot.telemetry.isMicah")

        // The protected marker takes effect in an already-running service.
        try "is_micah=true\n".write(to: marker, atomically: true, encoding: .utf8)
        captureBoth()
        XCTAssertTrue(requests.isEmpty)
        telemetry.resetForFreshInstall()
        XCTAssertNotEqual(originalID, telemetry.installID)
        captureBoth()
        XCTAssertTrue(requests.isEmpty)

        let log = base.appendingPathComponent("ProxyPilotTelemetry/events.ndjson")
        let events = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(TelemetryEvent.self, from: Data($0.utf8)) }
        XCTAssertEqual(events.map(\.name), ["app_opened", "onboarding_started", "proxy_start_failed"])

        // Recreated preferences simulate AppCleaner without touching the protected marker.
        let suite = "internal-telemetry-test-" + UUID().uuidString
        let freshDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { freshDefaults.removePersistentDomain(forName: suite) }
        let relaunched = TelemetryService(
            defaults: freshDefaults,
            baseDirectory: base,
            postHogDeliveryEnabled: true,
            protectedInternalMarkerURL: marker,
            postHogAPIKeyProvider: { "test-posthog-key" },
            postHogRequestHook: { requests.append($0) }
        )
        XCTAssertNotEqual(telemetry.installID, relaunched.installID)
        relaunched.trackCoreHealthAppOpen(appVersion: "1.16.2", buildNumber: "145")
        relaunched.track(name: "onboarding_started", telemetryOptIn: true)
        XCTAssertTrue(requests.isEmpty)

        // Malformed markers must not silently disable public telemetry.
        try "is_micah=false\n".write(to: marker, atomically: true, encoding: .utf8)
        captureBoth()
        XCTAssertEqual(requests.count, 3)
    }

    func testPreflightFailureTelemetryPayloadIncludesActionableContextOnly() {
        let checks = [
            PreflightCheckResult(
                id: "upstream_key",
                title: "Upstream API Key",
                detail: "Missing upstream API key in Keychain.",
                status: .fail,
                fixAction: .openUpstreamKeyEditor
            ),
            PreflightCheckResult(
                id: "port_available",
                title: "Proxy Port Availability",
                detail: "Port 4000 is already in use.",
                status: .fail,
                fixAction: .usePort4001
            ),
            PreflightCheckResult(
                id: "local_provider_reachability",
                title: "Ollama Server Reachability",
                detail: "Ollama is not listening.",
                status: .warning,
                fixAction: .none
            )
        ]

        let payload = AppViewModel.telemetryPayloadForPreflightFailure(
            checks: checks,
            useBuiltInProxy: true,
            requireLocalAuth: false,
            upstreamProvider: .zAI
        )

        XCTAssertEqual(payload["failure_count"], "2")
        XCTAssertEqual(payload["warning_count"], "1")
        XCTAssertEqual(payload["failure_ids"], "port_available,upstream_key")
        XCTAssertEqual(payload["warning_ids"], "local_provider_reachability")
        XCTAssertEqual(payload["fix_actions"], "openUpstreamKeyEditor,usePort4001")
        XCTAssertEqual(payload["mode"], "builtin")
        XCTAssertEqual(payload["provider_class"], "cloud")
        XCTAssertEqual(payload["local_auth_required"], "false")
        XCTAssertEqual(payload["upstream_key_required"], "true")
        XCTAssertNil(payload["proxy_url"])
        XCTAssertNil(payload["upstream_url"])
        XCTAssertNil(payload["provider"])
        XCTAssertNil(payload["model"])
        XCTAssertNil(payload["prompt"])
        XCTAssertNil(payload["output"])
        XCTAssertNil(payload["system_info"])
    }

    func testProxyStartFailureTelemetryPayloadIncludesIssueAndPreflightCodesOnly() {
        let issue = AppIssue(
            code: .generic,
            title: "Failed to Start Proxy",
            message: "The local proxy could not start.",
            actions: [.retryStart, .runPreflight, .exportDiagnostics]
        )
        let checks = [
            PreflightCheckResult(
                id: "upstream_base",
                title: "Upstream API Base URL",
                detail: "Invalid upstream base URL.",
                status: .fail,
                fixAction: .resetUpstreamURL
            ),
            PreflightCheckResult(
                id: "master_key",
                title: "Local Proxy Password",
                detail: "Optional in built-in mode when local auth is disabled.",
                status: .info,
                fixAction: .none
            )
        ]

        let payload = AppViewModel.telemetryPayloadForProxyStartFailure(
            issue: issue,
            useBuiltInProxy: false,
            preflightResults: checks
        )

        XCTAssertEqual(payload["code"], "E999")
        XCTAssertEqual(payload["mode"], "builtin")
        XCTAssertEqual(payload["issue_actions"], "exportDiagnostics,retryStart,runPreflight")
        XCTAssertEqual(payload["preflight_failure_count"], "1")
        XCTAssertEqual(payload["preflight_failure_ids"], "upstream_base")
        XCTAssertNil(payload["issue_title"])
        XCTAssertNil(payload["issue_message"])
        XCTAssertNil(payload["upstream_url"])
        XCTAssertNil(payload["proxy_url"])
        XCTAssertNil(payload["prompt"])
        XCTAssertNil(payload["output"])
        XCTAssertNil(payload["system_info"])
    }

    func testStableBuildUsesBundledPostHogKeyWhenPresentAndAlphaBuildsAreRuntimeBlocked() throws {
        let apiKey = hostAppBundle.object(forInfoDictionaryKey: "POSTHOG_API_KEY") as? String
        let bundleIdentifier = hostAppBundle.bundleIdentifier

        if AppBuildBadge.isAlphaBundle(bundleIdentifier) {
            XCTAssertFalse(TelemetryService.defaultPostHogDeliveryEnabled(
                bundleIdentifier: bundleIdentifier,
                environment: [:]
            ))
        } else {
            try XCTSkipIf(apiKey?.isEmpty ?? true, "PostHog key restoration is owned by the paired v1.8.1 telemetry session.")
            XCTAssertFalse(apiKey?.isEmpty ?? true)
            XCTAssertTrue(TelemetryService.defaultPostHogDeliveryEnabled(
                bundleIdentifier: bundleIdentifier,
                environment: [:]
            ))
        }
    }

    func testDefaultPostHogDeliveryIsDisabledForXCTestAndAlphaRuntime() {
        let stableID = "com.example.ProxyPilot"
        let alphaID = "com.example.ProxyPilot-alpha"
        XCTAssertFalse(TelemetryService.defaultPostHogDeliveryEnabled(
            bundleIdentifier: stableID,
            environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]
        ))
        XCTAssertFalse(TelemetryService.defaultPostHogDeliveryEnabled(
            bundleIdentifier: alphaID,
            environment: [:]
        ))
        XCTAssertTrue(TelemetryService.defaultPostHogDeliveryEnabled(
            bundleIdentifier: stableID,
            environment: [:]
        ))
    }

    func testLaunchBackgroundWorkIsDisabledForXCTest() {
        XCTAssertFalse(AppViewModel.shouldRunLaunchBackgroundWork(
            environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]
        ))
        XCTAssertTrue(AppViewModel.shouldRunLaunchBackgroundWork(environment: [:]))
    }

    func testProviderModelLookupTracksFetchedModelsByExactAndCaseInsensitiveID() {
        let vm = AppViewModel(defaults: defaults)
        vm.providerManager.applyFetchedUpstreamModels([
            UpstreamModel(
                id: "Example/Model",
                contextLength: 128_000,
                promptPricePer1M: nil,
                completionPricePer1M: nil
            )
        ])

        XCTAssertEqual(vm.providerManager.upstreamModel(for: "Example/Model")?.contextLength, 128_000)
        XCTAssertEqual(vm.providerManager.upstreamModel(for: "example/model")?.id, "Example/Model")
        XCTAssertEqual(vm.providerManager.upstreamModel(for: "example/model:exacto")?.id, "Example/Model:exacto")
    }

    private var hostAppBundle: Bundle {
        guard let testHost = ProcessInfo.processInfo.environment["TEST_HOST"] else {
            var candidate = Bundle.main.bundleURL
            while candidate.path != "/" {
                if candidate.pathExtension == "app", let bundle = Bundle(url: candidate) {
                    return bundle
                }
                candidate.deleteLastPathComponent()
            }
            return Bundle(for: AppViewModel.self)
        }
        return Bundle(path: testHost) ?? Bundle.main
    }

    // MARK: - Custom Providers (v1.4.18)

    func testAddCustomProviderAppearsInList() {
        let vm = AppViewModel(defaults: defaults)
        XCTAssertTrue(vm.customProviders.isEmpty)
        vm.addCustomProvider(name: "Together", apiBaseURL: "https://api.together.xyz/v1", apiKey: "sk-test")
        XCTAssertEqual(vm.customProviders.count, 1)
        XCTAssertEqual(vm.customProviders.first?.name, "Together")
    }

    func testDeleteCustomProviderRemovesIt() {
        let vm = AppViewModel(defaults: defaults)
        vm.addCustomProvider(name: "TestProvider", apiBaseURL: "https://example.com/v1", apiKey: "sk-test")
        XCTAssertEqual(vm.customProviders.count, 1)
        let provider = vm.customProviders.first!
        vm.deleteCustomProvider(provider)
        XCTAssertTrue(vm.customProviders.isEmpty)
    }

    func testActivateCustomProviderBuildsConfigWithCustomEndpointAndKey() throws {
        try KeychainService.set("local-secret", forKey: .litellmMasterKey)
        let vm = AppViewModel(defaults: defaults)
        vm.addCustomProvider(name: "Together", apiBaseURL: "https://api.together.xyz/v1", apiKey: "sk-custom")
        let provider = try XCTUnwrap(vm.customProviders.first)

        vm.activateCustomProvider(provider)

        let config = try vm.buildBuiltInProxyConfig()

        XCTAssertEqual(vm.selectedUpstreamSelection, .custom(provider.id))
        XCTAssertEqual(vm.upstreamProviderDisplayTitle, "Together")
        XCTAssertEqual(config.upstreamProvider, .openAI)
        XCTAssertEqual(config.upstreamAPIBase.absoluteString, "https://api.together.xyz/v1")
        XCTAssertEqual(config.upstreamAPIKey, "sk-custom")
        XCTAssertNil(config.inputOutputLogger)
    }

    func testCustomProviderModelStateDoesNotReuseOpenAIState() throws {
        let vm = AppViewModel(defaults: defaults)
        vm.selectBuiltInUpstreamProvider(.openAI)
        vm.upstreamModels = [
            UpstreamModel(id: "gpt-4.1", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil)
        ]
        vm.selectedUpstreamModels = ["gpt-4.1"]
        vm.selectedXcodeAgentModel = "gpt-4.1"
        vm.saveSelectedModelsAsDefaults()

        vm.addCustomProvider(name: "Together", apiBaseURL: "https://api.together.xyz/v1", apiKey: "sk-custom")
        let provider = try XCTUnwrap(vm.customProviders.first)
        vm.activateCustomProvider(provider)
        vm.upstreamModels = [
            UpstreamModel(id: "together/custom-model", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil)
        ]
        vm.selectedUpstreamModels = ["together/custom-model"]
        vm.selectedXcodeAgentModel = "together/custom-model"
        vm.saveSelectedModelsAsDefaults()

        XCTAssertEqual(vm.xcodeAgentModelCandidates, ["together/custom-model"])
        XCTAssertEqual(vm.modelSelectionRows.map(\.id), ["together/custom-model"])

        vm.selectBuiltInUpstreamProvider(.openAI)

        XCTAssertEqual(vm.selectedUpstreamSelection, .builtIn(.openAI))
        XCTAssertEqual(vm.xcodeAgentModelCandidates, ["gpt-4.1"])
        XCTAssertEqual(vm.modelSelectionRows.map(\.id), ["gpt-4.1"])
        XCTAssertFalse(vm.modelSelectionRows.map(\.id).contains("together/custom-model"))
    }

    func testCustomProviderEndpointEditingDoesNotOverwriteBuiltInOpenAIBaseURL() throws {
        let vm = AppViewModel(defaults: defaults)
        vm.selectBuiltInUpstreamProvider(.openAI)
        vm.upstreamAPIBaseURLString = "https://api.openai.com/v1"

        vm.addCustomProvider(name: "Fireworks", apiBaseURL: "https://api.fireworks.ai/inference/v1", apiKey: "sk-custom")
        let provider = try XCTUnwrap(vm.customProviders.first)
        vm.activateCustomProvider(provider)
        vm.upstreamAPIBaseURLString = "https://api.fireworks.ai/inference/v1/custom"

        vm.selectBuiltInUpstreamProvider(.openAI)

        XCTAssertEqual(vm.upstreamAPIBaseURLString, "https://api.openai.com/v1")

        let updatedProvider = try XCTUnwrap(vm.customProviders.first)
        vm.activateCustomProvider(updatedProvider)

        XCTAssertEqual(vm.upstreamAPIBaseURLString, "https://api.fireworks.ai/inference/v1/custom")
    }

    func testCustomProviderProxyConfigUsesObserveOnlyPromptCaching() throws {
        try KeychainService.set("local-secret", forKey: .litellmMasterKey)
        let vm = AppViewModel(defaults: defaults)
        vm.promptCachingMode = .computeCacheHints
        vm.addCustomProvider(name: "Together", apiBaseURL: "https://api.together.xyz/v1", apiKey: "sk-custom")
        let provider = try XCTUnwrap(vm.customProviders.first)
        vm.activateCustomProvider(provider)

        let config = try vm.buildBuiltInProxyConfig()

        XCTAssertEqual(config.upstreamProvider, .openAI)
        XCTAssertEqual(config.promptCaching.mode, .observeOnly)
        XCTAssertFalse(config.promptCaching.canonicalizeJSONForCache)
        XCTAssertTrue(config.promptCaching.recordsProviderCacheTelemetry)
    }

    func testCustomProviderClearSelectionKeepsSavedDefaultsAllowedOnly() throws {
        let vm = AppViewModel(defaults: defaults)
        vm.addCustomProvider(name: "Together", apiBaseURL: "https://api.together.xyz/v1", apiKey: "")
        let provider = try XCTUnwrap(vm.customProviders.first)
        vm.activateCustomProvider(provider)
        vm.upstreamModels = [
            UpstreamModel(id: "safe-default", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
            UpstreamModel(id: "expensive-unselected", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
        ]
        vm.selectedUpstreamModels = ["safe-default"]
        vm.selectedXcodeAgentModel = "safe-default"
        vm.saveSelectedModelsAsDefaults()
        vm.setModelSelected("expensive-unselected", isSelected: true)

        vm.clearUpstreamModelSelection()
        let config = try vm.buildBuiltInProxyConfig()

        XCTAssertTrue(vm.isModelSelected("safe-default"))
        XCTAssertFalse(vm.isModelSelected("expensive-unselected"))
        XCTAssertTrue(vm.selectedUpstreamModels.isEmpty)
        XCTAssertEqual(config.allowedModels, ["safe-default"])
    }

    func testActiveCustomProviderPersistsAcrossRelaunch() throws {
        var vm: AppViewModel? = AppViewModel(defaults: defaults)
        vm?.addCustomProvider(name: "Together", apiBaseURL: "https://api.together.xyz/v1", apiKey: "sk-custom")
        let provider = try XCTUnwrap(vm?.customProviders.first)
        vm?.activateCustomProvider(provider)
        vm = nil

        let relaunched = AppViewModel(defaults: defaults)

        XCTAssertEqual(relaunched.selectedUpstreamSelection, .custom(provider.id))
        XCTAssertEqual(relaunched.activeCustomProvider?.id, provider.id)
        XCTAssertEqual(relaunched.upstreamProviderDisplayTitle, "Together")
        XCTAssertEqual(relaunched.upstreamAPIBaseURLString, "https://api.together.xyz/v1")
        XCTAssertTrue(relaunched.hasUpstreamKey)
    }

    func testCustomProviderKeychainAccountFormat() {
        let provider = CustomProvider(name: "Test", apiBaseURL: "https://example.com/v1")
        XCTAssertTrue(provider.keychainAccountName.hasPrefix("CUSTOM_"))
        XCTAssertTrue(provider.keychainAccountName.count > 10)
    }

    // MARK: - API Key Page URL

    func testCloudProvidersHaveAPIKeyPageURL() {
        let cloudProviders: [UpstreamProvider] = [.zAI, .openRouter, .openAI, .xAI, .chutes, .groq, .google, .deepSeek, .mistral, .miniMax, .miniMaxCN, .qwen]
        for provider in cloudProviders {
            XCTAssertNotNil(provider.apiKeyPageURL, "\(provider.title) should have an API key page URL")
        }
    }

    func testLocalProvidersHaveNoAPIKeyPageURL() {
        XCTAssertNil(UpstreamProvider.ollama.apiKeyPageURL)
        XCTAssertNil(UpstreamProvider.lmStudio.apiKeyPageURL)
    }

    func test9RouterProviderUsesProjectURLWithOptionalKeychainKey() {
        XCTAssertEqual(UpstreamProvider.nineRouter.defaultAPIBaseURL, "http://localhost:20128/v1")
        XCTAssertEqual(UpstreamProvider.nineRouter.apiKeyPageURL?.absoluteString, "https://9router.com")
        XCTAssertEqual(UpstreamProvider.nineRouter.keychainKey, .nineRouterAPIKey)
        XCTAssertFalse(UpstreamProvider.nineRouter.requiresAPIKey)
    }

    func testAllCloudProvidersHaveKeychainKeys() {
        let cloudProviders: [UpstreamProvider] = [.zAI, .openRouter, .openAI, .xAI, .chutes, .groq, .google, .deepSeek, .mistral, .miniMax, .miniMaxCN, .qwen]
        for provider in cloudProviders {
            XCTAssertNotNil(provider.keychainKey, "\(provider.title) should have a keychain key")
            XCTAssertTrue(provider.requiresAPIKey, "\(provider.title) should require API key")
            XCTAssertNotNil(provider.apiKeyPageURL, "\(provider.title) should have API key page URL")
        }
    }

    func testGoogleProviderUsesExpectedDefaults() {
        XCTAssertEqual(UpstreamProvider.google.defaultAPIBaseURL, "https://generativelanguage.googleapis.com/v1beta/openai")
        XCTAssertEqual(UpstreamProvider.google.chatCompletionsPath, "/chat/completions")
        XCTAssertEqual(UpstreamProvider.openAI.chatCompletionsPath, "/chat/completions")
        XCTAssertEqual(UpstreamProvider.google.keychainKey, .googleAPIKey)
    }

    func testFeedbackDraftURLUsesCanonicalRecipientAndIncludesContext() throws {
        let vm = AppViewModel(defaults: defaults)
        vm.upstreamProvider = .google
        vm.upstreamAPIBaseURLString = "https://generativelanguage.googleapis.com/v1beta/openai"

        let url = try XCTUnwrap(vm.feedbackDraftURL())
        XCTAssertEqual(url.scheme, "mailto")
        XCTAssertEqual(url.path, "micah@micah.chat")

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertTrue(queryItems["subject"]?.contains("ProxyPilot Feedback") == true)
        XCTAssertTrue(queryItems["body"]?.contains("Upstream provider: Google (Gemini)") == true)
        XCTAssertTrue(queryItems["body"]?.contains("A technical support summary has been copied to the clipboard") == true)
    }

    func testPublicSupportLinksUsePublicRepository() {
        let vm = AppViewModel(defaults: defaults)

        XCTAssertEqual(
            vm.publicRepositoryURL.absoluteString,
            "https://github.com/masterofthechaos/ProxyPilot-public"
        )
        XCTAssertEqual(
            vm.readmeURL.absoluteString,
            "https://github.com/masterofthechaos/ProxyPilot-public/blob/main/README.md"
        )
    }

    func testLocalProvidersDontRequireKeys() {
        let localProviders: [UpstreamProvider] = [.ollama, .lmStudio, .nineRouter]
        for provider in localProviders {
            XCTAssertFalse(provider.requiresAPIKey, "\(provider.title) should not require API key")
        }
        XCTAssertNil(UpstreamProvider.ollama.keychainKey)
        XCTAssertNil(UpstreamProvider.lmStudio.keychainKey)
        XCTAssertEqual(UpstreamProvider.nineRouter.keychainKey, .nineRouterAPIKey)
    }

    // MARK: - Per-Provider Key Management

    func testProviderKeyDraftsAreIndependent() {
        let vm = AppViewModel(defaults: defaults)
        vm.providerKeyDrafts[.openRouter] = "sk-or-test"
        vm.providerKeyDrafts[.openAI] = "sk-openai-test"
        XCTAssertEqual(vm.providerKeyDrafts[.openRouter], "sk-or-test")
        XCTAssertEqual(vm.providerKeyDrafts[.openAI], "sk-openai-test")
        XCTAssertNil(vm.providerKeyDrafts[.zAI])
    }

    func testProviderKeyEditingStatesAreIndependent() {
        let vm = AppViewModel(defaults: defaults)
        vm.providerKeyEditing[.openRouter] = true
        XCTAssertEqual(vm.providerKeyEditing[.openRouter], true)
        XCTAssertNil(vm.providerKeyEditing[.openAI])
    }

    func testSavingProviderKeyVerifiesInstalledCLIVisibility() async {
        let stdout = #"{"ok":true,"data":{"provider":"zai","status":"stored","stored":true,"backend":"keychain"}}"#
        let vm = AppViewModel(
            defaults: defaults,
            cliExecutableResolver: { URL(fileURLWithPath: "/usr/local/bin/proxypilot") },
            cliAuthStatusRunner: { executable, provider in
                XCTAssertEqual(executable.path, "/usr/local/bin/proxypilot")
                XCTAssertEqual(provider, .zAI)
                return AppViewModel.CLIUpdateExecutionResult(
                    terminationStatus: 0,
                    stdout: stdout,
                    stderr: ""
                )
            }
        )

        vm.providerKeyDrafts[.zAI] = "test-zai-key-with-valid-length"
        vm.saveKey(for: .zAI)

        await vm.verifyProviderKeyCLIVisibility(for: .zAI)

        XCTAssertEqual(vm.providerCLIAuthStatuses[.zAI], .visible)
    }

    func testSavingShortZAIProviderKeyIsRejected() {
        let vm = AppViewModel(defaults: defaults)

        vm.providerKeyDrafts[.zAI] = "short-zai-key"
        vm.saveKey(for: .zAI)

        XCTAssertEqual(vm.providerKeyDrafts[.zAI], "short-zai-key")
        XCTAssertEqual(vm.activeIssue?.code, .missingUpstreamKey)
        XCTAssertTrue(vm.activeIssue?.message.contains("at least 20 characters") == true)
    }

    func testSavingProviderKeyRecordsCLIVisibilityMismatch() async {
        let stdout = #"{"ok":true,"data":{"provider":"zai","status":"not_set","stored":false,"backend":"keychain+file-fallback"}}"#
        let vm = AppViewModel(
            defaults: defaults,
            cliExecutableResolver: { URL(fileURLWithPath: "/usr/local/bin/proxypilot") },
            cliAuthStatusRunner: { _, _ in
                AppViewModel.CLIUpdateExecutionResult(
                    terminationStatus: 0,
                    stdout: stdout,
                    stderr: ""
                )
            }
        )

        vm.providerKeyDrafts[.zAI] = "test-zai-key-with-valid-length"
        vm.saveKey(for: .zAI)

        await vm.verifyProviderKeyCLIVisibility(for: .zAI)

        guard case .notVisible(let message) = vm.providerCLIAuthStatuses[.zAI] else {
            XCTFail("Expected CLI visibility mismatch")
            return
        }
        XCTAssertTrue(message.contains("not_set"))
    }

    func testImportsCLISessionReportEventsIntoSessionReportCard() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reportURL = directory.appendingPathComponent("session-report.jsonl")
        try SessionReportStore.append(
            SessionReportEvent(
                source: "cli",
                sessionID: "cli-session",
                record: RequestRecord(
                    timestamp: Date(timeIntervalSince1970: 1_714_000_000),
                    model: "glm-5",
                    promptTokens: 80,
                    completionTokens: 20,
                    durationSeconds: 0.75,
                    path: "/v1/messages",
                    wasStreaming: true
                )
            ),
            to: reportURL
        )

        let vm = AppViewModel(defaults: defaults, sessionReportURL: reportURL)
        vm.importExternalSessionReportEvents()
        try await waitForSessionReportImport(vm: vm, expectedTotalRequests: 1)

        XCTAssertEqual(vm.sessionReportCard.totalRequests, 1)
        XCTAssertEqual(vm.sessionReportCard.totalPromptTokens, 80)
        XCTAssertEqual(vm.sessionReportCard.totalCompletionTokens, 20)
        XCTAssertEqual(vm.sessionReportCard.requests.first?.model, "glm-5")
        XCTAssertEqual(vm.sessionReportCard.requests.first?.path, "/v1/messages")
        XCTAssertEqual(vm.sessionReportCard.requests.first?.wasStreaming, true)
    }

    /// Polls until the async import path moves `sessionReportCard.totalRequests` to the
    /// expected value. Required because `importExternalSessionReportEvents()` was made
    /// non-blocking in commit `89cc265` — it dispatches the read on a detached task and
    /// applies events back on the MainActor after the file I/O resolves.
    private func waitForSessionReportImport(
        vm: AppViewModel,
        expectedTotalRequests: Int,
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if vm.sessionReportCard.totalRequests == expectedTotalRequests { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail(
            "Timed out waiting for sessionReportCard.totalRequests == \(expectedTotalRequests); observed \(vm.sessionReportCard.totalRequests)",
            file: file,
            line: line
        )
    }

    func testDoesNotImportOlderCLISessionWhenNewerGUISessionExists() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reportURL = directory.appendingPathComponent("session-report.jsonl")
        try SessionReportStore.append(
            SessionReportEvent(
                source: "cli",
                sessionID: "older-cli-session",
                record: RequestRecord(
                    timestamp: Date(timeIntervalSince1970: 1_714_000_000),
                    model: "glm-5",
                    promptTokens: 4_500_000,
                    completionTokens: 40_000,
                    durationSeconds: 120,
                    path: "/v1/messages",
                    wasStreaming: true
                )
            ),
            to: reportURL
        )
        try SessionReportStore.append(
            SessionReportEvent(
                source: "gui",
                sessionID: "newer-gui-session",
                record: RequestRecord(
                    timestamp: Date(timeIntervalSince1970: 1_714_000_100),
                    model: "google/gemini-3.1-pro-preview:exacto",
                    promptTokens: 236,
                    completionTokens: 96,
                    durationSeconds: 2.95,
                    path: "/v1/messages",
                    wasStreaming: true
                )
            ),
            to: reportURL
        )
        let vm = AppViewModel(defaults: defaults, sessionReportURL: reportURL)
        let importTask = vm.importExternalSessionReportEvents()
        // Pin the Task's existence: `await importTask?.value` is a silent no-op
        // if the import ever returns nil early, which would re-vacate this test
        // without failing it.
        XCTAssertNotNil(importTask, "Import must return a Task for this test to observe the dedup guard")
        await importTask?.value

        XCTAssertEqual(vm.sessionReportCard.totalRequests, 0)
        XCTAssertTrue(vm.sessionReportCard.requests.isEmpty)
    }

    func testHasKeyForProviderReturnsFalseWhenNoKeyStored() {
        let vm = AppViewModel(defaults: defaults)
        XCTAssertFalse(vm.hasKey(for: .openRouter))
    }

    func testPreflightGeneratesCredentialWhenBuiltInAuthEnabled() {
        let preflight = PreflightService()
        let context = PreflightContext(
            proxyURLString: "http://127.0.0.1:4000",
            useBuiltInProxy: true,
            requireLocalAuth: true,
            upstreamProvider: .zAI,
            upstreamAPIBaseURLString: "https://api.z.ai/api/coding/paas/v4",
            fallbackUpstreamBaseURLString: "https://api.z.ai/api/coding/paas/v4",
            hasMasterKey: false,
            hasUpstreamKey: true
        )

        let results = preflight.run(context: context)
        let masterKeyCheck = results.first { $0.id == "master_key" }

        XCTAssertEqual(masterKeyCheck?.status, .info)
        XCTAssertEqual(masterKeyCheck?.fixAction, .some(.none))
    }

    func testAgentConfigInstalledHydratesFromStateProviderOnInit() {
        let vm = AppViewModel(defaults: defaults, xcodeAgentConfigStateProvider: { true })
        XCTAssertTrue(vm.agentConfigInstalled)
    }

    func testRefreshAgentConfigInstallationStateReconcilesRuntimeChanges() {
        var installed = false
        let vm = AppViewModel(defaults: defaults, xcodeAgentConfigStateProvider: { installed })
        XCTAssertFalse(vm.agentConfigInstalled)

        installed = true
        vm.refreshAgentConfigInstallationState()

        XCTAssertTrue(vm.agentConfigInstalled)
        XCTAssertTrue(vm.shouldPromptBeforeQuit())
    }

    func testUpdateCLIToolShowsMissingCLIErrorWhenBinaryCannotBeResolved() async {
        let vm = AppViewModel(defaults: defaults, cliExecutableResolver: { nil })

        await vm.updateCLITool()

        XCTAssertTrue(vm.cliUpdateStatusIsError)
        XCTAssertFalse(vm.cliUpdateStatusText.isEmpty)
        XCTAssertFalse(vm.isUpdatingCLITool)
    }

    func testUpdateCLIToolParsesSuccessfulJSONResponse() async {
        let stdout = #"{"ok":true,"data":{"status":"updated","from":"1.2.0","to":"1.2.1","path":"/usr/local/bin/proxypilot"}}"#
        let vm = AppViewModel(
            defaults: defaults,
            cliExecutableResolver: { URL(fileURLWithPath: "/usr/local/bin/proxypilot") },
            cliUpdateRunner: { _ in
                AppViewModel.CLIUpdateExecutionResult(
                    terminationStatus: 0,
                    stdout: stdout,
                    stderr: ""
                )
            }
        )

        await vm.updateCLITool()

        XCTAssertFalse(vm.cliUpdateStatusIsError)
        XCTAssertTrue(vm.cliUpdateStatusText.contains("v1.2.0"))
        XCTAssertTrue(vm.cliUpdateStatusText.contains("v1.2.1"))
        XCTAssertFalse(vm.isUpdatingCLITool)
    }

    func testUpdateCLIToolParsesErrorJSONResponse() async {
        let stdout = #"{"ok":false,"error":{"code":"E022","message":"Install directory is not writable","suggestion":"Run with sudo or choose a writable --install-path."}}"#
        let vm = AppViewModel(
            defaults: defaults,
            cliExecutableResolver: { URL(fileURLWithPath: "/usr/local/bin/proxypilot") },
            cliUpdateRunner: { _ in
                AppViewModel.CLIUpdateExecutionResult(
                    terminationStatus: 1,
                    stdout: stdout,
                    stderr: ""
                )
            }
        )

        await vm.updateCLITool()

        XCTAssertTrue(vm.cliUpdateStatusIsError)
        XCTAssertTrue(vm.cliUpdateStatusText.contains("E022"))
        XCTAssertTrue(vm.cliUpdateStatusText.contains("Install directory is not writable"))
        XCTAssertFalse(vm.isUpdatingCLITool)
    }

    func testSessionEstimatedCostUsesModelPricing() throws {
        let vm = AppViewModel(defaults: defaults)
        vm.upstreamModels = [
            UpstreamModel(id: "model-a", contextLength: nil, promptPricePer1M: 2.0, completionPricePer1M: 6.0)
        ]
        vm.sessionReportCard.record(.init(
            timestamp: Date(),
            model: "model-a",
            promptTokens: 1_000,
            completionTokens: 500,
            durationSeconds: 0.2,
            path: "/v1/chat/completions",
            wasStreaming: false
        ))

        let cost = try XCTUnwrap(vm.sessionEstimatedCostUSD)
        XCTAssertEqual(cost, 0.005, accuracy: 0.000001)
        XCTAssertEqual(vm.sessionPricedRequestCount, 1)
    }

    func testSessionEstimatedCostUsesDeepSeekKnownPricingWithExplicitCacheSplit() throws {
        defaults.set(UpstreamProvider.deepSeek.rawValue, forKey: ProviderManager.upstreamProviderDefaultsKey)
        let vm = AppViewModel(defaults: defaults)
        vm.upstreamModels = [
            .idOnly("deepseek-v4-flash")
        ]
        vm.sessionReportCard.record(.init(
            timestamp: Date(),
            model: "deepseek-v4-flash",
            promptTokens: 1_000_000,
            completionTokens: 1_000_000,
            promptCacheHitTokens: 250_000,
            promptCacheMissTokens: 750_000,
            durationSeconds: 0.2,
            path: "/v1/messages",
            wasStreaming: false
        ))

        let cost = try XCTUnwrap(vm.sessionEstimatedCostUSD)
        XCTAssertEqual(cost, 0.3857, accuracy: 0.000001)
        XCTAssertEqual(vm.sessionPricedRequestCount, 1)
    }

    func testSessionCostCopyDescribesCalculatedProviderPricing() {
        defaults.set(UpstreamProvider.deepSeek.rawValue, forKey: ProviderManager.upstreamProviderDefaultsKey)
        let vm = AppViewModel(defaults: defaults)
        vm.upstreamModels = [
            .idOnly("deepseek-v4-flash")
        ]
        vm.sessionReportCard.record(.init(
            timestamp: Date(),
            model: "deepseek-v4-flash",
            promptTokens: 1_000,
            completionTokens: 500,
            promptCacheHitTokens: 100,
            promptCacheMissTokens: 900,
            durationSeconds: 0.2,
            path: "/v1/messages",
            wasStreaming: false
        ))

        XCTAssertEqual(vm.sessionCostMetricLabel, "Calculated Cost")
        XCTAssertEqual(vm.sessionRequestCostLabel, "Calculated Cost")
        XCTAssertTrue(vm.sessionMenuCostText?.hasPrefix("calc ") == true)
        XCTAssertTrue(vm.sessionCostCoverageText.contains("Calculated from response token usage and model pricing"))
        XCTAssertTrue(vm.sessionCostCoverageText.contains("Check your API account dashboard"))
    }

    func testSessionCostCopyDescribesOpenRouterEstimate() {
        defaults.set(UpstreamProvider.openRouter.rawValue, forKey: ProviderManager.upstreamProviderDefaultsKey)
        let vm = AppViewModel(defaults: defaults)
        vm.upstreamModels = [
            UpstreamModel(id: "openrouter/test-model", contextLength: nil, promptPricePer1M: 2.0, completionPricePer1M: 6.0)
        ]
        vm.sessionReportCard.record(.init(
            timestamp: Date(),
            model: "openrouter/test-model",
            promptTokens: 1_000,
            completionTokens: 500,
            durationSeconds: 0.2,
            path: "/v1/chat/completions",
            wasStreaming: false
        ))

        XCTAssertEqual(vm.sessionCostMetricLabel, "OpenRouter Est.")
        XCTAssertEqual(vm.sessionRequestCostLabel, "OpenRouter Estimate")
        XCTAssertTrue(vm.sessionMenuCostText?.hasPrefix("OR est ") == true)
        XCTAssertTrue(vm.sessionCostCoverageText.contains("OpenRouter estimate extrapolated from response token usage and catalog pricing"))
        XCTAssertTrue(vm.sessionCostCoverageText.contains("Check your API account dashboard"))
    }

    func testSessionEstimatedCostFallsBackToStandardDeepSeekPricingWhenCacheSplitMissing() throws {
        // DeepSeek publishes cache hit/miss pricing, but session records from
        // /v1/messages don't carry a hit/miss split. Per f02b513, we fall back
        // to standard prompt/completion pricing rather than dropping the request
        // from the priced cost roll-up.
        defaults.set(UpstreamProvider.deepSeek.rawValue, forKey: ProviderManager.upstreamProviderDefaultsKey)
        let vm = AppViewModel(defaults: defaults)
        vm.sessionReportCard.record(.init(
            timestamp: Date(),
            model: "deepseek-v4-flash",
            promptTokens: 1_000_000,
            completionTokens: 1_000_000,
            durationSeconds: 0.2,
            path: "/v1/messages",
            wasStreaming: false
        ))

        let cost = try XCTUnwrap(vm.sessionEstimatedCostUSD)
        XCTAssertEqual(cost, 0.42, accuracy: 0.000001)
        XCTAssertEqual(vm.sessionPricedRequestCount, 1)
    }

    func testSessionEstimatedCostUsesCachedFetchedPricingAfterRelaunch() throws {
        defaults.set(UpstreamProvider.openRouter.rawValue, forKey: ProviderManager.upstreamProviderDefaultsKey)

        var firstLaunch: AppViewModel? = AppViewModel(defaults: defaults)
        firstLaunch?.providerManager.applyFetchedUpstreamModels([
            UpstreamModel(
                id: "google/gemini-3.1-pro-preview",
                contextLength: 1_000_000,
                promptPricePer1M: 2.0,
                completionPricePer1M: 8.0,
                supportedParameters: ["tools"]
            )
        ])
        firstLaunch = nil

        let relaunched = AppViewModel(defaults: defaults)
        relaunched.sessionReportCard.record(.init(
            timestamp: Date(),
            model: "google/gemini-3.1-pro-preview",
            promptTokens: 1_000,
            completionTokens: 500,
            durationSeconds: 0.2,
            path: "/v1/messages",
            wasStreaming: true
        ))

        let cost = try XCTUnwrap(relaunched.sessionEstimatedCostUSD)
        XCTAssertEqual(cost, 0.006, accuracy: 0.000001)
        XCTAssertEqual(relaunched.sessionPricedRequestCount, 1)
    }

    func testEstimatedRequestCostUsesSessionAverageTokens() throws {
        let vm = AppViewModel(defaults: defaults)
        vm.sessionReportCard.record(.init(
            timestamp: Date(),
            model: "m",
            promptTokens: 1_000,
            completionTokens: 500,
            durationSeconds: 0.2,
            path: "/v1/chat/completions",
            wasStreaming: false
        ))
        vm.sessionReportCard.record(.init(
            timestamp: Date(),
            model: "m",
            promptTokens: 3_000,
            completionTokens: 1_500,
            durationSeconds: 0.4,
            path: "/v1/chat/completions",
            wasStreaming: false
        ))

        let model = UpstreamModel(id: "priced", contextLength: nil, promptPricePer1M: 1.0, completionPricePer1M: 2.0)
        let estimate = try XCTUnwrap(vm.estimatedRequestCostUSD(for: model))
        XCTAssertEqual(estimate, 0.004, accuracy: 0.000001)
    }

    func testSessionRequestsCSVIncludesHeaderAndRows() {
        let vm = AppViewModel(defaults: defaults)
        vm.upstreamModels = [
            UpstreamModel(id: "model-a", contextLength: nil, promptPricePer1M: 1.0, completionPricePer1M: 1.0)
        ]
        vm.sessionReportCard.record(.init(
            timestamp: Date(timeIntervalSince1970: 0),
            model: "model-a",
            promptTokens: 100,
            completionTokens: 200,
            promptCacheHitTokens: 40,
            promptCacheMissTokens: 60,
            promptCacheWriteTokens: 10,
            durationSeconds: 0.123,
            path: "/v1/chat/completions",
            wasStreaming: true
        ))

        let csv = vm.sessionRequestsCSV()
        XCTAssertTrue(csv.contains("timestamp,model,path,streaming,prompt_tokens,completion_tokens,total_tokens,prompt_cache_hit_tokens,prompt_cache_miss_tokens,prompt_cache_write_tokens"))
        XCTAssertTrue(csv.contains("model-a"))
        XCTAssertTrue(csv.contains("/v1/chat/completions"))
        XCTAssertTrue(csv.contains(",40,60,10,"))
        XCTAssertTrue(csv.contains("0.000300"))
    }

    func testSessionRequestsCSVNeutralizesFormulaLeadingCellsWithoutChangingOrdinaryCells() {
        let vm = AppViewModel(defaults: defaults)
        let dangerousValues = ["=SUM(1,2)", "+1+1", "-1+1", "@sum", "\tvalue", "\rvalue", "\nvalue"]

        for value in dangerousValues {
            vm.sessionReportCard.record(.init(
                timestamp: Date(timeIntervalSince1970: 0),
                model: value,
                promptTokens: 0,
                completionTokens: 0,
                durationSeconds: 0,
                path: "ordinary-path",
                wasStreaming: false
            ))
        }
        vm.sessionReportCard.record(.init(
            timestamp: Date(timeIntervalSince1970: 0),
            model: "ordinary-model",
            promptTokens: 0,
            completionTokens: 0,
            durationSeconds: 0,
            path: "ordinary-path",
            wasStreaming: false
        ))

        let csv = vm.sessionRequestsCSV()

        XCTAssertTrue(csv.contains("\"'=SUM(1,2)\""))
        XCTAssertTrue(csv.contains("'+1+1"))
        XCTAssertTrue(csv.contains("'-1+1"))
        XCTAssertTrue(csv.contains("'@sum"))
        XCTAssertTrue(csv.contains("'\tvalue"))
        XCTAssertTrue(csv.contains("\"'\rvalue\""))
        XCTAssertTrue(csv.contains("\"'\nvalue\""))
        XCTAssertTrue(csv.contains("ordinary-model,ordinary-path"))
        XCTAssertFalse(csv.contains("'ordinary-model"))
    }

    func testSessionRequestsCSVIsEmptyWhenNoRequestsExist() {
        let vm = AppViewModel(defaults: defaults)

        XCTAssertEqual(vm.sessionRequestsCSV(), "")
    }

    func testSessionCacheTelemetryRemainsVisibleWhenCachingIsOff() {
        let vm = AppViewModel(defaults: defaults)
        vm.promptCachingMode = .off
        vm.sessionReportCard.record(.init(
            timestamp: Date(timeIntervalSince1970: 0),
            model: "model-a",
            promptTokens: 100,
            completionTokens: 200,
            promptCacheHitTokens: nil,
            promptCacheMissTokens: nil,
            promptCacheWriteTokens: 100,
            durationSeconds: 0.123,
            path: "/v1/chat/completions",
            wasStreaming: true
        ))

        XCTAssertEqual(vm.promptCachingHomeStatusTitle, "Cache reported")
        XCTAssertEqual(vm.sessionCacheMetricLabel, "Cache Reported")
        XCTAssertEqual(vm.sessionCacheMetricValue, "100 written")
        XCTAssertTrue(vm.sessionCacheTelemetryText.contains("Provider reported"))
        XCTAssertTrue(vm.sessionCacheTelemetryText.contains("100 written"))
        XCTAssertTrue(vm.sessionCacheTelemetryText.contains("Caching is off for future requests"))
    }

    func testSessionRequestJSONIncludesCacheTelemetryFields() throws {
        let vm = AppViewModel(defaults: defaults)
        let record = SessionReportCard.RequestRecord(
            timestamp: Date(timeIntervalSince1970: 0),
            model: "model-a",
            promptTokens: 100,
            completionTokens: 200,
            promptCacheHitTokens: 40,
            promptCacheMissTokens: 60,
            promptCacheWriteTokens: 10,
            durationSeconds: 0.123,
            path: "/v1/chat/completions",
            wasStreaming: true
        )

        let data = Data(vm.sessionRequestJSON(record).utf8)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(payload["prompt_cache_hit_tokens"] as? Int, 40)
        XCTAssertEqual(payload["prompt_cache_miss_tokens"] as? Int, 60)
        XCTAssertEqual(payload["prompt_cache_write_tokens"] as? Int, 10)
    }

    func testBuildBadgeIsHiddenForStableBundle() {
        XCTAssertNil(AppBuildBadge.descriptor(bundleIdentifier: "com.example.ProxyPilot"))
    }

    func testAlphaBuildBadgeUsesAlphaPinkCopy() {
        let descriptor = AppBuildBadge.descriptor(bundleIdentifier: "com.example.ProxyPilot-alpha")

        XCTAssertEqual(descriptor?.text, "Alpha")
        XCTAssertEqual(descriptor?.tintName, "pink")
    }

    func testAlphaBuildDisplayNameNamesAlphaBuild() {
        XCTAssertEqual(
            AppBuildBadge.appDisplayName(bundleIdentifier: "com.example.ProxyPilot-alpha"),
            "ProxyPilot Alpha"
        )
        XCTAssertEqual(
            AppBuildBadge.appDisplayName(bundleIdentifier: "com.example.ProxyPilot"),
            "ProxyPilot"
        )
    }

    func testAppBuildBadgeIsAlphaBundleRecognizesSuffix() {
        XCTAssertTrue(AppBuildBadge.isAlphaBundle("com.example.ProxyPilot-alpha"))
        XCTAssertTrue(AppBuildBadge.isAlphaBundle("com.acme.cool.ProxyPilot-alpha"))
        XCTAssertFalse(AppBuildBadge.isAlphaBundle("com.example.ProxyPilot"))
        XCTAssertFalse(AppBuildBadge.isAlphaBundle("com.example.ProxyPilot-alpha-extra"))
        XCTAssertFalse(AppBuildBadge.isAlphaBundle(nil))
    }

    func testSparkleChannelsStayStableByDefault() {
        XCTAssertEqual(SoftwareUpdateChannelPolicy.allowedChannels(isAlphaBuild: false), [])
    }

    func testSparkleChannelsIncludeAlphaOnlyForAlphaBuilds() {
        XCTAssertEqual(SoftwareUpdateChannelPolicy.allowedChannels(isAlphaBuild: true), ["alpha"])
    }

    func testAlphaRequiredFailureEventsBypassOptionalAnalytics() {
        XCTAssertFalse(TelemetryService.shouldSendRemoteEvent(
            name: "proxy_started",
            telemetryOptIn: false,
            isAlphaBuild: true
        ))
        XCTAssertTrue(TelemetryService.shouldSendRemoteEvent(
            name: "proxy_start_failed",
            telemetryOptIn: false,
            isAlphaBuild: true
        ))
    }

    func testProviderEndpointFailureTelemetryCapturesQwenNewBetaWithoutProviderNameOrURL() {
        let issue = AppIssue(
            code: .upstreamUnauthorized,
            title: "Upstream Authorization Failed",
            message: "Qwen returned HTTP 401 from https://dashscope.console.aliyun.com",
            actions: [.openUpstreamKeyEditor]
        )

        let payload = AppViewModel.telemetryPayloadForProviderEndpointFailure(
            provider: .qwen,
            operation: .modelFetch,
            issue: issue,
            usesDefaultEndpoint: true
        )

        XCTAssertEqual(payload["operation"], "modelFetch")
        XCTAssertEqual(payload["code"], AppIssue.Code.upstreamUnauthorized.rawValue)
        XCTAssertEqual(payload["provider_class"], "cloud")
        XCTAssertEqual(payload["provider_release_stage"], "new_beta")
        XCTAssertEqual(payload["default_endpoint"], "true")
        XCTAssertFalse(payload.values.contains { $0.localizedCaseInsensitiveContains("qwen") })
        XCTAssertFalse(payload.values.contains { $0.localizedCaseInsensitiveContains("dashscope") })
    }

    func testProviderEndpointFailureTelemetryClassifiesExistingPreviewProviders() {
        let payload = AppViewModel.telemetryPayloadForProviderEndpointFailure(
            provider: .miniMax,
            operation: .keyTest,
            issue: nil,
            usesDefaultEndpoint: false
        )

        XCTAssertEqual(payload["operation"], "keyTest")
        XCTAssertEqual(payload["provider_release_stage"], "beta")
        XCTAssertEqual(payload["default_endpoint"], "false")
        XCTAssertNil(payload["code"])
    }

    func testGitHubBugReportURLPrefillsIssueContext() throws {
        let url = try XCTUnwrap(AppViewModel.gitHubBugReportURL(
            appVersion: "1.7.27",
            buildNumber: "98",
            statusText: "Proxy Stopped",
            activeIssueCode: "E003"
        ))
        let text = url.absoluteString.removingPercentEncoding ?? url.absoluteString

        XCTAssertTrue(text.hasPrefix("https://github.com/masterofthechaos/ProxyPilot-public/issues/new?"))
        XCTAssertTrue(text.contains("ProxyPilot bug report"))
        XCTAssertTrue(text.contains("App version: 1.7.27 (98)"))
        XCTAssertTrue(text.contains("Proxy status: Proxy Stopped"))
        XCTAssertTrue(text.contains("Issue code: E003"))
    }

    func testAnalyticsPayloadAllowlistRejectsSensitiveAndModelFields() {
        let payload = TelemetryService.sanitizedPayload([
            "provider_identifier": "openrouter",
            "client_surface": "repogps",
            "status_class": "5xx",
            "prompt": "secret prompt",
            "output": "secret output",
            "model": "vendor/private-model-slug",
            "model_slug": "vendor/private-model-slug",
            "url": "https://private.example/path",
            "raw_error": "credential leaked"
        ], for: "proxy_request_failed")

        XCTAssertEqual(payload["provider_identifier"], "openrouter")
        XCTAssertEqual(payload["client_surface"], "repogps")
        XCTAssertEqual(payload["status_class"], "5xx")
        XCTAssertNil(payload["prompt"])
        XCTAssertNil(payload["output"])
        XCTAssertNil(payload["model"])
        XCTAssertNil(payload["model_slug"])
        XCTAssertNil(payload["url"])
        XCTAssertNil(payload["raw_error"])
    }

    func testSessionSummaryIncludesProviderButNeverSpecificModelSlug() throws {
        let forbiddenModel = "vendor/private-model-slug"
        let sessionID = UUID().uuidString
        let records = [
            RequestRecord(
                timestamp: Date(timeIntervalSince1970: 100),
                model: forbiddenModel,
                promptTokens: 1_200,
                completionTokens: 300,
                promptCacheHitTokens: 800,
                promptCacheMissTokens: 200,
                promptCacheWriteTokens: 100,
                durationSeconds: 1.4,
                path: "/v1/messages",
                wasStreaming: true,
                providerIdentifier: "openrouter",
                promptCachingMode: "computeCacheHints",
                contextCompactionEnabled: true,
                translationMode: "hardened"
            ),
            RequestRecord(
                timestamp: Date(timeIntervalSince1970: 104),
                model: forbiddenModel,
                promptTokens: 50,
                completionTokens: 25,
                durationSeconds: 4.2,
                path: "/v1/chat/completions",
                wasStreaming: false,
                providerIdentifier: "openrouter",
                promptCachingMode: "computeCacheHints",
                contextCompactionEnabled: true,
                translationMode: "hardened"
            )
        ]
        let events = records.map { SessionReportEvent(source: "repogps", sessionID: sessionID, record: $0) }

        let payload = try XCTUnwrap(TelemetryService.sessionSummaryPayloads(from: events).first)
        XCTAssertEqual(payload["provider_identifiers"], "openrouter")
        XCTAssertEqual(payload["client_surface"], "repogps")
        XCTAssertEqual(payload["request_count"], "2")
        XCTAssertEqual(payload["path_categories"], "anthropic_messages,chat_completions")
        XCTAssertFalse(payload.keys.contains { $0.localizedCaseInsensitiveContains("model") })
        XCTAssertFalse(payload.values.contains(forbiddenModel))
    }

    func testSessionSummaryNormalizesUnrecognizedProviderIdentifiers() throws {
        let forbiddenValue = "vendor/private-model-slug"
        let event = SessionReportEvent(source: "gui", sessionID: UUID().uuidString, record: RequestRecord(
            model: "another-private-model",
            promptTokens: 1,
            completionTokens: 1,
            durationSeconds: 1,
            path: "/v1/messages",
            wasStreaming: false,
            providerIdentifier: forbiddenValue
        ))

        let payload = try XCTUnwrap(TelemetryService.sessionSummaryPayloads(from: [event]).first)
        XCTAssertEqual(payload["provider_identifiers"], "other")
        XCTAssertFalse(payload.values.contains(forbiddenValue))
    }

    func testSessionAnalyticsAreProspectiveDeduplicatedAndOptInOnly() {
        var captured: [(String, [String: String])] = []
        let telemetry = TelemetryService(
            defaults: defaults,
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            postHogDeliveryEnabled: false,
            protectedInternalMarkerURL: nil,
            remoteCaptureHook: { captured.append(($0, $1)) }
        )
        let sessionID = UUID().uuidString
        func event(_ timestamp: TimeInterval) -> SessionReportEvent {
            SessionReportEvent(source: "cli", sessionID: sessionID, record: RequestRecord(
                timestamp: Date(timeIntervalSince1970: timestamp),
                model: "must-never-leave-device",
                promptTokens: 10,
                completionTokens: 5,
                durationSeconds: 1,
                path: "/v1/chat/completions",
                wasStreaming: false,
                providerIdentifier: "qwen"
            ))
        }
        let historical = event(100)
        let future = event(200)

        telemetry.trackSessionReportEvents([historical], telemetryOptIn: false)
        XCTAssertTrue(captured.isEmpty)

        telemetry.trackSessionReportEvents([historical], telemetryOptIn: true)
        XCTAssertTrue(captured.isEmpty, "First opted-in observation establishes a prospective baseline")

        telemetry.trackSessionReportEvents([historical, future], telemetryOptIn: true)
        XCTAssertEqual(captured.map(\.0), ["first_proxied_inference_succeeded", "proxy_session_summary"])
        XCTAssertEqual(captured[0].1["provider_identifier"], "qwen")
        XCTAssertEqual(captured[1].1["provider_identifiers"], "qwen")

        telemetry.trackSessionReportEvents([historical, future], telemetryOptIn: true)
        XCTAssertEqual(captured.count, 2, "Already summarized events must not be resent")
    }

    func testFreshInstallOptionalAnalyticsStillDefaultsOff() {
        XCTAssertNil(defaults.object(forKey: "proxypilot.telemetryOptIn"))
        let vm = AppViewModel(defaults: defaults)
        XCTAssertFalse(vm.telemetryOptIn)
    }

    func testTelemetryDisclosureMatchesExpandedContract() {
        let vm = AppViewModel(defaults: defaults)
        let disclosure = vm.alwaysOnTelemetryDisclosureText
        if !AppBuildBadge.isAlphaBundle(Bundle.main.bundleIdentifier) {
            XCTAssertTrue(disclosure.contains("provider usage"))
            XCTAssertTrue(disclosure.contains("specific model names are never sent"))
            XCTAssertTrue(disclosure.contains("Prompts, completions"))
        }
    }

    func testFeatureModeTelemetryFiresOnlyForPostInitializationChanges() {
        var captured: [(String, [String: String])] = []
        let telemetry = TelemetryService(
            defaults: defaults,
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            postHogDeliveryEnabled: false,
            protectedInternalMarkerURL: nil,
            remoteCaptureHook: { captured.append(($0, $1)) }
        )
        let vm = AppViewModel(defaults: defaults, telemetryService: telemetry)
        vm.telemetryOptIn = true
        captured.removeAll()

        vm.promptCachingMode = .observeOnly
        vm.anthropicTranslatorFallbackEnabled = true

        let featureEvents = captured.filter { $0.0 == "feature_used" }.map(\.1)
        XCTAssertEqual(featureEvents.count, 2)
        XCTAssertTrue(featureEvents.contains { $0["feature"] == "prompt_caching" && $0["mode"] == "observeOnly" })
        XCTAssertTrue(featureEvents.contains { $0["feature"] == "anthropic_translation" && $0["mode"] == "legacy_fallback" })
    }

    private func makeProviderManager() -> ProviderManager {
        ProviderManager(defaults: defaults, proxyService: ProxyService())
    }

    // MARK: - Coding Harness Tour

    private var harnessPresentedKey: String { "proxypilot.harnessOnboarding.presentedVersion" }
    private var harnessCompletedKey: String { "proxypilot.harnessOnboarding.completedVersion" }
    private var bundleVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// Guards the launch sheet chain: macOS silently drops a sheet when two are
    /// presented from the same view, so at most one flag may ever be true.
    private func assertAtMostOneSheetPresented(
        _ vm: AppViewModel,
        line: UInt = #line
    ) {
        let presented = [
            vm.showOnboardingWizard,
            vm.showKeychainAccessPrimer,
            vm.showAnalyticsPrompt,
            vm.showHarnessOnboarding
        ].filter { $0 }.count
        XCTAssertLessThanOrEqual(presented, 1, "More than one launch sheet presented", line: line)
    }

    func testHarnessOnboardingDoesNotInterruptFirstOpen() {
        defaults.set(true, forKey: "proxypilot.didCompleteOnboarding")
        defaults.set(bundleVersion, forKey: "proxypilot.analyticsPromptShownVersion")
        let vm = AppViewModel(defaults: defaults)

        vm.maybeShowHarnessOnboarding()

        XCTAssertFalse(vm.showHarnessOnboarding)
        XCTAssertNil(defaults.string(forKey: harnessPresentedKey))
        assertAtMostOneSheetPresented(vm)
    }

    func testHarnessOnboardingDoesNotAutoShowASecondTime() {
        defaults.set(true, forKey: "proxypilot.didCompleteOnboarding")
        defaults.set(bundleVersion, forKey: harnessPresentedKey)
        let vm = AppViewModel(defaults: defaults)

        vm.maybeShowHarnessOnboarding()

        XCTAssertFalse(vm.showHarnessOnboarding)
    }

    /// Presence-gated, not version-equality-gated: a later release must not re-present it.
    func testHarnessOnboardingDoesNotReappearOnALaterVersion() {
        defaults.set(true, forKey: "proxypilot.didCompleteOnboarding")
        defaults.set("0.0.1-ancient", forKey: harnessPresentedKey)
        let vm = AppViewModel(defaults: defaults)

        vm.maybeShowHarnessOnboarding()

        XCTAssertFalse(vm.showHarnessOnboarding)
    }

    func testHarnessOnboardingSkipDoesNotPromoteTerminalFeatures() {
        defaults.set(true, forKey: "proxypilot.didCompleteOnboarding")
        let vm = AppViewModel(defaults: defaults)
        vm.maybeShowHarnessOnboarding()

        vm.finishHarnessOnboarding(completed: false)

        XCTAssertFalse(vm.showHarnessOnboarding)
        XCTAssertFalse(vm.harnessOnboardingBadgeVisible)
        XCTAssertNil(defaults.string(forKey: harnessCompletedKey))
    }

    func testHarnessOnboardingCompletionClearsBadge() {
        defaults.set(true, forKey: "proxypilot.didCompleteOnboarding")
        let vm = AppViewModel(defaults: defaults)
        vm.maybeShowHarnessOnboarding()

        vm.finishHarnessOnboarding(completed: true)

        XCTAssertFalse(vm.showHarnessOnboarding)
        XCTAssertFalse(vm.harnessOnboardingBadgeVisible)
        XCTAssertEqual(defaults.string(forKey: harnessCompletedKey), bundleVersion)
    }

    func testHarnessBadgeStaysHiddenAfterRelaunchOnceCompleted() {
        defaults.set(bundleVersion, forKey: harnessCompletedKey)

        let relaunched = AppViewModel(defaults: defaults)

        XCTAssertFalse(relaunched.harnessOnboardingBadgeVisible)
    }

    func testHarnessBadgeHiddenEvenWithoutCompletingOptionalTour() {
        defaults.set(bundleVersion, forKey: harnessPresentedKey)

        let relaunched = AppViewModel(defaults: defaults)

        XCTAssertFalse(relaunched.harnessOnboardingBadgeVisible)
    }

    /// Manual re-entry is always available, even after the tour was completed.
    func testOpenHarnessOnboardingIgnoresPersistedKeys() {
        defaults.set(true, forKey: "proxypilot.didCompleteOnboarding")
        defaults.set(bundleVersion, forKey: harnessPresentedKey)
        defaults.set(bundleVersion, forKey: harnessCompletedKey)
        let vm = AppViewModel(defaults: defaults)

        vm.openHarnessOnboarding(surface: "harnesses_tab")

        XCTAssertTrue(vm.showHarnessOnboarding)
    }

    func testHarnessOnboardingSuppressedDuringWelcomeWizard() {
        let vm = AppViewModel(defaults: defaults)
        XCTAssertTrue(vm.showOnboardingWizard)

        vm.maybeShowHarnessOnboarding()

        XCTAssertFalse(vm.showHarnessOnboarding)
        XCTAssertNil(defaults.string(forKey: harnessPresentedKey))
        assertAtMostOneSheetPresented(vm)
    }

    func testHarnessOnboardingSuppressedWhileAnalyticsPromptIsUp() throws {
        try XCTSkipUnless(analyticsPromptAvailableInTestHost)
        defaults.set(true, forKey: "proxypilot.didCompleteOnboarding")
        let vm = AppViewModel(defaults: defaults)
        vm.maybeShowAnalyticsPrompt()
        XCTAssertTrue(vm.showAnalyticsPrompt)

        vm.maybeShowHarnessOnboarding()

        XCTAssertFalse(vm.showHarnessOnboarding)
        assertAtMostOneSheetPresented(vm)
    }

    /// Micah's ordering requirement: the tour follows the analytics decision, so an
    /// opted-in user has the tour itself attributed.
    func testHarnessOnboardingFollowsAnalyticsPromptDismissal() throws {
        try XCTSkipUnless(analyticsPromptAvailableInTestHost)
        defaults.set(true, forKey: "proxypilot.didCompleteOnboarding")
        let vm = AppViewModel(defaults: defaults)
        vm.maybeShowAnalyticsPrompt()
        vm.maybeShowHarnessOnboarding()
        XCTAssertFalse(vm.showHarnessOnboarding)

        vm.dismissAnalyticsPrompt(optIn: true)

        XCTAssertFalse(vm.showAnalyticsPrompt)
        XCTAssertFalse(vm.showHarnessOnboarding)
        assertAtMostOneSheetPresented(vm)
    }

    /// Mirrors ContentView's sheet binding, which routes any dismissal — Escape or a
    /// click outside included — through the view model rather than setting the flag.
    /// Calling the method directly would pass even if the binding bypassed it.
    private func dismissKeychainPrimerThroughSheetBinding(_ vm: AppViewModel) {
        let binding = Binding(
            get: { vm.showKeychainAccessPrimer },
            set: { newValue in
                if !newValue && vm.showKeychainAccessPrimer {
                    vm.dismissKeychainAccessPrimer()
                } else {
                    vm.showKeychainAccessPrimer = newValue
                }
            }
        )
        binding.wrappedValue = false
    }

    func testHarnessOnboardingFollowsKeychainPrimerSheetDismissal() {
        defaults.set(true, forKey: "proxypilot.didCompleteOnboarding")
        defaults.set(bundleVersion, forKey: "proxypilot.analyticsPromptShownVersion")
        let vm = AppViewModel(defaults: defaults)
        vm.showKeychainAccessPrimer = true
        vm.maybeShowHarnessOnboarding()
        XCTAssertFalse(vm.showHarnessOnboarding)

        dismissKeychainPrimerThroughSheetBinding(vm)

        XCTAssertFalse(vm.showKeychainAccessPrimer)
        XCTAssertFalse(vm.showHarnessOnboarding)
        assertAtMostOneSheetPresented(vm)
    }

    /// The Keychain primer had no dismissal chain point before this flow existed;
    /// without one the tour never appears for anyone with an authorized stored key.
    func testHarnessOnboardingFollowsKeychainPrimerDismissal() {
        defaults.set(true, forKey: "proxypilot.didCompleteOnboarding")
        defaults.set(bundleVersion, forKey: "proxypilot.analyticsPromptShownVersion")
        let vm = AppViewModel(defaults: defaults)
        vm.showKeychainAccessPrimer = true
        vm.maybeShowHarnessOnboarding()
        XCTAssertFalse(vm.showHarnessOnboarding)

        vm.dismissKeychainAccessPrimer()

        XCTAssertFalse(vm.showHarnessOnboarding)
        assertAtMostOneSheetPresented(vm)
    }

    /// Manual re-entry must not let a later `maybeShowAnalyticsPrompt()` double-present.
    func testAnalyticsPromptSuppressedWhileHarnessTourIsUp() {
        defaults.set(true, forKey: "proxypilot.didCompleteOnboarding")
        let vm = AppViewModel(defaults: defaults)
        vm.openHarnessOnboarding(surface: "harnesses_tab")
        XCTAssertTrue(vm.showHarnessOnboarding)

        vm.maybeShowAnalyticsPrompt()

        XCTAssertFalse(vm.showAnalyticsPrompt)
        assertAtMostOneSheetPresented(vm)
    }

    func testResetToFreshInstallClearsHarnessOnboardingState() async {
        defaults.set(bundleVersion, forKey: harnessPresentedKey)
        defaults.set(bundleVersion, forKey: harnessCompletedKey)
        let vm = AppViewModel(defaults: defaults)
        XCTAssertFalse(vm.harnessOnboardingBadgeVisible)

        await vm.resetToFreshInstall()

        XCTAssertNil(defaults.string(forKey: harnessPresentedKey))
        XCTAssertNil(defaults.string(forKey: harnessCompletedKey))
        XCTAssertFalse(vm.harnessOnboardingBadgeVisible)
        XCTAssertFalse(vm.showHarnessOnboarding)
    }
}
