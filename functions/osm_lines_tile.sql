-- Zoom-filtered tile function for osm_lines.
-- At low zoom levels only route-network lines are returned, keeping
-- tile query cost proportional to what the style actually renders.
-- geom is stored in 3857 (set at import time), so no ST_Transform needed.
CREATE OR REPLACE FUNCTION osm_functions.osm_lines_tile(z integer, x integer, y integer)
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
$$ LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE;
