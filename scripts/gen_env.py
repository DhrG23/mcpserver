#!/usr/bin/env python3
"""Create .env from .env.example with fresh random secrets. Refuses to overwrite an existing .env.

    python3 scripts/gen_env.py                 # writes ./.env
    python3 scripts/gen_env.py --host 192.168.1.20   # also sets SERVER_HOST (Docker LAN mode)
"""
import argparse
import re
import secrets
import sys
from pathlib import Path

from cryptography.fernet import Fernet

root = Path(__file__).resolve().parent.parent
ap = argparse.ArgumentParser()
ap.add_argument("--host", default="", help="LAN IP or hostname your phone will use")
ap.add_argument("--domain", default="", help="public domain (Docker public mode)")
args = ap.parse_args()

target = root / ".env"
if target.exists():
    sys.exit(".env already exists - not overwriting. Delete it first if you really want new secrets "
             "(new DATA_ENCRYPTION_KEY makes existing encrypted data unreadable).")

_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"      # no 0/O/1/I/L to avoid typos


def new_invite_code() -> str:
    pick = lambda n: "".join(secrets.choice(_ALPHABET) for _ in range(n))  # noqa: E731
    return f"NODE-{pick(5)}-{pick(5)}"


values = {
    "INVITE_CODE": new_invite_code(),
    "ALEXA_TOKEN": secrets.token_urlsafe(32), "NEMOTRON_TOKEN": secrets.token_urlsafe(32),
    "OLLAMA_TOKEN": secrets.token_urlsafe(32), "ADMIN_TOKEN": secrets.token_urlsafe(32),
    "DATA_ENCRYPTION_KEY": Fernet.generate_key().decode(),
}
if args.host:
    values["SERVER_HOST"] = args.host
if args.domain:
    values["SERVER_DOMAIN"] = args.domain

lines = []
for line in (root / ".env.example").read_text().splitlines():
    m = re.match(r"^([A-Z_]+)=", line)
    if m and m.group(1) in values:
        rest = line.split("#", 1)[1] if "#" in line else ""
        line = f"{m.group(1)}={values[m.group(1)]}" + (f"   #{rest}" if rest else "")
    lines.append(line)
target.write_text("\n".join(lines) + "\n")
target.chmod(0o600)
print(f"Wrote {target} (mode 600). Back up DATA_ENCRYPTION_KEY somewhere safe - without it stored data cannot be read.")
print(f"Invite code for the Node app's register screen: {values['INVITE_CODE']}")
