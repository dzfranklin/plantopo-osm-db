#!/usr/bin/env bash
# wait-for-import.sh — poll until osm_lines is non-empty or timeout expires.
# Usage: wait-for-import.sh [DATABASE_URL [TIMEOUT_SECS]]
set -euo pipefail

DB="${1:-postgresql://osm@localhost:5433/osm}"
TIMEOUT="${2:-600}"
DEADLINE=$(( $(date +%s) + TIMEOUT ))

while true; do
    COUNT=$(psql --no-psqlrc "${DB}" -tAc "SELECT count(*) FROM osm_lines" 2>/dev/null || echo 0)
    if [ "${COUNT}" -gt 0 ] 2>/dev/null; then
        echo "  Import complete (${COUNT} rows in osm_lines)."
        exit 0
    fi
    if [ "$(date +%s)" -ge "${DEADLINE}" ]; then
        echo "TIMEOUT: import did not complete within ${TIMEOUT} seconds."
        exit 1
    fi
    echo "  waiting... (osm_lines empty or unreachable)"
    sleep 10
done
