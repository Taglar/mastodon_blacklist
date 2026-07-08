#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Bitte als root ausführen, z. B. mit sudo." >&2
  exit 1
fi

echo "WARNUNG: Das entfernt lokale Automation, aber keine bestehenden Mastodon Domain-Blocks."
read -r -p "Fortfahren? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[YyJj]$ ]]; then
  echo "Abgebrochen."
  exit 0
fi

systemctl disable --now fediblockhole.timer 2>/dev/null || true
systemctl stop fediblockhole.service 2>/dev/null || true

rm -f /etc/systemd/system/fediblockhole.service
rm -f /etc/systemd/system/fediblockhole.timer
systemctl daemon-reload

rm -f /usr/local/bin/update-oliphant-fediblockhole.sh
rm -f /usr/local/bin/mastodon-promote-domain-blocks.py

read -r -p "Auch Konfiguration/Token unter /etc/fediblockhole* löschen? [y/N]: " delete_config
if [[ "$delete_config" =~ ^[YyJj]$ ]]; then
  rm -f /etc/fediblockhole.conf.toml
  rm -f /etc/fediblockhole.env
  rm -f /etc/fediblockhole-allowlist.csv
  rm -f /etc/fediblockhole-suspendlist.csv
fi

read -r -p "Auch Runtime-Daten unter /var/lib/fediblockhole und Logs löschen? [y/N]: " delete_data
if [[ "$delete_data" =~ ^[YyJj]$ ]]; then
  rm -rf /var/lib/fediblockhole
  rm -rf /var/log/fediblockhole
fi

read -r -p "Auch Systemuser fediblock und /opt/fediblockhole löschen? [y/N]: " delete_user
if [[ "$delete_user" =~ ^[YyJj]$ ]]; then
  userdel -r fediblock 2>/dev/null || true
  rm -rf /opt/fediblockhole
fi

echo "Deinstallation abgeschlossen."
