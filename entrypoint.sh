#!/usr/bin/env bash
set -euo pipefail

# ======================================================
# Configuration (Docker environment variables)
# ======================================================
: "${PLEX_DB_DIR:=/plexdb}"
: "${PLEX_DB_FILE:=com.plexapp.plugins.library.db}"
: "${LOG_DIR:=/logs}"

: "${DBREPAIR_MODE:=automatic}"   # automatic | check | vacuum | repair | reindex
: "${SHOW_LOG:=true}"              # true | false
: "${HEARTBEAT_INTERVAL:=300}"     # seconds (default 5 minutes)

DB_PATH="${PLEX_DB_DIR}/${PLEX_DB_FILE}"
DockerLOG_FILE="${LOG_DIR}/dbrepair.log"

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
echo " Docker Log     : ${DockerLOG_FILE}"
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

# Hard reset Docker log file every run
rm -f "${DockerLOG_FILE}"
: > "${DockerLOG_FILE}"

export DB_PATH
export MODE_CMD
export SHOW_LOG
export HEARTBEAT_INTERVAL
export DockerLOG_FILE

# ======================================================
# Mirror DBRepair log → Docker stdout
# ======================================================
tail -n 0 -F "${DockerLOG_FILE}" &
TAIL_PID=$!
trap "kill ${TAIL_PID} 2>/dev/null || true" EXIT

# ======================================================
# Write EXPECT controller script
# ======================================================
cat >run.expect <<'EOF'
set timeout -1
log_user 0
log_file -a $env(DockerLOG_FILE)

# Start DBRepair under a real PTY
spawn bash -lc "stdbuf -oL -eL ./DBRepair.sh --db '$env(DB_PATH)'"

# State flags
set sent_mode 0
set sent_show 0
set sent_exit 0

# ------------------------------------------------------
# Heartbeat loop (FIXED)
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
# DBRepair menu automation
# ------------------------------------------------------
expect {
  -re {Enter command #.*:} {

    # 1) Run requested operation
    if { $sent_mode == 0 } {
      send \"$env(MODE_CMD)\r\"
      set sent_mode 1
      exp_continue
    }

    # 2) Show DBRepair internal log (menu 10)
    if { $env(SHOW_LOG) == \"true\" && $sent_show == 0 } {
      send \"10\r\"
      set sent_show 1
      exp_continue
    }

    # 3) Exit DBRepair (menu 99)
    if { $sent_exit == 0 } {
      send \"99\r\"
      set sent_exit 1
      exp_continue
    }
  }

  # Cleanup prompt after 99
  -re {Ok to remove temporary.*\(Y/N\).*} {
    send \"Y\r\"
    exp_continue
  }

  # End of DBRepair
  eof {
    catch wait result
    exec kill $hb_pid 2>/dev/null
    exit [lindex $result 3]
  }
}
EOF

chmod +x run.expect

# ======================================================
# Run DBRepair (expect is PID 1)
# ======================================================
echo " Starting DBRepair"
exec expect ./run.expect
