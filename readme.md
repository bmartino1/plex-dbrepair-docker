# YOU ARE RESPONSIBLE FOR YOUR OWN DATA.

⚠️ **This container modifies your Plex SQLite database.**  
Always ensure you have **verified, working backups** before proceeding.

---

## About This Container

This Docker container is provided to assist users in running the Plex database repair tool to resolve common Plex database issues.

It wraps and automates the excellent repair script created by **ChuckPa**:

- **Project:** https://github.com/ChuckPa/DBRepair

Please review the upstream project documentation to understand **what the tool does**, **how it works**, and **when it should be used**.

---

## What This Container Does

- Runs DBRepair.sh adjacent code inside a controlled Docker environment
- Writes a persistent log file and mirrors output to Docker logs
- Exits automatically when the repair completes
- if variables enabled, it will also:
   - backup (file copy) the current database.
   - stop other plex dockers from running

with unraid variables for prune picture cache and db file restore(if you used this docker to make the backup...)
see unraid support...

## Support

- **Unraid Support Thread:**  
  https://forums.unraid.net/topic/196453-support-plex-db-repair-docker/#findComment-1601211


---

## Requirements

- Docker
- Access to the Docker socket (used to stop/start Plex if enabled) usualy host "/var/run/docker.sock"
- Plex Media Server running in a Docker container stoped and its Libray folder mounted to this docker at /config

---

## Running with Docker

```bash
docker run -d \
  --name=dbrepair \
  --net=bridge \
  --pids-limit 2048 \
  -e TZ="America/Chicago" \
  -e DBREPAIR_MODE="automatic" \
  -e ALLOW_PLEX_KILL="true" \
  -e PLEX_CONTAINER_MATCH="plex" \
  -e RESTART_PLEX="true" \
  -e PRUNE_DAYS="30" \
  -e ENABLE_BACKUPS="false" \
  -e RESTORE_LAST_BACKUP="false" \
  -e EXCLUDE_CONTAINER_NAMES="dbrepair,plex-dbrepair" \
  -e EXCLUDE_IMAGE_REGEX="plex-dbrepair" \
  -v /mnt/user/appdata/plex:/config:rw \
  -v /var/run/docker.sock:/var/run/docker.sock:rw \
  bmmbmm01/plex-dbrepair
```

```yaml
version: "3.8"

services:
  dbrepair:
    image: bmmbmm01/plex-dbrepair
    container_name: dbrepair
    restart: unless-stopped
    network_mode: bridge
    pids_limit: 2048

    environment:
      TZ: America/Chicago
      DBREPAIR_MODE: automatic
      ALLOW_PLEX_KILL: "true"
      PLEX_CONTAINER_MATCH: plex
      RESTART_PLEX: "true"
      PRUNE_DAYS: "30"
      ENABLE_BACKUPS: "false"
      RESTORE_LAST_BACKUP: "false"
      EXCLUDE_CONTAINER_NAMES: dbrepair,plex-dbrepair
      EXCLUDE_IMAGE_REGEX: plex-dbrepair

    volumes:
      - /mnt/user/appdata/dbrepair:/config:rw
      - /var/run/docker.sock:/var/run/docker.sock:rw
```

## Environment Variables

* No netowrk is needed for this docker.
* continer needs Plex appdata path set contner needs to see /config/Library/...Plex Nested folders

**Quick Table Min**

```text
| ---------------------- | ------------------------------------------------------------------- |
| Variable               | Description                                                         |
| ---------------------- | ------------------------------------------------------------------- |
| `DBREPAIR_MODE`        | `automatic` / `check` / `prune` / see more options below            |
| `ALLOW_PLEX_KILL`      | T/F Let this container stop Plex during repair                      |
| `PLEX_CONTAINER_MATCH` | Dfine Name to locate the Plex container to kill                     |
| `RESTART_PLEX`         | Restart killed Plex after repair completes                          |
| `PRUNE_DAYS`           | (requiers DBREPAIR set to prune) # N days age to remove             |
| `ENABLE_BACKUPS`       | T/F Enable Plex database backups (File copy in a sub directory)     |
| `RESTORE_LAST_BACKUP`  | T/F Restore the most recent backup (Overrides options for restore   |
| `TZ`                   | Container timezone/Time stamp                                       |
| ---------------------- | ------------------------------------------------------------------- |
```

---

### DBREPAIR_MODE

**Default:** `automatic`

**Description:**  
Selects which Plex database maintenance operation to run.

All modes operate directly on the mounted Plex database directory using SQLite.
Unless otherwise noted, Plex containers will be stopped before execution and restarted afterward (if enabled).

| Value       | Menu # | Action Description |
|------------|--------|--------------------|
| `automatic` | 2 | Full maintenance run: integrity check → VACUUM → reindex |
| `check`     | 3 | Perform SQLite integrity check only (read-only) |
| `vacuum`    | 4 | Vacuum databases to reclaim unused space |
| `repair`    | 5 | Repair / optimize databases (VACUUM) |
| `reindex`   | 6 | Rebuild all database indexes |
| `deflate`   | — | Rewrite database using `VACUUM INTO` to fully compact |
| `prune`     | — | Prune PhotoTranscoder cache files older than `PRUNE_DAYS` |
| `manual`    | — | Launch interactive shell inside container (no automation) more for testing.  |

* Manual: one could then run the chuckpa shipped script or use docker CLI to connect, update, and run other comands for your plex

---

### ENABLE_BACKUPS
**Default:** `true`

**Description:**  
If enabled, all Plex database files (including WAL/SHM files) are backed up before any write operation.
Backups are stored under the nested database foldder:

"<PLEX_DB_DIR>/dbrepair-backups/<timestamp>/"

You mount what becomes the PLEX_DB_DIR...

---

### RESTORE_LAST_BACKUP

**Default:** `false`

**Description:**  
Restores the most recent backup from `dbrepair-backups` and exits immediately.
No repair actions are performed when this option is enabled. skips DBREPAIR_MODE setting when true... File copies the backup made with this docker back into plex.

---

### ALLOW_PLEX_KILL

**Default:** `true`

**Description:**  
If enabled, the container will attempt to stop running Plex containers before performing database operations.
This prevents database corruption during maintenance. it also requries the docker sock mounted to this docker.

---

### RESTART_PLEX

**Default:** `true`

**Description:**  
If enabled, Plex containers that were stopped by DBRepair will be restarted automatically on exit.

---

### PLEX_CONTAINER_MATCH

**Default:** `plex`

**Description:**  
Case-insensitive substring match used to identify Plex containers.
Both container name and image name are checked.
*its best to but hte plex docker image here... or don't call at all and stop them before running this docker

Example:
plex
plexmediaserver
linuxserver/plex

---

### EXCLUDE_CONTAINER_NAMES

**Default:** `dbrepair,plex-dbrepair`

**Description:**  
Comma-separated list of container names that should never be stopped.

---

### EXCLUDE_IMAGE_REGEX

**Default:** `plex-dbrepair`

**Description:**  
Regular expression used to exclude container images from being stopped. even if this is not called its in the docker to not kill itself...

---

### PRUNE_DAYS

**Default:** `30`

**Description:**  
Number of days to retain files in Plex’s PhotoTranscoder cache when using `DBREPAIR_MODE=prune`.
*Is only required when DBREPAIR_MODE=prune default 30 days

---

### TZ

**Default:** *(not set)*

**Description:**  
Container timezone (used for logging and timestamps).

Example:
America/Chicago
