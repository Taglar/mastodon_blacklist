# Mastodon FediBlock Automation

-----------------------------------
 Disclaimer: Erstellt mit ChatGPT
 Läuft bei mir aktuell auf Ubuntu
-----------------------------------

Automatisierte, konservative Domain-Moderation für Mastodon mit:

- [FediBlockHole](https://github.com/eigenmagic/fediblockhole)
- Oliphant Tier-0 Blockliste als Quelle
- automatischer Header-Bereinigung für Oliphant CSV
- `max_severity = silence` als sichere Grundeinstellung
- optionaler lokaler Suspend-Override-Liste
- Pagination-fähigem Mastodon Admin API Script
- systemd Service + Timer

Das Ziel ist: **wenig Handarbeit, aber keine blinde harte Deföderation**.

## Was passiert technisch?

1. Die Oliphant-CSV wird heruntergeladen.
2. Der Header wird von `#domain,#severity,...` auf `domain,severity,...` bereinigt.
3. FediBlockHole importiert die Liste konservativ als `silence`.
4. Eine lokale Allowlist wird berücksichtigt.
5. Optional werden Domains aus `/etc/fediblockhole-suspendlist.csv` gezielt auf `suspend` hochgestuft.
6. systemd führt das täglich aus.

## Voraussetzungen

Getestet/gedacht für Debian/Ubuntu.

Benötigt:

- root/sudo
- Mastodon-Admin-Account
- Mastodon API Token mit Admin-Rechten

## Mastodon API Token erstellen

In Mastodon als Admin anmelden:

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

Alternativ zum Testen kannst du auch verwenden:

```text
admin:read
admin:write
```

Danach den **Access Token** kopieren. Der Installer fragt danach. Der Token wird lokal gespeichert unter:

```text
/etc/fediblockhole.env
```

Die Datei bekommt die Rechte `0640 root:fediblock`.

## Installation per curl

Wenn du das Projekt auf GitHub/Gitea/GitLab hochgeladen hast, kannst du den Installer so ausführen:

```bash
curl -fsSL https://raw.githubusercontent.com/Taglar/mastodon_blacklist/main/install.sh | sudo bash
```

Oder lokal aus dem geklonten Repository:

```bash
git clone https://github.com/Taglar/mastodon_blacklist.git
cd mastodon_blacklist
sudo ./install.sh
```

Der Installer fragt ab:

- Mastodon-Domain ohne `https://`, z. B. `talk.example.org`
- Mastodon Admin API Token
- tägliche Ausführungszeit für den systemd Timer, Standard `04:20:00`

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

## Dateien

### `/etc/fediblockhole.conf.toml`

FediBlockHole-Konfiguration. Standardmäßig wird Oliphant lokal als CSV eingebunden und auf `silence` begrenzt.

### `/etc/fediblockhole.env`

Enthält:

```bash
MASTODON_INSTANCE=talk.example.org
MASTODON_FEDIBLOCK_TOKEN=...
```

Diese Datei enthält ein Geheimnis. Nicht in Git committen.

### `/etc/fediblockhole-allowlist.csv`

Domains, die niemals automatisch blockiert werden sollen.

Format:

```csv
domain,severity
talk.example.org,noop
mastodon.social,noop
```

### `/etc/fediblockhole-suspendlist.csv`

Eigene lokale Liste für harte, explizit gewollte Suspend-Overrides.

Format:

```csv
domain,public_comment,private_comment
example-spam.tld,Spam/Abuse,Manuell als harte Spam-Instanz eingestuft
```

Wichtig: Diese Datei ist bewusst leer bzw. mit Beispiel-Kommentar vorbereitet. Trage nur Domains ein, die du wirklich hart suspendieren möchtest.

## Warum `silence` statt `suspend`?

`suspend` ist ein harter Eingriff. Bei falschen Blocklisten können Föderationsbeziehungen und Sichtbarkeit stärker beschädigt werden als nötig. Dieses Projekt setzt daher die große kuratierte Liste standardmäßig auf `silence` und erlaubt `suspend` nur über deine eigene lokale Trusted-Liste.

## Produktiver Ablauf

Der systemd-Service macht:

```text
ExecStartPre: Oliphant herunterladen und Header bereinigen
ExecStart:    FediBlockHole Sync
ExecStartPost: eigene Suspendliste mit Pagination anwenden
```

## Dry-Run

FediBlockHole:

```bash
sudo -u fediblock env $(sudo cat /etc/fediblockhole.env) \
  /opt/fediblockhole/venv/bin/fediblock-sync \
  -c /etc/fediblockhole.conf.toml \
  --dryrun
```

Suspend-Override-Script:

```bash
sudo -u fediblock DRYRUN=1 /usr/local/bin/mastodon-promote-domain-blocks.py
```

## Deinstallation

```bash
sudo ./uninstall.sh
```

Hinweis: Die Deinstallation entfernt die lokale Automation. Bereits in Mastodon angelegte Domain-Blocks werden nicht automatisch gelöscht.

## Sicherheitshinweise

- Den API Token niemals ins Git-Repo committen.
- Nach versehentlichem Veröffentlichen Token sofort in Mastodon widerrufen.
- Vor dem ersten produktiven Lauf Dry-Run ausführen.
- `suspend` nur über eigene, bewusst gepflegte Liste verwenden.

## Lizenz

MIT
