import Foundation
import ProxyPilotCore

@MainActor
final class ProxyService {
    struct Paths {
        let restartScript: URL
        let startScript: URL
        let stopScript: URL
        let pidFile: URL
        let logFile: URL
        let configFile: URL
    }

    let paths: Paths

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let toolsDir = homeDirectory.appendingPathComponent("tools/litellm", isDirectory: true)
        self.paths = Paths(
            restartScript: toolsDir.appendingPathComponent("restart_zai_proxy.sh"),
            startScript: toolsDir.appendingPathComponent("start_zai_proxy.sh"),
            stopScript: toolsDir.appendingPathComponent("stop_zai_proxy.sh"),
            pidFile: URL(fileURLWithPath: "/tmp/litellm_zai_proxy.pid"),
            logFile: URL(fileURLWithPath: "/tmp/litellm_zai_proxy.log"),
            configFile: toolsDir.appendingPathComponent("zai_config.yaml")
        )
    }

    func restart() async throws {
        try await run(script: paths.restartScript)
    }

    func start() async throws {
        try await run(script: paths.startScript)
    }

    func stop() async throws {
        try await run(script: paths.stopScript)
    }

    func isRunning() -> Bool {
        guard let pidText = try? String(contentsOf: paths.pidFile, encoding: .utf8) else { return false }
        let trimmed = pidText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(trimmed), pid > 1 else { return false }
        return kill(pid, 0) == 0
    }

    func readLogTail(maxBytes: Int = 32_000) -> String {
        readLogTail(from: paths.logFile, maxBytes: maxBytes)
    }

    func readLogTail(from logFile: URL, maxBytes: Int = 32_000) -> String {
        guard let data = try? Data(contentsOf: logFile) else { return "" }
        if data.count <= maxBytes {
            return String(decoding: data, as: UTF8.self)
        }
        return String(decoding: data.suffix(maxBytes), as: UTF8.self)
    }

    func normalizedUpstreamAPIBase(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        return Self.normalizedUpstreamAPIBase(url)
    }

    static func normalizedUpstreamAPIBase(_ apiBase: URL) -> URL {
        guard var components = URLComponents(url: apiBase, resolvingAgainstBaseURL: false) else {
            return apiBase
        }

        var segments = components.path.split(separator: "/").map(String.init)
        let suffixes: [[String]] = [
            ["chat", "completions"],
            ["completions"],
            ["models"],
            ["responses"],
            ["embeddings"],
            ["messages"]
        ]

        func hasSuffix(_ candidate: [String], suffix: [String]) -> Bool {
            guard candidate.count >= suffix.count else { return false }
            return Array(candidate.suffix(suffix.count)).map { $0.lowercased() } == suffix
        }

        var stripped = true
        while stripped {
            stripped = false
            for suffix in suffixes {
                if hasSuffix(segments, suffix: suffix) {
                    segments.removeLast(suffix.count)
                    stripped = true
                    break
                }
            }
        }

        components.path = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url ?? apiBase
    }

    func fetchModels(baseURL: URL, masterKey: String?) async throws -> String {
        let url = baseURL.appendingPathComponent("v1/models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let masterKey,
           !masterKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(masterKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 5

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProxyServiceError.httpStatus(http.statusCode, body)
        }
        return String(decoding: data, as: UTF8.self)
    }

    func probe(baseURL: URL) async throws -> Int {
        // We only care that something is listening and responding. Auth errors are still "up".
        let url = baseURL.appendingPathComponent("v1/models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2

        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            return http.statusCode
        }
        return 0
    }

    func fetchUpstreamModels(
        apiBase: URL,
        apiKey: String,
        provider: UpstreamProvider = .openAI
    ) async throws -> [UpstreamModel] {
        let modelsURL = Self.buildUpstreamURL(
            base: Self.normalizedUpstreamAPIBase(apiBase),
            path: provider.modelsPath
        )
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        applyUpstreamAuth(apiKey: apiKey, provider: provider, request: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProxyServiceError.httpStatus(http.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        return decoded.data.map { model in
            let promptPer1M = model.pricing?.prompt.flatMap(Double.init).map { $0 * 1_000_000 }
            let completionPer1M = model.pricing?.completion.flatMap(Double.init).map { $0 * 1_000_000 }
            return UpstreamModel(
                id: model.id,
                contextLength: model.contextLength,
                promptPricePer1M: promptPer1M,
                completionPricePer1M: completionPer1M
            )
        }.sorted { $0.id < $1.id }
    }

    func testUpstreamChat(
        apiBase: URL,
        apiKey: String,
        model: String,
        provider: UpstreamProvider = .openAI
    ) async throws -> String {
        let url = Self.buildUpstreamURL(
            base: Self.normalizedUpstreamAPIBase(apiBase),
            path: provider.chatCompletionsPath
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyUpstreamAuth(apiKey: apiKey, provider: provider, request: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let body = ChatCompletionRequest(
            model: model,
            messages: [
                .init(role: "system", content: "You are a brief assistant."),
                .init(role: "user", content: "Reply with exactly: ok")
            ],
            temperature: 0.0,
            maxTokens: 256
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw ProxyServiceError.httpStatus(http.statusCode, bodyText)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        return decoded.text ?? ""
    }

    private func run(script: URL) async throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: script.path) || fm.fileExists(atPath: script.path) else {
            throw ProxyServiceError.missingScript(script.path)
        }

        // Use zsh explicitly (execing the script directly can fail under some sandbox/FS setups).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { p in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: data, as: UTF8.self)
                if p.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ProxyServiceError.scriptFailed(script.lastPathComponent, Int(p.terminationStatus), output))
                }
            }
        }
    }

    private static func buildUpstreamURL(
        base: URL,
        path: String
    ) -> URL {
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return base.appendingPathComponent(normalizedPath)
    }

    private func applyUpstreamAuth(
        apiKey: String,
        provider: UpstreamProvider,
        request: inout URLRequest
    ) {
        guard !apiKey.isEmpty else { return }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
}

private struct OpenAIModelsResponse: Decodable {
    struct Model: Decodable {
        let id: String
        let contextLength: Int?
        let pricing: Pricing?

        struct Pricing: Decodable {
            let prompt: String?
            let completion: String?
        }

        enum CodingKeys: String, CodingKey {
            case id
            case contextLength = "context_length"
            case pricing
        }
    }
    let data: [Model]
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [Message]
    let temperature: Double?
    let maxTokens: Int?

    struct Message: Encodable {
        let role: String
        let content: String
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
    }
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct ResponseMessage: Decodable {
            let content: String?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                // Some providers (e.g., Mistral) may return content as an array
                // of typed parts instead of a plain string.
                if let str = try? container.decode(String.self, forKey: .content) {
                    content = str
                } else if let parts = try? container.decode([ContentPart].self, forKey: .content) {
                    content = parts.compactMap(\.text).joined()
                } else {
                    content = nil
                }
            }

            private struct ContentPart: Decodable {
                let text: String?
            }
            private enum CodingKeys: String, CodingKey { case content }
        }
        let message: ResponseMessage
    }

    let choices: [Choice]

    var text: String? {
        choices.first?.message.content
    }
}

enum ProxyServiceError: LocalizedError {
    case missingScript(String)
    case scriptFailed(String, Int, String)
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingScript(let path):
            return "Missing script: \(path)"
        case .scriptFailed(let name, let code, let output):
            if output.isEmpty {
                return "\(name) failed (exit \(code))."
            }
            return "\(name) failed (exit \(code)): \(output)"
        case .httpStatus(let status, let body):
            if body.isEmpty {
                return "HTTP \(status)"
            }
            return "HTTP \(status): \(body)"
        }
    }
}
