#!/usr/bin/env bash
set -euo pipefail

############################################################
# Plex Database Repair – Native Docker Implementation
#
# Goals:
#  - Operate on a mounted Plex data dir (NOT inside Plex container)
#  - Use Debian sqlite3 (/usr/bin/sqlite3)
#  - One-shot execution (unless DBREPAIR_MODE=manual)
#  - Make backups in a dedicated timestamped subdir (DBRepair-style)
#  - Optionally stop/start Plex containers via docker.sock
############################################################

# -----------------------------
# Environment defaults
# -----------------------------
: "${DBREPAIR_MODE:=automatic}"   # automatic|check|vacuum|repair|reindex|deflate|prune|manual
: "${ALLOW_PLEX_KILL:=true}"      # true|false  (stop Plex containers before DB work)
: "${RESTART_PLEX:=true}"         # true|false  (restart Plex containers afterwards)

: "${PLEX_MOUNT:=/plexmediaserver}"  # mountpoint root for Plex data dir (contains "Library/...")
: "${PLEX_REL:=Library/Application Support/Plex Media Server}" # relative path under mount

: "${PRUNE_DAYS:=30}"             # days for PhotoTranscoder file retention
: "${PLEX_CONTAINER_MATCH:=plex}" # grep pattern used against docker image/name fields

SQLITE="/usr/bin/sqlite3"

# -----------------------------
# Derived paths
# -----------------------------
PLEX_ROOT="${PLEX_MOUNT}/${PLEX_REL}"
DBDIR="${PLEX_ROOT}/Plug-in Support/Databases"

LIB_DB="${DBDIR}/com.plexapp.plugins.library.db"
BLOB_DB="${DBDIR}/com.plexapp.plugins.library.blobs.db"

TS="$(date '+%Y-%m-%d_%H-%M-%S')"

# Keep logs and backups in DB dir so they survive container exit
LOGFILE="${DBDIR}/dbrepair-docker-${TS}.log"
BACKUP_ROOT="${DBDIR}/dbrepair-backups"
BACKUP_DIR="${BACKUP_ROOT}/${TS}"

# Track which containers we stopped so we only restart those
STOPPED_IDS_FILE="/tmp/plex_stopped_ids.txt"

# -----------------------------
# Helpers
# -----------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1"; exit 1; }; }

docker_sock_available() {
  [[ -S /var/run/docker.sock ]] && need_cmd docker
}

# -----------------------------
# Safety checks
# -----------------------------
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

# Mirror everything to docker logs + file
exec > >(tee -a "$LOGFILE") 2>&1

log "=================================================="
log " Plex DBRepair – Native Docker"
log "=================================================="
log " Mode      : $DBREPAIR_MODE"
log " Plex Root : $PLEX_ROOT"
log " Databases : $DBDIR"
log " SQLite    : $SQLITE"
log " Backups   : $BACKUP_DIR"
log " Log File  : $LOGFILE"
log "=================================================="

# -----------------------------
# Docker Plex stop/start
# -----------------------------
stop_plex_containers() {
  : > "$STOPPED_IDS_FILE"

  if [[ "$ALLOW_PLEX_KILL" != "true" ]]; then
    log "ALLOW_PLEX_KILL=false — skipping container stop"
    return 0
  fi

  if ! docker_sock_available; then
    log "docker.sock unavailable — cannot stop Plex containers (continuing anyway)"
    return 0
  fi

  log "Scanning for Plex containers to stop (match: ${PLEX_CONTAINER_MATCH})..."
  # include ID, Names, Image
  docker ps --format '{{.ID}} {{.Names}} {{.Image}}' | while read -r cid name image; do
    if echo "$name $image" | grep -qiE "$PLEX_CONTAINER_MATCH"; then
      log "Stopping: $name ($cid) image=$image"
      echo "$cid" >> "$STOPPED_IDS_FILE"
      docker stop "$cid" >/dev/null 2>&1 || true
    fi
  done
}

restart_plex_containers() {
  if [[ "$RESTART_PLEX" != "true" ]]; then
    log "RESTART_PLEX=false — skipping container restart"
    return 0
  fi

  if ! docker_sock_available; then
    log "docker.sock unavailable — cannot restart Plex containers"
    return 0
  fi

  if [[ ! -s "$STOPPED_IDS_FILE" ]]; then
    log "No Plex containers were stopped — nothing to restart"
    return 0
  fi

  log "Restarting Plex containers that were stopped..."
  while read -r cid; do
    [[ -n "$cid" ]] || continue
    docker start "$cid" >/dev/null 2>&1 || true
    log "Started: $cid"
  done < "$STOPPED_IDS_FILE"
}

# Ensure restart happens even if DB ops fail
trap 'rc=$?; restart_plex_containers || true; exit $rc' EXIT

# -----------------------------
# Backup (DBRepair-style: dedicated dir)
# -----------------------------
prepare_backup_dir() {
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR" || true
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -a "$f" "$BACKUP_DIR/"
  fi
}

backup_all() {
  log "Creating backups..."
  prepare_backup_dir

  # main dbs
  backup_file "$LIB_DB"
  backup_file "$BLOB_DB"

  # wal/shm companions
  for suffix in wal shm; do
    backup_file "${LIB_DB}-${suffix}"
    backup_file "${BLOB_DB}-${suffix}"
  done

  log "Backup complete: $(ls -1 "$BACKUP_DIR" | wc -l) file(s)"
}

# -----------------------------
# Stats (page_count / page_size + file size)
# -----------------------------
db_stats() {
  local db="$1"
  if [[ ! -f "$db" ]]; then
    log "Stats: missing $(basename "$db") (skipping)"
    return 0
  fi

  local base
  base="$(basename "$db")"

  log "Stats (before/after) for $base"
  # Print page_size, page_count, freelist_count for visibility
  "$SQLITE" "$db" <<'EOF'
PRAGMA page_size;
PRAGMA page_count;
PRAGMA freelist_count;
EOF
  ls -lh "$db" || true
}

# -----------------------------
# SQLite operations
# -----------------------------
# Note: If Plex is properly stopped, these operations are safe.
# If Plex is NOT stopped and WAL is active, results can be inconsistent.
check_db() {
  local db="$1"
  log "Integrity check: $(basename "$db")"
  "$SQLITE" "$db" "PRAGMA integrity_check(1);"
}

# Make sure WAL content is merged into the DB before VACUUM/REINDEX/DEFALTE where possible.
# This helps avoid surprises if WAL exists.
checkpoint_db() {
  local db="$1"
  if [[ -f "${db}-wal" ]]; then
    log "Checkpoint WAL: $(basename "$db")"
    # TRUNCATE reduces WAL size; if it fails, continue.
    "$SQLITE" "$db" "PRAGMA wal_checkpoint(TRUNCATE);" || true
  fi
}

vacuum_db() {
  local db="$1"
  log "Vacuum: $(basename "$db")"
  checkpoint_db "$db"
  "$SQLITE" "$db" "VACUUM;"
}

reindex_db() {
  local db="$1"
  log "Reindex: $(basename "$db")"
  checkpoint_db "$db"
  "$SQLITE" "$db" "REINDEX;"
}

deflate_db() {
  local db="$1"
  log "Deflate (VACUUM INTO): $(basename "$db")"
  checkpoint_db "$db"

  local tmp="${db}.tmp"
  rm -f "$tmp" || true
  "$SQLITE" "$db" "VACUUM INTO '$tmp';"

  # Replace atomically-ish
  mv -f "$tmp" "$db"
}

# Minimal "repair" in SQLite terms = VACUUM.
# Note: DBRepair's "repair/optimize" does more nuanced flow, but VACUUM is the core operation.
repair_db() {
  local db="$1"
  vacuum_db "$db"
}

# Cache prune (PhotoTranscoder)
prune_cache() {
  local cache="${PLEX_ROOT}/Cache/PhotoTranscoder"
  if [[ ! -d "$cache" ]]; then
    log "PhotoTranscoder cache missing ($cache) — skipping prune"
    return 0
  fi
  log "Pruning PhotoTranscoder cache > ${PRUNE_DAYS} days: $cache"
  find "$cache" -type f -mtime "+${PRUNE_DAYS}" -print -delete || true
}

# -----------------------------
# Execute
# -----------------------------
stop_plex_containers

# Optional: show initial stats for visibility
log "----- PRE-STATS -----"
db_stats "$LIB_DB"
db_stats "$BLOB_DB"

case "$DBREPAIR_MODE" in
  manual)
    log "Entering manual shell (no changes will be made unless you run commands)."
    exec bash
    ;;
  check)
    check_db "$LIB_DB"
    check_db "$BLOB_DB"
    ;;
  vacuum)
    backup_all
    vacuum_db "$LIB_DB"
    [[ -f "$BLOB_DB" ]] && vacuum_db "$BLOB_DB"
    ;;
  repair)
    backup_all
    repair_db "$LIB_DB"
    [[ -f "$BLOB_DB" ]] && repair_db "$BLOB_DB"
    ;;
  reindex)
    backup_all
    reindex_db "$LIB_DB"
    [[ -f "$BLOB_DB" ]] && reindex_db "$BLOB_DB"
    ;;
  deflate)
    backup_all
    deflate_db "$LIB_DB"
    [[ -f "$BLOB_DB" ]] && deflate_db "$BLOB_DB"
    ;;
  prune)
    prune_cache
    ;;
  automatic|*)
    backup_all
    check_db "$LIB_DB"
    [[ -f "$BLOB_DB" ]] && check_db "$BLOB_DB"
    repair_db "$LIB_DB"
    [[ -f "$BLOB_DB" ]] && repair_db "$BLOB_DB"
    reindex_db "$LIB_DB"
    [[ -f "$BLOB_DB" ]] && reindex_db "$BLOB_DB"
    ;;
esac

log "----- POST-STATS -----"
db_stats "$LIB_DB"
db_stats "$BLOB_DB"

log "=================================================="
log " DBRepair completed"
log " Backups: $BACKUP_DIR"
log " Log    : $LOGFILE"
log "=================================================="
