# syntax=docker/dockerfile:1
FROM debian:bookworm-slim
LABEL org.opencontainers.image.title="Plex DBRepair (Docker exec)" \
      org.opencontainers.image.source="https://github.com/bmartino1/plex-dbrepair-docker" \
      org.opencontainers.image.description="One-shot Plex database maintenance via Docker socket"
ENV DEBIAN_FRONTEND=noninteractive \
    DBREPAIR_MODE=automatic \
    ENABLE_BACKUPS=true \
    RESTORE_LAST_BACKUP=false \
    ALLOW_PLEX_KILL=true \
    RESTART_PLEX=true \
    PLEX_MOUNT=/config \
    PLEX_REL="Library/Application Support/Plex Media Server" \
    PRUNE_DAYS=30 \
    PLEX_CONTAINER_MATCH=plex \
    EXCLUDE_CONTAINER_NAMES=dbrepair,plex-dbrepair \
    EXCLUDE_IMAGE_REGEX=plex-dbrepair \
    DBREPAIR_TIMEOUT=7200 \
    STOP_TIMEOUT=90 \
    LOG_DIR=/logs
RUN apt-get update && apt-get install -y --no-install-recommends \
       bash ca-certificates curl unzip coreutils findutils grep jq procps tar gzip \
       docker.io tini && rm -rf /var/lib/apt/lists/*
# DBRepair is intentionally NOT downloaded or distributed in this image.
# Each end user downloads the appropriate official release at runtime.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh && mkdir -p /logs
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
