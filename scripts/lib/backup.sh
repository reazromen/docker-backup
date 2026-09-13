#!/bin/bash

# Legt das Staging-Verzeichnis frisch an.
#
# Muss VOR der Platzpruefung laufen: Bricht ein Lauf ab, bleibt der halbe
# Stand unter STAGING_DIR liegen. Wuerde erst geprueft und dann geraeumt,
# koennte ein einmal zu voller Datentraeger jeden weiteren Lauf blockieren.
backup_prepare_staging() {
    log "--- Staging vorbereiten ($STAGING_DIR) ---"

    # Schutzgurt vor dem rm -rf weiter unten: Waeren BACKUP_ROOT oder
    # STAGING_NAME leer, zeigte STAGING_DIR auf "/" oder "/current".
    # require_config_var deckt BACKUP_ROOT bereits ab; hier steht die
    # Pruefung unmittelbar neben dem loeschenden Befehl.
    if [ -z "${BACKUP_ROOT:-}" ] || [ -z "${STAGING_NAME:-}" ] ||
       [ "$STAGING_DIR" = "/" ] || [ "$STAGING_DIR" = "$BACKUP_ROOT" ]; then
        log "FEHLER: Unplausibler Staging-Pfad: '${STAGING_DIR:-<leer>}' - Abbruch."
        return 1
    fi

    if [ -d "$STAGING_DIR" ]; then
        log "Rest eines vorherigen Laufs gefunden - wird entfernt."
        rm -rf "$STAGING_DIR"
    fi

    mkdir -p "$STAGING_DIR"
}

# Benennt das Staging-Verzeichnis nach dem Lauf in den datierten Ordner um.
#
# Erst dadurch wird der Stand ein Archiv, das backup_cleanup_local anhand des
# Datums im Namen findet und nach KEEP_LOCAL_BACKUPS begrenzt. Das Umbenennen
# ist ein rename() im selben Dateisystem: atomar und ohne Kopieraufwand.
backup_archive_staging() {
    log "--- Staging archivieren nach $ARCHIVE_DIR ---"

    if [ ! -d "$STAGING_DIR" ]; then
        log "WARNUNG: $STAGING_DIR existiert nicht - nichts zu archivieren."
        return 0
    fi

    # Kann nur bei zwei Laeufen in derselben Minute auftreten; der flock im
    # Hauptskript schliesst das eigentlich aus. Ohne diese Pruefung wuerde mv
    # das Staging IN den vorhandenen Ordner hinein verschieben.
    if [ -e "$ARCHIVE_DIR" ]; then
        log "WARNUNG: $ARCHIVE_DIR existiert bereits - wird ersetzt."
        rm -rf "$ARCHIVE_DIR"
    fi

    mv "$STAGING_DIR" "$ARCHIVE_DIR"

    # Ab hier zeigt TARGET_DIR auf das Archiv, damit Groessenermittlung und
    # Gotify-Meldung im EXIT-Trap den richtigen Pfad nennen.
    TARGET_DIR="$ARCHIVE_DIR"
}

# Nutzt die Backup-Routine von VaultVarden und erzeugt einen DB-Dump.
# Erwartet, dass Vaultwarden als Docker Compose Projekt existiert.
backup_vaultwarden() {
    local vw_dir="$DOCKER_DIR/apps/vaultwarden"
    local vw_compose="$vw_dir/docker-compose.yml"

    log "--- Vaultwarden Backup ---"

    if [ -f "$vw_compose" ]; then
        mkdir -p "$vw_dir/backup"

        (
            flock -n 9 || {
                log "Vaultwarden-Backup laeuft bereits - ueberspringe manuellen Lauf"
                exit 0
            }

            docker compose -f "$vw_compose" run --rm --no-deps vaultwarden-backup manual
        ) 9>/tmp/vaultwarden-backup.lock

        mkdir -p "$TARGET_DIR/vaultwarden"
        cp -a "$vw_dir/backup/." "$TARGET_DIR/vaultwarden/"
    else
        log "Vaultwarden Compose-Datei nicht gefunden - ueberspringe Vaultwarden-Backup"
    fi
}

# Ermittelt den freien Speicherplatz am angegebenen Pfad
get_free_space_local() {
    local path="$1"
    df -h "$path" | awk 'NR==2 {print $4}'
}

# Ermittelt den freien Speicherplatz auf dem Rclone-Remote
get_free_space_rclone() {
    local remote="$1"
    # Extrahiere den Remote-Namen aus restic-Stil "rclone:remote:path"
    local rclone_remote
    rclone_remote=$(echo "$remote" | sed 's/^rclone://;s/:.*$//')

    if [ -n "$rclone_remote" ]; then
        rclone about "${rclone_remote}:" --json 2>/dev/null | grep -o '"free":[0-9]*' | grep -o '[0-9]*' | awk '{ sum=$1 ; hum[1024**4]="TB";hum[1024**3]="GB";hum[1024**2]="MB";hum[1024]="KB"; for (x=1024**4; x>=1024; x/=1024){ if (sum>=x) { printf "%.2f %s\n",sum/x,hum[x]; break } } if (sum<1024) print sum " B" }' || echo "unbekannt"
    else
        echo "unbekannt"
    fi
}

# Erstellt einen MySQL-Dump für einen bestimmten Container.
# Parameter:
#   $1: Container-Name
#   $2: MySQL-Benutzer
#   $3: MySQL-Passwort
#   $4: Port (Standard: 3306)
#   $5: Zieldatei (Pfad zur .sql.gz)
do_mysql_dump() {
    local container="$1"
    local user="$2"
    local pass="$3"
    local port="${4:-3306}"
    local target_file="$5"

    # Wenn 'pass' der Name einer gesetzten Variable ist, nutze deren Wert (Indirektion)
    local actual_pass="$pass"
    if [[ -n "${!pass:-}" ]]; then
        actual_pass="${!pass}"
    fi

    log "Sichere Instanz: $container (Port: $port) nach $target_file..."

    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        mkdir -p "$(dirname "$target_file")"
        if docker exec "$container" \
            mysqldump \
            -u "$user" \
            -p"$pass" \
            --port="$port" \
            --all-databases \
            --single-transaction \
            --quick \
            --lock-tables=false \
            | gzip > "$target_file"; then
            log "Dump erfolgreich erstellt: $target_file"
            return 0
        else
            log "FEHLER: MySQL Dump fuer $container fehlgeschlagen."
            return 1
        fi
    else
        log "WARNUNG: Container $container nicht gefunden oder laeuft nicht - ueberspringe."
        return 1
    fi
}

# Iteriert ueber alle konfigurierten MySQL-Instanzen in MYSQL_INSTANCES
# und erstellt jeweils einen Dump.
backup_mysql_dump() {
    log "--- MySQL Multi-Dump gestartet ---"

    if [ "${#MYSQL_INSTANCES[@]}" -eq 0 ]; then
        log "Keine MySQL-Instanzen zur Sicherung konfiguriert."
        return 0
    fi

    for entry in "${MYSQL_INSTANCES[@]}"; do
        # Splitten des Eintrags (Format: container:user:pass:port)
        local IFS=':'
        read -r c_name c_user c_pass c_port <<< "$entry"
        IFS=$' \t\n' # IFS zuruecksetzen

        # Fallback auf Standardwerte falls Felder leer sind
        local container="${c_name}"
        local user="${c_user:-$MYSQL_DEFAULT_USER}"
        local pass="${c_pass:-$MYSQL_DEFAULT_PASSWORD}"
        local port="${c_port:-3306}"
        
        if [ -n "$container" ]; then
            local target="$TARGET_DIR/mysql/${container}.sql.gz"
            do_mysql_dump "$container" "$user" "$pass" "$port" "$target" || true
        else
            log "WARNUNG: Ungueltiger MySQL-Eintrag (Container-Name fehlt) - ueberspringe."
        fi
    done
}

# Kopiert die konfigurierten Docker-Verzeichnisse (DOCKER_DIR) in das Zielverzeichnis.
# Nutzt 'pv' fuer eine Fortschrittsanzeige, falls installiert.
backup_copy_docker_dirs() {
    log "--- Kopiere Docker-Verzeichnisse ---"
    mkdir -p "$TARGET_DIR/docker"

    if command -v pv >/dev/null 2>&1; then
        log "Kopiere mit Fortschrittsanzeige (pv)"
        local copy_size_bytes
        copy_size_bytes="$(du -sb "$DOCKER_DIR" 2>/dev/null | awk '{print $1}')"

        if [ -n "${copy_size_bytes:-}" ]; then
            tar -C "$DOCKER_DIR" -cf - . \
                | pv -f -pterb -s "$copy_size_bytes" \
                | tar -C "$TARGET_DIR/docker" -xpf -
        else
            tar -C "$DOCKER_DIR" -cf - . \
                | pv -f -pterb \
                | tar -C "$TARGET_DIR/docker" -xpf -
        fi
    else
        log "pv nicht gefunden, kopiere ohne Fortschrittsanzeige"
        cp -a "$DOCKER_DIR/." "$TARGET_DIR/docker/"
    fi
}

# Fuehrt das Restic-Backup fuer das gesamte Zielverzeichnis aus.
backup_run_restic() {
    log "--- Restic Backup ---"
    
    # Entferne evtl. vorhandene verwaiste Locks
    restic -r "$RESTIC_REPOSITORY" "${RESTIC_AUTH_ARGS[@]}" unlock || log "WARNUNG: Restic-Unlock fehlgeschlagen."

    # --ignore-inode und --ignore-ctime sind hier zwingend, nicht optional:
    # Das Staging wird bei jedem Lauf frisch per tar entpackt, Inode und
    # ctime sind daher immer neu. Ohne diese Schalter findet restic zwar
    # dank des stabilen Pfades den Parent, meldet aber trotzdem jede Datei
    # als "changed" und liest den gesamten Satz erneut - der stabile Pfad
    # allein bringt dann nichts. Nachgemessen mit einem Testrepository:
    #   stabiler Pfad allein            -> 200 changed
    #   stabiler Pfad + diese Schalter  -> 200 unmodified
    # Erkauft wird das damit, dass eine Aenderung ohne neue mtime und ohne
    # neue Groesse uebersehen wuerde. Da beides aus dem Quelldateisystem
    # stammt, faellt das hier nicht ins Gewicht.
    #
    # --group-by host,paths,tags nimmt den Tag in die Parent-Suche auf.
    # Seit beide Laeufe denselben stabilen Pfad sichern, unterscheidet nur
    # noch der Tag den vollen vom kritischen Satz. Zeigten beide Variablen
    # versehentlich auf dasselbe Repository, wuerde sonst der jeweils andere
    # Satz als Parent herangezogen.
    restic -r "$RESTIC_REPOSITORY" \
        "${RESTIC_AUTH_ARGS[@]}" \
        backup "$TARGET_DIR" \
        --tag "$RESTIC_TAG" \
        --group-by host,paths,tags \
        --ignore-inode \
        --ignore-ctime \
        --verbose
}

# Bereinigt alte Snapshots im Restic-Repository basierend auf der Retention-Policy.
#
# WICHTIG: --group-by host,tags ist zwingend.
# restic gruppiert per Default nach "host,paths". Da TARGET_DIR das Datum
# enthaelt (/srv/backups/YYYY-MM-DD_HH-MM), ist der Pfad bei jedem Lauf ein
# anderer - jeder Snapshot landete dadurch in einer eigenen Gruppe und war
# darin gleichzeitig der juengste taegliche, woechentliche UND monatliche
# Snapshot. Es wurde nie etwas geloescht: Das Repository wuchs unbegrenzt,
# bis das Remote-Kontingent mit 507 Insufficient Storage dichtmachte.
# Mit der Gruppierung nach Tag greift die Retention wie beabsichtigt.
backup_prune_restic() {
    log "--- Restic Aufraeumen ---"

    # Entferne evtl. vorhandene verwaiste Locks (besonders wichtig vor --prune)
    restic -r "$RESTIC_REPOSITORY" "${RESTIC_AUTH_ARGS[@]}" unlock || log "WARNUNG: Restic-Unlock fehlgeschlagen."

    restic -r "$RESTIC_REPOSITORY" \
        "${RESTIC_AUTH_ARGS[@]}" \
        forget --group-by host,tags --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" --prune
}

# Sichert nur den KRITISCHEN Satz in ein zweites, kleines Repository.
#
# Hintergrund: Das Haupt-Repository enthaelt eine Vollkopie von DOCKER_DIR.
# Davon entfallen rund 20 von 23 GB allein auf Nextcloud-Nutzerdaten, die
# unbegrenzt wachsen koennen. Auf einem kontingentierten Ziel verdraengen sie
# damit genau das, was am wichtigsten ist - im August 2026 fiel deshalb auch
# Vaultwarden aus dem Backup, als das Kontingent erschoepft war.
#
# Dieses Repository nimmt deshalb nur das Unverzichtbare auf: Vaultwarden,
# Datenbank-Dumps und Container-Konfigurationen. Was ausgeschlossen wird,
# steht in CRITICAL_EXCLUDES.
#
# Das Repository muss einmalig angelegt werden:
#   restic -r "$RESTIC_REPOSITORY_CRITICAL" init
backup_run_restic_critical() {
    if [ -z "${RESTIC_REPOSITORY_CRITICAL:-}" ]; then
        log "Kein kritisches Repository konfiguriert (RESTIC_REPOSITORY_CRITICAL) - uebersprungen."
        return 0
    fi

    if [ ! -f "${CRITICAL_EXCLUDES:-}" ]; then
        CRITICAL_FAILED=1
        log "FEHLER: Ausschlussliste nicht gefunden: ${CRITICAL_EXCLUDES:-<leer>}"
        log "        Der kritische Satz wird uebersprungen, der Lauf geht weiter."
        return 0
    fi

    log "--- Restic Backup: kritischer Satz ---"
    log "Ziel: $RESTIC_REPOSITORY_CRITICAL"

    local ropts=("-r" "$RESTIC_REPOSITORY_CRITICAL" "${RESTIC_AUTH_ARGS[@]}")

    restic "${ropts[@]}" unlock || log "WARNUNG: Restic-Unlock (kritisch) fehlgeschlagen."

    # Auch hier gilt: erst aufraeumen, dann schreiben - siehe backup_prune_restic.
    restic "${ropts[@]}" forget --group-by host,tags --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" --prune || log "WARNUNG: Aufraeumen des kritischen Repositories fehlgeschlagen."

    # Siehe backup_run_restic zur Begruendung von --ignore-inode/--ignore-ctime.
    #
    # Ein Fehlschlag hier darf das grosse Backup NICHT verhindern. Vorher
    # waere der Lauf durch "set -e" an dieser Stelle abgebrochen: Ein nicht
    # erreichbares kleines Ziel haette damit auch das Hetzner-Backup
    # gekostet - genau andersherum als beabsichtigt. Der Fehlschlag wird
    # stattdessen vermerkt und am Ende des Laufs als Fehler gemeldet.
    if ! restic "${ropts[@]}" backup "$TARGET_DIR" \
            --exclude-file "$CRITICAL_EXCLUDES" \
            --tag "$RESTIC_TAG_CRITICAL" \
            --group-by host,paths,tags \
            --ignore-inode \
            --ignore-ctime; then
        CRITICAL_FAILED=1
        log "FEHLER: Backup des kritischen Satzes fehlgeschlagen - der Lauf wird fortgesetzt."
        return 0
    fi
}

# Bereinigt alte lokale Backup-Ordner in BACKUP_ROOT.
# Behaelt die Anzahl der Ordner gemäss KEEP_LOCAL_BACKUPS.
backup_cleanup_local() {
    log "--- Lokales Aufraeumen ($BACKUP_ROOT) ---"

    # Sicherstellen, dass BACKUP_ROOT existiert
    if [ ! -d "$BACKUP_ROOT" ]; then
        log "WARNUNG: BACKUP_ROOT ($BACKUP_ROOT) existiert nicht. Ueberspringe lokale Bereinigung."
        return 0
    fi

    # Finde alle Verzeichnisse im Format YYYY-MM-DD_HH-MM
    # Sortiere sie (älteste zuerst) und behalte nur die letzten N
    local dirs
    dirs=$(find "$BACKUP_ROOT" -maxdepth 1 -type d -regextype posix-extended -regex ".*/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}$" | sort)

    local count
    count=$(echo "$dirs" | grep -c "^" || echo 0)

    if [ "$count" -le "$KEEP_LOCAL_BACKUPS" ]; then
        log "Keine alten lokalen Backups zum Loeschen (Vorhanden: $count, Behalten: $KEEP_LOCAL_BACKUPS)."
        return 0
    fi

    local to_delete_count=$((count - KEEP_LOCAL_BACKUPS))
    log "Loesche $to_delete_count alte lokale Backups..."

    echo "$dirs" | head -n "$to_delete_count" | while read -r dir; do
        if [ -d "$dir" ]; then
            log "Entferne altes lokales Backup: $dir"
            rm -rf "$dir"
        fi
    done
}

backup_sync_to_internxt() {
  log "--- Sync Restic-Repo zu Internxt ---"

  # Prüfen ob internxt-Remote erreichbar ist
  if ! rclone lsd "${INTERNXT_RCLONE_REMOTE}:" \
       --no-check-certificate \
       --contimeout 10s \
       --timeout 30s \
       &>/dev/null; then
    log "WARNUNG: Internxt-WebDAV nicht erreichbar – Sync übersprungen"
    return 0
  fi

  rclone sync \
    "$(echo "${RESTIC_REPOSITORY}" | sed 's|rclone:||')" \
    "${INTERNXT_RCLONE_REMOTE}:restic-repo" \
    --no-check-certificate \
    --transfers 3 \
    --tpslimit 4 \
    --retries 5 \
    --log-file "${LOG_DIR}/rclone-internxt-$(date +%F).log" \
    --log-level INFO \
    || log "WARNUNG: Internxt-Sync fehlgeschlagen – primäres Backup (1blu) ist OK"

  log "--- Internxt Sync abgeschlossen ---"
}