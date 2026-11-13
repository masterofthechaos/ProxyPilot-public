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
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pp-plan-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = ManagedAgentRuntimeLayout(root: root.appendingPathComponent("runtime"), configDirectory: root.appendingPathComponent("xcode"))
    try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: layout.engineExecutable.path, contents: Data())
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: layout.engineExecutable.path)
    let metadata = UpstreamModel(id: "test", contextLength: 1_000_000, promptPricePer1M: nil, completionPricePer1M: nil,
        inputModalities: ["text", "image", "file"], maximumOutputTokens: 100_000)
    let plan = try AgentAdapterLaunchPlan.make(settings: .init(port: 4555, modelMetadata: metadata),
        localProxyCredential: "pp_local_test", layout: layout,
        inheritedEnvironment: ["PATH": "/attacker", "ANTHROPIC_AUTH_TOKEN": "secret", "OPENAI_API_KEY": "secret", "OPENCODE_CONFIG_CONTENT": "{}", "TMPDIR": "/tmp/test"], home: root)
    #expect(plan.executable == layout.engineExecutable)
    #expect(plan.arguments == [layout.engineExecutable.path, "acp", "--hostname", "127.0.0.1"])
    #expect(plan.environment["ANTHROPIC_AUTH_TOKEN"] == nil)
    #expect(plan.environment["OPENAI_API_KEY"] == nil)
    #expect(plan.environment["XDG_DATA_HOME"] == layout.configDirectory.appendingPathComponent("data").path)
    #expect(plan.environment["TMPDIR"] == "/tmp/test")
    let config = try #require(try JSONSerialization.jsonObject(with: Data(plan.environment["OPENCODE_CONFIG_CONTENT"]!.utf8)) as? [String: Any])
    #expect(config["model"] as? String == "proxypilot/proxypilot-active")
    let providers = config["provider"] as! [String: [String: Any]]
    let options = providers["proxypilot"]!["options"] as! [String: Any]
    #expect(options["baseURL"] as? String == "http://127.0.0.1:4555/v1")
    #expect(options["apiKey"] as? String == "pp_local_test")
    let model = (providers["proxypilot"]!["models"] as! [String: [String: Any]])["proxypilot-active"]!
    #expect((model["limit"] as? [String: Int]) == ["context": 1_000_000, "output": 8_000])
    #expect((model["modalities"] as? [String: [String]])?["input"] == ["text", "image"])
    #expect((config["agent"] as? [String: [String: Bool]])?["title"]?["disable"] == true)
    let plugin = layout.configDirectory.appendingPathComponent("attribution.mjs")
    #expect(try String(contentsOf: plugin, encoding: .utf8) == AgentAdapterLaunchPlan.attributionPlugin)
}

@Test func adapterLaunchPlanFailsLoudlyWhenRuntimeIsMissing() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let layout = ManagedAgentRuntimeLayout(root: root, configDirectory: root)
    #expect(throws: AgentAdapterLaunchError.engineMissing(layout.engineExecutable.path)) {
        try AgentAdapterLaunchPlan.make(settings: .init(), localProxyCredential: "test", layout: layout, home: root)
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

/// Emits the production launch plan for the no-inference ACP contract harness.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PROXYPILOT_ACP_FIXTURE_ROOT"] != nil))
func exportOpenCodeACPFixturePlan() throws {
    let env = ProcessInfo.processInfo.environment
    let root = URL(fileURLWithPath: try #require(env["PROXYPILOT_ACP_FIXTURE_ROOT"]))
    let engine = URL(fileURLWithPath: try #require(env["PROXYPILOT_ACP_FIXTURE_ENGINE"]))
    let layout = ManagedAgentRuntimeLayout(root: root.appendingPathComponent("runtime"), configDirectory: root.appendingPathComponent("profile"))
    try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: layout.engineExecutable, withDestinationURL: engine)
    let metadata = UpstreamModel(id: "fixture", contextLength: 100_000, promptPricePer1M: nil, completionPricePer1M: nil, inputModalities: ["text", "image"])
    let plan = try AgentAdapterLaunchPlan.make(settings: .init(port: UInt16(env["PROXYPILOT_ACP_FIXTURE_PORT"]!)!, modelMetadata: metadata), localProxyCredential: "pp_local_fixture", layout: layout, inheritedEnvironment: ["XDG_CONFIG_HOME": root.appendingPathComponent("user-config").path], home: root)
    let data = try JSONSerialization.data(withJSONObject: ["executable": plan.executable.path, "arguments": plan.arguments, "environment": plan.environment], options: [.sortedKeys])
    try data.write(to: root.appendingPathComponent("plan.json"))
}
