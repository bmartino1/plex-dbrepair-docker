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
see 
- **Unraid Support Thread:**  
  https://forums.unraid.net/topic/196453-support-plex-db-repair-docker/#findComment-1601211

---

## Requirements

- Docker
- Access to the Docker socket (used to stop/start Plex if enabled)
- Plex Media Server running in a Docker container

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
  -v /mnt/user/appdata/dbrepair:/config:rw \
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

| Variable               | Description                                    |
| ---------------------- | ---------------------------------------------- |
| `DBREPAIR_MODE`        | `automatic` or `manual`                        |
| `ALLOW_PLEX_KILL`      | Allow the container to stop Plex during repair |
| `PLEX_CONTAINER_MATCH` | Substring used to locate the Plex container    |
| `RESTART_PLEX`         | Restart Plex after repair completes            |
| `PRUNE_DAYS`           | Remove logs older than N days                  |
| `ENABLE_BACKUPS`       | Enable Plex database backups                   |
| `RESTORE_LAST_BACKUP`  | Restore the most recent backup                 |
| `TZ`                   | Container timezone                             |

---

## Support

- **Unraid Support Thread:**  
  https://forums.unraid.net/topic/196453-support-plex-db-repair-docker/#findComment-1601211

