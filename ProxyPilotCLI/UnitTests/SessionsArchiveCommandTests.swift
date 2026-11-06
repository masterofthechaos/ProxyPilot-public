import ArgumentParser
import Testing
@testable import proxypilot

struct SessionsArchiveCommandTests {
    @Test func importRequiresExplicitYesForMutation() throws {
        let preview = try SessionsImportCommand.parse(["--input", "/tmp/history.pphistory", "--json"])
        #expect(!preview.yes && !preview.dryRun && preview.json)
        let apply = try SessionsImportCommand.parse(["--input", "/tmp/history.pphistory", "--yes"])
        #expect(apply.yes && !apply.dryRun)
        let dryRun = try SessionsImportCommand.parse(["--input", "/tmp/history.pphistory", "--yes", "--dry-run"])
        #expect(dryRun.dryRun)
    }
    @Test func archiveCommandsRequireExplicitFilePaths() {
        #expect(throws: (any Error).self) { try SessionsImportCommand.parse([]) }
        #expect(throws: (any Error).self) { try SessionsExportCommand.parse([]) }
    }
}
