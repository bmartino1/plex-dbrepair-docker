# ======================================================
# Base Image
#
# Debian SID is REQUIRED because:
#  - Plex databases can use ICU collations
#  - libsqlite3-ext-icu does NOT exist in Debian stable
#  - This is a one-shot maintenance container
# ======================================================
FROM debian:sid-slim

LABEL org.opencontainers.image.title="Plex DBRepair"
LABEL org.opencontainers.image.description="Native Plex SQLite repair container with ICU support and Docker CLI"
LABEL org.opencontainers.image.source="https://github.com/bmartino1/plex-dbrepair-docker"

ENV DEBIAN_FRONTEND=noninteractive

# ======================================================
# Base runtime dependencies
#
# Notes:
#  - sqlite3 + libsqlite3-ext-icu = ICU support
#  - gawk avoids virtual awk issues
# ======================================================
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        coreutils \
        util-linux \
        procps \
        gzip \
        findutils \
        grep \
        gawk \
        mawk \
        sqlite3 \
        libsqlite3-ext-icu \
        mc \
    && rm -rf /var/lib/apt/lists/*

# ======================================================
# Docker CLI (official)
#
# IMPORTANT:
# Docker does NOT publish a "sid" repo.
# We intentionally use the BOOKWORM repo, which is
# ABI-compatible with SID for the Docker CLI.
#
# This provides /usr/bin/docker for:
#  - stopping Plex containers
#  - restarting Plex containers
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
# Docker CLI sanity check (non-fatal)
#
# Verifies:
#  - docker binary exists
#  - version is visible in build logs
#
# NOTE:
#  - Docker daemon is NOT expected to be running
#  - docker --version does NOT require the daemon
# ======================================================
RUN command -v docker && docker --version || true

# ======================================================
# SQLite ICU sanity check (non-fatal)
#
# Entry point handles runtime safety.
# This only verifies ICU symbols exist.
# ======================================================
RUN sqlite3 :memory: "SELECT icu_load_collation('en_US','test');" || true

# ======================================================
# ChuckPa DBRepair script (for parity & manual use)
#
# IMPORTANT:
#  - Downloaded verbatim
#  - NOT executed automatically
#  - Available in manual mode for audit/debug
# ======================================================
WORKDIR /opt/dbrepair

RUN curl -fsSL \
    https://raw.githubusercontent.com/ChuckPa/DBRepair/refs/heads/master/DBRepair.sh \
    -o DBRepair.sh && \
    chmod +x DBRepair.sh

# ======================================================
# Entrypoint
#
# Implements:
#  - Native SQLite operations
#  - ICU-safe behavior
#  - Plex container self-protection
#  - Modes:
#      * automatic (check → vacuum → reindex)
#      * check
#      * vacuum
#      * repair
#      * reindex
#      * deflate
#      * prune
#      * manual
#  - Optional backup / restore
# ======================================================
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
