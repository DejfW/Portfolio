-- Task 8: follow-upy wycen (3. i 7. dzień), automatyczne `lost` po 14 dniach i ankieta powodów rezygnacji.
begin;

-- zamówienia z seeda nie mogą wpaść w okna testu
update orders set quoted_at = now() where status = 'quoted';
update orders set status = 'done' where status = 'lost';

-- quoted_at ustawiamy w przeszłości; wycena ma etykiety pozycji i sumę
create function pg_temp.mk(p_ext text, p_status text, p_days numeric, p_sent int default 0) returns uuid
language sql as $$
  insert into orders (external_id, source, customer_email, kind, status, quote, quoted_at, followups_sent)
  values (p_ext, 'form', p_ext || '@example.com', 'catalog', p_status,
          '{"total": 2400, "lines": [{"label": "Komoda dębowa, 4 szuflady", "qty": 1}]}'::jsonb,
          now() - make_interval(secs => p_days * 86400), p_sent)
  returning id
$$;

-- test_followup_day3
do $$
declare a uuid := pg_temp.mk('f-d4', 'quoted', 4); b uuid := pg_temp.mk('f-d2', 'quoted', 2);
begin
  assert (select followup_no from quotes_due_followup() where order_id = a) = 1, 'day 4 -> reminder 1';
  assert not exists (select 1 from quotes_due_followup() where order_id = b), 'day 2 -> nothing';
  assert (select quote->>'total' from quotes_due_followup() where order_id = a) = '2400', 'quote returned';
  raise notice 'PASS test_followup_day3';
end $$;

-- test_followup_day7: po pierwszym przypomnieniu drugie dopiero po 7 dniach; bez pierwszego najpierw numer 1
do $$
declare a uuid := pg_temp.mk('f-d8s1', 'quoted', 8, 1); b uuid := pg_temp.mk('f-d8s0', 'quoted', 8, 0);
        c uuid := pg_temp.mk('f-d5s1', 'quoted', 5, 1);
begin
  assert (select followup_no from quotes_due_followup() where order_id = a) = 2, 'day 8 after #1 -> reminder 2';
  assert (select followup_no from quotes_due_followup() where order_id = b) = 1, 'missed #1 -> still #1 first';
  assert not exists (select 1 from quotes_due_followup() where order_id = c), 'day 5 after #1 -> not yet';
  raise notice 'PASS test_followup_day7';
end $$;

-- test_no_followup_after_approved, po 14 dniach i po statusie lost
do $$
declare a uuid := pg_temp.mk('f-appr', 'approved', 5); b uuid := pg_temp.mk('f-old', 'quoted', 15);
        c uuid := pg_temp.mk('f-lost', 'lost', 5); d uuid := pg_temp.mk('f-new', 'new', 5);
begin
  assert not exists (select 1 from quotes_due_followup() where order_id in (a, b, c, d)), 'no reminders for approved/old/lost/new';
  raise notice 'PASS test_no_followup_after_approved';
end $$;

-- test_record_followup_idempotent: mail i licznik w jednej transakcji, ponowienie niczego nie dubluje
do $$
declare a uuid := pg_temp.mk('f-rec', 'quoted', 4); b uuid := pg_temp.mk('f-rec2', 'quoted', 4);
        c uuid := pg_temp.mk('f-rec3', 'approved', 4);
begin
  assert record_followup(a, 1, 'Przypomnienie', 'Treść'), 'first call succeeds';
  assert (select followups_sent from orders where id = a) = 1, 'counter moved';
  assert (select count(*) from email_outbox where order_id = a and kind = 'followup_1' and to_email = 'f-rec@example.com') = 1, 'mail queued';
  assert not record_followup(a, 1, 'Przypomnienie', 'Treść'), 'second call is a no-op';
  assert (select count(*) from email_outbox where order_id = a) = 1, 'no duplicate mail';
  assert not record_followup(b, 2, 's', 'b'), 'cannot skip reminder 1';
  assert (select followups_sent from orders where id = b) = 0, 'counter unchanged';
  assert not record_followup(c, 1, 's', 'b'), 'not for approved orders';
  assert not exists (select 1 from quotes_due_followup() where order_id = a), 'not due again right after #1';
  begin
    perform record_followup(b, 1, '', 'b');
    assert false, 'empty subject must be rejected';
  exception when others then
    assert sqlerrm = 'INVALID_MAIL', sqlerrm;
  end;
  raise notice 'PASS test_record_followup_idempotent';
end $$;

-- test_mark_lost_after_15_days
do $$
declare old_o uuid := pg_temp.mk('l-15', 'quoted', 15); young uuid := pg_temp.mk('l-13', 'quoted', 13);
        appr uuid := pg_temp.mk('l-appr', 'approved', 20); n int;
begin
  select count(*) into n from mark_lost_quotes(14, 'http://localhost:5678') x where x in (old_o, young, appr);
  assert n = 1, 'only the 15-day quote is lost, got ' || n;
  assert (select status from orders where id = old_o) = 'lost', '15 days -> lost';
  assert (select status from orders where id = young) = 'quoted', '13 days stays quoted';
  assert (select status from orders where id = appr) = 'approved', 'approved untouched';
  assert exists (select 1 from email_outbox e join orders o on o.id = e.order_id
                 where e.order_id = old_o and e.kind = 'lost_survey'
                   and e.body like '%http://localhost:5678/webhook/lost-reason?token=' || o.public_token || '%'), 'survey mail with link';
  select count(*) into n from mark_lost_quotes(14, 'http://localhost:5678');
  assert n = 0, 'second run does nothing, got ' || n;
  assert (select count(*) from email_outbox where order_id = old_o and kind = 'lost_survey') = 1, 'one survey mail';
  raise notice 'PASS test_mark_lost_after_15_days';
end $$;

-- test_mark_lost_url_and_days_validated: błędny adres przerywa operację bez zmian, NULL pomija ankietę, końcowy / jest przycinany
do $$
declare a uuid := pg_temp.mk('l-bad-url', 'quoted', 20);
begin
  begin
    perform mark_lost_quotes(14, 'javascript:alert(1)');
    assert false, 'bad url must raise';
  exception when others then
    assert sqlerrm = 'INVALID_PUBLIC_URL', sqlerrm;
  end;
  assert (select status from orders where id = a) = 'quoted', 'nothing changed after a config error';

  perform mark_lost_quotes(14, null);
  assert (select status from orders where id = a) = 'lost', 'lost without survey when url is null';
  assert not exists (select 1 from email_outbox where order_id = a), 'no survey mail without a url';

  a := pg_temp.mk('l-slash', 'quoted', 20);
  perform mark_lost_quotes(14, 'https://stolarnia.example/');
  assert exists (select 1 from email_outbox where order_id = a and body like '%https://stolarnia.example/webhook/lost-reason?token=%'),
         'trailing slash normalised';
  begin
    perform mark_lost_quotes(0);
    assert false, 'days < 1 must be rejected';
  exception when others then
    assert sqlerrm = 'INVALID_DAYS', sqlerrm;
  end;
  raise notice 'PASS test_mark_lost_url_and_days_validated';
end $$;

-- test_record_followup_window_rechecked: pod blokadą sprawdzamy ponownie okna 3/7/14 dni (granice dokładne)
do $$
declare a uuid; b uuid; c uuid; d uuid; e uuid;
begin
  a := pg_temp.mk('w-3d', 'quoted', 3);          -- dokładnie 3 dni: należy się
  b := pg_temp.mk('w-3d-1s', 'quoted', 2.99999); -- 1 sekunda za wcześnie
  c := pg_temp.mk('w-5-no2', 'quoted', 5, 1);    -- nr 2 dopiero po 7 dniach
  d := pg_temp.mk('w-14d', 'quoted', 14);        -- dokładnie 14 dni: tylko lost
  e := pg_temp.mk('w-7d', 'quoted', 7, 1);       -- dokładnie 7 dni po nr 1: należy się nr 2
  assert exists (select 1 from quotes_due_followup() where order_id = a), '3 days is due';
  assert not exists (select 1 from quotes_due_followup() where order_id = b), '3 days minus 1s is not due';
  assert record_followup(a, 1, 's', 'b'), 'recorded at the boundary';
  assert not record_followup(b, 1, 's', 'b'), 'too early is rejected under lock';
  assert not record_followup(c, 2, 's', 'b'), 'reminder 2 before 7 days is rejected';
  assert not record_followup(d, 1, 's', 'b'), 'quote at 14 days gets no reminder';
  assert record_followup(e, 2, 's', 'b'), 'reminder 2 at 7 days';
  raise notice 'PASS test_record_followup_window_rechecked';
end $$;

-- test_record_lost_reason
do $$
declare a uuid := pg_temp.mk('r-lost', 'lost', 20); b uuid := pg_temp.mk('r-quoted', 'quoted', 2);
        ta uuid; tb uuid; r jsonb;
begin
  select public_token into ta from orders where id = a;
  select public_token into tb from orders where id = b;
  assert (lost_reason_context(ta)->>'status') = 'lost' and not (lost_reason_context(ta)->>'answered')::boolean, 'context before answer';
  r := record_lost_reason(ta, 'price');
  assert (r->>'ok')::boolean, r::text;
  assert (select reason from lost_reasons where order_id = a) = 'price', 'reason stored';
  assert record_lost_reason(ta, 'time')->>'error' = 'ALREADY_ANSWERED', 'first answer wins';
  assert (select reason from lost_reasons where order_id = a) = 'price', 'reason not overwritten';
  assert record_lost_reason(ta, 'bo tak')->>'error' = 'INVALID_REASON', 'unknown reason';
  assert record_lost_reason(tb, 'price')->>'error' = 'ORDER_NOT_LOST', 'only lost orders';
  assert record_lost_reason(gen_random_uuid(), 'price')->>'error' = 'ORDER_NOT_FOUND', 'unknown token';
  assert (lost_reason_context(ta)->>'answered')::boolean, 'context after answer';
  assert lost_reason_context(gen_random_uuid()) is null, 'unknown token has no context';
  raise notice 'PASS test_record_lost_reason';
end $$;

rollback;
