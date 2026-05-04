#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS_DIR="$ROOT_DIR/supabase/migrations"
SCHEMA_FILE="$ROOT_DIR/supabase/schema.sql"

tmp_file="$(mktemp)"
{
  echo "-- Auto-generated from supabase/migrations."
  echo "-- Rebuild with ./scripts/rebuild-schema.sh"
  echo
  find "$MIGRATIONS_DIR" -maxdepth 1 -type f -name '*.sql' | sort | while read -r file; do
    echo
    echo "-- >>> $(basename "$file")"
    cat "$file"
    echo
  done
} > "$tmp_file"

mv "$tmp_file" "$SCHEMA_FILE"
echo "Rebuilt $SCHEMA_FILE"
