-- Task 1: wycena i idempotencja zamówień.
-- Każdy test tworzy własne dane w transakcji, która na końcu jest wycofywana,
-- więc seed nie wpływa na wynik.
begin;

-- Stawki z Global Constraints, ustawione jawnie, żeby testy nie zależały od seeda.
insert into settings (key, value) values ('labor_rate', 120), ('margin', 0.25), ('waste', 0.15)
on conflict (key) do update set value = excluded.value;

-- Stałe dane testowe: płyta po 100 PLN, produkt z BOM 2 m² i 3 h robocizny.
insert into suppliers (id, name, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'Test Hurt', 'test@example.com');
insert into materials (id, name, unit, stock, reserved, min_stock) values
  ('00000000-0000-0000-0000-0000000000b1', 'Test płyta', 'm2', 100, 0, 10);
insert into supplier_prices (supplier_id, material_id, price, updated_at) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1', 100, now());
insert into products (id, name, base_price, labor_hours) values
  ('00000000-0000-0000-0000-0000000000c1', 'Test szafka', 0, 3);
insert into product_materials (product_id, material_id, qty) values
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b1', 2);

-- test_catalog_quote: materiały 200 + robocizna 360 = 560, marża 25% = 140, razem 700.00
do $$
declare
  v_id uuid;
  v_q jsonb;
begin
  v_id := upsert_order(jsonb_build_object(
    'external_id', 'test-catalog-1',
    'source', 'form',
    'customer_email', 'klient@example.com',
    'kind', 'catalog',
    'raw_text', 'Szafka x1',
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', '00000000-0000-0000-0000-0000000000c1', 'qty', 1))));
  v_q := estimate_quote(v_id);
  assert (v_q->>'materials_cost')::numeric = 200.00, 'materials_cost: ' || (v_q->>'materials_cost');
  assert (v_q->>'labor_cost')::numeric = 360.00, 'labor_cost: ' || (v_q->>'labor_cost');
  assert (v_q->>'margin')::numeric = 140.00, 'margin: ' || (v_q->>'margin');
  assert (v_q->>'total')::numeric = 700.00, 'total: ' || (v_q->>'total');
  assert jsonb_array_length(v_q->'lines') = 1, 'lines';
  assert (select status from orders where id = v_id) = 'quoted', 'status quoted';
  assert (select quoted_at from orders where id = v_id) is not null, 'quoted_at set';
  assert (select quote->>'total' from orders where id = v_id)::numeric = 700.00, 'quote stored';
  raise notice 'PASS test_catalog_quote';
end $$;

-- test_catalog_quote_qty: ilość 2 podwaja wycenę
do $$
declare v_id uuid; v_q jsonb;
begin
  v_id := upsert_order(jsonb_build_object(
    'external_id', 'test-catalog-2', 'source', 'form', 'customer_email', 'k@example.com',
    'kind', 'catalog',
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', '00000000-0000-0000-0000-0000000000c1', 'qty', 2))));
  v_q := estimate_quote(v_id);
  assert (v_q->>'total')::numeric = 1400.00, 'total: ' || (v_q->>'total');
  raise notice 'PASS test_catalog_quote_qty';
end $$;

-- test_custom_quote: 100x80x40 cm
--   m² = (2*100*40 + 2*80*40 + 100*80)/10000 * 1.15 = 2.576
--   materiały 2.576 * 100 = 257.60, robocizna (4 + 2*2.576) * 120 = 1098.24
--   marża 0.25 * 1355.84 = 338.96, razem 1694.80
do $$
declare v_id uuid; v_q jsonb;
begin
  v_id := upsert_order(jsonb_build_object(
    'external_id', 'test-custom-1', 'source', 'email', 'customer_email', 'k@example.com',
    'kind', 'custom',
    'items', jsonb_build_array(jsonb_build_object(
      'custom_spec', jsonb_build_object(
        'width_cm', 100, 'height_cm', 80, 'depth_cm', 40,
        'material_id', '00000000-0000-0000-0000-0000000000b1'),
      'qty', 1))));
  v_q := estimate_quote(v_id);
  assert abs((v_q->>'materials_cost')::numeric - 257.60) < 0.01, 'materials_cost: ' || (v_q->>'materials_cost');
  assert abs((v_q->>'labor_cost')::numeric - 1098.24) < 0.01, 'labor_cost: ' || (v_q->>'labor_cost');
  assert abs((v_q->>'total')::numeric - 1694.80) < 0.01, 'total: ' || (v_q->>'total');
  raise notice 'PASS test_custom_quote';
end $$;

-- test_external_id_idempotent: ten sam external_id nie tworzy drugiego zamówienia
do $$
declare v_a uuid; v_b uuid; v_p jsonb;
begin
  v_p := jsonb_build_object(
    'external_id', 'test-dup-1', 'source', 'email', 'customer_email', 'k@example.com',
    'kind', 'catalog',
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', '00000000-0000-0000-0000-0000000000c1', 'qty', 1)));
  v_a := upsert_order(v_p);
  v_b := upsert_order(v_p);
  assert v_a = v_b, 'same id';
  assert (select count(*) from orders where external_id = 'test-dup-1') = 1, 'one order';
  assert (select count(*) from order_items where order_id = v_a) = 1, 'one item';
  raise notice 'PASS test_external_id_idempotent';
end $$;

-- test_no_price_needs_review: materiał bez ceny daje needs_review, a nie wycenę 0 zł
do $$
declare v_id uuid; v_q jsonb;
begin
  insert into materials (id, name, unit, stock, reserved, min_stock) values
    ('00000000-0000-0000-0000-0000000000b2', 'Test bez ceny', 'm2', 10, 0, 1);
  v_id := upsert_order(jsonb_build_object(
    'external_id', 'test-noprice-1', 'source', 'form', 'customer_email', 'k@example.com',
    'kind', 'custom',
    'items', jsonb_build_array(jsonb_build_object(
      'custom_spec', jsonb_build_object(
        'width_cm', 50, 'height_cm', 50, 'depth_cm', 50,
        'material_id', '00000000-0000-0000-0000-0000000000b2'),
      'qty', 1))));
  v_q := estimate_quote(v_id);
  assert v_q->>'error' = 'NO_PRICE', 'error: ' || coalesce(v_q::text, 'null');
  assert (select status from orders where id = v_id) = 'needs_review', 'status needs_review';
  raise notice 'PASS test_no_price_needs_review';
end $$;

-- test_anon_cannot_execute: publiczny klucz API nie może tworzyć ani wyceniać zamówień
do $$
declare v_fn text;
begin
  foreach v_fn in array array['upsert_order(jsonb)', 'estimate_quote(uuid)', '_quote_lines(jsonb)'] loop
    assert not has_function_privilege('anon', v_fn, 'execute'), 'anon can execute ' || v_fn;
    assert not has_function_privilege('authenticated', v_fn, 'execute'), 'authenticated can execute ' || v_fn;
    assert has_function_privilege('service_role', v_fn, 'execute'), 'service_role cannot execute ' || v_fn;
  end loop;
  raise notice 'PASS test_anon_cannot_execute';
end $$;

rollback;
