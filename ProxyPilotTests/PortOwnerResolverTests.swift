import XCTest
@testable import ProxyPilot

final class PortOwnerResolverTests: XCTestCase {
    private var helper: Process?

    override func tearDown() {
        if let helper, helper.isRunning { helper.terminate() }
        helper = nil
        super.tearDown()
    }

    // MARK: - Live lookup

    func testFindsThisProcessListeningOnPort() throws {
        let (socket, port) = try Self.listenOnEphemeralPort()
        defer { close(socket) }

        let owners = PortOwnerResolver.listeningOwners(port: port)
        let me = try XCTUnwrap(owners.first { $0.pid == getpid() })
        XCTAssertEqual(me.kind, .thisApp)
    }

    func testFindsAnotherProcessByName() throws {
        let port = try Self.freePort()
        let nc = Process()
        nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        nc.arguments = ["-l", "127.0.0.1", String(port)]
        nc.standardOutput = FileHandle.nullDevice
        nc.standardError = FileHandle.nullDevice
        try nc.run()
        helper = nc

        var owner: PortOwner?
        for _ in 0..<40 where owner == nil {
            owner = PortOwnerResolver.listeningOwners(port: port).first { $0.pid == nc.processIdentifier }
            if owner == nil { usleep(50_000) }
        }
        let found = try XCTUnwrap(owner, "nc on port \(port) was not found")
        XCTAssertEqual(found.name, "nc")
        XCTAssertEqual(found.kind, .other)
        XCTAssertEqual(found.location, "/usr/bin/nc")
        XCTAssertTrue(
            PortOwnerResolver.explanation(port: port, owners: [found]).contains("nc (PID \(nc.processIdentifier)")
        )
    }

    func testUnusedPortHasNoOwners() throws {
        XCTAssertTrue(PortOwnerResolver.listeningOwners(port: try Self.freePort()).isEmpty)
    }

    // MARK: - Classification

    func testKindIsCaseSensitiveBetweenAppAndCLI() {
        XCTAssertEqual(PortOwnerResolver.kind(pid: 2, currentPID: 1, bundleID: nil, executableName: "proxypilot"), .proxyPilotCLI)
        XCTAssertEqual(PortOwnerResolver.kind(pid: 2, currentPID: 1, bundleID: nil, executableName: "ProxyPilot"), .proxyPilotApp)
        XCTAssertEqual(PortOwnerResolver.kind(pid: 2, currentPID: 1, bundleID: nil, executableName: "proxypilot-agent"), .proxyPilotAgent)
        XCTAssertEqual(
            PortOwnerResolver.kind(pid: 2, currentPID: 1, bundleID: "com.yourname.ProxyPilot-alpha", executableName: "ProxyPilot Alpha"),
            .proxyPilotApp
        )
        XCTAssertEqual(PortOwnerResolver.kind(pid: 1, currentPID: 1, bundleID: nil, executableName: "proxypilot"), .thisApp)
        XCTAssertEqual(PortOwnerResolver.kind(pid: 2, currentPID: 1, bundleID: "com.docker.docker", executableName: "Docker"), .other)
    }

    // MARK: - Messages

    func testExplanationVariants() {
        func owner(_ kind: PortOwner.Kind, name: String = "X", location: String? = nil) -> PortOwner {
            PortOwner(pid: 42, name: name, location: location, kind: kind)
        }
        let none = PortOwnerResolver.explanation(port: 4000, owners: [])
        XCTAssertTrue(none.contains("didn't reveal"))
        XCTAssertTrue(none.contains("sudo lsof -nP -iTCP:4000 -sTCP:LISTEN"))

        XCTAssertTrue(PortOwnerResolver.explanation(port: 4000, owners: [owner(.thisApp)]).contains("this ProxyPilot app (PID 42)"))
        XCTAssertTrue(PortOwnerResolver.explanation(port: 4000, owners: [owner(.proxyPilotCLI)]).contains("proxypilot stop"))
        XCTAssertTrue(
            PortOwnerResolver.explanation(
                port: 4000,
                owners: [owner(.proxyPilotApp, location: "/Applications/ProxyPilot-before-1.17.7-155.app")]
            ).contains("another copy of ProxyPilot (PID 42) at /Applications/ProxyPilot-before-1.17.7-155.app")
        )
        XCTAssertTrue(
            PortOwnerResolver.explanation(port: 4000, owners: [owner(.other, name: "node", location: "/opt/homebrew/bin/node")])
                .contains("in use by node (PID 42, /opt/homebrew/bin/node)")
        )
        let many = PortOwnerResolver.explanation(
            port: 4000,
            owners: [owner(.other, name: "node"), PortOwner(pid: 7, name: "Docker", location: nil, kind: .other)]
        )
        XCTAssertTrue(many.contains("node (PID 42), Docker (PID 7)"))
    }

    // MARK: - Helpers

    private static func listenOnEphemeralPort() throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (fd, UInt16(bigEndian: address.sin_port))
    }

    private static func freePort() throws -> UInt16 {
        let (fd, port) = try listenOnEphemeralPort()
        close(fd)
        return port
    }
}
