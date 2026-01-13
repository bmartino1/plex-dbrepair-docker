#!/usr/bin/env bash
set -euo pipefail

############################################################
# Plex Database Repair – Native Docker Implementation
############################################################

# ---------------------------------------------------------
# Environment defaults
# ---------------------------------------------------------
: "${DBREPAIR_MODE:=automatic}"        # automatic|check|vacuum|repair|reindex|deflate|prune|manual
: "${ENABLE_BACKUPS:=true}"            # true|false
: "${RESTORE_LAST_BACKUP:=false}"      # true|false

: "${ALLOW_PLEX_KILL:=true}"
: "${RESTART_PLEX:=true}"

: "${PLEX_MOUNT:=/config}"
: "${PLEX_REL:=Library/Application Support/Plex Media Server}"

: "${PRUNE_DAYS:=30}"

# Plex container detection
: "${PLEX_CONTAINER_MATCH:=plex}"

# --- Self-protection ---
: "${EXCLUDE_CONTAINER_NAMES:=dbrepair,plex-dbrepair}"
: "${EXCLUDE_IMAGE_REGEX:=plex-dbrepair}"

# SQLite handling
: "${SQLITE_NO_ICU:=false}"
SQLITE="/usr/bin/sqlite3"

# ---------------------------------------------------------
# Derived paths
# ---------------------------------------------------------
PLEX_ROOT="${PLEX_MOUNT}/${PLEX_REL}"
DBDIR="${PLEX_ROOT}/Plug-in Support/Databases"

LIB_DB="${DBDIR}/com.plexapp.plugins.library.db"
BLOB_DB="${DBDIR}/com.plexapp.plugins.library.blobs.db"

TS="$(date '+%Y-%m-%d_%H-%M-%S')"

LOGFILE="${DBDIR}/dbrepair-docker-${TS}.log"
BACKUP_ROOT="${DBDIR}/dbrepair-backups"
BACKUP_DIR="${BACKUP_ROOT}/${TS}"

STOPPED_IDS_FILE="/tmp/plex_stopped_ids.txt"

# ---------------------------------------------------------
# Helpers
# ---------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

die() {
  log "FATAL: $*"
  exit 1
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

docker_sock_available() {
  [[ -S /var/run/docker.sock ]] && need_cmd docker
}

# ---------------------------------------------------------
# Safety checks
# ---------------------------------------------------------
need_cmd tee awk grep find cp mv ls

[[ -x "$SQLITE" ]] || die "sqlite3 missing at $SQLITE"
[[ -d "$DBDIR" ]]  || die "DBDIR missing: $DBDIR"
[[ -f "$LIB_DB" ]] || die "Main DB missing: $LIB_DB"
[[ -w "$DBDIR" ]]  || die "DBDIR not writable (check UID/GID mapping)"

# ICU workaround
if [[ "$SQLITE_NO_ICU" == "true" ]]; then
  export SQLITE_ICU=0
  log "SQLite ICU disabled (SQLITE_NO_ICU=true)"
fi

# Mirror all output
exec > >(tee -a "$LOGFILE") 2>&1

log "=================================================="
log " Plex DBRepair – Native Docker"
log "=================================================="
log " Mode                  : $DBREPAIR_MODE"
log " Plex Root             : $PLEX_ROOT"
log " Databases             : $DBDIR"
log " SQLite                : $SQLITE"
log " Backups Enabled       : $ENABLE_BACKUPS"
log " Restore Last Backup   : $RESTORE_LAST_BACKUP"
log " Backup Root           : $BACKUP_ROOT"
log " Exclude Names         : $EXCLUDE_CONTAINER_NAMES"
log " Exclude Image Regex   : $EXCLUDE_IMAGE_REGEX"
log "=================================================="

# ---------------------------------------------------------
# Docker Plex stop/start (self-safe)
# ---------------------------------------------------------
stop_plex_containers() {
  : > "$STOPPED_IDS_FILE"

  [[ "$ALLOW_PLEX_KILL" != "true" ]] && {
    log "ALLOW_PLEX_KILL=false — skipping Plex stop"
    return
  }

  docker_sock_available || {
    log "docker.sock unavailable — skipping Plex stop"
    return
  }

  IFS=',' read -ra EXCL <<< "$EXCLUDE_CONTAINER_NAMES"

  log "Scanning for Plex containers to stop..."

  docker ps --format '{{.ID}} {{.Names}} {{.Image}}' |
  while read -r cid name image; do

    for ex in "${EXCL[@]}"; do
      [[ "$name" == "$ex" ]] && {
        log "Skipping excluded container: $name"
        continue 2
      }
    done

    echo "$image" | grep -qiE "$EXCLUDE_IMAGE_REGEX" && {
      log "Skipping excluded image: $image"
      continue
    }

    echo "$name $image" | grep -qiE "$PLEX_CONTAINER_MATCH" || continue

    log "Stopping Plex container: $name ($cid)"
    echo "$cid" >> "$STOPPED_IDS_FILE"
    docker stop "$cid" >/dev/null 2>&1 || true
  done
}

restart_plex_containers() {
  [[ "$RESTART_PLEX" != "true" ]] && return
  docker_sock_available || return
  [[ ! -s "$STOPPED_IDS_FILE" ]] && return

  log "Restarting Plex containers..."
  while read -r cid; do
    docker start "$cid" >/dev/null 2>&1 || true
    log "Started: $cid"
  done < "$STOPPED_IDS_FILE"
}

trap 'rc=$?; restart_plex_containers || true; exit $rc' EXIT

# ---------------------------------------------------------
# Backup / Restore
# ---------------------------------------------------------
latest_backup_dir() {
  ls -1dt "$BACKUP_ROOT"/* 2>/dev/null | head -1
}

restore_last_backup() {
  local last
  last="$(latest_backup_dir)"
  [[ -d "$last" ]] || die "No backups found to restore"

  log "Restoring from backup: $last"

  for f in "$last"/*; do
    log "Restoring $(basename "$f")"
    cp -a "$f" "$DBDIR/"
  done
}

backup_all() {
  [[ "$ENABLE_BACKUPS" != "true" ]] && {
    log "Backups disabled — skipping"
    return
  }

  log "Creating backup set..."
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR" || true

  for f in \
    "$LIB_DB" "$BLOB_DB" \
    "$LIB_DB-wal" "$LIB_DB-shm" \
    "$BLOB_DB-wal" "$BLOB_DB-shm"
  do
    [[ -f "$f" ]] && cp -a "$f" "$BACKUP_DIR/"
  done

  log "Backup completed: $BACKUP_DIR"
}

# ---------------------------------------------------------
# SQLite operations
# ---------------------------------------------------------
checkpoint_db() {
  [[ -f "$1-wal" ]] && "$SQLITE" "$1" "PRAGMA wal_checkpoint(TRUNCATE);" || true
}

check_db()   { log "Integrity check: $(basename "$1")"; "$SQLITE" "$1" "PRAGMA integrity_check(1);"; }
vacuum_db()  { checkpoint_db "$1"; log "Vacuum: $(basename "$1")"; "$SQLITE" "$1" "VACUUM;"; }
reindex_db() { checkpoint_db "$1"; log "Reindex: $(basename "$1")"; "$SQLITE" "$1" "REINDEX;"; }

deflate_db() {
  checkpoint_db "$1"
  local tmp="$1.tmp"
  log "Deflate: $(basename "$1")"
  "$SQLITE" "$1" "VACUUM INTO '$tmp';"
  mv -f "$tmp" "$1"
}

prune_cache() {
  local cache="$PLEX_ROOT/Cache/PhotoTranscoder"
  [[ -d "$cache" ]] || return
  log "Pruning PhotoTranscoder cache > ${PRUNE_DAYS} days"
  find "$cache" -type f -mtime "+${PRUNE_DAYS}" -delete || true
}

# ---------------------------------------------------------
# Execute
# ---------------------------------------------------------
stop_plex_containers

if [[ "$RESTORE_LAST_BACKUP" == "true" ]]; then
  restore_last_backup
  log "Restore complete — exiting"
  exit 0
fi

case "$DBREPAIR_MODE" in
  manual)
    log "Entering manual shell (full Plex library available under /config)"
    exec bash
    ;;
  check)
    check_db "$LIB_DB"; check_db "$BLOB_DB"
    ;;
  vacuum)
    backup_all; vacuum_db "$LIB_DB"; vacuum_db "$BLOB_DB"
    ;;
  repair)
    backup_all; vacuum_db "$LIB_DB"; vacuum_db "$BLOB_DB"
    ;;
  reindex)
    backup_all; reindex_db "$LIB_DB"; reindex_db "$BLOB_DB"
    ;;
  deflate)
    backup_all; deflate_db "$LIB_DB"; deflate_db "$BLOB_DB"
    ;;
  prune)
    prune_cache
    ;;
  automatic|*)
    backup_all
    check_db "$LIB_DB"; check_db "$BLOB_DB"
    vacuum_db "$LIB_DB"; vacuum_db "$BLOB_DB"
    reindex_db "$LIB_DB"; reindex_db "$BLOB_DB"
    ;;
esac

log "=================================================="
log " DBRepair completed successfully"
log " Log     : $LOGFILE"
log " Backups : $BACKUP_ROOT"
log "=================================================="
