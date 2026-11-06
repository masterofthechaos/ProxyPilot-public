import Foundation

/// Prefers Keychain and reads the file-backed store when Keychain is unavailable.
/// Writes fall back only when primary absence is verified; partial mutations throw.
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
        let primaryWritten = (try? primary.set(key: key, value: value)) != nil
        if primaryWritten {
            recordBackend(primaryLabel)
            do { try fallback.delete(key: key) }
            catch {
                throw SecretsError.fileError("Credential saved to primary storage, but the old fallback could not be removed. Repair fallback storage and retry.")
            }
            return
        }

        // A failed primary update can leave an older readable credential that
        // would shadow a newly saved fallback. Never report that as success.
        let existing: String?
        do { existing = try primary.get(key: key) }
        catch {
            throw SecretsError.fileError("Primary credential storage is unavailable; replacement could not be verified. Unlock or repair primary storage and retry.")
        }
        if let existing {
            guard existing == value else {
                throw SecretsError.fileError("Primary storage retained the previous credential. Unlock or repair primary storage and retry; fallback was not changed.")
            }
            recordBackend(primaryLabel)
            do { try fallback.delete(key: key) }
            catch {
                throw SecretsError.fileError("Primary storage already has this credential, but fallback cleanup failed. Repair fallback storage and retry.")
            }
            return
        }
        try fallback.set(key: key, value: value)
        recordBackend("file")
    }

    public func delete(key: String) throws {
        // Attempt both removals even after a failure, but do not mistake an
        // absent/successful fallback for removal of a retained primary key.
        var failed = false
        do { try primary.delete(key: key) } catch { failed = true }
        do { try fallback.delete(key: key) } catch { failed = true }
        recordBackend(nil)
        if failed {
            throw SecretsError.fileError("Credential removal was incomplete. Unlock or repair both credential stores and retry; a stored credential may remain.")
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
