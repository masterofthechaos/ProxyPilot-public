import XCTest
@testable import ProxyPilot

@MainActor
final class CopilotSidecarServiceTests: XCTestCase {
    func testInstallAgentUsesOpenAILaunchdCommand() async throws {
        var installed = false
        var commands: [[String]] = []
        let service = makeService(
            endpointResponding: false,
            fileExists: { path in installed && path.hasSuffix("com.xcode-copilot-server.plist") },
            commandRunner: { _, arguments in
                commands.append(arguments)
                if arguments == ["--help"] {
                    return .init(terminationStatus: 0, stdout: "install-agent\nuninstall-agent", stderr: "")
                }
                if arguments.first == "install-agent" {
                    installed = true
                }
                return .init(terminationStatus: 0, stdout: "", stderr: "")
            }
        )

        try await service.installOrStart()

        XCTAssertEqual(commands.last, [
            "install-agent",
            "--proxy", "openai",
            "--port", "8080",
            "--log-level", "info",
            "--idle-timeout", "60"
        ])
    }

    func testStatusLaunchAgentInstalledButEndpointAsleep() async {
        let service = makeService(
            endpointResponding: false,
            fileExists: { $0.hasSuffix("com.xcode-copilot-server.plist") }
        )

        let status = await service.status()

        XCTAssertTrue(status.supportsLaunchAgent)
        XCTAssertTrue(status.isLaunchAgentInstalled)
        XCTAssertFalse(status.endpointResponding)
        XCTAssertTrue(status.isManaged)
        XCTAssertTrue(status.isRunning)
        XCTAssertFalse(status.isExternal)
        XCTAssertTrue(status.message.contains("launchd will wake it"))
    }

    func testStatusMissingExecutable() async {
        let service = makeService(executable: nil, endpointResponding: false)

        let status = await service.status()

        XCTAssertNil(status.executablePath)
        XCTAssertFalse(status.supportsLaunchAgent)
        XCTAssertFalse(status.isLaunchAgentInstalled)
        XCTAssertFalse(status.isRunning)
        XCTAssertTrue(status.message.contains("Install xcode-copilot-server"))
    }

    func testStatusPrefersCopilotLoginWhenCopilotCLIIsAvailable() async {
        let service = makeService(
            endpointResponding: false,
            shellRunner: { command in
                if command.contains("command -v copilot") {
                    return .init(terminationStatus: 0, stdout: "/opt/homebrew/bin/copilot\n", stderr: "")
                }
                if command.contains("command -v gh") {
                    return .init(terminationStatus: 0, stdout: "/opt/homebrew/bin/gh\n", stderr: "")
                }
                return .init(terminationStatus: 1, stdout: "", stderr: "")
            }
        )

        let status = await service.status()

        XCTAssertEqual(status.loginCommand, "copilot login")
        XCTAssertTrue(status.loginCommandDescription.contains("Copilot CLI"))
    }

    func testStatusFallsBackToGitHubLoginWhenCopilotCLIIsMissing() async {
        let service = makeService(
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

        let status = await service.status()

        XCTAssertEqual(status.loginCommand, "gh auth login")
        XCTAssertTrue(status.loginCommandDescription.contains("GitHub CLI fallback"))
    }

    func testStatusDetectsCompletedGitHubCLIAuthentication() async {
        let service = makeService(
            endpointResponding: false,
            shellRunner: { command in
                if command.contains("command -v copilot") {
                    return .init(terminationStatus: 1, stdout: "", stderr: "")
                }
                if command.contains("command -v gh") {
                    return .init(terminationStatus: 0, stdout: "/opt/homebrew/bin/gh\n", stderr: "")
                }
                if command.contains("gh auth status") {
                    return .init(
                        terminationStatus: 0,
                        stdout: "github.com\n  ✓ Logged in to github.com account masterofthechaos (keyring)\n",
                        stderr: ""
                    )
                }
                return .init(terminationStatus: 1, stdout: "", stderr: "")
            }
        )

        let status = await service.status()

        XCTAssertTrue(status.isGitHubAuthenticated)
        XCTAssertEqual(status.githubAccount, "masterofthechaos")
        XCTAssertNil(status.loginCommand)
        XCTAssertTrue(status.loginCommandDescription.contains("Signed in to GitHub as masterofthechaos"))
    }

    func testStatusEndpointRespondingExternally() async {
        let service = makeService(endpointResponding: true)

        let status = await service.status()

        XCTAssertTrue(status.endpointResponding)
        XCTAssertTrue(status.isExternal)
        XCTAssertFalse(status.isManaged)
        XCTAssertTrue(status.message.contains("started elsewhere"))
    }

    func testUninstallAgentUsesHelperCommand() async throws {
        var installed = true
        var commands: [[String]] = []
        let service = makeService(
            endpointResponding: false,
            fileExists: { path in installed && path.hasSuffix("com.xcode-copilot-server.plist") },
            commandRunner: { _, arguments in
                commands.append(arguments)
                if arguments.first == "uninstall-agent" {
                    installed = false
                }
                return .init(terminationStatus: 0, stdout: "", stderr: "")
            }
        )

        try await service.uninstallOrStop()

        XCTAssertEqual(commands.last, ["uninstall-agent"])
    }

    func testLogSnapshotReadsExistingLogWithoutOpeningWorkspace() throws {
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

        var openedURLs: [URL] = []
        let service = CopilotSidecarService(
            executableResolver: { URL(fileURLWithPath: "/tmp/xcode-copilot-server") },
            endpointProbe: { false },
            commandRunner: { _, _ in .init(terminationStatus: 0, stdout: "", stderr: "") },
            shellRunner: { _ in .init(terminationStatus: 1, stdout: "", stderr: "") },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            workspaceOpener: { openedURLs = $0 }
        )

        let snapshot = service.logSnapshot()

        XCTAssertTrue(snapshot.text.contains("Rejected request from unexpected user-agent"))
        XCTAssertTrue(snapshot.summary.contains("Showing"))
        XCTAssertTrue(snapshot.summary.contains("Copilot sidecar log file"))
        XCTAssertTrue(openedURLs.isEmpty)
    }

    private func makeService(
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
