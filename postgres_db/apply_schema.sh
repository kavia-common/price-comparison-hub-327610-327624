#!/bin/bash
set -euo pipefail

# Apply core schema for the Price Comparison Hub.
#
# Design goals:
# - Idempotent: safe to run on every container startup.
# - Minimal but complete: supports searches/queries, offers, price history,
#   and admin-configurable target sites/parsers.
# - Uses db_connection.txt as the authoritative connection source.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if [ ! -f "db_connection.txt" ]; then
  echo "ERROR: db_connection.txt not found. Cannot apply schema."
  exit 1
fi

DB_CMD="$(cat db_connection.txt)"

echo "Applying database schema using: ${DB_CMD}"

# Execute ONE statement at a time (per container rules).
run_sql () {
  local stmt="$1"
  ${DB_CMD} -v ON_ERROR_STOP=1 -c "${stmt}"
}

# --- Core lookup/enum-ish constraints are modeled as text with CHECKs for simplicity. ---

# 1) Target sites (admin configurable)
run_sql "CREATE TABLE IF NOT EXISTS target_sites (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  base_url TEXT NOT NULL,
  is_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  robots_txt_url TEXT NULL,
  rate_limit_per_minute INTEGER NOT NULL DEFAULT 60 CHECK (rate_limit_per_minute > 0),
  requires_js BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);"

run_sql "CREATE INDEX IF NOT EXISTS idx_target_sites_enabled ON target_sites (is_enabled) WHERE is_enabled = TRUE;"

# 2) Parsers per target site (configurable; stores selector/rules as JSON)
run_sql "CREATE TABLE IF NOT EXISTS site_parsers (
  id BIGSERIAL PRIMARY KEY,
  site_id BIGINT NOT NULL REFERENCES target_sites(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  parser_type TEXT NOT NULL DEFAULT 'css' CHECK (parser_type IN ('css','xpath','json','api')),
  config_json JSONB NOT NULL DEFAULT '{}'::jsonb,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  version INTEGER NOT NULL DEFAULT 1,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(site_id, name)
);"

run_sql "CREATE INDEX IF NOT EXISTS idx_site_parsers_site_active ON site_parsers (site_id, is_active);"
run_sql "CREATE INDEX IF NOT EXISTS idx_site_parsers_config_gin ON site_parsers USING GIN (config_json);"

# 3) Searches / queries (user submitted)
run_sql "CREATE TABLE IF NOT EXISTS searches (
  id BIGSERIAL PRIMARY KEY,
  query_text TEXT NOT NULL,
  input_url TEXT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','running','completed','failed')),
  requested_sites JSONB NULL,
  started_at TIMESTAMPTZ NULL,
  completed_at TIMESTAMPTZ NULL,
  error_message TEXT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);"

run_sql "CREATE INDEX IF NOT EXISTS idx_searches_created_at ON searches (created_at DESC);"
run_sql "CREATE INDEX IF NOT EXISTS idx_searches_status ON searches (status);"
run_sql "CREATE INDEX IF NOT EXISTS idx_searches_query_text_trgm ON searches USING GIN (query_text gin_trgm_ops);"

# Ensure pg_trgm exists for trigram index (safe/idempotent)
run_sql "CREATE EXTENSION IF NOT EXISTS pg_trgm;"

# 4) Offers (results from scraping; can be multiple per search and per site)
run_sql "CREATE TABLE IF NOT EXISTS offers (
  id BIGSERIAL PRIMARY KEY,
  search_id BIGINT NOT NULL REFERENCES searches(id) ON DELETE CASCADE,
  site_id BIGINT NULL REFERENCES target_sites(id) ON DELETE SET NULL,
  parser_id BIGINT NULL REFERENCES site_parsers(id) ON DELETE SET NULL,

  product_title TEXT NOT NULL,
  product_url TEXT NOT NULL,
  image_url TEXT NULL,
  currency_code CHAR(3) NULL,
  price_amount NUMERIC(12,2) NULL CHECK (price_amount IS NULL OR price_amount >= 0),
  shipping_amount NUMERIC(12,2) NULL CHECK (shipping_amount IS NULL OR shipping_amount >= 0),
  total_amount NUMERIC(12,2) NULL CHECK (total_amount IS NULL OR total_amount >= 0),

  availability TEXT NULL,
  seller_name TEXT NULL,

  scraped_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  raw_data JSONB NULL
);"

# Uniqueness guard to reduce duplicate rows during retries:
# same search + same product_url + same scraped_at (to the second) is considered duplicate.
run_sql "CREATE UNIQUE INDEX IF NOT EXISTS ux_offers_search_url_scraped
  ON offers (search_id, product_url, date_trunc('second', scraped_at));"

run_sql "CREATE INDEX IF NOT EXISTS idx_offers_search_id ON offers (search_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_offers_site_id ON offers (site_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_offers_scraped_at ON offers (scraped_at DESC);"
run_sql "CREATE INDEX IF NOT EXISTS idx_offers_total_amount ON offers (total_amount);"
run_sql "CREATE INDEX IF NOT EXISTS idx_offers_raw_data_gin ON offers USING GIN (raw_data);"

# 5) Price history (time series per offer URL+site)
# We normalize by (site_id, product_url) so price can be tracked across searches.
run_sql "CREATE TABLE IF NOT EXISTS price_history (
  id BIGSERIAL PRIMARY KEY,
  site_id BIGINT NULL REFERENCES target_sites(id) ON DELETE SET NULL,
  product_url TEXT NOT NULL,
  currency_code CHAR(3) NULL,
  price_amount NUMERIC(12,2) NULL CHECK (price_amount IS NULL OR price_amount >= 0),
  shipping_amount NUMERIC(12,2) NULL CHECK (shipping_amount IS NULL OR shipping_amount >= 0),
  total_amount NUMERIC(12,2) NULL CHECK (total_amount IS NULL OR total_amount >= 0),
  observed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  source_offer_id BIGINT NULL REFERENCES offers(id) ON DELETE SET NULL,
  source_search_id BIGINT NULL REFERENCES searches(id) ON DELETE SET NULL
);"

run_sql "CREATE INDEX IF NOT EXISTS idx_price_history_site_url_time
  ON price_history (site_id, product_url, observed_at DESC);"

run_sql "CREATE INDEX IF NOT EXISTS idx_price_history_observed_at
  ON price_history (observed_at DESC);"

echo "Schema application complete."
