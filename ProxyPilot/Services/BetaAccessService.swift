import Foundation
import Combine

/// Explicit invitation requests have their own transport and identity. They do
/// not attach an email to the app's diagnostics identity or write a local log.
struct BetaAccessService: Sendable {
    static let eventName = "proxypilot_beta_access_requested"
    static let endpoint = URL(string: "https://us.i.posthog.com/i/v0/e/")!
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    struct Submission: Equatable, Sendable {
        let email: String
        let id: UUID
        let createdAt: Date

        init(email: String, id: UUID = UUID(), createdAt: Date = Date()) {
            self.email = email
            self.id = id
            self.createdAt = createdAt
        }
    }

    enum SubmissionError: LocalizedError {
        case invalidEmail, unavailable, rejected

        var errorDescription: String? {
            switch self {
            case .invalidEmail: "Enter a valid e-mail address."
            case .unavailable: "Beta requests are unavailable right now. Please try again later."
            case .rejected: "Your request could not be submitted. Please check your connection and try again."
            }
        }
    }

    private let apiKeyProvider: @Sendable () -> String?
    private let transport: Transport

    init(
        apiKeyProvider: @escaping @Sendable () -> String? = {
            Bundle.main.object(forInfoDictionaryKey: "POSTHOG_API_KEY") as? String
        },
        transport: @escaping Transport = { request in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            return try await session.data(for: request)
        }
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.transport = transport
    }

    static func normalizedEmail(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Basic address-shape validation; delivery is confirmed by the invitation.
        guard value.range(of: #"^[^\s@<>]+@[^\s@<>.]+(?:\.[^\s@<>.]+)+$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    func submit(_ submission: Submission) async throws {
        guard let email = Self.normalizedEmail(submission.email) else { throw SubmissionError.invalidEmail }
        guard let key = apiKeyProvider(), !key.isEmpty else { throw SubmissionError.unavailable }
        let id = submission.id.uuidString.lowercased()
        let body: [String: Any] = [
            "api_key": key,
            "event": Self.eventName,
            "distinct_id": "proxypilot-beta-\(id)",
            "uuid": id,
            "timestamp": ISO8601DateFormatter().string(from: submission.createdAt),
            "properties": [
                "email": email,
                "submission_id": id,
                "$process_person_profile": false,
                "$geoip_disable": true
            ]
        ]
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        do {
            let (_, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw SubmissionError.rejected
            }
        } catch {
            // Never surface a response body or a URLSession error containing PII.
            throw SubmissionError.rejected
        }
    }
}

@MainActor
final class BetaAccessFormModel: ObservableObject {
    @Published var email = ""
    @Published private(set) var isSubmitting = false
    @Published private(set) var isSubmitted = false
    @Published private(set) var errorMessage: String?
    private let service: BetaAccessService
    private var pendingSubmission: BetaAccessService.Submission?

    init(service: BetaAccessService = BetaAccessService()) { self.service = service }

    var canSubmit: Bool {
        !isSubmitting && !isSubmitted && BetaAccessService.normalizedEmail(email) != nil
    }

    func submit() async {
        guard !isSubmitting, !isSubmitted else { return }
        guard let normalized = BetaAccessService.normalizedEmail(email) else {
            errorMessage = BetaAccessService.SubmissionError.invalidEmail.localizedDescription
            return
        }
        if pendingSubmission?.email != normalized {
            pendingSubmission = .init(email: normalized)
        }
        guard let submission = pendingSubmission else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            try await service.submit(submission)
            isSubmitted = true
            email = ""
            pendingSubmission = nil
        } catch {
            errorMessage = (error as? BetaAccessService.SubmissionError)?.localizedDescription
                ?? BetaAccessService.SubmissionError.rejected.localizedDescription
        }
    }
}
