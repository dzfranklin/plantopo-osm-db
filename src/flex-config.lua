-- osm2pgsql flex configuration for plantopo-osm-db
--
-- Schema:
--   osm_points   — nodes with interesting tags
--   osm_lines    — ways (non-closed or explicitly linear)
--   osm_polygons — closed ways and relations that form areas
--
-- Every row stores ALL tags as JSONB plus a small set of extracted columns
-- for indexed filtering. Buildings are excluded entirely.

local srid = 3857  -- Web Mercator, compatible with martin tile server

-- ---------------------------------------------------------------------------
-- Table definitions
-- ---------------------------------------------------------------------------

local points = osm2pgsql.define_node_table('osm_points', {
    { column = 'osm_id',   type = 'int8',       not_null = true },
    { column = 'highway',  type = 'text' },
    { column = 'waterway', type = 'text' },
    { column = 'natural_type', type = 'text' },
    { column = 'leisure',  type = 'text' },
    { column = 'route',    type = 'text' },
    { column = 'name',     type = 'text' },
    { column = 'amenity',    type = 'text' },   -- e.g. drinking_water, toilets, shelter, parking
    { column = 'tourism',    type = 'text' },   -- e.g. viewpoint, camp_site, alpine_hut, information
    { column = 'historic',   type = 'text' },   -- e.g. castle, ruins, memorial, standing_stone
    { column = 'place',      type = 'text' },   -- e.g. city, town, village, hamlet
    { column = 'population', type = 'int8' },   -- parsed from OSM population tag
    { column = 'tags',     type = 'jsonb',       not_null = true },
    { column = 'geom',     type = 'point', projection = srid },
})

local lines = osm2pgsql.define_way_table('osm_lines', {
    { column = 'osm_id',      type = 'int8',        not_null = true },
    { column = 'highway',     type = 'text' },
    { column = 'waterway',    type = 'text' },
    { column = 'natural_type', type = 'text' },
    { column = 'leisure',     type = 'text' },
    { column = 'route',       type = 'text' },
    { column = 'name',        type = 'text' },
    { column = 'route_relations',       type = 'jsonb' },  -- [{id,name,ref,network,color,operator,distance,website,description,osmc_symbol,wikidata,wikipedia}, ...]
    { column = 'primary_route_id',      type = 'int8' },   -- osm_id of highest-priority route relation
    { column = 'primary_route_name',    type = 'text' },
    { column = 'primary_route_ref',     type = 'text' },
    { column = 'primary_route_network', type = 'text' },   -- e.g. iwn, nwn, rwn, lwn, icn, ncn, rcn, lcn
    { column = 'primary_route_color',   type = 'text' },
    { column = 'tags',        type = 'jsonb',        not_null = true },
    { column = 'geom',        type = 'linestring', projection = srid },
})

local polygons = osm2pgsql.define_area_table('osm_polygons', {
    { column = 'osm_id',   type = 'int8',        not_null = true },
    { column = 'highway',  type = 'text' },
    { column = 'waterway', type = 'text' },
    { column = 'natural_type', type = 'text' },
    { column = 'leisure',  type = 'text' },
    { column = 'route',    type = 'text' },
    { column = 'name',     type = 'text' },
    { column = 'tags',     type = 'jsonb',        not_null = true },
    { column = 'geom',     type = 'geometry', projection = srid },
})

-- Relations table (stores route relations etc. for later use)
local relations = osm2pgsql.define_relation_table('osm_relations', {
    { column = 'osm_id',   type = 'int8',        not_null = true },
    { column = 'type',     type = 'text' },
    { column = 'route',    type = 'text' },
    { column = 'name',     type = 'text' },
    { column = 'tags',     type = 'jsonb',        not_null = true },
})

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Returns true if this object should be skipped entirely
local function skip(tags)
    -- Drop buildings
    if tags.building and tags.building ~= 'no' then
        return true
    end
    return false
end

-- Extract the indexed columns from a tags table
local function extract(tags)
    local pop = nil
    if tags.population then
        pop = tonumber(tags.population)  -- nil if not a number
    end
    return {
        highway  = tags.highway,
        waterway = tags.waterway,
        natural_type = tags['natural'],
        leisure  = tags.leisure,
        amenity  = tags.amenity,
        tourism  = tags.tourism,
        historic = tags.historic,
        route    = tags.route,
        name     = tags.name,
        place    = tags.place,
        population = pop,
        tags     = tags,
    }
end

-- Returns true if a way should be treated as an area
local function is_area(object)
    if object.is_closed then
        local t = object.tags
        -- Explicit area tag overrides everything
        if t.area == 'yes' then return true end
        if t.area == 'no'  then return false end
        -- Common area-type tags on closed ways
        if t.landuse or t.leisure or t.natural or t.amenity
            or t.waterway == 'riverbank' or t.waterway == 'dock'
        then
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Callbacks
-- ---------------------------------------------------------------------------

function osm2pgsql.process_node(object)
    local tags = object.tags
    if skip(tags) then return end
    -- Only store nodes that have at least one interesting tag
    if not (tags.highway or tags.waterway or tags['natural']
            or tags.leisure or tags.amenity or tags.tourism
            or tags.historic or tags.name or tags.place or tags.barrier) then
        return
    end
    local row = extract(tags)
    row.osm_id = object.id
    row.geom   = object:as_point()
    points:insert(row)
end

function osm2pgsql.process_way(object)
    local tags = object.tags
    if skip(tags) then return end

    local row = extract(tags)
    row.osm_id = object.id

    if is_area(object) then
        row.geom = object:as_polygon()
        polygons:insert(row)
    else
        row.geom = object:as_linestring()
        lines:insert(row)
    end
end

function osm2pgsql.process_relation(object)
    local tags = object.tags
    if skip(tags) then return end

    -- Store multipolygon relations as polygons
    if tags.type == 'multipolygon' then
        local row = extract(tags)
        row.osm_id = object.id
        row.geom   = object:as_multipolygon()
        polygons:insert(row)
    end

    -- Store all relations in the relations table for route network queries
    relations:insert({
        osm_id = object.id,
        type   = tags.type,
        route  = tags.route,
        name   = tags.name,
        tags   = tags,
    })
end
