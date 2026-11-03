-- Task 10: statusy zamówień (oś czasu dla klienta), powiadomienia o zmianie statusu i prośby o opinię.
begin;

delete from order_events;

create function pg_temp.mk(p_ext text, p_status text default 'new') returns uuid
language sql as $$
  insert into orders (external_id, source, customer_email, kind, status, quote)
  values (p_ext, 'form', p_ext || '@example.com', 'catalog', p_status, '{"total": 1234.5, "lines": [{"label": "Komoda", "qty": 1}]}'::jsonb)
  returning id
$$;

-- test_trigger_logs_status_change i test_no_event_when_status_same
do $$
declare a uuid := pg_temp.mk('ev-1');
begin
  assert (select count(*) from order_events where order_id = a) = 0, 'no event on insert';
  update orders set status = 'quoted' where id = a;
  update orders set status = 'quoted' where id = a;                 -- ten sam status
  update orders set customer_name = 'Jan' where id = a;             -- inne pole
  assert (select count(*) from order_events where order_id = a) = 1, 'exactly one event';
  assert (select old_status || '>' || new_status from order_events where order_id = a) = 'new>quoted', 'old and new status';
  update orders set status = 'in_progress' where id = a;
  assert (select count(*) from order_events where order_id = a) = 2, 'second transition logged';
  raise notice 'PASS test_trigger_logs_status_change';
end $$;

-- test_public_status_hides_internals: oś czasu bez e-maila, cen, identyfikatorów i danych wewnętrznych
do $$
declare a uuid := pg_temp.mk('pub-1', 'quoted'); t uuid; r jsonb;
begin
  update orders set status = 'in_progress' where id = a;
  select public_token into t from orders where id = a;
  r := order_status_public(t);
  assert r->>'status' = 'in_progress' and r->>'label_pl' = 'W realizacji', r::text;
  assert jsonb_array_length(r->'timeline') = 2, 'quoted and in_progress after creation: ' || r::text;   -- przyjęte + w realizacji
  assert (r->'timeline'->0->>'label_pl') = 'Zamówienie przyjęte', r::text;
  assert (r->'timeline'->1->>'label_pl') = 'W realizacji', r::text;
  assert r::text !~* ('pub-1|example\.com|1234|quote|customer|email|total|price|' || a::text || '|' || t::text), 'no internals leaked: ' || r::text;
  assert order_status_public(gen_random_uuid()) = '{}'::jsonb and order_status_public(null) = '{}'::jsonb, 'unknown token gives empty object';
  assert has_function_privilege('anon', 'order_status_public(uuid)', 'execute'), 'anon may call the status function';
  raise notice 'PASS test_public_status_hides_internals';
end $$;

-- test_public_status_timeline_collapses: kolejne zmiany w obrębie jednego etapu są jednym wpisem
do $$
declare a uuid := pg_temp.mk('pub-2'); t uuid; r jsonb;
begin
  update orders set status = 'needs_review' where id = a;
  update orders set status = 'quoted' where id = a;
  update orders set status = 'approved' where id = a;
  update orders set status = 'in_progress' where id = a;
  update orders set status = 'done' where id = a;
  select public_token into t from orders where id = a;
  r := order_status_public(t);
  assert (select string_agg(x->>'label_pl', ' > ') from jsonb_array_elements(r->'timeline') x) =
         'Zamówienie przyjęte > Wyceniono > Zatwierdzone > W realizacji > Gotowe', r::text;
  assert r->>'status' = 'done' and r->>'label_pl' = 'Gotowe', r::text;
  raise notice 'PASS test_public_status_timeline_collapses';
end $$;

-- test_notify_status_events
do $$
declare a uuid := pg_temp.mk('n-1', 'quoted'); b uuid := pg_temp.mk('n-2', 'quoted'); c uuid := pg_temp.mk('n-3', 'quoted');
        d uuid := pg_temp.mk('n-4', 'quoted'); e uuid := pg_temp.mk('n-5', 'quoted'); t uuid; n int;
begin
  update order_events set notified_at = now();   -- zdarzenia z wcześniejszych testów nie należą do tego
  update orders set status = 'in_progress' where id = a;
  update orders set status = 'approved' where id = b; update orders set status = 'in_progress' where id = b;      -- dwa zdarzenia, jedno powiadomienie
  update orders set status = 'done' where id = c;                                                               -- done ma osobny mail order_done
  update orders set status = 'in_progress' where id = d; update orders set status = 'done' where id = d;        -- stan już się zmienił
  update orders set status = 'in_progress' where id = e;
  update order_events set created_at = now() - interval '4 days' where order_id = e;                            -- przestarzałe po awarii

  select public_token into t from orders where id = a;
  n := notify_status_events('http://localhost:8080');
  assert n = 2, 'two notifications (a and b), got ' || n;
  assert exists (select 1 from email_outbox where order_id = a and kind = 'status_in_progress' and to_email = 'n-1@example.com'
                 and body like '%http://localhost:8080/status.html?token=' || t || '%'), 'status mail with link';
  assert (select count(*) from email_outbox where order_id = b) = 1 and exists (select 1 from email_outbox where order_id = b and kind = 'status_in_progress'),
         'approved+in_progress collapsed into one mail';
  assert not exists (select 1 from email_outbox where order_id in (c, d, e) and kind like 'status_%'), 'no status mail for done, outdated state or old event';
  assert not exists (select 1 from order_events where notified_at is null), 'all events handled';
  assert notify_status_events('http://localhost:8080') = 0, 'second run does nothing';
  assert (select count(*) from email_outbox where kind like 'status_%') = 2, 'no duplicates';
  raise notice 'PASS test_notify_status_events';
end $$;

-- test_notify_url_validation: błędny adres przerywa operację bez zmian, NULL wysyła mail bez linku
do $$
declare a uuid := pg_temp.mk('u-1', 'quoted');
begin
  update orders set status = 'in_progress' where id = a;
  begin
    perform notify_status_events('javascript:alert(1)');
    assert false, 'bad url must raise';
  exception when others then
    assert sqlerrm = 'INVALID_STATUS_URL', sqlerrm;
  end;
  assert exists (select 1 from order_events where order_id = a and notified_at is null), 'nothing changed after a config error';
  assert notify_status_events(null) >= 1, 'null url still notifies';
  assert (select body not like '%status.html%' from email_outbox where order_id = a and kind = 'status_in_progress'), 'no link without url';
  raise notice 'PASS test_notify_url_validation';
end $$;

-- test_review_request: 7 dni po done, raz, tylko dla zamówień z naszego zdarzenia done i bez zbyt starych
do $$
declare a uuid := pg_temp.mk('r-1', 'quoted'); b uuid := pg_temp.mk('r-2', 'quoted'); c uuid := pg_temp.mk('r-3', 'quoted');
        d uuid := pg_temp.mk('r-4', 'quoted'); e uuid := pg_temp.mk('r-legacy', 'done'); t uuid; n int;
begin
  update orders set status = 'done' where id in (a, b, c, d);
  update order_events set created_at = now() - interval '8 days' where order_id = a and new_status = 'done';
  update order_events set created_at = now() - interval '6 days' where order_id = b and new_status = 'done';
  update order_events set created_at = now() - interval '70 days' where order_id = c and new_status = 'done';
  update order_events set created_at = now() - interval '8 days' where order_id = d and new_status = 'done';
  update orders set status = 'in_progress' where id = d;   -- zamówienie otwarte ponownie

  assert (select count(*) from orders_due_review() x where x = a) = 1, 'a is due';
  assert not exists (select 1 from orders_due_review() x where x in (b, c, d, e)), '6 days, 70 days, reopened and legacy (no event) are not due';
  select public_token into t from orders where id = a;
  n := send_review_requests('https://g.page/r/demo/review');
  assert n = 1, 'one request, got ' || n;
  assert exists (select 1 from email_outbox where order_id = a and kind = 'review_request' and to_email = 'r-1@example.com'
                 and body like '%https://g.page/r/demo/review%' and body like '%zdjęcie%'), 'review mail with link and photo request';
  assert (select review_requested_at is not null from orders where id = a), 'marked as requested';
  assert send_review_requests('https://g.page/r/demo/review') = 0, 'only once';
  assert not exists (select 1 from orders_due_review() x where x = a), 'no longer due';
  assert send_review_requests(null) = 0, 'no url configured: nothing sent';
  begin
    perform send_review_requests('http://nie-https.example/x');
    assert false, 'non-https url must raise';
  exception when others then
    assert sqlerrm = 'INVALID_REVIEW_URL', sqlerrm;
  end;
  assert (select count(*) from email_outbox where kind = 'review_request') = 1, 'one review mail in total';
  raise notice 'PASS test_review_request';
end $$;

-- test_notify_isolates_bad_records: jeden wadliwy adres nie blokuje pozostałych, a jego zdarzenie czeka na ponowienie
do $$
declare bad uuid := pg_temp.mk('iso-bad', 'quoted'); good uuid := pg_temp.mk('iso-good', 'quoted'); n int;
begin
  update order_events set notified_at = now();
  update orders set customer_email = '' where id = bad;
  update orders set status = 'in_progress' where id in (bad, good);
  n := notify_status_events(null);
  assert n = 1, 'good order notified despite the bad one, got ' || n;
  assert exists (select 1 from email_outbox where order_id = good and kind = 'status_in_progress'), 'good mail queued';
  assert exists (select 1 from order_events where order_id = bad and notified_at is null), 'bad order event is left for retry';
  assert not exists (select 1 from order_events where order_id = good and notified_at is null), 'good order event marked';
  update orders set customer_email = 'poprawiony@example.com' where id = bad;
  assert notify_status_events(null) = 1, 'retried after the address was fixed';
  raise notice 'PASS test_notify_isolates_bad_records';
end $$;

-- test_event_time_is_real_time: czas zdarzenia to moment zmiany, a nie początek transakcji
do $$
declare a uuid := pg_temp.mk('clk-1', 'quoted'); t1 timestamptz; t2 timestamptz;
begin
  update orders set status = 'approved' where id = a;
  perform pg_sleep(0.05);
  update orders set status = 'in_progress' where id = a;
  select min(created_at), max(created_at) into t1, t2 from order_events where order_id = a;
  assert t2 >= t1 + interval '40 milliseconds' and t2 > now(), 'events carry real time, not the transaction start: ' || t1 || ' / ' || t2;
  raise notice 'PASS test_event_time_is_real_time';
end $$;

-- test_review_cycle: done -> in_progress -> done liczy 7 dni od ostatniego zakończenia
do $$
declare a uuid := pg_temp.mk('cyc-1', 'quoted');
begin
  update orders set status = 'done' where id = a;
  update order_events set created_at = now() - interval '9 days' where order_id = a;
  assert exists (select 1 from orders_due_review() x where x = a), 'due 9 days after the first done';
  update orders set status = 'in_progress' where id = a;
  update orders set status = 'done' where id = a;
  assert not exists (select 1 from orders_due_review() x where x = a), 'not due: the last done is fresh';
  raise notice 'PASS test_review_cycle';
end $$;

rollback;
