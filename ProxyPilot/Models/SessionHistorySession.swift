import Foundation
import ProxyPilotCore

struct SessionHistorySession: Identifiable, Equatable {
    let id: String
    let source: String
    let requests: [ProxyPilotCore.RequestRecord]

    var startedAt: Date? { requests.first?.timestamp }
    var endedAt: Date? { requests.last?.timestamp }
    var requestCount: Int { requests.count }
    var totalPromptTokens: Int { requests.reduce(0) { $0 + $1.promptTokens } }
    var totalCompletionTokens: Int { requests.reduce(0) { $0 + $1.completionTokens } }
    var totalTokens: Int { totalPromptTokens + totalCompletionTokens }

    var totalTokensFormatted: String {
        if totalTokens >= 1_000_000 {
            return String(format: "%.1fM", Double(totalTokens) / 1_000_000)
        }
        if totalTokens >= 1_000 {
            return String(format: "%.1fK", Double(totalTokens) / 1_000)
        }
        return "\(totalTokens)"
    }

    var modelDistribution: [(model: String, count: Int)] {
        Dictionary(grouping: requests, by: \.model)
            .map { (model: $0.key, count: $0.value.count) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.model < $1.model
            }
    }

    var p95Latency: TimeInterval? {
        percentile(requests.map(\.durationSeconds), percentile: 0.95)
    }

    static func build(from events: [SessionReportEvent]) -> [SessionHistorySession] {
        Dictionary(grouping: events, by: \.sessionID)
            .map { sessionID, events in
                let sortedEvents = events.sorted { $0.record.timestamp < $1.record.timestamp }
                let source = sortedEvents.first?.source ?? "unknown"
                return SessionHistorySession(
                    id: sessionID,
                    source: source,
                    requests: sortedEvents.map(\.record)
                )
            }
            .sorted {
                ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast)
            }
    }

    private func percentile(_ values: [TimeInterval], percentile: Double) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        if sorted.count == 1 { return sorted[0] }
        let clamped = min(max(percentile, 0), 1)
        let position = clamped * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        if lower == upper { return sorted[lower] }
        let weight = position - Double(lower)
        return sorted[lower] + ((sorted[upper] - sorted[lower]) * weight)
    }
}

enum SessionInputOutputLogAvailability: Equatable {
    case hasRecords(count: Int)
    case masterLoggingDisabled
    case cliCaptureDisabled
    case enabledWaitingForRecords
}

enum SessionHistoryDisplayPolicy {
    static let defaultVisibleRequestLimit = 25
    static let defaultVisibleLogLimit = 20

    static func visibleRequests(for session: SessionHistorySession, showAll: Bool) -> [RequestRecord] {
        guard !showAll else { return session.requests }
        return Array(session.requests.prefix(defaultVisibleRequestLimit))
    }

    static func hiddenRequestCount(for session: SessionHistorySession, showAll: Bool) -> Int {
        guard !showAll else { return 0 }
        return max(0, session.requests.count - defaultVisibleRequestLimit)
    }

    static func visibleLogs(
        _ logs: [SessionHistoryLogRecordViewModel],
        showAll: Bool
    ) -> [SessionHistoryLogRecordViewModel] {
        guard !showAll else { return logs }
        return Array(logs.prefix(defaultVisibleLogLimit))
    }

    static func hiddenLogCount(
        _ logs: [SessionHistoryLogRecordViewModel],
        showAll: Bool
    ) -> Int {
        guard !showAll else { return 0 }
        return max(0, logs.count - defaultVisibleLogLimit)
    }
}

enum SessionHistorySensitiveCopy {
    static let menuSectionTitle = "Decrypted prompt/output logs"
    static let jsonlMenuTitle = "Prompt/output logs as JSONL (decrypted)"
    static let markdownMenuTitle = "Prompt/output logs as Markdown (decrypted)"
    static let inlineNotice = "Prompt/output records may include source snippets, local file paths, credentials pasted into prompts, and other private project context. Copy and export actions produce decrypted content."
}

extension SessionHistorySession {
    var usesCLIInputOutputCapture: Bool {
        let normalizedSource = source.lowercased()
        return normalizedSource == "cli" || normalizedSource == "mcp"
    }

    func inputOutputLogAvailability(
        masterLoggingEnabled: Bool,
        cliLoggingEnabled: Bool,
        matchingRecordCount: Int
    ) -> SessionInputOutputLogAvailability {
        if matchingRecordCount > 0 {
            return .hasRecords(count: matchingRecordCount)
        }
        if !masterLoggingEnabled {
            return .masterLoggingDisabled
        }
        if usesCLIInputOutputCapture && !cliLoggingEnabled {
            return .cliCaptureDisabled
        }
        return .enabledWaitingForRecords
    }
}

struct SessionHistoryLogRecordViewModel: Identifiable, Equatable {
    let index: Int
    let record: InputOutputLogRecord
    let tokenCounts: SessionHistoryLogTokenCounts?

    var id: UUID { record.id }

    static func matching(
        _ records: [InputOutputLogRecord],
        session: SessionHistorySession
    ) -> [SessionHistoryLogRecordViewModel] {
        let sortedRecords = sortedMatchingRecords(records, sessionID: session.id)
        let sortedRequests = session.requests.sorted { $0.timestamp < $1.timestamp }
        let tokenCountsByRecordID = confidentTokenCountsByRecordID(
            records: sortedRecords,
            requests: sortedRequests
        )
        return sortedRecords
            .enumerated()
            .map { offset, record in
                SessionHistoryLogRecordViewModel(
                    index: offset + 1,
                    record: record,
                    tokenCounts: tokenCountsByRecordID[record.id]
                )
            }
    }

    static func matching(
        _ records: [InputOutputLogRecord],
        sessionID: String
    ) -> [SessionHistoryLogRecordViewModel] {
        sortedMatchingRecords(records, sessionID: sessionID)
            .enumerated()
            .map { offset, record in
                SessionHistoryLogRecordViewModel(index: offset + 1, record: record, tokenCounts: nil)
            }
    }

    private static func sortedMatchingRecords(
        _ records: [InputOutputLogRecord],
        sessionID: String
    ) -> [InputOutputLogRecord] {
        records
            .filter { $0.sessionID == sessionID }
            .sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    private static func confidentTokenCountsByRecordID(
        records: [InputOutputLogRecord],
        requests: [RequestRecord]
    ) -> [UUID: SessionHistoryLogTokenCounts] {
        guard !records.isEmpty, records.count == requests.count else { return [:] }

        var remainingRequests = requests
        var tokenCountsByRecordID: [UUID: SessionHistoryLogTokenCounts] = [:]
        for record in records {
            let candidates = remainingRequests.enumerated().filter { _, request in
                request.path == record.path
                    && request.wasStreaming == record.wasStreaming
                    && abs(request.timestamp.timeIntervalSince(record.timestamp)) <= 1
            }
            guard candidates.count == 1, let match = candidates.first else {
                return [:]
            }
            tokenCountsByRecordID[record.id] = SessionHistoryLogTokenCounts(request: match.element)
            remainingRequests.remove(at: match.offset)
        }

        return remainingRequests.isEmpty ? tokenCountsByRecordID : [:]
    }
}

struct SessionHistoryLogTokenCounts: Equatable {
    let promptTokens: Int
    let completionTokens: Int

    init(request: RequestRecord) {
        self.promptTokens = request.promptTokens
        self.completionTokens = request.completionTokens
    }

    var totalTokens: Int { promptTokens + completionTokens }
}

extension InputOutputLogContent {
    var sessionHistoryText: String {
        switch encoding {
        case .utf8:
            return text ?? ""
        case .base64:
            return base64 ?? ""
        }
    }

    var sessionHistoryEncodingLabel: String {
        switch encoding {
        case .utf8:
            return "UTF-8"
        case .base64:
            return "Base64"
        }
    }
}

enum SessionHistoryLogExport {
    static func json(for record: InputOutputLogRecord) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(record), as: UTF8.self)
    }

    static func jsonl(for records: [InputOutputLogRecord]) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try records
            .map { String(decoding: try encoder.encode($0), as: UTF8.self) }
            .joined(separator: "\n") + (records.isEmpty ? "" : "\n")
    }

    static func markdown(for records: [InputOutputLogRecord]) -> String {
        records.enumerated()
            .map { offset, record in
                "# Log \(offset + 1)\n\n" + markdown(for: record)
            }
            .joined(separator: "\n\n---\n\n")
    }

    static func markdown(for record: InputOutputLogRecord) -> String {
        var lines: [String] = [
            "- ID: `\(record.id.uuidString)`",
            "- Time: \(record.timestamp.formatted(date: .abbreviated, time: .standard))",
            "- Source: \(record.source)",
            "- Provider: \(record.provider)",
            "- Model: `\(record.model)`",
            "- Path: `\(record.path)`",
            "- Streaming: \(record.wasStreaming ? "Yes" : "No")",
            "- Status: \(record.statusCode.map(String.init) ?? "Unknown")",
            ""
        ]

        if record.outputTruncated == true {
            lines.append("> Output captured up to the streaming cap and was truncated. JSONL export preserves the truncation flag.")
            lines.append("")
        }

        if let input = record.input {
            let fence = markdownFence(for: input.sessionHistoryText)
            lines.append("## Prompt")
            lines.append("")
            lines.append("\(fence)\(markdownFenceLanguage(for: input))")
            lines.append(input.sessionHistoryText)
            lines.append(fence)
            lines.append("")
        }

        if let output = record.output {
            let fence = markdownFence(for: output.sessionHistoryText)
            lines.append("## Output")
            lines.append("")
            lines.append("\(fence)\(markdownFenceLanguage(for: output))")
            lines.append(output.sessionHistoryText)
            lines.append(fence)
        }

        return lines.joined(separator: "\n")
    }

    private static func markdownFenceLanguage(for content: InputOutputLogContent) -> String {
        guard content.encoding == .utf8 else { return "text" }
        let trimmed = content.sessionHistoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[") ? "json" : "text"
    }

    /// CommonMark requires the closing fence to be at least as long as the
    /// opening fence and longer than any inner backtick run. Captured LLM
    /// output routinely contains ` ```swift ` blocks; a fixed 3-backtick
    /// outer fence would close early on the first inner ```. Emit a fence
    /// of length max(3, longestInnerRun + 1).
    static func markdownFence(for text: String) -> String {
        var longestRun = 0
        var currentRun = 0
        for character in text {
            if character == "`" {
                currentRun += 1
                if currentRun > longestRun { longestRun = currentRun }
            } else {
                currentRun = 0
            }
        }
        return String(repeating: "`", count: max(3, longestRun + 1))
    }
}
