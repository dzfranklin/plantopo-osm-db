# Local development helpers
# Requires: docker, psql
#
# Deployment is handled by GitHub Actions:
#   - changes to Dockerfile or src/** → .github/workflows/docker.yml (full redeploy)
#   - changes to functions/**         → .github/workflows/functions.yml (live update, no rebuild)

GHCR_IMAGE = ghcr.io/dzfranklin/plantopo-osm-db
IMAGE      = $(GHCR_IMAGE):latest
TEST_PBF_URL = https://download.geofabrik.de/europe/united-kingdom/scotland-latest.osm.pbf
TEST_REPLICATION_URL = https://download.geofabrik.de/europe/united-kingdom/scotland-updates
CONTAINER        = osm-db-dev
MARTIN_CONTAINER = osm-martin-dev

.PHONY: build push run stop logs psql test-import update deploy-functions clean martin martin-stop

clean: stop
	docker volume rm osm-db-dev-data || true

clean-all: clean
	docker volume rm osm-db-dev-pbf || true

build:
	docker build --platform linux/amd64 -t $(IMAGE) .

# Run with the test extract (Rutland) instead of the full GB dump
run: build
	@trap 'docker stop $(CONTAINER) 2>/dev/null; exit 0' INT TERM EXIT; \
	docker run --rm \
		--platform linux/amd64 \
		--name $(CONTAINER) \
		-p 5433:5432 \
		-v osm-db-dev-data:/var/lib/postgresql/18 \
		-v osm-db-dev-pbf:/var/lib/postgresql/18/osm-imports \
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

deploy-functions:
	docker cp functions/. $(CONTAINER):/osm/functions/
	docker exec $(CONTAINER) python3 /osm/functions/deploy.py

martin:
	@(sleep 2 && open http://localhost:3000 && open https://maplibre.org/maputnik/?style=http%3A%2F%2Flocalhost%3A3000%2Fstyle%2Ftrails.overlay.style) &
	docker run --rm -it \
		--name $(MARTIN_CONTAINER) \
		-p 3000:3000 \
		-v $(PWD)/examples:/examples:ro \
		ghcr.io/maplibre/martin \
		--config /examples/martin-config.yaml \
		--listen-addresses 0.0.0.0:3000

martin-stop:
	docker stop $(MARTIN_CONTAINER) || true

# Wait for the import to complete, then run the integration test suite.
# Assumes the container is already running (make run).
test-import:
	@echo "=== Waiting for import to complete (timeout 10m) ==="
	src/scripts/wait-for-import.sh
	@echo "=== Running integration tests ==="
	src/scripts/test-import.sh
