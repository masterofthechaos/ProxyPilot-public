import XCTest
import Darwin
import ProxyPilotCore
@testable import ProxyPilot

final class QwenTokenPlanTests: XCTestCase {
    @MainActor func testTokenPlanKeySavesInExistingQwenKeychainSlot() throws {
        let service = "proxypilot.qwen-tests." + UUID().uuidString
        let previousService = ProcessInfo.processInfo.environment["PROXYPILOT_KEYCHAIN_SERVICE"]
        let previousLegacyService = ProcessInfo.processInfo.environment["PROXYPILOT_LEGACY_KEYCHAIN_SERVICE"]
        setenv("PROXYPILOT_KEYCHAIN_SERVICE", service, 1)
        setenv("PROXYPILOT_LEGACY_KEYCHAIN_SERVICE", service + ".legacy", 1)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: service))
        defer {
            try? KeychainService.delete(key: .qwenAPIKey)
            defaults.removePersistentDomain(forName: service)
            if let previousService { setenv("PROXYPILOT_KEYCHAIN_SERVICE", previousService, 1) }
            else { unsetenv("PROXYPILOT_KEYCHAIN_SERVICE") }
            if let previousLegacyService { setenv("PROXYPILOT_LEGACY_KEYCHAIN_SERVICE", previousLegacyService, 1) }
            else { unsetenv("PROXYPILOT_LEGACY_KEYCHAIN_SERVICE") }
        }
        let vm = AppViewModel(defaults: defaults)
        XCTAssertTrue(vm.saveBrowserEndpoint(QwenAPIService.tokenPlanSingapore.endpoint!, selection: .builtIn(.qwen)))
        XCTAssertTrue(vm.saveBrowserKey(" sk-sp-fixture-not-a-real-key\n", selection: .builtIn(.qwen)))
        XCTAssertEqual(KeychainService.get(key: .qwenAPIKey), "sk-sp-fixture-not-a-real-key")
        XCTAssertTrue(vm.browserHasKey(.builtIn(.qwen)))
        XCTAssertNil(defaults.string(forKey: "QWEN_API_KEY"))
        XCTAssertEqual(vm.selectedUpstreamSelection, .none)
    }

    func testTokenPlanServicesUseDedicatedRegionalCredentialsAndLinks() throws {
        for (service, host, console) in [
            (QwenAPIService.tokenPlanSingapore, "token-plan.ap-southeast-1.maas.aliyuncs.com", "modelstudio.console.alibabacloud.com"),
            (.tokenPlanChina, "token-plan.cn-beijing.maas.aliyuncs.com", "bailian.console.aliyun.com")
        ] {
            let url = try XCTUnwrap(URL(string: XCTUnwrap(service.endpoint)))
            XCTAssertEqual(url.host, host)
            XCTAssertEqual(url.path, "/compatible-mode/v1")
            XCTAssertEqual(QwenAPIService(apiBaseURL: url), service)
            XCTAssertEqual(UpstreamProvider.qwen.apiKeyPageURL(apiBaseURL: url)?.host, console)
            XCTAssertTrue(try XCTUnwrap(UpstreamProvider.qwen.apiKeyPageURL(apiBaseURL: url)).path.contains("subscription/token-plan"))
            XCTAssertTrue(try XCTUnwrap(UpstreamProvider.qwen.apiKeyRegionHint(apiBaseURL: url)).contains("sk-sp-"))
            XCTAssertEqual(APIKeyValidator.validate("sk-sp-fixture-not-a-real-key", for: .qwen), .success)
        }
    }

    func testCustomAndNonOpenAIEndpointsDoNotClaimTokenPlanSetup() {
        for raw in [
            "https://token-plan.ap-southeast-1.maas.aliyuncs.com.evil.invalid/compatible-mode/v1",
            "https://token-plan.ap-southeast-1.maas.aliyuncs.com/apps/anthropic",
            "https://coding-intl.dashscope.aliyuncs.com/v1",
            "http://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
            "https://token-plan.ap-southeast-1.maas.aliyuncs.com:444/compatible-mode/v1"
        ] {
            let url = URL(string: raw)
            XCTAssertEqual(QwenAPIService(apiBaseURL: url), .custom)
            XCTAssertNil(UpstreamProvider.qwen.apiKeyPageURL(apiBaseURL: url))
        }
        let trailingSlash = URL(string: QwenAPIService.tokenPlanSingapore.endpoint! + "/")
        XCTAssertEqual(QwenAPIService(apiBaseURL: trailingSlash), .tokenPlanSingapore)
    }

    @MainActor func testSavedTokenPlanEndpointSurvivesSelectionAndRelaunchWithoutChangingOtherProviders() throws {
        let name = "QwenTokenPlanTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let vm = AppViewModel(defaults: defaults)
        vm.useBrowserModel(.idOnly("existing-model"), selection: .builtIn(.openAI))
        let existingEndpoint = vm.browserEndpoint(.builtIn(.openAI))
        let endpoint = try XCTUnwrap(QwenAPIService.tokenPlanSingapore.endpoint)
        XCTAssertTrue(vm.saveBrowserEndpoint(endpoint, selection: .builtIn(.qwen)))
        XCTAssertEqual(vm.selectedUpstreamSelection, .builtIn(.openAI))
        XCTAssertEqual(vm.selectedXcodeAgentModel, "existing-model")
        XCTAssertEqual(vm.browserEndpoint(.builtIn(.openAI)), existingEndpoint)

        vm.useBrowserModel(.idOnly("qwen4-max-preview"), selection: .builtIn(.qwen))
        XCTAssertEqual(vm.upstreamAPIBaseURLString, endpoint)
        let restored = AppViewModel(defaults: defaults)
        XCTAssertEqual(restored.selectedUpstreamSelection, .builtIn(.qwen))
        XCTAssertEqual(restored.upstreamAPIBaseURLString, endpoint)
        XCTAssertEqual(restored.effectiveXcodeAgentModel, "qwen4-max-preview")
        XCTAssertEqual(restored.browserEndpoint(.builtIn(.openAI)), existingEndpoint)
        XCTAssertTrue(try XCTUnwrap(restored.apiKeyRegionHint(for: .qwen)).contains("Token Plan"))
    }
}
