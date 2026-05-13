import Foundation
import ProxyPilotCore

struct AuthVerificationOutcome: Equatable {
    let status: String
    let verified: Bool
    let modelCount: Int?
    let errorMessage: String?
}

enum AuthVerificationSupport {
    static func outcome(
        for provider: UpstreamProvider,
        apiKeyPresent: Bool,
        fetchResult: Result<[String], Error>?
    ) -> AuthVerificationOutcome {
        guard provider.requiresAPIKey else {
            return AuthVerificationOutcome(
                status: "not_required",
                verified: true,
                modelCount: nil,
                errorMessage: nil
            )
        }

        guard apiKeyPresent else {
            return AuthVerificationOutcome(
                status: "missing_key",
                verified: false,
                modelCount: nil,
                errorMessage: "No API key is stored for \(provider.title)."
            )
        }

        guard let fetchResult else {
            return AuthVerificationOutcome(
                status: "not_checked",
                verified: false,
                modelCount: nil,
                errorMessage: "Credential verification was not run."
            )
        }

        switch fetchResult {
        case .success(let models):
            return AuthVerificationOutcome(
                status: "verified",
                verified: true,
                modelCount: models.count,
                errorMessage: nil
            )

        case .failure(let error):
            if case let ModelDiscovery.Error.httpError(statusCode) = error {
                if statusCode == 401 || statusCode == 403 {
                    return AuthVerificationOutcome(
                        status: "rejected",
                        verified: false,
                        modelCount: nil,
                        errorMessage: "Upstream rejected the stored credential (HTTP \(statusCode))."
                    )
                }

                return AuthVerificationOutcome(
                    status: "upstream_error",
                    verified: false,
                    modelCount: nil,
                    errorMessage: "Upstream model verification failed (HTTP \(statusCode))."
                )
            }

            if case let ModelDiscovery.Error.networkError(underlying) = error {
                return AuthVerificationOutcome(
                    status: "unreachable",
                    verified: false,
                    modelCount: nil,
                    errorMessage: "Could not reach upstream: \(underlying.localizedDescription)"
                )
            }

            if let urlError = error as? URLError {
                return AuthVerificationOutcome(
                    status: "unreachable",
                    verified: false,
                    modelCount: nil,
                    errorMessage: "Could not reach upstream: \(urlError.localizedDescription)"
                )
            }

            if case ModelDiscovery.Error.invalidJSON = error {
                return AuthVerificationOutcome(
                    status: "invalid_response",
                    verified: false,
                    modelCount: nil,
                    errorMessage: "Upstream returned an invalid models response."
                )
            }

            return AuthVerificationOutcome(
                status: "unreachable",
                verified: false,
                modelCount: nil,
                errorMessage: "Could not verify upstream credential: \(error.localizedDescription)"
            )
        }
    }
}
