-- Task 3: intake_order i intake_status, czyli atomowe przyjęcie zamówienia po parsowaniu przez AI.
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

create function pg_temp.payload(p_ext text, p_route text, p_items jsonb) returns jsonb language sql as $$
  select jsonb_build_object(
    'external_id', p_ext, 'source', 'email', 'customer_email', 'k@example.com', 'kind', 'catalog',
    'raw_text', 'Chcę szafkę', 'parsed', jsonb_build_object('llm', 'x'), 'route', p_route, 'items', p_items)
$$;

-- test_intake_ok_route: poprawne zamówienie dostaje wycenę i status quoted
do $$
declare v_r jsonb;
begin
  v_r := intake_order(pg_temp.payload('in-1', 'ok', jsonb_build_array(jsonb_build_object(
    'product_id', '00000000-0000-0000-0000-0000000000c1', 'qty', 1))));
  assert (v_r->>'created')::boolean, 'created';
  assert v_r->>'status' = 'quoted', 'status: ' || (v_r->>'status');
  assert (v_r#>>'{quote,total}')::numeric = 700.00, 'total: ' || (v_r#>>'{quote,total}');
  assert (select raw_text from orders where id = (v_r->>'order_id')::uuid) = 'Chcę szafkę', 'raw_text stored';
  assert (select parsed->>'llm' from orders where id = (v_r->>'order_id')::uuid) = 'x', 'parsed stored';
  raise notice 'PASS test_intake_ok_route';
end $$;

-- test_intake_other_routes: needs_info i needs_review zapisują zamówienie bez wyceny
do $$
declare v_a jsonb; v_b jsonb;
begin
  v_a := intake_order(pg_temp.payload('in-2', 'needs_info', '[]'));
  v_b := intake_order(pg_temp.payload('in-3', 'needs_review', '[]'));
  assert v_a->>'status' = 'needs_info', 'needs_info: ' || (v_a->>'status');
  assert v_b->>'status' = 'needs_review', 'needs_review: ' || (v_b->>'status');
  assert (select quote from orders where id = (v_a->>'order_id')::uuid) is null, 'no quote';
  raise notice 'PASS test_intake_other_routes';
end $$;

-- test_intake_quote_error_needs_review: błąd wyceny (zły wymiar) daje needs_review i opis błędu
do $$
declare v_r jsonb;
begin
  v_r := intake_order(pg_temp.payload('in-4', 'ok', jsonb_build_array(jsonb_build_object(
    'custom_spec', jsonb_build_object('width_cm', 5, 'height_cm', 90, 'depth_cm', 45,
      'material_id', '00000000-0000-0000-0000-0000000000b1'), 'qty', 1))));
  assert v_r->>'status' = 'needs_review', 'status: ' || (v_r->>'status');
  assert v_r#>>'{quote,error}' = 'INVALID_SPEC', 'error: ' || coalesce(v_r#>>'{quote,error}', 'null');
  raise notice 'PASS test_intake_quote_error_needs_review';
end $$;

-- test_intake_idempotent: ponowne przyjęcie tego samego external_id nie zmienia zamówienia
do $$
declare v_a jsonb; v_b jsonb; v_p jsonb;
begin
  v_p := pg_temp.payload('in-5', 'ok', jsonb_build_array(jsonb_build_object(
    'product_id', '00000000-0000-0000-0000-0000000000c1', 'qty', 1)));
  v_a := intake_order(v_p);
  v_b := intake_order(v_p || '{"route":"needs_review"}');
  assert (v_a->>'created')::boolean and not (v_b->>'created')::boolean, 'created flags';
  assert v_a->>'order_id' = v_b->>'order_id', 'same id';
  assert v_b->>'status' = 'quoted', 'status unchanged: ' || (v_b->>'status');
  assert (select count(*) from orders where external_id = 'in-5') = 1, 'one order';
  raise notice 'PASS test_intake_idempotent';
end $$;

-- test_intake_rejects_bad_route: nieznana trasa jest błędem, a nie cichym zamówieniem
do $$
begin
  begin
    perform intake_order(pg_temp.payload('in-6', 'spam', '[]'));
    assert false, 'should have raised';
  exception when others then
    assert sqlerrm = 'INVALID_ROUTE:spam', 'wrong error: ' || sqlerrm;
  end;
  assert not exists (select 1 from orders where external_id = 'in-6'), 'nothing stored';
  raise notice 'PASS test_intake_rejects_bad_route';
end $$;

-- test_intake_status: istniejące zamówienie jest wykrywane, nieistniejące nie
do $$
declare v_id uuid;
begin
  v_id := (intake_order(pg_temp.payload('in-7', 'needs_info', '[]'))->>'order_id')::uuid;
  assert (intake_status('in-7')->>'exists')::boolean, 'exists';
  assert intake_status('in-7')->>'order_id' = v_id::text, 'order_id';
  assert not (intake_status('nie-ma-takiego')->>'exists')::boolean, 'not exists';
  raise notice 'PASS test_intake_status';
end $$;

-- test_intake_not_public: tylko service_role
do $$
declare v_fn text;
begin
  foreach v_fn in array array['intake_order(jsonb)', 'intake_status(text)'] loop
    assert not has_function_privilege('anon', v_fn, 'execute'), 'anon can execute ' || v_fn;
    assert not has_function_privilege('authenticated', v_fn, 'execute'), 'authenticated can execute ' || v_fn;
    assert has_function_privilege('service_role', v_fn, 'execute'), 'service_role cannot execute ' || v_fn;
  end loop;
  raise notice 'PASS test_intake_not_public';
end $$;

rollback;
