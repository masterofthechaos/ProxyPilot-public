#!/usr/bin/env python3
"""Offline CLI backup/preview/merge contract; touches only temporary metadata."""
import json
import os
import pathlib
import subprocess
import tempfile
import uuid


binary = pathlib.Path(os.environ.get(
    "PROXYPILOT_BIN", pathlib.Path(__file__).parents[1] / ".build" / "debug" / "proxypilot"
)).resolve()


def event(model="fixture"):
    return {
        "id": str(uuid.uuid4()), "schemaVersion": 2, "source": "repogps", "sessionID": "history-fixture",
        "record": {
            "timestamp": "2026-11-06T12:00:00Z", "model": model,
            "promptTokens": 10, "completionTokens": 1, "durationSeconds": 0.25,
            "path": "/v1/chat/completions", "wasStreaming": False,
            "promptCacheStrategy": "observe", "promptCacheApplied": False,
        },
    }


def invoke(journal, *args, ok=True):
    env = dict(os.environ, PROXYPILOT_SESSION_REPORT_PATH=str(journal))
    result = subprocess.run([str(binary), "sessions", *args, "--json"], env=env, text=True,
                            capture_output=True, timeout=30)
    assert (result.returncode == 0) == ok, (result.returncode, result.stdout, result.stderr)
    payload = json.loads(result.stdout)
    assert payload["ok"] == ok, payload
    return payload


with tempfile.TemporaryDirectory(prefix="proxypilot-history-contract-") as directory:
    root = pathlib.Path(directory)
    source, target, backup = root / "source.jsonl", root / "target.jsonl", root / "history.pphistory"
    old, current = event("old"), event("current")
    # Unknown body fields in a hand-copied journal never escape typed metadata export.
    old["record"]["input"] = "PRIVATE_BODY_MUST_NOT_APPEAR"
    source.write_text(json.dumps(old) + "\n")
    target.write_text(json.dumps(current) + "\n")
    result = invoke(source, "export", "--output", str(backup))["data"]
    assert result["events"] == 1 and result["metadataOnly"] is True
    assert "PRIVATE_BODY_MUST_NOT_APPEAR" not in backup.read_text()
    before = target.read_bytes()
    preview = invoke(target, "import", "--input", str(backup))["data"]
    assert preview["dryRun"] is True and preview["preview"]["newEvents"] == 1
    assert target.read_bytes() == before and not list(root.glob("target.archive.*"))
    dry = invoke(target, "import", "--input", str(backup), "--dry-run", "--yes")["data"]
    assert dry["dryRun"] is True and not list(root.glob("target.archive.*"))
    merged = invoke(target, "import", "--input", str(backup), "--yes")["data"]
    assert merged["dryRun"] is False and merged["preview"]["newEvents"] == 1
    assert target.read_bytes() == before
    archives = list(root.glob("target.archive.*.jsonl"))
    assert len(archives) == 1
    restored = json.loads(archives[0].read_text())
    assert uuid.UUID(restored["id"]) == uuid.UUID(old["id"]) and restored["record"]["promptCacheApplied"] is False
    repeat = invoke(target, "import", "--input", str(backup), "--yes")["data"]["preview"]
    assert repeat["newEvents"] == 0 and repeat["duplicateEvents"] == 1
    assert len(list(root.glob("target.archive.*.jsonl"))) == 1
    backup.write_text(backup.read_text().replace('"completionTokens":1', '"completionTokens":2'))
    invalid = invoke(target, "import", "--input", str(backup), "--dry-run")["data"]
    assert invalid["canImport"] is False and invalid["preview"]["invalidRecords"] > 0
    failure = invoke(target, "import", "--input", str(backup), "--yes", ok=False)
    assert failure["error"]["code"] == "E062" and target.read_bytes() == before

print("History archive CLI contract passed: export, privacy, preview, confirmation, merge, idempotence, corruption rejection.")
