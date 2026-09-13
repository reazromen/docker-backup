# Docker-Backup mit Restic, Rclone und Gotify

[Deutsch](readme.de.md) | [English](readme.md)

![Lizenz: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![BS: Linux](https://img.shields.io/badge/OS-Linux-333?logo=linux)
![Shell: Bash](https://img.shields.io/badge/Shell-Bash-121011?logo=gnubash)
![Backup: Restic](https://img.shields.io/badge/Backup-Restic-ffcc00)
![Sync: Rclone](https://img.shields.io/badge/Sync-Rclone-3f79e8)
![Benachrichtigung: Gotify](https://img.shields.io/badge/Notify-Gotify-4caf50)

Automatisiertes Backup für einen Linux Docker-Host mit lokalen Snapshots, Restic-Deduplizierung und Remote-Upload via Rclone.

## Inhaltsverzeichnis

- [Features](#features)
- [Backup-Ablauf](#backup-ablauf)
- [Voraussetzungen](#voraussetzungen)
- [Verzeichnisstruktur](#verzeichnisstruktur)
- [Konfiguration](#konfiguration)
- [Skript-Verhalten](#skript-verhalten)
- [Ausgeschlossene Stacks](#ausgeschlossene-stacks)
- [systemd-Automatisierung](#systemd-automatisierung)
- [Manuelle Ausführung](#manuelle-ausführung)
- [Wiederherstellung (Restore)](#wiederherstellung-restore)
- [Wartung](#wartung)
- [Versionierung](#versionierung)
- [Zusätzliche Dokumentation](#zusätzliche-dokumentation)
- [Projektstatus](#projektstatus)

## Features

- Backup von Docker Compose Stacks (inklusive Volumes und Konfiguration)
- Unterstützung für Vaultwarden-Backups
- Nextcloud-Backup mit automatischer Maintenance-Mode-Steuerung
- MySQL / MariaDB Dump je Instanz (konfigurierbare Liste)
- Deduplizierte Offsite-Backups mit Restic
- Optionale Sekundär-Synchronisierung zu Internxt via Rclone
- Lokale Snapshot-Aufbewahrung (konfigurierbare Anzahl)
- Gotify-Benachrichtigungen für Start/Erfolg/Fehler/Überspringen
- Ausführungsprotokolle (Info + Fehler) werden in `./log/` geschrieben
- Tägliche Ausführung via `systemd` Timer
- Ausschluss von Infrastruktur-Stacks von Stop/Start-Operationen

## Backup-Ablauf

```text
Docker-Daten
  -> Staging (/srv/backups/current, fester Name)
  -> Restic-Backup (kritischer Satz, dann Vollsatz)
  -> Umbenennen nach /srv/backups/<zeitstempel>
  -> Rclone-Remote (z. B. rclone:1blu:restic-repo)
  -> Primärer Speicher (z. B. 1blu)
  -> [Optional] Sekundär-Sync zu Internxt
```

## Voraussetzungen

Benötigte Tools:

- `docker`
- `docker compose` (Plugin)
- `restic`
- `rclone`
- `curl`
- `gzip`
- `flock` (aus `util-linux`)
- `pv` (optional, für Fortschrittsanzeige beim Kopieren)

Beispiel-Installation (Debian/Ubuntu):

```bash
apt update
apt install -y docker.io docker-compose-plugin restic rclone curl util-linux pv
```

Für eine Schritt-für-Schritt-Einrichtung auf einem neuen System siehe die [Installationsanleitung](docs/install_requirements.md).

## Verzeichnisstruktur

```text
/srv/docker                        # Docker-Umgebung
/srv/backups                       # Ziel für lokale Snapshots
/opt/docker-backup/                # Projekt-Wurzelverzeichnis
/opt/docker-backup/.env            # Laufzeit-Konfiguration (Secrets, Restic-Passwort)
/opt/docker-backup/backup.conf     # Backup-Konfiguration (Pfade, Instanzen, Aufbewahrung)
/opt/docker-backup/log/            # Protokolle der Backup-Läufe
```

Beispiel-Snapshot:

```text
/srv/backups/2026-03-15_22-34
```

Waehrend eines Laufs liegen die Daten unter `/srv/backups/current`. Erst wenn
beide Restic-Laeufe fertig sind, wird dieses Verzeichnis in den datierten
Ordner umbenannt.

Der feste Name ist notwendig, nicht kosmetisch: Restic sucht den
Parent-Snapshot ueber Host und Pfad. Bei einem datierten Pfad gibt es nie
einen Vorgaenger, und jeder Lauf liest und hasht den kompletten Satz neu.
Dazu gehoeren `--ignore-inode --ignore-ctime`, weil das Staging jeden Lauf
frisch angelegt wird und Inode und ctime deshalb immer neu sind.

## Konfiguration

### 1) `.env` erstellen

Pfad: `/opt/docker-backup/.env`

Beispiel (siehe `.env.example` in diesem Repository):

```env
# MySQL-Zugangsdaten (werden als Standard für MYSQL_INSTANCES und Nextcloud genutzt)
MYSQL_USER=root
MYSQL_PASSWORD=CHANGEME

# Instanz-spezifische Passwörter, referenziert aus backup.conf
PROD_DB_PASSWORD=CHANGEME
NEXTCLOUD_DB_PASSWORD=CHANGEME

# Gotify-Benachrichtigungen
GOTIFY_URL=https://gotify.example.com/message
GOTIFY_TOKEN=ÄNDERMICH
GOTIFY_PRIORITY_SUCCESS=4
GOTIFY_PRIORITY_ERROR=8

# Restic / Rclone
RCLONE_CONFIG=/root/.config/rclone/rclone.conf
RESTIC_REPOSITORY=rclone:1blu:restic-repo
RESTIC_PASSWORD='DeinResticPasswort'
```

> Passwörter mit Sonderzeichen (z. B. `*`, `$`, `!`) sollten in einfache Anführungszeichen gesetzt werden.

### 2) `backup.conf` erstellen

Pfad: `/opt/docker-backup/backup.conf`

Vorlage: `backup.conf.example` (kopieren und für den eigenen Host anpassen).
Optional: `LOG_DIR` setzen (sonst Standard `<projekt-root>/log`).

Beispiel:

```bash
BACKUP_ROOT=/srv/backups
DOCKER_DIR=/srv/docker

# Aufbewahrung
RESTIC_TAG=docker-backup
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6
# Anzahl lokaler Snapshot-Verzeichnisse (0 = sofort nach Restic-Backup löschen)
KEEP_LOCAL_BACKUPS=1

# MySQL-Instanzen für Dump
# Format: "CONTAINER_NAME:USER:PASSWORT_ODER_VARIABLE:PORT"
# USER, PASSWORT, PORT sind optional und fallen auf MYSQL_DEFAULT_* / 3306 zurück
MYSQL_INSTANCES=(
  "mysql-prod:backup:PROD_DB_PASSWORD:3306"  # Variablenreferenz aus .env
  "mysql-dev:root:rootpass"                  # Klartext-Passwort
  "mysql-legacy"                             # Nutzt MYSQL_DEFAULT_*-Werte
)

EXCLUDED_STACK_DIRS=(
  "/srv/docker/infrastructure/gotify"
)
EXCLUDED_CONTAINER_NAMES=(
  "gotify"
)

# Internxt Sekundär-Sync (optional)
# Name des rclone-Remotes für Internxt (wie in rclone config konfiguriert)
INTERNXT_RCLONE_REMOTE="internxt-webdav"

# Nextcloud-spezifisches Backup (optional)
NEXTCLOUD_APP_CONTAINER="nextcloud-app"
NEXTCLOUD_DB_CONTAINER="nextcloud-db"
NEXTCLOUD_DB_USER="nextcloud"
NEXTCLOUD_DB_PASSWORD="${NEXTCLOUD_DB_PASSWORD}"  # Referenz auf .env
NEXTCLOUD_DB_NAME="nextcloud"
NEXTCLOUD_DATA_DIR="/srv/docker/nextcloud/data/nextcloud"
# Optional: Dump-Befehl überschreiben (ohne Angabe: automatische Erkennung mariadb-dump vs mysqldump)
# NEXTCLOUD_DB_DUMP_CMD=mariadb-dump
```

### 3) Restic-Repository initialisieren

Bevor du Restic nutzen kannst, musst du eine Verbindung zu deinem Remote-Speicher herstellen. Siehe dazu die [Rclone-Konfigurationsanleitung](docs/rclone_setup.md).

```bash
restic -r rclone:1blu:restic-repo init
```

Snapshots auflisten:

```bash
restic -r rclone:1blu:restic-repo snapshots
```

## Skript-Verhalten

Das Skript [`scripts/docker-backup.sh`](scripts/docker-backup.sh) führt folgende Schritte aus:

1. Erkennung aktiver Docker Compose Stacks
2. Ausführung des Vaultwarden-Backups
3. Erstellung der MySQL-Dumps (alle konfigurierten `MYSQL_INSTANCES`)
4. Nextcloud-Backup (Maintenance Mode an → DB-Dump → Daten-Sync → Maintenance Mode aus)
5. Stoppen aktiver Stacks (außer ausgeschlossene)
6. Kopieren der Docker-Verzeichnisse in den lokalen Snapshot
7. Ausführung des Restic-Backups zum Remote-Repository
8. Anwendung der Aufbewahrungsrichtlinie und Löschen alter Snapshots
9. [Optional] Sekundär-Sync des Restic-Repositories zu Internxt
10. Bereinigung alter lokaler Snapshots (behält `KEEP_LOCAL_BACKUPS` Verzeichnisse)
11. Neustart der zuvor aktiven Stacks
12. Senden der Ergebnisbenachrichtigung via Gotify
13. Schreiben des vollständigen Protokolls (stdout/stderr) nach `LOG_DIR/docker-backup-<zeitstempel>.log`

## Ausgeschlossene Stacks

Infrastruktur-Stacks können von den Stop/Start-Operationen ausgeschlossen werden.

Wichtig: Diese Ausschlüsse betreffen nur die Dienst-Orchestrierung während des Backups (`docker compose down/up`).
Daten werden dadurch nicht vom Backup ausgeschlossen. Das Skript kopiert weiterhin das gesamte `DOCKER_DIR`.

Ausschlüsse in `backup.conf` festlegen:

```bash
EXCLUDED_STACK_DIRS=(
  "/srv/docker/infrastructure/gotify"
  "/srv/docker/infrastructure/ntpserver"
)

EXCLUDED_CONTAINER_NAMES=(
  "gotify"
)
```

## systemd-Automatisierung

Beispielhafte Unit-Dateien in diesem Repository:

- [`systemd/docker-backup.service`](systemd/docker-backup.service)
- [`systemd/docker-backup.timer`](systemd/docker-backup.timer)

Diese nach `/etc/systemd/system/` kopieren und anschließend ausführen:

```bash
systemctl daemon-reload
systemctl enable --now docker-backup.timer
systemctl list-timers | grep docker-backup
```

Standard-Zeitplan im Timer:

```ini
OnCalendar=*-*-* 05:30:00
```

## Manuelle Ausführung

```bash
systemctl start docker-backup.service
journalctl -u docker-backup.service -f
```

## Wiederherstellung (Restore)

Detaillierte Anweisungen zur Wiederherstellung finden sich im Verzeichnis [`restore/`](restore/README.md) und im [Wiederherstellungs-Leitfaden](docs/restore.md).

Kurzübersicht:

```bash
cd restore
./restore.sh snapshots  # Snapshots auflisten
./restore.sh ls latest  # Inhalt des neuesten Snapshots zeigen
./restore.sh restore latest /mysql.sql.gz  # Einzelne Datei wiederherstellen
```

## Wartung

Repository prüfen:

```bash
restic -r rclone:1blu:restic-repo check
```

Statistiken anzeigen:

```bash
restic -r rclone:1blu:restic-repo stats
```

## Versionierung

Dieses Projekt verwendet [Semantic Versioning](https://semver.org/) (SemVer). Die aktuelle Version wird in der Datei `VERSION` im Wurzelverzeichnis des Projekts gespeichert.

### Release-Prozess

Um ein neues Release zu erstellen:
1. Die Datei `VERSION` mit der neuen Versionsnummer aktualisieren (z. B. `1.1.0`).
2. Die Änderung committen.
3. Einen Git-Tag erstellen:
   ```bash
   git tag -a v1.1.0 -m "Release version 1.1.0"
   ```
4. Den Tag pushen:
   ```bash
   git push origin v1.1.0
   ```

## Zusätzliche Dokumentation

- [Installationsanleitung](docs/install_requirements.md)
- [Rclone-Konfiguration](docs/rclone_setup.md)
- [Architektur](docs/architecture.md)
- [Wiederherstellungs-Leitfaden](docs/restore.md)
- [Fehlerbehebung](docs/troubleshooting.md)

## Projektstatus

- Status: Produktion (Production)
- Tägliches automatisiertes Backup um: `05:30`
- Primärer Speicher: `1blu` via `rclone`
- Sekundärer Speicher: `Internxt` via `rclone` (optionaler Sync)
- Benachrichtigungen: `Gotify`
