"""Malformed-input regressions found by the real-world corpus sweep
(scripts/corpus_sweep.py). Each case is a small synthetic PDF with the defect
that crashed an operation (dev venv; see EngineSupport/transforms/README.md).

    python scripts/test_robustness.py
"""
from pathlib import Path
import sys
import unittest
import zlib

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
from test_redaction import Base, text_pdf  # noqa: E402
import pikepdf  # noqa: E402
from pikepdf import Name  # noqa: E402
import transforms  # noqa: E402
from engine.errors import EngineError  # noqa: E402

TEXT = b"BT /F1 12 Tf 72 700 Td (Hello robust world) Tj ET"


def text_annot(pdf, rect=(100, 100, 120, 120)):
    return pdf.make_indirect(pikepdf.Dictionary(Type=Name.Annot, Subtype=Name.Text, Rect=list(rect),
                                                Contents=pikepdf.String("note")))


class MalformedStructureTests(Base):
    def junk_annots_pdf(self):
        def extra(pdf, page):
            no_rect = pdf.make_indirect(pikepdf.Dictionary(Type=Name.Annot, Subtype=Name.Text))
            page.obj.Annots = pikepdf.Array([None, 5, no_rect, text_annot(pdf)])
        return text_pdf(self.tmp / "annots.pdf", TEXT, extra=extra)

    def test_null_and_rectless_annotations_are_dropped(self):
        src = self.junk_annots_pdf()
        for ops in ([{"op": "watermark", "text": "X"}], [{"op": "flatten_annotations", "include_widgets": True}],
                    [{"op": "duplicate_pages", "pages": [0]}], [{"op": "rotate_pages", "pages": [0], "angle": 90}]):
            out, _ = self.run_ops(src, ops)
            with pikepdf.open(out) as pdf:
                for page in pdf.pages:
                    for annot in page.obj.get("/Annots", []):
                        self.assertIsInstance(annot, pikepdf.Dictionary)
                        self.assertIn("/Rect", annot)
        for name in ("accessibility_check", "page_content", "form_fields"):
            transforms.inspect(src, name, {})

    def test_bogus_page_count_is_recomputed(self):
        src = text_pdf(self.tmp / "count.pdf", TEXT, pages=2)
        with pikepdf.open(src, allow_overwriting_input=True) as pdf:
            pdf.Root.Pages.Count = 99
            pdf.save(src)
        out, _ = self.run_ops(src, [{"op": "rotate_pages", "pages": [0], "angle": 90}])
        with pikepdf.open(out) as pdf:
            self.assertEqual(int(pdf.Root.Pages.Count), 2)

    def test_widget_parent_without_kids_duplicates(self):
        def extra(pdf, page):
            parent = pdf.make_indirect(pikepdf.Dictionary(FT=Name.Tx, T=pikepdf.String("name")))
            widget = pdf.make_indirect(pikepdf.Dictionary(Type=Name.Annot, Subtype=Name.Widget, Rect=[72, 600, 272, 620],
                                                          Parent=parent, P=page.obj))
            page.obj.Annots = pikepdf.Array([widget])
            pdf.Root.AcroForm = pikepdf.Dictionary(Fields=pikepdf.Array([parent]))
        src = text_pdf(self.tmp / "kids.pdf", TEXT, extra=extra)
        out, _ = self.run_ops(src, [{"op": "duplicate_pages", "pages": [0]}])
        with pikepdf.open(out) as pdf:
            self.assertEqual(len(pdf.pages), 2)


class EncodingTests(Base):
    def test_non_utf8_font_name(self):
        def extra(pdf, page):
            page.obj.Resources.Font.F1.BaseFont = Name("/#CB#CE#CC#E5")  # GBK "SimSun"
        src = text_pdf(self.tmp / "cjk.pdf", TEXT, extra=extra)
        self.assertTrue(transforms.inspect(src, "fonts", {}) is not None)
        self.assertTrue(transforms.inspect(src, "document_fonts", {}) is not None)
        self.run_ops(src, [{"op": "optimize", "preset": "medium"}])
        with self.assertRaises(EngineError) as caught:  # the named font isn't installed: a clean refusal
            self.run_ops(src, [{"op": "convert_pdfa", "level": "2b"}], name="a.pdf")
        self.assertEqual(caught.exception.code, "FONT_NOT_EMBEDDABLE")


class DamagedInputTests(Base):
    def test_corrupt_stream_is_a_clean_refusal(self):
        src = self.tmp / "damaged.pdf"
        pdf = pikepdf.new()
        page = pdf.add_blank_page(page_size=(612, 792))
        good = zlib.compress(TEXT)
        stream = pikepdf.Stream(pdf, good[:8] + b"\x00garbage\xff" * 8)
        stream.Filter = Name.FlateDecode
        page.obj.Contents = stream
        pdf.save(src)
        try:
            self.run_ops(src, [{"op": "replace_text", "find": "e", "replace": "E", "pages": [0]}])
        except EngineError as exc:
            self.assertIn(exc.code, ("DAMAGED_PDF", "VALIDATION_FAILED", "INVALID_ARGUMENT"))
        # Anything other than an EngineError fails the test.

    def test_jbig2_is_never_decoded_by_an_external_tool(self):
        import subprocess
        src = self.tmp / "jbig2.pdf"
        pdf = pikepdf.new()
        page = pdf.add_blank_page(page_size=(612, 792))
        bomb = pikepdf.Stream(pdf, b"\x97JB2\r\n\x1a\n" + b"\x00" * 64)
        bomb.Filter = Name.JBIG2Decode
        page.obj.Contents = pikepdf.Array([pdf.make_stream(TEXT), bomb])
        pdf.save(src)
        calls = []
        original = subprocess.run
        subprocess.run = lambda *a, **k: calls.append(a) or original(*a, **k)
        try:
            _, result = self.run_ops(src, [{"op": "autotag"}])
            self.assertTrue(result["results"][0]["notes"])
            with self.assertRaises(EngineError) as caught:
                self.run_ops(src, [{"op": "replace_text", "find": "e", "replace": "E", "pages": [0]}], name="r.pdf")
            self.assertEqual(caught.exception.code, "DAMAGED_PDF")
        finally:
            subprocess.run = original
        self.assertFalse([c for c in calls if "jbig2dec" in str(c)])

    def test_damaged_error_is_mapped(self):
        self.assertTrue(transforms.DAMAGED_MESSAGE.startswith("Part of this PDF is damaged"))
        errors = transforms._damage_errors()
        self.assertIn(pikepdf.PdfError, errors)
        self.assertIn(UnicodeDecodeError, errors)


class StandardsTests(Base):
    def test_pdfa_with_inline_image_and_form_without_need_appearances(self):
        inline = b"q 20 0 0 20 72 72 cm BI /W 2 /H 2 /CS /RGB /BPC 8 ID \xff\x00\x00\x00\xff\x00\x00\x00\xff\xff\xff\xff EI Q "

        def extra(pdf, page):
            pdf.Root.AcroForm = pikepdf.Dictionary(Fields=pikepdf.Array())
        src = text_pdf(self.tmp / "inline.pdf", inline + TEXT, extra=extra)
        out, _ = self.run_ops(src, [{"op": "convert_pdfa", "level": "2b"}])
        with pikepdf.open(out) as pdf:
            self.assertNotIn("/NeedAppearances", pdf.Root.AcroForm)


class PolicyTests(Base):
    def test_edit_policy(self):
        src = text_pdf(self.tmp / "plain.pdf", TEXT)
        self.assertIsNone(transforms.inspect(src, "edit_policy", {})["write_block"])

        def xfa(pdf, page):
            pdf.Root.AcroForm = pikepdf.Dictionary(Fields=pikepdf.Array(), XFA=pdf.make_stream(b"<xdp/>"))
        self.assertEqual(transforms.inspect(text_pdf(self.tmp / "xfa.pdf", TEXT, extra=xfa), "edit_policy", {})
                         ["write_block"], "XFA_EDIT_BLOCKED")
        locked = self.tmp / "locked.pdf"
        with pikepdf.open(src) as pdf:
            pdf.save(locked, encryption=pikepdf.Encryption(user="u", owner="o"))
        self.assertEqual(transforms.inspect(locked, "edit_policy", {}, password="u")["write_block"],
                         "UNSUPPORTED_ENCRYPTED_WRITE")


if __name__ == "__main__":
    unittest.main(verbosity=1)
