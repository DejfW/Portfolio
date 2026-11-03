#!/usr/bin/env bash
# Testy workflow 09-quote-followup (przypomnienia o wycenach, zamykanie starych wycen i ankieta powodów) na lokalnej bazie.
# Wymaga działającego Supabase i n8n w trybie testowym (ALLOW_LLM_MOCK=1 scripts/n8n.sh start). AI jest podmieniane atrapami.
# Testy zmieniają daty i statusy zamówień w statusie quoted oraz tworzą własne zamówienia i maile; po zakończeniu
# przywracają stan z kopii i usuwają własne dane. Uruchamiaj na lokalnej bazie bez równoległych operacji.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env.local ] && { set -a; . ./.env.local; set +a; }
DB_CONTAINER="supabase_db_meble-automatyzacja"
BASE="${N8N_URL:-http://localhost:5678}/webhook"
RUN="$(date +%s)"
BODYF="/tmp/followup-body-$RUN"
failures=0

q() { docker exec -i "$DB_CONTAINER" psql -U postgres -q -At -v ON_ERROR_STOP=1 -c "$1"; }

RESTORE_SQL="$(q "select coalesce(string_agg(format('update orders set status=%L, quoted_at=%L, followups_sent=%s where id=%L;', status, quoted_at, followups_sent, id), ' '), '') from orders where status = 'quoted'")"
START_TS="$(q "select now()")"

cleanup() {
  q "delete from email_outbox where created_at >= '$START_TS'" >/dev/null 2>&1 || true
  q "delete from orders where external_id like 'fu-$RUN-%'" >/dev/null 2>&1 || true
  [ -n "$RESTORE_SQL" ] && q "$RESTORE_SQL" >/dev/null 2>&1 || true
  rm -f "$BODYF"
}
trap cleanup EXIT

ok()   { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }
expect() { local got; got=$(q "$2"); if [ "$got" = "$3" ]; then ok "$1"; else fail "$1" "oczekiwano '$3', jest '$got'"; fi; }
body_has() { grep -qF -- "$1" "$BODYF"; }

# run_workflow [atrapa]: uruchamia workflow i czeka, aż przestanie zmieniać liczbę maili
run_workflow() {
  local args=(-s -o /dev/null -w '%{http_code}' -X POST "$BASE/followup-run")
  [ -n "${1:-}" ] && args+=(-H "X-LLM-Mock: $1")
  local code; code=$(curl "${args[@]}" || true)
  [ "$code" = "200" ] || fail "followup-run" "HTTP $code"
  local prev="" cur i
  for i in $(seq 1 30); do
    sleep 1; cur=$(q "select count(*) || '/' || (select count(*) from orders where status = 'lost') from email_outbox where created_at >= '$START_TS'")
    [ "$cur" = "$prev" ] && [ "$i" -gt 5 ] && break
    prev="$cur"
  done
}

# mk <nazwa> <status> <dni temu> [wysłane przypomnienia] -> id
mk() {
  q "insert into orders (external_id, source, customer_email, kind, status, quote, quoted_at, followups_sent)
     values ('fu-$RUN-$1', 'form', 'fu-$1@example.com', 'catalog', '$2',
             '{\"total\": 2400, \"lines\": [{\"label\": \"Komoda dębowa, 4 szuflady\", \"qty\": 1}]}'::jsonb,
             now() - interval '$3 days', ${4:-0}) returning id"
}

# --- przygotowanie: zamówienia z seeda nie mogą wpaść w okna testu --------------------------------------------------
q "update orders set quoted_at = now() where status = 'quoted'" >/dev/null
A=$(mk a quoted 4); B=$(mk b quoted 8 1); C=$(mk c quoted 16); D=$(mk d approved 5); E=$(mk e quoted 2)

# --- webhook testowy odrzuca niepoprawną atrapę ----------------------------------------------------------------------
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/followup-run" -H 'X-LLM-Mock: ../etc' || true)
[ "$code" = "403" ] && ok "followup-run: niepoprawna atrapa -> 403" || fail "followup-run atrapa" "HTTP $code"

# --- właściwy przebieg ---------------------------------------------------------------------------------------------------
run_workflow followup
expect "przypomnienie 1 po 3 dniach: mail i licznik" "select followups_sent || '/' || (select count(*) from email_outbox where order_id = '$A' and kind = 'followup_1') from orders where id = '$A'" "1/1"
expect "przypomnienie 2 po 7 dniach" "select followups_sent || '/' || (select count(*) from email_outbox where order_id = '$B' and kind = 'followup_2') from orders where id = '$B'" "2/1"
expect "mail zawiera tekst AI, kwotę wyceny i stopkę" \
  "select (body like '%Przypominamy o przygotowanej dla Państwa wycenie mebli z naszej pracowni%' and body like '%2400,00 zł%' and body like '%Komoda dębowa%')::text from email_outbox where order_id = '$A'" "true"
expect "wycena 16 dni: status lost i mail z ankietą" "select status || '/' || (select count(*) from email_outbox where order_id = '$C' and kind = 'lost_survey') from orders where id = '$C'" "lost/1"
expect "ankieta: link z tokenem zamówienia" "select (body like '%/webhook/lost-reason?token=' || o.public_token || '%')::text from email_outbox e join orders o on o.id = e.order_id where e.order_id = '$C'" "true"
expect "zatwierdzone zamówienie bez przypomnienia" "select count(*) from email_outbox where order_id = '$D'" "0"
expect "młoda wycena bez przypomnienia" "select followups_sent || '/' || (select count(*) from email_outbox where order_id = '$E') from orders where id = '$E'" "0/0"

run_workflow followup
expect "idempotencja: drugi przebieg nie dubluje maili" "select count(*) from email_outbox where order_id in ('$A', '$B', '$C')" "3"

# --- awaria i nadużycie AI: stały szablon ---------------------------------------------------------------------------
F=$(mk f quoted 4); G=$(mk g quoted 4); H=$(mk h quoted 4)
run_workflow garbage
expect "AI zwraca śmieci -> stały szablon" "select (body like '%Przypominamy o przygotowanej dla Państwa wycenie mebli z naszej pracowni%')::text from email_outbox where order_id = '$F' and kind = 'followup_1'" "true"
expect "przypomnienia dla F, G i H wysłane w jednym przebiegu" "select count(*) from email_outbox where order_id in ('$F', '$G', '$H') and kind = 'followup_1'" "3"
q "update orders set followups_sent = 0 where id = '$G'; delete from email_outbox where order_id = '$G'" >/dev/null
run_workflow followup-link
expect "AI wstawia link i e-mail -> stały szablon bez nich" "select (body not like '%oszust%' and body like '%Przypominamy o przygotowanej%')::text from email_outbox where order_id = '$G' and kind = 'followup_1'" "true"

# --- ankieta: strony publiczne chronione tokenem zamówienia ----------------------------------------------------------
TC=$(q "select public_token from orders where id = '$C'")
TE=$(q "select public_token from orders where id = '$E'")
http() { curl -s -o "$BODYF" -w '%{http_code}' "$@" || true; }
c=$(http "$BASE/lost-reason?token=$TC")
if [ "$c" = "200" ] && body_has '<form method="post" action="/webhook/lost-reason">' && body_has 'value="other_offer"'; then ok "ankieta GET: strona z przyciskami (bez logowania)"; else fail "ankieta GET" "HTTP $c"; fi
expect "ankieta GET niczego nie zapisuje" "select count(*) from lost_reasons where order_id = '$C'" "0"
c=$(http "$BASE/lost-reason?token=nie-uuid")
[ "$c" = "400" ] && ok "ankieta GET: zły token -> 400" || fail "ankieta zły token" "HTTP $c"
c=$(http "$BASE/lost-reason?token=$TE")
if [ "$c" = "200" ] && ! body_has '<form'; then ok "ankieta GET: wycena nadal aktywna -> bez formularza"; else fail "ankieta aktywna wycena" "HTTP $c"; fi
c=$(http -X POST "$BASE/lost-reason" -H 'Origin: null' -d "token=$TC&reason=zly")
[ "$c" = "400" ] && ok "ankieta POST: nieznany powód -> 400" || fail "ankieta zły powód" "HTTP $c"
c=$(http -X POST "$BASE/lost-reason" -H 'Origin: null' -d "token=$TC&reason=price")
if [ "$c" = "200" ] && body_has "Dziękujemy"; then ok "ankieta POST: powód zapisany"; else fail "ankieta POST" "HTTP $c"; fi
expect "ankieta: powód w bazie" "select reason from lost_reasons where order_id = '$C'" "price"
http -X POST "$BASE/lost-reason" -H 'Origin: null' -d "token=$TC&reason=time" >/dev/null
expect "ankieta: pierwsza odpowiedź wygrywa" "select reason from lost_reasons where order_id = '$C'" "price"
http -X POST "$BASE/lost-reason" -H 'Origin: null' -d "token=$TE&reason=price" >/dev/null
expect "ankieta: aktywna wycena nie przyjmuje powodu" "select count(*) from lost_reasons where order_id = '$E'" "0"

echo
if [ "$failures" -eq 0 ]; then echo "OK"; else echo "FAIL ($failures)"; exit 1; fi
