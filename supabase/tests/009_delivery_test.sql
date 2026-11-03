-- Task 4: tryb testowy dostarczania nie może dotknąć prawdziwych wiadomości.
begin;

do $$
declare v_o uuid; v_real uuid; v_test uuid; v_email_real uuid; v_email_test uuid; v_p jsonb;
begin
  v_o := upsert_order(jsonb_build_object('external_id', 'dl-1', 'source', 'form',
    'customer_email', 'k@example.com', 'kind', 'catalog'));
  v_real := enqueue_slack('stock_digest', 'Prawdziwa wiadomość', 'real-1');
  v_test := enqueue_slack('stock_digest', 'Testowa wiadomość', 'deliver-test-1');
  v_email_real := enqueue_email(v_o, 'needs_info', 'k@example.com', 'Prawdziwy temat', 'Treść');
  v_email_test := enqueue_email(v_o, 'order_done', 'k@example.com', '[deliver-test] Temat', 'Treść');

  -- tryb zwykły widzi wszystko
  v_p := pending_deliveries(100, false);
  assert (select count(*) from jsonb_array_elements(v_p) e where e->>'id' in (v_real::text, v_test::text, v_email_real::text, v_email_test::text)) = 4, 'normal sees all';

  -- tryb testowy widzi tylko oznaczone wiadomości
  v_p := pending_deliveries(100, true);
  assert (select count(*) from jsonb_array_elements(v_p) e where e->>'id' in (v_test::text, v_email_test::text)) = 2, 'test sees marked';
  assert not exists (select 1 from jsonb_array_elements(v_p) e where e->>'id' in (v_real::text, v_email_real::text)), 'test does not see real ones';

  -- jednoargumentowe wywołanie nadal działa (zgodność z Task 4: pending_deliveries(100))
  assert jsonb_typeof(pending_deliveries(100)) = 'array', 'default arg';
  raise notice 'PASS test_pending_deliveries_test_filter';
end $$;

rollback;
