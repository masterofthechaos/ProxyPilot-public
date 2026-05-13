import AppKit
import Foundation

@MainActor
final class CopilotSidecarService {
    struct CommandResult: Sendable {
        let terminationStatus: Int32
        let stdout: String
        let stderr: String

        var combinedOutput: String {
            stdout + "\n" + stderr
        }
    }

    struct Status: Sendable {
        let executablePath: String?
        let supportsLaunchAgent: Bool
        let isLaunchAgentInstalled: Bool
        let endpointResponding: Bool
        let isDirectProcessRunning: Bool
        let isExternal: Bool
        let isManaged: Bool
        let isRunning: Bool
        let message: String
        let logURLs: [URL]
    }

    struct DirectProcessLaunch {
        let process: Process
        let logHandle: FileHandle
    }

    enum SidecarError: LocalizedError {
        case executableNotFound
        case externalHelperAlreadyRunning
        case failedToStart
        case commandFailed(command: String, stderr: String)

        var errorDescription: String? {
            switch self {
            case .executableNotFound:
                return "xcode-copilot-server is not installed. Install it with: npm install -g xcode-copilot-server"
            case .externalHelperAlreadyRunning:
                return "A Copilot helper is already responding on port 8080. ProxyPilot will not replace a helper it did not install."
            case .failedToStart:
                return "xcode-copilot-server did not stay running. Check GitHub Copilot authentication with copilot login or gh auth login."
            case let .commandFailed(command, stderr):
                let details = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if details.isEmpty {
                    return "\(command) failed."
                }
                return "\(command) failed: \(details)"
            }
        }
    }

    typealias ExecutableResolver = @MainActor () async -> URL?
    typealias EndpointProbe = @MainActor () async -> Bool
    typealias CommandRunner = @MainActor (URL, [String]) async -> CommandResult
    typealias ShellRunner = @MainActor (String) async -> CommandResult
    typealias FileExists = @MainActor (String) -> Bool
    typealias DirectProcessLauncher = @MainActor (URL, [String], URL) throws -> DirectProcessLaunch
    typealias WorkspaceOpener = @MainActor ([URL]) -> Void

    private var process: Process?
    private var logHandle: FileHandle?
    private let port: UInt16
    private let directLogURL: URL
    private let launchAgentPlistURL: URL
    private let launchAgentOutLogURL: URL
    private let launchAgentErrLogURL: URL
    private let executableResolver: ExecutableResolver?
    private let endpointProbe: EndpointProbe
    private let commandRunner: CommandRunner
    private let shellRunner: ShellRunner
    private let fileExists: FileExists
    private let directProcessLauncher: DirectProcessLauncher
    private let workspaceOpener: WorkspaceOpener

    private static let launchAgentLabel = "com.xcode-copilot-server"

    init(
        port: UInt16 = 8080,
        executableResolver: ExecutableResolver? = nil,
        endpointProbe: EndpointProbe? = nil,
        commandRunner: CommandRunner? = nil,
        shellRunner: ShellRunner? = nil,
        fileExists: FileExists? = nil,
        directProcessLauncher: DirectProcessLauncher? = nil,
        workspaceOpener: WorkspaceOpener? = nil
    ) {
        self.port = port
        self.directLogURL = URL(fileURLWithPath: "/tmp/proxypilot_copilot_sidecar.log")
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.launchAgentPlistURL = home
            .appendingPathComponent("Library/LaunchAgents/\(Self.launchAgentLabel).plist")
        self.launchAgentOutLogURL = home
            .appendingPathComponent("Library/Logs/xcode-copilot-server.out.log")
        self.launchAgentErrLogURL = home
            .appendingPathComponent("Library/Logs/xcode-copilot-server.err.log")
        self.executableResolver = executableResolver
        self.endpointProbe = endpointProbe ?? { await Self.endpointResponds(port: port) }
        self.commandRunner = commandRunner ?? { executable, arguments in
            await Self.runCommand(executablePath: executable.path, arguments: arguments)
        }
        self.shellRunner = shellRunner ?? { command in
            await Self.runCommand(executablePath: "/bin/zsh", arguments: ["-lc", command])
        }
        self.fileExists = fileExists ?? { path in FileManager.default.fileExists(atPath: path) }
        self.directProcessLauncher = directProcessLauncher ?? { executable, arguments, logURL in
            try Self.launchDirectProcess(executable: executable, arguments: arguments, logURL: logURL)
        }
        self.workspaceOpener = workspaceOpener ?? { urls in
            for url in urls {
                NSWorkspace.shared.open(url)
            }
        }
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    var installAgentArguments: [String] {
        [
            "install-agent",
            "--proxy", "openai",
            "--port", "\(port)",
            "--log-level", "info",
            "--idle-timeout", "60"
        ]
    }

    var uninstallAgentArguments: [String] {
        ["uninstall-agent"]
    }

    func status() async -> Status {
        let executable = await findExecutable()
        let directProcessRunning = isRunning
        if !directProcessRunning {
            cleanupProcessHandles()
        }

        let endpointResponding = await endpointProbe()
        let launchAgentInstalled = await isLaunchAgentInstalled()
        let supportsLaunchAgentStatus: Bool
        if let executable {
            supportsLaunchAgentStatus = await supportsLaunchAgent(executable: executable)
        } else {
            supportsLaunchAgentStatus = false
        }
        let external = endpointResponding && !directProcessRunning && !launchAgentInstalled
        let managed = directProcessRunning || launchAgentInstalled
        let running = endpointResponding || directProcessRunning || launchAgentInstalled

        return Status(
            executablePath: executable?.path,
            supportsLaunchAgent: supportsLaunchAgentStatus,
            isLaunchAgentInstalled: launchAgentInstalled,
            endpointResponding: endpointResponding,
            isDirectProcessRunning: directProcessRunning,
            isExternal: external,
            isManaged: managed,
            isRunning: running,
            message: statusMessage(
                executableFound: executable != nil,
                supportsLaunchAgent: supportsLaunchAgentStatus,
                launchAgentInstalled: launchAgentInstalled,
                endpointResponding: endpointResponding,
                directProcessRunning: directProcessRunning,
                external: external
            ),
            logURLs: logURLs(forLaunchAgent: launchAgentInstalled)
        )
    }

    func installOrStart() async throws {
        if isRunning { return }
        let endpointAlreadyResponding = await endpointProbe()
        let launchAgentInstalled = await isLaunchAgentInstalled()
        if endpointAlreadyResponding && !launchAgentInstalled {
            throw SidecarError.externalHelperAlreadyRunning
        }
        cleanupProcessHandles()

        guard let executable = await findExecutable() else {
            throw SidecarError.executableNotFound
        }

        if await supportsLaunchAgent(executable: executable) {
            let result = await commandRunner(executable, installAgentArguments)
            guard result.terminationStatus == 0 else {
                throw SidecarError.commandFailed(command: "xcode-copilot-server install-agent", stderr: result.combinedOutput)
            }
            return
        }

        try startDirectProcess(executable: executable)
    }

    func uninstallOrStop() async throws {
        if await isLaunchAgentInstalled() {
            guard let executable = await findExecutable() else {
                throw SidecarError.executableNotFound
            }
            let result = await commandRunner(executable, uninstallAgentArguments)
            guard result.terminationStatus == 0 else {
                throw SidecarError.commandFailed(command: "xcode-copilot-server uninstall-agent", stderr: result.combinedOutput)
            }
            cleanupProcessHandles()
            return
        }

        if isRunning {
            process?.terminate()
            cleanupProcessHandles()
        }
    }

    func openLog() {
        let existingLogs = allLogURLs.filter { fileExists($0.path) }
        workspaceOpener(existingLogs.isEmpty ? [launchAgentOutLogURL] : existingLogs)
    }

    private var allLogURLs: [URL] {
        [launchAgentOutLogURL, launchAgentErrLogURL, directLogURL]
    }

    private func logURLs(forLaunchAgent launchAgentInstalled: Bool) -> [URL] {
        launchAgentInstalled ? [launchAgentOutLogURL, launchAgentErrLogURL] : [directLogURL]
    }

    private func statusMessage(
        executableFound: Bool,
        supportsLaunchAgent: Bool,
        launchAgentInstalled: Bool,
        endpointResponding: Bool,
        directProcessRunning: Bool,
        external: Bool
    ) -> String {
        if launchAgentInstalled {
            if endpointResponding {
                return "Background helper is installed and responding on port \(port)."
            }
            return "Background helper is installed. launchd will wake it when Xcode sends a Copilot request."
        }

        if directProcessRunning {
            return "Copilot helper is running on port \(port)."
        }

        if external {
            return "Copilot helper is already responding on port \(port). ProxyPilot can use it, but it was started elsewhere."
        }

        if !executableFound {
            return "Install xcode-copilot-server to enable the Copilot sidecar."
        }

        if supportsLaunchAgent {
            return "Helper found. Install the background helper to route ProxyPilot through your Copilot account."
        }

        return "Helper found. Start it to route ProxyPilot through your Copilot account."
    }

    private func supportsLaunchAgent(executable: URL) async -> Bool {
        let result = await commandRunner(executable, ["--help"])
        guard result.terminationStatus == 0 else { return false }
        let output = result.combinedOutput
        return output.contains("install-agent") && output.contains("uninstall-agent")
    }

    private func isLaunchAgentInstalled() async -> Bool {
        if fileExists(launchAgentPlistURL.path) {
            return true
        }

        let result = await shellRunner("launchctl list | /usr/bin/grep -q '\(Self.launchAgentLabel)'")
        return result.terminationStatus == 0
    }

    private func startDirectProcess(executable: URL) throws {
        let launch = try directProcessLauncher(
            executable,
            [
                "--proxy", "openai",
                "--port", "\(port)",
                "--log-level", "info"
            ],
            directLogURL
        )
        let newProcess = launch.process
        process = newProcess
        logHandle = launch.logHandle

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if newProcess.isRunning == false {
                cleanupProcessHandles()
            }
        }
    }

    private func findExecutable() async -> URL? {
        if let executableResolver {
            return await executableResolver()
        }

        let candidates = [
            "/opt/homebrew/bin/xcode-copilot-server",
            "/usr/local/bin/xcode-copilot-server"
        ]

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return await executableFromShellPath()
    }

    private func executableFromShellPath() async -> URL? {
        let result = await shellRunner("command -v xcode-copilot-server")
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.terminationStatus == 0,
              !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private static func endpointResponds(port: UInt16) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else { return false }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.8
        configuration.timeoutIntervalForResource = 0.8
        configuration.waitsForConnectivity = false

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Xcode/24577 CFNetwork/3860.300.31 Darwin/25.2.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession(configuration: configuration).data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return false
            }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return root["data"] is [Any] || root["object"] as? String == "list"
        } catch {
            return false
        }
    }

    private static func runCommand(executablePath: String, arguments: [String]) async -> CommandResult {
        await Task.detached {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
                process.waitUntilExit()
                let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                return CommandResult(
                    terminationStatus: process.terminationStatus,
                    stdout: String(decoding: stdoutData, as: UTF8.self),
                    stderr: String(decoding: stderrData, as: UTF8.self)
                )
            } catch {
                return CommandResult(
                    terminationStatus: 1,
                    stdout: "",
                    stderr: error.localizedDescription
                )
            }
        }.value
    }

    private static func launchDirectProcess(
        executable: URL,
        arguments: [String],
        logURL: URL
    ) throws -> DirectProcessLaunch {
        let fileManager = FileManager.default
        fileManager.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()

        let newProcess = Process()
        newProcess.executableURL = executable
        newProcess.arguments = arguments
        newProcess.standardOutput = logHandle
        newProcess.standardError = logHandle
        do {
            try newProcess.run()
        } catch {
            try? logHandle.close()
            throw error
        }
        return DirectProcessLaunch(process: newProcess, logHandle: logHandle)
    }

    private func cleanupProcessHandles() {
        process = nil
        try? logHandle?.close()
        logHandle = nil
    }
}
