"""Form authoring, filling, logic, flattening and security regressions.

    python scripts/test_forms.py   (dev venv with the pinned wheels)
"""
from pathlib import Path
import sys
import unittest
import warnings

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "EngineSupport"))
sys.path.insert(0, str(ROOT / "scripts"))
import pikepdf
import pypdfium2 as pdfium
import pypdfium2.raw as raw
import transforms
from transforms import formcalc as F
from engine.errors import EngineError
from engine import pdfium_adapter
from test_transforms import Base, blank_pdf, text_of

warnings.simplefilter("ignore")


def fields_of(path, password=None):
    return {f["name"]: f for f in transforms.inspect(path, "form_fields", {}, password)["fields"]}


def pdfium_values(path):
    """Field values as PDFium's form environment reports them (independent reader)."""
    out = {}
    with pdfium_adapter.document(str(path)) as doc:
        for index in range(len(doc)):
            page = doc[index]
            for a in range(raw.FPDFPage_GetAnnotCount(page)):
                with pdfium_adapter.annotation(page, a) as annot:
                    if raw.FPDFAnnot_GetSubtype(annot) != raw.FPDF_ANNOT_WIDGET:
                        continue
                    name = pdfium_adapter.getwide(raw.FPDFAnnot_GetFormFieldName, doc.formenv, annot)
                    value = pdfium_adapter.getwide(raw.FPDFAnnot_GetFormFieldValue, doc.formenv, annot)
                    checked = bool(raw.FPDFAnnot_IsChecked(doc.formenv, annot))
                    out.setdefault(name, []).append((value, checked))
            page.close()
    return out


class FormCalcTests(unittest.TestCase):
    def test_number_format(self):
        self.assertEqual(F.format_number(1234.5, 2, 0, 0, "$", True), ("$1,234.50", False))
        self.assertEqual(F.format_number(-1234.5, 2, 2, 2, "€", False), ("(1.234,50€)", False))
        self.assertEqual(F.format_number(-5, 0, 0, 3), ("(5)", True))
        self.assertEqual(F.make_number("$1,234.50"), 1234.5)
        self.assertEqual(F.make_number("1.234,5", 2), 1234.5)
        self.assertIsNone(F.make_number("abc"))

    def test_dates_and_special(self):
        logic = F.FieldLogic("D", {"F": 'AFDate_FormatEx("mm/dd/yyyy");', "K": 'AFDate_KeystrokeEx("mm/dd/yyyy");'})
        self.assertEqual(logic.display("1/2/24")[0], "01/02/2024")
        self.assertIsNotNone(logic.check("13/45/2024"))
        self.assertEqual(F.FieldLogic("D", {"F": 'AFDate_FormatEx("mmmm d, yyyy");'}).display("3/4/2025")[0], "March 4, 2025")
        self.assertEqual(F.format_special("4065551234", 2), "(406) 555-1234")
        self.assertEqual(F.format_special("123456789", 3), "123-45-6789")
        self.assertEqual(F.format_special("598121234", 1), "59812-1234")

    def test_validation_and_unsupported(self):
        logic = F.FieldLogic("Age", {"V": "AFRange_Validate(true, 0, true, 120);"})
        self.assertIsNone(logic.check("40"))
        self.assertIn("less than or equal to 120", logic.check("400"))
        custom = F.FieldLogic("X", {"C": "event.value = app.alert('hi');"})
        self.assertEqual(custom.unsupported, ["calculate"])
        self.assertIsNone(custom.compute(lambda n: None, lambda n: []))

    def test_calculations(self):
        logic = {"Total": F.FieldLogic("Total", {"C": 'AFSimple_Calculate("SUM", new Array ("A", "B", "Line"));'}),
                 "Avg": F.FieldLogic("Avg", {"C": 'AFSimple_Calculate("AVG", new Array ("A", "B"));'}),
                 "Expr": F.FieldLogic("Expr", {"C": "/** BVCALC (A + B) * 2 - Total / 4 EVCALC **/ event.value = 0;"})}
        values = {"A": "1", "B": "2.5", "Line.0": "10", "Line.1": "$1,000", "Total": "", "Avg": "", "Expr": ""}
        expand = lambda n: [n] if n in values else [k for k in values if k.startswith(n + ".")]
        changed = F.calculate(logic, values, ["Total", "Avg", "Expr"], expand)
        self.assertEqual(changed["Total"], "1013.5")
        self.assertEqual(changed["Avg"], "1.75")
        self.assertEqual(float(changed["Expr"]), (1 + 2.5) * 2 - 1013.5 / 4)
        with self.assertRaises(F.Unsupported):
            F.parse_sfn("A + * B")

    def test_script_generation_roundtrip(self):
        fmt, key = F.format_scripts({"kind": "number", "decimals": 1, "currency": "$"})
        self.assertEqual(F.describe_format(fmt)["decimals"], 1)
        self.assertEqual(F.describe_calculate(F.calculate_script({"kind": "sum", "fields": ["A", 'Q"x']}))["fields"], ["A", 'Q"x'])
        self.assertEqual(F.describe_validate(F.validate_script({"min": 1, "max": None})), {"kind": "range", "min": 1, "max": None})


class FormAuthoringTests(Base):
    def blank(self):
        return blank_pdf(self.tmp / "blank.pdf", pages=2)

    def test_create_every_field_kind_and_reopen(self):
        src = self.blank()
        ops = [
            {"op": "add_form_field", "type": "text", "name": "Name", "page": 0, "rect": [72, 700, 272, 722],
             "tooltip": "Full name", "required": True, "font": "times", "font_size": 11, "alignment": "center"},
            {"op": "add_form_field", "type": "text", "name": "Notes", "page": 0, "rect": [72, 600, 272, 680], "multiline": True},
            {"op": "add_form_field", "type": "text", "name": "Zip", "page": 0, "rect": [300, 700, 400, 722],
             "max_length": 5, "comb": True},
            {"op": "add_form_field", "type": "checkbox", "name": "Agree", "page": 0, "rect": [72, 560, 86, 574], "export_value": "Agreed"},
            {"op": "add_form_field", "type": "radio", "name": "Size", "page": 0, "rect": [72, 530, 86, 544], "export_value": "Small"},
            {"op": "add_form_field", "type": "radio", "name": "Size", "page": 0, "rect": [100, 530, 114, 544], "export_value": "Large"},
            {"op": "add_form_field", "type": "combo", "name": "Color", "page": 0, "rect": [72, 490, 222, 512],
             "options": [{"label": "Red", "export": "R"}, {"label": "Green", "export": "G"}], "editable": True},
            {"op": "add_form_field", "type": "list", "name": "Toppings", "page": 0, "rect": [72, 400, 222, 470],
             "options": ["Cheese", "Olives", "Peppers"], "multi_select": True},
            {"op": "add_form_field", "type": "date", "name": "Date", "page": 1, "rect": [72, 700, 172, 722], "date_format": "yyyy-mm-dd"},
            {"op": "add_form_field", "type": "signature", "name": "Sign Here", "page": 1, "rect": [72, 600, 272, 650]},
            {"op": "add_form_field", "type": "button", "name": "Submit", "page": 1, "rect": [72, 550, 162, 574],
             "caption": "Send", "action": {"kind": "submit", "url": "https://example.test/submit", "format": "xfdf"}},
            {"op": "add_form_field", "type": "button", "name": "Clear", "page": 1, "rect": [172, 550, 262, 574],
             "action": {"kind": "reset"}},
            {"op": "add_form_field", "type": "button", "name": "PrintIt", "page": 1, "rect": [272, 550, 362, 574],
             "action": {"kind": "print"}},
            {"op": "add_form_field", "type": "barcode", "name": "Code", "page": 1, "rect": [400, 600, 496, 696],
             "barcode": {"symbology": "qr", "fields": ["Name", "Zip"]}, "matrix": [[1, 0, 1], [0, 1, 0], [1, 0, 1]]},
        ]
        out, result = self.run_ops(src, ops)
        info = fields_of(out)
        self.assertEqual(set(info), {"Name", "Notes", "Zip", "Agree", "Size", "Color", "Toppings", "Date", "Sign Here",
                                     "Submit", "Clear", "PrintIt", "Code"})
        self.assertEqual(info["Name"]["tooltip"], "Full name")
        self.assertTrue(info["Name"]["required"])
        self.assertEqual(info["Name"]["font"], "times")
        self.assertEqual(info["Name"]["alignment"], "center")
        self.assertTrue(info["Notes"]["multiline"])
        self.assertTrue(info["Zip"]["comb"] and info["Zip"]["max_length"] == 5)
        self.assertEqual(info["Agree"]["exports"], ["Agreed"])
        self.assertEqual(info["Size"]["exports"], ["Large", "Small"])
        self.assertEqual(len(info["Size"]["widgets"]), 2)
        self.assertTrue(info["Color"]["editable"])
        self.assertEqual([o["export"] for o in info["Color"]["options"]], ["R", "G"])
        self.assertTrue(info["Toppings"]["multi_select"])
        self.assertEqual(info["Date"]["format"], {"kind": "date", "format": "yyyy-mm-dd"})
        self.assertEqual(info["Sign Here"]["kind"], "signature")
        self.assertEqual(info["Submit"]["action"]["kind"], "submit")
        self.assertEqual(info["Submit"]["action"]["format"], "xfdf")
        self.assertEqual(info["Submit"]["caption"], "Send")
        self.assertEqual(info["Clear"]["action"]["kind"], "reset")
        self.assertEqual(info["PrintIt"]["action"]["kind"], "print")
        self.assertEqual(info["Code"]["barcode"]["fields"], ["Name", "Zip"])
        # Every widget has an appearance; no NeedAppearances flag; DR has the standard fonts.
        with pikepdf.open(out) as pdf:
            acro = pdf.Root.AcroForm
            self.assertNotIn("/NeedAppearances", acro)
            self.assertIn("/Helv", acro.DR.Font)
            self.assertIn("/ZaDb", acro.DR.Font)
            for page in pdf.pages:
                for annot in page.Annots:
                    self.assertIn("/AP", annot, annot.get("/T"))
                    for key in annot.keys():
                        self.assertFalse(str(key).startswith("/ZPDF"), key)
        # The facade's independent reader (PDFium) sees every field.
        values = pdfium_values(out)
        self.assertIn("Size", values)
        self.assertEqual(len(values["Size"]), 2)

    def test_fill_all_kinds_with_appearances(self):
        src = self.blank()
        created, _ = self.run_ops(src, [
            {"op": "add_form_field", "type": "text", "name": "Name", "page": 0, "rect": [72, 700, 272, 722]},
            {"op": "add_form_field", "type": "checkbox", "name": "Agree", "page": 0, "rect": [72, 560, 86, 574]},
            {"op": "add_form_field", "type": "radio", "name": "Size", "page": 0, "rect": [72, 530, 86, 544], "export_value": "S"},
            {"op": "add_form_field", "type": "radio", "name": "Size", "page": 0, "rect": [100, 530, 114, 544], "export_value": "L"},
            {"op": "add_form_field", "type": "combo", "name": "Color", "page": 0, "rect": [72, 490, 222, 512],
             "options": ["Red", "Green"], "editable": True},
            {"op": "add_form_field", "type": "combo", "name": "Fixed", "page": 0, "rect": [250, 490, 400, 512],
             "options": ["One", "Two"]},
            {"op": "add_form_field", "type": "list", "name": "Toppings", "page": 0, "rect": [72, 400, 222, 470],
             "options": ["Cheese", "Olives", "Peppers"], "multi_select": True},
        ], name="created.pdf")
        filled, _ = self.run_ops(created, [{"op": "fill_fields", "values": {
            "Name": "Zoë Ünïcode ✓", "Agree": True, "Size": "L", "Color": "Purple", "Toppings": ["Olives", "Cheese"],
            "Fixed": "Two"}}], name="filled.pdf")
        info = fields_of(filled)
        self.assertEqual(info["Name"]["value"], "Zoë Ünïcode ✓")
        self.assertEqual(info["Agree"]["value"], "Yes")
        self.assertEqual(info["Size"]["value"], "L")
        self.assertEqual(info["Color"]["value"], "Purple")
        self.assertEqual(info["Toppings"]["value"], ["Cheese", "Olives"])
        values = pdfium_values(filled)
        self.assertEqual(values["Name"][0][0], "Zoë Ünïcode ✓")
        self.assertTrue(values["Agree"][0][1])
        self.assertEqual([checked for _, checked in values["Size"]], [False, True])
        self.assertEqual(values["Color"][0][0], "Purple")
        self.assertEqual(values["Fixed"][0][0], "Two")
        with pikepdf.open(filled) as pdf:
            size = next(f for f in pdf.Root.AcroForm.Fields if str(f.get("/T")) == "Size")
            self.assertEqual([str(k.AS) for k in size.Kids], ["/Off", "/L"])
            toppings = next(f for f in pdf.Root.AcroForm.Fields if str(f.get("/T")) == "Toppings")
            self.assertEqual(list(toppings.I), [0, 1])
        # Unicode value renders (embedded subset font) — visible after flattening.
        flat, _ = self.run_ops(filled, [{"op": "flatten_form_fields"}], name="flat.pdf")
        self.assertIn("Zoë Ünïcode", text_of(flat))
        self.assertIn("Purple", text_of(flat))
        with pikepdf.open(flat) as pdf:
            self.assertNotIn("/AcroForm", pdf.Root)
        with self.assertRaises(EngineError):
            self.run_ops(created, [{"op": "fill_fields", "values": {"Fixed": "Nope"}}], name="bad.pdf")
        with self.assertRaises(EngineError):
            self.run_ops(created, [{"op": "fill_fields", "values": {"Size": "M"}}], name="bad2.pdf")

    def test_calculation_format_validation_end_to_end(self):
        src = self.blank()
        out, _ = self.run_ops(src, [
            {"op": "add_form_field", "type": "number", "name": "Price", "page": 0, "rect": [72, 700, 172, 722],
             "format": {"kind": "number", "decimals": 2, "currency": "$"}},
            {"op": "add_form_field", "type": "text", "name": "Qty", "page": 0, "rect": [72, 670, 172, 692],
             "validate": {"min": 0, "max": 100}},
            {"op": "add_form_field", "type": "text", "name": "Total", "page": 0, "rect": [72, 640, 172, 662],
             "readonly": True, "format": {"kind": "number", "decimals": 2, "currency": "$"},
             "calculate": {"kind": "sfn", "expression": "Price * Qty"}},
            {"op": "add_form_field", "type": "text", "name": "Sum", "page": 0, "rect": [72, 610, 172, 632],
             "calculate": {"kind": "sum", "fields": ["Price", "Qty"]}},
        ], name="calc.pdf")
        info = fields_of(out)
        self.assertEqual(info["Total"]["calculate"], {"kind": "sfn", "expression": "Price * Qty"})
        live = transforms.inspect(out, "form_calculate", {"values": {"Price": "$1,234.50", "Qty": "3"}})
        self.assertEqual(live["calculated"]["Total"], "3703.5")
        self.assertEqual(live["display"]["Total"], "$3,703.50")
        self.assertEqual(live["normalized"]["Price"], "1234.5")
        self.assertIn("Qty", transforms.inspect(out, "form_calculate", {"values": {"Qty": "500"}})["errors"])
        filled, result = self.run_ops(out, [{"op": "fill_fields", "values": {"Price": "$1,234.50", "Qty": "3"}}], name="filled.pdf")
        info = fields_of(filled)
        self.assertEqual(info["Price"]["value"], "1234.5")
        self.assertEqual(info["Total"]["value"], "3703.5")
        self.assertEqual(info["Sum"]["value"], "1237.5")
        with pikepdf.open(filled) as pdf:
            self.assertEqual(len(pdf.Root.AcroForm.CO), 2)
        flat, _ = self.run_ops(filled, [{"op": "flatten_form_fields"}], name="flat.pdf")
        text = text_of(flat)
        self.assertIn("$3,703.50", text)
        self.assertIn("$1,234.50", text)
        with self.assertRaises(EngineError) as ctx:
            self.run_ops(out, [{"op": "fill_fields", "values": {"Qty": "500"}}], name="bad.pdf")
        self.assertEqual(ctx.exception.code, "INVALID_FIELD_VALUE")
        # Widget-located fills (the PDFKit Save path) recalculate too.
        with pikepdf.open(out) as pdf:
            annots = list(pdf.pages[0].Annots)
            price_index = next(i for i, a in enumerate(annots) if str(a.get("/T")) == "Price")
            qty_index = next(i for i, a in enumerate(annots) if str(a.get("/T")) == "Qty")
        widget_filled, _ = self.run_ops(out, [{"op": "fill_widgets", "edits": [
            {"page": 0, "index": price_index, "name": "Price", "value": "10"},
            {"page": 0, "index": qty_index, "name": "Qty", "value": "4"}]}], name="widgets.pdf")
        self.assertEqual(fields_of(widget_filled)["Total"]["value"], "40")

    def test_update_rename_move_delete_duplicate(self):
        src = self.blank()
        out, _ = self.run_ops(src, [
            {"op": "add_form_field", "type": "text", "name": "A", "page": 0, "rect": [72, 700, 172, 722]},
            {"op": "add_form_field", "type": "text", "name": "B", "page": 0, "rect": [72, 670, 172, 692]},
            {"op": "add_form_field", "type": "text", "name": "T", "page": 0, "rect": [72, 640, 172, 662],
             "calculate": {"kind": "sum", "fields": ["A", "B"]}},
        ], name="base.pdf")
        updated, _ = self.run_ops(out, [
            {"op": "update_form_field", "name": "A", "new_name": "Alpha", "tooltip": "First", "fill_color": [255, 255, 0],
             "border_style": "dashed", "readonly": True, "default": "5", "rect": [80, 700, 200, 724]},
            {"op": "duplicate_form_field", "name": "B", "pages": [1]},
            {"op": "delete_form_field", "name": "T"},
        ], name="updated.pdf")
        info = fields_of(updated)
        self.assertEqual(set(info), {"Alpha", "B"})
        self.assertEqual(info["Alpha"]["tooltip"], "First")
        self.assertTrue(info["Alpha"]["readonly"])
        self.assertEqual(info["Alpha"]["fill_color"], [1.0, 1.0, 0.0])
        self.assertEqual(info["Alpha"]["border_style"], "dashed")
        self.assertEqual(info["Alpha"]["default"], "5")
        self.assertEqual(info["Alpha"]["widgets"][0]["rect"], [80.0, 700.0, 200.0, 724.0])
        self.assertEqual([w["page"] for w in info["B"]["widgets"]], [0, 1])
        linked, _ = self.run_ops(updated, [{"op": "fill_fields", "values": {"B": "shared"}}], name="linked.pdf")
        self.assertEqual([v for v, _ in pdfium_values(linked)["B"]], ["shared", "shared"])
        with pikepdf.open(updated) as pdf:
            self.assertNotIn("/CO", pdf.Root.AcroForm)
        # Renaming keeps calculations pointing at the renamed field.
        renamed, _ = self.run_ops(out, [{"op": "update_form_field", "name": "A", "new_name": "Alpha"}], name="renamed.pdf")
        self.assertEqual(fields_of(renamed)["T"]["calculate"]["fields"], ["Alpha", "B"])

    def test_tab_and_calculation_order(self):
        src = self.blank()
        out, _ = self.run_ops(src, [
            {"op": "add_form_field", "type": "text", "name": n, "page": 0, "rect": [72, 700 - 30 * i, 172, 722 - 30 * i]}
            for i, n in enumerate(["A", "B", "C"])], name="base.pdf")
        ordered, _ = self.run_ops(out, [{"op": "set_tab_order", "page": 0, "order": ["C", "A", "B"]}], name="o.pdf")
        with pikepdf.open(ordered) as pdf:
            self.assertEqual([str(a.T) for a in pdf.pages[0].Annots], ["C", "A", "B"])
        rows, _ = self.run_ops(out, [{"op": "set_tab_order", "page": 0, "mode": "row"}], name="r.pdf")
        self.assertEqual(transforms.inspect(rows, "form_fields")["tab_order"][0], "row")

    def test_flatten_prune_and_annotation_flatten(self):
        src = self.fixture("uscis-i9.pdf")
        before = len(fields_of(src))
        self.assertGreater(before, 100)
        out, result = self.run_ops(src, [{"op": "flatten_annotations", "include_widgets": True}])
        with pikepdf.open(out) as pdf:
            self.assertNotIn("/AcroForm", pdf.Root)
        partial, _ = self.run_ops(src, [{"op": "flatten_form_fields", "names": [next(iter(fields_of(src)))]}], name="p.pdf")
        self.assertEqual(len(fields_of(partial)), before - 1)

    def test_convert_hybrid_xfa(self):
        src = self.fixture("irs-w9.pdf")
        with pikepdf.open(src) as pdf:
            self.assertIn("/XFA", pdf.Root.AcroForm)
        out, result = self.run_ops(src, [{"op": "convert_xfa_form"}])
        with pikepdf.open(out) as pdf:
            self.assertNotIn("/XFA", pdf.Root.AcroForm)
        doc = pdfium.PdfDocument(str(out))
        self.assertEqual(raw.FPDF_GetFormType(doc), raw.FORMTYPE_ACRO_FORM)
        doc.close()
        self.assertGreater(result["results"][0]["fields"], 10)
        with self.assertRaises(EngineError):
            self.run_ops(self.fixture("uscis-i9.pdf"), [{"op": "convert_xfa_form"}], name="no.pdf")

    def test_existing_form_edit_properties(self):
        src = self.fixture("uscis-i9.pdf")
        info = fields_of(src)
        text_name = next(n for n, f in info.items() if f["kind"] == "text" and not f["readonly"])
        out, _ = self.run_ops(src, [{"op": "update_form_field", "name": text_name, "required": True,
                                     "format": {"kind": "date", "format": "mm/dd/yyyy"}}])
        updated = fields_of(out)[text_name]
        self.assertTrue(updated["required"])
        self.assertEqual(updated["format"]["kind"], "date")


class FillSignTests(Base):
    def test_image_stamp_and_markup_notes(self):
        import base64, io
        from PIL import Image
        image = Image.new("RGBA", (200, 60), (0, 0, 0, 0))
        for x in range(20, 180):
            image.putpixel((x, 30), (0, 0, 0, 255))
        buffer = io.BytesIO()
        image.save(buffer, "PNG")
        src = blank_pdf(self.tmp / "blank.pdf")
        out, result = self.run_ops(src, [
            {"op": "place_image_stamp", "page": 0, "rect": [100, 100, 250, 145],
             "image": base64.b64encode(buffer.getvalue()).decode(), "kind": "signature", "author": "Ada"},
            {"op": "add_markup_note", "page": 0, "kind": "sticky_note", "rect": [300, 700, 320, 720], "contents": "Hi"},
            {"op": "add_markup_note", "page": 0, "kind": "highlight", "rect": [72, 600, 300, 614], "color": [255, 230, 0]},
        ])
        with pikepdf.open(out) as pdf:
            annots = list(pdf.pages[0].Annots)
            stamp = next(a for a in annots if a.Subtype == "/Stamp")
            self.assertEqual(str(stamp.Name), "/ZPDFSignature")
            image_xobject = stamp.AP.N.Resources.XObject.Im1
            self.assertIn("/SMask", image_xobject, "transparent signature keeps its alpha")
            self.assertEqual(str(next(a for a in annots if a.Subtype == "/Text").Contents), "Hi")
            highlight = next(a for a in annots if a.Subtype == "/Highlight")
            self.assertEqual(len(highlight.QuadPoints), 8)
            self.assertIn("/N", highlight.AP)
        flat, _ = self.run_ops(out, [{"op": "flatten_annotations"}], name="flat.pdf")
        with pikepdf.open(flat) as pdf:
            self.assertFalse(any(a.Subtype == "/Stamp" for a in pdf.pages[0].get("/Annots", [])))


class SecurityTests(Base):
    def test_password_encrypt_permissions_and_remove(self):
        src = self.fixture("uscis-i9.pdf")
        marked, _ = self.run_ops(src, [{"op": "set_security", "mode": "Password", "token": "t"}], name="m.pdf")
        info = transforms.inspect(marked, "security_info")
        self.assertEqual(info["marker"]["mode"], "Password")
        enc, _ = self.run_ops(marked, [{"op": "apply_security", "user_password": "open", "owner_password": "owner",
                                        "permissions": {"print": "low", "changes": "fill", "copy": False}}], name="e.pdf")
        with self.assertRaises(pikepdf.PasswordError):
            pikepdf.open(enc)
        with pikepdf.open(enc, password="open") as pdf:
            self.assertEqual(pdf.encryption.R, 6)
            self.assertFalse(pdf.allow.extract)
            self.assertFalse(pdf.allow.print_highres)
            self.assertTrue(pdf.allow.print_lowres)
            self.assertTrue(pdf.allow.modify_form)
            self.assertFalse(pdf.allow.modify_other)
            self.assertNotIn("/ZPDFSecurity", pdf.Root)
        # PDFium (independent reader) also needs and accepts the password.
        doc = pdfium.PdfDocument(str(enc), password="open")
        self.assertEqual(len(doc), 4)
        doc.close()
        # Open encrypted for editing: private decrypted revision + preserve marker.
        plain, result = self.run_ops(enc, [{"op": "decrypt_for_editing", "token": "k"}], password="open", name="plain.pdf")
        details = result["results"][0]
        self.assertTrue(details["user_password_matched"] and not details["owner_password_matched"])
        self.assertFalse(details["permissions"]["extract"])
        with pikepdf.open(plain) as pdf:
            self.assertFalse(pdf.is_encrypted)
        edited, _ = self.run_ops(plain, [{"op": "watermark", "text": "EDITED"}], name="edited.pdf")
        resaved, _ = self.run_ops(edited, [{"op": "apply_security", "original": str(enc), "original_password": "open"}],
                                  name="resaved.pdf")
        with pikepdf.open(resaved, password="open") as pdf:
            self.assertTrue(pdf.is_encrypted)
            self.assertEqual(pdf.encryption.R, 6)
            self.assertFalse(pdf.allow.extract)
        with pikepdf.open(resaved, password="owner") as pdf:
            self.assertTrue(pdf.owner_password_matched)
        self.assertIn("EDITED", text_of(resaved, password="open"))
        # Remove security.
        removed_marker, _ = self.run_ops(edited, [{"op": "set_security", "mode": "None"}], name="rm.pdf")
        removed, _ = self.run_ops(removed_marker, [{"op": "apply_security"}], name="removed.pdf")
        with pikepdf.open(removed) as pdf:
            self.assertFalse(pdf.is_encrypted)
            self.assertNotIn("/ZPDFSecurity", pdf.Root)

    def test_certificate_security_roundtrip(self):
        import base64, json, os, subprocess
        from transforms import cms as C, security
        ident = C.create_identity("Recipient", email="r@example.test", password="pw-123456")
        src = self.fixture("uscis-i9.pdf")
        marked, _ = self.run_ops(src, [{"op": "set_security", "mode": "Certificate", "token": "c"}], name="m.pdf")
        enc, result = self.run_ops(marked, [{"op": "apply_security", "recipients": [ident["certificate"]],
                                             "permissions": {"print": "low", "copy": False}}], name="cert.pdf")
        data = enc.read_bytes()
        self.assertIn(b"/Adobe.PubSec", data)
        self.assertNotIn(b"Employment Eligibility", data, "text must not be readable without the key")
        with self.assertRaises(pikepdf.PdfError):
            pikepdf.open(enc)
        # Decrypt with the recipient's digital ID, then with the file key.
        out = self.tmp / "plain.pdf"
        info = security.decrypt_certificate_file(str(enc), str(out), p12_b64=ident["p12"], password="pw-123456", token="t")
        self.assertEqual(info["page_count"], 4)
        self.assertFalse(info["can_copy"])
        self.assertTrue(info["can_print"])
        self.assertEqual(len(fields_of(out)), len(fields_of(src)))
        self.assertIn("Employment Eligibility", text_of(out))
        key = result["results"][0]["file_key"]
        again = self.tmp / "plain2.pdf"
        self.assertEqual(security.decrypt_certificate_file(str(enc), str(again), key_b64=key)["file_key"], key)
        other = C.create_identity("Stranger", password="pw-123456")
        with self.assertRaises(EngineError) as ctx:
            security.decrypt_certificate_file(str(enc), str(self.tmp / "no.pdf"), p12_b64=other["p12"], password="pw-123456")
        self.assertEqual(ctx.exception.code, "NOT_A_RECIPIENT")
        # Editing and saving keeps the same recipients and key.
        edited, _ = self.run_ops(out, [{"op": "watermark", "text": "EDITED"}], name="edited.pdf")
        kept, kept_result = self.run_ops(edited, [{"op": "apply_security", "certificate_key": key, "original": str(enc)}],
                                         name="kept.pdf")
        self.assertEqual(kept_result["results"][0]["file_key"], key)
        final = self.tmp / "final.pdf"
        security.decrypt_certificate_file(str(kept), str(final), p12_b64=ident["p12"], password="pw-123456")
        self.assertIn("EDITED", text_of(final))
        # Independent check: pyHanko decrypts the file with the recipient's key.
        hanko = os.environ.get("ZPDF_PYHANKO_PYTHON")
        if hanko:
            p12 = self.tmp / "id.p12"
            p12.write_bytes(base64.b64decode(ident["p12"]))
            script = (
                "import sys\n"
                "from pyhanko.pdf_utils.reader import PdfFileReader\n"
                "from pyhanko.pdf_utils.crypt import SimpleEnvelopeKeyDecrypter\n"
                "r = PdfFileReader(open(sys.argv[1], 'rb'))\n"
                "d = SimpleEnvelopeKeyDecrypter.load_pkcs12(sys.argv[2], b'pw-123456')\n"
                "print(r.decrypt_pubkey(d).status)\n"
                "print(r.root['/AcroForm']['/Fields'][0]['/T'])\n"
                "page = r.root['/Pages']['/Kids'][0]\n"
                "c = page['/Contents']\n"
                "c = c[0] if isinstance(c, list) else c\n"
                "print(len(c.data))\n")
            run = subprocess.run([hanko, "-c", script, str(enc), str(p12)], capture_output=True, text=True, timeout=120)
            self.assertEqual(run.returncode, 0, run.stderr[-1500:])
            self.assertIn("USER", run.stdout)
            with pikepdf.open(src) as plain:
                first = str(plain.Root.AcroForm.Fields[0].T)
            self.assertIn(first, run.stdout, "pyHanko decrypts strings to the original values")

    def test_aes128_and_owner_only(self):
        src = self.fixture("ordinary-edge.pdf")
        marked, _ = self.run_ops(src, [{"op": "set_security", "mode": "Password"}], name="m.pdf")
        enc, _ = self.run_ops(marked, [{"op": "apply_security", "owner_password": "owner", "method": "aes128",
                                        "permissions": {"changes": "none"}}], name="e.pdf")
        with pikepdf.open(enc) as pdf:  # no open password
            self.assertTrue(pdf.is_encrypted)
            self.assertEqual(pdf.encryption.R, 4)
            self.assertFalse(pdf.allow.modify_other)
        with self.assertRaises(EngineError):
            self.run_ops(marked, [{"op": "apply_security", "user_password": "same", "owner_password": "same"}], name="x.pdf")


if __name__ == "__main__":
    unittest.main(verbosity=2)
