#!/usr/bin/env bash
# Testy workflow 04-stock-prices: import cenników z CSV i raport magazynu na lokalnej bazie.
# Wymaga działającego Supabase i n8n w trybie testowym (ALLOW_LLM_MOCK=1 scripts/n8n.sh start).
# Po zakończeniu przywraca ceny hurtowni i usuwa własne wiadomości.
set -euo pipefail

cd "$(dirname "$0")/.."
DB_CONTAINER="supabase_db_meble-automatyzacja"
BASE="${N8N_URL:-http://localhost:5678}/webhook"
RUN="$(date +%s)"
failures=0

q() { docker exec -i "$DB_CONTAINER" psql -U postgres -q -At -v ON_ERROR_STOP=1 -c "$1"; }

RESTORE_SQL="$(q "select string_agg(format('insert into supplier_prices (supplier_id, material_id, price, updated_at) values (%L, %L, %s, %L) on conflict (supplier_id, material_id) do update set price = excluded.price, updated_at = excluded.updated_at;', supplier_id, material_id, price, updated_at), ' ') from supplier_prices")"
cleanup() {
  q "delete from slack_outbox where dedupe_key like 'stock-digest:t$RUN%'" >/dev/null 2>&1 || true
  q "delete from supplier_prices" >/dev/null 2>&1 || true
  q "$RESTORE_SQL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

ok()   { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }
expect() { local got; got=$(q "$2"); if [ "$got" = "$3" ]; then ok "$1"; else fail "$1" "oczekiwano '$3', jest '$got'"; fi; }
wait_for() { local i; for i in $(seq 1 $(( ${2:-30} * 2 ))); do [ "$(q "$1")" = "t" ] && return 0; sleep 0.5; done; return 1; }
run_report() { # <dir> <klucz> -> kod HTTP
  curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/stock-report" -H 'Content-Type: application/json' \
    -d "{\"dir\":\"$1\",\"digest_key\":\"$2\"}" || true
}

# --- cennik z błędami: poprawne wiersze wchodzą, błędne są raportowane --------------------------------
KEY1="t$RUN-mixed"
code=$(run_report suppliers-test "$KEY1")
[ "$code" = "200" ] && ok "mixed: HTTP 200" || fail "mixed" "HTTP $code"
wait_for "select exists(select 1 from slack_outbox where dedupe_key='stock-digest:$KEY1')" 40 \
  && ok "mixed: raport w kolejce Slack" || fail "mixed" "brak raportu"
expect "mixed: cena z przecinkiem zapisana" \
  "select price from supplier_prices where supplier_id=(select id from suppliers where name='Hurtownia Drewna Lasek') and material_id=(select id from materials where name='Dąb Halifax Naturalny 18 mm (Egger)')" "201.50"
expect "mixed: cena jest świeża" \
  "select updated_at > now() - interval '2 minutes' from supplier_prices where supplier_id=(select id from suppliers where name='Okucia24 Hurt') and material_id=(select id from materials where name='Konfirmat 7x50 (op. 100 szt)')" "t"
expect "mixed: plik bez końcowej nowej linii nie skleja się z następnym" \
  "select price from supplier_prices where supplier_id=(select id from suppliers where name='Okucia24 Hurt') and material_id=(select id from materials where name='Nóżka stalowa 70 cm')" "55.00"
expect "mixed: raport wymienia nieznaną hurtownię" "select text like '%Nieznane hurtownie: Nie ma takiej hurtowni%' from slack_outbox where dedupe_key='stock-digest:$KEY1'" "t"
expect "mixed: raport wymienia nieznany materiał" "select text like '%Nieznane materiały: Materiał, z przecinkiem%' from slack_outbox where dedupe_key='stock-digest:$KEY1'" "t"
expect "mixed: raport liczy błędne wiersze" "select text like '%Błędnych wierszy: 5%' from slack_outbox where dedupe_key='stock-digest:$KEY1'" "t"
expect "mixed: raport zawiera materiały do zamówienia" "select text like '%Do zamówienia%' and text like '%Uchwyt czarny 128 mm%' from slack_outbox where dedupe_key='stock-digest:$KEY1'" "t"

# --- ponowienie z tym samym kluczem niczego nie dubluje ------------------------------------------------
run_report suppliers-test "$KEY1" >/dev/null; sleep 4
expect "idempotent: jedna wiadomość na klucz" "select count(*) from slack_outbox where dedupe_key='stock-digest:$KEY1'" "1"

# --- właściwe cenniki z data/suppliers ----------------------------------------------------------------
q "update supplier_prices set updated_at = now() - interval '40 days'" >/dev/null
KEY2="t$RUN-prod"
code=$(run_report suppliers "$KEY2")
[ "$code" = "200" ] && ok "prod: HTTP 200" || fail "prod" "HTTP $code"
wait_for "select exists(select 1 from slack_outbox where dedupe_key='stock-digest:$KEY2')" 40 \
  && ok "prod: raport w kolejce Slack" || fail "prod" "brak raportu"
expect "prod: wszystkie 27 cen odświeżone" "select count(*) from supplier_prices where updated_at > now() - interval '2 minutes'" "27"
expect "prod: raport bez problemów importu" "select text not like '%⚠️%' from slack_outbox where dedupe_key='stock-digest:$KEY2'" "t"
expect "prod: najtańszy dąb to Lasek 195 zł" "select supplier_name || ' ' || price from best_price((select id from materials where name='Dąb Halifax Naturalny 18 mm (Egger)'))" "Hurtownia Drewna Lasek 195.00"

# --- bezpieczeństwo parametrów -------------------------------------------------------------------------
code=$(run_report "../etc" "t$RUN-bad")
[ "$code" = "403" ] && ok "params: katalog spoza data/ -> 403" || fail "params: ścieżka" "HTTP $code"
code=$(run_report "suppliers" "zły klucz")
[ "$code" = "403" ] && ok "params: zły klucz raportu -> 403" || fail "params: klucz" "HTTP $code"

if [ "$failures" -ne 0 ]; then echo "FAIL ($failures)"; exit 1; fi
echo "OK"
