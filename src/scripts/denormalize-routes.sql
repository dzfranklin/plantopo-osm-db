-- Denormalize route relation metadata onto osm_lines.
--
-- Run after initial import and after each incremental update.
-- Covers route types: hiking, foot, bicycle, mtb, horse, running.
--
-- Produces:
--   route_relations       — JSONB array of all route relation objects for this way
--   primary_route_*       — scalar fields from the highest-priority relation
--                           (priority: iwn > nwn > icn > ncn > rwn > rcn > lwn > lcn > none)

-- Update ways that belong to at least one route relation
WITH network_priority(network, priority) AS (
    SELECT unnest(ARRAY['iwn','nwn','icn','ncn','rwn','rcn','lwn','lcn']),
           generate_subscripts(ARRAY['iwn','nwn','icn','ncn','rwn','rcn','lwn','lcn'], 1)
),
route_members AS (
    SELECT
        (member->>'ref')::bigint                                            AS way_id,
        r.id                                                                AS rel_id,
        NULLIF(r.tags->>'name',        '')                                  AS name,
        NULLIF(r.tags->>'ref',         '')                                  AS ref,
        NULLIF(r.tags->>'network',     '')                                  AS network,
        COALESCE(NULLIF(r.tags->>'color',''), NULLIF(r.tags->>'colour','')) AS color,
        NULLIF(r.tags->>'operator',    '')                                  AS operator,
        NULLIF(r.tags->>'distance',    '')                                  AS distance,
        COALESCE(NULLIF(r.tags->>'website',''), NULLIF(r.tags->>'url',''))  AS website,
        NULLIF(r.tags->>'description', '')                                  AS description,
        NULLIF(r.tags->>'osmc:symbol', '')                                  AS osmc_symbol,
        NULLIF(r.tags->>'wikidata',    '')                                  AS wikidata,
        NULLIF(r.tags->>'wikipedia',   '')                                  AS wikipedia
    FROM planet_osm_rels r,
         jsonb_array_elements(r.members) AS member
    WHERE r.tags->>'type'  = 'route'
      AND r.tags->>'route' IN ('hiking', 'foot', 'bicycle', 'mtb', 'horse', 'running')
      AND member->>'type'  = 'W'
),
aggregated AS (
    SELECT
        rm.way_id,
        jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'id',          rm.rel_id,
            'name',        rm.name,
            'ref',         rm.ref,
            'network',     rm.network,
            'color',       rm.color,
            'operator',    rm.operator,
            'distance',    rm.distance,
            'website',     rm.website,
            'description', rm.description,
            'osmc_symbol', rm.osmc_symbol,
            'wikidata',    rm.wikidata,
            'wikipedia',   rm.wikipedia
        )))                                                                            AS route_relations,
        -- Primary = highest-priority network; ties broken by name asc
        (array_agg(rm.rel_id  ORDER BY COALESCE(np.priority, 999), rm.name))[1]      AS primary_id,
        (array_agg(rm.name    ORDER BY COALESCE(np.priority, 999), rm.name))[1]      AS primary_name,
        (array_agg(rm.ref     ORDER BY COALESCE(np.priority, 999), rm.name))[1]      AS primary_ref,
        (array_agg(rm.network ORDER BY COALESCE(np.priority, 999), rm.name))[1]      AS primary_network,
        (array_agg(rm.color   ORDER BY COALESCE(np.priority, 999), rm.name))[1]      AS primary_color
    FROM route_members rm
    LEFT JOIN network_priority np ON np.network = rm.network
    GROUP BY rm.way_id
)
UPDATE osm_lines l
SET
    route_relations       = agg.route_relations,
    primary_route_id      = agg.primary_id,
    primary_route_name    = agg.primary_name,
    primary_route_ref     = agg.primary_ref,
    primary_route_network = agg.primary_network,
    primary_route_color   = agg.primary_color
FROM aggregated agg
WHERE l.osm_id = agg.way_id;

-- Clear stale route data from ways no longer in any route relation
UPDATE osm_lines
SET
    route_relations       = NULL,
    primary_route_id      = NULL,
    primary_route_name    = NULL,
    primary_route_ref     = NULL,
    primary_route_network = NULL,
    primary_route_color   = NULL
WHERE route_relations IS NOT NULL
  AND osm_id NOT IN (
      SELECT (member->>'ref')::bigint
      FROM planet_osm_rels r,
           jsonb_array_elements(r.members) AS member
      WHERE r.tags->>'type'  = 'route'
        AND r.tags->>'route' IN ('hiking', 'foot', 'bicycle', 'mtb', 'horse', 'running')
        AND member->>'type'  = 'W'
  );
