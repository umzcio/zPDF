"""Document-transform regressions. Run with a Python that has the pinned
pikepdf, pypdfium2 and fontTools wheels (the app runtime cannot run outside
the sandbox). Fixtures are copied; sources are never written.

    python scripts/test_transforms.py
"""
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "EngineSupport"))
import pikepdf
import pypdfium2 as pdfium
import transforms
from engine.errors import EngineError

FIXTURES = ROOT / "zPDFTests/Fixtures"


def text_of(path, page=0, password=None):
    doc = pdfium.PdfDocument(str(path), password=password)
    try:
        tp = doc[page].get_textpage()
        return tp.get_text_range()
    finally:
        doc.close()


def blank_pdf(path, pages=1, size=(612, 792), rotate=0):
    pdf = pikepdf.new()
    for _ in range(pages):
        page = pdf.add_blank_page(page_size=size)
        if rotate:
            page.obj.Rotate = rotate
    pdf.save(path)
    return path


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="zpdf-transform-test-")
        self.tmp = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def fixture(self, name):
        target = self.tmp / name
        shutil.copy(FIXTURES / name, target)
        return target

    def run_ops(self, source, ops, password=None, name="out.pdf"):
        out = self.tmp / name
        if out.exists():
            out.unlink()
        result = transforms.run(source, out, ops, password)
        return out, result


class ContentTests(Base):
    def test_watermark_header_footer_bates_background(self):
        src = self.fixture("irs-w9.pdf")
        out, result = self.run_ops(src, [
            {"op": "background", "color": [240, 240, 255]},
            {"op": "watermark", "text": "CONFIDENTIAL", "size": 60, "opacity": 0.2},
            {"op": "header_footer", "items": {"bottom-center": "Page <<page>> of <<pages>>", "top-right": "Draft – ünïcode ✓"}},
            {"op": "bates", "prefix": "ABC", "start": 7, "digits": 5},
        ])
        text = text_of(out)
        self.assertIn("CONFIDENTIAL", text)
        self.assertIn("Page 1 of", text)
        self.assertIn("ünïcode", text)
        self.assertIn("ABC00007", text)
        self.assertEqual(result["results"][3]["first"], "ABC00007")
        # Original content survives underneath.
        self.assertIn("Request for Taxpayer", text)
        # Removal leaves no watermark text.
        out2, _ = self.run_ops(out, [{"op": "remove_overlays", "kind": "Watermark"}], name="out2.pdf")
        self.assertNotIn("CONFIDENTIAL", text_of(out2))
        self.assertIn("ABC00007", text_of(out2))

    def test_rotated_page_header_is_upright(self):
        src = blank_pdf(self.tmp / "rot.pdf", rotate=90)
        out, _ = self.run_ops(src, [{"op": "header_footer", "items": {"top-left": "HEADER"}}])
        doc = pdfium.PdfDocument(str(out))
        page = doc[0]
        tp = page.get_textpage()
        self.assertIn("HEADER", tp.get_text_range())
        # First char box in user space: header at visual top-left of a 90° page
        # maps to the user-space left edge (small x) near the bottom (small y).
        l, b, r, t = tp.get_charbox(0)
        self.assertLess(l, 100)
        self.assertLess(b, 100)
        doc.close()


class AnnotationTests(Base):
    def scratch(self):
        pdf = pikepdf.new()
        pdf.add_blank_page(page_size=(612, 792))
        ap = pikepdf.Stream(pdf, b"1 0 0 RG 2 w 1 1 98 58 re S")
        ap.Type, ap.Subtype, ap.BBox = pikepdf.Name.XObject, pikepdf.Name.Form, [0, 0, 100, 60]
        annot = pdf.make_indirect(pikepdf.Dictionary(Type=pikepdf.Name.Annot, Subtype=pikepdf.Name.Square,
                                                     Rect=[50, 50, 150, 110], C=[1, 0, 0], Contents="box",
                                                     AP=pikepdf.Dictionary(N=pdf.make_indirect(ap)), ZPDFScratchKey="k0"))
        pdf.pages[0].obj.Annots = pikepdf.Array([annot])
        path = self.tmp / "scratch.pdf"
        pdf.save(path)
        return path

    def test_add_update_delete_and_finalize(self):
        src = self.fixture("irs-w9.pdf")
        scratch = self.scratch()
        with pikepdf.open(src) as pdf:
            before = len(pdf.pages[0].obj.get("/Annots", []))
        out, _ = self.run_ops(src, [{"op": "annotations", "scratch": str(scratch),
                                      "items": [{"action": "add", "page": 0, "scratch_page": 0, "scratch_key": "k0"}]}])
        with pikepdf.open(out) as pdf:
            annots = pdf.pages[0].obj.Annots
            self.assertEqual(len(annots), before + 1)
            self.assertEqual(str(annots[-1].Subtype), "/Square")
            self.assertIn("/AP", annots[-1])
        # Update it in place, then delete via marker + finalize.
        out2, _ = self.run_ops(out, [{"op": "annotations", "scratch": str(scratch),
                                       "items": [{"action": "update", "page": 0, "index": before, "subtype": "Square",
                                                  "scratch_page": 0, "scratch_key": "k0"}]}], name="o2.pdf")
        out3, res = self.run_ops(out2, [{"op": "annotations", "scratch": "",
                                          "items": [{"action": "delete", "page": 0, "index": before}]},
                                         {"op": "finalize"}], name="o3.pdf")
        with pikepdf.open(out3) as pdf:
            self.assertEqual(len(pdf.pages[0].obj.get("/Annots", [])), before)
        self.assertEqual(res["results"][1]["removed"], 1)

    def test_stale_index_fails_closed(self):
        src = self.fixture("irs-w9.pdf")
        with self.assertRaises(EngineError) as ctx:
            self.run_ops(src, [{"op": "annotations", "scratch": str(self.scratch()),
                                 "items": [{"action": "delete", "page": 0, "index": 999}]}])
        self.assertEqual(ctx.exception.code, "STALE_ANNOTATION")
        self.assertFalse((self.tmp / "out.pdf").exists())


if __name__ == "__main__":
    unittest.main(verbosity=1)
