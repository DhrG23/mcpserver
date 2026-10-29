#!/usr/bin/env python3
"""Show, create or replace the invite code the Node app asks for when registering.

    python3 scripts/invite_code.py                 # print the code (creates one if .env has none)
    python3 scripts/invite_code.py --new           # replace it with a fresh code
    python3 scripts/invite_code.py --ensure --quiet   # used by restart scripts: add if missing, print nothing

Restart the server afterwards so it picks the code up:  ./restart.sh
Only the standard library is used, so any python3 works.
"""
import argparse
import re
import secrets
import sys
from pathlib import Path

ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"   # no 0/O/1/I/L to avoid typos
env_path = Path(__file__).resolve().parent.parent / ".env"


def new_code():
    pick = lambda n: "".join(secrets.choice(ALPHABET) for _ in range(n))  # noqa: E731
    return "NODE-%s-%s" % (pick(5), pick(5))


def read_code(lines):
    for line in lines:
        m = re.match(r"^INVITE_CODE=(.*)$", line)
        if m:
            return m.group(1).split("#")[0].strip()
    return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--new", action="store_true", help="replace the current code with a new one")
    ap.add_argument("--ensure", action="store_true", help="create a code only if there is none")
    ap.add_argument("--quiet", action="store_true", help="print nothing (for scripts)")
    args = ap.parse_args()

    if not env_path.exists():
        sys.exit("No .env here yet. Run ./reset_and_start.sh (or python3 scripts/gen_env.py) first.")

    lines = env_path.read_text().splitlines()
    current = read_code(lines)
    changed = False

    if args.new or not current:
        current = new_code()
        for i, line in enumerate(lines):
            if re.match(r"^INVITE_CODE=", line):
                lines[i] = "INVITE_CODE=" + current
                break
        else:
            lines.append("INVITE_CODE=" + current)
        env_path.write_text("\n".join(lines) + "\n")
        changed = True

    if args.quiet:
        return
    print(current)
    if changed:
        print("\nSaved to .env. Restart the server so it takes effect:  ./restart.sh", file=sys.stderr)
        if args.new:
            print("The old code no longer works for NEW accounts (existing accounts are not affected).", file=sys.stderr)


main()
