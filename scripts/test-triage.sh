#!/usr/bin/env bash
# Testy workflow 11-inbox-triage (klasyfikacja poczty, kierowanie do intake, pytania i reklamacje dla właściciela, spam)
# na lokalnej bazie. Wymaga działającego Supabase z seedem i n8n w trybie testowym (ALLOW_LLM_MOCK=1 scripts/n8n.sh start).
# AI klasyfikatora i parsera zamówień jest podmieniane atrapami (nagłówki X-LLM-Mock i X-Intake-Mock).
set -euo pipefail

cd "$(dirname "$0")/.."
DB_CONTAINER="supabase_db_meble-automatyzacja"
BASE="${N8N_URL:-http://localhost:5678}/webhook"
FIX="n8n/fixtures"
RUN="$(date +%s)"
failures=0

q() { docker exec -i "$DB_CONTAINER" psql -U postgres -q -At -v ON_ERROR_STOP=1 -c "$1"; }
ok()   { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }
expect() { local got; got=$(q "$2"); if [ "$got" = "$3" ]; then ok "$1"; else fail "$1" "oczekiwano '$3', jest '$got'"; fi; }
wait_for() { local i; for i in $(seq 1 $(( ${2:-40} * 2 ))); do [ "$(q "$1")" = "t" ] && return 0; sleep 0.5; done; return 1; }
cleanup() {
  q "delete from slack_outbox where dedupe_key in (select 'inbox:' || id from inbox_messages where external_id like 'tr-$RUN-%')" >/dev/null 2>&1 || true
  q "delete from orders where external_id like 'tr-$RUN-%'" >/dev/null 2>&1 || true
  q "delete from inbox_messages where external_id like 'tr-$RUN-%'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# triage <sufiks> <plik z treścią | tekst> <atrapa klasyfikatora> [atrapa intake] -> treść\nkod
triage() {
  local msg; if [ -f "$2" ]; then msg="$(jq -Rs . < "$2")"; else msg="$(jq -Rn --arg m "$2" '$m')"; fi
  local args=(-s -w '\n%{http_code}' -X POST "$BASE/triage" -H 'Content-Type: application/json' -H "X-LLM-Mock: $3")
  [ -n "${4:-}" ] && args+=(-H "X-Intake-Mock: $4")
  curl "${args[@]}" -d "{\"external_id\":\"tr-$RUN-$1\",\"from_email\":\"klient-$1@example.com\",\"subject\":\"Temat $1\",\"message\":$msg}"
}
code_of() { echo "${1##*$'\n'}"; }
body_of() { echo "${1%$'\n'*}"; }
ext() { echo "tr-$RUN-$1"; }
classified() { echo "select (route is not null) from inbox_messages where external_id = '$(ext "$1")'"; }
orders_for() { q "select count(*) from orders where external_id = '$(ext "$1")'"; }

# --- zamówienie: do intake, powstaje zamówienie z tym samym external_id ------------------------------------------
out="$(triage order "Chcę zamówić komodę dębową, proszę o wycenę." triage-order catalog)"
if [ "$(code_of "$out")" = "200" ] && [ "$(body_of "$out" | jq -r '.status')" = "processing" ]; then ok "order: przyjęte (processing)"; else fail "order" "$out"; fi
wait_for "select (forwarded_at is not null) from inbox_messages where external_id = '$(ext order)'" 60 && ok "order: przekazane do intake" || fail "order" "nie przekazane"
expect "order: trasa intake, kategoria order" "select route || '/' || category from inbox_messages where external_id = '$(ext order)'" "intake/order"
wait_for "select count(*) = 1 from orders where external_id = '$(ext order)'" 40 && ok "order: powstało zamówienie (źródło email)" || fail "order" "brak zamówienia"
expect "order: źródło i klient" "select source || '/' || customer_email from orders where external_id = '$(ext order)'" "email/klient-order@example.com"

# --- pytanie: szkic dla właściciela, bez zamówienia i bez wysyłki --------------------------------------------------------
triage question "$FIX/email-question.txt" triage-question catalog >/dev/null
wait_for "$(classified question)" 40 && ok "question: sklasyfikowane" || fail "question" "brak klasyfikacji"
expect "question: trasa i szkic zapisany" "select route || '/' || (reply_draft like '%3-5 tygodni%')::text from inbox_messages where external_id = '$(ext question)'" "question/true"
expect "question: Slack dla właściciela ze szkicem" "select count(*) from slack_outbox s join inbox_messages i on s.dedupe_key = 'inbox:' || i.id where i.external_id = '$(ext question)' and s.kind = 'inbox_question' and s.text like '%nic nie zostało wysłane%'" "1"
expect "question: bez zamówienia, bez przekazania i bez maila do klienta" \
  "select (select count(*) from orders where external_id = '$(ext question)') || '/' || (select (forwarded_at is null)::text from inbox_messages where external_id = '$(ext question)') || '/' || (select count(*) from email_outbox where to_email = 'klient-question@example.com')" "0/true/0"

# --- reklamacja ---------------------------------------------------------------------------------------------------------------
triage complaint "$FIX/email-complaint.txt" triage-complaint catalog >/dev/null
wait_for "$(classified complaint)" 40 || true
expect "complaint: alert dla właściciela, bez zamówienia" "select (select count(*) from slack_outbox s join inbox_messages i on s.dedupe_key = 'inbox:' || i.id where i.external_id = '$(ext complaint)' and s.kind = 'inbox_complaint') || '/' || (select count(*) from orders where external_id = '$(ext complaint)')" "1/0"

# --- spam: tylko oznaczony, nic nie usunięte, żadnych powiadomień ------------------------------------------------------
triage spam "$FIX/email-spam.txt" triage-spam catalog >/dev/null
wait_for "$(classified spam)" 40 || true
expect "spam: oznaczony, wiadomość zostaje, bez powiadomień i zamówienia" \
  "select route || '/' || (select count(*) from slack_outbox s where s.dedupe_key = 'inbox:' || i.id) || '/' || (select count(*) from orders where external_id = '$(ext spam)') from inbox_messages i where external_id = '$(ext spam)'" "spam/0/0"

# --- niepewność i awaria AI nigdy nie kończą w spamie ----------------------------------------------------------------
triage uncertain "$FIX/email-spam.txt" triage-uncertain catalog >/dev/null
wait_for "select count(*) = 1 from orders where external_id = '$(ext uncertain)'" 60 && ok "uncertain: spam z pewnością 0,5 trafił do intake (powstało zamówienie)" || fail "uncertain" "brak zamówienia"
expect "uncertain: trasa intake" "select route from inbox_messages where external_id = '$(ext uncertain)'" "intake"
triage garbage "Proszę o wycenę stołu" garbage catalog >/dev/null
wait_for "select count(*) = 1 from orders where external_id = '$(ext garbage)'" 60 && ok "garbage: śmieci od AI trafiły do intake (powstało zamówienie)" || fail "garbage" "brak zamówienia"
expect "garbage: kategoria unknown, trasa intake" "select category || '/' || route from inbox_messages where external_id = '$(ext garbage)'" "unknown/intake"

# --- idempotencja ---------------------------------------------------------------------------------------------------------------
out="$(triage question "$FIX/email-question.txt" triage-question catalog)"
if [ "$(code_of "$out")" = "200" ] && [ "$(body_of "$out" | jq -r '.status')" = "duplicate" ]; then ok "question ponownie: duplicate"; else fail "question ponownie" "$out"; fi
sleep 2
expect "idempotencja: jedna wiadomość i jedno powiadomienie" \
  "select (select count(*) from inbox_messages where external_id = '$(ext question)') || '/' || (select count(*) from slack_outbox s join inbox_messages i on s.dedupe_key = 'inbox:' || i.id where i.external_id = '$(ext question)')" "1/1"

# --- Message-ID ze znakami spoza bezpiecznego zestawu i równoległe dostawy ---------------------------------------------
MID="<tr-$RUN-bang!1@mail.example>"
out="$(curl -s -w '\n%{http_code}' -X POST "$BASE/triage" -H 'Content-Type: application/json' -H 'X-LLM-Mock: triage-order' -H 'X-Intake-Mock: catalog' \
  -d "{\"external_id\":\"$MID\",\"from_email\":\"klient-bang@example.com\",\"subject\":\"S\",\"message\":\"Proszę o wycenę komody\"}")"
[ "$(code_of "$out")" = "200" ] && ok "Message-ID z '!' przyjęty" || fail "Message-ID z !" "$out"
wait_for "select count(*) = 1 from orders o join inbox_messages i on i.external_id = o.external_id where i.message_id = '$MID'" 60 && ok "Message-ID z '!': zamówienie powstało pod kluczem ze skrótu" || fail "Message-ID z !" "brak zamówienia"
q "delete from orders where external_id in (select external_id from inbox_messages where message_id = '$MID'); delete from inbox_messages where message_id = '$MID'" >/dev/null
for i in 1 2 3; do triage "race" "$FIX/email-question.txt" triage-question catalog >/dev/null & done; wait
sleep 3
expect "równoległe dostawy tej samej wiadomości: jeden wiersz i jedno powiadomienie" \
  "select (select count(*) from inbox_messages where external_id = '$(ext race)') || '/' || (select count(*) from slack_outbox s join inbox_messages i on s.dedupe_key = 'inbox:' || i.id where i.external_id = '$(ext race)')" "1/1"

# --- walidacja wejścia ----------------------------------------------------------------------------------------------------------
c="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/triage" -H 'Content-Type: application/json' -d '{"external_id":"x","from_email":"a@example.com","message":""}')"
[ "$c" = "400" ] && ok "walidacja: pusta wiadomość -> 400" || fail "walidacja" "HTTP $c"
c="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/triage" -H 'X-LLM-Mock: ../x' -H 'Content-Type: application/json' -d "{\"external_id\":\"tr-$RUN-bad\",\"from_email\":\"a@example.com\",\"message\":\"x\"}")"
[ "$c" = "400" ] && ok "walidacja: zła atrapa -> 400" || fail "walidacja atrapa" "HTTP $c"

# --- naprawa: wiadomość bez odpowiedzi AI i sklasyfikowana, ale nieprzekazana ------------------------------------------
q "insert into inbox_messages (external_id, from_email, subject, body, created_at) values ('$(ext stuck)', 'klient-stuck@example.com', 'Utknęło', 'Proszę o wycenę szafki', now() - interval '10 minutes')" >/dev/null
q "insert into inbox_messages (external_id, from_email, subject, body, category, confidence, route, classified_at, created_at) values ('$(ext lost)', 'klient-lost@example.com', 'Nieprzekazane', 'Proszę o wycenę regału', 'order', 0.9, 'intake', now() - interval '3 minutes', now() - interval '4 minutes')" >/dev/null
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/triage-sweep" -H 'X-Intake-Mock: catalog')"
[ "$code" = "200" ] && ok "sweep: uruchomiony" || fail "sweep" "HTTP $code"
for n in stuck lost; do
  wait_for "select count(*) = 1 from orders where external_id = '$(ext $n)'" 60 && ok "sweep: $n przekazane do intake (powstało zamówienie)" || fail "sweep $n" "brak zamówienia"
  # znacznik przekazania ustawiany jest po odpowiedzi intake, więc chwilę po utworzeniu zamówienia
  wait_for "select (forwarded_at is not null) from inbox_messages where external_id = '$(ext $n)'" 20 || true
  expect "sweep: $n oznaczone jako przekazane" "select (forwarded_at is not null)::text from inbox_messages where external_id = '$(ext $n)'" "true"
done
expect "sweep: zawieszona wiadomość dostała trasę intake" "select route || '/' || category from inbox_messages where external_id = '$(ext stuck)'" "intake/unknown"
c="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/triage-sweep" -H 'X-Intake-Mock: ../x')"
[ "$c" = "403" ] && ok "sweep: zła atrapa -> 403" || fail "sweep atrapa" "HTTP $c"

echo
if [ "$failures" -eq 0 ]; then echo "OK"; else echo "FAIL ($failures)"; exit 1; fi
