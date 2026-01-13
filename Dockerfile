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
    && rm -rf /var/lib/apt/lists/*

# ======================================================
# Docker CLI (official, provides /usr/bin/docker)
#
# This is REQUIRED for:
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
https://download.docker.com/linux/debian sid stable" \
        > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends docker-ce-cli && \
    rm -rf /var/lib/apt/lists/*

# ======================================================
# SQLite ICU sanity check (non-fatal)
#
# Entry point handles runtime safety.
# This just confirms ICU symbols exist.
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
#  - Optional backup / restore
# ======================================================
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
