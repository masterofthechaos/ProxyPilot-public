import Foundation
import Testing
import ProxyPilotCore
@testable import proxypilot

struct RouteProbeTests {
    let singapore = "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"

    @Test func rejectsPayAsYouGoAndSpoofedEndpointsBeforeInference() throws {
        #expect(throws: (any Error).self) { try RouteProbeSupport.requireEndpoint(UpstreamProvider.qwen.defaultAPIBaseURL, matches: singapore) }
        #expect(throws: (any Error).self) { try RouteProbeSupport.requireEndpoint(singapore + ".evil.test", matches: singapore) }
        #expect(throws: (any Error).self) { try RouteProbeSupport.requireEndpoint(singapore + "?key=secret", matches: singapore) }
        try RouteProbeSupport.requireEndpoint(singapore + "/", matches: singapore)
        #expect(RouteProbeSupport.canonicalEndpoint("https://EXAMPLE.test:443/v1/") == "https://example.test/v1")
    }

    @Test func appliedIdentityMustMatchAllRouteFields() throws {
        let identity: [String: Any] = ["provider": "qwen", "model": "qwen4-max-preview", "endpoint": singapore, "session_id": "runtime-1"]
        #expect(try RouteProbeSupport.validateIdentity(identity, provider: "qwen", model: "qwen4-max-preview", endpoint: singapore) == "runtime-1")
        #expect(throws: (any Error).self) { try RouteProbeSupport.validateIdentity(identity, provider: "openai", model: "qwen4-max-preview", endpoint: singapore) }
        #expect(throws: (any Error).self) { try RouteProbeSupport.validateIdentity(identity, provider: "qwen", model: "other", endpoint: singapore) }
        #expect(throws: (any Error).self) { try RouteProbeSupport.validateIdentity(identity, provider: "qwen", model: "qwen4-max-preview", endpoint: UpstreamProvider.qwen.defaultAPIBaseURL) }
        var legacy = identity; legacy.removeValue(forKey: "session_id")
        #expect(throws: (any Error).self) { try RouteProbeSupport.validateIdentity(legacy, provider: "qwen", model: "qwen4-max-preview", endpoint: singapore) }
    }

    @Test func streamedToolFragmentsAndReasoningSurviveContinuation() throws {
        let chunks: [[String: Any]] = [
            ["choices": [["delta": ["reasoning_content": "check", "tool_calls": [["index": 0, "id": "call-1", "type": "function", "function": ["name": "proxypilot_route_probe", "arguments": "{\"val"]]]]]]],
            ["choices": [["delta": ["tool_calls": [["index": 0, "function": ["arguments": "ue\":\"ok\"}"]]]], "finish_reason": "tool_calls"]]]
        ]
        let text = try chunks.map { "data: " + String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n\n") + "\n\ndata: [DONE]\n\n"
        let reply = try RouteProbeReply(data: Data(text.utf8))
        #expect(reply.finishReason == "tool_calls")
        #expect(reply.message["reasoning_content"] as? String == "check")
        #expect(reply.tools.first?["id"] as? String == "call-1")
        #expect((reply.tools.first?["function"] as? [String: Any])?["arguments"] as? String == "{\"value\":\"ok\"}")
        #expect(throws: (any Error).self) { try RouteProbeReply(data: Data(text.replacingOccurrences(of: "data: [DONE]", with: "").utf8)) }
        #expect(throws: (any Error).self) { try RouteProbeReply(data: Data("data: {\"error\":{\"message\":\"failed\"}}\n\ndata: [DONE]\n".utf8)) }
    }

    @Test func probeAndStartupShareTheEndpointResolver() {
        #expect(CLIProxyRuntime.upstreamBaseURL(provider: .qwen, override: nil) == UpstreamProvider.qwen.preferredAPIBaseURL)
        #expect(CLIProxyRuntime.upstreamBaseURL(provider: .qwen, override: singapore) == singapore)
    }
}
