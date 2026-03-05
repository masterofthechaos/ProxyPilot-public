import ArgumentParser
import Foundation

struct LaunchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch",
        abstract: "Launch Xcode (macOS only)."
    )

    @Option(name: .long, help: "Xcode application path or app name (default: /Applications/Xcode.app).")
    var xcode: String = "/Applications/Xcode.app"

    @Flag(name: .long, help: "Emit JSON output.")
    var json: Bool = false

    mutating func run() async throws {
        #if os(macOS)
        do {
            try launchXcode(specifier: xcode)
            OutputFormatter.success(
                data: [
                    "status": "launched",
                    "target": xcode,
                ],
                humanMessage: "Requested launch for Xcode (\(xcode)).",
                json: json
            )
        } catch {
            OutputFormatter.error(
                code: "E033",
                message: "Failed to launch Xcode: \(error.localizedDescription)",
                suggestion: "Verify the path/app name and that Launch Services can open it.",
                json: json
            )
            throw ExitCode.failure
        }
        #else
        OutputFormatter.error(
            code: "E034",
            message: "'proxypilot launch' is only supported on macOS.",
            suggestion: nil,
            json: json
        )
        throw ExitCode.failure
        #endif
    }

    #if os(macOS)
    private func launchXcode(specifier: String) throws {
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.standardError = stderrPipe

        if specifier.contains("/") {
            process.arguments = [specifier]
        } else {
            process.arguments = ["-a", specifier]
        }

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(decoding: stderrData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if stderrText.isEmpty {
                throw NSError(domain: "ProxyPilotCLI", code: Int(process.terminationStatus))
            }
            throw NSError(
                domain: "ProxyPilotCLI",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: stderrText]
            )
        }
    }
    #endif
}
