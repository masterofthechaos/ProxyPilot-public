import XCTest
@testable import ProxyPilotCore

final class InputOutputLoggingStoreTests: XCTestCase {
    func testRetentionCleanupRunsWhenCaptureIsCurrentlyDisabled() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let preferencesStore = InputOutputLoggingPreferencesStore(
            url: directory.appendingPathComponent("settings.json")
        )
        try preferencesStore.save(InputOutputLoggingPreferences(
            enabled: false,
            recordInputs: false,
            recordOutputs: false,
            cliEnabled: false,
            retention: .untilQuit,
            externalStorageEnabled: false
        ))

        let key = Data(repeating: 0x41, count: 32)
        let logStore = InputOutputLogStore(
            url: InputOutputLogStore.resolvedURL(
                preferences: try preferencesStore.load()
            ),
            encryptionKey: key
        )
        let untilQuit = InputOutputLogRecord(
            timestamp: Date(timeIntervalSince1970: 1_714_000_000),
            source: "gui",
            path: "/v1/messages",
            model: "test-model",
            provider: "test-provider",
            wasStreaming: false,
            statusCode: 200,
            retentionExpiresAt: nil,
            deleteOnQuit: true,
            input: .utf8("sensitive prompt"),
            output: nil
        )
        try await logStore.append(untilQuit)

        let cleanup = InputOutputLoggingRecorder.retentionCleanupRecorder(
            source: "gui",
            preferencesStore: preferencesStore,
            encryptionKey: key
        )
        try await cleanup.pruneExpired(includeUntilQuit: true)

        let remaining = try await logStore.readRecords()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testLogKeyProviderUsesOverriddenKeychainServiceName() {
        XCTAssertEqual(
            InputOutputLogKeyProvider.keychainServiceName(
                environment: [SecretsProviderFactory.keychainServiceEnvVar: " proxypilot.tests.logging "]
            ),
            "proxypilot.tests.logging"
        )
        XCTAssertEqual(InputOutputLogKeyProvider.keychainServiceName(environment: [:]), "proxypilot")
    }

    func testExtendedRetentionCasesReturnCorrectDurations() {
        XCTAssertEqual(InputOutputLoggingRetention.sevenDays.durationSeconds, 7 * 24 * 60 * 60)
        XCTAssertEqual(InputOutputLoggingRetention.thirtyDays.durationSeconds, 30 * 24 * 60 * 60)
    }

    func testExpirationDateIsNoLongerCappedAtTwentyFourHours() {
        let timestamp = Date(timeIntervalSince1970: 1_714_000_000)

        XCTAssertEqual(
            InputOutputLoggingRetention.sevenDays.expirationDate(from: timestamp),
            timestamp.addingTimeInterval(7 * 24 * 60 * 60)
        )
        XCTAssertEqual(
            InputOutputLoggingRetention.thirtyDays.expirationDate(from: timestamp),
            timestamp.addingTimeInterval(30 * 24 * 60 * 60)
        )
        // Existing short-window cases must be unaffected by removing the old 24h cap.
        XCTAssertEqual(
            InputOutputLoggingRetention.oneHour.expirationDate(from: timestamp),
            timestamp.addingTimeInterval(60 * 60)
        )
        XCTAssertEqual(
            InputOutputLoggingRetention.twentyFourHoursDefault.expirationDate(from: timestamp),
            timestamp.addingTimeInterval(24 * 60 * 60)
        )
        XCTAssertNil(InputOutputLoggingRetention.untilQuit.expirationDate(from: timestamp))
    }

    func testPruneExpiredHandlesThirtyDayRetentionWindowRecords() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = directory.appendingPathComponent("records.jsonl.enc")
        let store = InputOutputLogStore(
            url: logURL,
            encryptionKey: Data(repeating: 3, count: 32)
        )

        let now = Date(timeIntervalSince1970: 1_714_000_000)
        let withinWindow = InputOutputLogRecord(
            timestamp: now,
            source: "cli",
            path: "/v1/messages",
            model: "glm-5",
            provider: "zai",
            wasStreaming: false,
            statusCode: 200,
            retentionExpiresAt: InputOutputLoggingRetention.thirtyDays.expirationDate(from: now),
            input: nil,
            output: nil
        )
        let expired = InputOutputLogRecord(
            timestamp: now.addingTimeInterval(-31 * 24 * 60 * 60),
            source: "cli",
            path: "/v1/messages",
            model: "glm-5",
            provider: "zai",
            wasStreaming: false,
            statusCode: 200,
            retentionExpiresAt: now.addingTimeInterval(-24 * 60 * 60),
            input: nil,
            output: nil
        )

        try await store.append(expired)
        try await store.append(withinWindow)
        try await store.pruneExpired(now: now)

        let remaining = try await store.readRecords()
        XCTAssertEqual(remaining.map(\.id), [withinWindow.id])
    }

    func testPruneExpiredDropsCorruptLinesInsteadOfThrowing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = directory.appendingPathComponent("records.jsonl.enc")
        let store = InputOutputLogStore(
            url: logURL,
            encryptionKey: Data(repeating: 3, count: 32)
        )

        let now = Date(timeIntervalSince1970: 1_714_000_000)
        let valid = InputOutputLogRecord(
            timestamp: now,
            source: "gui",
            path: "/v1/messages",
            model: "glm-5",
            provider: "zai",
            wasStreaming: false,
            statusCode: 200,
            retentionExpiresAt: InputOutputLoggingRetention.thirtyDays.expirationDate(from: now),
            input: .utf8("prompt"),
            output: nil
        )
        try await store.append(valid)

        // Simulate a partial write / key-rotation remnant: a line that cannot decrypt.
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not-a-valid-encrypted-line\n".utf8))
        try handle.close()

        // Prune must not throw, must keep the valid record, and must drop the corrupt line.
        try await store.pruneExpired(now: now)
        let remaining = try await store.readRecords()
        XCTAssertEqual(remaining.map(\.id), [valid.id])

        // New appends keep working after the corrupt line is cleaned up.
        try await store.append(valid)
        let afterAppend = try await store.readRecords()
        XCTAssertEqual(afterAppend.count, 2)
    }

    func testRecorderSavesNewRecordsUnderThirtyDayRetentionDespiteCorruptStoreLine() async throws {
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
            retention: .thirtyDays,
            externalStorageEnabled: false
        ))

        // Pre-seed the store with a line the recorder cannot decrypt.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("corrupt-line\n".utf8).write(to: logURL)

        let recorder = InputOutputLoggingRecorder(
            source: "gui",
            preferencesStore: preferencesStore,
            logStore: InputOutputLogStore(
                url: logURL,
                encryptionKey: Data(repeating: 6, count: 32)
            )
        )
        let now = Date(timeIntervalSince1970: 1_714_000_000)

        try await recorder.record(
            path: "/v1/messages",
            model: "glm-5",
            provider: "zai",
            wasStreaming: false,
            statusCode: 200,
            startedAt: now,
            inputBody: Data("thirty-day prompt".utf8),
            outputBody: Data("thirty-day output".utf8)
        )

        let jsonl = try await recorder.exportJSONL(now: now)
        XCTAssertTrue(jsonl.contains("thirty-day prompt"))
        let records = try await recorder.readRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(
            records[0].retentionExpiresAt,
            InputOutputLoggingRetention.thirtyDays.expirationDate(from: now)
        )
    }

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

    func testReadRecordsMatchingSessionIDReturnsOnlyThatSession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = directory.appendingPathComponent("records.jsonl.enc")
        let store = InputOutputLogStore(
            url: logURL,
            encryptionKey: Data(repeating: 7, count: 32)
        )

        let targetOlder = InputOutputLogRecord(
            timestamp: Date(timeIntervalSince1970: 10),
            source: "cli",
            sessionID: "target",
            path: "/v1/messages",
            model: "glm-5",
            provider: "zai",
            wasStreaming: true,
            statusCode: 200,
            retentionExpiresAt: nil,
            input: .utf8("target older prompt"),
            output: .utf8("target older output")
        )
        let other = InputOutputLogRecord(
            timestamp: Date(timeIntervalSince1970: 20),
            source: "cli",
            sessionID: "other",
            path: "/v1/messages",
            model: "glm-5",
            provider: "zai",
            wasStreaming: true,
            statusCode: 200,
            retentionExpiresAt: nil,
            input: .utf8("other prompt"),
            output: .utf8("other output")
        )
        let targetNewer = InputOutputLogRecord(
            timestamp: Date(timeIntervalSince1970: 30),
            source: "cli",
            sessionID: "target",
            path: "/v1/messages",
            model: "glm-5",
            provider: "zai",
            wasStreaming: true,
            statusCode: 200,
            retentionExpiresAt: nil,
            input: .utf8("target newer prompt"),
            output: .utf8("target newer output")
        )

        try await store.append(targetOlder)
        try await store.append(other)
        try await store.append(targetNewer)

        let decoded = try await store.readRecords(matchingSessionID: "target")
        XCTAssertEqual(decoded.map(\.sessionID), ["target", "target"])
        XCTAssertEqual(
            decoded.map { $0.input?.text },
            ["target older prompt", "target newer prompt"]
        )

        // Stored IDs are mixed-case (daemon sessions keep `UUID().uuidString`
        // uppercase; attributed sessions are lowercased), so lookups must not
        // care about case.
        let caseInsensitive = try await store.readRecords(matchingSessionID: "TARGET")
        XCTAssertEqual(caseInsensitive.count, 2)
    }

    func testRecordFilesUnderRequestAttributionSessionNotRecorderSession() async throws {
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
            retention: .twentyFourHoursDefault
        ))

        let daemonSessionID = UUID().uuidString // uppercase, as ProxyConfiguration defaults
        let recorder = InputOutputLoggingRecorder(
            source: "cli",
            sessionID: daemonSessionID,
            preferencesStore: preferencesStore,
            logStore: InputOutputLogStore(
                url: logURL,
                encryptionKey: Data(repeating: 9, count: 32)
            )
        )

        // An attributed request (X-ProxyPilot-Client/-Session-ID) must file
        // under the caller's session, mirroring SessionStats.record. Before the
        // fix every record carried the daemon's own session ID, so
        // `sessions show <agent-session> --include-logs` returned 0 records for
        // sessions whose reports attributed correctly.
        let attribution = try XCTUnwrap(RequestAttribution.validated(
            client: "repogps",
            sessionID: "5A01889E-762F-477B-BFB2-17F5DA3EE310"
        ))
        try await RequestAttributionContext.$current.withValue(attribution) {
            try await recorder.record(
                path: "/v1/chat/completions",
                model: "glm-5",
                provider: "zai",
                wasStreaming: true,
                statusCode: 200,
                startedAt: Date(timeIntervalSince1970: 100),
                inputBody: Data("attributed prompt".utf8),
                outputBody: Data("attributed output".utf8)
            )
        }

        // An unattributed request keeps the recorder's own session.
        try await recorder.record(
            path: "/v1/messages",
            model: "glm-5",
            provider: "zai",
            wasStreaming: false,
            statusCode: 200,
            startedAt: Date(timeIntervalSince1970: 200),
            inputBody: Data("daemon prompt".utf8),
            outputBody: Data("daemon output".utf8)
        )

        let attributed = try await recorder.readRecords(
            matchingSessionID: "5a01889e-762f-477b-bfb2-17f5da3ee310"
        )
        XCTAssertEqual(attributed.count, 1)
        XCTAssertEqual(attributed.first?.source, "repogps")
        XCTAssertEqual(attributed.first?.input?.text, "attributed prompt")

        let daemon = try await recorder.readRecords(matchingSessionID: daemonSessionID)
        XCTAssertEqual(daemon.count, 1)
        XCTAssertEqual(daemon.first?.source, "cli")
        XCTAssertEqual(daemon.first?.input?.text, "daemon prompt")
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

    func testResolvedURLPrefersValidExternalStorageOverride() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let preferences = InputOutputLoggingPreferences(
            externalStorageEnabled: true,
            externalStoragePath: directory.path
        )

        XCTAssertEqual(
            InputOutputLogStore.resolvedURL(preferences: preferences),
            directory.appendingPathComponent("records.jsonl.enc")
        )
        XCTAssertTrue(InputOutputLogStore.isExternalStorageOverrideReachable(preferences: preferences))
    }

    func testResolvedURLFallsBackToDefaultWhenOverrideDirectoryIsMissing() throws {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let preferences = InputOutputLoggingPreferences(
            externalStorageEnabled: true,
            externalStoragePath: missingDirectory.path
        )

        XCTAssertEqual(InputOutputLogStore.resolvedURL(preferences: preferences), InputOutputLogStore.defaultURL)
        XCTAssertFalse(InputOutputLogStore.isExternalStorageOverrideReachable(preferences: preferences))
    }

    func testResolvedURLUsesDefaultWhenExternalStorageDisabled() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let preferences = InputOutputLoggingPreferences(
            externalStorageEnabled: false,
            externalStoragePath: directory.path
        )

        XCTAssertEqual(InputOutputLogStore.resolvedURL(preferences: preferences), InputOutputLogStore.defaultURL)
        XCTAssertTrue(InputOutputLogStore.isExternalStorageOverrideReachable(preferences: preferences))
    }

    func testPreferencesDecodeWithoutExternalStoragePathDefaultsToNil() throws {
        let json = """
        {
            "enabled": true,
            "recordInputs": true,
            "recordOutputs": false,
            "cliEnabled": false,
            "retention": "twentyFourHoursDefault",
            "externalStorageEnabled": false
        }
        """
        let decoded = try JSONDecoder().decode(InputOutputLoggingPreferences.self, from: Data(json.utf8))
        XCTAssertNil(decoded.externalStoragePath)
        XCTAssertTrue(decoded.enabled)
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

    func testPreferencesDefaultURLUsesXDGConfigHomeWhenProvided() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = InputOutputLoggingPreferencesStore.defaultURL(
            environment: ["XDG_CONFIG_HOME": directory.path]
        )

        XCTAssertEqual(
            url.path,
            directory
                .appendingPathComponent("proxypilot", isDirectory: true)
                .appendingPathComponent("input-output-logging", isDirectory: true)
                .appendingPathComponent("settings.json")
                .path
        )
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

    func testEncryptedStoreCreatesLogFileWithPrivatePermissions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = directory.appendingPathComponent("records.jsonl.enc")
        let store = InputOutputLogStore(
            url: logURL,
            encryptionKey: Data(repeating: 7, count: 32)
        )

        try await store.append(InputOutputLogRecord(
            timestamp: Date(timeIntervalSince1970: 1_714_000_000),
            source: "cli",
            path: "/v1/messages",
            model: "glm-5",
            provider: "zai",
            wasStreaming: false,
            statusCode: 200,
            retentionExpiresAt: nil,
            input: .utf8("prompt"),
            output: .utf8("output")
        ))

        XCTAssertEqual(try filePermissions(at: logURL), 0o600)
    }

    func testEncryptedStoreRewriteRestoresPrivatePermissions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = directory.appendingPathComponent("records.jsonl.enc")
        let store = InputOutputLogStore(
            url: logURL,
            encryptionKey: Data(repeating: 8, count: 32)
        )
        let now = Date(timeIntervalSince1970: 1_714_000_000)

        try await store.append(InputOutputLogRecord(
            timestamp: now.addingTimeInterval(-7200),
            source: "gui",
            path: "/v1/messages",
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
            path: "/v1/messages",
            model: "fresh",
            provider: "zai",
            wasStreaming: false,
            statusCode: 200,
            retentionExpiresAt: now.addingTimeInterval(3600),
            input: .utf8("new"),
            output: nil
        ))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: logURL.path)
        try await store.pruneExpired(now: now)

        XCTAssertEqual(try filePermissions(at: logURL), 0o600)
        let records = try await store.readRecords()
        XCTAssertEqual(records.map(\.model), ["fresh"])
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

    /// Regression: the CLI/MCP proxy entry points used to resolve the recorder
    /// once at daemon start and freeze it into `ProxyConfiguration`, so enabling
    /// capture under a running daemon could never attach a recorder — the defect
    /// recorded in the 2026-07-08 and 2026-07-14 punch-outs. `inputOutputLogger`
    /// must now resolve through the provider on every access.
    func testConfigurationResolvesInputOutputLoggerOnEveryAccess() throws {
        final class ProviderState: @unchecked Sendable {
            private let lock = NSLock()
            private var recorder: InputOutputLoggingRecorder?
            private(set) var callCount = 0

            func resolve() -> InputOutputLoggingRecorder? {
                lock.lock()
                defer { lock.unlock() }
                callCount += 1
                return recorder
            }

            func enable(_ recorder: InputOutputLoggingRecorder) {
                lock.lock()
                defer { lock.unlock() }
                self.recorder = recorder
            }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let preferencesStore = InputOutputLoggingPreferencesStore(
            url: directory.appendingPathComponent("settings.json")
        )
        let recorder = InputOutputLoggingRecorder(
            source: "cli",
            preferencesStore: preferencesStore,
            logStore: InputOutputLogStore(
                url: directory.appendingPathComponent("records.jsonl.enc"),
                encryptionKey: Data(repeating: 7, count: 32)
            )
        )

        let state = ProviderState()
        let config = ProxyConfiguration(inputOutputLoggerProvider: { state.resolve() })

        // Capture is off when the proxy starts: no recorder.
        XCTAssertNil(config.inputOutputLogger)
        XCTAssertEqual(state.callCount, 1)

        // Capture is enabled mid-session, without restarting the proxy.
        state.enable(recorder)

        XCTAssertNotNil(config.inputOutputLogger)
        XCTAssertEqual(state.callCount, 2, "Provider must be consulted per access, not memoized by the configuration.")
    }

    /// The convenience initializer that takes an already-resolved recorder must
    /// keep returning that same recorder (constant provider, no live pickup).
    func testConfigurationWithResolvedRecorderKeepsReturningIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let recorder = InputOutputLoggingRecorder(
            source: "cli",
            preferencesStore: InputOutputLoggingPreferencesStore(
                url: directory.appendingPathComponent("settings.json")
            ),
            logStore: InputOutputLogStore(
                url: directory.appendingPathComponent("records.jsonl.enc"),
                encryptionKey: Data(repeating: 9, count: 32)
            )
        )

        let config = ProxyConfiguration(inputOutputLogger: recorder)
        XCTAssertNotNil(config.inputOutputLogger)
        XCTAssertNotNil(config.inputOutputLogger)

        let none = ProxyConfiguration(inputOutputLogger: nil)
        XCTAssertNil(none.inputOutputLogger)
    }

    private func filePermissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
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
