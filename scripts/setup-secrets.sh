#!/usr/bin/env bash
# Interaktywnie zapisuje dane dostępowe do .env.local (plik poza gitem, uprawnienia 600).
# Wpisywane wartości nie są wyświetlane ani nigdzie logowane. Enter pomija pole i zostawia obecną wartość.
# Użycie: scripts/setup-secrets.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ENV_FILE="${ENV_FILE:-.env.local}"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

# set_var KLUCZ WARTOŚĆ: ustawia KLUCZ='WARTOŚĆ' w pliku (bez duplikatów, z poprawnym cytowaniem),
# żeby znaki specjalne w haśle nie psuły wczytywania pliku przez powłokę.
set_var() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  KEY="$key" VALUE="$value" awk '
    BEGIN {
      key = ENVIRON["KEY"]; value = ENVIRON["VALUE"]
      gsub(/\047/, "\047\\\047\047", value)
      line = key "=\047" value "\047"
    }
    $0 ~ "^" key "=" { if (!done) { print line; done = 1 }; next }
    { print }
    END { if (!done) print line }
  ' "$ENV_FILE" > "$tmp"
  cat "$tmp" > "$ENV_FILE"
  rm -f "$tmp"
}

has_var() { grep -q "^$1='.\+'" "$ENV_FILE" 2>/dev/null; }

if [ "${1:-}" = "--status" ]; then
  for k in SUPABASE_CLOUD_REF SUPABASE_DB_PASSWORD GMAIL_USER GMAIL_APP_PASSWORD SLACK_WEBHOOK_URL; do
    if has_var "$k"; then echo "ustawione  $k"; else echo "brak       $k"; fi
  done
  exit 0
fi

# ask KLUCZ "opis" [sekret|jawne] [wartość domyślna]
ask() {
  local key="$1" label="$2" kind="${3:-sekret}" default="${4:-}" value="" suffix=""
  has_var "$key" && suffix=" [jest ustawione, Enter zostawia]"
  [ -n "$default" ] && ! has_var "$key" && suffix=" [Enter = $default]"
  if [ "$kind" = "sekret" ]; then
    read -r -s -p "$label$suffix: " value || true
    echo
  else
    read -r -p "$label$suffix: " value || true
  fi
  if [ -z "$value" ] && [ -n "$default" ] && ! has_var "$key"; then value="$default"; fi
  if [ -n "$value" ]; then
    # hasła aplikacji Google bywają wyświetlane ze spacjami co 4 znaki; spacje nie należą do hasła
    [ "$key" = "GMAIL_APP_PASSWORD" ] && value="${value// /}"
    set_var "$key" "$value"
    echo "  zapisano $key"
  else
    echo "  pominięto $key"
  fi
}

echo "Dane zapisuję w $ENV_FILE (poza gitem). Skrypt pyta wyłącznie o sekrety, a wpisywane znaki nie są widoczne."
echo "Wpisuj każde hasło tylko przy jego własnym pytaniu."
echo
echo "== Supabase (projekt Portfolio) =="
# Ref projektu nie jest sekretem i nie jest pytaniem: pole jest jawne, więc łatwo wpisać w nie hasło.
# Zawsze ustawiamy znaną wartość, a jeśli w pliku jest coś innego niż 20 małych liter, nadpisujemy to.
PORTFOLIO_REF="ifbeqnhgoemhfricouii"
set_var SUPABASE_CLOUD_REF "$PORTFOLIO_REF"
echo "  ref projektu: $PORTFOLIO_REF"
ask SUPABASE_DB_PASSWORD "Hasło do bazy projektu Portfolio (wpisz je tutaj, znaki nie będą widoczne)" sekret
echo
echo "== Gmail (dawidmarekportfolio@gmail.com) =="
# Adres konta też jest stałą (nie pytamy o niego, bo pole jawne łatwo pomylić z polem na hasło).
set_var GMAIL_USER "dawidmarekportfolio@gmail.com"
echo "  konto: dawidmarekportfolio@gmail.com"
ask GMAIL_APP_PASSWORD "Hasło aplikacji Google (16 znaków)" sekret
echo
echo "== Slack (#zamowienia-demo) =="
ask SLACK_WEBHOOK_URL "Adres Incoming Webhook (https://hooks.slack.com/services/...)" sekret
if has_var SLACK_WEBHOOK_URL && ! grep -q "^SLACK_WEBHOOK_URL='https://hooks.slack.com/services/" "$ENV_FILE"; then
  echo "  uwaga: to nie wygląda jak adres Incoming Webhook Slacka; wpisz poprawny przy następnym uruchomieniu"
  set_var SLACK_WEBHOOK_URL ""
fi

echo
if has_var SUPABASE_DB_PASSWORD; then
  read -r -p "Sprawdzić teraz, co zostałoby wdrożone do chmury (dry run, nic nie zmienia)? [t/N] " yn || true
  if [[ "${yn:-}" =~ ^[tTyY]$ ]]; then
    scripts/deploy-db.sh
  fi
fi
echo "Gotowe. Sprawdzenie bez ujawniania wartości: scripts/setup-secrets.sh --status"
