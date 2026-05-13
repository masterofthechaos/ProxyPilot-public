import XCTest
@testable import ProxyPilotCore

final class AgentContractTests: XCTestCase {
    func testEnvelopeUsesSchemaVersionAndSortedKeys() throws {
        let payload = StatusPayload(
            running: true,
            process: .init(managed: false, pid: nil),
            http: .init(reachable: true, port: 4000, modelsCount: 12),
            effectiveStatus: "running_unmanaged"
        )
        let envelope = AgentEnvelope(command: "status", data: payload)

        let first = try AgentJSON.encode(envelope)
        let second = try AgentJSON.encode(envelope)

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains("\"schema_version\":1"))
        XCTAssertTrue(first.contains("\"models_count\":12"))
        XCTAssertTrue(first.contains("\"port\":4000"))
        XCTAssertFalse(first.contains("\"port\":\"4000\""))
    }

    func testStatusPayloadCanExposeProxyOwner() throws {
        let payload = StatusPayload(
            running: true,
            process: .init(managed: false, pid: nil, owner: "external_or_gui"),
            http: .init(reachable: true, port: 4000, modelsCount: 3),
            effectiveStatus: "running_unmanaged"
        )
        let envelope = AgentEnvelope(command: "status", data: payload)
        let json = try AgentJSON.encode(envelope)

        XCTAssertTrue(json.contains("\"owner\":\"external_or_gui\""))
    }

    func testStatusPayloadCanExposeHTTPProbeError() throws {
        let payload = StatusPayload(
            running: false,
            process: .init(managed: false, pid: nil, owner: "none"),
            http: .init(reachable: false, port: 4000, modelsCount: nil, errorMessage: "Operation not permitted"),
            effectiveStatus: "stopped"
        )
        let envelope = AgentEnvelope(command: "status", data: payload)
        let json = try AgentJSON.encode(envelope)

        XCTAssertTrue(json.contains("\"error\":\"Operation not permitted\""))
    }

    func testErrorEnvelopeIncludesRecoverableNextAction() throws {
        let action = NextAction(
            id: "set_auth",
            kind: .cli,
            command: "proxypilot auth set --provider zai",
            destructive: false
        )
        let envelope = AgentErrorEnvelope(
            command: "start",
            error: AgentError(
                code: "E004",
                message: "No API key found for provider zai.",
                suggestion: "Run proxypilot auth set --provider zai.",
                recoverable: true
            ),
            nextActions: [action]
        )

        let json = try AgentJSON.encode(envelope)

        XCTAssertTrue(json.contains("\"ok\":false"))
        XCTAssertTrue(json.contains("\"recoverable\":true"))
        XCTAssertTrue(json.contains("\"next_actions\""))
        XCTAssertTrue(json.contains("\"kind\":\"cli\""))
    }

    func testNextActionArgumentsPreservePrimitiveTypes() throws {
        let action = NextAction(
            id: "auth_set_zai",
            kind: .mcpTool,
            tool: "auth_set",
            arguments: [
                "provider": .string("zai"),
                "port": .int(4000),
                "allow_secret_write": .bool(true),
            ],
            destructive: false
        )

        let json = try AgentJSON.encode(action)

        XCTAssertTrue(json.contains("\"provider\":\"zai\""))
        XCTAssertTrue(json.contains("\"port\":4000"))
        XCTAssertTrue(json.contains("\"allow_secret_write\":true"))
    }

    func testRoutingVerificationPayloadMarksLocalOnlyProbe() throws {
        let payload = RoutingVerificationPayload(
            localModelsReachable: true,
            modelsCount: 3,
            xcodeConfigInstalled: true,
            configuredBaseURL: "http://127.0.0.1:4000",
            portMatchesConfig: true,
            upstreamProbePerformed: false
        )

        let json = try AgentJSON.encode(AgentEnvelope(tool: "verify_routing", data: payload))

        XCTAssertTrue(json.contains("\"models_count\":3"))
        XCTAssertTrue(json.contains("\"upstream_probe_performed\":false"))
    }
}
