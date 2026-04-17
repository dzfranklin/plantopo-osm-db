-- Tile function customised for the trails overlay style.
-- Returns two layers (osm_lines and osm_points) so it can serve as a
-- single source in the style without needing the generic osm endpoint.
-- Only the fields and zoom levels required by the style are included.
-- geom is stored in 3857 (set at import time), so no ST_Transform needed.
CREATE OR REPLACE FUNCTION osm_functions.trails_overlay(z integer, x integer, y integer)
RETURNS bytea AS $$
DECLARE
    tile_env  geometry := ST_TileEnvelope(z, x, y);
    tile_env_m geometry := ST_TileEnvelope(z, x, y, margin => 0.015625);
    lines_mvt bytea;
    points_mvt bytea;
BEGIN
    -- osm_lines layer ----------------------------------------------------------
    -- zoom 7+:  international/national walking routes (iwn, nwn)
    -- zoom 8+:  international/national cycling routes (icn, ncn)
    -- zoom 9+:  regional walking routes (rwn)
    -- zoom 11+: regional cycling (rcn), local routes, and all trail highways
    SELECT ST_AsMVT(tile, 'osm_lines', 4096, 'geom', 'osm_id')
    INTO lines_mvt
    FROM (
        SELECT
            ST_AsMVTGeom(
                CASE
                    WHEN z <= 9  THEN ST_Simplify(geom, 78271.5 / 2^z)
                    WHEN z <= 12 THEN ST_Simplify(geom, 78271.5 / 2^z * 0.5)
                    ELSE geom
                END,
                tile_env, 4096, 64, true
            ) AS geom,
            osm_id,
            highway,
            name,
            primary_route_network,
            primary_route_color,
            primary_route_ref,
            tags
        FROM osm_lines
        WHERE
            geom && tile_env_m
            AND (
                (z >= 7  AND primary_route_network IN ('iwn', 'nwn'))
                OR (z >= 8  AND primary_route_network IN ('icn', 'ncn'))
                OR (z >= 9  AND primary_route_network IN ('rwn'))
                OR (z >= 11 AND (
                    highway IN ('footway', 'path', 'track', 'bridleway', 'cycleway',
                                'steps', 'via_ferrata', 'pedestrian', 'corridor')
                    OR primary_route_network IN ('rcn', 'lwn', 'lcn')
                ))
            )
    ) AS tile;

    -- osm_points layer ---------------------------------------------------------
    -- zoom 15+: barrier nodes (gate, stile, kissing_gate, turnstile, lift_gate)
    SELECT ST_AsMVT(tile, 'osm_points', 4096, 'geom', 'osm_id')
    INTO points_mvt
    FROM (
        SELECT
            ST_AsMVTGeom(geom, tile_env, 4096, 64, true) AS geom,
            osm_id,
            tags
        FROM osm_points
        WHERE
            z >= 15
            AND geom && tile_env_m
            AND tags ? 'barrier'
            AND tags->>'barrier' IN ('gate', 'stile', 'kissing_gate', 'turnstile', 'lift_gate')
    ) AS tile;

    RETURN coalesce(lines_mvt, ''::bytea) || coalesce(points_mvt, ''::bytea);
END
$$ LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE;

-- TileJSON metadata read by Martin at startup.
-- JSON Merge-patched onto Martin's auto-generated TileJSON.
DO $do$ BEGIN
    EXECUTE 'COMMENT ON FUNCTION osm_functions.trails_overlay IS $tj$' || $$
    {
        "description": "Trails overlay: hiking/cycling paths, route networks, and barrier points",
        "minzoom": 7,
        "maxzoom": 16,
        "vector_layers": [
            {
                "id": "osm_lines",
                "fields": {
                    "osm_id": "Number",
                    "highway": "String",
                    "name": "String",
                    "primary_route_color": "String",
                    "primary_route_network": "String",
                    "primary_route_ref": "String",
                    "tags": "String"
                },
                "minzoom": 7,
                "maxzoom": 16
            },
            {
                "id": "osm_points",
                "fields": {
                    "osm_id": "Number",
                    "tags": "String"
                },
                "minzoom": 15,
                "maxzoom": 16
            }
        ]
    }
    $$::json || '$tj$';
END $do$;
