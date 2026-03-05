import Foundation

public enum LogReader {

    /// Default proxy log file path.
    public static let defaultLogURL = URL(fileURLWithPath: "/tmp/proxypilot_builtin_proxy.log")

    /// Read the last N lines from a log file, optionally redacting secrets.
    public static func tail(url: URL, lines: Int, redact: Bool = false) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let allLines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let trimmed = allLines.filter { !$0.isEmpty }
        let sliced = Array(trimmed.suffix(lines))

        guard redact else { return sliced }
        return sliced.map { redactSecrets(in: $0) }
    }

    private static func redactSecrets(in line: String) -> String {
        var result = line
        // Redact Bearer tokens
        if let range = result.range(of: "Bearer [^ \"]+", options: .regularExpression) {
            result.replaceSubrange(range, with: "Bearer [REDACTED]")
        }
        // Redact api_key values
        if let range = result.range(of: "api_key=[^ &\"]+", options: .regularExpression) {
            result.replaceSubrange(range, with: "api_key=[REDACTED]")
        }
        // Redact Authorization header values
        if let range = result.range(of: "Authorization: [^\r\n]+", options: .regularExpression) {
            result.replaceSubrange(range, with: "Authorization: [REDACTED]")
        }
        return result
    }
}
