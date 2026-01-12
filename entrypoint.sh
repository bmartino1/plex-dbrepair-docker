#!/usr/bin/env bash
set -euo pipefail

# ======================================================
# Docker environment variables
# ======================================================
: "${PLEX_DB_DIR:=/plexdb}"
: "${LOG_DIR:=/logs}"
: "${DBREPAIR_MODE:=automatic}"   # automatic | check | vacuum | repair | reindex | manual

# Plex control variables (container-level only)
: "${PLEX_MATCH_REGEX:=Plex Media Server|plex}"
: "${EXCLUDE_CONTAINER_NAMES:=dbrepair,plex-dbrepair}"
: "${EXCLUDE_IMAGE_REGEX:=plex-dbrepair}"
: "${ALLOW_PLEX_KILL:=true}"
: "${KILL_STRAY_PLEX_PROCESSES:=true}"

# ======================================================
# Constants
# ======================================================
CPPL="com.plexapp.plugins.library"
DB_MAIN="${PLEX_DB_DIR}/${CPPL}.db"
DB_BLOBS="${PLEX_DB_DIR}/${CPPL}.blobs.db"
SQLITE_BIN="/usr/bin/sqlite3"

LOGFILE="${LOG_DIR}/dbrepair.log"
TMPDIR="/tmp/dbrepair"

mkdir -p "$LOG_DIR" "$TMPDIR"
: > "$LOGFILE"
exec > >(tee -a "$LOGFILE") 2>&1

# ======================================================
# Banner
# ======================================================
echo "=================================================="
echo " Plex DBRepair (Docker Native)"
echo "=================================================="
echo " Mode        : ${DBREPAIR_MODE}"
echo " DB Dir      : ${PLEX_DB_DIR}"
echo " Main DB     : ${DB_MAIN}"
echo " Blobs DB    : ${DB_BLOBS}"
echo "=================================================="

# ======================================================
# Safety checks
# ======================================================
[[ -d "$PLEX_DB_DIR" ]] || { echo "ERROR: Plex DB dir missing"; exit 1; }
[[ -f "$DB_MAIN" ]]     || { echo "ERROR: Main DB missing"; exit 1; }
[[ -f "$DB_BLOBS" ]]    || { echo "ERROR: Blobs DB missing"; exit 1; }

# ======================================================
# Manual mode = escape hatch
# ======================================================
if [[ "$DBREPAIR_MODE" == "manual" ]]; then
  echo "Entering MANUAL mode. You may run DBRepair.sh yourself."
  exec bash
fi

# ======================================================
# Plex shutdown logic (container-level)
# ======================================================
if [[ "$ALLOW_PLEX_KILL" == "true" ]]; then
  echo "Scanning for Plex containers to stop..."
  IFS=',' read -ra EXCL <<< "$EXCLUDE_CONTAINER_NAMES"

  docker ps --format '{{.ID}} {{.Names}} {{.Image}}' | while read -r CID NAME IMAGE; do
    for X in "${EXCL[@]}"; do
      [[ "$NAME" == "$X" ]] && continue 2
    done
    echo "$IMAGE" | grep -qiE "$EXCLUDE_IMAGE_REGEX" && continue
    if echo "$NAME $IMAGE" | grep -qiE "$PLEX_MATCH_REGEX"; then
      echo "Stopping Plex container: $NAME ($CID)"
      docker update --restart=no "$CID" >/dev/null 2>&1 || true
      docker stop "$CID" >/dev/null 2>&1 || true
    fi
  done
else
  echo "Skipping Plex shutdown"
fi

# ======================================================
# Core DBRepair logic (extracted from ChuckPa)
# ======================================================
db_check_one() {
  local db="$1"
  echo "Checking $(basename "$db")"
  local result
  result="$("$SQLITE_BIN" "$db" "PRAGMA integrity_check(1);")"
  [[ "$result" == "ok" ]] && return 0
  echo "Integrity error: $result"
  return 1
}

db_check() {
  db_check_one "$DB_MAIN" && db_check_one "$DB_BLOBS"
}

db_backup() {
  TS="$(date +%Y%m%d-%H%M%S)"
  BK="${PLEX_DB_DIR}/dbrepair-backup-${TS}"
  mkdir -p "$BK"
  echo "Creating backup: $BK"

  for f in \
    "${CPPL}.db" \
    "${CPPL}.db-wal" \
    "${CPPL}.db-shm" \
    "${CPPL}.blobs.db" \
    "${CPPL}.blobs.db-wal" \
    "${CPPL}.blobs.db-shm"
  do
    [[ -f "${PLEX_DB_DIR}/$f" ]] && cp -p "${PLEX_DB_DIR}/$f" "$BK/"
  done
}

db_repair_one() {
  local db="$1"
  local base
  base="$(basename "$db")"

  echo "Repairing $base"
  local dump="${TMPDIR}/${base}.sql"
  local newdb="${TMPDIR}/${base}.new"

  "$SQLITE_BIN" "$db" .dump > "$dump"
  "$SQLITE_BIN" "$newdb" < "$dump"

  mv "$db" "${db}.damaged.$(date +%s)"
  mv "$newdb" "$db"
}

db_repair() {
  db_backup
  db_repair_one "$DB_MAIN"
  db_repair_one "$DB_BLOBS"
  db_reindex
}

db_vacuum() {
  echo "Vacuuming databases"
  "$SQLITE_BIN" "$DB_MAIN"  "VACUUM;"
  "$SQLITE_BIN" "$DB_BLOBS" "VACUUM;"
}

db_reindex() {
  echo "Reindexing databases"
  "$SQLITE_BIN" "$DB_MAIN"  "REINDEX;"
  "$SQLITE_BIN" "$DB_BLOBS" "REINDEX;"
}

db_auto() {
  if db_check; then
    echo "Databases OK — skipping repair"
  else
    echo "Damage detected — repairing"
    db_repair
  fi
  db_vacuum
  db_reindex
}

# ======================================================
# Dispatch
# ======================================================
case "$DBREPAIR_MODE" in
  automatic) db_auto ;;
  check)     db_check ;;
  vacuum)    db_vacuum ;;
  repair)    db_repair ;;
  reindex)   db_reindex ;;
  *)
    echo "ERROR: Unknown DBREPAIR_MODE=$DBREPAIR_MODE"
    exit 2
    ;;
esac

echo "=================================================="
echo " Plex DBRepair completed successfully"
echo "=================================================="
