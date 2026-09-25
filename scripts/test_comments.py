"""Comment review engine regressions (threads, media, FDF/XFDF, compare).

    python scripts/test_comments.py        # dev venv with the pinned wheels
"""
import base64
import io
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
import wave

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "EngineSupport"))
import pikepdf
from pikepdf import Array, Dictionary, Name
import pypdfium2 as pdfium
import transforms

FIXTURES = ROOT / "zPDFTests/Fixtures"


def wav_bytes(seconds=0.25, rate=8000):
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        frames = bytearray()
        for i in range(int(seconds * rate)):
            value = int(8000 * ((i // 20) % 2 * 2 - 1))
            frames += value.to_bytes(2, "little", signed=True)
        w.writeframes(bytes(frames))
    return out.getvalue()


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="zpdf-comments-test-")
        self.tmp = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def blank(self, name="blank.pdf", pages=2):
        pdf = pikepdf.new()
        for _ in range(pages):
            pdf.add_blank_page(page_size=(612, 792))
        path = self.tmp / name
        pdf.save(path)
        return path

    def run_ops(self, source, ops, name="out.pdf"):
        out = self.tmp / name
        if out.exists():
            out.unlink()
        return out, transforms.run(source, out, ops)

    def scratch(self, annots):
        """A PDFKit-like scratch file: one page whose annots carry scratch keys."""
        pdf = pikepdf.new()
        pdf.add_blank_page(page_size=(612, 792))
        objs = []
        for i, spec in enumerate(annots):
            d = Dictionary(Type=Name.Annot, ZPDFScratchKey=f"k{i}")
            for key, value in spec.items():
                d[Name(key)] = value
            if "/AP" not in d:
                ap = pikepdf.Stream(pdf, b"")  # PDFKit's empty appearance for generic types
                ap.Type, ap.Subtype, ap.BBox = Name.XObject, Name.Form, [0, 0, 0, 0]
                d.AP = Dictionary(N=pdf.make_indirect(ap))
            objs.append(pdf.make_indirect(d))
        pdf.pages[0].obj.Annots = Array(objs)
        path = self.tmp / f"scratch-{len(list(self.tmp.iterdir()))}.pdf"
        pdf.save(path)
        return path

    def annots(self, path, page=0):
        pdf = pikepdf.open(path)
        self.addCleanup(pdf.close)
        return list(pdf.pages[page].obj.get("/Annots", []))


class GraftTests(Base):
    def test_media_spec_threads_and_reply_to_new(self):
        src = self.blank()
        attachment = self.tmp / "notes.txt"
        attachment.write_bytes(b"attached bytes")
        audio = self.tmp / "memo.wav"
        audio.write_bytes(wav_bytes())
        scratch = self.scratch([
            {"/Subtype": Name.FileAttachment, "/Rect": [100, 100, 120, 124], "/Contents": "see file",
             "/ZPDFSpec": json.dumps({"attach": {"path": str(attachment), "name": "notes.txt"}})},
            {"/Subtype": Name.Sound, "/Rect": [200, 100, 220, 120], "/ZPDFSpec": json.dumps({"sound": {"path": str(audio)}})},
            {"/Subtype": Name.Polygon, "/Rect": [300, 300, 400, 400], "/C": [1, 0, 0],
             "/ZPDFSpec": json.dumps({"vertices": [300, 300, 400, 300, 350, 400], "cloudy": 1, "opacity": 0.5,
                                      "intent": "PolygonCloud"}), "/ZPDFCommentID": "parent-1"},
            {"/Subtype": Name.Text, "/Rect": [300, 300, 320, 320], "/Contents": "Accepted",
             "/State": Name.Accepted, "/StateModel": Name.Review, "/ZPDFSpec": json.dumps({"flags": 30})},
            {"/Subtype": Name.Caret, "/Rect": [50, 50, 60, 62], "/Contents": "inserted",
             "/ZPDFSpec": json.dumps({"symbol": "None"})},
        ])
        items = [{"action": "add", "page": 0, "scratch_page": 0, "scratch_key": f"k{i}"} for i in range(5)]
        items[3]["reply_to_comment"] = "parent-1"
        items[4]["reply_to"] = [0, 0]
        items[4]["reply_type"] = "Group"
        out, _ = self.run_ops(src, [{"op": "annotations", "scratch": str(scratch), "items": items}, {"op": "finalize"}])
        fa, snd, poly, status, caret = self.annots(out)
        self.assertEqual(bytes(fa.FS.EF.F.read_bytes()), b"attached bytes")
        self.assertEqual(str(fa.FS.UF), "notes.txt")
        self.assertEqual(int(snd.Sound.R), 8000)
        self.assertEqual(int(snd.Sound.B), 16)
        self.assertGreater(len(poly.AP.N.read_bytes()), 20, "an appearance is generated for a bare polygon")
        self.assertAlmostEqual(float(poly.CA), 0.5)
        self.assertEqual(str(poly.BE.S), "/C")
        self.assertEqual(str(poly.IT), "/PolygonCloud")
        self.assertEqual(status.IRT.objgen, poly.objgen)
        self.assertEqual(str(status.RT), "/R")
        self.assertEqual(int(status.F), 30)
        self.assertEqual(caret.IRT.objgen, fa.objgen)
        self.assertEqual(str(caret.RT), "/Group")
        self.assertEqual(str(caret.Sy), "/None")
        for annot in (fa, snd, poly, status, caret):
            self.assertNotIn("/ZPDFSpec", annot)
            self.assertNotIn("/ZPDFCommentID", annot)
        info = transforms.inspect(out, "comment_threads")
        page = info["pages"][0]
        self.assertEqual(page[3]["irt"], [0, 2])
        self.assertEqual(page[3]["state"], "Accepted")
        self.assertEqual(page[0]["file_name"], "notes.txt")
        self.assertAlmostEqual(page[1]["duration"], 0.25, places=2)
        # Media queries round-trip.
        data = transforms.inspect(out, "comment_attachment", {"page": 0, "index": 0})
        self.assertEqual(base64.b64decode(data["data"]), b"attached bytes")
        wav = base64.b64decode(transforms.inspect(out, "comment_sound", {"page": 0, "index": 1})["wav"])
        with wave.open(io.BytesIO(wav)) as w:
            self.assertEqual(w.getframerate(), 8000)
            self.assertEqual(w.getnframes(), 2000)
            original = wave.open(io.BytesIO(wav_bytes()))
            self.assertEqual(w.readframes(10), original.readframes(10))

    def test_update_keeps_media_and_moves_vertices(self):
        src = self.blank()
        attachment = self.tmp / "a.bin"
        attachment.write_bytes(b"\x00\x01payload")
        scratch = self.scratch([
            {"/Subtype": Name.FileAttachment, "/Rect": [100, 100, 120, 120],
             "/ZPDFSpec": json.dumps({"attach": {"path": str(attachment), "name": "a.bin"}})},
            {"/Subtype": Name.Polygon, "/Rect": [300, 300, 400, 400], "/ZPDFSpec": json.dumps({"vertices": [300, 300, 400, 300, 350, 400]})},
        ])
        out, _ = self.run_ops(src, [{"op": "annotations", "scratch": str(scratch), "items": [
            {"action": "add", "page": 0, "scratch_page": 0, "scratch_key": "k0"},
            {"action": "add", "page": 0, "scratch_page": 0, "scratch_key": "k1"}]}, {"op": "finalize"}])
        ap_before = self.annots(out)[1].AP.N.read_bytes()
        # PDFKit's rewrite of a moved attachment: empty EF, empty appearance.
        moved = self.scratch([
            {"/Subtype": Name.FileAttachment, "/Rect": [100, 200, 120, 220],
             "/FS": Dictionary(Type=Name.Filespec, F="a.bin", EF=Dictionary())},
            {"/Subtype": Name.Polygon, "/Rect": [310, 300, 410, 400], "/Vertices": [300, 300, 400, 300, 350, 400]},
        ])
        out2, _ = self.run_ops(out, [{"op": "annotations", "scratch": str(moved), "items": [
            {"action": "update", "page": 0, "index": 0, "subtype": "FileAttachment", "scratch_page": 0, "scratch_key": "k0"},
            {"action": "update", "page": 0, "index": 1, "subtype": "Polygon", "scratch_page": 0, "scratch_key": "k1"}]},
            {"op": "finalize"}], name="out2.pdf")
        fa, poly = self.annots(out2)
        self.assertEqual([float(v) for v in fa.Rect], [100, 200, 120, 220])
        self.assertEqual(fa.FS.EF.F.read_bytes(), b"\x00\x01payload")
        self.assertEqual([float(v) for v in poly.Vertices], [310, 300, 410, 300, 360, 400])
        self.assertEqual(poly.AP.N.read_bytes(), ap_before)

    def test_unknown_reply_parent_fails_closed(self):
        src = self.blank()
        scratch = self.scratch([{"/Subtype": Name.Text, "/Rect": [0, 0, 20, 20]}])
        with self.assertRaises(transforms.EngineError):
            self.run_ops(src, [{"op": "annotations", "scratch": str(scratch), "items": [
                {"action": "add", "page": 0, "scratch_page": 0, "scratch_key": "k0", "reply_to_comment": "missing"}]}])


class InterchangeTests(Base):
    def commented(self):
        src = self.blank()
        attachment = self.tmp / "data.csv"
        attachment.write_bytes(b"a,b\n1,2\n")
        scratch = self.scratch([
            {"/Subtype": Name.Text, "/Rect": [50, 700, 70, 720], "/Contents": "Top note", "/T": "Ana", "/C": [1, 1, 0],
             "/NM": "note-1", "/ZPDFCommentID": "n1"},
            {"/Subtype": Name.Text, "/Rect": [50, 700, 70, 720], "/Contents": "A reply", "/T": "Ben"},
            {"/Subtype": Name.Square, "/Rect": [100, 100, 200, 160], "/C": [0, 0, 1], "/IC": [1, 0, 0],
             "/BS": Dictionary(W=3, S=Name.D, D=[4, 2]), "/Contents": "Box"},
            {"/Subtype": Name.Ink, "/Rect": [300, 300, 360, 360], "/InkList": [[300, 300, 330, 350, 360, 310]], "/C": [0, 0.5, 0]},
            {"/Subtype": Name.Highlight, "/Rect": [100, 400, 300, 420], "/QuadPoints": [100, 420, 300, 420, 100, 400, 300, 400],
             "/C": [1, 1, 0], "/Contents": "hl"},
            {"/Subtype": Name.FreeText, "/Rect": [100, 500, 300, 560], "/Contents": "Callout text", "/DA": "/Helv 12 Tf 0 0 1 rg",
             "/ZPDFSpec": json.dumps({"callout": [60, 450, 80, 500, 100, 530], "intent": "FreeTextCallout"})},
            {"/Subtype": Name.FileAttachment, "/Rect": [400, 100, 420, 120],
             "/ZPDFSpec": json.dumps({"attach": {"path": str(attachment), "name": "data.csv"}})},
            {"/Subtype": Name.Stamp, "/Rect": [400, 600, 550, 650], "/Name": Name.Approved},
        ])
        items = [{"action": "add", "page": 0, "scratch_page": 0, "scratch_key": f"k{i}"} for i in range(8)]
        items[1]["reply_to_comment"] = "n1"
        out, _ = self.run_ops(src, [{"op": "annotations", "scratch": str(scratch), "items": items}, {"op": "finalize"}],
                              name="commented.pdf")
        return out

    def check_imported(self, path, expect_media=True):
        annots = self.annots(path)
        subtypes = [str(a.Subtype) for a in annots]
        self.assertEqual(subtypes.count("/Text"), 2)
        for kind in ("/Square", "/Ink", "/Highlight", "/FreeText", "/Stamp"):
            self.assertIn(kind, subtypes)
        reply = next(a for a in annots if str(a.get("/Contents", "")) == "A reply")
        self.assertEqual(str(reply.IRT.Contents), "Top note")
        for a in annots:
            self.assertIn("/AP", a, f"{a.Subtype} has an appearance")
        if expect_media:
            fa = next(a for a in annots if str(a.Subtype) == "/FileAttachment")
            self.assertEqual(fa.FS.EF.F.read_bytes(), b"a,b\n1,2\n")
        square = next(a for a in annots if str(a.Subtype) == "/Square")
        self.assertEqual(float(square.BS.W), 3)

    def test_xfdf_round_trip(self):
        src = self.commented()
        exported = transforms.inspect(src, "export_comments", {"format": "xfdf", "file_name": "commented.pdf"})
        self.assertEqual(exported["count"], 8)
        self.assertIn('inreplyto="note-1"', exported["text"])
        xfdf = self.tmp / "c.xfdf"
        xfdf.write_text(exported["text"], encoding="utf-8")
        target = self.blank("target.pdf")
        out, result = self.run_ops(target, [{"op": "import_comments", "path": str(xfdf)}], name="imported.pdf")
        self.assertEqual(result["results"][0]["added"], 8)
        self.check_imported(out)
        free = next(a for a in self.annots(out) if str(a.Subtype) == "/FreeText")
        self.assertEqual(len(free.CL), 6)
        # Importing again is idempotent: named comments are skipped.
        out2, result2 = self.run_ops(out, [{"op": "import_comments", "path": str(xfdf)}], name="again.pdf")
        self.assertEqual(result2["results"][0]["added"], 0)
        # PDFium renders the imported page.
        doc = pdfium.PdfDocument(str(out))
        doc[0].render(draw_annots=True)
        doc.close()

    def test_fdf_round_trip_and_pdf_import(self):
        src = self.commented()
        exported = transforms.inspect(src, "export_comments", {"format": "fdf", "file_name": "commented.pdf"})
        data = base64.b64decode(exported["data"])
        self.assertTrue(data.startswith(b"%FDF-1.2"))
        fdf = self.tmp / "c.fdf"
        fdf.write_bytes(data)
        out, result = self.run_ops(self.blank("t1.pdf"), [{"op": "import_comments", "path": str(fdf)}], name="fdf-in.pdf")
        self.assertEqual(result["results"][0]["added"], 8)
        self.check_imported(out)
        out2, result2 = self.run_ops(self.blank("t2.pdf"), [{"op": "import_comments", "path": str(src)}], name="pdf-in.pdf")
        self.assertEqual(result2["results"][0]["added"], 8)
        self.check_imported(out2)

    def test_compare_and_flatten(self):
        src = self.commented()
        # Edit a copy: change one comment, remove one, add one.
        changed = self.tmp / "changed.pdf"
        with pikepdf.open(src) as pdf:
            annots = pdf.pages[0].obj.Annots
            square = next(a for a in annots if str(a.Subtype) == "/Square")
            square.Contents = pikepdf.String("Box (revised)")
            kept = [a for a in annots if str(a.Subtype) != "/Ink"]
            new = pdf.make_indirect(Dictionary(Type=Name.Annot, Subtype=Name.Text, Rect=[10, 10, 30, 30], Contents="New one"))
            kept.append(new)
            pdf.pages[0].obj.Annots = Array(kept)
            pdf.save(changed)
        diff = transforms.inspect(changed, "compare_comments", {"other": str(src)})
        self.assertEqual([c["contents"] for c in diff["added"]], ["New one"])
        self.assertEqual([c["subtype"] for c in diff["removed"]], ["Ink"])
        self.assertEqual(len(diff["changed"]), 1)
        self.assertIn("contents", diff["changed"][0]["changes"])
        self.assertEqual(diff["changed"][0]["before"]["contents"], "Box")
        out, result = self.run_ops(src, [{"op": "flatten_annotations"}], name="flat.pdf")
        self.assertGreaterEqual(result["results"][0]["flattened"], 7)
        remaining = [str(a.Subtype) for a in self.annots(out)]
        self.assertFalse(any(s in remaining for s in ("/Square", "/Ink", "/Highlight", "/FreeText", "/Stamp")))


if __name__ == "__main__":
    unittest.main(verbosity=1)
