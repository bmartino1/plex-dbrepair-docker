#!/usr/bin/env bash
set -euo pipefail

# ======================================================
# Docker environment variables
# ======================================================
: "${PLEX_DB_DIR:=/plexdb}"
: "${PLEX_DB_FILE:=com.plexapp.plugins.library.db}"
: "${LOG_DIR:=/logs}"

: "${DBREPAIR_MODE:=automatic}"     # automatic | check | vacuum | repair | reindex
: "${DBREPAIR_UPDATE:=false}"       # true | false
: "${SHOW_LOG:=true}"               # true | false
: "${HEARTBEAT_INTERVAL:=300}"      # seconds

DB_PATH="${PLEX_DB_DIR}/${PLEX_DB_FILE}"
LOGFILE="${LOG_DIR}/dbrepair.log"

# ======================================================
# Map mode → DBRepair SCRIPTED command (UPSTREAM CORRECT)
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
echo " Plex DBRepair (SCRIPTED MODE)"
echo "=================================================="
echo " Plex DB Dir : ${PLEX_DB_DIR}"
echo " DB Path     : ${DB_PATH}"
echo " Mode        : ${DBREPAIR_MODE}"
echo " Update      : ${DBREPAIR_UPDATE}"
echo " Show Log    : ${SHOW_LOG}"
echo " Heartbeat   : ${HEARTBEAT_INTERVAL}s"
echo " Log File    : ${LOGFILE}"
echo "=================================================="

# ======================================================
# Safety checks (DO NOT REMOVE)
# ======================================================
[[ -d "${PLEX_DB_DIR}" ]] || { echo "ERROR: Plex DB directory missing"; exit 1; }
[[ -f "${DB_PATH}" ]]     || { echo "ERROR: Plex DB file missing"; exit 1; }

mkdir -p "${LOG_DIR}"
cd /opt/dbrepair

# Reset log every run
: > "${LOGFILE}"

# ======================================================
# Build DBRepair scripted command list
# (MATCHES README SAMPLE)
# ======================================================
DBR_CMDS=()

[[ "${DBREPAIR_UPDATE}" == "true" ]] && DBR_CMDS+=( update )
DBR_CMDS+=( "${MODE_CMD}" )
[[ "${SHOW_LOG}" == "true" ]] && DBR_CMDS+=( show )
DBR_CMDS+=( exit )

# ======================================================
# Heartbeat (ONLY while DBRepair is running)
# ======================================================
heartbeat() {
  while true; do
    echo "[HEARTBEAT] $(date '+%Y-%m-%d %H:%M:%S') - DBRepair running, please be patient..."
    sleep "${HEARTBEAT_INTERVAL}"
  done
}

# ======================================================
# Run DBRepair (SCRIPTED MODE, REAL TTY)
# ======================================================
export Scripted=1
export LOGFILE

echo "--------------------------------------------------"
echo "DBRepair command sequence:"
printf '  %s\n' "${DBR_CMDS[@]}"
echo "--------------------------------------------------"

heartbeat &
HB_PID=$!

set +e
script -q -e -c \
  "stdbuf -oL -eL ./DBRepair.sh --db '${DB_PATH}' ${DBR_CMDS[*]}" \
  /dev/null \
  2>&1 | tee -a "${LOGFILE}"
RC=${PIPESTATUS[0]}
set -e

kill "${HB_PID}" 2>/dev/null || true

echo "--------------------------------------------------"
echo "DBRepair finished with exit code ${RC}"
exit "${RC}"
