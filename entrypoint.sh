#!/usr/bin/env bash
set -euo pipefail

# ======================================================
# Configuration
# ======================================================
: "${PLEX_DB_DIR:=/plexdb}"
: "${PLEX_DB_FILE:=com.plexapp.plugins.library.db}"
: "${LOG_DIR:=/logs}"
: "${HEARTBEAT_INTERVAL:=120}"

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
echo " Heartbeat   : every ${HEARTBEAT_INTERVAL}s"
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

# Hard reset log file every run
rm -f "${LOG_FILE}"
: > "${LOG_FILE}"

export DB_PATH
export LOG_FILE
export HEARTBEAT_INTERVAL

# ======================================================
# Mirror log file to Docker stdout
# ======================================================
tail -n 0 -F "${LOG_FILE}" &
TAIL_PID=$!

cleanup() {
    kill "${TAIL_PID}" 2>/dev/null || true
}
trap cleanup EXIT

# ======================================================
# Write EXPECT script (PID 1 controller)
# ======================================================
cat >run.expect <<'EOF'
set timeout -1
log_user 0

# Log everything to file only
log_file -a $env(LOG_FILE)

spawn bash -lc "
  echo '\\[DBREPAIR\\] started at '\"\$(date)\";

  # Heartbeat loop
  (
    while true; do
      echo '\\[DBREPAIR\\] heartbeat at '\"\$(date)\" 'interval='\"\$HEARTBEAT_INTERVAL\"'s';
      sleep \"\$HEARTBEAT_INTERVAL\";
    done
  ) &
  HB_PID=\$!

  # Run DBRepair
  stdbuf -oL -eL ./DBRepair.sh --db '$env(DB_PATH)';
  RC=\$?

  # Stop heartbeat
  kill \$HB_PID 2>/dev/null || true

  echo '\\[DBREPAIR\\] finished at '\"\$(date)\";
  echo '\\[DBREPAIR\\] exit code '\"\$RC\";

  exit \$RC
"

# Capture DBRepair exit code
set exit_status 0
expect {
    eof {
        catch wait result
        set exit_status [lindex $result 3]
    }
}

exit $exit_status
EOF

chmod +x run.expect

# ======================================================
# Run DBRepair (expect is PID 1)
# ======================================================
echo " Starting DBRepair via expect"
echo " You can follow progress with: docker logs -f plex-dbrepair"
echo " Be Patient, this can take a while!"
exec expect ./run.expect
