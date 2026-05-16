import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

#if canImport(Security)
import Security
#endif

public enum InputOutputLoggingRetention: String, Sendable, Codable, CaseIterable {
    case twentyFourHoursDefault
    case untilQuit
    case thirtyMinutes
    case oneHour
    case twoHours
    case sixHours
    case twelveHours
    case twentyFourHoursMaximum

    public var durationSeconds: TimeInterval? {
        switch self {
        case .untilQuit:
            return nil
        case .thirtyMinutes:
            return 30 * 60
        case .oneHour:
            return 60 * 60
        case .twoHours:
            return 2 * 60 * 60
        case .sixHours:
            return 6 * 60 * 60
        case .twelveHours:
            return 12 * 60 * 60
        case .twentyFourHoursDefault, .twentyFourHoursMaximum:
            return 24 * 60 * 60
        }
    }

    public func expirationDate(from timestamp: Date) -> Date? {
        durationSeconds.map { timestamp.addingTimeInterval(min($0, 24 * 60 * 60)) }
    }
}

public struct InputOutputLoggingPreferences: Sendable, Codable, Equatable {
    public var enabled: Bool
    public var recordInputs: Bool
    public var recordOutputs: Bool
    public var cliEnabled: Bool
    public var retention: InputOutputLoggingRetention
    public var externalStorageEnabled: Bool

    public init(
        enabled: Bool = false,
        recordInputs: Bool = false,
        recordOutputs: Bool = false,
        cliEnabled: Bool = false,
        retention: InputOutputLoggingRetention = .twentyFourHoursDefault,
        externalStorageEnabled: Bool = false
    ) {
        self.enabled = enabled
        self.recordInputs = recordInputs
        self.recordOutputs = recordOutputs
        self.cliEnabled = cliEnabled
        self.retention = retention
        self.externalStorageEnabled = externalStorageEnabled
    }

    public func isEffective(for source: String) -> Bool {
        guard enabled, recordInputs || recordOutputs else { return false }
        if source == "cli" || source == "mcp" {
            return cliEnabled
        }
        return true
    }
}

public struct InputOutputLoggingPreferencesStore: Sendable {
    public let url: URL

    public init(url: URL = Self.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        #if os(macOS)
        if let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return applicationSupport
                .appendingPathComponent("ProxyPilot", isDirectory: true)
                .appendingPathComponent("input-output-logging", isDirectory: true)
                .appendingPathComponent("settings.json")
        }
        #endif

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("proxypilot", isDirectory: true)
            .appendingPathComponent("input-output-logging", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    public func load() throws -> InputOutputLoggingPreferences {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return InputOutputLoggingPreferences()
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(InputOutputLoggingPreferences.self, from: data)
    }

    public func save(_ preferences: InputOutputLoggingPreferences) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preferences)
        try data.write(to: url, options: .atomic)
    }
}

public struct InputOutputLogContent: Sendable, Codable, Equatable {
    public enum Encoding: String, Sendable, Codable {
        case utf8
        case base64
    }

    public let encoding: Encoding
    public let text: String?
    public let base64: String?
    public let byteCount: Int

    public static func utf8(_ text: String) -> InputOutputLogContent {
        InputOutputLogContent(
            encoding: .utf8,
            text: text,
            base64: nil,
            byteCount: Data(text.utf8).count
        )
    }

    public static func fromBody(_ data: Data?) -> InputOutputLogContent? {
        guard let data else { return nil }
        if let text = String(data: data, encoding: .utf8) {
            return InputOutputLogContent(
                encoding: .utf8,
                text: text,
                base64: nil,
                byteCount: data.count
            )
        }

        return InputOutputLogContent(
            encoding: .base64,
            text: nil,
            base64: data.base64EncodedString(),
            byteCount: data.count
        )
    }
}

public struct InputOutputLogRecord: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let schemaVersion: Int
    public let timestamp: Date
    public let source: String
    public let sessionID: String?
    public let path: String
    public let model: String
    public let provider: String
    public let wasStreaming: Bool
    public let statusCode: Int?
    public let retentionExpiresAt: Date?
    public let deleteOnQuit: Bool
    public let input: InputOutputLogContent?
    public let output: InputOutputLogContent?
    /// Nil for records written before the streaming cap landed; `true` when
    /// the captured response exceeded `StreamedOutputCapture.defaultCapBytes`
    /// and was truncated. Surfaced in Session History so users do not silently
    /// see a partial Markdown/JSONL export.
    public let outputTruncated: Bool?

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = 2,
        timestamp: Date,
        source: String,
        sessionID: String? = nil,
        path: String,
        model: String,
        provider: String,
        wasStreaming: Bool,
        statusCode: Int?,
        retentionExpiresAt: Date?,
        deleteOnQuit: Bool = false,
        input: InputOutputLogContent?,
        output: InputOutputLogContent?,
        outputTruncated: Bool? = nil
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.timestamp = timestamp
        self.source = source
        self.sessionID = sessionID
        self.path = path
        self.model = model
        self.provider = provider
        self.wasStreaming = wasStreaming
        self.statusCode = statusCode
        self.retentionExpiresAt = retentionExpiresAt
        self.deleteOnQuit = deleteOnQuit
        self.input = input
        self.output = output
        self.outputTruncated = outputTruncated
    }
}

public enum InputOutputLogStoreError: Error, Sendable {
    case encryptionUnavailable
    case invalidEncryptionKey
    case encryptedPayloadMissing
    case corruptLine
}

public actor InputOutputLogStore {
    public let url: URL
    private let encryptionKey: Data

    public init(url: URL = InputOutputLogStore.defaultURL, encryptionKey: Data) {
        self.url = url
        self.encryptionKey = encryptionKey
    }

    public static var defaultURL: URL {
        #if os(macOS)
        if let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return applicationSupport
                .appendingPathComponent("ProxyPilot", isDirectory: true)
                .appendingPathComponent("input-output-logging", isDirectory: true)
                .appendingPathComponent("records.jsonl.enc")
        }
        #endif

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("proxypilot", isDirectory: true)
            .appendingPathComponent("input-output-logging", isDirectory: true)
            .appendingPathComponent("records.jsonl.enc")
    }

    public func append(_ record: InputOutputLogRecord) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        var line = try encrypt(data).data(using: .utf8) ?? Data()
        line.append(0x0A)

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    public func readRecords() throws -> [InputOutputLogRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                guard let encrypted = String(line).data(using: .utf8) else {
                    throw InputOutputLogStoreError.corruptLine
                }
                let decrypted = try decrypt(String(decoding: encrypted, as: UTF8.self))
                return try decoder.decode(InputOutputLogRecord.self, from: decrypted)
            }
    }

    public func pruneExpired(now: Date = Date(), includeUntilQuit: Bool = false) throws {
        let records = try readRecords().filter { record in
            if includeUntilQuit, record.deleteOnQuit { return false }
            guard let expiresAt = record.retentionExpiresAt else { return true }
            return expiresAt > now
        }
        try rewrite(records)
    }

    public func reset() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func rewrite(_ records: [InputOutputLogRecord]) throws {
        if records.isEmpty {
            try reset()
            return
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var output = Data()
        for record in records {
            let data = try encoder.encode(record)
            output.append(Data(try encrypt(data).utf8))
            output.append(0x0A)
        }
        try output.write(to: url, options: .atomic)
    }

    private func encrypt(_ data: Data) throws -> String {
        #if canImport(CryptoKit)
        guard encryptionKey.count == 32 else {
            throw InputOutputLogStoreError.invalidEncryptionKey
        }
        let key = SymmetricKey(data: encryptionKey)
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else {
            throw InputOutputLogStoreError.encryptedPayloadMissing
        }
        return combined.base64EncodedString()
        #else
        throw InputOutputLogStoreError.encryptionUnavailable
        #endif
    }

    private func decrypt(_ line: String) throws -> Data {
        #if canImport(CryptoKit)
        guard encryptionKey.count == 32 else {
            throw InputOutputLogStoreError.invalidEncryptionKey
        }
        guard let data = Data(base64Encoded: line) else {
            throw InputOutputLogStoreError.corruptLine
        }
        let key = SymmetricKey(data: encryptionKey)
        let sealed = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealed, using: key)
        #else
        throw InputOutputLogStoreError.encryptionUnavailable
        #endif
    }
}

public enum InputOutputLogKeyProvider {
    public static let keychainAccount = "INPUT_OUTPUT_LOGGING_KEY"

    public static func loadExisting() throws -> Data? {
        #if canImport(Security)
        let secrets = KeychainSecretsProvider()
        guard let existing = try secrets.get(key: keychainAccount) else {
            return nil
        }
        guard let data = Data(base64Encoded: existing), data.count == 32 else {
            throw InputOutputLogStoreError.invalidEncryptionKey
        }
        return data
        #else
        throw InputOutputLogStoreError.encryptionUnavailable
        #endif
    }

    public static func loadOrCreate() throws -> Data {
        #if canImport(Security)
        if let data = try loadExisting() {
            return data
        }

        let secrets = KeychainSecretsProvider()
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw SecretsError.fileError("SecRandomCopyBytes OSStatus \(status)")
        }
        let data = Data(bytes)
        try secrets.set(key: keychainAccount, value: data.base64EncodedString())
        return data
        #else
        throw InputOutputLogStoreError.encryptionUnavailable
        #endif
    }
}

public struct InputOutputLoggingRecorder: Sendable {
    public let source: String
    public let sessionID: String?
    private let preferencesStore: InputOutputLoggingPreferencesStore
    private let logStore: InputOutputLogStore

    public init(
        source: String,
        sessionID: String? = nil,
        preferencesStore: InputOutputLoggingPreferencesStore = InputOutputLoggingPreferencesStore(),
        logStore: InputOutputLogStore
    ) {
        self.source = source
        self.sessionID = sessionID
        self.preferencesStore = preferencesStore
        self.logStore = logStore
    }

    public static func production(source: String, sessionID: String? = nil) throws -> InputOutputLoggingRecorder {
        try InputOutputLoggingRecorder(
            source: source,
            sessionID: sessionID,
            logStore: InputOutputLogStore(encryptionKey: InputOutputLogKeyProvider.loadOrCreate())
        )
    }

    public static func productionIfKeyExists(source: String) throws -> InputOutputLoggingRecorder? {
        guard let key = try InputOutputLogKeyProvider.loadExisting() else {
            return nil
        }

        return InputOutputLoggingRecorder(
            source: source,
            logStore: InputOutputLogStore(encryptionKey: key)
        )
    }

    public static func productionIfConfigured(source: String, sessionID: String? = nil) throws -> InputOutputLoggingRecorder? {
        let preferencesStore = InputOutputLoggingPreferencesStore()
        let preferences = try preferencesStore.load()
        guard preferences.isEffective(for: source) else { return nil }

        return try InputOutputLoggingRecorder(
            source: source,
            sessionID: sessionID,
            preferencesStore: preferencesStore,
            logStore: InputOutputLogStore(encryptionKey: InputOutputLogKeyProvider.loadOrCreate())
        )
    }

    public func record(
        path: String,
        model: String?,
        provider: String,
        wasStreaming: Bool,
        statusCode: Int?,
        startedAt: Date,
        inputBody: Data?,
        outputBody: Data?,
        outputTruncated: Bool = false
    ) async throws {
        let preferences = try preferencesStore.load()
        guard preferences.isEffective(for: source) else { return }

        let recordedOutput: InputOutputLogContent? = preferences.recordOutputs ? .fromBody(outputBody) : nil
        let record = InputOutputLogRecord(
            timestamp: startedAt,
            source: source,
            sessionID: sessionID,
            path: path,
            model: {
                let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? "unknown" : trimmed
            }(),
            provider: provider,
            wasStreaming: wasStreaming,
            statusCode: statusCode,
            retentionExpiresAt: preferences.retention.expirationDate(from: startedAt),
            deleteOnQuit: preferences.retention == .untilQuit,
            input: preferences.recordInputs ? .fromBody(inputBody) : nil,
            output: recordedOutput,
            outputTruncated: (recordedOutput != nil && outputTruncated) ? true : nil
        )

        guard record.input != nil || record.output != nil else { return }
        try await logStore.pruneExpired()
        try await logStore.append(record)
    }

    public func readRecords() async throws -> [InputOutputLogRecord] {
        try await logStore.readRecords()
    }

    public func exportJSONL(now: Date = Date()) async throws -> String {
        try await logStore.pruneExpired(now: now)
        let records = try await logStore.readRecords()
        guard !records.isEmpty else { return "" }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        return try records
            .map { record in
                String(decoding: try encoder.encode(record), as: UTF8.self)
            }
            .joined(separator: "\n") + "\n"
    }

    public func recordCount(now: Date = Date()) async throws -> Int {
        try await logStore.pruneExpired(now: now)
        return try await logStore.readRecords().count
    }

    public func pruneExpired(now: Date = Date(), includeUntilQuit: Bool = false) async throws {
        try await logStore.pruneExpired(now: now, includeUntilQuit: includeUntilQuit)
    }

    public func resetRecords() async throws {
        try await logStore.reset()
    }
}
