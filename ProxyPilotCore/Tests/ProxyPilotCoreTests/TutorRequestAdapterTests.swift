import Foundation
import XCTest
@testable import ProxyPilotCore

final class TutorRequestAdapterTests: XCTestCase {
    private let attribution = RequestAttribution(
        client: "repogps",
        sessionID: "00000000-0000-0000-0000-000000000123"
    )

    func testProjectsAdvisorThenSubagentWithoutDisturbingClientTools() throws {
        let original: [String: Any] = [
            "model": "proxypilot-active",
            "messages": [["role": "user", "content": "test"]],
            "tools": [[
                "type": "function",
                "function": ["name": "read_file", "parameters": ["type": "object"]],
            ]],
        ]
        let result = TutorRequestAdapter.mutateChatCompletionsBody(
            try JSONSerialization.data(withJSONObject: original),
            envelopeHeader: envelope(workerWebAccess: true),
            attribution: attribution,
            provider: .openRouter
        )
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        let tools = try XCTUnwrap(request["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 3)
        XCTAssertEqual(tools[0]["type"] as? String, "function")
        XCTAssertEqual(tools[1]["type"] as? String, "openrouter:advisor")
        XCTAssertEqual(tools[2]["type"] as? String, "openrouter:subagent")

        let advisor = try XCTUnwrap(tools[1]["parameters"] as? [String: Any])
        XCTAssertEqual(advisor["name"] as? String, "Tutor")
        XCTAssertEqual(advisor["model"] as? String, "~advisor/example")
        XCTAssertEqual(advisor["forward_transcript"] as? Bool, false)
        XCTAssertEqual(advisor["max_completion_tokens"] as? Int, 4096)
        // Advisor has no documented inner tool loop. The user's consultation
        // count belongs to the outer server-tool loop, not an ignored field.
        XCTAssertNil(advisor["max_tool_calls"])

        let worker = try XCTUnwrap(tools[2]["parameters"] as? [String: Any])
        XCTAssertEqual(worker["model"] as? String, "~worker/example")
        XCTAssertEqual(worker["max_completion_tokens"] as? Int, 2048)
        XCTAssertEqual(worker["max_tool_calls"] as? Int, 5)
        let nested = try XCTUnwrap(worker["tools"] as? [[String: Any]])
        XCTAssertEqual(nested.count, 1)
        XCTAssertEqual(nested[0]["type"] as? String, "openrouter:web_search")
        XCTAssertNil(request["tool_choice"])
    }

    func testRequiredPolicyForcesConsultation() throws {
        // First round of the turn: messages end in a user message with no
        // tool activity yet, so forcing applies.
        let result = TutorRequestAdapter.mutateChatCompletionsBody(
            requestBody(),
            envelopeHeader: envelope(policy: "required"),
            attribution: attribution,
            provider: .openRouter
        )
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual((request["tool_choice"] as? [String: String])?["type"], "openrouter:advisor")
    }

    func testRequiredPolicyDoesNotForceOnContinuationRound() throws {
        // Continuation round: the last user message is followed by an
        // assistant tool call and its role-"tool" result. Consultation
        // already happened this turn, so forcing must not be reapplied, and
        // a client-sent tool_choice value must survive untouched.
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "proxypilot-active",
            "messages": [
                ["role": "user", "content": "test"],
                [
                    "role": "assistant",
                    "content": NSNull(),
                    "tool_calls": [
                        ["id": "call_1", "type": "function", "function": ["name": "read_file", "arguments": "{}"]],
                    ],
                ],
                ["role": "tool", "tool_call_id": "call_1", "content": "file contents"],
            ],
            "tool_choice": "auto",
        ])
        let result = TutorRequestAdapter.mutateChatCompletionsBody(
            body,
            envelopeHeader: envelope(policy: "required"),
            attribution: attribution,
            provider: .openRouter
        )
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual(request["tool_choice"] as? String, "auto")
    }

    func testRequiredPolicyForcesAgainOnNewUserTurnAfterPriorToolActivity() throws {
        // A new user turn opens after an earlier turn that already contained
        // tool activity. The earlier assistant tool_calls message sits
        // BEFORE the last user message, so it must not suppress forcing for
        // this new turn.
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "proxypilot-active",
            "messages": [
                ["role": "user", "content": "first turn"],
                [
                    "role": "assistant",
                    "content": NSNull(),
                    "tool_calls": [
                        ["id": "call_1", "type": "function", "function": ["name": "read_file", "arguments": "{}"]],
                    ],
                ],
                ["role": "tool", "tool_call_id": "call_1", "content": "file contents"],
                ["role": "assistant", "content": "here is the answer"],
                ["role": "user", "content": "second turn"],
            ],
        ])
        let result = TutorRequestAdapter.mutateChatCompletionsBody(
            body,
            envelopeHeader: envelope(policy: "required"),
            attribution: attribution,
            provider: .openRouter
        )
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual((request["tool_choice"] as? [String: String])?["type"], "openrouter:advisor")
    }

    func testNonRepoGPSAndNonOpenRouterRequestsRemainByteIdentical() {
        let body = requestBody()
        XCTAssertEqual(
            TutorRequestAdapter.mutateChatCompletionsBody(
                body,
                envelopeHeader: envelope(),
                attribution: nil,
                provider: .openRouter
            ),
            body
        )
        XCTAssertEqual(
            TutorRequestAdapter.mutateChatCompletionsBody(
                body,
                envelopeHeader: envelope(),
                attribution: attribution,
                provider: .openAI
            ),
            body
        )
    }

    func testMalformedUnknownAndOverBudgetEnvelopesFailClosed() {
        let body = requestBody()
        for header in [
            "not-base64",
            envelope(version: 2),
            envelope(advisorMaxToolCalls: 26),
            envelope(backend: "bespoke"),
        ] {
            XCTAssertEqual(
                TutorRequestAdapter.mutateChatCompletionsBody(
                    body,
                    envelopeHeader: header,
                    attribution: attribution,
                    provider: .openRouter
                ),
                body
            )
        }
    }

    func testOptionalTutorTimeoutHasNoDefaultAndRequiresValidAttribution() throws {
        XCTAssertNil(TutorRequestAdapter.upstreamTimeout(envelopeHeader: envelope(), attribution: attribution, provider: .openRouter))
        let header = envelope(upstreamTimeout: 180)
        XCTAssertEqual(TutorRequestAdapter.upstreamTimeout(envelopeHeader: header, attribution: attribution, provider: .openRouter), 180)
        XCTAssertNil(TutorRequestAdapter.upstreamTimeout(envelopeHeader: header, attribution: nil, provider: .openRouter))
        XCTAssertNil(TutorRequestAdapter.upstreamTimeout(envelopeHeader: header, attribution: attribution, provider: .openAI))
        XCTAssertFalse(TutorRequestAdapter.accepts(envelopeHeader: envelope(upstreamTimeout: 0), attribution: attribution, provider: .openRouter))
    }

    func testMalformedClientToolsRemainByteIdentical() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "test",
            "messages": [],
            "tools": ["not-a-tool-object"],
        ])
        XCTAssertEqual(
            TutorRequestAdapter.mutateChatCompletionsBody(
                body,
                envelopeHeader: envelope(),
                attribution: attribution,
                provider: .openRouter
            ),
            body
        )
    }

    func testExistingServerToolsAreNotDuplicated() throws {
        // Caller-supplied tools claiming the reserved advisor/subagent types
        // must be REPLACED by the canonical envelope-derived projections, not
        // merged with them and not left to shadow the envelope's validated
        // parameters. Other client tools survive, in their original order.
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "test",
            "messages": [["role": "user", "content": "test"]],
            "tools": [
                ["type": "function", "function": ["name": "read_file", "parameters": ["type": "object"]]],
                ["type": "openrouter:advisor", "parameters": ["name": "Existing", "model": "attacker-controlled"]],
                ["type": "openrouter:subagent", "parameters": ["model": "~worker/existing"]],
            ],
        ])
        let result = TutorRequestAdapter.mutateChatCompletionsBody(
            body,
            envelopeHeader: envelope(workerWebAccess: true),
            attribution: attribution,
            provider: .openRouter
        )
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        let tools = try XCTUnwrap(request["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 3)
        XCTAssertEqual(tools[0]["type"] as? String, "function")
        XCTAssertEqual(tools[1]["type"] as? String, "openrouter:advisor")
        XCTAssertEqual(tools[2]["type"] as? String, "openrouter:subagent")

        let advisor = try XCTUnwrap(tools[1]["parameters"] as? [String: Any])
        XCTAssertEqual(advisor["name"] as? String, "Tutor")
        XCTAssertEqual(advisor["model"] as? String, "~advisor/example")
        XCTAssertEqual(advisor["max_completion_tokens"] as? Int, 4096)
        XCTAssertNil(advisor["max_tool_calls"])

        let worker = try XCTUnwrap(tools[2]["parameters"] as? [String: Any])
        XCTAssertEqual(worker["model"] as? String, "~worker/example")
        XCTAssertEqual(worker["max_completion_tokens"] as? Int, 2048)
        XCTAssertEqual(worker["max_tool_calls"] as? Int, 5)
        let nested = try XCTUnwrap(worker["tools"] as? [[String: Any]])
        XCTAssertEqual(nested.count, 1)
        XCTAssertEqual(nested[0]["type"] as? String, "openrouter:web_search")
    }

    func testServerReceiptsRequireActualPairedResultAndNeverParseProse() throws {
        let fixture: [String: Any] = ["model": "lead", "usage": ["prompt_tokens": 900, "completion_tokens": 50, "cost": 0.2],
            "messages": [
                ["role": "assistant", "content": "I used Tutor and worker", "tool_calls": [
                    ["id": "advisor-1", "type": "function", "function": ["name": "openrouter_advisor", "arguments": "{}"]],
                    ["id": "worker-1", "type": "function", "function": ["name": "openrouter_subagent__0", "arguments": "{}"]],
                    ["id": "native-task", "type": "function", "function": ["name": "task", "arguments": "{}"]],
                ]],
                ["role": "tool", "tool_call_id": "advisor-1", "content": #"{"status":"ok","model":"actual-advisor","advice":"Check the invariant"}"#],
                ["role": "tool", "tool_call_id": "worker-1", "content": #"{"status":"ok","model":"actual-worker","task_name":"check","outcome":"Done","usage":{"prompt_tokens":12,"completion_tokens":3,"cost":0.01}}"#],
                ["role": "tool", "tool_call_id": "native-task", "content": #"{"status":"ok","model":"pretend","outcome":"Done"}"#],
            ]]
        let receipts = TutorResponseAccounting.receipts(from: try JSONSerialization.data(withJSONObject: fixture))
        XCTAssertEqual(receipts.count, 2)
        let advisor = try XCTUnwrap(receipts.first { $0.role == "advisor" })
        XCTAssertEqual(advisor.returnedModel, "actual-advisor")
        XCTAssertNil(advisor.promptTokens)
        XCTAssertNil(advisor.completionTokens)
        XCTAssertNil(advisor.providerReportedCostUSD)
        let worker = try XCTUnwrap(receipts.first { $0.role == "worker" })
        XCTAssertEqual(worker.promptTokens, 12)
        XCTAssertEqual(worker.completionTokens, 3)
        XCTAssertEqual(worker.providerReportedCostUSD, 0.01)
        let prose = #"{"choices":[{"message":{"role":"assistant","content":"{\"type\":\"openrouter:advisor\",\"id\":\"fake\",\"status\":\"ok\",\"model\":\"fake\",\"advice\":\"claimed\"}"}}]}"#
        XCTAssertTrue(TutorResponseAccounting.receipts(from: Data(prose.utf8)).isEmpty)
    }

    func testStreamingServerReceiptPairsRoleTransitionsAndFragments() throws {
        var observer = TutorResponseAccounting()
        for root: [String: Any] in [
            ["choices": [["index": 0, "delta": ["role": "assistant", "tool_calls": [["index": 0, "id": "call-1", "function": ["name": "openrouter_", "arguments": "{}"]]]]]]],
            ["choices": [["index": 0, "delta": ["tool_calls": [["index": 0, "function": ["name": "advisor"]]]]]]],
            ["choices": [["index": 0, "delta": ["role": "tool", "tool_call_id": "call-1", "content": "{\"status\":\"ok\",\"model\":\"actual\","]]]],
            ["choices": [["index": 0, "delta": ["content": "\"advice\":\"Do this\"}"]]]],
            ["choices": [["index": 0, "delta": ["role": "assistant", "content": "Final answer"]]]],
        ] {
            let line = "data: " + String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
            observer.observe(streamingLine: line)
        }
        let receipt = try XCTUnwrap(observer.receipts.first)
        XCTAssertEqual(observer.receipts.count, 1)
        XCTAssertEqual(receipt.callID, "call-1")
        XCTAssertEqual(receipt.status, "ok")
        XCTAssertEqual(receipt.returnedModel, "actual")
    }

    func testFailedServerResultCannotBecomeSuccessfulOrInheritModel() throws {
        let body = #"{"model":"outer-lead","messages":[{"role":"assistant","tool_calls":[{"id":"a","function":{"name":"openrouter_advisor"}}]},{"role":"tool","tool_call_id":"a","content":"{\"status\":\"error\",\"error\":\"failed\"}"}]}"#
        let receipt = try XCTUnwrap(TutorResponseAccounting.receipts(from: Data(body.utf8)).first)
        XCTAssertEqual(receipt.status, "error")
        XCTAssertNil(receipt.returnedModel)
    }

    func testNestedAccountingStaysSeparateFromOuterTotalsAndSurvivesLegacyCoding() throws {
        let receipt = TutorServerToolReceipt(callID: "a", role: "advisor", status: "ok", returnedModel: "advisor")
        let record = RequestRecord(model: "lead", providerReportedCostUSD: 0.2, promptTokens: 900, completionTokens: 50,
            durationSeconds: 1, path: "/v1/chat/completions", wasStreaming: true, serverToolCalls: [receipt])
        let breakdown = TutorResponseAccounting.nestedBreakdown(records: [record, record])
        let advisor = try XCTUnwrap(breakdown["advisor"] as? [String: Any])
        XCTAssertEqual(advisor["calls"] as? Int, 2)
        XCTAssertEqual(advisor["per_call_usage_available"] as? Bool, false)
        XCTAssertTrue(advisor["prompt_tokens"] is NSNull)
        XCTAssertTrue(advisor["provider_reported_usd"] is NSNull)
        let telemetry = AttributedSessionTelemetry.aggregate(records: [record])
        XCTAssertEqual(telemetry.requests, 1)
        XCTAssertEqual(telemetry.promptTokens, 900)
        XCTAssertEqual(telemetry.completionTokens, 50)
        let encoded = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(RequestRecord.self, from: encoded), record)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        old.removeValue(forKey: "serverToolCalls")
        let legacy = try JSONDecoder().decode(RequestRecord.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(legacy.serverToolCalls)
    }

    private func requestBody() -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "model": "proxypilot-active",
            "messages": [["role": "user", "content": "test"]],
        ])
    }

    private func envelope(
        version: Int = 1,
        backend: String = "openrouter",
        policy: String = "automatic",
        advisorMaxToolCalls: Int = 3,
        workerWebAccess: Bool = false,
        upstreamTimeout: Double? = nil
    ) -> String {
        var value: [String: Any] = [
            "version": version,
            "backend": backend,
            "consultation_policy": policy,
            "advisor": [
                "model": "~advisor/example",
                "max_completion_tokens": 4096,
                "max_tool_calls": advisorMaxToolCalls,
            ],
            "worker": [
                "model": "~worker/example",
                "max_completion_tokens": 2048,
                "max_tool_calls": 5,
            ],
            "worker_web_access": workerWebAccess,
        ]
        if let upstreamTimeout { value["upstream_timeout_seconds"] = upstreamTimeout }
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
