-- Task 12: zamówienia z salonów (showroom_order, showroom_info) i naprawa powiadomień.
begin;

insert into settings (key, value) values ('labor_rate', 120), ('margin', 0.25), ('waste', 0.15)
on conflict (key) do update set value = excluded.value;
insert into suppliers (id, name, email) values ('00000000-0000-0000-0000-0000000000a1', 'Test Hurt', 'a@example.com');
insert into materials (id, name, unit, stock, reserved, min_stock, custom_ok) values
  ('00000000-0000-0000-0000-0000000000b1', 'Test płyta', 'm2', 100, 0, 2, true);
insert into supplier_prices (supplier_id, material_id, price, updated_at) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1', 10.01, now());
insert into products (id, name, base_price, labor_hours) values
  ('00000000-0000-0000-0000-0000000000c1', 'Test P1', 0, 1);
insert into product_materials (product_id, material_id, qty) values
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b1', 3);
insert into showrooms (code, name, salesperson_email, access_token, active) values
  ('test-salon', 'Salon Testowy', 'handlowiec.test@example.com', 'tok-test', true),
  ('test-off',   'Salon Wyłączony', 'off@example.com', 'tok-off', false);

-- test_showroom_idempotent
do $$
declare p jsonb; r1 jsonb; r2 jsonb;
begin
  p := '{"external_id":"showroom:test-salon:aaa","showroom_code":"test-salon","access_token":"tok-test","consent":true,
          "customer_name":"Jan Kowalski","customer_email":"jan@example.com",
          "items":[{"product_id":"00000000-0000-0000-0000-0000000000c1","qty":2}]}';
  r1 := showroom_order(p);
  r2 := showroom_order(p);
  assert not (r1 ? 'error'), r1::text;
  assert (r1->>'created')::boolean and r1->>'status' = 'quoted', r1::text;
  assert not (r2->>'created')::boolean and r2->>'order_id' = r1->>'order_id', r2::text;
  assert (select count(*) from orders where external_id = 'showroom:test-salon:aaa') = 1, 'one order';
  assert (select source from orders where id = (r1->>'order_id')::uuid) = 'showroom', 'source showroom';
  assert (select showroom_name from orders where id = (r1->>'order_id')::uuid) = 'Salon Testowy', 'showroom name';
  assert (select consent_at is not null from orders where id = (r1->>'order_id')::uuid), 'consent stored';
  raise notice 'PASS test_showroom_idempotent';
end $$;

-- test_showroom_unknown_code (także salon wyłączony)
do $$
declare r jsonb;
begin
  r := showroom_order('{"external_id":"showroom:test-salon:x1","showroom_code":"nie-ma","access_token":"tok-test","consent":true,
          "customer_name":"Jan","customer_email":"jan@example.com","notes":"x"}');
  assert r->>'error' = 'UNKNOWN_SHOWROOM', r::text;
  r := showroom_order('{"external_id":"showroom:test-salon:x2","showroom_code":"test-off","access_token":"tok-off","consent":true,
          "customer_name":"Jan","customer_email":"jan@example.com","notes":"x"}');
  assert r->>'error' = 'UNKNOWN_SHOWROOM', r::text;
  assert not exists (select 1 from orders where external_id like 'showroom:test-salon:x%'), 'no order created';
  raise notice 'PASS test_showroom_unknown_code';
end $$;

-- test_showroom_wrong_token_rejected
do $$
declare r jsonb;
begin
  r := showroom_order('{"external_id":"showroom:test-salon:x3","showroom_code":"test-salon","access_token":"zly","consent":true,
          "customer_name":"Jan","customer_email":"jan@example.com","notes":"x"}');
  assert r->>'error' = 'UNAUTHORIZED', r::text;
  r := showroom_order('{"external_id":"showroom:test-salon:x4","showroom_code":"test-salon","consent":true,
          "customer_name":"Jan","customer_email":"jan@example.com","notes":"x"}');
  assert r->>'error' = 'UNAUTHORIZED', 'missing token: ' || r::text;
  assert not exists (select 1 from orders where external_id in ('showroom:test-salon:x3', 'showroom:test-salon:x4')), 'no order created';
  raise notice 'PASS test_showroom_wrong_token_rejected';
end $$;

-- test_showroom_requires_consent
do $$
declare r jsonb;
begin
  r := showroom_order('{"external_id":"showroom:test-salon:x5","showroom_code":"test-salon","access_token":"tok-test",
          "customer_name":"Jan","customer_email":"jan@example.com","notes":"x"}');
  assert r->>'error' = 'NO_CONSENT', r::text;
  r := showroom_order('{"external_id":"showroom:test-salon:x5","showroom_code":"test-salon","access_token":"tok-test","consent":"true",
          "customer_name":"Jan","customer_email":"jan@example.com","notes":"x"}');
  assert r->>'error' = 'NO_CONSENT', 'string "true" is not consent: ' || r::text;
  assert not exists (select 1 from orders where external_id = 'showroom:test-salon:x5'), 'no order created';
  raise notice 'PASS test_showroom_requires_consent';
end $$;

-- test_showroom_ignores_client_salesperson
do $$
declare r jsonb;
begin
  r := showroom_order('{"external_id":"showroom:test-salon:bbb","showroom_code":"test-salon","access_token":"tok-test","consent":true,
          "customer_name":"Jan","customer_email":"jan@example.com","salesperson_email":"hacker@evil.example",
          "showroom_name":"Fałszywy salon","items":[{"product_id":"00000000-0000-0000-0000-0000000000c1","qty":1}]}');
  assert not (r ? 'error'), r::text;
  assert (select salesperson_email from orders where id = (r->>'order_id')::uuid) = 'handlowiec.test@example.com',
         'salesperson from showrooms';
  assert (select showroom_name from orders where id = (r->>'order_id')::uuid) = 'Salon Testowy', 'name from showrooms';
  raise notice 'PASS test_showroom_ignores_client_salesperson';
end $$;

-- test_showroom_lead_without_items
do $$
declare r jsonb; v_id uuid;
begin
  r := showroom_order('{"external_id":"showroom:test-salon:lead1","showroom_code":"test-salon","access_token":"tok-test",
          "consent":true,"customer_name":"Anna","customer_email":"anna@example.com","notes":"Oglądała próbki dębu, oddzwonić"}');
  assert not (r ? 'error') and r->>'status' = 'needs_review' and (r->>'created')::boolean, r::text;
  v_id := (r->>'order_id')::uuid;
  assert (select quote is null from orders where id = v_id), 'no quote for lead';
  assert (select parsed->>'source' from orders where id = v_id) = 'showroom', 'parsed source';
  assert (select count(*) from order_items where order_id = v_id) = 0, 'no items';
  r := showroom_order('{"external_id":"showroom:test-salon:lead2","showroom_code":"test-salon","access_token":"tok-test",
          "consent":true,"customer_name":"Anna","customer_email":"anna@example.com","items":[],"notes":"  "}');
  assert r->>'error' = 'EMPTY_LEAD', r::text;
  assert not exists (select 1 from orders where external_id = 'showroom:test-salon:lead2'), 'no order for empty lead';
  raise notice 'PASS test_showroom_lead_without_items';
end $$;

-- test_showroom_customer_name_sanitized
do $$
declare r jsonb; v_name text;
begin
  r := showroom_order(jsonb_build_object('external_id', 'showroom:test-salon:n1', 'showroom_code', 'test-salon',
        'access_token', 'tok-test', 'consent', true, 'customer_name', E'Jan\r\nBcc: x@y.z',
        'customer_email', 'jan@example.com', 'notes', 'x'));
  select customer_name into v_name from orders where id = (r->>'order_id')::uuid;
  assert v_name !~ '[\r\n]', 'no control chars: ' || v_name;
  r := showroom_order(jsonb_build_object('external_id', 'showroom:test-salon:n2', 'showroom_code', 'test-salon',
        'access_token', 'tok-test', 'consent', true, 'customer_name', repeat('A', 10000),
        'customer_email', 'jan@example.com', 'notes', 'x'));
  select customer_name into v_name from orders where id = (r->>'order_id')::uuid;
  assert length(v_name) = 120, 'truncated to 120: ' || length(v_name);
  r := showroom_order(jsonb_build_object('external_id', 'showroom:test-salon:n3', 'showroom_code', 'test-salon',
        'access_token', 'tok-test', 'consent', true, 'customer_name', E' \r\n ',
        'customer_email', 'jan@example.com', 'notes', 'x'));
  assert r->>'error' = 'INVALID_NAME', r::text;
  raise notice 'PASS test_showroom_customer_name_sanitized';
end $$;

-- test_showroom_quote_matches_calculator
do $$
declare rs jsonb; rc jsonb;
begin
  rs := showroom_order('{"external_id":"showroom:test-salon:q1","showroom_code":"test-salon","access_token":"tok-test","consent":true,
          "customer_name":"Jan","customer_email":"jan@example.com",
          "items":[{"product_id":"00000000-0000-0000-0000-0000000000c1","qty":3}]}');
  rc := calculator_order('{"external_id":"calc:q1","customer_email":"jan@example.com",
          "items":[{"product_id":"00000000-0000-0000-0000-0000000000c1","qty":3}]}');
  assert not (rs ? 'error') and not (rc ? 'error'), rs::text || rc::text;
  assert (select quote->>'total' from orders where id = (rs->>'order_id')::uuid)
       = (select quote->>'total' from orders where id = (rc->>'order_id')::uuid), 'same total';
  assert (select source from orders where id = (rc->>'order_id')::uuid) = 'form', 'calculator source stays form';
  raise notice 'PASS test_showroom_quote_matches_calculator';
end $$;

-- test_showroom_info_hides_email
do $$
declare r jsonb;
begin
  r := showroom_info('test-salon');
  assert r = '{"name": "Salon Testowy"}'::jsonb, r::text;
  assert showroom_info('test-off') = '{}'::jsonb and showroom_info('nie-ma') = '{}'::jsonb, 'unknown or inactive';
  raise notice 'PASS test_showroom_info_hides_email';
end $$;

-- test_showroom_recovered_by_sweeper: zamówienie i lead bez maili są do naprawy, po mailu znikają
do $$
declare rq jsonb; rl jsonb; v_q uuid; v_l uuid;
begin
  rq := showroom_order('{"external_id":"showroom:test-salon:s1","showroom_code":"test-salon","access_token":"tok-test","consent":true,
          "customer_name":"Jan","customer_email":"jan@example.com",
          "items":[{"product_id":"00000000-0000-0000-0000-0000000000c1","qty":1}]}');
  rl := showroom_order('{"external_id":"showroom:test-salon:s2","showroom_code":"test-salon","access_token":"tok-test","consent":true,
          "customer_name":"Anna","customer_email":"anna@example.com","notes":"oddzwonić"}');
  v_q := (rq->>'order_id')::uuid; v_l := (rl->>'order_id')::uuid;
  update orders set created_at = now() - interval '3 minutes' where id in (v_q, v_l);

  assert exists (select 1 from orders_missing_notifications() m where m.order_id = v_q), 'quoted needs repair';
  assert exists (select 1 from orders_missing_notifications() m where m.order_id = v_l), 'lead needs repair';

  perform enqueue_email(v_q, 'customer_quote', 'jan@example.com', 's', 'b');
  assert exists (select 1 from orders_missing_notifications() m where m.order_id = v_q), 'quoted still needs showroom_lead';
  perform enqueue_email(v_q, 'showroom_lead', 'handlowiec.test@example.com', 's', 'b');
  perform enqueue_email(v_l, 'showroom_lead', 'handlowiec.test@example.com', 's', 'b');
  assert not exists (select 1 from orders_missing_notifications() m where m.order_id in (v_q, v_l)), 'repaired';

  assert (notification_context(v_l)->>'salesperson_email') = 'handlowiec.test@example.com', 'context has salesperson';
  assert (notification_context(v_l)->>'customer_name') = 'Anna', 'context has customer name';
  raise notice 'PASS test_showroom_recovered_by_sweeper';
end $$;

-- test_showroom_external_id_namespace: identyfikator musi należeć do salonu i nie może przejąć cudzego zamówienia
do $$
declare r jsonb; v_calc jsonb;
begin
  v_calc := calculator_order('{"external_id":"showroom:test-salon:cross","customer_email":"calc@example.com",
        "items":[{"product_id":"00000000-0000-0000-0000-0000000000c1","qty":1}]}');
  assert (select source from orders where id = (v_calc->>'order_id')::uuid) = 'form', 'calculator order exists with that id';
  r := showroom_order('{"external_id":"showroom:test-salon:cross","showroom_code":"test-salon","access_token":"tok-test","consent":true,
          "customer_name":"Jan","customer_email":"jan@example.com","notes":"x"}');
  assert r->>'error' = 'EXTERNAL_ID_CONFLICT', r::text;
  assert (select customer_email from orders where external_id = 'showroom:test-salon:cross') = 'calc@example.com', 'foreign order untouched';
  assert (select showroom_name from orders where external_id = 'showroom:test-salon:cross') is null, 'no salon data written';
  r := showroom_order('{"external_id":"calc-123","showroom_code":"test-salon","access_token":"tok-test","consent":true,
          "customer_name":"Jan","customer_email":"jan@example.com","notes":"x"}');
  assert r->>'error' = 'INVALID_EXTERNAL_ID', 'no salon prefix: ' || r::text;
  r := showroom_order('{"external_id":"showroom:inny-salon:1","showroom_code":"test-salon","access_token":"tok-test","consent":true,
          "customer_name":"Jan","customer_email":"jan@example.com","notes":"x"}');
  assert r->>'error' = 'INVALID_EXTERNAL_ID', 'other salon prefix: ' || r::text;
  raise notice 'PASS test_showroom_external_id_namespace';
end $$;

-- test_showroom_retry_survives_catalog_change: ponowienie zapisanego zamówienia nie zależy od aktualnego cennika
do $$
declare p jsonb; r1 jsonb; r2 jsonb;
begin
  p := '{"external_id":"showroom:test-salon:retry","showroom_code":"test-salon","access_token":"tok-test","consent":true,
          "customer_name":"Jan","customer_email":"jan@example.com",
          "items":[{"product_id":"00000000-0000-0000-0000-0000000000c1","qty":1}]}';
  r1 := showroom_order(p);
  assert (r1->>'created')::boolean, r1::text;
  delete from supplier_prices where material_id = '00000000-0000-0000-0000-0000000000b1';
  r2 := showroom_order(p);
  assert not (r2 ? 'error') and not (r2->>'created')::boolean and r2->>'order_id' = r1->>'order_id', 'retry confirmed: ' || r2::text;
  raise notice 'PASS test_showroom_retry_survives_catalog_change';
end $$;

rollback;
