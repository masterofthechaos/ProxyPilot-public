import XCTest
import CryptoKit
@testable import ProxyPilot

final class RepoGPSServiceTests: XCTestCase {
    @MainActor
    func testRepoGPSInstallActivatesProxyPilotCLIBeforePayloadInstallation() async {
        var activationCount = 0
        let service = RepoGPSService(
            home: URL(fileURLWithPath: "/private/tmp/repogps-install-test"),
            bundle: Bundle(for: Self.self),
            cliActivator: {
                activationCount += 1
                return nil
            }
        )

        await service.install()

        XCTAssertEqual(activationCount, 1)
        XCTAssertEqual(service.lastError, "This ProxyPilot build does not contain a RepoGPS payload.")
    }

    @MainActor
    func testProxyPilotCLIActivationFailureStopsRepoGPSInstallWithActionableError() async {
        let service = RepoGPSService(
            home: URL(fileURLWithPath: "/private/tmp/repogps-install-test"),
            bundle: Bundle(for: Self.self),
            cliActivator: { "permission denied" }
        )

        let installed = await service.installProxyPilotCLI()

        XCTAssertFalse(installed)
        XCTAssertEqual(service.lastError, "Could not install ProxyPilot CLI: permission denied")
    }

    func testGettingStartedContractExplainsTerminalEntryAndOrientationSafety() {
        XCTAssertEqual(RepoGPSGettingStarted.starterCommand, "cd /path/to/your/project\n~/.repogps/bin/rgps")
        XCTAssertEqual(
            RepoGPSGettingStarted.commands.map(\.command),
            [
                "cd /path/to/your/project\n~/.repogps/bin/rgps",
                "~/.repogps/bin/rgps --dir /path/to/your/project",
                "~/.repogps/bin/rgps orient --mode quick",
                "~/.repogps/bin/rgps orient --mode standard",
                "~/.repogps/bin/rgps orient --mode deep",
            ]
        )
        XCTAssertTrue(RepoGPSGettingStarted.commands[2].explanation.contains("does not create"))
        XCTAssertTrue(RepoGPSGettingStarted.commands[3].explanation.contains("confirmation"))
        XCTAssertFalse(RepoGPSGettingStarted.commands.contains { $0.command.contains("open -a") })
    }

    func testTerminalLauncherUsesExactPathsAndDeletesOnlyItsOwnScript() {
        let script = RepoGPSService.terminalLauncherScript(
            executable: URL(fileURLWithPath: "/Users/tester/.repogps/bin/rgps"),
            repository: URL(fileURLWithPath: "/Users/tester/Projects/Micah's App")
        )

        XCTAssertTrue(script.hasPrefix("#!/bin/zsh\n"))
        XCTAssertTrue(script.contains(#"/bin/rm -f -- "$0" || true"#))
        XCTAssertTrue(script.contains("cd -- '/Users/tester/Projects/Micah'\\''s App'"))
        XCTAssertTrue(script.contains("exec '/Users/tester/.repogps/bin/rgps' --dir '/Users/tester/Projects/Micah'\\''s App'"))
        XCTAssertFalse(script.contains("~/.repogps"))
        XCTAssertFalse(script.contains("open -a"))
    }

    func testDistributionContractDecodesManagedPayload() throws {
        let data = Data(#"{"installed":true,"ownership":"managed","current_version":"0.2.0","previous_version":"0.1.0","executable":"/tmp/rgps","behavior_pack_version":"1","engine_ready":true}"#.utf8)
        let status = try XCTUnwrap(RepoGPSService.parseDistributionStatus(data))
        XCTAssertEqual(status.currentVersion, "0.2.0")
        XCTAssertEqual(status.previousVersion, "0.1.0")
        XCTAssertEqual(status.behaviorPackVersion, "1")
        XCTAssertTrue(status.engineReady)
    }

    func testOldMissingAndExternalStatusRemainBackwardCompatible() throws {
        let old = try XCTUnwrap(RepoGPSService.parseDistributionStatus(Data(#"{"installed":true,"ownership":"managed","current_version":"0.5.0","engine_ready":true}"#.utf8)))
        XCTAssertNil(old.integrity)
        XCTAssertNil(old.pathConfigured)
        XCTAssertFalse(old.needsRepair)
        XCTAssertEqual(old.primaryAction, .maintain)
        XCTAssertEqual(RepoGPSService.DistributionStatus.missing.primaryAction, .install)

        let external = try XCTUnwrap(RepoGPSService.parseDistributionStatus(Data(#"{"installed":true,"ownership":"external","engine_ready":false,"integrity":"unverifiable","repair_required":true}"#.utf8)))
        XCTAssertFalse(external.needsRepair)
        XCTAssertEqual(external.primaryAction, .adopt)
    }

    func testDamagedManagedPayloadOffersRepairEvenWhenExecutableIsMissing() throws {
        let status = try XCTUnwrap(RepoGPSService.parseDistributionStatus(Data(#"{"installed":false,"ownership":"managed","current_version":"0.8.1","engine_ready":true,"payload_present":false,"integrity":"unverifiable","repair_required":true,"issue":"Missing executable","path_configured":false,"path_remediation":"export PATH='/Users/tester/.local/bin':\"$PATH\""}"#.utf8)))
        XCTAssertTrue(status.needsRepair)
        XCTAssertEqual(status.primaryAction, .repair)
        XCTAssertEqual(status.issue, "Missing executable")
        XCTAssertEqual(status.pathGuidance, #"export PATH='/Users/tester/.local/bin':"$PATH""#)

        let corrupt = try XCTUnwrap(RepoGPSService.parseDistributionStatus(Data(#"{"installed":true,"ownership":"managed","current_version":"0.8.1","engine_ready":true,"payload_present":true,"integrity":"unverifiable","repair_required":false}"#.utf8)))
        XCTAssertTrue(corrupt.needsRepair)
        XCTAssertEqual(corrupt.primaryAction, .repair)
        let orphaned = try XCTUnwrap(RepoGPSService.parseDistributionStatus(Data(#"{"installed":false,"ownership":"missing","engine_ready":false,"payload_present":true,"repair_required":true}"#.utf8)))
        XCTAssertEqual(orphaned.primaryAction, .repair)
    }

    func testHealthyPayloadAndConfiguredPathDoNotShowRecoveryGuidance() throws {
        let status = try XCTUnwrap(RepoGPSService.parseDistributionStatus(Data(#"{"installed":true,"ownership":"managed","current_version":"0.8.1","engine_ready":true,"payload_present":true,"integrity":"verified","repair_required":false,"path_configured":true,"path_remediation":"stale command"}"#.utf8)))
        XCTAssertFalse(status.needsRepair)
        XCTAssertEqual(status.primaryAction, .maintain)
        XCTAssertNil(status.pathGuidance)
    }

    func testRecoverySelectsMatchingNewerInstalledPayloadAndRefusesDowngrade() {
        let installed = RepoGPSService.PayloadCandidate(payload: URL(fileURLWithPath: "/tmp/versions/0.8.1"), version: "0.8.1", bundled: false)
        let oldBundle = RepoGPSService.PayloadCandidate(payload: URL(fileURLWithPath: "/tmp/app/payload"), version: "0.5.0", bundled: true)
        XCTAssertEqual(RepoGPSService.preferredPayload([oldBundle, installed], currentVersion: "0.8.1"), installed)
        XCTAssertNil(RepoGPSService.preferredPayload([oldBundle], currentVersion: "0.8.1"))
        var sameVersionBundle = oldBundle
        sameVersionBundle.version = "0.8.1"
        XCTAssertEqual(RepoGPSService.preferredPayload([sameVersionBundle, installed], currentVersion: "0.8.1"), installed)
        var newerBundle = oldBundle
        newerBundle.version = "0.8.2"
        XCTAssertEqual(RepoGPSService.preferredPayload([installed, newerBundle], currentVersion: "0.8.1"), newerBundle)
    }

    func testPayloadVerificationRejectsCorruptionVersionMismatchAndSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try makePayload(at: root, version: "0.8.1")
        XCTAssertEqual(RepoGPSService.verifiedPayload(at: root, bundled: false)?.executable, root.appendingPathComponent("bin/rgps"))
        try Data("modified executable".utf8).write(to: root.appendingPathComponent("bin/rgps"))
        XCTAssertNil(RepoGPSService.verifiedPayload(at: root, bundled: false))
        try makePayload(at: root, version: "0.8.1", executableVersion: "0.5.0")
        XCTAssertNil(RepoGPSService.verifiedPayload(at: root, bundled: false))
        try makePayload(at: root, version: "0.8.1")
        let binary = root.appendingPathComponent("bin/rgps")
        let renamed = root.appendingPathComponent("bin/real-rgps")
        try FileManager.default.moveItem(at: binary, to: renamed)
        try FileManager.default.createSymbolicLink(at: binary, withDestinationURL: renamed)
        XCTAssertNil(RepoGPSService.verifiedPayload(at: root, bundled: false))
    }

    @MainActor
    func testRefreshFallsBackToVerifiedBundleAndRepairDoesNotDowngradeDamagedNewerInstall() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".repogps/versions/0.8.1/bin"), withIntermediateDirectories: true)
        try Data(#"{"current_version":"0.8.1"}"#.utf8).write(to: home.appendingPathComponent(".repogps/distribution.json"))
        let bundle = try makeBundle(at: root.appendingPathComponent("Fixture.bundle"))
        let payload = try XCTUnwrap(bundle.resourceURL).appendingPathComponent("RepoGPSPayload")
        let status = #"{"installed":false,"ownership":"managed","current_version":"0.8.1","engine_ready":false,"payload_present":true,"integrity":"unverifiable","repair_required":true,"issue":"Missing executable"}"#
        try makePayload(at: payload, version: "0.5.0", script: "#!/bin/sh\nprintf '%s' '" + status + "'\n")
        let service = RepoGPSService(home: home, bundle: bundle, cliActivator: { nil })
        await service.refresh()
        XCTAssertEqual(service.distribution.currentVersion, "0.8.1")
        XCTAssertEqual(service.distribution.primaryAction, .repair)
        XCTAssertFalse(service.isInstalledAndCompatible)
        await service.repair()
        XCTAssertTrue(service.lastError?.contains("older bundled fallback was not installed") == true)
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".repogps/distribution.json"), encoding: .utf8), #"{"current_version":"0.8.1"}"#)
    }

    @MainActor
    func testMonitoringInvalidatesVerifiedControlWhenExecutableChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let payload = home.appendingPathComponent(".repogps/versions/0.8.1")
        let status = #"{"installed":true,"ownership":"managed","current_version":"0.8.1","engine_ready":true}"#
        try makePayload(at: payload, version: "0.8.1", script: "#!/bin/sh\nprintf '%s' '" + status + "'\n")
        try Data(#"{"current_version":"0.8.1"}"#.utf8).write(to: home.appendingPathComponent(".repogps/distribution.json"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".repogps/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".local/bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".repogps/bin/rgps"), withDestinationURL: payload.appendingPathComponent("bin/rgps"))
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".local/bin/rgps"), withDestinationURL: home.appendingPathComponent(".repogps/bin/rgps"))
        let service = RepoGPSService(home: home, bundle: Bundle(for: Self.self), cliActivator: { nil })
        await service.refresh()
        XCTAssertFalse(service.distribution.needsRepair)
        try Data("#!/bin/sh\ntouch \"$RGPS_HOME/corrupt-executed\"\n".utf8).write(to: payload.appendingPathComponent("bin/rgps"))
        await service.refresh()
        XCTAssertEqual(service.distribution.ownership, "managed")
        XCTAssertTrue(service.distribution.needsRepair)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("corrupt-executed").path))
    }

    @MainActor
    func testCorruptLegacyDirectVersionShimRemainsManagedAndOffersRepair() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let payload = home.appendingPathComponent(".repogps/versions/0.8.1")
        try makePayload(at: payload, version: "0.8.1")
        try Data("corrupted executable".utf8).write(to: payload.appendingPathComponent("bin/rgps"))
        try Data(#"{"current_version":"0.8.1"}"#.utf8).write(to: home.appendingPathComponent(".repogps/distribution.json"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".local/bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".local/bin/rgps"), withDestinationURL: payload.appendingPathComponent("bin/rgps"))
        let service = RepoGPSService(home: home, bundle: Bundle(for: Self.self), cliActivator: { nil })
        await service.refresh()
        XCTAssertEqual(service.distribution.ownership, "managed")
        XCTAssertEqual(service.distribution.currentVersion, "0.8.1")
        XCTAssertTrue(service.distribution.needsRepair)
        XCTAssertEqual(service.distribution.primaryAction, .repair)
    }

    @MainActor
    func testRepairRunsVerifiedInstalledControlWithMatchingPayloadAndIsolatedHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let installedPayload = home.appendingPathComponent(".repogps/versions/0.8.1")
        let status = #"{"installed":true,"ownership":"managed","current_version":"0.8.1","engine_ready":true,"payload_present":true,"integrity":"verified","repair_required":false}"#
        let script = """
        #!/bin/sh
        if [ "$1" = distribution ] && [ "$2" = repair ]; then
          printf '%s\\n' "$@" > "$RGPS_HOME/repair-arguments"
          printf '%s' "$RGPS_HOME" > "$RGPS_HOME/command-home"
        fi
        printf '%s' '\(status)'
        """ + "\n"
        try makePayload(at: installedPayload, version: "0.8.1", script: script)
        try Data(#"{"current_version":"0.8.1"}"#.utf8).write(to: home.appendingPathComponent(".repogps/distribution.json"))
        let service = RepoGPSService(home: home, bundle: Bundle(for: Self.self), cliActivator: { nil })
        await service.repair()
        XCTAssertNil(service.lastError)
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("command-home"), encoding: .utf8), home.path)
        let arguments = try String(contentsOf: home.appendingPathComponent("repair-arguments"), encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(arguments, ["distribution", "repair", "--payload", installedPayload.path, "--json"])
        XCTAssertTrue(service.lastReceipt?.contains("verified installed payload") == true)
    }

    private func makePayload(at root: URL, version: String, executableVersion: String? = nil, script: String = "#!/bin/sh\nexit 0\n") throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let binary = root.appendingPathComponent("bin/rgps")
        let bytes = Data(script.utf8)
        try bytes.write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let manifest: [String: Any] = ["schema_version": 1, "payload_version": version, "repogps_version": executableVersion ?? version,
                                       "files": [["path": "bin/rgps", "sha256": digest, "executable": true]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("payload.json"))
    }

    private func makeBundle(at root: URL) throws -> Bundle {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "dev.slicewrite.repogps.test." + UUID().uuidString, "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: root.appendingPathComponent("Contents/Info.plist"))
        return try XCTUnwrap(Bundle(url: root))
    }

    func testIndependentUpdateContractDecodesSignedFeedStatus() throws {
        let data = Data(#"{"state":"update-available","installed_version":"0.3.0","latest_version":"0.4.0","ownership":"managed","update_available":true,"compatible":true,"feed_url":"https://micah.chat/downloads/repogps-versions.json"}"#.utf8)

        let status = try XCTUnwrap(RepoGPSService.parseUpdateStatus(data))

        XCTAssertEqual(status.state, "update-available")
        XCTAssertEqual(status.installedVersion, "0.3.0")
        XCTAssertEqual(status.latestVersion, "0.4.0")
        XCTAssertEqual(status.ownership, "managed")
        XCTAssertTrue(status.updateAvailable)
        XCTAssertTrue(status.compatible)
        XCTAssertEqual(status.feedURL.absoluteString, "https://micah.chat/downloads/repogps-versions.json")
    }

    func testBundledFallbackComparisonNeverDowngradesManagedRepoGPS() {
        XCTAssertTrue(RepoGPSService.isStableVersion("0.4.0", newerThan: "0.3.0"))
        XCTAssertTrue(RepoGPSService.isStableVersion("0.10.0", newerThan: "0.9.0"))
        XCTAssertFalse(RepoGPSService.isStableVersion("0.4.0", newerThan: "0.4.0"))
        XCTAssertFalse(RepoGPSService.isStableVersion("0.3.0", newerThan: "0.4.0"))
    }

    func testLiveSessionContractDecodesCockpitFields() throws {
        let id = UUID()
        let data = Data("""
        {"active":true,"lease":{"session_id":"\(id.uuidString)","repository":"/tmp/repo","mode":"deep","activity":"tool","started_at":"2026-08-25T20:00:00Z","repogps_version":"0.2.0","behavior_pack_version":"1"},"pending_signals":2,"acknowledged_signals":3}
        """.utf8)
        let status = try XCTUnwrap(RepoGPSService.parseSessionStatus(data))
        XCTAssertTrue(status.active)
        XCTAssertEqual(status.lease?.sessionID, id)
        XCTAssertEqual(status.lease?.mode, "deep")
        XCTAssertEqual(status.lease?.activity, "tool")
        XCTAssertEqual(status.pendingSignals, 2)
        XCTAssertEqual(status.acknowledgedSignals, 3)
    }

    func testLiveSessionContractAcceptsRepoGPSReferenceDateTimestamp() throws {
        let id = UUID()
        let referenceSeconds = 809_401_052.0
        let data = Data("""
        {"active":true,"lease":{"session_id":"\(id.uuidString)","repository":"/tmp/repo","mode":"normal","activity":"idle","started_at":\(referenceSeconds),"repogps_version":"0.2.0","behavior_pack_version":"1"},"pending_signals":0,"acknowledged_signals":0}
        """.utf8)

        let status = try XCTUnwrap(RepoGPSService.parseSessionStatus(data))

        XCTAssertTrue(status.active)
        XCTAssertEqual(status.lease?.sessionID, id)
        XCTAssertEqual(status.lease?.startedAt, Date(timeIntervalSinceReferenceDate: referenceSeconds))
    }
}
