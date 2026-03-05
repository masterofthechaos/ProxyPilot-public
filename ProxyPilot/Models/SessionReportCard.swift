import Foundation

@MainActor
final class SessionReportCard: ObservableObject {
    nonisolated init() {}

    struct RequestRecord: Sendable {
        let timestamp: Date
        let model: String
        let promptTokens: Int
        let completionTokens: Int
        let durationSeconds: TimeInterval
        let path: String
        let wasStreaming: Bool
    }

    @Published private(set) var requests: [RequestRecord] = []

    var totalRequests: Int { requests.count }

    var totalPromptTokens: Int {
        requests.reduce(0) { $0 + $1.promptTokens }
    }

    var totalCompletionTokens: Int {
        requests.reduce(0) { $0 + $1.completionTokens }
    }

    var totalTokens: Int { totalPromptTokens + totalCompletionTokens }

    var modelDistribution: [(model: String, count: Int)] {
        let grouped = Dictionary(grouping: requests, by: \.model)
        return grouped.map { (model: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    var averageRequestDuration: TimeInterval? {
        guard !requests.isEmpty else { return nil }
        let total = requests.reduce(0.0) { $0 + $1.durationSeconds }
        return total / Double(requests.count)
    }

    var sessionStartTime: Date? { requests.first?.timestamp }

    var totalTokensFormatted: String {
        if totalTokens >= 1_000_000 {
            return String(format: "%.1fM", Double(totalTokens) / 1_000_000)
        }
        if totalTokens >= 1_000 {
            return String(format: "%.1fK", Double(totalTokens) / 1_000)
        }
        return "\(totalTokens)"
    }

    func record(_ entry: RequestRecord) {
        requests.append(entry)
    }

    func reset() {
        requests.removeAll()
    }
}
