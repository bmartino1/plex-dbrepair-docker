FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="Plex DBRepair"
LABEL org.opencontainers.image.description="SQLite repair container for Plex Media Server databases using ChuckPa DBRepair"
LABEL org.opencontainers.image.source="https://github.com/ChuckPa/DBRepair"

ENV DEBIAN_FRONTEND=noninteractive

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
        screen \
        mc \
        expect \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/dbrepair

RUN curl -fsSL \
    https://raw.githubusercontent.com/ChuckPa/DBRepair/refs/heads/master/DBRepair.sh \
    -o DBRepair.sh && \
    chmod +x DBRepair.sh

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
