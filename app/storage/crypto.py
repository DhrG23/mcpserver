"""
At-rest encryption for sensitive columns: memory values and device telemetry
payloads (screenshots, notification content, location).

This is server-held-key encryption, not end-to-end: the server can decrypt,
because Alexa+/Nemotron/Ollama need to actually read this data to be useful.
What it protects against: someone getting a copy of the SQLite file or a
backup without also getting the key. It does NOT protect against a
compromised running server process — be accurate about that when describing
this system, don't oversell it as "fully private."

Key comes from DATA_ENCRYPTION_KEY (a Fernet key: 32 url-safe base64 bytes).
If unset, a key is generated for this process only and a loud warning is
printed — fine for a first local test, wrong for anything you restart and
expect to still read, and definitely wrong for real device data.
"""
from __future__ import annotations

import os
import sys

from cryptography.fernet import Fernet, InvalidToken

_KEY_ENV = "DATA_ENCRYPTION_KEY"


def _load_key() -> bytes:
    key = os.environ.get(_KEY_ENV)
    if key:
        return key.encode()

    generated = Fernet.generate_key()
    print(
        f"\n[personal-ai-mcp] WARNING: {_KEY_ENV} is not set. Generated a "
        f"throwaway key for this process only -- encrypted data will be "
        f"UNREADABLE after restart.\n"
        f"Set a permanent one in .env:\n"
        f"  {_KEY_ENV}={generated.decode()}\n",
        file=sys.stderr,
    )
    return generated


_fernet = Fernet(_load_key())


def encrypt(plaintext: str) -> str:
    """Encrypt a string, return a string safe to store in a TEXT column."""
    return _fernet.encrypt(plaintext.encode()).decode()


def decrypt(ciphertext: str) -> str:
    """Decrypt a value produced by encrypt(). Raises ValueError on a bad/rotated key
    rather than crashing the caller with a raw cryptography exception."""
    try:
        return _fernet.decrypt(ciphertext.encode()).decode()
    except InvalidToken as e:
        raise ValueError(
            "Could not decrypt stored data -- DATA_ENCRYPTION_KEY doesn't match "
            "the key this data was written with."
        ) from e


def hash_token(token: str) -> str:
    """One-way hash for device bearer tokens. Plain SHA-256 is fine here (unlike a
    password hash) because tokens are high-entropy random values, not guessable
    dictionary words -- there's nothing for a rainbow table to gain traction on."""
    import hashlib

    return hashlib.sha256(token.encode()).hexdigest()
