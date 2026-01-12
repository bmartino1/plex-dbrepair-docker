#!/usr/bin/env bash
set -euo pipefail

# ======================================================
# Docker environment variables
# ======================================================
: "${PLEX_DB_DIR:=/plexdb}"
: "${PLEX_DB_FILE:=com.plexapp.plugins.library.db}"
: "${LOG_DIR:=/logs}"

: "${DBREPAIR_MODE:=automatic}"     # automatic | check | vacuum | repair | reindex
: "${DBREPAIR_UPDATE:=false}"       # true | false
: "${SHOW_LOG:=true}"               # true | false
: "${HEARTBEAT_INTERVAL:=300}"      # seconds
: "${PLEX_CONTAINER_NAME:=plex}"    # match containers by name/image substring

# Optional: Unraid usually provides this
: "${HOST_CONTAINERNAME:=}"         # e.g. "dbrepair"

DB_PATH="${PLEX_DB_DIR}/${PLEX_DB_FILE}"
LOGFILE="${LOG_DIR}/dbrepair.log"

# ======================================================
# Map mode → DBRepair SCRIPTED command (UPSTREAM CORRECT)
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
echo " Plex DB Dir    : ${PLEX_DB_DIR}"
echo " DB File        : ${PLEX_DB_FILE}"
echo " DB Path        : ${DB_PATH}"
echo " Mode           : ${DBREPAIR_MODE} (${MODE_CMD})"
echo " Update Script  : ${DBREPAIR_UPDATE}"
echo " Show Log       : ${SHOW_LOG}"
echo " Heartbeat      : every ${HEARTBEAT_INTERVAL}s (while running)"
echo " Log File       : ${LOGFILE}"
echo " Plex match      : ${PLEX_CONTAINER_NAME}"
echo "=================================================="

# ======================================================
# SAFETY CHECKS (DO NOT REMOVE)
# ======================================================
[[ -d "${PLEX_DB_DIR}" ]] || { echo "ERROR: Plex DB directory missing: ${PLEX_DB_DIR}"; exit 1; }
[[ -f "${DB_PATH}" ]]     || { echo "ERROR: Plex DB file missing: ${DB_PATH}"; exit 1; }

mkdir -p "${LOG_DIR}"
cd /opt/dbrepair

# Reset log every run (docker log + file log will rebuild)
: > "${LOGFILE}"

# Mirror ALL stdout/stderr into the logfile as well
exec > >(tee -a "${LOGFILE}") 2>&1

# If you want to stop Plex containers, docker CLI + socket are REQUIRED
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker CLI not installed in image (add docker.io to Dockerfile)"; exit 1; }
[[ -S /var/run/docker.sock ]] || { echo "ERROR: /var/run/docker.sock not mounted"; exit 1; }

# ======================================================
# Identify THIS container (robust enough)
# ======================================================
SELF_ID_SHORT="$(awk -F/ '/docker/ {print substr($NF,1,12); exit}' /proc/self/cgroup 2>/dev/null || true)"
SELF_NAME="$(hostname)"

echo "Self detect:"
echo "  SELF_ID_SHORT     : ${SELF_ID_SHORT:-unknown}"
echo "  HOSTNAME          : ${SELF_NAME}"
echo "  HOST_CONTAINERNAME: ${HOST_CONTAINERNAME:-n/a}"

# ======================================================
# STOP ALL PLEX CONTAINERS (except this one)
# - disable restart first so they don't pop back up
# ======================================================
echo "Stopping Plex containers matching '${PLEX_CONTAINER_NAME}'..."
docker ps --format '{{.ID}} {{.Names}} {{.Image}}' | while read -r CID NAME IMAGE; do
  # Exclude self by ID prefix
  if [[ -n "${SELF_ID_SHORT}" && "${CID}" == "${SELF_ID_SHORT}"* ]]; then
    continue
  fi
  # Exclude self by name
  if [[ "${NAME}" == "${SELF_NAME}" ]]; then
    continue
  fi
  # Exclude if Unraid gave us container name and it matches
  if [[ -n "${HOST_CONTAINERNAME}" && "${NAME}" == "${HOST_CONTAINERNAME}" ]]; then
    continue
  fi
  # Exclude our own image name if it contains plex-dbrepair
  if echo "${IMAGE}" | grep -qi 'plex-dbrepair'; then
    continue
  fi

  # Match Plex containers by name OR image containing plex substring you choose
  if echo "${NAME}" | grep -qi "${PLEX_CONTAINER_NAME}" || echo "${IMAGE}" | grep -qi "${PLEX_CONTAINER_NAME}"; then
    echo "Disabling restart + stopping: ${NAME} (${CID}) image=${IMAGE}"
    docker update --restart=no "${CID}" >/dev/null 2>&1 || true
    docker stop "${CID}" >/dev/null 2>&1 || true
  fi
done

echo "Plex container shutdown step complete."

# ======================================================
# Build DBRepair scripted command list (README style)
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
# Heartbeat (ONLY while DBRepair runs)
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
# Run DBRepair (SCRIPTED MODE)
# - Use `script` to provide a TTY if DBRepair expects one
# ======================================================
export Scripted=1
export LOGFILE

set +e
script -q -e -c "stdbuf -oL -eL ./DBRepair.sh --db '${DB_PATH}' ${DBR_CMDS[*]}" /dev/null
RC=$?
set -e

kill "${HB_PID}" 2>/dev/null || true

echo "--------------------------------------------------"
echo "DBRepair finished with exit code ${RC}"
exit "${RC}"
