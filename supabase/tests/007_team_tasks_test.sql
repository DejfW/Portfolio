-- Task 4: zatwierdzanie zamówień, zadania zespołu, kolejka Slack, import cen hurtowni, raport niskich stanów.
begin;

insert into settings (key, value) values ('labor_rate', 120), ('margin', 0.25), ('waste', 0.15)
on conflict (key) do update set value = excluded.value;

insert into suppliers (id, name, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'Test Hurt A', 'a@example.com'),
  ('00000000-0000-0000-0000-0000000000a2', 'Test Hurt B', 'b@example.com');
insert into materials (id, name, unit, stock, reserved, min_stock) values
  ('00000000-0000-0000-0000-0000000000b1', 'Test M1', 'szt', 10, 0, 2),
  ('00000000-0000-0000-0000-0000000000b2', 'Test M2', 'szt', 3, 0, 5);
insert into supplier_prices (supplier_id, material_id, price, updated_at) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1', 10, now()),
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b2', 20, now()),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000b2', 18, now());
insert into products (id, name, base_price, labor_hours) values
  ('00000000-0000-0000-0000-0000000000c1', 'Test P1', 0, 1),
  ('00000000-0000-0000-0000-0000000000c2', 'Test P2', 0, 1);
insert into product_materials (product_id, material_id, qty) values
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b1', 6),
  ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000b1', 4),
  ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000b2', 5);

create function pg_temp.new_order(p_ext text, p_product text) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  v_id := upsert_order(jsonb_build_object(
    'external_id', p_ext, 'source', 'form', 'customer_email', 'k@example.com', 'kind', 'catalog',
    'items', jsonb_build_array(jsonb_build_object('product_id', p_product, 'qty', 1))));
  perform estimate_quote(v_id);
  return v_id;
end $$;

-- test_enqueue_slack_idempotent: ten sam klucz deduplikacji daje jedną wiadomość
do $$
declare v_a uuid; v_b uuid;
begin
  v_a := enqueue_slack('task_assigned', 'Nowe zadanie', 'k-1');
  v_b := enqueue_slack('task_assigned', 'Nowe zadanie (powtórka)', 'k-1');
  assert v_a is not null and v_b is null, 'second ignored';
  assert (select count(*) from slack_outbox where dedupe_key = 'k-1') = 1, 'one row';
  assert (select text from slack_outbox where dedupe_key = 'k-1') = 'Nowe zadanie', 'first wins';
  begin
    perform enqueue_slack('spam', 'x', 'k-2');
    assert false, 'unknown kind accepted';
  exception when others then
    assert sqlerrm <> 'unknown kind accepted', 'wrong: ' || sqlerrm;
  end;
  begin
    perform enqueue_slack('task_done', '', 'k-3');
    assert false, 'empty text accepted';
  exception when others then
    assert sqlerrm <> 'empty text accepted', 'wrong: ' || sqlerrm;
  end;
  raise notice 'PASS test_enqueue_slack_idempotent';
end $$;

-- test_approve_order_assigns_task: zatwierdzenie tworzy zadanie, rezerwuje materiał i przypisuje osobę
do $$
declare v_o uuid; v_r jsonb;
begin
  v_o := pg_temp.new_order('tt-1', '00000000-0000-0000-0000-0000000000c1');
  v_r := approve_order(v_o, '  Jan  ');
  assert (v_r->>'ok')::boolean, 'ok: ' || v_r::text;
  assert (select assignee from tasks where id = (v_r->>'task_id')::uuid) = 'Jan', 'assignee trimmed';
  assert (select status from orders where id = v_o) = 'in_progress', 'in_progress';
  assert (select reserved from materials where id = '00000000-0000-0000-0000-0000000000b1') = 6, 'reserved 6';
  assert v_r->>'customer_email' = 'k@example.com', 'email returned for notifications';
  raise notice 'PASS test_approve_order_assigns_task';
end $$;

-- test_approve_order_shortage: brak materiału daje listę braków z najlepszą hurtownią, a w bazie nic się nie zmienia
do $$
declare v_o uuid; v_r jsonb; v_s jsonb;
begin
  update materials set reserved = 0, stock = 10 where id = '00000000-0000-0000-0000-0000000000b1';
  delete from stock_movements;
  delete from tasks;
  -- P2 potrzebuje 4 sztuki M1 (jest 10) i 5 sztuk M2 (jest 3, brakuje 2)
  v_o := pg_temp.new_order('tt-2', '00000000-0000-0000-0000-0000000000c2');
  v_r := approve_order(v_o, 'Anna');
  assert not (v_r->>'ok')::boolean, 'not ok';
  assert v_r->>'error' = 'INSUFFICIENT_STOCK', 'error: ' || (v_r->>'error');
  assert jsonb_array_length(v_r->'shortages') = 1, 'one shortage: ' || (v_r->'shortages')::text;
  v_s := v_r->'shortages'->0;
  assert v_s->>'name' = 'Test M2', 'name';
  assert (v_s->>'needed')::numeric = 5 and (v_s->>'available')::numeric = 3 and (v_s->>'missing')::numeric = 2, 'amounts: ' || v_s::text;
  assert v_s->>'best_supplier' = 'Test Hurt B' and (v_s->>'best_price')::numeric = 18, 'best supplier: ' || v_s::text;
  assert (select status from orders where id = v_o) = 'quoted', 'order still quoted';
  assert (select count(*) from tasks where order_id = v_o) = 0, 'no task';
  assert (select reserved from materials where id = '00000000-0000-0000-0000-0000000000b1') = 0, 'nothing reserved';
  raise notice 'PASS test_approve_order_shortage';
end $$;

-- test_approve_order_errors: powtórne zatwierdzenie, zły przydział i nieistniejące zamówienie to błędy, a nie wyjątki
do $$
declare v_o uuid; v_r jsonb;
begin
  update materials set reserved = 0, stock = 100 where id = '00000000-0000-0000-0000-0000000000b1';
  v_o := pg_temp.new_order('tt-3', '00000000-0000-0000-0000-0000000000c1');
  assert (approve_order(v_o, 'Jan')->>'ok')::boolean, 'first ok';
  v_r := approve_order(v_o, 'Anna');
  assert not (v_r->>'ok')::boolean and v_r->>'error' = 'ORDER_NOT_READY:in_progress', 'second: ' || v_r::text;
  assert (select count(*) from tasks where order_id = v_o) = 1, 'one task';

  v_o := pg_temp.new_order('tt-4', '00000000-0000-0000-0000-0000000000c1');
  assert approve_order(v_o, '')->>'error' = 'MISSING_ASSIGNEE', 'empty assignee';
  assert approve_order(v_o, repeat('x', 51))->>'error' = 'INVALID_ASSIGNEE', 'long assignee';
  assert approve_order(v_o, E'Jan\nAnna')->>'error' = 'INVALID_ASSIGNEE', 'newline in assignee';
  assert (select status from orders where id = v_o) = 'quoted', 'still quoted after invalid input';

  assert approve_order('00000000-0000-0000-0000-00000000dead', 'Jan')->>'error' = 'ORDER_NOT_FOUND', 'not found';
  raise notice 'PASS test_approve_order_errors';
end $$;

-- test_task_done: zakończenie zadania zużywa materiał i zwraca dane do maila, drugie kończy się błędem
do $$
declare v_o uuid; v_t uuid; v_r jsonb;
begin
  update materials set reserved = 0, stock = 100 where id = '00000000-0000-0000-0000-0000000000b1';
  v_o := pg_temp.new_order('tt-5', '00000000-0000-0000-0000-0000000000c1');
  v_t := (approve_order(v_o, 'Jan')->>'task_id')::uuid;
  v_r := task_done(v_t);
  assert (v_r->>'ok')::boolean, 'ok: ' || v_r::text;
  assert v_r->>'customer_email' = 'k@example.com' and v_r->>'order_id' = v_o::text, 'payload';
  assert (select status from orders where id = v_o) = 'done', 'order done';
  v_r := task_done(v_t);
  assert not (v_r->>'ok')::boolean and v_r->>'error' = 'TASK_ALREADY_DONE', 'second: ' || v_r::text;
  assert task_done('00000000-0000-0000-0000-00000000dead')->>'error' = 'TASK_NOT_FOUND', 'not found';
  raise notice 'PASS test_task_done';
end $$;

-- test_import_supplier_prices: poprawne wiersze są zapisywane, błędne raportowane, a stare ceny odświeżane
do $$
declare v_r jsonb;
begin
  update supplier_prices set updated_at = now() - interval '40 days'
    where material_id = '00000000-0000-0000-0000-0000000000b1';
  assert not exists (select 1 from best_price('00000000-0000-0000-0000-0000000000b1')), 'stale before import';

  v_r := import_supplier_prices(jsonb_build_object('rows', jsonb_build_array(
    jsonb_build_object('supplier', 'test hurt a ', 'material', 'Test M1', 'price', 11.5),
    jsonb_build_object('supplier', 'Test Hurt B', 'material', 'Test M2', 'price', '17,90'),
    jsonb_build_object('supplier', 'Nie ma takiej', 'material', 'Test M1', 'price', 5),
    jsonb_build_object('supplier', 'Test Hurt A', 'material', 'Nie ma takiego', 'price', 5),
    jsonb_build_object('supplier', 'Test Hurt A', 'material', 'Test M2', 'price', 0),
    jsonb_build_object('supplier', 'Test Hurt A', 'material', 'Test M2', 'price', -3),
    jsonb_build_object('supplier', 'Test Hurt A', 'material', 'Test M2', 'price', 'abc'),
    jsonb_build_object('supplier', 'Test Hurt A', 'material', 'Test M2'))));
  assert (v_r->>'updated')::int = 2, 'updated: ' || v_r::text;
  assert v_r->'unknown_suppliers' = '["Nie ma takiej"]'::jsonb, 'unknown suppliers: ' || v_r::text;
  assert v_r->'unknown_materials' = '["Nie ma takiego"]'::jsonb, 'unknown materials: ' || v_r::text;
  assert jsonb_array_length(v_r->'invalid') = 4, 'invalid: ' || v_r::text;

  assert (select price from best_price('00000000-0000-0000-0000-0000000000b1')) = 11.5, 'price refreshed and fresh';
  assert (select price from supplier_prices where supplier_id = '00000000-0000-0000-0000-0000000000a2'
          and material_id = '00000000-0000-0000-0000-0000000000b2') = 17.90, 'comma decimal parsed';
  assert (select price from supplier_prices where supplier_id = '00000000-0000-0000-0000-0000000000a1'
          and material_id = '00000000-0000-0000-0000-0000000000b2') = 20, 'invalid rows did not overwrite';

  -- pusty import to nie błąd
  assert (import_supplier_prices(jsonb_build_object('rows', '[]'::jsonb))->>'updated')::int = 0, 'empty';
  assert import_supplier_prices('{}'::jsonb)->>'error' = 'INVALID_ROWS', 'missing rows';
  raise notice 'PASS test_import_supplier_prices';
end $$;

-- test_low_stock_report: materiały poniżej minimum z ilością do zamówienia, a bez ceny osobno
do $$
declare v_r jsonb; v_i jsonb;
begin
  update materials set stock = 3, reserved = 0, min_stock = 5 where id = '00000000-0000-0000-0000-0000000000b2';
  update materials set stock = 100, reserved = 0, min_stock = 2 where id = '00000000-0000-0000-0000-0000000000b1';
  v_r := low_stock_report();
  select e into v_i from jsonb_array_elements(v_r->'items') e where e->>'name' = 'Test M2';
  assert v_i is not null, 'M2 listed';
  assert (v_i->>'available')::numeric = 3 and (v_i->>'to_order')::numeric = 7, 'to_order = ceil(2*5-3): ' || v_i::text;
  assert v_i->>'best_supplier' = 'Test Hurt B', 'supplier: ' || v_i::text;
  assert not exists (select 1 from jsonb_array_elements(v_r->'items') e where e->>'name' = 'Test M1'), 'M1 not listed';

  update supplier_prices set updated_at = now() - interval '40 days' where material_id = '00000000-0000-0000-0000-0000000000b2';
  v_r := low_stock_report();
  assert v_r->'unpriced' @> '["Test M2"]'::jsonb, 'unpriced: ' || (v_r->'unpriced')::text;
  raise notice 'PASS test_low_stock_report';
end $$;

-- test_pending_deliveries: kolejka Slack i maili w jednym miejscu, oznaczenie wysłania usuwa wpis
do $$
declare v_o uuid; v_s uuid; v_e uuid; v_p jsonb;
begin
  v_o := upsert_order(jsonb_build_object('external_id', 'tt-9', 'source', 'form',
    'customer_email', 'k@example.com', 'kind', 'catalog'));
  v_s := enqueue_slack('stock_digest', 'Raport', 'pd-1');
  v_e := enqueue_email(v_o, 'needs_info', 'k@example.com', 'Temat', 'Treść');

  v_p := pending_deliveries(100);
  assert exists (select 1 from jsonb_array_elements(v_p) e where e->>'channel' = 'slack' and e->>'id' = v_s::text), 'slack pending';
  assert exists (select 1 from jsonb_array_elements(v_p) e where e->>'channel' = 'email' and e->>'id' = v_e::text
                 and e->>'to' = 'k@example.com' and e->>'subject' = 'Temat'), 'email pending';

  perform mark_delivered('slack', v_s);
  perform mark_delivered('email', v_e);
  perform mark_delivered('email', v_e);
  v_p := pending_deliveries(100);
  assert not exists (select 1 from jsonb_array_elements(v_p) e where e->>'id' in (v_s::text, v_e::text)), 'delivered gone';
  assert (select sent_at from email_outbox where id = v_e) is not null, 'sent_at set';
  begin
    perform mark_delivered('sms', v_s);
    assert false, 'unknown channel accepted';
  exception when others then
    assert sqlerrm <> 'unknown channel accepted', 'wrong: ' || sqlerrm;
  end;
  raise notice 'PASS test_pending_deliveries';
end $$;

-- test_order_done_email_kind: nowy rodzaj maila dla klienta po zakończeniu zadania
do $$
declare v_o uuid;
begin
  v_o := upsert_order(jsonb_build_object('external_id', 'tt-10', 'source', 'form',
    'customer_email', 'k@example.com', 'kind', 'catalog'));
  assert enqueue_email(v_o, 'order_done', 'k@example.com', 'Gotowe', 'Treść') is not null, 'order_done accepted';
  raise notice 'PASS test_order_done_email_kind';
end $$;

rollback;
