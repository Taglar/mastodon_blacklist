#!/usr/bin/env bash
set -euo pipefail

SOURCE_URL="${OLIPHANT_SOURCE_URL:-https://raw.githubusercontent.com/sgrigson/oliphant/main/blocklists/mastodon/_unified_tier0_blocklist.csv}"
TARGET="${OLIPHANT_TARGET:-/var/lib/fediblockhole/sources/oliphant-tier0-fediblockhole.csv}"
TMP="$(mktemp)"

cleanup() {
  rm -f "$TMP"
}
trap cleanup EXIT

mkdir -p "$(dirname "$TARGET")"

curl -fsSL "$SOURCE_URL" \
  | sed '1s/#//g' \
  > "$TMP"

# Minimaler Plausibilitätscheck: Header und mehr als ein paar Zeilen.
grep -q '^domain,severity' "$TMP"
test "$(wc -l < "$TMP")" -gt 10

install -o fediblock -g fediblock -m 0640 "$TMP" "$TARGET"

echo "INFO: Oliphant-Quelle aktualisiert: $TARGET"
