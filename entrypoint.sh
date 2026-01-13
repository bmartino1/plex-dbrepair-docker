#!/usr/bin/env bash
set -euo pipefail

############################################################
# Plex Database Repair – Native Docker Implementation
############################################################

# ---------------------------------------------------------
# Environment defaults
# ---------------------------------------------------------
: "${DBREPAIR_MODE:=automatic}"        # automatic|check|vacuum|repair|reindex|deflate|prune|manual
: "${ALLOW_PLEX_KILL:=true}"           # true|false
: "${RESTART_PLEX:=true}"              # true|false

: "${PLEX_MOUNT:=/plexmediaserver}"
: "${PLEX_REL:=Library/Application Support/Plex Media Server}"

: "${PRUNE_DAYS:=30}"

# Plex container detection
: "${PLEX_CONTAINER_MATCH:=plex}"

# *** CRITICAL SELF-PROTECTION ***
: "${EXCLUDE_CONTAINER_NAMES:=dbrepair,plex-dbrepair}"
: "${EXCLUDE_IMAGE_REGEX:=plex-dbrepair}"

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

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing command: $1"
    exit 1
  }
}

docker_sock_available() {
  [[ -S /var/run/docker.sock ]] && need_cmd docker
}

# ---------------------------------------------------------
# Safety checks
# ---------------------------------------------------------
need_cmd tee
need_cmd awk
need_cmd grep
need_cmd find
need_cmd ls
need_cmd cp
need_cmd mv

[[ -x "$SQLITE" ]] || { echo "ERROR: sqlite3 missing at $SQLITE"; exit 1; }
[[ -d "$DBDIR" ]]  || { echo "ERROR: DBDIR missing: $DBDIR"; exit 1; }
[[ -f "$LIB_DB" ]] || { echo "ERROR: Main DB missing: $LIB_DB"; exit 1; }
[[ -w "$DBDIR" ]]  || { echo "ERROR: DBDIR not writable: $DBDIR"; exit 1; }

# Mirror all output
exec > >(tee -a "$LOGFILE") 2>&1

log "=================================================="
log " Plex DBRepair – Native Docker"
log "=================================================="
log " Mode                  : $DBREPAIR_MODE"
log " Plex Root             : $PLEX_ROOT"
log " Databases             : $DBDIR"
log " SQLite                : $SQLITE"
log " Backup Dir            : $BACKUP_DIR"
log " Exclude Names         : $EXCLUDE_CONTAINER_NAMES"
log " Exclude Image Regex   : $EXCLUDE_IMAGE_REGEX"
log "=================================================="

# ---------------------------------------------------------
# Docker Plex stop/start (SELF-SAFE)
# ---------------------------------------------------------
stop_plex_containers() {
  : > "$STOPPED_IDS_FILE"

  [[ "$ALLOW_PLEX_KILL" != "true" ]] && {
    log "ALLOW_PLEX_KILL=false — skipping container stop"
    return 0
  }

  docker_sock_available || {
    log "docker.sock unavailable — cannot stop Plex containers"
    return 0
  }

  IFS=',' read -ra EXCL_NAMES <<< "$EXCLUDE_CONTAINER_NAMES"

  log "Scanning for Plex containers to stop (match: $PLEX_CONTAINER_MATCH)"

  docker ps --format '{{.ID}} {{.Names}} {{.Image}}' | while read -r cid name image; do

    # --- Exclude by container name
    for ex in "${EXCL_NAMES[@]}"; do
      [[ "$name" == "$ex" ]] && {
        log "Skipping (excluded name): $name"
        continue 2
      }
    done

    # --- Exclude by image regex
    if echo "$image" | grep -qiE "$EXCLUDE_IMAGE_REGEX"; then
      log "Skipping (excluded image): $image"
      continue
    fi

    # --- Match Plex containers
    if echo "$name $image" | grep -qiE "$PLEX_CONTAINER_MATCH"; then
      log "Stopping Plex container: $name ($cid) image=$image"
      echo "$cid" >> "$STOPPED_IDS_FILE"
      docker stop "$cid" >/dev/null 2>&1 || true
    fi
  done
}

restart_plex_containers() {
  [[ "$RESTART_PLEX" != "true" ]] && {
    log "RESTART_PLEX=false — skipping restart"
    return 0
  }

  docker_sock_available || {
    log "docker.sock unavailable — cannot restart Plex containers"
    return 0
  }

  [[ ! -s "$STOPPED_IDS_FILE" ]] && {
    log "No Plex containers were stopped — nothing to restart"
    return 0
  }

  log "Restarting Plex containers that were stopped..."
  while read -r cid; do
    docker start "$cid" >/dev/null 2>&1 || true
    log "Started: $cid"
  done < "$STOPPED_IDS_FILE"
}

trap 'rc=$?; restart_plex_containers || true; exit $rc' EXIT

# ---------------------------------------------------------
# Backup handling (DBRepair-style)
# ---------------------------------------------------------
prepare_backup_dir() {
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR" || true
}

backup_file() {
  [[ -f "$1" ]] && cp -a "$1" "$BACKUP_DIR/"
}

backup_all() {
  log "Creating backups..."
  prepare_backup_dir

  backup_file "$LIB_DB"
  backup_file "$BLOB_DB"

  for s in wal shm; do
    backup_file "${LIB_DB}-${s}"
    backup_file "${BLOB_DB}-${s}"
  done

  log "Backup complete: $(ls -1 "$BACKUP_DIR" | wc -l) file(s)"
}

# ---------------------------------------------------------
# SQLite helpers
# ---------------------------------------------------------
checkpoint_db() {
  [[ -f "$1-wal" ]] && "$SQLITE" "$1" "PRAGMA wal_checkpoint(TRUNCATE);" || true
}

check_db()   { log "Check: $(basename "$1")"; "$SQLITE" "$1" "PRAGMA integrity_check(1);"; }
vacuum_db()  { checkpoint_db "$1"; log "Vacuum: $(basename "$1")"; "$SQLITE" "$1" "VACUUM;"; }
reindex_db() { checkpoint_db "$1"; log "Reindex: $(basename "$1")"; "$SQLITE" "$1" "REINDEX;"; }

deflate_db() {
  checkpoint_db "$1"
  local tmp="$1.tmp"
  log "Deflate: $(basename "$1")"
  "$SQLITE" "$1" "VACUUM INTO '$tmp';"
  mv -f "$tmp" "$1"
}

repair_db() { vacuum_db "$1"; }

prune_cache() {
  local cache="$PLEX_ROOT/Cache/PhotoTranscoder"
  [[ -d "$cache" ]] || return 0
  log "Pruning cache > ${PRUNE_DAYS} days"
  find "$cache" -type f -mtime "+${PRUNE_DAYS}" -delete || true
}

# ---------------------------------------------------------
# Execute
# ---------------------------------------------------------
stop_plex_containers

case "$DBREPAIR_MODE" in
  manual)
    log "Entering manual shell"
    exec bash
    ;;
  check)
    check_db "$LIB_DB"; check_db "$BLOB_DB"
    ;;
  vacuum)
    backup_all; vacuum_db "$LIB_DB"; vacuum_db "$BLOB_DB"
    ;;
  repair)
    backup_all; repair_db "$LIB_DB"; repair_db "$BLOB_DB"
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
    repair_db "$LIB_DB"; repair_db "$BLOB_DB"
    reindex_db "$LIB_DB"; reindex_db "$BLOB_DB"
    ;;
esac

log "=================================================="
log " DBRepair completed"
log " Backups: $BACKUP_DIR"
log " Log    : $LOGFILE"
log "=================================================="
