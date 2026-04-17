#!/usr/bin/env bash
# entrypoint.sh — starts PostgreSQL, initialises the OSM database on first run,
# then runs daily incremental updates via osm2pgsql-replication.
set -euo pipefail

OSM_DB="${OSM_DB:-osm}"
OSM_USER="${OSM_USER:-osm}"
OSM_DATA_DIR="${OSM_DATA_DIR:-/var/lib/postgresql/18/osm-imports}"
PBF_URL="${PBF_URL:-https://download.geofabrik.de/europe/great-britain-latest.osm.pbf}"
REPLICATION_URL="${REPLICATION_URL:-https://download.geofabrik.de/europe/great-britain-updates}"
UPDATE_HOUR="${UPDATE_HOUR:-3}"   # run update at 03:xx UTC each day
FLEX_CONFIG="/osm/flex-config.lua"
PBF_FILE="${OSM_DATA_DIR}/$(basename "${PBF_URL}")"
PGDATA="${PGDATA:?PGDATA must be set}"

# shellcheck source=lib.sh
source /osm/lib.sh

# ---------------------------------------------------------------------------
# 1. Initialise pgdata if needed, then start PostgreSQL in the background
# ---------------------------------------------------------------------------
log "Starting PostgreSQL..."

if [ ! -f "${PGDATA}/PG_VERSION" ]; then
    log "Initialising database cluster..."
    mkdir -p "${PGDATA}"
    chown -R postgres:postgres "${PGDATA}"
    su postgres -c "initdb --auth-local=trust --auth-host=md5 -D '${PGDATA}'"
    cp /etc/postgresql/postgresql.conf "${PGDATA}/postgresql.conf"
    log "Tuning conf installed."
fi

su postgres -c "postgres -D '${PGDATA}'" &
PG_PID=$!

# Wait until postgres is ready to accept connections
log "Waiting for PostgreSQL to be ready..."
until su postgres -c "pg_isready -q" 2>/dev/null; do
    sleep 1
done
log "PostgreSQL is ready."

# ---------------------------------------------------------------------------
# 2. Allow passwordless connections for the osm read role
# ---------------------------------------------------------------------------
if ! grep -q "host.*${OSM_USER}" "${PGDATA}/pg_hba.conf" 2>/dev/null; then
    echo "host    ${OSM_DB}    ${OSM_USER}    all    trust" >> "${PGDATA}/pg_hba.conf"
    su postgres -c "psql -c 'SELECT pg_reload_conf();'"
fi

# ---------------------------------------------------------------------------
# 3. Create OSM role and database if they don't exist yet
# ---------------------------------------------------------------------------
ROLE_EXISTS=$(su postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${OSM_USER}';\"")
if [ "${ROLE_EXISTS}" != "1" ]; then
    su postgres -c "psql -c \"CREATE ROLE ${OSM_USER} WITH LOGIN;\""
fi

DB_EXISTS=$(su postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${OSM_DB}';\"")
if [ "${DB_EXISTS}" != "1" ]; then
    su postgres -c "psql -c \"CREATE DATABASE ${OSM_DB} OWNER ${OSM_USER};\""
fi

su postgres -c "psql -d ${OSM_DB} -c 'CREATE EXTENSION IF NOT EXISTS postgis;'"
su postgres -c "psql -d ${OSM_DB} -c 'CREATE EXTENSION IF NOT EXISTS hstore;'"

# ---------------------------------------------------------------------------
# 4. Initial import (only if osm_lines table doesn't exist yet) — background
# ---------------------------------------------------------------------------
initial_import() {
    log "No existing data found — starting initial import."

    mkdir -p "${OSM_DATA_DIR}"

    if [ -f "${PBF_FILE}" ]; then
        log "PBF already present at ${PBF_FILE} — skipping download."
    else
        log "Downloading ${PBF_URL} ..."
        wget --progress=dot:giga -O "${PBF_FILE}.tmp" "${PBF_URL}"
        mv "${PBF_FILE}.tmp" "${PBF_FILE}"
        log "Download complete."
    fi

    log "Running osm2pgsql initial import (this will take a while)..."
    osm2pgsql-wrapper osm2pgsql \
        --create \
        --slim \
        --output=flex \
        --style="${FLEX_CONFIG}" \
        --database="postgresql:///${OSM_DB}?user=postgres&options=-c%20work_mem%3D256MB" \
        --number-processes="${OSM2PGSQL_PROCS:-6}" \
        --log-progress=true \
        "${PBF_FILE}" || return 1
    log "Initial import complete. Removing PBF to free space..."
    rm -f "${PBF_FILE}"

    log "Initialising replication state..."
    osm2pgsql-replication init \
        --database "postgresql:///${OSM_DB}?user=postgres" \
        --server "${REPLICATION_URL}"
    log "Replication state initialised."

    log "Creating indexes..."
    su postgres -c "psql -d ${OSM_DB}" <<'SQL'
        CREATE INDEX IF NOT EXISTS osm_lines_highway  ON osm_lines (highway)  WHERE highway  IS NOT NULL;
        CREATE INDEX IF NOT EXISTS osm_lines_waterway ON osm_lines (waterway) WHERE waterway IS NOT NULL;
        CREATE INDEX IF NOT EXISTS osm_lines_natural  ON osm_lines (natural_type)  WHERE natural_type  IS NOT NULL;
        CREATE INDEX IF NOT EXISTS osm_lines_leisure  ON osm_lines (leisure)  WHERE leisure  IS NOT NULL;
        CREATE INDEX IF NOT EXISTS osm_lines_geom     ON osm_lines USING gist (geom);

        CREATE INDEX IF NOT EXISTS osm_polygons_highway  ON osm_polygons (highway)  WHERE highway  IS NOT NULL;
        CREATE INDEX IF NOT EXISTS osm_polygons_waterway ON osm_polygons (waterway) WHERE waterway IS NOT NULL;
        CREATE INDEX IF NOT EXISTS osm_polygons_natural  ON osm_polygons (natural_type)  WHERE natural_type  IS NOT NULL;
        CREATE INDEX IF NOT EXISTS osm_polygons_leisure  ON osm_polygons (leisure)  WHERE leisure  IS NOT NULL;
        CREATE INDEX IF NOT EXISTS osm_polygons_geom     ON osm_polygons USING gist (geom);

        CREATE INDEX IF NOT EXISTS osm_points_geom ON osm_points USING gist (geom);

        -- GIN on tags for ad-hoc prototyping queries
        CREATE INDEX IF NOT EXISTS osm_lines_tags    ON osm_lines    USING gin (tags);
        CREATE INDEX IF NOT EXISTS osm_polygons_tags ON osm_polygons USING gin (tags);

        -- GIN index on route_relations for ad-hoc membership queries
        CREATE INDEX IF NOT EXISTS osm_lines_route_relations ON osm_lines USING gin (route_relations) WHERE route_relations IS NOT NULL;
SQL
    log "Indexes created."

    log "Denormalizing route relation names onto osm_lines..."
    su postgres -c "psql -d ${OSM_DB} -f /osm/denormalize-routes.sql"
    log "Route denormalization complete."

    log "Creating tile functions..."
    su postgres -c "psql -d ${OSM_DB}" <<'SQL'
        -- Zoom-filtered tile function for osm_lines.
        -- At low zoom levels only route-network lines are returned, keeping
        -- tile query cost proportional to what the style actually renders.
        -- geom is stored in 3857 (set at import time), so no ST_Transform needed.
        CREATE OR REPLACE FUNCTION osm_lines_tile(z integer, x integer, y integer)
        RETURNS bytea AS $$
            SELECT ST_AsMVT(tile, 'osm_lines', 4096, 'geom', 'osm_id')
            FROM (
                SELECT
                    ST_AsMVTGeom(
                        geom,
                        ST_TileEnvelope(z, x, y),
                        4096, 64, true
                    ) AS geom,
                    osm_id, highway, leisure, name, natural_type,
                    primary_route_color, primary_route_id, primary_route_name,
                    primary_route_network, primary_route_ref, route,
                    route_relations, tags, waterway, way_id
                FROM osm_lines
                WHERE
                    geom && ST_TileEnvelope(z, x, y, margin => 0.015625)
                    AND (
                        -- zoom 7+: international/national walking and cycling routes
                        (z >= 7 AND primary_route_network IN ('iwn','nwn','icn','ncn'))
                        -- zoom 8+: rivers, canals
                        OR (z >= 8 AND waterway IN ('river','canal'))
                        -- zoom 9+: regional routes
                        OR (z >= 9 AND primary_route_network IN ('rwn','rcn'))
                        -- zoom 11+: all paths, tracks, streams, local routes
                        OR (z >= 11 AND (
                            highway IN ('footway','path','track','bridleway','cycleway',
                                        'steps','via_ferrata','pedestrian','corridor')
                            OR waterway IN ('stream','drain','ditch')
                            OR primary_route_network IN ('lwn','lcn')
                        ))
                    )
            ) AS tile
        $$ LANGUAGE sql STABLE PARALLEL SAFE;

SQL
    su postgres -c "psql -d ${OSM_DB} -c 'GRANT EXECUTE ON FUNCTION osm_lines_tile(integer, integer, integer) TO ${OSM_USER};'"
    log "Tile functions created."

    log "Granting access to ${OSM_USER}..."
    su postgres -c "psql -d ${OSM_DB} -c 'GRANT CONNECT ON DATABASE ${OSM_DB} TO ${OSM_USER};'"
    su postgres -c "psql -d ${OSM_DB} -c 'GRANT USAGE ON SCHEMA public TO ${OSM_USER};'"
    su postgres -c "psql -d ${OSM_DB} -c 'GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${OSM_USER};'"
    su postgres -c "psql -d ${OSM_DB} -c 'ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO ${OSM_USER};'"
    log "Grants complete. Database is ready."

    touch "${OSM_DATA_DIR}/.import-complete"
}

TABLE_EXISTS=$(su postgres -c "psql -d ${OSM_DB} -tAc \"SELECT to_regclass('public.osm_lines')::text;\"")
if [ "${TABLE_EXISTS}" = "" ] || [ "${TABLE_EXISTS}" = "null" ]; then
    (initial_import || { log "FATAL: initial_import failed — exiting container."; kill "${PG_PID}"; }) &
else
    log "Existing data found — skipping initial import."
fi

# ---------------------------------------------------------------------------
# 5. Daily update loop
# ---------------------------------------------------------------------------
log "Entering daily update loop (runs at ${UPDATE_HOUR}:xx UTC)."

daily_update_loop() {
    while true; do
        if [ ! -f "${OSM_DATA_DIR}/.import-complete" ]; then
            sleep 300
            continue
        fi

        CURRENT_HOUR=$(date -u '+%H')
        TARGET_HOUR=$(printf '%02d' "${UPDATE_HOUR}")

        LAST_RUN_FILE="${OSM_DATA_DIR}/.last-update-date"
        TODAY=$(date -u '+%Y-%m-%d')
        LAST_RUN=$(cat "${LAST_RUN_FILE}" 2>/dev/null || echo "")

        if [ "${LAST_RUN}" = "${TODAY}" ]; then
            sleep 300
        elif [ "${CURRENT_HOUR}" = "${TARGET_HOUR}" ]; then
            log "Starting daily update..."
            if /osm/update.sh "postgresql:///${OSM_DB}?user=postgres"; then
                echo "${TODAY}" > "${LAST_RUN_FILE}"
                log "Daily update complete."
            else
                log "ERROR: daily update failed — will retry next day."
            fi
            sleep 300
        else
            sleep 300  # check every 5 minutes
        fi
    done
}

daily_update_loop &

# ---------------------------------------------------------------------------
# 6. Keep the container alive by waiting on postgres
# ---------------------------------------------------------------------------
# Forward SIGTERM/SIGINT to PostgreSQL so systemd can stop the container
# cleanly instead of escalating to SIGKILL after the StopSignal timeout.
_shutdown() {
    log "Caught shutdown signal — stopping PostgreSQL..."
    su postgres -c "pg_ctl stop -D '${PGDATA}' -m fast -w" 2>/dev/null || kill -TERM "${PG_PID}" 2>/dev/null || true
    wait "${PG_PID}" 2>/dev/null || true
    log "PostgreSQL stopped."
    exit 0
}
trap _shutdown TERM INT

wait "${PG_PID}"
