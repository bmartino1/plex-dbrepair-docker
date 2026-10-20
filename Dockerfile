# syntax=docker/dockerfile:1
FROM debian:bookworm-slim
ARG TARGETARCH
ARG DBREPAIR_VERSION=26.10.00
ARG DBREPAIR_SHA256_AMD64=d85f3252ae8c947feaf3c5e43046ea30a6be66bfed884a0ce808c03bea24253a
ARG DBREPAIR_SHA256_ARM64=c346af079048bff831f032b59851861a37998730ada2e29022bcbb5c019666e3
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
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
      amd64) artifact=x86_64; sha="$DBREPAIR_SHA256_AMD64" ;; \
      arm64) artifact=arm64; sha="$DBREPAIR_SHA256_ARM64" ;; \
      *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/ChuckPa/DBRepair/releases/download/v${DBREPAIR_VERSION}/DBRepair-${DBREPAIR_VERSION}-Linux-${artifact}.zip"; \
    curl -fSL --retry 3 "$url" -o /tmp/dbrepair.zip; \
    echo "$sha  /tmp/dbrepair.zip" | sha256sum -c -; \
    mkdir -p /opt/dbrepair; unzip -q /tmp/dbrepair.zip -d /opt/dbrepair; \
    chmod 0755 /opt/dbrepair/DBRepair; rm /tmp/dbrepair.zip
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh && mkdir -p /logs
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
