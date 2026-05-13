import Foundation
import ProxyPilotCore
import Testing
@testable import proxypilot

struct AuthVerificationSupportTests {
    @Test func successfulModelFetchMarksCredentialVerified() {
        let outcome = AuthVerificationSupport.outcome(
            for: .zAI,
            apiKeyPresent: true,
            fetchResult: .success(["glm-5.1", "glm-4.5"])
        )

        #expect(outcome.status == "verified")
        #expect(outcome.verified == true)
        #expect(outcome.modelCount == 2)
        #expect(outcome.errorMessage == nil)
    }

    @Test func upstreamUnauthorizedMarksCredentialRejected() {
        let outcome = AuthVerificationSupport.outcome(
            for: .zAI,
            apiKeyPresent: true,
            fetchResult: .failure(ModelDiscovery.Error.httpError(statusCode: 401))
        )

        #expect(outcome.status == "rejected")
        #expect(outcome.verified == false)
        #expect(outcome.modelCount == nil)
        #expect(outcome.errorMessage == "Upstream rejected the stored credential (HTTP 401).")
    }

    @Test func upstreamForbiddenMarksCredentialRejected() {
        let outcome = AuthVerificationSupport.outcome(
            for: .zAI,
            apiKeyPresent: true,
            fetchResult: .failure(ModelDiscovery.Error.httpError(statusCode: 403))
        )

        #expect(outcome.status == "rejected")
        #expect(outcome.verified == false)
        #expect(outcome.errorMessage == "Upstream rejected the stored credential (HTTP 403).")
    }

    @Test func networkErrorIsNotReportedAsVerified() {
        let outcome = AuthVerificationSupport.outcome(
            for: .zAI,
            apiKeyPresent: true,
            fetchResult: .failure(URLError(.cannotFindHost))
        )

        #expect(outcome.status == "unreachable")
        #expect(outcome.verified == false)
        #expect(outcome.errorMessage?.contains("Could not reach upstream") == true)
    }

    @Test func missingCloudKeyIsReportedBeforeNetworkWork() {
        let outcome = AuthVerificationSupport.outcome(
            for: .zAI,
            apiKeyPresent: false,
            fetchResult: nil
        )

        #expect(outcome.status == "missing_key")
        #expect(outcome.verified == false)
        #expect(outcome.errorMessage == "No API key is stored for z.ai.")
    }

    @Test func localProvidersDoNotRequireVerification() {
        let outcome = AuthVerificationSupport.outcome(
            for: .ollama,
            apiKeyPresent: false,
            fetchResult: nil
        )

        #expect(outcome.status == "not_required")
        #expect(outcome.verified == true)
        #expect(outcome.errorMessage == nil)
    }
}
