"""Page-content editing regressions: text blocks, text boxes, find/replace and
objects (dev venv; see EngineSupport/transforms/README.md).

    python scripts/test_edit.py
"""
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
from test_redaction import (Base, text_of, char_boxes, find_box, text_pdf, rgb_image, helvetica,  # noqa: E402
                            all_stream_bytes, FIXTURES)
import pikepdf  # noqa: E402
from pikepdf import Name  # noqa: E402
import pypdfium2 as pdfium  # noqa: E402
import transforms  # noqa: E402
from engine.errors import EngineError  # noqa: E402

PARAGRAPH = (b"BT /F1 12 Tf 14 TL 72 700 Td (The quick brown fox jumps over) Tj T* (the lazy dog near the) Tj T* "
             b"(river bank today.) Tj ET BT /F1 10 Tf 72 400 Td (Separate footer text) Tj ET")


def content(path, page=0):
    return transforms.inspect(path, "page_content", {"pages": [page]})["pages"][0]


def render(path, page=0, scale=1):
    doc = pdfium.PdfDocument(str(path))
    try:
        return doc[page].render(scale=scale).to_pil()
    finally:
        doc.close()


class BlockTests(Base):
    def test_blocks_are_paragraphs(self):
        src = text_pdf(self.tmp / "p.pdf", PARAGRAPH)
        blocks = content(src)["blocks"]
        self.assertEqual(len(blocks), 2)
        para = blocks[0]
        self.assertEqual(para["text"], "The quick brown fox jumps over the lazy dog near the river bank today.")
        self.assertEqual(len(para["lines"]), 3)
        self.assertAlmostEqual(para["line_spacing"] * para["size"], 14, places=1)
        self.assertEqual(para["font"]["base"], "Helvetica")
        self.assertEqual(blocks[1]["text"], "Separate footer text")

    def test_edit_reflows_in_original_font(self):
        src = text_pdf(self.tmp / "p.pdf", PARAGRAPH)
        page = content(src)
        para = page["blocks"][0]
        runs = [{"text": "A much longer replacement paragraph that has to wrap across several lines inside the "
                         "original width of the block.", "font": {"original": para["runs"][0]["font"]},
                 "size": 12, "color": [0, 0, 0]}]
        footer_before = find_box(src, "Separate")
        out, result = self.run_ops(src, [{"op": "edit_text_block", "page": 0, "block": 0, "digest": page["digest"],
                                          "runs": runs}])
        self.assertEqual(result["results"][0]["substituted"], [])
        text = text_of(out)
        self.assertNotIn("quick brown", text)
        self.assertIn("replacement", text)
        for a, b in zip(footer_before, find_box(out, "Separate")):
            self.assertAlmostEqual(a, b, places=1)
        after = content(out)["blocks"]
        edited = next(b for b in after if "replacement" in b["text"])
        self.assertGreaterEqual(len(edited["lines"]), 3)
        self.assertLessEqual(edited["bbox"][2], para["bbox"][2] + 1)
        self.assertAlmostEqual(edited["bbox"][0], para["bbox"][0], delta=0.5)
        with pikepdf.open(out) as pdf:
            fonts = [str(f.get("/BaseFont")) for f in pdf.pages[0].Resources.Font.values()]
        self.assertIn("/Helvetica", fonts)

    def test_substitution_when_font_cannot_encode(self):
        src = text_pdf(self.tmp / "p.pdf", PARAGRAPH)
        page = content(src)
        key = page["blocks"][0]["runs"][0]["font"]
        out, result = self.run_ops(src, [{"op": "edit_text_block", "page": 0, "block": 0, "digest": page["digest"],
                                          "runs": [{"text": "Привет ✓ done", "font": {"original": key}, "size": 12}],
                                          "align": "center"}])
        self.assertEqual(result["results"][0]["substituted"], ["Helvetica"])
        self.assertIn("Привет ✓ done", text_of(out))

    def test_styles_bold_color_and_alignment(self):
        src = text_pdf(self.tmp / "p.pdf", PARAGRAPH)
        page = content(src)
        out, _ = self.run_ops(src, [{"op": "edit_text_block", "page": 0, "block": 1, "digest": page["digest"],
                                     "runs": [{"text": "Bold red ", "font": {"family": "sans", "bold": True},
                                               "size": 14, "color": [255, 0, 0]},
                                              {"text": "serif italic", "font": {"family": "serif", "italic": True},
                                               "size": 14, "color": [0, 0, 255]}], "align": "right"}])
        blocks = content(out)["blocks"]
        edited = next(b for b in blocks if "Bold red" in b["text"])
        self.assertEqual(edited["text"], "Bold red serif italic")
        styles = {r["style"]["bold"] for r in edited["runs"]}
        self.assertEqual(styles, {True, False})
        self.assertEqual(edited["runs"][0]["color"], [1.0, 0.0, 0.0])
        self.assertTrue(any(r["style"]["italic"] for r in edited["runs"]))

    def test_move_keeps_original_glyphs(self):
        src = text_pdf(self.tmp / "p.pdf", PARAGRAPH)
        page = content(src)
        before = find_box(src, "Separate")
        out, _ = self.run_ops(src, [{"op": "edit_text_block", "page": 0, "block": 1, "digest": page["digest"],
                                     "offset": [50, -100]}])
        after = find_box(out, "Separate")
        self.assertAlmostEqual(after[0], before[0] + 50, places=1)
        self.assertAlmostEqual(after[1], before[1] - 100, places=1)
        self.assertIn("Separate footer text", text_of(out))
        # Resize: narrower box reflows the original glyphs onto more lines.
        page = content(out)
        para = page["blocks"][0]
        out2, _ = self.run_ops(out, [{"op": "edit_text_block", "page": 0, "block": 0, "digest": page["digest"],
                                      "width": 90}], name="o2.pdf")
        para2 = next(b for b in content(out2)["blocks"] if "quick" in b["text"])
        self.assertGreater(len(para2["lines"]), len(para["lines"]))
        self.assertIn("quick", text_of(out2))

    def test_delete_and_stale(self):
        src = text_pdf(self.tmp / "p.pdf", PARAGRAPH)
        page = content(src)
        with self.assertRaises(EngineError) as ctx:
            self.run_ops(src, [{"op": "edit_text_block", "page": 0, "block": 0, "digest": "stale", "delete": True}])
        self.assertEqual(ctx.exception.code, "STALE_CONTENT")
        out, _ = self.run_ops(src, [{"op": "edit_text_block", "page": 0, "block": 0, "digest": page["digest"],
                                     "delete": True}])
        self.assertNotIn("quick", text_of(out))
        self.assertIn("Separate", text_of(out))

    def test_edit_embedded_subset_fixture(self):
        src = self.fixture("irs-w9.pdf")
        page = content(src)
        block = next(b for b in page["blocks"] if b["text"].startswith("Request for Taxpayer"))
        runs = [dict(r) for r in block["runs"]]
        runs = [{"text": "Request for Taxpayer Certification", "font": {"original": runs[0]["font"]},
                 "size": runs[0]["size"], "color": runs[0]["color"]}]
        out, result = self.run_ops(src, [{"op": "edit_text_block", "page": 0, "block": block["id"],
                                          "digest": page["digest"], "runs": runs}])
        text = text_of(out)
        self.assertIn("Request for Taxpayer Certification", text)
        self.assertNotIn("Taxpayer Identification Number and Certification", text)
        # All needed glyphs exist in the subset; no substitution.
        self.assertEqual(result["results"][0]["substituted"], [])
        # "z" is not in the subset of that heading font.
        out2, result2 = self.run_ops(src, [{"op": "edit_text_block", "page": 0, "block": block["id"],
                                            "digest": page["digest"],
                                            "runs": [{"text": "Zebra quiz 42", "font": {"original": runs[0]["font"]["original"]},
                                                      "size": 14}]}], name="o2.pdf")
        self.assertIn("Zebra quiz 42", text_of(out2))
        self.assertTrue(result2["results"][0]["substituted"])


class TextBoxTests(Base):
    def test_add_text_upright_on_rotated_page(self):
        pdf = pikepdf.new()
        page = pdf.add_blank_page(page_size=(612, 792))
        page.obj.Rotate = 90
        pdf.save(self.tmp / "r.pdf")
        # Visual top-left of a 90° page is user-space (0, 0) side... pick a point inside.
        out, _ = self.run_ops(self.tmp / "r.pdf", [{"op": "add_text", "page": 0, "point": [100, 100],
                                                    "runs": [{"text": "Hello box", "size": 18}], "width": 200}])
        self.assertIn("Hello box", text_of(out))
        blocks = content(out)["blocks"]
        frame = blocks[0]["frame"]
        # Text runs along +y in user space on a 90° page (upright on screen).
        self.assertAlmostEqual(frame[0], 0, places=3)
        self.assertAlmostEqual(frame[1], 1, places=3)

    def test_add_text_wraps(self):
        pdf = pikepdf.new()
        pdf.add_blank_page(page_size=(612, 792))
        pdf.save(self.tmp / "b.pdf")
        out, result = self.run_ops(self.tmp / "b.pdf", [{"op": "add_text", "page": 0, "point": [72, 720],
                                                         "runs": [{"text": "one two three four five six seven", "size": 12}],
                                                         "width": 80}])
        self.assertGreaterEqual(result["results"][0]["lines"], 3)
        box = find_box(out, "one")
        self.assertAlmostEqual(box[0], 72, delta=1.5)
        self.assertLess(box[3], 720.5)


class ReplaceTests(Base):
    def test_replace_in_simple_font_flows_line(self):
        src = text_pdf(self.tmp / "p.pdf", b"BT /F1 12 Tf 72 700 Td (Invoice for ACME Corp, ACME ltd.) Tj ET")
        out, result = self.run_ops(src, [{"op": "replace_text", "find": "acme", "replace": "Globex"}])
        self.assertEqual(result["results"][0]["replaced"], 2)
        self.assertEqual(text_of(out).strip(), "Invoice for Globex Corp, Globex ltd.")
        self.assertNotIn(b"ACME", all_stream_bytes(out))

    def test_replace_whole_word_and_case(self):
        src = text_pdf(self.tmp / "p.pdf", b"BT /F1 12 Tf 72 700 Td (cat concat Cat) Tj ET")
        out, result = self.run_ops(src, [{"op": "replace_text", "find": "cat", "replace": "dog", "whole_word": True,
                                          "match_case": True}])
        self.assertEqual(result["results"][0]["replaced"], 1)
        self.assertEqual(text_of(out).strip(), "dog concat Cat")

    def test_replace_across_tj_items_and_substitution(self):
        src = self.fixture("irs-w9.pdf")
        before = text_of(src).count("Taxpayer")
        self.assertGreater(before, 0)
        out, result = self.run_ops(src, [{"op": "replace_text", "find": "Taxpayer", "replace": "Zebra™", "pages": [0]}])
        after = text_of(out)
        self.assertEqual(after.count("Taxpayer"), 0)
        self.assertEqual(after.count("Zebra™"), result["results"][0]["replaced"])
        self.assertIn("Identification Number", after)

    def test_replace_regex(self):
        src = text_pdf(self.tmp / "p.pdf", b"BT /F1 12 Tf 72 700 Td (Call 555-123-4567 now) Tj ET")
        out, _ = self.run_ops(src, [{"op": "replace_text", "find": r"(\d{3})-(\d{3})-(\d{4})",
                                     "replace": r"(\1) \2-XXXX", "regex": True}])
        self.assertEqual(text_of(out).strip(), "Call (555) 123-XXXX now")


class ObjectTests(Base):
    def image_page(self):
        def extra(pdf, page):
            page.obj.Resources.XObject = pikepdf.Dictionary(Im1=rgb_image(pdf))
        return text_pdf(self.tmp / "i.pdf", b"0 0 1 rg 50 50 100 100 re f q 200 0 0 100 100 500 cm /Im1 Do Q "
                                            b"1 0 0 rg 150 520 60 60 re f", extra=extra)

    def test_list_move_delete(self):
        src = self.image_page()
        page = content(src)
        kinds = [o["kind"] for o in page["objects"]]
        self.assertEqual(kinds, ["path", "image", "path"])
        image = page["objects"][1]
        self.assertEqual(image["bbox"], [100, 500, 300, 600])
        out, _ = self.run_ops(src, [{"op": "object_transform", "page": 0, "digest": page["digest"],
                                     "ids": [image["id"]], "matrix": [1, 0, 0, 1, 10, -300]}])
        moved = content(out)["objects"]
        self.assertEqual([round(v) for v in next(o for o in moved if o["kind"] == "image")["bbox"]], [110, 200, 310, 300])
        page2 = content(out)
        path = page2["objects"][0]
        out2, _ = self.run_ops(out, [{"op": "object_delete", "page": 0, "digest": page2["digest"], "ids": [path["id"]]}],
                               name="o2.pdf")
        self.assertEqual([o["kind"] for o in content(out2)["objects"]], ["image", "path"])
        self.assertEqual(render(out2).getpixel((100, 792 - 100))[:3], (255, 255, 255))

    def test_step_forward_and_backward(self):
        """Bring Forward / Send Backward move one step past the nearest overlap,
        and reset transparency set by content in between."""
        pdf = pikepdf.new()
        page = pdf.add_blank_page(page_size=(300, 300))
        page.obj.Resources = pikepdf.Dictionary(ExtGState=pikepdf.Dictionary(
            Half=pikepdf.Dictionary(Type=Name.ExtGState, ca=0.5)))
        page.obj.Contents = pdf.make_stream(b"q 1 0 0 rg 50 50 120 120 re f 0 1 0 rg 90 90 120 120 re f "
                                            b"/Half gs 0 0 1 rg 130 130 120 120 re f Q")
        src = self.tmp / "layers.pdf"
        pdf.save(src)

        def pixel(path, x, y):
            return render(path).convert("RGB").getpixel((x, 300 - y))

        self.assertEqual(pixel(src, 100, 100), (0, 255, 0))
        red, green, blue = [o["id"] for o in content(src)["objects"]]
        one, result = self.run_ops(src, [{"op": "object_step", "page": 0, "ids": [red], "direction": "forward"}], name="one.pdf")
        self.assertEqual(result["results"][0]["moved"], 1)
        self.assertEqual(pixel(one, 100, 100), (255, 0, 0), "red now above green")
        self.assertEqual(pixel(one, 150, 150)[1], 0, "blue (half transparent) still above red")
        red_now = content(one)["objects"][1]["id"]
        two, _ = self.run_ops(one, [{"op": "object_step", "page": 0, "ids": [red_now], "direction": "forward"}], name="two.pdf")
        self.assertEqual(pixel(two, 150, 150), (255, 0, 0), "red above blue and still opaque")
        self.assertEqual(pixel(two, 60, 60), (255, 0, 0))
        top = content(two)["objects"][-1]["id"]
        _, noop = self.run_ops(two, [{"op": "object_step", "page": 0, "ids": [top], "direction": "forward"}], name="top.pdf")
        self.assertEqual(noop["results"][0]["moved"], 0, "already frontmost")
        back, _ = self.run_ops(two, [{"op": "object_step", "page": 0, "ids": [top], "direction": "backward"}], name="back.pdf")
        self.assertEqual(pixel(back, 150, 150)[2], 127, "red stepped back below blue")

    def test_step_refuses_to_cross_clipped_content(self):
        pdf = pikepdf.new()
        page = pdf.add_blank_page(page_size=(300, 300))
        page.obj.Contents = pdf.make_stream(b"1 0 0 rg 50 50 120 120 re f q 60 60 200 200 re W n 0 1 0 rg 90 90 120 120 re f Q")
        src = self.tmp / "clip.pdf"
        pdf.save(src)
        red = content(src)["objects"][0]["id"]
        with self.assertRaises(EngineError) as ctx:
            self.run_ops(src, [{"op": "object_step", "page": 0, "ids": [red], "direction": "forward"}], name="c.pdf")
        self.assertIn("Bring to Front", ctx.exception.message)

    def test_scale_rotate_flip(self):
        src = self.image_page()
        page = content(src)
        image = page["objects"][1]
        # Rotate 90° about the image centre (200, 550).
        import math
        c, s = 0.0, 1.0
        cx, cy = 200, 550
        m = [c, s, -s, c, cx - c * cx + s * cy, cy - s * cx - c * cy]
        out, _ = self.run_ops(src, [{"op": "object_transform", "page": 0, "digest": page["digest"],
                                     "ids": [image["id"]], "matrix": m}])
        box = next(o for o in content(out)["objects"] if o["kind"] == "image")["bbox"]
        self.assertEqual([round(v) for v in box], [150, 450, 250, 650])

    def test_arrange_front_and_back(self):
        src = self.image_page()
        page = content(src)
        red = page["objects"][2]
        # Red square overlaps the image's left part; send it to back: image (white) covers it.
        pixel = (160, 792 - 550)
        self.assertGreater(render(src).getpixel(pixel)[0], 200)
        self.assertLess(render(src).getpixel(pixel)[1], 50)
        out, _ = self.run_ops(src, [{"op": "object_arrange", "page": 0, "digest": page["digest"],
                                     "ids": [red["id"]], "to": "back"}])
        self.assertEqual(render(out).getpixel(pixel)[:3], (255, 255, 255))
        page2 = content(out)
        red2 = next(o for o in page2["objects"] if o["kind"] == "path" and o["bbox"][0] == 150)
        out2, _ = self.run_ops(out, [{"op": "object_arrange", "page": 0, "digest": page2["digest"],
                                      "ids": [red2["id"]], "to": "front"}], name="o2.pdf")
        px = render(out2).getpixel(pixel)
        self.assertGreater(px[0], 200)
        self.assertLess(px[1], 50)

    def test_replace_crop_and_add_image(self):
        from PIL import Image
        png = self.tmp / "new.png"
        Image.new("RGB", (50, 100), (0, 200, 0)).save(png)
        src = self.image_page()
        page = content(src)
        image = page["objects"][1]
        out, _ = self.run_ops(src, [{"op": "image_replace", "page": 0, "digest": page["digest"], "id": image["id"],
                                     "image": str(png)}])
        bitmap = render(out)
        self.assertEqual(bitmap.getpixel((220, 792 - 560))[:3], (0, 200, 0))   # centre: new image
        self.assertEqual(bitmap.getpixel((110, 792 - 550))[:3], (255, 255, 255))  # aspect-fit margin
        page2 = content(out)
        image2 = next(o for o in page2["objects"] if o["kind"] == "image")
        out2, _ = self.run_ops(out, [{"op": "image_crop", "page": 0, "digest": page2["digest"], "id": image2["id"],
                                      "rect": [100, 500, 200, 550]}], name="o2.pdf")
        bitmap = render(out2)
        self.assertEqual(bitmap.getpixel((190, 792 - 510))[:3], (0, 200, 0))
        self.assertEqual(bitmap.getpixel((210, 792 - 510))[:3], (255, 255, 255))
        out3, _ = self.run_ops(out2, [{"op": "image_add", "page": 0, "image": str(png), "rect": [400, 100, 450, 200]}],
                               name="o3.pdf")
        self.assertEqual(render(out3).getpixel((425, 792 - 150))[:3], (0, 200, 0))

    def test_fixture_paths_listed(self):
        page = content(FIXTURES / "uscis-i9.pdf")
        kinds = {o["kind"] for o in page["objects"]}
        self.assertIn("path", kinds)
        self.assertIn("image", kinds)


if __name__ == "__main__":
    unittest.main(verbosity=1)
