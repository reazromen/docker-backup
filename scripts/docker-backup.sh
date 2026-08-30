#!/bin/bash
set -Eeuo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ENV_FILE="/opt/docker-backup/.env"
CONFIG_FILE="/opt/docker-backup/backup.conf"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Version laden
APP_VERSION="unknown"
if [ -f "$ROOT_DIR/VERSION" ]; then
    APP_VERSION="$(cat "$ROOT_DIR/VERSION")"
fi

if [ "$(basename "$SCRIPT_DIR")" = "scripts" ]; then
    DEFAULT_LOG_DIR="$ROOT_DIR/log"
else
    DEFAULT_LOG_DIR="$SCRIPT_DIR/log"
fi

# shellcheck disable=SC1090
source "$LIB_DIR/common.sh"
# shellcheck disable=SC1090
source "$LIB_DIR/config.sh"
# shellcheck disable=SC1090
source "$LIB_DIR/docker.sh"
# shellcheck disable=SC1090
source "$LIB_DIR/backup.sh"
# shellcheck disable=SC1090
source "$LIB_DIR/nextcloud.sh"

LOCK_FILE="/var/lock/docker-backup.lock"
BACKUP_OK=0
START_TS="$(date +%s)"
START_TIME="$(date '+%F %T')"
HOSTNAME="$(hostname -f 2>/dev/null || hostname)"

cleanup() {
    local exit_code=$?
    local end_ts end_time duration backup_size

    end_ts="$(date +%s)"
    end_time="$(date '+%F %T')"
    duration="$(format_duration $((end_ts - START_TS)))"

    docker_restart_stacks_from_file "$ACTIVE_STACKS_STATE_FILE"

    # Sicherheitsnetz: Der Nextcloud-Wartungsmodus darf niemals aktiv
    # zurueckbleiben - sonst ist Nextcloud nach einem Abbruch offline.
    nextcloud_ensure_maintenance_off

    # Lokale Snapshot-Ordner IMMER begrenzen, auch nach einem Abbruch.
    # Vorher stand dieser Aufruf nur am Ende des Hauptlaufs. Scheiterte ein
    # Schritt davor, blieb bei jedem Lauf ein vollstaendiger Ordner liegen,
    # bis BACKUP_ROOT volllief - und der naechste Lauf scheiterte frueher.
    backup_cleanup_local || log "WARNUNG: Lokales Aufraeumen fehlgeschlagen."

    if [ "$exit_code" -eq 0 ] && [ "$BACKUP_OK" -eq 1 ]; then
        if [ -f "$ACTIVE_STACKS_STATE_FILE" ]; then
            rm -f "$ACTIVE_STACKS_STATE_FILE"
        fi
        backup_size="$(du -sh "$TARGET_DIR" 2>/dev/null | awk '{print $1}')" || backup_size="unbekannt"
        free_local="$(get_free_space_local "$BACKUP_ROOT")" || free_local="unbekannt"
        free_remote="$(get_free_space_rclone "$RESTIC_REPOSITORY")" || free_remote="unbekannt"

        send_gotify \
            "Backup erfolgreich (v$APP_VERSION)" \
            "Host: $HOSTNAME
Start: $START_TIME
Ende: $end_time
Dauer: $duration
Lokales Ziel: $TARGET_DIR
Groesse: ${backup_size:-unbekannt}
Frei (Lokal): ${free_local:-unbekannt}
Frei (Remote): ${free_remote:-unbekannt}
Restic: $RESTIC_REPOSITORY" \
            "${GOTIFY_PRIORITY_SUCCESS:-4}"
        log "=== Backup abgeschlossen: $DATE ==="
    else
        free_local="$(get_free_space_local "$BACKUP_ROOT")" || free_local="unbekannt"
        send_gotify \
            "Backup FEHLER" \
            "Host: $HOSTNAME
Start: $START_TIME
Fehlerzeit: $end_time
Dauer bis Fehler: $duration
Letztes lokales Ziel: $TARGET_DIR
Frei (Lokal): ${free_local:-unbekannt}
Bitte Journal/Log pruefen." \
            "${GOTIFY_PRIORITY_ERROR:-8}"
        log "=== Backup fehlgeschlagen: $DATE ==="
    fi
}

load_configuration
init_logging

trap on_error ERR
trap cleanup EXIT

exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log "Ein anderes Backup laeuft bereits - Abbruch"
    send_gotify \
        "Backup uebersprungen" \
        "Host: $HOSTNAME
Start: $START_TIME
Grund: Es laeuft bereits ein anderes Backup." \
        "${GOTIFY_PRIORITY_ERROR:-8}"
    exit 1
fi

    send_gotify \
    "Backup gestartet (v$APP_VERSION)" \
    "Host: $HOSTNAME
Start: $START_TIME
Ziel: $TARGET_DIR" \
    "${GOTIFY_PRIORITY_SUCCESS:-4}"

# --- Vorabpruefung: genuegend lokaler Speicher vorhanden? ---
# Bricht ab, BEVOR halb fertige Daten geschrieben werden. Der EXIT-Trap
# raeumt danach alte Ordner ab, sodass der naechste Lauf wieder Platz hat.
FREE_LOCAL_MB="$(df -Pm "$BACKUP_ROOT" 2>/dev/null | awk 'NR==2{print $4}')"
if [ "${MIN_FREE_LOCAL_MB:-0}" -gt 0 ] && [ -n "${FREE_LOCAL_MB:-}" ]; then
    if [ "$FREE_LOCAL_MB" -lt "$MIN_FREE_LOCAL_MB" ]; then
        log "FEHLER: Zu wenig freier Speicher in $BACKUP_ROOT (${FREE_LOCAL_MB} MB frei, mindestens ${MIN_FREE_LOCAL_MB} MB noetig) - Abbruch vor dem Kopieren."
        exit 1
    fi
    log "Freier Speicher in $BACKUP_ROOT: ${FREE_LOCAL_MB} MB (Minimum: ${MIN_FREE_LOCAL_MB} MB)"
fi

mkdir -p "$TARGET_DIR"

log "=== Backup gestartet: $DATE (Version: $APP_VERSION) ==="

log "--- Erfasse aktive Docker Compose Projekte ---"
ACTIVE_STACK_DIRS="$(docker_detect_active_stack_dirs)"
printf '%s\n' "$ACTIVE_STACK_DIRS" > "$ACTIVE_STACKS_STATE_FILE"

log "Aktive Stacks:"
cat "$ACTIVE_STACKS_STATE_FILE"
echo

backup_vaultwarden
backup_mysql_dump
backup_nextcloud
docker_stop_stacks_from_file "$ACTIVE_STACKS_STATE_FILE"
backup_copy_docker_dirs

# Der kritische Satz zuerst: klein, schnell und am wichtigsten. Scheitert
# danach das grosse Backup, ist das Unverzichtbare bereits gesichert.
backup_run_restic_critical

# Erst aufraeumen, dann schreiben: Auf einem kontingentierten Remote muss
# Platz frei sein, BEVOR restic neue Bloecke ablegt. Lief prune erst nach
# dem Backup, konnte sich ein volles Repository nie selbst befreien
# (507 Insufficient Storage -> Abbruch -> prune wurde nie erreicht).
backup_prune_restic
backup_run_restic
backup_sync_to_internxt

# backup_cleanup_local laeuft jetzt im EXIT-Trap (siehe cleanup()),
# damit es auch bei einem Abbruch garantiert ausgefuehrt wird.


BACKUP_OK=1
