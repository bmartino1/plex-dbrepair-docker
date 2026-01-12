#!/usr/bin/env bash
set -euo pipefail

# ======================================================
# Docker environment variables
# ======================================================
: "${PLEX_DB_DIR:=/plexdb}"
: "${PLEX_DB_FILE:=com.plexapp.plugins.library.db}"
: "${LOG_DIR:=/logs}"

: "${DBREPAIR_MODE:=automatic}"        # automatic | check | vacuum | repair | reindex
: "${DBREPAIR_UPDATE:=false}"          # true | false
: "${SHOW_LOG:=true}"                  # true | false
: "${HEARTBEAT_INTERVAL:=300}"         # seconds

# Plex control variables
: "${PLEX_MATCH_REGEX:=Plex Media Server|plex}"
: "${EXCLUDE_CONTAINER_NAMES:=dbrepair,plex-dbrepair}"
: "${EXCLUDE_IMAGE_REGEX:=plex-dbrepair}"
: "${ALLOW_PLEX_KILL:=true}"
: "${KILL_STRAY_PLEX_PROCESSES:=true}"

DB_PATH="${PLEX_DB_DIR}/${PLEX_DB_FILE}"
LOGFILE="${LOG_DIR}/dbrepair.log"

# ======================================================
# Map DBREPAIR_MODE → UPSTREAM SCRIPTED COMMAND
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
echo " DB Path                : ${DB_PATH}"
echo " Mode                   : ${DBREPAIR_MODE}"
echo " Update                 : ${DBREPAIR_UPDATE}"
echo " Show Log               : ${SHOW_LOG}"
echo " Heartbeat              : ${HEARTBEAT_INTERVAL}s"
echo " Plex Match Regex       : ${PLEX_MATCH_REGEX}"
echo " Exclude Containers     : ${EXCLUDE_CONTAINER_NAMES}"
echo " Exclude Image Regex    : ${EXCLUDE_IMAGE_REGEX}"
echo " Allow Plex Kill        : ${ALLOW_PLEX_KILL}"
echo " Kill Stray Plex Procs  : ${KILL_STRAY_PLEX_PROCESSES}"
echo " Log File               : ${LOGFILE}"
echo "=================================================="

# ======================================================
# Safety checks
# ======================================================
[[ -d "${PLEX_DB_DIR}" ]] || { echo "ERROR: Plex DB dir missing"; exit 1; }
[[ -f "${DB_PATH}" ]]     || { echo "ERROR: Plex DB file missing"; exit 1; }

mkdir -p "${LOG_DIR}"
cd /opt/dbrepair
: > "${LOGFILE}"

# Mirror EVERYTHING to docker log + logfile
exec > >(tee -a "${LOGFILE}") 2>&1

# ======================================================
# Plex shutdown logic (CONTAINER LEVEL ONLY)
# ======================================================
if [[ "${ALLOW_PLEX_KILL}" == "true" ]]; then
  echo "Scanning for Plex containers to stop…"

  IFS=',' read -ra EXCL_NAMES <<< "${EXCLUDE_CONTAINER_NAMES}"

  docker ps --format '{{.ID}} {{.Names}} {{.Image}}' | while read -r CID NAME IMAGE; do
    # Exclude by name
    for EX in "${EXCL_NAMES[@]}"; do
      [[ "${NAME}" == "${EX}" ]] && continue 2
    done

    # Exclude by image regex
    echo "${IMAGE}" | grep -qiE "${EXCLUDE_IMAGE_REGEX}" && continue

    # Match Plex
    if echo "${NAME} ${IMAGE}" | grep -qiE "${PLEX_MATCH_REGEX}"; then
      echo "Stopping Plex container: ${NAME} (${CID}) image=${IMAGE}"
      docker update --restart=no "${CID}" >/dev/null 2>&1 || true
      docker stop "${CID}" >/dev/null 2>&1 || true
    fi
  done
else
  echo "ALLOW_PLEX_KILL=false — skipping container shutdown"
fi

# ======================================================
# Stray Plex process kill (OPTIONAL)
# ======================================================
if [[ "${KILL_STRAY_PLEX_PROCESSES}" == "true" ]]; then
  if pgrep -f "Plex Media Server" >/dev/null 2>&1; then
    echo "Killing stray Plex Media Server processes"
    pkill -TERM -f "Plex Media Server" || true
    sleep 3
    pkill -9 -f "Plex Media Server" || true
  fi
else
  echo "KILL_STRAY_PLEX_PROCESSES=false — skipping process kill"
fi

# ======================================================
# Build DBRepair command list (UPSTREAM)
# ======================================================
DBR_CMDS=()
[[ "${DBREPAIR_UPDATE}" == "true" ]] && DBR_CMDS+=( update )
DBR_CMDS+=( "${MODE_CMD}" )
[[ "${SHOW_LOG}" == "true" ]] && DBR_CMDS+=( show )
DBR_CMDS+=( exit )

echo "--------------------------------------------------"
echo "DBRepair command sequence:"
printf '  %s\n' "${DBR_CMDS[@]}"
echo "--------------------------------------------------"

# ======================================================
# Heartbeat (ONLY during DBRepair)
# ======================================================
heartbeat() {
  while true; do
    echo "[HEARTBEAT] $(date '+%Y-%m-%d %H:%M:%S') - DBRepair running, please be patient..."
    sleep "${HEARTBEAT_INTERVAL}"
  done
}

heartbeat &
HB_PID=$!
trap 'kill "${HB_PID}" 2>/dev/null || true' EXIT

# ======================================================
# Run DBRepair (SCRIPTED MODE, REAL TTY)
# ======================================================
export Scripted=1
export LOGFILE

set +e
script -q -e -c \
  "stdbuf -oL -eL ./DBRepair.sh --db '${DB_PATH}' ${DBR_CMDS[*]}" \
  /dev/null
RC=$?
set -e

kill "${HB_PID}" 2>/dev/null || true

echo "--------------------------------------------------"
echo "DBRepair finished with exit code ${RC}"
exit "${RC}"
