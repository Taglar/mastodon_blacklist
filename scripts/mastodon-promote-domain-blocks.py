#!/usr/bin/env python3
"""
Promotes selected Mastodon domain blocks to severity=suspend.

The large imported blocklist should stay conservative, for example severity=silence.
This script reads a local trusted suspend CSV and only creates/updates those entries
as suspend. It supports Mastodon Admin API pagination.
"""

from __future__ import annotations

import csv
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

INSTANCE = os.environ.get("MASTODON_INSTANCE", "").strip()
ENV_FILE = Path(os.environ.get("FEDIBLOCK_ENV_FILE", "/etc/fediblockhole.env"))
SUSPENDLIST = Path(os.environ.get("FEDIBLOCK_SUSPENDLIST", "/etc/fediblockhole-suspendlist.csv"))
ALLOWLIST = Path(os.environ.get("FEDIBLOCK_ALLOWLIST", "/etc/fediblockhole-allowlist.csv"))
DRYRUN = os.environ.get("DRYRUN", "0") == "1"


def load_env_file(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if not path.exists():
        raise SystemExit(f"ERROR: Env-Datei fehlt: {path}")

    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = value.strip().strip("'").strip('"')

    return env


ENV = load_env_file(ENV_FILE)
TOKEN = ENV.get("MASTODON_FEDIBLOCK_TOKEN", "").strip()
INSTANCE = INSTANCE or ENV.get("MASTODON_INSTANCE", "").strip()

if not TOKEN:
    raise SystemExit(f"ERROR: MASTODON_FEDIBLOCK_TOKEN fehlt in {ENV_FILE}")

if not INSTANCE:
    raise SystemExit(
        "ERROR: MASTODON_INSTANCE fehlt. Setze MASTODON_INSTANCE in /etc/fediblockhole.env."
    )


def api_request(method: str, url: str, data: dict[str, str] | None = None):
    headers = {
        "Authorization": f"Bearer {TOKEN}",
        "User-Agent": "mastodon-fediblock-automation/1.0",
    }

    encoded_data = None
    if data is not None:
        encoded_data = urllib.parse.urlencode(data).encode("utf-8")
        headers["Content-Type"] = "application/x-www-form-urlencoded"

    req = urllib.request.Request(url, data=encoded_data, headers=headers, method=method)

    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return response, response.read()
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        print(f"ERROR: HTTP {e.code} bei {method} {url}: {body}", file=sys.stderr)
        raise
    except urllib.error.URLError as e:
        print(f"ERROR: Verbindung fehlgeschlagen bei {method} {url}: {e}", file=sys.stderr)
        raise


def extract_next_link(link_header: str | None) -> str | None:
    if not link_header:
        return None

    for part in link_header.split(","):
        part = part.strip()
        match = re.match(r'<([^>]+)>;\s*rel="next"', part)
        if match:
            return match.group(1)

    return None


def fetch_all_domain_blocks() -> list[dict]:
    print(f"INFO: Lade bestehende Domain-Blocks von {INSTANCE} mit Pagination ...")

    url = f"https://{INSTANCE}/api/v1/admin/domain_blocks?limit=200"
    all_blocks: list[dict] = []
    page = 1

    while url:
        response, body = api_request("GET", url)
        blocks = json.loads(body.decode("utf-8"))

        if not isinstance(blocks, list):
            raise SystemExit(f"ERROR: Unerwartete API-Antwort auf Seite {page}")

        all_blocks.extend(blocks)
        print(f"INFO: Seite {page}: {len(blocks)} Blocks geladen, gesamt: {len(all_blocks)}")

        url = extract_next_link(response.headers.get("Link"))
        page += 1

    print(f"INFO: Insgesamt {len(all_blocks)} bestehende Domain-Blocks geladen.")
    return all_blocks


def load_allowlist() -> set[str]:
    domains: set[str] = set()
    if not ALLOWLIST.exists():
        return domains

    with ALLOWLIST.open(newline="", encoding="utf-8") as fp:
        reader = csv.DictReader(fp)
        for row in reader:
            domain = (row.get("domain") or "").strip().lower()
            if domain:
                domains.add(domain)

    return domains


def load_suspendlist() -> list[dict[str, str]]:
    if not SUSPENDLIST.exists():
        print(f"INFO: Keine Suspendliste vorhanden: {SUSPENDLIST}")
        return []

    entries: list[dict[str, str]] = []

    with SUSPENDLIST.open(newline="", encoding="utf-8") as fp:
        reader = csv.DictReader(fp)
        for row in reader:
            domain = (row.get("domain") or "").strip().lower()
            if not domain or domain.startswith("#"):
                continue

            entries.append(
                {
                    "domain": domain,
                    "public_comment": (row.get("public_comment") or "Trusted suspend override").strip(),
                    "private_comment": (row.get("private_comment") or "Trusted suspend override").strip(),
                }
            )

    return entries


def create_domain_block(domain: str, public_comment: str, private_comment: str) -> None:
    url = f"https://{INSTANCE}/api/v1/admin/domain_blocks"
    data = {
        "domain": domain,
        "severity": "suspend",
        "reject_media": "false",
        "reject_reports": "false",
        "public_comment": public_comment,
        "private_comment": private_comment,
        "obfuscate": "false",
    }

    if DRYRUN:
        print(f"DRYRUN CREATE: {domain} als suspend")
        return

    api_request("POST", url, data)
    print(f"CREATE: {domain} als suspend")


def update_domain_block(block_id: str, domain: str, public_comment: str, private_comment: str) -> None:
    url = f"https://{INSTANCE}/api/v1/admin/domain_blocks/{block_id}"
    data = {
        "severity": "suspend",
        "reject_media": "false",
        "reject_reports": "false",
        "public_comment": public_comment,
        "private_comment": private_comment,
        "obfuscate": "false",
    }

    if DRYRUN:
        print(f"DRYRUN UPDATE: {domain} auf suspend")
        return

    api_request("PUT", url, data)
    print(f"UPDATE: {domain} auf suspend")


def main() -> None:
    allowlist = load_allowlist()
    suspendlist = load_suspendlist()

    if not suspendlist:
        print("INFO: Suspendliste leer. Nichts zu tun.")
        return

    existing_blocks = fetch_all_domain_blocks()
    existing_by_domain = {
        (block.get("domain") or "").strip().lower(): block
        for block in existing_blocks
        if block.get("domain")
    }

    print(f"INFO: Verarbeite Suspendliste: {SUSPENDLIST}")

    for entry in suspendlist:
        domain = entry["domain"]

        if domain in allowlist:
            print(f"SKIP: {domain} ist in der Allowlist")
            continue

        existing = existing_by_domain.get(domain)

        if existing:
            existing_id = existing.get("id")
            existing_severity = existing.get("severity")

            if existing_severity == "suspend":
                print(f"OK: {domain} ist bereits suspend")
                continue

            update_domain_block(
                str(existing_id),
                domain,
                entry["public_comment"],
                entry["private_comment"],
            )
        else:
            create_domain_block(
                domain,
                entry["public_comment"],
                entry["private_comment"],
            )

    print("INFO: Fertig.")


if __name__ == "__main__":
    main()
