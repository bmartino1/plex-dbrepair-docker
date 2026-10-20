# YOU ARE RESPONSIBLE FOR YOUR OWN DATA.

⚠️ **This container modifies your Plex SQLite database.**  
Always ensure you have **verified, working backups** before proceeding.

# Plex DBRepair Docker

One-shot Docker maintenance wrapper for [ChuckPa / DBRepair](https://github.com/ChuckPa/DBRepair). Image: [`bmmbmm01/plex-dbrepair`](https://hub.docker.com/r/bmmbmm01/plex-dbrepair). This rewrite packages **DBRepair v26.10.00**, not the old interactive `DBRepair.sh` or the previous custom SQLite/FTS maintenance routines.

> **Warning — you are responsible for your data.** This software can modify or rebuild Plex databases. Have a **separate, verified, restorable backup** before using it on a production library. This version was tested on a *fresh LinuxServer Plex test container*. Binhex and Hotio are intended targets but remain unverified. Consult [upstream DBRepair releases](https://github.com/ChuckPa/DBRepair/releases) for compatibility updates; do not assume future Plex schema/FTS changes are safe automatically.

## How it works

1. Connects to the Docker daemon through `/var/run/docker.sock` (not a second Docker daemon).
2. Finds exactly **one running Plex container** with a database at the expected internal path; or selects an exact name from `PLEX_CONTAINER_NAME`.
3. Reports target image, container ID, mounts, restart policy and database location in the logs.
4. Copies the bundled `DBRepair` executable into the Plex container using `docker cp` and runs it with `docker exec`.
5. Requests graceful Plex Media Server shutdown through `DBRepair stop`, with a SIGTERM process fallback when allowed; verifies the PMS process has exited **and the container remains running**.
6. Creates a verified cold `.tar.gz` database backup by default (except prune), runs the requested native DBRepair operation, and restarts the Plex Docker container on success if enabled.
7. Exits automatically, writing Docker console output and a timestamped persistent log.

**No Plex appdata folder mount is required inside the repair container.** The tool accesses the Plex config *through the running Plex container*. `PLEX_MOUNT=/config` is an internal **target Plex** path, not a volume mapping for this container.

## Unraid Community Applications

Use the Unraid [plexrepair.xml template](https://github.com/bmartino1/unraid-docker-templates/blob/main/templates/plexrepair.xml). For most installations, keep the defaults: `DBREPAIR_MODE=automatic`, `PLEX_CONTAINER_NAME=auto`, `ENABLE_BACKUPS=true`, `RESTART_PLEX=true`, a persistent `/logs` mount and the `/var/run/docker.sock` bind mount. Choose **Restart policy: No** for this one-shot maintenance container (do not use `always` / `unless-stopped`).

If multiple Plex containers qualify, enter the **exact container name** from `docker ps` into `PLEX_CONTAINER_NAME`. Default Plex paths inside the target are `/config/Library/Application Support/Plex Media Server`; adjust `PLEX_MOUNT` and `PLEX_REL` under Advanced View only if your target differs. The target Plex container must be **running at discovery time**; DBRepair then stops its internal PMS process itself.

**Security:** Docker socket access grants effective host-admin privileges. Use only with code/images you trust. Privileged mode is not separately required.

## Docker CLI example

```bash
docker run --name plex-dbrepair-test \
  --hostname plex-dbrepair-test \
  --network bridge \
  --restart no \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /mnt/user/appdata/plex-dbrepair-logs:/logs \
  -e DBREPAIR_MODE=automatic \
  -e PLEX_CONTAINER_NAME=auto \
  -e PLEX_MOUNT=/config \
  -e PLEX_REL='Library/Application Support/Plex Media Server' \
  -e ENABLE_BACKUPS=true \
  -e ALLOW_PLEX_KILL=true \
  -e RESTART_PLEX=true \
  -e PRUNE_DAYS=30 \
  -e DBREPAIR_TIMEOUT=7200 \
  -e STOP_TIMEOUT=90 \
  bmmbmm01/plex-dbrepair:latest
```

Change only `DBREPAIR_MODE` for other operations. For further runs, remove the old *exited repair container* (`docker rm plex-dbrepair-test`) first. Follow logs with `docker logs -f plex-dbrepair-test`, inspect exit status with `docker inspect plex-dbrepair-test --format '{{.State.ExitCode}}'`, and check Plex availability independently afterwards.

## Maintenance modes

| `DBREPAIR_MODE` | ChuckPa command | What it does |
| --- | --- | --- |
| `automatic` (default) | `auto` | Upstream automatic database checks/maintenance; does **not** guarantee VACUUM and REINDEX every run |
| `check` | `check` | Database integrity checks |
| `vacuum` | `vacuum` | VACUUM databases and verify resulting files |
| `repair` | `repair` | Rebuild databases, including schema, FTS tables, triggers, data and indexes |
| `reindex` | `reindex` | Rebuild database indexes |
| `deflate` | `deflate` | Check database bloat and compact if needed |
| `prune` | `prune` | Clean aged PhotoTranscoder cache files (`PRUNE_DAYS`) |

Unknown `DBREPAIR_MODE` values fall back to `automatic`, but discovery, shutdown, backup and database failures **do not** trigger automatic repair fallback. Legacy `ftscheck` maps to `check` and `ftsrepair` maps to `reindex`; native DBRepair handles FTS. `manual` is deliberately rejected for one-shot unattended use.

## Environment variables

| Variable | Default | Notes |
| --- | --- | --- |
| `DBREPAIR_MODE` | `automatic` | See modes above |
| `PLEX_CONTAINER_NAME` | `auto` | Auto-discover or supply exact Docker container name (not image name) |
| `PLEX_CONTAINER_MATCH` | `plex` | Auto-discovery name substring; Plex image names also checked |
| `PLEX_MOUNT` | `/config` | **Inside target Plex** |
| `PLEX_REL` | `Library/Application Support/Plex Media Server` | Relative to target's `PLEX_MOUNT` |
| `ENABLE_BACKUPS` | `true` | Backup before operations except `prune` |
| `ALLOW_PLEX_KILL` | `true` | Allow SIGTERM if native DBRepair stop fails |
| `RESTART_PLEX` | `true` | Restart Docker target only after successful run; on errors inspect before manual restart |
| `PRUNE_DAYS` | `30` | Applies only to `prune`; valid 1–999 |
| `DBREPAIR_TIMEOUT` | `7200` | Operation timeout, seconds |
| `STOP_TIMEOUT` | `90` | PMS shutdown wait time, seconds |
| `LOG_DIR` | `/logs` | Persistent logging target; map a host directory |
| `RESTART_FALLBACK` | `true` | Docker start if container exits during cleanup (not an offline maintenance mode) |
| `RESTORE_LAST_BACKUP` | `false` | **Unsupported** when true: entrypoint aborts instead of guessing which backup to restore |

Old custom `ENABLE_FTS_CHECK` and `ENABLE_FTS_REPAIR` variables are no longer needed. Old `EXCLUDE_CONTAINER_NAMES` / `EXCLUDE_IMAGE_REGEX` are implementation filters, not necessary in the normal CA template.

## Backups and errors

Backup archives are saved **inside the target Plex configuration tree**, e.g.:

```text
/config/Library/Application Support/Plex Media Server/DBRepair-Backups/dbrepair-pre-repair-YYYYMMDDTHHMMSSZ.tar.gz
```

They include the Databases directory and SQLite WAL/SHM files when present; the repair container does **not** automatically prune backup archives. Ensure adequate free space and maintain **independent** backups of your Plex appdata. Restoring an archive is a manual recovery task; the old `RESTORE_LAST_BACKUP` feature is **not implemented** in this rewrite.

If Plex's internal process cannot be stopped without losing its Docker container, or a supervisor respawns Plex, the script aborts rather than repairing a live database. There is **no offline Method B fallback**. On a repair error or timeout, it intentionally avoids automatically restarting Plex. Review logs, database integrity and backups before bringing Plex back online.

## Test history (LinuxServer Plex, disposable library)

Tested against `lscr.io/linuxserver/plex`, PMS `1.43.4.10903`, using `bmmbmm01/plex-dbrepair:latest` with DBRepair `26.10.00`:

- `automatic`: successful health checks and no orphaned items; operation exited `0`.
- `vacuum`: Main and Blobs DB vacuum completed, post-operation verified, exited `0`.
- `reindex`: Main and Blobs indexes rebuilt and checked, exited `0`.
- `repair`: Main and Blobs databases rebuilt, including FTS, and verified, exited `0`.
- `deflate`: correctly reported no deflation needed; exited `0`.
- `prune`: completed with 0 files removed (empty test cache); exited `0`.

These tests do **not** prove repair of a corrupt database, actual cache deletion, compatibility with other Plex image variants, or resilience to real-world large-library maintenance failures.

## Support and upstream

- [Unraid support thread](https://forums.unraid.net/topic/196453-support-plex-db-repair-docker/)
- [Docker image](https://hub.docker.com/r/bmmbmm01/plex-dbrepair)
- [Project source](https://github.com/bmartino1/plex-dbrepair-docker)
- [ChuckPa DBRepair](https://github.com/ChuckPa/DBRepair)
