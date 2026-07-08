#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="mastodon-fediblock-automation"
DEFAULT_TIMER="04:20:00"
DEFAULT_DOMAIN=""
DEFAULT_MAX_SEVERITY="silence"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Bitte als root ausführen, z. B. mit sudo." >&2
    exit 1
  fi
}

ask() {
  local prompt="$1"
  local default="${2:-}"
  local value

  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " value
    echo "${value:-$default}"
  else
    read -r -p "$prompt: " value
    echo "$value"
  fi
}

ask_secret() {
  local prompt="$1"
  local value
  read -r -s -p "$prompt: " value
  echo >&2
  echo "$value"
}

valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9._*-]+\.[A-Za-z0-9._*-]+$ ]]
}

print_token_hint() {
  cat <<'HINT'

Mastodon API-Token erstellen:
  1. Als Admin in Mastodon anmelden
  2. Einstellungen -> Entwicklung -> Neue Anwendung
  3. Name z. B.: fediblockhole
  4. Scopes/Rechte setzen:
       admin:read
       admin:read:domain_blocks
       admin:write:domain_blocks
     Alternativ zum Testen: admin:read und admin:write
  5. Anwendung speichern und den Access Token kopieren

Wichtig: Der Token gehört zu einem Admin-Account und wird lokal in
/etc/fediblockhole.env gespeichert. Diese Datei erhält 0640 root:fediblock.

HINT
}

install_packages() {
  echo "INFO: Installiere Systempakete ..."
  apt-get update
  apt-get install -y python3-venv python3-pip curl ca-certificates jq
}

create_user_and_dirs() {
  echo "INFO: Erstelle User/Verzeichnisse ..."
  if ! id fediblock >/dev/null 2>&1; then
    useradd --system --home /opt/fediblockhole --create-home --shell /usr/sbin/nologin fediblock
  fi

  mkdir -p /opt/fediblockhole /var/lib/fediblockhole/sources /var/log/fediblockhole
  chown -R fediblock:fediblock /opt/fediblockhole /var/lib/fediblockhole /var/log/fediblockhole
  chmod 750 /opt/fediblockhole /var/lib/fediblockhole /var/log/fediblockhole
}

install_fediblockhole() {
  echo "INFO: Installiere FediBlockHole in Python venv ..."
  if [[ ! -x /opt/fediblockhole/venv/bin/python ]]; then
    sudo -u fediblock python3 -m venv /opt/fediblockhole/venv
  fi
  sudo -u fediblock /opt/fediblockhole/venv/bin/python -m pip install --upgrade pip
  sudo -u fediblock /opt/fediblockhole/venv/bin/python -m pip install --upgrade fediblockhole
}

write_file_from_repo_or_inline() {
  local source_file="$1"
  local target_file="$2"
  local mode="$3"

  if [[ -f "$source_file" ]]; then
    install -m "$mode" "$source_file" "$target_file"
  else
    return 1
  fi
}

install_runtime_scripts() {
  echo "INFO: Installiere Runtime-Scripte ..."
  local base_dir
  base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  if ! write_file_from_repo_or_inline "$base_dir/scripts/update-oliphant-fediblockhole.sh" /usr/local/bin/update-oliphant-fediblockhole.sh 0755; then
    cat > /usr/local/bin/update-oliphant-fediblockhole.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
SOURCE_URL="${OLIPHANT_SOURCE_URL:-https://raw.githubusercontent.com/sgrigson/oliphant/main/blocklists/mastodon/_unified_tier0_blocklist.csv}"
TARGET="${OLIPHANT_TARGET:-/var/lib/fediblockhole/sources/oliphant-tier0-fediblockhole.csv}"
TMP="$(mktemp)"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT
mkdir -p "$(dirname "$TARGET")"
curl -fsSL "$SOURCE_URL" | sed '1s/#//g' > "$TMP"
grep -q '^domain,severity' "$TMP"
test "$(wc -l < "$TMP")" -gt 10
install -o fediblock -g fediblock -m 0640 "$TMP" "$TARGET"
echo "INFO: Oliphant-Quelle aktualisiert: $TARGET"
SCRIPT
    chmod 0755 /usr/local/bin/update-oliphant-fediblockhole.sh
  fi

  if ! write_file_from_repo_or_inline "$base_dir/scripts/mastodon-promote-domain-blocks.py" /usr/local/bin/mastodon-promote-domain-blocks.py 0755; then
    cat > /usr/local/bin/mastodon-promote-domain-blocks.py <<'PY_SCRIPT'
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
PY_SCRIPT
    chmod 0755 /usr/local/bin/mastodon-promote-domain-blocks.py
  fi
}

write_config_files() {
  local domain="$1"
  local token="$2"

  echo "INFO: Schreibe Konfigurationsdateien ..."

  cat > /etc/fediblockhole.env <<EOFENV
MASTODON_INSTANCE=$domain
MASTODON_FEDIBLOCK_TOKEN=$token
EOFENV
  chown root:fediblock /etc/fediblockhole.env
  chmod 640 /etc/fediblockhole.env

  cat > /etc/fediblockhole.conf.toml <<EOFCONF
save_intermediate = true
savedir = "/var/lib/fediblockhole"
blocklist_savefile = "/var/lib/fediblockhole/merged_blocklist.csv"
blocklist_auditfile = "/var/log/fediblockhole/fediblockhole-audit.csv"

mergeplan = "max"

blocklist_url_sources = [
  { url = "file:///var/lib/fediblockhole/sources/oliphant-tier0-fediblockhole.csv", format = "csv", max_severity = "$DEFAULT_MAX_SEVERITY" }
]

blocklist_instance_destinations = [
  {
    domain = "$domain",
    token_env_var = "MASTODON_FEDIBLOCK_TOKEN",
    import_fields = ["public_comment", "private_comment"],
    max_severity = "$DEFAULT_MAX_SEVERITY",
    max_followed_severity = "$DEFAULT_MAX_SEVERITY"
  }
]

allowlist_url_sources = [
  { url = "file:///etc/fediblockhole-allowlist.csv", format = "csv" }
]
EOFCONF
  chown root:fediblock /etc/fediblockhole.conf.toml
  chmod 640 /etc/fediblockhole.conf.toml

  if [[ ! -f /etc/fediblockhole-allowlist.csv ]]; then
    cat > /etc/fediblockhole-allowlist.csv <<EOFALLOW
domain,severity
$domain,noop
mastodon.social,noop
chaos.social,noop
troet.cafe,noop
EOFALLOW
  fi
  chown root:fediblock /etc/fediblockhole-allowlist.csv
  chmod 640 /etc/fediblockhole-allowlist.csv

  if [[ ! -f /etc/fediblockhole-suspendlist.csv ]]; then
    cat > /etc/fediblockhole-suspendlist.csv <<'EOFSUSPEND'
domain,public_comment,private_comment
# example-spam.tld,Spam/Abuse,Manuell als harte Spam-Instanz eingestuft
EOFSUSPEND
  fi
  chown root:fediblock /etc/fediblockhole-suspendlist.csv
  chmod 640 /etc/fediblockhole-suspendlist.csv
}

write_systemd_units() {
  local timer_time="$1"

  echo "INFO: Schreibe systemd Units ..."
  cat > /etc/systemd/system/fediblockhole.service <<'EOFSERVICE'
[Unit]
Description=Sync Mastodon domain blocklist with FediBlockHole
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=fediblock
Group=fediblock
EnvironmentFile=/etc/fediblockhole.env
ExecStartPre=/usr/local/bin/update-oliphant-fediblockhole.sh
ExecStart=/opt/fediblockhole/venv/bin/fediblock-sync -c /etc/fediblockhole.conf.toml
ExecStartPost=/usr/local/bin/mastodon-promote-domain-blocks.py
EOFSERVICE

  cat > /etc/systemd/system/fediblockhole.timer <<EOFTIMER
[Unit]
Description=Daily FediBlockHole sync

[Timer]
OnCalendar=*-*-* $timer_time
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
EOFTIMER

  systemctl daemon-reload
  systemctl enable --now fediblockhole.timer
}

run_tests() {
  echo "INFO: Aktualisiere Oliphant-Quelle ..."
  sudo -u fediblock /usr/local/bin/update-oliphant-fediblockhole.sh

  echo "INFO: Teste Mastodon Admin API ..."
  local domain token
  domain="$(sed -n 's/^MASTODON_INSTANCE=//p' /etc/fediblockhole.env)"
  token="$(sed -n 's/^MASTODON_FEDIBLOCK_TOKEN=//p' /etc/fediblockhole.env)"

  curl -fsS \
    -H "Authorization: Bearer $token" \
    "https://$domain/api/v1/admin/domain_blocks?limit=1" >/dev/null

  echo "INFO: FediBlockHole Dry-Run ..."
  sudo -u fediblock env "$(cat /etc/fediblockhole.env | tr '\n' ' ')" true >/dev/null 2>&1 || true
  sudo -u fediblock env $(cat /etc/fediblockhole.env) \
    /opt/fediblockhole/venv/bin/fediblock-sync \
    -c /etc/fediblockhole.conf.toml \
    --dryrun \
    --no-push-instance

  echo "INFO: Prüfe gemergte Blockliste ..."
  wc -l /var/lib/fediblockhole/merged_blocklist.csv || true

  echo "INFO: Suspend-Override Dry-Run ..."
  sudo -u fediblock DRYRUN=1 /usr/local/bin/mastodon-promote-domain-blocks.py
}

main() {
  require_root

  echo "== Mastodon FediBlock Automation Installer =="
  print_token_hint

  local domain token timer_time run_now

  domain="$(ask "Mastodon-Domain ohne https://" "$DEFAULT_DOMAIN")"
  while ! valid_domain "$domain"; do
    echo "ERROR: Bitte eine gültige Domain angeben, z. B. talk.example.org"
    domain="$(ask "Mastodon-Domain ohne https://" "$DEFAULT_DOMAIN")"
  done

  token="$(ask_secret "Mastodon Admin API Token")"
  while [[ -z "$token" ]]; do
    echo "ERROR: Token darf nicht leer sein."
    token="$(ask_secret "Mastodon Admin API Token")"
  done

  timer_time="$(ask "Tägliche Uhrzeit für systemd Timer" "$DEFAULT_TIMER")"

  install_packages
  create_user_and_dirs
  install_fediblockhole
  install_runtime_scripts
  write_config_files "$domain" "$token"
  write_systemd_units "$timer_time"
  run_tests

  echo
  echo "Installation abgeschlossen."
  echo
  echo "Nützliche Befehle:"
  echo "  systemctl list-timers | grep fediblockhole"
  echo "  sudo systemctl start fediblockhole.service"
  echo "  sudo journalctl -u fediblockhole.service -n 150 --no-pager"
  echo "  sudo nano /etc/fediblockhole-allowlist.csv"
  echo "  sudo nano /etc/fediblockhole-suspendlist.csv"
  echo
  read -r -p "Jetzt einmal produktiv synchronisieren? [y/N]: " run_now
  if [[ "$run_now" =~ ^[YyJj]$ ]]; then
    systemctl start fediblockhole.service
    journalctl -u fediblockhole.service -n 150 --no-pager
  else
    echo "Produktiver Lauf übersprungen. Der Timer läuft automatisch."
  fi
}

main "$@"
