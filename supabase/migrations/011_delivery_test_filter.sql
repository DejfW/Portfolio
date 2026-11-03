-- pending_deliveries z filtrem testowym: przy p_only_test = true zwraca wyłącznie wiadomości
-- oznaczone jako testowe (Slack: klucz deduplikacji zaczyna się od "deliver-test-", mail: temat od
-- "[deliver-test]"). Dzięki temu test dostarczania nie oznaczy prawdziwych wiadomości jako wysłanych.
drop function pending_deliveries(int);

create function pending_deliveries(p_limit int default 50, p_only_test boolean default false) returns jsonb
language sql stable set search_path = public, pg_temp as $$
  with u as (
    select jsonb_build_object('channel', 'slack', 'id', id, 'kind', kind, 'text', text) as x, created_at
    from slack_outbox
    where sent_at is null and (not p_only_test or dedupe_key like 'deliver-test-%')
    union all
    select jsonb_build_object('channel', 'email', 'id', id, 'kind', kind, 'to', to_email,
                              'subject', subject, 'text', body), created_at
    from email_outbox
    where sent_at is null and (not p_only_test or subject like '[deliver-test]%')),
  l as (select * from u order by created_at limit greatest(p_limit, 0))
  select coalesce(jsonb_agg(x order by created_at), '[]'::jsonb) from l
$$;
