#!/usr/bin/env python3
"""Makes a Redde setup code for your server: a setup link, and its QR code in the terminal when
qrencode is installed. Scan the code from Redde's setup screen (or with the Camera), or open or
paste the link, and the connection is filled in.

    scripts/setup-code.py --name Home --dashboard http://hermes.home.example:9119 --user redde
    scripts/setup-code.py --api https://hermes.home.example:8642 --profile work
    scripts/setup-code.py --model-url http://llama.home.example:8080 --model qwen3

Passwords and keys are asked for without being shown, so they stay out of your shell history. To
run unattended, set them in the environment instead: REDDE_PASSWORD (Dashboard), REDDE_KEY (Hermes
API), REDDE_PROFILE_KEY, REDDE_ACCESS_SECRET (Cloudflare Access), REDDE_MODEL_KEY. With
--no-secrets they are left out and typed on the phone.

The link is a web address, https://redde.goosehouse.org/connect#…, which iOS opens in Redde. The
connection comes after the "#", the part of an address that is never sent to a server, so the site
doesn't see it. With --app-link the link is redde://connect?… instead and involves no website.

The link and the QR code hold whatever secrets you gave: treat them like the passwords themselves.
"""
import argparse
import getpass
import os
import shutil
import subprocess
import sys
from urllib.parse import quote, urlsplit


def address(value):
    if not value:   # argparse runs a default through this too
        return ""
    parts = urlsplit(value)
    if parts.scheme not in ("http", "https") or not parts.hostname or parts.username:
        raise argparse.ArgumentTypeError(f"{value!r} is not an http or https address")
    return value.rstrip("/")


def secret(env, prompt, wanted):
    """The secret from the environment, else asked for; blank leaves it out."""
    if not wanted:
        return ""
    if env in os.environ:
        return os.environ[env]
    return getpass.getpass(f"{prompt} (blank to leave out): ") if sys.stdin.isatty() else ""


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--name", default="", help="what the server is called in Redde")
    parser.add_argument("--dashboard", type=address, default="", help="Hermes Dashboard address (hermes serve, port 9119)")
    parser.add_argument("--user", default="", help="Dashboard user name")
    parser.add_argument("--api", type=address, default="", help="Hermes API server address (port 8642)")
    parser.add_argument("--profile", default="", help="Hermes profile, when it isn't the default one")
    parser.add_argument("--access-id", default="", help="Cloudflare Access service token client ID")
    parser.add_argument("--model-url", type=address, default="", help="OpenAI-compatible endpoint address")
    parser.add_argument("--model", default="", help="model name at that endpoint")
    parser.add_argument("--use", choices=["dashboard", "api", "model"], help="which connection Redde talks to (default: the first given)")
    parser.add_argument("--no-secrets", action="store_true", help="leave passwords and keys out")
    parser.add_argument("--app-link", action="store_true", help="print a redde://connect link instead of the web address")
    args = parser.parse_args()
    if not (args.dashboard or args.api or args.model_url):
        parser.error("give at least one of --dashboard, --api or --model-url")

    ask = not args.no_secrets
    fields = [
        ("name", args.name),
        ("dashboard", args.dashboard),
        ("user", args.user if args.dashboard else ""),
        ("password", secret("REDDE_PASSWORD", "Dashboard password", ask and args.dashboard)),
        ("api", args.api),
        ("key", secret("REDDE_KEY", "Hermes API key (API_SERVER_KEY)", ask and args.api)),
        ("profile", args.profile),
        ("profile-key", secret("REDDE_PROFILE_KEY", f"API key of the profile {args.profile}", ask and args.api and args.profile)),
        ("access-id", args.access_id),
        ("access-secret", secret("REDDE_ACCESS_SECRET", "Cloudflare Access client secret", ask and args.access_id)),
        ("model-url", args.model_url),
        ("model-key", secret("REDDE_MODEL_KEY", "Model endpoint API key", ask and args.model_url)),
        ("model", args.model if args.model_url else ""),
        ("use", args.use or ""),
    ]
    # quote, not quote_plus: Redde reads "+" as a plus sign, not as a space.
    parameters = "&".join(f"{name}={quote(value, safe='')}" for name, value in fields if value)
    link = ("redde://connect?" if args.app_link else "https://redde.goosehouse.org/connect#") + parameters

    if shutil.which("qrencode") and sys.stderr.isatty():
        subprocess.run(["qrencode", "-t", "ANSIUTF8", "-m", "2", "-o", "-", link], stdout=sys.stderr, check=False)
    elif sys.stderr.isatty():
        print("(Install qrencode to see this as a QR code here, or paste the link into Redde's setup screen.)", file=sys.stderr)
    print(link)


if __name__ == "__main__":
    main()
