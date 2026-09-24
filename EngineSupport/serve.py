"""Private Save transport. The vendored facade and its command API are unchanged."""
import hashlib
import json
import sys
import os

# Private macOS app transport only: isolate this helper and its QPDF children.
# This handshake is outside the frozen engine command protocol and is opt-in.
if os.environ.get("ZPDF_HELPER_PROCESS_GROUP") == "1":
    if sys.platform != "darwin":
        raise RuntimeError("Private process-group transport is macOS-only")
    if os.getpgrp() != os.getpid():
        os.setsid()
    print(json.dumps({"transport_ready": True, "pid": os.getpid(), "process_group": os.getpgrp()}), flush=True)

from app_engine import AppEngine as Engine

ALLOWED = {"open", "inspect_policy", "fill", "annotate", "organize_pages", "save", "edit_comments", "add_fields", "detect_fields"}

def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()

with Engine() as engine:
    for line in sys.stdin:
        try:
            request = json.loads(line)
            command, args = request["command"], request["parameters"]
            if command not in ALLOWED:
                raise ValueError("Command outside Save slice")
            before = digest(args["path"]) if command == "open" else None
            response = engine.dispatch(command, **args)
            if command == "open" and response["ok"]:
                if before != digest(args["path"]):
                    response = {"ok": False, "error": {"code": "SOURCE_CHANGED", "message": "Source changed during open."}}
                else:
                    response["transport"] = {"source_sha256": before}
        except Exception:
            response = {"ok": False, "error": {"code": "TRANSPORT_FAILED", "message": "Save helper could not process the request."}}
        print(json.dumps(response, separators=(",", ":")), flush=True)
