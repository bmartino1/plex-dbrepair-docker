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
: "${PLEX_CONTAINER_NAME:=plex}"    # match plex containers

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

# Reset logfile every run
: > "${LOGFILE}"

# ======================================================
# STOP ALL PLEX CONTAINERS (EXCEPT THIS ONE)
# ======================================================
echo "Stopping Plex containers..." | tee -a "${LOGFILE}"

SELF_CID="$(cat /proc/self/cgroup | grep docker | head -n1 | sed 's#.*/##')"

docker ps --format '{{.ID}} {{.Names}} {{.Image}}' \
| grep -i "${PLEX_CONTAINER_NAME}" \
| while read -r CID NAME IMAGE; do
    if [[ "${CID}" != "${SELF_CID}" ]]; then
      echo "Disabling restart + stopping Plex container: ${NAME} (${CID})" \
        | tee -a "${LOGFILE}"
      docker update --restart=no "${CID}" >/dev/null 2>&1 || true
      docker stop "${CID}" || true
    fi
  done

echo "All Plex containers stopped." | tee -a "${LOGFILE}"

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
# Heartbeat (stdout + logfile)
# ======================================================
heartbeat() {
  while true; do
    echo "$(date '+%Y-%m-%d %H:%M:%S') - DBRepair running, please be patient…" \
      | tee -a "${LOGFILE}"
    sleep "${HEARTBEAT_INTERVAL}"
  done
}

heartbeat &
HB_PID=$!
trap 'kill ${HB_PID} 2>/dev/null || true' EXIT

# ======================================================
# Run DBRepair (REAL TTY, SCRIPTED MODE)
# ======================================================
export Scripted=1
export LOGFILE

echo "--------------------------------------------------" | tee -a "${LOGFILE}"
echo "DBREPAIR COMMAND:" | tee -a "${LOGFILE}"
echo "  ./DBRepair.sh ${DBREPAIR_ARGS[*]}" | tee -a "${LOGFILE}"
echo "--------------------------------------------------" | tee -a "${LOGFILE}"

set +e
script -q -e -c \
  "stdbuf -oL -eL ./DBRepair.sh ${DBREPAIR_ARGS[*]}" \
  /dev/null \
  2>&1 | tee -a "${LOGFILE}"
RC=${PIPESTATUS[0]}
set -e

echo "--------------------------------------------------" | tee -a "${LOGFILE}"
echo "DBRepair finished with exit code ${RC}" | tee -a "${LOGFILE}"

exit "${RC}"
