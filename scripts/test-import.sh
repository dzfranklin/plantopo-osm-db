#!/usr/bin/env bash
# test-import.sh — integration test suite for the OSM import pipeline.
# Runs against a live database; expects import to already be complete.
# Usage: test-import.sh [DATABASE_URL]
#   DATABASE_URL defaults to postgresql://osm@localhost:5433/osm
set -euo pipefail

DB="${1:-postgresql://osm@localhost:5433/osm}"

FAILURES=0

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# Run SQL, return single trimmed value.
# --no-psqlrc avoids user settings (e.g. \x on) corrupting the output.
q() { psql --no-psqlrc "${DB}" -tAc "$1"; }

check_eq() {
    local desc="$1" got="$2" want="$3"
    if [ "${got}" = "${want}" ]; then
        pass "${desc}"
    else
        fail "${desc} (got ${got}, want ${want})"
    fi
}

check_gt() {
    local desc="$1" got="$2" want="$3"
    if [ "${got}" -gt "${want}" ]; then
        pass "${desc}"
    else
        fail "${desc} (got ${got}, want > ${want})"
    fi
}

# ---------------------------------------------------------------------------
echo "=== Row counts ==="
# ---------------------------------------------------------------------------

check_gt "osm_lines row count"    "$(q "SELECT count(*) FROM osm_lines")"    1000
check_gt "osm_polygons row count" "$(q "SELECT count(*) FROM osm_polygons")" 100
check_gt "osm_points row count"   "$(q "SELECT count(*) FROM osm_points")"   100

# ---------------------------------------------------------------------------
echo "=== Buildings excluded ==="
# ---------------------------------------------------------------------------

check_eq "no buildings in osm_lines" \
    "$(q "SELECT count(*) FROM osm_lines WHERE tags->>'building' IS NOT NULL")" "0"
check_eq "no buildings in osm_polygons" \
    "$(q "SELECT count(*) FROM osm_polygons WHERE tags->>'building' IS NOT NULL")" "0"

# ---------------------------------------------------------------------------
echo "=== Trail types present ==="
# ---------------------------------------------------------------------------

check_gt "footways/paths/bridleways/cycleways/tracks in osm_lines" \
    "$(q "SELECT count(*) FROM osm_lines WHERE highway IN ('path','footway','bridleway','cycleway','track')")" \
    0

# ---------------------------------------------------------------------------
echo "=== Geometry validity ==="
# ---------------------------------------------------------------------------

check_eq "no invalid geometries in osm_lines" \
    "$(q "SELECT count(*) FROM osm_lines WHERE NOT ST_IsValid(geom)")" "0"
check_eq "no invalid geometries in osm_polygons" \
    "$(q "SELECT count(*) FROM osm_polygons WHERE NOT ST_IsValid(geom)")" "0"

# ---------------------------------------------------------------------------
echo "=== Projection ==="
# ---------------------------------------------------------------------------

check_eq "osm_lines geometries in SRID 3857" \
    "$(q "SELECT count(*) FROM osm_lines WHERE ST_SRID(geom) != 3857")" "0"
check_eq "osm_polygons geometries in SRID 3857" \
    "$(q "SELECT count(*) FROM osm_polygons WHERE ST_SRID(geom) != 3857")" "0"

# ---------------------------------------------------------------------------
echo "=== Relations table ==="
# ---------------------------------------------------------------------------

check_gt "osm_relations has route relations" \
    "$(q "SELECT count(*) FROM osm_relations WHERE type = 'route'")" 0

# ---------------------------------------------------------------------------
echo "=== Route denormalization ==="
# ---------------------------------------------------------------------------

check_gt "osm_lines with route_relations populated" \
    "$(q "SELECT count(*) FROM osm_lines WHERE route_relations IS NOT NULL")" 0
check_gt "osm_lines with primary_route_network populated" \
    "$(q "SELECT count(*) FROM osm_lines WHERE primary_route_network IS NOT NULL")" 0

# ---------------------------------------------------------------------------
echo ""
echo "=== Sample rows (verify data looks sensible) ==="
# ---------------------------------------------------------------------------

echo ""
echo "--- osm_lines ---"
psql "${DB}" -c \
    "SELECT * FROM osm_lines WHERE name IS NOT NULL AND highway IS NOT NULL LIMIT 1;" \
    2>/dev/null || true
psql "${DB}" -c \
    "SELECT * FROM osm_lines WHERE primary_route_name IS NOT NULL LIMIT 1;" \
    2>/dev/null || true

echo ""
echo "--- osm_polygons ---"
psql "${DB}" -c \
    "SELECT * FROM osm_polygons ORDER BY (name IS NULL) LIMIT 1;" \
    2>/dev/null || true

echo ""
echo "--- osm_points ---"
psql "${DB}" -c \
    "SELECT * FROM osm_points ORDER BY (name IS NULL) LIMIT 1;" \
    2>/dev/null || true

echo ""
echo "--- osm_relations ---"
psql "${DB}" -c \
    "SELECT * FROM osm_relations ORDER BY (name IS NULL) LIMIT 1;" \
    2>/dev/null || true

# ---------------------------------------------------------------------------
echo ""
if [ "${FAILURES}" -eq 0 ]; then
    echo "All tests passed."
else
    echo "${FAILURES} test(s) FAILED."
fi

exit "${FAILURES}"
