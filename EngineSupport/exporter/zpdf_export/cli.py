"""Standalone coordinator CLI around the export worker.

Owns destination handling: unique staging beside the destination, artifact
validation, explicit overwrite consent, same-filesystem publication, cleanup,
and cancellation ordering. The worker never learns the final destination.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid
import zipfile
from pathlib import Path
from typing import Any

from . import PROTOCOL_VERSION, __version__
from .errors import ExportError

GRACE_SECONDS = 3.0


class CoordinatorError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def parse_pages(spec: str | None, page_count: int) -> list[int]:
    if spec is None or spec.strip().lower() == "all":
        return list(range(1, page_count + 1))
    pages: list[int] = []
    for part in spec.split(","):
        part = part.strip()
        if not part:
            raise CoordinatorError("INVALID_REQUEST", "empty page range element")
        if "-" in part:
            a, _, b = part.partition("-")
            if not (a.strip().isdigit() and b.strip().isdigit()):
                raise CoordinatorError("INVALID_REQUEST", f"bad page range {part!r}")
            lo, hi = int(a), int(b)
            if hi < lo:
                raise CoordinatorError("INVALID_REQUEST", f"descending page range {part!r}")
            pages.extend(range(lo, hi + 1))
        elif part.isdigit():
            pages.append(int(part))
        else:
            raise CoordinatorError("INVALID_REQUEST", f"bad page number {part!r}")
    if not pages or any(p < 1 or p > page_count for p in pages):
        raise CoordinatorError("INVALID_REQUEST", "page out of range")
    if any(b <= a for a, b in zip(pages, pages[1:])):
        raise CoordinatorError("INVALID_REQUEST", "pages must be ascending and unique")
    return pages


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def page_count_of(path: Path) -> int:
    import pypdfium2 as pdfium
    try:
        pdf = pdfium.PdfDocument(str(path))
    except Exception as exc:  # noqa: BLE001
        raise CoordinatorError("BAD_PDF", f"cannot open source: {type(exc).__name__}") from exc
    try:
        return len(pdf)
    finally:
        pdf.close()


class _Stderr:
    """Bounded capture of the worker's stderr."""

    def __init__(self, stream, limit: int = 64 * 1024) -> None:
        self.buf = bytearray()
        self.limit = limit
        self.thread = threading.Thread(target=self._pump, args=(stream,), daemon=True)
        self.thread.start()

    def _pump(self, stream) -> None:
        for chunk in iter(lambda: stream.read(4096), b""):
            if len(self.buf) < self.limit:
                self.buf.extend(chunk[: self.limit - len(self.buf)])

    def text(self) -> str:
        return self.buf.decode("utf-8", "replace")


def convert(args: argparse.Namespace) -> tuple[int, dict[str, Any]]:
    started = time.time()
    source = Path(args.source)
    dest = Path(args.destination)
    if not source.is_file():
        raise CoordinatorError("BAD_PDF", "source file not found")
    if dest.exists() and dest.is_dir():
        raise CoordinatorError("INVALID_REQUEST", "destination is a directory")
    if dest.resolve() == source.resolve() or (dest.exists() and os.path.samefile(dest, source)):
        raise CoordinatorError("DESTINATION_IS_SOURCE", "destination must not be the source PDF")
    if dest.exists() and not args.force:
        raise CoordinatorError("DESTINATION_EXISTS", "destination exists; pass --force to replace it")
    asset_dir = None
    if args.format == "md" and args.md_images == "folder" and not args.no_images:
        asset_dir = dest.parent / f"{dest.stem}_images"      # pictures beside the Markdown, linked relatively
        if asset_dir.exists() and not args.force:
            raise CoordinatorError("DESTINATION_EXISTS", "the picture folder exists; pass --force to replace it")
        if asset_dir.exists() and (asset_dir.is_symlink() or not asset_dir.is_dir()):
            raise CoordinatorError("WRITE_FAILED", "the picture folder path is not a plain directory")
    if not dest.parent.is_dir():
        raise CoordinatorError("WRITE_FAILED", "destination directory does not exist")
    if args.format not in ("docx", "xlsx", "html", "md", "pptx", "rtf", "xml", "epub"):
        raise CoordinatorError("UNSUPPORTED_FORMAT", f"format {args.format!r} is not available")

    source_sha = sha256_file(source)
    pages = parse_pages(args.pages, page_count_of(source))
    options = {
        "include_images": not args.no_images, "include_hyperlinks": not args.no_links,
        "include_form_values": not args.no_form_values, "include_comments": not args.no_comments,
        "running_headers": "preserve", "layout_mode": args.layout, "ocr": "off", "locale": None,
        "allow_partial": bool(args.allow_partial),
    }
    if args.format in ("xlsx", "md", "pptx", "rtf", "xml", "epub"):
        options.pop("layout_mode")          # not applicable to XLSX, Markdown, PPTX, RTF, XML or EPUB
    if args.format == "xml":
        options["xml_images"] = args.xml_images
    if args.format == "pptx":
        options["pptx_mode"] = args.pptx_mode
    if args.format == "md":
        options["markdown_images"] = args.md_images
        if asset_dir is not None:
            options["markdown_asset_folder"] = asset_dir.name
    if args.dump_ir:
        from .ir import to_json
        from .reconstruct import ExportOptions, build_document
        doc = build_document(source, source_sha, pages, ExportOptions(**options))
        Path(args.dump_ir).write_text(to_json(doc))

    staging = dest.parent / f".zpdf-export-{uuid.uuid4().hex}"
    staging.mkdir(mode=0o700)
    job_id = uuid.uuid4().hex
    cancel_requested = threading.Event()
    proc = subprocess.Popen([sys.executable, "-m", "zpdf_export.worker"], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    err_capture = _Stderr(proc.stderr)

    def send(obj: dict) -> None:
        try:
            proc.stdin.write((json.dumps(obj) + "\n").encode("utf-8"))
            proc.stdin.flush()
        except (BrokenPipeError, OSError):
            pass

    def on_sigint(signum, frame):  # noqa: ARG001
        if not cancel_requested.is_set():
            cancel_requested.set()
            send({"protocol_version": PROTOCOL_VERSION, "operation": "cancel", "job_id": job_id})

    previous = signal.signal(signal.SIGINT, on_sigint)
    result: dict[str, Any] | None = None
    try:
        send({"protocol_version": PROTOCOL_VERSION, "operation": "convert", "job_id": job_id,
              "snapshot": {"path": str(source), "sha256": source_sha, "revision_token": "cli"},
              "staging_directory": str(staging), "format": args.format, "pages": pages, "options": options})
        result = _read_until_result(proc, job_id, cancel_requested, args)
        if result is None:
            raise CoordinatorError("WORKER_FAILED", "worker exited without a terminal result")
        status = result.get("status")
        if status == "cancelled":
            return 130, {"status": "cancelled", "job_id": job_id}
        if status == "error":
            err = result.get("error", {"code": "WORKER_FAILED", "message_key": "unknown"})
            return 1, {"status": "error", "error": err, "job_id": job_id}
        artifact = _validate_artifact(staging, result["artifact"])
        if cancel_requested.is_set():
            return 130, {"status": "cancelled", "job_id": job_id}
        # publication gate: re-check destination, then same-filesystem replace
        if dest.exists():
            if os.path.samefile(dest, source):
                raise CoordinatorError("DESTINATION_IS_SOURCE", "destination must not be the source PDF")
            if not args.force:
                raise CoordinatorError("DESTINATION_EXISTS", "destination appeared during conversion")
            if dest.is_symlink():
                raise CoordinatorError("WRITE_FAILED", "destination is a symlink")
        with open(artifact, "rb") as fh:
            os.fsync(fh.fileno())
        files = result["artifact"].get("files") or []
        if files and asset_dir is not None:
            # the picture folder is published first, so the document's links resolve when it appears
            staged = staging / asset_dir.name
            if asset_dir.exists():
                if not args.force:
                    raise CoordinatorError("DESTINATION_EXISTS", "the picture folder appeared during conversion")
                old = staging / ".replaced-pictures"
                os.replace(asset_dir, old)
            os.replace(staged, asset_dir)
        os.replace(artifact, dest)
        summary = {
            "status": status, "destination": str(dest), "job_id": job_id,
            "artifact": result["artifact"], "warnings": result.get("warnings", []),
            "stats": result.get("stats", {}), "backend": result.get("backend"),
            "elapsed_seconds": round(time.time() - started, 3),
        }
        if args.report:
            report_path = Path(args.report)
            report_path.parent.mkdir(parents=True, exist_ok=True)
            report = {**result.get("report", {}), "status": status, "backend": result.get("backend"),
                      "snapshot_sha256": result.get("snapshot_sha256"), "artifact": result["artifact"],
                      "warnings": result.get("warnings", []), "stats": result.get("stats", {}),
                      "elapsed_seconds": summary["elapsed_seconds"], "cli_version": __version__}
            report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
            summary["report"] = str(report_path)
        return 0, summary
    finally:
        signal.signal(signal.SIGINT, previous)
        _shutdown_worker(proc)
        shutil.rmtree(staging, ignore_errors=True)
        if args.verbose:
            text = err_capture.text()
            if text:
                sys.stderr.write(text)


def _read_until_result(proc, job_id: str, cancel_requested: threading.Event, args) -> dict | None:
    cancel_sent_at: float | None = None
    while True:
        if cancel_requested.is_set() and cancel_sent_at is None:
            cancel_sent_at = time.time()
        if cancel_sent_at is not None and time.time() - cancel_sent_at > GRACE_SECONDS:
            proc.kill()
            return {"status": "cancelled", "job_id": job_id, "forced": True}
        line = proc.stdout.readline()
        if not line:
            if cancel_requested.is_set():
                return {"status": "cancelled", "job_id": job_id}
            return None
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        if msg.get("job_id") not in (job_id, None):
            continue
        if msg.get("event") == "progress":
            if not args.quiet:
                sys.stderr.write(f"[{msg['stage']}] {msg['pages_done']}/{msg['pages_total']}\n")
                sys.stderr.flush()
            continue
        if msg.get("event") == "result":
            return msg


def _validate_artifact(staging: Path, artifact: dict) -> Path:
    rel = artifact.get("relative_path")
    if not isinstance(rel, str) or not rel or Path(rel).is_absolute() or ".." in Path(rel).parts:
        raise CoordinatorError("OUTPUT_INVALID", "artifact path escapes staging")
    path = staging / rel
    if path.is_symlink() or not path.is_file():
        raise CoordinatorError("OUTPUT_INVALID", "artifact missing or not a regular file")
    if path.resolve().parent != staging.resolve():
        raise CoordinatorError("OUTPUT_INVALID", "artifact outside staging")
    if sha256_file(path) != artifact.get("sha256") or path.stat().st_size != artifact.get("bytes"):
        raise CoordinatorError("OUTPUT_INVALID", "artifact hash or size mismatch")
    if path.suffix == ".md":
        try:
            path.read_text(encoding="utf-8")
        except UnicodeDecodeError as exc:
            raise CoordinatorError("OUTPUT_INVALID", "artifact is not UTF-8 Markdown") from exc
        for f in artifact.get("files") or []:
            rel = f.get("relative_path", "")
            p = staging / rel
            if Path(rel).is_absolute() or ".." in Path(rel).parts or len(Path(rel).parts) != 2:
                raise CoordinatorError("OUTPUT_INVALID", "picture path escapes staging")
            if p.is_symlink() or not p.is_file() or sha256_file(p) != f.get("sha256") or p.stat().st_size != f.get("bytes"):
                raise CoordinatorError("OUTPUT_INVALID", "picture missing or hash mismatch")
        return path
    if path.suffix == ".xml":
        if not path.read_bytes()[:5] == b"<?xml":
            raise CoordinatorError("OUTPUT_INVALID", "artifact is not an XML document")
        return path
    if path.suffix == ".rtf":
        if not path.read_bytes()[:6] == b"{\\rtf1":
            raise CoordinatorError("OUTPUT_INVALID", "artifact is not an RTF document")
        return path
    if path.suffix == ".html":
        if not path.read_bytes()[:15] == b"<!doctype html>":
            raise CoordinatorError("OUTPUT_INVALID", "artifact is not an HTML document")
        return path
    try:
        with zipfile.ZipFile(path) as z:
            main = {".docx": "word/document.xml", ".xlsx": "xl/workbook.xml",
                    ".pptx": "ppt/presentation.xml", ".epub": "META-INF/container.xml"}.get(path.suffix)
            if z.testzip() is not None or main is None or main not in z.namelist():
                raise CoordinatorError("OUTPUT_INVALID", f"artifact is not a valid {path.suffix[1:].upper()} package")
    except zipfile.BadZipFile as exc:
        raise CoordinatorError("OUTPUT_INVALID", "artifact is not a zip package") from exc
    return path


def _shutdown_worker(proc) -> None:
    try:
        proc.stdin.close()
    except OSError:
        pass
    try:
        proc.wait(timeout=GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def cmd_capabilities(_args) -> tuple[int, dict]:
    proc = subprocess.run([sys.executable, "-m", "zpdf_export.worker"],
                          input=json.dumps({"protocol_version": PROTOCOL_VERSION, "operation": "capabilities"}) + "\n",
                          capture_output=True, text=True, timeout=60)
    line = proc.stdout.splitlines()[0] if proc.stdout else "{}"
    return 0, json.loads(line)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="zpdf-export", description="Local, offline PDF export helper (DOCX, XLSX, HTML, Markdown, PPTX, RTF, XML, EPUB).")
    sub = p.add_subparsers(dest="command", required=True)
    c = sub.add_parser("convert", help="convert a PDF into an editable document")
    c.add_argument("source")
    c.add_argument("destination")
    c.add_argument("--format", default="docx", choices=["docx", "xlsx", "html", "md", "pptx", "rtf", "xml", "epub"])
    c.add_argument("--pages", default=None, help="1-based pages, e.g. 1-3,5 (default: all)")
    c.add_argument("--force", action="store_true", help="replace an existing destination")
    c.add_argument("--md-images", default="folder", choices=["folder", "embed"],
                   help="Markdown pictures: files in <name>_images/ beside the document (default) or data URIs inside it")
    c.add_argument("--xml-images", default="embed", choices=["embed", "omit"],
                   help="XML: pictures as base64 inside the file (default), or described without their pixels")
    c.add_argument("--pptx-mode", default="editable", choices=["editable", "page_image"],
                   help="PPTX: editable shapes and text boxes (default), or the page's drawing as a background picture under editable text")
    c.add_argument("--layout", default="preserve", choices=["preserve", "reflow"],
                   help="preserve: layout-preserving DOCX (default); reflow: explicit reading-order fallback")
    c.add_argument("--no-images", action="store_true")
    c.add_argument("--no-links", action="store_true")
    c.add_argument("--no-form-values", action="store_true")
    c.add_argument("--no-comments", action="store_true")
    c.add_argument("--allow-partial", action="store_true")
    c.add_argument("--report", default=None, help="write a private diagnostic report (no document text)")
    c.add_argument("--dump-ir", default=None, help="write the content-bearing IR JSON (development only)")
    c.add_argument("--json", action="store_true", help="machine-readable summary on stdout")
    c.add_argument("--quiet", action="store_true", help="suppress progress on stderr")
    c.add_argument("--verbose", action="store_true", help="echo the worker's redacted stderr")
    c.set_defaults(func=convert)
    k = sub.add_parser("capabilities", help="print worker capabilities")
    k.set_defaults(func=cmd_capabilities, json=True)
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        code, payload = args.func(args)
    except CoordinatorError as exc:
        code, payload = 1, {"status": "error", "error": {"code": exc.code, "message": exc.message}}
    except ExportError as exc:
        code, payload = 1, {"status": "error", "error": exc.to_dict()}
    if getattr(args, "json", False):
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        _print_human(payload)
    return code


def _print_human(payload: dict) -> None:
    status = payload.get("status")
    if status in ("ok", "ok_with_warnings"):
        print(f"{status}: wrote {payload['destination']}")
        for w in payload.get("warnings", []):
            print(f"  warning {w.get('code')}" + (f" (page {w['page']})" if "page" in w else ""))
    elif status == "cancelled":
        print("cancelled: no output written")
    elif status == "error":
        err = payload.get("error", {})
        print(f"error {err.get('code')}: {err.get('message') or err.get('message_key')}")
    else:
        print(json.dumps(payload, indent=2, sort_keys=True))


if __name__ == "__main__":
    sys.exit(main())
