import Foundation
import Testing
@testable import ProxyPilotCore

struct StreamedOutputCaptureTests {
    @Test func captureDisabledIsNoOpRegardlessOfInputSize() {
        var capture = StreamedOutputCapture(captureEnabled: false, capBytes: 1024)
        let chunk = Data(repeating: 0x41, count: 10_000)
        capture.append(chunk)
        capture.append(chunk)
        #expect(capture.data.isEmpty)
        #expect(capture.isTruncated == false)
        #expect(capture.capturedOutput == nil)
    }

    @Test func captureEnabledAccumulatesBytesUnderCap() {
        var capture = StreamedOutputCapture(captureEnabled: true, capBytes: 1024)
        capture.append(Data([0x68, 0x65, 0x6C, 0x6C, 0x6F])) // "hello"
        capture.append(Data([0x20, 0x77, 0x6F, 0x72, 0x6C, 0x64])) // " world"
        #expect(capture.data == Data("hello world".utf8))
        #expect(capture.isTruncated == false)
        #expect(capture.capturedOutput == Data("hello world".utf8))
    }

    @Test func appendStopsAtCapAndFlipsTruncated() {
        var capture = StreamedOutputCapture(captureEnabled: true, capBytes: 10)
        capture.append(Data(repeating: 0x41, count: 8)) // 8 bytes, under cap
        #expect(capture.data.count == 8)
        #expect(capture.isTruncated == false)

        capture.append(Data(repeating: 0x42, count: 5)) // would push to 13
        // First 2 bytes of this chunk fit; remainder discarded.
        #expect(capture.data.count == 10)
        #expect(capture.isTruncated == true)
        let expectedTail = Data(repeating: 0x42, count: 2)
        #expect(capture.data.suffix(2) == expectedTail)
    }

    @Test func appendAfterTruncationDropsAllFurtherChunks() {
        var capture = StreamedOutputCapture(captureEnabled: true, capBytes: 4)
        capture.append(Data(repeating: 0x41, count: 10)) // exceeds; cap reached
        #expect(capture.isTruncated == true)
        #expect(capture.data.count == 4)

        // Subsequent appends must not even touch the buffer.
        capture.append(Data(repeating: 0x42, count: 100))
        #expect(capture.data.count == 4)
        #expect(capture.isTruncated == true)
    }

    @Test func emptyChunkIsAlwaysIgnored() {
        var capture = StreamedOutputCapture(captureEnabled: true, capBytes: 1024)
        capture.append(Data())
        #expect(capture.data.isEmpty)
        #expect(capture.isTruncated == false)
    }

    @Test func capturedOutputReflectsAccumulatedData() {
        var capture = StreamedOutputCapture(captureEnabled: true, capBytes: 1024)
        capture.append(Data("a".utf8))
        capture.append(Data("b".utf8))
        #expect(capture.capturedOutput == Data("ab".utf8))
    }

    @Test func zeroCapTruncatesImmediately() {
        var capture = StreamedOutputCapture(captureEnabled: true, capBytes: 0)
        capture.append(Data("anything".utf8))
        #expect(capture.data.isEmpty)
        #expect(capture.isTruncated == true)
    }

    @Test func negativeCapIsClampedToZero() {
        var capture = StreamedOutputCapture(captureEnabled: true, capBytes: -1)
        capture.append(Data("anything".utf8))
        #expect(capture.data.isEmpty)
        #expect(capture.isTruncated == true)
    }
}
