#!/usr/bin/env bash
# Prawdziwy test równoległości: dwie sesje zlecają zadania na ten sam materiał jednocześnie.
# Każde zamówienie potrzebuje 6 z 10 sztuk, więc dokładnie jedno ma się udać.
# Dane testowe są zatwierdzane (commit), więc na końcu sprzątamy po sobie.
set -euo pipefail

DB_CONTAINER="supabase_db_meble-automatyzacja"
psql_run() { docker exec -i "$DB_CONTAINER" psql -U postgres -q -At -v ON_ERROR_STOP=1 "$@"; }

M=00000000-0000-0000-0000-0000000000f1
P=00000000-0000-0000-0000-0000000000f2
S=00000000-0000-0000-0000-0000000000f3

cleanup() {
  psql_run <<SQL >/dev/null
delete from stock_movements where material_id = '$M';
delete from tasks where order_id in (select id from orders where external_id like 'conc-%');
delete from orders where external_id like 'conc-%';
delete from product_materials where product_id = '$P';
delete from products where id = '$P';
delete from supplier_prices where material_id = '$M';
delete from materials where id = '$M';
delete from suppliers where id = '$S';
SQL
}
trap cleanup EXIT
cleanup

psql_run <<SQL >/dev/null
insert into suppliers (id, name, email) values ('$S', 'Conc Hurt', 'c@example.com');
insert into materials (id, name, unit, stock, min_stock) values ('$M', 'Conc materiał', 'szt', 10, 1);
insert into supplier_prices (supplier_id, material_id, price) values ('$S', '$M', 10);
insert into products (id, name, labor_hours) values ('$P', 'Conc produkt', 1);
insert into product_materials (product_id, material_id, qty) values ('$P', '$M', 6);
SQL

order_ids=()
for n in 1 2; do
  id=$(psql_run <<SQL
select upsert_order(jsonb_build_object('external_id','conc-$n','source','form',
  'customer_email','k@example.com','kind','catalog',
  'items', jsonb_build_array(jsonb_build_object('product_id','$P','qty',1))));
SQL
)
  psql_run -c "select estimate_quote('$id')" >/dev/null
  order_ids+=("$id")
done

# Sesja 1 trzyma blokadę 2 s po rezerwacji; sesja 2 startuje w trakcie i musi na nią poczekać.
out1=$(mktemp); out2=$(mktemp)
( psql_run <<SQL >"$out1" 2>&1 || true
begin;
select 'OK';
select create_task('${order_ids[0]}', 'Jan');
select pg_sleep(2);
commit;
SQL
) &
sleep 0.7
( psql_run <<SQL >"$out2" 2>&1 || true
select create_task('${order_ids[1]}', 'Anna');
SQL
) &
wait

ok=0; fail=0
for f in "$out1" "$out2"; do
  if grep -q 'INSUFFICIENT_STOCK' "$f"; then fail=$((fail + 1));
  elif grep -qE '^[0-9a-f-]{36}$' "$f"; then ok=$((ok + 1)); fi
done

reserved=$(psql_run -c "select reserved from materials where id = '$M'")
echo "udane=$ok odrzucone=$fail reserved=$reserved"

if [ "$ok" -eq 1 ] && [ "$fail" -eq 1 ] && [ "$reserved" = "6.000" ]; then
  echo "PASS test_parallel_reservation"
else
  echo "FAIL test_parallel_reservation"
  cat "$out1" "$out2"
  exit 1
fi
