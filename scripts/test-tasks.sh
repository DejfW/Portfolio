#!/usr/bin/env bash
# Testy workflow 03-team-tasks (zatwierdzanie zamówień i zamykanie zadań przez linki) na lokalnej bazie.
# Wymaga działającego Supabase i n8n (scripts/n8n.sh start). Testy zmieniają stany magazynowe,
# a po zakończeniu przywracają je z kopii i usuwają własne zamówienia, zadania i powiadomienia.
set -euo pipefail

cd "$(dirname "$0")/.."
DB_CONTAINER="supabase_db_meble-automatyzacja"
BASE="${N8N_URL:-http://localhost:5678}/webhook"
RUN="$(date +%s)"
BODYF="/tmp/tasks-body-$RUN"
failures=0

q() { docker exec -i "$DB_CONTAINER" psql -U postgres -q -At -v ON_ERROR_STOP=1 -c "$1"; }

# kopia stanów magazynowych do przywrócenia po testach
RESTORE_SQL="$(q "select string_agg(format('update materials set stock=%s, reserved=%s where id=%L;', stock, reserved, id), ' ') from materials")"

cleanup() {
  q "delete from slack_outbox where dedupe_key in (select 'task:' || id from tasks where order_id in (select id from orders where external_id like 'tk-$RUN-%')
       union select 'done:' || id from tasks where order_id in (select id from orders where external_id like 'tk-$RUN-%')
       union select 'shortage:' || id || ':' || to_char(now() at time zone 'utc', 'YYYY-MM-DD') from orders where external_id like 'tk-$RUN-%')" >/dev/null 2>&1 || true
  q "delete from stock_movements where task_id in (select id from tasks where order_id in (select id from orders where external_id like 'tk-$RUN-%'))" >/dev/null 2>&1 || true
  q "delete from tasks where order_id in (select id from orders where external_id like 'tk-$RUN-%')" >/dev/null 2>&1 || true
  q "delete from orders where external_id like 'tk-$RUN-%'" >/dev/null 2>&1 || true
  q "$RESTORE_SQL" >/dev/null 2>&1 || true
  rm -f "$BODYF"
}
trap cleanup EXIT

ok()   { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }
expect() { local got; got=$(q "$2"); if [ "$got" = "$3" ]; then ok "$1"; else fail "$1" "oczekiwano '$3', jest '$got'"; fi; }

# http <GET|POST> <ścieżka> [dane formularza] -> kod HTTP, treść w $BODYF
http() {
  local args=(-s -o "$BODYF" -w '%{http_code}' -X "$1" "$BASE/$2")
  [ "$1" = "POST" ] && args+=(-H 'Content-Type: application/x-www-form-urlencoded' --data "${3:-}")
  curl "${args[@]}" || true
}
body_has() { grep -qF -- "$1" "$BODYF"; }

# new_order <id> <produkt> [email] -> id zamówienia z wyceną (status quoted)
new_order() {
  local ext="tk-$RUN-$1" email="${3:-klient-$1@example.com}"
  q "select intake_receive(jsonb_build_object('external_id','$ext','source','form','customer_email','$email','raw_text','Zamówienie testowe'))" >/dev/null
  q "select intake_complete((select id from orders where external_id='$ext'), jsonb_build_object('kind','catalog','route','ok','parsed',jsonb_build_object('llm','x'),'items',jsonb_build_array(jsonb_build_object('product_id',(select id from products where name='$2'),'qty',1))))" >/dev/null
  q "select id from orders where external_id='$ext'"
}

PRODUCT="Szafka nocna MDF biała"

# --- strona zatwierdzenia: GET niczego nie zmienia ---------------------------------------------------
O1=$(new_order a "$PRODUCT")
code=$(http GET "approve?order_id=$O1")
[ "$code" = "200" ] && ok "approve_page: HTTP 200" || fail "approve_page" "HTTP $code"
body_has '<form method="post" action="/webhook/approve">' && ok "approve_page: formularz POST" || fail "approve_page" "brak formularza"
body_has "klient-a@example.com" && ok "approve_page: dane klienta" || fail "approve_page" "brak e-maila klienta"
body_has "<option>Jan</option>" && ok "approve_page: lista zespołu" || fail "approve_page" "brak listy zespołu"
expect "approve_page: GET nie zmienia statusu" "select status from orders where id='$O1'" "quoted"
expect "approve_page: GET nie tworzy zadania" "select count(*) from tasks where order_id='$O1'" "0"

code=$(http GET "approve?order_id=nie-uuid")
[ "$code" = "400" ] && ok "approve_page: zły identyfikator -> 400" || fail "approve_page: zły identyfikator" "HTTP $code"
code=$(http GET "approve?order_id=00000000-0000-0000-0000-00000000dead")
[ "$code" = "404" ] && ok "approve_page: nieistniejące zamówienie -> 404" || fail "approve_page: nieistniejące" "HTTP $code"

# --- zlecenie zadania ---------------------------------------------------------------------------------
RES_BEFORE=$(q "select reserved from materials where name='Płyta MDF 18 mm biała'")
code=$(http POST approve "order_id=$O1&assignee=Jan")
[ "$code" = "200" ] && ok "approve_post: HTTP 200" || fail "approve_post" "HTTP $code: $(head -c 200 "$BODYF")"
body_has "Zlecono zadanie" && ok "approve_post: strona potwierdzenia" || fail "approve_post" "brak potwierdzenia"
body_has "/webhook/task-done?task_id=" && ok "approve_post: link do zakończenia zadania" || fail "approve_post" "brak linku"
expect "approve_post: zamówienie w realizacji" "select status from orders where id='$O1'" "in_progress"
expect "approve_post: zadanie przydzielone Janowi" "select assignee from tasks where order_id='$O1'" "Jan"
expect "approve_post: materiał zarezerwowany" "select reserved > $RES_BEFORE from materials where name='Płyta MDF 18 mm biała'" "t"
T1=$(q "select id from tasks where order_id='$O1'")
expect "approve_post: wiadomość Slack w kolejce" "select count(*) from slack_outbox where dedupe_key='task:$T1' and kind='task_assigned' and text like '%*Jan*%' and text like '%task-done?task_id=$T1%'" "1"

code=$(http POST approve "order_id=$O1&assignee=Anna")
[ "$code" = "409" ] && ok "approve_post: powtórka -> 409" || fail "approve_post: powtórka" "HTTP $code"
expect "approve_post: powtórka nie tworzy drugiego zadania" "select count(*) from tasks where order_id='$O1'" "1"
expect "approve_post: powtórka nie dubluje Slacka" "select count(*) from slack_outbox where dedupe_key='task:$T1'" "1"

# --- błędne dane formularza ---------------------------------------------------------------------------
O2=$(new_order b "$PRODUCT")
code=$(http POST approve "order_id=$O2")
[ "$code" = "409" ] && ok "approve_post: brak osoby -> 409" || fail "approve_post: brak osoby" "HTTP $code"
code=$(http POST approve "order_id=$O2' or 1=1--&assignee=Jan")
[ "$code" = "400" ] && ok "approve_post: wstrzyknięcie w identyfikatorze -> 400" || fail "approve_post: wstrzyknięcie" "HTTP $code"
expect "approve_post: błędne dane niczego nie zmieniły" "select status from orders where id='$O2'" "quoted"

# --- brak materiału -----------------------------------------------------------------------------------
O3=$(new_order c "$PRODUCT")
UCH_RESERVED=$(q "select reserved from materials where name='Uchwyt czarny 128 mm'")
q "update materials set reserved = stock where name='Uchwyt czarny 128 mm'"
code=$(http POST approve "order_id=$O3&assignee=Piotr")
[ "$code" = "409" ] && ok "shortage: HTTP 409" || fail "shortage" "HTTP $code"
body_has "Uchwyt czarny 128 mm" && ok "shortage: strona z listą braków" || fail "shortage" "brak materiału na stronie"
expect "shortage: zamówienie nadal czeka" "select status from orders where id='$O3'" "quoted"
expect "shortage: brak zadania" "select count(*) from tasks where order_id='$O3'" "0"
expect "shortage: alert Slack z hurtownią" "select count(*) from slack_outbox where kind='stock_shortage' and dedupe_key like 'shortage:$O3:%' and text like '%Uchwyt czarny 128 mm%' and text like '%najtaniej: MebloHurt Poznań%'" "1"
q "update materials set reserved = $UCH_RESERVED where name='Uchwyt czarny 128 mm'" >/dev/null

# --- escapowanie danych klienta na stronie -----------------------------------------------------------
XSS='<img src=x onerror=alert(1)>@x.pl'
O4=$(new_order d "$PRODUCT" "$XSS")
http GET "approve?order_id=$O4" >/dev/null
body_has '<img src=x' && fail "xss" "surowy znacznik na stronie" || ok "xss: dane klienta są escapowane"
body_has '&lt;img src=x' && ok "xss: widoczna wersja zakodowana" || fail "xss" "brak zakodowanego tekstu"

# --- zakończenie zadania ------------------------------------------------------------------------------
STOCK_BEFORE=$(q "select stock from materials where name='Płyta MDF 18 mm biała'")
code=$(http GET "task-done?task_id=$T1")
[ "$code" = "200" ] && ok "done_page: HTTP 200" || fail "done_page" "HTTP $code"
body_has '<form method="post" action="/webhook/task-done">' && ok "done_page: formularz POST" || fail "done_page" "brak formularza"
expect "done_page: GET nie kończy zadania" "select status from tasks where id='$T1'" "todo"
code=$(http GET "task-done?task_id=zly")
[ "$code" = "400" ] && ok "done_page: zły identyfikator -> 400" || fail "done_page: zły identyfikator" "HTTP $code"

code=$(http POST task-done "task_id=$T1")
[ "$code" = "200" ] && ok "done_post: HTTP 200" || fail "done_post" "HTTP $code: $(head -c 200 "$BODYF")"
body_has "Zadanie zakończone" && ok "done_post: strona potwierdzenia" || fail "done_post" "brak potwierdzenia"
expect "done_post: zadanie i zamówienie zakończone" "select (select status from tasks where id='$T1') || '/' || (select status from orders where id='$O1')" "done/done"
expect "done_post: materiał zużyty" "select stock < $STOCK_BEFORE from materials where name='Płyta MDF 18 mm biała'" "t"
expect "done_post: mail dla klienta w kolejce" "select count(*) from email_outbox where order_id='$O1' and kind='order_done' and to_email='klient-a@example.com'" "1"
expect "done_post: Slack o zakończeniu" "select count(*) from slack_outbox where dedupe_key='done:$T1' and kind='task_done'" "1"

code=$(http POST task-done "task_id=$T1")
[ "$code" = "409" ] && ok "done_post: powtórka -> 409" || fail "done_post: powtórka" "HTTP $code"
expect "done_post: powtórka nie dubluje powiadomień" "select (select count(*) from email_outbox where order_id='$O1' and kind='order_done') || '/' || (select count(*) from slack_outbox where dedupe_key='done:$T1')" "1/1"
code=$(http POST task-done "task_id=00000000-0000-0000-0000-00000000dead")
[ "$code" = "409" ] && ok "done_post: nieistniejące zadanie -> 409" || fail "done_post: nieistniejące" "HTTP $code"

if [ "$failures" -ne 0 ]; then echo "FAIL ($failures)"; exit 1; fi
echo "OK"
