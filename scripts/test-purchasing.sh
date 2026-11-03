#!/usr/bin/env bash
# Testy workflow 08-purchase-orders (szkice zamówień do hurtowni, zatwierdzenie linkiem, przyjęcie dostawy) na lokalnej bazie.
# Wymaga działającego Supabase i n8n w trybie testowym (ALLOW_LLM_MOCK=1 scripts/n8n.sh start).
# Testy zmieniają stany i minima materiałów, daty cen oraz zamówienia do hurtowni; po zakończeniu przywracają je z kopii
# i usuwają własne zamówienia, powiadomienia i ruchy magazynowe. Uruchamiaj na lokalnej bazie bez równoległych operacji.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env.local ] && { set -a; . ./.env.local; set +a; }
: "${OPERATOR_PASSWORD:?Brak OPERATOR_PASSWORD w .env.local (uruchom scripts/n8n.sh start, który go wygeneruje)}"
OPERATOR_USER="${OPERATOR_USER:-operator}"
DB_CONTAINER="supabase_db_meble-automatyzacja"
BASE="${N8N_URL:-http://localhost:5678}/webhook"
RUN="$(date +%s)"
BODYF="/tmp/po-body-$RUN"
failures=0

q() { docker exec -i "$DB_CONTAINER" psql -U postgres -q -At -v ON_ERROR_STOP=1 -c "$1"; }

# kopia stanów i minimów materiałów oraz lista otwartych zamówień do hurtowni (odłożymy je na czas testu)
RESTORE_SQL="$(q "select string_agg(format('update materials set stock=%s, reserved=%s, min_stock=%s where id=%L;', stock, reserved, min_stock, id), ' ') from materials")"
RESTORE_POS="$(q "select coalesce(string_agg(format('update purchase_orders set status=%L where id=%L;', status, id), ' '), '') from purchase_orders where status in ('draft','sent')")"
RESTORE_PRICES="$(q "select coalesce(string_agg(format('update supplier_prices set updated_at=%L where supplier_id=%L and material_id=%L;', updated_at, supplier_id, material_id), ' '), '') from supplier_prices")"
START_TS="$(q "select now()")"

cleanup() {
  q "delete from slack_outbox where kind in ('po_draft','po_unpriced') and created_at >= '$START_TS'" >/dev/null 2>&1 || true
  q "delete from purchase_orders where created_at >= '$START_TS'" >/dev/null 2>&1 || true
  q "delete from stock_movements where kind = 'receive' and created_at >= '$START_TS'" >/dev/null 2>&1 || true
  q "$RESTORE_SQL" >/dev/null 2>&1 || true
  [ -n "$RESTORE_POS" ] && q "$RESTORE_POS" >/dev/null 2>&1 || true
  [ -n "$RESTORE_PRICES" ] && q "$RESTORE_PRICES" >/dev/null 2>&1 || true
  rm -f "$BODYF"
}
trap cleanup EXIT

ok()   { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }
expect() { local got; got=$(q "$2"); if [ "$got" = "$3" ]; then ok "$1"; else fail "$1" "oczekiwano '$3', jest '$got'"; fi; }

# http <GET|POST> <ścieżka> [dane formularza] -> kod HTTP, treść w $BODYF
http() {
  local args=(-s -o "$BODYF" -w '%{http_code}' -X "$1" "$BASE/$2" -u "$OPERATOR_USER:$OPERATOR_PASSWORD")
  # strony n8n są w piaskownicy CSP, więc prawdziwa przeglądarka wysyła Origin: null; tak symulujemy kliknięcie
  [ "$1" = "POST" ] && args+=(-H 'Content-Type: application/x-www-form-urlencoded' -H 'Origin: null' --data "${3:-}")
  curl "${args[@]}" || true
}
body_has() { grep -qF -- "$1" "$BODYF"; }

run_workflow() {
  local code; code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/po-run" || true)
  [ "$code" = "200" ] || fail "po-run" "HTTP $code"
  sleep 4
}

# --- przygotowanie: dwa materiały poniżej minimum, reszta bez minimum, otwarte zamówienia odłożone ---------------
q "update purchase_orders set status = 'cancelled' where status in ('draft','sent')" >/dev/null
q "update materials set min_stock = 0" >/dev/null
q "update materials set stock = 15, reserved = 0, min_stock = 30 where name = 'Uchwyt czarny 128 mm'" >/dev/null
q "update materials set stock = 2, reserved = 0, min_stock = 3 where name = 'Olej do drewna'" >/dev/null
q "update supplier_prices set updated_at = now()" >/dev/null   # ceny z seeda mogą być starsze niż 30 dni

# --- webhook testowy jest wyłączony poza trybem testowym: tu działa, więc tworzy szkice -------------------------
run_workflow
expect "po-run: dwa szkice (po jednym na dostawcę)" "select count(*) from purchase_orders where created_at >= '$START_TS' and status = 'draft'" "2"
expect "po-run: każdy materiał u najtańszego dostawcy" \
  "select count(*) from purchase_order_lines l join purchase_orders p on p.id = l.po_id where p.created_at >= '$START_TS' and p.supplier_id = (select supplier_id from best_price(l.material_id))" "2"
expect "po-run: ilości uzupełniają do dwukrotności minimum" \
  "select string_agg(m.name || '=' || trim_scale(l.qty), ',' order by m.name) from purchase_order_lines l join materials m on m.id = l.material_id join purchase_orders p on p.id = l.po_id where p.created_at >= '$START_TS'" \
  "Olej do drewna=4,Uchwyt czarny 128 mm=45"
expect "slack: wiadomość z linkiem zatwierdzenia dla każdego szkicu" \
  "select count(*) from slack_outbox where kind = 'po_draft' and created_at >= '$START_TS' and text like '%/webhook/po-approve?po_id=%'" "2"

run_workflow
expect "idempotencja: drugie uruchomienie nie tworzy nowych szkiców" "select count(*) from purchase_orders where created_at >= '$START_TS'" "2"

PO="$(q "select id from purchase_orders where created_at >= '$START_TS' order by id limit 1")"
MAT="$(q "select material_id from purchase_order_lines where po_id = '$PO'")"
QTY="$(q "select qty from purchase_order_lines where po_id = '$PO'")"
SUP_EMAIL="$(q "select s.email from purchase_orders p join suppliers s on s.id = p.supplier_id where p.id = '$PO'")"

# --- uwierzytelnienie i CSRF ---------------------------------------------------------------------------------------
for path in "GET po-approve?po_id=$PO" "POST po-approve" "GET po-received?po_id=$PO" "POST po-received"; do
  m="${path%% *}"; p="${path#* }"
  args=(-s -o /dev/null -w '%{http_code}' -X "$m" "$BASE/$p")
  [ "$m" = "POST" ] && args+=(--data "po_id=$PO")
  c=$(curl "${args[@]}" || true)
  [ "$c" = "401" ] && ok "auth: $m $p bez logowania -> 401" || fail "auth $m $p" "HTTP $c"
done
for origin in "https://evil.example" "http://evil.example:5678"; do
  c=$(curl -s -o /dev/null -w '%{http_code}' -u "$OPERATOR_USER:$OPERATOR_PASSWORD" -H "Origin: $origin" -X POST "$BASE/po-approve" --data "po_id=$PO" || true)
  [ "$c" = "400" ] && ok "csrf: formularz z Origin $origin -> 400" || fail "csrf $origin" "HTTP $c"
done
c=$(curl -s -o /dev/null -w '%{http_code}' -u "$OPERATOR_USER:$OPERATOR_PASSWORD" -X POST "$BASE/po-approve?po_id=$PO" || true)
[ "$c" = "400" ] && ok "csrf: pusty POST z identyfikatorem w adresie -> 400" || fail "csrf pusty POST" "HTTP $c"
c=$(curl -s -o /dev/null -w '%{http_code}' -u "$OPERATOR_USER:$OPERATOR_PASSWORD" -H 'Origin: https://evil.example' -X POST "$BASE/po-received?po_id=$PO" || true)
[ "$c" = "400" ] && ok "csrf: pusty POST /po-received z obcym Origin -> 400" || fail "csrf po-received" "HTTP $c"
expect "auth i csrf: szkic nadal draft" "select status from purchase_orders where id = '$PO'" "draft"

# --- zatwierdzenie ---------------------------------------------------------------------------------------------------
c=$(http GET "po-approve?po_id=$PO")
if [ "$c" = "200" ] && body_has '<form method="post" action="/webhook/po-approve">'; then ok "approve GET: strona z przyciskiem"; else fail "approve GET" "HTTP $c"; fi
expect "approve GET niczego nie zmienia" "select status from purchase_orders where id = '$PO'" "draft"
c=$(http GET "po-approve?po_id=nie-uuid")
[ "$c" = "400" ] && ok "approve GET: zły identyfikator -> 400" || fail "approve GET zły id" "HTTP $c"

c=$(http POST po-approve "po_id=$PO")
if [ "$c" = "200" ] && body_has "Zamówienie wysłane"; then ok "approve POST: zamówienie wysłane"; else fail "approve POST" "HTTP $c"; fi
expect "approve: status sent" "select status from purchase_orders where id = '$PO'" "sent"
expect "approve: mail do hurtowni w kolejce" "select count(*) from email_outbox where po_id = '$PO' and kind = 'purchase_order' and to_email = '$SUP_EMAIL'" "1"
c=$(http POST po-approve "po_id=$PO")
if [ "$c" = "409" ]; then ok "approve POST ponownie -> 409"; else fail "approve ponownie" "HTTP $c"; fi
expect "approve ponownie: jeden mail" "select count(*) from email_outbox where po_id = '$PO'" "1"

# --- przyjęcie dostawy -------------------------------------------------------------------------------------------------
BEFORE="$(q "select stock from materials where id = '$MAT'")"
c=$(http GET "po-received?po_id=$PO")
if [ "$c" = "200" ] && body_has 'action="/webhook/po-received"'; then ok "received GET: strona z przyciskiem"; else fail "received GET" "HTTP $c"; fi
expect "received GET niczego nie zmienia" "select stock from materials where id = '$MAT'" "$BEFORE"
c=$(http POST po-received "po_id=$PO")
if [ "$c" = "200" ] && body_has "Dostawa przyjęta"; then ok "received POST: dostawa przyjęta"; else fail "received POST" "HTTP $c"; fi
expect "received: stan wzrósł o ilość z zamówienia" "select stock - $BEFORE = $QTY from materials where id = '$MAT'" "t"
expect "received: ruch magazynowy receive" "select count(*) from stock_movements where material_id = '$MAT' and kind = 'receive' and created_at >= '$START_TS'" "1"
expect "received: status received" "select status from purchase_orders where id = '$PO'" "received"
c=$(http POST po-received "po_id=$PO")
[ "$c" = "409" ] && ok "received POST ponownie -> 409" || fail "received ponownie" "HTTP $c"
expect "received ponownie: stan bez zmian" "select stock - $BEFORE = $QTY from materials where id = '$MAT'" "t"

# --- współbieżność: równoległe wywołania nie dublują szkiców, maili ani przyjęć dostawy -----------------------------
run_sql() { docker exec -i "$DB_CONTAINER" psql -U postgres -q -At -v ON_ERROR_STOP=1 -c "$1" >/dev/null 2>&1 || true; }
q "update purchase_orders set status = 'cancelled' where status in ('draft','sent')" >/dev/null
q "update materials set stock = 15, reserved = 0, min_stock = 30 where name = 'Uchwyt czarny 128 mm'" >/dev/null
q "update materials set stock = 2, reserved = 0, min_stock = 3 where name = 'Olej do drewna'" >/dev/null
CT="$(q "select now()")"
run_sql "select create_purchase_orders()" & run_sql "select create_purchase_orders()" & wait
expect "równolegle create: dokładnie dwa szkice" "select count(*) from purchase_orders where created_at >= '$CT'" "2"
CPO="$(q "select id from purchase_orders where created_at >= '$CT' order by id limit 1")"
CMAT="$(q "select material_id from purchase_order_lines where po_id = '$CPO'")"
CQTY="$(q "select qty from purchase_order_lines where po_id = '$CPO'")"
CBEFORE="$(q "select stock from materials where id = '$CMAT'")"
run_sql "select approve_purchase_order('$CPO')" & run_sql "select approve_purchase_order('$CPO')" & wait
expect "równolegle approve: jeden mail" "select count(*) from email_outbox where po_id = '$CPO'" "1"
run_sql "select receive_delivery('$CPO')" & run_sql "select receive_delivery('$CPO')" & wait
expect "równolegle receive: stan wzrósł tylko raz" "select stock - $CBEFORE = $CQTY from materials where id = '$CMAT'" "t"
expect "równolegle receive: jeden ruch magazynowy" "select count(*) from stock_movements where material_id = '$CMAT' and kind = 'receive' and created_at >= '$CT'" "1"

echo
if [ "$failures" -eq 0 ]; then echo "OK"; else echo "FAIL ($failures)"; exit 1; fi
