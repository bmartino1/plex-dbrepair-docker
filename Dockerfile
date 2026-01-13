FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="Plex DBRepair"
LABEL org.opencontainers.image.description="SQLite repair container for Plex Media Server databases using ChuckPa DBRepair"
LABEL org.opencontainers.image.source="https://github.com/ChuckPa/DBRepair"

ENV DEBIAN_FRONTEND=noninteractive

# ======================================================
# Runtime dependencies (Docker CLI via docker.io)
# ======================================================

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash \
        curl \
        ca-certificates \
        sqlite3 \
        coreutils \
        util-linux \
        procps \
        gzip \
        libsqlite3-mod-icu \
        findutils \
        grep \
        awk \
        docker.io \
    && rm -rf /var/lib/apt/lists/*
	

# ======================================================
# DBRepair setup
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
