-- Task 12: zamówienia z salonów stacjonarnych. Tablet w salonie zna kod i token salonu; nazwę salonu
-- i e-mail handlowca zawsze bierzemy z tabeli showrooms, nigdy z żądania.

-- Wspólna walidacja identyfikatora zamówienia i e-maila klienta (kalkulator i salon). NULL = poprawne.
create function _order_input_error(p jsonb) returns text
language sql immutable set search_path = public, pg_temp as $$
  select case
    when p is null or jsonb_typeof(p) <> 'object' then 'INVALID_INPUT'
    when coalesce(p->>'external_id', '') !~ '^[A-Za-z0-9._:@<>+=/-]{1,200}$' then 'INVALID_EXTERNAL_ID'
    when length(btrim(coalesce(p->>'customer_email', ''))) > 200
      or btrim(coalesce(p->>'customer_email', '')) !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then 'INVALID_EMAIL'
  end
$$;

-- Dawne ciało calculator_order, sparametryzowane źródłem zamówienia. Wycena po stronie serwera,
-- idempotencja po external_id, blokada wiersza rozstrzyga równoległe ponowienia.
create function _place_order(p jsonb, p_source text) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare
  v_ext    text := p->>'external_id';
  v_email  text := btrim(coalesce(p->>'customer_email', ''));
  v_notes  text := left(btrim(coalesce(p->>'notes', '')), 1000);
  v_items  jsonb := p->'items';
  v_err    text := _order_input_error(p);
  v_q      jsonb;
  v_id     uuid;
  v_status text;
  v_has_q  boolean;
  v_kind   text;
  v_desc   text;
begin
  if v_err is not null then
    return jsonb_build_object('error', v_err);
  end if;

  v_q := _calculator_quote(v_items);
  if v_q ? 'error' then
    return v_q;
  end if;

  v_kind := case when exists (select 1 from jsonb_array_elements(v_items) e
                              where nullif(e->'custom_spec', 'null'::jsonb) is not null) then 'custom' else 'catalog' end;
  v_desc := case p_source when 'showroom' then 'Zamówienie z salonu' else 'Zamówienie z kalkulatora' end
            || case when v_notes <> '' then E'\nUwagi klienta: ' || v_notes else '' end;

  v_id := upsert_order(jsonb_build_object(
    'external_id', v_ext, 'source', p_source, 'customer_email', v_email, 'kind', v_kind,
    'raw_text', v_desc,
    'parsed', jsonb_build_object('source', case p_source when 'showroom' then 'showroom' else 'calculator' end),
    'items', (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                'product_id', e->>'product_id', 'custom_spec', e->'custom_spec', 'qty', coalesce(e->'qty', '1'::jsonb))))
              from jsonb_array_elements(v_items) e)));

  -- blokada wiersza rozstrzyga równoległe ponowienia: wycenia tylko pierwsze wywołanie
  select status, quote is not null into v_status, v_has_q from orders where id = v_id for update;
  if v_status = 'new' and not v_has_q then
    perform estimate_quote(v_id);
    return jsonb_build_object('order_id', v_id, 'created', true,
      'status', (select status from orders where id = v_id));
  end if;
  return jsonb_build_object('order_id', v_id, 'created', false, 'status', v_status);
end $$;

-- Zamówienie z kalkulatora: to samo zachowanie co wcześniej (testy 012 bez zmian).
create or replace function calculator_order(p jsonb) returns jsonb
language sql set search_path = public, pg_temp as $$
  select _place_order(p, 'form')
$$;

-- Dane salonu dla tabletu: tylko nazwa (bez e-maila handlowca i tokenu). {} dla nieznanego lub wyłączonego.
create function showroom_info(p_code text) returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select coalesce((select jsonb_build_object('name', s.name) from showrooms s where s.code = p_code and s.active),
                  '{}'::jsonb)
$$;

-- Zamówienie albo lead z salonu. Wejście: {external_id, showroom_code, access_token, consent, customer_name,
-- customer_email, items?, notes?}. Z pozycjami: wycena jak w kalkulatorze. Bez pozycji: lead do oceny przez
-- handlowca (needs_review), wymaga niepustej notatki.
create function showroom_order(p jsonb) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare
  v_s      showrooms;
  v_name   text;
  v_notes  text;
  v_err    text;
  v_r      jsonb;
  v_id     uuid;
  v_new    boolean;
  v_items  jsonb;
  v_status text;
  v_src    text;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    return jsonb_build_object('error', 'INVALID_INPUT');
  end if;
  select * into v_s from showrooms where code = p->>'showroom_code' and active;
  if not found then
    return jsonb_build_object('error', 'UNKNOWN_SHOWROOM');
  end if;
  if coalesce(p->>'access_token', '') <> v_s.access_token then
    return jsonb_build_object('error', 'UNAUTHORIZED');
  end if;
  if p->'consent' is distinct from 'true'::jsonb then
    return jsonb_build_object('error', 'NO_CONSENT');
  end if;
  -- identyfikatory salonu mają własną przestrzeń: nie mogą trafić w zamówienie z kalkulatora, maila ani innego salonu
  if coalesce(p->>'external_id', '') not like 'showroom:' || v_s.code || ':%' then
    return jsonb_build_object('error', 'INVALID_EXTERNAL_ID');
  end if;
  v_name := left(btrim(regexp_replace(coalesce(p->>'customer_name', ''), '[[:cntrl:]]', ' ', 'g')), 120);
  if v_name = '' then
    return jsonb_build_object('error', 'INVALID_NAME');
  end if;
  v_notes := left(btrim(coalesce(p->>'notes', '')), 1000);
  v_items := p->'items';

  -- ponowienie już zapisanego zamówienia potwierdzamy bez wyceny: utrata odpowiedzi nie może zamienić się w błąd,
  -- gdy w międzyczasie zmienił się katalog lub cennik
  select id, status into v_id, v_status from orders
    where external_id = p->>'external_id' and source = 'showroom' and showroom_name is not null;
  if found then
    return jsonb_build_object('order_id', v_id, 'created', false, 'status', v_status);
  end if;

  if v_items is null or v_items = '[]'::jsonb or v_items = 'null'::jsonb then
    v_err := _order_input_error(p);
    if v_err is not null then
      return jsonb_build_object('error', v_err);
    end if;
    if v_notes = '' then
      return jsonb_build_object('error', 'EMPTY_LEAD');
    end if;
    v_id := upsert_order(jsonb_build_object(
      'external_id', p->>'external_id', 'source', 'showroom', 'customer_email', btrim(p->>'customer_email'),
      'kind', 'catalog', 'status', 'needs_review',
      'raw_text', E'Lead z salonu (bez pozycji)\nUwagi klienta: ' || v_notes,
      'parsed', jsonb_build_object('source', 'showroom', 'reason', 'lead_without_items'),
      'items', '[]'::jsonb));
  else
    v_r := _place_order(p, 'showroom');
    if v_r ? 'error' then
      return v_r;
    end if;
    v_id := (v_r->>'order_id')::uuid;
  end if;

  -- pierwszy wywołujący (pod blokadą wiersza) uzupełnia dane salonu; ponowienie widzi je i zwraca created = false
  select showroom_name is null, source into v_new, v_src from orders where id = v_id for update;
  if v_src <> 'showroom' then
    -- identyfikator należy do zamówienia z innego kanału: niczego mu nie dopisujemy
    return jsonb_build_object('error', 'EXTERNAL_ID_CONFLICT');
  end if;
  if v_new then
    update orders set showroom_name = v_s.name, salesperson_email = v_s.salesperson_email,
                      customer_name = v_name, consent_at = now()
    where id = v_id;
  end if;
  return jsonb_build_object('order_id', v_id, 'created', v_new, 'status', (select status from orders where id = v_id));
end $$;

alter table email_outbox drop constraint email_outbox_kind_check;
alter table email_outbox add constraint email_outbox_kind_check
  check (kind in ('customer_quote', 'needs_info', 'owner_alert', 'order_done', 'showroom_lead'));

-- Kontekst powiadomień z danymi salonu.
create or replace function notification_context(p_order_id uuid) returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'order_id', o.id,
    'status', o.status,
    'customer_email', o.customer_email,
    'source', o.source,
    'raw_text', o.raw_text,
    'quote', o.quote,
    'missing', coalesce(o.parsed->'missing', '[]'::jsonb),
    'reason', coalesce(o.quote->>'error', o.parsed->>'reason'),
    'showroom_name', o.showroom_name,
    'salesperson_email', o.salesperson_email,
    'customer_name', o.customer_name,
    'existing_kinds', coalesce((select jsonb_agg(e.kind order by e.kind)
                                from email_outbox e where e.order_id = o.id), '[]'::jsonb))
  from orders o
  where o.id = p_order_id
$$;

-- Naprawa po awarii: zamówienie z salonu wymaga maila do handlowca (showroom_lead) zamiast owner_alert.
create or replace function orders_missing_notifications(p_older_than_seconds int default 120)
returns table (order_id uuid)
language sql stable set search_path = public, pg_temp as $$
  select o.id
  from orders o
  where o.parsed is not null
    and o.created_at < now() - make_interval(secs => p_older_than_seconds)
    and case
      when o.source = 'showroom' then
        case o.status
          when 'quoted' then
            not exists (select 1 from email_outbox e where e.order_id = o.id and e.kind = 'customer_quote')
            or not exists (select 1 from email_outbox e where e.order_id = o.id and e.kind = 'showroom_lead')
          when 'needs_review' then
            not exists (select 1 from email_outbox e where e.order_id = o.id and e.kind = 'showroom_lead')
          else false
        end
      else
        case o.status
          when 'quoted' then
            not exists (select 1 from email_outbox e where e.order_id = o.id and e.kind = 'customer_quote')
            or not exists (select 1 from email_outbox e where e.order_id = o.id and e.kind = 'owner_alert')
          when 'needs_info' then
            not exists (select 1 from email_outbox e where e.order_id = o.id and e.kind = 'needs_info')
          when 'needs_review' then
            not exists (select 1 from email_outbox e where e.order_id = o.id and e.kind = 'owner_alert')
          else false
        end
    end
$$;

revoke execute on function _order_input_error(jsonb), _place_order(jsonb, text), calculator_order(jsonb),
  showroom_info(text), showroom_order(jsonb) from public, anon, authenticated;
grant execute on function _order_input_error(jsonb), _place_order(jsonb, text), calculator_order(jsonb),
  showroom_info(text), showroom_order(jsonb) to service_role;
