#!/usr/bin/env bash
set -Eeuo pipefail

: "${DBREPAIR_MODE:=automatic}"
: "${ENABLE_BACKUPS:=true}"
: "${RESTORE_LAST_BACKUP:=false}"
: "${ALLOW_PLEX_KILL:=true}"
: "${RESTART_PLEX:=true}"
: "${ENABLE_FTS_CHECK:=true}"
: "${ENABLE_FTS_REPAIR:=true}"
: "${PLEX_MOUNT:=/config}"
: "${PLEX_REL:=Library/Application Support/Plex Media Server}"
: "${PRUNE_DAYS:=30}"
: "${PLEX_CONTAINER_MATCH:=plex}"
: "${PLEX_CONTAINER_NAME:=auto}"
: "${EXCLUDE_CONTAINER_NAMES:=dbrepair,plex-dbrepair}"
: "${EXCLUDE_IMAGE_REGEX:=plex-dbrepair}"
: "${DBREPAIR_TIMEOUT:=7200}"
: "${STOP_TIMEOUT:=90}"
: "${LOG_DIR:=/logs}"
: "${RESTART_FALLBACK:=true}"

mkdir -p "$LOG_DIR" 2>/dev/null || { echo "Cannot write log directory: $LOG_DIR" >&2; exit 1; }
LOG_FILE="$LOG_DIR/dbrepair-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
touch "$LOG_FILE" || exit 1
exec > >(tee -a "$LOG_FILE") 2>&1
log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }
boolean() { [[ "$1" == true || "$1" == false ]] || die "Invalid boolean: $1"; }
for b in ENABLE_BACKUPS RESTORE_LAST_BACKUP ALLOW_PLEX_KILL RESTART_PLEX RESTART_FALLBACK; do boolean "${!b}"; done
[[ "$PRUNE_DAYS" =~ ^[0-9]+$ ]] && (( PRUNE_DAYS >= 1 && PRUNE_DAYS <= 999 )) || die "PRUNE_DAYS must be 1..999"
for t in DBREPAIR_TIMEOUT STOP_TIMEOUT; do [[ "${!t}" =~ ^[0-9]+$ ]] && (( ${!t} > 0 )) || die "Invalid $t"; done
[[ "$PLEX_MOUNT" == /* && "$PLEX_MOUNT" != *'..'* ]] || die "PLEX_MOUNT must be an absolute container path"
[[ "$PLEX_REL" != /* && "$PLEX_REL" != *'..'* ]] || die "PLEX_REL must be a relative path"
[[ -S /var/run/docker.sock ]] || die "Mount /var/run/docker.sock into this container"
docker info >/dev/null 2>&1 || die "Cannot connect to Docker daemon"

case "${DBREPAIR_MODE,,}" in
  automatic|auto) MODE=auto ;;
  check|vacuum|repair|reindex|deflate|prune|manual|ftscheck|ftsrepair) MODE="${DBREPAIR_MODE,,}" ;;
  *) log "Unrecognized DBREPAIR_MODE '$DBREPAIR_MODE'; defaulting to automatic"; MODE=auto ;;
esac
case "$MODE" in
  ftscheck) log "FTS check is included in 'check' with DBRepair 26.10.00"; MODE=check ;;
  ftsrepair) log "FTS index reconstruction is included in 'reindex'"; MODE=reindex ;;
esac
[[ "$RESTORE_LAST_BACKUP" == false ]] || die "RESTORE_LAST_BACKUP is not automated: requires explicit backup selection using DBRepair 'replace'"
[[ "$MODE" != manual ]] || die "manual mode is intentionally disabled for unattended CA runs; use docker exec -it on the Plex container"

# Discover by container name or image, excluding ourselves/repair tools.
mapfile -t IDS < <(docker ps --format '{{.ID}}')
MATCHES=()
self_id="$(hostname)"
for id in "${IDS[@]}"; do
  [[ "$id" == "${self_id:0:12}" || "$self_id" == "$id"* ]] && continue
  obj="$(docker inspect "$id")" || continue
  name="$(jq -r '.[0].Name | ltrimstr("/")' <<<"$obj")"
  image="$(jq -r '.[0].Config.Image' <<<"$obj")"
  skip=false
  IFS=, read -ra excluded <<<"$EXCLUDE_CONTAINER_NAMES"
  for item in "${excluded[@]}"; do
    [[ -n "$item" && "${name,,}" == *"${item,,}"* ]] && skip=true
  done
  [[ "$image" =~ $EXCLUDE_IMAGE_REGEX ]] && skip=true
  [[ "$skip" == true ]] && continue
  if [[ "$PLEX_CONTAINER_NAME" != auto && -n "$PLEX_CONTAINER_NAME" ]]; then
    [[ "$name" == "$PLEX_CONTAINER_NAME" ]] || continue
  else
    [[ "${name,,}" == *"${PLEX_CONTAINER_MATCH,,}"* || "${image,,}" == *plex* ]] || continue
  fi
  # Verify candidate has the Plex config directory and databases.
  if docker exec --user 0 "$id" test -f "$PLEX_MOUNT/$PLEX_REL/Plug-in Support/Databases/com.plexapp.plugins.library.db" 2>/dev/null; then
    MATCHES+=("$id")
    log "Candidate: $name ($image), id=$id"
  else
    log "Skipping $name ($image): no Plex DB at configured path"
  fi
done
(( ${#MATCHES[@]} == 1 )) || die "Expected exactly one running Plex container; found ${#MATCHES[@]}. Set PLEX_CONTAINER_NAME to exact name; inspect PLEX_MOUNT/PLEX_REL if none."
TARGET="${MATCHES[0]}"
NAME="$(docker inspect -f '{{.Name}}' "$TARGET" | sed 's#^/##')"
IMAGE="$(docker inspect -f '{{.Config.Image}}' "$TARGET")"
DB_DIR="$PLEX_MOUNT/$PLEX_REL/Plug-in Support/Databases"
REMOTE_DIR='/tmp/plex-dbrepair-runner'
REMOTE_BIN="$REMOTE_DIR/DBRepair"
WAS_RUNNING=true
SHUTDOWN_REQUESTED=false
MAINTENANCE_ACTIVE=false
CLEANUP_DONE=false
RESULT=0

running() { [[ "$(docker inspect -f '{{.State.Running}}' "$TARGET" 2>/dev/null || echo false)" == true ]]; }
pms_running() {
  running || return 1
  docker exec --user 0 "$TARGET" /bin/sh -c 'pidof "Plex Media Server" >/dev/null 2>&1' >/dev/null 2>&1
}
# Entrypoint cleans only its own temporary files; DO NOT try to restart automatically
# on interruption before the maintenance tool has stopped writing.
cleanup() {
  local code=$?
  trap - EXIT ERR INT TERM
  if [[ "$MAINTENANCE_ACTIVE" == true ]]; then
    log "WARNING: maintenance was interrupted; NOT restarting Plex automatically. Investigate and restore manually."
  elif [[ "$SHUTDOWN_REQUESTED" == true && "$RESTART_PLEX" == true ]]; then
    if running; then
      log "Restoring Plex using Docker restart (independent of image's internal supervisor)"
      docker restart --time 30 "$TARGET" >/dev/null || log 'ERROR: Docker restart failed'
    elif [[ "$RESTART_FALLBACK" == true ]]; then
      log "Restoring exited Plex container using Docker start"
      docker start "$TARGET" >/dev/null || log 'ERROR: Docker start failed'
    else
      log 'Plex container stopped; restart fallback disabled'
    fi
  fi
  if running && [[ "$MAINTENANCE_ACTIVE" != true ]]; then
    docker exec --user 0 "$TARGET" /bin/sh -c 'rm -rf /tmp/plex-dbrepair-runner' >/dev/null 2>&1 || true
  fi
  log "Finished exit=$code; log=$LOG_FILE"
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log "Plex DBRepair version: $(/opt/dbrepair/DBRepair --version 2>&1 | head -1 || true)"
log "Target: name=$NAME image=$IMAGE id=$TARGET mode=$MODE"
log "Paths: mount=$PLEX_MOUNT relative=$PLEX_REL databases=$DB_DIR"
log "Mounts: $(docker inspect "$TARGET" | jq -c '.[0].Mounts | map({Type,Source,Destination,Mode,RW})')"
log "Restart policy: $(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$TARGET")"
log "Original Plex container running=$WAS_RUNNING"

# DBRepair binary copied into target: no secondary Plex config mount on our side.
# Native binary must match target machine architecture and target libc requirements.
TARGET_ARCH="$(docker image inspect "$(docker inspect -f '{{.Image}}' "$TARGET")" -f '{{.Architecture}}' 2>/dev/null || true)"
[[ -z "$TARGET_ARCH" || "$TARGET_ARCH" == "$(dpkg --print-architecture)" ]] || die "Architecture mismatch: Plex=$TARGET_ARCH repair=$(dpkg --print-architecture)"
docker exec --user 0 "$TARGET" /bin/sh -c 'mkdir -p /tmp/plex-dbrepair-runner' || die "Cannot create runner directory in Plex"
docker cp /opt/dbrepair/DBRepair "$TARGET:$REMOTE_BIN" || die "Cannot copy DBRepair to Plex"
docker exec --user 0 "$TARGET" /bin/sh -c 'chmod 755 /tmp/plex-dbrepair-runner/DBRepair' || die 'Cannot chmod runner'
docker exec --user 0 "$TARGET" "$REMOTE_BIN" --version || die 'DBRepair binary cannot execute in target (architecture/libc incompatibility)'

# Only read-only check can run without shutdown; DBRepair check itself can check
# live DB state but consistent checks are safer with PMS stopped, so all modes stop.
log 'Requesting supported PMS shutdown via DBRepair stop'
if timeout 120 docker exec --user 0 "$TARGET" "$REMOTE_BIN" stop; then
  SHUTDOWN_REQUESTED=true
else
  log 'DBRepair stop unavailable or failed'
fi
if pms_running; then
  [[ "$ALLOW_PLEX_KILL" == true ]] || die 'PMS still running and ALLOW_PLEX_KILL=false'
  log 'Sending SIGTERM to Plex Media Server inside its own container'
  docker exec --user 0 "$TARGET" /bin/sh -c 'pids=$(pidof "Plex Media Server" 2>/dev/null || true); [ -n "$pids" ] && kill -TERM $pids' || die 'Unable to signal Plex process'
  SHUTDOWN_REQUESTED=true
fi
log "Waiting up to $STOP_TIMEOUT seconds for PMS to exit"
for ((i=0; i<STOP_TIMEOUT; i++)); do
  running || die 'Plex container exited during process shutdown; aborting (no offline fallback)'
  if ! pms_running; then break; fi
  sleep 1
done
running || die 'Plex container stopped; cannot docker exec; aborting'
! pms_running || die 'Plex respawned or failed to stop; refusing database access'
SHUTDOWN_REQUESTED=true

# Optional cold backup, in config tree but OUTSIDE Databases; tar excludes itself.
if [[ "$ENABLE_BACKUPS" == true && "$MODE" != prune ]]; then
  log 'Creating cold backup of Databases before maintenance (including SQLite WAL files)'
  backup_name="dbrepair-pre-${MODE}-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
  docker exec --user 0 "$TARGET" /bin/sh -c '
    set -eu
    base="$1"; dest="$base/DBRepair-Backups"; mkdir -p "$dest"
    tar -czf "$dest/$2.partial" -C "$base/Plug-in Support" Databases
    mv "$dest/$2.partial" "$dest/$2"
    tar -tzf "$dest/$2" >/dev/null
    echo "Backup saved: $dest/$2"
  ' _ "$PLEX_MOUNT/$PLEX_REL" "$backup_name" || die 'Backup creation/verification failed; refusing maintenance'
fi

log "Executing mode=$MODE; max duration=${DBREPAIR_TIMEOUT}s"
args=(--databases "$DB_DIR" --notrunning)
if [[ "$MODE" == prune ]]; then args+=(--cacheage "$PRUNE_DAYS"); fi
# The explicit database directory turns on DBRepair manual configuration mode;
# --notrunning is only used AFTER verification that the actual PMS process stopped.
MAINTENANCE_ACTIVE=true
set +e
timeout --signal=TERM --kill-after=30 "$DBREPAIR_TIMEOUT" \
  docker exec --user 0 "$TARGET" "$REMOTE_BIN" "${args[@]}" "$MODE"
RESULT=$?
set -e
MAINTENANCE_ACTIVE=false
if [[ "$RESULT" -ne 0 ]]; then
  log "ERROR: DBRepair failed with exit=$RESULT (124 means timed out). Review database before restarting."
  # Fail closed on timeout/error; automatic restart of possibly inconsistent DB is dangerous.
  SHUTDOWN_REQUESTED=false
  exit "$RESULT"
fi
log 'DBRepair finished successfully'
if [[ "$RESTART_PLEX" == false ]]; then
  SHUTDOWN_REQUESTED=false
  log 'RESTART_PLEX=false; Plex remains stopped inside its container'
fi
