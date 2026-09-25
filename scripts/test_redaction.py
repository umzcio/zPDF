"""Redaction and content-interpreter regressions (dev venv; see
EngineSupport/transforms/README.md).

    python scripts/test_redaction.py
"""
from io import BytesIO
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "EngineSupport"))
import pikepdf
from pikepdf import Name
import pypdfium2 as pdfium
import transforms
from engine.errors import EngineError

FIXTURES = ROOT / "zPDFTests/Fixtures"


def text_of(path, page=0):
    doc = pdfium.PdfDocument(str(path))
    try:
        return doc[page].get_textpage().get_text_range()
    finally:
        doc.close()


def char_boxes(path, page=0):
    doc = pdfium.PdfDocument(str(path))
    try:
        tp = doc[page].get_textpage()
        return [(tp.get_text_range(i, 1), tp.get_charbox(i)) for i in range(tp.count_chars())]
    finally:
        doc.close()


def find_box(path, needle, page=0):
    """User-space bbox of the first occurrence of `needle` (PDFium)."""
    doc = pdfium.PdfDocument(str(path))
    try:
        tp = doc[page].get_textpage()
        text = tp.get_text_range()
        start = text.index(needle)
        boxes = [tp.get_charbox(i) for i in range(start, start + len(needle))]
        return [min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes)]
    finally:
        doc.close()


def all_stream_bytes(path):
    out = b""
    with pikepdf.open(path) as pdf:
        for obj in pdf.objects:
            if isinstance(obj, pikepdf.Stream):
                try:
                    out += obj.read_bytes()
                except pikepdf.PdfError:
                    out += obj.read_raw_bytes()
    return out


def helvetica(pdf):
    return pdf.make_indirect(pikepdf.Dictionary(Type=Name.Font, Subtype=Name.Type1, BaseFont=Name.Helvetica,
                                                Encoding=Name.WinAnsiEncoding))


def text_pdf(path, content, pages=1, extra=None):
    pdf = pikepdf.new()
    font = helvetica(pdf)
    for _ in range(pages):
        page = pdf.add_blank_page(page_size=(612, 792))
        page.obj.Resources = pikepdf.Dictionary(Font=pikepdf.Dictionary(F1=font))
        page.obj.Contents = pdf.make_stream(content)
        if extra:
            extra(pdf, page)
    pdf.save(path)
    return path


def rgb_image(pdf, width=100, height=100, jpeg=False):
    from PIL import Image
    image = Image.new("RGB", (width, height), (255, 255, 255))
    if jpeg:
        buffer = BytesIO()
        image.save(buffer, "JPEG", quality=95)
        xobj = pikepdf.Stream(pdf, buffer.getvalue())
        xobj.Filter = Name.DCTDecode
    else:
        xobj = pikepdf.Stream(pdf, zlib.compress(image.tobytes()))
        xobj.Filter = Name.FlateDecode
    xobj.Type, xobj.Subtype = Name.XObject, Name.Image
    xobj.Width, xobj.Height, xobj.ColorSpace, xobj.BitsPerComponent = width, height, Name.DeviceRGB, 8
    return pdf.make_indirect(xobj)


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="zpdf-redact-test-")
        self.tmp = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def fixture(self, name):
        target = self.tmp / name
        shutil.copy(FIXTURES / name, target)
        return target

    def run_ops(self, source, ops, name="out.pdf"):
        out = self.tmp / name
        if out.exists():
            out.unlink()
        result = transforms.run(source, out, ops)
        return out, result


class InterpreterTests(Base):
    def test_glyph_boxes_match_pdfium_on_fixtures(self):
        from transforms.interpret import walk_page
        for name in ("uscis-i9.pdf", "irs-w9.pdf", "export-numeric-table.pdf", "ordinary-edge.pdf"):
            path = FIXTURES / name
            with pikepdf.open(path) as pdf:
                walker = walk_page(pdf, pdf.pages[0])
                ours = [g for g in walker.glyphs if g.text.strip()]
            theirs = [(c, b) for c, b in char_boxes(path) if c.strip()]
            self.assertEqual(len(ours), len(theirs), name)
            outside = 0
            for g, (c, b) in zip(ours, theirs):
                self.assertEqual(g.text[:1], c, name)
                x, y = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
                gb = g.bbox()
                if not (gb[0] - 1 <= x <= gb[2] + 1 and gb[1] - 1 <= y <= gb[3] + 1):
                    outside += 1
            self.assertLessEqual(outside, 2, name)


class RedactionTests(Base):
    def test_text_removed_and_neighbours_keep_positions(self):
        src = text_pdf(self.tmp / "t.pdf", b"BT /F1 14 Tf 72 700 Td (Name: John Secret Smith) Tj 0 -20 Td "
                                           b"[(Kerned) -250 (Secret) 120 (Tail)] TJ ET")
        box = find_box(src, "Secret")
        before = {c: b for c, b in char_boxes(src) if c in "ST"}
        smith_before = find_box(src, "Smith")
        tail_before = find_box(src, "Tail")
        out, result = self.run_ops(src, [{"op": "apply_redactions", "marks": False,
                                          "areas": [{"page": 0, "rects": [box]}]}])
        text = text_of(out)
        self.assertNotIn("Secret", text.split("\n")[0])
        self.assertIn("John", text)
        self.assertIn("Smith", text)
        self.assertEqual(text.count("Secret"), 1)  # second line untouched
        smith_after = find_box(out, "Smith")
        for a, b in zip(smith_before, smith_after):
            self.assertAlmostEqual(a, b, places=1)
        self.assertEqual(result["results"][0]["glyphs"], 6)
        # Second secret, in a TJ with kerning.
        box2 = find_box(out, "Secret")
        out2, _ = self.run_ops(out, [{"op": "apply_redactions", "marks": False,
                                      "areas": [{"page": 0, "rects": [box2], "fill": None}]}], name="o2.pdf")
        self.assertNotIn("Secret", text_of(out2))
        for a, b in zip(tail_before, find_box(out2, "Tail")):
            self.assertAlmostEqual(a, b, places=1)
        self.assertNotIn(b"Secret", all_stream_bytes(out2))

    def test_cid_font_text_and_overlay(self):
        src = blank = self.tmp / "b.pdf"
        pdf = pikepdf.new()
        pdf.add_blank_page(page_size=(612, 792))
        pdf.save(blank)
        out, _ = self.run_ops(src, [{"op": "watermark", "text": "Account 4111 1111 1111 1111 ✓", "angle": 0,
                                     "opacity": 1, "size": 20, "color": [0, 0, 0]}], name="w.pdf")
        # Watermark overlays are app-owned forms; redaction still removes their glyphs.
        box = find_box(out, "4111 1111 1111 1111")
        out2, result = self.run_ops(out, [{"op": "apply_redactions", "marks": False,
                                           "areas": [{"page": 0, "rects": [box], "text": "(b)(6)"}]}], name="r.pdf")
        text = text_of(out2)
        self.assertNotIn("4111", text)
        self.assertIn("Account", text)
        self.assertIn("(b)(6)", text)
        self.assertGreaterEqual(result["results"][0]["glyphs"], 19)

    def test_shared_form_is_copied(self):
        def add_form(pdf, page):
            if not hasattr(add_form, "form"):
                form = pikepdf.Stream(pdf, b"BT /F1 12 Tf 0 0 Td (Shared Secret Text) Tj ET")
                form.Type, form.Subtype, form.BBox = Name.XObject, Name.Form, [0, 0, 300, 50]
                form.Resources = pikepdf.Dictionary(Font=pikepdf.Dictionary(F1=helvetica(pdf)))
                add_form.form = pdf.make_indirect(form)
            page.obj.Resources.XObject = pikepdf.Dictionary(Fm1=add_form.form)
        src = text_pdf(self.tmp / "f.pdf", b"q 1 0 0 1 100 600 cm /Fm1 Do Q", pages=2, extra=add_form)
        box = find_box(src, "Secret")
        out, result = self.run_ops(src, [{"op": "apply_redactions", "marks": False,
                                          "areas": [{"page": 0, "rects": [box]}]}])
        self.assertNotIn("Secret", text_of(out, 0))
        self.assertIn("Shared", text_of(out, 0))
        self.assertIn("Secret", text_of(out, 1))

    def test_image_pixels_blanked_and_original_unreachable(self):
        def add_image(pdf, page):
            page.obj.Resources.XObject = pikepdf.Dictionary(Im1=rgb_image(pdf))
        for jpeg in (False, True):
            def extra(pdf, page, jpeg=jpeg):
                page.obj.Resources.XObject = pikepdf.Dictionary(Im1=rgb_image(pdf, jpeg=jpeg))
            src = text_pdf(self.tmp / f"i{jpeg}.pdf", b"q 200 0 0 200 100 100 cm /Im1 Do Q", extra=extra)
            out, result = self.run_ops(src, [{"op": "apply_redactions", "marks": False,
                                              "areas": [{"page": 0, "rects": [[50, 50, 200, 350]], "fill": None}]}],
                                       name=f"o{jpeg}.pdf")
            self.assertEqual(result["results"][0]["images"], 1)
            with pikepdf.open(out) as pdf:
                xobjects = pdf.pages[0].Resources.XObject
                self.assertNotIn("/Im1", xobjects)
                (name, image), = list(xobjects.items())
                pil = pikepdf.PdfImage(image).as_pil_image().convert("RGB")
                left, right = pil.getpixel((10, 50)), pil.getpixel((90, 50))
                self.assertLess(sum(left), 60, jpeg)
                self.assertGreater(sum(right), 700, jpeg)
                # Column 50 (image x = 200) is on the boundary: covered.
                self.assertLess(sum(pil.getpixel((49, 50))), 60)
            # Rendered: the redacted half is black even without an overlay fill.
            doc = pdfium.PdfDocument(str(out))
            bitmap = doc[0].render(scale=1).to_pil()
            self.assertLess(sum(bitmap.getpixel((120, 792 - 200))[:3]), 60)
            self.assertGreater(sum(bitmap.getpixel((280, 792 - 200))[:3]), 700)
            doc.close()

    def test_image_fully_inside_removed(self):
        def extra(pdf, page):
            page.obj.Resources.XObject = pikepdf.Dictionary(Im1=rgb_image(pdf))
        src = text_pdf(self.tmp / "i.pdf", b"q 100 0 0 100 100 100 cm /Im1 Do Q", extra=extra)
        out, result = self.run_ops(src, [{"op": "apply_redactions", "marks": False,
                                          "areas": [{"page": 0, "rects": [[90, 90, 210, 210]]}]}])
        self.assertEqual(result["results"][0]["images_removed"], 1)
        with pikepdf.open(out) as pdf:
            self.assertNotIn("/Im1", pdf.pages[0].Resources.get("/XObject", {}))

    def test_paths_removed_or_clipped(self):
        src = text_pdf(self.tmp / "p.pdf", b"1 0 0 rg 100 100 50 50 re f 0 0 1 rg 300 300 200 20 re f")
        out, result = self.run_ops(src, [{"op": "apply_redactions", "marks": False,
                                          "areas": [{"page": 0, "rects": [[90, 90, 160, 160], [350, 290, 400, 330]],
                                                     "fill": None}]}])
        r = result["results"][0]
        self.assertEqual(r["paths"], 1)
        self.assertEqual(r["clipped"], 1)
        doc = pdfium.PdfDocument(str(out))
        bitmap = doc[0].render(scale=1).to_pil()
        self.assertEqual(bitmap.getpixel((125, 792 - 125))[:3], (255, 255, 255))   # removed
        self.assertEqual(bitmap.getpixel((375, 792 - 310))[:3], (255, 255, 255))   # clipped away
        self.assertLess(bitmap.getpixel((320, 792 - 310))[0], 50)                  # rest of the bar stays
        doc.close()

    def test_redact_annotations_widgets_and_fields(self):
        src = self.fixture("uscis-i9.pdf")
        with pikepdf.open(src) as pdf:
            page = pdf.pages[0]
            widget = next(a for a in page.Annots if str(a.get("/Subtype")) == "/Widget" and "/T" in a)
            name = str(widget.T)
            rect = [float(v) for v in widget.Rect]
            fields_before = len(list(pdf.Root.AcroForm.Fields))
            mark = pdf.make_indirect(pikepdf.Dictionary(Type=Name.Annot, Subtype=Name.Redact, Rect=rect,
                                                        IC=[0, 0, 0], OverlayText="WITHHELD", DA="/Helv 0 Tf 1 g"))
            page.Annots.append(mark)
            pdf.save(self.tmp / "marked.pdf")
        out, result = self.run_ops(self.tmp / "marked.pdf", [{"op": "apply_redactions"}])
        r = result["results"][0]
        self.assertEqual(r["marks"], 1)
        self.assertGreaterEqual(r["annotations"], 1)
        with pikepdf.open(out) as pdf:
            self.assertFalse(any(str(a.get("/Subtype")) == "/Redact" for a in pdf.pages[0].Annots))
            names = []

            def walk(fields, prefix=""):
                for f in fields:
                    full = prefix + str(f.get("/T", ""))
                    names.append(full)
                    walk(f.get("/Kids", []), full + ".")
            walk(pdf.Root.AcroForm.Fields)
            self.assertFalse(any(n.endswith(name) for n in names))
        self.assertIn("WITHHELD", text_of(out))

    def test_whole_page_and_actualtext(self):
        src = text_pdf(self.tmp / "a.pdf", b"/Span <</ActualText (Hidden Secret)>> BDC BT /F1 12 Tf 72 700 Td "
                                           b"(XXXX) Tj ET EMC BT /F1 12 Tf 72 600 Td (Keep me) Tj ET", pages=2)
        box = [70, 695, 110, 712]
        out, _ = self.run_ops(src, [{"op": "apply_redactions", "marks": False,
                                     "areas": [{"page": 0, "rects": [box]},
                                               {"page": 1, "rects": [[0, 0, 612, 792]], "text": "Page withheld"}]}])
        self.assertNotIn(b"Hidden Secret", all_stream_bytes(out))
        self.assertIn("Keep me", text_of(out, 0))
        self.assertEqual(text_of(out, 1).strip(), "Page withheld")
        with pikepdf.open(out) as pdf:
            self.assertNotIn("/F1", pdf.pages[1].Resources.get("/Font", {}))

    def test_fixture_word_redaction_is_verifiable(self):
        src = self.fixture("irs-w9.pdf")
        box = find_box(src, "Taxpayer")
        before = text_of(src)
        out, _ = self.run_ops(src, [{"op": "apply_redactions", "marks": False,
                                     "areas": [{"page": 0, "rects": [box]}]}])
        after = text_of(out)
        self.assertEqual(before.count("Taxpayer") - 1, after.count("Taxpayer"))
        self.assertIn("Request for", after)
        self.assertIn("Identification Number", after)

    def test_nothing_marked_fails_closed(self):
        src = text_pdf(self.tmp / "n.pdf", b"BT /F1 12 Tf 72 700 Td (x) Tj ET")
        with self.assertRaises(EngineError) as ctx:
            self.run_ops(src, [{"op": "apply_redactions"}])
        self.assertEqual(ctx.exception.code, "NOTHING_TO_REDACT")


class HiddenTextTests(Base):
    def test_invisible_text_removed_by_sanitize(self):
        src = text_pdf(self.tmp / "h.pdf", b"BT /F1 12 Tf 72 700 Td (Visible) Tj 3 Tr 0 -20 Td (Invisible) Tj ET "
                                           b"BT /F1 12 Tf 900 900 Td (Offpage) Tj ET")
        from transforms.interpret import count_hidden_text
        out, result = self.run_ops(src, [{"op": "sanitize", "hidden_text": True}])
        text = text_of(out)
        self.assertIn("Visible", text)
        self.assertNotIn("Invisible", text)
        self.assertNotIn(b"Offpage", all_stream_bytes(out))
        self.assertEqual(result["results"][0]["removed"]["hidden_text"], 16)
        self.assertEqual(transforms.inspect(src, "sanitize_scan")["hidden_text"], 16)


if __name__ == "__main__":
    unittest.main(verbosity=1)
