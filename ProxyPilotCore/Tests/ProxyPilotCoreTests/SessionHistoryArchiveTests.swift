import Foundation
import Testing
@testable import ProxyPilotCore

@Suite struct SessionHistoryArchiveTests {
    private func event(id: UUID = UUID(), model: String = "model", schema: Int = 2) -> SessionReportEvent {
        SessionReportEvent(id: id, schemaVersion: schema, source: "repogps", sessionID: "preserved-session", role: "lead",
            record: RequestRecord(timestamp: Date(timeIntervalSince1970: 1_700_000_000), model: model,
                requestedModel: "proxypilot-active", providerReportedCostUSD: 0.25,
                promptTokens: 100, completionTokens: 10, promptCacheHitTokens: 40,
                promptCacheMissTokens: 60, promptCacheWriteTokens: 20, durationSeconds: 1,
                path: "/v1/chat/completions", wasStreaming: true, providerIdentifier: "openrouter",
                serverToolCalls: [.init(callID: "call-1", role: "advisor", status: "ok", returnedModel: "advisor", promptTokens: 5, completionTokens: 2)]))
    }
    private func root() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func encode(_ event: SessionReportEvent) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(event); data.append(0x0A)
        return data
    }

    @Test func mergedTotalsOverflowRejectedBeforePublishing() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jsonl"), target = root.appendingPathComponent("target.jsonl")
        let backup = root.appendingPathComponent("backup.pphistory")
        func huge() -> SessionReportEvent {
            SessionReportEvent(source: "fixture", sessionID: "overflow", record: RequestRecord(model: "fixture",
                promptTokens: Int.max / 2, completionTokens: 1, durationSeconds: 1, path: "/v1/chat/completions", wasStreaming: false))
        }
        try SessionReportStore.append(huge(), to: source)
        try SessionReportStore.append(huge(), to: target)
        try SessionHistoryArchive.export(to: backup, from: source)
        let before = try Data(contentsOf: target)
        #expect(try !SessionHistoryArchive.previewImport(from: backup, into: target).canImport)
        #expect(throws: SessionHistoryArchiveError.self) { try SessionHistoryArchive.merge(from: backup, into: target) }
        #expect(try Data(contentsOf: target) == before)
    }

    @Test func canonicalEncodingExpansionRejectedBeforeExport() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jsonl"), backup = root.appendingPathComponent("backup.pphistory")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var raw = try encoder.encode(event(model: String(repeating: "/", count: 40000))); raw.append(0x0A)
        #expect(raw.count < SessionReportStore.maximumEventBytes)
        try raw.write(to: source)
        #expect(throws: SessionHistoryArchiveError.self) { try SessionHistoryArchive.export(to: backup, from: source) }
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func exportRejectsLiveArchiveSymlinkAndJournalAliasNamespaces() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("session.jsonl"), outside = root.appendingPathComponent("external.jsonl")
        let link = root.appendingPathComponent("session.archive.old.jsonl")
        try encode(event()).write(to: outside)
        try SessionReportStore.append(event(), to: journal)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let before = try Data(contentsOf: outside)
        #expect(throws: SessionHistoryArchiveError.self) { try SessionHistoryArchive.export(to: link, from: journal) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == outside.path)
        #expect(try Data(contentsOf: outside) == before)
        let alias = root.appendingPathComponent("alias.jsonl")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: journal)
        #expect(throws: SessionHistoryArchiveError.self) {
            try SessionHistoryArchive.export(to: root.appendingPathComponent("alias.archive.new.jsonl"), from: alias)
        }
    }

    @Test func nestedReceiptOverflowCannotEnterPortableHistory() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jsonl"), backup = root.appendingPathComponent("backup.pphistory")
        let record = RequestRecord(model: "fixture", promptTokens: 1, completionTokens: 1,
            durationSeconds: 1, path: "/v1/chat/completions", wasStreaming: false,
            serverToolCalls: [.init(callID: "nested", role: "advisor", status: "ok", returnedModel: nil, promptTokens: Int.max, completionTokens: 1)])
        try SessionReportStore.append(.init(source: "fixture", sessionID: "nested", record: record), to: source)
        #expect(throws: SessionHistoryArchiveError.self) { try SessionHistoryArchive.export(to: backup, from: source) }
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func roundTripPreservesUUIDsMetadataLegacyAndNewHistory() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jsonl"), target = root.appendingPathComponent("target.jsonl")
        let backup = root.appendingPathComponent("backup.pphistory")
        let old = event(schema: 1), shared = event(), current = event()
        try encode(old).write(to: root.appendingPathComponent("source.archive.jsonl"))
        try SessionReportStore.append(shared, to: source)
        try SessionReportStore.append(shared, to: target)
        try SessionReportStore.append(current, to: target)
        let originalBytes = try Data(contentsOf: target)
        #expect(try SessionHistoryArchive.export(to: backup, from: source) == 2)
        let preview = try SessionHistoryArchive.previewImport(from: backup, into: target)
        #expect(preview.newEvents == 1 && preview.duplicateEvents == 1 && preview.canImport)
        #expect(try Data(contentsOf: target) == originalBytes)
        let imported = try SessionHistoryArchive.merge(from: backup, into: target)
        #expect(imported == preview)
        let events = try SessionReportStore.readEvents(from: target)
        #expect(Set(events.map(\.id)) == Set([old.id, shared.id, current.id]))
        #expect(events.first { $0.id == old.id } == old)
        #expect(try Data(contentsOf: target) == originalBytes)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let again = try SessionHistoryArchive.merge(from: backup, into: target)
        #expect(again.newEvents == 0 && again.duplicateEvents == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == files.sorted())
        let mode = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test func conflictingUUIDRejectsEntireImportIncludingUnrelatedNewEvents() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jsonl"), target = root.appendingPathComponent("target.jsonl")
        let backup = root.appendingPathComponent("backup.pphistory"), id = UUID()
        try SessionReportStore.append(event(id: id, model: "original"), to: target)
        try SessionReportStore.append(event(id: id, model: "changed"), to: source)
        try SessionReportStore.append(event(), to: source)
        try SessionHistoryArchive.export(to: backup, from: source)
        let before = try SessionReportStore.readEvents(from: target)
        let preview = try SessionHistoryArchive.previewImport(from: backup, into: target)
        #expect(preview.conflictingEvents == 1 && preview.newEvents == 1 && !preview.canImport)
        #expect(throws: SessionHistoryArchiveError.self) { try SessionHistoryArchive.merge(from: backup, into: target) }
        #expect(try SessionReportStore.readEvents(from: target) == before)
    }

    @Test func truncationCorruptionAndUnsupportedVersionRejectBeforeMutation() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jsonl"), target = root.appendingPathComponent("target.jsonl")
        let backup = root.appendingPathComponent("backup.pphistory")
        try SessionReportStore.append(event(), to: source)
        try SessionHistoryArchive.export(to: backup, from: source)
        let text = try String(contentsOf: backup, encoding: .utf8)
        let lines = text.split(separator: "\n")
        let candidates = [lines.dropLast().joined(separator: "\n") + "\n",
                          text.replacingOccurrences(of: "\"version\":1", with: "\"version\":999"),
                          text.replacingOccurrences(of: "\"completionTokens\":10", with: "\"completionTokens\":11")]
        for candidate in candidates {
            try candidate.write(to: backup, atomically: true, encoding: .utf8)
            let preview = try SessionHistoryArchive.previewImport(from: backup, into: target)
            #expect(preview.invalidRecords > 0 && !preview.canImport)
            #expect(throws: SessionHistoryArchiveError.self) { try SessionHistoryArchive.merge(from: backup, into: target) }
            #expect(try SessionReportStore.readEvents(from: target).isEmpty)
        }
    }

    @Test func fullLargeArchivesAndCurrentJournalAreReadWithoutTailTruncation() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jsonl"), target = root.appendingPathComponent("target.jsonl")
        let archive = root.appendingPathComponent("source.archive.legacy.jsonl"), backup = root.appendingPathComponent("backup.pphistory")
        var bytes = Data()
        for _ in 0..<190 { bytes.append(try encode(event(model: String(repeating: "x", count: 45_000)))) }
        #expect(bytes.count > SessionReportStore.maximumFileBytes)
        try bytes.write(to: archive)
        try SessionReportStore.append(event(), to: source)
        #expect(try SessionReportStore.readEvents(from: source).count == 191)
        #expect(try SessionHistoryArchive.export(to: backup, from: source) == 191)
        #expect(try SessionHistoryArchive.merge(from: backup, into: target).newEvents == 191)
        #expect(try SessionReportStore.readEvents(from: target).count == 191)
    }

    @Test func concurrentAppendAndImportPreserveEveryEvent() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jsonl"), target = root.appendingPathComponent("target.jsonl")
        let backup = root.appendingPathComponent("backup.pphistory")
        let imported = event()
        try SessionReportStore.append(imported, to: source)
        try SessionHistoryArchive.export(to: backup, from: source)
        let appended = (0..<30).map { _ in event() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try SessionHistoryArchive.merge(from: backup, into: target) }
            for event in appended { group.addTask { try SessionReportStore.append(event, to: target) } }
            try await group.waitForAll()
        }
        #expect(Set(try SessionReportStore.readEvents(from: target).map(\.id)) == Set((appended + [imported]).map(\.id)))
    }

    @Test func invalidStoredMetadataCannotProducePartialBackup() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jsonl"), backup = root.appendingPathComponent("backup.pphistory")
        try Data("existing backup".utf8).write(to: backup)
        var bytes = try encode(event())
        bytes.append(Data("{\"broken\":true}\n".utf8))
        try bytes.write(to: source)
        #expect(throws: SessionHistoryArchiveError.self) { try SessionHistoryArchive.export(to: backup, from: source) }
        #expect(try String(contentsOf: backup, encoding: .utf8) == "existing backup")
    }

    @Test func exportCannotOverwriteTheLiveJournalOrArchive() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jsonl")
        try SessionReportStore.append(event(), to: source)
        for name in ["source.jsonl", "source.jsonl.lock", "source.archive.jsonl", "source.archive.new.jsonl"] {
            #expect(throws: SessionHistoryArchiveError.self) { try SessionHistoryArchive.export(to: root.appendingPathComponent(name), from: source) }
        }
        #expect(try SessionReportStore.readEvents(from: source).count == 1)
    }

    @Test func oversizedLineIsSkippedWithoutLosingFollowingRecord() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jsonl"), backup = root.appendingPathComponent("backup.pphistory")
        var bytes = Data(repeating: 0x41, count: SessionReportStore.maximumEventBytes * 3)
        bytes.append(0x0A)
        let valid = event(); bytes.append(try encode(valid))
        try bytes.write(to: source)
        #expect(try SessionReportStore.readEvents(from: source) == [valid])
        #expect(throws: SessionHistoryArchiveError.self) { try SessionHistoryArchive.export(to: backup, from: source) }
    }
}
