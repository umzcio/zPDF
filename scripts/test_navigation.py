"""Navigation / properties regressions (bookmarks, destinations, attachments,
layers, articles, 3D, document properties, initial view, JavaScript).

    build/devenv/bin/python scripts/test_navigation.py
"""
import base64
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "EngineSupport"))
import pikepdf
from pikepdf import Array, Dictionary, Name, String
import pypdfium2 as pdfium
import transforms
from engine.errors import EngineError

FIXTURES = ROOT / "zPDFTests/Fixtures"


def helvetica(pdf):
    return pdf.make_indirect(Dictionary(Type=Name.Font, Subtype=Name.Type1, BaseFont=Name.Helvetica,
                                        Encoding=Name.WinAnsiEncoding))


def text_page(pdf, lines):
    """lines: [(size, y, text)]"""
    font = helvetica(pdf)
    ops = []
    for size, y, value in lines:
        ops.append(f"BT /F1 {size} Tf 72 {y} Td ({value}) Tj ET")
    page = pdf.add_blank_page(page_size=(612, 792))
    page.obj.Resources = Dictionary(Font=Dictionary(F1=font))
    page.obj.Contents = pdf.make_stream("\n".join(ops).encode())
    return page


def headings_pdf(path):
    pdf = pikepdf.new()
    text_page(pdf, [(24, 700, "Introduction"), (11, 670, "Body text line one about the report."),
                    (11, 655, "Body text line two continues here."), (16, 620, "Background"),
                    (11, 600, "More body text here to set the median size.")])
    text_page(pdf, [(24, 700, "Methods"), (16, 660, "Sampling"), (11, 640, "Body text about sampling methods."),
                    (11, 625, "Body text again, plenty of it for the median."), (11, 610, "Even more body text.")])
    pdf.save(path)
    return path


def rendered_ink(path, page=0, box=None):
    doc = pdfium.PdfDocument(str(path))
    try:
        bitmap = doc[page].render(scale=1).to_pil().convert("L")
        if box:
            h = bitmap.height
            l, b, r, t = box
            bitmap = bitmap.crop((int(l), int(h - t), int(r), int(h - b)))
        return sum(1 for px in bitmap.getdata() if px < 128)
    finally:
        doc.close()


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="zpdf-nav-test-")
        self.tmp = Path(self._tmp.name)
        self.n = 0

    def tearDown(self):
        self._tmp.cleanup()

    def fixture(self, name):
        target = self.tmp / name
        shutil.copy(FIXTURES / name, target)
        return target

    def run_ops(self, source, ops):
        self.n += 1
        out = self.tmp / f"out{self.n}.pdf"
        result = transforms.run(source, out, ops)
        return out, result

    def q(self, source, name, **params):
        return transforms.inspect(source, name, params)


class OutlineTests(Base):
    def test_set_query_roundtrip_and_styles(self):
        src = headings_pdf(self.tmp / "h.pdf")
        tree = [{"title": "Chapter 1", "page": 0, "top": 700, "open": True, "bold": True, "color": [255, 0, 0],
                 "children": [{"title": "Section 1.1", "page": 0, "top": 620},
                              {"title": "Web", "uri": "https://example.com"}]},
                {"title": "Chapter 2", "page": 1, "zoom": 1.5, "top": 700, "left": 10}]
        out, result = self.run_ops(src, [{"op": "set_outline", "items": tree}])
        self.assertEqual(result["results"][0]["count"], 4)
        items = self.q(out, "outline")["items"]
        self.assertEqual([i["title"] for i in items], ["Chapter 1", "Chapter 2"])
        self.assertTrue(items[0]["open"] and items[0]["bold"])
        self.assertEqual(items[0]["color"], [255, 0, 0])
        self.assertEqual(items[0]["children"][0]["page"], 0)
        self.assertEqual(items[0]["children"][1]["uri"], "https://example.com")
        self.assertEqual(items[1]["page"], 1)
        self.assertAlmostEqual(items[1]["zoom"], 1.5)
        with pikepdf.open(out) as pdf:
            self.assertEqual(int(pdf.Root.Outlines.Count), 4)  # open chapter shows its 2 kids
        # Reorder/nest via round trip; keep refs; delete all.
        items[1]["children"] = [items[0]["children"].pop(0)]
        out2, _ = self.run_ops(out, [{"op": "set_outline", "items": items}])
        again = self.q(out2, "outline")["items"]
        self.assertEqual(again[1]["children"][0]["title"], "Section 1.1")
        out3, _ = self.run_ops(out2, [{"op": "set_outline", "items": []}])
        self.assertEqual(self.q(out3, "outline")["items"], [])

    def test_unknown_action_is_preserved_via_ref(self):
        src = headings_pdf(self.tmp / "h.pdf")
        with pikepdf.open(src, allow_overwriting_input=True) as pdf:
            item = pdf.make_indirect(Dictionary(Title=String("Script"),
                                                A=Dictionary(S=Name.JavaScript, JS=String("app.alert(1)"))))
            root = pdf.make_indirect(Dictionary(Type=Name.Outlines, First=item, Last=item, Count=1))
            item.Parent = root
            pdf.Root.Outlines = root
            pdf.save(src)
        items = self.q(src, "outline")["items"]
        self.assertEqual(items[0]["action"], "JavaScript")
        items[0]["title"] = "Renamed"
        out, _ = self.run_ops(src, [{"op": "set_outline", "items": items}])
        with pikepdf.open(out) as pdf:
            self.assertEqual(str(pdf.Root.Outlines.First.A.S), "/JavaScript")
            self.assertEqual(str(pdf.Root.Outlines.First.Title), "Renamed")

    def test_outline_from_headings(self):
        src = headings_pdf(self.tmp / "h.pdf")
        detected = self.q(src, "detect_headings")["items"]
        self.assertEqual([h["title"] for h in detected], ["Introduction", "Background", "Methods", "Sampling"])
        self.assertEqual([h["level"] for h in detected], [1, 2, 1, 2])
        out, result = self.run_ops(src, [{"op": "outline_from_headings"}])
        self.assertEqual(result["results"][0]["added"], 4)
        items = self.q(out, "outline")["items"]
        self.assertEqual([i["title"] for i in items], ["Introduction", "Methods"])
        self.assertEqual(items[0]["children"][0]["title"], "Background")
        self.assertEqual(items[1]["children"][0]["page"], 1)

    def test_no_headings_fails_closed(self):
        src = self.tmp / "plain.pdf"
        pdf = pikepdf.new()
        text_page(pdf, [(11, 700, "only body"), (11, 680, "text here")])
        pdf.save(src)
        with self.assertRaises(EngineError) as ctx:
            self.run_ops(src, [{"op": "outline_from_headings"}])
        self.assertEqual(ctx.exception.code, "NO_HEADINGS")

    def test_fixture_outline_query(self):
        for name in ("uscis-i9.pdf", "irs-w9.pdf", "ordinary-edge.pdf"):
            result = self.q(self.fixture(name), "outline")
            self.assertIn("items", result)


class DestinationTests(Base):
    def test_add_rename_remove_and_references(self):
        src = headings_pdf(self.tmp / "h.pdf")
        out, _ = self.run_ops(src, [{"op": "add_destination", "name": "intro", "page": 0, "top": 700},
                                    {"op": "add_destination", "name": "methods", "page": 1},
                                    {"op": "set_outline", "items": [{"title": "Go", "dest_name": "intro"}]}])
        items = self.q(out, "destinations")["items"]
        self.assertEqual([i["name"] for i in items], ["intro", "methods"])
        self.assertEqual(items[0]["page"], 0)
        self.assertEqual(items[0]["top"], 700)
        self.assertEqual(items[1]["fit"], "Fit")
        with self.assertRaises(EngineError):
            self.run_ops(out, [{"op": "add_destination", "name": "intro", "page": 1}])
        out2, res = self.run_ops(out, [{"op": "rename_destination", "old": "intro", "new": "start"}])
        self.assertEqual(res["results"][0]["references"], 1)
        outline = self.q(out2, "outline")["items"]
        self.assertEqual(outline[0]["dest_name"], "start")
        self.assertEqual(outline[0]["page"], 0)
        out3, _ = self.run_ops(out2, [{"op": "remove_destinations", "names": ["methods"]}])
        self.assertEqual([i["name"] for i in self.q(out3, "destinations")["items"]], ["start"])


class AttachmentTests(Base):
    def test_add_list_extract_describe_remove(self):
        src = headings_pdf(self.tmp / "h.pdf")
        payload = self.tmp / "notes.txt"
        payload.write_text("hello attachment ✓", encoding="utf-8")
        out, result = self.run_ops(src, [{"op": "add_attachment", "path": str(payload), "description": "Notes"},
                                         {"op": "add_attachment", "path": str(payload)}])
        self.assertEqual(result["results"][1]["name"], "notes (2).txt")
        items = self.q(out, "attachments")["items"]
        self.assertEqual([i["name"] for i in items], ["notes (2).txt", "notes.txt"])
        first = next(i for i in items if i["name"] == "notes.txt")
        self.assertEqual(first["description"], "Notes")
        self.assertEqual(first["mime"], "text/plain")
        self.assertEqual(first["size"], len(payload.read_bytes()))
        data = self.q(out, "attachment_data", id=first["id"])
        self.assertEqual(base64.b64decode(data["data"]), payload.read_bytes())
        out2, _ = self.run_ops(out, [{"op": "describe_attachment", "id": first["id"], "description": "Changed"},
                                     {"op": "remove_attachments", "ids": ["tree:notes (2).txt"]}])
        items = self.q(out2, "attachments")["items"]
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["description"], "Changed")
        with pikepdf.open(out2) as pdf:
            self.assertEqual(len(pdf.attachments), 1)

    def test_annotation_attachment_listed(self):
        src = headings_pdf(self.tmp / "h.pdf")
        with pikepdf.open(src, allow_overwriting_input=True) as pdf:
            stream = pikepdf.Stream(pdf, b"inner")
            stream.Type = Name.EmbeddedFile
            fs = Dictionary(Type=Name.Filespec, F=String("clip.bin"), EF=Dictionary(F=stream))
            pdf.pages[0].obj.Annots = Array([pdf.make_indirect(Dictionary(Type=Name.Annot, Subtype=Name.FileAttachment,
                                                                          Rect=[10, 10, 30, 30], FS=fs))])
            pdf.save(src)
        items = self.q(src, "attachments")["items"]
        self.assertEqual(items[0]["id"], "annot:0:0")
        self.assertEqual(base64.b64decode(self.q(src, "attachment_data", id="annot:0:0")["data"]), b"inner")
        out, _ = self.run_ops(src, [{"op": "remove_attachments", "ids": ["annot:0:0"]}])
        self.assertEqual(self.q(out, "attachments")["items"], [])


def layered_pdf(path):
    pdf = pikepdf.new()
    font = helvetica(pdf)
    visible = pdf.make_indirect(Dictionary(Type=Name.OCG, Name=String("Visible layer")))
    hidden = pdf.make_indirect(Dictionary(Type=Name.OCG, Name=String("Hidden layer")))
    page = pdf.add_blank_page(page_size=(612, 792))
    page.obj.Resources = Dictionary(Font=Dictionary(F1=font), Properties=Dictionary(oc1=visible, oc2=hidden))
    page.obj.Contents = pdf.make_stream(
        b"/OC /oc1 BDC BT /F1 24 Tf 72 700 Td (SHOWN TEXT) Tj ET EMC\n"
        b"/OC /oc2 BDC 0 0 1 rg 72 400 200 100 re f BT /F1 24 Tf 72 300 Td (SECRET TEXT) Tj ET EMC\n"
        b"BT /F1 12 Tf 72 100 Td (plain) Tj ET")
    pdf.Root.OCProperties = Dictionary(OCGs=Array([visible, hidden]),
                                       D=Dictionary(Order=Array([String("Group"), visible, hidden]) if False else Array([visible, Array([String("Group"), hidden])]),
                                                    ON=Array([visible]), OFF=Array([hidden])))
    pdf.save(path)
    return path


class LayerTests(Base):
    def text(self, path):
        doc = pdfium.PdfDocument(str(path))
        try:
            return doc[0].get_textpage().get_text_range()
        finally:
            doc.close()

    def test_list_toggle_flatten(self):
        src = layered_pdf(self.tmp / "l.pdf")
        items = self.q(src, "layers")["items"]
        layers = [i for i in items if i["kind"] == "layer"]
        self.assertEqual([(l["name"], l["visible"]) for l in layers], [("Visible layer", True), ("Hidden layer", False)])
        self.assertTrue(any(i["kind"] == "label" and i["name"] == "Group" for i in items))
        self.assertEqual(layers[1]["depth"], 1)
        hidden_id = layers[1]["id"]
        # PDFium honours the default configuration.
        self.assertEqual(rendered_ink(src, box=(72, 400, 272, 500)), 0)
        out, _ = self.run_ops(src, [{"op": "set_layer_visibility", "states": {hidden_id: True}}])
        self.assertTrue(all(l["visible"] for l in self.q(out, "layers")["items"] if l["kind"] == "layer"))
        self.assertGreater(rendered_ink(out, box=(72, 400, 272, 500)), 100)
        # Flatten with the hidden layer off drops its content entirely.
        flat, result = self.run_ops(src, [{"op": "flatten_layers"}])
        self.assertGreaterEqual(result["results"][0]["dropped"], 2)
        text = self.text(flat)
        self.assertIn("SHOWN TEXT", text)
        self.assertNotIn("SECRET TEXT", text)
        self.assertIn("plain", text)
        with pikepdf.open(flat) as pdf:
            self.assertNotIn("/OCProperties", pdf.Root)
            self.assertNotIn(b"/OC", pdf.pages[0].obj.Contents.read_bytes())
        self.assertFalse(self.q(flat, "layers")["has_layers"])

    def test_no_layers(self):
        src = headings_pdf(self.tmp / "h.pdf")
        self.assertFalse(self.q(src, "layers")["has_layers"])
        with self.assertRaises(EngineError):
            self.run_ops(src, [{"op": "flatten_layers"}])


class ArticleAnd3DTests(Base):
    def test_threads_and_models(self):
        src = headings_pdf(self.tmp / "h.pdf")
        with pikepdf.open(src, allow_overwriting_input=True) as pdf:
            p0, p1 = pdf.pages[0].obj, pdf.pages[1].obj
            thread = pdf.make_indirect(Dictionary(Type=Name.Thread, I=Dictionary(Title=String("Story"))))
            b1 = pdf.make_indirect(Dictionary(Type=Name.Bead, T=thread, P=p0, R=[72, 500, 300, 720]))
            b2 = pdf.make_indirect(Dictionary(Type=Name.Bead, T=thread, P=p1, R=[72, 400, 300, 720]))
            b1.N, b1.V, b2.N, b2.V = b2, b2, b1, b1
            thread.F = b1
            pdf.Root.Threads = Array([thread])
            dd = pikepdf.Stream(pdf, b"U3D")
            dd.Type, dd.Subtype = Name("/3D"), Name.U3D
            dd.VA = Array([Dictionary(Type=Name("/3DView"), XN=String("Front"))])
            model = pdf.make_indirect(Dictionary(Type=Name.Annot, Subtype=Name("/3D"), Rect=[0, 0, 100, 100],
                                                 Contents=String("Engine")))
            model[Name("/3DD")] = dd
            p1.Annots = Array([model])
            pdf.save(src)
        threads = self.q(src, "articles")["threads"]
        self.assertEqual(threads[0]["title"], "Story")
        self.assertEqual([b["page"] for b in threads[0]["beads"]], [0, 1])
        models = self.q(src, "models_3d")["items"]
        self.assertEqual(models[0]["name"], "Engine")
        self.assertEqual(models[0]["format"], "U3D")
        self.assertEqual(models[0]["views"], ["Front"])

    def test_content_objects(self):
        src = layered_pdf(self.tmp / "l.pdf")
        result = self.q(src, "content_objects", page=0)
        types = [o["type"] for o in result["objects"]]
        self.assertIn("text", types)
        self.assertIn("path", types)
        self.assertTrue(any(o["text"] and "SHOWN" in o["text"] for o in result["objects"]))


class PropertiesTests(Base):
    def test_properties_and_metadata_sync(self):
        src = self.fixture("uscis-i9.pdf")
        props = self.q(src, "document_properties")
        self.assertGreater(props["page_count"], 0)
        self.assertTrue(self.q(src, "fonts")["items"])
        out, _ = self.run_ops(src, [{"op": "set_metadata",
                                     "info": {"title": "Új cím ✓", "author": "Ann; Bob", "subject": "S", "keywords": "a, b"},
                                     "custom": {"Department": "Legal"}}])
        props = self.q(out, "document_properties")
        self.assertEqual(props["info"]["title"], "Új cím ✓")
        self.assertEqual(props["custom"]["Department"], "Legal")
        self.assertIn("Legal", props["xmp"])
        with pikepdf.open(out) as pdf:
            meta = pdf.open_metadata()
            self.assertEqual(meta["dc:title"], "Új cím ✓")
            self.assertEqual(meta["dc:creator"], ["Ann", "Bob"])
            self.assertEqual(meta["pdf:Keywords"], "a, b")
            self.assertEqual(str(pdf.docinfo.Title), "Új cím ✓")
        out2, _ = self.run_ops(out, [{"op": "set_metadata", "info": {"subject": ""}, "remove_custom": ["Department"]}])
        props = self.q(out2, "document_properties")
        self.assertIsNone(props["info"]["subject"])
        self.assertNotIn("Department", props["custom"])
        with pikepdf.open(out2) as pdf:
            self.assertNotIn("dc:description", pdf.open_metadata())
        with self.assertRaises(EngineError):
            self.run_ops(out, [{"op": "set_metadata", "custom": {"Title": "x"}}])

    def test_set_xmp_validates(self):
        src = headings_pdf(self.tmp / "h.pdf")
        with self.assertRaises(EngineError):
            self.run_ops(src, [{"op": "set_xmp", "xmp": "<broken"}])
        xmp = ('<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
               '<rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title><rdf:Alt>'
               '<rdf:li xml:lang="x-default">From XMP</rdf:li></rdf:Alt></dc:title></rdf:Description></rdf:RDF></x:xmpmeta>')
        out, _ = self.run_ops(src, [{"op": "set_xmp", "xmp": xmp}])
        self.assertEqual(self.q(out, "document_properties")["info"]["title"], "From XMP")

    def test_initial_view(self):
        src = headings_pdf(self.tmp / "h.pdf")
        out, _ = self.run_ops(src, [{"op": "set_initial_view", "page_layout": "TwoPageRight", "page_mode": "UseOutlines",
                                     "open_page": 1, "open_zoom": 150,
                                     "viewer_preferences": {"DisplayDocTitle": True, "HideToolbar": True,
                                                            "PrintScaling": "None", "NumCopies": 2}}])
        view = self.q(out, "document_properties")["initial_view"]
        self.assertEqual(view["page_layout"], "TwoPageRight")
        self.assertEqual(view["page_mode"], "UseOutlines")
        self.assertEqual(view["open"]["page"], 1)
        self.assertEqual(view["open"]["zoom"], 150)
        self.assertTrue(view["viewer_preferences"]["DisplayDocTitle"])
        self.assertEqual(view["viewer_preferences"]["PrintScaling"], "None")
        self.assertEqual(view["viewer_preferences"]["NumCopies"], 2)
        out2, _ = self.run_ops(out, [{"op": "set_initial_view", "page_layout": None, "open_page": 0, "open_zoom": "fit_page",
                                      "viewer_preferences": {"HideToolbar": False}}])
        view = self.q(out2, "document_properties")["initial_view"]
        self.assertIsNone(view["page_layout"])
        self.assertEqual(view["page_mode"], "UseOutlines")
        self.assertEqual(view["open"]["zoom"], "fit_page")
        self.assertFalse(view["viewer_preferences"]["HideToolbar"])

    def test_fonts_list(self):
        src = headings_pdf(self.tmp / "h.pdf")
        fonts = self.q(src, "fonts")["items"]
        self.assertEqual(fonts[0]["name"], "Helvetica")
        self.assertFalse(fonts[0]["embedded"])
        self.assertEqual(fonts[0]["encoding"], "WinAnsiEncoding")
        self.assertEqual(sorted(p for f in fonts for p in f["pages"]), [0, 1])

    def test_linearize(self):
        src = headings_pdf(self.tmp / "h.pdf")
        out, _ = self.run_ops(src, [{"op": "linearize"}])
        self.assertTrue(self.q(out, "document_properties")["linearized"])

    def test_list_operations(self):
        src = headings_pdf(self.tmp / "h.pdf")
        ops = self.q(src, "list_operations")
        self.assertIn("set_outline", ops["ops"])
        self.assertIn("outline", ops["queries"])


class JavaScriptTests(Base):
    def test_inspect_and_remove(self):
        src = headings_pdf(self.tmp / "h.pdf")
        with pikepdf.open(src, allow_overwriting_input=True) as pdf:
            names = pikepdf.NameTree.new(pdf)
            names["init"] = Dictionary(S=Name.JavaScript, JS=String("var x = 1;"))
            pdf.Root.Names = Dictionary(JavaScript=names.obj)
            pdf.Root.OpenAction = Dictionary(S=Name.JavaScript, JS=String("app.alert('hi')"),
                                             Next=Dictionary(S=Name.GoTo, D=Array([pdf.pages[1].obj, Name.Fit])))
            pdf.Root.AA = Dictionary(WC=Dictionary(S=Name.JavaScript, JS=pdf.make_stream(b"closing();")))
            pdf.pages[0].obj.AA = Dictionary(O=Dictionary(S=Name.JavaScript, JS=String("pageOpen()")))
            link = pdf.make_indirect(Dictionary(Type=Name.Annot, Subtype=Name.Link, Rect=[0, 0, 50, 50],
                                                A=Dictionary(S=Name.JavaScript, JS=String("linkClick()"))))
            pdf.pages[0].obj.Annots = Array([link])
            pdf.save(src)
        items = self.q(src, "document_javascript")["items"]
        by_id = {i["id"]: i for i in items}
        self.assertEqual(set(by_id), {"names:init", "open", "catalog_aa:WC", "page_aa:0:O", "annot_a:0:0"})
        self.assertEqual(by_id["catalog_aa:WC"]["script"], "closing();")
        self.assertEqual(by_id["annot_a:0:0"]["location"], "link")
        out, res = self.run_ops(src, [{"op": "remove_javascript", "ids": ["open", "annot_a:0:0"]}])
        self.assertEqual(res["results"][0]["removed"], 2)
        with pikepdf.open(out) as pdf:
            self.assertEqual(str(pdf.Root.OpenAction.S), "/GoTo")  # chained GoTo survives
        remaining = {i["id"] for i in self.q(out, "document_javascript")["items"]}
        self.assertEqual(remaining, {"names:init", "catalog_aa:WC", "page_aa:0:O"})
        out2, _ = self.run_ops(out, [{"op": "remove_javascript"}])
        self.assertEqual(self.q(out2, "document_javascript")["items"], [])
        with pikepdf.open(out2) as pdf:
            self.assertNotIn("/AA", pdf.Root)
        with self.assertRaises(EngineError):
            self.run_ops(out2, [{"op": "remove_javascript", "ids": ["open"]}])


class PrintingAndAutomationTests(Base):
    def test_keep_pages_and_optional_steps(self):
        src = headings_pdf(self.tmp / "h.pdf")
        out, result = self.run_ops(src, [{"op": "keep_pages", "pages": [1]}])
        self.assertEqual(result["page_count"], 1)
        self.assertIn("Methods", pdfium.PdfDocument(str(out))[0].get_textpage().get_text_range())
        with self.assertRaises(EngineError):
            self.run_ops(src, [{"op": "keep_pages", "pages": [5]}])
        # Not-applicable steps are skipped; real errors still fail closed.
        out, result = self.run_ops(src, [{"op": "optional", "step": {"op": "flatten_layers"}},
                                         {"op": "watermark", "text": "OK"}])
        self.assertTrue(result["results"][0]["skipped"])
        with self.assertRaises(EngineError):
            self.run_ops(src, [{"op": "optional", "step": {"op": "keep_pages", "pages": [9]}}])
        with self.assertRaises(EngineError):
            self.run_ops(src, [{"op": "optional", "step": {"op": "optional", "step": {"op": "finalize"}}}])


if __name__ == "__main__":
    unittest.main(verbosity=1)
