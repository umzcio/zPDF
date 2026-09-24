"""Frozen API.md command dispatcher; private snapshots are the sole authority."""

from collections import Counter
from contextlib import ExitStack
from copy import deepcopy
from dataclasses import dataclass, field
from pathlib import Path
import inspect
import json
import os
import shutil
import tempfile
import uuid

from . import pdfium_adapter as pdfium, policy
from .errors import EngineError, require
from .qpdf_adapter import QPDF
from .runtime import WORKER, digest, identity, install, staging


def token():
    return uuid.uuid4().hex


def signature(data, names=True):
    """Compare semantic inventories without transient object numbers or IDs."""
    def encoded(value):
        return json.dumps(value, sort_keys=True)
    fields = []
    for item in data["fields"]:
        f = {k: item[k] for k in ("type", "flags", "value", "options")}
        if names:
            f["name"] = item["name"]
        f["widgets"] = sorted((
            {k: w[k] for k in ("page", "value", "export", "checked")}
            for w in item["widgets"]), key=encoded)
        fields.append(encoded(f))
    annotations = [encoded({k: a[k] for k in ("page", "type", "contents", "rect")})
                   for a in data["annotations"]]
    return data["pages"], Counter(fields), Counter(annotations)


def equivalent(expected, actual, names=True):
    require(signature(expected, names) == signature(actual, names), "VALIDATION_FAILED",
            "Candidate changed unexpected page, field, widget or annotation semantics.")


@dataclass
class Session:
    storage: object
    path: Path
    source: Path
    source_identity: tuple
    password: str | None
    raw: dict
    policy: dict
    document_id: str = field(default_factory=token)
    revision: int = 0
    dirty: bool = False
    cursors: dict = field(default_factory=dict)
    page_ids: dict = field(default_factory=dict)
    field_ids: dict = field(default_factory=dict)
    annotation_ids: dict = field(default_factory=dict)
    view: dict = field(default_factory=dict)

    @property
    def ref(self):
        return {"document_id": self.document_id, "revision": self.revision}

    def refresh(self):
        self.cursors.clear()
        self.page_ids = {token(): p["index"] for p in self.raw["pages"]}
        by_index = {index: id_ for id_, index in self.page_ids.items()}
        pages = [dict(page, id=id_) for id_, page in zip(self.page_ids, self.raw["pages"])]
        self.field_ids = {token(): f for f in self.raw["fields"]}
        fields = []
        for id_, f in self.field_ids.items():
            item = {key: deepcopy(value) for key, value in f.items() if key not in ("key", "widgets", "options")}
            item["id"] = id_
            item["widgets"] = [{**w, "page_id": by_index[w["page"]]} for w in f["widgets"]]
            item["options"] = [{**option, "id": token()} for option in f["options"]]
            fields.append(item)
        self.annotation_ids = {token(): a for a in self.raw["annotations"]}
        annots = [{**a, "id": id_, "page_id": by_index[a["page"]]} for id_, a in self.annotation_ids.items()]
        self.view = {"pages": pages, "fields": fields, "annotations": annots}

    def result(self):
        return deepcopy({**self.view, "ref": self.ref, "policy": self.policy,
                         "dirty": self.dirty, "diagnostics": self.policy["diagnostics"]})


class Engine:
    """Call dispatch(command, **parameters); results/errors are plain data.

    Context-manager cleanup is host lifecycle management, not another command.
    The shared worker serializes every command across every Engine instance.
    """
    COMMANDS = frozenset(("open", "inspect_policy", "render", "search", "annotate",
                          "fill", "organize_pages", "save", "close"))

    def __init__(self, qpdf_bin=None, temp_root=None):
        self._qpdf_bin = qpdf_bin
        self._qpdf_instance = None
        self._temp_root = temp_root
        self._sessions = {}
        self._disposed = False

    @property
    def _qpdf(self):
        if self._qpdf_instance is None:
            self._qpdf_instance = QPDF(self._qpdf_bin)
        return self._qpdf_instance

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        WORKER.submit(self._dispose).result()

    def _dispose(self):
        for session in self._sessions.values():
            session.password = None
            session.storage.cleanup()
        self._sessions.clear()
        self._disposed = True

    def dispatch(self, command, **parameters):
        # Freeze caller-owned data before enqueueing; native handles never cross.
        return WORKER.submit(self._dispatch, command, deepcopy(parameters)).result()

    def _dispatch(self, command, parameters):
        try:
            require(not self._disposed, "DOCUMENT_CLOSED", "Engine host has been disposed.")
            require(isinstance(command, str) and command in self.COMMANDS,
                    "UNSUPPORTED_OPERATION", "Unknown v0 command.")
            method = getattr(self, "_" + command)
            try:
                inspect.signature(method).bind(**parameters)
            except TypeError as exc:
                raise EngineError("INVALID_ARGUMENT", "Arguments do not match the command contract.") from exc
            return {"ok": True, "result": method(**parameters)}
        except EngineError as exc:
            error = {"code": exc.code, "message": exc.message, "diagnostics": exc.diagnostics}
        except (TypeError, ValueError, KeyError, IndexError) as exc:
            error = {"code": "INVALID_ARGUMENT", "message": "Invalid command data.", "diagnostics": []}
        except OSError as exc:
            error = {"code": "IO_ERROR", "message": "File operation failed; no candidate was published.",
                     "diagnostics": [{"errno": exc.errno}]}
        except Exception as exc:
            error = {"code": "ENGINE_FAILED", "message": "Native engine operation failed.",
                     "diagnostics": [{"exception": type(exc).__name__}]}
        if "ref" in parameters:
            error["ref"] = parameters["ref"]
        return {"ok": False, "error": error}

    def _get(self, ref):
        require(isinstance(ref, dict) and isinstance(ref.get("document_id"), str)
                and type(ref.get("revision")) is int, "INVALID_ARGUMENT", "Invalid document reference.")
        session = self._sessions.get(ref["document_id"])
        require(session is not None, "DOCUMENT_CLOSED", "Document is not open.")
        require(session.revision == ref["revision"], "STALE_REVISION", "Document revision has changed.")
        return session

    def _load(self, path, password=None, strict=False):
        if strict:
            self._qpdf.check(path)
        with pdfium.document(path, password) as doc:
            structure, diagnostics = self._qpdf.inspect(path, password)
            verdict = policy.inspect(doc, structure, diagnostics)
            try:
                data = pdfium.inventory(doc, structure)
            except (KeyError, IndexError, TypeError, ValueError) as exc:
                raise EngineError("POLICY_INSPECTION_FAILED", "Unusable field/page structure.") from exc
        return data, verdict

    def _open(self, path, password=None):
        require(password is None or isinstance(password, str), "INVALID_ARGUMENT", "Password must be a string.")
        source = Path(path).expanduser().resolve()
        require(source.is_file(), "NOT_FOUND", "Input PDF does not exist.")
        before = identity(source)
        storage = tempfile.TemporaryDirectory(prefix="zpdf-session-", dir=self._temp_root)
        try:
            snapshot = Path(storage.name) / (token() + ".pdf")
            shutil.copyfile(source, snapshot)
            require(identity(source) == before and digest(snapshot) == before[-1],
                    "SOURCE_CHANGED", "Input changed while opening.")
            data, verdict = self._load(snapshot, password)
            session = Session(storage, snapshot, source, before, password, data, verdict)
            session.refresh()
            self._sessions[session.document_id] = session
            return session.result()
        except BaseException:
            storage.cleanup()
            raise

    def _inspect_policy(self, ref):
        session = self._get(ref)
        return deepcopy({"ref": session.ref, **session.policy})

    def _publish(self, session, candidate, expected, names=True, added=None):
        actual, verdict = self._load(candidate, strict=True)
        policy.guard(verdict)
        equivalent(expected, actual, names)
        old = session.path
        published = Path(session.storage.name) / (token() + ".pdf")
        # Build the complete replacement session before changing the authority.
        next_session = Session(session.storage, published, session.source, session.source_identity,
                               session.password, actual, verdict, session.document_id,
                               session.revision + 1, True)
        next_session.refresh()
        result = next_session.result()
        if added is not None:
            ids = [id_ for id_, a in next_session.annotation_ids.items() if (a["page"], a["index"]) == added]
            require(len(ids) == 1, "VALIDATION_FAILED", "Created annotation was not retained.")
            result["created_annotation_id"] = ids[0]
        os.replace(candidate, published)
        self._sessions[session.document_id] = next_session
        # Failed cleanup is harmless; the session directory owns any leftovers.
        try:
            old.unlink()
        except OSError:
            pass
        return result

    def _fill(self, ref, field_id, value):
        session = self._get(ref)
        policy.guard(session.policy)
        require(isinstance(field_id, str) and field_id in session.field_ids, "NOT_FOUND", "Field ID is not in this revision.")
        selected = session.field_ids[field_id]
        if selected["type"] == pdfium.r.FPDF_FORMFIELD_COMBOBOX:
            public = next(f for f in session.view["fields"] if f["id"] == field_id)
            options = [o for o in public["options"] if o["id"] == value]
            require(len(options) == 1, "INVALID_ARGUMENT", "Dropdown requires an option ID from this revision.")
            value = options[0]["index"]
        plan = pdfium.plan_fill(selected, value)
        structure, _ = self._qpdf.inspect(session.path)
        with staging(session.storage.name) as candidate:
            with pdfium.document(session.path) as doc:
                pdfium.fill(doc, plan)
                expected = pdfium.inventory(doc, structure)
                actual = next(f for f in expected["fields"] if f["key"] == selected["key"])
                self._validate_fill(selected, actual, value, expected, session.raw)
                pdfium.save(doc, candidate)
            return self._publish(session, candidate, expected)

    @staticmethod
    def _validate_fill(before, actual, value, expected, prior):
        typ = before["type"]
        if typ == pdfium.r.FPDF_FORMFIELD_TEXTFIELD:
            ok = all(w["value"] == value for w in actual["widgets"])
        elif typ == pdfium.r.FPDF_FORMFIELD_COMBOBOX:
            export = before["options"][value]["export"]
            ok = all(w["value"] == export for w in actual["widgets"])
        elif typ == pdfium.r.FPDF_FORMFIELD_RADIOBUTTON:
            ok = [w["export"] for w in actual["widgets"] if w["checked"]] == [value]
        else:
            ok = all(w["checked"] == value for w in actual["widgets"])
        require(ok, "VALIDATION_FAILED", "Native form event did not set the requested value.")
        # Every other field, including unrelated same-name fields, stays intact.
        unaffected = deepcopy(expected)
        unaffected["fields"] = [deepcopy(before) if f["key"] == before["key"] else f for f in expected["fields"]]
        equivalent(prior, unaffected)

    def _annotate(self, ref, page_id, annotation):
        session = self._get(ref)
        policy.guard(session.policy)
        index = self._page(session, page_id)
        pdfium.validate_annotation(annotation)
        structure, _ = self._qpdf.inspect(session.path)
        with staging(session.storage.name) as candidate:
            with pdfium.document(session.path) as doc:
                added = pdfium.annotate(doc, index, annotation)
                expected = pdfium.inventory(doc, structure)
                pdfium.save(doc, candidate)
            return self._publish(session, candidate, expected, added=added)

    def _organize_pages(self, ref, pages, compression="none"):
        session = self._get(ref)
        policy.guard(session.policy)
        require(isinstance(pages, list) and pages, "INVALID_ARGUMENT", "Output pages cannot be empty.")
        require(compression in ("none", "lossless"), "INVALID_ARGUMENT", "Unsupported compression mode.")
        seen, sources, selected = set(), {session.document_id: session}, []
        for item in pages:
            source = self._get(item["source_ref"])
            policy.guard(source.policy)
            index = self._page(source, item["page_id"])
            rotation = item.get("rotation_delta", 0)
            require(type(rotation) is int and rotation in (0, 90, 180, 270), "INVALID_ARGUMENT", "Invalid rotation.")
            key = (source.document_id, index)
            require(key not in seen, "INVALID_ARGUMENT", "Duplicate source pages are not supported.")
            seen.add(key)
            sources[source.document_id] = source
            selected.append((source, index, rotation))
        expected = self._composition_expected(selected)
        with ExitStack() as stack:
            snapshots = {}
            # Serialize each pinned revision and close all native handles before
            # launching QPDF. Neither original paths nor unsaved state can leak in.
            for id_, source in sources.items():
                path = stack.enter_context(staging(session.storage.name))
                self._serialize(source, path)
                snapshots[id_] = path
            candidate = stack.enter_context(staging(session.storage.name))
            entries = [(snapshots[s.document_id], index, rotation) for s, index, rotation in selected]
            self._qpdf.organize(snapshots[session.document_id], entries, candidate, compression)
            return self._publish(session, candidate, expected, names=False)

    @staticmethod
    def _composition_expected(selected):
        result = {"pages": [], "fields": [], "annotations": []}
        groups = {}
        for out_index, (source, index, rotation) in enumerate(selected):
            page = deepcopy(source.raw["pages"][index])
            page.update(index=out_index, rotation=(page["rotation"] + rotation) % 360)
            result["pages"].append(page)
            for annot in source.raw["annotations"]:
                if annot["page"] == index:
                    result["annotations"].append({**annot, "page": out_index})
            for f in source.raw["fields"]:
                widgets = [{**w, "page": out_index} for w in f["widgets"] if w["page"] == index]
                if widgets:
                    key = (source.document_id, f["key"])
                    if key not in groups:
                        groups[key] = {**deepcopy(f), "widgets": []}
                    groups[key]["widgets"].extend(widgets)
        result["fields"] = list(groups.values())
        return result

    def _serialize(self, session, path):
        policy.guard(session.policy)
        with pdfium.document(session.path) as doc:
            pdfium.save(doc, path)
        actual, verdict = self._load(path, strict=True)
        policy.guard(verdict)
        equivalent(session.raw, actual)

    def _save(self, ref, destination, overwrite=False):
        session = self._get(ref)
        policy.guard(session.policy)
        require(type(overwrite) is bool, "INVALID_ARGUMENT", "overwrite must be boolean.")
        target = Path(destination).expanduser().resolve()
        # Resolve aliases to the original before replacing it.
        original = target == session.source
        if target.exists() and session.source.exists():
            original = original or target.samefile(session.source)
        def check_source():
            if original:
                try:
                    current = identity(session.source)
                except OSError:
                    current = None
                require(current == session.source_identity, "SOURCE_CHANGED", "Original source changed since open/save.")
        check_source()
        with staging(target.parent) as candidate:
            self._serialize(session, candidate)
            receipt = {"ref": session.ref, "path": str(target), "sha256": digest(candidate),
                       "bytes": candidate.stat().st_size, "diagnostics": [], "dirty": False}
            saved_identity = identity(candidate)
            check_source()
            install(candidate, target, overwrite)
            session.dirty = False
            # Rename/link preserves this identity; no fallible read after commit.
            # Replacing a different hard-link path does not replace the source.
            if target == session.source:
                session.source_identity = saved_identity
            return receipt

    def _close(self, ref, discard_changes=False):
        session = self._get(ref)
        require(type(discard_changes) is bool, "INVALID_ARGUMENT", "discard_changes must be boolean.")
        require(not session.dirty or discard_changes, "UNSAVED_CHANGES", "Document has unsaved changes.")
        session.storage.cleanup()
        session.password = None
        del self._sessions[session.document_id]
        return {"ref": ref, "closed": True}

    @staticmethod
    def _page(session, page_id):
        require(isinstance(page_id, str) and page_id in session.page_ids,
                "NOT_FOUND", "Page ID is not in this revision.")
        return session.page_ids[page_id]

    def _render(self, ref, page_id, scale, clip=None):
        session = self._get(ref)
        index = self._page(session, page_id)
        with pdfium.document(session.path, session.password) as doc:
            result = pdfium.render(doc, index, scale, clip)
        return {**result, "ref": session.ref, "page_id": page_id,
                "limitation": session.policy["rendering_limitation"]}

    def _search(self, ref, query, case_sensitive=False, cursor=None, limit=100):
        session = self._get(ref)
        require(isinstance(query, str) and query and "\0" not in query, "INVALID_ARGUMENT", "Search query must be nonempty text.")
        require(type(case_sensitive) is bool and type(limit) is int and 1 <= limit <= 1000,
                "INVALID_ARGUMENT", "Invalid search options.")
        start = (0, 0)
        if cursor is not None:
            require(isinstance(cursor, str) and cursor in session.cursors,
                    "STALE_REVISION", "Search cursor is not valid for this revision.")
            previous = session.cursors[cursor]
            require(previous[:2] == (query, case_sensitive), "INVALID_ARGUMENT", "Cursor belongs to another query.")
            start = previous[2]
        with pdfium.document(session.path, session.password) as doc:
            hits, continuation = pdfium.search(doc, query, case_sensitive, start, limit)
        page_ids = {index: id_ for id_, index in session.page_ids.items()}
        for hit in hits:
            hit["page_id"] = page_ids[hit.pop("page")]
        next_cursor = None
        if continuation is not None:
            next_cursor = token()
            session.cursors[next_cursor] = (query, case_sensitive, continuation)
        return {"ref": session.ref, "matches": hits, "cursor": next_cursor,
                "complete": continuation is None, "limitation": session.policy["rendering_limitation"]}
