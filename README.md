# osm-db

Configuration for an OpenStreetMap postgis database for my specific needs.

## Usage with [Martin](https://martin.maplibre.org/)


Example `config.yaml`:

```yaml
postgres:
  - connection_string: "postgresql://osm@host.containers.internal:5433/osm"
    auto_publish:
      functions:
        from_schemas: [osm_functions]
```
