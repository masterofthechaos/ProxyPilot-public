import Foundation
import ProxyPilotCore

enum OutputFormatter {
    static func success<T: Encodable>(
        command: String,
        data: T,
        humanMessage: String,
        json: Bool,
        nextActions: [NextAction] = []
    ) {
        if json {
            let output = AgentEnvelope(command: command, data: data, nextActions: nextActions)
            if let str = try? AgentJSON.encode(output) {
                print(str)
            }
        } else {
            print(humanMessage)
        }
    }

    static func error(
        command: String,
        code: String,
        message: String,
        suggestion: String? = nil,
        recoverable: Bool = true,
        json: Bool,
        nextActions: [NextAction] = []
    ) {
        if json {
            let output = AgentErrorEnvelope(
                command: command,
                error: AgentError(code: code, message: message, suggestion: suggestion, recoverable: recoverable),
                nextActions: nextActions
            )
            if let str = try? AgentJSON.encode(output) {
                print(str)
            }
        } else {
            var msg = "Error [\(code)]: \(message)"
            if let suggestion { msg += "\n  Hint: \(suggestion)" }
            FileHandle.standardError.write(Data((msg + "\n").utf8))
        }
    }
}
