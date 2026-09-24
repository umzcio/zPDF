"""CMS / PAdES primitives: digital IDs, detached signatures, RFC 3161 timestamps.

Built on `cryptography` (keys, X.509, PKCS#12, signature math) and
`asn1crypto` (CMS structure). Only standard, fully specified structures are
produced: CMS SignedData with the PAdES baseline signed attributes
(content-type, message-digest, signing-certificate-v2) and, for B-T, a
signature-time-stamp-token unsigned attribute. No JavaScript, no network
access unless a timestamp/revocation URL is explicitly configured.
"""
import base64
import datetime as dt
import hashlib
import os
import urllib.request

from asn1crypto import cms, core, tsp, x509 as ax509, algos, ocsp as aocsp, crl as acrl
from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

from engine.errors import EngineError, require

HASHES = {"sha256": hashes.SHA256, "sha384": hashes.SHA384, "sha512": hashes.SHA512, "sha1": hashes.SHA1}
USER_AGENT = "zPDF"


# --------------------------------------------------------------------- IDs

def create_identity(name, email="", organization="", unit="", country="", key="rsa2048", years=5, password=""):
    """A self-signed digital ID as a password-protected PKCS#12 blob."""
    require(isinstance(name, str) and name.strip() and len(name) <= 128, "INVALID_ARGUMENT", "Enter a name for the digital ID.")
    require(isinstance(password, str) and len(password) >= 6, "INVALID_ARGUMENT",
            "Use a password of at least 6 characters to protect the digital ID.")
    if key == "rsa2048":
        private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    elif key == "rsa3072":
        private = rsa.generate_private_key(public_exponent=65537, key_size=3072)
    elif key in ("p256", "ecdsa"):
        private = ec.generate_private_key(ec.SECP256R1())
    elif key == "p384":
        private = ec.generate_private_key(ec.SECP384R1())
    else:
        raise EngineError("INVALID_ARGUMENT", "Unsupported key type.")
    attributes = [x509.NameAttribute(NameOID.COMMON_NAME, name.strip())]
    if organization:
        attributes.append(x509.NameAttribute(NameOID.ORGANIZATION_NAME, organization[:64]))
    if unit:
        attributes.append(x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, unit[:64]))
    if country:
        require(len(country) == 2, "INVALID_ARGUMENT", "Country must be a two-letter code.")
        attributes.append(x509.NameAttribute(NameOID.COUNTRY_NAME, country.upper()))
    if email:
        attributes.append(x509.NameAttribute(NameOID.EMAIL_ADDRESS, email[:128]))
    subject = x509.Name(attributes)
    now = dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=5)
    is_rsa = isinstance(private, rsa.RSAPrivateKey)
    builder = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject)
               .public_key(private.public_key()).serial_number(x509.random_serial_number())
               .not_valid_before(now).not_valid_after(now + dt.timedelta(days=365 * int(years)))
               .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
               .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=True,
                                            key_encipherment=is_rsa, data_encipherment=is_rsa,
                                            key_agreement=False, key_cert_sign=False, crl_sign=False,
                                            encipher_only=False, decipher_only=False), critical=True)
               .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.EMAIL_PROTECTION,
                                                     x509.ObjectIdentifier("1.2.840.113583.1.1.5")]), critical=False)
               .add_extension(x509.SubjectKeyIdentifier.from_public_key(private.public_key()), critical=False))
    if email:
        builder = builder.add_extension(x509.SubjectAlternativeName([x509.RFC822Name(email)]), critical=False)
    cert = builder.sign(private, hashes.SHA256())
    blob = pkcs12.serialize_key_and_certificates(name.strip().encode()[:64], private, cert, None,
                                                 serialization.BestAvailableEncryption(password.encode()))
    return {"p12": base64.b64encode(blob).decode(), **describe(cert)}


def load_identity(p12_b64, password):
    try:
        blob = base64.b64decode(p12_b64)
    except (ValueError, TypeError) as exc:
        raise EngineError("INVALID_ARGUMENT", "The digital ID data is damaged.") from exc
    try:
        key, cert, extra = pkcs12.load_key_and_certificates(blob, (password or "").encode())
    except ValueError as exc:
        raise EngineError("INVALID_PASSWORD", "The digital ID password is incorrect.") from exc
    require(key is not None and cert is not None, "INVALID_ARGUMENT",
            "This file does not contain a private key and certificate.")
    require(isinstance(key, (rsa.RSAPrivateKey, ec.EllipticCurvePrivateKey)), "UNSUPPORTED_OPERATION",
            "Only RSA and ECDSA digital IDs are supported.")
    return key, cert, list(extra or [])


def describe(cert):
    def attr(oid):
        values = cert.subject.get_attributes_for_oid(oid)
        return values[0].value if values else ""
    der = cert.public_bytes(serialization.Encoding.DER)
    email = attr(NameOID.EMAIL_ADDRESS)
    try:
        san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
        email = email or next(iter(san.get_values_for_type(x509.RFC822Name)), "")
    except x509.ExtensionNotFound:
        pass
    key = cert.public_key()
    if isinstance(key, rsa.RSAPublicKey):
        algorithm = f"RSA {key.key_size}"
    elif isinstance(key, ec.EllipticCurvePublicKey):
        algorithm = f"ECDSA {key.curve.name}"
    else:
        algorithm = "Other"
    return {"name": attr(NameOID.COMMON_NAME) or cert.subject.rfc4514_string(),
            "email": email, "organization": attr(NameOID.ORGANIZATION_NAME),
            "subject": cert.subject.rfc4514_string(), "issuer": cert.issuer.rfc4514_string(),
            "serial": format(cert.serial_number, "x"),
            "not_before": cert.not_valid_before_utc.isoformat(), "not_after": cert.not_valid_after_utc.isoformat(),
            "sha256": hashlib.sha256(der).hexdigest(), "certificate": base64.b64encode(der).decode(),
            "self_signed": cert.subject == cert.issuer, "algorithm": algorithm}


def inspect_identity(p12_b64, password):
    key, cert, extra = load_identity(p12_b64, password)
    info = describe(cert)
    info["chain"] = [base64.b64encode(c.public_bytes(serialization.Encoding.DER)).decode() for c in extra]
    # Re-protect with the same password using modern PBES2/AES so stored IDs
    # never keep legacy RC2/3DES protection.
    info["p12"] = base64.b64encode(pkcs12.serialize_key_and_certificates(
        info["name"].encode()[:64], key, cert, extra or None,
        serialization.BestAvailableEncryption((password or "").encode()) if password else serialization.NoEncryption())).decode()
    return info


def describe_certificate(der_b64):
    try:
        cert = x509.load_der_x509_certificate(base64.b64decode(der_b64))
    except ValueError:
        try:
            cert = x509.load_pem_x509_certificate(base64.b64decode(der_b64))
        except ValueError as exc:
            raise EngineError("INVALID_ARGUMENT", "This is not an X.509 certificate.") from exc
    return describe(cert)


# ---------------------------------------------------------------- signing

def _signature_algorithm(key):
    if isinstance(key, rsa.RSAPrivateKey):
        return {"algorithm": "rsassa_pkcs1v15"}
    return {"algorithm": "sha256_ecdsa"}


def _raw_sign(key, data):
    if isinstance(key, rsa.RSAPrivateKey):
        return key.sign(data, padding.PKCS1v15(), hashes.SHA256())
    return key.sign(data, ec.ECDSA(hashes.SHA256()))


def _asn1_cert(cert):
    return ax509.Certificate.load(cert.public_bytes(serialization.Encoding.DER))


def build_signed_data(digest, key, cert, chain=(), timestamp_url=None, signing_time=None, fetch=None):
    """CMS SignedData over a precomputed SHA-256 document digest (PAdES B-B/B-T)."""
    ac = _asn1_cert(cert)
    ess = tsp.SigningCertificateV2({"certs": [tsp.ESSCertIDv2({
        "hash_algorithm": {"algorithm": "sha256"},
        "cert_hash": hashlib.sha256(ac.dump()).digest(),
        "issuer_serial": {"issuer": [ax509.GeneralName({"directory_name": ac.issuer})],
                          "serial_number": ac.serial_number}})]})
    attributes = [
        cms.CMSAttribute({"type": "content_type", "values": ["data"]}),
        cms.CMSAttribute({"type": "message_digest", "values": [digest]}),
        cms.CMSAttribute({"type": "signing_certificate_v2", "values": [ess]}),
    ]
    if signing_time is not None:  # adbe.pkcs7.detached compatibility only
        attributes.insert(1, cms.CMSAttribute({"type": "signing_time", "values": [cms.Time({"utc_time": signing_time})]}))
    signed_attrs = cms.CMSAttributes(attributes)
    signature = _raw_sign(key, signed_attrs.dump())
    info = {
        "version": "v1",
        "sid": cms.SignerIdentifier({"issuer_and_serial_number": cms.IssuerAndSerialNumber(
            {"issuer": ac.issuer, "serial_number": ac.serial_number})}),
        "digest_algorithm": {"algorithm": "sha256"},
        "signed_attrs": signed_attrs,
        "signature_algorithm": _signature_algorithm(key),
        "signature": signature,
    }
    if timestamp_url:
        token = request_timestamp(timestamp_url, hashlib.sha256(signature).digest(), fetch=fetch)
        info["unsigned_attrs"] = cms.CMSAttributes([cms.CMSAttribute(
            {"type": "signature_time_stamp_token", "values": [token]})])
    certificates = [ac] + [_asn1_cert(c) for c in chain if c.fingerprint(hashes.SHA256()) != cert.fingerprint(hashes.SHA256())]
    signed = cms.SignedData({
        "version": "v1",
        "digest_algorithms": [{"algorithm": "sha256"}],
        "encap_content_info": {"content_type": "data"},
        "certificates": certificates,
        "signer_infos": [cms.SignerInfo(info)],
    })
    return cms.ContentInfo({"content_type": "signed_data", "content": signed}).dump()


def _http(url, body, content_type, fetch=None, timeout=20):
    if fetch is not None:
        return fetch(url, body, content_type)
    require(url.startswith(("http://", "https://")), "INVALID_ARGUMENT", "Timestamp and revocation URLs must use HTTP or HTTPS.")
    request = urllib.request.Request(url, data=body, method="POST" if body is not None else "GET",
                                     headers={"Content-Type": content_type, "User-Agent": USER_AGENT} if body is not None
                                     else {"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read(4 * 1024 * 1024)
    except OSError as exc:
        raise EngineError("NETWORK_FAILED", f"Could not reach {url.split('/')[2] if '//' in url else url}.") from exc


def request_timestamp(url, message_hash, fetch=None):
    nonce = int.from_bytes(os.urandom(8), "big")
    request = tsp.TimeStampReq({
        "version": 1,
        "message_imprint": {"hash_algorithm": {"algorithm": "sha256"}, "hashed_message": message_hash},
        "nonce": nonce, "cert_req": True})
    reply = _http(url, request.dump(), "application/timestamp-query", fetch=fetch)
    try:
        response = tsp.TimeStampResp.load(reply)
        status = response["status"]["status"].native
    except (ValueError, TypeError) as exc:
        raise EngineError("TIMESTAMP_FAILED", "The timestamp server returned an unreadable reply.") from exc
    require(status in ("granted", "granted_with_mods"), "TIMESTAMP_FAILED", "The timestamp server refused the request.")
    token = response["time_stamp_token"]
    info = token["content"]["encap_content_info"]["content"].parsed
    require(info["message_imprint"]["hashed_message"].native == message_hash, "TIMESTAMP_FAILED",
            "The timestamp does not match this signature.")
    require(info["nonce"].native == nonce, "TIMESTAMP_FAILED", "The timestamp reply is not for this request.")
    return token


# ------------------------------------------------------------- validation

def _load_cert(ac):
    return x509.load_der_x509_certificate(ac.dump())


def _verify_raw(public_key, signature, data, digest_name, sig_algo):
    hash_cls = HASHES.get(digest_name)
    require(hash_cls is not None, "UNSUPPORTED_OPERATION", "Unsupported digest algorithm.")
    if isinstance(public_key, rsa.RSAPublicKey):
        if sig_algo == "rsassa_pss":
            public_key.verify(signature, data, padding.PSS(mgf=padding.MGF1(hash_cls()), salt_length=padding.PSS.AUTO), hash_cls())
        else:
            public_key.verify(signature, data, padding.PKCS1v15(), hash_cls())
    elif isinstance(public_key, ec.EllipticCurvePublicKey):
        public_key.verify(signature, data, ec.ECDSA(hash_cls()))
    else:
        raise InvalidSignature()


def _signer(signed, signer_info):
    sid = signer_info["sid"]
    certs = [c.chosen for c in signed["certificates"] if isinstance(c.chosen, ax509.Certificate)] if signed["certificates"] else []
    for cert in certs:
        if sid.name == "issuer_and_serial_number":
            if cert.issuer == sid.chosen["issuer"] and cert.serial_number == sid.chosen["serial_number"].native:
                return cert, certs
        elif cert.key_identifier == sid.chosen.native:
            return cert, certs
    return None, certs


def verify_signed_data(blob, content_digest_for):
    """Verify a CMS SignedData. `content_digest_for(name)` hashes the signed bytes.

    Returns a dict describing integrity, the signer, the embedded chain and
    any signature timestamp. Never raises for a bad signature (reports it).
    """
    result = {"integrity": False, "signature_valid": False, "digest_valid": False, "errors": []}
    try:
        content = cms.ContentInfo.load(blob.rstrip(b"\0") if blob.endswith(b"\0\0") else blob)
        # Trailing zero padding after DER is expected in /Contents.
        content = cms.ContentInfo.load(content.dump())
        require(content["content_type"].native == "signed_data", "INVALID_SIGNATURE", "Not a CMS SignedData.")
        signed = content["content"]
        signer_info = signed["signer_infos"][0]
    except (ValueError, TypeError, KeyError, IndexError, EngineError) as exc:
        result["errors"].append("The signature data is damaged.")
        return result
    digest_name = signer_info["digest_algorithm"]["algorithm"].native
    sig_algo = signer_info["signature_algorithm"]["algorithm"].native
    result["digest_algorithm"] = digest_name
    result["signature_algorithm"] = sig_algo
    cert, certs = _signer(signed, signer_info)
    result["certificates"] = [base64.b64encode(c.dump()).decode() for c in certs]
    if cert is None:
        result["errors"].append("The signer's certificate is not embedded.")
        return result
    signer_cert = _load_cert(cert)
    result["signer"] = describe(signer_cert)
    signature = signer_info["signature"].native
    try:
        document_digest = content_digest_for(digest_name)
    except (EngineError, ValueError) as exc:
        result["errors"].append("The signed byte range is invalid.")
        return result
    attrs = signer_info["signed_attrs"]
    if attrs.native is not None and len(attrs):
        signed_bytes = attrs.untag().dump()
        values = {a["type"].native: a["values"] for a in attrs}
        md = values.get("message_digest")
        result["digest_valid"] = md is not None and md[0].native == document_digest
        if "signing_time" in values:
            result["claimed_time"] = values["signing_time"][0].native.isoformat()
        if values.get("content_type") is None or values["content_type"][0].native != "data":
            result["errors"].append("Unexpected content type.")
        result["pades_attributes"] = "signing_certificate_v2" in values
    else:
        signed_bytes = None
        result["digest_valid"] = False
    try:
        if signed_bytes is None:
            raise InvalidSignature()
        _verify_raw(signer_cert.public_key(), signature, signed_bytes, digest_name, sig_algo)
        result["signature_valid"] = True
    except (InvalidSignature, EngineError, ValueError, TypeError):
        result["signature_valid"] = False
    result["integrity"] = result["signature_valid"] and result["digest_valid"]
    if not result["digest_valid"]:
        result["errors"].append("The document bytes do not match the signed digest.")
    if not result["signature_valid"]:
        result["errors"].append("The cryptographic signature is invalid.")
    unsigned = signer_info["unsigned_attrs"]
    if unsigned.native is not None:
        for attr in unsigned:
            if attr["type"].native == "signature_time_stamp_token":
                result["timestamp"] = verify_timestamp(attr["values"][0], hashlib.sha256(signature).digest())
    return result


def verify_timestamp(token, expected_hash):
    info = {"valid": False}
    try:
        signed = token["content"]
        tst = signed["encap_content_info"]["content"].parsed
        info["time"] = tst["gen_time"].native.isoformat()
        info["imprint_valid"] = tst["message_imprint"]["hashed_message"].native == expected_hash
        signer_info = signed["signer_infos"][0]
        cert, certs = _signer(signed, signer_info)
        info["certificates"] = [base64.b64encode(c.dump()).decode() for c in certs]
        if cert is None:
            return info
        tsa = _load_cert(cert)
        info["authority"] = describe(tsa)["name"]
        attrs = signer_info["signed_attrs"]
        values = {a["type"].native: a["values"] for a in attrs}
        digest_name = signer_info["digest_algorithm"]["algorithm"].native
        encap = signed["encap_content_info"]["content"].contents
        h = hashes.Hash(HASHES[digest_name]())
        h.update(encap)
        ok_digest = values["message_digest"][0].native == h.finalize()
        _verify_raw(tsa.public_key(), signer_info["signature"].native, attrs.untag().dump(), digest_name,
                    signer_info["signature_algorithm"]["algorithm"].native)
        info["valid"] = ok_digest and info["imprint_valid"]
    except (InvalidSignature, KeyError, ValueError, TypeError, IndexError):
        info["valid"] = False
    return info


# ------------------------------------------------------------ revocation

def revocation_material(certificates, fetch=None, allow_network=False):
    """Best-effort CRLs/OCSP responses for a chain (DER bytes lists)."""
    crls, ocsps, notes = [], [], []
    if not allow_network:
        return crls, ocsps, ["Revocation data was not fetched (network use is off)."]
    loaded = [x509.load_der_x509_certificate(c) for c in certificates]
    for index, cert in enumerate(loaded):
        if cert.subject == cert.issuer:
            continue
        issuer = next((c for c in loaded if c.subject == cert.issuer), None)
        if issuer is not None:
            try:
                aia = cert.extensions.get_extension_for_class(x509.AuthorityInformationAccess).value
                ocsp_urls = [d.access_location.value for d in aia
                             if d.access_method == x509.oid.AuthorityInformationAccessOID.OCSP]
            except x509.ExtensionNotFound:
                ocsp_urls = []
            for url in ocsp_urls[:1]:
                try:
                    from cryptography.x509 import ocsp
                    req = ocsp.OCSPRequestBuilder().add_certificate(cert, issuer, hashes.SHA1()).build()
                    reply = _http(url, req.public_bytes(serialization.Encoding.DER), "application/ocsp-request", fetch=fetch)
                    parsed = ocsp.load_der_ocsp_response(reply)
                    if parsed.response_status == ocsp.OCSPResponseStatus.SUCCESSFUL:
                        ocsps.append(reply)
                except (EngineError, ValueError):
                    notes.append(f"OCSP unavailable for {describe(cert)['name']}.")
        for url in _crl_urls(cert)[:1]:
            try:
                data = _http(url, None, "", fetch=fetch)
                x509.load_der_x509_crl(data)
                crls.append(data)
            except (EngineError, ValueError):
                notes.append(f"CRL unavailable for {describe(cert)['name']}.")
    return crls, ocsps, notes


def _crl_urls(cert):
    urls = []
    try:
        points = cert.extensions.get_extension_for_class(x509.CRLDistributionPoints).value
    except x509.ExtensionNotFound:
        return urls
    for point in points:
        for name in point.full_name or []:
            if isinstance(name, x509.UniformResourceIdentifier) and name.value.startswith("http"):
                urls.append(name.value)
    return urls
