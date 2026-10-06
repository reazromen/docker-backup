# Docker Backup with Restic, Rclone, and Gotify

[Deutsch](readme.de.md) | [English](readme.md)

![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![OS: Linux](https://img.shields.io/badge/OS-Linux-333?logo=linux)
![Shell: Bash](https://img.shields.io/badge/Shell-Bash-121011?logo=gnubash)
![Backup: Restic](https://img.shields.io/badge/Backup-Restic-ffcc00)
![Sync: Rclone](https://img.shields.io/badge/Sync-Rclone-3f79e8)
![Notify: Gotify](https://img.shields.io/badge/Notify-Gotify-4caf50)

Automated backup for a Linux Docker host using local snapshots, Restic deduplication, and remote upload via Rclone.

## Table of Contents

- [Features](#features)
- [Backup Flow](#backup-flow)
- [Requirements](#requirements)
- [Directory Layout](#directory-layout)
- [Configuration](#configuration)
- [Script Behavior](#script-behavior)
- [Excluded Stacks](#excluded-stacks)
- [systemd Automation](#systemd-automation)
- [Run Manually](#run-manually)
- [Restore](#restore)
- [Maintenance](#maintenance)
- [Versioning](#versioning)
- [Additional Documentation](#additional-documentation)
- [Project Status](#project-status)

## Features

- Backup of Docker Compose stacks (including volumes and config)
- Vaultwarden backup support
- Nextcloud backup with automatic maintenance mode handling
- MySQL / MariaDB dump per instance (configurable list)
- Deduplicated offsite backups with Restic
- Optional secondary sync to Internxt via Rclone
- Local snapshot retention (configurable count)
- Gotify notifications for start/success/error/skip
- Run logs (info + errors) written to `./log/`
- Daily execution via `systemd` timer
- Exclusion of infrastructure stacks from stop/start operations

## Backup Flow

```text
Docker data
  -> Staging (/srv/backups/current, stable name)
  -> Restic backup (critical set, then full set)
  -> Rename to /srv/backups/<timestamp>
  -> Rclone remote (e.g. rclone:1blu:restic-repo)
  -> Primary storage (e.g. 1blu)
  -> [Optional] Secondary sync to Internxt
```

## Requirements

Required tools:

- `docker`
- `docker compose` (plugin)
- `restic`
- `rclone`
- `curl`
- `gzip`
- `flock` (from `util-linux`)
- `pv` (optional, for copy progress display)

Example install (Debian/Ubuntu):

```bash
apt update
apt install -y docker.io docker-compose-plugin restic rclone curl util-linux pv
```

See [Installation Guide](docs/install_requirements.md) for a step-by-step setup on a fresh system.

## Directory Layout

```text
/srv/docker                        # Docker environment
/srv/backups                       # Local snapshot targets
/opt/docker-backup/                # Backup project root
/opt/docker-backup/.env            # Runtime configuration (secrets, Restic password)
/opt/docker-backup/backup.conf     # Backup configuration (paths, instances, retention)
/opt/docker-backup/log/            # Backup run logs
```

Example snapshot:

```text
/srv/backups/2026-03-15_22-34
```

During a run the data lives in `/srv/backups/current`. It is renamed to the
dated folder only once both restic runs have finished.

The stable name is required, not cosmetic: restic looks a parent snapshot up
by host and path, so a dated path never has a predecessor and every run
re-reads and re-hashes the whole set. `--ignore-inode --ignore-ctime` belong
with it, because the staging directory is recreated on every run and its
inodes and ctimes are therefore always new.

## Configuration

### 1) Create `.env`

Path: `/opt/docker-backup/.env`

Example (see `.env.example` in this repo):

```env
# MySQL credentials (used as defaults for MYSQL_INSTANCES and Nextcloud)
MYSQL_USER=root
MYSQL_PASSWORD=CHANGEME

# Per-instance passwords referenced from backup.conf
PROD_DB_PASSWORD=CHANGEME
NEXTCLOUD_DB_PASSWORD=CHANGEME

# Gotify notifications
GOTIFY_URL=https://gotify.example.com/message
GOTIFY_TOKEN=CHANGEME
GOTIFY_PRIORITY_SUCCESS=4
GOTIFY_PRIORITY_ERROR=8

# Restic / Rclone
RCLONE_CONFIG=/root/.config/rclone/rclone.conf
RESTIC_REPOSITORY=rclone:1blu:restic-repo
RESTIC_PASSWORD='YourResticPassword'
```

> Passwords containing special characters (e.g. `*`, `$`, `!`) should be wrapped in single quotes.

### 2) Create `backup.conf`

Path: `/opt/docker-backup/backup.conf`

Template: `backup.conf.example` (copy and adjust for your host).
Optional: set `LOG_DIR` (otherwise default is `<project-root>/log`).

Example:

```bash
BACKUP_ROOT=/srv/backups
DOCKER_DIR=/srv/docker

# Retention
RESTIC_TAG=docker-backup
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6
# Number of local snapshot directories to keep (0 = delete immediately after Restic backup)
KEEP_LOCAL_BACKUPS=1

# MySQL instances to dump
# Format: "CONTAINER_NAME:USER:PASSWORD_OR_VAR:PORT"
# USER, PASSWORD, PORT are optional and fall back to MYSQL_DEFAULT_* / 3306
MYSQL_INSTANCES=(
  "mysql-prod:backup:PROD_DB_PASSWORD:3306"  # references .env variable
  "mysql-dev:root:rootpass"                  # plaintext password
  "mysql-legacy"                             # uses MYSQL_DEFAULT_* values
)

EXCLUDED_STACK_DIRS=(
  "/srv/docker/infrastructure/gotify"
)
EXCLUDED_CONTAINER_NAMES=(
  "gotify"
)

# Internxt secondary sync (optional)
# Name of the rclone remote for Internxt (as configured with rclone config)
INTERNXT_RCLONE_REMOTE="internxt-webdav"

# Nextcloud-specific backup (optional)
NEXTCLOUD_APP_CONTAINER="nextcloud-app"
NEXTCLOUD_DB_CONTAINER="nextcloud-db"
NEXTCLOUD_DB_USER="nextcloud"
NEXTCLOUD_DB_PASSWORD="${NEXTCLOUD_DB_PASSWORD}"  # references .env
NEXTCLOUD_DB_NAME="nextcloud"
NEXTCLOUD_DATA_DIR="/srv/docker/nextcloud/data/nextcloud"
# Optional: override dump command (auto-detects mariadb-dump vs mysqldump if unset)
# NEXTCLOUD_DB_DUMP_CMD=mariadb-dump
```

### 3) Initialize the Restic repository

Before using Restic, configure your rclone remote. See the [Rclone Setup Guide](docs/rclone_setup.md).

```bash
restic -r rclone:1blu:restic-repo init
```

List snapshots:

```bash
restic -r rclone:1blu:restic-repo snapshots
```

## Script Behavior

The script [`scripts/docker-backup.sh`](scripts/docker-backup.sh) performs:

1. Detect active Docker Compose stacks
2. Run Vaultwarden backup
3. Create MySQL dumps (all configured `MYSQL_INSTANCES`)
4. Run Nextcloud backup (maintenance mode on → DB dump → data sync → maintenance mode off)
5. Stop active stacks (except excluded ones)
6. Copy Docker directories to local snapshot
7. Run Restic backup to remote repository
8. Apply retention policy and prune old snapshots
9. [Optional] Sync Restic repository to Internxt secondary remote
10. Clean up old local snapshots (keeps `KEEP_LOCAL_BACKUPS` directories)
11. Restart previously active stacks
12. Send result notification via Gotify
13. Write complete run log (stdout/stderr) to `LOG_DIR/docker-backup-<timestamp>.log`

## Excluded Stacks

Infrastructure stacks can be excluded from stop/start operations.

Important: These exclusions only affect service orchestration during backup (`docker compose down/up`).
They do not exclude data from backup content. The script still copies the full `DOCKER_DIR`.

Set exclusions in `backup.conf`:

```bash
EXCLUDED_STACK_DIRS=(
  "/srv/docker/infrastructure/gotify"
  "/srv/docker/infrastructure/ntpserver"
)

EXCLUDED_CONTAINER_NAMES=(
  "gotify"
)
```

## systemd Automation

Example unit files in this repository:

- [`systemd/docker-backup.service`](systemd/docker-backup.service)
- [`systemd/docker-backup.timer`](systemd/docker-backup.timer)

Copy them to `/etc/systemd/system/`, then run:

```bash
systemctl daemon-reload
systemctl enable --now docker-backup.timer
systemctl list-timers | grep docker-backup
```

Default schedule in timer:

```ini
OnCalendar=*-*-* 05:30:00
```

## Run Manually

```bash
systemctl start docker-backup.service
journalctl -u docker-backup.service -f
```

## Restore

See [`restore/README.md`](restore/README.md) and the [Restore Guide](docs/restore.md) for detailed instructions.

Quick overview:

```bash
cd restore
./restore.sh snapshots  # List snapshots
./restore.sh ls latest  # Show contents of latest snapshot
./restore.sh restore latest /mysql.sql.gz  # Restore a single file
```

## Maintenance

Check repository:

```bash
restic -r rclone:1blu:restic-repo check
```

Show stats:

```bash
restic -r rclone:1blu:restic-repo stats
```

## Versioning

This project uses [Semantic Versioning](https://semver.org/) (SemVer). The current version is stored in the `VERSION` file in the project root.

### Release Process

To create a new release:
1. Update the `VERSION` file with the new version number (e.g., `1.1.0`).
2. Commit the change.
3. Create a Git tag:
   ```bash
   git tag -a v1.1.0 -m "Release version 1.1.0"
   ```
4. Push the tag:
   ```bash
   git push origin v1.1.0
   ```

## Additional Documentation

- [Installation Guide](docs/install_requirements.md)
- [Rclone Setup](docs/rclone_setup.md)
- [Architecture](docs/architecture.md)
- [Restore Guide](docs/restore.md)
- [Troubleshooting](docs/troubleshooting.md)

## Project Status

- Status: production
- Daily automated backup at: `05:30`
- Primary storage: `1blu` via `rclone`
- Secondary storage: `Internxt` via `rclone` (optional sync)
- Notifications: `Gotify`


## Hugging Face Storage Bucket mirror

This fork adds an optional third-copy target for an already encrypted Restic
repository. Hugging Face Storage Buckets are accessed through their
S3-compatible endpoint with rclone. The primary backup remains independent;
the Hugging Face copy is best-effort and can be disabled by leaving
`HF_RCLONE_REMOTE` or `HF_BUCKET` empty.

See `docs/rclone_setup.md` for the rclone S3 configuration. Never commit Hugging
Face access keys or Restic passwords to Git.
