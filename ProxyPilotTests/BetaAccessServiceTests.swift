import XCTest
@testable import ProxyPilot

private actor BetaRequestRecorder {
    var requests: [URLRequest] = []
    var statuses: [Int]
    var held: CheckedContinuation<Void, Never>?
    let holdsFirst: Bool

    init(statuses: [Int] = [200], holdsFirst: Bool = false) {
        self.statuses = statuses
        self.holdsFirst = holdsFirst
    }

    func send(_ request: URLRequest) async -> (Data, URLResponse) {
        requests.append(request)
        if holdsFirst && requests.count == 1 {
            await withCheckedContinuation { held = $0 }
        }
        let status = statuses.count > 1 ? statuses.removeFirst() : statuses[0]
        return (Data("1".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func release() { held?.resume(); held = nil }
}

@MainActor
final class BetaAccessServiceTests: XCTestCase {
    func testEmailValidationAndOuterWhitespace() {
        XCTAssertEqual(BetaAccessService.normalizedEmail("  Micah+beta@example.com \n"), "Micah+beta@example.com")
        for input in ["", " ", "example.com", "a@b", "a@@example.com", "a b@example.com", "a@.example.com", "a@example..com", "<a@example.com>", "a\nb@example.com"] {
            XCTAssertNil(BetaAccessService.normalizedEmail(input), input)
        }
    }

    func testOnlyExplicitValidSubmitSendsMinimalIndependentPayload() async throws {
        let recorder = BetaRequestRecorder()
        let service = BetaAccessService(apiKeyProvider: { "public-project-token" }, transport: { await recorder.send($0) })
        let model = BetaAccessFormModel(service: service)
        do { let requests = await recorder.requests; XCTAssertTrue(requests.isEmpty) }
        await model.submit()
        XCTAssertFalse(model.isSubmitted)
        do { let requests = await recorder.requests; XCTAssertTrue(requests.isEmpty) }
        model.email = "  beta+test@example.invalid  "
        await model.submit()
        XCTAssertTrue(model.isSubmitted)
        XCTAssertTrue(model.email.isEmpty)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url, BetaAccessService.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try payload(request)
        XCTAssertEqual(body["event"] as? String, BetaAccessService.eventName)
        let id = try XCTUnwrap(body["uuid"] as? String)
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(body["distinct_id"] as? String, "proxypilot-beta-\(id)")
        let properties = try XCTUnwrap(body["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["email", "submission_id", "$process_person_profile", "$geoip_disable"])
        XCTAssertEqual(properties["email"] as? String, "beta+test@example.invalid")
        XCTAssertEqual(properties["$process_person_profile"] as? Bool, false)
        XCTAssertEqual(properties["$geoip_disable"] as? Bool, true)
        await model.submit()
        do { let requests = await recorder.requests; XCTAssertEqual(requests.count, 1) }
    }

    func testRejectedSubmissionDoesNotClaimSuccessAndRetryKeepsIdentity() async throws {
        let recorder = BetaRequestRecorder(statuses: [503, 200])
        let model = BetaAccessFormModel(service: BetaAccessService(apiKeyProvider: { "token" }, transport: { await recorder.send($0) }))
        model.email = "beta@example.invalid"
        await model.submit()
        XCTAssertFalse(model.isSubmitted)
        XCTAssertFalse(model.isSubmitting)
        XCTAssertEqual(model.email, "beta@example.invalid")
        XCTAssertNotNil(model.errorMessage)
        await model.submit()
        XCTAssertTrue(model.isSubmitted)
        XCTAssertNil(model.errorMessage)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
    }

    func testEditingEmailAfterFailureCreatesNewSubmissionIdentity() async throws {
        let recorder = BetaRequestRecorder(statuses: [400, 200])
        let model = BetaAccessFormModel(service: BetaAccessService(apiKeyProvider: { "token" }, transport: { await recorder.send($0) }))
        model.email = "first@example.invalid"
        await model.submit()
        model.email = "second@example.invalid"
        await model.submit()
        let requests = await recorder.requests
        XCTAssertNotEqual(try payload(requests[0])["uuid"] as? String, try payload(requests[1])["uuid"] as? String)
        XCTAssertTrue(model.isSubmitted)
    }

    func testPendingSubmissionCannotDoubleSubmitOrClaimSuccess() async {
        let recorder = BetaRequestRecorder(holdsFirst: true)
        let model = BetaAccessFormModel(service: BetaAccessService(apiKeyProvider: { "token" }, transport: { await recorder.send($0) }))
        model.email = "beta@example.invalid"
        let task = Task { await model.submit() }
        while await recorder.held == nil { await Task.yield() }
        XCTAssertTrue(model.isSubmitting)
        XCTAssertFalse(model.isSubmitted)
        XCTAssertFalse(model.canSubmit)
        await model.submit()
        do { let requests = await recorder.requests; XCTAssertEqual(requests.count, 1) }
        await recorder.release()
        await task.value
        XCTAssertTrue(model.isSubmitted)
    }

    func testMissingConfigurationDoesNotSendOrShowConfirmation() async {
        let recorder = BetaRequestRecorder()
        let model = BetaAccessFormModel(service: BetaAccessService(apiKeyProvider: { nil }, transport: { await recorder.send($0) }))
        model.email = "beta@example.invalid"
        await model.submit()
        XCTAssertFalse(model.isSubmitted)
        XCTAssertEqual(model.errorMessage, BetaAccessService.SubmissionError.unavailable.localizedDescription)
        do { let requests = await recorder.requests; XCTAssertTrue(requests.isEmpty) }
    }

    func testNetworkErrorsNeverEchoTheEmailOrServerDetails() async {
        let model = BetaAccessFormModel(service: BetaAccessService(apiKeyProvider: { "token" }, transport: { _ in
            throw NSError(domain: "network", code: 1, userInfo: [NSLocalizedDescriptionKey: "secret beta@example.invalid"])
        }))
        model.email = "beta@example.invalid"
        await model.submit()
        XCTAssertFalse(model.isSubmitted)
        XCTAssertFalse(model.errorMessage?.contains("beta@example.invalid") == true)
    }

    private func payload(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
}
