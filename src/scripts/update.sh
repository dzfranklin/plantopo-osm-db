#!/usr/bin/env bash
# update.sh — apply incremental OSM diffs via osm2pgsql-replication.
# Usage: update.sh [DATABASE_URL]
#   DATABASE_URL defaults to postgresql://postgres@localhost/osm
set -euo pipefail

# shellcheck source=lib.sh
source /osm/lib.sh

DATABASE_URL="${1:-postgresql:///osm?user=postgres}"
FLEX_CONFIG="/osm/flex-config.lua"

log "Starting incremental update..."

# Append work_mem to the connection options so it only affects osm2pgsql's
# sessions, leaving martin's tile-serving connections unaffected.
IMPORT_DATABASE_URL="${DATABASE_URL}&options=-c%20work_mem%3D256MB"

osm2pgsql-wrapper osm2pgsql-replication update \
    --database "${IMPORT_DATABASE_URL}" \
    --osm2pgsql-cmd osm2pgsql \
    -- \
    --output=flex \
    --style="${FLEX_CONFIG}" \
    --number-processes="${OSM2PGSQL_PROCS:-4}" \
    --log-progress=true

log "Re-denormalizing route relation names..."

psql "${DATABASE_URL}" -f /osm/denormalize-routes.sql

log "Update complete."
