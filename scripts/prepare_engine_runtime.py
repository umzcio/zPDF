#!/usr/bin/env python3
"""Pinned, relocatable macOS arm64 Save helper; downloads are build-time only."""
from pathlib import Path
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
RUNTIME = BUILD / "EngineRuntime"
PYTHON_URL = "https://github.com/astral-sh/python-build-standalone/releases/download/20260901/cpython-3.13.15%2B20260901-aarch64-apple-darwin-install_only_stripped.tar.gz"
PYTHON_SHA = "d3904bd6a072246e07aa0bdadee9a14e80521e42a943c0848059feb16a2816dc"
WHEEL_URL = "https://files.pythonhosted.org/packages/08/99/1fe58428b69d2722dcbcfaa08ce71834a332c5b518fd58874bcef936b823/pypdfium2-5.13.0-py3-none-macosx_13_0_arm64.whl"
WHEEL_SHA = "da5c7b74eebf40b5c1fbe1de01aa1edc8827a79fb1efd999616bc20dcaf77ba4"

def download(name, url, sha):
    path = BUILD / name
    if not path.exists():
        pending = path.with_suffix(".download")
        subprocess.run(["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error", url, "-o", str(pending)], check=True)
        if hashlib.sha256(pending.read_bytes()).hexdigest() != sha:
            pending.unlink()
            raise RuntimeError("Runtime checksum mismatch")
        pending.rename(path)
    if hashlib.sha256(path.read_bytes()).hexdigest() != sha:
        raise RuntimeError("Cached runtime checksum mismatch")
    return path

def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("This Save slice packages macOS arm64 only. Windows is unverified.")
    BUILD.mkdir(exist_ok=True)
    stamp = RUNTIME / ".prepared"
    export_lock = ROOT / "EngineSupport/exporter/wheels.json"
    export_stamp = RUNTIME / ".export-prepared"
    lock_hash = hashlib.sha256(export_lock.read_bytes()).hexdigest()
    transform_lock = ROOT / "EngineSupport/transform-wheels.json"
    transform_stamp = RUNTIME / ".transform-prepared"
    transform_hash = hashlib.sha256(transform_lock.read_bytes()).hexdigest()
    stale = lambda path, expected: path.exists() and path.read_text() != expected
    if not stamp.exists() or stale(export_stamp, lock_hash) or stale(transform_stamp, transform_hash):
        archive = download("save-python.tar.gz", PYTHON_URL, PYTHON_SHA)
        wheel = download("save-pdfium.whl", WHEEL_URL, WHEEL_SHA)
        if RUNTIME.exists():
            shutil.rmtree(RUNTIME)
        RUNTIME.mkdir()
        with tarfile.open(archive) as tar:
            tar.extractall(RUNTIME)
        with zipfile.ZipFile(wheel) as z:
            z.extractall(RUNTIME / "python/lib/python3.13/site-packages")
        # No toolchain/package-manager paths are used by the running app.
        stamp.write_text(json.dumps({"python_sha256": PYTHON_SHA, "pdfium_wheel_sha256": WHEEL_SHA}))
    # Pinned export dependencies share the interpreter/PDFium already shipped.
    if not export_stamp.exists() or export_stamp.read_text() != lock_hash:
        for item in json.loads(export_lock.read_text()):
            wheel = download("export-" + item["url"].rsplit("/", 1)[1], item["url"], item["sha256"])
            with zipfile.ZipFile(wheel) as archive:
                archive.extractall(RUNTIME / "python/lib/python3.13/site-packages")
        export_stamp.write_text(lock_hash)
    # Pinned document-transform dependencies (pikepdf bundles its own libqpdf).
    if not transform_stamp.exists() or transform_stamp.read_text() != transform_hash:
        for item in json.loads(transform_lock.read_text()):
            wheel = download("transform-" + item["url"].rsplit("/", 1)[1], item["url"], item["sha256"])
            with zipfile.ZipFile(wheel) as archive:
                archive.extractall(RUNTIME / "python/lib/python3.13/site-packages")
        transform_stamp.write_text(transform_hash)
    provenance = json.loads((ROOT / "EngineSupport/exporter/provenance.json").read_text())
    for name, expected in provenance["files"].items():
        if hashlib.sha256((ROOT / "EngineSupport/exporter" / name).read_bytes()).hexdigest() != expected:
            raise RuntimeError("Pinned exporter source checksum mismatch: " + name)
    support = RUNTIME / "support"
    if support.exists():
        shutil.rmtree(support)
    shutil.copytree(ROOT / "EngineSupport", support, dirs_exist_ok=True, ignore=shutil.ignore_patterns("__pycache__"))
    helper_entitlements = ROOT / "scripts/engine-helper.entitlements"
    # Signed helpers inherit the app sandbox, including user-selected file access.
    for p in RUNTIME.rglob("*"):
        if not p.is_file() or p.is_symlink():
            continue
        with p.open("rb") as f:
            magic = f.read(4)
        if magic not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):
            continue
        identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"
        args = ["/usr/bin/codesign", "--force", "--sign", identity]
        if identity != "-":
            # Distributable (Developer ID) builds: notarization requires the
            # hardened runtime and a secure timestamp on every nested binary.
            args += ["--options", "runtime", "--timestamp"]
        if p.name in ("python3.13", "qpdf"):
            args += ["--entitlements", str(helper_entitlements)]
        subprocess.run(args + [str(p)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if "TARGET_BUILD_DIR" in os.environ:
        target = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"] / "EngineRuntime"
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            shutil.rmtree(target)
        subprocess.run(["/usr/bin/ditto", str(RUNTIME), str(target)], check=True)
    print("Prepared relocatable Save runtime:", RUNTIME)

if __name__ == "__main__":
    main()
