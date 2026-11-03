#!/usr/bin/env bash
# Testy workflow 05-deliver: wysyłka z kolejek Slack i maili na lokalnej bazie, z odbiornikiem zamiast Slacka.
# Wymaga działającego Supabase i n8n w trybie testowym (ALLOW_LLM_MOCK=1 scripts/n8n.sh start).
# Dostarczane są wyłącznie wiadomości oznaczone jako testowe, więc prawdziwe oczekujące zostają nietknięte.
set -euo pipefail

cd "$(dirname "$0")/.."
DB_CONTAINER="supabase_db_meble-automatyzacja"
BASE="${N8N_URL:-http://localhost:5678}/webhook"
RUN="$(date +%s)"
TMP="$(mktemp -d)"
failures=0

q() { docker exec -i "$DB_CONTAINER" psql -U postgres -q -At -v ON_ERROR_STOP=1 -c "$1"; }
ok()   { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }
expect() { local got; got=$(q "$2"); if [ "$got" = "$3" ]; then ok "$1"; else fail "$1" "oczekiwano '$3', jest '$got'"; fi; }
wait_for() { local i; for i in $(seq 1 $(( ${2:-30} * 2 ))); do [ "$(q "$1")" = "t" ] && return 0; sleep 0.5; done; return 1; }
sink_count() { grep -c -F -- "$1" "$TMP/log" || true; }

node scripts/lib/http-sink.mjs "$TMP/port" "$TMP/log" & SINK_PID=$!
cleanup() {
  kill "$SINK_PID" 2>/dev/null || true
  q "delete from slack_outbox where dedupe_key like 'deliver-test-$RUN-%'" >/dev/null 2>&1 || true
  q "delete from orders where external_id = 'dv-$RUN'" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
for i in $(seq 1 40); do [ -s "$TMP/port" ] && break; sleep 0.25; done
PORT="$(cat "$TMP/port")"
deliver() { curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/deliver" -H 'Content-Type: application/json' -d "{\"slack_url\":\"$1\"}" || true; }
URL="http://127.0.0.1:$PORT/hook"

# prawdziwe oczekujące wiadomości (poza testowymi) nie mogą się zmienić
REAL_BEFORE="$(q "select (select count(*) from slack_outbox where sent_at is null and dedupe_key not like 'deliver-test-%') || '/' || (select count(*) from email_outbox where sent_at is null and subject not like '[deliver-test]%')")"

ORDER="$(q "select upsert_order(jsonb_build_object('external_id','dv-$RUN','source','form','customer_email','obcy@example.com','kind','catalog'))")"
A="deliver-test-$RUN-a"; B="deliver-test-$RUN-b"
q "select enqueue_slack('stock_digest', 'Wiadomość A $RUN', '$A')" >/dev/null
q "select enqueue_slack('stock_digest', 'Wiadomość B SINKFAIL $RUN', '$B')" >/dev/null
q "select enqueue_email('$ORDER', 'needs_info', 'obcy@example.com', '[deliver-test] Temat $RUN', 'Treść')" >/dev/null

# --- dostarczanie Slacka: potwierdzone idzie, odrzucone zostaje w kolejce ------------------------------
[ "$(deliver "$URL")" = "200" ] && ok "deliver: HTTP 200" || fail "deliver" "brak 200"
wait_for "select (select sent_at is not null from slack_outbox where dedupe_key='$A')" 40 \
  && ok "slack: potwierdzona wiadomość oznaczona jako wysłana" || fail "slack" "A nie została oznaczona"
expect "slack: odrzucona przez odbiornik zostaje w kolejce" "select sent_at is null from slack_outbox where dedupe_key='$B'" "t"
[ "$(sink_count "Wiadomość A $RUN")" = "1" ] && ok "slack: odbiornik dostał A raz" || fail "slack" "A dostarczona $(sink_count "Wiadomość A $RUN") razy"
grep -F "Wiadomość A $RUN" "$TMP/log" | grep -q '"method":"POST"' && ok "slack: żądanie POST z polem text" || fail "slack" "zły format żądania"
[ "$(sink_count "SINKFAIL")" -ge 1 ] && ok "slack: próba wysłania B została podjęta" || fail "slack" "B nie była próbowana"

# --- maile: domyślnie wyłączone, niczego nie wysyłamy ------------------------------------------------
expect "email: bez włączenia wysyłki mail zostaje w kolejce" "select sent_at is null from email_outbox where subject='[deliver-test] Temat $RUN'" "t"

# --- ponowny przebieg: A nie jest wysyłana drugi raz, B jest ponawiana -----------------------------------
sleep 1
deliver "$URL" >/dev/null; sleep 4
[ "$(sink_count "Wiadomość A $RUN")" = "1" ] && ok "retry: A nie jest wysyłana ponownie" || fail "retry" "A wysłana $(sink_count "Wiadomość A $RUN") razy"
[ "$(sink_count "SINKFAIL")" -ge 2 ] && ok "retry: B jest ponawiana" || fail "retry" "B próbowana $(sink_count "SINKFAIL") razy"

# --- bezpieczeństwo ------------------------------------------------------------------------------------
for bad in "http://evil.example/x" "https://hooks.slack.com/services/T/B/x" "http://localhost:$PORT/hook"; do
  [ "$(deliver "$bad")" = "403" ] && ok "params: $bad -> 403" || fail "params" "adres $bad nie został odrzucony"
done
REAL_AFTER="$(q "select (select count(*) from slack_outbox where sent_at is null and dedupe_key not like 'deliver-test-%') || '/' || (select count(*) from email_outbox where sent_at is null and subject not like '[deliver-test]%')")"
[ "$REAL_BEFORE" = "$REAL_AFTER" ] && ok "prawdziwe oczekujące wiadomości nietknięte ($REAL_AFTER)" || fail "izolacja" "przed $REAL_BEFORE, po $REAL_AFTER"

if [ "$failures" -ne 0 ]; then echo "FAIL ($failures)"; exit 1; fi
echo "OK"
