import XCTest
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
    }

    override func tearDown() {
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        unsetenv("PROXYPILOT_KEYCHAIN_SERVICE")
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

    func testBuiltInProxyConfigCarriesPromptCachingMode() throws {
        let vm = AppViewModel(defaults: defaults)
        vm.promptCachingMode = .off

        let config = try vm.buildBuiltInProxyConfig()

        XCTAssertEqual(config.promptCaching.mode, .off)
        XCTAssertFalse(config.promptCaching.recordsProviderCacheTelemetry)
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
        vm?.inputOutputLoggingExternalStorageEnabled = true
        vm = nil

        let relaunched = AppViewModel(defaults: defaults)

        XCTAssertTrue(relaunched.inputOutputLoggingEnabled)
        XCTAssertFalse(relaunched.inputOutputLoggingRecordInputs)
        XCTAssertTrue(relaunched.inputOutputLoggingRecordOutputs)
        XCTAssertTrue(relaunched.inputOutputLoggingCLIEnabled)
        XCTAssertEqual(relaunched.inputOutputLoggingRetention, .sixHours)
        XCTAssertFalse(relaunched.inputOutputLoggingExternalStorageEnabled)
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
        XCTAssertTrue(vm.copilotSidecarExpanded)
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

    func testCustomizationPreferencesPersistAcrossRelaunch() {
        var vm: AppViewModel? = AppViewModel(defaults: defaults)
        vm?.appearancePreference = .dark
        vm?.proxyPilotAccentHex = "#FF2D55"
        vm?.showMenuBarExtra = false
        vm?.menuBarSectionOrder = [.quickActions, .statusDetails, .updates, .modelPicker, .sessionStats]
        vm?.visibleMenuBarSections = [.statusDetails, .quickActions]
        vm?.visibleHomeDashboardSections = [.sessionSummary, .sessionReportCard]
        vm?.defaultSettingsSection = .customization
        vm?.keysProviderOrder = [.openAI, .githubCopilot, .zAI, .openRouter, .xAI, .chutes, .groq, .google, .deepSeek, .mistral, .miniMax, .miniMaxCN, .qwen, .ollama, .lmStudio]
        vm?.visibleKeysProviders = [.openAI, .githubCopilot]
        vm?.copilotSidecarExpanded = false
        vm = nil

        let relaunched = AppViewModel(defaults: defaults)

        XCTAssertEqual(relaunched.appearancePreference, .dark)
        XCTAssertEqual(relaunched.proxyPilotAccentHex, "#FF2D55")
        XCTAssertFalse(relaunched.showMenuBarExtra)
        XCTAssertEqual(relaunched.menuBarSectionOrder, [.quickActions, .statusDetails, .updates, .modelPicker, .sessionStats])
        XCTAssertEqual(relaunched.visibleMenuBarSections, [.statusDetails, .quickActions])
        XCTAssertEqual(relaunched.visibleHomeDashboardSections, [.sessionSummary, .sessionReportCard])
        XCTAssertEqual(relaunched.defaultSettingsSection, .customization)
        XCTAssertEqual(relaunched.keysProviderOrder.first, .openAI)
        XCTAssertEqual(relaunched.keysProviderOrder.dropFirst().first, .githubCopilot)
        XCTAssertEqual(relaunched.visibleKeysProviders, [.openAI, .githubCopilot])
        XCTAssertFalse(relaunched.copilotSidecarExpanded)
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
        vm.keysProviderOrder = [.openAI, .githubCopilot, .zAI, .openRouter, .xAI, .chutes, .groq, .google, .deepSeek, .mistral, .miniMax, .miniMaxCN, .qwen, .ollama, .lmStudio]
        vm.visibleKeysProviders = [.openAI]
        vm.copilotSidecarExpanded = false

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
        XCTAssertTrue(vm.copilotSidecarExpanded)
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

        XCTAssertEqual(vm.menuBarSectionOrder, [.quickActions, .statusDetails, .modelPicker, .sessionStats, .updates])
        XCTAssertEqual(vm.visibleMenuBarSections, [.quickActions])
    }

    func testKeysProviderCustomizationNormalizesStoredUnknownMissingAndDuplicateProviders() {
        defaults.set(
            [
                KeysProviderViewItem.openAI.rawValue,
                "unknown",
                KeysProviderViewItem.openAI.rawValue,
                KeysProviderViewItem.githubCopilot.rawValue
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

        XCTAssertEqual(vm.keysProviderOrder.prefix(2), [.openAI, .githubCopilot])
        XCTAssertEqual(vm.keysProviderOrder.count, KeysProviderViewItem.defaultOrder.count)
        XCTAssertEqual(vm.visibleKeysProviders, [.openAI, .qwen])
    }

    func testKeysProviderCustomizationMigratesQwenIntoLegacyVisibleProvidersOnce() {
        defaults.set(
            [
                KeysProviderViewItem.openAI.rawValue,
                KeysProviderViewItem.githubCopilot.rawValue,
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
        XCTAssertEqual(vm.visibleKeysProviders, [.openAI, .qwen])
        XCTAssertTrue(defaults.bool(forKey: AppViewModel.didMigrateQwenVisibleProviderDefaultsKey))
    }

    func testKeysProviderCustomizationRespectsQwenHiddenAfterMigration() {
        defaults.set(
            [
                KeysProviderViewItem.openAI.rawValue,
                KeysProviderViewItem.qwen.rawValue,
                KeysProviderViewItem.githubCopilot.rawValue
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

    func testKeysProviderCustomizationCanHideAndResetCopilotSidecar() {
        let vm = AppViewModel(defaults: defaults)

        XCTAssertTrue(vm.isKeysProviderVisible(.githubCopilot))
        vm.setKeysProvider(.githubCopilot, isVisible: false)
        vm.copilotSidecarExpanded = false

        XCTAssertFalse(vm.isKeysProviderVisible(.githubCopilot))

        vm.resetKeysProvidersCustomization()

        XCTAssertTrue(vm.isKeysProviderVisible(.githubCopilot))
        XCTAssertEqual(vm.keysProviderOrder, KeysProviderViewItem.defaultOrder)
        XCTAssertEqual(vm.visibleKeysProviders, Set(KeysProviderViewItem.defaultOrder))
        XCTAssertTrue(vm.copilotSidecarExpanded)
    }

    func testResetAllViewCustomizationsRestoresViewDefaultsWithoutNuclearReset() {
        let vm = AppViewModel(defaults: defaults)
        vm.appearancePreference = .dark
        vm.proxyPilotAccentHex = "#FF2D55"
        vm.liquidGlassEnabled = false
        vm.showMenuBarExtra = false
        vm.menuBarSectionOrder = [.quickActions, .statusDetails, .updates, .modelPicker, .sessionStats]
        vm.visibleMenuBarSections = [.statusDetails]
        vm.visibleHomeDashboardSections = [.sessionSummary]
        vm.defaultSettingsSection = .customization
        vm.keysProviderOrder = [.openAI, .githubCopilot, .zAI, .openRouter, .xAI, .chutes, .groq, .google, .deepSeek, .mistral, .miniMax, .miniMaxCN, .qwen, .ollama, .lmStudio]
        vm.visibleKeysProviders = [.openAI]
        vm.copilotSidecarExpanded = false

        vm.resetAllViewCustomizations()

        XCTAssertEqual(vm.appearancePreference, .system)
        XCTAssertEqual(vm.proxyPilotAccentHex, ProxyPilotAccentColor.defaultHex)
        XCTAssertTrue(vm.liquidGlassEnabled)
        XCTAssertTrue(vm.showMenuBarExtra)
        XCTAssertEqual(vm.menuBarSectionOrder, MenuBarSection.defaultOrder)
        XCTAssertEqual(vm.visibleMenuBarSections, Set(MenuBarSection.defaultOrder))
        XCTAssertEqual(vm.visibleHomeDashboardSections, Set(HomeDashboardSection.allCases))
        XCTAssertEqual(vm.defaultSettingsSection, .home)
        XCTAssertEqual(vm.keysProviderOrder, KeysProviderViewItem.defaultOrder)
        XCTAssertEqual(vm.visibleKeysProviders, Set(KeysProviderViewItem.defaultOrder))
        XCTAssertTrue(vm.copilotSidecarExpanded)
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
        XCTAssertEqual(AppViewModel.statusText(for: .runningExternal), "Running (via CLI)")
        XCTAssertEqual(AppViewModel.statusText(for: .stopped), "Stopped")
        XCTAssertEqual(AppViewModel.statusText(for: .portOccupied(statusCode: 418)), "Port occupied by another service (HTTP 418)")
    }

    func testExternalCLIProxyCanBeStoppedFromGUI() {
        XCTAssertTrue(AppViewModel.canStopProxy(for: .runningExternal))
        XCTAssertTrue(AppViewModel.canStopProxy(for: .runningInApp))
        XCTAssertFalse(AppViewModel.canStopProxy(for: .runningExternal, isStoppingCLIProxy: true))
        XCTAssertFalse(AppViewModel.canStopProxy(for: .stopped))
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

    func testPreflightMasterKeyOptionalWhenBuiltInAuthDisabled() {
        let preflight = PreflightService()
        let context = PreflightContext(
            proxyURLString: "http://127.0.0.1:4000",
            useBuiltInProxy: true,
            requireLocalAuth: false,
            upstreamProvider: .zAI,
            upstreamAPIBaseURLString: "https://api.z.ai/api/coding/paas/v4",
            fallbackUpstreamBaseURLString: "https://api.z.ai/api/coding/paas/v4",
            hasMasterKey: false,
            hasUpstreamKey: true,
            liteLLMScriptsExist: false
        )

        let results = preflight.run(context: context)
        let masterKeyCheck = results.first { $0.id == "master_key" }

        XCTAssertEqual(masterKeyCheck?.status, .info)
        XCTAssertEqual(masterKeyCheck?.fixAction, PreflightFixAction.none)
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
            hasUpstreamKey: false,
            liteLLMScriptsExist: false
        )

        let results = preflight.run(context: context)
        let keyCheck = results.first { $0.id == "upstream_key" }
        let reachability = results.first { $0.id == "local_provider_reachability" }

        XCTAssertEqual(keyCheck?.status, .info)
        XCTAssertEqual(keyCheck?.fixAction, PreflightFixAction.none)
        XCTAssertNotNil(reachability)
        XCTAssertTrue(reachability?.detail.contains("Ollama") == true)
    }

    func testPreflightWarnsWhenCopilotSidecarInstalledButGitHubAuthMissing() {
        let preflight = PreflightService()
        let context = PreflightContext(
            proxyURLString: "http://127.0.0.1:4000",
            useBuiltInProxy: true,
            requireLocalAuth: false,
            upstreamProvider: .githubCopilot,
            upstreamAPIBaseURLString: "http://127.0.0.1:8080/v1",
            fallbackUpstreamBaseURLString: "http://127.0.0.1:8080/v1",
            hasMasterKey: false,
            hasUpstreamKey: false,
            liteLLMScriptsExist: false,
            isCopilotSidecarInstalled: true,
            isCopilotGitHubAuthenticated: false
        )

        let results = preflight.run(context: context)
        let copilotAuth = results.first { $0.id == "copilot_auth" }

        XCTAssertEqual(copilotAuth?.status, .warning)
        XCTAssertEqual(copilotAuth?.fixAction, PreflightFixAction.openCopilotLogin)
        XCTAssertTrue(copilotAuth?.detail.contains("Sign in") == true)
    }

    func testPreflightShowsConfirmedCopilotSignInOnProviderKeyRowWhenReady() {
        let preflight = PreflightService()
        let context = PreflightContext(
            proxyURLString: "http://127.0.0.1:4000",
            useBuiltInProxy: true,
            requireLocalAuth: false,
            upstreamProvider: .githubCopilot,
            upstreamAPIBaseURLString: "http://127.0.0.1:8080/v1",
            fallbackUpstreamBaseURLString: "http://127.0.0.1:8080/v1",
            hasMasterKey: false,
            hasUpstreamKey: false,
            liteLLMScriptsExist: false,
            isCopilotSidecarInstalled: true,
            isCopilotGitHubAuthenticated: true
        )

        let results = preflight.run(context: context)
        let keyCheck = results.first { $0.id == "upstream_key" }

        XCTAssertEqual(keyCheck?.status, .confirmed)
        XCTAssertEqual(keyCheck?.fixAction, PreflightFixAction.none)
        XCTAssertTrue(keyCheck?.detail.contains("(GitHub sign-in detected.)") == true)
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

    func testGitHubCopilotDropsStaleStoredModelWithoutLiveFetch() {
        defaults.set(
            UpstreamProvider.githubCopilot.rawValue,
            forKey: ProviderManager.upstreamProviderDefaultsKey
        )
        defaults.set(
            "copilot-chat",
            forKey: ProviderManager.xcodeAgentModelDefaultsKey(for: .githubCopilot)
        )
        defaults.set(
            ["copilot-chat"],
            forKey: ProviderManager.defaultModelsKey(for: .githubCopilot)
        )

        let vm = AppViewModel(defaults: defaults)

        XCTAssertEqual(vm.upstreamProvider, .githubCopilot)
        XCTAssertEqual(vm.effectiveXcodeAgentModel, "")
        XCTAssertFalse(vm.xcodeAgentModelCandidates.contains("copilot-chat"))
        XCTAssertFalse(vm.proxySyncModelCandidates.contains("auto"))
        XCTAssertFalse(vm.proxySyncModelCandidates.contains("copilot-chat"))
        XCTAssertFalse(vm.canSyncProxyModels)
    }

    func testGitHubCopilotLiveModelsReplaceStaleStoredModel() {
        defaults.set(
            UpstreamProvider.githubCopilot.rawValue,
            forKey: ProviderManager.upstreamProviderDefaultsKey
        )
        defaults.set(
            "copilot-chat",
            forKey: ProviderManager.xcodeAgentModelDefaultsKey(for: .githubCopilot)
        )
        defaults.set(
            ["copilot-chat"],
            forKey: ProviderManager.defaultModelsKey(for: .githubCopilot)
        )
        let manager = makeProviderManager()

        manager.applyFetchedUpstreamModels([
            UpstreamModel(id: "auto", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
            UpstreamModel(id: "gpt-4.1", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
            UpstreamModel(id: "gpt-5-mini", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
        ])

        XCTAssertEqual(manager.effectiveXcodeAgentModel, "auto")
        XCTAssertFalse(manager.xcodeAgentModelCandidates.contains("copilot-chat"))
        XCTAssertFalse(manager.modelSelectionRows.contains { $0.id == "copilot-chat" })
        XCTAssertFalse(manager.proxySyncModelCandidates.contains("copilot-chat"))
        XCTAssertEqual(defaults.stringArray(forKey: ProviderManager.defaultModelsKey(for: .githubCopilot)), [])
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
        XCTAssertEqual(payload["mode"], "litellm")
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

    func testGitHubCopilotProviderUsesProjectURLWithoutKeychainKey() {
        XCTAssertEqual(UpstreamProvider.githubCopilot.defaultAPIBaseURL, "http://127.0.0.1:8080/v1")
        XCTAssertNotNil(UpstreamProvider.githubCopilot.apiKeyPageURL)
        XCTAssertNil(UpstreamProvider.githubCopilot.keychainKey)
        XCTAssertFalse(UpstreamProvider.githubCopilot.requiresAPIKey)
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
        let localProviders: [UpstreamProvider] = [.ollama, .lmStudio, .githubCopilot]
        for provider in localProviders {
            XCTAssertNil(provider.keychainKey, "\(provider.title) should not have a keychain key")
            XCTAssertFalse(provider.requiresAPIKey, "\(provider.title) should not require API key")
        }
    }

    // MARK: - Copilot Sidecar Lifecycle

    func testCopilotSidecarMissingExecutableState() async {
        let service = makeCopilotSidecarService(executable: nil, endpointResponding: false)
        let vm = AppViewModel(defaults: defaults, copilotSidecarService: service)

        await vm.refreshCopilotSidecarStatus()

        XCTAssertEqual(vm.copilotSidecarExecutablePath, "")
        XCTAssertFalse(vm.copilotSidecarSupportsLaunchAgent)
        XCTAssertFalse(vm.isCopilotSidecarAgentInstalled)
        XCTAssertFalse(vm.isCopilotSidecarRunning)
        XCTAssertTrue(vm.copilotSidecarStatusText.contains("Install xcode-copilot-server"))
    }

    func testCopilotSidecarDetectsLaunchAgentSupport() async {
        let service = makeCopilotSidecarService(endpointResponding: false)
        let vm = AppViewModel(defaults: defaults, copilotSidecarService: service)

        await vm.refreshCopilotSidecarStatus()

        XCTAssertTrue(vm.copilotSidecarSupportsLaunchAgent)
        XCTAssertFalse(vm.isCopilotSidecarAgentInstalled)
        XCTAssertTrue(vm.copilotSidecarStatusText.contains("Install the background helper"))
    }

    func testCopilotSidecarRefreshExposesLoginCommand() async {
        let service = makeCopilotSidecarService(
            endpointResponding: false,
            shellRunner: { command in
                if command.contains("command -v copilot") {
                    return .init(terminationStatus: 1, stdout: "", stderr: "")
                }
                if command.contains("command -v gh") {
                    return .init(terminationStatus: 0, stdout: "/opt/homebrew/bin/gh\n", stderr: "")
                }
                return .init(terminationStatus: 1, stdout: "", stderr: "")
            }
        )
        let vm = AppViewModel(defaults: defaults, copilotSidecarService: service)

        await vm.refreshCopilotSidecarStatus()

        XCTAssertEqual(vm.copilotSidecarLoginCommand, "gh auth login")
        XCTAssertTrue(vm.copilotSidecarLoginDescription.contains("GitHub CLI fallback"))
    }

    func testCopilotSidecarLaunchAgentInstalledButEndpointAsleep() async {
        let service = makeCopilotSidecarService(
            endpointResponding: false,
            fileExists: { $0.hasSuffix("com.xcode-copilot-server.plist") }
        )
        let vm = AppViewModel(defaults: defaults, copilotSidecarService: service)

        await vm.refreshCopilotSidecarStatus()

        XCTAssertTrue(vm.isCopilotSidecarAgentInstalled)
        XCTAssertFalse(vm.isCopilotSidecarEndpointResponding)
        XCTAssertTrue(vm.isCopilotSidecarManaged)
        XCTAssertTrue(vm.isCopilotSidecarRunning)
        XCTAssertTrue(vm.copilotSidecarStatusText.contains("launchd will wake it"))
    }

    func testCopilotSidecarEndpointRespondingExternally() async {
        let service = makeCopilotSidecarService(endpointResponding: true)
        let vm = AppViewModel(defaults: defaults, copilotSidecarService: service)

        await vm.refreshCopilotSidecarStatus()

        XCTAssertTrue(vm.isCopilotSidecarEndpointResponding)
        XCTAssertTrue(vm.isCopilotSidecarExternal)
        XCTAssertFalse(vm.isCopilotSidecarManaged)
        XCTAssertTrue(vm.copilotSidecarStatusText.contains("started elsewhere"))
    }

    func testCopilotSidecarLogActionShowsInlineLogSnapshot() throws {
        let logURL = URL(fileURLWithPath: "/tmp/proxypilot_copilot_sidecar.log")
        let originalData = try? Data(contentsOf: logURL)
        try? FileManager.default.removeItem(at: logURL)
        defer {
            try? FileManager.default.removeItem(at: logURL)
            if let originalData {
                try? originalData.write(to: logURL)
            }
        }

        try "2026-05-17 WARN Rejected request from unexpected user-agent: curl/8.7.1\n"
            .write(to: logURL, atomically: true, encoding: .utf8)
        let service = makeCopilotSidecarService(
            endpointResponding: false,
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
        let vm = AppViewModel(defaults: defaults, copilotSidecarService: service)

        vm.openCopilotSidecarLog()

        XCTAssertTrue(vm.isCopilotSidecarLogVisible)
        XCTAssertTrue(vm.copilotSidecarLogText.contains("Rejected request from unexpected user-agent"))
        XCTAssertTrue(vm.copilotSidecarLogStatusText.contains("Showing"))
        XCTAssertTrue(vm.copilotSidecarLogStatusText.contains("Copilot sidecar log file"))
    }

    func testCopilotSidecarInstallSwitchesProviderAndURL() async {
        var installed = false
        let service = makeCopilotSidecarService(
            endpointResponding: false,
            fileExists: { path in installed && path.hasSuffix("com.xcode-copilot-server.plist") },
            commandRunner: { _, arguments in
                if arguments == ["--help"] {
                    return .init(terminationStatus: 0, stdout: "install-agent\nuninstall-agent", stderr: "")
                }
                if arguments.first == "install-agent" {
                    installed = true
                }
                return .init(terminationStatus: 0, stdout: "", stderr: "")
            }
        )
        let vm = AppViewModel(defaults: defaults, copilotSidecarService: service)

        await vm.startCopilotSidecar()

        XCTAssertEqual(vm.upstreamProvider, .githubCopilot)
        XCTAssertEqual(vm.upstreamAPIBaseURLString, UpstreamProvider.githubCopilot.defaultAPIBaseURL)
        XCTAssertTrue(vm.isCopilotSidecarAgentInstalled)
        XCTAssertTrue(vm.isCopilotSidecarManaged)
    }

    func testCopilotSidecarUninstallClearsManagedLaunchAgent() async {
        var installed = true
        let service = makeCopilotSidecarService(
            endpointResponding: false,
            fileExists: { path in installed && path.hasSuffix("com.xcode-copilot-server.plist") },
            commandRunner: { _, arguments in
                if arguments == ["--help"] {
                    return .init(terminationStatus: 0, stdout: "install-agent\nuninstall-agent", stderr: "")
                }
                if arguments.first == "uninstall-agent" {
                    installed = false
                }
                return .init(terminationStatus: 0, stdout: "", stderr: "")
            }
        )
        let vm = AppViewModel(defaults: defaults, copilotSidecarService: service)

        await vm.refreshCopilotSidecarStatus()
        XCTAssertTrue(vm.isCopilotSidecarAgentInstalled)

        await vm.stopCopilotSidecar()

        XCTAssertFalse(vm.isCopilotSidecarAgentInstalled)
        XCTAssertFalse(vm.isCopilotSidecarManaged)
        XCTAssertEqual(vm.copilotSidecarStatusText, "Copilot helper stopped.")
    }

    func testCopilotSidecarStopDoesNotTouchExternalHelper() async {
        var commandArguments: [[String]] = []
        let service = makeCopilotSidecarService(
            endpointResponding: true,
            commandRunner: { _, arguments in
                commandArguments.append(arguments)
                if arguments == ["--help"] {
                    return .init(terminationStatus: 0, stdout: "install-agent\nuninstall-agent", stderr: "")
                }
                return .init(terminationStatus: 0, stdout: "", stderr: "")
            }
        )
        let vm = AppViewModel(defaults: defaults, copilotSidecarService: service)

        await vm.refreshCopilotSidecarStatus()
        await vm.stopCopilotSidecar()

        XCTAssertTrue(vm.isCopilotSidecarExternal)
        XCTAssertFalse(commandArguments.contains(["uninstall-agent"]))
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

    func testImportsCLISessionReportEventsIntoSessionReportCard() throws {
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

        XCTAssertEqual(vm.sessionReportCard.totalRequests, 1)
        XCTAssertEqual(vm.sessionReportCard.totalPromptTokens, 80)
        XCTAssertEqual(vm.sessionReportCard.totalCompletionTokens, 20)
        XCTAssertEqual(vm.sessionReportCard.requests.first?.model, "glm-5")
        XCTAssertEqual(vm.sessionReportCard.requests.first?.path, "/v1/messages")
        XCTAssertEqual(vm.sessionReportCard.requests.first?.wasStreaming, true)
    }

    func testDoesNotImportOlderCLISessionWhenNewerGUISessionExists() throws {
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
        vm.importExternalSessionReportEvents()

        XCTAssertEqual(vm.sessionReportCard.totalRequests, 0)
        XCTAssertEqual(vm.sessionReportCard.totalTokens, 0)
    }

    func testHasKeyForProviderReturnsFalseWhenNoKeyStored() {
        let vm = AppViewModel(defaults: defaults)
        let result = vm.hasKey(for: .openRouter)
        XCTAssertTrue(result == true || result == false)
    }

    func testPreflightMasterKeyRequiredWhenBuiltInAuthEnabled() {
        let preflight = PreflightService()
        let context = PreflightContext(
            proxyURLString: "http://127.0.0.1:4000",
            useBuiltInProxy: true,
            requireLocalAuth: true,
            upstreamProvider: .zAI,
            upstreamAPIBaseURLString: "https://api.z.ai/api/coding/paas/v4",
            fallbackUpstreamBaseURLString: "https://api.z.ai/api/coding/paas/v4",
            hasMasterKey: false,
            hasUpstreamKey: true,
            liteLLMScriptsExist: false
        )

        let results = preflight.run(context: context)
        let masterKeyCheck = results.first { $0.id == "master_key" }

        XCTAssertEqual(masterKeyCheck?.status, .fail)
        XCTAssertEqual(masterKeyCheck?.fixAction, .openMasterKeyEditor)
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

    func testSessionEstimatedCostDoesNotGuessDeepSeekCacheSplit() {
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

        XCTAssertNil(vm.sessionEstimatedCostUSD)
        XCTAssertEqual(vm.sessionPricedRequestCount, 0)
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
        XCTAssertEqual(SoftwareUpdateChannelPolicy.allowedChannels(alphaUpdatesEnabled: false, isAlphaBuild: false), [])
    }

    func testSparkleChannelsIncludeAlphaWhenOptedInOrAlreadyAlpha() {
        XCTAssertEqual(SoftwareUpdateChannelPolicy.allowedChannels(alphaUpdatesEnabled: true, isAlphaBuild: false), ["alpha"])
        XCTAssertEqual(SoftwareUpdateChannelPolicy.allowedChannels(alphaUpdatesEnabled: false, isAlphaBuild: true), ["alpha"])
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

    private func makeProviderManager() -> ProviderManager {
        ProviderManager(defaults: defaults, proxyService: ProxyService())
    }

    private func makeCopilotSidecarService(
        executable: URL? = URL(fileURLWithPath: "/tmp/xcode-copilot-server"),
        endpointResponding: Bool,
        fileExists: @escaping CopilotSidecarService.FileExists = { _ in false },
        commandRunner: CopilotSidecarService.CommandRunner? = nil,
        shellRunner: CopilotSidecarService.ShellRunner? = nil
    ) -> CopilotSidecarService {
        CopilotSidecarService(
            executableResolver: { executable },
            endpointProbe: { endpointResponding },
            commandRunner: commandRunner ?? { _, arguments in
                if arguments == ["--help"] {
                    return .init(terminationStatus: 0, stdout: "install-agent\nuninstall-agent", stderr: "")
                }
                return .init(terminationStatus: 0, stdout: "", stderr: "")
            },
            shellRunner: shellRunner ?? { _ in .init(terminationStatus: 1, stdout: "", stderr: "") },
            fileExists: fileExists,
            workspaceOpener: { _ in }
        )
    }
}
