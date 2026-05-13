import Foundation

public struct SessionReportEvent: Sendable, Codable, Equatable {
    public let id: UUID
    public let schemaVersion: Int
    public let source: String
    public let sessionID: String
    public let record: RequestRecord

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = 1,
        source: String,
        sessionID: String,
        record: RequestRecord
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.source = source
        self.sessionID = sessionID
        self.record = record
    }
}

public enum SessionReportStore {
    public static var defaultURL: URL {
        #if os(macOS)
        if let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return applicationSupport
                .appendingPathComponent("ProxyPilot", isDirectory: true)
                .appendingPathComponent("session-report.jsonl")
        }
        #endif

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("proxypilot", isDirectory: true)
            .appendingPathComponent("session-report.jsonl")
    }

    public static func append(_ event: SessionReportEvent, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(event)
        data.append(0x0A)

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    public static func readEvents(from url: URL = defaultURL) throws -> [SessionReportEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(SessionReportEvent.self, from: data)
            }
    }

    public static func reset(at url: URL = defaultURL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
