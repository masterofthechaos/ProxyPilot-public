import Testing
import Foundation
@testable import proxypilot

struct CLIProxyRuntimeTests {
    @Test func processOutputDrainsMoreThanPipeCapacity() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let expected = Data(repeating: 0x61, count: 1_048_576)
        try expected.write(to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }
        #expect(CLIProxyRuntime.processOutput(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [fixture.path]) == expected)
    }

    @Test func processOutputReportsLaunchFailure() {
        #expect(CLIProxyRuntime.processOutput(executable: URL(fileURLWithPath: "/nonexistent/proxypilot-process"), arguments: []) == nil)
    }

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

    @Test func daemonStartArgumentsUseStdinForInlineKey() {
        let secret = "sk-secret-argv-regression"
        let configuration = CLIProxyRuntime.daemonSpawnConfiguration(
            port: 4024,
            provider: "zai",
            upstreamUrl: "https://api.example.test/v1",
            key: secret,
            model: "glm-5",
            promptCaching: .auto,
            json: true
        )

        #expect(!configuration.arguments.contains(secret))
        #expect(!configuration.arguments.contains("--key"))
        #expect(configuration.arguments.contains("--key-stdin"))
        #expect(configuration.inlineKeyForStdin == secret)
    }

    @Test func daemonLogFileIsCreatedPrivate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxypilot-cli-runtime-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("daemon.log")
        try CLIProxyRuntime.preparePrivateLogFile(at: logURL.path)

        let attributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
    }
}
