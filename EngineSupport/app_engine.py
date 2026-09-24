"""App-only adapters; the frozen v0 engine package remains unchanged."""
from itertools import groupby
from pathlib import Path
import json
import tempfile
import os
from engine.errors import require
from engine.session import Engine
from engine.qpdf_adapter import QPDF


class AppQPDF(QPDF):
    def organize(self, primary, entries, output, compression):
        sources = list(dict.fromkeys(path for path, _, _ in entries))
        if len(sources) == 1:
            return self._compose(primary, entries, output, compression)
        # Namespace top-level fields on private serialized snapshots so separate
        # forms cannot become one shared field during a foreign-page import.
        with tempfile.TemporaryDirectory(prefix="zpdf-compose-", dir=Path(output).parent) as tmp:
            mapped = {}
            for number, source in enumerate(sources):
                structure, _ = self.inspect(source)
                acro, _ = structure.catalog()
                objects = {}
                for ref in structure.resolve(acro.get("/Fields", [])):
                    require(isinstance(ref, str), "UNSUPPORTED_OPERATION", "Direct form roots cannot be combined safely.")
                    node = dict(structure.resolve(ref))
                    name = node.get("/T", "u:Field")
                    require(isinstance(name, str) and name.startswith("u:"), "UNSUPPORTED_OPERATION", "Unsupported form field name encoding.")
                    node["/T"] = f"u:zpdf{number + 1}_" + name[2:]
                    objects["obj:" + ref] = {"value": node}
                target = Path(tmp) / f"source-{number}.pdf"
                patch = Path(tmp) / f"fields-{number}.json"
                patch.write_text(json.dumps({"qpdf": [{"jsonversion": 2}, objects]}), encoding="utf-8")
                self.run([source, "--update-from-json=" + str(patch), target])
                mapped[source] = target
            result = self._compose(mapped[primary], [(mapped[path], index, rotation) for path, index, rotation in entries], output, compression)
            self._restore_shared_widgets(entries, output)
            return result

    def _compose(self, primary, entries, output, compression):
        # One --pages source per consecutive document, not one per page.
        # QPDF treats repeated foreign-source arguments as separate imports,
        # which can split a field with widgets on multiple pages.
        args = [primary, "--pages"]
        for path, group in groupby(entries, key=lambda entry: entry[0]):
            args.extend([path, ",".join(str(index + 1) for _, index, _ in group)])
        args.append("--")
        for index, (_, _, rotation) in enumerate(entries, 1):
            if rotation:
                args.append(f"--rotate=+{rotation}:{index}")
        if compression == "lossless":
            args.extend(["--object-streams=generate", "--recompress-flate", "--compression-level=9"])
        diagnostics = self.run(args + [output])[1]
        self._restore_shared_widgets(entries, output)
        return diagnostics

    def _restore_shared_widgets(self, entries, output):
        # A merged field/widget reused on two source pages may be duplicated by
        # QPDF. Reparent those widgets to one terminal field in the candidate.
        # This restores linking, rather than relaxing the engine's validation.
        groups, source_structures = {}, {}
        for out_page, (path, page_index, _) in enumerate(entries):
            if path not in source_structures:
                source_structures[path] = self.inspect(path)[0]
            source = source_structures[path]
            page = source.resolve(source.pages[page_index]["object"])
            for index, ref in enumerate(source.resolve(page.get("/Annots", []))):
                if source.resolve(ref).get("/Subtype") == "/Widget":
                    key, _ = source.field(page_index, index)
                    groups.setdefault((path, key), []).append((out_page, index))
        actual, _ = self.inspect(output)
        acro, _ = actual.catalog()
        roots = list(actual.resolve(acro.get("/Fields", [])))
        objects = {}
        next_id = max([int(k.split(":")[1].split()[0]) for k in actual.objects if k.startswith("obj:")] + [0]) + 1
        for locations in groups.values():
            keys = {actual.field(page, index)[0] for page, index in locations}
            if len(keys) <= 1:
                continue
            require(keys.issubset(set(roots)), "UNSUPPORTED_OPERATION", "Nested shared widgets need unsupported field-tree repair.")
            parent_ref = f"{next_id} 0 R"
            next_id += 1
            first = actual.resolve(next(iter(keys)))
            parent = {key: actual.inherited(first, key) for key in ("/FT", "/T", "/TU", "/TM", "/Ff", "/V", "/DV", "/Opt", "/DA", "/Q") if actual.inherited(first, key) is not None}
            kids = []
            for page, index in locations:
                page_node = actual.resolve(actual.pages[page]["object"])
                ref = actual.resolve(page_node["/Annots"])[index]
                child = dict(actual.resolve(ref))
                for key in ("/FT", "/T", "/TU", "/TM", "/Ff", "/V", "/DV", "/Opt", "/DA", "/Q"):
                    child.pop(key, None)
                child["/Parent"] = parent_ref
                objects["obj:" + ref] = {"value": child}
                kids.append(ref)
            parent["/Kids"] = kids
            objects["obj:" + parent_ref] = {"value": parent}
            roots = [ref for ref in roots if ref not in keys] + [parent_ref]
        if not objects:
            return
        root_ref = actual.objects["trailer"]["value"]["/Root"]
        catalog = dict(actual.resolve(root_ref))
        acro_ref = catalog["/AcroForm"]
        updated_acro = dict(acro, **{"/Fields": roots})
        if isinstance(acro_ref, str):
            objects["obj:" + acro_ref] = {"value": updated_acro}
        else:
            catalog["/AcroForm"] = updated_acro
            objects["obj:" + root_ref] = {"value": catalog}
        with tempfile.TemporaryDirectory(prefix="zpdf-widgets-", dir=Path(output).parent) as tmp:
            patch = Path(tmp) / "fields.json"
            patch.write_text(json.dumps({"qpdf": [{"jsonversion": 2}, objects]}), encoding="utf-8")
            repaired = Path(tmp) / "linked.pdf"
            self.run([output, "--update-from-json=" + str(patch), repaired])
            os.replace(repaired, output)


class AppEngine(Engine):
    @staticmethod
    def _rectangles(data):
        # PDF rectangles permit either pair of opposite corners. PDFium may
        # normalize a foreign annotation on save; compare the same geometric box.
        for annotation in data["annotations"]:
            x1, y1, x2, y2 = annotation["rect"]
            annotation["rect"] = [min(x1, x2), min(y1, y2), max(x1, x2), max(y1, y2)]
        return data

    def _load(self, *args, **kwargs):
        data, policy = super()._load(*args, **kwargs)
        return self._rectangles(data), policy

    def _publish(self, session, candidate, expected, names=True, added=None):
        return super()._publish(session, candidate, self._rectangles(expected), names, added)

    @staticmethod
    def _validate_fill(before, actual, value, expected, prior):
        return Engine._validate_fill(before, actual, value, AppEngine._rectangles(expected), prior)

    @property
    def _qpdf(self):
        if self._qpdf_instance is None:
            self._qpdf_instance = AppQPDF(self._qpdf_bin)
        return self._qpdf_instance

    # Private app transport extension; v0 callers continue to use engine.Engine.
    COMMANDS = Engine.COMMANDS | {"edit_comments", "add_fields", "detect_fields"}

    def _add_fields(self, ref, fields):
        from form_fields import add_fields
        return add_fields(self, ref, fields)

    def _detect_fields(self, ref, page_id):
        from field_detection import detect_fields
        session = self._get(ref)
        from engine import policy
        policy.guard(session.policy)
        return detect_fields(session.path, self._page(session, page_id))

    def _edit_comments(self, ref, edits):
        from copy import deepcopy
        from contextlib import closing
        from engine import pdfium_adapter as pdfium, policy
        from engine.runtime import staging
        session = self._get(ref)
        policy.guard(session.policy)
        require(isinstance(edits, list) and edits, "INVALID_ARGUMENT", "Comment edits are required.")
        structure, _ = self._qpdf.inspect(session.path)
        reply_targets = set()
        for page_info in structure.pages:
            page_node = structure.resolve(page_info["object"])
            for ref_ in structure.resolve(page_node.get("/Annots", [])):
                target = structure.resolve(ref_).get("/IRT")
                if isinstance(target, str):
                    reply_targets.add(target)
        planned, seen, removed = [], set(), set()
        expected = deepcopy(session.raw)
        for edit in edits:
            id_ = edit.get("annotation_id")
            require(isinstance(id_, str) and id_ in session.annotation_ids and id_ not in seen, "STALE_ANNOTATION", "Comment ID is not unique in this revision.")
            seen.add(id_)
            before = session.annotation_ids[id_]
            require(before["type"] in (pdfium.r.FPDF_ANNOT_TEXT, pdfium.r.FPDF_ANNOT_HIGHLIGHT, pdfium.r.FPDF_ANNOT_UNDERLINE), "UNSUPPORTED_OPERATION", "Only notes, highlights and underlines can be edited.")
            value = edit.get("contents")
            require(value is None or isinstance(value, str) and "\0" not in value, "INVALID_ARGUMENT", "Invalid comment text.")
            location = (before["page"], before["index"])
            planned.append((location, value))
            for item in expected["annotations"]:
                if (item["page"], item["index"]) == location:
                    if value is None:
                        removed.add(location)
                    else:
                        item["contents"] = value
            if value is None:
                page = structure.resolve(structure.pages[before["page"]]["object"])
                refs = structure.resolve(page.get("/Annots", []))
                reference = refs[before["index"]]
                require(reference not in reply_targets, "UNSUPPORTED_OPERATION", "Comments with reply threads cannot be deleted yet.")
                popup = structure.resolve(reference).get("/Popup")
                for index, candidate in enumerate(refs):
                    node = structure.resolve(candidate)
                    if candidate == popup or node.get("/Subtype") == "/Popup" and node.get("/Parent") == reference:
                        removed.add((before["page"], index))
        expected["annotations"] = [a for a in expected["annotations"] if (a["page"], a["index"]) not in removed]
        with staging(session.storage.name) as candidate:
            with pdfium.document(session.path) as doc:
                for (page_index, index), value in planned:
                    if value is not None:
                        with closing(doc[page_index]) as page:
                            with pdfium.annotation(page, index) as annotation:
                                pdfium.native(pdfium.r.FPDFAnnot_SetStringValue(annotation, b"Contents", pdfium.wide(value)), "update comment")
                for page_index, index in sorted(removed, reverse=True):
                    with closing(doc[page_index]) as page:
                        pdfium.native(pdfium.r.FPDFPage_RemoveAnnot(page, index), "remove comment")
                pdfium.save(doc, candidate)
            return self._publish(session, candidate, expected)
