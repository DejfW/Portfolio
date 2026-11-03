#!/usr/bin/env bash
# Testy workflow 01-order-intake: wysyłają zamówienia na webhook n8n i sprawdzają wynik w bazie.
# Wymaga działającego Supabase (supabase start) i n8n (scripts/start-n8n.sh) z ALLOW_LLM_MOCK=1.
# Odpowiedzi AI są podmieniane na n8n/fixtures/llm-*.json nagłówkiem X-LLM-Mock, więc testy
# nie zużywają limitu modelu. Jedyny wyjątek to smoke_real_agy (pomiń: SKIP_REAL_AGY=1).
set -euo pipefail

cd "$(dirname "$0")/.."
DB_CONTAINER="supabase_db_meble-automatyzacja"
WEBHOOK="${N8N_URL:-http://localhost:5678}/webhook/order"
RUN="$(date +%s)"
PWNED="/tmp/intake-pwned-$RUN"
BODYF="/tmp/intake-body-$RUN"
failures=0

q() { docker exec -i "$DB_CONTAINER" psql -U postgres -q -At -v ON_ERROR_STOP=1 -c "$1"; }

cleanup() { q "delete from orders where external_id like 'it-$RUN-%'" >/dev/null 2>&1 || true; rm -f "$PWNED" "$BODYF"; }
trap cleanup EXIT

# post <external_id> <email> <wiadomość> [mock] -> wypisuje kod HTTP, ciało odpowiedzi w $BODYF
# (plik, bo funkcja jest wołana w podpowłoce i zmienne nie wracają do głównej powłoki)
post() {
  : >"$BODYF"
  local payload
  payload=$(jq -n --arg id "$1" --arg e "$2" --arg m "$3" \
    '{external_id: $id, customer_email: $e, message: $m, source: "email"}')
  local args=(-s -o "$BODYF" -w '%{http_code}' -X POST "$WEBHOOK" -H 'Content-Type: application/json' -d "$payload")
  [ -n "${4:-}" ] && args+=(-H "X-LLM-Mock: $4")
  [ -n "${INTAKE_TOKEN:-}" ] && args+=(-H "X-Intake-Token: $INTAKE_TOKEN")
  curl "${args[@]}" || true
}

# wait_for <sql zwracające t/f> [sekundy] -> czeka aż warunek będzie prawdziwy
wait_for() {
  local i
  for i in $(seq 1 $(( ${2:-30} * 2 ))); do
    [ "$(q "$1")" = "t" ] && return 0
    sleep 0.5
  done
  return 1
}

ok()   { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }

# expect <nazwa> <sql> <oczekiwana wartość>
expect() {
  local got
  got=$(q "$2")
  if [ "$got" = "$3" ]; then ok "$1"; else fail "$1" "oczekiwano '$3', jest '$got'"; fi
}

# Test wymaga n8n uruchomionego w trybie testowym (nagłówek X-LLM-Mock i webhook /sweep).
probe=$(post "it-$RUN-probe" probe@example.com "probe" catalog)
if [ "$probe" != "200" ]; then
  echo "n8n nie działa w trybie testowym (HTTP $probe: $(cat "$BODYF"))."
  echo "Uruchom: ALLOW_LLM_MOCK=1 scripts/n8n.sh start (z INTAKE_TOKEN, jeśli test ma go używać)."
  exit 2
fi

# sweep <stuck_after_s> <notify_after_s> -> uruchamia sweeper (tylko tryb testowy), wypisuje kod HTTP
sweep() {
  curl -s -o /dev/null -w '%{http_code}' -X POST "${N8N_URL:-http://localhost:5678}/webhook/sweep" \
    -H 'Content-Type: application/json' -d "{\"stuck_after_seconds\":$1,\"notify_after_seconds\":$2}"
}

# scenario <nazwa> <id> <email> <wiadomość> <mock> <status końcowy> <maile: customer_quote needs_info owner_alert>
scenario() {
  local name=$1 id="it-$RUN-$2" email=$3 msg=$4 mock=$5 status=$6 cq=$7 ni=$8 oa=$9
  local code
  code=$(post "$id" "$email" "$msg" "$mock")
  if [ "$code" != "200" ]; then fail "$name" "HTTP $code: $(cat "$BODYF")"; return; fi
  if ! wait_for "select exists(select 1 from orders o where o.external_id='$id' and o.status='$status'
        and (select count(*) from email_outbox e where e.order_id=o.id) = $((cq + ni + oa)))" 40; then
    fail "$name" "brak oczekiwanego stanu: $(q "select status from orders where external_id='$id'") / maile: $(q "select string_agg(kind,',') from email_outbox where order_id=(select id from orders where external_id='$id')")"
    return
  fi
  local o="(select id from orders where external_id='$id')"
  expect "$name: customer_quote" "select count(*) from email_outbox where order_id=$o and kind='customer_quote'" "$cq"
  expect "$name: needs_info"     "select count(*) from email_outbox where order_id=$o and kind='needs_info'" "$ni"
  expect "$name: owner_alert"    "select count(*) from email_outbox where order_id=$o and kind='owner_alert'" "$oa"
  if [ "$cq" = "1" ]; then
    expect "$name: wycena > 0" "select (quote->>'total')::numeric > 0 from orders where id=$o" "t"
    expect "$name: mail do klienta" "select to_email from email_outbox where order_id=$o and kind='customer_quote'" "$email"
  fi
}

CATALOG_MSG=$(cat n8n/fixtures/email-catalog.txt)
CUSTOM_MSG=$(cat n8n/fixtures/email-custom.txt)
INCOMPLETE_MSG=$(cat n8n/fixtures/email-incomplete.txt)

scenario parse_catalog_email    cat   anna@example.com   "$CATALOG_MSG"    catalog    quoted       1 0 1
scenario parse_custom_email     cus   jan@example.com    "$CUSTOM_MSG"     custom     quoted       1 0 1
scenario parse_fenced_json      fen   ola@example.com    "$CATALOG_MSG"    fenced     quoted       1 0 1
scenario parse_incomplete_email inc   ewa@example.com    "$INCOMPLETE_MSG" incomplete needs_info   0 1 0
scenario parse_unknown_product  unk   tom@example.com    "$CATALOG_MSG"    unknown    needs_review 0 0 1
scenario parse_invalid_spec     bad   kasia@example.com  "$CUSTOM_MSG"     badspec    needs_review 0 0 1
scenario parse_garbage_llm_output gar piotr@example.com  "$CATALOG_MSG"    garbage    needs_review 0 0 1

# Wycena z AI trafia do klienta tylko w poprawnym przypadku, a ostrzeżenie dla właściciela zawiera link zatwierdzenia.
expect "owner_alert zawiera link zatwierdzenia" \
  "select body like '%/webhook/approve?order_id=%' from email_outbox where order_id=(select id from orders where external_id='it-$RUN-cat') and kind='owner_alert'" "t"
expect "mail do klienta zawiera kwotę i zastrzeżenie o wstępnej wycenie" \
  "select body like '%zł%' and body ilike '%wstępn%' from email_outbox where order_id=(select id from orders where external_id='it-$RUN-cat') and kind='customer_quote'" "t"

# idempotent_resend: ten sam external_id nie tworzy drugiego zamówienia ani drugiego maila
code=$(post "it-$RUN-cat" anna@example.com "$CATALOG_MSG" catalog)
sleep 3
[ "$code" = "200" ] && ok "resend: HTTP 200" || fail "resend" "HTTP $code"
grep -q '"duplicate"' "$BODYF" && ok "resend: odpowiedź duplicate" || fail "resend: odpowiedź" "$(cat "$BODYF")"
expect "resend: jedno zamówienie" "select count(*) from orders where external_id='it-$RUN-cat'" "1"
expect "resend: jeden mail do klienta" \
  "select count(*) from email_outbox where order_id=(select id from orders where external_id='it-$RUN-cat') and kind='customer_quote'" "1"

# invalid_input: brak maila klienta albo pusta wiadomość to 400 i brak zamówienia
code=$(post "it-$RUN-nomail" "" "$CATALOG_MSG" catalog)
[ "$code" = "400" ] && ok "invalid_input: brak maila -> 400" || fail "invalid_input: brak maila" "HTTP $code"
code=$(post "it-$RUN-nomsg" kto@example.com "" catalog)
[ "$code" = "400" ] && ok "invalid_input: pusta wiadomość -> 400" || fail "invalid_input: pusta wiadomość" "HTTP $code"
expect "invalid_input: nic nie zapisano" "select count(*) from orders where external_id in ('it-$RUN-nomail','it-$RUN-nomsg')" "0"

# invalid_mock_name: nazwa fixture'a spoza ^[a-z0-9-]+$ jest odrzucana, nigdy nie trafia do ścieżki pliku
code=$(post "it-$RUN-mock" kto@example.com "$CATALOG_MSG" "../../etc/passwd")
[ "$code" = "400" ] && ok "invalid_mock_name -> 400" || fail "invalid_mock_name" "HTTP $code"

# shell_injection_safe: wiadomość z poleceniem powłoki nie może niczego uruchomić
INJECT="\"; touch $PWNED; echo \" \$(touch $PWNED) \`touch $PWNED\` '; touch $PWNED; '"
scenario shell_injection_safe inj hack@example.com "$INJECT" catalog quoted 1 0 1
[ ! -e "$PWNED" ] && ok "shell_injection_safe: plik nie powstał" || fail "shell_injection_safe" "powstał $PWNED"


# durable_ack: po odpowiedzi 200 zamówienie jest już trwale w bazie (zapis przed odpowiedzią)
code=$(post "it-$RUN-ack" ack@example.com "$CATALOG_MSG" catalog)
[ "$code" = "200" ] && ok "durable_ack: HTTP 200" || fail "durable_ack" "HTTP $code"
expect "durable_ack: zamówienie jest w bazie zaraz po 200" \
  "select exists(select 1 from orders where external_id='it-$RUN-ack')" "t"

# missing_external_id: brak stabilnego klucza idempotencji to 400
code=$(post "" noid@example.com "$CATALOG_MSG" catalog)
[ "$code" = "400" ] && ok "missing_external_id -> 400" || fail "missing_external_id" "HTTP $code"

# parallel_same_external_id: dwa równoległe żądania, jedno wywołuje AI, drugie dostaje duplicate
pid="it-$RUN-par"
ppayload=$(jq -n --arg id "$pid" --arg m "$CATALOG_MSG" '{external_id:$id,customer_email:"par@example.com",message:$m,source:"form"}')
pargs=(-s -X POST "$WEBHOOK" -H 'Content-Type: application/json' -H 'X-LLM-Mock: catalog')
[ -n "${INTAKE_TOKEN:-}" ] && pargs+=(-H "X-Intake-Token: $INTAKE_TOKEN")
curl "${pargs[@]}" -d "$ppayload" -o /tmp/intake-par1-$RUN & curl "${pargs[@]}" -d "$ppayload" -o /tmp/intake-par2-$RUN & wait
statuses=$(jq -r .status /tmp/intake-par1-$RUN /tmp/intake-par2-$RUN | sort | paste -sd' ' -)
rm -f /tmp/intake-par1-$RUN /tmp/intake-par2-$RUN
[ "$statuses" = "duplicate processing" ] && ok "parallel: jedno processing i jedno duplicate" || fail "parallel: odpowiedzi" "$statuses"
wait_for "select exists(select 1 from orders o where o.external_id='$pid' and o.status='quoted' and (select count(*) from email_outbox e where e.order_id=o.id)=2)" 40 \
  && ok "parallel: jedno zamówienie z kompletem maili" || fail "parallel" "brak kompletu maili"
sleep 2
expect "parallel: nadal jedno zamówienie" "select count(*) from orders where external_id='$pid'" "1"
expect "parallel: dokładnie dwa maile" "select count(*) from email_outbox where order_id=(select id from orders where external_id='$pid')" "2"

# stuck_recovery: zgłoszenie zapisane, ale nigdy domknięte (awaria po odpowiedzi 200), trafia do sprawdzenia
sid="it-$RUN-stuck"
q "select intake_receive(jsonb_build_object('external_id','$sid','source','form','customer_email','stuck@example.com','raw_text','Zgłoszenie które utknęło'))" >/dev/null
q "update orders set created_at = now() - interval '20 minutes' where external_id='$sid'"
[ "$(sweep 600 0)" = "200" ] && ok "sweep: HTTP 200" || fail "sweep" "nie odpowiedział 200"
wait_for "select exists(select 1 from orders o where o.external_id='$sid' and o.status='needs_review' and exists(select 1 from email_outbox e where e.order_id=o.id and e.kind='owner_alert' and e.body like '%STUCK_INTAKE%'))" 30 \
  && ok "stuck_recovery: needs_review i alert dla właściciela" || fail "stuck_recovery" "status: $(q "select status from orders where external_id='$sid'")"

# repair_missing_emails: zamówienie domknięte w bazie, ale bez maili (awaria po zapisie), dostaje komplet
rid="it-$RUN-repair"
q "select intake_receive(jsonb_build_object('external_id','$rid','source','email','customer_email','repair@example.com','raw_text','Szafka'))" >/dev/null
q "select intake_complete((select id from orders where external_id='$rid'), jsonb_build_object('kind','catalog','route','ok','parsed',jsonb_build_object('llm','x'),'items',jsonb_build_array(jsonb_build_object('product_id',(select id from products where name='Szafka nocna MDF biała'),'qty',1))))" >/dev/null
q "update orders set created_at = now() - interval '10 minutes' where external_id='$rid'"
expect "repair: przed sweeperem brak maili" "select count(*) from email_outbox where order_id=(select id from orders where external_id='$rid')" "0"
sweep 600 0 >/dev/null
wait_for "select (select count(*) from email_outbox where order_id=(select id from orders where external_id='$rid'))=2" 30 \
  && ok "repair_missing_emails: komplet maili po sweeperze" || fail "repair_missing_emails" "maile: $(q "select count(*) from email_outbox where order_id=(select id from orders where external_id='$rid')")"
sweep 600 0 >/dev/null; sleep 3
expect "repair: ponowny sweep niczego nie dubluje" "select count(*) from email_outbox where order_id=(select id from orders where external_id='$rid')" "2"
expect "sweep pomija dane demo" "select count(*) from email_outbox e join orders o on o.id=e.order_id where o.external_id like 'seed-%'" "0"

# auth: gdy n8n działa z INTAKE_TOKEN, żądanie bez tokenu lub z błędnym jest odrzucane (INTAKE_TOKEN=... scripts/test-intake.sh)
if [ -n "${INTAKE_TOKEN:-}" ]; then
  apayload=$(jq -n --arg id "it-$RUN-auth" --arg m "$CATALOG_MSG" '{external_id:$id,customer_email:"auth@example.com",message:$m}')
  c1=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$WEBHOOK" -H 'Content-Type: application/json' -H 'X-LLM-Mock: catalog' -d "$apayload")
  c2=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$WEBHOOK" -H 'Content-Type: application/json' -H 'X-LLM-Mock: catalog' -H 'X-Intake-Token: zly' -d "$apayload")
  [ "$c1" = "401" ] && [ "$c2" = "401" ] && ok "auth: brak lub zły token -> 401" || fail "auth" "bez tokenu $c1, zły token $c2"
  expect "auth: nic nie zapisano" "select count(*) from orders where external_id='it-$RUN-auth'" "0"
else
  echo "SKIP auth (ustaw INTAKE_TOKEN, gdy n8n działa z tym samym tokenem)"
fi

# smoke_real_agy: jedno zapytanie do prawdziwego modelu; sprawdzamy tylko, że przepływ się kończy
if [ "${SKIP_REAL_AGY:-0}" = "1" ]; then
  echo "SKIP smoke_real_agy (SKIP_REAL_AGY=1)"
else
  code=$(post "it-$RUN-real" real@example.com "$CATALOG_MSG" "")
  if [ "$code" != "200" ]; then
    fail "smoke_real_agy" "HTTP $code: $(cat "$BODYF")"
  elif wait_for "select exists(select 1 from orders where external_id='it-$RUN-real' and status in ('quoted','needs_info','needs_review'))" 150; then
    ok "smoke_real_agy (status: $(q "select status from orders where external_id='it-$RUN-real'"))"
  else
    fail "smoke_real_agy" "zamówienie nie dotarło do stanu końcowego w 150 s"
  fi
fi

rm -f "$BODYF"
if [ "$failures" -ne 0 ]; then echo "FAIL ($failures)"; exit 1; fi
echo "OK"
