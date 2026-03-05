import Foundation

/// macOS-friendly secrets provider that prefers Keychain but silently falls back
/// to the default file-backed store when Keychain is unavailable.
public final class FallbackSecretsProvider: SecretsProvider, @unchecked Sendable {
    private let primary: any SecretsProvider
    private let fallback: FileSecretsProvider
    private let primaryLabel: String
    private let lock = NSLock()
    private var recordedBackendLabel: String?

    public init(
        primary: any SecretsProvider,
        primaryLabel: String = "keychain",
        fallback: FileSecretsProvider = FileSecretsProvider()
    ) {
        self.primary = primary
        self.primaryLabel = primaryLabel
        self.fallback = fallback
    }

    public var lastResolvedBackendLabel: String? {
        lock.lock()
        defer { lock.unlock() }
        return recordedBackendLabel
    }

    public var fallbackFileURL: URL { fallback.secretsFileURL }

    public func get(key: String) throws -> String? {
        if let value = try? primary.get(key: key) {
            recordBackend(primaryLabel)
            return value
        }

        let fallbackValue = try fallback.get(key: key)
        recordBackend(fallbackValue == nil ? nil : "file")
        return fallbackValue
    }

    public func exists(key: String) throws -> Bool {
        if let primaryExists = try? primary.exists(key: key), primaryExists {
            recordBackend(primaryLabel)
            return true
        }

        let fallbackExists = try fallback.exists(key: key)
        recordBackend(fallbackExists ? "file" : nil)
        return fallbackExists
    }

    public func set(key: String, value: String) throws {
        if (try? primary.set(key: key, value: value)) != nil {
            try? fallback.delete(key: key)
            recordBackend(primaryLabel)
            return
        }

        try fallback.set(key: key, value: value)
        recordBackend("file")
    }

    public func delete(key: String) throws {
        var removed = false

        if (try? primary.delete(key: key)) != nil {
            removed = true
            recordBackend(primaryLabel)
        }

        if (try? fallback.delete(key: key)) != nil {
            removed = true
            recordBackend("file")
        }

        if !removed {
            recordBackend(nil)
            throw SecretsError.fileError("No accessible secrets backend was available for delete.")
        }
    }

    public func list() throws -> [String] {
        var keys = Set<String>()
        if let primaryKeys = try? primary.list() {
            keys.formUnion(primaryKeys)
        }
        if let fallbackKeys = try? fallback.list() {
            keys.formUnion(fallbackKeys)
        }
        recordBackend(keys.isEmpty ? nil : "mixed")
        return keys.sorted()
    }

    private func recordBackend(_ label: String?) {
        lock.lock()
        defer { lock.unlock() }
        recordedBackendLabel = label
    }
}
