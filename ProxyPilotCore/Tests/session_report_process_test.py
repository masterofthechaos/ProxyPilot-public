#!/usr/bin/env python3
"""Exercise the actual journal source in independent Swift writer processes.

No package executable or test-only production entry point is needed. Large
synthetic records cross the existing rotation boundary; no owner data is read.
"""
import json
from pathlib import Path
import subprocess
import tempfile


repo = Path(__file__).resolve().parents[2]
source = repo / "ProxyPilotCore/Sources/ProxyPilotCore/Models"
with tempfile.TemporaryDirectory(prefix="proxypilot-journal-process-") as temporary:
    root = Path(temporary)
    main = root / "main.swift"
    main.write_text(r'''
import Foundation
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let mode = CommandLine.arguments[2]
if mode == "read" {
    let events = try SessionReportStore.readEvents(from: url)
    let result: [String: Any] = ["sessions": events.map(\.sessionID),
        "tokens": events.reduce(0) { $0 + $1.record.promptTokens }]
    print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
} else if mode == "reset" {
    try SessionReportStore.reset(at: url)
} else {
    for index in 0..<40 {
        let event = SessionReportEvent(source: "fixture", sessionID: "\(mode)-\(index)",
            record: RequestRecord(model: String(repeating: "m", count: 32_000),
                promptTokens: 3, completionTokens: 2, durationSeconds: 0,
                path: "/fixture", wasStreaming: false))
        try SessionReportStore.append(event, to: url)
    }
}
''')
    executable = root / "journal-fixture"
    subprocess.run(["swiftc", str(source / "RequestRecord.swift"),
                    str(source / "SessionReportStore.swift"), str(main),
                    "-o", str(executable)], check=True)
    journal = root / "report.jsonl"
    writers = [subprocess.Popen([str(executable), str(journal), str(worker)])
               for worker in range(8)]
    last_count = 0
    for _ in range(3):
        snapshot = json.loads(subprocess.check_output([str(executable), str(journal), "read"]))
        assert len(snapshot["sessions"]) >= last_count
        last_count = len(snapshot["sessions"])
    for writer in writers:
        assert writer.wait(timeout=30) == 0
    result = json.loads(subprocess.check_output([str(executable), str(journal), "read"]))
    expected = {f"{worker}-{index}" for worker in range(8) for index in range(40)}
    assert len(result["sessions"]) == len(expected), len(result["sessions"])
    assert set(result["sessions"]) == expected
    assert result["tokens"] == 3 * len(expected)
    assert list(root.glob("report.archive.*.jsonl")), "fixture must exercise rotation"
    for file in root.glob("report*"):
        assert file.stat().st_mode & 0o777 == 0o600, file
    lock = journal.with_suffix(".jsonl.lock")
    lock_inode = lock.stat().st_ino
    subprocess.run([str(executable), str(journal), "reset"], check=True)
    assert lock.stat().st_ino == lock_inode, "reset must preserve the shared lock inode"
    assert not journal.exists() and not list(root.glob("report.archive.*.jsonl"))
    assert json.loads(subprocess.check_output([str(executable), str(journal), "read"]))["sessions"] == []
    print("Journal multiprocess append, rotation, snapshots, totals, permissions and reset passed")
