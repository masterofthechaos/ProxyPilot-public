import Testing
import Foundation
@testable import ProxyPilotCore
#if canImport(Security)
import Security
#endif

#if canImport(Security)
@Test func keychainSecretsProvider_setQueryUsesWhenUnlockedAccessibility() throws {
    let provider = KeychainSecretsProvider(service: "proxypilot-tests")
    let data = try #require("secret".data(using: .utf8))

    let query = provider.makeSetQuery(key: "TEST_KEY", valueData: data)

    #expect(query[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlocked as String)
}
#endif

@Test func fileSecretsProvider_setAndGet() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let provider = FileSecretsProvider(directory: tmpDir)
    try provider.set(key: "TEST_KEY", value: "test_value")
    let result = try provider.get(key: "TEST_KEY")
    #expect(result == "test_value")
    try? FileManager.default.removeItem(at: tmpDir)
}

@Test func fileSecretsProvider_writesSecretsFileWithOwnerOnlyPermissions() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let provider = FileSecretsProvider(directory: tmpDir)

    try provider.set(key: "TEST_KEY", value: "test_value")

    let attributes = try FileManager.default.attributesOfItem(atPath: provider.secretsFileURL.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue & 0o777 == 0o600)
}

@Test func fileSecretsProvider_delete() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let provider = FileSecretsProvider(directory: tmpDir)
    try provider.set(key: "TEST_KEY", value: "test_value")
    try provider.delete(key: "TEST_KEY")
    let result = try provider.get(key: "TEST_KEY")
    #expect(result == nil)
    try? FileManager.default.removeItem(at: tmpDir)
}

@Test func fileSecretsProvider_list() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let provider = FileSecretsProvider(directory: tmpDir)
    try provider.set(key: "KEY_A", value: "a")
    try provider.set(key: "KEY_B", value: "b")
    let keys = try provider.list()
    #expect(keys.sorted() == ["KEY_A", "KEY_B"])
    try? FileManager.default.removeItem(at: tmpDir)
}

@Test func fileSecretsProvider_getMissing() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let provider = FileSecretsProvider(directory: tmpDir)
    let result = try provider.get(key: "NONEXISTENT")
    #expect(result == nil)
}

@Test func fileSecretsProvider_mutationsPreserveCorruptStore() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let provider = FileSecretsProvider(directory: directory)
    let corrupt = Data("{interrupted secret store".utf8)
    try corrupt.write(to: provider.secretsFileURL)
    #expect(throws: (any Error).self) { try provider.set(key: "new", value: "new-value") }
    #expect(try Data(contentsOf: provider.secretsFileURL) == corrupt)
    #expect(throws: (any Error).self) { try provider.delete(key: "old") }
    #expect(try Data(contentsOf: provider.secretsFileURL) == corrupt)
}

private struct MutationSecretsStub: SecretsProvider {
    var value: String? = nil
    var readFails = false
    var writeFails = true
    var deleteFails = false
    func get(key: String) throws -> String? {
        if readFails { throw SecretsError.fileError("unavailable") }
        return value
    }
    func set(key: String, value: String) throws {
        if writeFails { throw SecretsError.fileError("unavailable") }
    }
    func delete(key: String) throws {
        if deleteFails { throw SecretsError.fileError("unavailable") }
    }
    func list() throws -> [String] { [] }
}

@Test func fallbackSecretsProvider_doesNotShadowAReadableOldPrimary() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fallback = FileSecretsProvider(directory: directory)
    try fallback.set(key: "key", value: "previous-fallback")
    let provider = FallbackSecretsProvider(primary: MutationSecretsStub(value: "old-primary"), fallback: fallback)
    #expect(throws: (any Error).self) { try provider.set(key: "key", value: "replacement") }
    #expect(try fallback.get(key: "key") == "previous-fallback")
    #expect(try provider.get(key: "key") == "old-primary")
}

@Test func fallbackSecretsProvider_samePrimaryValueStillCleansFallback() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fallback = FileSecretsProvider(directory: directory)
    try fallback.set(key: "key", value: "old-fallback")
    let provider = FallbackSecretsProvider(primary: MutationSecretsStub(value: "current"), fallback: fallback)
    try provider.set(key: "key", value: "current")
    #expect(try fallback.get(key: "key") == nil)
    #expect(try provider.get(key: "key") == "current")
}

@Test func fallbackSecretsProvider_verifiedAbsentPrimaryAllowsFallback() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fallback = FileSecretsProvider(directory: directory)
    let provider = FallbackSecretsProvider(primary: MutationSecretsStub(), fallback: fallback)
    try provider.set(key: "key", value: "replacement")
    #expect(try provider.get(key: "key") == "replacement")
}

@Test func fallbackSecretsProvider_partialDeleteThrowsEvenWhenFallbackAbsent() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let provider = FallbackSecretsProvider(primary: MutationSecretsStub(value: "retained", deleteFails: true), fallback: FileSecretsProvider(directory: directory))
    #expect(throws: (any Error).self) { try provider.delete(key: "key") }
    #expect(try provider.get(key: "key") == "retained")
}

@Test func fallbackSecretsProvider_cleanupFailureIsNotSuccessfulReplacement() throws {
    for primary in [MutationSecretsStub(value: "current"), MutationSecretsStub(value: "current", writeFails: false)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fallback = FileSecretsProvider(directory: directory)
        let bytes = Data("corrupt".utf8)
        try bytes.write(to: fallback.secretsFileURL)
        let provider = FallbackSecretsProvider(primary: primary, fallback: fallback)
        #expect(throws: (any Error).self) { try provider.set(key: "key", value: "current") }
        #expect(try Data(contentsOf: fallback.secretsFileURL) == bytes)
    }
}
