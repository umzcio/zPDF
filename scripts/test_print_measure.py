"""Print imposition and measuring regressions (dev venv with the pinned wheels).

    python scripts/test_print_measure.py
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


def numbered_pdf(path, pages=6, size=(612, 792), rotate=0):
    """Pages showing a large 'P<n>' label at their visual centre."""
    pdf = pikepdf.new()
    font = pdf.make_indirect(pikepdf.Dictionary(Type=pikepdf.Name.Font, Subtype=pikepdf.Name.Type1,
                                                BaseFont=pikepdf.Name.Helvetica))
    for n in range(1, pages + 1):
        page = pdf.add_blank_page(page_size=size)
        page.obj.Resources = pikepdf.Dictionary(Font=pikepdf.Dictionary(F1=font))
        text = f"BT /F1 48 Tf {size[0] / 2 - 40} {size[1] / 2} Td (P{n}) Tj ET 0 0 1 RG 4 w 10 10 {size[0] - 20} {size[1] - 20} re S"
        page.obj.Contents = pdf.make_indirect(pikepdf.Stream(pdf, text.encode()))
        if rotate:
            page.obj.Rotate = rotate
    pdf.save(path)
    return path


def text_boxes(path, page=0):
    """{word: (cx, cy)} for words starting with 'P' followed by digits."""
    doc = pdfium.PdfDocument(str(path))
    try:
        tp = doc[page].get_textpage()
        text = tp.get_text_range()
        found = {}
        i = 0
        while i < len(text):
            if text[i] == "P" and i + 1 < len(text) and text[i + 1].isdigit():
                j = i + 1
                while j < len(text) and text[j].isdigit():
                    j += 1
                l, b, r, t = tp.get_charbox(i)
                found[text[i:j]] = ((l + r) / 2, (b + t) / 2)
                i = j
            else:
                i += 1
        return found, text
    finally:
        doc.close()


def render_nonwhite(path, page, rect, scale=1.0):
    doc = pdfium.PdfDocument(str(path))
    try:
        p = doc[page]
        image = p.render(scale=scale, may_draw_forms=True).to_pil().convert("RGB")
        height = p.get_height()
        l, b, r, t = rect
        crop = image.crop((int(l * scale), int((height - t) * scale), int(r * scale), int((height - b) * scale)))
        data = crop.tobytes()
        return sum(1 for i in range(0, len(data), 3) if data[i:i + 3] != b"\xff\xff\xff")
    finally:
        doc.close()


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="zpdf-print-test-")
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
        return out, transforms.run(source, out, ops)


class PrintPrepareTests(Base):
    def square_doc(self, flags=4):
        pdf = pikepdf.new()
        pdf.add_blank_page(page_size=(612, 792))
        ap = pikepdf.Stream(pdf, b"1 0 0 rg 0 0 100 60 re f")
        ap.Type, ap.Subtype, ap.BBox = pikepdf.Name.XObject, pikepdf.Name.Form, [0, 0, 100, 60]
        annot = pdf.make_indirect(pikepdf.Dictionary(Type=pikepdf.Name.Annot, Subtype=pikepdf.Name.Square,
                                                     Rect=[50, 50, 150, 110], F=flags,
                                                     AP=pikepdf.Dictionary(N=pdf.make_indirect(ap))))
        link = pdf.make_indirect(pikepdf.Dictionary(Type=pikepdf.Name.Annot, Subtype=pikepdf.Name.Link,
                                                    Rect=[300, 300, 350, 320], F=4))
        pdf.pages[0].obj.Annots = pikepdf.Array([annot, link])
        path = self.tmp / f"square-{flags}.pdf"
        pdf.save(path)
        return path

    def test_comments_flattened_or_removed(self):
        src = self.square_doc()
        out, result = self.run_ops(src, [{"op": "print_prepare"}])
        self.assertEqual(result["results"][0]["flattened"], 1)
        self.assertEqual(result["results"][0]["removed"], 1)
        with pikepdf.open(out) as pdf:
            self.assertNotIn("/Annots", pdf.pages[0].obj)
        self.assertGreater(render_nonwhite(out, 0, (55, 55, 145, 105)), 1000)
        out2, result = self.run_ops(src, [{"op": "print_prepare", "comments": False}], name="o2.pdf")
        self.assertEqual(result["results"][0]["flattened"], 0)
        self.assertEqual(render_nonwhite(out2, 0, (55, 55, 145, 105)), 0)

    def test_non_printing_annotation_removed(self):
        src = self.square_doc(flags=0)
        out, result = self.run_ops(src, [{"op": "print_prepare"}])
        self.assertEqual(result["results"][0]["flattened"], 0)
        self.assertEqual(render_nonwhite(out, 0, (55, 55, 145, 105)), 0)

    def test_form_fields(self):
        src = self.fixture("uscis-i9.pdf")
        with pikepdf.open(src) as pdf:
            widgets = sum(1 for p in pdf.pages for a in p.obj.get("/Annots", []) if a.get("/Subtype") == "/Widget")
        self.assertGreater(widgets, 0)
        out, result = self.run_ops(src, [{"op": "print_prepare", "fields": True}])
        self.assertGreater(result["results"][0]["flattened"], 0)
        with pikepdf.open(out) as pdf:
            self.assertNotIn("/AcroForm", pdf.Root)
            self.assertFalse(any("/Annots" in p.obj for p in pdf.pages))
        out2, result2 = self.run_ops(src, [{"op": "print_prepare", "fields": False}], name="o2.pdf")
        self.assertLess(result2["results"][0]["flattened"], result["results"][0]["flattened"])
        with pikepdf.open(out2) as pdf:
            self.assertNotIn("/AcroForm", pdf.Root)


class ImpositionTests(Base):
    def test_scale_pages(self):
        src = numbered_pdf(self.tmp / "n.pdf", pages=1)
        out, _ = self.run_ops(src, [{"op": "scale_pages", "percent": 50}])
        boxes, _ = text_boxes(out)
        x, y = boxes["P1"]
        # Centre-scaled: label moves halfway towards the page centre.
        self.assertAlmostEqual(y, 396 + (396 + 17 - 396) * 0.5, delta=12)
        with pikepdf.open(out) as pdf:
            self.assertEqual([float(v) for v in pdf.pages[0].MediaBox], [0, 0, 612, 792])
        out2, _ = self.run_ops(src, [{"op": "scale_pages", "percent": 50, "center": False}], name="o2.pdf")
        x2, y2 = text_boxes(out2)[0]["P1"]
        self.assertLess(y2, 250)
        self.assertLess(x2, 200)

    def test_nup_orders(self):
        src = numbered_pdf(self.tmp / "n.pdf", pages=6)
        out, result = self.run_ops(src, [{"op": "impose_nup", "cols": 2, "rows": 2, "borders": True}])
        self.assertEqual(result["results"][0]["sheets"], 2)
        self.assertEqual(result["page_count"], 2)
        boxes, _ = text_boxes(out, 0)
        self.assertEqual(set(boxes), {"P1", "P2", "P3", "P4"})
        self.assertLess(boxes["P1"][0], boxes["P2"][0])
        self.assertAlmostEqual(boxes["P1"][1], boxes["P2"][1], delta=2)
        self.assertGreater(boxes["P1"][1], boxes["P3"][1])
        self.assertEqual(set(text_boxes(out, 1)[0]), {"P5", "P6"})
        out2, _ = self.run_ops(src, [{"op": "impose_nup", "cols": 2, "rows": 2, "order": "vertical"}], name="v.pdf")
        boxes, _ = text_boxes(out2, 0)
        self.assertLess(boxes["P1"][0], boxes["P3"][0])
        self.assertGreater(boxes["P1"][1], boxes["P2"][1])
        self.assertAlmostEqual(boxes["P1"][0], boxes["P2"][0], delta=2)
        out3, _ = self.run_ops(src, [{"op": "impose_nup", "cols": 2, "rows": 1, "order": "horizontal_reversed"}],
                               name="r.pdf")
        boxes, _ = text_boxes(out3, 0)
        self.assertGreater(boxes["P1"][0], boxes["P2"][0])
        with pikepdf.open(out3) as pdf:  # 2x1 of portrait pages -> landscape sheet
            box = [float(v) for v in pdf.pages[0].MediaBox]
            self.assertGreater(box[2], box[3])

    def test_nup_rotated_source_upright(self):
        src = numbered_pdf(self.tmp / "rot.pdf", pages=2, rotate=90)
        out, _ = self.run_ops(src, [{"op": "impose_nup", "cols": 1, "rows": 2}])
        doc = pdfium.PdfDocument(str(out))
        try:
            tp = doc[0].get_textpage()
            text = tp.get_text_range()
            i = text.index("P1")
            l, b, r, t = tp.get_charbox(i)
            _, _, _, t2 = tp.get_charbox(i + 1)
            # Placed as a viewer shows a /Rotate 90 page: text runs top to bottom.
            self.assertLess(t2, t)
        finally:
            doc.close()

    def test_booklet(self):
        src = numbered_pdf(self.tmp / "n.pdf", pages=6)
        out, result = self.run_ops(src, [{"op": "impose_booklet"}])
        info = result["results"][0]
        self.assertEqual((info["sheets"], info["sides"], info["blank_pages_added"]), (2, 4, 2))
        self.assertEqual(result["page_count"], 4)
        with pikepdf.open(out) as pdf:
            box = [float(v) for v in pdf.pages[0].MediaBox]
            self.assertEqual(box, [0, 0, 1224, 792])
        side1, _ = text_boxes(out, 0)
        self.assertEqual(set(side1), {"P1"})  # left half is blank page 8
        self.assertGreater(side1["P1"][0], 612)
        side2, _ = text_boxes(out, 1)
        self.assertLess(side2["P2"][0], 612)
        self.assertNotIn("P7", side2)  # padded blank (page 7 of 8)
        side3, _ = text_boxes(out, 2)
        self.assertLess(side3["P6"][0], 612)
        self.assertGreater(side3["P3"][0], 612)
        side4, _ = text_boxes(out, 3)
        self.assertLess(side4["P4"][0], 612)
        self.assertGreater(side4["P5"][0], 612)
        out2, _ = self.run_ops(src, [{"op": "impose_booklet", "binding": "right"}], name="r.pdf")
        side1, _ = text_boxes(out2, 0)
        self.assertLess(side1["P1"][0], 612)

    def test_booklet_eight_pages(self):
        src = numbered_pdf(self.tmp / "n8.pdf", pages=8)
        out, _ = self.run_ops(src, [{"op": "impose_booklet"}])
        side1, _ = text_boxes(out, 0)
        self.assertLess(side1["P8"][0], 612)
        self.assertGreater(side1["P1"][0], 612)
        side2, _ = text_boxes(out, 1)
        self.assertLess(side2["P2"][0], 612)
        self.assertGreater(side2["P7"][0], 612)

    def test_poster(self):
        src = numbered_pdf(self.tmp / "n.pdf", pages=1)
        out, result = self.run_ops(src, [{"op": "impose_poster", "scale": 200, "overlap": 18}])
        info = result["results"][0]
        # 1224 x 1584 on 594 x 774 steps -> 3 x 3 tiles (the overlap eats the remainder).
        self.assertEqual(info["grid"], [[3, 3]])
        self.assertEqual(info["tiles"], 9)
        self.assertEqual(result["page_count"], 9)
        _, text = text_boxes(out, 0)
        self.assertIn("Row 1, Col 1", text)
        _, text = text_boxes(out, 8)
        self.assertIn("Row 3, Col 3", text)
        out2, result2 = self.run_ops(src, [{"op": "impose_poster", "scale": 100, "labels": False}], name="o2.pdf")
        self.assertEqual(result2["results"][0]["tiles"], 1)

    def test_crop_area(self):
        src = numbered_pdf(self.tmp / "n.pdf", pages=3)
        out, result = self.run_ops(src, [{"op": "crop_area", "page": 1, "rect": [-50, 300, 400, 500]}])
        self.assertEqual(result["results"][0]["rect"], [0, 300, 400, 500])
        self.assertEqual(result["page_count"], 1)
        boxes, _ = text_boxes(out)
        self.assertIn("P2", boxes)
        with self.assertRaises(EngineError):
            self.run_ops(src, [{"op": "crop_area", "page": 0, "rect": [700, 900, 800, 1000]}], name="bad.pdf")

    def test_fixture_nup_validates(self):
        src = self.fixture("irs-1040-worksheet-b.pdf")
        out, result = self.run_ops(src, [{"op": "print_prepare"}, {"op": "impose_nup", "cols": 2, "rows": 1}])
        self.assertGreaterEqual(result["page_count"], 1)


class MeasureTests(Base):
    def geometry_doc(self):
        pdf = pikepdf.new()
        page = pdf.add_blank_page(page_size=(612, 792))
        form = pikepdf.Stream(pdf, b"0 0 m 20 0 l S")
        form.Type, form.Subtype, form.BBox = pikepdf.Name.XObject, pikepdf.Name.Form, [0, 0, 100, 100]
        page.obj.Resources = pikepdf.Dictionary(XObject=pikepdf.Dictionary(Fm=pdf.make_indirect(form)))
        content = (b"100 100 200 100 re S "          # rectangle 100..300 x 100..200
                   b"400 400 m 500 500 l S 400 500 m 500 400 l S "   # an X crossing at 450,450
                   b"q 2 0 0 2 50 600 cm /Fm Do Q")    # form line: 50,600 -> 90,600
        page.obj.Contents = pdf.make_indirect(pikepdf.Stream(pdf, content))
        path = self.tmp / "geo.pdf"
        pdf.save(path)
        return path

    def test_snap_points(self):
        src = self.geometry_doc()
        result = transforms.inspect(src, "vector_snap_points", {"page": 0})
        ends = {tuple(p) for p in result["endpoints"]}
        for corner in [(100, 100), (300, 100), (300, 200), (100, 200), (400, 400), (500, 500), (50, 600), (90, 600)]:
            self.assertIn(corner, ends)
        mids = {tuple(p) for p in result["midpoints"]}
        self.assertIn((200, 100), mids)
        self.assertIn((100, 150), mids)
        self.assertIn((70, 600), mids)
        self.assertIn((450, 450), {tuple(p) for p in result["intersections"]})
        # Rectangle corners are joints, not intersections.
        self.assertNotIn((100, 100), {tuple(p) for p in result["intersections"]})
        self.assertGreaterEqual(len(result["segments"]), 7)
        capped = transforms.inspect(src, "vector_snap_points", {"page": 0, "max_points": 10})
        self.assertLessEqual(len(capped["endpoints"]) + len(capped["intersections"]) + len(capped["midpoints"]), 10)

    def test_snap_points_fixture_fast(self):
        import time
        src = self.fixture("irs-1040-worksheet-b.pdf")
        start = time.time()
        result = transforms.inspect(src, "vector_snap_points", {"page": 0})
        self.assertLess(time.time() - start, 10)
        self.assertIsInstance(result["endpoints"], list)

    def test_add_and_query_measurements(self):
        src = numbered_pdf(self.tmp / "n.pdf", pages=1)
        items = [
            {"page": 0, "kind": "distance", "points": [[100, 100], [300, 100]], "label": "27.78 ft",
             "unit": "ft", "ratio": "1 in = 10 ft", "factor": 10 / 72, "author": "Tester"},
            {"page": 0, "kind": "perimeter", "points": [[100, 400], [200, 450], [300, 400]], "label": "30 ft",
             "unit": "ft", "ratio": "1 in = 10 ft", "factor": 10 / 72, "name": "perim-1"},
            {"page": 0, "kind": "area", "points": [[350, 600], [500, 600], [500, 700], [350, 700]],
             "label": "289.35 sq ft", "unit": "ft", "ratio": "1 in = 10 ft", "factor": 10 / 72},
        ]
        out, result = self.run_ops(src, [{"op": "add_measurements", "items": items}])
        info = result["results"][0]
        self.assertEqual(info["added"], 3)
        self.assertEqual(info["names"][1], "perim-1")
        self.assertTrue(info["names"][0].startswith("zpdf-measure-"))
        listed = transforms.inspect(out, "measurements", {})["items"]
        self.assertEqual([i["kind"] for i in listed], ["distance", "perimeter", "area"])
        self.assertEqual([i["subtype"] for i in listed], ["Line", "PolyLine", "Polygon"])
        self.assertEqual(listed[0]["points"], [[100, 100], [300, 100]])
        self.assertEqual(listed[0]["label"], "27.78 ft")
        self.assertEqual(listed[0]["ratio"], "1 in = 10 ft")
        self.assertEqual(listed[0]["author"], "Tester")
        with pikepdf.open(out) as pdf:
            annots = pdf.pages[0].obj.Annots
            line = annots[0]
            self.assertEqual(str(line.IT), "/LineDimension")
            self.assertEqual([str(v) for v in line.LE], ["/OpenArrow", "/OpenArrow"])
            self.assertEqual(int(line.F), 4)
            self.assertAlmostEqual(float(line.Measure.X[0].C), 10 / 72, places=6)
            self.assertEqual(str(annots[2].Measure.A[0].U), "sq ft")
            self.assertIn("/N", line.AP)
            rects = [[float(v) for v in a.Rect] for a in annots]
        for rect in rects:
            self.assertGreater(render_nonwhite(out, 0, rect), 20)
        with pikepdf.open(out) as pdf:
            self.assertIn(b"(27.78 ft) Tj", pdf.pages[0].obj.Annots[0].AP.N.read_bytes())

    def test_invalid_measurement_fails_closed(self):
        src = numbered_pdf(self.tmp / "n.pdf", pages=1)
        with self.assertRaises(EngineError):
            self.run_ops(src, [{"op": "add_measurements", "items": [{"page": 0, "kind": "area", "points": [[0, 0], [1, 1]]}]}])
        self.assertFalse((self.tmp / "out.pdf").exists())

    def test_page_scale_round_trip(self):
        src = numbered_pdf(self.tmp / "n.pdf", pages=2)
        out, result = self.run_ops(src, [{"op": "set_page_scale", "ratio": "1 in = 10 ft", "factor": 10 / 72,
                                           "unit": "ft", "pages": [1]}])
        self.assertEqual(result["results"][0]["pages"], 1)
        scales = transforms.inspect(out, "page_scales", {})["pages"]
        self.assertIsNone(scales[0]["ratio"])
        self.assertEqual(scales[1]["ratio"], "1 in = 10 ft")
        self.assertEqual(scales[1]["unit"], "ft")
        self.assertAlmostEqual(scales[1]["factor"], 10 / 72, places=6)
        self.assertEqual(scales[1]["bbox"], [0, 0, 612, 792])
        # Replacing keeps a single zPDF viewport.
        out2, _ = self.run_ops(out, [{"op": "set_page_scale", "ratio": "1 cm = 1 m", "factor": 2.54 / 72,
                                       "unit": "m"}], name="o2.pdf")
        with pikepdf.open(out2) as pdf:
            self.assertEqual(len(pdf.pages[1].obj.VP), 1)
        scales = transforms.inspect(out2, "page_scales", {})["pages"]
        self.assertEqual([s["unit"] for s in scales], ["m", "m"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
