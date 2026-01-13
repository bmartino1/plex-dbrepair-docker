# ======================================================
# Base Image
#
# Debian SID is REQUIRED because:
#  - Plex databases can rely on ICU collations
#  - Plex SQLite extensions are NOT in Debian...
#  - This is a one-shot maintenance container
# ======================================================
FROM debian:sid-slim

LABEL org.opencontainers.image.title="Plex DBRepair"
LABEL org.opencontainers.image.description="Native Plex SQLite repair container with Plex SQLite extensions"
LABEL org.opencontainers.image.source="https://github.com/bmartino1/plex-dbrepair-docker"

ENV DEBIAN_FRONTEND=noninteractive

# ======================================================
# Core runtime dependencies
# ======================================================
# ======================================================
# Runtime + SQLite + Diagnostics (Plex-safe)
# ======================================================
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        coreutils \
        util-linux \
        procps \
        psmisc \
        gzip \
        findutils \
        grep \
        gawk \
        mawk \
        less \
        file \
        jq \
        lsof \
        strace \
        tzdata \
        screen \
        mc \
        sqlite3 \
        libsqlite3-0 \
        libsqlite3-ext-icu \
        libsqlite3-mod-fts5 \
        libsqlite3-mod-json1 \
        libsqlite3-mod-spatialite \
    && rm -rf /var/lib/apt/lists/*


# ======================================================
# Docker CLI (official)
#
# Docker does NOT publish a SID repo.
# We intentionally use BOOKWORM (ABI compatible).
# ======================================================
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian bookworm stable" \
        > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends docker-ce-cli && \
    rm -rf /var/lib/apt/lists/*

# ======================================================
# Plex Media Server (HEADLESS INSTALL)
#
# IMPORTANT:
#  - Plex is NEVER started
#  - Ports are NOT exposed
#  - This exists ONLY to provide:
#      * Plex SQLite extensions
#      * Plex collations / tokenizers
# ======================================================
ENV PLEX_DOWNLOAD="https://downloads.plex.tv/plex-media-server-new"
ENV PLEX_ARCH="amd64"

RUN set -eux; \
    PLEX_VERSION="$(curl -fsSL https://plex.tv/api/downloads/5.json \
      | grep -oP '"version":"\K[^"]+' | head -1)"; \
    curl -fsSL \
      "${PLEX_DOWNLOAD}/${PLEX_VERSION}/debian/plexmediaserver_${PLEX_VERSION}_${PLEX_ARCH}.deb" \
      -o /tmp/plex.deb; \
    dpkg -i /tmp/plex.deb || true; \
    apt-get -f install -y; \
    rm -f /tmp/plex.deb; \
    rm -rf /var/lib/apt/lists/*

# ======================================================
# SQLite ICU sanity check (non-fatal)
# ======================================================
RUN sqlite3 :memory: "SELECT icu_load_collation('en_US','test');" || true

# ======================================================
# ChuckPa DBRepair script (parity only)
#
# NOT executed automatically.
# Available in manual mode for inspection.
# ======================================================
WORKDIR /opt/dbrepair

RUN curl -fsSL \
    https://raw.githubusercontent.com/ChuckPa/DBRepair/refs/heads/master/DBRepair.sh \
    -o DBRepair.sh && \
    chmod +x DBRepair.sh

# ======================================================
# Entrypoint
# ======================================================
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
