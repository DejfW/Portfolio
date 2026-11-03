#!/usr/bin/env bash
# Testy workflow 05-deliver: wysyłka z kolejek Slack i maili na lokalnej bazie, z odbiornikiem zamiast Slacka.
# Wymaga działającego Supabase i n8n w trybie testowym (ALLOW_LLM_MOCK=1 scripts/n8n.sh start).
# Dostarczane są wyłącznie wiadomości oznaczone jako testowe, więc prawdziwe oczekujące zostają nietknięte.
set -euo pipefail

cd "$(dirname "$0")/.."
DB_CONTAINER="supabase_db_meble-automatyzacja"
BASE="${N8N_URL:-http://localhost:5678}/webhook"
PORT="${TEST_SINK_PORT:-18765}"
RUN="$(date +%s)"
TMP="$(mktemp -d)"
failures=0

q() { docker exec -i "$DB_CONTAINER" psql -U postgres -q -At -v ON_ERROR_STOP=1 -c "$1"; }
ok()   { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }
expect() { local got; got=$(q "$2"); if [ "$got" = "$3" ]; then ok "$1"; else fail "$1" "oczekiwano '$3', jest '$got'"; fi; }
wait_for() { local i; for i in $(seq 1 $(( ${2:-30} * 2 ))); do [ "$(q "$1")" = "t" ] && return 0; sleep 0.5; done; return 1; }
sink_count() { grep -c -F -- "$1" "$TMP/log" || true; }

node scripts/lib/http-sink.mjs "$TMP/port" "$TMP/log" "$PORT" & SINK_PID=$!
cleanup() {
  kill "$SINK_PID" 2>/dev/null || true
  q "delete from slack_outbox where dedupe_key like 'deliver-test-$RUN-%'" >/dev/null 2>&1 || true
  q "delete from orders where external_id = 'dv-$RUN'" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
for i in $(seq 1 40); do [ -s "$TMP/port" ] && break; sleep 0.25; done
[ -s "$TMP/port" ] || { echo "Nie udało się uruchomić odbiornika na porcie $PORT (zajęty?). Ustaw TEST_SINK_PORT, tak samo jak dla n8n."; exit 2; }
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

# --- niepowodzenie: zapis błędu i odstęp przed ponowieniem; po jego upływie wiadomość jest ponawiana ---------
expect "failure: licznik prób i zapisany powód" "select attempts || '/' || (last_error is not null) from slack_outbox where dedupe_key='$B'" "1/true"
expect "failure: kolejna próba dopiero za kilka minut" "select next_attempt_at > now() + interval '1 minute' from slack_outbox where dedupe_key='$B'" "t"
expect "failure: zapisany błąd nie zawiera adresu odbiornika" "select last_error not like '%127.0.0.1%' from slack_outbox where dedupe_key='$B'" "t"
sleep 1
deliver "$URL" >/dev/null; sleep 3
[ "$(sink_count "SINKFAIL")" = "1" ] && ok "backoff: B nie jest ponawiana przed upływem odstępu" || fail "backoff" "B próbowana $(sink_count "SINKFAIL") razy"
q "update slack_outbox set next_attempt_at = now() - interval '1 second' where dedupe_key='$B'" >/dev/null
deliver "$URL" >/dev/null; sleep 4
[ "$(sink_count "SINKFAIL")" = "2" ] && ok "retry: po upływie odstępu B jest ponawiana" || fail "retry" "B próbowana $(sink_count "SINKFAIL") razy"
[ "$(sink_count "Wiadomość A $RUN")" = "1" ] && ok "retry: A nie jest wysyłana ponownie" || fail "retry" "A wysłana $(sink_count "Wiadomość A $RUN") razy"
expect "retry: licznik prób rośnie" "select attempts from slack_outbox where dedupe_key='$B'" "2"

# --- bezpieczeństwo ------------------------------------------------------------------------------------
for bad in "http://evil.example/x" "https://hooks.slack.com/services/T/B/x" "http://localhost:$PORT/hook" "http://127.0.0.1:$((PORT + 1))/hook" "http://127.0.0.1:$PORT/inna" "http://127.0.0.1:$PORT/hook/" ""; do
  [ "$(deliver "$bad")" = "403" ] && ok "params: '$bad' -> 403" || fail "params" "adres '$bad' nie został odrzucony"
done
# pusty webhook w trybie testowym nie może uruchomić prawdziwej wysyłki (zarzut z recenzji)
c=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/deliver" -H 'Content-Type: application/json' -d '{}' || true)
[ "$c" = "403" ] && ok "params: pusty webhook -> 403" || fail "params" "pusty webhook: HTTP $c"
REAL_AFTER="$(q "select (select count(*) from slack_outbox where sent_at is null and dedupe_key not like 'deliver-test-%') || '/' || (select count(*) from email_outbox where sent_at is null and subject not like '[deliver-test]%')")"
[ "$REAL_BEFORE" = "$REAL_AFTER" ] && ok "prawdziwe oczekujące wiadomości nietknięte ($REAL_AFTER)" || fail "izolacja" "przed $REAL_BEFORE, po $REAL_AFTER"

if [ "$failures" -ne 0 ]; then echo "FAIL ($failures)"; exit 1; fi
echo "OK"
