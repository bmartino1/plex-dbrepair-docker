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
export LOG_FILE

# ======================================================
# Inform on How to Connect! and run!
# ======================================================
echo
echo "=================================================="
echo
echo " Attach with:"
echo "   docker exec -it plex-dbrepair screen -r ${SCREEN_NAME}"
echo
echo " Detach with: Ctrl+A then D"
echo "=================================================="

# ======================================================
# Write EXPECT script (THIS CALLS DBREPAIR)
# ======================================================
cat >run.expect <<'EOF'
set timeout -1
log_user 1

# Log everything to file AND screen
log_file -a $env(LOG_FILE)

# Start DBRepair (REAL TTY via screen)
spawn ./DBRepair.sh --db "$env(DB_PATH)"

# ======================================================
# DBRepair Prompt Handling
# ======================================================

expect {
    # Plex is running warning
    -re {Plex Media Server.*running.*Continue.*\[y/N\]} {
        send "y\r"
        exp_continue
    }

    # Generic Continue (y/N)?
    -re {Continue.*\[y/N\]} {
        send "y\r"
        exp_continue
    }

    # Proceed with repair
    -re {Proceed.*\[y/N\]} {
        send "y\r"
        exp_continue
    }

    # Enter-only pause
    -re {Press Enter to continue} {
        send "\r"
        exp_continue
    }

    # Some versions say just "Press Enter"
    -re {Press.*Enter} {
        send "\r"
        exp_continue
    }

    # Normal completion
    eof
}
EOF

chmod +x run.expect

# ======================================================
# Launch SCREEN and RUN DBREPAIR (EXPLICIT)
# ======================================================
echo " Starting DBRepair script inside screen ${SCREEN_NAME}"

exec screen -S "${SCREEN_NAME}" expect ./run.expect
