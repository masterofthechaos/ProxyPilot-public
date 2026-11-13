import Foundation
import Testing
@testable import ProxyPilotCore

struct EpiphyteRoutingTests {
    @Test func seedIsOneTimeAndSelectionsStayIndependent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EpiphyteRouteStore(directory: root)
        let old = EpiphyteRoute(provider: "openrouter", model: "legacy-model")
        #expect(try store.loadOrSeed(old) == old)
        let next = EpiphyteRoute(provider: "openai", model: "epi-model")
        try store.save(next)
        #expect(try store.loadOrSeed(old) == next)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("route.json").path))
        try Data("corrupt preserved".utf8).write(to: store.selectionURL)
        #expect(try store.loadOrSeed(old) == nil)
        #expect(try String(contentsOf: store.selectionURL, encoding: .utf8) == "corrupt preserved")
    }
    @Test func onlyHeldLeasesCountAndConcurrentRequestsSurviveIndependently() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = IndependentRequestActivity(sessionID: UUID().uuidString, provider: "openai", model: "a")
        let b = IndependentRequestActivity(sessionID: UUID().uuidString, provider: "openrouter", model: "b")
        var first: EpiphyteRequestLease? = try EpiphyteRequestLease(a, root: root)
        var second: EpiphyteRequestLease? = try EpiphyteRequestLease(b, root: root)
        withExtendedLifetime((first, second)) { #expect(Set(EpiphyteRequestLease.active(root: root).map(\.sessionID)) == Set([a.sessionID, b.sessionID])) }
        let abandoned = EpiphyteRequestLease.activityDirectory(root: root).appendingPathComponent("abandoned.json")
        try JSONEncoder().encode(a).write(to: abandoned)
        first = nil
        withExtendedLifetime(second) { #expect(EpiphyteRequestLease.active(root: root).map(\.sessionID) == [b.sessionID]) }
        second = nil
        #expect(EpiphyteRequestLease.active(root: root).isEmpty)
    }
    @Test func clientDeathReleasesActivityEvenWhenJSONRemains() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = EpiphyteRequestLease.activityDirectory(root: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let activity = IndependentRequestActivity(sessionID: UUID().uuidString, provider: "openai", model: "fixture")
        let path = directory.appendingPathComponent("child.json")
        let json = String(decoding: try JSONEncoder().encode(activity), as: UTF8.self)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import fcntl,sys,time,signal; signal.signal(signal.SIGTERM,signal.SIG_DFL); f=open(sys.argv[1],'w'); fcntl.flock(f,fcntl.LOCK_EX); f.write(sys.argv[2]); f.flush(); print('ready',flush=True); time.sleep(60)", path.path, json]
        let output = Pipe(); process.standardOutput = output
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        _ = output.fileHandleForReading.availableData
        #expect(EpiphyteRequestLease.active(root: root).map(\.sessionID) == [activity.sessionID])
        process.terminate(); process.waitUntilExit()
        #expect(FileManager.default.fileExists(atPath: path.path))
        #expect(EpiphyteRequestLease.active(root: root).isEmpty)
    }
}
