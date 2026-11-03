-- Task 4: enqueue_notifications zapisuje komplet powiadomień (Slack i maile) jednym wywołaniem.
begin;

do $$
declare v_o uuid; v_r jsonb;
begin
  v_o := upsert_order(jsonb_build_object('external_id', 'nf-1', 'source', 'form',
    'customer_email', 'k@example.com', 'kind', 'catalog'));

  v_r := enqueue_notifications(jsonb_build_array(
    jsonb_build_object('channel', 'slack', 'kind', 'task_done', 'text', 'Gotowe', 'dedupe_key', 'nf-k1'),
    jsonb_build_object('channel', 'email', 'order_id', v_o, 'kind', 'order_done', 'to', 'k@example.com',
                       'subject', 'Gotowe', 'body', 'Treść')));
  assert (v_r->>'queued')::int = 2 and (v_r->>'skipped')::int = 0, 'queued: ' || v_r::text;
  assert (select count(*) from slack_outbox where dedupe_key = 'nf-k1') = 1, 'slack row';
  assert (select count(*) from email_outbox where order_id = v_o and kind = 'order_done') = 1, 'email row';

  -- ponowienie niczego nie dubluje
  v_r := enqueue_notifications(jsonb_build_array(
    jsonb_build_object('channel', 'slack', 'kind', 'task_done', 'text', 'Gotowe', 'dedupe_key', 'nf-k1'),
    jsonb_build_object('channel', 'email', 'order_id', v_o, 'kind', 'order_done', 'to', 'k@example.com',
                       'subject', 'Gotowe', 'body', 'Treść')));
  assert (v_r->>'queued')::int = 0 and (v_r->>'skipped')::int = 2, 'repeat: ' || v_r::text;

  -- pusta lista to nie błąd
  assert (enqueue_notifications('[]'::jsonb)->>'queued')::int = 0, 'empty list';
  raise notice 'PASS test_enqueue_notifications';
end $$;

-- test_enqueue_notifications_atomic: jeden błędny element cofa cały zestaw
do $$
declare v_o uuid;
begin
  v_o := upsert_order(jsonb_build_object('external_id', 'nf-2', 'source', 'form',
    'customer_email', 'k@example.com', 'kind', 'catalog'));
  begin
    perform enqueue_notifications(jsonb_build_array(
      jsonb_build_object('channel', 'slack', 'kind', 'task_done', 'text', 'Dobra', 'dedupe_key', 'nf-k2'),
      jsonb_build_object('channel', 'fax', 'text', 'Zła')));
    assert false, 'should have raised';
  exception when others then
    assert sqlerrm = 'INVALID_NOTIFICATION', 'wrong error: ' || sqlerrm;
  end;
  assert not exists (select 1 from slack_outbox where dedupe_key = 'nf-k2'), 'rolled back';
  assert enqueue_notifications('{"a":1}'::jsonb)->>'error' = 'INVALID_NOTIFICATIONS', 'not an array';
  assert enqueue_notifications((select jsonb_agg(jsonb_build_object('channel','slack','kind','task_done','text','x','dedupe_key', 'm' || g))
    from generate_series(1, 21) g))->>'error' = 'TOO_MANY_NOTIFICATIONS', 'too many';
  raise notice 'PASS test_enqueue_notifications_atomic';
end $$;

rollback;
