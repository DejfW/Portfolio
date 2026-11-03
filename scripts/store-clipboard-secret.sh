#!/usr/bin/env bash
# Zapisuje wartość ze schowka (macOS) do .env.local jako podany klucz, bez wypisywania jej,
# a potem czyści schowek. Przydatne, gdy sekret da się skopiować przyciskiem "Copy" na stronie.
# Użycie: scripts/store-clipboard-secret.sh SLACK_WEBHOOK_URL | GMAIL_APP_PASSWORD | SUPABASE_DB_PASSWORD
set -euo pipefail

cd "$(dirname "$0")/.."
ENV_FILE="${ENV_FILE:-.env.local}"
key="${1:-}"
value="$(pbpaste)"

case "$key" in
  SLACK_WEBHOOK_URL)
    [[ "$value" =~ ^https://hooks\.slack\.com/services/T[A-Z0-9]+/B[A-Z0-9]+/[A-Za-z0-9]+$ ]] || {
      echo "Schowek nie zawiera adresu Incoming Webhook Slacka." >&2; exit 1; } ;;
  GMAIL_APP_PASSWORD)
    value="${value// /}"
    [[ "$value" =~ ^[a-z]{16}$ ]] || { echo "BŁĄD: w schowku nie ma hasła aplikacji (wymagane dokładnie 16 małych liter, spacje są usuwane). Nic nie zapisano." >&2; exit 1; } ;;
  SUPABASE_DB_PASSWORD)
    [ -n "$value" ] || { echo "Schowek jest pusty." >&2; exit 1; } ;;
  *)
    echo "Użycie: $0 SLACK_WEBHOOK_URL | GMAIL_APP_PASSWORD | SUPABASE_DB_PASSWORD" >&2; exit 1 ;;
esac

touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
tmp="$(mktemp)"
KEY="$key" VALUE="$value" awk '
  BEGIN { key = ENVIRON["KEY"]; value = ENVIRON["VALUE"]; gsub(/\047/, "\047\\\047\047", value); line = key "=\047" value "\047" }
  $0 ~ "^" key "=" { if (!done) { print line; done = 1 }; next }
  { print }
  END { if (!done) print line }
' "$ENV_FILE" > "$tmp"
cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"
printf '' | pbcopy
echo "zapisano $key w $ENV_FILE (schowek wyczyszczony)"
