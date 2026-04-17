ARG DEBIAN_FRONTEND=noninteractive

FROM --platform=linux/amd64 docker.io/postgis/postgis:18-3.6 AS osm2pgsql-builder

# Based on <https://github.com/iboates/osm-utilities-docker/blob/f3924f6535bba59dcb102a0861b8d604bc7182e3/osm2pgsql/dockerfiles/2.2.0/Dockerfile>

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    cmake \
    make \
    g++ \
    nlohmann-json3-dev \
    libpq-dev \
    libboost-dev \
    libboost-system-dev \
    libexpat1-dev \
    libbz2-dev \
    zlib1g-dev \
    libproj-dev \
    liblua5.3-dev \
    libluajit-5.1-dev \
    python3 \
    python3-dev \
    python3-pip \
    python3-venv \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/osm2pgsql-dev/osm2pgsql.git /osm2pgsql
WORKDIR /osm2pgsql
RUN git checkout 2.1.1

RUN cmake -B build -D WITH_LUAJIT=ON && make -C build -j$(nproc) && make -C build install

RUN python3 -m venv /venv
ENV PATH="/venv/bin:$PATH"
RUN pip install osmium psycopg2

FROM --platform=linux/amd64 docker.io/postgis/postgis:18-3.6

LABEL org.opencontainers.image.source="https://github.com/dzfranklin/plantopo-osm-db"

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    libluajit-5.1-2 \
    liblua5.3-0 \
    libproj-dev \
    libboost-system-dev \
    python3 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=osm2pgsql-builder /usr/local/bin/osm2pgsql* /usr/local/bin/
COPY --from=osm2pgsql-builder /usr/local/share/osm2pgsql/ /usr/local/share/osm2pgsql/
COPY --from=osm2pgsql-builder /osm2pgsql/scripts/osm2pgsql-replication /usr/local/bin/
COPY --from=osm2pgsql-builder /venv /venv
ENV PATH="/venv/bin:$PATH"

# postgresql.conf template — copied into PGDATA by entrypoint.sh after initdb.
COPY src/postgresql.conf /etc/postgresql/postgresql.conf

COPY src/flex-config.lua /osm/flex-config.lua
COPY src/scripts/ /osm/
COPY functions/ /osm/functions/

RUN chmod +x /osm/*.sh

ENTRYPOINT ["/osm/entrypoint.sh"]
