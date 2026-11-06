import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Counts refer to incoming records. A conflict is one UUID with different metadata.
public struct SessionHistoryImportPreview: Sendable, Codable, Equatable {
    public var newEvents = 0
    public var duplicateEvents = 0
    public var conflictingEvents = 0
    public var invalidRecords = 0
    public var canImport: Bool { conflictingEvents == 0 && invalidRecords == 0 }
    public init() {}
}

public enum SessionHistoryArchiveError: Error, LocalizedError {
    case rejected(SessionHistoryImportPreview)
    case unsafeDestination

    public var errorDescription: String? {
        switch self {
        case .rejected(let preview):
            return "History was not changed: \(preview.conflictingEvents) conflicting and \(preview.invalidRecords) invalid records."
        case .unsafeDestination:
            return "Choose a backup destination outside the session journal and its archive filenames."
        }
    }
}

/// Portable metadata-only JSONL. The footer detects incomplete or altered backups.
/// Bodies, decrypted logs, preferences and Keychain credentials are never read.
public enum SessionHistoryArchive {
    private struct Header: Codable {
        let format: String
        let version: Int
        let metadataOnly: Bool
    }
    private struct Footer: Codable {
        let eventCount: Int
        let sha256: String
    }
    private struct Parsed {
        var events: [SessionReportEvent] = []
        var invalid = 0
    }

    /// Exports every journal/archive record. Any malformed source or UUID conflict
    /// fails before replacing the destination, rather than producing a partial backup.
    @discardableResult
    public static func export(to destination: URL, from journal: URL = SessionReportStore.defaultURL) throws -> Int {
        try validateDestination(destination, journal: journal)
        return try SessionReportStore.withJournalLock(at: journal) {
            let stored = try readStore(journal)
            var preview = SessionHistoryImportPreview()
            preview.invalidRecords = stored.invalid
            let unique = classify(stored.events, existing: [:], preview: &preview)
            if !safeTotals(unique) { preview.invalidRecords += 1 }
            guard preview.canImport else { throw SessionHistoryArchiveError.rejected(preview) }
            let encoder = makeEncoder()
            try publish(to: destination) { handle in
                try write(encoder.encode(Header(format: "proxypilot.session-history", version: 1, metadataOnly: true)), to: handle)
                var hash = SHA256()
                for event in unique {
                    var data = try encoder.encode(event)
                    data.append(0x0A)
                    hash.update(data: data)
                    try handle.write(contentsOf: data)
                }
                try write(encoder.encode(Footer(eventCount: unique.count, sha256: digest(hash))), to: handle)
            }
            return unique.count
        }
    }

    public static func previewImport(from backup: URL, into journal: URL = SessionReportStore.defaultURL) throws -> SessionHistoryImportPreview {
        try merge(from: backup, into: journal, dryRun: true)
    }

    /// Parses the input once, then revalidates against current storage under the
    /// append/rotation lock. One atomic archive rename publishes only additions;
    /// concurrent writers and the active journal are preserved.
    @discardableResult
    public static func merge(from backup: URL, into journal: URL = SessionReportStore.defaultURL, dryRun: Bool = false) throws -> SessionHistoryImportPreview {
        let incoming = try parseBackup(backup)
        return try SessionReportStore.withJournalLock(at: journal) {
            let stored = try readStore(journal)
            var preview = SessionHistoryImportPreview()
            preview.invalidRecords = incoming.invalid + stored.invalid
            var existing: [UUID: SessionReportEvent] = [:]
            for event in stored.events {
                if let prior = existing[event.id], prior != event { preview.conflictingEvents += 1 }
                existing[event.id] = event
            }
            let additions = classify(incoming.events, existing: existing, preview: &preview)
            if !safeTotals(Array(existing.values) + additions) { preview.invalidRecords += 1 }
            if dryRun { return preview }
            guard preview.canImport else { throw SessionHistoryArchiveError.rejected(preview) }
            if !additions.isEmpty {
                let encoder = makeEncoder()
                try publish(to: SessionReportStore.freshArchiveURL(for: journal)) { handle in
                    for event in additions { try write(encoder.encode(event), to: handle) }
                }
            }
            return preview
        }
    }

    private static func classify(_ incoming: [SessionReportEvent], existing: [UUID: SessionReportEvent], preview: inout SessionHistoryImportPreview) -> [SessionReportEvent] {
        var known = existing
        var additions: [SessionReportEvent] = []
        for event in incoming {
            if let prior = known[event.id] {
                if prior == event { preview.duplicateEvents += 1 }
                else { preview.conflictingEvents += 1 }
            } else {
                known[event.id] = event
                additions.append(event)
                preview.newEvents += 1
            }
        }
        return additions
    }

    private static func parseBackup(_ url: URL) throws -> Parsed {
        let decoder = makeDecoder()
        var result = Parsed()
        var lineNumber = 0
        var footerSeen = false
        var hash = SHA256()
        var count = 0
        try forEachLine(in: url) { line in
            lineNumber += 1
            guard let line, !line.isEmpty else { result.invalid += 1; return }
            if lineNumber == 1 {
                guard let header = try? decoder.decode(Header.self, from: line),
                      header.format == "proxypilot.session-history", header.version == 1, header.metadataOnly else {
                    result.invalid += 1
                    return
                }
            } else if footerSeen {
                result.invalid += 1
            } else if let footer = try? decoder.decode(Footer.self, from: line) {
                footerSeen = true
                if footer.eventCount != count || footer.sha256 != digest(hash) { result.invalid += 1 }
            } else {
                count += 1
                var bytes = line
                bytes.append(0x0A)
                hash.update(data: bytes)
                if let event = try? decoder.decode(SessionReportEvent.self, from: line), valid(event) {
                    result.events.append(event)
                } else { result.invalid += 1 }
            }
        }
        if !footerSeen { result.invalid += 1 }
        return result
    }

    private static func readStore(_ journal: URL) throws -> Parsed {
        var result = Parsed()
        let decoder = makeDecoder()
        let sources = SessionReportStore.archiveURLs(for: journal) + [journal].filter { FileManager.default.fileExists(atPath: $0.path) }
        for source in sources {
            try forEachLine(in: source) { line in
                if let line, line.isEmpty { return }
                guard let line, let event = try? decoder.decode(SessionReportEvent.self, from: line), valid(event) else {
                    result.invalid += 1
                    return
                }
                result.events.append(event)
            }
        }
        return result
    }

    private static func valid(_ event: SessionReportEvent) -> Bool {
        let record = event.record
        guard let canonical = try? makeEncoder().encode(event), canonical.count + 1 <= SessionReportStore.maximumEventBytes else { return false }
        return (1...2).contains(event.schemaVersion) && !event.source.isEmpty && !event.sessionID.isEmpty &&
            record.promptTokens >= 0 && record.completionTokens >= 0 &&
            [record.promptCacheHitTokens, record.promptCacheMissTokens, record.promptCacheWriteTokens].allSatisfy { ($0 ?? 0) >= 0 } &&
            record.durationSeconds.isFinite && record.durationSeconds >= 0 && record.durationSeconds < Double(Int.max / 1000) &&
            record.timestamp.timeIntervalSince1970.isFinite &&
            (record.providerReportedCostUSD.map { $0.isFinite && $0 >= 0 } ?? true)
    }

    /// Validate the merged ledger before publication, not only each input row:
    /// independently valid counters can overflow downstream session/usage sums.
    private static func safeTotals(_ events: [SessionReportEvent]) -> Bool {
        var tokens = 0
        var cache = 0
        var milliseconds = 0
        var nestedTokens = 0
        var nestedCost = 0.0
        var cost = 0.0
        for event in events {
            let record = event.record
            for value in [record.promptTokens, record.completionTokens] {
                let sum = tokens.addingReportingOverflow(value)
                if sum.overflow { return false }; tokens = sum.partialValue
            }
            for value in [record.promptCacheHitTokens, record.promptCacheMissTokens, record.promptCacheWriteTokens] {
                let sum = cache.addingReportingOverflow(value ?? 0)
                if sum.overflow { return false }; cache = sum.partialValue
            }
            guard record.durationSeconds.isFinite, record.durationSeconds >= 0,
                  record.durationSeconds < Double(Int.max / 1000) else { return false }
            let sum = milliseconds.addingReportingOverflow(Int((record.durationSeconds * 1000).rounded()))
            if sum.overflow { return false }; milliseconds = sum.partialValue
            for receipt in record.serverToolCalls ?? [] {
                for value in [receipt.promptTokens, receipt.completionTokens] {
                    guard (value ?? 0) >= 0 else { return false }
                    let sum = nestedTokens.addingReportingOverflow(value ?? 0)
                    if sum.overflow { return false }; nestedTokens = sum.partialValue
                }
                let amount = receipt.providerReportedCostUSD ?? 0
                guard amount.isFinite, amount >= 0 else { return false }
                nestedCost += amount
                if !nestedCost.isFinite { return false }
            }
            cost += record.providerReportedCostUSD ?? 0
            if !cost.isFinite { return false }
        }
        return true
    }

    /// Reads full files in bounded chunks, including old archives larger than the
    /// rotation threshold. Oversized lines yield nil without retaining their body.
    static func forEachLine(in url: URL, _ body: (Data?) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data()
        var oversized = false
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            var start = chunk.startIndex
            while start < chunk.endIndex {
                let end = chunk[start...].firstIndex(of: 0x0A) ?? chunk.endIndex
                if !oversized {
                    if pending.count + end - start > SessionReportStore.maximumEventBytes {
                        oversized = true
                        pending.removeAll(keepingCapacity: true)
                    } else { pending.append(contentsOf: chunk[start..<end]) }
                }
                if end < chunk.endIndex {
                    try body(oversized ? nil : pending)
                    pending.removeAll(keepingCapacity: true)
                    oversized = false
                    start = end + 1
                } else { start = end }
            }
        }
        if oversized || !pending.isEmpty { try body(oversized ? nil : pending) }
    }

    private static func validateDestination(_ destination: URL, journal: URL) throws {
        let lexical = destination.standardizedFileURL
        let resolved = destination.resolvingSymlinksInPath().standardizedFileURL
        if (try? FileManager.default.attributesOfItem(atPath: lexical.path)[.type]) as? FileAttributeType == .typeSymbolicLink {
            throw SessionHistoryArchiveError.unsafeDestination
        }
        for source in [journal.standardizedFileURL, journal.resolvingSymlinksInPath().standardizedFileURL] {
            let base = source.deletingPathExtension().lastPathComponent + ".archive"
            for dest in [lexical, resolved] {
                if dest == source || dest == source.appendingPathExtension("lock") ||
                    (dest.deletingLastPathComponent() == source.deletingLastPathComponent() &&
                     (dest.lastPathComponent == "\(base).jsonl" || (dest.lastPathComponent.hasPrefix("\(base).") && dest.pathExtension == "jsonl"))) {
                    throw SessionHistoryArchiveError.unsafeDestination
                }
            }
        }
        if SessionReportStore.archiveURLs(for: journal).contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL == resolved }) {
            throw SessionHistoryArchiveError.unsafeDestination
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
    private static func digest(_ hash: SHA256) -> String {
        hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func write(_ data: Data, to handle: FileHandle) throws {
        var line = data
        line.append(0x0A)
        try handle.write(contentsOf: line)
    }
    private static func publish(to destination: URL, writeContents: (FileHandle) throws -> Void) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".history-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try writeContents(handle)
        try handle.synchronize()
        guard rename(temporary.path, destination.path) == 0 else { throw posixError() }
    }
    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
