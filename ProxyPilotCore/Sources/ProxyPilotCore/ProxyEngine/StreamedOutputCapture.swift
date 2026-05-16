import Foundation

/// Captures streamed upstream response bytes for the optional input/output
/// logging path. Two invariants the streaming handlers rely on:
///
/// 1. When capture is disabled (`captureEnabled == false`), `append` is a
///    no-op and `capturedOutput` is `nil`. The default-off majority of users
///    pays no allocation cost on the response path.
/// 2. When capture is enabled, accumulation is bounded by `capBytes`. Past
///    the cap, further bytes are dropped and `isTruncated` flips to `true`
///    so the record can surface the partial-capture state to users.
public struct StreamedOutputCapture: Sendable {
    /// 10 MB — matches the inbound `HTTPRequestParser.maxBodyBytes` order of
    /// magnitude. Tunable per call site if a path has different needs.
    public static let defaultCapBytes = 10 * 1024 * 1024

    public private(set) var data = Data()
    public private(set) var isTruncated = false

    private let captureEnabled: Bool
    private let capBytes: Int

    public init(captureEnabled: Bool, capBytes: Int = StreamedOutputCapture.defaultCapBytes) {
        self.captureEnabled = captureEnabled
        self.capBytes = max(0, capBytes)
    }

    public mutating func append(_ chunk: Data) {
        guard captureEnabled, !isTruncated, !chunk.isEmpty else { return }
        let remaining = capBytes - data.count
        if chunk.count <= remaining {
            data.append(chunk)
        } else {
            if remaining > 0 {
                data.append(chunk.prefix(remaining))
            }
            isTruncated = true
        }
    }

    /// Returns the captured output suitable for handing to the recorder.
    /// `nil` when capture was disabled so callers can pass a single value
    /// through without conditionals.
    public var capturedOutput: Data? {
        captureEnabled ? data : nil
    }
}
