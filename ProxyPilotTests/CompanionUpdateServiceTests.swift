import XCTest
@testable import ProxyPilot

final class CompanionUpdateServiceTests: XCTestCase {
    private func fixture(_ directory: URL, _ name: String, version: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\necho '\(version)'\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testUpdatesExistingCopyWithoutInstallingAbsentToolOrDowngradingNewerCopy() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture(dir, "source", version: "1.16.1")
        let old = try fixture(dir, "old", version: "1.4.0")
        let newer = try fixture(dir, "newer", version: "9.0.0")
        let absent = dir.appendingPathComponent("absent")
        let result = CompanionUpdateService.reconcile(source: source, destinations: [old, newer, absent], sourceVersion: "1.16.1")
        XCTAssertEqual(result.updated, [old.path])
        XCTAssertTrue(result.needsAttention.isEmpty)
        XCTAssertEqual(try Data(contentsOf: old), try Data(contentsOf: source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
        XCTAssertTrue(try String(contentsOf: newer, encoding: .utf8).contains("9.0.0"))
        XCTAssertTrue(CompanionUpdateService.reconcile(source: source, destinations: [old], sourceVersion: "1.16.1").updated.isEmpty)
    }

    func testProtectedInstallationRequestsAuthorizationWithoutReplacingBytes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let source = try fixture(dir, "source", version: "1.16.1")
        let old = try fixture(dir, "old", version: "1.4.0")
        let original = try Data(contentsOf: old)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        let result = CompanionUpdateService.reconcile(source: source, destinations: [old], sourceVersion: "1.16.1")
        XCTAssertEqual(result.protectedDestinations, [old])
        XCTAssertEqual(try Data(contentsOf: old), original)
    }

    func testCLISourceVersionMatchesGUIVersion() throws {
        // Debug test hosts intentionally omit Release-only bundled helpers.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("ProxyPilotCLI/Sources/ProxyPilotCommand.swift"), encoding: .utf8)
        let version = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        XCTAssertTrue(source.contains("version: \"" + version + "\""))
    }

    func testPackageManagedSymlinkIsNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture(dir, "source", version: "1.16.1")
        let target = try fixture(dir, "managed", version: "1.4.0")
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let result = CompanionUpdateService.reconcile(source: source, destinations: [link], sourceVersion: "1.16.1")
        XCTAssertTrue(result.updated.isEmpty)
        XCTAssertEqual(result.needsAttention.count, 1)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertTrue(try String(contentsOf: target, encoding: .utf8).contains("1.4.0"))
    }
}
