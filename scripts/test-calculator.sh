#!/usr/bin/env bash
# Testy workflowów 06-calculator i 07-weekly-report na lokalnej bazie.
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
cleanup() {
  q "delete from slack_outbox where dedupe_key like 'weekly-report:t$RUN%'" >/dev/null 2>&1 || true
  q "delete from orders where external_id like 'rp-$RUN-%' or external_id like 'calc-test-%'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

PRODUCT="$(q "select id from products p where exists (select 1 from product_materials pm where pm.product_id = p.id) order by name limit 1")"
MATERIAL="$(q "select id from materials m where m.custom_ok and exists (select 1 from supplier_prices sp where sp.material_id = m.id) order by name limit 1")"
BAD_MATERIAL="$(q "select id from materials m where not m.custom_ok and exists (select 1 from supplier_prices sp where sp.material_id = m.id) order by name limit 1")"
[ -n "$PRODUCT" ] && [ -n "$MATERIAL" ] || { echo "Brak seedu w lokalnej bazie (produkty, ceny)."; exit 2; }
post() { curl -s -w '\n%{http_code}' -X POST "$BASE/$1" -H 'Content-Type: application/json' "${@:3}" -d "$2"; }

# --- katalog i CORS ---------------------------------------------------------------------------------
cat="$(curl -s "$BASE/catalog")"
echo "$cat" | jq -e '(.products | length) > 0 and (.materials | length) > 0 and .limits.max_cm == 300' >/dev/null \
  && ok "catalog: produkty i materiały" || fail "catalog" "pusty albo zły kształt"
echo "$cat" | grep -Eqi 'price|stock|supplier' && fail "catalog" "wyciekają ceny, stany albo hurtownie" || ok "catalog: bez cen, stanów i hurtowni"

curl -s -D - -o /dev/null -H 'Origin: http://localhost:8080' "$BASE/catalog" | grep -qi '^access-control-allow-origin: \(\*\|http://localhost:8080\)' \
  && ok "catalog: CORS dla strony kalkulatora" || fail "catalog" "brak nagłówka CORS"
curl -s -D - -o /dev/null -X OPTIONS -H 'Origin: http://localhost:8080' -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: content-type' "$BASE/quote-preview" \
  | grep -qi '^access-control-allow-headers:.*content-type' && ok "preview: preflight OPTIONS" || fail "preview" "brak preflight"
curl -s -D - -o /dev/null -X OPTIONS -H 'Origin: http://localhost:8080' -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: content-type' "$BASE/order" \
  | grep -qi '^access-control-allow-headers:.*content-type' && ok "order: preflight OPTIONS" || fail "order" "brak preflight"

# --- wycena na żywo ---------------------------------------------------------------------------------
ORDERS_BEFORE="$(q "select count(*) from orders")"
out="$(post quote-preview "{\"items\":[{\"product_id\":\"$PRODUCT\",\"qty\":2}]}")"
code="${out##*$'\n'}"; body="${out%$'\n'*}"
[ "$code" = "200" ] && ok "preview: HTTP 200" || fail "preview" "HTTP $code: $body"
want="$(q "select quote_preview(jsonb_build_object('items', jsonb_build_array(jsonb_build_object('product_id','$PRODUCT','qty',2))))->>'total'")"
num_eq() { awk -v a="$1" -v b="$2" 'BEGIN { exit !((a - b) < 0.005 && (b - a) < 0.005) }'; }
num_eq "$(echo "$body" | jq -r '.total')" "$want" && ok "preview: kwota zgodna z bazą ($want)" || fail "preview" "kwota $(echo "$body" | jq -r '.total') vs $want"
echo "$body" | grep -Eq 'materials_cost|labor_cost|margin' && fail "preview" "wyciekają koszty wewnętrzne" || ok "preview: bez kosztów wewnętrznych"
num_eq "$(echo "$body" | jq '[.lines[].price] | add')" "$(echo "$body" | jq -r '.total')" && ok "preview: suma pozycji = suma wyceny" || fail "preview" "suma pozycji różni się od sumy"

out="$(post quote-preview "{\"items\":[{\"custom_spec\":{\"width_cm\":120,\"height_cm\":80,\"depth_cm\":40,\"material_id\":\"$MATERIAL\"},\"qty\":1}]}")"
[ "${out##*$'\n'}" = "200" ] && echo "${out%$'\n'*}" | jq -e '.total > 0' >/dev/null && ok "preview: mebel na wymiar" || fail "preview" "custom: $out"

for case in '{"items":[]}|NO_ITEMS' '{}|NO_ITEMS' "{\"items\":[{\"custom_spec\":{\"width_cm\":10,\"height_cm\":80,\"depth_cm\":40,\"material_id\":\"$MATERIAL\"}}]}|INVALID_SPEC" "{\"items\":[{\"product_id\":\"$PRODUCT\",\"qty\":0}]}|INVALID_QTY"; do
  out="$(post quote-preview "${case%%|*}")"
  [ "${out##*$'\n'}" = "422" ] && [ "$(echo "${out%$'\n'*}" | jq -r '.error')" = "${case##*|}" ] \
    && ok "preview: ${case##*|} -> 422" || fail "preview" "${case##*|}: $out"
done
out="$(post quote-preview "{\"items\":[{\"custom_spec\":{\"width_cm\":120,\"height_cm\":80,\"depth_cm\":40,\"material_id\":\"$BAD_MATERIAL\"}}]}")"
[ "${out##*$'\n'}" = "422" ] && echo "${out%$'\n'*}" | jq -e '.error == "MATERIAL_NOT_ALLOWED"' >/dev/null \
  && ok "preview: materiał niepłytowy nie nadaje się na wymiar" || fail "preview" "zawias jako materiał mebla: $out"
expect "preview: nic nie zapisuje" "select count(*) from orders" "$ORDERS_BEFORE"

# --- zamówienie z kalkulatora (bez parsera AI) -----------------------------------------------------------
EXT="calc-test-$RUN"
ITEMS="[{\"product_id\":\"$PRODUCT\",\"qty\":2},{\"custom_spec\":{\"width_cm\":120,\"height_cm\":80,\"depth_cm\":40,\"material_id\":\"$MATERIAL\"},\"qty\":1}]"
ORDER="{\"external_id\":\"$EXT\",\"customer_email\":\"klient-$RUN@example.com\",\"items\":$ITEMS,\"notes\":\"<script>x</script>\"}"
out="$(post calculator-order "$ORDER")"
[ "${out##*$'\n'}" = "200" ] && [ "$(echo "${out%$'\n'*}" | jq -r .status)" = "received" ] && ok "order: HTTP 200 received" || fail "order" "$out"
expect "order: zamówienie mieszane wycenione (quoted, kind custom)" "select status || '/' || kind from orders where external_id='$EXT'" "quoted/custom"
expect "order: obie pozycje zapisane" "select count(*) from order_items oi join orders o on o.id=oi.order_id where o.external_id='$EXT'" "2"
wait_for "select exists (select 1 from email_outbox eo join orders o on o.id=eo.order_id where o.external_id='$EXT' and eo.kind='customer_quote')" 30 \
  && ok "order: mail z wyceną dla klienta w kolejce" || fail "order" "brak maila customer_quote"
expect "order: mail do właściciela w kolejce" "select count(*) from email_outbox eo join orders o on o.id=eo.order_id where o.external_id='$EXT' and eo.kind='owner_alert'" "1"
out="$(post calculator-order "$ORDER")"
[ "$(echo "${out%$'\n'*}" | jq -r .status)" = "duplicate" ] && ok "order: ponowienie to duplikat" || fail "order" "ponowienie: $out"
sleep 2
expect "order: ponowienie niczego nie dubluje" "select (select count(*) from orders where external_id='$EXT') || '/' || (select count(*) from email_outbox eo join orders o on o.id=eo.order_id where o.external_id='$EXT')" "1/2"
for case in 'INVALID_EMAIL|{"external_id":"calc-test-bad","customer_email":"zly","items":[{"product_id":"'$PRODUCT'","qty":1}]}' 'NO_ITEMS|{"external_id":"calc-test-bad","customer_email":"a@b.pl","items":[]}' 'INVALID_EXTERNAL_ID|{"external_id":"zły id","customer_email":"a@b.pl","items":[{"product_id":"'$PRODUCT'","qty":1}]}'; do
  out="$(post calculator-order "${case#*|}")"
  [ "${out##*$'\n'}" = "422" ] && [ "$(echo "${out%$'\n'*}" | jq -r .error)" = "${case%%|*}" ] && ok "order: ${case%%|*} -> 422" || fail "order" "${case%%|*}: $out"
done
expect "order: błędne żądania niczego nie zapisują" "select count(*) from orders where external_id='calc-test-bad'" "0"

# --- raport tygodniowy ------------------------------------------------------------------------------
mk() { q "select upsert_order(jsonb_build_object('external_id','rp-$RUN-$1','source','form','customer_email','k@example.com','kind','catalog','items',jsonb_build_array(jsonb_build_object('product_id','$PRODUCT','qty',$2))))" >/dev/null
       q "select estimate_quote(id) from orders where external_id='rp-$RUN-$1'" >/dev/null
       q "update orders set status='approved' where external_id='rp-$RUN-$1'"; }
mk a 4 >/dev/null
KEY="t$RUN"
report() { curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/weekly-report" -H 'Content-Type: application/json' -H "X-LLM-Mock: $2" -d "{\"report_key\":\"$1\"}" || true; }
[ "$(report "$KEY" report-ok)" = "200" ] && ok "report: HTTP 200" || fail "report" "brak 200"
wait_for "select exists (select 1 from slack_outbox where dedupe_key='weekly-report:$KEY')" 60 && ok "report: wiadomość w kolejce Slack" || fail "report" "brak wiadomości"
expect "report: rodzaj weekly_report" "select kind from slack_outbox where dedupe_key='weekly-report:$KEY'" "weekly_report"
expect "report: tabele i podsumowanie AI" "select (text like '%Ostatnie 7 dni%' and text like '%Ostatnie 30 dni%' and text like '%Podsumowanie:%Rekomendacja%') from slack_outbox where dedupe_key='weekly-report:$KEY'" "t"
expect "report: najlepszy produkt z zamówienia testowego (4 szt.)" "select text like '%4 szt.%' from slack_outbox where dedupe_key='weekly-report:$KEY'" "t"
report "$KEY" report-ok >/dev/null; sleep 5
expect "report: ten sam klucz nie dubluje" "select count(*) from slack_outbox where dedupe_key='weekly-report:$KEY'" "1"

report "${KEY}l" report-long >/dev/null
wait_for "select exists (select 1 from slack_outbox where dedupe_key='weekly-report:${KEY}l')" 60 || true
expect "report: długie podsumowanie jest skracane i escapowane" "select (length(text) <= 3000 and text like '%&lt;znacznikami&gt; &amp;%' and text like '%&lt;!channel&gt;%' and text not like '%<!channel>%') from slack_outbox where dedupe_key='weekly-report:${KEY}l'" "t"

report "${KEY}f" nie-ma-takiego >/dev/null
wait_for "select exists (select 1 from slack_outbox where dedupe_key='weekly-report:${KEY}f')" 60 || true
expect "report: awaria AI nie blokuje raportu" "select text like '%Podsumowanie AI niedostępne%' and text like '%Ostatnie 7 dni%' from slack_outbox where dedupe_key='weekly-report:${KEY}f'" "t"

c=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/weekly-report" -H 'Content-Type: application/json' -H 'X-LLM-Mock: ../../etc' -d '{}' || true)
[ "$c" = "403" ] && ok "report: zła nazwa atrapy -> 403" || fail "report" "nazwa atrapy: HTTP $c"
c=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/weekly-report" -H 'Content-Type: application/json' -d '{"report_key":"a b!"}' || true)
[ "$c" = "403" ] && ok "report: zły klucz -> 403" || fail "report" "zły klucz: HTTP $c"

if [ "$failures" -ne 0 ]; then echo "FAIL ($failures)"; exit 1; fi
echo "OK"
