import Testing
@testable import proxypilot

struct CLIProxyRuntimeTests {
    @Test func startCommandWithLongPortFlagMatchesRequestedPort() {
        #expect(CLIProxyRuntime.commandIncludesPort("proxypilot start --port 4024 --provider ollama", port: 4024))
    }

    @Test func startCommandWithEqualsPortFlagMatchesRequestedPort() {
        #expect(CLIProxyRuntime.commandIncludesPort("proxypilot start --port=4024 --provider ollama", port: 4024))
    }

    @Test func startCommandWithShortPortFlagMatchesRequestedPort() {
        #expect(CLIProxyRuntime.commandIncludesPort("proxypilot start -p 4024 --provider ollama", port: 4024))
    }

    @Test func differentPortDoesNotMatch() {
        #expect(!CLIProxyRuntime.commandIncludesPort("proxypilot start --port 4000 --provider ollama", port: 4024))
    }

    @Test func substringPortDoesNotMatch() {
        #expect(!CLIProxyRuntime.commandIncludesPort("proxypilot start --port 14024 --provider ollama", port: 4024))
    }
}

