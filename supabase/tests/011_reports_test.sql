-- Task 5: quote_preview, catalog_for_calculator, bestsellers.
begin;

insert into settings (key, value) values ('labor_rate', 120), ('margin', 0.25), ('waste', 0.15)
on conflict (key) do update set value = excluded.value;
insert into suppliers (id, name, email) values ('00000000-0000-0000-0000-0000000000a1', 'Test Hurt', 'a@example.com');
insert into materials (id, name, unit, stock, reserved, min_stock) values
  ('00000000-0000-0000-0000-0000000000b1', 'Test M1', 'm2', 100, 0, 2),
  ('00000000-0000-0000-0000-0000000000b2', 'Test bez ceny', 'szt', 100, 0, 2);
update materials set custom_ok = true where id = '00000000-0000-0000-0000-0000000000b1';
insert into supplier_prices (supplier_id, material_id, price, updated_at) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1', 10, now());
insert into products (id, name, base_price, labor_hours) values
  ('00000000-0000-0000-0000-0000000000c1', 'Test P1', 0, 1),
  ('00000000-0000-0000-0000-0000000000c2', 'Test P2', 0, 2),
  ('00000000-0000-0000-0000-0000000000c3', 'Test P3 bez ceny', 0, 1);
insert into product_materials (product_id, material_id, qty) values
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b1', 6),
  ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000b1', 3),
  ('00000000-0000-0000-0000-0000000000c3', '00000000-0000-0000-0000-0000000000b2', 1);

create function pg_temp.order_with(p_ext text, p_items jsonb, p_status text) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  v_id := upsert_order(jsonb_build_object('external_id', p_ext, 'source', 'form',
    'customer_email', 'k@example.com', 'kind', 'catalog', 'items', p_items));
  perform estimate_quote(v_id);
  update orders set status = p_status where id = v_id;
  return v_id;
end $$;

-- test_preview_matches_estimate
do $$
declare v_o uuid; v_items jsonb; v_est jsonb; v_prev jsonb;
begin
  v_items := jsonb_build_array(
    jsonb_build_object('product_id', '00000000-0000-0000-0000-0000000000c1', 'qty', 2),
    jsonb_build_object('custom_spec', jsonb_build_object('width_cm', 100, 'height_cm', 80, 'depth_cm', 40,
                       'material_id', '00000000-0000-0000-0000-0000000000b1'), 'qty', 1));
  v_o := pg_temp.order_with('rp-1', v_items, 'quoted');
  v_est := (select quote from orders where id = v_o);
  v_prev := quote_preview(jsonb_build_object('items', v_items));
  assert v_prev ->> 'total' = v_est ->> 'total', format('total %s vs %s', v_prev ->> 'total', v_est ->> 'total');
  assert v_prev ->> 'total' = v_est ->> 'total', 'preview total equals stored quote total';
  raise notice 'PASS test_preview_matches_estimate';
end $$;

-- test_preview_does_not_write
do $$
declare v_before bigint; v_after bigint; v_items_before bigint;
begin
  select count(*) into v_before from orders; select count(*) into v_items_before from order_items;
  perform quote_preview(jsonb_build_object('items', jsonb_build_array(
    jsonb_build_object('product_id', '00000000-0000-0000-0000-0000000000c1', 'qty', 1))));
  select count(*) into v_after from orders;
  assert v_before = v_after, 'orders unchanged';
  assert v_items_before = (select count(*) from order_items), 'order_items unchanged';
  raise notice 'PASS test_preview_does_not_write';
end $$;

-- test_preview_rejects_bad_input
do $$
begin
  assert quote_preview(null) ->> 'error' = 'NO_ITEMS', 'null';
  assert quote_preview('{}') ->> 'error' = 'NO_ITEMS', 'no items key';
  assert quote_preview('{"items":[]}') ->> 'error' = 'NO_ITEMS', 'empty';
  assert quote_preview('{"items":"x"}') ->> 'error' = 'NO_ITEMS', 'not array';
  assert quote_preview('[1]') ->> 'error' = 'NO_ITEMS', 'array root';
  assert quote_preview(jsonb_build_object('items', (select jsonb_agg('{}'::jsonb) from generate_series(1, 21))))
         ->> 'error' = 'TOO_MANY_ITEMS', 'limit 20';
  assert quote_preview('{"items":[{"product_id":"00000000-0000-0000-0000-0000000000c1","qty":0}]}') ->> 'error' = 'INVALID_QTY', 'qty 0';
  assert quote_preview('{"items":[{"custom_spec":{"width_cm":10,"height_cm":80,"depth_cm":40,"material_id":"00000000-0000-0000-0000-0000000000b1"}}]}')
         ->> 'error' = 'INVALID_SPEC', 'width below 20';
  assert quote_preview('{"items":[{"custom_spec":{"width_cm":301,"height_cm":80,"depth_cm":40,"material_id":"00000000-0000-0000-0000-0000000000b1"}}]}')
         ->> 'error' = 'INVALID_SPEC', 'width above 300';
  assert quote_preview('{"items":[{"product_id":"00000000-0000-0000-0000-0000000000c3"}]}') ->> 'error' = 'NO_PRICE', 'no price';
  assert quote_preview('{"items":[{"product_id":"nie-uuid"}]}') ->> 'error' = 'INVALID_ITEM', 'bad uuid';
  raise notice 'PASS test_preview_rejects_bad_input';
end $$;

-- test_calculator_catalog_hides_unpriced_and_internals
do $$
declare v_c jsonb;
begin
  v_c := catalog_for_calculator();
  assert exists (select 1 from jsonb_array_elements(v_c -> 'products') x where x ->> 'name' = 'Test P1'), 'priced product listed';
  assert not exists (select 1 from jsonb_array_elements(v_c -> 'products') x where x ->> 'name' = 'Test P3 bez ceny'), 'unpriced product hidden';
  assert not exists (select 1 from jsonb_array_elements(v_c -> 'materials') x where x ->> 'name' = 'Test bez ceny'), 'unpriced material hidden';
  assert not (v_c::text ~ '(stock|price|supplier)'), 'no stock or price fields';
  raise notice 'PASS test_calculator_catalog_hides_unpriced_and_internals';
end $$;

-- test_bestsellers_order: liczą się tylko zamówienia zatwierdzone, w oknie czasowym; custom = "Na wymiar"
do $$
declare v_old uuid; r record; v_n int := 0;
begin
  perform pg_temp.order_with('rp-b1', '[{"product_id":"00000000-0000-0000-0000-0000000000c2","qty":3}]', 'approved');
  perform pg_temp.order_with('rp-b2', '[{"product_id":"00000000-0000-0000-0000-0000000000c1","qty":1}]', 'done');
  perform pg_temp.order_with('rp-b3', '[{"product_id":"00000000-0000-0000-0000-0000000000c1","qty":1}]', 'quoted');
  perform pg_temp.order_with('rp-b4', '[{"custom_spec":{"width_cm":100,"height_cm":80,"depth_cm":40,"material_id":"00000000-0000-0000-0000-0000000000b1"},"qty":2}]', 'in_progress');
  v_old := pg_temp.order_with('rp-b5', '[{"product_id":"00000000-0000-0000-0000-0000000000c1","qty":50}]', 'done');
  update orders set created_at = now() - interval '20 days' where id = v_old;
  -- rp-1 z pierwszego testu (quoted) też się nie liczy

  for r in select * from bestsellers(7) where name like 'Test %' or name = 'Na wymiar' loop
    v_n := v_n + 1;
    if v_n = 1 then assert r.name = 'Test P2' and r.qty = 3 and r.revenue > 0, format('first %s %s', r.name, r.qty); end if;
  end loop;
  assert (select qty from bestsellers(7) where name = 'Test P1') = 1, 'quoted and old orders not counted in 7 days';
  assert (select qty from bestsellers(7) where name = 'Na wymiar') = 2, 'custom grouped';
  assert (select qty from bestsellers(30) where name = 'Test P1') = 51, '30 days includes the old order';
  assert (select count(*) from bestsellers(7) where name = 'Test P1') = 1, 'one row per product';
  assert (select max(qty) from bestsellers(7)) >= 3, 'sorted';
  assert (select name from bestsellers(7) limit 1) = (select name from bestsellers(7) order by qty desc, revenue desc limit 1), 'sorted desc';
  assert jsonb_typeof(weekly_report() -> 'week') = 'array' and jsonb_typeof(weekly_report() -> 'month') = 'array', 'weekly_report shape';
  raise notice 'PASS test_bestsellers_order';
end $$;

-- test_weekly_report_kind_allowed
do $$
begin
  perform enqueue_slack('weekly_report', 'raport', 'wr-test-1');
  assert exists (select 1 from slack_outbox where dedupe_key = 'wr-test-1' and kind = 'weekly_report'), 'queued';
  raise notice 'PASS test_weekly_report_kind_allowed';
end $$;

rollback;
