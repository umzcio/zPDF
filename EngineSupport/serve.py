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
from engine.errors import EngineError
from engine.runtime import WORKER, install, staging

ALLOWED = {"open", "inspect_policy", "fill", "annotate", "organize_pages", "save", "edit_comments", "add_fields", "detect_fields"}

def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()

DOCUMENT_COMMANDS = {"transform", "query", "publish", "crypto"}


def crypto_command(args):
    """Digital-ID helpers that involve no document (app transport only)."""
    import transforms  # noqa: F401  (package path setup)
    from transforms import cms, security
    commands = {"create_identity": cms.create_identity, "inspect_identity": cms.inspect_identity,
                "describe_certificate": cms.describe_certificate,
                "decrypt_certificate_file": security.decrypt_certificate_file}
    name = args["name"]
    if name not in commands:
        raise EngineError("UNSUPPORTED_OPERATION", "Unknown digital ID command.")
    return commands[name](**(args.get("params") or {}))


def document_command(command, args):
    """Stateless file -> file transforms and read-only queries (app transport only)."""
    import transforms
    from pathlib import Path
    try:
        if command == "crypto":
            return {"ok": True, "result": crypto_command(args)}
        source = Path(args["path"])
        expected = args.get("sha256")
        if expected is not None and digest(source) != expected:
            raise EngineError("SOURCE_CHANGED", "The editing revision changed on disk.")
        if command == "transform":
            destination = Path(args["destination"])
            if destination.exists():
                raise EngineError("DESTINATION_EXISTS", "Transform output already exists.")
            result = transforms.run(source, destination, args["ops"], args.get("password"))
        elif command == "query":
            result = transforms.inspect(source, args["name"], args.get("params"), args.get("password"))
        else:
            # Install a finished private candidate at the user's destination.
            destination = Path(args["destination"]).expanduser().resolve()
            overwrite = args.get("overwrite") is True
            with staging(destination.parent) as candidate:
                with open(source, "rb") as src, open(candidate, "wb") as dst:
                    for block in iter(lambda: src.read(1024 * 1024), b""):
                        dst.write(block)
                    dst.flush()
                    os.fsync(dst.fileno())
                sha = digest(candidate)
                if sha != expected:
                    raise EngineError("VALIDATION_FAILED", "The saved copy does not match its candidate.")
                install(candidate, destination, overwrite)
            result = {"sha256": sha, "path": str(destination)}
        return {"ok": True, "result": result}
    except EngineError as exc:
        return {"ok": False, "error": {"code": exc.code, "message": exc.message}}
    except (KeyError, TypeError, ValueError) as exc:
        return {"ok": False, "error": {"code": "INVALID_ARGUMENT", "message": "Invalid document command."}}
    except OSError:
        return {"ok": False, "error": {"code": "IO_ERROR", "message": "A file operation failed; nothing was published."}}
    except Exception as exc:
        import traceback
        return {"ok": False, "error": {"code": "ENGINE_FAILED", "message": "The PDF engine could not complete this operation.",
                                        "detail": type(exc).__name__ + ": " + str(exc)[:300],
                                        "trace": traceback.format_exc()[-1500:] if os.environ.get("ZPDF_DEBUG") else None}}


with Engine() as engine:
    for line in sys.stdin:
        try:
            request = json.loads(line)
            command, args = request["command"], request["parameters"]
            if command in DOCUMENT_COMMANDS:
                response = WORKER.submit(document_command, command, args).result()
                print(json.dumps(response, separators=(",", ":")), flush=True)
                continue
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
