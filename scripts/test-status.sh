#!/usr/bin/env bash
# Testy workflowów 10-status-notify i 12-review-request oraz publicznej strony statusu na lokalnej bazie.
# Wymaga działającego Supabase z seedem, n8n w trybie testowym (ALLOW_LLM_MOCK=1 scripts/n8n.sh start) i
# serwera stron (node scripts/serve-web.mjs) na http://localhost:8080.
set -euo pipefail

cd "$(dirname "$0")/.."
DB_CONTAINER="supabase_db_meble-automatyzacja"
BASE="${N8N_URL:-http://localhost:5678}/webhook"
WEB="${WEB_URL:-http://localhost:8080}"
RUN="$(date +%s)"
failures=0

q() { docker exec -i "$DB_CONTAINER" psql -U postgres -q -At -v ON_ERROR_STOP=1 -c "$1"; }
ok()   { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }
expect() { local got; got=$(q "$2"); if [ "$got" = "$3" ]; then ok "$1"; else fail "$1" "oczekiwano '$3', jest '$got'"; fi; }
wait_for() { local i; for i in $(seq 1 $(( ${2:-30} * 2 ))); do [ "$(q "$1")" = "t" ] && return 0; sleep 0.5; done; return 1; }
START_TS="$(q "select now()")"
# kopia stanu, który testowe uruchomienia webhooków mogą zmienić także dla cudzych zamówień
RESTORE_EVENTS="$(q "select coalesce(string_agg(format('%L', id), ','), '') from order_events where notified_at is null")"
RESTORE_REVIEWS="$(q "select coalesce(string_agg(format('%L', id), ','), '') from orders where status = 'done' and review_requested_at is null")"
cleanup() {
  q "delete from orders where external_id like 'st-$RUN-%'" >/dev/null 2>&1 || true
  q "delete from email_outbox where created_at >= '$START_TS' and kind in ('status_approved', 'status_in_progress', 'review_request')" >/dev/null 2>&1 || true
  [ -n "$RESTORE_EVENTS" ] && q "update order_events set notified_at = null where id in ($RESTORE_EVENTS)" >/dev/null 2>&1 || true
  [ -n "$RESTORE_REVIEWS" ] && q "update orders set review_requested_at = null where id in ($RESTORE_REVIEWS)" >/dev/null 2>&1 || true
}
trap cleanup EXIT

API_URL="$(supabase status -o env 2>/dev/null | sed -n 's/^API_URL="\(.*\)"$/\1/p')"
ANON_KEY="$(supabase status -o env 2>/dev/null | sed -n 's/^ANON_KEY="\(.*\)"$/\1/p')"
[ -n "$API_URL" ] && [ -n "$ANON_KEY" ] || { echo "Supabase nie działa (supabase start)."; exit 2; }

mk() { q "insert into orders (external_id, source, customer_email, kind, status, quote) values ('st-$RUN-$1', 'form', 'st-$1@example.com', 'catalog', '$2',
          '{\"total\": 2400, \"lines\": [{\"label\": \"Komoda\", \"qty\": 1}]}'::jsonb) returning id"; }
run_status() { curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/status-run" || true; }
run_review() { curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/review-run" -H 'Content-Type: application/json' -d "{\"review_url\":\"$1\"}" || true; }

# --- powiadomienie o rozpoczęciu realizacji -------------------------------------------------------------------------
q "update order_events set notified_at = now() where notified_at is null" >/dev/null   # zdarzenia z innych testów
A=$(mk a quoted); B=$(mk b quoted)
q "update orders set status = 'approved' where id = '$A'; update orders set status = 'in_progress' where id = '$A'; update orders set status = 'done' where id = '$B'" >/dev/null
TA=$(q "select public_token from orders where id = '$A'")
[ "$(run_status)" = "200" ] && ok "status-run: uruchomiony" || fail "status-run" "nie 200"
wait_for "select count(*) = 1 from email_outbox where order_id = '$A' and kind = 'status_in_progress'" 30 && ok "status: mail o realizacji (zatwierdzone + w realizacji = jeden mail)" || fail "status" "brak maila"
expect "status: link do strony statusu z tokenem zamówienia" "select (body like '%http://localhost:8080/status.html?token=$TA%')::text from email_outbox where order_id = '$A' and kind = 'status_in_progress'" "true"
expect "status: zakończone zamówienie nie dostaje maila statusowego" "select count(*) from email_outbox where order_id = '$B' and kind like 'status_%'" "0"
[ "$(run_status)" = "200" ] && sleep 3
expect "status: ponowne uruchomienie niczego nie dubluje" "select count(*) from email_outbox where kind like 'status_%' and order_id in ('$A', '$B')" "1"

# --- prośba o opinię ---------------------------------------------------------------------------------------------------
q "update order_events set created_at = now() - interval '8 days' where order_id = '$B' and new_status = 'done'" >/dev/null
[ "$(run_review "https://g.page/r/demo/review")" = "200" ] && ok "review-run: uruchomiony" || fail "review-run" "nie 200"
wait_for "select count(*) = 1 from email_outbox where order_id = '$B' and kind = 'review_request'" 30 && ok "opinia: mail z prośbą po 7 dniach od zakończenia" || fail "opinia" "brak maila"
expect "opinia: link i prośba o zdjęcie w treści" "select (body like '%https://g.page/r/demo/review%' and body like '%zdjęcie%')::text from email_outbox where order_id = '$B' and kind = 'review_request'" "true"
expect "opinia: oznaczone jako poproszone" "select (review_requested_at is not null)::text from orders where id = '$B'" "true"
run_review "https://g.page/r/demo/review" >/dev/null; sleep 3
expect "opinia: tylko raz" "select count(*) from email_outbox where order_id = '$B' and kind = 'review_request'" "1"
C=$(mk c quoted); q "update orders set status = 'done' where id = '$C'; update order_events set created_at = now() - interval '8 days' where order_id = '$C' and new_status = 'done'" >/dev/null
run_review "http://nie-https.example/x" >/dev/null; sleep 3
expect "opinia: adres inny niż https nie wysyła nic" "select count(*) from email_outbox where order_id = '$C' and kind = 'review_request'" "0"
expect "opinia: zamówienie z błędnym adresem zostaje do ponowienia" "select (review_requested_at is null)::text from orders where id = '$C'" "true"

# --- publiczne API statusu (rola anon) -----------------------------------------------------------------------------------
rpc() { curl -s -w '\n%{http_code}' -X POST "$API_URL/rest/v1/rpc/$1" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_KEY" -H 'Content-Type: application/json' -d "$2"; }
out="$(rpc order_status_public "{\"p_token\":\"$TA\"}")"
code="${out##*$'\n'}"; body="${out%$'\n'*}"
if [ "$code" = "200" ] && [ "$(echo "$body" | jq -r '.label_pl')" = "W realizacji" ] && [ "$(echo "$body" | jq '.timeline | length')" -ge 2 ]; then ok "anon: status zamówienia i oś czasu"; else fail "anon status" "$out"; fi
echo "$body" | grep -Eqi 'example\.com|2400|quote|customer|email|total' && fail "anon status" "wyciek danych: $body" || ok "anon: odpowiedź bez e-maila, kwot i wyceny"
out="$(rpc order_status_public '{"p_token":"00000000-0000-0000-0000-000000000000"}')"
[ "${out%$'\n'*}" = "{}" ] && ok "anon: nieznany token -> {}" || fail "anon nieznany token" "$out"
for fn in 'notify_status_events|{}' 'send_review_requests|{"p_review_url":"https://x.example"}' 'quote_preview|{"p":{}}' 'orders_due_review|{}'; do
  out="$(rpc "${fn%%|*}" "${fn##*|}")"; c="${out##*$'\n'}"
  case "$c" in 401|403|404) ok "anon: ${fn%%|*} niedostępna ($c)" ;; *) fail "anon ${fn%%|*}" "HTTP $c: $out" ;; esac
done
c="$(curl -s -o /dev/null -w '%{http_code}' "$API_URL/rest/v1/orders?select=customer_email" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_KEY")"
case "$c" in 401|403|404) ok "anon: tabela orders niedostępna ($c)" ;; *) fail "anon orders" "HTTP $c" ;; esac

# --- strona statusu serwowana z kluczem publicznym -----------------------------------------------------------------------
page="$(curl -s -D - "$WEB/status.html?token=$TA")"
if echo "$page" | grep -qi '^HTTP/1.1 200' && ! echo "$page" | grep -q '__SUPABASE'; then ok "status.html: strona z wstawionym adresem i kluczem"; else fail "status.html" "brak strony albo niewstawione znaczniki"; fi
echo "$page" | grep -qi "connect-src $(echo "$API_URL" | sed -E 's#^(https?://[^/]+).*#\1#')" && ok "status.html: CSP zezwala tylko na Supabase" || fail "status.html" "zła CSP"
PAGE_KEY="$(echo "$page" | sed -n 's/.*KEY = "\([^"]*\)".*/\1/p' | head -1)"
ROLE="$(echo "$PAGE_KEY" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq -r '.role' 2>/dev/null || true)"
case "$PAGE_KEY" in sb_publishable_*) ok "status.html: klucz publiczny sb_publishable" ;; *)
  [ "$ROLE" = "anon" ] && ok "status.html: wstawiony klucz ma rolę anon" || fail "status.html" "klucz w stronie ma rolę '$ROLE'" ;; esac

echo
if [ "$failures" -eq 0 ]; then echo "OK"; else echo "FAIL ($failures)"; exit 1; fi
