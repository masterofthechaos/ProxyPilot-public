import XCTest
@testable import ProxyPilotCore

final class InputOutputLoggingStoreTests: XCTestCase {
    func testOutputTruncatedFlagRoundTripsThroughEncryptedStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = directory.appendingPathComponent("records.jsonl.enc")
        let store = InputOutputLogStore(
            url: logURL,
            encryptionKey: Data(repeating: 9, count: 32)
        )

        let timestamp = Date(timeIntervalSince1970: 1_714_000_000)
        let truncated = InputOutputLogRecord(
            timestamp: timestamp,
            source: "cli",
            path: "/v1/messages",
            model: "glm-5",
            provider: "zai",
            wasStreaming: true,
            statusCode: 200,
            retentionExpiresAt: nil,
            input: .utf8("prompt"),
            output: .utf8("partial output"),
            outputTruncated: true
        )
        let untruncated = InputOutputLogRecord(
            timestamp: timestamp.addingTimeInterval(1),
            source: "cli",
            path: "/v1/messages",
            model: "glm-5",
            provider: "zai",
            wasStreaming: true,
            statusCode: 200,
            retentionExpiresAt: nil,
            input: .utf8("prompt"),
            output: .utf8("full output"),
            outputTruncated: nil
        )

        try await store.append(truncated)
        try await store.append(untruncated)

        let decoded = try await store.readRecords()
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].outputTruncated, true)
        XCTAssertNil(decoded[1].outputTruncated)
    }

    func testRecordWithoutOutputTruncatedFieldDecodesAsNilForBackwardCompat() throws {
        // Records written by pre-v1.8.0 code do not include `outputTruncated`
        // in their JSON. The synthesized Codable must tolerate the missing
        // field and decode it as nil.
        let legacyJSON = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "schemaVersion": 2,
          "timestamp": "2026-05-01T00:00:00Z",
          "source": "cli",
          "sessionID": null,
          "path": "/v1/messages",
          "model": "glm-5",
          "provider": "zai",
          "wasStreaming": false,
          "statusCode": 200,
          "retentionExpiresAt": null,
          "deleteOnQuit": false,
          "input": {"encoding":"utf8","text":"prompt","base64":null,"byteCount":6},
          "output": {"encoding":"utf8","text":"output","base64":null,"byteCount":6}
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let record = try decoder.decode(
            InputOutputLogRecord.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertNil(record.outputTruncated)
        XCTAssertEqual(record.source, "cli")
    }

    func testPreferencesPersistToSharedJSONFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("settings.json")
        let store = InputOutputLoggingPreferencesStore(url: url)

        let preferences = InputOutputLoggingPreferences(
            enabled: true,
            recordInputs: true,
            recordOutputs: false,
            cliEnabled: true,
            retention: .sixHours,
            externalStorageEnabled: false
        )

        try store.save(preferences)

        XCTAssertEqual(try store.load(), preferences)
    }

    func testEncryptedStoreDoesNotWritePlainPromptOrOutputText() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = directory.appendingPathComponent("records.jsonl.enc")
        let store = InputOutputLogStore(
            url: logURL,
            encryptionKey: Data(repeating: 7, count: 32)
        )

        let timestamp = Date(timeIntervalSince1970: 1_714_000_000)
        let record = InputOutputLogRecord(
            timestamp: timestamp,
            source: "cli",
            path: "/v1/chat/completions",
            model: "glm-5",
            provider: "zai",
            wasStreaming: false,
            statusCode: 200,
            retentionExpiresAt: timestamp.addingTimeInterval(3600),
            input: .utf8("secret prompt"),
            output: .utf8("secret output")
        )

        try await store.append(record)

        let raw = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("secret prompt"))
        XCTAssertFalse(raw.contains("secret output"))

        let decoded = try await store.readRecords()
        XCTAssertEqual(decoded, [record])
    }

    func testEncryptedStorePrunesExpiredRecords() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = directory.appendingPathComponent("records.jsonl.enc")
        let store = InputOutputLogStore(
            url: logURL,
            encryptionKey: Data(repeating: 9, count: 32)
        )
        let now = Date(timeIntervalSince1970: 1_714_000_000)

        try await store.append(InputOutputLogRecord(
            timestamp: now.addingTimeInterval(-7200),
            source: "gui",
            path: "/v1/chat/completions",
            model: "expired",
            provider: "zai",
            wasStreaming: false,
            statusCode: 200,
            retentionExpiresAt: now.addingTimeInterval(-3600),
            input: .utf8("old"),
            output: nil
        ))
        try await store.append(InputOutputLogRecord(
            timestamp: now,
            source: "gui",
            path: "/v1/chat/completions",
            model: "fresh",
            provider: "zai",
            wasStreaming: false,
            statusCode: 200,
            retentionExpiresAt: now.addingTimeInterval(3600),
            input: .utf8("new"),
            output: nil
        ))

        try await store.pruneExpired(now: now)

        let records = try await store.readRecords()
        XCTAssertEqual(records.map(\.model), ["fresh"])
    }

    func testRecorderExportsDecryptedJSONLAndPrunesExpiredRecords() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let preferencesURL = directory.appendingPathComponent("settings.json")
        let logURL = directory.appendingPathComponent("records.jsonl.enc")
        let preferencesStore = InputOutputLoggingPreferencesStore(url: preferencesURL)
        try preferencesStore.save(InputOutputLoggingPreferences(
            enabled: true,
            recordInputs: true,
            recordOutputs: true,
            cliEnabled: false,
            retention: .oneHour,
            externalStorageEnabled: false
        ))

        let recorder = InputOutputLoggingRecorder(
            source: "gui",
            preferencesStore: preferencesStore,
            logStore: InputOutputLogStore(
                url: logURL,
                encryptionKey: Data(repeating: 4, count: 32)
            )
        )
        let now = Date(timeIntervalSince1970: 1_714_000_000)

        try await recorder.record(
            path: "/v1/chat/completions",
            model: "expired-model",
            provider: "zai",
            wasStreaming: false,
            statusCode: 200,
            startedAt: now.addingTimeInterval(-7200),
            inputBody: Data("old prompt".utf8),
            outputBody: Data("old output".utf8)
        )
        try await recorder.record(
            path: "/v1/chat/completions",
            model: "fresh-model",
            provider: "zai",
            wasStreaming: false,
            statusCode: 200,
            startedAt: now,
            inputBody: Data("fresh prompt".utf8),
            outputBody: Data("fresh output".utf8)
        )

        let jsonl = try await recorder.exportJSONL(now: now)

        XCTAssertFalse(jsonl.contains("old prompt"))
        XCTAssertTrue(jsonl.contains("fresh prompt"))
        XCTAssertTrue(jsonl.contains("fresh output"))

        let exportedLines = jsonl.split(separator: "\n")
        XCTAssertEqual(exportedLines.count, 1)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exported = try decoder.decode(
            InputOutputLogRecord.self,
            from: Data(exportedLines[0].utf8)
        )
        XCTAssertEqual(exported.model, "fresh-model")
        let recordCount = try await recorder.recordCount(now: now)
        XCTAssertEqual(recordCount, 1)

        try await recorder.resetRecords()
        let resetRecords = try await recorder.readRecords()
        XCTAssertEqual(resetRecords, [])
    }

    func testRecorderHonorsPreferencesAndSource() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let preferencesURL = directory.appendingPathComponent("settings.json")
        let logURL = directory.appendingPathComponent("records.jsonl.enc")
        let preferencesStore = InputOutputLoggingPreferencesStore(url: preferencesURL)
        try preferencesStore.save(InputOutputLoggingPreferences(
            enabled: true,
            recordInputs: true,
            recordOutputs: false,
            cliEnabled: false,
            retention: .oneHour,
            externalStorageEnabled: false
        ))

        let recorder = InputOutputLoggingRecorder(
            source: "cli",
            preferencesStore: preferencesStore,
            logStore: InputOutputLogStore(
                url: logURL,
                encryptionKey: Data(repeating: 3, count: 32)
            )
        )

        try await recorder.record(
            path: "/v1/chat/completions",
            model: "glm-5",
            provider: "zai",
            wasStreaming: false,
            statusCode: 200,
            startedAt: Date(timeIntervalSince1970: 1_714_000_000),
            inputBody: Data("prompt".utf8),
            outputBody: Data("output".utf8)
        )

        let initiallyRecorded = try await recorder.readRecords()
        XCTAssertEqual(initiallyRecorded, [])

        try preferencesStore.save(InputOutputLoggingPreferences(
            enabled: true,
            recordInputs: true,
            recordOutputs: false,
            cliEnabled: true,
            retention: .oneHour,
            externalStorageEnabled: false
        ))

        try await recorder.record(
            path: "/v1/chat/completions",
            model: "glm-5",
            provider: "zai",
            wasStreaming: false,
            statusCode: 200,
            startedAt: Date(timeIntervalSince1970: 1_714_000_000),
            inputBody: Data("prompt".utf8),
            outputBody: Data("output".utf8)
        )

        let records = try await recorder.readRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].input?.text, "prompt")
        XCTAssertNil(records[0].output)
    }

    func testRecorderPersistsSessionIdentifierForJoiningToReportHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let preferencesURL = directory.appendingPathComponent("settings.json")
        let logURL = directory.appendingPathComponent("records.jsonl.enc")
        let preferencesStore = InputOutputLoggingPreferencesStore(url: preferencesURL)
        try preferencesStore.save(InputOutputLoggingPreferences(
            enabled: true,
            recordInputs: true,
            recordOutputs: true,
            cliEnabled: true,
            retention: .twentyFourHoursDefault,
            externalStorageEnabled: false
        ))

        let recorder = InputOutputLoggingRecorder(
            source: "cli",
            sessionID: "cli-history-session",
            preferencesStore: preferencesStore,
            logStore: InputOutputLogStore(
                url: logURL,
                encryptionKey: Data(repeating: 5, count: 32)
            )
        )

        try await recorder.record(
            path: "/v1/messages",
            model: "glm-5.1",
            provider: "zai",
            wasStreaming: false,
            statusCode: 200,
            startedAt: Date(timeIntervalSince1970: 1_714_000_000),
            inputBody: Data("{\"messages\":[]}".utf8),
            outputBody: Data("{\"id\":\"response\"}".utf8)
        )

        let records = try await recorder.readRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].sessionID, "cli-history-session")
    }
}
