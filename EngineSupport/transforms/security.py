"""Document security: password encryption (AES-256 R6), permissions,
encrypted editing and removal.

The editing revision of an encrypted PDF is kept decrypted in the app's
private temporary storage so every other feature can work on it. The
security the user wants is recorded in the catalog as a private marker
(`/ZPDFSecurity`, never containing secrets) and applied by `apply_security`
when the document is saved, published or exported:

* Preserve – the original file's encryption (same passwords, same file key)
  is kept by transplanting the edited content into the original encrypted
  document and writing it with QPDF's preserve-encryption mode. This works
  even when only the open password is known.
* Password – new AES-256 (or AES-128) encryption with the given passwords
  and permissions.
* None – saved without encryption (requires the permissions password when
  the original was encrypted).
"""
import os

import pikepdf
from pikepdf import Name

from engine.errors import EngineError, require
from transforms import op, query

MARKER = Name("/ZPDFSecurity")
PERMISSION_KEYS = ("print_lowres", "print_highres", "modify_other", "modify_annotation", "modify_form",
                   "modify_assembly", "extract", "accessibility")


def permissions_dict(allow):
    return {key: bool(getattr(allow, key)) for key in PERMISSION_KEYS}


def describe(pdf):
    if not pdf.is_encrypted:
        return {"encrypted": False}
    info = pdf.encryption
    method = str(info.stream_method).split(".")[-1]
    return {"encrypted": True, "revision": int(info.R), "version": int(info.V), "bits": int(info.bits),
            "method": {"aesv3": "AES-256", "aesv2": "AES-128", "rc4": "RC4"}.get(method, method),
            "permissions": permissions_dict(pdf.allow),
            "owner_password_matched": bool(pdf.owner_password_matched),
            "user_password_matched": bool(pdf.user_password_matched)}


def marker(pdf):
    value = pdf.Root.get(MARKER)
    if not isinstance(value, pikepdf.Dictionary):
        return None
    out = {"mode": str(value.get("/Mode", "/None"))[1:], "token": str(value.get("/Token", ""))}
    summary = value.get("/Summary")
    if isinstance(summary, pikepdf.Dictionary):
        out["summary"] = {str(k)[1:]: (bool(v) if isinstance(v, bool) else str(v)) for k, v in summary.items()}
    return out


def _set_marker(pdf, mode, token, summary=None):
    value = pikepdf.Dictionary(Mode=Name("/" + mode), Token=pikepdf.String(token or ""))
    if summary:
        value.Summary = pikepdf.Dictionary({"/" + k: (v if isinstance(v, bool) else pikepdf.String(str(v)))
                                            for k, v in summary.items()})
    pdf.Root[MARKER] = value


@query("security_info")
def security_info(ctx):
    info = describe(ctx.pdf)
    info["marker"] = marker(ctx.pdf)
    from transforms import incremental
    info["signed"] = incremental.is_signed(ctx.pdf)
    return info


@query("edit_policy")
def edit_policy(ctx):
    """The v0 write policy (XFA and encrypted documents are read-only), for
    files the original facade can't open but the transform layer can."""
    pdf = ctx.pdf
    acro = pdf.Root.get("/AcroForm")
    xfa = isinstance(acro, pikepdf.Dictionary) and "/XFA" in acro
    block = "XFA_EDIT_BLOCKED" if xfa else ("UNSUPPORTED_ENCRYPTED_WRITE" if pdf.is_encrypted else None)
    return {"write_block": block, "encrypted": pdf.is_encrypted}


@op("decrypt_for_editing", rewrite=True)
def decrypt_for_editing(ctx, token=""):
    """Private decrypted working copy of an encrypted PDF (opened with its password)."""
    pdf = ctx.pdf
    require(pdf.is_encrypted, "NOT_ENCRYPTED", "This document is not encrypted.")
    info = describe(pdf)
    _set_marker(pdf, "Preserve", token, {"method": info["method"], "owner": info["owner_password_matched"]})
    ctx.save_options["encryption"] = False
    ctx.save_options["validate_password"] = ""
    return info


@op("set_security")
def set_security(ctx, mode, token="", summary=None):
    """Record the security to apply on Save (no secrets are stored)."""
    require(mode in ("Preserve", "Password", "None", "Certificate"), "INVALID_ARGUMENT", "Unknown security mode.")
    _set_marker(ctx.pdf, mode, token, summary)
    return {"mode": mode}


def _permissions(spec):
    spec = spec or {}
    printing = spec.get("print", "high")
    changes = spec.get("changes", "any")
    return pikepdf.Permissions(
        accessibility=bool(spec.get("accessibility", True)),
        extract=bool(spec.get("copy", True)),
        modify_annotation=changes in ("comments", "any"),
        modify_assembly=changes in ("assembly", "any"),
        modify_form=changes in ("fill", "comments", "any"),
        modify_other=changes == "any",
        print_lowres=printing in ("low", "high"),
        print_highres=printing == "high")


def transplant(original, password, edited, destination):
    """Write `edited`'s content inside `original`, preserving its encryption."""
    try:
        target = pikepdf.open(original, password=password or "")
    except pikepdf.PasswordError as exc:
        raise EngineError("INVALID_PASSWORD", "The password for the original document is no longer valid.") from exc
    with target:
        count = len(target.pages)
        import warnings
        with warnings.catch_warnings():
            # The AcroForm and every other catalog entry are transplanted below
            # through the same foreign-object map, so widgets stay linked.
            warnings.simplefilter("ignore")
            target.pages.extend(edited.pages)
        for _ in range(count):
            del target.pages[0]
        for key in list(target.Root.keys()):
            if key not in ("/Pages", "/Type"):
                del target.Root[key]
        for key, value in edited.Root.items():
            if key in ("/Pages", "/Type") or key == str(MARKER):
                continue
            target.Root[key] = _foreign(target, edited, value)
        if "/Info" in edited.trailer:
            target.trailer.Info = _foreign(target, edited, edited.trailer.Info)
        elif "/Info" in target.trailer:
            del target.trailer["/Info"]
        target.save(destination, encryption=True)


def _foreign(target, source, value):
    if isinstance(value, (pikepdf.Dictionary, pikepdf.Array, pikepdf.Stream)):
        if not value.is_indirect:
            value = source.make_indirect(value)
        return target.copy_foreign(value)
    return pikepdf.Object.parse(value.unparse())


@op("apply_security", rewrite=True)
def apply_security(ctx, user_password=None, owner_password=None, permissions=None, method="aes256",
                   encrypt_metadata=True, original=None, original_password=None, recipients=None,
                   certificate_key=None):
    """Apply the recorded security while writing the final file."""
    pdf = ctx.pdf
    recorded = marker(pdf)
    if MARKER in pdf.Root:
        del pdf.Root[MARKER]
    mode = recorded["mode"] if recorded else "None"
    if mode == "None":
        ctx.save_options["encryption"] = False
        return {"mode": "None"}
    if mode == "Preserve":
        require(original, "INVALID_ARGUMENT", "The original encrypted document is required.")

        def writer(ctx_, candidate):
            transplant(original, original_password, ctx_.pdf, candidate)

        ctx.save_options["writer"] = writer
        ctx.save_options["validate_password"] = original_password or ""
        return {"mode": "Preserve"}
    if mode == "Password":
        require(user_password or owner_password, "INVALID_ARGUMENT", "Enter a password.")
        owner = owner_password or user_password
        require(not (user_password and owner_password and user_password == owner_password), "INVALID_ARGUMENT",
                "The open password and the permissions password must be different.")
        if method == "aes128":
            encryption = pikepdf.Encryption(user=user_password or "", owner=owner, R=4, aes=True,
                                            allow=_permissions(permissions), metadata=bool(encrypt_metadata))
        else:
            encryption = pikepdf.Encryption(user=user_password or "", owner=owner, R=6,
                                            allow=_permissions(permissions), metadata=bool(encrypt_metadata))
        ctx.save_options["encryption"] = encryption
        ctx.save_options["validate_password"] = user_password or owner
        return {"mode": "Password", "method": "AES-128" if method == "aes128" else "AES-256"}
    if mode == "Certificate":
        return _apply_certificate_security(ctx, recipients, permissions, encrypt_metadata, certificate_key, original)
    raise EngineError("UNSUPPORTED_OPERATION", "Unknown security mode.")


def _apply_certificate_security(ctx, recipients, permissions, encrypt_metadata, certificate_key, original):
    """New recipients (fresh seed) or, with `certificate_key` + `original`,
    the original document's recipients and file key unchanged."""
    import base64
    from transforms import pubsec
    if certificate_key:
        require(original, "INVALID_ARGUMENT", "The original encrypted document is required.")
        key = base64.b64decode(certificate_key)
        source, _, blobs, _, cfm, meta = pubsec.open_encrypted(original, ctx.workdir)
        source.close()
        require(cfm == "/AESV3", "UNSUPPORTED_OPERATION",
                "This document's certificate security uses AES-128; choose new recipients to save it with AES-256.")
        encrypt_metadata = meta
    else:
        require(recipients, "INVALID_ARGUMENT", "Choose at least one recipient certificate.")
        seed = os.urandom(20)
        blobs = [pubsec.build_recipients([base64.b64decode(c) for c in recipients], seed,
                                         pubsec.permission_value(permissions))]
        key = pubsec.file_key(seed, blobs, bool(encrypt_metadata))

    def writer(ctx_, candidate):
        pubsec.write_encrypted(ctx_.pdf, candidate, key, blobs, bool(encrypt_metadata))

    def validator(candidate, workdir):
        readable = workdir / "certificate-check.pdf"
        pubsec.decrypt_file(candidate, readable, workdir, key=key)
        return readable

    ctx.save_options["writer"] = writer
    ctx.save_options["validator"] = validator
    return {"mode": "Certificate", "file_key": base64.b64encode(key).decode(), "recipients": len(recipients or [])}


def decrypt_certificate_file(source, destination, p12_b64=None, password="", key_b64=None, token=""):
    """crypto command: private decrypted copy of a certificate-secured PDF."""
    import base64
    import tempfile
    from pathlib import Path
    from transforms import pubsec
    from transforms import cms as C
    destination = Path(destination)
    require(not destination.exists(), "DESTINATION_EXISTS", "Output already exists.")
    with tempfile.TemporaryDirectory(prefix="zpdf-pubsec-", dir=destination.parent) as workdir:
        work = Path(workdir)
        if key_b64:
            key, permissions = pubsec.decrypt_file(source, work / "plain.pdf", work, key=base64.b64decode(key_b64))
        else:
            private_key, cert, _ = C.load_identity(p12_b64, password)
            from cryptography.hazmat.primitives import serialization
            key, permissions = pubsec.decrypt_file(source, work / "plain.pdf", work, private_key=private_key,
                                                   certificate=cert.public_bytes(serialization.Encoding.DER))
        with pikepdf.open(work / "plain.pdf") as plain:
            pages = len(plain.pages)
            _set_marker(plain, "Certificate", token, {"method": "AES-256 certificate"})
            plain.save(work / "marked.pdf")
        os.replace(work / "marked.pdf", destination)
    return {"file_key": base64.b64encode(key).decode(), "permissions": permissions, "page_count": pages,
            "can_modify": bool(permissions & (1 << 3)), "can_copy": bool(permissions & (1 << 4)),
            "can_print": bool(permissions & (1 << 2))}


@query("check_password")
def check_password(ctx):
    """Opened with ctx.password: reports which password matched."""
    return describe(ctx.pdf)
