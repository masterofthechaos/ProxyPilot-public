import ArgumentParser
import Foundation
import ProxyPilotCore

struct SessionsExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "export", abstract: "Back up all session metadata without prompts, outputs, preferences, or keys.")

    @Option(name: .long, help: "Destination for the portable .pphistory backup.")
    var output: String
    @Flag(name: .long, help: "Emit JSON output.")
    var json = false

    mutating func run() async throws {
        do {
            let destination = URL(fileURLWithPath: output)
            let count = try SessionHistoryArchive.export(to: destination)
            OutputFormatter.success(command: "sessions export", data: ExportPayload(output: destination.path, events: count, metadataOnly: true),
                humanMessage: "Exported \(count) metadata records to \(destination.path). Prompts, outputs, preferences and keys are excluded.", json: json)
        } catch {
            OutputFormatter.error(command: "sessions export", code: "E061", message: error.localizedDescription, json: json)
            throw ExitCode.failure
        }
    }
    private struct ExportPayload: Encodable { let output: String; let events: Int; let metadataOnly: Bool }
}

struct SessionsImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "import", abstract: "Preview a history backup, then merge new metadata records with --yes.")

    @Option(name: .long, help: "Portable .pphistory backup to read.")
    var input: String
    @Flag(name: .long, help: "Preview new, duplicate, conflicting and invalid records without importing.")
    var dryRun = false
    @Flag(name: .long, help: "Merge the validated backup. Without this flag, only preview it.")
    var yes = false
    @Flag(name: .long, help: "Emit JSON output.")
    var json = false

    mutating func run() async throws {
        do {
            let previewOnly = dryRun || !yes
            let preview = try SessionHistoryArchive.merge(from: URL(fileURLWithPath: input), dryRun: previewOnly)
            let summary = "\(preview.newEvents) new, \(preview.duplicateEvents) duplicate, \(preview.conflictingEvents) conflicting, \(preview.invalidRecords) invalid records."
            let outcome = previewOnly ? "Preview: \(summary)\nNothing imported.\(preview.canImport ? " Run again with --yes to merge." : " Resolve the conflicts or use a valid backup.")" : "Imported \(preview.newEvents) new records; \(preview.duplicateEvents) duplicates skipped."
            OutputFormatter.success(command: "sessions import", data: ImportPayload(dryRun: previewOnly, canImport: preview.canImport, preview: preview), humanMessage: outcome, json: json)
        } catch {
            OutputFormatter.error(command: "sessions import", code: "E062", message: error.localizedDescription,
                suggestion: "Use --dry-run to inspect the backup. Existing history is preserved if validation fails.", json: json)
            throw ExitCode.failure
        }
    }
    private struct ImportPayload: Encodable { let dryRun: Bool; let canImport: Bool; let preview: SessionHistoryImportPreview }
}
