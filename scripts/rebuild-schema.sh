#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEMA_FILE="$ROOT_DIR/supabase/schema.sql"
export PATH="/opt/homebrew/opt/libpq/bin:$PATH"

if [[ -f "$ROOT_DIR/.env.local" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.env.local"
fi

tmp_dump="$(mktemp)"
tmp_final="$(mktemp)"
tmp_plan="$(mktemp)"

dump_args=(db dump --linked --schema public --schema storage --dry-run)
if [[ -n "${SUPABASE_DATABASE_PASSWORD:-}" ]]; then
  dump_args+=(--password "$SUPABASE_DATABASE_PASSWORD")
fi

supabase "${dump_args[@]}" > "$tmp_plan"

export PGHOST="$(grep '^export PGHOST=' "$tmp_plan" | cut -d'"' -f2)"
export PGPORT="$(grep '^export PGPORT=' "$tmp_plan" | cut -d'"' -f2)"
export PGUSER="$(grep '^export PGUSER=' "$tmp_plan" | cut -d'"' -f2)"
export PGPASSWORD="$(grep '^export PGPASSWORD=' "$tmp_plan" | cut -d'"' -f2)"
export PGDATABASE="$(grep '^export PGDATABASE=' "$tmp_plan" | cut -d'"' -f2)"

pg_dump \
  --schema-only \
  --quote-all-identifier \
  --role "postgres" \
  --schema=public \
  --schema=storage \
  > "$tmp_dump"

{
  echo "-- Canonical schema snapshot for VoltFriq."
  echo "-- Rebuild with ./scripts/rebuild-schema.sh"
  echo
  cat "$tmp_dump"
} > "$tmp_final"

mv "$tmp_final" "$SCHEMA_FILE"
rm -f "$tmp_dump" "$tmp_plan"
echo "Rebuilt $SCHEMA_FILE from linked database dump"
