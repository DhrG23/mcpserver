"""
At-rest encryption (server-held key, NOT end-to-end -- see README).

DATA_ENCRYPTION_KEY      current Fernet key (new data is encrypted with it)
DATA_ENCRYPTION_KEY_OLD  optional comma-separated previous keys, still accepted
                         for decryption (key rotation via MultiFernet)
If DATA_ENCRYPTION_KEY is unset a throwaway key is generated and a loud
warning is printed; data will be unreadable after a restart.
"""
from __future__ import annotations

import hashlib
import os
import sys

from cryptography.fernet import Fernet, InvalidToken, MultiFernet

import app.config  # noqa: F401  (loads .env first)

_KEY_ENV = "DATA_ENCRYPTION_KEY"


def _build() -> MultiFernet:
    key = os.environ.get(_KEY_ENV)
    if not key:
        generated = Fernet.generate_key()
        print(
            f"\n[personal-ai-mcp] WARNING: {_KEY_ENV} is not set. Generated a throwaway key for "
            f"this process only -- encrypted data will be UNREADABLE after restart.\n"
            f"Set a permanent one in .env:\n  {_KEY_ENV}={generated.decode()}\n",
            file=sys.stderr,
        )
        key = generated.decode()
    keys = [key.strip()]
    keys += [k.strip() for k in os.environ.get("DATA_ENCRYPTION_KEY_OLD", "").split(",") if k.strip()]
    return MultiFernet([Fernet(k.encode()) for k in keys])


_fernet = _build()


def encrypt(plaintext: str) -> str:
    return _fernet.encrypt(plaintext.encode()).decode()


def decrypt(ciphertext: str) -> str:
    try:
        return _fernet.decrypt(ciphertext.encode()).decode()
    except InvalidToken as e:
        raise ValueError(
            "Could not decrypt stored data -- DATA_ENCRYPTION_KEY doesn't match the key it was written with."
        ) from e


def hash_token(token: str) -> str:
    """SHA-256 of a high-entropy random token (not for passwords)."""
    return hashlib.sha256(token.encode()).hexdigest()
