import Foundation
import ProxyPilotCore
import Testing

@Test func daemonBootstrapArgumentsCarryPersistedRoutingWithoutSecrets() {
    let settings = AgentLaunchSettings(
        port: 4321,
        modelID: "glm-5",
        upstreamLabel: "Z.ai",
        providerID: "zai",
        upstreamURL: "https://api.example.test/v1",
        promptCachingMode: .observeOnly
    )

    #expect(ProxyDaemonBootstrapper.commandArguments(settings: settings) == [
        "start", "--daemon", "--port", "4321", "--json",
        "--provider", "zai",
        "--upstream-url", "https://api.example.test/v1",
        "--model", "glm-5",
        "--prompt-caching", "observe-only",
    ])
}

@Test func customProviderBootstrapRequestsCredentialOverStandardInput() {
    let settings = AgentLaunchSettings(
        providerID: "openai",
        upstreamURL: "https://custom.example.test/v1",
        credentialKey: "CUSTOM_123"
    )

    let arguments = ProxyDaemonBootstrapper.commandArguments(
        settings: settings,
        credentialViaStandardInput: true
    )

    #expect(arguments.contains("--key-stdin"))
    #expect(!arguments.contains("CUSTOM_123"))
}

@Test func cliLocatorPrefersExplicitOverrideInStrippedEnvironment() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("proxypilot-cli-locator-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("proxypilot")
    FileManager.default.createFile(atPath: executable.path, contents: Data())
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    let result = ProxyPilotCLIExecutableLocator.locate(
        environment: ["PROXYPILOT_CLI_PATH": executable.path],
        currentExecutableURL: nil,
        home: root
    )

    #expect(result?.standardizedFileURL == executable.standardizedFileURL)
}

@Test func adapterLaunchPlanUsesOnlyManagedRuntimeAndLocalProxy() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("proxypilot-agent-plan-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = root.appendingPathComponent("runtime")
    let claudeConfig = root.appendingPathComponent("claude-config")
    let layout = ManagedAgentRuntimeLayout(root: runtime, claudeConfigDirectory: claudeConfig)
    try FileManager.default.createDirectory(
        at: layout.nodeExecutable.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: layout.nodeExecutable.path, contents: Data())
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: layout.nodeExecutable.path
    )
    try FileManager.default.createDirectory(
        at: layout.adapterEntryPoint.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: layout.adapterEntryPoint.path, contents: Data())

    let plan = try AgentAdapterLaunchPlan.make(
        settings: AgentLaunchSettings(port: 4555, modelID: "test-model"),
        localProxyCredential: "pp_local_test-capability",
        layout: layout,
        inheritedEnvironment: [
            "PATH": "/attacker/bin",
            "ANTHROPIC_AUTH_TOKEN": "real-secret",
            "TMPDIR": "/tmp/test",
        ],
        home: root
    )

    #expect(plan.executable == layout.nodeExecutable)
    #expect(plan.arguments == [layout.nodeExecutable.path, layout.adapterEntryPoint.path])
    #expect(plan.environment["PATH"] == "\(runtime.appendingPathComponent("bin").path):/usr/bin:/bin")
    #expect(plan.environment["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:4555")
    #expect(plan.environment["ANTHROPIC_AUTH_TOKEN"] == "pp_local_test-capability")
    #expect(plan.environment["ANTHROPIC_AUTH_TOKEN"] != "real-secret")
    #expect(plan.environment["ANTHROPIC_MODEL"] == "test-model")
    #expect(plan.environment["CLAUDE_CONFIG_DIR"] == claudeConfig.path)
    #expect(plan.environment["TMPDIR"] == "/tmp/test")
}

@Test func adapterLaunchPlanFailsLoudlyWhenRuntimeIsMissing() {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("proxypilot-agent-missing-tests-\(UUID().uuidString)")
    let layout = ManagedAgentRuntimeLayout(
        root: root.appendingPathComponent("runtime"),
        claudeConfigDirectory: root.appendingPathComponent("claude-config")
    )

    #expect(throws: AgentAdapterLaunchError.nodeMissing(layout.nodeExecutable.path)) {
        try AgentAdapterLaunchPlan.make(
            settings: AgentLaunchSettings(),
            localProxyCredential: "pp_local_test-capability",
            layout: layout,
            home: root
        )
    }
}

@Test func launchTelemetryAppendsPrivateNDJSON() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("proxypilot-agent-telemetry-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("agent-launches.ndjson")
    let settings = AgentLaunchSettings(port: 4666, modelID: "model-a", upstreamLabel: "Local")

    try AgentLaunchTelemetry.record(.init(name: "first", settings: settings), to: url)
    try AgentLaunchTelemetry.record(.init(name: "second", settings: settings), to: url)

    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 2)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}
