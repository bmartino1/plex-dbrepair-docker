# Plex DBRepair — Docker exec rewrite (test candidate)

This is a **test candidate, not a production-tested release**. It uses Docker's socket to discover a Plex container, copies ChuckPa DBRepair v26.10.00 into that container, attempts to stop its PMS process without stopping the container, creates a database archive (by default), runs the selected operation, and restarts the Plex container after successful completion.

## Build

```bash
docker build -t plex-dbrepair:dev .
```

The Dockerfile downloads the **pinned** upstream v26.10.00 archive during build and checks its published SHA256. It supports amd64/arm64. Update the version **and hash** together for new releases. Runtime never downloads the executable.

## First test

Test against a *disposable Plex installation with a restored database*, not your only working Plex database.

```bash
docker run --rm --name plex-dbrepair-test \
  --privileged=false \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /mnt/user/appdata/plex-dbrepair-logs:/logs \
  -e PLEX_CONTAINER_NAME=plex \
  -e DBREPAIR_MODE=check \
  -e ENABLE_BACKUPS=true \
  plex-dbrepair:dev
```

Change `PLEX_CONTAINER_NAME` to the exact container name in `docker ps`. Omit it for autodetection if exactly one Plex database candidate exists.

## Supported options

- `DBREPAIR_MODE=automatic|check|vacuum|repair|reindex|deflate|prune|ftscheck|ftsrepair`. Unknown mode maps to `automatic`; `ftscheck` maps to `check`, and `ftsrepair` maps to `reindex` (the compiled DBRepair handles FTS). `manual` is explicitly rejected for an unattended CA run.
- `PLEX_CONTAINER_NAME=auto` (exact target name override).
- `PLEX_CONTAINER_MATCH=plex` (name substring for auto-detection; image names also checked).
- `PLEX_MOUNT=/config`, `PLEX_REL=Library/Application Support/Plex Media Server` (paths **inside the target Plex container**, not the maintenance container).
- `ENABLE_BACKUPS=true` creates `DBRepair-Backups/dbrepair-pre-*.tar.gz` in the target Plex configuration folder, including WAL files, after PMS shutdown.
- `ALLOW_PLEX_KILL=true` allows graceful `SIGTERM` as fallback if native `DBRepair stop` cannot stop PMS.
- `RESTART_PLEX=true` restarts the target container *only after a successful maintenance run*. `RESTART_FALLBACK=true` allows Docker start if the container exited later during cleanup.
- `PRUNE_DAYS=30` for `prune`; `DBREPAIR_TIMEOUT=7200`; `STOP_TIMEOUT=90`; `LOG_DIR=/logs`.
- `RESTORE_LAST_BACKUP=true` **intentionally fails closed**; selecting and restoring databases requires an explicit, reviewed recovery workflow.
- Legacy `ENABLE_FTS_CHECK` and `ENABLE_FTS_REPAIR` variables are accepted but not used: FTS checks and repair are now handled by DBRepair itself.

## Limitations to test before publishing

**No offline method B fallback** is included. If PMS shuts down its container, or is automatically respawned by its supervisor, maintenance aborts. Do not attempt to run SQL against a live PMS database.

This build requires the target Plex container to expose `/bin/sh`, `pidof`, `tar`, and compatible Linux executable support. It uses `docker cp` and `docker exec` as root in the target. Some image variants may not support these assumptions. The DBRepair `stop` command and signal/restart behavior need individual tests for LinuxServer, Binhex and Hotio.

**Failure policy:** On database maintenance errors/timeouts, this candidate leaves Plex stopped where possible, records an error, and exits nonzero for recovery rather than restarting against potentially inconsistent files. Investigate and manually start Plex after the database is confirmed safe. The container should not be given Docker restart policy `always` or `unless-stopped` because that could create a maintenance loop.

Docker socket access is effectively full host administrator access. Install only on trusted hosts and review the code first.

## Logs

Both Unraid Docker logs and timestamped `/logs/dbrepair-*.log` record discovery, image, container ID, mount metadata, action, backup and result. Mount `/logs` to a persistent location.
