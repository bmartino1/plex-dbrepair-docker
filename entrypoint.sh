#!/usr/bin/env bash
set -euo pipefail

# ======================================================
# Docker environment variables
# ======================================================
: "${PLEX_DB_DIR:=/plexdb}"
: "${PLEX_DB_FILE:=com.plexapp.plugins.library.db}"
: "${LOG_DIR:=/logs}"
: "${SQLITE_BIN:=/usr/bin/sqlite3}"

: "${DBREPAIR_MODE:=automatic}"     # automatic | check | vacuum | repair | reindex
: "${DBREPAIR_UPDATE:=false}"       # true | false
: "${SHOW_LOG:=true}"               # true | false
: "${HEARTBEAT_INTERVAL:=300}"      # seconds

# Optional: Unraid usually provides this
: "${HOST_CONTAINERNAME:=}"         # e.g. "dbrepair"

DB_PATH="${PLEX_DB_DIR}/${PLEX_DB_FILE}"
LOGFILE="${LOG_DIR}/dbrepair.log"

# ======================================================
# Map mode → DBRepair scripted command (DOCUMENTED)
# ======================================================
case "${DBREPAIR_MODE}" in
  automatic) MODE_CMD="auto" ;;
  check)     MODE_CMD="check" ;;
  vacuum)    MODE_CMD="vacuum" ;;
  repair)    MODE_CMD="repair" ;;
  reindex)   MODE_CMD="reindex" ;;
  *)
    echo "WARNING: Invalid DBREPAIR_MODE='${DBREPAIR_MODE}', defaulting to automatic"
    MODE_CMD="auto"
    DBREPAIR_MODE="automatic"
    ;;
esac

# ======================================================
# Banner
# ======================================================
echo "=================================================="
echo " Plex DBRepair Docker"
echo "=================================================="
echo " Plex DB Dir    : ${PLEX_DB_DIR}"
echo " DB Path        : ${DB_PATH}"
echo " Mode           : ${DBREPAIR_MODE}"
echo " Update Script  : ${DBREPAIR_UPDATE}"
echo " Show Log       : ${SHOW_LOG}"
echo " Heartbeat      : every ${HEARTBEAT_INTERVAL}s"
echo " Log File       : ${LOGFILE}"
echo "=================================================="

# ======================================================
# SAFETY CHECKS (DO NOT REMOVE)
# ======================================================
[[ -d "${PLEX_DB_DIR}" ]] || { echo "ERROR: Plex DB directory missing"; exit 1; }
[[ -f "${DB_PATH}" ]]     || { echo "ERROR: Plex DB file missing"; exit 1; }
[[ -x "${SQLITE_BIN}" ]]  || { echo "ERROR: sqlite3 binary missing"; exit 1; }
[[ -S /var/run/docker.sock ]] || { echo "ERROR: docker.sock not mounted"; exit 1; }

mkdir -p "${LOG_DIR}"
cd /opt/dbrepair

# Reset log every run
: > "${LOGFILE}"

# ======================================================
# Identify THIS container (robust)
# ======================================================
SELF_ID_FULL="$(awk -F/ '/docker/ {print $NF; exit}' /proc/self/cgroup || true)"
SELF_ID_SHORT="${SELF_ID_FULL:0:12}"
SELF_NAME="$(hostname)"

echo "Self container detection:" | tee -a "${LOGFILE}"
echo "  SELF_ID_FULL : ${SELF_ID_FULL:-unknown}" | tee -a "${LOGFILE}"
echo "  SELF_ID_SHORT: ${SELF_ID_SHORT:-unknown}" | tee -a "${LOGFILE}"
echo "  HOSTNAME     : ${SELF_NAME}" | tee -a "${LOGFILE}"
[[ -n "${HOST_CONTAINERNAME}" ]] && echo "  HOST_CONTAINERNAME: ${HOST_CONTAINERNAME}" | tee -a "${LOGFILE}"

# ======================================================
# STOP ALL PLEX INSTANCES (containers + stray processes)
# ======================================================
echo "Stopping ALL Plex instances..." | tee -a "${LOGFILE}"

# Stop containers that look like Plex, but DO NOT stop self or plex-dbrepair
docker ps --format '{{.ID}} {{.Names}} {{.Image}}' | while read -r CID NAME IMAGE; do
  # Exclude self by ID prefix
  if [[ -n "${SELF_ID_SHORT}" && "${CID}" == "${SELF_ID_SHORT}"* ]]; then
    continue
  fi
  # Exclude self by hostname name match (best-effort)
  if [[ "${NAME}" == "${SELF_NAME}" ]]; then
    continue
  fi
  # Exclude if Unraid gave us container name and this matches
  if [[ -n "${HOST_CONTAINERNAME}" && "${NAME}" == "${HOST_CONTAINERNAME}" ]]; then
    continue
  fi
  # Exclude our own image
  if echo "${IMAGE}" | grep -qiE 'plex-dbrepair'; then
    continue
  fi

  # Match Plex containers (name or image)
  if echo "${NAME}" | grep -qiE 'plex' || echo "${IMAGE}" | grep -qiE '(^|/|-)plex(:|$)'; then
    echo "Disabling restart + stopping Plex container: ${NAME} (${CID}) image=${IMAGE}" \
      | tee -a "${LOGFILE}"
    docker update --restart=no "${CID}" >/dev/null 2>&1 || true
    docker stop "${CID}" >/dev/null 2>&1 || true
  fi
done

# Kill stray PMS processes (rare, but safe)
if pgrep -f "Plex Media Server" >/dev/null 2>&1; then
  echo "Killing stray Plex Media Server processes..." | tee -a "${LOGFILE}"
  pkill -TERM -f "Plex Media Server" || true
  sleep 3
  pkill -9 -f "Plex Media Server" || true
fi

echo "Plex shutdown complete." | tee -a "${LOGFILE}"

# ======================================================
# Build DBRepair argument list (SCRIPTED MODE)
# ======================================================
DBREPAIR_ARGS=(
  "--sqlite" "${SQLITE_BIN}"
  "--databases" "${PLEX_DB_DIR}"
)

[[ "${DBREPAIR_UPDATE}" == "true" ]] && DBREPAIR_ARGS+=( "update" )
DBREPAIR_ARGS+=( "${MODE_CMD}" )
[[ "${SHOW_LOG}" == "true" ]] && DBREPAIR_ARGS+=( "show" )
DBREPAIR_ARGS+=( "exit" )

# ======================================================
# Heartbeat (runs WHILE DBRepair executes)
# ======================================================
heartbeat() {
  while true; do
    echo "$(date '+%Y-%m-%d %H:%M:%S') - DBRepair running, please be patient…" \
      | tee -a "${LOGFILE}"
    sleep "${HEARTBEAT_INTERVAL}"
  done
}

# ======================================================
# Run DBRepair (REAL TTY, SCRIPTED MODE)
# ======================================================
export Scripted=1
export LOGFILE

echo "--------------------------------------------------" | tee -a "${LOGFILE}"
echo "DBREPAIR COMMAND:" | tee -a "${LOGFILE}"
echo "  ./DBRepair.sh ${DBREPAIR_ARGS[*]}" | tee -a "${LOGFILE}"
echo "--------------------------------------------------" | tee -a "${LOGFILE}"

heartbeat &
HB_PID=$!

set +e
script -q -e -c \
  "stdbuf -oL -eL ./DBRepair.sh ${DBREPAIR_ARGS[*]}" \
  /dev/null \
  2>&1 | tee -a "${LOGFILE}"
RC=${PIPESTATUS[0]}
set -e

kill "${HB_PID}" 2>/dev/null || true

echo "--------------------------------------------------" | tee -a "${LOGFILE}"
echo "DBRepair finished with exit code ${RC}" | tee -a "${LOGFILE}"

exit "${RC}"
