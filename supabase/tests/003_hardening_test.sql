-- Poprawki po recenzji Codex (Task 1–2): walidacja wejścia, blokada ponownej wyceny,
-- spójność zaokrągleń. Każdy test odtwarza scenariusz z recenzji.
begin;

insert into settings (key, value) values ('labor_rate', 120), ('margin', 0.25), ('waste', 0.15)
on conflict (key) do update set value = excluded.value;

insert into suppliers (id, name, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'Test Hurt', 'a@example.com');
insert into materials (id, name, unit, stock, reserved, min_stock) values
  ('00000000-0000-0000-0000-0000000000b1', 'Test M1', 'm2', 100, 0, 1);
insert into supplier_prices (supplier_id, material_id, price, updated_at) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1', 100, now());
insert into products (id, name, base_price, labor_hours) values
  ('00000000-0000-0000-0000-0000000000c1', 'Test P1', 0, 1),
  ('00000000-0000-0000-0000-0000000000c2', 'Test bez BOM', 2400, 3),
  ('00000000-0000-0000-0000-0000000000c3', 'Test bez robocizny', 0, 0);
insert into product_materials (product_id, material_id, qty) values
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b1', 6),
  ('00000000-0000-0000-0000-0000000000c3', '00000000-0000-0000-0000-0000000000b1', 1);

create function pg_temp.spec(p_w jsonb, p_h jsonb, p_d jsonb) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('qty', 1, 'custom_spec', jsonb_build_object(
    'width_cm', p_w, 'height_cm', p_h, 'depth_cm', p_d,
    'material_id', '00000000-0000-0000-0000-0000000000b1')))
$$;

create function pg_temp.prod(p_id text, p_qty jsonb) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('product_id', p_id, 'qty', p_qty))
$$;

create function pg_temp.new_order(p_ext text) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  v_id := upsert_order(jsonb_build_object(
    'external_id', p_ext, 'source', 'form', 'customer_email', 'k@example.com', 'kind', 'catalog',
    'items', pg_temp.prod('00000000-0000-0000-0000-0000000000c1', to_jsonb(1))));
  perform estimate_quote(v_id);
  return v_id;
end $$;

-- test_requote_after_task_blocked: ponowna wycena po zleceniu nie otwiera drogi do drugiego zadania
do $$
declare v_o uuid;
begin
  v_o := pg_temp.new_order('h-1');
  perform create_task(v_o, 'Jan');
  begin
    perform estimate_quote(v_o);
    assert false, 'estimate_quote should have raised';
  exception when others then
    assert sqlerrm = 'ORDER_LOCKED:in_progress', 'wrong error: ' || sqlerrm;
  end;
  assert (select status from orders where id = v_o) = 'in_progress', 'status unchanged';
  assert (select count(*) from tasks where order_id = v_o) = 1, 'one task';
  assert (select reserved from materials where id = '00000000-0000-0000-0000-0000000000b1') = 6, 'reserved 6';
  raise notice 'PASS test_requote_after_task_blocked';
end $$;

-- test_one_open_task_db_level: nawet bezpośredni INSERT nie utworzy drugiego otwartego zadania
do $$
declare v_o uuid;
begin
  v_o := (select order_id from tasks limit 1);
  begin
    insert into tasks (order_id, assignee) values (v_o, 'Anna');
    assert false, 'should have raised';
  exception when unique_violation then
    null;
  end;
  raise notice 'PASS test_one_open_task_db_level';
end $$;

-- test_intake_status_whitelist: przy przyjęciu zamówienia nie da się ustawić statusu 'quoted'
do $$
begin
  begin
    perform upsert_order(jsonb_build_object(
      'external_id', 'h-2', 'source', 'form', 'customer_email', 'a@b.c', 'kind', 'catalog',
      'status', 'quoted', 'items', '[]'::jsonb));
    assert false, 'should have raised';
  exception when others then
    assert sqlerrm like 'INVALID_STATUS%', 'wrong error: ' || sqlerrm;
  end;
  raise notice 'PASS test_intake_status_whitelist';
end $$;

-- test_empty_order_cannot_be_tasked: zamówienie bez pozycji i wyceny nie przejdzie do realizacji
do $$
declare v_o uuid; v_q jsonb;
begin
  v_o := upsert_order(jsonb_build_object(
    'external_id', 'h-3', 'source', 'form', 'customer_email', 'a@b.c', 'kind', 'catalog', 'items', '[]'::jsonb));
  v_q := estimate_quote(v_o);
  assert v_q->>'error' = 'NO_ITEMS', 'error: ' || v_q::text;
  assert (select status from orders where id = v_o) = 'needs_review', 'needs_review';
  begin
    perform create_task(v_o, 'Jan');
    assert false, 'should have raised';
  exception when others then
    assert sqlerrm = 'ORDER_NOT_READY:needs_review', 'wrong error: ' || sqlerrm;
  end;

  -- status ustawiony ręcznie na quoted, ale bez wyceny
  update orders set status = 'quoted' where id = v_o;
  begin
    perform create_task(v_o, 'Jan');
    assert false, 'should have raised';
  exception when others then
    assert sqlerrm = 'ORDER_NOT_QUOTED', 'wrong error: ' || sqlerrm;
  end;
  raise notice 'PASS test_empty_order_cannot_be_tasked';
end $$;

-- test_invalid_custom_spec: null, zero, ujemne, poza zakresem 20–300 cm i tekst dają INVALID_SPEC
do $$
declare v_case jsonb; v_q jsonb;
begin
  for v_case in select * from jsonb_array_elements('[
      [null, 80, 40], [0, 80, 40], [-1000, 100, 100], [19, 80, 40], [301, 80, 40],
      [100, "abc", 40], [100, 80, null]
    ]'::jsonb)
  loop
    v_q := _quote_lines(pg_temp.spec(v_case->0, v_case->1, v_case->2));
    assert v_q->>'error' = 'INVALID_SPEC', 'case ' || v_case::text || ' -> ' || v_q::text;
  end loop;

  -- granice są dozwolone
  v_q := _quote_lines(pg_temp.spec(to_jsonb(20), to_jsonb(300), to_jsonb(20)));
  assert not (v_q ? 'error'), 'boundaries allowed: ' || v_q::text;
  assert (v_q->>'total') is not null, 'total not null';

  -- brakujący klucz
  v_q := _quote_lines(jsonb_build_array(jsonb_build_object('qty', 1, 'custom_spec', jsonb_build_object(
    'width_cm', 100, 'height_cm', 80, 'material_id', '00000000-0000-0000-0000-0000000000b1'))));
  assert v_q->>'error' = 'INVALID_SPEC', 'missing depth: ' || v_q::text;
  raise notice 'PASS test_invalid_custom_spec';
end $$;

-- test_invalid_qty: 0, ujemna, ułamkowa i tekstowa ilość są odrzucane także w kalkulatorze
do $$
declare v_qty jsonb; v_q jsonb;
begin
  foreach v_qty in array array['0'::jsonb, '-1'::jsonb, '1.5'::jsonb, '"2"'::jsonb, 'null'::jsonb] loop
    v_q := _quote_lines(pg_temp.prod('00000000-0000-0000-0000-0000000000c1', v_qty));
    assert v_q->>'error' = 'INVALID_QTY', 'qty ' || v_qty::text || ' -> ' || v_q::text;
  end loop;
  raise notice 'PASS test_invalid_qty';
end $$;

-- test_incomplete_product: produkt bez BOM albo bez robocizny nie dostaje wyceny 0 zł
do $$
declare v_q jsonb;
begin
  v_q := _quote_lines(pg_temp.prod('00000000-0000-0000-0000-0000000000c2', to_jsonb(1)));
  assert v_q->>'error' = 'INCOMPLETE_PRODUCT', 'no bom: ' || v_q::text;
  v_q := _quote_lines(pg_temp.prod('00000000-0000-0000-0000-0000000000c3', to_jsonb(1)));
  assert v_q->>'error' = 'INCOMPLETE_PRODUCT', 'no labor: ' || v_q::text;
  raise notice 'PASS test_incomplete_product';
end $$;

-- test_settings_validated: ujemna marża jest niemożliwa, brak stawki przerywa wycenę
do $$
declare v_q jsonb;
begin
  begin
    update settings set value = -1 where key = 'margin';
    assert false, 'negative setting accepted';
  exception when check_violation then
    null;
  end;
  delete from settings where key = 'labor_rate';
  begin
    v_q := _quote_lines(pg_temp.prod('00000000-0000-0000-0000-0000000000c1', to_jsonb(1)));
    assert false, 'should have raised, got ' || v_q::text;
  exception when others then
    assert sqlerrm = 'MISSING_SETTING:labor_rate', 'wrong error: ' || sqlerrm;
  end;
  insert into settings (key, value) values ('labor_rate', 120);
  raise notice 'PASS test_settings_validated';
end $$;

-- test_json_null_custom_spec: jawny null w custom_spec nie psuje pozycji katalogowej
do $$
declare v_o uuid;
begin
  v_o := upsert_order(jsonb_build_object(
    'external_id', 'h-4', 'source', 'form', 'customer_email', 'a@b.c', 'kind', 'catalog',
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', '00000000-0000-0000-0000-0000000000c1', 'custom_spec', null, 'qty', 1))));
  assert (select count(*) from order_items where order_id = v_o) = 1, 'item stored';
  assert (select custom_spec from order_items where order_id = v_o) is null, 'custom_spec is SQL null';
  raise notice 'PASS test_json_null_custom_spec';
end $$;

-- test_quote_parts_sum_to_total: rozbicie kosztów sumuje się co do grosza do total
do $$
declare v_q jsonb; v_l jsonb;
begin
  -- przypadek z recenzji: 5×80×40,1 cm przy cenie 100 (poza zakresem 20–300, więc 20×80×40,1)
  v_q := _quote_lines(pg_temp.spec(to_jsonb(20), to_jsonb(80), to_jsonb(40.1)));
  assert (v_q->>'materials_cost')::numeric + (v_q->>'labor_cost')::numeric + (v_q->>'margin')::numeric
         = (v_q->>'total')::numeric, 'parts do not sum: ' || v_q::text;

  -- dwie sztuki: nagłówek to suma zaokrąglonych linii
  v_q := _quote_lines(jsonb_build_array(
    jsonb_build_object('qty', 1, 'custom_spec', jsonb_build_object('width_cm', 20, 'height_cm', 80,
      'depth_cm', 40.1, 'material_id', '00000000-0000-0000-0000-0000000000b1')),
    jsonb_build_object('qty', 1, 'custom_spec', jsonb_build_object('width_cm', 20, 'height_cm', 80,
      'depth_cm', 40.1, 'material_id', '00000000-0000-0000-0000-0000000000b1'))));
  assert (v_q->>'materials_cost')::numeric =
         (select sum((l->>'materials_cost')::numeric) from jsonb_array_elements(v_q->'lines') l),
         'header materials != sum of lines: ' || v_q::text;
  assert (v_q->>'labor_cost')::numeric =
         (select sum((l->>'labor_cost')::numeric) from jsonb_array_elements(v_q->'lines') l),
         'header labor != sum of lines';
  assert (v_q->>'materials_cost')::numeric + (v_q->>'labor_cost')::numeric + (v_q->>'margin')::numeric
         = (v_q->>'total')::numeric, 'parts do not sum (2 lines)';
  raise notice 'PASS test_quote_parts_sum_to_total';
end $$;

rollback;
