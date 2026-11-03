-- Zapisuje komplet powiadomień (Slack i maile) jednym wywołaniem i atomowo: albo wszystkie, albo żadne.
-- Dzięki temu workflow n8n nie musi rozgałęziać się na kanały, a ponowienie niczego nie dubluje
-- (klucze deduplikacji w slack_outbox i unikalność (zamówienie, rodzaj) w email_outbox).
-- p: [{channel:'slack', kind, text, dedupe_key} | {channel:'email', order_id, kind, to, subject, body}]
create function enqueue_notifications(p jsonb) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare
  n    jsonb;
  v_id uuid;
  v_q  int := 0;
  v_s  int := 0;
begin
  if jsonb_typeof(p) is distinct from 'array' then
    return jsonb_build_object('error', 'INVALID_NOTIFICATIONS');
  end if;
  if jsonb_array_length(p) > 20 then
    return jsonb_build_object('error', 'TOO_MANY_NOTIFICATIONS');
  end if;

  for n in select * from jsonb_array_elements(p) loop
    if n->>'channel' = 'slack' then
      v_id := enqueue_slack(n->>'kind', n->>'text', n->>'dedupe_key');
    elsif n->>'channel' = 'email' then
      v_id := enqueue_email((n->>'order_id')::uuid, n->>'kind', n->>'to', n->>'subject', n->>'body');
    else
      raise exception 'INVALID_NOTIFICATION';
    end if;
    if v_id is null then v_s := v_s + 1; else v_q := v_q + 1; end if;
  end loop;

  return jsonb_build_object('queued', v_q, 'skipped', v_s);
end $$;
