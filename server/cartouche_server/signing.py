"""Ed25519 keys and detached signatures for the manifest.

Keys are stored as base64 of their raw 32 bytes, which is what CryptoKit's
``Curve25519.Signing.PublicKey(rawRepresentation:)`` takes on the phone.
The private key never goes into the repository: CI reads it from a secret.
"""

from __future__ import annotations

import base64
import binascii

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.serialization import Encoding, NoEncryption, PrivateFormat, PublicFormat


class SigningKeyError(ValueError):
    """A key could not be read."""


def _decode(text: str, what: str) -> bytes:
    try:
        raw = base64.b64decode(text.strip(), validate=True)
    except (binascii.Error, ValueError) as exc:
        raise SigningKeyError(f"the {what} is not valid base64") from exc
    if len(raw) != 32:
        raise SigningKeyError(f"the {what} must be 32 bytes, not {len(raw)}")
    return raw


def generate() -> tuple[str, str]:
    """Return a new (private, public) key pair, both base64 text."""
    private = Ed25519PrivateKey.generate()
    raw_private = private.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
    raw_public = private.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    return base64.b64encode(raw_private).decode(), base64.b64encode(raw_public).decode()


def public_from_private(private_b64: str) -> str:
    private = Ed25519PrivateKey.from_private_bytes(_decode(private_b64, "private key"))
    return base64.b64encode(private.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)).decode()


def sign(message: bytes, private_b64: str) -> str:
    """Sign ``message``; return the 64-byte signature as base64."""
    private = Ed25519PrivateKey.from_private_bytes(_decode(private_b64, "private key"))
    return base64.b64encode(private.sign(message)).decode()


def verify(message: bytes, signature_b64: str, public_b64: str) -> bool:
    public = Ed25519PublicKey.from_public_bytes(_decode(public_b64, "public key"))
    try:
        signature = base64.b64decode(signature_b64.strip(), validate=True)
    except (binascii.Error, ValueError):
        return False
    try:
        public.verify(signature, message)
    except InvalidSignature:
        return False
    return True
