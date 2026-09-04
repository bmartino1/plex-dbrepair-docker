#!/usr/bin/env bash
set -euo pipefail

############################################################
# Plex Database Repair – Native Docker Implementation
#
# Goals:
# - Use Plex SQLite whenever Plex-specific FTS is involved
# - Stop the target Plex container before any DB maintenance
# - Verify PRAGMA integrity_check actually returns "ok"
# - Back up databases with SQLite .backup
# - Check Plex FTS4 indexes using the same integrity-check
#   mechanism used by ChuckPa DBRepair
# - If enabled, repair damaged FTS by preserving the current
#   Plex FTS schema/triggers, recreating the virtual tables,
#   rebuilding from source content, and verifying afterward
############################################################

# ---------------------------------------------------------
# Environment defaults
# ---------------------------------------------------------
: "${DBREPAIR_MODE:=automatic}"        # automatic|check|vacuum|repair|reindex|ftscheck|ftsrepair|deflate|prune|manual
: "${ENABLE_BACKUPS:=true}"            # true|false
: "${RESTORE_LAST_BACKUP:=false}"      # true|false
: "${ALLOW_PLEX_KILL:=true}"
: "${RESTART_PLEX:=true}"

: "${ENABLE_FTS_CHECK:=true}"          # true|false
: "${ENABLE_FTS_REPAIR:=true}"         # true|false; only used when FTS check fails

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

# IMPORTANT: absolute path.  The old ./dbtmp value was relative
# to the container working directory, not the Plex DB directory.
DBTMP="${DBDIR}/dbtmp"

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
  log "$(printf '%-10s' "$1") : $(basename "$2")"
}

final_log() {
  log "=================================================="
  log " DBRepair completed"
  log " Log     : $LOGFILE"
  log " Backups : $BACKUP_ROOT"
  log "=================================================="
}

# ---------------------------------------------------------
# SQLite selection
# ---------------------------------------------------------
if [[ -x "/usr/lib/plexmediaserver/Plex SQLite" ]]; then
  SQLITE="/usr/lib/plexmediaserver/Plex SQLite"
  SQLITE_KIND="plex"
else
  SQLITE="$(command -v sqlite3 || true)"
  SQLITE_KIND="system"
fi

[[ -n "$SQLITE" && -x "$SQLITE" ]] || die "No usable SQLite binary found"

# ---------------------------------------------------------
# Safety checks
# ---------------------------------------------------------
[[ -d "$DBDIR" ]]  || die "DBDIR missing: $DBDIR"
[[ -f "$LIB_DB" ]] || die "Main DB missing: $LIB_DB"
[[ -f "$BLOB_DB" ]] || die "Blobs DB missing: $BLOB_DB"
[[ -w "$DBDIR" ]]  || die "DBDIR not writable: $DBDIR"

mkdir -p "$DBTMP"
export TMPDIR="$DBTMP"
export TMP="$DBTMP"

# PMS FTS uses Plex-specific ICU/collating tokenizers.  Do not try
# to inspect/recreate those tables with a generic sqlite3 binary.
if [[ "$ENABLE_FTS_CHECK" == "true" || "$ENABLE_FTS_REPAIR" == "true" ]]; then
  [[ "$SQLITE_KIND" == "plex" ]] || \
    die "FTS check/repair requires Plex SQLite; generic sqlite3 is not safe for Plex ICU FTS"
fi

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
log " FTS Check           : $ENABLE_FTS_CHECK"
log " FTS Auto Repair     : $ENABLE_FTS_REPAIR"
log " TMPDIR              : $DBTMP"

if [[ -f /opt/dbrepair/DBRepair.sh ]]; then
  UPSTREAM_VERSION="$(awk -F= '/^Version=/{gsub(/"/,"",$2); print $2; exit}' /opt/dbrepair/DBRepair.sh || true)"
  [[ -n "$UPSTREAM_VERSION" ]] && log " ChuckPa DBRepair     : $UPSTREAM_VERSION"
fi

# ---------------------------------------------------------
# Docker helpers
# ---------------------------------------------------------
docker_available() {
  [[ -S /var/run/docker.sock ]] && command -v docker >/dev/null 2>&1
}

is_excluded_container() {
  local name="$1" image="$2" ex
  IFS=',' read -ra EXCL <<< "$EXCLUDE_CONTAINER_NAMES"

  for ex in "${EXCL[@]}"; do
    [[ "$name" == "$ex" ]] && return 0
  done

  echo "$image" | grep -qiE "$EXCLUDE_IMAGE_REGEX" && return 0
  return 1
}

stop_plex_containers() {
  : > "$STOPPED_IDS_FILE"

  [[ "$ALLOW_PLEX_KILL" != "true" ]] && {
    log "ALLOW_PLEX_KILL=false — Plex must already be stopped externally"
    return 0
  }

  docker_available || die "Docker socket/CLI unavailable; cannot safely stop target Plex container"

  section "Stopping Plex containers (match: $PLEX_CONTAINER_MATCH)"

  local matched=0
  while read -r cid name image; do
    [[ -n "$cid" ]] || continue

    if is_excluded_container "$name" "$image"; then
      log "Skipping excluded container: $name"
      continue
    fi

    echo "$name $image" | grep -qiE "$PLEX_CONTAINER_MATCH" || continue
    matched=1

    log "Stopping Plex container: $name ($cid)"
    if ! docker stop "$cid" >/dev/null; then
      die "Failed to stop Plex container: $name ($cid)"
    fi

    if [[ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo unknown)" != "false" ]]; then
      die "Container still appears to be running after stop: $name ($cid)"
    fi

    echo "$cid" >> "$STOPPED_IDS_FILE"
    log "Stopped: $name ($cid)"
  done < <(docker ps --format '{{.ID}} {{.Names}} {{.Image}}')

  [[ "$matched" -eq 1 ]] || log "No running Plex container matched '$PLEX_CONTAINER_MATCH'"
}

restart_plex_containers() {
  [[ "$RESTART_PLEX" != "true" ]] && return 0
  docker_available || return 0

  [[ -s "$STOPPED_IDS_FILE" ]] || {
    log "No Plex containers were stopped — nothing to restart"
    return 0
  }

  section "Restarting Plex containers"
  while read -r cid; do
    [[ -n "$cid" ]] || continue
    if docker start "$cid" >/dev/null; then
      log "Started: $cid"
    else
      log "WARNING: failed to restart container: $cid"
    fi
  done < "$STOPPED_IDS_FILE"
}

trap 'rc=$?; restart_plex_containers || true; exit $rc' EXIT

# ---------------------------------------------------------
# SQLite core workers
# ---------------------------------------------------------
checkpoint_db() {
  local db="$1" result
  [[ -f "$db-wal" ]] || return 0

  if ! result="$("$SQLITE" "$db" 'PRAGMA wal_checkpoint(TRUNCATE);' 2>&1)"; then
    log "WAL checkpoint FAILED: $(basename "$db")"
    log "$result"
    return 1
  fi

  log "WAL checkpoint: $(basename "$db") -> $result"
}

check_db() {
  local db="$1" result

  if ! result="$("$SQLITE" "$db" 'PRAGMA integrity_check(1);' 2>&1)"; then
    log "SQLite integrity command FAILED: $(basename "$db")"
    log "$result"
    return 1
  fi

  if [[ "$result" == "ok" ]]; then
    log "Integrity OK: $(basename "$db")"
    return 0
  fi

  log "Integrity FAILED: $(basename "$db")"
  log "$result"
  return 1
}

check_core_all() {
  local failed=0
  check_db "$LIB_DB" || failed=1
  check_db "$BLOB_DB" || failed=1
  return "$failed"
}

vacuum_db() {
  checkpoint_db "$1"
  "$SQLITE" "$1" 'VACUUM;'
}

reindex_db() {
  checkpoint_db "$1"
  "$SQLITE" "$1" 'REINDEX;'
}

deflate_db() {
  checkpoint_db "$1"

  local tmp="$DBTMP/$(basename "$1").deflate-$TS"
  rm -f "$tmp"
  "$SQLITE" "$1" "VACUUM INTO '$tmp';"
  check_db "$tmp"

  # Preserve live DB ownership/mode by overwriting its contents.
  cat "$tmp" > "$1"
  rm -f "$tmp" "$1-wal" "$1-shm"
}

# ---------------------------------------------------------
# Backup / Restore
# ---------------------------------------------------------
latest_backup_dir() {
  ls -1dt "$BACKUP_ROOT"/* 2>/dev/null | head -1
}

backup_one_db() {
  local src="$1" dst="$2"
  checkpoint_db "$src"
  "$SQLITE" "$src" ".backup '$dst'"
  check_db "$dst"
}

backup_all() {
  [[ "$ENABLE_BACKUPS" != "true" ]] && {
    log "Backups disabled — skipping persistent backup"
    return 0
  }

  section "Backup databases"
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR" || true

  backup_one_db "$LIB_DB" "$BACKUP_DIR/$(basename "$LIB_DB")"
  backup_one_db "$BLOB_DB" "$BACKUP_DIR/$(basename "$BLOB_DB")"

  sha256sum \
    "$BACKUP_DIR/$(basename "$LIB_DB")" \
    "$BACKUP_DIR/$(basename "$BLOB_DB")" \
    > "$BACKUP_DIR/SHA256SUMS"

  log "Backup dir: $BACKUP_DIR"
}

restore_last_backup() {
  local last main_backup blob_backup
  last="$(latest_backup_dir)"
  [[ -d "$last" ]] || die "No backups found"

  main_backup="$last/$(basename "$LIB_DB")"
  blob_backup="$last/$(basename "$BLOB_DB")"

  [[ -f "$main_backup" ]] || die "Backup main DB missing: $main_backup"
  [[ -f "$blob_backup" ]] || die "Backup blobs DB missing: $blob_backup"

  section "Verify last backup"
  check_db "$main_backup" || die "Backup main DB failed integrity check"
  check_db "$blob_backup" || die "Backup blobs DB failed integrity check"

  section "Restore last backup"
  rm -f "$LIB_DB-wal" "$LIB_DB-shm" "$BLOB_DB-wal" "$BLOB_DB-shm"

  # Preserve destination permissions/ownership.
  cat "$main_backup" > "$LIB_DB"
  cat "$blob_backup" > "$BLOB_DB"

  check_core_all || die "Restored databases failed integrity verification"
  log "Restored: $last"
}

# ---------------------------------------------------------
# FTS helpers
# ---------------------------------------------------------
fts_table_list() {
  "$SQLITE" "$1" <<'SQL'
.mode list
SELECT name
FROM sqlite_master
WHERE type='table'
  AND sql IS NOT NULL
  AND lower(sql) LIKE 'create virtual table%using fts4%'
ORDER BY name;
SQL
}

other_fts_table_list() {
  "$SQLITE" "$1" <<'SQL'
.mode list
SELECT name || ' | ' || sql
FROM sqlite_master
WHERE type='table'
  AND sql IS NOT NULL
  AND lower(sql) LIKE 'create virtual table%using fts%'
  AND lower(sql) NOT LIKE 'create virtual table%using fts4%'
ORDER BY name;
SQL
}

check_fts_db() {
  local db="$1" label="$2" tables other table out failed=0

  tables="$(fts_table_list "$db")" || return 1

  if [[ -z "$tables" ]]; then
    other="$(other_fts_table_list "$db")" || return 1
    if [[ -n "$other" ]]; then
      log "FTS [$label]: unsupported/non-FTS4 virtual tables detected; refusing to assume they are healthy"
      while IFS= read -r table; do log "FTS [$label]: $table"; done <<< "$other"
      return 1
    fi
    log "FTS [$label]: no FTS virtual tables found"
    return 0
  fi

  while IFS= read -r table; do
    [[ -n "$table" ]] || continue

    # sqlite_master supplied the name, but validate before injecting it
    # as an identifier into the FTS special command.
    if [[ ! "$table" =~ ^[A-Za-z0-9_]+$ ]]; then
      log "FTS [$label]: refusing unsafe table name: $table"
      failed=1
      continue
    fi

    if out="$("$SQLITE" "$db" "INSERT INTO $table($table) VALUES('integrity-check');" 2>&1)"; then
      if [[ -z "$out" ]]; then
        log "FTS [$label]: $table - OK"
      else
        log "FTS [$label]: $table - DAMAGED"
        log "FTS [$label]: $out"
        failed=1
      fi
    else
      log "FTS [$label]: $table - DAMAGED"
      log "FTS [$label]: $out"
      failed=1
    fi
  done <<< "$tables"

  return "$failed"
}

check_fts_all() {
  [[ "$ENABLE_FTS_CHECK" == "true" ]] || {
    log "FTS checks disabled"
    return 0
  }

  local failed=0
  check_fts_db "$LIB_DB" "main" || failed=1
  check_fts_db "$BLOB_DB" "blobs" || failed=1
  return "$failed"
}

restore_fts_snapshot() {
  local db="$1" snapshot="$2"
  log "Restoring FTS safety snapshot for $(basename "$db")"
  rm -f "$db-wal" "$db-shm"
  cat "$snapshot" > "$db"
}

fresh_rebuild_fts_db() {
  local db="$1" label="$2"
  local tables work snapshot schema triggers drop_triggers drop_tables rebuild_sql run_sql

  check_db "$db" || {
    log "FTS [$label]: core database is not clean; refusing FTS rebuild"
    return 1
  }

  tables="$(fts_table_list "$db")" || return 1
  if [[ -z "$tables" ]]; then
    log "FTS [$label]: no FTS4 tables to rebuild"
    return 0
  fi

  work="$(mktemp -d "$DBTMP/fts-${label}-${TS}-XXXXXX")"
  snapshot="$work/pre-fts.db"
  schema="$work/fts-tables.sql"
  triggers="$work/fts-triggers.sql"
  drop_triggers="$work/drop-triggers.sql"
  drop_tables="$work/drop-tables.sql"
  rebuild_sql="$work/rebuild.sql"
  run_sql="$work/run.sql"

  log "FTS [$label]: safety snapshot -> $snapshot"
  "$SQLITE" "$db" ".backup '$snapshot'"
  check_db "$snapshot" >/dev/null || {
    log "FTS [$label]: safety snapshot failed integrity verification"
    log "FTS [$label]: work files retained at $work"
    return 1
  }

  # Preserve the exact FTS4 CREATE statements from the current Plex DB.
  "$SQLITE" "$db" <<'SQL' > "$schema"
.mode list
SELECT sql || ';'
FROM sqlite_master
WHERE type='table'
  AND sql IS NOT NULL
  AND lower(sql) LIKE 'create virtual table%using fts4%'
ORDER BY name;
SQL

  # Preserve only triggers which reference one of the current FTS4 tables.
  "$SQLITE" "$db" <<'SQL' > "$triggers"
.mode list
SELECT DISTINCT t.sql || ';'
FROM sqlite_master AS t
WHERE t.type='trigger'
  AND t.sql IS NOT NULL
  AND EXISTS (
    SELECT 1
    FROM sqlite_master AS f
    WHERE f.type='table'
      AND f.sql IS NOT NULL
      AND lower(f.sql) LIKE 'create virtual table%using fts4%'
      AND instr(t.sql, f.name) > 0
  )
ORDER BY t.name;
SQL

  "$SQLITE" "$db" <<'SQL' > "$drop_triggers"
.mode list
SELECT DISTINCT 'DROP TRIGGER IF EXISTS "' || replace(t.name,'"','""') || '";'
FROM sqlite_master AS t
WHERE t.type='trigger'
  AND t.sql IS NOT NULL
  AND EXISTS (
    SELECT 1
    FROM sqlite_master AS f
    WHERE f.type='table'
      AND f.sql IS NOT NULL
      AND lower(f.sql) LIKE 'create virtual table%using fts4%'
      AND instr(t.sql, f.name) > 0
  )
ORDER BY t.name;
SQL

  "$SQLITE" "$db" <<'SQL' > "$drop_tables"
.mode list
SELECT 'DROP TABLE IF EXISTS "' || replace(name,'"','""') || '";'
FROM sqlite_master
WHERE type='table'
  AND sql IS NOT NULL
  AND lower(sql) LIKE 'create virtual table%using fts4%'
ORDER BY name;
SQL

  "$SQLITE" "$db" <<'SQL' > "$rebuild_sql"
.mode list
SELECT 'INSERT INTO "' || replace(name,'"','""') || '"("' ||
       replace(name,'"','""') || '") VALUES(''rebuild'');'
FROM sqlite_master
WHERE type='table'
  AND sql IS NOT NULL
  AND lower(sql) LIKE 'create virtual table%using fts4%'
ORDER BY name;
SQL

  [[ -s "$schema" ]] || {
    log "FTS [$label]: failed to capture FTS schema; refusing rebuild"
    log "FTS [$label]: work files retained at $work"
    return 1
  }

  {
    echo '.bail on'
    echo 'BEGIN IMMEDIATE;'
    cat "$drop_triggers"
    cat "$drop_tables"
    cat "$schema"
    cat "$rebuild_sql"
    cat "$triggers"
    echo 'COMMIT;'
  } > "$run_sql"

  section "Fresh FTS rebuild: $label"
  log "FTS [$label]: preserving current schema/triggers and recreating FTS4 virtual tables"

  # DDL + rebuild + trigger restore are committed as one SQLite transaction.
  if ! "$SQLITE" "$db" < "$run_sql"; then
    log "FTS [$label]: rebuild SQL failed; restoring snapshot"
    restore_fts_snapshot "$db" "$snapshot"
    check_db "$db" || true
    log "FTS [$label]: work files retained at $work"
    return 1
  fi

  if ! check_db "$db" || ! check_fts_db "$db" "$label"; then
    log "FTS [$label]: post-rebuild verification failed; restoring snapshot"
    restore_fts_snapshot "$db" "$snapshot"
    check_db "$db" || true
    log "FTS [$label]: work files retained at $work"
    return 1
  fi

  log "FTS [$label]: fresh rebuild verified clean"
  rm -rf "$work"
}

repair_fts_if_needed() {
  [[ "$ENABLE_FTS_CHECK" == "true" ]] || {
    log "FTS checks disabled"
    return 0
  }

  local failed=0

  if ! check_fts_db "$LIB_DB" "main"; then
    if [[ "$ENABLE_FTS_REPAIR" == "true" ]]; then
      fresh_rebuild_fts_db "$LIB_DB" "main" || failed=1
    else
      log "FTS [main]: damaged and ENABLE_FTS_REPAIR=false"
      failed=1
    fi
  fi

  if ! check_fts_db "$BLOB_DB" "blobs"; then
    if [[ "$ENABLE_FTS_REPAIR" == "true" ]]; then
      fresh_rebuild_fts_db "$BLOB_DB" "blobs" || failed=1
    else
      log "FTS [blobs]: damaged and ENABLE_FTS_REPAIR=false"
      failed=1
    fi
  fi

  return "$failed"
}

# ---------------------------------------------------------
# Execute
# ---------------------------------------------------------
stop_plex_containers

if [[ "$RESTORE_LAST_BACKUP" == "true" ]]; then
  restore_last_backup
  final_log
  exit 0
fi

case "$DBREPAIR_MODE" in
  manual)
    section "Manual mode"
    log "Starting detached screen session"
    screen -dmS dbrepair bash -i
    log "Attach with: screen -r dbrepair"
    tail -f /dev/null
    ;;

  check)
    section "Integrity + FTS check"
    check_core_all
    check_fts_all
    final_log
    ;;

  ftscheck)
    section "FTS check"
    check_core_all
    check_fts_all
    final_log
    ;;

  ftsrepair)
    section "FTS check / conditional fresh repair"
    backup_all
    check_core_all
    repair_fts_if_needed
    check_core_all
    check_fts_all
    final_log
    ;;

  vacuum)
    section "Vacuum"
    backup_all
    step "Vacuum" "$LIB_DB";  vacuum_db "$LIB_DB"
    step "Vacuum" "$BLOB_DB"; vacuum_db "$BLOB_DB"
    check_core_all
    final_log
    ;;

  repair)
    section "Repair / Optimize"
    backup_all
    step "Vacuum" "$LIB_DB";  vacuum_db "$LIB_DB"
    step "Vacuum" "$BLOB_DB"; vacuum_db "$BLOB_DB"
    check_core_all
    final_log
    ;;

  reindex)
    section "Reindex + FTS verification"
    backup_all
    check_core_all
    step "Reindex" "$LIB_DB";  reindex_db "$LIB_DB"
    step "Reindex" "$BLOB_DB"; reindex_db "$BLOB_DB"
    repair_fts_if_needed
    check_core_all
    check_fts_all
    final_log
    ;;

  deflate)
    section "Deflate"
    backup_all
    check_core_all
    step "Deflate" "$LIB_DB";  deflate_db "$LIB_DB"
    step "Deflate" "$BLOB_DB"; deflate_db "$BLOB_DB"
    check_core_all
    check_fts_all
    final_log
    ;;

  prune)
    section "Prune PhotoTranscoder cache"
    if [[ -d "$PLEX_ROOT/Cache/PhotoTranscoder" ]]; then
      find "$PLEX_ROOT/Cache/PhotoTranscoder" -type f -mtime "+${PRUNE_DAYS}" -delete
    else
      log "PhotoTranscoder cache not found — nothing to prune"
    fi
    final_log
    ;;

  automatic)
    section "Automatic (check -> vacuum -> reindex -> FTS check/repair -> verify)"
    backup_all

    step "Check" "$LIB_DB";  check_db "$LIB_DB"
    step "Check" "$BLOB_DB"; check_db "$BLOB_DB"

    step "Vacuum" "$LIB_DB";  vacuum_db "$LIB_DB"
    step "Vacuum" "$BLOB_DB"; vacuum_db "$BLOB_DB"

    step "Reindex" "$LIB_DB";  reindex_db "$LIB_DB"
    step "Reindex" "$BLOB_DB"; reindex_db "$BLOB_DB"

    repair_fts_if_needed

    section "Final verification"
    check_core_all
    check_fts_all
    final_log
    ;;

  *)
    log "WARNING: unknown DBREPAIR_MODE='$DBREPAIR_MODE'; falling back to automatic"
    section "Automatic (check -> vacuum -> reindex -> FTS check/repair -> verify)"
    backup_all

    check_core_all
    vacuum_db "$LIB_DB"
    vacuum_db "$BLOB_DB"
    reindex_db "$LIB_DB"
    reindex_db "$BLOB_DB"
    repair_fts_if_needed
    check_core_all
    check_fts_all
    final_log
    ;;
esac
