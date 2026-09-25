"""Accessibility engine regressions (checker, fixes, autotag, tag editing).
Run with the dev venv that has the pinned pikepdf/pypdfium2 wheels:

    python scripts/test_accessibility.py
"""
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "EngineSupport"))
import pikepdf
from pikepdf import Array, Dictionary, Name
import pypdfium2 as pdfium
import pypdfium2.raw as pdfium_c
import transforms
from engine.errors import EngineError

FIXTURES = ROOT / "zPDFTests/Fixtures"
FIXTURE_NAMES = ["uscis-i9", "irs-w9", "ordinary-edge", "irs-1040-worksheet-b", "export-numeric-table"]


def texts(path):
    doc = pdfium.PdfDocument(str(path))
    try:
        out = []
        for i in range(len(doc)):
            tp = doc[i].get_textpage()
            out.append(tp.get_text_range())
            tp.close()
        return out
    finally:
        doc.close()


def page_mcids(path):
    """{page index: set of MCIDs on top-level page objects} via PDFium."""
    doc = pdfium.PdfDocument(str(path))
    result = {}
    try:
        for i in range(len(doc)):
            page = doc[i]
            found = set()
            for j in range(pdfium_c.FPDFPage_CountObjects(page.raw)):
                obj = pdfium_c.FPDFPage_GetObject(page.raw, j)
                m = pdfium_c.FPDFPageObj_GetMarkedContentID(obj)
                if m >= 0:
                    found.add(m)
            result[i] = found
    finally:
        doc.close()
    return result


def owns(elem, mcid, page):
    k = elem.get("/K")
    items = list(k) if isinstance(k, Array) else ([] if k is None else [k])
    for item in items:
        if isinstance(item, int) and item == mcid and elem.Pg.objgen == page.objgen:
            return True
        if isinstance(item, Dictionary) and item.get("/Type") == Name.MCR and int(item.MCID) == mcid:
            pg = item.get("/Pg") or elem.get("/Pg")
            if pg.objgen == page.objgen:
                return True
    return False


def parent_tree(pdf):
    nums = list(pdf.Root.StructTreeRoot.ParentTree.Nums)
    return {int(nums[i]): nums[i + 1] for i in range(0, len(nums), 2)}


def text_op(x, y, text, font="/F1", size=11):
    return f"BT {font} {size} Tf {x} {y} Td ({text}) Tj ET\n"


def sample_pdf(path, link=True):
    """Heading, paragraphs, bullet list, image, 3x3 table, decorative rule; 2 pages."""
    pdf = pikepdf.new()
    helv = pdf.make_indirect(Dictionary(Type=Name.Font, Subtype=Name.Type1, BaseFont=Name.Helvetica,
                                        Encoding=Name.WinAnsiEncoding))
    bold = pdf.make_indirect(Dictionary(Type=Name.Font, Subtype=Name("/Type1"), BaseFont=Name("/Helvetica-Bold"),
                                        Encoding=Name.WinAnsiEncoding))
    image = pikepdf.Stream(pdf, bytes([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0]))
    image.Type, image.Subtype = Name.XObject, Name.Image
    image.Width, image.Height, image.ColorSpace, image.BitsPerComponent = 2, 2, Name.DeviceRGB, 8
    res = Dictionary(Font=Dictionary(F1=helv, F2=bold), XObject=Dictionary(Im1=pdf.make_indirect(image)))
    c = ""
    c += "0.5 w 72 705 m 540 705 l S\n"
    c += text_op(72, 720, "Annual Report", "/F2", 28)
    c += text_op(72, 680, "This report describes the year in review for the whole team.")
    c += text_op(72, 666, "It continues on a second line with more words to read.")
    c += text_op(72, 652, "And a third line closes the first paragraph neatly.")
    c += text_op(72, 620, "A second paragraph starts after a clear gap in the text.")
    c += text_op(72, 606, "It has two lines of body text.")
    for i, y in enumerate((570, 556, 542)):
        c += f"BT /F1 11 Tf 72 {y} Td (\\225) Tj 12 0 Td (List item number {i + 1}) Tj ET\n"
    c += "q 100 0 0 80 72 420 cm /Im1 Do Q\n"
    rows = [("Name", "Qty", "Price"), ("Apples", "3", "1.20"), ("Pears", "5", "2.50")]
    for r, row in enumerate(rows):
        y = 360 - 16 * r
        for col, x in enumerate((72, 220, 360)):
            c += text_op(x, y, row[col], "/F2" if r == 0 else "/F1")
    c += text_op(72, 280, "Closing remarks follow the table in a final paragraph.")
    page = pdf.add_blank_page(page_size=(612, 792))
    page.obj.Resources = res
    page.obj.Contents = pdf.make_stream(c.encode("latin-1"))
    page2 = pdf.add_blank_page(page_size=(612, 792))
    page2.obj.Resources = res
    page2.obj.Contents = pdf.make_stream((text_op(72, 720, "Second page body text is here.") +
                                          text_op(72, 706, "More text on the second page.")).encode())
    if link:
        annot = pdf.make_indirect(Dictionary(Type=Name.Annot, Subtype=Name.Link, Rect=[72, 700, 250, 730],
                                             Border=[0, 0, 0], A=Dictionary(S=Name.URI, URI="https://example.com")))
        page2.obj.Annots = Array([annot])
    pdf.save(path)
    return path


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="zpdf-a11y-test-")
        self.tmp = Path(self._tmp.name)
        self.n = 0

    def tearDown(self):
        self._tmp.cleanup()

    def fixture(self, name):
        target = self.tmp / f"{name}.pdf"
        shutil.copy(FIXTURES / f"{name}.pdf", target)
        return target

    def run_ops(self, source, ops):
        self.n += 1
        out = self.tmp / f"out{self.n}.pdf"
        result = transforms.run(source, out, ops)
        return out, result["results"]

    def check(self, path):
        report = transforms.inspect(path, "accessibility_check")
        return report, {item["id"]: item for item in report["items"]}

    def tree(self, path):
        return transforms.inspect(path, "structure_tree")

    def flat(self, node, out=None):
        out = [] if out is None else out
        out.append(node)
        for child in node["children"]:
            self.flat(child, out)
        return out

    def assert_parent_tree(self, path):
        mcids = page_mcids(path)
        with pikepdf.open(path) as pdf:
            tree = parent_tree(pdf)
            for index, page in enumerate(pdf.pages):
                if not mcids[index]:
                    continue
                key = int(page.obj.StructParents)
                array = tree[key]
                for mcid in mcids[index]:
                    elem = array[mcid]
                    self.assertTrue(isinstance(elem, Dictionary), f"page {index} mcid {mcid} unmapped")
                    self.assertTrue(owns(elem, mcid, page.obj), f"page {index} mcid {mcid} owner mismatch")


class CheckerTests(Base):
    def test_untagged_document_fails_with_fixes(self):
        src = sample_pdf(self.tmp / "s.pdf")
        report, items = self.check(src)
        self.assertFalse(report["tagged"])
        self.assertEqual(items["tagged_pdf"]["status"], "failed")
        self.assertEqual(items["tagged_pdf"]["fix"], "autotag")
        self.assertEqual(items["title"]["fix"], "set_title")
        self.assertEqual(items["primary_language"]["fix"], "set_language")
        self.assertEqual(items["tab_order"]["fix"], "set_tab_order")
        self.assertEqual(items["tab_order"]["pages"], [1])
        self.assertEqual(items["figures_alt_text"]["status"], "skipped")
        self.assertEqual(items["logical_reading_order"]["status"], "manual")
        self.assertEqual(items["bookmarks"]["status"], "passed")
        self.assertEqual(items["character_encoding"]["status"], "passed")
        self.assertEqual(sum(report["summary"].values()), len(report["items"]))
        for item in report["items"]:
            self.assertIn(item["status"], ("passed", "failed", "manual", "skipped"))
        self.assertEqual(len({i["id"] for i in report["items"]}), len(report["items"]))

    def test_simple_fixes_flip_checks(self):
        src = sample_pdf(self.tmp / "s.pdf")
        out, results = self.run_ops(src, [{"op": "set_title", "title": "Annual Report"},
                                          {"op": "set_language", "lang": "en-US"},
                                          {"op": "set_tab_order"}])
        self.assertEqual(results[0]["title"], "Annual Report")
        _, items = self.check(out)
        for cid in ("title", "primary_language", "tab_order"):
            self.assertEqual(items[cid]["status"], "passed", cid)
        with pikepdf.open(out) as pdf:
            self.assertEqual(str(pdf.docinfo.Title), "Annual Report")
            self.assertEqual(str(pdf.open_metadata().get("dc:title")), "Annual Report")
            self.assertTrue(bool(pdf.Root.ViewerPreferences.DisplayDocTitle))

    def test_invalid_language_fails_closed(self):
        src = sample_pdf(self.tmp / "s.pdf")
        with self.assertRaises(EngineError) as ctx:
            self.run_ops(src, [{"op": "set_language", "lang": "not a language!"}])
        self.assertEqual(ctx.exception.code, "INVALID_ARGUMENT")

    def test_field_tooltips(self):
        src = self.fixture("uscis-i9")
        _, items = self.check(src)
        out, results = self.run_ops(src, [{"op": "set_field_tooltips", "overwrite": False}])
        _, after = self.check(out)
        self.assertEqual(after["field_descriptions"]["status"], "passed")
        if items["field_descriptions"]["status"] == "failed":
            self.assertGreater(results[0]["updated"], 0)
        from transforms.accessibility import _humanize
        self.assertEqual(_humanize("first_name"), "First name")
        self.assertEqual(_humanize("Line1Col2"), "Line 1 col 2")
        self.assertEqual(_humanize("SSN[0]"), "SSN")

    def test_long_document_needs_bookmarks(self):
        pdf = pikepdf.new()
        for _ in range(21):
            pdf.add_blank_page()
        path = self.tmp / "long.pdf"
        pdf.save(path)
        _, items = self.check(path)
        self.assertEqual(items["bookmarks"]["status"], "failed")
        self.assertEqual(items["bookmarks"]["fix"], "bookmarks")


class AutotagTests(Base):
    def test_autotag_sample_structure(self):
        src = sample_pdf(self.tmp / "s.pdf")
        before = texts(src)
        out, results = self.run_ops(src, [{"op": "autotag", "language": "en-US"}])
        stats = results[0]
        self.assertEqual(texts(out), before)
        self.assertEqual(stats["headings"], 1)
        self.assertEqual(stats["lists"], 1)
        self.assertEqual(stats["tables"], 1)
        self.assertEqual(stats["figures"], 1)
        self.assertGreaterEqual(stats["paragraphs"], 3)
        self.assertGreaterEqual(stats["artifacts"], 1)
        tree = self.tree(out)
        self.assertTrue(tree["tagged"])
        nodes = self.flat(tree["root"])
        types = [n["type"] for n in nodes]
        for t in ("Document", "H1", "P", "L", "LI", "Lbl", "LBody", "Figure", "Table", "TR", "TH", "TD", "Link"):
            self.assertIn(t, types)
        self.assertEqual(types.count("TR"), 3)
        self.assertEqual(types.count("TH"), 3)
        self.assertEqual(types.count("LI"), 3)
        h1 = next(n for n in nodes if n["type"] == "H1")
        self.assertEqual(h1["text"], "Annual Report")
        self.assertEqual(h1["page"], 0)
        paragraphs = [n["text"] for n in nodes if n["type"] == "P"]
        self.assertTrue(any(p.startswith("This report") and "It continues" in p for p in paragraphs), paragraphs)
        lbl = next(n for n in nodes if n["type"] == "Lbl")
        self.assertEqual(lbl["text"], "•")
        # Reading order: heading first, closing remark last on page 1.
        order = transforms.inspect(out, "reading_order", {"page": 0})["items"]
        self.assertEqual(order[0]["type"], "H1")
        self.assertIn("Closing remarks", order[-1]["text"])
        self.assertEqual([i["order"] for i in order], list(range(1, len(order) + 1)))
        fig = next(i for i in order if i["type"] == "Figure")
        self.assertAlmostEqual(fig["rect"][0], 72, delta=1)
        self.assertAlmostEqual(fig["rect"][3], 500, delta=1)
        self.assert_parent_tree(out)
        report, items = self.check(out)
        self.assertTrue(report["tagged"])
        for cid in ("tagged_pdf", "tagged_content", "tagged_annotations", "tab_order", "primary_language",
                    "list_items", "lbl_lbody", "heading_nesting", "table_rows", "table_th_td", "table_headers",
                    "table_regularity", "tagged_form_fields", "nested_alt_text", "alt_associated_with_content"):
            self.assertEqual(items[cid]["status"], "passed", cid)
        self.assertEqual(items["figures_alt_text"]["status"], "failed")
        self.assertEqual(items["table_summary"]["status"], "failed")
        with pikepdf.open(out) as pdf:
            self.assertTrue(bool(pdf.Root.MarkInfo.Marked))
            self.assertEqual(str(pdf.Root.Lang), "en-US")
            annot = pdf.pages[1].obj.Annots[0]
            self.assertIn("/StructParent", annot)
            self.assertEqual(parent_tree(pdf)[int(annot.StructParent)].S, Name("/Link"))

    def test_fixtures_autotag(self):
        for name in FIXTURE_NAMES:
            with self.subTest(name=name):
                src = self.fixture(name)
                before = texts(src)
                with pikepdf.open(src) as pdf:
                    replace = "/StructTreeRoot" in pdf.Root
                out, results = self.run_ops(src, [{"op": "autotag", "replace": replace}])
                self.assertEqual(texts(out), before)
                report, items = self.check(out)
                self.assertTrue(report["tagged"])
                self.assertEqual(items["tagged_content"]["status"], "passed", items["tagged_content"])
                self.assertEqual(items["tagged_annotations"]["status"], "passed")
                self.assertEqual(items["tagged_form_fields"]["status"], "passed")
                self.assertEqual(items["heading_nesting"]["status"] in ("passed", "skipped"), True)
                self.assert_parent_tree(out)
                with pikepdf.open(out) as pdf:
                    self.assertGreater(len(pdf.pages), 0)
                tree = self.tree(out)
                self.assertGreater(len(self.flat(tree["root"])), 2)

    def test_retag_refused_then_replaced(self):
        src = sample_pdf(self.tmp / "s.pdf")
        out, _ = self.run_ops(src, [{"op": "autotag"}])
        with self.assertRaises(EngineError) as ctx:
            self.run_ops(out, [{"op": "autotag"}])
        self.assertEqual(ctx.exception.code, "ALREADY_TAGGED")
        out2, results = self.run_ops(out, [{"op": "autotag", "replace": True}])
        self.assertEqual(results[0]["tables"], 1)
        self.assertEqual(texts(out2), texts(src))
        self.assert_parent_tree(out2)
        _, items = self.check(out2)
        self.assertEqual(items["tagged_content"]["status"], "passed")
        with pikepdf.open(out2) as pdf:
            data = pdf.pages[0].obj.Contents.read_bytes()
            # No stale nested MCIDs: each MCID appears once per page.
            import re
            ids = re.findall(rb"/MCID (\d+)", data)
            self.assertEqual(len(ids), len(set(ids)))

    def test_optional_content_marks_are_preserved(self):
        pdf = pikepdf.new()
        font = Dictionary(Type=Name.Font, Subtype=Name.Type1, BaseFont=Name.Helvetica)
        ocg = pdf.make_indirect(Dictionary(Type=Name.OCG, Name="Layer"))
        page = pdf.add_blank_page()
        page.obj.Resources = Dictionary(Font=Dictionary(F1=font), Properties=Dictionary(oc1=ocg))
        page.obj.Contents = pdf.make_stream(b"/OC /oc1 BDC BT /F1 12 Tf 72 700 Td (Layered text) Tj ET EMC")
        pdf.Root.OCProperties = Dictionary(OCGs=[ocg], D=Dictionary(ON=[ocg]))
        path = self.tmp / "oc.pdf"
        pdf.save(path)
        out, _ = self.run_ops(path, [{"op": "autotag"}])
        with pikepdf.open(out) as result:
            data = result.pages[0].obj.Contents.read_bytes()
        self.assertIn(b"/OC /oc1 BDC", data)
        self.assertIn(b"/MCID 0", data)
        self.assertEqual(texts(out), texts(path))


class StructureEditTests(Base):
    def tagged(self):
        src = sample_pdf(self.tmp / "s.pdf")
        out, _ = self.run_ops(src, [{"op": "autotag"}])
        return out

    def test_structure_tree_ids(self):
        out = self.tagged()
        tree = self.tree(out)
        root = tree["root"]
        self.assertEqual(root["id"], "root")
        self.assertEqual(root["type"], "StructTreeRoot")
        nodes = self.flat(root)[1:]
        self.assertTrue(all(n["id"].startswith("o") for n in nodes))
        self.assertEqual(len({n["id"] for n in nodes}), len(nodes))
        limited = transforms.inspect(out, "structure_tree", {"max_nodes": 3})
        self.assertTrue(limited["truncated"])

    def test_direct_elements_get_path_ids(self):
        pdf = pikepdf.new()
        font = Dictionary(Type=Name.Font, Subtype=Name.Type1, BaseFont=Name.Helvetica)
        page = pdf.add_blank_page()
        page.obj.Resources = Dictionary(Font=Dictionary(F1=font))
        page.obj.Contents = pdf.make_stream(b"/P <</MCID 0>> BDC BT /F1 12 Tf 72 700 Td (Hello) Tj ET EMC")
        root = pdf.make_indirect(Dictionary(Type=Name.StructTreeRoot))
        doc = Dictionary(S=Name.Document, P=root, K=Array([Dictionary(S=Name.P, Pg=page.obj, K=0)]))
        root.K = Array([doc])
        pdf.Root.StructTreeRoot = root
        pdf.Root.MarkInfo = Dictionary(Marked=True)
        path = self.tmp / "direct.pdf"
        pdf.save(path)
        tree = self.tree(path)
        doc_node = tree["root"]["children"][0]
        self.assertEqual(doc_node["id"], "p0")
        self.assertEqual(doc_node["children"][0]["id"], "p0.0")
        self.assertEqual(doc_node["children"][0]["text"], "Hello")
        out, _ = self.run_ops(path, [{"op": "edit_structure", "edits": [{"id": "p0.0", "set": {"type": "H1"}}]}])
        tree = self.tree(out)
        self.assertEqual(tree["root"]["children"][0]["children"][0]["type"], "H1")
        self.assert_parent_tree(out)

    def test_edit_set_move_delete(self):
        out = self.tagged()
        nodes = self.flat(self.tree(out)["root"])
        doc = next(n for n in nodes if n["type"] == "Document")
        h1 = next(n for n in nodes if n["type"] == "H1")
        paragraph = next(n for n in nodes if n["type"] == "P")
        lst = next(n for n in nodes if n["type"] == "L")
        out2, results = self.run_ops(out, [{"op": "edit_structure", "edits": [
            {"id": h1["id"], "set": {"type": "H2", "alt": "", "title": "Main", "lang": "en"}},
            {"id": paragraph["id"], "move": {"parent": doc["id"], "index": 0}},
            {"id": lst["id"], "delete": True},
        ]}])
        self.assertEqual(results[0]["edited"], 3)
        nodes2 = self.flat(self.tree(out2)["root"])
        doc2 = next(n for n in nodes2 if n["type"] == "Document")
        # Ids are per revision (objects are renumbered on save); compare content.
        self.assertEqual(doc2["children"][0]["text"], paragraph["text"])
        changed = next(n for n in nodes2 if n["type"] == "H2")
        self.assertEqual((changed["type"], changed["title"], changed["lang"]), ("H2", "Main", "en"))
        self.assertFalse(any(n["type"] == "L" for n in nodes2))
        # LI children were spliced into the Document.
        self.assertEqual(sum(1 for n in doc2["children"] if n["type"] == "LI"), 3)
        self.assert_parent_tree(out2)
        self.assertEqual(texts(out2), texts(out))

    def test_edit_rejects_stale_and_cycles(self):
        out = self.tagged()
        nodes = self.flat(self.tree(out)["root"])
        table = next(n for n in nodes if n["type"] == "Table")
        tr = next(n for n in nodes if n["type"] == "TR")
        with self.assertRaises(EngineError) as ctx:
            self.run_ops(out, [{"op": "edit_structure", "edits": [{"id": "o99999_0", "set": {"alt": "x"}}]}])
        self.assertEqual(ctx.exception.code, "STALE_STRUCTURE")
        with self.assertRaises(EngineError) as ctx:
            self.run_ops(out, [{"op": "edit_structure", "edits": [
                {"id": table["id"], "move": {"parent": tr["id"], "index": 0}}]}])
        self.assertEqual(ctx.exception.code, "INVALID_STRUCTURE_EDIT")

    def test_alt_text_and_reading_order(self):
        out = self.tagged()
        nodes = self.flat(self.tree(out)["root"])
        figure = next(n for n in nodes if n["type"] == "Figure")
        out2, results = self.run_ops(out, [{"op": "set_alt_text", "items": [{"id": figure["id"], "alt": "Red and green squares"}]}])
        self.assertEqual(results[0]["updated"], 1)
        _, items = self.check(out2)
        self.assertEqual(items["figures_alt_text"]["status"], "passed")
        self.assertEqual(next(n for n in self.flat(self.tree(out2)["root"]) if n["id"] == figure["id"])["alt"],
                         "Red and green squares")
        order = transforms.inspect(out2, "reading_order", {"page": 0})["items"]
        top_level = [i for i in order if i["type"] in ("H1", "P", "Figure")]
        ids = [i["id"] for i in top_level]
        reversed_ids = list(reversed(ids))
        out3, results = self.run_ops(out2, [{"op": "set_reading_order", "page": 0, "ids": reversed_ids}])
        self.assertEqual(results[0]["reordered"], len(ids))
        wanted = [i["text"] for i in reversed(top_level)]
        order2 = [i["text"] for i in transforms.inspect(out3, "reading_order", {"page": 0})["items"]
                  if i["text"] in wanted]
        self.assertEqual(order2, wanted)
        order = transforms.inspect(out3, "reading_order", {"page": 0})["items"]
        self.assert_parent_tree(out3)
        # Mixed parents: an LBody and a paragraph move together into the paragraph's parent.
        lbody = next(i for i in order if i["type"] == "LBody")
        para = next(i for i in order if i["type"] == "P")
        out4, _ = self.run_ops(out3, [{"op": "set_reading_order", "page": 0, "ids": [para["id"], lbody["id"]]}])
        order4 = [i["text"] for i in transforms.inspect(out4, "reading_order", {"page": 0})["items"]]
        self.assertEqual(order4.index(lbody["text"]), order4.index(para["text"]) + 1)
        self.assert_parent_tree(out4)

    def test_tag_annotations_and_pdfua(self):
        src = sample_pdf(self.tmp / "s.pdf")
        with self.assertRaises(EngineError) as ctx:
            self.run_ops(src, [{"op": "mark_pdfua"}])
        self.assertEqual(ctx.exception.code, "NOT_TAGGED")
        tagged = self.tagged()
        # Add an untagged annotation after tagging.
        with pikepdf.open(tagged) as pdf:
            annot = pdf.make_indirect(Dictionary(Type=Name.Annot, Subtype=Name.Square, Rect=[10, 10, 50, 50]))
            pdf.pages[0].obj.Annots = Array([annot])
            path = self.tmp / "late.pdf"
            pdf.save(path)
        _, items = self.check(path)
        self.assertEqual(items["tagged_annotations"]["status"], "failed")
        self.assertEqual(items["tagged_annotations"]["fix"], "tag_annotations")
        out, results = self.run_ops(path, [{"op": "tag_annotations"}, {"op": "mark_pdfua"}])
        self.assertEqual(results[0]["tagged"], 1)
        report, items = self.check(out)
        self.assertEqual(items["tagged_annotations"]["status"], "passed")
        self.assertTrue(report["pdfua"]["claimed"])
        self.assert_parent_tree(out)
        out2, _ = self.run_ops(out, [{"op": "mark_pdfua", "enabled": False}])
        self.assertFalse(self.check(out2)[0]["pdfua"]["claimed"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
