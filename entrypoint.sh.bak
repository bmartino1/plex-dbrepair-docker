#!/usr/bin/env bash
set -euo pipefail

############################################################
# Plex Database Repair – Native Docker Implementation
#
# ChuckPa-aligned behavior:
# - Run real SQLite commands and fail only if they fail
# - Prefer Plex SQLite, fallback to system sqlite
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
: "${PLEX_CONTAINER_MATCH:=plex}"

: "${EXCLUDE_CONTAINER_NAMES:=dbrepair,plex-dbrepair}"
: "${EXCLUDE_IMAGE_REGEX:=plex-dbrepair}"

# ---------------------------------------------------------
# Paths
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
# Logging helpers
# ---------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "FATAL: $*"; exit 1; }

section() {
  log "=================================================="
  log " $*"
  log "=================================================="
}

step() {
  log "$(printf '%-8s' "$1") : $(basename "$2")"
}

final_log() {
  log "=================================================="
  log " DBRepair completed"
  log " Log     : $LOGFILE"
  log " Backups : $BACKUP_ROOT"
  log "=================================================="
}

# ---------------------------------------------------------
# SQLite selection (ChuckPa style)
# ---------------------------------------------------------
if [[ -x "/usr/lib/plexmediaserver/Plex SQLite" ]]; then
  SQLITE="/usr/lib/plexmediaserver/Plex SQLite"
  SQLITE_KIND="plex"
else
  SQLITE="$(command -v sqlite3 || true)"
  SQLITE_KIND="system"
fi

[[ -x "$SQLITE" ]] || die "No usable SQLite binary found"

# ---------------------------------------------------------
# Safety checks (minimal)
# ---------------------------------------------------------
[[ -d "$DBDIR" ]]  || die "DBDIR missing: $DBDIR"
[[ -f "$LIB_DB" ]] || die "Main DB missing"
[[ -w "$DBDIR" ]]  || die "DBDIR not writable"

# ---------------------------------------------------------
# ChuckPa TMPDIR handling (CRITICAL)
# ---------------------------------------------------------
DBTMP="./dbtmp"
mkdir -p "$DBDIR/$DBTMP"

export TMPDIR="$DBTMP"
export TMP="$DBTMP"

# ---------------------------------------------------------
# Mirror output to logfile
# ---------------------------------------------------------
exec > >(tee -a "$LOGFILE") 2>&1

# ---------------------------------------------------------
# Header
# ---------------------------------------------------------
section "Plex DBRepair – Native Docker"
log " Mode                : $DBREPAIR_MODE"
log " Plex Root           : $PLEX_ROOT"
log " Databases           : $DBDIR"
log " SQLite              : $SQLITE ($SQLITE_KIND)"
log " Backups Enabled     : $ENABLE_BACKUPS"
log " Restore Last Backup : $RESTORE_LAST_BACKUP"

# ---------------------------------------------------------
# Docker helpers
# ---------------------------------------------------------
docker_available() {
  [[ -S /var/run/docker.sock ]] && command -v docker >/dev/null 2>&1
}

stop_plex_containers() {
  : > "$STOPPED_IDS_FILE"

  [[ "$ALLOW_PLEX_KILL" != "true" ]] && {
    log "ALLOW_PLEX_KILL=false — skipping Plex stop"
    return
  }

  docker_available || {
    log "docker unavailable — skipping Plex stop"
    return
  }

  IFS=',' read -ra EXCL <<< "$EXCLUDE_CONTAINER_NAMES"

  section "Stopping Plex containers (match: $PLEX_CONTAINER_MATCH)"

  docker ps --format '{{.ID}} {{.Names}} {{.Image}}' |
  while read -r cid name image; do
    for ex in "${EXCL[@]}"; do
      [[ "$name" == "$ex" ]] && { log "Skipping excluded container: $name"; continue 2; }
    done
    echo "$image" | grep -qiE "$EXCLUDE_IMAGE_REGEX" && continue
    echo "$name $image" | grep -qiE "$PLEX_CONTAINER_MATCH" || continue

    log "Stopping Plex container: $name ($cid)"
    echo "$cid" >> "$STOPPED_IDS_FILE"
    docker stop "$cid" >/dev/null 2>&1 || true
  done
}

restart_plex_containers() {
  [[ "$RESTART_PLEX" != "true" ]] && return
  docker_available || return
  [[ -s "$STOPPED_IDS_FILE" ]] || {
    log "No Plex containers were stopped — nothing to restart"
    return
  }

  section "Restarting Plex containers"
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
  [[ -d "$last" ]] || die "No backups found"
  section "Restore last backup"
  cp -a "$last"/* "$DBDIR/"
}

backup_all() {
  [[ "$ENABLE_BACKUPS" != "true" ]] && {
    log "Backups disabled — skipping"
    return
  }

  section "Backup databases"
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR" || true

  local n=0
  for f in "$LIB_DB" "$BLOB_DB" "$LIB_DB-wal" "$LIB_DB-shm" "$BLOB_DB-wal" "$BLOB_DB-shm"; do
    [[ -f "$f" ]] || continue
    log "Backup   : $(basename "$f")"
    cp -a "$f" "$BACKUP_DIR/"
    n=$((n+1))
  done
  log "Backup dir: $BACKUP_DIR ($n file(s))"
}

# ---------------------------------------------------------
# SQLite workers (fail naturally)
# ---------------------------------------------------------
checkpoint_db() {
  [[ -f "$1-wal" ]] && "$SQLITE" "$1" "PRAGMA wal_checkpoint(TRUNCATE);" || true
}

check_db()   { "$SQLITE" "$1" "PRAGMA integrity_check(1);"; }
vacuum_db()  { checkpoint_db "$1"; "$SQLITE" "$1" "VACUUM;"; }
reindex_db() { checkpoint_db "$1"; "$SQLITE" "$1" "REINDEX;"; }

deflate_db() {
  checkpoint_db "$1"
  local tmp="$1.tmp"
  rm -f "$tmp"
  "$SQLITE" "$1" "VACUUM INTO '$tmp';"
  mv -f "$tmp" "$1"
}

# ---------------------------------------------------------
# Execute
# ---------------------------------------------------------
stop_plex_containers

[[ "$RESTORE_LAST_BACKUP" == "true" ]] && {
  restore_last_backup
  final_log
  exit 0
}

case "$DBREPAIR_MODE" in
  manual)
    section "Manual mode"
    log "Starting detached screen session"
    screen -dmS dbrepair bash -i
    log "Attach with: screen -r dbrepair"
    tail -f /dev/null
    ;;

  check)
    section "Integrity check"
    step "Check" "$LIB_DB";  check_db "$LIB_DB"
    step "Check" "$BLOB_DB"; check_db "$BLOB_DB"
    final_log
    ;;

  vacuum)
    section "Vacuum"
    backup_all
    step "Vacuum" "$LIB_DB";  vacuum_db "$LIB_DB"
    step "Vacuum" "$BLOB_DB"; vacuum_db "$BLOB_DB"
    final_log
    ;;

  repair)
    section "Repair / Optimize"
    backup_all
    step "Vacuum" "$LIB_DB";  vacuum_db "$LIB_DB"
    step "Vacuum" "$BLOB_DB"; vacuum_db "$BLOB_DB"
    final_log
    ;;

  reindex)
    section "Reindex"
    backup_all
    step "Reindex" "$LIB_DB";  reindex_db "$LIB_DB"
    step "Reindex" "$BLOB_DB"; reindex_db "$BLOB_DB"
    final_log
    ;;

  deflate)
    section "Deflate"
    backup_all
    step "Deflate" "$LIB_DB";  deflate_db "$LIB_DB"
    step "Deflate" "$BLOB_DB"; deflate_db "$BLOB_DB"
    final_log
    ;;

  prune)
    section "Prune PhotoTranscoder cache"
    find "$PLEX_ROOT/Cache/PhotoTranscoder" -type f -mtime "+${PRUNE_DAYS}" -delete || true
    final_log
    ;;

  automatic|*)
    section "Automatic (check → vacuum → reindex)"
    backup_all
    step "Check"   "$LIB_DB";  check_db "$LIB_DB"
    step "Check"   "$BLOB_DB"; check_db "$BLOB_DB"
    step "Vacuum"  "$LIB_DB";  vacuum_db "$LIB_DB"
    step "Vacuum"  "$BLOB_DB"; vacuum_db "$BLOB_DB"
    step "Reindex" "$LIB_DB";  reindex_db "$LIB_DB"
    step "Reindex" "$BLOB_DB"; reindex_db "$BLOB_DB"
    final_log
    ;;
esac
