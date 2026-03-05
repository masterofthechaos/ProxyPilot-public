import Testing
import Foundation
@testable import ProxyPilotCore

@Test func fileSecretsProvider_setAndGet() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let provider = FileSecretsProvider(directory: tmpDir)
    try provider.set(key: "TEST_KEY", value: "test_value")
    let result = try provider.get(key: "TEST_KEY")
    #expect(result == "test_value")
    try? FileManager.default.removeItem(at: tmpDir)
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
