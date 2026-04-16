#!/usr/bin/env bash
log() { echo "[osm-db] $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }

# Run osm2pgsql or osm2pgsql-replication, piping stdout+stderr through sed to
# convert \r to \n so journald doesn't encode progress bars as blob data.
# Exit code is preserved.
osm2pgsql-wrapper() {
    "$@" 2>&1 | sed 's/\r/\n/g'
    [ "${PIPESTATUS[0]}" -eq 0 ]
}
