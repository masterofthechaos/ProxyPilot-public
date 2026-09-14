import Foundation

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
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
    case sevenDays
    case thirtyDays

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
        case .sevenDays:
            return 7 * 24 * 60 * 60
        case .thirtyDays:
            return 30 * 24 * 60 * 60
        }
    }

    public func expirationDate(from timestamp: Date) -> Date? {
        durationSeconds.map { timestamp.addingTimeInterval($0) }
    }
}

public struct InputOutputLoggingPreferences: Sendable, Codable, Equatable {
    public var enabled: Bool
    public var recordInputs: Bool
    public var recordOutputs: Bool
    public var cliEnabled: Bool
    public var retention: InputOutputLoggingRetention
    public var externalStorageEnabled: Bool
    public var externalStoragePath: String?

    public init(
        enabled: Bool = false,
        recordInputs: Bool = false,
        recordOutputs: Bool = false,
        cliEnabled: Bool = false,
        retention: InputOutputLoggingRetention = .twentyFourHoursDefault,
        externalStorageEnabled: Bool = false,
        externalStoragePath: String? = nil
    ) {
        self.enabled = enabled
        self.recordInputs = recordInputs
        self.recordOutputs = recordOutputs
        self.cliEnabled = cliEnabled
        self.retention = retention
        self.externalStorageEnabled = externalStorageEnabled
        self.externalStoragePath = externalStoragePath
    }

    /// Decodes older persisted preferences that predate `externalStoragePath`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        recordInputs = try container.decode(Bool.self, forKey: .recordInputs)
        recordOutputs = try container.decode(Bool.self, forKey: .recordOutputs)
        cliEnabled = try container.decode(Bool.self, forKey: .cliEnabled)
        retention = try container.decode(InputOutputLoggingRetention.self, forKey: .retention)
        externalStorageEnabled = try container.decode(Bool.self, forKey: .externalStorageEnabled)
        externalStoragePath = try container.decodeIfPresent(String.self, forKey: .externalStoragePath)
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
        defaultURL(environment: ProcessInfo.processInfo.environment)
    }

    static func defaultURL(environment: [String: String]) -> URL {
        if let xdgConfigHome = environment["XDG_CONFIG_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !xdgConfigHome.isEmpty {
            return URL(fileURLWithPath: (xdgConfigHome as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("proxypilot", isDirectory: true)
                .appendingPathComponent("input-output-logging", isDirectory: true)
                .appendingPathComponent("settings.json")
        }

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
    private static let privateFilePermissions: Int = 0o600

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

    /// Resolves where records should be stored given the user's preferences,
    /// consulting a configured external location before falling back to
    /// Application Support. Re-checked on every call rather than cached, so an
    /// override that becomes unreachable (unmounted volume, revoked permission)
    /// falls back automatically without requiring a settings change.
    public static func resolvedURL(preferences: InputOutputLoggingPreferences) -> URL {
        guard let directory = reachableExternalStorageDirectory(preferences: preferences) else {
            return defaultURL
        }
        return directory.appendingPathComponent("records.jsonl.enc")
    }

    /// `true` when no override is configured, or when the configured override
    /// directory currently exists and is writable. `false` means the caller is
    /// about to fall back to Application Support and should surface a warning.
    public static func isExternalStorageOverrideReachable(preferences: InputOutputLoggingPreferences) -> Bool {
        guard preferences.externalStorageEnabled,
              let path = preferences.externalStoragePath,
              !path.isEmpty else {
            return true
        }
        return reachableExternalStorageDirectory(preferences: preferences) != nil
    }

    private static func reachableExternalStorageDirectory(preferences: InputOutputLoggingPreferences) -> URL? {
        guard preferences.externalStorageEnabled,
              let path = preferences.externalStoragePath,
              !path.isEmpty else {
            return nil
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: directory.path) else {
            return nil
        }
        return directory
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
            FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: Self.privateFilePermissions]
            )
        } else {
            try applyPrivateFilePermissions()
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

    public func readRecords(matchingSessionID sessionID: String) throws -> [InputOutputLogRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var matchingRecords: [InputOutputLogRecord] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let encrypted = String(line).data(using: .utf8) else {
                throw InputOutputLogStoreError.corruptLine
            }
            let decrypted = try decrypt(String(decoding: encrypted, as: UTF8.self))
            let record = try decoder.decode(InputOutputLogRecord.self, from: decrypted)
            // Stored IDs are mixed-case (daemon sessions keep `UUID().uuidString`
            // uppercase; attributed sessions are lowercased), so match
            // case-insensitively rather than normalizing either side.
            if record.sessionID?.caseInsensitiveCompare(sessionID) == .orderedSame {
                matchingRecords.append(record)
            }
        }
        return matchingRecords
    }

    public func pruneExpired(now: Date = Date(), includeUntilQuit: Bool = false) throws {
        let records = try readDecodableRecords().filter { record in
            if includeUntilQuit, record.deleteOnQuit { return false }
            guard let expiresAt = record.retentionExpiresAt else { return true }
            return expiresAt > now
        }
        try rewrite(records)
    }

    /// Lenient reader used by pruning: a line that cannot be decrypted or decoded
    /// (partial write, key rotation) is dropped instead of failing the whole pass.
    /// A single corrupt line must never permanently block new records from saving.
    private func readDecodableRecords() throws -> [InputOutputLogRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let decrypted = try? decrypt(String(line)) else { return nil }
                return try? decoder.decode(InputOutputLogRecord.self, from: decrypted)
            }
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
        try applyPrivateFilePermissions()
    }

    private func applyPrivateFilePermissions() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: Self.privateFilePermissions],
            ofItemAtPath: url.path
        )
    }

    private func encrypt(_ data: Data) throws -> String {
        #if canImport(CryptoKit) || canImport(Crypto)
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
        #if canImport(CryptoKit) || canImport(Crypto)
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

/// Memoizes the session's `InputOutputLoggingRecorder` so every request shares
/// one underlying store actor (serialized appends) while still resolving
/// lazily: if logging is disabled when the proxy starts, each request re-checks
/// the shared preferences until logging becomes effective, then caches the
/// recorder for the rest of the session.
///
/// Used by every proxy entry point — GUI (`LocalProxyServer`), CLI (`start`,
/// `serve`), and MCP — so enabling capture under a running proxy takes effect
/// without a restart. Resolving once at start instead is the defect recorded in
/// `docs/session-punch-cards/punch-outs/2026-07-08T21-53-57-0400-cli-io-log-session-mismatch.md`.
public final class InputOutputLoggerSessionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: InputOutputLoggingRecorder?

    public init() {}

    public func recorder(
        source: String,
        sessionID: String,
        preferencesStore: InputOutputLoggingPreferencesStore = InputOutputLoggingPreferencesStore()
    ) -> InputOutputLoggingRecorder? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        cached = try? InputOutputLoggingRecorder.productionIfConfigured(
            source: source,
            sessionID: sessionID,
            preferencesStore: preferencesStore
        )
        return cached
    }

    /// Provider closure suitable for `ProxyConfiguration.inputOutputLoggerProvider`.
    public func provider(
        source: String,
        sessionID: String,
        preferencesStore: InputOutputLoggingPreferencesStore = InputOutputLoggingPreferencesStore()
    ) -> @Sendable () -> InputOutputLoggingRecorder? {
        { [self] in
            recorder(source: source, sessionID: sessionID, preferencesStore: preferencesStore)
        }
    }
}

public enum InputOutputLogKeyProvider {
    public static let keychainAccount = "INPUT_OUTPUT_LOGGING_KEY"

    static func keychainServiceName(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let serviceOverride = environment[SecretsProviderFactory.keychainServiceEnvVar]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let serviceOverride, !serviceOverride.isEmpty {
            return serviceOverride
        }
        return "proxypilot"
    }

    public static func loadExisting() throws -> Data? {
        #if canImport(Security)
        let secrets = KeychainSecretsProvider(service: keychainServiceName())
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

        let secrets = KeychainSecretsProvider(service: keychainServiceName())
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
        try productionIfKeyExists(source: source, preferencesStore: InputOutputLoggingPreferencesStore())
    }

    public static func productionIfKeyExists(
        source: String,
        preferencesStore: InputOutputLoggingPreferencesStore
    ) throws -> InputOutputLoggingRecorder? {
        guard let key = try InputOutputLogKeyProvider.loadExisting() else {
            return nil
        }

        return retentionCleanupRecorder(
            source: source,
            preferencesStore: preferencesStore,
            encryptionKey: key
        )
    }

    /// Opens the historical store without consulting current capture enablement.
    /// Retention is a lifecycle obligation for already-written records, not a
    /// side effect that disappears when the user later turns capture off.
    static func retentionCleanupRecorder(
        source: String,
        preferencesStore: InputOutputLoggingPreferencesStore,
        encryptionKey: Data
    ) -> InputOutputLoggingRecorder {
        let preferences = (try? preferencesStore.load()) ?? InputOutputLoggingPreferences()
        return InputOutputLoggingRecorder(
            source: source,
            preferencesStore: preferencesStore,
            logStore: InputOutputLogStore(
                url: InputOutputLogStore.resolvedURL(preferences: preferences),
                encryptionKey: encryptionKey
            )
        )
    }

    public static func productionIfConfigured(source: String, sessionID: String? = nil) throws -> InputOutputLoggingRecorder? {
        try productionIfConfigured(
            source: source,
            sessionID: sessionID,
            preferencesStore: InputOutputLoggingPreferencesStore()
        )
    }

    public static func productionIfConfigured(
        source: String,
        sessionID: String? = nil,
        preferencesStore: InputOutputLoggingPreferencesStore
    ) throws -> InputOutputLoggingRecorder? {
        let preferences = try preferencesStore.load()
        guard preferences.isEffective(for: source) else { return nil }

        return try InputOutputLoggingRecorder(
            source: source,
            sessionID: sessionID,
            preferencesStore: preferencesStore,
            logStore: InputOutputLogStore(
                url: InputOutputLogStore.resolvedURL(preferences: preferences),
                encryptionKey: InputOutputLogKeyProvider.loadOrCreate()
            )
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

        // Attributed requests (X-ProxyPilot-Client/-Session-ID) file under the
        // caller's session, exactly as SessionStats.record does for session
        // reports. Without this, every record lands in the proxy's own startup
        // session and `sessions show <agent-session> --include-logs` finds
        // nothing.
        let attribution = RequestAttributionContext.current
        let recordedOutput: InputOutputLogContent? = preferences.recordOutputs ? .fromBody(outputBody) : nil
        let record = InputOutputLogRecord(
            timestamp: startedAt,
            source: attribution?.client ?? source,
            sessionID: attribution?.sessionID ?? sessionID,
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
        // Pruning rewrites the whole encrypted store, which grows large under the
        // 7/30-day retention windows — throttle it off the per-request hot path,
        // and never let a prune failure block the append.
        if Self.pruneThrottle.shouldPrune(storePath: logStore.url.path) {
            try? await logStore.pruneExpired()
        }
        try await logStore.append(record)
    }

    private static let pruneThrottle = PruneThrottle()

    final class PruneThrottle: @unchecked Sendable {
        private let lock = NSLock()
        private var lastPruneByPath: [String: Date] = [:]
        private let minimumInterval: TimeInterval

        init(minimumInterval: TimeInterval = 5 * 60) {
            self.minimumInterval = minimumInterval
        }

        func shouldPrune(storePath: String, now: Date = Date()) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if let last = lastPruneByPath[storePath], now.timeIntervalSince(last) < minimumInterval {
                return false
            }
            lastPruneByPath[storePath] = now
            return true
        }
    }

    public func readRecords() async throws -> [InputOutputLogRecord] {
        try await logStore.readRecords()
    }

    public func readRecords(matchingSessionID sessionID: String) async throws -> [InputOutputLogRecord] {
        try await logStore.readRecords(matchingSessionID: sessionID)
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
