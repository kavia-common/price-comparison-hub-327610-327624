# PostgreSQL Schema (Price Comparison Hub)

This DB container bootstraps PostgreSQL and then applies the application schema automatically on startup via:

- `startup.sh` → `apply_schema.sh`
- Connection is read from `db_connection.txt` (authoritative).

## Entities

### `target_sites`
Admin-configured target e-commerce sites.

Key fields:
- `name` (unique)
- `base_url`
- `is_enabled`
- `rate_limit_per_minute`
- `requires_js`

### `site_parsers`
Configurable parsers per site (selectors/rules in JSON).

Key fields:
- `site_id` → `target_sites.id`
- `parser_type`: `css|xpath|json|api`
- `config_json` (JSONB, GIN indexed)
- `is_active`

### `searches`
User searches / scraping jobs.

Key fields:
- `query_text`, `input_url`
- `status`: `pending|running|completed|failed`
- timestamps and error message
- `requested_sites` (JSONB)

Indexes:
- status, created_at
- trigram search on `query_text` using `pg_trgm`

### `offers`
Scraped offers/results for a `search`.

Key fields:
- `search_id` → `searches.id`
- `site_id` → `target_sites.id` (nullable)
- `parser_id` → `site_parsers.id` (nullable)
- product info + pricing fields
- `raw_data` JSONB (GIN indexed)

### `price_history`
Time series of observed prices per `(site_id, product_url)`.

Key fields:
- `site_id` (nullable), `product_url`
- pricing fields
- `observed_at`
- optional provenance: `source_offer_id`, `source_search_id`

## Extensions

- `pg_trgm` is enabled (idempotently) to support `query_text` trigram index.

## Notes

- All DDL is written to be idempotent (`CREATE ... IF NOT EXISTS`).
- `apply_schema.sh` runs statements **one at a time** via `psql -c`.
