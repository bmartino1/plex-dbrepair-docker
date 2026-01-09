#!/usr/bin/env bash
set -euo pipefail

# ======================================================
# Configuration (override via docker run -e)
# ======================================================
: "${PLEX_DB_DIR:=/plexdb}"
: "${PLEX_DB_FILE:=com.plexapp.plugins.library.db}"
: "${AUTO_REPAIR:=yes}"
: "${LOG_DIR:=/logs}"

DB_PATH="${PLEX_DB_DIR}/${PLEX_DB_FILE}"

echo "=================================================="
echo " Plex DBRepair Container"
echo "=================================================="
echo " Plex DB Dir : ${PLEX_DB_DIR}"
echo " Database    : ${PLEX_DB_FILE}"
echo " Full Path   : ${DB_PATH}"
echo "=================================================="

# ------------------------------------------------------
# Safety Checks
# ------------------------------------------------------
if [[ ! -d "${PLEX_DB_DIR}" ]]; then
    echo "ERROR: Plex DB directory not found: ${PLEX_DB_DIR}"
    exit 1
fi

if [[ ! -f "${DB_PATH}" ]]; then
    echo "ERROR: Plex DB file not found: ${DB_PATH}"
    exit 1
fi

mkdir -p "${LOG_DIR}"

cd /opt/dbrepair

# ------------------------------------------------------
# Run DBRepair
# ------------------------------------------------------
echo "Starting DBRepair..."

if [[ "${AUTO_REPAIR}" == "yes" ]]; then
    ./DBRepair.sh \
        --auto \
        --db "${DB_PATH}" \
        2>&1 | tee "${LOG_DIR}/dbrepair.log"
else
    ./DBRepair.sh \
        --db "${DB_PATH}" \
        2>&1 | tee "${LOG_DIR}/dbrepair.log"
fi

echo "=================================================="
echo " DBRepair completed"
echo " Logs: ${LOG_DIR}/dbrepair.log"
echo "=================================================="
