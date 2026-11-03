-- Task 7: automatyczne zamówienia do hurtowni. Materiały poniżej minimum trafiają do szkiców zamówień
-- u najtańszego dostawcy (jeden szkic na dostawcę), właściciel zatwierdza linkiem, hurtownia dostaje mail,
-- a przyjęcie dostawy zwiększa stan magazynu. Wszystkie funkcje mają stały search_path i działają tylko
-- dla service_role. Powiadomienia powstają w tej samej transakcji co zmiana stanu.

create table purchase_orders (
  id          uuid primary key default gen_random_uuid(),
  supplier_id uuid not null references suppliers(id),
  status      text not null default 'draft' check (status in ('draft', 'sent', 'received', 'cancelled')),
  created_at  timestamptz not null default now(),
  sent_at     timestamptz,
  received_at timestamptz
);
create table purchase_order_lines (
  po_id       uuid not null references purchase_orders(id) on delete cascade,
  material_id uuid not null references materials(id),
  qty         numeric(12,3) not null check (qty > 0),
  unit_price  numeric(12,2) not null check (unit_price > 0),
  primary key (po_id, material_id)
);
alter table purchase_orders enable row level security;
alter table purchase_order_lines enable row level security;
revoke all on purchase_orders, purchase_order_lines from anon, authenticated;
create index on purchase_orders (status);
create index on purchase_order_lines (material_id);

-- Maile do hurtowni nie dotyczą zamówienia klienta: kolejka dostaje drugi klucz (po_id).
alter table email_outbox alter column order_id drop not null;
alter table email_outbox add column po_id uuid references purchase_orders(id) on delete cascade;
alter table email_outbox add constraint email_outbox_owner_check check (num_nonnulls(order_id, po_id) = 1);
create unique index email_outbox_po_kind_key on email_outbox (po_id, kind) where po_id is not null;
alter table email_outbox drop constraint email_outbox_kind_check;
alter table email_outbox add constraint email_outbox_kind_check
  check (kind in ('customer_quote', 'needs_info', 'owner_alert', 'order_done', 'showroom_lead', 'purchase_order'));

alter table slack_outbox drop constraint slack_outbox_kind_check;
alter table slack_outbox add constraint slack_outbox_kind_check
  check (kind in ('task_assigned', 'stock_shortage', 'stock_digest', 'task_done', 'weekly_report', 'po_draft', 'po_unpriced'));

create function enqueue_po_email(p_po_id uuid, p_kind text, p_to text, p_subject text, p_body text)
returns uuid
language sql set search_path = public, pg_temp as $$
  insert into email_outbox (po_id, kind, to_email, subject, body)
  values (p_po_id, p_kind, p_to, p_subject, p_body)
  on conflict (po_id, kind) where po_id is not null do nothing
  returning id
$$;

-- Co zamówić: materiały poniżej minimum (stan dostępny), z aktualną ceną, których nie ma w otwartym zamówieniu
-- (draft albo sent). Ilość = ceil(2 × minimum − dostępne), czyli uzupełnienie do dwukrotności minimum.
create function _po_candidates()
returns table (supplier_id uuid, material_id uuid, name text, unit text, qty numeric, price numeric)
language sql stable set search_path = public, pg_temp as $$
  select bp.supplier_id, m.id, m.name, m.unit,
         ceil(2 * m.min_stock - (m.stock - m.reserved)), bp.price
  from materials m
  cross join lateral best_price(m.id) bp
  where m.stock - m.reserved < m.min_stock
    and not exists (select 1 from purchase_order_lines l join purchase_orders p on p.id = l.po_id
                    where l.material_id = m.id and p.status in ('draft', 'sent'))
$$;

-- Materiały poniżej minimum bez żadnej aktualnej ceny: nie da się ich zamówić automatycznie.
create function low_stock_unpriced()
returns table (material_id uuid, name text, available numeric, min_stock numeric)
language sql stable set search_path = public, pg_temp as $$
  select m.id, m.name, m.stock - m.reserved, m.min_stock
  from materials m
  where m.stock - m.reserved < m.min_stock
    and not exists (select 1 from best_price(m.id))
  order by m.name
$$;

-- Tworzy szkice zamówień (po jednym na dostawcę) i zwraca ich id. Ponowne wywołanie przy otwartych szkicach
-- niczego nie tworzy. Dla każdego szkicu wiadomość Slack z linkiem zatwierdzenia (adres tylko http/https);
-- osobny alert dla materiałów bez ceny (raz dziennie).
create function create_purchase_orders(p_public_url text default null) returns setof uuid
language plpgsql set search_path = public, pg_temp as $$
declare
  v_url   text := case when p_public_url ~ '^https?://[A-Za-z0-9.:-]{1,200}$' then p_public_url end;
  v_cand  jsonb;
  v_sup   uuid;
  v_po    uuid;
  v_name  text;
  v_lines text;
  v_total numeric;
  v_unp   text;
begin
  -- dwa równoległe uruchomienia nie mogą utworzyć podwójnych szkiców
  perform pg_advisory_xact_lock(hashtext('create_purchase_orders'));

  -- kandydaci liczeni raz: dostawcy i pozycje szkiców pochodzą z tego samego stanu cen i magazynu
  select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) into v_cand from _po_candidates() c;

  for v_sup in select distinct (e->>'supplier_id')::uuid from jsonb_array_elements(v_cand) e order by 1 loop
    insert into purchase_orders (supplier_id) values (v_sup) returning id into v_po;
    insert into purchase_order_lines (po_id, material_id, qty, unit_price)
      select v_po, (e->>'material_id')::uuid, (e->>'qty')::numeric, (e->>'price')::numeric
      from jsonb_array_elements(v_cand) e where (e->>'supplier_id')::uuid = v_sup;

    select s.name into v_name from suppliers s where s.id = v_sup;
    select string_agg(format('• %s: %s %s × %s', _slack_esc(m.name), trim_scale(l.qty), _slack_esc(m.unit), _pln(l.unit_price)),
                      E'\n' order by m.name),
           sum(l.qty * l.unit_price)
      into v_lines, v_total
      from purchase_order_lines l join materials m on m.id = l.material_id where l.po_id = v_po;

    perform enqueue_slack('po_draft',
      left(format(E'📦 Szkic zamówienia do *%s* (nr %s), razem %s%s\n%s',
        _slack_esc(v_name), upper(left(v_po::text, 8)), _pln(v_total),
        case when v_url is null then '' else E'\nZatwierdź: ' || v_url || '/webhook/po-approve?po_id=' || v_po end,
        v_lines), 2900),
      'po-draft:' || v_po);
    return next v_po;
  end loop;

  select string_agg(format('• %s (dostępne %s, minimum %s)', _slack_esc(u.name), trim_scale(u.available), trim_scale(u.min_stock)),
                    E'\n' order by u.name)
    into v_unp from low_stock_unpriced() u;
  if v_unp is not null then
    perform enqueue_slack('po_unpriced',
      left(E'⚠️ Brak aktualnej ceny w hurtowniach, nie da się zamówić automatycznie:\n' || v_unp, 2900),
      'po-unpriced:' || to_char(now() at time zone 'Europe/Warsaw', 'YYYY-MM-DD'));
  end if;
end $$;

-- Dane do strony potwierdzenia. NULL, gdy nie ma takiego zamówienia. Bez e-maila dostawcy.
create function purchase_order_context(p_po_id uuid) returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'po_id', p.id, 'status', p.status, 'supplier', s.name,
    'lines', coalesce((select jsonb_agg(jsonb_build_object('name', m.name, 'unit', m.unit, 'qty', l.qty,
                                                            'unit_price', l.unit_price) order by m.name)
                       from purchase_order_lines l join materials m on m.id = l.material_id where l.po_id = p.id), '[]'::jsonb),
    'total', coalesce((select sum(l.qty * l.unit_price) from purchase_order_lines l where l.po_id = p.id), 0))
  from purchase_orders p join suppliers s on s.id = p.supplier_id
  where p.id = p_po_id
$$;

-- Zatwierdzenie szkicu: status sent i mail do hurtowni (w jednej transakcji). Ceny zostają takie jak w szkicu.
create function approve_purchase_order(p_po_id uuid) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare
  v_po    purchase_orders;
  v_sup   suppliers;
  v_email text;
  v_lines text;
  v_total numeric;
begin
  select * into v_po from purchase_orders where id = p_po_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'PO_NOT_FOUND');
  end if;
  if v_po.status <> 'draft' then
    return jsonb_build_object('ok', false, 'error', 'PO_NOT_DRAFT');
  end if;
  if not exists (select 1 from purchase_order_lines where po_id = p_po_id) then
    return jsonb_build_object('ok', false, 'error', 'PO_EMPTY');
  end if;
  select * into v_sup from suppliers where id = v_po.supplier_id;
  -- adres musi spełniać ten sam kontrakt co wysyłka (_email_allowed), inaczej mail utknąłby w kolejce
  v_email := btrim(coalesce(v_sup.email, ''));
  if v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
    return jsonb_build_object('ok', false, 'error', 'SUPPLIER_NO_EMAIL');
  end if;

  select string_agg(format('- %s: %s %s po %s', m.name, trim_scale(l.qty), m.unit, _pln(l.unit_price)), E'\n' order by m.name),
         sum(l.qty * l.unit_price)
    into v_lines, v_total
    from purchase_order_lines l join materials m on m.id = l.material_id where l.po_id = p_po_id;

  update purchase_orders set status = 'sent', sent_at = now() where id = p_po_id;
  perform enqueue_po_email(p_po_id, 'purchase_order', v_email,
    'Zamówienie nr ' || upper(left(p_po_id::text, 8)),
    format(E'Dzień dobry,\n\nproszę o realizację zamówienia nr %s:\n\n%s\n\nRazem: %s\n\nDziękuję i pozdrawiam',
           upper(left(p_po_id::text, 8)), v_lines, _pln(v_total)));
  return jsonb_build_object('ok', true, 'po_id', p_po_id, 'supplier', v_sup.name, 'total', v_total);
end $$;

-- Przyjęcie dostawy: tylko z statusu sent. Stan rośnie o ilości z zamówienia, każda pozycja zostawia ruch 'receive'.
create function receive_delivery(p_po_id uuid) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare
  v_po purchase_orders;
  l    record;
begin
  select * into v_po from purchase_orders where id = p_po_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'PO_NOT_FOUND');
  end if;
  if v_po.status <> 'sent' then
    return jsonb_build_object('ok', false, 'error', 'PO_NOT_SENT');
  end if;
  -- stała kolejność blokad materiałów, jak w create_task, żeby równoległe operacje nie zakleszczyły się
  for l in select material_id, qty from purchase_order_lines where po_id = p_po_id order by material_id loop
    update materials set stock = stock + l.qty where id = l.material_id;
    insert into stock_movements (material_id, qty, kind) values (l.material_id, l.qty, 'receive');
  end loop;
  update purchase_orders set status = 'received', received_at = now() where id = p_po_id;
  return jsonb_build_object('ok', true, 'po_id', p_po_id);
end $$;

revoke execute on function enqueue_po_email(uuid, text, text, text, text), _po_candidates(), low_stock_unpriced(),
  create_purchase_orders(text), purchase_order_context(uuid), approve_purchase_order(uuid), receive_delivery(uuid)
  from public, anon, authenticated;
grant execute on function enqueue_po_email(uuid, text, text, text, text), _po_candidates(), low_stock_unpriced(),
  create_purchase_orders(text), purchase_order_context(uuid), approve_purchase_order(uuid), receive_delivery(uuid)
  to service_role;
