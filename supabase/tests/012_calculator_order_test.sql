-- Poprawki po recenzji Task 5: publiczna wycena bez kosztów, materiały na wymiar, zamówienia z kalkulatora.
begin;

insert into settings (key, value) values ('labor_rate', 120), ('margin', 0.25), ('waste', 0.15)
on conflict (key) do update set value = excluded.value;
insert into suppliers (id, name, email) values ('00000000-0000-0000-0000-0000000000a1', 'Test Hurt', 'a@example.com');
insert into materials (id, name, unit, stock, reserved, min_stock, custom_ok) values
  ('00000000-0000-0000-0000-0000000000b1', 'Test płyta', 'm2', 100, 0, 2, true),
  ('00000000-0000-0000-0000-0000000000b2', 'Test zawias', 'szt', 100, 0, 2, false);
insert into supplier_prices (supplier_id, material_id, price, updated_at) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1', 10.01, now()),
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b2', 3, now());
insert into products (id, name, base_price, labor_hours) values
  ('00000000-0000-0000-0000-0000000000c1', 'Test P1', 0, 1),
  ('00000000-0000-0000-0000-0000000000c2', 'Test P2', 0, 3);
insert into product_materials (product_id, material_id, qty) values
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b1', 3),
  ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000b1', 7);

-- test_preview_public_format: tylko ceny sprzedaży, suma pozycji = suma wyceny (także przy groszach)
do $$
declare v_p jsonb; v_sum numeric;
begin
  v_p := quote_preview('{"items":[
     {"product_id":"00000000-0000-0000-0000-0000000000c1","qty":3},
     {"product_id":"00000000-0000-0000-0000-0000000000c2","qty":7},
     {"custom_spec":{"width_cm":33,"height_cm":77,"depth_cm":29,"material_id":"00000000-0000-0000-0000-0000000000b1"},"qty":5}]}');
  assert not (v_p ? 'error'), v_p::text;
  assert not (v_p::text ~ '(materials_cost|labor_cost|margin)'), 'no internal costs';
  select sum((l->>'price')::numeric) into v_sum from jsonb_array_elements(v_p->'lines') l;
  assert v_sum = (v_p->>'total')::numeric, format('sum %s vs total %s', v_sum, v_p->>'total');
  assert jsonb_array_length(v_p->'lines') = 3, 'three lines';
  assert (select bool_and((l->>'price')::numeric > 0) from jsonb_array_elements(v_p->'lines') l), 'positive prices';
  raise notice 'PASS test_preview_public_format';
end $$;

-- test_custom_material_must_be_sheet
do $$
begin
  assert quote_preview('{"items":[{"custom_spec":{"width_cm":100,"height_cm":80,"depth_cm":40,"material_id":"00000000-0000-0000-0000-0000000000b2"}}]}')
         ->> 'error' = 'MATERIAL_NOT_ALLOWED', 'zawias not allowed for custom';
  assert quote_preview('{"items":[{"custom_spec":{"width_cm":100,"height_cm":80,"depth_cm":40,"material_id":"00000000-0000-0000-0000-00000000ffff"}}]}')
         ->> 'error' = 'UNKNOWN_MATERIAL', 'unknown material';
  assert not exists (select 1 from jsonb_array_elements(catalog_for_calculator()->'materials') x where x->>'name' = 'Test zawias'),
         'zawias hidden in catalog';
  assert exists (select 1 from jsonb_array_elements(catalog_for_calculator()->'materials') x where x->>'name' = 'Test płyta'),
         'plyta listed';
  raise notice 'PASS test_custom_material_must_be_sheet';
end $$;

-- test_calculator_order_mixed_and_idempotent
do $$
declare v_r jsonb; v_r2 jsonb; v_o uuid; v_items jsonb; v_prev jsonb; v_count int;
begin
  v_items := '[{"product_id":"00000000-0000-0000-0000-0000000000c1","qty":2},
               {"custom_spec":{"width_cm":100,"height_cm":80,"depth_cm":40,"material_id":"00000000-0000-0000-0000-0000000000b1"},"qty":1}]';
  v_r := calculator_order(jsonb_build_object('external_id','calc-t1','customer_email','k@example.com','items',v_items,'notes','<b>uwaga</b>'));
  assert (v_r->>'created')::boolean, v_r::text;
  assert v_r->>'status' = 'quoted', 'quoted';
  v_o := (v_r->>'order_id')::uuid;
  assert (select kind from orders where id = v_o) = 'custom', 'mixed order is custom';
  assert (select count(*) from order_items where order_id = v_o) = 2, 'both items stored';
  assert (select count(*) from order_items where order_id = v_o and product_id is not null) = 1, 'one catalog item';
  assert (select count(*) from order_items where order_id = v_o and custom_spec is not null) = 1, 'one custom item';
  v_prev := quote_preview(jsonb_build_object('items', v_items));
  assert (select quote->>'total' from orders where id = v_o) = v_prev->>'total', 'stored total equals preview total';
  assert (select raw_text from orders where id = v_o) like '%<b>uwaga</b>%', 'notes kept as plain text';
  assert (select parsed->>'source' from orders where id = v_o) = 'calculator', 'source marked';

  v_r2 := calculator_order(jsonb_build_object('external_id','calc-t1','customer_email','k@example.com','items',v_items));
  assert not (v_r2->>'created')::boolean, 'retry is not created';
  assert v_r2->>'order_id' = v_r->>'order_id', 'same order';
  select count(*) into v_count from orders where external_id = 'calc-t1';
  assert v_count = 1, 'one order';
  assert (select count(*) from order_items where order_id = v_o) = 2, 'items not duplicated';
  raise notice 'PASS test_calculator_order_mixed_and_idempotent';
end $$;

-- test_calculator_order_rejects_bad_input
do $$
declare v_ok jsonb := '[{"product_id":"00000000-0000-0000-0000-0000000000c1","qty":1}]';
begin
  assert calculator_order(null) ->> 'error' = 'INVALID_INPUT', 'null';
  assert calculator_order(jsonb_build_object('customer_email','k@example.com','items',v_ok)) ->> 'error' = 'INVALID_EXTERNAL_ID', 'no id';
  assert calculator_order(jsonb_build_object('external_id','bad id!','customer_email','k@example.com','items',v_ok)) ->> 'error' = 'INVALID_EXTERNAL_ID', 'bad id';
  assert calculator_order(jsonb_build_object('external_id','calc-t2','customer_email','nie-email','items',v_ok)) ->> 'error' = 'INVALID_EMAIL', 'bad email';
  assert calculator_order(jsonb_build_object('external_id','calc-t2','customer_email','k@example.com','items','[]'::jsonb)) ->> 'error' = 'NO_ITEMS', 'no items';
  assert calculator_order(jsonb_build_object('external_id','calc-t2','customer_email','k@example.com',
           'items','[{"product_id":"00000000-0000-0000-0000-0000000000c1","qty":0}]'::jsonb)) ->> 'error' = 'INVALID_QTY', 'qty';
  assert calculator_order(jsonb_build_object('external_id','calc-t2','customer_email','k@example.com',
           'items','[{"custom_spec":{"width_cm":100,"height_cm":80,"depth_cm":40,"material_id":"00000000-0000-0000-0000-0000000000b2"}}]'::jsonb))
         ->> 'error' = 'MATERIAL_NOT_ALLOWED', 'material';
  assert not exists (select 1 from orders where external_id = 'calc-t2'), 'nothing saved on error';
  raise notice 'PASS test_calculator_order_rejects_bad_input';
end $$;

-- test_bestsellers_unpriced_is_null_not_zero: cena wygasa, ilość zostaje, przychód jest nieznany
do $$
declare v_r jsonb; v_rev numeric;
begin
  v_r := calculator_order(jsonb_build_object('external_id','calc-t3','customer_email','k@example.com',
           'items','[{"product_id":"00000000-0000-0000-0000-0000000000c2","qty":2}]'::jsonb));
  update orders set status = 'approved' where id = (v_r->>'order_id')::uuid;
  select revenue into v_rev from bestsellers(7) where name = 'Test P2';
  assert v_rev > 0, 'revenue known while priced';
  delete from supplier_prices where material_id = '00000000-0000-0000-0000-0000000000b1';
  assert (select qty from bestsellers(7) where name = 'Test P2') = 2, 'qty kept';
  assert (select revenue from bestsellers(7) where name = 'Test P2') is null, 'revenue unknown, not zero';
  raise notice 'PASS test_bestsellers_unpriced_is_null_not_zero';
end $$;

rollback;
