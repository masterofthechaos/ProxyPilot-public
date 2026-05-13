import XCTest
@testable import ProxyPilotCore

final class ProxyPilotDefaultsTests: XCTestCase {
    func testDefaultProvidersAreExplicitlyDivergent() {
        XCTAssertEqual(ProxyPilotDefaults.defaultCLIProvider, .openAI)
        XCTAssertEqual(ProxyPilotDefaults.defaultXcodeProvider, .zAI)
    }

    func testProviderHelpIncludesAllProviders() {
        for provider in UpstreamProvider.allCases {
            XCTAssertTrue(UpstreamProvider.cliOptionsDescription.contains(provider.rawValue))
        }
        XCTAssertTrue(UpstreamProvider.cliOptionsDescription.contains("github-copilot"))
    }

    func testDefaultAgentModelForXcodeProvider() {
        XCTAssertEqual(UpstreamProvider.zAI.defaultAgentModel, "glm-4.7")
    }
}
