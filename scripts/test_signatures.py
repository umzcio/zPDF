"""Digital-signature regressions (dev venv with the pinned wheels).

    python scripts/test_signatures.py

Independent checks: when `ZPDF_PYHANKO_PYTHON` points at a Python with
pyHanko installed, every signature is also validated by pyHanko; when an
OpenSSL 3 binary is found, the CMS blob is verified with `openssl cms`.
Networked parts use a local in-process RFC 3161 timestamp authority.
"""
from pathlib import Path
import base64
import datetime as dt
import hashlib
import http.server
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "EngineSupport"))
sys.path.insert(0, str(ROOT / "scripts"))
import pikepdf
import transforms
from transforms import cms as C
from engine.errors import EngineError
from test_transforms import Base, blank_pdf

from asn1crypto import cms, tsp, algos, core, x509 as ax509
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID

PYHANKO = os.environ.get("ZPDF_PYHANKO_PYTHON")
OPENSSL = next((p for p in ("/opt/homebrew/bin/openssl", "/usr/local/bin/openssl") if Path(p).exists()), None)
PASSWORD = "correct horse"


def identity(name="Test Signer", key="rsa2048"):
    info = C.create_identity(name, email="signer@example.test", organization="zPDF Tests", key=key, password=PASSWORD)
    return info


class MockTSA:
    """RFC 3161 responder signing with a throwaway RSA key."""

    def __init__(self):
        self.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "zPDF Test TSA")])
        now = dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=5)
        self.cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                     .public_key(self.key.public_key()).serial_number(7)
                     .not_valid_before(now).not_valid_after(now + dt.timedelta(days=30))
                     .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.TIME_STAMPING]), critical=True)
                     .sign(self.key, hashes.SHA256()))
        self.requests = 0

    def respond(self, body):
        self.requests += 1
        req = tsp.TimeStampReq.load(body)
        ac = ax509.Certificate.load(self.cert.public_bytes(serialization.Encoding.DER))
        info = tsp.TSTInfo({
            "version": 1, "policy": "1.2.3.4.1", "message_imprint": req["message_imprint"],
            "serial_number": self.requests, "gen_time": dt.datetime.now(dt.timezone.utc),
            "nonce": req["nonce"], "accuracy": {"seconds": 1}})
        encap = info.dump()
        attrs = cms.CMSAttributes([
            cms.CMSAttribute({"type": "content_type", "values": ["tst_info"]}),
            cms.CMSAttribute({"type": "message_digest", "values": [hashlib.sha256(encap).digest()]}),
            cms.CMSAttribute({"type": "signing_certificate_v2", "values": [tsp.SigningCertificateV2({"certs": [
                tsp.ESSCertIDv2({"hash_algorithm": {"algorithm": "sha256"}, "cert_hash": hashlib.sha256(ac.dump()).digest()})]})]}),
        ])
        signature = self.key.sign(attrs.dump(), padding.PKCS1v15(), hashes.SHA256())
        signed = cms.SignedData({
            "version": "v3", "digest_algorithms": [{"algorithm": "sha256"}],
            "encap_content_info": {"content_type": "tst_info", "content": core.ParsableOctetString(encap)},
            "certificates": [ac],
            "signer_infos": [cms.SignerInfo({
                "version": "v1", "sid": cms.SignerIdentifier({"issuer_and_serial_number": {
                    "issuer": ac.issuer, "serial_number": ac.serial_number}}),
                "digest_algorithm": {"algorithm": "sha256"}, "signed_attrs": attrs,
                "signature_algorithm": {"algorithm": "rsassa_pkcs1v15"}, "signature": signature})]})
        token = cms.ContentInfo({"content_type": "signed_data", "content": signed})
        return tsp.TimeStampResp({"status": {"status": "granted"}, "time_stamp_token": token}).dump()

    def fetch(self, url, body, content_type):
        assert content_type == "application/timestamp-query"
        return self.respond(body)


def pyhanko_check(path, trusted_der):
    if not PYHANKO:
        return None
    script = r'''
import sys, json
from pyhanko.pdf_utils.reader import PdfFileReader
from pyhanko.sign.validation import validate_pdf_signature
from pyhanko_certvalidator import ValidationContext
from asn1crypto import x509
roots = [x509.Certificate.load(bytes.fromhex(h)) for h in sys.argv[2:]]
out = []
with open(sys.argv[1], "rb") as f:
    r = PdfFileReader(f)
    for sig in r.embedded_signatures:
        st = validate_pdf_signature(sig, ValidationContext(trust_roots=roots, allow_fetching=False))
        out.append({"intact": st.intact, "valid": st.valid, "trusted": st.trusted,
                    "coverage": str(st.coverage), "modification": str(st.modification_level),
                    "docmdp_ok": st.docmdp_ok, "timestamp": st.timestamp_validity is not None and st.timestamp_validity.intact})
print(json.dumps(out))
'''
    result = subprocess.run([PYHANKO, "-c", script, str(path)] + [d.hex() for d in trusted_der],
                            capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        raise AssertionError(result.stderr[-2000:])
    return json.loads(result.stdout)


def openssl_check(path, tmp, index=0):
    if not OPENSSL:
        return None
    data = Path(path).read_bytes()
    with pikepdf.open(path) as pdf:
        from transforms.signatures import signature_fields
        sigs = [f.V for _, f in signature_fields(pdf) if "/V" in f]
        v = sigs[index]
        ranges = [int(x) for x in v.ByteRange]
        blob = bytes(v.Contents)
    content = tmp / "signed-bytes.bin"
    content.write_bytes(data[ranges[0]:ranges[0] + ranges[1]] + data[ranges[2]:ranges[2] + ranges[3]])
    der = cms.ContentInfo.load(blob).dump()
    sig = tmp / "sig.der"
    sig.write_bytes(der)
    result = subprocess.run([OPENSSL, "cms", "-verify", "-binary", "-inform", "DER", "-in", str(sig),
                             "-content", str(content), "-noverify", "-out", os.devnull],
                            capture_output=True, text=True)
    return result.returncode == 0, result.stderr


class SignatureTests(Base):
    def setUp(self):
        super().setUp()
        self.id = identity()
        self.cert_der = base64.b64decode(self.id["certificate"])

    def ident(self):
        return {"p12": self.id["p12"], "password": PASSWORD}

    def query(self, path, name="signatures", **params):
        return transforms.inspect(path, name, params)

    def test_identity_roundtrip_and_password(self):
        info = C.inspect_identity(self.id["p12"], PASSWORD)
        self.assertEqual(info["name"], "Test Signer")
        self.assertEqual(info["email"], "signer@example.test")
        self.assertTrue(info["self_signed"])
        with self.assertRaises(EngineError) as ctx:
            C.load_identity(self.id["p12"], "wrong")
        self.assertEqual(ctx.exception.code, "INVALID_PASSWORD")
        ec = identity("EC Signer", key="p256")
        self.assertTrue(ec["algorithm"].startswith("ECDSA"))

    def test_visible_signature_is_incremental_and_valid(self):
        src = self.fixture("uscis-i9.pdf")
        original = src.read_bytes()
        out, result = self.run_ops(src, [{"op": "sign", "identity": self.ident(), "page": 0,
                                          "rect": [300, 60, 520, 110], "reason": "I approve",
                                          "location": "Missoula, MT"}])
        data = out.read_bytes()
        self.assertTrue(data.startswith(original), "signing must append to the original bytes")
        report = self.query(out)["signatures"]
        self.assertEqual(len(report), 1)
        sig = report[0]
        self.assertTrue(sig["signed"] and sig["integrity"] and sig["covers_document"], sig)
        self.assertEqual(sig["signer"]["name"], "Test Signer")
        self.assertEqual(sig["reason"], "I approve")
        self.assertEqual(sig["subfilter"], "ETSI.CAdES.detached")
        self.assertTrue(sig["pades_attributes"])
        # Independent verifications.
        ok = openssl_check(out, self.tmp)
        if ok is not None:
            self.assertTrue(ok[0], ok[1])
        hanko = pyhanko_check(out, [self.cert_der])
        if hanko is not None:
            self.assertTrue(hanko[0]["intact"] and hanko[0]["valid"] and hanko[0]["trusted"], hanko)
            self.assertIn("ENTIRE_FILE", hanko[0]["coverage"])
        # The widget has a visible appearance and PDFium renders the page.
        with pikepdf.open(out) as pdf:
            widget = next(a for a in pdf.pages[0].Annots if a.get("/FT") == "/Sig")
            self.assertIn("/N", widget.AP)
            self.assertEqual(pdf.Root.AcroForm.SigFlags, 3)

    def test_signing_object_stream_and_linearized_pdfs(self):
        """Browser/Office/Docs exports use object streams, xref streams and often
        linearization; pikepdf lists unused object numbers there as None."""
        for label, opts in [("objstreams", dict(object_stream_mode=pikepdf.ObjectStreamMode.generate)),
                            ("linearized", dict(linearize=True))]:
            with self.subTest(label):
                src = self.tmp / f"{label}.pdf"
                with pikepdf.open(ROOT / "zPDFTests/Fixtures/irs-1040-worksheet-b.pdf") as pdf:
                    pdf.save(src, **opts)
                original = src.read_bytes()
                out, _ = self.run_ops(src, [{"op": "sign", "identity": self.ident(), "page": 0,
                                              "rect": [100, 100, 300, 160], "reason": "I approve"}],
                                      name=f"{label}-signed.pdf")
                self.assertTrue(out.read_bytes().startswith(original), "signing appends to the original bytes")
                sig = self.query(out)["signatures"][0]
                self.assertTrue(sig["signed"] and sig["integrity"] and sig["covers_document"], sig)
                hanko = pyhanko_check(out, [self.cert_der])
                if hanko is not None:
                    self.assertTrue(hanko[0]["intact"] and hanko[0]["valid"], hanko)

    def test_signing_pdf_with_indirect_numbers(self):
        """wkhtmltopdf/Qt (and others) store stream lengths as indirect integer
        objects; pikepdf lists those in pdf.objects as plain Python ints."""
        content = b"BT /F1 24 Tf 72 700 Td (Indirect lengths) Tj ET"
        body = [b"<< /Type /Catalog /Pages 2 0 R >>",
                b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
                b"/Resources << /Font << /F1 6 0 R >> >> >>",
                b"<< /Length 5 0 R >>\nstream\n" + content + b"\nendstream",
                str(len(content)).encode(),
                b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
        data, offsets = b"%PDF-1.4\n", []
        for number, obj in enumerate(body, 1):
            offsets.append(len(data))
            data += f"{number} 0 obj\n".encode() + obj + b"\nendobj\n"
        xref = len(data)
        data += f"xref\n0 {len(body) + 1}\n0000000000 65535 f \n".encode()
        data += b"".join(f"{o:010d} 00000 n \n".encode() for o in offsets)
        data += f"trailer\n<< /Size {len(body) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
        src = self.tmp / "indirect-numbers.pdf"
        src.write_bytes(data)
        with pikepdf.open(src) as pdf:
            self.assertTrue(any(isinstance(o, int) for o in pdf.objects), "fixture must reproduce the int case")
        out, _ = self.run_ops(src, [{"op": "sign", "identity": self.ident(), "page": 0,
                                      "rect": [100, 100, 300, 160], "reason": "I approve"}], name="indirect-signed.pdf")
        self.assertTrue(out.read_bytes().startswith(data))
        sig = self.query(out)["signatures"][0]
        self.assertTrue(sig["signed"] and sig["integrity"] and sig["covers_document"], sig)

    def test_second_signature_keeps_first_valid(self):
        src = self.fixture("uscis-i9.pdf")
        one, _ = self.run_ops(src, [{"op": "sign", "identity": self.ident(), "page": 0, "rect": [40, 40, 200, 80]}], name="one.pdf")
        other = identity("Second Signer")
        two, _ = self.run_ops(one, [{"op": "sign", "identity": {"p12": other["p12"], "password": PASSWORD},
                                     "page": 1, "rect": [40, 40, 200, 80]}], name="two.pdf")
        report = self.query(two)["signatures"]
        signed = [s for s in report if s["signed"]]
        self.assertEqual(len(signed), 2)
        first = next(s for s in signed if s["signer"]["name"] == "Test Signer")
        second = next(s for s in signed if s["signer"]["name"] == "Second Signer")
        self.assertTrue(first["integrity"] and not first["covers_document"])
        self.assertEqual(first["changes_after"], ["signatures"])
        self.assertTrue(second["integrity"] and second["covers_document"])
        hanko = pyhanko_check(two, [self.cert_der, base64.b64decode(other["certificate"])])
        if hanko is not None:
            self.assertTrue(all(h["intact"] and h["valid"] for h in hanko), hanko)

    def test_edit_after_signing_is_appended_and_detected(self):
        src = self.fixture("uscis-i9.pdf")
        signed, _ = self.run_ops(src, [{"op": "sign", "identity": self.ident(), "page": 0, "rect": [40, 40, 200, 80]}], name="s.pdf")
        before = signed.read_bytes()
        edited, _ = self.run_ops(signed, [{"op": "watermark", "text": "LATER"}], name="edited.pdf")
        self.assertTrue(edited.read_bytes().startswith(before))
        sig = next(s for s in self.query(edited)["signatures"] if s["signed"])
        self.assertTrue(sig["integrity"])
        self.assertFalse(sig["covers_document"])
        self.assertIn("content", sig["changes_after"])

    def test_invisible_signature_and_existing_field(self):
        src = blank_pdf(self.tmp / "blank.pdf", pages=2)
        out, _ = self.run_ops(src, [{"op": "add_form_field", "type": "signature", "name": "Approver",
                                     "page": 1, "rect": [72, 72, 272, 132]}], name="field.pdf")
        empty = self.query(out)["signatures"]
        self.assertEqual([(s["field"], s["signed"]) for s in empty], [("Approver", False)])
        signed, _ = self.run_ops(out, [{"op": "sign", "identity": self.ident(), "field": "Approver"}], name="signed.pdf")
        sig = self.query(signed)["signatures"][0]
        self.assertTrue(sig["signed"] and sig["integrity"] and sig["page"] == 1)
        invisible, _ = self.run_ops(src, [{"op": "sign", "identity": self.ident(), "page": 0}], name="inv.pdf")
        sig = self.query(invisible)["signatures"][0]
        self.assertTrue(sig["integrity"] and not sig["visible"])

    def test_certify_docmdp(self):
        src = self.fixture("uscis-i9.pdf")
        cert, _ = self.run_ops(src, [{"op": "sign", "identity": self.ident(), "page": 0, "rect": [40, 40, 200, 80],
                                      "certify": 2}], name="cert.pdf")
        report = self.query(cert)
        self.assertEqual(report["certification"], 2)
        sig = report["signatures"][0]
        self.assertEqual(sig["certification"], 2)
        self.assertFalse(sig["mdp_violation"])
        hanko = pyhanko_check(cert, [self.cert_der])
        if hanko is not None:
            self.assertTrue(hanko[0]["intact"] and hanko[0]["valid"] and hanko[0]["docmdp_ok"], hanko)
        changed, _ = self.run_ops(cert, [{"op": "watermark", "text": "NOT ALLOWED"}], name="violated.pdf")
        sig = self.query(changed)["signatures"][0]
        self.assertTrue(sig["mdp_violation"])
        locked, _ = self.run_ops(src, [{"op": "sign", "identity": self.ident(), "page": 0, "certify": 1}], name="p1.pdf")
        with self.assertRaises(EngineError) as ctx:
            self.run_ops(locked, [{"op": "sign", "identity": self.ident(), "page": 0}], name="again.pdf")
        self.assertEqual(ctx.exception.code, "CERTIFIED_NO_CHANGES")

    def test_timestamp_and_ltv(self):
        tsa = MockTSA()
        src = self.fixture("uscis-i9.pdf")
        out, _ = self.run_ops(src, [{"op": "sign", "identity": self.ident(), "page": 0, "rect": [40, 40, 200, 80],
                                     "timestamp_url": "http://tsa.invalid/", "_fetch": tsa.fetch}], name="ts.pdf")
        self.assertEqual(tsa.requests, 1)
        sig = self.query(out)["signatures"][0]
        self.assertTrue(sig["integrity"])
        self.assertTrue(sig["timestamp"]["valid"], sig["timestamp"])
        hanko = pyhanko_check(out, [self.cert_der, tsa.cert.public_bytes(serialization.Encoding.DER)])
        if hanko is not None:
            self.assertTrue(hanko[0]["intact"] and hanko[0]["valid"] and hanko[0]["timestamp"], hanko)
        ltv, result = self.run_ops(out, [{"op": "add_ltv"}], name="ltv.pdf")
        self.assertTrue(ltv.read_bytes().startswith(out.read_bytes()))
        report = self.query(ltv)
        self.assertTrue(report["has_dss"])
        sig = report["signatures"][0]
        self.assertTrue(sig["ltv"] and sig["integrity"])
        self.assertEqual(sig["changes_after"], ["security_store"])

    def test_tampering_detected(self):
        src = self.fixture("uscis-i9.pdf")
        out, _ = self.run_ops(src, [{"op": "sign", "identity": self.ident(), "page": 0, "rect": [40, 40, 200, 80]}])
        data = bytearray(out.read_bytes())
        # Flip a byte inside the signed range (in the first page's content area).
        index = data.index(b"endstream") - 5
        data[index] ^= 0x01
        tampered = self.tmp / "tampered.pdf"
        tampered.write_bytes(bytes(data))
        sig = self.query(tampered)["signatures"][0]
        self.assertFalse(sig["integrity"])
        self.assertFalse(sig["digest_valid"])

    def test_pkcs7_detached_and_ecdsa(self):
        src = self.fixture("ordinary-edge.pdf")
        ec = identity("EC Signer", key="p256")
        out, _ = self.run_ops(src, [{"op": "sign", "identity": {"p12": ec["p12"], "password": PASSWORD}, "page": 0,
                                     "rect": [40, 40, 200, 80], "subfilter": "pkcs7"}])
        sig = self.query(out)["signatures"][0]
        self.assertTrue(sig["integrity"], sig)
        self.assertEqual(sig["subfilter"], "adbe.pkcs7.detached")
        ok = openssl_check(out, self.tmp)
        if ok is not None:
            self.assertTrue(ok[0], ok[1])

    def test_signed_revision_extraction(self):
        src = self.fixture("uscis-i9.pdf")
        one, _ = self.run_ops(src, [{"op": "sign", "identity": self.ident(), "page": 0, "rect": [40, 40, 200, 80]}], name="one.pdf")
        edited, _ = self.run_ops(one, [{"op": "watermark", "text": "LATER"}], name="edited.pdf")
        field = self.query(edited)["signatures"][0]["field"]
        revision, _ = self.run_ops(edited, [{"op": "extract_signed_revision", "field": field}], name="rev.pdf")
        self.assertEqual(revision.read_bytes(), one.read_bytes())


if __name__ == "__main__":
    unittest.main(verbosity=2)
