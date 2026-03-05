import ArgumentParser
import Foundation
import ProxyPilotCore

struct LogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Show recent proxy log output."
    )

    @Option(name: [.short, .long], help: "Number of lines to show.")
    var lines: Int = 75

    @Flag(name: [.short, .long], help: "Follow log output (like tail -f). Press Ctrl-C to stop.")
    var follow: Bool = false

    @Flag(name: .long, help: "Emit JSON output.")
    var json: Bool = false

    mutating func run() async throws {
        if follow {
            try await followLog()
        } else {
            showTail()
        }
    }

    private func showTail() {
        let result = LogReader.tail(url: LogReader.defaultLogURL, lines: lines, redact: true)

        if json {
            OutputFormatter.success(
                data: ["lines": result, "count": result.count],
                humanMessage: "",
                json: true
            )
        } else {
            if result.isEmpty {
                print("No log output yet.")
            } else {
                for line in result {
                    print(line)
                }
            }
        }
    }

    private func followLog() async throws {
        let url = LogReader.defaultLogURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("Log file not found: \(url.path)")
            print("Start the proxy first with 'proxypilot start'.")
            throw ExitCode.failure
        }

        // Print initial tail
        let initial = LogReader.tail(url: url, lines: lines, redact: true)
        for line in initial {
            print(line)
        }

        // Follow new lines
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw ExitCode.failure
        }
        handle.seekToEndOfFile()

        // Park and poll for new data
        signal(SIGINT) { _ in _exit(0) }
        signal(SIGTERM) { _ in _exit(0) }

        while true {
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                print(text, terminator: "")
            }
            try await Task.sleep(nanoseconds: 250_000_000) // 250ms
        }
    }
}
