import XCTest
@testable import ProxyPilotCore

final class LogReaderTests: XCTestCase {
    func testTailReturnsLastNLines() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("logreader_test_\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let lines = (1...10).map { "line \($0)" }.joined(separator: "\n")
        try lines.write(to: tmp, atomically: true, encoding: .utf8)

        let result = LogReader.tail(url: tmp, lines: 3)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result, ["line 8", "line 9", "line 10"])
    }

    func testTailReturnsAllLinesWhenFewerThanRequested() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("logreader_test_\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "one\ntwo".write(to: tmp, atomically: true, encoding: .utf8)

        let result = LogReader.tail(url: tmp, lines: 10)
        XCTAssertEqual(result, ["one", "two"])
    }

    func testTailRedactsSecrets() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("logreader_test_\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let content = """
        normal line
        Authorization: Bearer sk-1234567890abcdef
        api_key=secret123
        another normal line
        """
        try content.write(to: tmp, atomically: true, encoding: .utf8)

        let result = LogReader.tail(url: tmp, lines: 10, redact: true)
        XCTAssertTrue(result.contains("normal line"))
        XCTAssertFalse(result.joined().contains("sk-1234567890"))
        XCTAssertFalse(result.joined().contains("secret123"))
    }

    func testTailMissingFileReturnsEmpty() {
        let missing = URL(fileURLWithPath: "/tmp/does_not_exist_\(UUID().uuidString).log")
        let result = LogReader.tail(url: missing, lines: 10)
        XCTAssertTrue(result.isEmpty)
    }
}
