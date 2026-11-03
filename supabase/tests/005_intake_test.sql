-- Task 3: przyjęcie zamówienia w dwóch krokach (intake_receive przed odpowiedzią HTTP,
-- intake_complete po odpowiedzi AI) oraz odzyskiwanie zgłoszeń, które utknęły.
begin;

insert into settings (key, value) values ('labor_rate', 120), ('margin', 0.25), ('waste', 0.15)
on conflict (key) do update set value = excluded.value;
insert into suppliers (id, name, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'Test Hurt', 'a@example.com');
insert into materials (id, name, unit, stock, min_stock) values
  ('00000000-0000-0000-0000-0000000000b1', 'Test M1', 'm2', 100, 1);
insert into supplier_prices (supplier_id, material_id, price) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1', 100);
insert into products (id, name, base_price, labor_hours) values
  ('00000000-0000-0000-0000-0000000000c1', 'Test P1', 0, 3);
insert into product_materials (product_id, material_id, qty) values
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b1', 2);

create function pg_temp.receive(p_ext text) returns uuid language sql as $$
  select (intake_receive(jsonb_build_object(
    'external_id', p_ext, 'source', 'email', 'customer_email', 'k@example.com',
    'raw_text', 'Chcę szafkę')) ->> 'order_id')::uuid
$$;

create function pg_temp.complete(p_id uuid, p_route text, p_items jsonb) returns jsonb language sql as $$
  select intake_complete(p_id, jsonb_build_object(
    'kind', 'catalog', 'route', p_route, 'items', p_items,
    'parsed', jsonb_build_object('llm', 'x', 'missing', jsonb_build_array('wymiary'), 'reason', 'R')))
$$;

create function pg_temp.item() returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('product_id', '00000000-0000-0000-0000-0000000000c1', 'qty', 1))
$$;

-- test_receive_creates_placeholder: zgłoszenie jest zapisane z surową treścią, zanim ruszy AI
do $$
declare v_r jsonb; v_id uuid;
begin
  v_r := intake_receive(jsonb_build_object(
    'external_id', 'rc-1', 'source', 'form', 'customer_email', 'k@example.com', 'raw_text', 'Treść klienta'));
  v_id := (v_r->>'order_id')::uuid;
  assert (v_r->>'created')::boolean, 'created';
  assert (select status from orders where id = v_id) = 'new', 'status new';
  assert (select raw_text from orders where id = v_id) = 'Treść klienta', 'raw_text stored';
  assert (select count(*) from order_items where order_id = v_id) = 0, 'no items yet';
  raise notice 'PASS test_receive_creates_placeholder';
end $$;

-- test_receive_duplicate: drugie zgłoszenie z tym samym external_id nie tworzy zamówienia
do $$
declare v_a jsonb; v_b jsonb;
begin
  v_a := intake_receive(jsonb_build_object('external_id', 'rc-2', 'source', 'form',
    'customer_email', 'k@example.com', 'raw_text', 'a'));
  v_b := intake_receive(jsonb_build_object('external_id', 'rc-2', 'source', 'form',
    'customer_email', 'inny@example.com', 'raw_text', 'b'));
  assert (v_a->>'created')::boolean and not (v_b->>'created')::boolean, 'created flags';
  assert v_a->>'order_id' = v_b->>'order_id', 'same id';
  assert (select count(*) from orders where external_id = 'rc-2') = 1, 'one order';
  assert (select raw_text from orders where external_id = 'rc-2') = 'a', 'first wins';
  raise notice 'PASS test_receive_duplicate';
end $$;

-- test_complete_ok_route: poprawne zamówienie dostaje wycenę i status quoted
do $$
declare v_id uuid; v_r jsonb;
begin
  v_id := pg_temp.receive('cp-1');
  v_r := pg_temp.complete(v_id, 'ok', pg_temp.item());
  assert (v_r->>'completed')::boolean, 'completed';
  assert v_r->>'status' = 'quoted', 'status: ' || (v_r->>'status');
  assert (v_r#>>'{quote,total}')::numeric = 700.00, 'total: ' || (v_r#>>'{quote,total}');
  assert (select parsed->>'llm' from orders where id = v_id) = 'x', 'parsed stored';
  assert (select count(*) from order_items where order_id = v_id) = 1, 'item stored';
  raise notice 'PASS test_complete_ok_route';
end $$;

-- test_complete_other_routes: needs_info i needs_review zapisują zamówienie bez wyceny
do $$
declare v_a jsonb; v_b jsonb;
begin
  v_a := pg_temp.complete(pg_temp.receive('cp-2'), 'needs_info', '[]');
  v_b := pg_temp.complete(pg_temp.receive('cp-3'), 'needs_review', '[]');
  assert v_a->>'status' = 'needs_info', 'needs_info: ' || (v_a->>'status');
  assert v_b->>'status' = 'needs_review', 'needs_review: ' || (v_b->>'status');
  assert (select quote from orders where id = (v_a->>'order_id')::uuid) is null, 'no quote';
  raise notice 'PASS test_complete_other_routes';
end $$;

-- test_complete_quote_error: błąd wyceny (zły wymiar) daje needs_review i opis błędu
do $$
declare v_r jsonb;
begin
  v_r := pg_temp.complete(pg_temp.receive('cp-4'), 'ok', jsonb_build_array(jsonb_build_object(
    'custom_spec', jsonb_build_object('width_cm', 5, 'height_cm', 90, 'depth_cm', 45,
      'material_id', '00000000-0000-0000-0000-0000000000b1'), 'qty', 1)));
  assert v_r->>'status' = 'needs_review', 'status: ' || (v_r->>'status');
  assert v_r#>>'{quote,error}' = 'INVALID_SPEC', 'error: ' || coalesce(v_r#>>'{quote,error}', 'null');
  raise notice 'PASS test_complete_quote_error';
end $$;

-- test_complete_twice: drugie domknięcie (np. wyścig dwóch żądań) niczego nie zmienia
do $$
declare v_id uuid; v_a jsonb; v_b jsonb;
begin
  v_id := pg_temp.receive('cp-5');
  v_a := pg_temp.complete(v_id, 'ok', pg_temp.item());
  v_b := pg_temp.complete(v_id, 'needs_review', '[]');
  assert (v_a->>'completed')::boolean and not (v_b->>'completed')::boolean, 'completed flags';
  assert v_b->>'status' = 'quoted', 'status unchanged: ' || (v_b->>'status');
  assert (select count(*) from order_items where order_id = v_id) = 1, 'items not duplicated';
  raise notice 'PASS test_complete_twice';
end $$;

-- test_complete_bad_route: brak trasy, JSON null i nieznana trasa to błąd, a nie ciche zamówienie
do $$
declare v_id uuid; v_p jsonb; v_route jsonb;
begin
  v_id := pg_temp.receive('cp-6');
  foreach v_route in array array['"spam"'::jsonb, 'null'::jsonb] loop
    begin
      perform intake_complete(v_id, jsonb_build_object('kind', 'catalog', 'route', v_route, 'items', '[]'::jsonb));
      assert false, 'should have raised';
    exception when others then
      assert sqlerrm like 'INVALID_ROUTE:%', 'wrong error: ' || sqlerrm;
    end;
  end loop;
  begin
    perform intake_complete(v_id, jsonb_build_object('kind', 'catalog', 'items', '[]'::jsonb));
    assert false, 'missing route should have raised';
  exception when others then
    assert sqlerrm = 'INVALID_ROUTE:null', 'wrong error: ' || sqlerrm;
  end;
  assert (select status from orders where id = v_id) = 'new', 'order untouched';
  raise notice 'PASS test_complete_bad_route';
end $$;

-- test_mark_stuck_intakes: zgłoszenie bez domknięcia po upływie czasu trafia do sprawdzenia
do $$
declare v_old uuid; v_young uuid; v_done uuid; v_r jsonb;
begin
  v_old := pg_temp.receive('st-1');
  v_young := pg_temp.receive('st-2');
  v_done := pg_temp.receive('st-3');
  perform pg_temp.complete(v_done, 'needs_info', '[]');
  update orders set created_at = now() - interval '20 minutes' where id in (v_old, v_done);

  v_r := mark_stuck_intakes(600);
  assert (v_r->>'marked')::int = 1, 'marked: ' || v_r::text;
  assert (select status from orders where id = v_old) = 'needs_review', 'old stuck -> needs_review';
  assert (select parsed->>'reason' from orders where id = v_old) = 'STUCK_INTAKE', 'reason';
  assert (select status from orders where id = v_young) = 'new', 'young untouched';
  assert (select status from orders where id = v_done) = 'needs_info', 'completed untouched';

  -- późne domknięcie wyniku AI po oznaczeniu jako utknięte niczego nie nadpisuje
  assert not (pg_temp.complete(v_old, 'ok', pg_temp.item())->>'completed')::boolean, 'late complete ignored';
  raise notice 'PASS test_mark_stuck_intakes';
end $$;

-- test_orders_missing_notifications: wykrywa zamówienia bez kompletu maili, pomija dane demo
do $$
declare v_q uuid; v_i uuid; v_r uuid; v_seed uuid; v_young uuid;
begin
  v_q := (pg_temp.complete(pg_temp.receive('nm-1'), 'ok', pg_temp.item()))->>'order_id';
  v_i := (pg_temp.complete(pg_temp.receive('nm-2'), 'needs_info', '[]'))->>'order_id';
  v_r := (pg_temp.complete(pg_temp.receive('nm-3'), 'needs_review', '[]'))->>'order_id';
  v_young := (pg_temp.complete(pg_temp.receive('nm-4'), 'needs_info', '[]'))->>'order_id';
  -- zamówienie spoza intake (np. dane demo): parsed IS NULL
  v_seed := upsert_order(jsonb_build_object('external_id', 'nm-seed', 'source', 'form',
    'customer_email', 'd@example.com', 'kind', 'catalog',
    'items', pg_temp.item()));
  perform estimate_quote(v_seed);
  update orders set created_at = now() - interval '10 minutes' where id in (v_q, v_i, v_r, v_seed);

  assert (select count(*) from orders_missing_notifications(120) where order_id in (v_q, v_i, v_r)) = 3, 'three missing';
  assert not exists (select 1 from orders_missing_notifications(120) where order_id = v_young), 'young skipped';
  assert not exists (select 1 from orders_missing_notifications(120) where order_id = v_seed), 'seed skipped';

  -- quoted potrzebuje obu maili: sam customer_quote nie wystarcza
  perform enqueue_email(v_q, 'customer_quote', 'k@example.com', 'W', 'B');
  assert exists (select 1 from orders_missing_notifications(120) where order_id = v_q), 'still missing owner_alert';
  perform enqueue_email(v_q, 'owner_alert', 'o@example.com', 'W', 'B');
  perform enqueue_email(v_i, 'needs_info', 'k@example.com', 'W', 'B');
  perform enqueue_email(v_r, 'owner_alert', 'o@example.com', 'W', 'B');
  assert (select count(*) from orders_missing_notifications(120) where order_id in (v_q, v_i, v_r)) = 0, 'all covered';
  raise notice 'PASS test_orders_missing_notifications';
end $$;

-- test_notification_context: komplet danych do złożenia maili z samego stanu bazy
do $$
declare v_id uuid; v_c jsonb;
begin
  v_id := (pg_temp.complete(pg_temp.receive('nc-1'), 'needs_info', '[]'))->>'order_id';
  perform enqueue_email(v_id, 'needs_info', 'k@example.com', 'W', 'B');
  v_c := notification_context(v_id);
  assert v_c->>'status' = 'needs_info', 'status';
  assert v_c->>'customer_email' = 'k@example.com', 'email';
  assert v_c->>'raw_text' = 'Chcę szafkę', 'raw_text';
  assert v_c->'missing' = '["wymiary"]'::jsonb, 'missing: ' || (v_c->'missing')::text;
  assert v_c->'existing_kinds' = '["needs_info"]'::jsonb, 'existing_kinds';
  assert notification_context('00000000-0000-0000-0000-00000000dead') is null, 'unknown order -> null';
  raise notice 'PASS test_notification_context';
end $$;

-- test_intake_not_public: tylko service_role
do $$
declare v_fn text;
begin
  foreach v_fn in array array['intake_receive(jsonb)', 'intake_complete(uuid,jsonb)', 'mark_stuck_intakes(integer)',
                              'orders_missing_notifications(integer)', 'notification_context(uuid)'] loop
    assert not has_function_privilege('anon', v_fn, 'execute'), 'anon can execute ' || v_fn;
    assert not has_function_privilege('authenticated', v_fn, 'execute'), 'authenticated can execute ' || v_fn;
    assert has_function_privilege('service_role', v_fn, 'execute'), 'service_role cannot execute ' || v_fn;
  end loop;
  raise notice 'PASS test_intake_not_public';
end $$;

rollback;
