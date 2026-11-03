-- Task 7: automatyczne zamówienia do hurtowni (create_purchase_orders, approve_purchase_order, receive_delivery).
begin;

-- Neutralizujemy materiały z seeda, żeby test widział tylko własne dane.
update materials set min_stock = 0;
delete from slack_outbox;

insert into suppliers (id, name, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'Hurt A', 'a@example.com'),
  ('00000000-0000-0000-0000-0000000000a2', 'Hurt B', 'b@example.com');
insert into materials (id, name, unit, stock, reserved, min_stock) values
  ('00000000-0000-0000-0000-0000000000b1', 'Mat 1', 'm2',  2, 0, 10),   -- dostępne 2, min 10 -> qty ceil(20-2)=18
  ('00000000-0000-0000-0000-0000000000b2', 'Mat 2', 'szt', 5, 1, 4.5),  -- dostępne 4, min 4.5 -> ceil(9-4)=5
  ('00000000-0000-0000-0000-0000000000b3', 'Mat 3', 'l',   0, 0, 3),    -- dostępne 0 -> 6
  ('00000000-0000-0000-0000-0000000000b4', 'Mat 4 bez ceny', 'szt', 0, 0, 3);
insert into supplier_prices (supplier_id, material_id, price, updated_at) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1', 10.00, now()),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000b1', 12.00, now()),
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b2', 3.50, now()),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000b2', 4.00, now()),
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b3', 20.00, now()),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000b3', 18.00, now()),
  -- jedyna cena Mat 4 jest przeterminowana
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b4', 5.00, now() - interval '40 days');

-- test_po_groups_by_cheapest_supplier
do $$
declare v_ids uuid[]; v_a uuid; v_b uuid;
begin
  select array_agg(x) into v_ids from create_purchase_orders('http://localhost:5678') x;
  assert coalesce(array_length(v_ids, 1), 0) = 2, 'two POs expected, got ' || coalesce(array_length(v_ids, 1), 0);
  select id into v_a from purchase_orders where id = any(v_ids) and supplier_id = '00000000-0000-0000-0000-0000000000a1';
  select id into v_b from purchase_orders where id = any(v_ids) and supplier_id = '00000000-0000-0000-0000-0000000000a2';
  assert (select count(*) from purchase_order_lines where po_id = v_a) = 2, 'A has Mat 1 and Mat 2';
  assert (select count(*) from purchase_order_lines where po_id = v_b) = 1, 'B has Mat 3';
  assert (select unit_price from purchase_order_lines where po_id = v_a and material_id = '00000000-0000-0000-0000-0000000000b1') = 10.00, 'unit price A/Mat 1';
  assert (select qty from purchase_order_lines where po_id = v_a and material_id = '00000000-0000-0000-0000-0000000000b1') = 18, 'qty Mat 1 = ceil(2*10-2)';
  assert (select qty from purchase_order_lines where po_id = v_a and material_id = '00000000-0000-0000-0000-0000000000b2') = 5, 'qty rounds up (9-4=5)';
  assert (select unit_price from purchase_order_lines where po_id = v_b) = 18.00, 'unit price B/Mat 3';
  assert (select status from purchase_orders where id = v_a) = 'draft', 'draft status';
  raise notice 'PASS test_po_groups_by_cheapest_supplier';
end $$;

-- test_po_slack_link_and_idempotent: drugie wywołanie nie tworzy nic nowego, Slack dostaje jedną wiadomość na PO
do $$
declare v_n int; v_before int;
begin
  select count(*) into v_before from purchase_orders;
  select count(*) into v_n from create_purchase_orders('http://localhost:5678');
  assert v_n = 0, 'second run returns nothing, got ' || v_n;
  assert (select count(*) from purchase_orders) = v_before, 'no new POs';
  assert (select count(*) from slack_outbox where kind = 'po_draft') = 2, 'one Slack message per PO';
  assert exists (select 1 from slack_outbox where kind = 'po_draft'
                 and text like '%http://localhost:5678/webhook/po-approve?po_id=%'), 'approval link in Slack text';
  raise notice 'PASS test_po_slack_link_and_idempotent';
end $$;

-- test_po_skips_unpriced
do $$
begin
  assert not exists (select 1 from purchase_order_lines where material_id = '00000000-0000-0000-0000-0000000000b4'),
         'unpriced material is not ordered';
  assert exists (select 1 from low_stock_unpriced() u where u.material_id = '00000000-0000-0000-0000-0000000000b4'),
         'unpriced material is reported';
  assert (select count(*) from low_stock_unpriced()) = 1, 'only the unpriced one';
  assert exists (select 1 from slack_outbox where kind = 'po_unpriced' and text like '%Mat 4 bez ceny%'), 'alert about missing price';
  raise notice 'PASS test_po_skips_unpriced';
end $$;

-- test_po_public_url_validated: zły adres nie trafia do wiadomości
do $$
begin
  update purchase_orders set status = 'cancelled';
  delete from slack_outbox;
  perform create_purchase_orders('javascript:alert(1)');
  assert not exists (select 1 from slack_outbox where kind = 'po_draft' and text like '%javascript%'), 'bad url ignored';
  assert exists (select 1 from slack_outbox where kind = 'po_draft'), 'message still sent without link';
  update purchase_orders set status = 'cancelled';
  raise notice 'PASS test_po_public_url_validated';
end $$;

-- test_approve_sends_supplier_email
do $$
declare v_po uuid; v_ids uuid[]; r jsonb;
begin
  update purchase_orders set status = 'cancelled';
  select array_agg(x) into v_ids from create_purchase_orders() x;
  select id into v_po from purchase_orders
    where id = any(v_ids) and supplier_id = '00000000-0000-0000-0000-0000000000a1';
  assert v_po is not null, 'PO for A created';
  r := approve_purchase_order(v_po);
  assert (r->>'ok')::boolean, r::text;
  assert (select status from purchase_orders where id = v_po) = 'sent', 'sent status';
  assert (select sent_at is not null from purchase_orders where id = v_po), 'sent_at set';
  assert exists (select 1 from email_outbox where po_id = v_po and kind = 'purchase_order'
                 and to_email = 'a@example.com' and body like '%Mat 1%' and body like '%18%'), 'supplier email queued';
  r := approve_purchase_order(v_po);
  assert r->>'error' = 'PO_NOT_DRAFT' and not (r->>'ok')::boolean, r::text;
  assert (select count(*) from email_outbox where po_id = v_po) = 1, 'no duplicate email';
  assert approve_purchase_order(gen_random_uuid())->>'error' = 'PO_NOT_FOUND', 'unknown PO';
  raise notice 'PASS test_approve_sends_supplier_email';
end $$;

-- test_receive_requires_sent: z draftu odbiór jest niemożliwy, stan bez zmian
do $$
declare v_po uuid; v_stock numeric; r jsonb;
begin
  update purchase_orders set status = 'cancelled';
  select x into v_po from create_purchase_orders() x limit 1;
  select stock into v_stock from materials where id = '00000000-0000-0000-0000-0000000000b3';
  r := receive_delivery(v_po);
  assert r->>'error' = 'PO_NOT_SENT', r::text;
  assert (select stock from materials where id = '00000000-0000-0000-0000-0000000000b3') = v_stock, 'stock unchanged';
  raise notice 'PASS test_receive_requires_sent';
end $$;

-- test_receive_delivery_increases_stock, test_po_excludes_materials_on_order
do $$
declare v_po uuid; v_ids uuid[]; r jsonb; v_n int;
begin
  update purchase_orders set status = 'cancelled';
  select array_agg(x) into v_ids from create_purchase_orders() x;
  select id into v_po from purchase_orders
    where id = any(v_ids) and supplier_id = '00000000-0000-0000-0000-0000000000a1';
  perform approve_purchase_order(v_po);

  -- materiały z PO sent albo draft nie trafiają do kolejnego szkicu, mimo że stan jest nadal niski
  select count(*) into v_n from create_purchase_orders();
  assert v_n = 0, 'materials on order are skipped, got ' || v_n;

  r := receive_delivery(v_po);
  assert (r->>'ok')::boolean, r::text;
  assert (select stock from materials where id = '00000000-0000-0000-0000-0000000000b1') = 2 + 18, 'stock +18';
  assert (select stock from materials where id = '00000000-0000-0000-0000-0000000000b2') = 5 + 5, 'stock +5';
  assert (select count(*) from stock_movements where kind = 'receive'
          and material_id in ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b2')) = 2, 'receive movements';
  assert (select status from purchase_orders where id = v_po) = 'received', 'received status';
  assert (select received_at is not null from purchase_orders where id = v_po), 'received_at set';
  assert receive_delivery(v_po)->>'error' = 'PO_NOT_SENT', 'second receive rejected';
  assert (select stock from materials where id = '00000000-0000-0000-0000-0000000000b1') = 20, 'stock not doubled';
  assert receive_delivery(gen_random_uuid())->>'error' = 'PO_NOT_FOUND', 'unknown PO';
  raise notice 'PASS test_receive_delivery_increases_stock';
end $$;

-- test_purchase_order_context: dane do strony potwierdzenia
do $$
declare v_po uuid; c jsonb;
begin
  update purchase_orders set status = 'cancelled';
  select x into v_po from create_purchase_orders() x limit 1;
  c := purchase_order_context(v_po);
  assert c->>'status' = 'draft' and c->>'supplier' is not null and jsonb_array_length(c->'lines') >= 1, c::text;
  assert (c->>'total')::numeric > 0, 'total present';
  assert purchase_order_context(gen_random_uuid()) is null, 'unknown PO gives null';
  raise notice 'PASS test_purchase_order_context';
end $$;

-- test_po_qty_fractional_rounds_up: minimum 5,1 przy stanie 0 -> ceil(10,2) = 11
do $$
begin
  update purchase_orders set status = 'cancelled';
  insert into materials (id, name, unit, stock, reserved, min_stock) values
    ('00000000-0000-0000-0000-0000000000b5', 'Mat 5', 'szt', 0, 0, 5.1);
  insert into supplier_prices (supplier_id, material_id, price, updated_at) values
    ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b5', 2.00, now());
  assert (select qty from _po_candidates() where material_id = '00000000-0000-0000-0000-0000000000b5') = 11, 'ceil(10.2)=11';
  delete from supplier_prices where material_id = '00000000-0000-0000-0000-0000000000b5';
  delete from materials where id = '00000000-0000-0000-0000-0000000000b5';
  raise notice 'PASS test_po_qty_fractional_rounds_up';
end $$;

-- test_approve_validates: pusty szkic i zły adres hurtowni nie zmieniają statusu; adres jest przycinany
do $$
declare v_po uuid; r jsonb;
begin
  update purchase_orders set status = 'cancelled';
  insert into purchase_orders (supplier_id) values ('00000000-0000-0000-0000-0000000000a1') returning id into v_po;
  r := approve_purchase_order(v_po);
  assert r->>'error' = 'PO_EMPTY', r::text;
  assert (select status from purchase_orders where id = v_po) = 'draft', 'empty PO stays draft';

  insert into purchase_order_lines (po_id, material_id, qty, unit_price)
    values (v_po, '00000000-0000-0000-0000-0000000000b1', 1, 10);
  update suppliers set email = 'nie ma malpy' where id = '00000000-0000-0000-0000-0000000000a1';
  r := approve_purchase_order(v_po);
  assert r->>'error' = 'SUPPLIER_NO_EMAIL', r::text;
  assert (select status from purchase_orders where id = v_po) = 'draft', 'still draft';

  update suppliers set email = '  a@example.com ' where id = '00000000-0000-0000-0000-0000000000a1';
  r := approve_purchase_order(v_po);
  assert (r->>'ok')::boolean, r::text;
  assert exists (select 1 from email_outbox where po_id = v_po and to_email = 'a@example.com'), 'trimmed address queued';
  assert claim_deliveries(10, false, false, true, 'a@example.com') @> '[{"channel":"email","to":"a@example.com"}]'::jsonb,
         'delivery can claim the mail';
  raise notice 'PASS test_approve_validates';
end $$;

rollback;
