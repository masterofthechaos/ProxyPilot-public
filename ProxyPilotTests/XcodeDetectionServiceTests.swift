import XCTest
@testable import ProxyPilot

final class XcodeDetectionServiceTests: XCTestCase {

    func testVersionCompareEqual() {
        XCTAssertTrue(XcodeDetectionService.versionCompare("26.3", isAtLeast: "26.3"))
    }

    func testVersionCompareGreater() {
        XCTAssertTrue(XcodeDetectionService.versionCompare("26.4", isAtLeast: "26.3"))
    }

    func testVersionCompareLess() {
        XCTAssertFalse(XcodeDetectionService.versionCompare("26.2", isAtLeast: "26.3"))
    }

    func testVersionCompareMajorGreater() {
        XCTAssertTrue(XcodeDetectionService.versionCompare("27.0", isAtLeast: "26.3"))
    }

    func testVersionCompareMajorLess() {
        XCTAssertFalse(XcodeDetectionService.versionCompare("25.0", isAtLeast: "26.3"))
    }

    func testVersionCompareSingleComponent() {
        XCTAssertTrue(XcodeDetectionService.versionCompare("27", isAtLeast: "26.3"))
        XCTAssertFalse(XcodeDetectionService.versionCompare("26", isAtLeast: "26.3"))
    }

    func testVersionCompareThreeComponents() {
        XCTAssertTrue(XcodeDetectionService.versionCompare("26.3.1", isAtLeast: "26.3"))
        XCTAssertTrue(XcodeDetectionService.versionCompare("26.4.0", isAtLeast: "26.3.1"))
        XCTAssertFalse(XcodeDetectionService.versionCompare("26.2.9", isAtLeast: "26.3"))
    }

    func testMinimumVersionIsCorrect() {
        XCTAssertEqual(XcodeDetectionService.minimumAgenticVersion, "26.3")
    }

    func testConfigPathUsesClaudeAgentConfig() {
        XCTAssertEqual(XcodeDetectionService.configRelativePath, "Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig")
    }
}
