"""Page-composition transform regressions (insert, replace, duplicate, labels,
boxes, resize, transitions). Run with the dev venv:

    python scripts/test_pages.py
"""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_transforms import Base, blank_pdf, text_of  # noqa: E402
import pikepdf  # noqa: E402
import pypdfium2 as pdfium  # noqa: E402
from PIL import Image  # noqa: E402
from engine.errors import EngineError  # noqa: E402


def text_pdf(path, texts, size=(612, 792)):
    """Pages with real Helvetica text; page 1 links to the last page."""
    pdf = pikepdf.new()
    font = pdf.make_indirect(pikepdf.Dictionary(Type=pikepdf.Name.Font, Subtype=pikepdf.Name.Type1,
                                                BaseFont=pikepdf.Name.Helvetica, Encoding=pikepdf.Name.WinAnsiEncoding))
    for text in texts:
        page = pdf.add_blank_page(page_size=size)
        page.obj.Resources = pikepdf.Dictionary(Font=pikepdf.Dictionary(F1=font))
        page.obj.Contents = pdf.make_indirect(pikepdf.Stream(pdf, f"BT /F1 24 Tf 72 700 Td ({text}) Tj ET".encode()))
    if len(texts) > 1:
        link = pdf.make_indirect(pikepdf.Dictionary(Type=pikepdf.Name.Annot, Subtype=pikepdf.Name.Link,
                                                    Rect=[72, 690, 300, 730], Border=[0, 0, 0],
                                                    Dest=pikepdf.Array([pdf.pages[-1].obj, pikepdf.Name.Fit])))
        pdf.pages[0].obj.Annots = pikepdf.Array([link])
    pdf.save(path)
    return path


def field_names(path):
    with pikepdf.open(path) as pdf:
        acro = pdf.Root.get("/AcroForm")
        return [str(f.T) for f in acro.Fields] if acro is not None else []


class InsertTests(Base):
    def test_insert_blank_sizes(self):
        src = blank_pdf(self.tmp / "b.pdf", pages=2)
        out, result = self.run_ops(src, [
            {"op": "insert_blank_pages", "at": 1, "count": 2, "size": "a4"},
            {"op": "insert_blank_pages", "at": 0, "size": [300, 200]},
            {"op": "insert_blank_pages", "size": "letter", "orientation": "landscape"},
        ])
        self.assertEqual(result["page_count"], 6)
        with pikepdf.open(out) as pdf:
            sizes = [tuple(round(float(v)) for v in p.MediaBox[2:]) for p in pdf.pages]
        self.assertEqual(sizes, [(300, 200), (612, 792), (595, 842), (595, 842), (612, 792), (792, 612)])

    def test_insert_pdf_keeps_links_and_namespaces_fields(self):
        target = self.fixture("uscis-i9.pdf")
        before = field_names(target)
        out, result = self.run_ops(target, [
            {"op": "insert_pages", "path": str(target), "at": 0, "pages": [0]},
        ])
        info = result["results"][0]
        self.assertEqual(info["inserted"], 1)
        self.assertGreater(info["fields"], 0)
        self.assertEqual(info["renamed"], info["fields"], "same-named fields are namespaced")
        names = field_names(out)
        self.assertEqual(len(names), len(before) + info["fields"])
        self.assertTrue(any(n.startswith("zpdf1_") for n in names))
        # Imported widgets are real, fillable fields in PDFium.
        doc = pdfium.PdfDocument(str(out))
        doc.init_forms()
        page = doc[0]
        self.assertGreater(len(list(page.get_objects())), 0)
        doc.close()

    def test_insert_pdf_links(self):
        target = blank_pdf(self.tmp / "t.pdf", pages=1)
        other = text_pdf(self.tmp / "o.pdf", ["ONE", "TWO", "THREE"])
        out, result = self.run_ops(target, [{"op": "insert_pages", "path": str(other), "at": 1}])
        self.assertEqual(result["page_count"], 4)
        self.assertIn("THREE", text_of(out, 3))
        with pikepdf.open(out) as pdf:
            dest = pdf.pages[1].obj.Annots[0].Dest
            self.assertEqual(dest[0].objgen, pdf.pages[3].obj.objgen)
        # Only page 1 imported: its link target did not come along -> removed, no orphan page copied.
        out2, result2 = self.run_ops(target, [{"op": "insert_pages", "path": str(other), "pages": [0]}], name="o2.pdf")
        self.assertEqual(result2["results"][0]["links_removed"], 1)
        with pikepdf.open(out2) as pdf:
            pages = [o for o in pdf.objects if isinstance(o, pikepdf.Dictionary) and o.get("/Type") == pikepdf.Name.Page]
            self.assertEqual(len(pages), 2)

    def test_insert_images_fit(self):
        rgb = self.tmp / "photo.jpg"
        Image.new("RGB", (400, 200), (200, 30, 30)).save(rgb, dpi=(144, 144))
        png = self.tmp / "alpha.png"
        Image.new("RGBA", (100, 300), (0, 0, 255, 128)).save(png)
        src = blank_pdf(self.tmp / "b.pdf")
        out, result = self.run_ops(src, [
            {"op": "insert_images", "images": [str(rgb), str(png)], "at": 0},
            {"op": "insert_images", "images": [{"path": str(rgb)}], "page_size": "letter", "fit": "fit", "margin": 36},
            {"op": "delete_pages", "pages": [2]},
        ])
        self.assertEqual(result["page_count"], 3)
        with pikepdf.open(out) as pdf:
            self.assertEqual([round(float(v)) for v in pdf.pages[0].MediaBox[2:]], [200, 100])  # 144 dpi
            self.assertEqual([round(float(v)) for v in pdf.pages[1].MediaBox[2:]], [100, 300])
            self.assertEqual([round(float(v)) for v in pdf.pages[2].MediaBox[2:]], [792, 612])  # auto landscape
            im = list(pdf.pages[0].images.values())[0]
            self.assertEqual(im.Filter, pikepdf.Name.DCTDecode, "JPEG passes through unchanged")
            self.assertIn("/SMask", list(pdf.pages[1].images.values())[0])

    def test_delete_all_fails_closed(self):
        src = blank_pdf(self.tmp / "b.pdf", pages=2)
        with self.assertRaises(EngineError):
            self.run_ops(src, [{"op": "delete_pages", "pages": [0, 1]}])


class ReplaceDuplicateTests(Base):
    def test_replace_keeps_annotations(self):
        target = text_pdf(self.tmp / "t.pdf", ["OLD1", "OLD2"])
        other = text_pdf(self.tmp / "o.pdf", ["NEW1"], size=(500, 500))
        out, _ = self.run_ops(target, [{"op": "replace_pages", "path": str(other), "targets": [0], "source_pages": [0]}])
        self.assertIn("NEW1", text_of(out, 0))
        self.assertNotIn("OLD1", text_of(out, 0))
        with pikepdf.open(out) as pdf:
            self.assertEqual(len(pdf.pages[0].obj.Annots), 1, "replaced page keeps its link")
            self.assertEqual([float(v) for v in pdf.pages[0].MediaBox], [0, 0, 500, 500])
            self.assertEqual(pdf.pages[0].obj.Annots[0].Dest[0].objgen, pdf.pages[1].obj.objgen)

    def test_duplicate_links_widgets(self):
        target = self.fixture("uscis-i9.pdf")
        with pikepdf.open(target) as pdf:
            count = len(pdf.pages)
            widgets = len([a for a in pdf.pages[0].obj.get("/Annots", []) if a.get("/Subtype") == pikepdf.Name.Widget])
        out, result = self.run_ops(target, [{"op": "duplicate_pages", "pages": [0]}])
        self.assertEqual(result["page_count"], count + 1)
        with pikepdf.open(out) as pdf:
            first = pdf.pages[0].obj.Annots
            dup = pdf.pages[1].obj.Annots
            self.assertEqual(len([a for a in dup if a.get("/Subtype") == pikepdf.Name.Widget]), widgets)
            for a, b in zip(first, dup):
                self.assertNotEqual(a.objgen, b.objgen)
                self.assertEqual(b.P.objgen, pdf.pages[1].obj.objgen)
                if a.get("/Subtype") == pikepdf.Name.Widget:
                    self.assertEqual(a.Parent.objgen, b.Parent.objgen, "duplicate widget shares its field")
        # Round-trips through PDFium form handling.
        doc = pdfium.PdfDocument(str(out))
        doc.init_forms()
        self.assertEqual(len(doc), count + 1)
        doc.close()

    def test_rotate_range(self):
        src = blank_pdf(self.tmp / "b.pdf", pages=3, rotate=90)
        out, _ = self.run_ops(src, [{"op": "rotate_pages", "pages": [0, 2], "angle": 90},
                                    {"op": "rotate_pages", "pages": [1], "angle": -90}])
        with pikepdf.open(out) as pdf:
            self.assertEqual([int(p.obj.Rotate) for p in pdf.pages], [180, 0, 180])


class LabelBoxTests(Base):
    def test_page_labels(self):
        src = blank_pdf(self.tmp / "b.pdf", pages=6)
        out, result = self.run_ops(src, [{"op": "set_page_labels", "ranges": [
            {"start": 0, "style": "r"}, {"start": 3, "style": "D", "first": 1, "prefix": "A-"}]}])
        self.assertEqual(result["results"][0]["labels"], ["i", "ii", "iii", "A-1", "A-2", "A-3"])
        doc = pdfium.PdfDocument(str(out))
        self.assertEqual(doc.get_page_label(4), "A-2")
        doc.close()
        import transforms
        self.assertEqual(transforms.inspect(out, "page_labels")["labels"][2], "iii")
        out2, _ = self.run_ops(out, [{"op": "set_page_labels", "ranges": []}], name="o2.pdf")
        self.assertEqual(transforms.inspect(out2, "page_labels")["labels"][4], "5")

    def test_page_boxes_and_resize(self):
        src = text_pdf(self.tmp / "t.pdf", ["HELLO", "WORLD"])
        out, _ = self.run_ops(src, [{"op": "set_page_boxes", "pages": [0], "boxes": {
            "CropBox": {"margins": [36, 36, 36, 36]}, "TrimBox": {"margins": [18, 18, 18, 18]},
            "BleedBox": {"rect": [9, 9, 603, 783]}}}])
        with pikepdf.open(out) as pdf:
            self.assertEqual([float(v) for v in pdf.pages[0].CropBox], [36, 36, 576, 756])
            self.assertEqual([float(v) for v in pdf.pages[0].TrimBox], [18, 18, 594, 774])
        out2, _ = self.run_ops(src, [{"op": "resize_pages", "size": "a4", "mode": "scale"}], name="o2.pdf")
        doc = pdfium.PdfDocument(str(out2))
        page = doc[1]
        self.assertAlmostEqual(page.get_width(), 595.28, places=1)
        tp = page.get_textpage()
        self.assertIn("WORLD", tp.get_text_range())
        l, b, r, t = tp.get_charbox(0)
        self.assertLess(l, 72)  # scaled toward the origin
        # Link annotation rect follows the content.
        with pikepdf.open(out2) as pdf:
            rect = [float(v) for v in pdf.pages[0].obj.Annots[0].Rect]
            self.assertLess(rect[2], 300)
        doc.close()
        with self.assertRaises(EngineError):
            self.run_ops(src, [{"op": "set_page_boxes", "boxes": {"CropBox": {"margins": [400, 0, 400, 0]}}}], name="bad.pdf")

    def test_transitions(self):
        src = blank_pdf(self.tmp / "b.pdf", pages=2)
        out, _ = self.run_ops(src, [{"op": "set_transitions", "style": "Wipe", "direction": 90, "duration": 0.5,
                                     "advance": 3}])
        import transforms
        info = transforms.inspect(out, "page_transitions")["pages"]
        self.assertEqual(info[0], {"style": "Wipe", "duration": 0.5, "advance": 3.0})
        out2, _ = self.run_ops(out, [{"op": "set_transitions", "style": None}], name="o2.pdf")
        self.assertIsNone(transforms.inspect(out2, "page_transitions")["pages"][1]["style"])

    def test_split_by_size(self):
        import transforms
        big = self.tmp / "big.png"
        import random
        random.seed(1)
        Image.frombytes("RGB", (300, 300), bytes(random.getrandbits(8) for _ in range(300 * 300 * 3))).save(big)
        src = blank_pdf(self.tmp / "b.pdf")
        out, _ = self.run_ops(src, [{"op": "insert_images", "images": [str(big)] * 4}])
        groups = transforms.inspect(out, "split_by_size", {"max_bytes": 600_000})["groups"]
        self.assertEqual(sum(len(g) for g in groups), 5)
        self.assertGreater(len(groups), 1)


class PortfolioTests(Base):
    def test_create_list_extract(self):
        import transforms
        a = text_pdf(self.tmp / "a.pdf", ["Alpha"])
        note = self.tmp / "notes.txt"
        note.write_text("hello portfolio")
        src = blank_pdf(self.tmp / "seed.pdf")
        out, result = self.run_ops(src, [{"op": "create_portfolio", "title": "Case files",
                                          "files": [str(a), {"path": str(note), "description": "Notes"}]}])
        self.assertEqual(result["results"][0]["files"], ["a.pdf", "notes.txt"])
        self.assertIn("Case files", text_of(out))
        info = transforms.inspect(out, "embedded_files")
        self.assertTrue(info["portfolio"])
        self.assertEqual([f["name"] for f in info["files"]], ["a.pdf", "notes.txt"])
        self.assertEqual(info["files"][1]["description"], "Notes")
        folder = self.tmp / "x"
        folder.mkdir()
        path = transforms.inspect(out, "extract_embedded", {"name": "notes.txt", "directory": str(folder)})["path"]
        self.assertEqual(Path(path).read_text(), "hello portfolio")


if __name__ == "__main__":
    unittest.main(verbosity=1)
