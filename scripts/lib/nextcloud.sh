#!/bin/bash
# Nextcloud-spezifisches Backup mit Maintenance Mode

# Debug-Modus: auf 1 setzen fuer ausfuehrliche Ausgaben (PW wird maskiert)
NC_DEBUG="${NC_DEBUG:-1}"

_nc_debug() {
  [ "$NC_DEBUG" = "1" ] && log "[NC_DEBUG] $*"
}

# Deaktiviert den Nextcloud-Wartungsmodus und meldet einen Fehlschlag laut.
# Wird per RETURN-Trap in backup_nextcloud und zusaetzlich aus dem EXIT-Trap
# des Hauptskripts aufgerufen. Gibt immer 0 zurueck, damit sie unter
# 'set -e' gefahrlos in Traps verwendet werden kann.
nextcloud_ensure_maintenance_off() {
  [ -n "${NEXTCLOUD_APP_CONTAINER:-}" ] || return 0
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${NEXTCLOUD_APP_CONTAINER}$" || return 0

  if docker exec "${NEXTCLOUD_APP_CONTAINER}" php occ maintenance:mode --off >/dev/null 2>&1; then
    return 0
  fi

  # Haeufigste Ursache: Platte voll, occ kann config.php nicht schreiben.
  log "FEHLER: Nextcloud-Wartungsmodus konnte NICHT deaktiviert werden - Nextcloud bleibt offline!"
  log "        Manuell pruefen: docker exec -u www-data ${NEXTCLOUD_APP_CONTAINER} php occ maintenance:mode --off"
  return 0
}

backup_nextcloud() {
  log "--- Nextcloud Backup gestartet ---"

  _nc_debug "NEXTCLOUD_APP_CONTAINER='${NEXTCLOUD_APP_CONTAINER}'"
  _nc_debug "NEXTCLOUD_DB_CONTAINER='${NEXTCLOUD_DB_CONTAINER}'"
  _nc_debug "NEXTCLOUD_DB_USER='${NEXTCLOUD_DB_USER}'"
  _nc_debug "NEXTCLOUD_DB_PASSWORD='${NEXTCLOUD_DB_PASSWORD:0:2}***${NEXTCLOUD_DB_PASSWORD: -1}' (Laenge: ${#NEXTCLOUD_DB_PASSWORD})"
  _nc_debug "NEXTCLOUD_DB_NAME='${NEXTCLOUD_DB_NAME}'"
  _nc_debug "NEXTCLOUD_DATA_DIR='${NEXTCLOUD_DATA_DIR}'"
  _nc_debug "TARGET_DIR='${TARGET_DIR}'"

  # 1. Maintenance Mode AN
  log "Nextcloud: Aktiviere Maintenance Mode..."
  docker exec "${NEXTCLOUD_APP_CONTAINER}" \
    php occ maintenance:mode --on \
    || { log "FEHLER: Maintenance Mode konnte nicht aktiviert werden"; return 1; }

  # Sicherheitsnetz: Maintenance Mode beim Exit immer deaktivieren
  # Vorher wurde ein Fehlschlag hier durch '2>/dev/null || true' verschluckt.
  # Genau das hat verborgen, dass Nextcloud im Wartungsmodus haengen blieb.
  trap 'nextcloud_ensure_maintenance_off' RETURN

  local NC_BACKUP_DIR="${TARGET_DIR}/nextcloud"
  mkdir -p "${NC_BACKUP_DIR}"

  # 2. DB-Dump
  log "Nextcloud: Erstelle DB-Dump..."

  # Dump-Befehl: explizit konfigurierbar, sonst Autodetection (mariadb-dump > mysqldump)
  local dump_cmd="${NEXTCLOUD_DB_DUMP_CMD:-}"
  if [ -z "$dump_cmd" ]; then
    if docker exec "${NEXTCLOUD_DB_CONTAINER}" which mariadb-dump &>/dev/null; then
      dump_cmd="mariadb-dump"
    else
      dump_cmd="mysqldump"
    fi
  fi
  _nc_debug "Verwende Dump-Befehl: ${dump_cmd}"
  _nc_debug "Kommando: docker exec ${NEXTCLOUD_DB_CONTAINER} ${dump_cmd} --single-transaction --quick -u${NEXTCLOUD_DB_USER} -p[MASKED] ${NEXTCLOUD_DB_NAME}"

  local dump_stderr_file
  dump_stderr_file=$(mktemp)
  local dump_exit=0

  docker exec "${NEXTCLOUD_DB_CONTAINER}" \
    "${dump_cmd}" \
      --single-transaction \
      --quick \
      -u"${NEXTCLOUD_DB_USER}" \
      -p"${NEXTCLOUD_DB_PASSWORD}" \
      "${NEXTCLOUD_DB_NAME}" \
    2>"${dump_stderr_file}" \
    | gzip > "${NC_BACKUP_DIR}/nextcloud-db.sql.gz" \
    || dump_exit=$?

  if [ -s "${dump_stderr_file}" ]; then
    _nc_debug "mysqldump stderr: $(cat "${dump_stderr_file}")"
  fi
  rm -f "${dump_stderr_file}"

  _nc_debug "mysqldump Exit-Code: ${dump_exit}"
  if [ "$dump_exit" -ne 0 ]; then
    log "FEHLER: Nextcloud DB-Dump fehlgeschlagen (Exit ${dump_exit})"
    return 1
  fi
  log "Nextcloud: DB-Dump abgeschlossen."

  # 3. Daten sichern
  log "Nextcloud: Sichere Daten-Verzeichnisse..."
  for dir in data config custom_apps themes; do
    local src="${NEXTCLOUD_DATA_DIR}/${dir}"
    local dst="${NC_BACKUP_DIR}/${dir}"
    if [ -d "${src}" ]; then
      rsync -a --delete "${src}/" "${dst}/" \
        || { log "FEHLER: rsync für ${dir} fehlgeschlagen"; return 1; }
      log "Nextcloud: ${dir} gesichert."
    else
      log "WARNUNG: ${src} nicht gefunden, übersprungen."
    fi
  done

  # 4. Maintenance Mode AUS (auch via trap, aber explizit sauberer)
  log "Nextcloud: Deaktiviere Maintenance Mode..."
  nextcloud_ensure_maintenance_off

  log "--- Nextcloud Backup abgeschlossen ---"
}