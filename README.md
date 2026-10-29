# Plex DBRepair Docker

[![Docker Hub](https://img.shields.io/badge/Docker%20Hub-bmmbmm01%2Fplex--dbrepair-blue?logo=docker)](https://hub.docker.com/r/bmmbmm01/plex-dbrepair)
[![GitHub](https://img.shields.io/badge/Source-bmartino1%2Fplex--dbrepair--docker-181717?logo=github)](https://github.com/bmartino1/plex-dbrepair-docker)

A one-shot Docker maintenance container for [ChuckPa's DBRepair](https://github.com/ChuckPa/DBRepair), designed to run database checks, maintenance, and repairs against an existing Plex Media Server Docker container. It downloads the **latest official compiled DBRepair release at container runtime**, selecting the Linux package for the machine's architecture. The retired `DBRepair.sh` and earlier custom SQLite/FTS routines are not used. **The DBRepair binary is not included in this Docker image.**

> ⚠️ **YOU ARE RESPONSIBLE FOR YOUR OWN DATA.** This tool can modify or rebuild your Plex SQLite databases. Always have a **separate, verified, restorable backup** before using it on a production library. Testing has been performed on a fresh LinuxServer Plex test container; Binhex and Hotio are intended targets but have not been verified. Check [upstream DBRepair releases](https://github.com/ChuckPa/DBRepair/releases) for compatibility information, especially after Plex database schema changes.

## How it works

1. Connects to the Docker daemon through `/var/run/docker.sock` (not a second Docker daemon).
2. Finds exactly **one running Plex container** with a database at the expected internal path; or selects an exact name from `PLEX_CONTAINER_NAME`.
3. Reports target image, container ID, mounts, restart policy and database location in the logs.
4. Downloads the latest official compiled DBRepair release for the host/Plex architecture, verifies the ZIP archive (and SHA-256 digest when provided by GitHub), extracts the executable, then copies it into the Plex container using `docker cp` and runs it with `docker exec`. **If downloading fails, Plex is not stopped.**
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

**Historical test results (bundled DBRepair 26.10.00):** Tested against `lscr.io/linuxserver/plex`, PMS `1.43.4.10903`. The new runtime-download method and later upstream versions have not yet been validated against this test setup:

- `automatic`: successful health checks and no orphaned items; operation exited `0`.
- `vacuum`: Main and Blobs DB vacuum completed, post-operation verified, exited `0`.
- `reindex`: Main and Blobs indexes rebuilt and checked, exited `0`.
- `repair`: Main and Blobs databases rebuilt, including FTS, and verified, exited `0`.
- `deflate`: correctly reported no deflation needed; exited `0`.
- `prune`: completed with 0 files removed (empty test cache); exited `0`.

These tests do **not** prove repair of a corrupt database, actual cache deletion, compatibility with other Plex image variants, or resilience to real-world large-library maintenance failures.

## Upstream DBRepair download and licensing

Following guidance from DBRepair's author, ChuckPa, the Docker image **does not bundle or redistribute** a DBRepair executable. Each container run fetches the current official GitHub release for its Linux architecture (`x86_64`, `arm64`, or `arm32`) and extracts the compiled executable to temporary container storage. It does not use the retired `DBRepair.sh`.

A working connection to GitHub is required on every run. If the download, asset selection, archive check, or executable staging fails, maintenance does not begin. New upstream releases may change behavior or compatibility; check [ChuckPa's release notes and licensing](https://github.com/ChuckPa/DBRepair/releases) before running on important data. The end user is responsible for complying with the upstream DBRepair license. DBRepair's own update mechanism does not need to modify the container: the next run fetches the latest official release again.

## Support and upstream

- [Unraid support thread](https://forums.unraid.net/topic/196453-support-plex-db-repair-docker/)
- [Docker image](https://hub.docker.com/r/bmmbmm01/plex-dbrepair)
- [Project source](https://github.com/bmartino1/plex-dbrepair-docker)
- [ChuckPa DBRepair](https://github.com/ChuckPa/DBRepair)

### Docker Temporary Filesystem Compatibility

Plex DBRepair copies the ChuckPa DBRepair executable into the running Plex container at `/tmp/plex-dbrepair-runner` and executes it using `docker exec`.

**The Plex container must have a writable and executable `/tmp` directory.**

If your Plex container uses a custom RAM-backed temporary filesystem (`tmpfs`) mounted at `/tmp`, it may prevent Docker from copying or executing the DBRepair executable.

This can result in errors such as:

```text
Error: No such container:path
ERROR: Cannot copy DBRepair to Plex
```

Or:

```text
permission denied
```

**Recommended solution:** Remove or disable custom `/tmp` tmpfs mounts in your Plex Docker configuration, then recreate the Plex container before retrying DBRepair.

For Docker Compose, remove or comment out settings such as:

```yaml
tmpfs:
  - /tmp:size=1g,mode=1777
```

You can check your Plex container's temporary filesystem configuration using:

```bash
docker exec plex grep ' /tmp ' /proc/mounts
```

If the output contains `noexec`, programs cannot execute directly from that filesystem.

Plex DBRepair logs failures and exits if it cannot install or execute the repair utility. Database maintenance will not begin if executable staging fails.

After correcting the Plex container configuration, run Plex DBRepair again.
