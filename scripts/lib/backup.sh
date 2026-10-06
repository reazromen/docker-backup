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
    #
    # STAGING_NAME muss ausserdem ein einzelner Verzeichnisname sein. Ein
    # Wert wie "../docker" kaeme sonst durch und das rm -rf traefe
    # /srv/docker - ein reiner Zeichenkettenvergleich gegen BACKUP_ROOT
    # faengt das nicht ab.
    if [ -z "${BACKUP_ROOT:-}" ] || [ -z "${STAGING_NAME:-}" ] ||
       [ "$STAGING_DIR" = "/" ] || [ "$STAGING_DIR" = "$BACKUP_ROOT" ]; then
        log "FEHLER: Unplausibler Staging-Pfad: '${STAGING_DIR:-<leer>}' - Abbruch."
        return 1
    fi

    case "$STAGING_NAME" in
        */*|.|..)
            log "FEHLER: STAGING_NAME muss ein einzelner Verzeichnisname sein, ist aber '$STAGING_NAME' - Abbruch."
            return 1
            ;;
    esac

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

    # Zweiter loeschender Befehl, also derselbe Schutzgurt wie in
    # backup_prepare_staging. Waere DATE leer, zeigte ARCHIVE_DIR auf
    # BACKUP_ROOT selbst - das rm -rf unten raeumte dann saemtliche lokalen
    # Staende ab. Nicht wahrscheinlich, aber der Schaden waere vollstaendig.
    if [ -z "${DATE:-}" ] || [ "$ARCHIVE_DIR" = "$BACKUP_ROOT" ] ||
       [ "$ARCHIVE_DIR" = "$BACKUP_ROOT/" ] || [ "$ARCHIVE_DIR" = "/" ]; then
        log "FEHLER: Unplausibler Archivpfad: '${ARCHIVE_DIR:-<leer>}' - Staging bleibt liegen."
        return 1
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
#
# Die Exitcodes der Pipeline werden EINZELN bewertet, statt sie von
# 'set -o pipefail' pauschal als Fehler behandeln zu lassen. Grund: GNU tar
# unterscheidet
#
#   0  alles gelesen
#   1  "Some files differ" - eine Datei hat sich waehrend des Lesens
#      geaendert; das Archiv ist bis auf diese Datei vollstaendig
#   2  fataler Fehler (Quelle fehlt, Medium defekt, kein Platz)
#
# und in DOCKER_DIR laufen Datenbanken weiter: nextcloud-db und
# nextcloud-redis stehen in EXCLUDED_CONTAINER_NAMES und werden deshalb
# absichtlich nicht gestoppt. Ihre Dateien werden also permanent
# beschrieben. In der Nacht auf den 14.09.2026 hat das den ganzen Lauf
# gekippt:
#
#   tar: ./apps/nextcloud/data/redis/appendonlydir/appendonly.aof.10.incr.aof:
#        file changed as we read it
#   tar: ./apps/nextcloud/data/db/ib_logfile0: file changed as we read it
#
# Damit war ein Backup wegen zweier Dateien verloren, die in dieser Form
# ohnehin wertlos sind - eine Dateikopie einer laufenden Datenbank ist nicht
# verlaesslich wiederherstellbar. Die belastbare Sicherung der Nextcloud-DB
# ist der Dump aus backup_nextcloud (nextcloud/nextcloud-db.sql.gz).
#
# Die Warnung wird bewusst NICHT per --warning=no-file-changed unterdrueckt:
# Sie benennt die betroffene Datei und ist der einzige Hinweis darauf, dass
# eine Datei inkonsistent im Archiv liegt.
backup_copy_docker_dirs() {
    log "--- Kopiere Docker-Verzeichnisse ---"
    mkdir -p "$TARGET_DIR/docker"

    if ! command -v pv >/dev/null 2>&1; then
        log "pv nicht gefunden, kopiere ohne Fortschrittsanzeige"
        cp -a "$DOCKER_DIR/." "$TARGET_DIR/docker/"
        return 0
    fi

    log "Kopiere mit Fortschrittsanzeige (pv)"
    local copy_size_bytes
    copy_size_bytes="$(du -sb "$DOCKER_DIR" 2>/dev/null | awk '{print $1}')"

    local pv_args=(-f -pterb)
    if [ -n "${copy_size_bytes:-}" ]; then
        pv_args+=(-s "$copy_size_bytes")
    fi

    # errexit hier gezielt aus, damit die Pipeline durchlaeuft und ihre
    # Exitcodes ueberhaupt bewertet werden koennen.
    local -a status
    set +e
    tar -C "$DOCKER_DIR" -cf - . \
        | pv "${pv_args[@]}" \
        | tar -C "$TARGET_DIR/docker" -xpf -
    status=("${PIPESTATUS[@]}")
    set -e

    # Das Entpacken muss sauber sein - hier gibt es nichts zu tolerieren.
    if [ "${status[2]}" -ne 0 ]; then
        log "FEHLER: Entpacken nach $TARGET_DIR/docker fehlgeschlagen (Exit ${status[2]})."
        return 1
    fi

    if [ "${status[1]}" -ne 0 ]; then
        log "FEHLER: pv fehlgeschlagen (Exit ${status[1]})."
        return 1
    fi

    case "${status[0]}" in
        0)
            ;;
        1)
            log "WARNUNG: Mindestens eine Datei hat sich waehrend des Lesens geaendert (tar Exit 1)."
            log "         Betroffene Dateien stehen oben im Log. Der Lauf wird fortgesetzt;"
            log "         fuer die Nextcloud-Datenbank gilt ohnehin der Dump, nicht die Dateikopie."
            ;;
        *)
            log "FEHLER: Lesen von $DOCKER_DIR fehlgeschlagen (tar Exit ${status[0]})."
            return 1
            ;;
    esac
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
# WICHTIG: --group-by host,tags ist zwingend - auch weiterhin.
#
# Urspruenglich stand hier, der Grund sei das Datum im Pfad: restic gruppiert
# per Default nach "host,paths", und mit /srv/backups/YYYY-MM-DD_HH-MM landete
# jeder Snapshot in einer eigenen Gruppe. Er war darin gleichzeitig der
# juengste taegliche, woechentliche UND monatliche - es wurde nie etwas
# geloescht, das Repository wuchs unbegrenzt, bis das Remote-Kontingent mit
# 507 Insufficient Storage dichtmachte.
#
# Seit dem stabilen Staging-Pfad trifft diese Begruendung nicht mehr zu, das
# Flag bleibt aber richtig: Im Repository liegen weiterhin die alten
# Snapshots mit datierten Pfaden, und ohne die Gruppierung nach Tag fielen
# sie wieder in eigene Gruppen und damit aus der Retention. Nachgemessen:
# mit --group-by host,tags werden alte und neue Snapshots gemeinsam bewertet,
# mit dem Default host,paths wird nichts entfernt.
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
        # Kein Fehler - ohne zweites Ziel ist das Werkzeug voll brauchbar.
        # Aber auch nicht still: Genau dieser Zweig lief auf dem Produktivhost
        # seit dem 30.08.2026 jede Nacht durch, waehrend jeder Lauf Erfolg
        # meldete. Der kritische Satz lag dadurch nur im grossen Repository,
        # und aufgefallen ist es erst, als jemand gezielt nachsah. Die
        # Erfolgsmeldung sagt es jetzt dazu.
        CRITICAL_SKIPPED=1
        log "HINWEIS: Kein kritisches Repository konfiguriert (RESTIC_REPOSITORY_CRITICAL)."
        log "         Der kritische Satz liegt damit NUR in $RESTIC_REPOSITORY."
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
    #
    # Ein Fehlschlag darf den Lauf nicht abbrechen, aber er ist auch keine
    # blosse Randnotiz: Auf einem kontingentierten Ziel wie einem
    # Webspace-Paket ist ein nicht aufgeraeumtes Repository der Vorbote des
    # naechsten Ausfalls. Genau so ist im August 2026 Vaultwarden aus dem
    # Backup gefallen. Der Lauf geht weiter, meldet am Ende aber einen Fehler.
    if ! restic "${ropts[@]}" forget \
            --group-by host,tags \
            --keep-daily "$KEEP_DAILY" \
            --keep-weekly "$KEEP_WEEKLY" \
            --keep-monthly "$KEEP_MONTHLY" \
            --prune; then
        CRITICAL_FAILED=1
        log "FEHLER: Aufraeumen des kritischen Repositories fehlgeschlagen - der Lauf wird fortgesetzt."
    fi

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

backup_sync_to_huggingface() {
  if [ -z "${HF_RCLONE_REMOTE:-}" ] || [ -z "${HF_BUCKET:-}" ]; then
    log "--- Hugging Face sync disabled ---"
    return 0
  fi

  local prefix="${HF_PREFIX:-nextcloud-restic}"
  local destination="${HF_RCLONE_REMOTE}:${HF_BUCKET}"
  if [ -n "$prefix" ]; then
    destination="${destination}/${prefix#/}"
  fi

  log "--- Sync encrypted Restic repository to Hugging Face Storage Bucket ---"

  if ! rclone lsd "${HF_RCLONE_REMOTE}:" \
       --contimeout 10s \
       --timeout 30s \
       &>/dev/null; then
    log "WARNUNG: Hugging Face Storage Bucket remote nicht erreichbar - Sync uebersprungen"
    return 0
  fi

  rclone sync \
    "$(echo "${RESTIC_REPOSITORY}" | sed 's|^rclone:||')" \
    "$destination" \
    --transfers "${HF_TRANSFERS:-4}" \
    --checkers "${HF_CHECKERS:-8}" \
    --retries 5 \
    --log-file "${LOG_DIR}/rclone-huggingface-$(date +%F).log" \
    --log-level INFO \
    || log "WARNUNG: Hugging-Face-Sync fehlgeschlagen - primaeres Backup bleibt unveraendert"

  log "--- Hugging Face sync abgeschlossen ---"
}
