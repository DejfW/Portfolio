#!/usr/bin/env bash
# Wysyła jedną wiadomość testową na kanał Slacka z .env.local (SLACK_WEBHOOK_URL).
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env.local ] && { set -a; . ./.env.local; set +a; }
[ -n "${SLACK_WEBHOOK_URL:-}" ] || { echo "Brak SLACK_WEBHOOK_URL w .env.local." >&2; exit 1; }
code=$(curl -s -o /tmp/slack-test-body -w '%{http_code}' -X POST -H 'Content-type: application/json' \
  --data '{"text":"Test: system zamówień jest połączony ze Slackiem."}' "$SLACK_WEBHOOK_URL")
body=$(cat /tmp/slack-test-body); rm -f /tmp/slack-test-body
if [ "$code" = "200" ] && [ "$body" = "ok" ]; then echo "OK: wiadomość testowa wysłana"; else echo "Błąd Slacka: HTTP $code $body" >&2; exit 1; fi
