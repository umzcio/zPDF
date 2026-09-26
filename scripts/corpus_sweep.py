"""Robustness sweep: run the engine's everyday operations over a folder of
real-world PDFs and report crashes (unexpected exceptions), hangs and invalid
outputs. Clean refusals (EngineError with a user-facing message) are fine.

The corpus is never committed; point this at any local folder, e.g. Mozilla's
pdf.js test PDFs. Run with a development Python that has the pinned wheels:

    python scripts/corpus_sweep.py build/corpus/pdfjs/test/pdfs --jobs 8
    python scripts/corpus_sweep.py --summary build/corpus/results.jsonl

Each file runs in its own process (all operations in sequence, each on a
fresh copy of the source) with a per-file timeout, so one hang or native crash
can't stop the sweep.
"""
from pathlib import Path
import argparse
import collections
import concurrent.futures as futures
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import traceback

ROOT = Path(__file__).resolve().parents[1]
FILE_TIMEOUT = 240
OP_ORDER = ["facade_save", "page_text", "form_fields", "page_content", "accessibility_check", "watermark",
            "header_footer", "redact_area", "replace_text", "rotate", "duplicate", "crop", "insert_blank",
            "flatten", "sanitize", "encrypt", "sign", "optimize", "pdfa", "autotag"]


def _ops(identity):
    return {
        "watermark": [{"op": "watermark", "text": "SWEEP"}],
        "header_footer": [{"op": "header_footer", "items": {"bottom-center": "Page <<page>> of <<pages>>"}}],
        "redact_area": [{"op": "apply_redactions", "marks": False,
                         "areas": [{"page": 0, "rects": [[40, 40, 320, 320]]}]}],
        "replace_text": [{"op": "replace_text", "find": "e", "replace": "E", "pages": [0]}],
        "rotate": [{"op": "rotate_pages", "pages": [0], "angle": 90}],
        "duplicate": [{"op": "duplicate_pages", "pages": [0]}],
        "crop": [{"op": "crop_pages", "pages": [0], "margins": [10, 10, 10, 10]}],
        "insert_blank": [{"op": "insert_blank_pages", "at": 0}],
        "flatten": [{"op": "flatten_annotations", "include_widgets": True}],
        "sanitize": [{"op": "sanitize"}],
        "encrypt": [{"op": "apply_security", "user_password": "u", "owner_password": "o"}],
        "sign": [{"op": "sign", "identity": identity, "page": 0, "rect": [60, 60, 260, 110], "reason": "Sweep"}],
        "optimize": [{"op": "optimize", "preset": "medium"}],
        "pdfa": [{"op": "convert_pdfa", "level": "2b"}],
        "autotag": [{"op": "autotag"}],
    }


def run_one(path):
    """Child process body: run every operation on `path`; print one JSON line."""
    sys.path.insert(0, str(ROOT / "EngineSupport"))
    import pikepdf
    import transforms
    from transforms import cms
    from engine.errors import EngineError
    from app_engine import AppEngine

    identity = json.loads(os.environ["SWEEP_IDENTITY"])
    source = Path(path)
    record = {"file": source.name, "bytes": source.stat().st_size, "ops": {}}
    try:
        with pikepdf.open(source) as pdf:
            record["pages"] = len(pdf.pages)
            record["producer"] = str(pdf.docinfo.get("/Producer", ""))[:80]
            record["encrypted"] = pdf.is_encrypted
    except Exception as exc:  # unreadable by pikepdf: the app can view it but not edit
        record["unreadable"] = f"{type(exc).__name__}: {str(exc)[:160]}"
        print(json.dumps(record)); return

    def classify(fn):
        start = time.monotonic()
        try:
            fn()
            result = {"status": "ok"}
        except EngineError as exc:
            result = {"status": "refused", "code": exc.code}
        except Exception as exc:
            tb = traceback.extract_tb(exc.__traceback__)
            ours = [f for f in tb if "EngineSupport" in f.filename] or tb
            frame = ours[-1]
            result = {"status": "crash", "error": f"{type(exc).__name__}: {str(exc)[:200]}",
                      "at": f"{frame.filename.split('EngineSupport/')[-1]}:{frame.lineno}",
                      "line": (frame.line or "")[:160]}
        result["seconds"] = round(time.monotonic() - start, 2)
        return result

    with tempfile.TemporaryDirectory(prefix="zpdf-sweep-") as tmp:
        tmp = Path(tmp)
        work = tmp / "source.pdf"
        shutil.copy(source, work)
        progress = Path(os.environ["SWEEP_PROGRESS"])

        def mark(op):
            progress.write_text(op)

        def facade():
            with AppEngine() as engine:
                opened = engine.dispatch("open", path=str(work))
                if not opened["ok"]:
                    raise EngineError(opened["error"]["code"], opened["error"]["message"])
                saved = engine.dispatch("save", ref=opened["result"]["ref"], destination=str(tmp / "facade.pdf"))
                if not saved["ok"]:
                    code = saved["error"]["code"]
                    if code in ("ENGINE_FAILED", "INVALID_ARGUMENT"):
                        raise RuntimeError(f"facade save {code}: {saved['error'].get('message')}")
                    raise EngineError(code, saved["error"]["message"])

        mark("facade_save"); record["ops"]["facade_save"] = classify(facade)
        for name, params in [("page_text", {"pages": [0]}), ("form_fields", {}), ("page_content", {"pages": [0]}),
                             ("accessibility_check", {})]:
            mark(name)
            record["ops"][name] = classify(lambda n=name, p=params: transforms.inspect(work, n, p))
        for name, ops in _ops(identity).items():
            mark(name)
            out = tmp / f"{name}.pdf"
            record["ops"][name] = classify(lambda o=ops, d=out: transforms.run(work, d, o))
    print(json.dumps(record))


def sweep(folder, jobs, results):
    sys.path.insert(0, str(ROOT / "EngineSupport"))
    from transforms import cms
    identity = cms.create_identity("Sweep Signer", key="rsa2048", password="sweep-pass")
    env = dict(os.environ, SWEEP_IDENTITY=json.dumps({"p12": identity["p12"], "password": "sweep-pass"}))
    files = sorted(p for p in Path(folder).rglob("*.pdf") if p.is_file())
    done = set()
    if results.exists():
        done = {json.loads(line)["file"] for line in results.read_text().splitlines() if line.strip()}
    todo = [p for p in files if p.name not in done]
    print(f"{len(files)} PDFs, {len(todo)} to run", flush=True)
    progress_dir = Path(tempfile.mkdtemp(prefix="zpdf-sweep-progress-"))

    def child(path):
        progress = progress_dir / (path.name + ".op")
        try:
            proc = subprocess.run([sys.executable, "-B", __file__, "--one", str(path)], capture_output=True,
                                  text=True, timeout=FILE_TIMEOUT, env=dict(env, SWEEP_PROGRESS=str(progress)),
                                  cwd=str(ROOT))
            line = next((l for l in proc.stdout.splitlines()[::-1] if l.startswith("{")), None)
            if line:
                return line
            op = progress.read_text() if progress.exists() else "?"
            return json.dumps({"file": path.name, "native_crash": {"op": op, "returncode": proc.returncode,
                                                                    "stderr": proc.stderr[-300:]}})
        except subprocess.TimeoutExpired:
            op = progress.read_text() if progress.exists() else "?"
            return json.dumps({"file": path.name, "timeout": {"op": op, "seconds": FILE_TIMEOUT}})

    with open(results, "a") as out, futures.ThreadPoolExecutor(jobs) as pool:
        for n, line in enumerate(pool.map(child, todo), 1):
            out.write(line + "\n"); out.flush()
            if n % 50 == 0:
                print(f"  {n}/{len(todo)}", flush=True)


def summary(results):
    records = [json.loads(l) for l in Path(results).read_text().splitlines() if l.strip()]
    counts = collections.Counter()
    crashes = collections.defaultdict(list)
    for r in records:
        if "unreadable" in r: counts["unreadable"] += 1; continue
        if "timeout" in r: crashes[("TIMEOUT", r["timeout"]["op"], "")].append(r["file"]); continue
        if "native_crash" in r:
            crashes[("NATIVE", r["native_crash"]["op"], str(r["native_crash"]["returncode"]))].append(r["file"]); continue
        for op, res in r["ops"].items():
            counts[res["status"]] += 1
            if res["status"] == "crash":
                crashes[(op, res["error"].split(":")[0], res["at"])].append(r["file"])
    print(f"{len(records)} files; op results: {dict(counts)}")
    print(f"{len(crashes)} distinct crash signatures:")
    for (op, kind, at), files in sorted(crashes.items(), key=lambda kv: -len(kv[1])):
        print(f"  {len(files):4d}  {op:20s} {kind:22s} {at}   e.g. {files[0]}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("folder", nargs="?")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    parser.add_argument("--results", default=str(ROOT / "build/corpus/results.jsonl"))
    parser.add_argument("--one")
    parser.add_argument("--summary")
    args = parser.parse_args()
    if args.one:
        run_one(args.one)
    elif args.summary:
        summary(args.summary)
    else:
        sweep(args.folder, args.jobs, Path(args.results))
        summary(args.results)
