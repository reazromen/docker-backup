#!/bin/bash

require_config_var() {
    local var_name="$1"

    if [ -z "${!var_name:-}" ]; then
        echo "Pflichtwert fehlt in Konfiguration: $var_name"
        return 1
    fi
}

load_configuration() {
    if [ -f "$ENV_FILE" ]; then
        set -a
        # shellcheck disable=SC1090
        source "$ENV_FILE"
        set +a
    else
        echo "ENV-Datei nicht gefunden: $ENV_FILE"
        return 1
    fi

    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    else
        echo "Config-Datei nicht gefunden: $CONFIG_FILE"
        return 1
    fi

    # Arrays initialisieren, falls nicht in backup.conf definiert
    if [ "${#EXCLUDED_STACK_DIRS[@]}" -eq 0 ]; then
        EXCLUDED_STACK_DIRS=()
    fi
    if [ "${#EXCLUDED_CONTAINER_NAMES[@]}" -eq 0 ]; then
        EXCLUDED_CONTAINER_NAMES=()
    fi
    
    # MySQL-Konfiguration initialisieren
    if [ "${#MYSQL_INSTANCES[@]}" -eq 0 ]; then
        if [ -n "${MYSQL_CONTAINER:-}" ]; then
            # Abwaertskompatibilitaet: Falls MYSQL_CONTAINER gesetzt ist, 
            # konvertiere es in das neue Array-Format
            MYSQL_INSTANCES=("$MYSQL_CONTAINER:${MYSQL_USER:-}:${MYSQL_PASSWORD:-}:3306")
        else
            MYSQL_INSTANCES=()
        fi
    fi
    
    # Standardwerte fuer MySQL-User und Passwort
    MYSQL_DEFAULT_USER="${MYSQL_DEFAULT_USER:-${MYSQL_USER:-backup}}"
    MYSQL_DEFAULT_PASSWORD="${MYSQL_DEFAULT_PASSWORD:-${MYSQL_PASSWORD:-}}"

    RESTIC_TAG="${RESTIC_TAG:-docker-backup}"
    KEEP_DAILY="${KEEP_DAILY:-7}"
    KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
    KEEP_MONTHLY="${KEEP_MONTHLY:-6}"
    # Wie viele lokale Snapshot-Ordner in BACKUP_ROOT aufbewahrt werden sollen (standard: 1)
    KEEP_LOCAL_BACKUPS="${KEEP_LOCAL_BACKUPS:-1}"
    # Mindestens noetiger freier Speicher in BACKUP_ROOT (in MB).
    # Wird das unterschritten, bricht der Lauf sofort ab, statt die Platte
    # vollzuschreiben. 0 deaktiviert die Pruefung.
    MIN_FREE_LOCAL_MB="${MIN_FREE_LOCAL_MB:-51200}"

    require_config_var "BACKUP_ROOT" || return 1
    require_config_var "DOCKER_DIR" || return 1

    RESTIC_AUTH_ARGS=()
    if [ -n "${RESTIC_PASSWORD:-}" ]; then
        # RESTIC_PASSWORD ist gesetzt (vorzugsweise in .env)
        # Restic nutzt diese Variable automatisch, wenn sie exportiert ist.
        # Da wir 'set -a' beim Laden der .env nutzen, ist sie bereits exportiert.
        RESTIC_AUTH_ARGS=()
    elif [ -n "${RESTIC_PASSWORD_FILE:-}" ]; then
        RESTIC_AUTH_ARGS=(--password-file "$RESTIC_PASSWORD_FILE")
    else
        echo "Restic Passwort fehlt: Bitte RESTIC_PASSWORD (.env) oder RESTIC_PASSWORD_FILE (backup.conf) setzen."
        return 1
    fi

    DATE="$(date +%F_%H-%M)"
    TARGET_DIR="$BACKUP_ROOT/$DATE"
    LOG_DIR="${LOG_DIR:-$DEFAULT_LOG_DIR}"
    LOG_FILE="$LOG_DIR/docker-backup-$DATE.log"

    export RCLONE_CONFIG="${RCLONE_CONFIG:-/home/matthi/.config/rclone/rclone.conf}"
    export RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-rclone:1blu:restic-repo}"
    
    # Datei für den Status der aktiven Stacks
    ACTIVE_STACKS_STATE_FILE="${ACTIVE_STACKS_STATE_FILE:-$ROOT_DIR/.active_stacks}"
}
