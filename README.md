# Mastodon FediBlock Automation

> Disclaimer: Dieses Projekt wurde mithilfe von ChatGPT erstellt und läuft aktuell auf Ubuntu.

Automatisierte, konservative Domain-Moderation für Mastodon.

Das Projekt nutzt:

- [FediBlockHole](https://github.com/eigenmagic/fediblockhole)
- die Oliphant Tier-0 Blockliste als Quelle
- automatische Header-Bereinigung für die Oliphant-CSV
- `max_severity = silence` als sichere Grundeinstellung
- eine optionale lokale Suspend-Override-Liste
- ein Pagination-fähiges Mastodon-Admin-API-Script
- systemd Service und Timer

Ziel: **möglichst wenig Handarbeit, aber keine blinde harte Deföderation.**

---

## Inhaltsverzeichnis

- [Was passiert technisch?](#was-passiert-technisch)
- [Verhalten bei Änderungen in der Quelle](#verhalten-bei-änderungen-in-der-quelle)
- [Voraussetzungen](#voraussetzungen)
- [Mastodon API Token erstellen](#mastodon-api-token-erstellen)
- [Installation per curl](#installation-per-curl)
- [Installation aus lokalem Repository](#installation-aus-lokalem-repository)
- [Nach der Installation](#nach-der-installation)
- [Wichtige Dateien](#wichtige-dateien)
- [Warum silence statt suspend?](#warum-silence-statt-suspend)
- [Produktiver Ablauf](#produktiver-ablauf)
- [Dry-Run](#dry-run)
- [Allowlist pflegen](#allowlist-pflegen)
- [Suspend-Override-Liste pflegen](#suspend-override-liste-pflegen)
- [Logs und Wartung](#logs-und-wartung)
- [Deinstallation](#deinstallation)
- [Sicherheitshinweise](#sicherheitshinweise)
- [Lizenz](#lizenz)

---

## Was passiert technisch?

1. Die Oliphant-CSV wird heruntergeladen.
2. Der CSV-Header wird von `#domain,#severity,...` auf `domain,severity,...` bereinigt.
3. FediBlockHole importiert die Liste konservativ als `silence`.
4. Eine lokale Allowlist wird berücksichtigt.
5. Optional werden Domains aus `/etc/fediblockhole-suspendlist.csv` gezielt auf `suspend` hochgestuft.
6. systemd führt den Ablauf täglich automatisch aus.

---

## Verhalten bei Änderungen in der Quelle

Neue Domains aus der Oliphant-Liste werden automatisch als `silence` hinzugefügt.

Domains, die aus der Oliphant-Liste herausfallen, werden **nicht automatisch** aus Mastodon gelöscht. Das ist bewusst konservativ, damit bei temporären Listenfehlern oder versehentlichen Änderungen nicht automatisch Domains entsperrt werden.

Die lokale Suspendliste ist ebenfalls additiv:

- neue Einträge werden auf `suspend` gesetzt
- entfernte Einträge werden nicht automatisch entsperrt
- bestehende manuelle Blocks in Mastodon bleiben erhalten

Ein späteres Report-/Cleanup-Script kann ergänzen, welche automatisch verwalteten Domains nicht mehr in der aktuellen Quelle stehen.

---

## Voraussetzungen

Getestet bzw. gedacht für Debian/Ubuntu.

Benötigt werden:

- root- oder sudo-Rechte
- ein Mastodon-Admin-Account
- ein Mastodon API Token mit Admin-Rechten
- ausgehender HTTPS-Zugriff auf GitHub/Raw-GitHub und die eigene Mastodon-Instanz

Der Installer installiert die benötigten Systempakete und FediBlockHole in ein eigenes Python-venv unter:

```text
/opt/fediblockhole/venv
```

---

## Mastodon API Token erstellen

In Mastodon als Admin anmelden und öffnen:

```text
Einstellungen -> Entwicklung -> Neue Anwendung
```

Name zum Beispiel:

```text
fediblockhole
```

Benötigte Scopes:

```text
admin:read
admin:read:domain_blocks
admin:write:domain_blocks
```

Alternativ kann zum Testen der breitere Scope `admin:write` verwendet werden. Empfohlen sind jedoch die engeren Scopes oben.

Danach den **Access Token** kopieren. Der Installer fragt danach.

Der Token wird lokal gespeichert unter:

```text
/etc/fediblockhole.env
```

Die Datei bekommt die Rechte:

```text
0640 root:fediblock
```

---

## Installation per curl

Installer direkt von GitHub ausführen:

```bash
curl -fsSL https://raw.githubusercontent.com/Taglar/mastodon_blacklist/main/install.sh | sudo bash
```

Der Installer fragt ab:

- Mastodon-Domain ohne `https://`, z. B. `talk.example.org`
- Mastodon Admin API Token
- tägliche Ausführungszeit für den systemd Timer, Standard `04:20:00`

---

## Installation aus lokalem Repository

```bash
git clone https://github.com/Taglar/mastodon_blacklist.git
cd mastodon_blacklist
sudo ./install.sh
```

---

## Nach der Installation

Timer prüfen:

```bash
systemctl list-timers | grep fediblockhole
```

Service manuell starten:

```bash
sudo systemctl start fediblockhole.service
```

Logs ansehen:

```bash
sudo journalctl -u fediblockhole.service -n 150 --no-pager
```

Gemergte Blockliste prüfen:

```bash
sudo -u fediblock wc -l /var/lib/fediblockhole/merged_blocklist.csv
sudo -u fediblock head -n 20 /var/lib/fediblockhole/merged_blocklist.csv
```

---

## Wichtige Dateien

### `/etc/fediblockhole.conf.toml`

FediBlockHole-Konfiguration.

Standardmäßig wird die lokal vorbereitete Oliphant-CSV eingebunden und auf `silence` begrenzt.

### `/etc/fediblockhole.env`

Enthält:

```bash
MASTODON_INSTANCE=talk.example.org
MASTODON_FEDIBLOCK_TOKEN=...
```

Diese Datei enthält ein Geheimnis und darf nicht in Git committed werden.

### `/etc/fediblockhole-allowlist.csv`

Domains, die niemals automatisch blockiert werden sollen.

Format:

```csv
domain,severity
talk.example.org,noop
mastodon.social,noop
```

Die eigene Instanz sollte immer in der Allowlist stehen.

### `/etc/fediblockhole-suspendlist.csv`

Eigene lokale Liste für harte, explizit gewollte Suspend-Overrides.

Format:

```csv
domain,public_comment,private_comment
example-spam.tld,Spam/Abuse,Manuell als harte Spam-Instanz eingestuft
```

Wichtig: Trage hier nur Domains ein, die du wirklich hart suspendieren möchtest.

### `/var/lib/fediblockhole/merged_blocklist.csv`

Von FediBlockHole erzeugte zusammengeführte Blockliste.

### `/var/log/fediblockhole/fediblockhole-audit.csv`

Audit-Datei von FediBlockHole.

---

## Warum `silence` statt `suspend`?

`suspend` ist ein harter Eingriff. Bei falschen oder zu weit gefassten Blocklisten können Föderationsbeziehungen und Sichtbarkeit stärker beschädigt werden als nötig.

Dieses Projekt setzt daher die große kuratierte Liste standardmäßig auf `silence` und erlaubt `suspend` nur über die eigene lokale Trusted-Liste.

Praktische Logik:

```text
Oliphant-Liste         -> maximal silence
eigene Suspendliste    -> gezielt suspend
Allowlist              -> niemals automatisch blockieren
```

---

## Produktiver Ablauf

Der systemd-Service macht:

```text
ExecStartPre:  Oliphant herunterladen und Header bereinigen
ExecStart:     FediBlockHole Sync
ExecStartPost: eigene Suspendliste mit Pagination anwenden
```

Der Timer startet den Service täglich zur angegebenen Uhrzeit mit zusätzlicher zufälliger Verzögerung.

---

## Dry-Run

FediBlockHole testen, ohne Änderungen zu schreiben:

```bash
sudo -u fediblock env $(sudo cat /etc/fediblockhole.env) \
  /opt/fediblockhole/venv/bin/fediblock-sync \
  -c /etc/fediblockhole.conf.toml \
  --dryrun
```

Suspend-Override-Script testen, ohne Änderungen zu schreiben:

```bash
sudo -u fediblock DRYRUN=1 /usr/local/bin/mastodon-promote-domain-blocks.py
```

---

## Allowlist pflegen

Allowlist öffnen:

```bash
sudo nano /etc/fediblockhole-allowlist.csv
```

Beispiel:

```csv
domain,severity
talk.example.org,noop
mastodon.social,noop
chaos.social,noop
```

Danach Service testen:

```bash
sudo systemctl start fediblockhole.service
sudo journalctl -u fediblockhole.service -n 150 --no-pager
```

---

## Suspend-Override-Liste pflegen

Suspendliste öffnen:

```bash
sudo nano /etc/fediblockhole-suspendlist.csv
```

Beispiel:

```csv
domain,public_comment,private_comment
example-spam.tld,Spam/Abuse,Manuell als harte Spam-Instanz eingestuft
```

Dry-Run:

```bash
sudo -u fediblock DRYRUN=1 /usr/local/bin/mastodon-promote-domain-blocks.py
```

Echter Lauf:

```bash
sudo -u fediblock /usr/local/bin/mastodon-promote-domain-blocks.py
```

Hinweis: Wenn du eine Domain aus der Suspendliste entfernst, wird sie nicht automatisch in Mastodon entsperrt.

---

## Logs und Wartung

Timerstatus:

```bash
systemctl list-timers | grep fediblockhole
```

Service-Status:

```bash
systemctl status fediblockhole.service
```

Letzte Logs:

```bash
sudo journalctl -u fediblockhole.service -n 150 --no-pager
```

Merged Blocklist prüfen:

```bash
sudo -u fediblock wc -l /var/lib/fediblockhole/merged_blocklist.csv
sudo -u fediblock head -n 20 /var/lib/fediblockhole/merged_blocklist.csv
```

Installierte systemd-Unit anzeigen:

```bash
systemctl cat fediblockhole.service
systemctl cat fediblockhole.timer
```

---

## Deinstallation

Aus dem Repository:

```bash
sudo ./uninstall.sh
```

Hinweis: Die Deinstallation entfernt die lokale Automation. Bereits in Mastodon angelegte Domain-Blocks werden nicht automatisch gelöscht.

---

## Sicherheitshinweise
- Vor dem ersten produktiven Lauf immer einen Dry-Run ausführen.
- `suspend` nur über eine bewusst gepflegte eigene Liste verwenden.
- Die eigene Mastodon-Instanz immer in die Allowlist aufnehmen.
- Automatisches Entsperren ist bewusst nicht enthalten.

---

## Lizenz

MIT
