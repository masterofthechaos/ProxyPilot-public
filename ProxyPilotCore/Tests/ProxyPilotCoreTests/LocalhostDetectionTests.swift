import Testing
@testable import ProxyPilotCore

@Suite("LocalhostDetection")
struct LocalhostDetectionTests {
    @Test func localhostWithPort() { #expect(isLocalhostURL("http://localhost:11434/v1") == true) }
    @Test func localhostWithoutPort() { #expect(isLocalhostURL("http://localhost/v1") == true) }
    @Test func ipv4Loopback() { #expect(isLocalhostURL("http://127.0.0.1:1234/v1") == true) }
    @Test func ipv6Loopback() { #expect(isLocalhostURL("http://[::1]:8080/v1") == true) }
    @Test func httpsLocalhost() { #expect(isLocalhostURL("https://localhost:4000") == true) }
    @Test func remoteURLIsNotLocal() { #expect(isLocalhostURL("https://api.openai.com/v1") == false) }
    @Test func emptyStringIsNotLocal() { #expect(isLocalhostURL("") == false) }
    @Test func localhostSubdomainIsNotLocal() { #expect(isLocalhostURL("http://localhost.evil.com:4000") == false) }
}
