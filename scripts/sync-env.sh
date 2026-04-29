#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env.local"
OUTPUT_FILE="${ROOT_DIR}/env.js"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo ".env.local not found. Copy .env.example to .env.local first."
  exit 1
fi

set -a
source "${ENV_FILE}"
set +a

cat > "${OUTPUT_FILE}" <<EOF
window.VOLTFRIQ_ENV = {
  SUPABASE_URL: "${SUPABASE_URL:-}",
  SUPABASE_ANON_KEY: "${SUPABASE_ANON_KEY:-}"
};
EOF

echo "Wrote ${OUTPUT_FILE}"
