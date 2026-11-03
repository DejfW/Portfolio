-- Task 4: zatwierdzanie zamówień, zadania zespołu, kolejka Slack, import cen hurtowni, raport niskich stanów.
-- Wszystkie funkcje mają stały search_path i są wywoływalne tylko przez service_role (patrz test 006).

-- Nowy rodzaj maila dla klienta: zamówienie gotowe.
alter table email_outbox drop constraint email_outbox_kind_check;
alter table email_outbox add constraint email_outbox_kind_check
  check (kind in ('customer_quote', 'needs_info', 'owner_alert', 'order_done'));

-- Wiadomości Slack do wysłania. dedupe_key chroni przed dubletami przy ponowieniu workflow
-- (np. task:<id>, stock-digest:2026-11-03).
create table slack_outbox (
  id         uuid primary key default gen_random_uuid(),
  kind       text not null check (kind in ('task_assigned', 'stock_shortage', 'stock_digest', 'task_done')),
  text       text not null check (text <> '' and length(text) <= 3000),
  dedupe_key text not null unique check (dedupe_key <> ''),
  created_at timestamptz not null default now(),
  sent_at    timestamptz
);
alter table slack_outbox enable row level security;
revoke all on slack_outbox from anon, authenticated;
create index on slack_outbox (created_at) where sent_at is null;

create function enqueue_slack(p_kind text, p_text text, p_dedupe_key text) returns uuid
language sql set search_path = public, pg_temp as $$
  insert into slack_outbox (kind, text, dedupe_key)
  values (p_kind, p_text, p_dedupe_key)
  on conflict (dedupe_key) do nothing
  returning id
$$;

-- Braki materiałów dla zamówienia: ile potrzeba, ile jest, ile brakuje i gdzie najtaniej kupić.
create function task_shortages(p_order_id uuid) returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'material_id', m.id, 'name', m.name, 'unit', m.unit,
      'needed', rq.qty, 'available', m.stock - m.reserved, 'missing', rq.qty - (m.stock - m.reserved),
      'best_supplier', bp.supplier_name, 'best_price', bp.price) order by m.name), '[]'::jsonb)
  from _task_requirements(p_order_id) rq
  join materials m on m.id = rq.material_id
  left join lateral best_price(m.id) bp on true
  where rq.qty > m.stock - m.reserved
$$;

-- Zatwierdzenie zamówienia przez właściciela: tworzy zadanie, rezerwuje materiały i przydziela osobę.
-- Oczekiwane problemy (brak materiału, zły status) wracają jako {ok:false, error}, a nie wyjątek,
-- żeby n8n mógł o nich powiadomić. Przy braku materiału w bazie nic się nie zmienia.
create function approve_order(p_order_id uuid, p_assignee text) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare
  v_assignee text := trim(coalesce(p_assignee, ''));
  v_task     uuid;
  v_order    record;
begin
  if v_assignee = '' then
    return jsonb_build_object('ok', false, 'error', 'MISSING_ASSIGNEE');
  end if;
  if length(v_assignee) > 50 or v_assignee ~ '[[:cntrl:]]' then
    return jsonb_build_object('ok', false, 'error', 'INVALID_ASSIGNEE');
  end if;

  begin
    v_task := create_task(p_order_id, v_assignee);
  exception when others then
    if sqlerrm like 'INSUFFICIENT_STOCK:%' then
      return jsonb_build_object('ok', false, 'error', 'INSUFFICIENT_STOCK',
                                'shortages', task_shortages(p_order_id));
    elsif sqlerrm in ('ORDER_NOT_FOUND', 'ORDER_NOT_QUOTED', 'EMPTY_ORDER') or sqlerrm like 'ORDER_NOT_READY:%' then
      return jsonb_build_object('ok', false, 'error', sqlerrm);
    end if;
    raise;
  end;

  select customer_email, quote->'total' as total into v_order from orders where id = p_order_id;
  return jsonb_build_object('ok', true, 'task_id', v_task, 'order_id', p_order_id,
                            'assignee', v_assignee, 'customer_email', v_order.customer_email,
                            'total', v_order.total);
end $$;

-- Zakończenie zadania: zużywa zarezerwowany materiał i zwraca dane do maila dla klienta.
create function task_done(p_task_id uuid) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare
  v_order    uuid;
  v_assignee text;
begin
  select order_id, assignee into v_order, v_assignee from tasks where id = p_task_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'TASK_NOT_FOUND');
  end if;

  begin
    perform complete_task(p_task_id);
  exception when others then
    if sqlerrm = 'TASK_ALREADY_DONE' then
      return jsonb_build_object('ok', false, 'error', 'TASK_ALREADY_DONE');
    end if;
    raise;
  end;

  return jsonb_build_object('ok', true, 'order_id', v_order, 'assignee', v_assignee,
    'customer_email', (select customer_email from orders where id = v_order));
end $$;

-- Import cenników hurtowni: {rows: [{supplier, material, price}]}. Nazwy dopasowujemy bez
-- rozróżniania wielkości liter i spacji na brzegach, cenę przyjmujemy jako liczbę lub tekst
-- z przecinkiem ("17,90"). Poprawne wiersze są zapisywane (cena i data aktualizacji), a błędne
-- raportowane, żeby jeden zły wiersz nie blokował reszty pliku.
create function import_supplier_prices(p jsonb) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare
  r       jsonb;
  v_sup   uuid;
  v_mat   uuid;
  v_price numeric;
  v_text  text;
  v_n     int := 0;
  v_unk_s jsonb := '[]';
  v_unk_m jsonb := '[]';
  v_inv   jsonb := '[]';
begin
  if jsonb_typeof(p->'rows') is distinct from 'array' then
    return jsonb_build_object('error', 'INVALID_ROWS');
  end if;
  if jsonb_array_length(p->'rows') > 5000 then
    return jsonb_build_object('error', 'TOO_MANY_ROWS');
  end if;

  for r in select * from jsonb_array_elements(p->'rows') loop
    v_price := null;
    if jsonb_typeof(r->'price') = 'number' then
      v_price := (r->>'price')::numeric;
    elsif jsonb_typeof(r->'price') = 'string' then
      v_text := replace(trim(r->>'price'), ',', '.');
      if v_text ~ '^[0-9]{1,7}(\.[0-9]{1,2})?$' then
        v_price := v_text::numeric;
      end if;
    end if;
    if v_price is null or v_price <= 0 or v_price > 1000000 then
      v_inv := v_inv || jsonb_build_array(r);
      continue;
    end if;

    select id into v_sup from suppliers where lower(trim(name)) = lower(trim(coalesce(r->>'supplier', '')));
    if not found then
      if not v_unk_s @> jsonb_build_array(r->>'supplier') then
        v_unk_s := v_unk_s || jsonb_build_array(r->>'supplier');
      end if;
      continue;
    end if;
    select id into v_mat from materials where lower(trim(name)) = lower(trim(coalesce(r->>'material', '')));
    if not found then
      if not v_unk_m @> jsonb_build_array(r->>'material') then
        v_unk_m := v_unk_m || jsonb_build_array(r->>'material');
      end if;
      continue;
    end if;

    insert into supplier_prices (supplier_id, material_id, price, updated_at)
    values (v_sup, v_mat, v_price, now())
    on conflict (supplier_id, material_id) do update set price = excluded.price, updated_at = now();
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('updated', v_n, 'unknown_suppliers', v_unk_s,
                            'unknown_materials', v_unk_m, 'invalid', v_inv);
end $$;

-- Materiały poniżej minimum z ilością do zamówienia (do dwukrotności minimum, jak w automatycznych
-- zamówieniach z Task 7) oraz lista tych, dla których nie ma aktualnej ceny w żadnej hurtowni.
create function low_stock_report() returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'items', coalesce(jsonb_agg(jsonb_build_object(
        'name', name, 'available', available, 'min_stock', min_stock,
        'to_order', ceil(2 * min_stock - available),
        'best_supplier', best_supplier, 'best_price', best_price) order by name), '[]'::jsonb),
    'unpriced', coalesce(jsonb_agg(name order by name) filter (where best_supplier is null), '[]'::jsonb))
  from low_stock
$$;

-- Wszystko, co czeka na wysłanie (Slack i maile), od najstarszego.
create function pending_deliveries(p_limit int default 50) returns jsonb
language sql stable set search_path = public, pg_temp as $$
  with u as (
    select jsonb_build_object('channel', 'slack', 'id', id, 'kind', kind, 'text', text) as x, created_at
    from slack_outbox where sent_at is null
    union all
    select jsonb_build_object('channel', 'email', 'id', id, 'kind', kind, 'to', to_email,
                              'subject', subject, 'text', body), created_at
    from email_outbox where sent_at is null),
  l as (select * from u order by created_at limit greatest(p_limit, 0))
  select coalesce(jsonb_agg(x order by created_at), '[]'::jsonb) from l
$$;

create function mark_delivered(p_channel text, p_id uuid) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
begin
  if p_channel = 'slack' then
    update slack_outbox set sent_at = now() where id = p_id and sent_at is null;
  elsif p_channel = 'email' then
    update email_outbox set sent_at = now() where id = p_id and sent_at is null;
  else
    raise exception 'UNKNOWN_CHANNEL:%', p_channel;
  end if;
  return jsonb_build_object('ok', true);
end $$;
