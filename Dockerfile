# ======================================================
# Base Image
#
# We intentionally use Debian SID (unstable) because:
#  - Plex databases REQUIRE SQLite ICU collations
#  - libsqlite3-ext-icu does NOT exist in Debian stable
#  - This container is a one-shot maintenance utility,
#    not a long-running service
# ======================================================
FROM debian:sid-slim

LABEL org.opencontainers.image.title="Plex DBRepair"
LABEL org.opencontainers.image.description="Native Plex SQLite repair container with ICU support, compatible with ChuckPa DBRepair"
LABEL org.opencontainers.image.source="https://github.com/ChuckPa/DBRepair"

ENV DEBIAN_FRONTEND=noninteractive

# ======================================================
# Runtime dependencies
#
# Notes:
#  - sqlite3 + libsqlite3-ext-icu provide ICU collations
#  - docker.io is required to stop/start Plex containers
#    via /var/run/docker.sock
#  - gawk is used instead of virtual 'awk'
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
        docker.io \
        sqlite3 \
        libsqlite3-ext-icu \
    && rm -rf /var/lib/apt/lists/*

# ======================================================
# SQLite ICU sanity check (non-fatal)
#
# We DO NOT fail the build if ICU cannot be loaded.
# The entrypoint script handles runtime behavior safely.
# ======================================================
RUN sqlite3 :memory: "SELECT icu_load_collation('en_US','test');" || true

# ======================================================
# DBRepair (ChuckPa) script
#
# IMPORTANT:
#  - This script is downloaded verbatim and preserved
#  - It is NOT executed automatically by this container
#  - It is available for:
#       * manual debugging
#       * parity with upstream
#       * trust / audit purposes
# ======================================================
WORKDIR /opt/dbrepair

RUN curl -fsSL \
    https://raw.githubusercontent.com/ChuckPa/DBRepair/refs/heads/master/DBRepair.sh \
    -o DBRepair.sh && \
    chmod +x DBRepair.sh

# ======================================================
# Entrypoint
#
# The entrypoint implements:
#  - Native SQLite operations
#  - ICU-safe behavior
#  - Plex container self-protection
#  - Optional backup / restore
#
# DBRepair.sh is NOT called unless user explicitly does so
# in manual mode.
# ======================================================
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
