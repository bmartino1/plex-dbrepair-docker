#!/usr/bin/env bash
set -euo pipefail

# ======================================================
# Configuration (Docker environment variables)
# ======================================================
: "${PLEX_DB_DIR:=/plexdb}"
: "${PLEX_DB_FILE:=com.plexapp.plugins.library.db}"
: "${LOG_DIR:=/logs}"

: "${DBREPAIR_MODE:=automatic}"    # automatic | check | vacuum | repair | reindex
: "${SHOW_LOG:=true}"              # true | false
: "${HEARTBEAT_INTERVAL:=300}"     # seconds (default 5 minutes)

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
    echo "WARNING: Invalid DBREPAIR_MODE='${DBREPAIR_MODE}', falling back to 'automatic'"
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
if [[ ! -d "${PLEX_DB_DIR}" ]]; then
  echo "ERROR: Plex DB directory not found: ${PLEX_DB_DIR}"
  exit 1
fi

if [[ ! -f "${DB_PATH}" ]]; then
  echo "ERROR: Plex DB file not found: ${DB_PATH}"
  exit 1
fi

# ======================================================
# Prep filesystem
# ======================================================
mkdir -p "${LOG_DIR}"
cd /opt/dbrepair

# Reset docker-visible log every run
rm -f "${DOCKER_LOG_FILE}"
: > "${DOCKER_LOG_FILE}"

export DB_PATH
export MODE_CMD
export SHOW_LOG
export HEARTBEAT_INTERVAL
export DOCKER_LOG_FILE

# ======================================================
# Mirror DBRepair log → Docker stdout
# ======================================================
tail -n 0 -F "${DOCKER_LOG_FILE}" &
TAIL_PID=$!
trap "kill ${TAIL_PID} 2>/dev/null || true" EXIT

# ======================================================
# Write EXPECT controller (NO MENU MATCHING)
# ======================================================
cat >run.expect <<'EOF'
set timeout -1

# Show DBRepair output in docker logs
log_user 1
log_file -a $env(DOCKER_LOG_FILE)

# Spawn DBRepair under PTY
spawn bash -lc "stdbuf -oL -eL ./DBRepair.sh --db '$env(DB_PATH)'"

# ------------------------------------------------------
# Heartbeat (background)
# ------------------------------------------------------
set hb_pid [exec sh -c "
  INTERVAL='$env(HEARTBEAT_INTERVAL)';
  while true; do
    echo \"DBREPAIR: heartbeat at \$(date) interval=\${INTERVAL}s\";
    echo \"DBREPAIR: Be patient, this can take a while...\";
    sleep \"\${INTERVAL}\";
  done
" &]

# ------------------------------------------------------
# Give DBRepair time to initialize UI
# ------------------------------------------------------
sleep 5

# ------------------------------------------------------
# Send command sequence (guaranteed)
# ------------------------------------------------------
send "$env(MODE_CMD)\r"
sleep 1

if { "$env(SHOW_LOG)" == "true" } {
  send "10\r"
  sleep 1
}

send "99\r"
sleep 1
send "Y\r"

# ------------------------------------------------------
# Wait for DBRepair to exit
# ------------------------------------------------------
expect eof

# Cleanup heartbeat
exec kill $hb_pid 2>/dev/null

# Exit container cleanly
exit 0
EOF

chmod +x run.expect

# ======================================================
# Run DBRepair (expect is PID 1)
# ======================================================
echo " Starting DBRepair"
exec expect ./run.expect
