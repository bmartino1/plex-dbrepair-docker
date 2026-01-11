#!/usr/bin/env bash
set -euo pipefail

# ======================================================
# Plex DBRepair – SCREEN DEBUG Entrypoint
# ======================================================

: "${PLEX_DB_DIR:=/plexdb}"
: "${PLEX_DB_FILE:=com.plexapp.plugins.library.db}"
: "${LOG_DIR:=/logs}"
: "${SCREEN_NAME:=dbrepair}"

DB_PATH="${PLEX_DB_DIR}/${PLEX_DB_FILE}"
LOG_FILE="${LOG_DIR}/dbrepair.log"

echo "=================================================="
echo " Plex DBRepair Container (screen mode)"
echo "=================================================="
echo " Plex DB Dir : ${PLEX_DB_DIR}"
echo " Database    : ${PLEX_DB_FILE}"
echo " DB Path     : ${DB_PATH}"
echo " Screen Name : ${SCREEN_NAME}"
echo "=================================================="

# ------------------------------------------------------
# Safety checks
# ------------------------------------------------------
if [[ ! -d "${PLEX_DB_DIR}" ]]; then
    echo "ERROR: Plex DB directory not found"
    exit 1
fi

if [[ ! -f "${DB_PATH}" ]]; then
    echo "ERROR: Plex DB file not found"
    exit 1
fi

mkdir -p "${LOG_DIR}"
cd /opt/dbrepair

# Clear old log
: > "${LOG_FILE}"

# ------------------------------------------------------
# Launch DBRepair inside screen
# ------------------------------------------------------
echo "Starting DBRepair inside screen session '${SCREEN_NAME}'"
echo "Log file: ${LOG_FILE}"

screen -DmS "${SCREEN_NAME}" bash -c "
stdbuf -oL -eL ./DBRepair.sh \
  --db '${DB_PATH}' \
  2>&1 | tee -a '${LOG_FILE}'
"

echo
echo "=================================================="
echo " DBRepair is now running inside screen"
echo
echo " To attach:"
echo "   docker exec -it <container> screen -r ${SCREEN_NAME}"
echo
echo " To detach:"
echo "   Ctrl+A then D"
echo
echo " Container will stay running until DBRepair exits"
echo "=================================================="

# ------------------------------------------------------
# Keep container alive while screen session exists
# ------------------------------------------------------
while screen -list | grep -q "${SCREEN_NAME}"; do
    sleep 5
done

echo "DBRepair finished, exiting container"
