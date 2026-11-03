-- Przyjęcie zamówienia odporne na awarie (poprawki po recenzji Task 3).
--  1. intake_receive zapisuje zgłoszenie PRZED odpowiedzią HTTP i przed wywołaniem AI,
--     więc 200 oznacza, że zamówienie jest trwale w bazie, a atomowy INSERT rozstrzyga wyścig.
--  2. intake_complete domyka je po odpowiedzi AI (raz; drugie wywołanie niczego nie zmienia).
--  3. Maile są liczone ze stanu zamówienia w bazie (notification_context), więc ten sam kod
--     obsługuje przepływ normalny i naprawę po awarii (orders_missing_notifications).
--  4. mark_stuck_intakes oznacza zgłoszenia, które nie doczekały się wyniku AI.

drop function intake_order(jsonb);
drop function intake_status(text);

-- Zapisuje surowe zgłoszenie. created = false oznacza, że takie external_id już jest.
create function intake_receive(p jsonb) returns jsonb
language plpgsql as $$
declare
  v_id  uuid;
  v_ext text := p->>'external_id';
begin
  if coalesce(v_ext, '') = '' then
    raise exception 'MISSING_EXTERNAL_ID';
  end if;

  insert into orders (external_id, source, customer_email, kind, status, raw_text)
  values (v_ext, p->>'source', p->>'customer_email', 'catalog', 'new', p->>'raw_text')
  on conflict (external_id) do nothing
  returning id into v_id;

  if v_id is not null then
    return jsonb_build_object('order_id', v_id, 'created', true, 'status', 'new');
  end if;
  return (select jsonb_build_object('order_id', id, 'created', false, 'status', status)
          from orders where external_id = v_ext);
end $$;

-- Domyka zgłoszenie wynikiem AI. route: 'ok' -> wycena, 'needs_info' -> brakuje danych od klienta,
-- 'needs_review' -> sprawdza człowiek. Działa tylko na zamówieniu w stanie 'new'; w innym
-- (już domknięte albo oznaczone jako utknięte) zwraca completed = false i niczego nie zmienia.
create function intake_complete(p_order_id uuid, p jsonb) returns jsonb
language plpgsql as $$
declare
  v_route  text := p->>'route';
  v_status text;
  v_quote  jsonb;
begin
  if coalesce(v_route, '') not in ('ok', 'needs_info', 'needs_review') then
    raise exception 'INVALID_ROUTE:%', coalesce(v_route, 'null');
  end if;

  select status into v_status from orders where id = p_order_id for update;
  if not found then
    raise exception 'ORDER_NOT_FOUND';
  end if;
  if v_status <> 'new' then
    return jsonb_build_object('order_id', p_order_id, 'completed', false, 'status', v_status);
  end if;

  update orders
  set kind = p->>'kind', parsed = p->'parsed',
      status = case v_route when 'ok' then 'new' else v_route end
  where id = p_order_id;

  insert into order_items (order_id, product_id, custom_spec, qty)
  select p_order_id, (e->>'product_id')::uuid, nullif(e->'custom_spec', 'null'::jsonb), coalesce((e->>'qty')::int, 1)
  from jsonb_array_elements(coalesce(p->'items', '[]')) e;

  if v_route = 'ok' then
    v_quote := estimate_quote(p_order_id);
  end if;

  return jsonb_build_object(
    'order_id', p_order_id, 'completed', true,
    'status', (select status from orders where id = p_order_id),
    'quote', v_quote);
end $$;

-- Zgłoszenia zapisane, ale niedomknięte po p_older_than_seconds (awaria n8n, timeout AI) idą do
-- ręcznego sprawdzenia. Powiadomienie dla właściciela powstaje zwykłą ścieżką (notification_context).
create function mark_stuck_intakes(p_older_than_seconds int default 600) returns jsonb
language sql as $$
  with s as (
    update orders o
    set status = 'needs_review', parsed = jsonb_build_object('reason', 'STUCK_INTAKE')
    where o.status = 'new' and o.parsed is null and o.quote is null
      and not exists (select 1 from order_items i where i.order_id = o.id)
      and o.created_at < now() - make_interval(secs => p_older_than_seconds)
    returning 1)
  select jsonb_build_object('marked', count(*)) from s
$$;

-- Komplet maili dla zamówienia w danym statusie:
--   quoted -> customer_quote + owner_alert, needs_info -> needs_info, needs_review -> owner_alert.
-- Dotyczy tylko zamówień przyjętych przez intake (parsed IS NOT NULL); dane demo są pomijane.
create function orders_missing_notifications(p_older_than_seconds int default 120)
returns table (order_id uuid)
language sql stable as $$
  select o.id
  from orders o
  where o.parsed is not null
    and o.created_at < now() - make_interval(secs => p_older_than_seconds)
    and case o.status
      when 'quoted' then
        not exists (select 1 from email_outbox e where e.order_id = o.id and e.kind = 'customer_quote')
        or not exists (select 1 from email_outbox e where e.order_id = o.id and e.kind = 'owner_alert')
      when 'needs_info' then
        not exists (select 1 from email_outbox e where e.order_id = o.id and e.kind = 'needs_info')
      when 'needs_review' then
        not exists (select 1 from email_outbox e where e.order_id = o.id and e.kind = 'owner_alert')
      else false
    end
$$;

-- Wszystko, czego n8n potrzebuje do złożenia maili. NULL, gdy nie ma takiego zamówienia.
create function notification_context(p_order_id uuid) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'order_id', o.id,
    'status', o.status,
    'customer_email', o.customer_email,
    'source', o.source,
    'raw_text', o.raw_text,
    'quote', o.quote,
    'missing', coalesce(o.parsed->'missing', '[]'::jsonb),
    'reason', coalesce(o.quote->>'error', o.parsed->>'reason'),
    'existing_kinds', coalesce((select jsonb_agg(e.kind order by e.kind)
                                from email_outbox e where e.order_id = o.id), '[]'::jsonb))
  from orders o
  where o.id = p_order_id
$$;
