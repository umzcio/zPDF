"""OCR layer, optimization, space audit and PDF/A /X /E regressions.

    python scripts/test_standards.py
"""
from pathlib import Path
import io
import random
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_transforms import Base, blank_pdf, text_of  # noqa: E402
from test_pages import text_pdf  # noqa: E402
import pikepdf  # noqa: E402
import pypdfium2 as pdfium  # noqa: E402
from PIL import Image  # noqa: E402
import transforms  # noqa: E402
from engine.errors import EngineError  # noqa: E402


def scan_pdf(tmp, pixels=(1700, 2200), rotate=0):
    """A letter page that is one big photo-like image (a "scan")."""
    random.seed(7)
    img = Image.new("RGB", pixels, (250, 250, 245))
    noise = Image.frombytes("L", (200, 200), bytes(random.getrandbits(8) for _ in range(40000))).resize(pixels)
    img = Image.composite(img, Image.new("RGB", pixels, (30, 30, 30)), noise.point(lambda v: 255 if v > 40 else 0))
    path = tmp / "scan.jpg"
    img.save(path, quality=92, dpi=(200, 200))
    src = blank_pdf(tmp / "seed.pdf")
    out = tmp / "scan.pdf"
    transforms.run(src, out, [{"op": "insert_images", "images": [str(path)], "at": 0, "page_size": "letter"},
                              {"op": "delete_pages", "pages": [1]}] +
                   ([{"op": "rotate_pages", "angle": rotate}] if rotate else []))
    return out


class OCRTests(Base):
    def test_invisible_layer_searchable_and_positioned(self):
        src = scan_pdf(self.tmp)
        lines = [[{"t": "Hello", "b": [72, 700, 150, 720]}, {"t": "wörld", "b": [160, 700, 240, 720]}],
                 [{"t": "Second", "b": [72, 660, 160, 680]}]]
        out, result = self.run_ops(src, [{"op": "ocr_text_layer", "pages": [{"page": 0, "lines": lines}]}])
        self.assertEqual(result["results"][0]["words"], 3)
        text = text_of(out)
        self.assertIn("Hello", text)
        self.assertIn("wörld", text)
        doc = pdfium.PdfDocument(str(out))
        tp = doc[0].get_textpage()
        l, b, r, t = tp.get_charbox(0)
        self.assertAlmostEqual(l, 72, delta=3)
        self.assertAlmostEqual(b, 700, delta=6)
        # Width of "Hello" spans its box.
        l2, _, r2, _ = tp.get_charbox(4)
        self.assertAlmostEqual(r2, 150, delta=6)
        doc.close()
        status = transforms.inspect(out, "text_status")["pages"][0]
        self.assertTrue(status["ocr"])
        # Re-running replaces instead of doubling.
        out2, _ = self.run_ops(out, [{"op": "ocr_text_layer", "pages": [{"page": 0, "lines": [[{"t": "Only", "b": [72, 600, 120, 620]}]]}]}], name="o2.pdf")
        self.assertNotIn("Hello", text_of(out2))
        self.assertIn("Only", text_of(out2))
        # Invisible: rendering is unchanged by the layer.
        a = pdfium.PdfDocument(str(src))[0].render(scale=0.5).to_pil()
        b_ = pdfium.PdfDocument(str(out))[0].render(scale=0.5).to_pil()
        self.assertEqual(a.tobytes(), b_.tobytes())

    def test_rotated_page_layer(self):
        src = scan_pdf(self.tmp, rotate=90)
        # Visual page is landscape (792 x 612).
        out, _ = self.run_ops(src, [{"op": "ocr_text_layer", "pages": [{"page": 0, "lines": [[{"t": "Upright", "b": [50, 550, 150, 570]}]]}]}])
        self.assertIn("Upright", text_of(out))

    def test_visible_editable_text_and_replace_image(self):
        src = scan_pdf(self.tmp)
        out, _ = self.run_ops(src, [{"op": "ocr_text_layer", "visible": True, "cover": True,
                                     "pages": [{"page": 0, "lines": [[{"t": "Visible", "b": [72, 700, 200, 730]}]]}]}])
        img = pdfium.PdfDocument(str(out))[0].render(scale=1).to_pil().convert("L")
        # Text drawn in black inside the covered (white) box.
        crop = img.crop((72, 792 - 730, 200, 792 - 700))
        self.assertLess(min(crop.getdata()), 60)
        clean = self.tmp / "clean.png"
        Image.new("L", (850, 1100), 255).save(clean)
        out2, _ = self.run_ops(out, [{"op": "replace_page_image", "pages": [{"page": 0, "path": str(clean)}]}], name="o2.pdf")
        self.assertEqual(text_of(out2).strip(), "")


class OptimizeTests(Base):
    def test_downsample_and_audit(self):
        src = scan_pdf(self.tmp)  # ~200 dpi effective
        before = src.stat().st_size
        audit = transforms.inspect(src, "space_audit")
        self.assertGreater(audit["categories"]["images"], before * 0.8)
        self.assertEqual(audit["total"], before)
        inv = transforms.inspect(src, "image_inventory")["images"][0]
        self.assertAlmostEqual(inv["dpi"], 200, delta=3)
        out, result = self.run_ops(src, [{"op": "optimize", "preset": "low", "linearize": True}])
        info = result["results"][0]
        self.assertEqual(info["images"], 1)
        self.assertLess(result["bytes"], before * 0.5)
        inv2 = transforms.inspect(out, "image_inventory")["images"][0]
        self.assertAlmostEqual(inv2["dpi"], 96, delta=2)
        with pikepdf.open(out) as pdf:
            self.assertTrue(pdf.is_linearized)

    def test_grayscale_and_removals(self):
        src = scan_pdf(self.tmp)
        with pikepdf.open(src, allow_overwriting_input=True) as pdf:
            pdf.Root.PieceInfo = pikepdf.Dictionary(App=pikepdf.Dictionary(Private=1))
            pdf.pages[0].obj.Thumb = pdf.make_indirect(pikepdf.Stream(pdf, b"x" * 100))
            pdf.Root.Names = pikepdf.Dictionary(JavaScript=pikepdf.Dictionary(Names=pikepdf.Array()))
            pdf.docinfo["/Author"] = "Someone"
            pdf.save(src)
        out, result = self.run_ops(src, [{"op": "optimize", "images": {"grayscale": True, "color_dpi": None, "jpeg_quality": 80},
                                          "remove": {"metadata": True, "thumbnails": True, "private_data": True, "javascript": True}}])
        with pikepdf.open(out) as pdf:
            self.assertNotIn("/PieceInfo", pdf.Root)
            self.assertNotIn("/Thumb", pdf.pages[0].obj)
            self.assertNotIn("/JavaScript", pdf.Root.get("/Names", {}))
            self.assertNotIn("/Author", pdf.docinfo)
            im = list(pdf.pages[0].obj.Resources.XObject.values())[0]
            self.assertEqual(im.ColorSpace, pikepdf.Name.DeviceGray)

    def test_font_subset_and_unembed(self):
        # Embed a full TrueType font for a simple WinAnsi font, then subset it.
        src = text_pdf(self.tmp / "t.pdf", ["Subset me"])
        data = Path("/System/Library/Fonts/Supplemental/Arial.ttf").read_bytes()
        with pikepdf.open(src, allow_overwriting_input=True) as pdf:
            font = pdf.pages[0].obj.Resources.Font.F1
            font.Subtype = pikepdf.Name.TrueType
            font.BaseFont = pikepdf.Name("/ArialMT")
            stream = pdf.make_indirect(pikepdf.Stream(pdf, data))
            font.FontDescriptor = pdf.make_indirect(pikepdf.Dictionary(Type=pikepdf.Name.FontDescriptor, FontName=pikepdf.Name("/ArialMT"),
                                                                       Flags=32, FontBBox=[0, 0, 1000, 1000], ItalicAngle=0,
                                                                       Ascent=900, Descent=-200, CapHeight=700, StemV=80, FontFile2=stream))
            font.FirstChar, font.LastChar = 32, 126
            font.Widths = pikepdf.Array([500] * 95)
            pdf.save(src)
        before = src.stat().st_size
        out, result = self.run_ops(src, [{"op": "optimize", "images": False, "fonts": {"subset": True}}])
        self.assertEqual(result["results"][0]["fonts_subset"], 1)
        self.assertLess(result["bytes"], before / 3)
        self.assertIn("Subset me", text_of(out))

    def test_extract_images(self):
        src = scan_pdf(self.tmp)
        folder = self.tmp / "images"
        folder.mkdir()
        result = transforms.inspect(src, "extract_images", {"directory": str(folder)})
        self.assertEqual(len(result["images"]), 1)
        self.assertTrue(result["images"][0]["path"].endswith(".jpg"), "JPEG exported in its original encoding")


class StandardsTests(Base):
    def test_pdfa_conversion_and_validation(self):
        src = text_pdf(self.tmp / "t.pdf", ["Archive", "Two"])  # unembedded Helvetica, no XMP
        report = transforms.inspect(src, "validate_standard", {"standard": "PDF/A-2b"})
        self.assertFalse(report["compliant"])
        rules = {i["rule"] for i in report["issues"]}
        self.assertIn("fonts", rules)
        self.assertIn("metadata", rules)
        out, result = self.run_ops(src, [{"op": "convert_pdfa", "level": "2b"}])
        info = result["results"][0]
        self.assertEqual(info["fonts_embedded"][0]["substitute"], "Arial.ttf")
        report2 = transforms.inspect(out, "validate_standard", {"standard": "PDF/A-2b"})
        self.assertTrue(report2["compliant"], report2["issues"])
        self.assertIn("Archive", text_of(out))
        with pikepdf.open(out) as pdf:
            self.assertEqual(pdf.open_metadata()["pdfaid:part"], "2")
            self.assertEqual(pdf.Root.OutputIntents[0].S, pikepdf.Name.GTS_PDFA1)
            self.assertNotIn("/Filter", pdf.Root.Metadata)
            self.assertIn("/ID", pdf.trailer)
        claims = transforms.inspect(out, "standards_status")["claims"]
        self.assertEqual(claims, ["PDF/A-2b"])

    def test_pdfa3_with_attachment_and_cmyk(self):
        src = text_pdf(self.tmp / "t.pdf", ["CMYK"])
        with pikepdf.open(src, allow_overwriting_input=True) as pdf:
            page = pdf.pages[0]
            page.obj.Contents = pdf.make_indirect(pikepdf.Stream(pdf, b"0 0 0 1 k 10 10 100 100 re f 1 0 0 rg 200 200 50 50 re f " + page.obj.Contents.read_bytes()))
            spec = pikepdf.AttachedFileSpec(pdf, b"hello", mime_type="text/plain")
            pdf.attachments["note.txt"] = spec
            pdf.save(src)
        out, _ = self.run_ops(src, [{"op": "convert_pdfa", "level": "3b"}])
        report = transforms.inspect(out, "validate_standard", {"standard": "PDF/A-3b"})
        self.assertTrue(report["compliant"], report["issues"])
        with pikepdf.open(out) as pdf:
            self.assertIn("note.txt", pdf.attachments)
            self.assertIn("/DefaultCMYK", pdf.pages[0].obj.Resources.ColorSpace)
        out2, _ = self.run_ops(src, [{"op": "convert_pdfa", "level": "2b"}], name="o2.pdf")
        with pikepdf.open(out2) as pdf:
            self.assertEqual(len(pdf.attachments), 0)

    def test_symbol_font_embedding(self):
        src = text_pdf(self.tmp / "t.pdf", ["abc"])
        with pikepdf.open(src, allow_overwriting_input=True) as pdf:
            font = pdf.pages[0].obj.Resources.Font.F1
            font.BaseFont = pikepdf.Name.Symbol
            del font["/Encoding"]
            pdf.save(src)
        out, result = self.run_ops(src, [{"op": "convert_pdfa", "level": "2b"}])
        self.assertEqual(result["results"][0]["fonts_embedded"][0]["substitute"], "Symbol.ttf")
        self.assertTrue(transforms.inspect(out, "validate_standard", {"standard": "PDF/A-2b"})["compliant"])

    def test_pdfx_and_pdfe(self):
        src = text_pdf(self.tmp / "t.pdf", ["Print"])
        report = transforms.inspect(src, "validate_standard", {"standard": "PDF/X-4"})
        self.assertFalse(report["compliant"])
        out, _ = self.run_ops(src, [{"op": "convert_pdfx", "bleed": 9}])
        report2 = transforms.inspect(out, "validate_standard", {"standard": "PDF/X-4"})
        self.assertTrue(report2["compliant"], report2["issues"])
        with pikepdf.open(out) as pdf:
            self.assertEqual(str(pdf.docinfo.GTS_PDFXVersion), "PDF/X-4")
            self.assertIn("/TrimBox", pdf.pages[0].obj)
        out2, _ = self.run_ops(src, [{"op": "convert_pdfe"}], name="e.pdf")
        self.assertTrue(transforms.inspect(out2, "validate_standard", {"standard": "PDF/E-1"})["compliant"])

    def test_real_form_to_pdfa(self):
        src = self.fixture("uscis-i9.pdf")
        out, result = self.run_ops(src, [{"op": "convert_pdfa", "level": "2b"}])
        report = transforms.inspect(out, "validate_standard", {"standard": "PDF/A-2b"})
        self.assertTrue(report["compliant"], report["issues"])


def spot_pdf(path, function="type2"):
    pdf = pikepdf.new()
    page = pdf.add_blank_page(page_size=(400, 400))
    if function == "type2":
        fn = pikepdf.Dictionary(FunctionType=2, Domain=[0, 1], C0=[0, 0, 0, 0], C1=[0, 0.5, 1, 0], N=1)
    else:
        fn = pdf.make_indirect(pikepdf.Stream(pdf, b"{dup 0 mul exch dup 0.5 mul exch dup 1 mul exch 0 mul}"))
        fn.FunctionType, fn.Domain, fn.Range = 4, [0, 1], [0, 1, 0, 1, 0, 1, 0, 1]
    sep = pikepdf.Array([pikepdf.Name.Separation, pikepdf.Name("/PANTONE 300 C"), pikepdf.Name.DeviceCMYK, fn])
    gs = pdf.make_indirect(pikepdf.Dictionary(Type=pikepdf.Name.ExtGState, ca=0.5))
    page.obj.Resources = pikepdf.Dictionary(ColorSpace=pikepdf.Dictionary(CS0=sep), ExtGState=pikepdf.Dictionary(GS0=gs))
    page.obj.Contents = pdf.make_indirect(pikepdf.Stream(pdf, b"/CS0 cs 1 scn 50 50 100 100 re f 0.1 w 0 0 m 400 400 l S /GS0 gs 1 0 0 rg 200 200 50 50 re f"))
    pdf.save(path)
    return path


class PrepressTests(Base):
    def test_preflight_profiles(self):
        src = spot_pdf(self.tmp / "s.pdf")
        report = transforms.inspect(src, "preflight", {"profile": "commercial"})
        ids = {r["id"]: r for r in report["results"]}
        self.assertEqual(ids["hairlines"]["severity"], "warning")
        self.assertEqual(ids["trim"]["severity"], "error")
        self.assertIn("PANTONE 300 C", ids["spots"]["detail"])
        self.assertIn("transparency", ids)
        web = transforms.inspect(src, "preflight", {"profile": "web"})
        self.assertEqual(web["errors"], 0)

    def test_inks_and_mapping(self):
        for kind in ("type2", "type4"):
            src = spot_pdf(self.tmp / f"s-{kind}.pdf", kind)
            inks = transforms.inspect(src, "inks")
            self.assertEqual(inks["spots"][0]["name"], "PANTONE 300 C")
            self.assertEqual(inks["spots"][0]["preview"]["values"], [0, 0.5, 1, 0])
            out, result = self.run_ops(src, [{"op": "map_spots_to_process"}], name=f"o-{kind}.pdf")
            self.assertEqual(result["results"][0]["converted"], 1)
            with pikepdf.open(out) as pdf:
                data = pdf.pages[0].obj.Contents.read_bytes()
                self.assertIn(b"0 0.5 1 0 k", data)
                self.assertNotIn(b"scn", data)

    def test_marks_hairlines_flatten(self):
        src = text_pdf(self.tmp / "t.pdf", ["Marks"])
        out, _ = self.run_ops(src, [{"op": "printer_marks", "title": "Job"}])
        with pikepdf.open(out) as pdf:
            page = pdf.pages[0].obj
            self.assertEqual([float(v) for v in page.TrimBox], [0, 0, 612, 792])
            self.assertEqual([float(v) for v in page.BleedBox], [-9, -9, 621, 801])
            self.assertLess(float(page.MediaBox[0]), -40)
        self.assertIn("Page 1 of 1", text_of(out))
        out2, _ = self.run_ops(out, [{"op": "remove_printer_marks"}], name="o2.pdf")
        with pikepdf.open(out2) as pdf:
            self.assertEqual([float(v) for v in pdf.pages[0].obj.MediaBox], [0, 0, 612, 792])
        spot = spot_pdf(self.tmp / "s.pdf")
        out3, res = self.run_ops(spot, [{"op": "fix_hairlines"}], name="o3.pdf")
        self.assertEqual(res["results"][0]["fixed"], 1)
        report = transforms.inspect(out3, "preflight", {"profile": "digital"})
        self.assertEqual({r["id"]: r["severity"] for r in report["results"]}["hairlines"], "pass")
        textual = text_pdf(self.tmp / "t2.pdf", ["Flatten me"])
        with pikepdf.open(textual, allow_overwriting_input=True) as pdf:
            pdf.pages[0].obj.Group = pikepdf.Dictionary(S=pikepdf.Name.Transparency, CS=pikepdf.Name.DeviceRGB)
            pdf.save(textual)
        out4, res4 = self.run_ops(textual, [{"op": "flatten_transparency", "dpi": 150}], name="o4.pdf")
        self.assertEqual(res4["results"][0]["pages"], 1)
        self.assertIn("Flatten", text_of(out4), "text stays searchable")


if __name__ == "__main__":
    unittest.main(verbosity=1)
