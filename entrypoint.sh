#!/usr/bin/env bash
set -euo pipefail

# ======================================================
# Configuration
# ======================================================
: "${PLEX_DB_DIR:=/plexdb}"
: "${PLEX_DB_FILE:=com.plexapp.plugins.library.db}"
: "${LOG_DIR:=/logs}"

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
# Write EXPECT script (THIS CALLS DBREPAIR)
# ======================================================
cat >run.expect <<'EOF'
set timeout -1
log_user 1

# Log everything
log_file -a $env(LOG_FILE)

# Spawn DBRepair with a real PTY
spawn ./DBRepair.sh --db "$env(DB_PATH)"

# ======================================================
# DBRepair Prompt Handling (based on actual script)
# ======================================================
expect {
    -re {Plex Media Server.*running.*Continue.*\[y/N\]} {
        send "y\r"
        exp_continue
    }

    -re {Continue.*\[y/N\]} {
        send "y\r"
        exp_continue
    }

    -re {Proceed.*\[y/N\]} {
        send "y\r"
        exp_continue
    }

    -re {Press Enter to continue} {
        send "\r"
        exp_continue
    }

    -re {Press.*Enter} {
        send "\r"
        exp_continue
    }

    eof
}
EOF

chmod +x run.expect

# ======================================================
# Run DBRepair (expect is PID 1)
# ======================================================
echo " Starting DBRepair via expect"
exec expect ./run.expect
