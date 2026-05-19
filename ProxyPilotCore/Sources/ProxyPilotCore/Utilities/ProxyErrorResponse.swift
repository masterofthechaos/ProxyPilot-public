import Foundation

public enum ProxyErrorResponse {
    public static func openAI(
        message: String,
        type: String = "invalid_request_error",
        code: Int? = nil
    ) -> String {
        var error: [String: Any] = [
            "message": message,
            "type": type
        ]
        if let code {
            error["code"] = code
        }

        let envelope: [String: Any] = ["error": error]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"error":{"message":"Unknown error","type":"invalid_request_error"}}"#
        }
        return json
    }
}
