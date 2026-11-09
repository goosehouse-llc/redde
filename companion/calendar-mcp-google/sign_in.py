#!/usr/bin/env python3
"""Sign one Google account in to the calendar server, from any device.

    sign_in.py <name>        e.g. sign_in.py personal

Prints a link. Open it on any device signed in to that Google account, tick the calendar boxes and
press Allow. The browser then lands on a page that fails to load (http://127.0.0.1:8099/…): that's
expected. Copy the whole address from the address bar and paste it here. The refresh token is kept
in <home>/accounts/<name>.json, readable only by this account, and never printed.

Run it again to replace an account's sign-in; delete the file to remove it.
"""

from __future__ import annotations

import re
import secrets
import sys

import google


def main(argv: list[str]) -> int:
    if len(argv) != 1 or not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,31}", argv[0]):
        print("Usage: sign_in.py <name>   (a short name for the account: letters, digits, - or _, e.g. personal)")
        return 2
    name = argv[0]
    try:
        google.client()
    except google.GoogleError as error:
        print(error)
        print("Put the OAuth client you downloaded from Google Cloud there first (see the README).")
        return 1
    state, verifier = secrets.token_urlsafe(16), google.new_verifier()
    print("1. Open this link on any device signed in to the Google account:\n")
    print(google.sign_in_link(state, verifier))
    print("\n2. Tick both calendar boxes and press Allow. The page after that won't load: that's expected.")
    print("3. Copy the whole address from the address bar and paste it here.\n")
    try:
        pasted = input("Address: ")
    except (EOFError, KeyboardInterrupt):
        print()
        return 1
    try:
        google.finish_sign_in(name, google.code_from(pasted, state), verifier)
    except google.GoogleError as error:
        print(f"\nNot signed in: {error}")
        return 1
    print(f"\nSigned in as {name!r}. A running calendar server picks it up within five minutes.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
