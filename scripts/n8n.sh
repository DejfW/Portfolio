#!/usr/bin/env bash
# Uruchamia n8n lokalnie (przez npx, bez instalacji) z konfiguracją potrzebną workflowom.
# Użycie:
#   scripts/n8n.sh start     uruchamia n8n na http://localhost:5678 (tryb testowy: ALLOW_LLM_MOCK=1)
#   scripts/n8n.sh sync      buduje workflowy z n8n/code, importuje je i publikuje (n8n musi być zatrzymane)
#   scripts/n8n.sh <polecenie n8n>   np. list:workflow
# Stan n8n (baza, klucz szyfrowania) leży w tmp/n8n, poza gitem.
set -euo pipefail

cd "$(dirname "$0")/.."
N8N_VERSION="${N8N_VERSION:-2.45.7}"

service_key="$(supabase status -o env 2>/dev/null | sed -n 's/^SERVICE_ROLE_KEY="\(.*\)"$/\1/p')"
api_url="$(supabase status -o env 2>/dev/null | sed -n 's/^API_URL="\(.*\)"$/\1/p')"
if [ -z "$service_key" ] || [ -z "$api_url" ]; then
  echo "Supabase nie działa. Uruchom: supabase start" >&2
  exit 1
fi

export SUPABASE_URL="$api_url"
export SUPABASE_SERVICE_KEY="$service_key"
export PROJECT_DIR="$PWD"
# Tryb testowy (nagłówek X-LLM-Mock, webhook /sweep z krótszymi czasami) jest domyślnie WYŁĄCZONY.
# Do testów: ALLOW_LLM_MOCK=1 scripts/n8n.sh start
export ALLOW_LLM_MOCK="${ALLOW_LLM_MOCK:-0}"
# Opcjonalny wspólny sekret dla webhooka /order (nagłówek X-Intake-Token), np. INTAKE_TOKEN=... scripts/n8n.sh start
export OWNER_EMAIL="${OWNER_EMAIL:-owner@example.com}"
export N8N_USER_FOLDER="$PWD/tmp/n8n"
# Workflowy czytają konfigurację przez $env, a węzeł Execute Command woła scripts/llm.sh.
# Oba są domyślnie wyłączone w n8n 2.x; to środowisko deweloperskie na localhost.
export N8N_BLOCK_ENV_ACCESS_IN_NODE=false
export NODES_EXCLUDE='[]'
export N8N_DIAGNOSTICS_ENABLED=false
export N8N_VERSION_NOTIFICATIONS_ENABLED=false
export N8N_PERSONALIZATION_ENABLED=false
mkdir -p "$N8N_USER_FOLDER"

n8n() { npx --yes "n8n@$N8N_VERSION" "$@"; }

case "${1:-}" in
  start)
    exec npx --yes "n8n@$N8N_VERSION" start
    ;;
  sync)
    node n8n/build.mjs
    for f in n8n/workflows/*.json; do
      n8n import:workflow --input="$f"
    done
    for id in $(jq -r '.id' n8n/workflows/*.json); do
      n8n publish:workflow --id="$id"
    done
    ;;
  *)
    n8n "$@"
    ;;
esac
