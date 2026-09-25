"""Public-key (certificate) security: Adobe.PubSec / adbe.pkcs7.s5.

QPDF only implements the standard (password) security handler, so this
module encrypts and decrypts certificate-secured PDFs itself, following
ISO 32000-2 §7.6.5:

* A random 20-byte seed plus 4 permission bytes are wrapped in a CMS
  EnvelopedData for every recipient certificate (RSA key transport,
  PKCS#1 v1.5, content encrypted with AES-256-CBC).
* The file key is SHA-256(seed || each /Recipients blob [|| FFFFFFFF when
  metadata is not encrypted]) and every string and stream is encrypted
  with AES-256-CBC (AESV3), a random IV prepended — the same object
  encryption the standard AES-256 handler uses.

Excluded from encryption, as the specification requires: the encryption
dictionary, the trailer /ID, signature /Contents, cross-reference streams,
and /Metadata when EncryptMetadata is false. Only this module's output and
files using V5/AESV3 or V4/AESV2 crypt filters with RSA recipients can be
opened.
"""
import hashlib
import os
import re
import struct

import pikepdf
from pikepdf import Name

from engine.errors import EngineError, require

PLACEHOLDER = b"/ZPDFEnc"   # same length as /Encrypt
ENCRYPT_KEY = re.compile(rb"/Encrypt(?=[\s/<\[\(\d>])")


def _aes_cbc(key, data, iv=None, decrypt=False):
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    from cryptography.hazmat.primitives import padding
    if decrypt:
        if len(data) < 32 or len(data) % 16:
            return b"" if len(data) <= 16 else data  # tolerate empty/garbled strings
        iv, body = data[:16], data[16:]
        decryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
        padded = decryptor.update(body) + decryptor.finalize()
        unpadder = padding.PKCS7(128).unpadder()
        try:
            return unpadder.update(padded) + unpadder.finalize()
        except ValueError:
            return padded
    iv = iv or os.urandom(16)
    padder = padding.PKCS7(128).padder()
    padded = padder.update(data) + padder.finalize()
    encryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
    return iv + encryptor.update(padded) + encryptor.finalize()


def permission_value(spec):
    """PDF /P-style bits for the recipients' permissions (bit 1 = LSB)."""
    spec = spec or {}
    value = 0xFFFFFFFF
    def clear(bit):
        nonlocal value
        value &= ~(1 << (bit - 1))
    printing = spec.get("print", "high")
    changes = spec.get("changes", "any")
    if printing == "none":
        clear(3); clear(12)
    elif printing == "low":
        clear(12)
    if changes != "any":
        clear(4)
    if changes not in ("comments", "any"):
        clear(6)
    if changes not in ("fill", "comments", "any"):
        clear(9)
    if changes not in ("assembly", "any"):
        clear(11)
    if not spec.get("copy", True):
        clear(5)
    if not spec.get("accessibility", True):
        clear(10)
    return value


def build_recipients(certificates_der, seed, permissions):
    """One CMS EnvelopedData (DER) addressed to every certificate."""
    from asn1crypto import cms, x509 as ax509
    from cryptography import x509
    from cryptography.hazmat.primitives.asymmetric import padding, rsa
    content = seed + struct.pack(">I", permissions)
    envelope_key = os.urandom(32)
    iv = os.urandom(16)
    encrypted = _aes_cbc(envelope_key, content, iv=iv)[16:]
    infos = []
    for der in certificates_der:
        cert = x509.load_der_x509_certificate(der)
        key = cert.public_key()
        require(isinstance(key, rsa.RSAPublicKey), "UNSUPPORTED_OPERATION",
                "Certificate security needs RSA certificates. ECDSA digital IDs can sign but can’t receive encrypted documents.")
        ac = ax509.Certificate.load(der)
        infos.append(cms.RecipientInfo({"ktri": cms.KeyTransRecipientInfo({
            "version": "v0",
            "rid": cms.RecipientIdentifier({"issuer_and_serial_number": cms.IssuerAndSerialNumber(
                {"issuer": ac.issuer, "serial_number": ac.serial_number})}),
            "key_encryption_algorithm": {"algorithm": "rsaes_pkcs1v15"},
            "encrypted_key": key.encrypt(envelope_key, padding.PKCS1v15())})}))
    require(infos, "INVALID_ARGUMENT", "Choose at least one recipient certificate.")
    enveloped = cms.EnvelopedData({
        "version": "v0", "recipient_infos": infos,
        "encrypted_content_info": {"content_type": "data",
                                   "content_encryption_algorithm": {"algorithm": "aes256_cbc", "parameters": iv},
                                   "encrypted_content": encrypted}})
    return cms.ContentInfo({"content_type": "enveloped_data", "content": enveloped}).dump()


def file_key(seed, recipients, encrypt_metadata=True, length=32, sha256=True):
    h = hashlib.sha256() if sha256 else hashlib.sha1()
    h.update(seed)
    for blob in recipients:
        h.update(blob)
    if not encrypt_metadata:
        h.update(b"\xff\xff\xff\xff")
    return h.digest()[:length]


def open_seed(recipients, private_key, certificate):
    """Recover the seed (and permissions) with the recipient's private key."""
    from asn1crypto import cms, x509 as ax509
    from cryptography.hazmat.primitives.asymmetric import padding
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    ac = ax509.Certificate.load(certificate)
    for blob in recipients:
        try:
            info = cms.ContentInfo.load(bytes(blob))
            enveloped = info["content"]
        except (ValueError, KeyError):
            continue
        for recipient in enveloped["recipient_infos"]:
            if recipient.name != "ktri":
                continue
            ktri = recipient.chosen
            rid = ktri["rid"]
            if rid.name == "issuer_and_serial_number":
                if rid.chosen["issuer"] != ac.issuer or rid.chosen["serial_number"].native != ac.serial_number:
                    continue
            algorithm = ktri["key_encryption_algorithm"]["algorithm"].native
            encrypted_key = ktri["encrypted_key"].native
            try:
                if algorithm == "rsaes_oaep":
                    envelope_key = private_key.decrypt(encrypted_key, padding.OAEP(mgf=padding.MGF1(hashes.SHA1()),
                                                                                   algorithm=hashes.SHA1(), label=None))
                else:
                    envelope_key = private_key.decrypt(encrypted_key, padding.PKCS1v15())
            except ValueError:
                continue
            content_info = enveloped["encrypted_content_info"]
            cipher = content_info["content_encryption_algorithm"]
            name = cipher["algorithm"].native
            iv = cipher["parameters"].native
            data = content_info["encrypted_content"].native
            if name.startswith("aes"):
                decryptor = Cipher(algorithms.AES(envelope_key), modes.CBC(iv)).decryptor()
            elif name == "tripledes_3key":
                from cryptography.hazmat.decrepit.ciphers.algorithms import TripleDES
                decryptor = Cipher(TripleDES(envelope_key), modes.CBC(iv)).decryptor()
            else:
                raise EngineError("UNSUPPORTED_OPERATION", "This document uses an unsupported certificate cipher.")
            plain = decryptor.update(data) + decryptor.finalize()
            pad = plain[-1]
            if 0 < pad <= 16:
                plain = plain[:-pad]
            require(len(plain) >= 20, "INVALID_PDF", "The certificate security data is damaged.")
            permissions = struct.unpack(">I", plain[20:24])[0] if len(plain) >= 24 else 0xFFFFFFFF
            return plain[:20], permissions
    raise EngineError("NOT_A_RECIPIENT", "This document isn’t encrypted for the selected digital ID.")


# ------------------------------------------------------------ object walk

def _is_signature_dict(obj):
    return isinstance(obj, pikepdf.Dictionary) and str(obj.get("/Type", "")) in ("/Sig", "/DocTimeStamp") \
        and "/ByteRange" in obj


def _transform_strings(value, fn, parent_is_sig=False, key=None):
    """Apply fn to every string inside a direct value; returns replacement."""
    if isinstance(value, pikepdf.String):
        if parent_is_sig and key == "/Contents":
            return value
        return pikepdf.String(fn(bytes(value)))
    if isinstance(value, pikepdf.Array) and not value.is_indirect:
        for index in range(len(value)):
            item = value[index]
            if isinstance(item, (pikepdf.String, pikepdf.Array, pikepdf.Dictionary)) and not item.is_indirect:
                value[index] = _transform_strings(item, fn)
        return value
    if isinstance(value, pikepdf.Dictionary) and not value.is_indirect:
        _transform_dict(value, fn)
        return value
    return value


def _transform_dict(dictionary, fn):
    is_sig = _is_signature_dict(dictionary)
    for key in list(dictionary.keys()):
        item = dictionary[key]
        if isinstance(item, (pikepdf.String, pikepdf.Array, pikepdf.Dictionary)) and not item.is_indirect:
            dictionary[key] = _transform_strings(item, fn, is_sig, key)


def _transform_document(pdf, string_fn, stream_fn, skip=(), encrypt_metadata=True):
    metadata = pdf.Root.get("/Metadata")
    metadata_id = metadata.objgen if isinstance(metadata, pikepdf.Stream) and metadata.is_indirect else None
    for obj in pdf.objects:
        if not obj.is_indirect or obj.objgen in skip:
            continue
        if isinstance(obj, pikepdf.Stream):
            kind = str(obj.stream_dict.get("/Type", ""))
            if kind in ("/XRef", "/ObjStm"):
                continue
            _transform_dict(obj.stream_dict, string_fn)
            if metadata_id is not None and obj.objgen == metadata_id and not encrypt_metadata:
                continue
            raw = obj.read_raw_bytes()
            filters = obj.stream_dict.get("/Filter")
            parms = obj.stream_dict.get("/DecodeParms")
            obj.write(stream_fn(raw), filter=filters, decode_parms=parms) if filters is not None \
                else obj.write(stream_fn(raw), filter=pikepdf.Array())
            if filters is None and "/Filter" in obj.stream_dict:
                del obj.stream_dict["/Filter"]
        elif isinstance(obj, pikepdf.Dictionary):
            _transform_dict(obj, string_fn)
        elif isinstance(obj, pikepdf.Array):
            for index in range(len(obj)):
                item = obj[index]
                if isinstance(item, (pikepdf.String, pikepdf.Array, pikepdf.Dictionary)) and not item.is_indirect:
                    obj[index] = _transform_strings(item, string_fn)
        elif isinstance(obj, pikepdf.String):
            # Indirect strings can't be replaced in place; rare in practice.
            pass


# ------------------------------------------------------------ write/read

def write_encrypted(pdf, destination, key, recipients, encrypt_metadata=True, v=5):
    """Encrypt `pdf` in place with `key` and write it with a PubSec dictionary."""
    require(v == 5, "UNSUPPORTED_OPERATION", "Only AES-256 certificate security can be written.")
    encrypt = pdf.make_indirect(pikepdf.Dictionary(
        Filter=Name("/Adobe.PubSec"), SubFilter=Name("/adbe.pkcs7.s5"), V=5, Length=256,
        EncryptMetadata=bool(encrypt_metadata),
        CF=pikepdf.Dictionary(DefaultCryptFilter=pikepdf.Dictionary(
            Type=Name.CryptFilter, CFM=Name.AESV3, Length=256, AuthEvent=Name.DocOpen,
            EncryptMetadata=bool(encrypt_metadata),
            Recipients=pikepdf.Array([pikepdf.String(blob) for blob in recipients]))),
        StmF=Name.DefaultCryptFilter, StrF=Name.DefaultCryptFilter))
    if "/ID" not in pdf.trailer:
        ident = os.urandom(16)
        pdf.trailer.ID = pikepdf.Array([pikepdf.String(ident), pikepdf.String(ident)])
    _transform_document(pdf, lambda b: _aes_cbc(key, b), lambda b: _aes_cbc(key, b),
                        skip={encrypt.objgen}, encrypt_metadata=encrypt_metadata)
    pdf.trailer[Name(PLACEHOLDER.decode())] = encrypt
    pdf.save(destination, object_stream_mode=pikepdf.ObjectStreamMode.disable, compress_streams=False,
             stream_decode_level=pikepdf.StreamDecodeLevel.none, encryption=False, fix_metadata_version=False)
    with open(destination, "rb") as stream:
        data = bytearray(stream.read())
    index = data.rfind(b"trailer")
    require(index >= 0, "ENGINE_FAILED", "Unexpected cross-reference layout.")
    placeholder = data.find(PLACEHOLDER, index)
    require(placeholder >= 0, "ENGINE_FAILED", "Could not attach the security dictionary.")
    data[placeholder:placeholder + len(PLACEHOLDER)] = b"/Encrypt"
    with open(destination, "wb") as stream:
        stream.write(data)


def is_pubsec(path):
    with open(path, "rb") as stream:
        data = stream.read()
    return b"/Adobe.PubSec" in data or b"/Adobe#2EPubSec" in data


def _unlock_bytes(data):
    """Rename the trailer /Encrypt key so QPDF reads the file as unencrypted."""
    patched = bytearray(data)
    for match in list(ENCRYPT_KEY.finditer(data)):
        start = match.start()
        # Only trailer / cross-reference stream dictionaries carry /Encrypt.
        window = data[max(0, start - 2048):start]
        if b"trailer" in window[-1024:] or b"/XRef" in data[start:start + 1024] or b"/XRef" in window[-1024:]:
            patched[start:start + len(PLACEHOLDER)] = PLACEHOLDER
    return bytes(patched)


def open_encrypted(path, workdir):
    """(pdf, encrypt dict, recipients, version, cfm, encrypt_metadata) with /Encrypt renamed."""
    with open(path, "rb") as stream:
        data = stream.read()
    require(b"/ObjStm" not in data, "UNSUPPORTED_OPERATION",
            "This certificate-secured PDF uses compressed object streams, which zPDF can’t decrypt yet.")
    unlocked = workdir / "pubsec-unlocked.pdf"
    unlocked.write_bytes(_unlock_bytes(data))
    pdf = pikepdf.open(unlocked)
    encrypt = pdf.trailer.get(PLACEHOLDER.decode())
    require(isinstance(encrypt, pikepdf.Dictionary) and str(encrypt.get("/Filter", "")) == "/Adobe.PubSec",
            "UNSUPPORTED_OPERATION", "This document isn’t protected with certificate security.")
    version = int(encrypt.get("/V", 0))
    encrypt_metadata = bool(encrypt.get("/EncryptMetadata", True))
    cfm = "/AESV3" if version == 5 else None
    recipients = []
    if str(encrypt.get("/SubFilter", "")) == "/adbe.pkcs7.s5" and "/CF" in encrypt:
        name = str(encrypt.get("/StmF", "/DefaultCryptFilter"))
        cf = encrypt.CF.get(name)
        require(cf is not None, "INVALID_PDF", "The certificate security data is incomplete.")
        cfm = str(cf.get("/CFM", cfm or ""))
        encrypt_metadata = bool(cf.get("/EncryptMetadata", encrypt_metadata))
        items = cf.get("/Recipients")
        recipients = [bytes(items)] if isinstance(items, pikepdf.String) else [bytes(r) for r in items or []]
    else:
        recipients = [bytes(r) for r in encrypt.get("/Recipients", [])]
    require(cfm in ("/AESV3", "/AESV2"), "UNSUPPORTED_OPERATION",
            "This certificate-secured document uses an unsupported cipher (only AES is supported).")
    return pdf, encrypt, recipients, version, cfm, encrypt_metadata


def decrypt_file(source, destination, workdir, private_key=None, certificate=None, key=None):
    """Write a decrypted copy; returns (file key, permissions, version info)."""
    pdf, encrypt, recipients, version, cfm, encrypt_metadata = open_encrypted(source, workdir)
    with pdf:
        permissions = 0xFFFFFFFF
        if key is None:
            seed, permissions = open_seed(recipients, private_key, certificate)
            key = file_key(seed, recipients, encrypt_metadata, 32 if cfm == "/AESV3" else 16, sha256=cfm == "/AESV3")
        if cfm == "/AESV3":
            string_fn = stream_fn = lambda b: _aes_cbc(key, b, decrypt=True)
            _transform_document(pdf, string_fn, stream_fn, skip={encrypt.objgen} if encrypt.is_indirect else (),
                                encrypt_metadata=encrypt_metadata)
        else:
            _decrypt_aesv2(pdf, key, encrypt, encrypt_metadata)
        del pdf.trailer[PLACEHOLDER.decode()]
        pdf.save(destination)
    return key, permissions


def _decrypt_aesv2(pdf, key, encrypt, encrypt_metadata):
    """AESV2: per-object keys MD5(key || objnum[3] || gen[2] || 'sAlT')."""
    metadata = pdf.Root.get("/Metadata")
    metadata_id = metadata.objgen if isinstance(metadata, pikepdf.Stream) else None
    for obj in pdf.objects:
        if not obj.is_indirect or (encrypt.is_indirect and obj.objgen == encrypt.objgen):
            continue
        number, generation = obj.objgen
        object_key = hashlib.md5(key + number.to_bytes(3, "little") + generation.to_bytes(2, "little") + b"sAlT").digest()
        fn = lambda b, k=object_key: _aes_cbc(k, b, decrypt=True)
        if isinstance(obj, pikepdf.Stream):
            if str(obj.stream_dict.get("/Type", "")) in ("/XRef", "/ObjStm"):
                continue
            _transform_dict(obj.stream_dict, fn)
            if obj.objgen == metadata_id and not encrypt_metadata:
                continue
            filters = obj.stream_dict.get("/Filter")
            parms = obj.stream_dict.get("/DecodeParms")
            raw = fn(obj.read_raw_bytes())
            obj.write(raw, filter=filters, decode_parms=parms) if filters is not None else obj.write(raw, filter=pikepdf.Array())
        elif isinstance(obj, pikepdf.Dictionary):
            _transform_dict(obj, fn)
