import Foundation
import Testing
@testable import ProxyPilotCore

@Test func openAIErrorJSONEscapesMessageContent() throws {
    let message = "quoted \"message\" with newline\nand backslash \\"
    let json = ProxyErrorResponse.openAI(message: message, type: "server_error", code: 502)
    let data = try #require(json.data(using: .utf8))
    let parsed = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let error = try #require(parsed["error"] as? [String: Any])

    #expect(error["message"] as? String == message)
    #expect(error["type"] as? String == "server_error")
    #expect(error["code"] as? Int == 502)
}
