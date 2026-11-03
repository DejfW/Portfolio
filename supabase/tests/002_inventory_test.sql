-- Task 2: rezerwacje materiałów, najlepsza cena i widok low_stock.
-- Całość w transakcji wycofywanej na końcu, więc seed nie wpływa na wynik.
begin;

insert into settings (key, value) values ('labor_rate', 120), ('margin', 0.25), ('waste', 0.15)
on conflict (key) do update set value = excluded.value;

insert into suppliers (id, name, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'Test Hurt A', 'a@example.com'),
  ('00000000-0000-0000-0000-0000000000a2', 'Test Hurt B', 'b@example.com');

-- Materiał M1: stan 10, rezerwacja 0. Produkt P1 potrzebuje 6 sztuk M1.
insert into materials (id, name, unit, stock, reserved, min_stock) values
  ('00000000-0000-0000-0000-0000000000b1', 'Test M1', 'szt', 10, 0, 2);
insert into supplier_prices (supplier_id, material_id, price, updated_at) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1', 10, now());
insert into products (id, name, base_price, labor_hours) values
  ('00000000-0000-0000-0000-0000000000c1', 'Test P1', 0, 1);
insert into product_materials (product_id, material_id, qty) values
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b1', 6);

create function pg_temp.new_order(p_ext text) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  v_id := upsert_order(jsonb_build_object(
    'external_id', p_ext, 'source', 'form', 'customer_email', 'k@example.com', 'kind', 'catalog',
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', '00000000-0000-0000-0000-0000000000c1', 'qty', 1))));
  perform estimate_quote(v_id);
  return v_id;
end $$;

-- test_create_task_reserves: rezerwacja rośnie o zapotrzebowanie, jest jeden ruch 'reserve'
do $$
declare v_o uuid; v_t uuid;
begin
  v_o := pg_temp.new_order('inv-1');
  v_t := create_task(v_o, 'Jan');
  assert (select reserved from materials where id = '00000000-0000-0000-0000-0000000000b1') = 6, 'reserved 6';
  assert (select stock from materials where id = '00000000-0000-0000-0000-0000000000b1') = 10, 'stock unchanged';
  assert (select count(*) from stock_movements where task_id = v_t and kind = 'reserve') = 1, 'one reserve movement';
  assert (select qty from stock_movements where task_id = v_t) = 6, 'movement qty';
  assert (select status from orders where id = v_o) = 'in_progress', 'order in_progress';
  assert (select assignee from tasks where id = v_t) = 'Jan', 'assignee';
  raise notice 'PASS test_create_task_reserves';
end $$;

-- test_complete_task_consumes: rezerwacja zamienia się w zużycie
do $$
declare v_o uuid; v_t uuid;
begin
  v_o := pg_temp.new_order('inv-2');
  v_t := (select id from tasks order by created_at desc limit 1);  -- zadanie z poprzedniego testu
  perform complete_task(v_t);
  assert (select stock from materials where id = '00000000-0000-0000-0000-0000000000b1') = 4, 'stock 4';
  assert (select reserved from materials where id = '00000000-0000-0000-0000-0000000000b1') = 0, 'reserved 0';
  assert (select count(*) from stock_movements where task_id = v_t and kind = 'consume') = 1, 'consume movement';
  assert (select status from tasks where id = v_t) = 'done', 'task done';
  assert (select status from orders where id = (select order_id from tasks where id = v_t)) = 'done', 'order done';
  raise notice 'PASS test_complete_task_consumes';
end $$;

-- test_complete_task_twice: drugie zakończenie nie zużywa materiału drugi raz
do $$
declare v_t uuid;
begin
  v_t := (select id from tasks order by created_at desc limit 1);
  begin
    perform complete_task(v_t);
    assert false, 'should have raised';
  exception when others then
    assert sqlerrm = 'TASK_ALREADY_DONE', 'wrong error: ' || sqlerrm;
  end;
  assert (select stock from materials where id = '00000000-0000-0000-0000-0000000000b1') = 4, 'stock still 4';
  raise notice 'PASS test_complete_task_twice';
end $$;

-- test_insufficient_stock_raises: stan 4 nie wystarcza na 6, nic się nie zmienia
do $$
declare v_o uuid; v_before int;
begin
  v_o := pg_temp.new_order('inv-3');
  select count(*) into v_before from stock_movements;
  begin
    perform create_task(v_o, 'Jan');
    assert false, 'should have raised';
  exception when others then
    assert sqlerrm like 'INSUFFICIENT_STOCK:%Test M1%', 'wrong error: ' || sqlerrm;
  end;
  assert (select reserved from materials where id = '00000000-0000-0000-0000-0000000000b1') = 0, 'reserved unchanged';
  assert (select count(*) from tasks where order_id = v_o) = 0, 'no task';
  assert (select count(*) from stock_movements) = v_before, 'no movement';
  assert (select status from orders where id = v_o) = 'quoted', 'order status unchanged';
  raise notice 'PASS test_insufficient_stock_raises';
end $$;

-- test_concurrent_reservation: dwa zamówienia po 60% stanu, drugie odrzucone, dostępne >= 0
do $$
declare v_o1 uuid; v_o2 uuid;
begin
  update materials set stock = 10, reserved = 0 where id = '00000000-0000-0000-0000-0000000000b1';
  v_o1 := pg_temp.new_order('inv-4a');
  v_o2 := pg_temp.new_order('inv-4b');
  perform create_task(v_o1, 'Jan');
  begin
    perform create_task(v_o2, 'Anna');
    assert false, 'second should have raised';
  exception when others then
    assert sqlerrm like 'INSUFFICIENT_STOCK:%', 'wrong error: ' || sqlerrm;
  end;
  assert (select stock - reserved from materials where id = '00000000-0000-0000-0000-0000000000b1') = 4, 'available 4';
  raise notice 'PASS test_concurrent_reservation';
end $$;

-- test_one_open_task_per_order: ponowne zlecenie tego samego zamówienia nie rezerwuje drugi raz
do $$
declare v_o uuid;
begin
  update materials set stock = 100, reserved = 0 where id = '00000000-0000-0000-0000-0000000000b1';
  v_o := pg_temp.new_order('inv-5');
  perform create_task(v_o, 'Jan');
  begin
    perform create_task(v_o, 'Anna');
    assert false, 'should have raised';
  exception when others then
    assert sqlerrm = 'ORDER_NOT_READY:in_progress', 'wrong error: ' || sqlerrm;
  end;
  assert (select reserved from materials where id = '00000000-0000-0000-0000-0000000000b1') = 6, 'reserved once';
  raise notice 'PASS test_one_open_task_per_order';
end $$;

-- test_create_task_wrong_status: zamówienie needs_info/new nie może dostać zadania
do $$
declare v_o uuid;
begin
  v_o := upsert_order(jsonb_build_object(
    'external_id', 'inv-6', 'source', 'email', 'customer_email', 'k@example.com', 'kind', 'catalog',
    'status', 'needs_info'));
  begin
    perform create_task(v_o, 'Jan');
    assert false, 'should have raised';
  exception when others then
    assert sqlerrm like 'ORDER_NOT_READY:%', 'wrong error: ' || sqlerrm;
  end;
  raise notice 'PASS test_create_task_wrong_status';
end $$;

-- test_best_price_stale_ignored: najtańsza cena sprzed 31 dni jest pomijana
do $$
declare r record;
begin
  insert into materials (id, name, unit, stock, min_stock) values
    ('00000000-0000-0000-0000-0000000000b2', 'Test M2', 'szt', 5, 1);
  insert into supplier_prices (supplier_id, material_id, price, updated_at) values
    ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b2', 50, now() - interval '31 days'),
    ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000b2', 80, now() - interval '1 day');
  select * into r from best_price('00000000-0000-0000-0000-0000000000b2');
  assert r.price = 80, 'price: ' || coalesce(r.price::text, 'null');
  assert r.supplier_name = 'Test Hurt B', 'supplier: ' || coalesce(r.supplier_name, 'null');

  -- zero i cena ujemna są odrzucane już przez tabelę (constraint supplier_prices_price_positive)
  begin
    update supplier_prices set price = 0 where material_id = '00000000-0000-0000-0000-0000000000b2'
      and supplier_id = '00000000-0000-0000-0000-0000000000a2';
    assert false, 'zero price accepted';
  exception when check_violation then null;
  end;

  -- same przeterminowane ceny: wynik pusty, a wycena kończy się NO_PRICE
  update supplier_prices set price = 80, updated_at = now() - interval '31 days'
    where material_id = '00000000-0000-0000-0000-0000000000b2' and supplier_id = '00000000-0000-0000-0000-0000000000a2';
  assert not exists (select 1 from best_price('00000000-0000-0000-0000-0000000000b2')), 'only stale -> empty';
  raise notice 'PASS test_best_price_stale_ignored';
end $$;

-- test_quote_uses_fresh_price: estimate_quote korzysta z best_price, a nie z najtańszej ceny w ogóle
do $$
declare v_o uuid; v_q jsonb;
begin
  -- M1: stara tania cena u B (31 dni) i świeża droga u A; wycena ma użyć świeżej
  insert into supplier_prices (supplier_id, material_id, price, updated_at) values
    ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000b1', 1, now() - interval '31 days');
  v_o := pg_temp.new_order('inv-7');
  v_q := (select quote from orders where id = v_o);
  assert (v_q->>'materials_cost')::numeric = 60.00, 'materials_cost: ' || (v_q->>'materials_cost');
  raise notice 'PASS test_quote_uses_fresh_price';
end $$;

-- test_low_stock_view: materiał poniżej minimum widać z najlepszym dostawcą, a powyżej minimum nie
do $$
declare r record;
begin
  update materials set stock = 20, reserved = 0, min_stock = 5 where id = '00000000-0000-0000-0000-0000000000b1';
  assert not exists (select 1 from low_stock where material_id = '00000000-0000-0000-0000-0000000000b1'), 'above min hidden';

  update materials set stock = 8, reserved = 5, min_stock = 5 where id = '00000000-0000-0000-0000-0000000000b1';
  select * into r from low_stock where material_id = '00000000-0000-0000-0000-0000000000b1';
  assert r.available = 3, 'available: ' || coalesce(r.available::text, 'null');
  assert r.best_supplier = 'Test Hurt A', 'supplier: ' || coalesce(r.best_supplier, 'null');
  assert r.best_price = 10, 'price';

  -- brak aktualnej ceny: materiał nadal na liście, ale bez dostawcy
  update supplier_prices set updated_at = now() - interval '40 days'
    where material_id = '00000000-0000-0000-0000-0000000000b1';
  select * into r from low_stock where material_id = '00000000-0000-0000-0000-0000000000b1';
  assert r.best_supplier is null and r.best_price is null, 'unpriced still listed';
  raise notice 'PASS test_low_stock_view';
end $$;

-- test_inventory_not_public: widok i funkcje magazynu niedostępne dla anon/authenticated
do $$
declare v_fn text;
begin
  foreach v_fn in array array['create_task(uuid,text)', 'complete_task(uuid)', 'best_price(uuid)'] loop
    assert not has_function_privilege('anon', v_fn, 'execute'), 'anon can execute ' || v_fn;
    assert not has_function_privilege('authenticated', v_fn, 'execute'), 'authenticated can execute ' || v_fn;
    assert has_function_privilege('service_role', v_fn, 'execute'), 'service_role cannot execute ' || v_fn;
  end loop;
  assert not has_table_privilege('anon', 'low_stock', 'select'), 'anon can select low_stock';
  assert not has_table_privilege('authenticated', 'low_stock', 'select'), 'authenticated can select low_stock';
  assert has_table_privilege('service_role', 'low_stock', 'select'), 'service_role cannot select low_stock';
  raise notice 'PASS test_inventory_not_public';
end $$;

rollback;
