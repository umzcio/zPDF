#!/usr/bin/env python3
"""Mac changes Windows hasn't caught up with (keeps the two apps from drifting apart).

windows/PARITY.md records the last Mac commit the Windows app was checked against:

    Synced with the Mac app through: <commit>

Every later commit that changes the Mac app (zPDF/, excluding tests) is listed, unless it
also changed windows/ (ported together) or its message says "[mac-only]" (nothing for
Windows to do, e.g. a Mac-specific fix). When the list is handled, move the marker to the
newest Mac commit (``--mark`` does it).

    python3 scripts/parity_drift.py            list; exit 1 if anything is pending
    python3 scripts/parity_drift.py --hook     list as a reminder; always exit 0 (pre-push)
    python3 scripts/parity_drift.py --github   also emit GitHub Actions warnings and a summary
    python3 scripts/parity_drift.py --mark     move the marker to the newest Mac commit
"""
from pathlib import Path
import os
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PARITY = ROOT / "windows" / "PARITY.md"
MARKER = re.compile(r"^Synced with the Mac app through: ([0-9a-f]{7,40})\s*$", re.M)
MAC_PATHS = ["zPDF/"]


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, check=True).stdout


def pending(since):
    rows = []
    for line in git("log", "--no-merges", "--format=%H%x09%s", f"{since}..HEAD", "--", *MAC_PATHS).splitlines():
        sha, subject = line.split("\t", 1)
        body = git("log", "-1", "--format=%B", sha)
        if "[mac-only]" in body.lower():
            continue
        files = git("show", "--name-only", "--format=", sha).split()
        if any(f.startswith("windows/") for f in files):
            continue
        mac = [f for f in files if f.startswith("zPDF/") and not f.startswith("zPDFTests/")]
        if mac:
            rows.append((sha[:9], subject, mac))
    return rows


def main():
    text = PARITY.read_text(encoding="utf-8")
    match = MARKER.search(text)
    if not match:
        print(f"parity: no 'Synced with the Mac app through:' line in {PARITY.relative_to(ROOT)}")
        return 0 if "--hook" in sys.argv else 1
    since = match.group(1)
    if "--mark" in sys.argv:
        newest = git("log", "-1", "--format=%H", "--", *MAC_PATHS).strip()
        PARITY.write_text(MARKER.sub(f"Synced with the Mac app through: {newest}", text, count=1), encoding="utf-8")
        print(f"parity: marker moved to {newest[:9]} (commit windows/PARITY.md)")
        return 0
    rows = pending(since)
    if not rows:
        print("parity: Windows is in step with the Mac app.")
        return 0
    print(f"parity: {len(rows)} Mac change(s) not yet brought to Windows (since {since[:9]}):")
    for sha, subject, files in rows:
        print(f"  {sha}  {subject}")
        for f in files[:4]:
            print(f"             {f}")
        if len(files) > 4:
            print(f"             … {len(files) - 4} more")
    print("  Port each to windows/ (or add it to windows/PARITY.md as [ ]), then run --mark.")
    print("  A change with nothing for Windows: say [mac-only] in its commit message.")
    if "--github" in sys.argv:
        for sha, subject, _ in rows:
            print(f"::warning title=Windows parity::{sha} {subject} — not yet on Windows")
        if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(summary, "a", encoding="utf-8") as out:
                out.write(f"### Windows parity: {len(rows)} Mac change(s) pending\n\n")
                out.writelines(f"- `{sha}` {subject}\n" for sha, subject, _ in rows)
    return 0 if "--hook" in sys.argv or "--github" in sys.argv else 1


if __name__ == "__main__":
    sys.exit(main())
