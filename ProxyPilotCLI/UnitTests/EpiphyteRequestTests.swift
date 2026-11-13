import ArgumentParser
import Foundation
import Testing
@testable import proxypilot
import ProxyPilotCore

@Suite struct EpiphyteRequestTests {
    @Test func epiphyteRequestUsesIndependentExplicitClientAndEditableTimeout() throws {
        let id = UUID().uuidString
        let request = try RequestCommand.parse(["--provider", "openrouter", "--model", "test", "--session-id", id,
                                               "--client", "epiphyte", "--role", "lead", "--timeout-seconds", "90", "--json"])
        #expect(request.client == "epiphyte")
        #expect(request.timeoutSeconds == 90)
        #expect(RequestAttribution.validated(client: request.client, sessionID: request.sessionId, role: request.role)?.sessionID == id.lowercased())
    }
    @Test func completeAssistantMessageAndToolStateSurviveProjection() throws {
        let message: [String: Any] = ["role": "assistant", "content": NSNull(),
            "tool_calls": [["id": "call1", "type": "function", "function": ["name": "inspect_page", "arguments": "{}"], "thought_signature": "opaque"]]]
        let reply = try IndependentRequestAssistantReply(result: ["choices": [["message": message, "finish_reason": "tool_calls"]]])
        #expect(reply.output == nil)
        #expect(reply.messageJSON.contains("opaque"))
        #expect(reply.finishReason == "tool_calls")
        #expect(throws: (any Error).self) {
            try IndependentRequestAssistantReply(result: ["choices": [["message": message, "finish_reason": "stop"]]])
        }
        #expect(throws: (any Error).self) {
            try IndependentRequestAssistantReply(result: ["choices": [["message": ["role": "assistant", "content": "text"], "finish_reason": "tool_calls"]]])
        }
    }
    @Test func repogpsDefaultsAreBackwardCompatible() throws {
        let request = try RequestCommand.parse(["--provider", "openrouter", "--model", "test", "--session-id", UUID().uuidString])
        #expect(request.client == "repogps")
        #expect(request.role == "navigator")
        #expect(request.timeoutSeconds == 45)
        #expect(request.maxOutputTokens == 2048)
    }
}
