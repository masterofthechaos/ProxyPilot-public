import Foundation
import Testing
@testable import ProxyPilotCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private let environmentLock = NSLock()

private func withEnvironmentLock<T>(_ body: () throws -> T) rethrows -> T {
    environmentLock.lock()
    defer { environmentLock.unlock() }
    return try body()
}

private func withEnvironmentValue<T>(_ name: String, value: String?, _ body: () throws -> T) rethrows -> T {
    let previous = ProcessInfo.processInfo.environment[name]
    if let value {
        setenv(name, value, 1)
    } else {
        unsetenv(name)
    }
    defer {
        if let previous {
            setenv(name, previous, 1)
        } else {
            unsetenv(name)
        }
    }
    return try body()
}

@Test func secretsProviderFactory_usesFileProviderWhenSecretsDirectoryOverrideIsSet() throws {
    withEnvironmentLock {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        withEnvironmentValue(SecretsProviderFactory.keychainServiceEnvVar, value: nil) {
            withEnvironmentValue(SecretsProviderFactory.secretsDirectoryEnvVar, value: tmpDir.path) {
                let provider = SecretsProviderFactory.make()
                #expect(provider is FileSecretsProvider)
                guard let fileProvider = provider as? FileSecretsProvider else { return }
                let expectedPath = tmpDir.appendingPathComponent("secrets.json").path
                #expect(fileProvider.secretsFileURL.path == expectedPath)
            }
        }
    }
}

@Test func fileSecretsProvider_existsReportsPresenceWithoutReadingValue() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let provider = FileSecretsProvider(directory: tmpDir)

    #expect(try provider.exists(key: SecretKey.openAIAPIKey) == false)
    try provider.set(key: SecretKey.openAIAPIKey, value: "test-key")
    #expect(try provider.exists(key: SecretKey.openAIAPIKey) == true)
}

#if canImport(Security)
@Test func keychainSecretsProvider_existsReturnsFalseForAbsentKey() throws {
    let service = "proxypilot.tests.\(UUID().uuidString)"
    let provider = KeychainSecretsProvider(service: service)
    let key = "MISSING_KEY_\(UUID().uuidString)"
    #expect(try provider.exists(key: key) == false)
}

@Test func fallbackSecretsProvider_readsFromFileWhenPrimaryMisses() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let primary = KeychainSecretsProvider(service: "proxypilot.tests.\(UUID().uuidString)")
    let fallback = FileSecretsProvider(directory: tmpDir)
    try fallback.set(key: SecretKey.zaiAPIKey, value: "from-file")

    let provider = FallbackSecretsProvider(primary: primary, fallback: fallback)
    let value = try provider.get(key: SecretKey.zaiAPIKey)

    #expect(value == "from-file")
    #expect(provider.lastResolvedBackendLabel == "file")
}

@Test func fallbackSecretsProvider_writesToFileWhenPrimaryFails() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    struct AlwaysFailProvider: SecretsProvider {
        func get(key: String) throws -> String? { throw SecretsError.fileError("primary failed") }
        func exists(key: String) throws -> Bool { throw SecretsError.fileError("primary failed") }
        func set(key: String, value: String) throws { throw SecretsError.fileError("primary failed") }
        func delete(key: String) throws { throw SecretsError.fileError("primary failed") }
        func list() throws -> [String] { throw SecretsError.fileError("primary failed") }
    }

    let fallback = FileSecretsProvider(directory: tmpDir)
    let provider = FallbackSecretsProvider(primary: AlwaysFailProvider(), fallback: fallback)
    try provider.set(key: SecretKey.openAIAPIKey, value: "saved")

    #expect(try fallback.get(key: SecretKey.openAIAPIKey) == "saved")
    #expect(provider.lastResolvedBackendLabel == "file")
}
#endif
