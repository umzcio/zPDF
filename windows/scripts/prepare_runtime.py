"""Pinned, relocatable Windows x64 engine runtime for zPDF (build time only).

Mirrors scripts/prepare_engine_runtime.py (macOS): the same CPython release
(python-build-standalone) and package versions, every download checked against
its published SHA-256. Produces windows/build/EngineRuntime:

    python/            CPython 3.13 + the pinned wheels in Lib/site-packages
    support/           EngineSupport (engine, transforms, exporter, serve.py)
    support/engine/native/qpdf.exe (+ DLLs, licenses)   used by the Save facade

Run with any Python 3.9+ on Windows:  py windows\\scripts\\prepare_runtime.py
"""
from pathlib import Path
import hashlib
import json
import shutil
import sys
import tarfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "windows" / "build"
CACHE = BUILD / "downloads"
RUNTIME = BUILD / "EngineRuntime"
PYTHON_URL = ("https://github.com/astral-sh/python-build-standalone/releases/download/20260901/"
              "cpython-3.13.15%2B20260901-x86_64-pc-windows-msvc-install_only_stripped.tar.gz")
PYTHON_SHA = "63d263ab0162f34a241a56dc5b283c22d6e131f5516117e6a921350c69ba7d4f"
QPDF_URL = "https://github.com/qpdf/qpdf/releases/download/v12.4.1/qpdf-12.4.1-msvc64.zip"
QPDF_SHA = "3cd016cd433ef7232e42f4c13348a49cc14907a3c7278ef4f99120593126f7a6"
WHEELS = ROOT / "windows" / "runtime-wheels.json"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def download(url, expected):
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / url.rsplit("/", 1)[1].replace("%2B", "+")
    if not path.exists():
        pending = path.with_name(path.name + ".download")
        with urllib.request.urlopen(url) as response, open(pending, "wb") as out:
            shutil.copyfileobj(response, out)
        if sha256(pending) != expected:
            pending.unlink()
            raise SystemExit(f"Checksum mismatch: {url}")
        pending.replace(path)
    if sha256(path) != expected:
        raise SystemExit(f"Cached download checksum mismatch: {path}")
    return path


def main():
    if sys.platform != "win32":
        raise SystemExit("Run this on Windows (it packages the Windows x64 runtime).")
    if RUNTIME.exists():
        shutil.rmtree(RUNTIME)
    RUNTIME.mkdir(parents=True)
    with tarfile.open(download(PYTHON_URL, PYTHON_SHA)) as tar:
        tar.extractall(RUNTIME, filter="data")
    site = RUNTIME / "python" / "Lib" / "site-packages"
    for item in json.loads(WHEELS.read_text()):
        with zipfile.ZipFile(download(item["url"], item["sha256"])) as wheel:
            wheel.extractall(site)
    # Same pinned exporter sources as the Mac build.
    exporter = ROOT / "EngineSupport" / "exporter"
    for name, expected in json.loads((exporter / "provenance.json").read_text())["files"].items():
        if sha256(exporter / name) != expected:
            raise SystemExit("Pinned exporter source checksum mismatch: " + name)
    support = RUNTIME / "support"
    shutil.copytree(ROOT / "EngineSupport", support, ignore=shutil.ignore_patterns("__pycache__", "native"))
    native = support / "engine" / "native"
    native.mkdir(parents=True)
    with zipfile.ZipFile(download(QPDF_URL, QPDF_SHA)) as archive:
        for member in archive.infolist():
            parts = Path(member.filename).parts
            if member.is_dir() or len(parts) < 3:
                continue
            if parts[1] == "bin" and parts[-1].lower().endswith((".exe", ".dll")):
                target = native / parts[-1]
            elif parts[1] in ("share", "licenses") or parts[-1].upper().startswith(("LICENSE", "NOTICE")):
                target = native / "licenses" / "qpdf" / parts[-1]
            else:
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(member) as src, open(target, "wb") as dst:
                shutil.copyfileobj(src, dst)
    if not (native / "qpdf.exe").is_file():
        raise SystemExit("qpdf.exe was not found in the QPDF release archive.")
    python = RUNTIME / "python" / "python.exe"
    print(f"Prepared Windows engine runtime: {RUNTIME}")
    print(f"  {python}")
    print(f"  {native / 'qpdf.exe'}")


if __name__ == "__main__":
    main()
