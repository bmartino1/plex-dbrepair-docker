#!/usr/bin/env bash
set -euo pipefail

# ======================================================
# Plex DBRepair – SCREEN DEBUG (interactive-safe)
# ======================================================

: "${PLEX_DB_DIR:=/plexdb}"
: "${PLEX_DB_FILE:=com.plexapp.plugins.library.db}"
: "${LOG_DIR:=/logs}"
: "${SCREEN_NAME:=dbrepair}"

DB_PATH="${PLEX_DB_DIR}/${PLEX_DB_FILE}"
LOG_FILE="${LOG_DIR}/dbrepair.log"

echo "=================================================="
echo " Plex DBRepair Container (screen debug mode)"
echo "=================================================="
echo " Plex DB Dir : ${PLEX_DB_DIR}"
echo " Database    : ${PLEX_DB_FILE}"
echo " DB Path     : ${DB_PATH}"
echo " Screen Name : ${SCREEN_NAME}"
echo "=================================================="

# -------------------------
# Safety checks
# -------------------------
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
: > "${LOG_FILE}"

echo
echo "=================================================="
echo " Screen session starting."
echo
echo " Attach with:"
echo "   docker exec -it plex-dbrepair screen -r ${SCREEN_NAME}"
echo
echo " Detach with: Ctrl+A then D"
echo "=================================================="

# -------------------------
# Start screen with shell
# -------------------------
echo "Launching screen session..."

screen -S "${SCREEN_NAME}" -dm bash

# Give screen time to initialize
sleep 1

# -------------------------
# Inject commands into screen
# -------------------------
screen -S "${SCREEN_NAME}" -X stuff $'echo "Starting DBRepair..."\n'
screen -S "${SCREEN_NAME}" -X stuff $'pwd\n'
screen -S "${SCREEN_NAME}" -X stuff $'ls -lh DBRepair.sh\n'

screen -S "${SCREEN_NAME}" -X stuff \
$'stdbuf -oL -eL ./DBRepair.sh --db "'"${DB_PATH}"'" 2>&1 | tee -a "'"${LOG_FILE}"'"\n'


# -------------------------
# Keep container alive
# -------------------------
while screen -list | grep -q "${SCREEN_NAME}"; do
    sleep 5
done

echo "DBRepair finished. Exiting container."
