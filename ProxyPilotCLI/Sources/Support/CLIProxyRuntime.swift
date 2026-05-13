#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

struct LocalProxyProbeResult {
    let reachable: Bool
    let modelCount: Int?
    let errorMessage: String?
}

struct DaemonLaunchResult {
    let pid: Int32
    let managed: Bool
    let modelCount: Int?
}

struct DiscoveredProxyProcess {
    let pid: Int32
    let command: String
}

enum CLIProxyRuntime {
    enum InlineKeyError: LocalizedError {
        case missingInput
        case emptyInput

        var errorDescription: String? {
            switch self {
            case .missingInput:
                return "No API key input provided on stdin."
            case .emptyInput:
                return "API key is empty or whitespace-only."
            }
        }
    }

    static func readInlineKey(key: String?, keyStdin: Bool) throws -> String? {
        if let key {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw InlineKeyError.emptyInput
            }
            return trimmed
        }

        guard keyStdin else { return nil }
        guard let line = readLine(strippingNewline: true) else {
            throw InlineKeyError.missingInput
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw InlineKeyError.emptyInput
        }
        return trimmed
    }

    static func probeProxy(on port: UInt16, timeout: TimeInterval = 1.5) async -> LocalProxyProbeResult {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else {
            return LocalProxyProbeResult(reachable: false, modelCount: nil, errorMessage: "Invalid local proxy probe URL.")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode
                let message = status.map { "HTTP \($0) from /v1/models." } ?? "No HTTP response from /v1/models."
                return LocalProxyProbeResult(reachable: false, modelCount: nil, errorMessage: message)
            }

            let modelCount: Int?
            if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = parsed["data"] as? [[String: Any]] {
                modelCount = models.count
            } else {
                modelCount = nil
            }

            return LocalProxyProbeResult(reachable: true, modelCount: modelCount, errorMessage: nil)
        } catch {
            return LocalProxyProbeResult(reachable: false, modelCount: nil, errorMessage: error.localizedDescription)
        }
    }

    static func bindFailureSuggestion(port: UInt16, error: Error) -> String {
        let detail = "\(error) \(error.localizedDescription)".lowercased()
        if port == 0 {
            return "ProxyPilot asked macOS for any free port, so this is not a fixed-port collision. Check local listener permissions or sandbox restrictions, then retry outside the restricted host."
        }
        if detail.contains("operation not permitted") || detail.contains("permission") || detail.contains("not permitted") {
            return "macOS refused the local listener. Check local network permissions or sandbox restrictions for this host, then retry."
        }
        return "Check if port \(port) is already in use. If the port is free, inspect the error detail above for local network or sandbox restrictions."
    }

    static func discoverStartProcesses(on port: UInt16) -> [DiscoveredProxyProcess] {
        let pgrepPath: String
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/pgrep") {
            pgrepPath = "/usr/bin/pgrep"
        } else {
            pgrepPath = "/bin/pgrep"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pgrepPath)
        process.arguments = ["-alf", "proxypilot"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return []
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        return output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let firstSpace = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                return nil
            }

            let pidText = String(trimmed[..<firstSpace])
            let command = trimmed[firstSpace...].trimmingCharacters(in: .whitespaces)
            guard let pid = Int32(pidText), pid != currentPID else {
                return nil
            }

            guard command.contains("proxypilot"),
                  command.contains(" start "),
                  commandIncludesPort(command, port: port) else {
                return nil
            }

            return DiscoveredProxyProcess(pid: pid, command: command)
        }
    }

    static func commandIncludesPort(_ command: String, port: UInt16) -> Bool {
        let portText = "\(port)"
        if command.contains("--port=\(portText)") || command.contains("-p=\(portText)") {
            return true
        }

        let tokens = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        for (index, token) in tokens.enumerated() {
            guard token == "--port" || token == "-p" else { continue }
            if tokens.indices.contains(index + 1), tokens[index + 1] == portText {
                return true
            }
        }
        return false
    }

    static func launchDaemon(
        port: UInt16,
        provider: String,
        upstreamUrl: String?,
        key: String?,
        model: String?,
        json: Bool
    ) async throws -> DaemonLaunchResult {
        let probeBefore = await probeProxy(on: port)
        let execPath = currentExecutablePath()

        var args = ["proxypilot", "start", "--port", "\(port)", "--provider", provider]
        if let upstreamUrl {
            args += ["--upstream-url", upstreamUrl]
        }
        if let key {
            args += ["--key", key]
        }
        if let model {
            args += ["--model", model]
        }
        if json {
            args += ["--json"]
        }

        let logPath = "/tmp/proxypilot_builtin_proxy.log"
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)

        var spawnAttrs: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttrs)
        #if canImport(Darwin)
        posix_spawnattr_setflags(&spawnAttrs, Int16(POSIX_SPAWN_SETSID))
        #endif

        var childPid: pid_t = 0
        let cArgs = args.map { strdup($0) } + [nil]
        defer { cArgs.forEach { $0.map { free($0) } } }

        let result = posix_spawn(&childPid, execPath, &fileActions, &spawnAttrs, cArgs, environ)
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&spawnAttrs)

        guard result == 0 else {
            throw NSError(
                domain: "ProxyPilotCLI",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: "posix_spawn failed: \(result)"]
            )
        }

        var childRegistered = false
        var probeAfter = LocalProxyProbeResult(reachable: false, modelCount: nil, errorMessage: nil)
        var sawReachableWithoutPID = false
        for _ in 0..<20 {
            if let runningPid = PidFile.read(), runningPid == childPid {
                childRegistered = true
                break
            }

            probeAfter = await probeProxy(on: port, timeout: 0.3)
            if !probeBefore.reachable && probeAfter.reachable {
                sawReachableWithoutPID = true
            }

            if !PidFile.isProcessRunning(pid: childPid) {
                break
            }

            try? await Task.sleep(for: .milliseconds(100))
        }

        if !childRegistered && sawReachableWithoutPID {
            return DaemonLaunchResult(
                pid: childPid,
                managed: false,
                modelCount: probeAfter.modelCount
            )
        }

        guard childRegistered else {
            throw NSError(
                domain: "ProxyPilotCLI",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Daemon process failed to become ready."]
            )
        }

        if !probeAfter.reachable {
            probeAfter = await probeProxy(on: port)
        }

        return DaemonLaunchResult(
            pid: childPid,
            managed: true,
            modelCount: probeAfter.modelCount
        )
    }

    private static func currentExecutablePath() -> String {
        if let executablePath = Bundle.main.executablePath,
           !executablePath.isEmpty {
            return executablePath
        }

        let arg0 = ProcessInfo.processInfo.arguments[0]
        if arg0.contains("/") {
            return arg0
        }

        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        for entry in pathEntries {
            let candidate = URL(fileURLWithPath: entry)
                .appendingPathComponent(arg0)
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return arg0
    }
}
