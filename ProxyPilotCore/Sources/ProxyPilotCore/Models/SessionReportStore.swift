import Foundation

public struct SessionReportEvent: Sendable, Codable, Equatable {
    public let id: UUID
    public let schemaVersion: Int
    public let source: String
    public let sessionID: String
    public let role: String?
    public let record: RequestRecord

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = 2,
        source: String,
        sessionID: String,
        role: String? = nil,
        record: RequestRecord
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.source = source
        self.sessionID = sessionID
        self.role = role
        self.record = record
    }
}

public enum SessionReportStore {
    public static let maximumFileBytes = 8 * 1_024 * 1_024
    public static let maximumEventBytes = 64 * 1_024
    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["PROXYPILOT_SESSION_REPORT_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
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
        guard data.count <= maximumEventBytes else { return }

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        } else if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize),
                  size + data.count > maximumFileBytes {
            let archive = freshArchiveURL(for: url)
            try FileManager.default.moveItem(at: url, to: archive)
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    public static func readEvents(from url: URL = defaultURL) throws -> [SessionReportEvent] {
        let urls = archiveURLs(for: url) + [url].filter { FileManager.default.fileExists(atPath: $0.path) }
        var events: [SessionReportEvent] = []
        var seen = Set<UUID>()
        for source in urls {
            for event in try readOne(source) where seen.insert(event.id).inserted { events.append(event) }
        }
        return events
    }

    private static func readOne(_ url: URL) throws -> [SessionReportEvent] {

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > UInt64(maximumFileBytes) ? size - UInt64(maximumFileBytes) : 0
        try handle.seek(toOffset: start)
        var data = try handle.readToEnd() ?? Data()
        if start > 0, let newline = data.firstIndex(of: 0x0A) {
            data.removeSubrange(data.startIndex...newline)
        }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard line.utf8.count <= maximumEventBytes else { return nil }
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(SessionReportEvent.self, from: data)
            }
    }

    private static func archiveURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("archive.jsonl")
    }

    private static func freshArchiveURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("archive.\(UUID().uuidString.lowercased()).jsonl")
    }

    private static func archiveURLs(for url: URL) -> [URL] {
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent + ".archive"
        return ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { candidate in
                let name = candidate.lastPathComponent
                return name == "\(base).jsonl" || (name.hasPrefix("\(base).") && name.hasSuffix(".jsonl"))
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func reset(at url: URL = defaultURL) throws {
        for target in archiveURLs(for: url) + [url] where FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }
}
