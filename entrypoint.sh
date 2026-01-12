#!/usr/bin/env bash
set -euo pipefail

# ======================================================
# Docker environment variables
# ======================================================
: "${PLEX_DB_DIR:=/plexdb}"
: "${PLEX_DB_FILE:=com.plexapp.plugins.library.db}"
: "${LOG_DIR:=/logs}"

: "${DBREPAIR_MODE:=automatic}"     # automatic | check | vacuum | repair | reindex
: "${DBREPAIR_UPDATE:=false}"       # true | false  (runs 'update' / menu 88 before doing work)
: "${SHOW_LOG:=true}"               # true | false  (runs 'show' / menu 10 before exit)
: "${HEARTBEAT_INTERVAL:=300}"      # seconds (default 5 minutes)

# Where sqlite3 is inside THIS container
: "${SQLITE_BIN:=/usr/bin/sqlite3}"

DB_PATH="${PLEX_DB_DIR}/${PLEX_DB_FILE}"
DOCKER_LOG_FILE="${LOG_DIR}/dbrepair.log"

# ======================================================
# Map DBREPAIR_MODE -> scripted command
# DBRepair supports command-line args equal to menu commands.
# Example shown in README: ./DBRepair.sh stop auto start exit
# ======================================================
case "${DBREPAIR_MODE}" in
  automatic) MODE_CMD="auto" ;;
  check)     MODE_CMD="check" ;;
  vacuum)    MODE_CMD="vacuum" ;;
  repair)    MODE_CMD="repair" ;;
  reindex)   MODE_CMD="reindex" ;;
  *)
    echo "WARNING: Invalid DBREPAIR_MODE='${DBREPAIR_MODE}', defaulting to 'automatic'"
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
echo " Plex DB Dir     : ${PLEX_DB_DIR}"
echo " DB File         : ${PLEX_DB_FILE}"
echo " DB Path         : ${DB_PATH}"
echo " Mode            : ${DBREPAIR_MODE} (script cmd: ${MODE_CMD})"
echo " Update Script   : ${DBREPAIR_UPDATE}"
echo " Show Tool Log   : ${SHOW_LOG}"
echo " Heartbeat       : every ${HEARTBEAT_INTERVAL}s"
echo " Docker Log File : ${DOCKER_LOG_FILE}"
echo " SQLite Bin      : ${SQLITE_BIN}"
echo "=================================================="

# ======================================================
# SAFETY CHECKS (DO NOT REMOVE)
# ======================================================
[[ -d "${PLEX_DB_DIR}" ]] || { echo "ERROR: Plex DB directory missing: ${PLEX_DB_DIR}"; exit 1; }
[[ -f "${DB_PATH}" ]]     || { echo "ERROR: Plex DB file missing: ${DB_PATH}"; exit 1; }
[[ -x "${SQLITE_BIN}" ]]  || { echo "ERROR: sqlite binary not executable: ${SQLITE_BIN}"; exit 1; }

# ======================================================
# Prep filesystem
# ======================================================
mkdir -p "${LOG_DIR}"
cd /opt/dbrepair

# Reset docker-visible log every run
: > "${DOCKER_LOG_FILE}"

# ======================================================
# Build DBRepair scripted argument list
# NOTE: For non-Plex containers, README says use BOTH --sqlite and --databases.
# ======================================================
DBREPAIR_ARGS=()
DBREPAIR_ARGS+=( "--sqlite" "${SQLITE_BIN}" )
DBREPAIR_ARGS+=( "--databases" "${PLEX_DB_DIR}" )

# Scripted mode:
# - DBRepair has an internal Scripted variable used for behavior like auto-yes to Y/N prompts.
# - We also pass commands as args so it won't sit at the menu.
export Scripted=1

# Optional update
if [[ "${DBREPAIR_UPDATE}" == "true" ]]; then
  DBREPAIR_ARGS+=( "update" )
fi

# Requested operation
DBREPAIR_ARGS+=( "${MODE_CMD}" )

# Optional show tool logfile to stdout (so you SEE it in docker logs)
if [[ "${SHOW_LOG}" == "true" ]]; then
  DBREPAIR_ARGS+=( "show" )
fi

# Exit
DBREPAIR_ARGS+=( "exit" )

# ======================================================
# Heartbeat (stdout + docker log)
# ======================================================
heartbeat() {
  while true; do
    echo "DBREPAIR: heartbeat $(date '+%Y-%m-%d %H:%M:%S') - running (${DBREPAIR_MODE}), please be patient..." \
      | tee -a "${DOCKER_LOG_FILE}"
    sleep "${HEARTBEAT_INTERVAL}"
  done
}

heartbeat &
HB_PID=$!

cleanup() {
  kill "${HB_PID}" 2>/dev/null || true
}
trap cleanup EXIT

# ======================================================
# Run DBRepair with a PTY and stream output to docker logs
# - script(1) forces a real TTY (DBRepair is interactive by nature)
# - script -e propagates DBRepair exit code
# ======================================================
echo "Starting DBRepair..." | tee -a "${DOCKER_LOG_FILE}"
echo "Command: ./DBRepair.sh ${DBREPAIR_ARGS[*]}" | tee -a "${DOCKER_LOG_FILE}"
echo "--------------------------------------------------" | tee -a "${DOCKER_LOG_FILE}"

set +e
script -q -e -c \
  "stdbuf -oL -eL ./DBRepair.sh ${DBREPAIR_ARGS[*]}" \
  /dev/null \
  2>&1 | tee -a "${DOCKER_LOG_FILE}"
RC=${PIPESTATUS[0]}
set -e

echo "--------------------------------------------------" | tee -a "${DOCKER_LOG_FILE}"
echo "DBRepair finished with exit code ${RC}" | tee -a "${DOCKER_LOG_FILE}"

exit "${RC}"
