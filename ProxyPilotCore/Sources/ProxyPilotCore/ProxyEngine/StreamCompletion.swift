import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Metadata-only breadcrumbs for Xcode agent requests. Usage and captured bodies
/// remain in their separate stores.
public struct AgentStreamTrace: Sendable {
    public enum Engine: String, Codable, Sendable { case gui, cli }
    private struct Event: Encodable {
        let schemaVersion = 1
        let event: String
        let timestamp: String
        let engine: Engine
        let sessionID: String
        let correlationID: String
        let port: Int
    }

    private static let writer = Writer()
    private let engine: Engine
    private let sessionID: String
    private let requestID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let port: Int

    public init?(engine: Engine, attribution: RequestAttribution?, port: Int) {
        guard let attribution, attribution.client == "xcode-agent",
              UUID(uuidString: attribution.sessionID) != nil else { return nil }
        self.engine = engine
        sessionID = attribution.sessionID
        self.port = port
    }

    public func record(_ event: String) async {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        let row = Event(event: event, timestamp: formatter.string(from: Date()), engine: engine,
                        sessionID: sessionID, correlationID: requestID, port: port)
        await Self.writer.append(row)
    }

    public static func failureEvent(for error: Error) -> String {
        let failure = error as NSError
        return failure.domain == NSURLErrorDomain && failure.code == NSURLErrorTimedOut
            ? "stream_timeout" : "stream_transport_error"
    }

    private actor Writer {
        func append(_ event: Event) {
            let folder = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".proxypilot/diagnostics", isDirectory: true)
            let file = folder.appendingPathComponent("stream-\(event.engine.rawValue).jsonl")
            do {
                let manager = FileManager.default
                try manager.createDirectory(at: folder, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
                var data = try JSONEncoder().encode(event)
                data.append(0x0a)
                let descriptor = open(file.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
                guard descriptor >= 0 else { return }
                let handle = FileHandle(fileDescriptor: descriptor)
                defer { try? handle.close() }
                if try handle.seekToEnd() >= 1_000_000 {
                    try handle.truncate(atOffset: 0)
                }
                try handle.write(contentsOf: data)
            } catch {
                // Diagnostics are best-effort and must not fail the request.
            }
        }
    }
}

/// How a streamed response ended. Recorded in the usage journal
/// (`RequestRecord.streamOutcome`) and the input/output log so an incomplete
/// stream can no longer pass as an ordinary completed request.
///
/// Client cancellation has no case: as before, a cancelled request writes no
/// journal or log record (the v1.17.3 abandoned-request cleanup).
public enum StreamOutcome: String, Sendable, Codable, Equatable {
    /// Upstream sent a terminal `finish_reason` or `data: [DONE]`.
    case completed
    /// Upstream closed the stream cleanly without either terminal signal.
    case interrupted
    /// The upstream transport failed, or upstream sent its own error event,
    /// after the response to the client had started.
    case upstreamError = "upstream_error"
}

/// Tracks whether an OpenAI-compatible chat completion stream reached a
/// terminal signal.
///
/// Either signal completes the stream. Some valid upstreams send a terminal
/// `finish_reason` and then close without `[DONE]`, so requiring `[DONE]`
/// alone would misreport them as interrupted. Feed it raw upstream lines and
/// keep forwarding after `finish_reason`: usage chunks and `[DONE]` follow it.
public struct OpenAIChatStreamCompletion: Sendable, Equatable {
    public private(set) var sawDone = false
    public private(set) var sawFinishReason = false
    /// Upstream sent its own `{"error": ...}` data event, which was forwarded.
    public private(set) var sawUpstreamError = false
    /// What that error event said, classified. Set with `sawUpstreamError`.
    public private(set) var upstreamFailure: UpstreamFailureReport?

    public init() {}

    public var isComplete: Bool { sawDone || sawFinishReason }

    public mutating func observe(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            sawDone = true
            return
        }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if object["error"] != nil, !(object["error"] is NSNull) {
            sawUpstreamError = true
            if upstreamFailure == nil {
                upstreamFailure = UpstreamFailureClassifier.classify(streamLine: trimmed)
            }
        }
        if let choices = object["choices"] as? [[String: Any]],
           choices.contains(where: { ($0["finish_reason"] as? String)?.isEmpty == false }) {
            sawFinishReason = true
        }
    }

    /// The outcome of a stream whose upstream ended without throwing.
    public var outcomeAtEndOfStream: StreamOutcome {
        if isComplete { return .completed }
        return sawUpstreamError ? .upstreamError : .interrupted
    }

    /// Whether ProxyPilot must append its own error event at end of stream:
    /// only for a silent cut-off. An upstream error event was already
    /// forwarded, and a second one would be noise.
    public var needsInterruptionEvent: Bool {
        outcomeAtEndOfStream == .interrupted
    }
}

/// In-band error events for a response whose HTTP 200 and SSE headers were
/// already sent. A second HTTP status line on the same connection is not a
/// valid response, so after headers an error can only be reported inside the
/// stream, in the shape the route's clients parse.
public enum StreamErrorEvent {
    public static let interruptedCode = "stream_interrupted"
    public static let upstreamFailureCode = "upstream_stream_error"

    public static let interruptedMessage =
        "ProxyPilot: the upstream model stream ended before the response finished (no finish_reason or [DONE] was received). The response is incomplete."

    public static func upstreamFailureMessage(_ error: Error) -> String {
        upstreamFailureMessage(detail: error.localizedDescription)
    }

    public static func upstreamFailureMessage(detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = trimmed.isEmpty ? "" : " (\(String(trimmed.prefix(300))))"
        return "ProxyPilot: the upstream model stream failed before the response finished\(suffix). The response is incomplete."
    }

    /// An OpenAI-compatible SSE error chunk:
    /// `data: {"error":{"message":…,"type":"server_error","code":…}}`.
    ///
    /// `@ai-sdk/openai-compatible` (bundled in the pinned OpenCode runtime)
    /// parses a chunk with an `error` member as a stream error and ends the
    /// step with finish reason `error`. Keep the message free of
    /// rate-limit/overload wording: OpenCode retries automatically on those,
    /// which would silently replay a long local-model request.
    public static func openAIChat(message: String, code: String) -> Data {
        let payload: [String: Any] = [
            "error": [
                "message": message,
                "type": "server_error",
                "code": code,
            ] as [String: Any],
        ]
        return sseData(prefix: "", payload: payload)
    }

    /// An Anthropic Messages stream error:
    /// `event: error` / `data: {"type":"error","error":{"type":"api_error","message":…}}`.
    public static func anthropic(message: String) -> Data {
        let payload: [String: Any] = [
            "type": "error",
            "error": [
                "type": "api_error",
                "message": message,
            ] as [String: Any],
        ]
        return sseData(prefix: "event: error\n", payload: payload)
    }

    private static func sseData(prefix: String, payload: [String: Any]) -> Data {
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) }
            ?? #"{"error":{"message":"ProxyPilot stream error","type":"server_error"}}"#
        return Data((prefix + "data: " + json + "\n\n").utf8)
    }
}
