#!/usr/bin/env bash
# Testy workflow 13-showroom (zamówienia i leady z tabletu w salonie) na lokalnej bazie.
# Wymaga działającego Supabase z seedem i n8n w trybie testowym (ALLOW_LLM_MOCK=1 scripts/n8n.sh start).
set -euo pipefail

cd "$(dirname "$0")/.."
DB_CONTAINER="supabase_db_meble-automatyzacja"
BASE="${N8N_URL:-http://localhost:5678}/webhook"
RUN="$(date +%s)"
failures=0

q() { docker exec -i "$DB_CONTAINER" psql -U postgres -q -At -v ON_ERROR_STOP=1 -c "$1"; }
ok()   { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }
expect() { local got; got=$(q "$2"); if [ "$got" = "$3" ]; then ok "$1"; else fail "$1" "oczekiwano '$3', jest '$got'"; fi; }
wait_for() { local i; for i in $(seq 1 $(( ${2:-30} * 2 ))); do [ "$(q "$1")" = "t" ] && return 0; sleep 0.5; done; return 1; }
cleanup() { q "delete from orders where external_id like 'showroom:%t$RUN-%'" >/dev/null 2>&1 || true; }
trap cleanup EXIT

CODE="warszawa-mokotow"
TOKEN="$(q "select access_token from showrooms where code = '$CODE'")"
SALES="$(q "select salesperson_email from showrooms where code = '$CODE'")"
PRODUCT="$(q "select id from products p where exists (select 1 from product_materials pm where pm.product_id = p.id) order by name limit 1")"
[ -n "$TOKEN" ] && [ -n "$PRODUCT" ] || { echo "Brak seedu w lokalnej bazie (salony, produkty)."; exit 2; }
post() { curl -s -w '\n%{http_code}' -X POST "$BASE/showroom-order" -H 'Content-Type: application/json' "${@:2}" -d "$1"; }
order() { # order <sufiks> [json dodatkowy] -> treść\nkod
  post "{\"external_id\":\"showroom:$CODE:t$RUN-$1\",\"showroom_code\":\"$CODE\",\"access_token\":\"$TOKEN\",\"consent\":true,\"customer_name\":\"Jan Kowalski\",\"customer_email\":\"jan-$1@example.com\"${2:-}}"
}
code_of() { echo "${1##*$'\n'}"; }
body_of() { echo "${1%$'\n'*}"; }
ITEMS=",\"items\":[{\"product_id\":\"$PRODUCT\",\"qty\":1}]"

# --- informacje o salonie ---------------------------------------------------------------------------
info="$(curl -s -w '\n%{http_code}' "$BASE/showroom-info?code=$CODE")"
if [ "$(code_of "$info")" = "200" ] && [ "$(body_of "$info" | jq -r '.name')" = "$(q "select name from showrooms where code = '$CODE'")" ]; then ok "info: nazwa salonu"; else fail "info" "$info"; fi
body_of "$info" | grep -Eqi 'example\.com|token|@' && fail "info" "wyciek adresu handlowca lub tokenu" || ok "info: bez e-maila handlowca i tokenu"
for bad in "code=nie-ma" "code=" "" "code=../x"; do
  c="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/showroom-info?$bad")"
  [ "$c" = "404" ] && ok "info: '$bad' -> 404" || fail "info '$bad'" "HTTP $c"
done
curl -s -D - -o /dev/null -H 'Origin: http://localhost:8080' "$BASE/showroom-info?code=$CODE" | grep -qi '^access-control-allow-origin: \(\*\|http://localhost:8080\)' \
  && ok "info: CORS dla strony tabletu" || fail "info" "brak nagłówka CORS"
curl -s -D - -o /dev/null -X OPTIONS -H 'Origin: http://localhost:8080' -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: content-type' "$BASE/showroom-order" \
  | grep -qi '^access-control-allow-headers:.*content-type' && ok "order: preflight OPTIONS" || fail "order" "brak preflight"

# --- zamówienie z pozycjami ---------------------------------------------------------------------------
out="$(order a "$ITEMS")"
if [ "$(code_of "$out")" = "200" ] && [ "$(body_of "$out" | jq -r '.status')" = "received" ]; then ok "order: przyjęte"; else fail "order" "$out"; fi
ID="$(q "select id from orders where external_id = 'showroom:$CODE:t$RUN-a'")"
expect "order: źródło, salon, handlowiec i klient z bazy" \
  "select source || '/' || showroom_name || '/' || salesperson_email || '/' || customer_name || '/' || status from orders where id = '$ID'" \
  "showroom/$(q "select name from showrooms where code = '$CODE'")/$SALES/Jan Kowalski/quoted"
wait_for "select (select count(*) from email_outbox where order_id = '$ID') = 2" 30 && ok "order: dwa maile w kolejce" || fail "order" "maile nie pojawiły się"
expect "order: wycena dla klienta" "select count(*) from email_outbox where order_id = '$ID' and kind = 'customer_quote' and to_email = 'jan-a@example.com'" "1"
expect "order: mail do handlowca z linkiem zatwierdzenia" "select count(*) from email_outbox where order_id = '$ID' and kind = 'showroom_lead' and to_email = '$SALES' and body like '%/webhook/approve?order_id=$ID%'" "1"
expect "order: imię klienta tylko w treści maila do handlowca" "select (subject not like '%Kowalski%' and body like '%Jan Kowalski%')::text from email_outbox where order_id = '$ID' and kind = 'showroom_lead'" "true"
expect "order: brak alertu dla właściciela" "select count(*) from email_outbox where order_id = '$ID' and kind = 'owner_alert'" "0"

out="$(order a "$ITEMS")"
if [ "$(code_of "$out")" = "200" ] && [ "$(body_of "$out" | jq -r '.status')" = "duplicate" ]; then ok "order ponownie: duplicate"; else fail "order ponownie" "$out"; fi
sleep 2
expect "order ponownie: jedno zamówienie i dwa maile" "select (select count(*) from orders where external_id = 'showroom:$CODE:t$RUN-a') || '/' || (select count(*) from email_outbox where order_id = '$ID')" "1/2"

# --- odrzucenia -----------------------------------------------------------------------------------------
for case in "unknown|\"showroom_code\":\"nie-ma\"|UNKNOWN_SHOWROOM" "token|\"access_token\":\"zly\"|UNAUTHORIZED" "consent|\"consent\":false|NO_CONSENT" "name|\"customer_name\":\"  \"|INVALID_NAME" "email|\"customer_email\":\"nie-mail\"|INVALID_EMAIL"; do
  IFS='|' read -r label override err <<<"$case"
  # bazowe żądanie z jednym nadpisanym polem
  json="$(jq -c --arg ext "showroom:$CODE:t$RUN-r-$label" ". + {$override} | .external_id = \$ext" <<<"{\"showroom_code\":\"$CODE\",\"access_token\":\"$TOKEN\",\"consent\":true,\"customer_name\":\"Jan\",\"customer_email\":\"jan-r@example.com\",\"notes\":\"x\"}")"
  out="$(post "$json")"
  if [ "$(code_of "$out")" = "422" ] && [ "$(body_of "$out" | jq -r '.error')" = "$err" ]; then ok "order: $err -> 422"; else fail "order $label" "$out"; fi
done
expect "odrzucone żądania nie tworzą zamówień" "select count(*) from orders where external_id like 'showroom:$CODE:t$RUN-r-%'" "0"
out="$(order e "")"
[ "$(code_of "$out")" = "422" ] && [ "$(body_of "$out" | jq -r '.error')" = "EMPTY_LEAD" ] && ok "order: EMPTY_LEAD -> 422" || fail "order pusty lead" "$out"

# --- lead bez pozycji ------------------------------------------------------------------------------------
out="$(order l ",\"notes\":\"Oglądał próbki dębu, oddzwonić po 16\"")"
if [ "$(code_of "$out")" = "200" ] && [ "$(body_of "$out" | jq -r '.status')" = "received" ]; then ok "lead: przyjęty"; else fail "lead" "$out"; fi
LID="$(q "select id from orders where external_id = 'showroom:$CODE:t$RUN-l'")"
expect "lead: needs_review bez wyceny" "select status || '/' || (quote is null)::text from orders where id = '$LID'" "needs_review/true"
wait_for "select (select count(*) from email_outbox where order_id = '$LID') >= 1" 30 || true
sleep 1
expect "lead: tylko mail do handlowca" "select string_agg(kind || '>' || to_email, ',') from email_outbox where order_id = '$LID'" "showroom_lead>$SALES"
expect "lead: notatka i powód w treści" "select (body like '%oddzwonić po 16%' and body like '%bez pozycji%')::text from email_outbox where order_id = '$LID'" "true"

echo
if [ "$failures" -eq 0 ]; then echo "OK"; else echo "FAIL ($failures)"; exit 1; fi
