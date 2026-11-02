#!/usr/bin/env bash
# Prawdziwe testy równoległości na lokalnej bazie: dwie sesje działają jednocześnie.
# Test jest ważny tylko wtedy, gdy druga sesja faktycznie czeka na blokadę pierwszej;
# skrypt to sprawdza w pg_stat_activity i inaczej kończy się porażką.
# Dane testowe są zatwierdzane (commit), więc na końcu usuwamy dokładnie te rekordy,
# które sami utworzyliśmy (stałe identyfikatory z prefiksem conc-parallel-).
set -euo pipefail

DB_CONTAINER="supabase_db_meble-automatyzacja"
psql_run() { docker exec -i "$DB_CONTAINER" psql -U postgres -q -At -v ON_ERROR_STOP=1 "$@"; }

M1=00000000-0000-0000-0000-0000000000f1
M2=00000000-0000-0000-0000-0000000000f4
P1=00000000-0000-0000-0000-0000000000f2
P2=00000000-0000-0000-0000-0000000000f5
S=00000000-0000-0000-0000-0000000000f3
EXT="'conc-parallel-a1','conc-parallel-a2','conc-parallel-b1','conc-parallel-b2','conc-parallel-c1'"

cleanup() {
  psql_run <<SQL >/dev/null
delete from stock_movements where task_id in
  (select id from tasks where order_id in (select id from orders where external_id in ($EXT)));
delete from tasks where order_id in (select id from orders where external_id in ($EXT));
delete from orders where external_id in ($EXT);
delete from product_materials where product_id in ('$P1','$P2');
delete from products where id in ('$P1','$P2');
delete from supplier_prices where supplier_id = '$S';
delete from materials where id in ('$M1','$M2');
delete from suppliers where id = '$S';
SQL
}
trap cleanup EXIT
cleanup

tmp=$(mktemp -d)
failures=0

setup() { # $1 = stan obu materiałów
  psql_run <<SQL >/dev/null
insert into suppliers (id, name, email) values ('$S', 'Conc Hurt', 'c@example.com');
insert into materials (id, name, unit, stock, min_stock) values
  ('$M1', 'Conc materiał 1', 'szt', $1, 1), ('$M2', 'Conc materiał 2', 'szt', $1, 1);
insert into supplier_prices (supplier_id, material_id, price) values ('$S', '$M1', 10), ('$S', '$M2', 10);
insert into products (id, name, labor_hours) values ('$P1', 'Conc produkt 1', 1), ('$P2', 'Conc produkt 2', 1);
insert into product_materials (product_id, material_id, qty) values
  ('$P1', '$M1', 6), ('$P1', '$M2', 6), ('$P2', '$M2', 6), ('$P2', '$M1', 6);
SQL
}

new_order() { # $1 = external_id, $2 = produkt; wypisuje id zamówienia
  psql_run <<SQL
with o as (
  select upsert_order(jsonb_build_object('external_id','$1','source','form','customer_email','k@example.com',
    'kind','catalog','items', jsonb_build_array(jsonb_build_object('product_id','$2','qty',1)))) as id)
select id from o \gset
select estimate_quote(:'id') is not null as quoted \gset
select :'id';
SQL
}

reset_data() { cleanup; setup "$1"; }

# race <zamówienie1> <zamówienie2>: sesja 1 rezerwuje i trzyma blokadę 3 s,
# sesja 2 startuje, gdy sesja 1 już śpi z blokadą, i musi poczekać.
race() {
  : >"$tmp/out1"; : >"$tmp/out2"
  ( psql_run >"$tmp/out1" 2>&1 <<SQL || true
begin;
select create_task('$1', 'Jan');
select pg_sleep(3);
commit;
SQL
  ) &
  local pid1=$!
  local i
  for i in $(seq 1 50); do
    [ "$(psql_run -c "select count(*) from pg_stat_activity where state='active' and query like '%pg_sleep(3)%' and pid <> pg_backend_pid()")" = "1" ] && break
    sleep 0.1
  done
  ( psql_run >"$tmp/out2" 2>&1 <<SQL || true
select create_task('$2', 'Anna');
SQL
  ) &
  local pid2=$!
  WAITED=0
  for i in $(seq 1 30); do
    if [ "$(psql_run -c "select count(*) from pg_stat_activity where wait_event_type='Lock' and datname='postgres'")" -ge 1 ]; then WAITED=1; break; fi
    sleep 0.1
  done
  wait "$pid1" "$pid2"
}

classify() { # $1 = plik; wypisuje: ok | <kod błędu> | unknown
  if grep -qE '^[0-9a-f-]{36}$' "$1"; then echo ok
  elif grep -q 'deadlock' "$1"; then echo deadlock
  elif grep -qoE 'INSUFFICIENT_STOCK|ORDER_NOT_READY:[a-z_]+' "$1"; then grep -oE 'INSUFFICIENT_STOCK|ORDER_NOT_READY:[a-z_]+' "$1" | head -1
  else echo unknown; fi
}

check() { # $1 = nazwa, $2 = oczekiwane "wynik1 wynik2" (kolejność dowolna), $3 = oczekiwane reserved M1
  local r1 r2 got reserved
  r1=$(classify "$tmp/out1"); r2=$(classify "$tmp/out2")
  got=$(printf '%s\n%s\n' "$r1" "$r2" | sort | paste -sd' ' -)
  reserved=$(psql_run -c "select reserved from materials where id = '$M1'")
  if [ "$WAITED" -ne 1 ]; then
    echo "FAIL $1: druga sesja nie czekała na blokadę (test nieważny)"; failures=$((failures + 1)); return
  fi
  if [ "$got" = "$2" ] && [ "$reserved" = "$3" ]; then
    echo "PASS $1 (wyniki: $got, reserved=$reserved)"
  else
    echo "FAIL $1: wyniki '$got' (oczekiwane '$2'), reserved=$reserved (oczekiwane $3)"
    cat "$tmp/out1" "$tmp/out2"; failures=$((failures + 1))
  fi
}

# A: dwa zamówienia na ten sam materiał, stan 10, każde potrzebuje 6 → jedno przechodzi
reset_data 10
a1=$(new_order conc-parallel-a1 "$P1"); a2=$(new_order conc-parallel-a2 "$P1")
race "$a1" "$a2"
check test_parallel_same_material "INSUFFICIENT_STOCK ok" "6.000"

# B: dwa zamówienia na dwa materiały w przeciwnej kolejności w BOM, stan 100 → oba przechodzą, bez zakleszczenia
reset_data 100
b1=$(new_order conc-parallel-b1 "$P1"); b2=$(new_order conc-parallel-b2 "$P2")
race "$b1" "$b2"
check test_parallel_opposite_bom_order "ok ok" "12.000"

# C: to samo zamówienie zlecone równolegle dwa razy → jedno zadanie
reset_data 100
c1=$(new_order conc-parallel-c1 "$P1")
race "$c1" "$c1"
check test_parallel_same_order "ORDER_NOT_READY:in_progress ok" "6.000"

rm -rf "$tmp"
if [ "$failures" -ne 0 ]; then echo "FAIL"; exit 1; fi
echo "OK"
