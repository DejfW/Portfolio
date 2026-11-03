#!/usr/bin/env bash
# Uruchamia n8n lokalnie (przez npx, bez instalacji) z konfiguracją potrzebną workflowom.
# Użycie:
#   scripts/n8n.sh start     uruchamia n8n na http://localhost:5678 (tryb testowy: ALLOW_LLM_MOCK=1)
#   scripts/n8n.sh sync      buduje workflowy z n8n/code, importuje je i publikuje (n8n musi być zatrzymane)
#   scripts/n8n.sh <polecenie n8n>   np. list:workflow
# Stan n8n (baza, klucz szyfrowania) leży w tmp/n8n, poza gitem.
set -euo pipefail

cd "$(dirname "$0")/.."

# Dane dostępowe (Gmail, Slack) trzymamy w .env.local, który jest poza gitem. Wzór: env.local.example
if [ -f .env.local ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env.local
  set +a
fi
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
export TEST_SINK_PORT="${TEST_SINK_PORT:-18765}"
# Hasło operatora (logowanie Basic do linków zatwierdzania i zamykania zadań). Jeśli go nie ma, generujemy je
# i zapisujemy w .env.local (uprawnienia 600); nigdy nie jest wypisywane.
if [ -z "${OPERATOR_PASSWORD:-}" ]; then
  # openssl zamiast potoku tr|head: przy pipefail SIGPIPE po cichu przerywał skrypt
  OPERATOR_PASSWORD="$(openssl rand -hex 16)"
  touch .env.local; chmod 600 .env.local
  printf "OPERATOR_PASSWORD='%s'\n" "$OPERATOR_PASSWORD" >> .env.local
  echo "Wygenerowano hasło operatora i zapisano w .env.local (OPERATOR_PASSWORD)." >&2
fi
export OPERATOR_USER="${OPERATOR_USER:-operator}"
export OPERATOR_PASSWORD
export OWNER_EMAIL="${OWNER_EMAIL:-owner@example.com}"
export N8N_USER_FOLDER="$PWD/tmp/n8n"
# Workflowy czytają konfigurację przez $env, a węzeł Execute Command woła scripts/llm.sh.
# Oba są domyślnie wyłączone w n8n 2.x; to środowisko deweloperskie na localhost.
export N8N_BLOCK_ENV_ACCESS_IN_NODE=false
export NODES_EXCLUDE='[]'
# Harmonogramy (np. raport o 7:00) liczą się w czasie polskim
export GENERIC_TIMEZONE="${GENERIC_TIMEZONE:-Europe/Warsaw}"
export TZ="$GENERIC_TIMEZONE"
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
    # Poświadczenie SMTP dla Gmaila powstaje z .env.local w pliku tymczasowym (uprawnienia 600),
    # który jest usuwany zaraz po imporcie. Hasło nie trafia do repozytorium ani do logów.
    if [ -n "${GMAIL_USER:-}" ] && [ -n "${GMAIL_APP_PASSWORD:-}" ]; then
      cred_file="$(mktemp)"
      node -e '
        const fs = require("fs");
        fs.writeFileSync(process.argv[1], JSON.stringify([{
          id: "smtpgmail000001", name: "Gmail SMTP", type: "smtp",
          data: { user: process.env.GMAIL_USER, password: process.env.GMAIL_APP_PASSWORD,
                  host: "smtp.gmail.com", port: 465, secure: true },
        }]), { mode: 0o600 });
      ' "$cred_file"
      n8n import:credentials --input="$cred_file" || echo "Import poświadczeń SMTP nie powiódł się" >&2
      rm -f "$cred_file"
    else
      echo "Pominięto poświadczenia SMTP (brak GMAIL_USER lub GMAIL_APP_PASSWORD w .env.local)"
    fi
    # Poświadczenie Basic dla linków operatora (z .env.local, plik tymczasowy usuwany po imporcie)
    op_file="$(mktemp)"
    node -e '
      const fs = require("fs");
      fs.writeFileSync(process.argv[1], JSON.stringify([{
        id: "operatorauth0001", name: "Operator", type: "httpBasicAuth",
        data: { user: process.env.OPERATOR_USER, password: process.env.OPERATOR_PASSWORD },
      }]), { mode: 0o600 });
    ' "$op_file"
    n8n import:credentials --input="$op_file" || echo "Import poświadczenia operatora nie powiódł się" >&2
    rm -f "$op_file"
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
