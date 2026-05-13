import MCP
import ProxyPilotCore
import Testing
@testable import proxypilot

struct MCPArgumentValidatorTests {
    @Test func stringPortIsRejectedInsteadOfDefaulting() {
        let result = MCPArgumentValidator.port(
            Value.string("4022"),
            default: 4000,
            tool: "proxy_start"
        )

        #expect(result == .failure(code: "E030", message: "Invalid port argument. Expected integer 0 or 1024-65535."))
    }

    @Test func outOfRangePortIsRejected() {
        let result = MCPArgumentValidator.port(
            Value.int(80),
            default: 4000,
            tool: "proxy_start"
        )

        #expect(result == .failure(code: "E030", message: "Invalid port 80. Use 1024-65535, or 0 for auto-assign."))
    }

    @Test func zeroPortCanBeRejectedForXcodeConfig() {
        let result = MCPArgumentValidator.port(
            Value.int(0),
            default: 4000,
            tool: "xcode_config_install",
            allowZero: false
        )

        #expect(result == .failure(code: "E030", message: "Invalid port 0. Use 1024-65535."))
    }

    @Test func validPortReturnsRequestedPort() {
        let result = MCPArgumentValidator.port(
            Value.int(4024),
            default: 4000,
            tool: "proxy_status"
        )

        #expect(result == .success(4024))
    }

    @Test func missingPortReturnsDefaultPort() {
        let result = MCPArgumentValidator.port(
            nil,
            default: 4000,
            tool: "proxy_status"
        )

        #expect(result == .success(4000))
    }

    @Test func unknownProviderIsRejected() {
        let result = MCPArgumentValidator.provider("not-a-provider", tool: "preflight")

        #expect(result.isFailure(code: "E001"))
    }

    @Test func nonStringProviderArgumentIsRejectedInsteadOfDefaulting() {
        let result = MCPArgumentValidator.provider(
            Value.int(123),
            default: "openai",
            tool: "preflight"
        )

        #expect(result.isFailure(code: "E001"))
    }

    @Test func omittedProviderArgumentUsesDefaultProvider() {
        let result = MCPArgumentValidator.provider(
            nil,
            default: "ollama",
            tool: "preflight"
        )

        #expect(result == .success(.ollama))
    }

    @Test func knownProviderIsAccepted() {
        let result = MCPArgumentValidator.provider("ollama", tool: "preflight")

        #expect(result == .success(.ollama))
    }

    @Test func invalidModelFilterIsRejectedBeforeNetwork() {
        let result = MCPArgumentValidator.modelFilter("not-a-filter", tool: "list_upstream_models")

        #expect(result == .failure(code: "E034", message: "Invalid model filter: not-a-filter. Use exacto, verified, tool-calling, or chat."))
    }

    @Test func validModelFilterIsAccepted() {
        let result = MCPArgumentValidator.modelFilter("tool-calling", tool: "list_upstream_models")

        #expect(result == .success("tool-calling"))
    }

    @Test func nonStringModelFilterArgumentIsRejectedInsteadOfDefaulting() {
        let result = MCPArgumentValidator.modelFilter(Value.int(123), tool: "list_upstream_models")

        #expect(result.isFailure(code: "E034"))
    }

    @Test func missingModelFilterIsAccepted() {
        let result = MCPArgumentValidator.modelFilter(nil as Value?, tool: "list_upstream_models")

        #expect(result == .success(nil))
    }

    @Test func nonBoolArgumentIsRejectedInsteadOfDefaulting() {
        let result = MCPArgumentValidator.bool(
            Value.string("true"),
            default: false,
            name: "metadata",
            tool: "list_upstream_models"
        )

        #expect(result == .failure(code: "E035", message: "Invalid metadata argument. Expected boolean."))
    }

    @Test func nonStringOptionalArgumentIsRejectedInsteadOfDefaulting() {
        let result = MCPArgumentValidator.string(
            Value.int(123),
            default: nil,
            name: "url",
            tool: "list_upstream_models"
        )

        #expect(result == .failure(code: "E035", message: "Invalid url argument. Expected string."))
    }

    @Test func omittedOptionalStringArgumentUsesDefault() {
        let result = MCPArgumentValidator.string(
            nil,
            default: "fallback",
            name: "url",
            tool: "proxy_start"
        )

        #expect(result == .success("fallback"))
    }
}
