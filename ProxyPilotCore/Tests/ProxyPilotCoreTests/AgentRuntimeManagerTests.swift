import Foundation
@testable import ProxyPilotCore
import Testing

private func makeRuntimeFixture() throws -> (root: URL, layout: ManagedAgentRuntimeLayout, manager: AgentRuntimeManager) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-runtime-\(UUID().uuidString)")
    let layout = ManagedAgentRuntimeLayout(root: root.appendingPathComponent("runtime"), configDirectory: root.appendingPathComponent("config"))
    try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
    try Data("engine-fixture".utf8).write(to: layout.engineExecutable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: layout.engineExecutable.path)
    return (root, layout, AgentRuntimeManager(layout: layout, architecture: "arm64"))
}

@Test func runtimeStatusReportsNotInstalled() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    #expect(AgentRuntimeManager(layout: .init(root: root, configDirectory: root)).status() == .notInstalled)
}

@Test func runtimeStatusVerifiesExecutableAndPinnedArchive() throws {
    let f = try makeRuntimeFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(f.manager.status() == .corrupt(reason: "Runtime manifest is missing or unreadable.", manifest: nil))
    let manifest = AgentRuntimeManifest(engineVersion: AgentRuntimeRelease.pinned.engineVersion, architecture: "arm64",
        archiveSHA256: AgentRuntimeRelease.pinned.archives["arm64"]!.sha256,
        executableSHA256: try AgentRuntimeManager.sha256(of: f.layout.engineExecutable))
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(to: f.manager.manifestURL)
    #expect(f.manager.status().isReady)
    try Data("modified".utf8).write(to: f.layout.engineExecutable)
    if case .corrupt = f.manager.status() {} else { Issue.record("Modified engine accepted") }
}

@Test func legacyManifestNeedsOpenCodeWithoutDeletingSessionData() throws {
    let f = try makeRuntimeFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    try Data(#"{"schema":1,"nodeVersion":"26.3.0"}"#.utf8).write(to: f.manager.manifestURL)
    if case .stale = f.manager.status() {} else { Issue.record("Legacy manifest accepted") }
    #expect(FileManager.default.fileExists(atPath: f.layout.engineExecutable.path))
}

@Test func pinnedReleaseContainsBothMacArchitectures() {
    #expect(AgentRuntimeRelease.pinned.engineVersion == "1.18.4")
    for architecture in ["arm64", "x86_64"] {
        #expect(AgentRuntimeRelease.pinned.archives[architecture]?.sha256.count == 64)
        #expect(AgentRuntimeRelease.pinned.archives[architecture]?.url.host == "github.com")
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PROXYPILOT_TEST_LIVE_RUNTIME_INSTALL"] == "1"))
func pinnedRuntimeInstallsInIsolatedDirectory() async throws {
    let f = try makeRuntimeFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let manifest = try await f.manager.install()
    #expect(manifest.engineVersion == AgentRuntimeRelease.pinned.engineVersion)
    #expect(f.manager.status().isReady)
}

@Test func executableLinksInstallAndRefreshStaleTargets() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-link-manager-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let launcher = root.appendingPathComponent("build/proxypilot-agent")
    let cli = root.appendingPathComponent("build/proxypilot")
    try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
    for executable in [launcher, cli] {
        FileManager.default.createFile(atPath: executable.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    let manager = AgentExecutableLinkManager(binDirectory: root.appendingPathComponent("bin"))

    try manager.install(launcherSource: launcher, cliSource: cli)
    #expect(manager.launcherStatus(expectedSource: launcher) == .ready)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: manager.cliURL.path) == cli.path)

    let replacement = root.appendingPathComponent("updated/proxypilot-agent")
    try FileManager.default.createDirectory(at: replacement.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: replacement.path, contents: Data())
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: replacement.path)
    #expect(manager.launcherStatus(expectedSource: replacement) == .staleTarget(launcher.path))

    try manager.install(launcherSource: replacement, cliSource: cli)
    #expect(manager.launcherStatus(expectedSource: replacement) == .ready)
}
