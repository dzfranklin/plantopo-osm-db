# Local development helpers
# Requires: docker, psql
#
# Deployment is handled by GitHub Actions:
#   - changes to Dockerfile or src/** → .github/workflows/docker.yml (full redeploy)
#   - changes to functions/**         → .github/workflows/functions.yml (live update, no rebuild)

GHCR_IMAGE = ghcr.io/dzfranklin/plantopo-osm-db
IMAGE      = $(GHCR_IMAGE):latest
# Small extract for local testing (~25MB vs 1.5GB for GB)
TEST_PBF_URL = https://download.geofabrik.de/europe/united-kingdom/england/rutland-latest.osm.pbf
TEST_REPLICATION_URL = https://download.geofabrik.de/europe/united-kingdom/england/rutland-updates
CONTAINER = osm-db-dev

.PHONY: build push run stop logs psql test-import update deploy-functions clean

clean: stop
	docker volume rm osm-db-dev-data || true

build:
	docker build --platform linux/amd64 -t $(IMAGE) .

# Run with the test extract (Rutland) instead of the full GB dump
run: build
	docker run --rm -it \
		--platform linux/amd64 \
		--name $(CONTAINER) \
		-p 5433:5432 \
		-v osm-db-dev-data:/var/lib/postgresql/18 \
		-e PBF_URL=$(TEST_PBF_URL) \
		-e REPLICATION_URL=$(TEST_REPLICATION_URL) \
		-e OSM2PGSQL_PROCS=2 \
		$(IMAGE)

stop:
	docker stop $(CONTAINER) || true

logs:
	docker logs -f $(CONTAINER)

psql:
	psql postgresql://osm@localhost:5433/osm

update:
	docker exec $(CONTAINER) /osm/update.sh

# Apply functions against the dev container (no martin restart)
deploy-functions:
	docker cp functions/. $(CONTAINER):/osm/functions/
	docker exec $(CONTAINER) python3 /osm/functions/deploy.py --no-restart

# Wait for the import to complete, then run the integration test suite.
# Assumes the container is already running (make run).
test-import:
	@echo "=== Waiting for import to complete (timeout 10m) ==="
	src/scripts/wait-for-import.sh
	@echo "=== Running integration tests ==="
	src/scripts/test-import.sh
