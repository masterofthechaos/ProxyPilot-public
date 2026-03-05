import Foundation

enum OutputFormatter {
    static func success(data: [String: Any], humanMessage: String, json: Bool) {
        if json {
            let output: [String: Any] = ["ok": true, "data": data]
            if let jsonData = try? JSONSerialization.data(withJSONObject: output),
               let str = String(data: jsonData, encoding: .utf8) {
                print(str)
            }
        } else {
            print(humanMessage)
        }
    }

    static func error(code: String, message: String, suggestion: String? = nil, json: Bool) {
        if json {
            var err: [String: Any] = ["code": code, "message": message]
            if let suggestion { err["suggestion"] = suggestion }
            let output: [String: Any] = ["ok": false, "error": err]
            if let jsonData = try? JSONSerialization.data(withJSONObject: output),
               let str = String(data: jsonData, encoding: .utf8) {
                print(str)
            }
        } else {
            var msg = "Error [\(code)]: \(message)"
            if let suggestion { msg += "\n  Hint: \(suggestion)" }
            FileHandle.standardError.write(Data((msg + "\n").utf8))
        }
    }
}
