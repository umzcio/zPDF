"""Read-only structure inspection and form-aware structural composition."""

import json
import subprocess

from .errors import EngineError, require
from .runtime import qpdf_binary


class QPDF:
    def __init__(self, binary=None):
        self.binary = qpdf_binary(binary)

    def run(self, args, password=None, inspection=False):
        argv = [str(self.binary)]
        if password is not None:
            require("\n" not in password and "\r" not in password,
                    "UNSUPPORTED_OPERATION", "Multiline PDF passwords are unsupported by this bridge.")
            argv.append("--password-file=-")
        try:
            p = subprocess.run(argv + [str(x) for x in args],
                               input=None if password is None else password + "\n",
                               capture_output=True, text=True, encoding="utf-8", errors="replace")
        except OSError as exc:
            raise EngineError("DEPENDENCY_UNAVAILABLE", "QPDF could not be launched.") from exc
        diagnostics = [{"engine": "qpdf", "exit_code": p.returncode, "message": p.stderr}] if p.stderr else []
        if p.returncode not in ((0, 3) if inspection else (0,)):
            raise EngineError("POLICY_INSPECTION_FAILED" if inspection else "VALIDATION_FAILED",
                              "QPDF rejected the candidate or reported structural warnings.", diagnostics)
        return p.stdout, diagnostics

    def inspect(self, path, password=None):
        text, diagnostics = self.run(["--json", "--json-key=qpdf", "--json-key=pages", path],
                                     password, inspection=True)
        try:
            structure = Structure(json.loads(text))
            structure.catalog()
        except (KeyError, TypeError, ValueError, RecursionError) as exc:
            raise EngineError("POLICY_INSPECTION_FAILED", "Invalid QPDF catalog inspection.", diagnostics) from exc
        return structure, diagnostics

    def check(self, path):
        return self.run(["--check", path])[1]

    def organize(self, primary, entries, output, compression):
        args = [primary, "--pages"]
        for path, index, rotation in entries:
            args.extend([path, str(index + 1)])
        args.append("--")
        for output_index, (_, _, rotation) in enumerate(entries, 1):
            if rotation:
                args.append(f"--rotate=+{rotation}:{output_index}")
        if compression == "lossless":
            args.extend(["--object-streams=generate", "--recompress-flate", "--compression-level=9"])
        args.append(output)
        return self.run(args)[1]


class Structure:
    def __init__(self, data):
        self.objects = data["qpdf"][1]
        self.pages = data["pages"]

    def resolve(self, value):
        if isinstance(value, str) and value.endswith(" R"):
            return self.objects["obj:" + value]["value"]
        return value

    def catalog(self):
        trailer = self.objects["trailer"]["value"]
        catalog = self.resolve(trailer["/Root"])
        if not isinstance(catalog, dict) or catalog.get("/Type") != "/Catalog":
            raise ValueError("Missing catalog")
        acro = self.resolve(catalog.get("/AcroForm", {}))
        if not isinstance(acro, dict):
            raise ValueError("Invalid AcroForm")
        return acro, "/Encrypt" in trailer

    def field(self, page_index, annotation_index):
        page = self.resolve(self.pages[page_index]["object"])
        annots = self.resolve(page.get("/Annots", []))
        ref = annots[annotation_index]
        node = self.resolve(ref)
        # A merged field/widget is its own identity; a child widget belongs to
        # its terminal parent. Names are metadata, never grouping keys.
        if "/T" not in node and "/Parent" in node:
            ref = node["/Parent"]
            node = self.resolve(ref)
        require(isinstance(ref, str) and ref.endswith(" R"), "UNSUPPORTED_OPERATION",
                "Direct field dictionaries cannot yet be assigned stable widget locators.")
        return ref, node

    def inherited(self, node, key, default=None):
        seen = set()
        while True:
            if key in node:
                return self.resolve(node[key])
            ref = node.get("/Parent")
            if not ref or ref in seen:
                return default
            seen.add(ref)
            node = self.resolve(ref)
