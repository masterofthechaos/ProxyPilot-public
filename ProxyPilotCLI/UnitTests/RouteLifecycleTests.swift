#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import Testing
@testable import proxypilot

struct RouteLifecycleTests {
    @Test func epiphyteRouteIsExplicitAndSharedRouteDefaultsRemainCompatible() throws {
        let legacy = try RouteStatusCommand.parse(["--json"])
        #expect(legacy.client == "repogps")
        let epi = try RouteStatusCommand.parse(["--client", "epiphyte", "--json"])
        #expect(epi.client == "epiphyte")
        let save = try RouteSetCommand.parse(["--client", "epiphyte", "--provider", "openai", "--model", "fixture", "--json"])
        #expect(save.client == "epiphyte")
    }
    @Test func unknownRouteClientIsRejectedBeforeProbingOrMigration() async throws {
        do {
            try await RouteStatusReporter.run(json: true, client: "unknown")
            Issue.record("Unknown client was accepted")
        } catch { #expect(String(describing: error).contains("Unknown route client")) }
    }
    @Test func routeLockDescriptorIsCloseOnExec() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = try RouteStateStore.acquireExclusiveLock(at: directory.appendingPathComponent("route.lock"))
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }

        let flags = fcntl(descriptor, F_GETFD)
        #expect(flags >= 0)
        #expect(flags & FD_CLOEXEC == FD_CLOEXEC)
    }

    @Test func routeStatusCommandRequiresParsingButReporterDoesNot() async throws {
        let parsed = try RouteStatusCommand.parse(["--json"])
        #expect(parsed.json)

        // This is the supported in-process path for `route set` and `route
        // ensure`; it must not touch an unparsed ArgumentParser wrapper.
        try await RouteStatusReporter.run(json: true)
    }
}
