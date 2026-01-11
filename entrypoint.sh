#!/usr/bin/env bash
set -euo pipefail

# ======================================================
# Configuration
# ======================================================
: "${PLEX_DB_DIR:=/plexdb}"
: "${PLEX_DB_FILE:=com.plexapp.plugins.library.db}"
: "${LOG_DIR:=/logs}"
: "${SCREEN_NAME:=db}"

DB_PATH="${PLEX_DB_DIR}/${PLEX_DB_FILE}"
LOG_FILE="${LOG_DIR}/dbrepair.log"

# ======================================================
# Banner
# ======================================================
echo "=================================================="
echo " Plex DBRepair Container"
echo "=================================================="
echo " Plex DB Dir : ${PLEX_DB_DIR}"
echo " Database    : ${PLEX_DB_FILE}"
echo " DB Path     : ${DB_PATH}"
echo " Screen Name : ${SCREEN_NAME}"
echo "=================================================="

# ======================================================
# Safety checks
# ======================================================
if [[ ! -d "${PLEX_DB_DIR}" ]]; then
    echo "ERROR: Plex DB directory not found"
    exit 1
fi

if [[ ! -f "${DB_PATH}" ]]; then
    echo "ERROR: Plex DB file not found"
    exit 1
fi

# ======================================================
# Prep filesystem
# ======================================================
mkdir -p "${LOG_DIR}"
cd /opt/dbrepair
: > "${LOG_FILE}"

export DB_PATH

# ======================================================
# Inform on How to Connect!
# ======================================================
echo
echo "=================================================="
echo
echo " Attach with:"
echo "   docker exec -it plex-dbrepair screen -r ${SCREEN_NAME}"
echo
echo " Detach with: Ctrl+A then D"
echo "=================================================="
echo " Starting DBRepair script" 

# ======================================================
# Write EXPECT script (THIS CALLS DBREPAIR)
# ======================================================
cat >run.expect <<'EOF'
set timeout -1
log_user 1

spawn ./DBRepair.sh --db "$env(DB_PATH)"

expect {
    -re "Plex Media Server.*running" {
        send "y\r"
        exp_continue
    }
    -re "Do you want to continue" {
        send "y\r"
        exp_continue
    }
    -re "Proceed.*repair" {
        send "y\r"
        exp_continue
    }
    -re "Press.*Enter" {
        send "\r"
        exp_continue
    }
    eof
}
EOF

chmod +x run.expect

# ======================================================
# Launch SCREEN and RUN DBREPAIR (EXPLICIT)
# ======================================================
echo " Starting DBRepair inside screen"
exec screen -S "${SCREEN_NAME}" \
    expect ./run.expect 2>&1 | tee -a "${LOG_FILE}"
