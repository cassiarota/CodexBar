#!/usr/bin/env python3
"""Exercise shipped cost commands with synthetic homes; emit no real account or session data."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile


COMMAND = ["cost", "--provider", "codex", "--days", "30", "--refresh",
           "--provider-native-only", "--format", "json"]


def environment(home):
    home.mkdir(parents=True, exist_ok=True)
    return {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(home),
            "CFFIXED_USER_HOME": str(home), "CODEX_HOME": str(home / ".codex"),
            "XDG_CACHE_HOME": str(home / ".cache"), "TZ": "UTC",
            "CODEXBAR_DISABLE_KEYCHAIN_ACCESS": "1", "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1"}


def rollout(home, name, multiplier, archived=False, padding=0):
    day = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=multiplier + 1)).replace(
        hour=12, minute=0, second=0, microsecond=0)
    stamp = day.isoformat().replace("+00:00", "Z")
    directory = home / ".codex" / ("archived_sessions" if archived else "sessions/" + day.strftime("%Y/%m/%d"))
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / ("rollout-" + day.strftime("%Y-%m-%d") + "-" + name + ".jsonl")
    lines = [
        {"type": "session_meta", "timestamp": stamp,
         "payload": {"id": "proof-" + name, "cwd": "/workspace/synthetic"}},
        {"type": "turn_context", "timestamp": stamp, "payload": {"model": "gpt-5"}},
        {"type": "event_msg", "timestamp": stamp, "payload": {"type": "token_count", "info": {
            "total_token_usage": {"input_tokens": 1000 * multiplier, "cached_input_tokens": 0,
                                  "output_tokens": 100 * multiplier, "total_tokens": 1100 * multiplier}}}},
    ]
    with path.open("wb") as output:
        output.write((json.dumps(lines[0]) + "\n").encode())
        if padding:
            output.write(b'{"type":"synthetic_padding","value":"')
            chunk = b"x" * (1024 * 1024)
            for _ in range(padding):
                output.write(chunk)
            output.write(b'"}\n')
        for line in lines[1:]:
            output.write((json.dumps(line) + "\n").encode())
    return path


def compress(path):
    subprocess.run(["zstd", "--quiet", "--force", "--", str(path)], check=True)
    path.unlink()


def database(home):
    return home / "Library/Caches/CodexBar/cost-usage/cost-usage.sqlite"


def pending(home):
    with sqlite3.connect(database(home)) as connection:
        row = connection.execute("SELECT payload FROM scan_metadata WHERE id = 1").fetchone()
        return bool(json.loads(row[0]).get("codexScanCatchUpPending", False)) if row else True


def run(binary, home):
    result = subprocess.run([str(binary), *COMMAND], env=environment(home), check=True,
                            capture_output=True, text=True, timeout=120)
    payload = next(item for item in json.loads(result.stdout) if item["provider"] == "codex")
    assert not payload.get("error"), payload.get("error")
    return {"tokens": payload.get("last30DaysTokens") or 0,
            "costUSD": payload.get("last30DaysCostUSD"),
            "days": len(payload.get("daily", [])),
            "coverageEstablished": payload.get("historyCoverageIsEstablished"),
            "pending": pending(home)}


def converge(binary, home, expected):
    passes = []
    for _ in range(16):
        report = run(binary, home)
        passes.append(report)
        assert report["tokens"] <= expected, "A representation was counted twice"
        if report["tokens"] == expected and not report["pending"]:
            return {"passes": passes, "final": report}
    raise AssertionError("Bounded refreshes did not converge: " + json.dumps(passes))


def ledger_state(home, path):
    with sqlite3.connect(database(home)) as connection:
        row = connection.execute(
            "SELECT id, inode, size, parsed_bytes, anchor_indexed_bytes, anchor_window_start, "
            "anchor_sha256, scan_target_size, scan_complete, session_id FROM files WHERE path = ?",
            (str(path),)).fetchone()
        assert row is not None
        rows = connection.execute("SELECT * FROM usage_rows WHERE file_id = ? ORDER BY row_index", (row[0],)).fetchall()
        snapshots = connection.execute(
            "SELECT * FROM token_snapshots WHERE file_id = ? ORDER BY event_index", (row[0],)).fetchall()
        parser = connection.execute("SELECT value FROM meta WHERE key = 'parser_hash'").fetchone()[0]
    digest = hashlib.sha256(repr((row, rows, snapshots)).encode()).hexdigest()
    return {"inode": database(home).stat().st_ino, "digest": digest, "rows": len(rows),
            "checkpoints": len(snapshots), "parserHash": parser}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--head", type=Path, required=True)
    parser.add_argument("--large", action="store_true", help="Also exceed the CLI's combined decode/parse byte budget")
    args = parser.parse_args()
    args.base, args.head = args.base.resolve(), args.head.resolve()
    proof = {"fixture": "synthetic only", "baseline": "v0.82.0", "command": "codexbar " + " ".join(COMMAND)}
    with tempfile.TemporaryDirectory(prefix="codex-zstd-proof-") as temp:
        root = Path(temp)
        reference = root / "reference"
        for name, factor, archived in [("plain", 1, False), ("active", 2, False), ("archived", 3, True)]:
            rollout(reference, name, factor, archived)
        proof["decompressedReference"] = converge(args.base, reference, 6600)

        mixed = root / "mixed"
        rollout(mixed, "plain", 1)
        compress(rollout(mixed, "active", 2))
        compress(rollout(mixed, "archived", 3, True))
        proof["releasedCompressedOmission"] = run(args.base, mixed)
        assert proof["releasedCompressedOmission"]["tokens"] == 1100
        proof["compressedActiveAndArchived"] = converge(args.head, mixed, 6600)
        assert proof["compressedActiveAndArchived"]["final"] == proof["decompressedReference"]["final"]

        upgrade = root / "upgrade"
        plain = rollout(upgrade, "plain", 1)
        converge(args.base, upgrade, 1100)
        before = ledger_state(upgrade, plain)
        compress(rollout(upgrade, "active", 2))
        compress(rollout(upgrade, "archived", 3, True))
        proof["upgrade"] = converge(args.head, upgrade, 6600)
        after = ledger_state(upgrade, plain)
        assert before["inode"] == after["inode"], "Upgrade rebuilt the database"
        assert before["digest"] == after["digest"], "Upgrade changed existing rows or checkpoints"
        assert before["rows"] > 0 and before["checkpoints"] > 0
        proof["upgrade"].update({"sameDatabaseInode": True, "existingRowsAndCheckpointsUnchanged": True,
                                 "preservedRows": before["rows"], "preservedCheckpoints": before["checkpoints"],
                                 "parserHashBefore": before["parserHash"], "parserHashAfter": after["parserHash"]})
        compress(plain)
        proof["plainToCompressedTransition"] = converge(args.head, upgrade, 6600)
        archived = upgrade / ".codex/archived_sessions" / (plain.name + ".zst")
        plain.with_suffix(plain.suffix + ".zst").rename(archived)
        proof["activeToArchivedTransition"] = converge(args.head, upgrade, 6600)

        if args.large:
            large = root / "large"
            for factor in range(1, 4):
                compress(rollout(large, "large-" + str(factor), factor, factor == 3, padding=96))
            proof["boundedCorpus"] = converge(args.head, large, 6600)
            assert len(proof["boundedCorpus"]["passes"]) > 1, "Fixture did not exercise bounded catch-up"
            proof["boundedCorpus"]["decodedMiB"] = 288
    print(json.dumps(proof, indent=2))


if __name__ == "__main__":
    main()
