"""Regressions for sanitize, links and page-design transforms. Run with a
Python that has the pinned pikepdf, pypdfium2, fontTools and Pillow wheels.

    python scripts/test_engine_extras.py
"""
from pathlib import Path
import json
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "EngineSupport"))
import pikepdf
from pikepdf import Name, Dictionary, Array
import pypdfium2 as pdfium
import transforms
from engine.errors import EngineError


def text_of(path, page=0):
    doc = pdfium.PdfDocument(str(path))
    try:
        return doc[page].get_textpage().get_text_range()
    finally:
        doc.close()


def helvetica(pdf):
    return pdf.make_indirect(Dictionary(Type=Name.Font, Subtype=Name.Type1, BaseFont=Name.Helvetica,
                                        Encoding=Name.WinAnsiEncoding))


def text_page(pdf, content, size=(612, 792), extra_res=None, rotate=0):
    page = pdf.add_blank_page(page_size=size)
    res = Dictionary(Font=Dictionary(F1=helvetica(pdf)))
    for key, value in (extra_res or {}).items():
        res[key] = value
    page.obj.Resources = res
    page.obj.Contents = pdf.make_stream(content)
    if rotate:
        page.obj.Rotate = rotate
    return page


def form(pdf, content, bbox=(0, 0, 200, 50), res=None, **keys):
    stream = pikepdf.Stream(pdf, content)
    stream.Type, stream.Subtype = Name.XObject, Name.Form
    stream.BBox = Array(list(bbox))
    stream.Resources = res if res is not None else Dictionary()
    for key, value in keys.items():
        stream[Name("/" + key)] = value
    return pdf.make_indirect(stream)


def js(pdf, code):
    return pdf.make_indirect(Dictionary(S=Name.JavaScript, JS=pikepdf.String(code)))


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="zpdf-extras-test-")
        self.tmp = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def run_ops(self, source, ops, name="out.pdf"):
        out = self.tmp / name
        if out.exists():
            out.unlink()
        return out, transforms.run(source, out, ops)

    def query(self, source, name, params=None):
        return transforms.inspect(source, name, params)

    def assertFails(self, code, source, ops):
        with self.assertRaises(EngineError) as ctx:
            self.run_ops(source, ops, name="failed.pdf")
        self.assertEqual(ctx.exception.code, code)
        self.assertFalse((self.tmp / "failed.pdf").exists())


# ---------------------------------------------------------------- sanitize

class SanitizeTests(Base):
    def build(self):
        pdf = pikepdf.new()
        font = helvetica(pdf)
        ocg_off = pdf.make_indirect(Dictionary(Type=Name.OCG, Name=pikepdf.String("Hidden layer")))
        ocg_on = pdf.make_indirect(Dictionary(Type=Name.OCG, Name=pikepdf.String("Shown layer")))
        pdf.Root.OCProperties = Dictionary(OCGs=Array([ocg_off, ocg_on]),
                                           D=Dictionary(ON=Array([ocg_on]), OFF=Array([ocg_off])))
        inner = form(pdf, b"/OC /oc1 BDC BT /F1 12 Tf 0 30 Td (FormSecret) Tj ET EMC "
                          b"BT /F1 12 Tf 0 5 Td (FormShown) Tj ET",
                     res=Dictionary(Font=Dictionary(F1=font), Properties=Dictionary(oc1=ocg_off)))
        hidden_xo = form(pdf, b"BT /F1 12 Tf 0 5 Td (XObjectSecret) Tj ET",
                         res=Dictionary(Font=Dictionary(F1=font)), OC=ocg_off)
        content = (b"BT /F1 12 Tf 72 700 Td (Visible text) Tj ET\n"
                   b"/OC /oc1 BDC BT /F1 12 Tf 72 650 Td (Secret words) Tj ET "
                   b"q BI /W 1 /H 1 /BPC 8 /CS /G ID \x00 EI Q EMC\n"
                   b"/OC /oc2 BDC BT /F1 12 Tf 72 620 Td (Layer shown) Tj ET EMC\n"
                   b"q 1 0 0 1 72 500 cm /Fm1 Do Q q 1 0 0 1 72 400 cm /Fm2 Do Q\n"
                   b"q BI /W 1 /H 1 /BPC 8 /CS /G ID \xff EI Q\n")
        page = pdf.add_blank_page(page_size=(612, 792))
        page.obj.Resources = Dictionary(Font=Dictionary(F1=font),
                                        Properties=Dictionary(oc1=ocg_off, oc2=ocg_on),
                                        XObject=Dictionary(Fm1=inner, Fm2=hidden_xo))
        page.obj.Contents = pdf.make_stream(content)
        page.obj.AA = Dictionary(O=js(pdf, "app.alert('page open')"))
        page.obj.PieceInfo = Dictionary(App=Dictionary(LastModified=pikepdf.String("D:2020")))
        # JavaScript: open action, name tree, link action.
        pdf.Root.OpenAction = js(pdf, "app.alert('open')")
        tree = pikepdf.NameTree.new(pdf)
        tree["init"] = js(pdf, "var x = 1;")
        files = pikepdf.NameTree.new(pdf)
        filespec = pikepdf.AttachedFileSpec(pdf, b"secret attachment", mime_type="text/plain")
        files["notes.txt"] = filespec.obj
        pdf.Root.Names = Dictionary(JavaScript=tree.obj, EmbeddedFiles=files.obj)
        # Metadata
        with pdf.open_metadata() as meta:
            meta["dc:title"] = "Secret title"
        pdf.docinfo["/Title"] = pikepdf.String("Secret title")
        pdf.docinfo["/Author"] = pikepdf.String("Someone")
        # Annotations
        annots = Array()
        annots.append(pdf.make_indirect(Dictionary(Type=Name.Annot, Subtype=Name.Link, Rect=[72, 690, 200, 712],
                                                   A=js(pdf, "app.launchURL('x')"))))
        annots.append(pdf.make_indirect(Dictionary(Type=Name.Annot, Subtype=Name.Link, Rect=[72, 600, 200, 612],
                                                   A=Dictionary(S=Name.URI, URI=pikepdf.String("https://example.com")))))
        note = pdf.make_indirect(Dictionary(Type=Name.Annot, Subtype=Name.Text, Rect=[300, 700, 320, 720],
                                            Contents=pikepdf.String("A comment")))
        popup = pdf.make_indirect(Dictionary(Type=Name.Annot, Subtype=Name.Popup, Rect=[320, 600, 500, 700],
                                             Parent=note))
        note.Popup = popup
        annots.extend([note, popup])
        annots.append(pdf.make_indirect(Dictionary(Type=Name.Annot, Subtype=Name.FileAttachment,
                                                   Rect=[400, 400, 420, 420], FS=filespec.obj)))
        annots.append(pdf.make_indirect(Dictionary(Type=Name.Annot, Subtype=Name.Square, Rect=[100, 100, 150, 150],
                                                   OC=ocg_off)))
        ap = form(pdf, b"BT /F1 10 Tf 2 5 Td (FieldValue) Tj ET", bbox=(0, 0, 150, 20),
                  res=Dictionary(Font=Dictionary(F1=font)))
        widget = pdf.make_indirect(Dictionary(Type=Name.Annot, Subtype=Name.Widget, FT=Name.Tx,
                                              T=pikepdf.String("name"), V=pikepdf.String("FieldValue"),
                                              Rect=[72, 300, 222, 320], AP=Dictionary(N=ap), F=4,
                                              AA=Dictionary(K=js(pdf, "event.rc = true;"))))
        widget.P = page.obj
        annots.append(widget)
        page.obj.Annots = annots
        pdf.Root.AcroForm = Dictionary(Fields=Array([widget]), DA=pikepdf.String("/Helv 0 Tf 0 g"))
        # Bookmarks: two top-level items, one child.
        outlines = pdf.make_indirect(Dictionary(Type=Name.Outlines))
        first = pdf.make_indirect(Dictionary(Title=pikepdf.String("One"), Parent=outlines,
                                             Dest=Array([page.obj, Name.Fit])))
        second = pdf.make_indirect(Dictionary(Title=pikepdf.String("Two"), Parent=outlines,
                                              A=js(pdf, "app.alert('bookmark')")))
        child = pdf.make_indirect(Dictionary(Title=pikepdf.String("Child"), Parent=first,
                                             Dest=Array([page.obj, Name.Fit])))
        first.First = first.Last = child
        first.Count = 1
        first.Next, second.Prev = second, first
        outlines.First, outlines.Last, outlines.Count = first, second, 3
        pdf.Root.Outlines = outlines
        pdf.Root.PageMode = Name.UseOutlines
        path = self.tmp / "dirty.pdf"
        pdf.save(path)
        return path

    def test_scan_counts(self):
        src = self.build()
        scan = self.query(src, "sanitize_scan")
        self.assertEqual(scan["metadata"], 4)  # Title, Author, Producer + XMP
        self.assertEqual(scan["javascript"], 6)  # open, tree, page AA, widget AA, link, bookmark
        self.assertEqual(scan["embedded_files"], 2)  # name tree entry, attachment annotation
        self.assertEqual(scan["hidden_layers"], 1)
        self.assertIsInstance(scan["hidden_text"], int)
        self.assertEqual(scan["bookmarks"], 3)
        self.assertEqual(scan["comments"], 3)  # note, file attachment, square (popup not counted)
        self.assertEqual(scan["form_fields"], 1)
        self.assertEqual(scan["links"], 2)
        self.assertGreaterEqual(scan["private_data"], 1)

    def test_default_sanitize(self):
        src = self.build()
        # PDFium's text layer includes hidden optional content, so the check below is meaningful.
        self.assertIn("Secret words", text_of(src))
        out, result = self.run_ops(src, [{"op": "sanitize"}])
        removed = result["results"][0]["removed"]
        self.assertEqual(removed["hidden_layers"], 1)
        self.assertEqual(removed["javascript"], 6)
        self.assertEqual(removed["embedded_files"], 2)
        text = text_of(out)
        for shown in ("Visible text", "Layer shown", "FormShown"):
            self.assertIn(shown, text)
        for secret in ("Secret words", "FormSecret", "XObjectSecret"):
            self.assertNotIn(secret, text)
        with pikepdf.open(out) as pdf:
            root = pdf.Root
            self.assertNotIn("/OCProperties", root)
            self.assertNotIn("/OpenAction", root)
            self.assertNotIn("/Names", root)
            self.assertNotIn("/Metadata", root)
            self.assertIsNone(pdf.trailer.get("/Info"))
            page = pdf.pages[0].obj
            self.assertNotIn("/AA", page)
            self.assertNotIn("/PieceInfo", page)
            subtypes = [str(a.Subtype) for a in page.Annots]
            # JS link removed, URI link kept, attachment and hidden square gone.
            self.assertEqual(subtypes.count("/Link"), 1)
            self.assertNotIn("/FileAttachment", subtypes)
            self.assertNotIn("/Square", subtypes)
            self.assertIn("/Text", subtypes)
            self.assertIn("/Widget", subtypes)
            widget = [a for a in page.Annots if a.Subtype == Name.Widget][0]
            self.assertNotIn("/AA", widget)
            # Bookmarks kept, but the JavaScript bookmark action is gone.
            self.assertIn("/Outlines", root)
            self.assertNotIn("/A", root.Outlines.First.Next)
            for obj in pdf.objects:
                if isinstance(obj, (pikepdf.Dictionary, pikepdf.Stream)):
                    self.assertNotEqual(str(obj.get("/S", "")), "/JavaScript")
                    self.assertNotIn("/OC", obj)
        rescan = self.query(out, "sanitize_scan")
        for key in ("javascript", "embedded_files", "hidden_layers", "private_data"):
            self.assertEqual(rescan[key], 0, key)
        self.assertEqual(rescan["metadata"], 0)

    def test_optional_categories(self):
        src = self.build()
        out, result = self.run_ops(src, [{"op": "sanitize", "bookmarks": True, "comments": True,
                                          "form_fields": True, "links": True}])
        removed = result["results"][0]["removed"]
        self.assertEqual(removed["bookmarks"], 3)
        self.assertEqual(removed["form_fields"], 1)
        self.assertEqual(removed["comments"], 1)  # the note; the attachment went with embedded files
        self.assertEqual(removed["links"], 1)  # the script link went with javascript
        with pikepdf.open(out) as pdf:
            self.assertNotIn("/Outlines", pdf.Root)
            self.assertEqual(pdf.Root.PageMode, Name.UseNone)
            self.assertNotIn("/AcroForm", pdf.Root)
            self.assertEqual(len(pdf.pages[0].obj.get("/Annots", [])), 0)
        # The field's appearance is now part of the page.
        self.assertIn("FieldValue", text_of(out))

    def test_toggles_off_keep_everything(self):
        src = self.build()
        out, _ = self.run_ops(src, [{"op": "sanitize", "metadata": False, "embedded_files": False,
                                     "javascript": False, "hidden_layers": False, "hidden_text": False,
                                     "private_data": False}])
        with pikepdf.open(out) as pdf:
            self.assertIn("/OpenAction", pdf.Root)
            self.assertIn("/OCProperties", pdf.Root)
            self.assertIn("/Title", pdf.docinfo)
            self.assertIn("/EmbeddedFiles", pdf.Root.Names)

    def test_real_fixtures_validate(self):
        import shutil
        for name in ("uscis-i9.pdf", "irs-w9.pdf", "ordinary-edge.pdf"):
            source = ROOT / "zPDFTests/Fixtures" / name
            if not source.exists():
                continue
            src = self.tmp / name
            shutil.copy(source, src)
            self.query(src, "sanitize_scan")
            out, result = self.run_ops(src, [{"op": "sanitize", "bookmarks": True, "comments": True,
                                              "form_fields": True, "links": True}], name="fx-" + name)
            self.assertGreater(result["page_count"], 0)
            with pikepdf.open(out) as pdf:
                self.assertNotIn("/AcroForm", pdf.Root)

    def test_openaction_chain_keeps_safe_actions(self):
        pdf = pikepdf.new()
        page = text_page(pdf, b"BT /F1 12 Tf 72 700 Td (Hi) Tj ET")
        goto = Dictionary(S=Name.GoTo, D=Array([page.obj, Name.Fit]))
        pdf.Root.OpenAction = Dictionary(S=Name.JavaScript, JS=pikepdf.String("x"), Next=Array([goto]))
        path = self.tmp / "chain.pdf"
        pdf.save(path)
        out, result = self.run_ops(path, [{"op": "sanitize"}])
        self.assertEqual(result["results"][0]["removed"]["javascript"], 1)
        with pikepdf.open(out) as check:
            self.assertEqual(check.Root.OpenAction.S, Name.GoTo)
            self.assertNotIn("/Next", check.Root.OpenAction)


# ---------------------------------------------------------------- links

class LinkTests(Base):
    def doc(self, pages=3):
        pdf = pikepdf.new()
        for n in range(pages):
            text_page(pdf, f"BT /F1 12 Tf 72 700 Td (Page {n + 1}) Tj ET".encode())
        path = self.tmp / "links.pdf"
        pdf.save(path)
        return path

    def test_round_trip(self):
        src = self.doc()
        out, result = self.run_ops(src, [
            {"op": "link_add", "page": 0, "rect": [200, 100, 72, 120], "uri": "https://example.com/a"},
            {"op": "link_add", "page": 0, "rect": [72, 200, 200, 220], "dest_page": 2, "border": [0, 0, 255]},
            {"op": "link_add", "page": 0, "rect": [72, 300, 200, 320], "dest_page": 1, "zoom": "xyz",
             "highlight": "none"},
        ])
        self.assertEqual([r["index"] for r in result["results"]], [0, 1, 2])
        links = self.query(out, "links", {"page": 0})["links"]
        self.assertEqual(links[0], {"index": 0, "rect": [72.0, 100.0, 200.0, 120.0],
                                    "uri": "https://example.com/a", "dest_page": None, "kind": "uri"})
        self.assertEqual(links[1]["dest_page"], 2)
        self.assertEqual(links[1]["kind"], "page")
        self.assertEqual(links[2]["dest_page"], 1)
        with pikepdf.open(out) as pdf:
            annots = pdf.pages[0].obj.Annots
            self.assertEqual(list(annots[0].Border), [0, 0, 0])
            self.assertEqual(annots[0].H, Name.I)
            self.assertEqual(list(annots[1].Border), [0, 0, 1])
            self.assertEqual(annots[2].H, Name.N)
            self.assertEqual(annots[2].Dest[1], Name.XYZ)
            self.assertTrue(annots[0].is_indirect)
        # Retarget a URI link to a page and move it; then remove two.
        out2, _ = self.run_ops(out, [{"op": "link_update", "page": 0, "index": 0, "dest_page": 1,
                                      "rect": [10, 10, 50, 30]}], name="o2.pdf")
        link = self.query(out2, "links", {"page": 0})["links"][0]
        self.assertEqual((link["uri"], link["dest_page"], link["rect"]), (None, 1, [10.0, 10.0, 50.0, 30.0]))
        with pikepdf.open(out2) as pdf:
            self.assertNotIn("/A", pdf.pages[0].obj.Annots[0])
        out3, _ = self.run_ops(out2, [{"op": "link_update", "page": 0, "index": 1, "uri": "mailto:a@b.org"}],
                               name="o3.pdf")
        link = self.query(out3, "links", {"page": 0})["links"][1]
        self.assertEqual((link["uri"], link["dest_page"]), ("mailto:a@b.org", None))
        out4, _ = self.run_ops(out3, [{"op": "link_remove", "page": 0, "indexes": [0, 2]}], name="o4.pdf")
        links = self.query(out4, "links", {"page": 0})["links"]
        self.assertEqual(len(links), 1)
        self.assertEqual(links[0]["uri"], "mailto:a@b.org")

    def test_named_destinations(self):
        pdf = pikepdf.new()
        for n in range(3):
            text_page(pdf, b"BT /F1 12 Tf 72 700 Td (x) Tj ET")
        dests = pikepdf.NameTree.new(pdf)
        dests["chapter"] = Array([pdf.pages[2].obj, Name.Fit])
        pdf.Root.Names = Dictionary(Dests=dests.obj)
        pdf.Root.Dests = Dictionary(old=Dictionary(D=Array([pdf.pages[1].obj, Name.Fit])))
        pdf.pages[0].obj.Annots = Array([
            pdf.make_indirect(Dictionary(Type=Name.Annot, Subtype=Name.Link, Rect=[0, 0, 10, 10],
                                         Dest=pikepdf.String("chapter"))),
            pdf.make_indirect(Dictionary(Type=Name.Annot, Subtype=Name.Link, Rect=[0, 0, 10, 10],
                                         A=Dictionary(S=Name.GoTo, D=Name("/old")))),
            pdf.make_indirect(Dictionary(Type=Name.Annot, Subtype=Name.Text, Rect=[0, 0, 10, 10])),
            pdf.make_indirect(Dictionary(Type=Name.Annot, Subtype=Name.Link, Rect=[0, 0, 10, 10],
                                         A=Dictionary(S=Name.Named, N=Name.NextPage))),
        ])
        path = self.tmp / "named.pdf"
        pdf.save(path)
        links = self.query(path, "links", {"page": 0})["links"]
        self.assertEqual([(l["index"], l["dest_page"], l["kind"]) for l in links],
                         [(0, 2, "page"), (1, 1, "page"), (3, None, "other")])
        # Index 2 is a Text note, not a link.
        self.assertFails("STALE_ANNOTATION", path, [{"op": "link_remove", "page": 0, "indexes": [0, 2]}])
        self.assertFails("STALE_ANNOTATION", path, [{"op": "link_update", "page": 0, "index": 9, "uri": "https://x.org"}])

    def test_invalid_arguments_fail_closed(self):
        src = self.doc()
        for bad in ("javascript:alert(1)", "file:///etc/passwd", "ftp://x.org", "https://", "notaurl"):
            self.assertFails("INVALID_ARGUMENT", src, [{"op": "link_add", "page": 0, "rect": [0, 0, 10, 10], "uri": bad}])
        self.assertFails("INVALID_ARGUMENT", src, [{"op": "link_add", "page": 0, "rect": [0, 0, 10, 10]}])
        self.assertFails("INVALID_ARGUMENT", src, [{"op": "link_add", "page": 0, "rect": [0, 0, 10, 10],
                                                    "uri": "https://x.org", "dest_page": 1}])
        self.assertFails("INVALID_ARGUMENT", src, [{"op": "link_add", "page": 0, "rect": [0, 0, 0, 10],
                                                    "uri": "https://x.org"}])
        self.assertFails("STALE_PAGE", src, [{"op": "link_add", "page": 0, "rect": [0, 0, 10, 10], "dest_page": 7}])


# ---------------------------------------------------------------- page design

class CropTests(Base):
    def doc(self, rotate=0, content=b"BT /F1 12 Tf 72 700 Td (Hello) Tj ET", pages=1):
        pdf = pikepdf.new()
        for _ in range(pages):
            text_page(pdf, content, rotate=rotate)
        path = self.tmp / f"crop{rotate}.pdf"
        pdf.save(path)
        return path

    def boxes(self, path):
        return self.query(path, "page_boxes")["pages"]

    def test_box_and_reset(self):
        src = self.doc(pages=2)
        with pikepdf.open(src, allow_overwriting_input=True) as pdf:
            pdf.pages[0].obj.TrimBox = Array([0, 0, 612, 792])
            pdf.save(src)
        out, result = self.run_ops(src, [{"op": "crop_pages", "pages": [0], "box": [50, 60, 700, 500]}])
        self.assertEqual(result["results"][0]["pages"], 1)
        boxes = self.boxes(out)
        self.assertEqual(boxes[0]["crop"], [50.0, 60.0, 612.0, 500.0])  # clamped to media
        self.assertEqual(boxes[1]["crop"], [0.0, 0.0, 612.0, 792.0])
        with pikepdf.open(out) as pdf:
            self.assertEqual([float(v) for v in pdf.pages[0].obj.TrimBox], [50, 60, 612, 500])
        out2, _ = self.run_ops(out, [{"op": "crop_pages", "reset": True}], name="o2.pdf")
        self.assertEqual(self.boxes(out2)[0]["crop"], [0.0, 0.0, 612.0, 792.0])
        with pikepdf.open(out2) as pdf:
            self.assertNotIn("/CropBox", pdf.pages[0].obj)

    def test_margins_rotated_page(self):
        src = self.doc(rotate=90)
        out, _ = self.run_ops(src, [{"op": "crop_pages", "margins": [0, 0, 0, 100]}])
        # On a /Rotate 90 page the visual top edge is the user-space left edge.
        box = self.boxes(out)[0]
        self.assertEqual(box["rotation"], 90)
        self.assertEqual(box["crop"], [100.0, 0.0, 612.0, 792.0])
        doc = pdfium.PdfDocument(str(out))
        try:
            width, height = doc[0].get_size()
        finally:
            doc.close()
        self.assertEqual((round(width), round(height)), (792, 512))
        src0 = self.doc(rotate=0)
        out0, _ = self.run_ops(src0, [{"op": "crop_pages", "margins": [10, 20, 30, 40]}], name="o0.pdf")
        self.assertEqual(self.boxes(out0)[0]["crop"], [10.0, 20.0, 582.0, 752.0])

    def test_remove_white_margins(self):
        content = b"0 0 1 rg 200 300 100 50 re f"
        src = self.doc(content=content, pages=2)
        with pikepdf.open(src, allow_overwriting_input=True) as pdf:
            pdf.pages[1].obj.Contents = pdf.make_stream(b"")  # blank page is skipped
            pdf.save(src)
        out, result = self.run_ops(src, [{"op": "crop_pages", "remove_white_margins": True}])
        self.assertEqual(result["results"][0]["pages"], 1)
        crop = self.boxes(out)[0]["crop"]
        for got, want in zip(crop, [198, 298, 302, 352]):
            self.assertAlmostEqual(got, want, delta=1.5)
        self.assertEqual(self.boxes(out)[1]["crop"], [0.0, 0.0, 612.0, 792.0])

    def test_remove_white_margins_rotated(self):
        src = self.doc(rotate=90, content=b"0 g 200 300 100 50 re f")
        out, _ = self.run_ops(src, [{"op": "crop_pages", "remove_white_margins": True}])
        crop = self.boxes(out)[0]["crop"]
        for got, want in zip(crop, [198, 298, 302, 352]):
            self.assertAlmostEqual(got, want, delta=1.5)

    def test_invalid_crop_fails_closed(self):
        src = self.doc()
        self.assertFails("INVALID_ARGUMENT", src, [{"op": "crop_pages", "box": [0, 0, 10, 10]}])
        self.assertFails("INVALID_ARGUMENT", src, [{"op": "crop_pages", "box": [700, 800, 900, 900]}])
        self.assertFails("INVALID_ARGUMENT", src, [{"op": "crop_pages", "margins": [300, 0, 300, 0]}])
        self.assertFails("INVALID_ARGUMENT", src, [{"op": "crop_pages", "box": [0, 0, 100, 100], "reset": True}])
        self.assertFails("INVALID_ARGUMENT", src, [{"op": "crop_pages"}])
        self.assertFails("INVALID_ARGUMENT", src, [{"op": "crop_pages", "pages": [4], "reset": True}])


class DesignTests(Base):
    def test_tag_and_read_back(self):
        pdf = pikepdf.new()
        for _ in range(3):
            text_page(pdf, b"BT /F1 12 Tf 72 700 Td (Body) Tj ET")
        src = self.tmp / "design.pdf"
        pdf.save(src)
        settings = {"text": "DRAFT", "opacity": 0.3, "pages": [0, 2]}
        out, result = self.run_ops(src, [
            {"op": "watermark", "text": "DRAFT", "pages": [0, 2]},
            {"op": "tag_overlay_settings", "kind": "Watermark", "settings": settings},
            {"op": "tag_overlay_settings", "kind": "Bates", "settings": {}},
        ])
        self.assertEqual(result["results"][1]["tagged"], 1)
        self.assertEqual(result["results"][2]["tagged"], 0)
        design = self.query(out, "page_design")
        self.assertEqual(design["Watermark"], {"pages": [0, 2], "settings": settings})
        self.assertEqual(design["Bates"], {"pages": [], "settings": None})
        self.assertEqual(set(design), {"Watermark", "HeaderFooter", "Background", "Bates"})
        # Replacing the watermark drops the old settings with the old form.
        out2, _ = self.run_ops(out, [{"op": "watermark", "text": "NEW"}], name="o2.pdf")
        design = self.query(out2, "page_design")
        self.assertEqual(design["Watermark"], {"pages": [0, 1, 2], "settings": None})
        self.assertFails("INVALID_ARGUMENT", src, [{"op": "tag_overlay_settings", "kind": "Nope", "settings": {}}])
        self.assertFails("INVALID_ARGUMENT", src, [{"op": "tag_overlay_settings", "kind": "Watermark",
                                                    "settings": {"x": float("nan")}}])


if __name__ == "__main__":
    unittest.main(verbosity=1)
