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

    private func makeService(
        executable: URL? = URL(fileURLWithPath: "/tmp/xcode-copilot-server"),
        endpointResponding: Bool,
        fileExists: @escaping CopilotSidecarService.FileExists = { _ in false },
        commandRunner: CopilotSidecarService.CommandRunner? = nil
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
            shellRunner: { _ in .init(terminationStatus: 1, stdout: "", stderr: "") },
            fileExists: fileExists,
            workspaceOpener: { _ in }
        )
    }
}
