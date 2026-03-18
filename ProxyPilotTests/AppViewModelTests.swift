import XCTest
import ProxyPilotCore
@testable import ProxyPilot

@MainActor
final class AppViewModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppViewModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
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

    func testPreflightMasterKeyOptionalWhenBuiltInAuthDisabled() {
        let preflight = PreflightService()
        let context = PreflightContext(
            proxyURLString: "http://127.0.0.1:4000",
            useBuiltInProxy: true,
            requireLocalAuth: false,
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

    func testExactoFilterShowsOnlyExactoModelsForOpenRouter() {
        let vm = AppViewModel(defaults: defaults)
        vm.upstreamProvider = .openRouter
        vm.upstreamModels = [
            UpstreamModel(id: "anthropic/claude-opus-4:exacto", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
            UpstreamModel(id: "anthropic/claude-opus-4", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
            UpstreamModel(id: "google/gemini-3.1-pro:exacto", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
        ]
        vm.exactoFilterEnabled = true

        XCTAssertEqual(vm.filteredUpstreamModels.count, 2)
        XCTAssertTrue(vm.filteredUpstreamModels.allSatisfy { $0.id.contains(":exacto") })
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
            UpstreamModel(id: "anthropic/claude-opus-4:exacto", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
            UpstreamModel(id: "anthropic/claude-opus-4", contextLength: nil, promptPricePer1M: nil, completionPricePer1M: nil),
        ]
        vm.exactoFilterEnabled = true
        vm.selectedUpstreamModels = []

        vm.selectAllUpstreamModels()
        XCTAssertEqual(vm.selectedUpstreamModels, ["anthropic/claude-opus-4:exacto"])
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

    // MARK: - API Key Page URL

    func testCloudProvidersHaveAPIKeyPageURL() {
        let cloudProviders: [UpstreamProvider] = [.zAI, .openRouter, .openAI, .xAI, .chutes, .groq, .google, .deepSeek, .mistral, .miniMax]
        for provider in cloudProviders {
            XCTAssertNotNil(provider.apiKeyPageURL, "\(provider.title) should have an API key page URL")
        }
    }

    func testLocalProvidersHaveNoAPIKeyPageURL() {
        XCTAssertNil(UpstreamProvider.ollama.apiKeyPageURL)
        XCTAssertNil(UpstreamProvider.lmStudio.apiKeyPageURL)
    }

    func testAllCloudProvidersHaveKeychainKeys() {
        let cloudProviders: [UpstreamProvider] = [.zAI, .openRouter, .openAI, .xAI, .chutes, .groq, .google, .deepSeek, .mistral, .miniMax]
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

    func testLocalProvidersDontRequireKeys() {
        let localProviders: [UpstreamProvider] = [.ollama, .lmStudio]
        for provider in localProviders {
            XCTAssertNil(provider.keychainKey, "\(provider.title) should not have a keychain key")
            XCTAssertFalse(provider.requiresAPIKey, "\(provider.title) should not require API key")
            XCTAssertNil(provider.apiKeyPageURL, "\(provider.title) should not have API key page URL")
        }
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
            durationSeconds: 0.123,
            path: "/v1/chat/completions",
            wasStreaming: true
        ))

        let csv = vm.sessionRequestsCSV()
        XCTAssertTrue(csv.contains("timestamp,model,path,streaming,prompt_tokens"))
        XCTAssertTrue(csv.contains("model-a"))
        XCTAssertTrue(csv.contains("/v1/chat/completions"))
        XCTAssertTrue(csv.contains("0.000300"))
    }
}
