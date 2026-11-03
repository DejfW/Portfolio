-- Poprawki po recenzji Task 4: powiadomienia w tej samej transakcji co zmiana stanu, kolejka dostarczania
-- z dzierżawą i ponowieniami, walidacje cen i nazw.
begin;

insert into settings (key, value) values ('labor_rate', 120), ('margin', 0.25), ('waste', 0.15)
on conflict (key) do update set value = excluded.value;
insert into suppliers (id, name, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'Test Hurt <A>', 'a@example.com');
insert into materials (id, name, unit, stock, reserved, min_stock) values
  ('00000000-0000-0000-0000-0000000000b1', 'Test M1', 'szt', 100, 0, 2),
  ('00000000-0000-0000-0000-0000000000b2', 'Test <!channel> M2', 'szt', 1, 0, 5);
insert into supplier_prices (supplier_id, material_id, price, updated_at) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1', 10, now()),
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b2', 20, now());
insert into products (id, name, base_price, labor_hours) values
  ('00000000-0000-0000-0000-0000000000c1', 'Test P1', 0, 1),
  ('00000000-0000-0000-0000-0000000000c2', 'Test P2', 0, 1);
insert into product_materials (product_id, material_id, qty) values
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b1', 6),
  ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000b2', 5);

create function pg_temp.new_order(p_ext text, p_product text, p_email text default 'k@example.com') returns uuid language plpgsql as $$
declare v_id uuid;
begin
  v_id := upsert_order(jsonb_build_object(
    'external_id', p_ext, 'source', 'form', 'customer_email', p_email, 'kind', 'catalog',
    'items', jsonb_build_array(jsonb_build_object('product_id', p_product, 'qty', 1))));
  perform estimate_quote(v_id);
  return v_id;
end $$;

-- test_approve_enqueues_atomically: przydział zadania zapisuje wiadomość Slack w tej samej transakcji
do $$
declare v_o uuid; v_r jsonb; v_t uuid; v_text text;
begin
  v_o := pg_temp.new_order('th-1', '00000000-0000-0000-0000-0000000000c1', 'a&b@x.pl');
  v_r := approve_order(v_o, 'Jan <!here>', 'http://pub');
  v_t := (v_r->>'task_id')::uuid;
  select text into v_text from slack_outbox where dedupe_key = 'task:' || v_t and kind = 'task_assigned';
  assert v_text is not null, 'slack row exists';
  assert v_text like '%*Jan &lt;!here&gt;*%', 'assignee escaped: ' || v_text;
  assert v_text like '%a&amp;b@x.pl%', 'email escaped: ' || v_text;
  assert v_text like '%http://pub/webhook/task-done?task_id=' || v_t || '%', 'done link: ' || v_text;
  assert v_text ~ 'Wycena: [0-9]+,[0-9]{2} zł', 'price format: ' || v_text;

  -- nieudane zatwierdzenie nie zostawia powiadomienia o przydziale
  assert approve_order(v_o, 'Anna', 'http://pub')->>'error' = 'ORDER_NOT_READY:in_progress', 'second fails';
  assert (select count(*) from slack_outbox where kind = 'task_assigned' and dedupe_key like 'task:%'
          and text like '%Anna%') = 0, 'no notification for failed approval';
  raise notice 'PASS test_approve_enqueues_atomically';
end $$;

-- test_shortage_alert_enqueued: brak materiału zapisuje alert ze znakami Slacka zakodowanymi
do $$
declare v_o uuid; v_r jsonb; v_text text;
begin
  v_o := pg_temp.new_order('th-2', '00000000-0000-0000-0000-0000000000c2');
  v_r := approve_order(v_o, 'Anna', 'http://pub');
  assert v_r->>'error' = 'INSUFFICIENT_STOCK', 'shortage';
  select text into v_text from slack_outbox where kind = 'stock_shortage' and dedupe_key like 'shortage:' || v_o || ':%';
  assert v_text is not null, 'alert row exists';
  assert v_text like '%Test &lt;!channel&gt; M2%', 'material escaped: ' || v_text;
  assert v_text like '%Test Hurt &lt;A&gt;%', 'supplier escaped: ' || v_text;
  assert v_text not like '%<!channel>%', 'no raw slack syntax';
  assert (select status from orders where id = v_o) = 'quoted', 'order untouched';

  -- powtórka tego samego dnia nie dubluje alertu
  perform approve_order(v_o, 'Anna', 'http://pub');
  assert (select count(*) from slack_outbox where dedupe_key like 'shortage:' || v_o || ':%') = 1, 'one alert per day';
  raise notice 'PASS test_shortage_alert_enqueued';
end $$;

-- test_task_done_enqueues_atomically: zakończenie zadania zapisuje mail dla klienta i Slack w jednej transakcji
do $$
declare v_o uuid; v_t uuid;
begin
  v_o := pg_temp.new_order('th-3', '00000000-0000-0000-0000-0000000000c1', 'klient@example.com');
  v_t := (approve_order(v_o, 'Jan', 'http://pub')->>'task_id')::uuid;
  assert (task_done(v_t)->>'ok')::boolean, 'done';
  assert (select count(*) from email_outbox where order_id = v_o and kind = 'order_done' and to_email = 'klient@example.com') = 1, 'email';
  assert (select count(*) from slack_outbox where dedupe_key = 'done:' || v_t and kind = 'task_done') = 1, 'slack';
  -- powtórka kończy się błędem i niczego nie dubluje
  assert task_done(v_t)->>'error' = 'TASK_ALREADY_DONE', 'second';
  assert (select count(*) from email_outbox where order_id = v_o and kind = 'order_done') = 1, 'one email';
  raise notice 'PASS test_task_done_enqueues_atomically';
end $$;

-- test_import_price_precision: cena zaokrąglona do zera jest błędna, także zapisana jako liczba JSON
do $$
declare v_r jsonb;
begin
  v_r := import_supplier_prices(jsonb_build_object('rows', jsonb_build_array(
    jsonb_build_object('supplier', 'Test Hurt <A>', 'material', 'Test M1', 'price', 0.001),
    jsonb_build_object('supplier', 'Test Hurt <A>', 'material', 'Test M1', 'price', 0.004),
    jsonb_build_object('supplier', 'Test Hurt <A>', 'material', 'Test M1', 'price', '0.001'),
    jsonb_build_object('supplier', 'Test Hurt <A>', 'material', 'Test M1', 'price', 12.345))));
  assert (v_r->>'updated')::int = 0, 'updated: ' || v_r::text;
  assert jsonb_array_length(v_r->'invalid') = 4, 'invalid: ' || v_r::text;
  assert (select price from supplier_prices where material_id = '00000000-0000-0000-0000-0000000000b1') = 10, 'price unchanged';
  begin
    update supplier_prices set price = 0 where material_id = '00000000-0000-0000-0000-0000000000b1';
    assert false, 'zero price accepted by table';
  exception when check_violation then null;
  end;
  raise notice 'PASS test_import_price_precision';
end $$;

-- test_unique_normalized_names: nazwy różniące się wielkością liter lub spacjami to ten sam obiekt
do $$
begin
  begin insert into suppliers (name, email) values ('test hurt <a> ', 'x@example.com'); assert false, 'supplier dup accepted';
  exception when unique_violation then null; end;
  begin insert into materials (name, unit) values ('TEST M1', 'szt'); assert false, 'material dup accepted';
  exception when unique_violation then null; end;
  begin insert into products (name) values (' test p1'); assert false, 'product dup accepted';
  exception when unique_violation then null; end;
  raise notice 'PASS test_unique_normalized_names';
end $$;

-- test_claim_deliveries_lease: odebrane wiadomości są dzierżawione, więc drugi wykonawca ich nie dostaje
do $$
declare v_a jsonb; v_b jsonb; v_id uuid;
begin
  v_id := enqueue_slack('stock_digest', 'Dzierżawa', 'cl-1');
  v_a := claim_deliveries(10, false, true, false, '');
  assert exists (select 1 from jsonb_array_elements(v_a) e where e->>'id' = v_id::text), 'first claims';
  v_b := claim_deliveries(10, false, true, false, '');
  assert not exists (select 1 from jsonb_array_elements(v_b) e where e->>'id' = v_id::text), 'second does not';
  -- po wygaśnięciu dzierżawy wiadomość wraca
  update slack_outbox set next_attempt_at = now() - interval '1 second' where id = v_id;
  assert exists (select 1 from jsonb_array_elements(claim_deliveries(10, false, true, false, '')) e where e->>'id' = v_id::text), 'after lease';
  -- wysłana znika na stałe
  perform mark_delivered('slack', v_id);
  update slack_outbox set next_attempt_at = now() - interval '1 second' where id = v_id;
  assert not exists (select 1 from jsonb_array_elements(claim_deliveries(10, false, true, false, '')) e where e->>'id' = v_id::text), 'delivered gone';
  raise notice 'PASS test_claim_deliveries_lease';
end $$;

-- test_delivery_retries_and_giving_up: nieudane próby wydłużają odstęp, a po 8 próbach wiadomość przestaje blokować kolejkę
do $$
declare v_id uuid; v_i int;
begin
  v_id := enqueue_slack('stock_digest', 'Zawsze błąd', 'cl-2');
  perform mark_failed('slack', v_id, 'HTTP 500');
  assert (select attempts from slack_outbox where id = v_id) = 1, 'attempts 1';
  assert (select next_attempt_at > now() + interval '1 minute' from slack_outbox where id = v_id), 'backoff set';
  assert (select last_error from slack_outbox where id = v_id) = 'HTTP 500', 'error stored';
  assert not exists (select 1 from jsonb_array_elements(claim_deliveries(10, false, true, false, '')) e where e->>'id' = v_id::text), 'not claimed during backoff';
  for v_i in 2..8 loop perform mark_failed('slack', v_id, 'HTTP 500'); end loop;
  assert (select failed_at is not null from slack_outbox where id = v_id), 'given up after 8';
  update slack_outbox set next_attempt_at = now() - interval '1 second' where id = v_id;
  assert not exists (select 1 from jsonb_array_elements(claim_deliveries(10, false, true, false, '')) e where e->>'id' = v_id::text), 'never claimed again';
  raise notice 'PASS test_delivery_retries_and_giving_up';
end $$;

-- test_email_allowlist_in_claim: maile tylko na dozwolone adresy i tylko przy włączonej wysyłce; zablokowane nie głodzą Slacka
do $$
declare v_o uuid; v_ok uuid; v_slack uuid; v_i int; v_c jsonb;
begin
  v_o := pg_temp.new_order('th-4', '00000000-0000-0000-0000-0000000000c1', 'obcy@example.com');
  -- 25 zablokowanych maili jest starszych niż wiadomość Slack
  for v_i in 1..25 loop
    perform enqueue_email(v_o, case when v_i % 2 = 0 then 'needs_info' else 'owner_alert' end, 'obcy' || v_i || '@example.com', 'Temat', 'Treść')
      where v_i <= 2;
  end loop;
  insert into email_outbox (order_id, kind, to_email, subject, body, created_at)
  select v_o, 'order_done', 'obcy' || g || '@example.com', 'Blokada ' || g, 'x', now() - interval '1 hour' from generate_series(1, 25) g
  on conflict do nothing;
  v_slack := enqueue_slack('stock_digest', 'Czeka za mailami', 'cl-3');

  -- wysyłka maili wyłączona: żaden mail nie jest wydawany, a Slack przechodzi mimo limitu 5
  v_c := claim_deliveries(5, false, true, false, 'portfolio@gmail.com');
  assert not exists (select 1 from jsonb_array_elements(v_c) e where e->>'channel' = 'email'), 'no email when off';
  assert exists (select 1 from jsonb_array_elements(v_c) e where e->>'id' = v_slack::text), 'slack not starved';

  -- wysyłka włączona: tylko adresy z listy (pełny adres lub @domena), bez rozróżniania wielkości liter
  update email_outbox set next_attempt_at = now() where order_id = v_o;
  v_ok := (select id from email_outbox where order_id = v_o and kind = 'owner_alert');
  update email_outbox set to_email = 'Portfolio@Gmail.com' where id = v_ok;
  v_c := claim_deliveries(5, false, false, true, ' portfolio@gmail.com , @firma.pl ');
  assert (select count(*) from jsonb_array_elements(v_c) e where e->>'channel' = 'email') = 1, 'only allowed: ' || v_c::text;
  assert v_c->0->>'id' = v_ok::text, 'the allowed one';

  update email_outbox set to_email = 'jan@firma.pl', next_attempt_at = now() where id = v_ok;
  assert jsonb_array_length(claim_deliveries(5, false, false, true, '@firma.pl')) = 1, 'domain match';
  update email_outbox set to_email = 'jan@evilfirma.pl', next_attempt_at = now() where id = v_ok;
  assert jsonb_array_length(claim_deliveries(5, false, false, true, '@firma.pl')) = 0, 'no suffix trick';
  update email_outbox set to_email = 'jan@firma.pl.evil.com', next_attempt_at = now() where id = v_ok;
  assert jsonb_array_length(claim_deliveries(5, false, false, true, '@firma.pl')) = 0, 'no prefix trick';
  update email_outbox set to_email = 'jan@firma.pl', next_attempt_at = now() where id = v_ok;
  assert jsonb_array_length(claim_deliveries(5, false, false, true, '')) = 0, 'empty allowlist allows nothing';
  raise notice 'PASS test_email_allowlist_in_claim';
end $$;

-- test_claim_test_filter: tryb testowy widzi wyłącznie wiadomości oznaczone jako testowe
do $$
declare v_o uuid; v_real uuid; v_test uuid; v_c jsonb;
begin
  v_o := pg_temp.new_order('th-5', '00000000-0000-0000-0000-0000000000c1');
  v_real := enqueue_slack('stock_digest', 'Prawdziwa', 'real-9');
  v_test := enqueue_slack('stock_digest', 'Testowa', 'deliver-test-9');
  v_c := claim_deliveries(50, true, true, false, '');
  assert exists (select 1 from jsonb_array_elements(v_c) e where e->>'id' = v_test::text), 'sees test';
  assert not exists (select 1 from jsonb_array_elements(v_c) e where e->>'id' = v_real::text), 'does not see real';
  raise notice 'PASS test_claim_test_filter';
end $$;

rollback;
