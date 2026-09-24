"""Digital signatures: PAdES signing, certification (DocMDP), LTV and validation.

Signing is always an incremental update appended to the exact input bytes
(see incremental.py), so earlier signatures keep covering their revisions.
The signature value is a CMS SignedData (ETSI.CAdES.detached) over the
/ByteRange of the new revision.
"""
import base64
import binascii
import datetime as dt
import hashlib
import re

import pikepdf
from pikepdf import Name

from engine.errors import EngineError, require
from transforms import op, query
from transforms import incremental

try:  # cryptography/asn1crypto are pinned transform wheels; fail per-op, not globally
    from transforms import cms as C
except ImportError:  # pragma: no cover
    C = None

PLACEHOLDER_RANGE = b"/ByteRange [0 0000000000 0000000000 0000000000]"
SUBFILTERS = {"pades": "/ETSI.CAdES.detached", "pkcs7": "/adbe.pkcs7.detached"}


# ---------------------------------------------------------------- helpers

def _text(value):
    return str(value) if value is not None else ""


def _walk_fields(fields, parent_name=""):
    for field in fields or []:
        if not isinstance(field, pikepdf.Dictionary):
            continue
        part = _text(field.get("/T"))
        name = f"{parent_name}.{part}" if parent_name and part else (part or parent_name)
        kids = field.get("/Kids")
        terminal = kids is None or not any("/T" in k for k in kids if isinstance(k, pikepdf.Dictionary))
        if terminal:
            yield name, field
        if kids is not None:
            yield from _walk_fields([k for k in kids if isinstance(k, pikepdf.Dictionary) and "/T" in k], name)


def _inherited(field, key):
    node, depth = field, 0
    while node is not None and depth < 32:
        if key in node:
            return node[key]
        node = node.get("/Parent")
        depth += 1
    return None


def signature_fields(pdf):
    acro = pdf.Root.get("/AcroForm")
    if acro is None:
        return []
    return [(name, field) for name, field in _walk_fields(acro.get("/Fields"))
            if str(_inherited(field, "/FT") or "") == "/Sig"]


def _widgets(field):
    kids = field.get("/Kids")
    if kids is None:
        return [field]
    return [k for k in kids if isinstance(k, pikepdf.Dictionary)]


def _page_index(pdf, widget):
    for index, page in enumerate(pdf.pages):
        for annot in page.obj.get("/Annots", []):
            if annot.is_indirect and widget.is_indirect and annot.objgen == widget.objgen:
                return index
    return None


def pdf_date(moment=None):
    moment = moment or dt.datetime.now().astimezone()
    offset = moment.utcoffset() or dt.timedelta(0)
    minutes = int(offset.total_seconds() // 60)
    sign = "+" if minutes >= 0 else "-"
    minutes = abs(minutes)
    return moment.strftime("D:%Y%m%d%H%M%S") + f"{sign}{minutes // 60:02d}'{minutes % 60:02d}'"


def parse_pdf_date(value):
    match = re.match(r"D:(\d{4})(\d{2})?(\d{2})?(\d{2})?(\d{2})?(\d{2})?([Zz+\-])?(\d{2})?'?(\d{2})?", value or "")
    if not match:
        return None
    parts = [int(p) if p else d for p, d in zip(match.groups()[:6], (0, 1, 1, 0, 0, 0))]
    tz = dt.timezone.utc
    if match.group(7) in ("+", "-") and match.group(8):
        delta = dt.timedelta(hours=int(match.group(8)), minutes=int(match.group(9) or 0))
        tz = dt.timezone(delta if match.group(7) == "+" else -delta)
    try:
        return dt.datetime(*parts, tzinfo=tz).isoformat()
    except ValueError:
        return None


def _docmdp_level(pdf):
    perms = pdf.Root.get("/Perms")
    if perms is None or "/DocMDP" not in perms:
        return None
    for ref in perms.DocMDP.get("/Reference", []):
        if str(ref.get("/TransformMethod", "")) == "/DocMDP":
            return int(ref.get("/TransformParams", {}).get("/P", 2))
    return 2


# ------------------------------------------------------------- appearance

def _appearance(ctx, width, height, info, image_path=None, style=None):
    """Acrobat-style visible signature: image or large name left, details right."""
    from transforms.fonts import EmbeddedFont
    from transforms.content import fmt, image_xobject
    style = style or {}
    pdf = ctx.pdf
    font = EmbeddedFont(pdf, style.get("font"))
    resources = pikepdf.Dictionary(Font=pikepdf.Dictionary(F1=font.ref))
    ops = []
    lines = []
    if info.get("show_label", True):
        lines.append("Digitally signed by " + info.get("name", ""))
    else:
        lines.append(info.get("name", ""))
    if info.get("show_date", True) and info.get("date_text"):
        lines.append("Date: " + info["date_text"])
    if info.get("reason"):
        lines.append("Reason: " + info["reason"])
    if info.get("location"):
        lines.append("Location: " + info["location"])
    left_width = width * 0.45 if (image_path or info.get("show_name_left", True)) else 0
    pad = min(4.0, height * 0.08)
    if image_path:
        xobject, pw, ph = image_xobject(pdf, image_path)
        resources.XObject = pikepdf.Dictionary(Im1=xobject)
        box_w, box_h = left_width - 2 * pad, height - 2 * pad
        scale = min(box_w / pw, box_h / ph)
        dw, dh = pw * scale, ph * scale
        x = pad + (box_w - dw) / 2
        y = pad + (box_h - dh) / 2
        ops.append(f"q {fmt(dw, 0, 0, dh, x, y)} cm /Im1 Do Q")
    elif left_width:
        name = info.get("name", "")
        size = min((left_width - 2 * pad) / max(font.width(name, 1), 0.01), height * 0.45)
        size = max(size, 4)
        y = (height - size) / 2 - font.descent * size * 0.5
        ops.append(f"BT 0 0 0 rg /F1 {fmt(size)} Tf {fmt(pad, y)} Td {font.encode(name)} Tj ET")
    text_x = left_width + pad
    avail = width - text_x - pad
    count = max(len(lines), 1)
    size = min((height - 2 * pad) / (count * 1.25), 11)
    widest = max(font.width(line, 1) for line in lines) if lines else 1
    if widest * size > avail:
        size = max(avail / max(widest, 0.01), 3)
    y = height - pad - size
    ops.append("BT 0 0 0 rg")
    for line in lines:
        ops.append(f"/F1 {fmt(size)} Tf 1 0 0 1 {fmt(text_x, y)} Tm {font.encode(line)} Tj")
        y -= size * 1.25
    ops.append("ET")
    font.finish()
    stream = pikepdf.Stream(pdf, "\n".join(ops).encode())
    stream.Type, stream.Subtype = Name.XObject, Name.Form
    stream.BBox = pikepdf.Array([0, 0, width, height])
    stream.Resources = resources
    return pdf.make_indirect(stream)


def _write_image(ctx, image_b64):
    if not image_b64:
        return None
    try:
        data = base64.b64decode(image_b64)
    except (ValueError, TypeError) as exc:
        raise EngineError("INVALID_ARGUMENT", "The signature image is damaged.") from exc
    require(len(data) <= 8 * 1024 * 1024, "INVALID_ARGUMENT", "The signature image is too large.")
    path = ctx.scratch(".png")
    path.write_bytes(data)
    return path


# ------------------------------------------------------------------- sign

def _prepare_field(ctx, field_name, page, rect):
    pdf = ctx.pdf
    acro = pdf.Root.get("/AcroForm")
    if acro is None:
        acro = pdf.make_indirect(pikepdf.Dictionary(Fields=pikepdf.Array()))
        pdf.Root.AcroForm = acro
    if "/Fields" not in acro:
        acro.Fields = pikepdf.Array()
    acro.SigFlags = 3
    existing = dict(signature_fields(pdf))
    if field_name and field_name in existing:
        field = existing[field_name]
        require("/V" not in field, "ALREADY_SIGNED", "This signature field is already signed.")
        widget = _widgets(field)[0]
        index = _page_index(pdf, widget)
        require(index is not None, "INVALID_ARGUMENT", "The signature field is not placed on a page.")
        r = [float(v) for v in widget.Rect]
        return field, widget, index, [min(r[0], r[2]), min(r[1], r[3]), max(r[0], r[2]), max(r[1], r[3])]
    names = {name for name, _ in _walk_fields(acro.Fields)}
    if not field_name:
        number = 1
        while f"Signature{number}" in names:
            number += 1
        field_name = f"Signature{number}"
    require(field_name not in names, "INVALID_ARGUMENT", "A field with that name already exists.")
    require(isinstance(page, int) and 0 <= page < len(pdf.pages), "INVALID_ARGUMENT", "Choose a page for the signature.")
    visible = rect is not None
    if visible:
        require(isinstance(rect, list) and len(rect) == 4 and rect[2] - rect[0] >= 8 and rect[3] - rect[1] >= 8,
                "INVALID_ARGUMENT", "Draw a larger signature box.")
    box = [float(v) for v in rect] if visible else [0.0, 0.0, 0.0, 0.0]
    page_obj = pdf.pages[page].obj
    widget = pdf.make_indirect(pikepdf.Dictionary(
        Type=Name.Annot, Subtype=Name.Widget, FT=Name.Sig, T=pikepdf.String(field_name),
        F=132 if visible else 134, Rect=pikepdf.Array(box), P=page_obj))
    if "/Annots" not in page_obj:
        page_obj.Annots = pikepdf.Array()
    page_obj.Annots.append(widget)
    acro.Fields.append(widget)
    return widget, widget, page, box


def _signature_dictionary(pdf, subfilter, info, certify):
    sig = pikepdf.Dictionary(Type=Name.Sig, Filter=Name("/Adobe.PPKLite"), SubFilter=Name(subfilter),
                             M=pikepdf.String(info["m"]))
    for key, value in (("/Name", info.get("name")), ("/Reason", info.get("reason")),
                       ("/Location", info.get("location")), ("/ContactInfo", info.get("contact"))):
        if value:
            sig[key] = pikepdf.String(value)
    sig.Prop_Build = pikepdf.Dictionary(App=pikepdf.Dictionary(Name=Name("/zPDF")),
                                        Filter=pikepdf.Dictionary(Name=Name("/Adobe.PPKLite")))
    if certify:
        sig.Reference = pikepdf.Array([pikepdf.Dictionary(
            Type=Name.SigRef, TransformMethod=Name.DocMDP, DigestMethod=Name.SHA256,
            TransformParams=pikepdf.Dictionary(Type=Name.TransformParams, P=int(certify), V=Name("/1.2")))])
    return sig


@op("sign", incremental=True)
def sign(ctx, identity, field=None, page=None, rect=None, name=None, reason="", location="", contact="",
         appearance=None, image=None, certify=None, timestamp_url=None, subfilter="pades",
         reserve=None, date_text=None, _fetch=None):
    """Sign the document. Must be the last operation of its list."""
    pdf = ctx.pdf
    require(C is not None, "DEPENDENCY_UNAVAILABLE", "Digital signatures are unavailable in this build.")
    require(ctx.tracker is not None, "UNSUPPORTED_OPERATION", "Signing needs an unencrypted document.")
    require(isinstance(identity, dict) and identity.get("p12"), "INVALID_ARGUMENT", "Choose a digital ID.")
    require(subfilter in SUBFILTERS, "INVALID_ARGUMENT", "Unsupported signature format.")
    require(certify in (None, 1, 2, 3), "INVALID_ARGUMENT", "Choose a certification permission level.")
    level = _docmdp_level(pdf)
    require(level != 1, "CERTIFIED_NO_CHANGES", "This document is certified with no changes allowed; it can't be signed again.")
    if certify:
        require(not incremental.is_signed(pdf), "ALREADY_SIGNED",
                "Only an unsigned document can be certified. Certify before anyone signs.")
    key, cert, chain = C.load_identity(identity["p12"], identity.get("password", ""))
    signer = C.describe(cert)
    now = dt.datetime.now().astimezone()
    info = {"name": name or signer["name"], "reason": reason or "", "location": location or "",
            "contact": contact or signer.get("email", ""), "m": pdf_date(now),
            "date_text": date_text or now.strftime("%Y.%m.%d %H:%M:%S %z")}
    field_obj, widget, page_index, box = _prepare_field(ctx, field, page, rect)
    width, height = box[2] - box[0], box[3] - box[1]
    options = dict(appearance or {})
    if width > 0 and height > 0:
        info.update({k: options.get(k, d) for k, d in (("show_label", True), ("show_date", True),
                                                        ("show_name_left", True))})
        if not options.get("show_reason", True):
            info_display = dict(info, reason="")
        else:
            info_display = info
        if not options.get("show_location", True):
            info_display = dict(info_display, location="")
        ap = _appearance(ctx, width, height, info_display, _write_image(ctx, image), options)
        widget.AP = pikepdf.Dictionary(N=ap)
    else:
        blank = pikepdf.Stream(pdf, b"")
        blank.Type, blank.Subtype, blank.BBox = Name.XObject, Name.Form, pikepdf.Array([0, 0, 0, 0])
        widget.AP = pikepdf.Dictionary(N=pdf.make_indirect(blank))
    sig = pdf.make_indirect(_signature_dictionary(pdf, SUBFILTERS[subfilter], info, certify))
    field_obj.V = sig
    widget.F = int(widget.get("/F", 4)) | 128  # locked once signed
    if certify:
        pdf.Root.Perms = pikepdf.Dictionary(DocMDP=sig)
    chain_size = sum(len(c.public_bytes(C.serialization.Encoding.DER)) for c in [cert] + chain)
    size = reserve or (chain_size + 6000 + (12000 if timestamp_url else 0))
    size = int(min(max(size, 8192), 200_000))

    def finish(ctx_, candidate):
        body = _signature_dictionary(pdf, SUBFILTERS[subfilter], info, certify).unparse()
        require(body.endswith(b">>"), "ENGINE_FAILED", "Unexpected signature dictionary encoding.")
        serialized = (f"{sig.objgen[0]} {sig.objgen[1]} obj\n".encode() + body[:-2] + b" " + PLACEHOLDER_RANGE
                      + b" /Contents <" + b"0" * (size * 2) + b"> >>\nendobj\n")
        written = incremental.write(pdf, ctx_.tracker, candidate, overrides={sig.objgen: serialized})
        data = bytearray(written["bytes"])
        start = written["offsets"][sig.objgen]
        contents = data.index(b"/Contents <", start) + len(b"/Contents ")
        end = contents + 2 + size * 2
        require(data[end - 1:end] == b">", "ENGINE_FAILED", "Signature placeholder is misplaced.")
        ranges = [0, contents, end, len(data) - end]
        text = ("/ByteRange [" + " ".join(str(v) for v in ranges) + "]").encode()
        require(len(text) <= len(PLACEHOLDER_RANGE), "ENGINE_FAILED", "The document is too large to sign.")
        placeholder = data.index(PLACEHOLDER_RANGE, start)
        data[placeholder:placeholder + len(PLACEHOLDER_RANGE)] = text + b" " * (len(PLACEHOLDER_RANGE) - len(text))
        digest = hashlib.sha256(bytes(data[:contents]) + bytes(data[end:])).digest()
        signing_time = now.astimezone(dt.timezone.utc) if subfilter == "pkcs7" else None
        blob = C.build_signed_data(digest, key, cert, chain, timestamp_url=timestamp_url,
                                   signing_time=signing_time, fetch=_fetch)
        require(len(blob) <= size, "SIGNATURE_TOO_LARGE", "The signature is larger than its reserved space.")
        data[contents + 1:end - 1] = binascii.hexlify(blob).upper().ljust(size * 2, b"0")
        with open(candidate, "wb") as stream:
            stream.write(data)

    ctx.save_options["writer"] = finish
    return {"field": _text(field_obj.get("/T")), "page": page_index, "signer": signer["name"],
            "certified": certify, "timestamped": bool(timestamp_url)}


# ------------------------------------------------------------------ LTV

@op("add_ltv", incremental=True)
def add_ltv(ctx, extra_certificates=None, allow_network=False, _fetch=None):
    """Embed a Document Security Store with every chain/timestamp certificate
    and any revocation data that can be obtained."""
    pdf = ctx.pdf
    require(ctx.tracker is not None and incremental.is_signed(pdf), "NOT_SIGNED", "Sign the document first.")
    data = ctx.tracker.base
    certs, vri = [], {}
    for _, field in signature_fields(pdf):
        value = field.get("/V")
        if not isinstance(value, pikepdf.Dictionary) or "/Contents" not in value:
            continue
        blob = bytes(value.Contents)
        report = C.verify_signed_data(blob, lambda name: b"")
        chain = [base64.b64decode(c) for c in report.get("certificates", [])]
        chain += [base64.b64decode(c) for c in report.get("timestamp", {}).get("certificates", [])]
        certs.extend(chain)
        vri[hashlib.sha1(blob).hexdigest().upper()] = chain
    certs += [base64.b64decode(c) for c in extra_certificates or []]
    unique = list(dict.fromkeys(certs))
    crls, ocsps, notes = C.revocation_material(unique, fetch=_fetch, allow_network=allow_network)
    dss = pdf.Root.get("/DSS")
    if dss is None:
        dss = pdf.make_indirect(pikepdf.Dictionary())
        pdf.Root.DSS = dss

    def streams(key, items):
        array = dss.get(key)
        if array is None:
            array = pikepdf.Array()
            dss[key] = array
        existing = {hashlib.sha256(s.read_bytes()).digest(): s for s in array}
        refs = []
        for item in items:
            h = hashlib.sha256(item).digest()
            if h not in existing:
                existing[h] = pdf.make_indirect(pikepdf.Stream(pdf, item))
                array.append(existing[h])
            refs.append(existing[h])
        return refs

    cert_refs = dict(zip(unique, streams("/Certs", unique)))
    ocsp_refs = streams("/OCSPs", ocsps) if ocsps else []
    crl_refs = streams("/CRLs", crls) if crls else []
    vri_dict = dss.get("/VRI")
    if vri_dict is None:
        vri_dict = pikepdf.Dictionary()
        dss.VRI = vri_dict
    for key, chain in vri.items():
        entry = pikepdf.Dictionary(Cert=pikepdf.Array([cert_refs[c] for c in dict.fromkeys(chain) if c in cert_refs]))
        if ocsp_refs:
            entry.OCSP = pikepdf.Array(ocsp_refs)
        if crl_refs:
            entry.CRL = pikepdf.Array(crl_refs)
        vri_dict[Name("/" + key)] = entry
    return {"certificates": len(unique), "ocsps": len(ocsps), "crls": len(crls), "notes": notes}


# ------------------------------------------------------------- validation

def _revision_ends(data):
    ends = []
    for match in re.finditer(rb"%%EOF[ \t]*(\r\n|\r|\n)?", data):
        ends.append(match.end())
    return ends


def _page_digest(pdf):
    out = []
    for page in pdf.pages:
        contents = page.obj.get("/Contents")
        h = hashlib.sha256()
        if isinstance(contents, pikepdf.Array):
            for part in contents:
                h.update(part.read_bytes())
        elif isinstance(contents, pikepdf.Stream):
            h.update(contents.read_bytes())
        annots = []
        for annot in page.obj.get("/Annots", []):
            subtype = str(annot.get("/Subtype", ""))
            if subtype == "/Widget":
                continue
            annots.append((subtype, _text(annot.get("/Contents")), tuple(round(float(v), 1) for v in annot.get("/Rect", []))))
        out.append((h.hexdigest(), sorted(annots), [round(float(v), 1) for v in page.mediabox], int(page.obj.get("/Rotate", 0))))
    return out


def _field_values(pdf):
    values = {}
    acro = pdf.Root.get("/AcroForm")
    if acro is None:
        return values
    for name, field in _walk_fields(acro.get("/Fields")):
        ft = str(_inherited(field, "/FT") or "")
        value = _inherited(field, "/V")
        if ft == "/Sig":
            values[name] = ("sig", isinstance(value, pikepdf.Dictionary))
        else:
            values[name] = (ft, value.unparse() if value is not None else b"")
    return values


def _changes_between(signed_bytes, current_path):
    import io
    kinds = set()
    try:
        before = pikepdf.open(io.BytesIO(signed_bytes))
    except pikepdf.PdfError:
        return ["unreadable"]
    with before, pikepdf.open(current_path) as after:
        a, b = _page_digest(before), _page_digest(after)
        if len(a) != len(b):
            kinds.add("pages")
        else:
            for x, y in zip(a, b):
                if x[0] != y[0] or x[2] != y[2] or x[3] != y[3]:
                    kinds.add("content")
                if x[1] != y[1]:
                    kinds.add("annotations")
        fa, fb = _field_values(before), _field_values(after)
        for name in set(fa) | set(fb):
            va, vb = fa.get(name), fb.get(name)
            if va == vb:
                continue
            if (va is None or va[0] == "sig") and vb is not None and vb[0] == "sig":
                kinds.add("signatures")
            elif va is None or vb is None:
                kinds.add("fields")
            else:
                kinds.add("form_fill")
        if "/DSS" in after.Root and after.Root.get("/DSS") is not None:
            if "/DSS" not in before.Root:
                kinds.add("security_store")
    return sorted(kinds)


ALLOWED = {1: set(), 2: {"form_fill", "signatures", "security_store"},
           3: {"form_fill", "signatures", "security_store", "annotations"}}


@query("signatures")
def signatures_query(ctx):
    pdf = ctx.pdf
    with open(ctx.source, "rb") as stream:
        data = stream.read()
    ends = _revision_ends(data)
    level = _docmdp_level(pdf)
    certifier = None
    perms = pdf.Root.get("/Perms")
    if perms is not None and "/DocMDP" in perms and perms.DocMDP.is_indirect:
        certifier = perms.DocMDP.objgen
    items = []
    dss = pdf.Root.get("/DSS")
    dss_certs = set()
    if dss is not None:
        for s in dss.get("/Certs", []):
            dss_certs.add(hashlib.sha256(s.read_bytes()).hexdigest())
    for name, field in signature_fields(pdf):
        widget = _widgets(field)[0]
        page = _page_index(pdf, widget)
        rect = [float(v) for v in widget.get("/Rect", [0, 0, 0, 0])]
        value = field.get("/V")
        item = {"field": name, "page": page, "rect": rect,
                "visible": abs(rect[2] - rect[0]) > 0 and abs(rect[3] - rect[1]) > 0, "signed": False}
        if not isinstance(value, pikepdf.Dictionary) or "/ByteRange" not in value or "/Contents" not in value:
            items.append(item)
            continue
        item["signed"] = True
        item["reason"] = _text(value.get("/Reason"))
        item["location"] = _text(value.get("/Location"))
        item["contact"] = _text(value.get("/ContactInfo"))
        item["name"] = _text(value.get("/Name"))
        item["time"] = parse_pdf_date(_text(value.get("/M")))
        item["subfilter"] = str(value.get("/SubFilter", "")).lstrip("/")
        item["certification"] = None
        for ref in value.get("/Reference", []):
            if str(ref.get("/TransformMethod", "")) == "/DocMDP":
                item["certification"] = int(ref.get("/TransformParams", {}).get("/P", 2))
        if value.is_indirect and certifier == value.objgen and item["certification"] is None:
            item["certification"] = level
        ranges = [int(v) for v in value.ByteRange]
        errors = []
        ok_range = (len(ranges) == 4 and ranges[0] == 0 and ranges[1] > 0 and ranges[2] > ranges[1]
                    and ranges[2] + ranges[3] <= len(data)
                    and data[ranges[1]:ranges[1] + 1] == b"<" and data[ranges[2] - 1:ranges[2]] == b">")
        if not ok_range:
            errors.append("The signature byte range is malformed.")
        signed_end = ranges[2] + ranges[3] if len(ranges) == 4 else 0
        blob = bytes(value.Contents)

        def digest_for(algorithm, _ranges=ranges):
            require(ok_range, "INVALID_SIGNATURE", "Malformed byte range.")
            h = hashlib.new(algorithm)
            h.update(data[_ranges[0]:_ranges[0] + _ranges[1]])
            h.update(data[_ranges[2]:_ranges[2] + _ranges[3]])
            return h.digest()

        report = C.verify_signed_data(blob, digest_for)
        item.update({k: report.get(k) for k in ("integrity", "signature_valid", "digest_valid", "signer",
                                                "certificates", "timestamp", "digest_algorithm",
                                                "signature_algorithm", "claimed_time", "pades_attributes")})
        item["errors"] = errors + report.get("errors", [])
        item["integrity"] = bool(report.get("integrity")) and ok_range
        trailing = data[signed_end:].strip() if signed_end else b""
        item["covers_document"] = ok_range and not trailing
        revision = sum(1 for end in ends if end <= signed_end) if signed_end else 0
        item["revision"] = revision
        item["revisions"] = len(ends)
        item["changes_after"] = []
        if ok_range and trailing:
            item["changes_after"] = _changes_between(data[:signed_end], ctx.source)
        allowed = ALLOWED.get(item["certification"] or level or 0)
        if item["certification"] and allowed is not None:
            item["mdp_violation"] = bool(set(item["changes_after"]) - allowed)
        elif level and allowed is not None:
            item["mdp_violation"] = bool(set(item["changes_after"]) - allowed)
        else:
            item["mdp_violation"] = False
        chain = report.get("certificates") or []
        item["ltv"] = bool(chain) and all(hashlib.sha256(base64.b64decode(c)).hexdigest() in dss_certs for c in chain)
        items.append(item)
    return {"signatures": items, "certification": level, "revisions": len(ends),
            "has_dss": dss is not None}


@query("signature_revision")
def signature_revision(ctx, field):
    """The bytes a signature covers, for "View signed version"."""
    with open(ctx.source, "rb") as stream:
        data = stream.read()
    for name, f in signature_fields(ctx.pdf):
        value = f.get("/V")
        if name == field and isinstance(value, pikepdf.Dictionary) and "/ByteRange" in value:
            ranges = [int(v) for v in value.ByteRange]
            end = ranges[2] + ranges[3]
            return {"length": end, "sha256": hashlib.sha256(data[:end]).hexdigest()}
    raise EngineError("NOT_FOUND", "No signed field with that name.")


@op("extract_signed_revision", rewrite=True)
def extract_signed_revision(ctx, field):
    """Replace the working document with the exact revision a signature covers."""
    with open(ctx.source, "rb") as stream:
        data = stream.read()
    for name, f in signature_fields(ctx.pdf):
        value = f.get("/V")
        if name == field and isinstance(value, pikepdf.Dictionary) and "/ByteRange" in value:
            ranges = [int(v) for v in value.ByteRange]
            end = ranges[2] + ranges[3]
            path = ctx.scratch()
            path.write_bytes(data[:end])
            def verbatim(ctx_, candidate, _path=path):
                import shutil
                shutil.copyfile(_path, candidate)
            ctx.save_options["writer"] = verbatim
            return {"length": end}
    raise EngineError("NOT_FOUND", "No signed field with that name.")


@op("clear_signature", rewrite=True)
def clear_signature(ctx, field):
    """Remove a signature value (full rewrite; invalidates all signatures)."""
    for name, f in signature_fields(ctx.pdf):
        if name == field and "/V" in f:
            del f["/V"]
            for widget in _widgets(f):
                widget.F = int(widget.get("/F", 4)) & ~128
                if "/AP" in widget:
                    del widget["/AP"]
            perms = ctx.pdf.Root.get("/Perms")
            if perms is not None and "/DocMDP" in perms:
                del ctx.pdf.Root["/Perms"]
            return {"cleared": name}
    raise EngineError("NOT_FOUND", "No signed field with that name.")
