-- Atomowe przyjęcie zamówienia po parsowaniu przez AI.

-- Czy zamówienie o danym external_id już istnieje? Pozwala n8n pominąć drogie wywołanie AI.
create function intake_status(p_external_id text) returns jsonb
language sql stable as $$
  select coalesce(
    (select jsonb_build_object('exists', true, 'order_id', id, 'status', status)
     from orders where external_id = p_external_id),
    jsonb_build_object('exists', false))
$$;

-- Zapisuje zamówienie i, jeśli AI dało komplet danych (route = 'ok'), od razu je wycenia.
-- route: 'ok' -> wycena, 'needs_info' -> brakuje danych od klienta, 'needs_review' -> sprawdza człowiek.
-- Zwraca {order_id, created, status, quote}. Istniejący external_id niczego nie zmienia.
create function intake_order(p jsonb) returns jsonb
language plpgsql as $$
declare
  v_route    text := p->>'route';
  v_existing jsonb := intake_status(p->>'external_id');
  v_id       uuid;
  v_quote    jsonb;
begin
  if v_route not in ('ok', 'needs_info', 'needs_review') then
    raise exception 'INVALID_ROUTE:%', coalesce(v_route, 'null');
  end if;

  if (v_existing->>'exists')::boolean then
    return jsonb_build_object('order_id', v_existing->>'order_id', 'created', false,
                              'status', v_existing->>'status');
  end if;

  v_id := upsert_order((p - 'route') || jsonb_build_object(
    'status', case v_route when 'ok' then 'new' else v_route end));

  if v_route = 'ok' then
    v_quote := estimate_quote(v_id);
  end if;

  return jsonb_build_object(
    'order_id', v_id, 'created', true,
    'status', (select status from orders where id = v_id),
    'quote', v_quote);
end $$;
