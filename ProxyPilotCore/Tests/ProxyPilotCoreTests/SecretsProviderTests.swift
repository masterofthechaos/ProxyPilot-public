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
