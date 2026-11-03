"""Independent standard ES256/JWK verification for synthetic Dart proofs.

Reads one JSON array from stdin; never opens a network connection or key store.
"""
import base64
import hashlib
import json
import sys

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, utils


def decode(value):
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def verify(case):
    header_text, payload_text, signature_text = case["proof"].split(".")
    header = json.loads(decode(header_text))
    jwk = header["jwk"]
    if header["alg"] != "ES256" or jwk["crv"] != "P-256" or jwk["kty"] != "EC":
        return {"valid": False}
    x, y = decode(jwk["x"]), decode(jwk["y"])
    signature = decode(signature_text)
    if len(x) != 32 or len(y) != 32 or len(signature) != 64:
        return {"valid": False}
    key = ec.EllipticCurvePublicNumbers(int.from_bytes(x, "big"),
        int.from_bytes(y, "big"), ec.SECP256R1()).public_key()
    canonical = json.dumps({"crv": "P-256", "kty": "EC", "x": jwk["x"], "y": jwk["y"]}, separators=(",", ":")).encode()
    thumbprint = base64.urlsafe_b64encode(hashlib.sha256(canonical).digest()).decode().rstrip("=")
    encoded = utils.encode_dss_signature(int.from_bytes(signature[:32], "big"), int.from_bytes(signature[32:], "big"))
    try:
        key.verify(encoded, (header_text + "." + payload_text).encode("ascii"), ec.ECDSA(hashes.SHA256()))
        order = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
        valid = (thumbprint == case["keyThumbprint"] and
            int.from_bytes(signature[32:], "big") <= order // 2)
    except InvalidSignature:
        valid = False
    return {"valid": valid, "publicKeyHex": (x + y).hex()}


print(json.dumps([verify(case) for case in json.load(sys.stdin)]))
