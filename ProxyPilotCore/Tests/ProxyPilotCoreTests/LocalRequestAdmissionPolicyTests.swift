import Testing
@testable import ProxyPilotCore

private let admissionPort: UInt16 = 4000

@Test func localAdmissionAcceptsNativeJSONAndLoopbackAuthorities() {
    for host in ["localhost:4000", "127.0.0.1:4000", "127.12.34.56:4000", "[::1]:4000"] {
        let rejection = LocalRequestAdmissionPolicy.rejection(
            method: "POST",
            requestTarget: "/v1/chat/completions",
            headers: [
                .init(name: "Host", value: host),
                .init(name: "Content-Type", value: "application/json; charset=utf-8")
            ],
            listenerPort: admissionPort
        )
        #expect(rejection == nil)
    }
}

@Test func localAdmissionAcceptsOSAssignedListenerPortWithoutRelaxingHost() {
    let accepted = LocalRequestAdmissionPolicy.rejection(
        method: "GET",
        requestTarget: "/v1/models",
        headers: [.init(name: "Host", value: "127.0.0.1:53124")],
        listenerPort: 0
    )
    let rejected = LocalRequestAdmissionPolicy.rejection(
        method: "GET",
        requestTarget: "/v1/models",
        headers: [.init(name: "Host", value: "attacker.invalid:53124")],
        listenerPort: 0
    )

    #expect(accepted == nil)
    #expect(rejected?.statusCode == 403)
}

@Test func localAdmissionRejectsBrowserOriginAndFetchMetadata() {
    let origin = LocalRequestAdmissionPolicy.rejection(
        method: "POST",
        requestTarget: "/v1/messages",
        headers: [
            .init(name: "Host", value: "127.0.0.1:4000"),
            .init(name: "Origin", value: "http://attacker.invalid"),
            .init(name: "Content-Type", value: "application/json")
        ],
        listenerPort: admissionPort
    )
    let fetchMetadata = LocalRequestAdmissionPolicy.rejection(
        method: "GET",
        requestTarget: "/v1/models",
        headers: [
            .init(name: "Host", value: "localhost:4000"),
            .init(name: "Sec-Fetch-Site", value: "same-site")
        ],
        listenerPort: admissionPort
    )

    #expect(origin?.statusCode == 403)
    #expect(fetchMetadata?.statusCode == 403)
}

@Test func localAdmissionRejectsSimpleNoCORSMediaTypes() {
    for contentType in ["text/plain", "application/x-www-form-urlencoded", "multipart/form-data", ""] {
        let headers = [
            LocalHTTPHeaderField(name: "Host", value: "127.0.0.1:4000"),
            LocalHTTPHeaderField(name: "Content-Type", value: contentType)
        ]
        let rejection = LocalRequestAdmissionPolicy.rejection(
            method: "POST",
            requestTarget: "/chat/completions",
            headers: headers,
            listenerPort: admissionPort
        )
        #expect(rejection?.statusCode == 415)
    }
}

@Test func localAdmissionRejectsWrongOrAmbiguousAuthority() {
    for headers in [
        [LocalHTTPHeaderField(name: "Host", value: "attacker.invalid:4000")],
        [LocalHTTPHeaderField(name: "Host", value: "127.0.0.1.evil:4000")],
        [LocalHTTPHeaderField(name: "Host", value: "127.0.0.1:4999")],
        [
            LocalHTTPHeaderField(name: "Host", value: "127.0.0.1:4000"),
            LocalHTTPHeaderField(name: "Host", value: "attacker.invalid:4000")
        ],
        []
    ] {
        #expect(LocalRequestAdmissionPolicy.rejection(
            method: "GET",
            requestTarget: "/v1/models",
            headers: headers,
            listenerPort: admissionPort
        ) != nil)
    }
}

@Test func localAdmissionRejectsAbsoluteAndNetworkPathTargets() {
    for target in ["http://127.0.0.1:4000/v1/models", "//attacker.invalid/v1/models"] {
        #expect(LocalRequestAdmissionPolicy.rejection(
            method: "GET",
            requestTarget: target,
            headers: [.init(name: "Host", value: "127.0.0.1:4000")],
            listenerPort: admissionPort
        )?.statusCode == 400)
    }
}
