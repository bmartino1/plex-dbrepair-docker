#!/usr/bin/env bash
set -euo pipefail

# ======================================================
# Configuration (Docker environment variables)
# ======================================================
: "${PLEX_DB_DIR:=/plexdb}"
: "${PLEX_DB_FILE:=com.plexapp.plugins.library.db}"
: "${LOG_DIR:=/logs}"

: "${DBREPAIR_MODE:=automatic}"   # automatic | check | vacuum | repair | reindex
: "${SHOW_LOG:=true}"             # true | false
: "${HEARTBEAT_INTERVAL:=300}"    # seconds (default 5 minutes)

DB_PATH="${PLEX_DB_DIR}/${PLEX_DB_FILE}"
DOCKER_LOG_FILE="${LOG_DIR}/dbrepair.log"

# ======================================================
# Map DBREPAIR_MODE → DBRepair menu command
# ======================================================
case "${DBREPAIR_MODE}" in
  automatic) MODE_CMD="2" ;;
  check)     MODE_CMD="3" ;;
  vacuum)    MODE_CMD="4" ;;
  repair)    MODE_CMD="5" ;;
  reindex)   MODE_CMD="6" ;;
  *)
    echo "WARNING: Invalid DBREPAIR_MODE='${DBREPAIR_MODE}', defaulting to automatic"
    MODE_CMD="2"
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
echo " Mode           : ${DBREPAIR_MODE} (menu ${MODE_CMD})"
echo " Show Log       : ${SHOW_LOG}"
echo " Heartbeat      : every ${HEARTBEAT_INTERVAL}s"
echo " Docker Log     : ${DOCKER_LOG_FILE}"
echo "=================================================="

# ======================================================
# Safety checks
# ======================================================
[[ -d "${PLEX_DB_DIR}" ]] || { echo "ERROR: Plex DB dir missing"; exit 1; }
[[ -f "${DB_PATH}" ]] || { echo "ERROR: Plex DB file missing"; exit 1; }

# ======================================================
# Prep filesystem
# ======================================================
mkdir -p "${LOG_DIR}"
cd /opt/dbrepair

# Reset docker-visible log
: > "${DOCKER_LOG_FILE}"

# ======================================================
# Heartbeat (background)
# ======================================================
heartbeat() {
  while true; do
    echo "DBREPAIR: heartbeat at $(date) interval=${HEARTBEAT_INTERVAL}s"
    echo "DBREPAIR: Be patient, this can take a while..."
    sleep "${HEARTBEAT_INTERVAL}"
  done
}

heartbeat >>"${DOCKER_LOG_FILE}" &
HB_PID=$!

cleanup() {
  kill "${HB_PID}" 2>/dev/null || true
}
trap cleanup EXIT

# ======================================================
# Build DBRepair command stream
# ======================================================
{
  echo "${MODE_CMD}"

  if [[ "${SHOW_LOG}" == "true" ]]; then
    echo "10"
  fi

  echo "99"
  echo "Y"
} | tee /tmp/dbrepair.stdin

# ======================================================
# Run DBRepair (REAL execution)
# ======================================================
echo "Starting DBRepair..."
echo "--------------------------------------------------"

stdbuf -oL -eL ./DBRepair.sh --db "${DB_PATH}" \
  < /tmp/dbrepair.stdin \
  | tee -a "${DOCKER_LOG_FILE}"

RC=${PIPESTATUS[0]}

echo "--------------------------------------------------"
echo "DBREPAIR: finished with exit code ${RC}"

exit "${RC}"
