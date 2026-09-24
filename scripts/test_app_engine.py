"""App-only adapter regression; run with Python containing pinned pypdfium2.

No UI, reader automation, or source fixture writes. Uses the bundled QPDF.
"""
from pathlib import Path
import hashlib
import json
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "EngineSupport"))
from app_engine import AppEngine, AppQPDF


class CommentThreadTests(unittest.TestCase):
    def test_cross_page_reply_blocks_deletion_without_publishing(self):
        qpdf_path = ROOT / "EngineSupport/engine/native/qpdf"
        fixture = ROOT / "zPDFTests/Fixtures/uscis-i9.pdf"
        original_hash = hashlib.sha256(fixture.read_bytes()).hexdigest()
        with tempfile.TemporaryDirectory(prefix="zpdf-thread-test-") as tmp:
            tmp = Path(tmp)
            source, threaded = tmp / "notes.pdf", tmp / "threaded.pdf"
            with AppEngine(qpdf_bin=qpdf_path) as engine:
                def call(command, **args):
                    response = engine.dispatch(command, **args)
                    self.assertTrue(response["ok"], response)
                    return response["result"]

                document = call("open", path=str(fixture))
                for page, contents in [(0, "Parent"), (1, "Reply")]:
                    document = call("annotate", ref=document["ref"], page_id=document["pages"][page]["id"],
                                    annotation={"type": "sticky_note", "rect": [20, 20, 44, 44],
                                                "contents": contents, "author": "Regression", "color": [255, 200, 0, 255]})
                call("save", ref=document["ref"], destination=str(source))
                qpdf = AppQPDF(qpdf_path)
                structure, _ = qpdf.inspect(source)
                refs = {}
                for page_info in structure.pages:
                    page = structure.resolve(page_info["object"])
                    for ref in structure.resolve(page.get("/Annots", [])):
                        contents = structure.resolve(ref).get("/Contents")
                        if contents in ("u:Parent", "u:Reply"):
                            refs[contents] = ref
                self.assertEqual(set(refs), {"u:Parent", "u:Reply"})
                reply = dict(structure.resolve(refs["u:Reply"]))
                reply["/IRT"] = refs["u:Parent"]
                patch = tmp / "thread.json"
                patch.write_text(json.dumps({"qpdf": [{"jsonversion": 2}, {
                    "obj:" + refs["u:Reply"]: {"value": reply}
                }]}), encoding="utf-8")
                qpdf.run([source, "--update-from-json=" + str(patch), threaded])
                document = call("open", path=str(threaded))
                parent = next(a for a in document["annotations"] if a["contents"] == "Parent")
                blocked = engine.dispatch("edit_comments", ref=document["ref"],
                                          edits=[{"annotation_id": parent["id"], "contents": None}])
                self.assertFalse(blocked["ok"])
                self.assertEqual(blocked["error"]["code"], "UNSUPPORTED_OPERATION")
                self.assertEqual(blocked["error"]["ref"], document["ref"])
                # The same revision and IDs remain valid after rejection.
                edited = call("edit_comments", ref=document["ref"],
                              edits=[{"annotation_id": parent["id"], "contents": "Edited parent"}])
                self.assertIn("Reply", [a["contents"] for a in edited["annotations"]])
                self.assertIn("Edited parent", [a["contents"] for a in edited["annotations"]])
        self.assertEqual(hashlib.sha256(fixture.read_bytes()).hexdigest(), original_hash)


class FieldAuthoringTests(unittest.TestCase):
    def test_empty_cells_lines_and_occupied_cells(self):
        from field_detection import candidates
        h=[(100,10,110),(120,10,110),(50,20,100)]
        v=[(10,100,120),(110,100,120)]
        found=candidates(h,v,[],[0,0,200,200])
        self.assertEqual(len(found),2)
        found=candidates(h,v,[[20,105,40,115]],[0,0,200,200])
        self.assertEqual(len(found),1)
        self.assertEqual(found[0]['rect'],[20,51,100,64])
        self.assertEqual(candidates([],[],[],[0,0,200,200]),[])

    def test_field_creation_validation_and_preservation(self):
        fixture=ROOT/'zPDFTests/Fixtures/irs-1040-worksheet-b.pdf'
        before=hashlib.sha256(fixture.read_bytes()).hexdigest()
        with AppEngine(qpdf_bin=ROOT/'EngineSupport/engine/native/qpdf') as engine:
            def call(command, **args):
                result=engine.dispatch(command,**args)
                self.assertTrue(result['ok'],result)
                return result['result']
            doc=call('open',path=str(fixture))
            field={'page_id':doc['pages'][0]['id'],'name':'Amount','type':'text','rect':[480.5,635.7,556.7,659.7]}
            for invalid in [dict(field,name=''),dict(field,rect=[-2,1,100,20]),dict(field,type='signature')]:
                result=engine.dispatch('add_fields',ref=doc['ref'],fields=[invalid])
                self.assertFalse(result['ok'])
                self.assertEqual(result['error']['ref'],doc['ref'])
            doc=call('add_fields',ref=doc['ref'],fields=[field])
            self.assertEqual(len(doc['fields']),1)
            result=engine.dispatch('add_fields',ref=doc['ref'],fields=[dict(field,page_id=doc['pages'][0]['id'])])
            self.assertFalse(result['ok'])
            doc=call('fill',ref=doc['ref'],field_id=doc['fields'][0]['id'],value='123.45')
            self.assertEqual(doc['fields'][0]['value'],'123.45')
        self.assertEqual(hashlib.sha256(fixture.read_bytes()).hexdigest(),before)


if __name__ == "__main__":
    unittest.main()
