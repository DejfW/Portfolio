-- Poprawki po recenzji Task 4:
--  * powiadomienia Slack i maile zapisywane w tej samej transakcji co zmiana stanu (approve_order, task_done),
--  * kolejka dostarczania z dzierżawą, ponowieniami z odstępem i rezygnacją po 8 próbach (claim_deliveries),
--  * lista dozwolonych adresów maili egzekwowana w bazie, przed limitem, więc zablokowane wpisy nie głodzą reszty,
--  * walidacje: cena po zaokrągleniu, unikalność znormalizowanych nazw.

-- 1. Ceny i nazwy ---------------------------------------------------------------------------------

alter table supplier_prices add constraint supplier_prices_price_positive check (price > 0);

-- Nazwy różniące się tylko wielkością liter lub spacjami to ten sam obiekt; dopasowanie w imporcie jest dzięki temu jednoznaczne.
create unique index suppliers_name_normalized_uq on suppliers (lower(trim(name)));
create unique index materials_name_normalized_uq on materials (lower(trim(name)));
create unique index products_name_normalized_uq on products (lower(trim(name)));

-- Cena musi mieć najwyżej dwa miejsca po przecinku i być dodatnia; ułamki grosza nie są po cichu zaokrąglane do zera.
create or replace function import_supplier_prices(p jsonb) returns jsonb
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
    if v_price is null or v_price <= 0 or v_price > 1000000 or scale(v_price) > 2 then
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

-- 2. Pomocniki tekstowe ------------------------------------------------------------------------------

-- Slack traktuje &, < i > jako składnię (<!channel>, <url|tekst>); dane od klientów i z cenników trzeba je kodować.
create function _slack_esc(p text) returns text
language sql immutable set search_path = public, pg_temp as $$
  select replace(replace(replace(coalesce(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
$$;

create function _pln(p numeric) returns text
language sql immutable set search_path = public, pg_temp as $$
  select replace(to_char(p, 'FM999999990.00'), '.', ',') || ' zł'
$$;

-- 3. Powiadomienia w tej samej transakcji co zmiana stanu -----------------------------------------------

drop function approve_order(uuid, text);

-- Zatwierdzenie zamówienia. p_public_url to adres n8n widoczny dla właściciela (do linku zamykającego zadanie).
-- Powiadomienie Slack o przydziale albo o brakach materiałów powstaje razem ze zmianą stanu; klucz deduplikacji
-- chroni przed dublem przy ponowieniu.
create function approve_order(p_order_id uuid, p_assignee text, p_public_url text default null) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare
  v_assignee text := trim(coalesce(p_assignee, ''));
  v_task     uuid;
  v_order    record;
  v_short    jsonb;
  v_lines    text;
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
      v_short := task_shortages(p_order_id);
      select string_agg(format('• %s: brakuje %s %s (potrzeba %s, dostępne %s), %s',
          _slack_esc(s->>'name'), trim_scale((s->>'missing')::numeric), _slack_esc(s->>'unit'),
          trim_scale((s->>'needed')::numeric), trim_scale((s->>'available')::numeric),
          case when s->>'best_supplier' is null then 'brak aktualnej ceny w hurtowniach'
               else 'najtaniej: ' || _slack_esc(s->>'best_supplier') || ' po ' || _pln((s->>'best_price')::numeric) end),
        E'\n' order by s->>'name')
      into v_lines
      from jsonb_array_elements(v_short) s;

      perform enqueue_slack('stock_shortage',
        left(format(E'⚠️ Brakuje materiałów dla zamówienia %s:\n%s', p_order_id, v_lines), 2900),
        format('shortage:%s:%s', p_order_id, to_char(now() at time zone 'utc', 'YYYY-MM-DD')));
      return jsonb_build_object('ok', false, 'error', 'INSUFFICIENT_STOCK', 'shortages', v_short);
    elsif sqlerrm in ('ORDER_NOT_FOUND', 'ORDER_NOT_QUOTED', 'EMPTY_ORDER') or sqlerrm like 'ORDER_NOT_READY:%' then
      return jsonb_build_object('ok', false, 'error', sqlerrm);
    end if;
    raise;
  end;

  select customer_email, (quote->>'total')::numeric as total into v_order from orders where id = p_order_id;
  perform enqueue_slack('task_assigned',
    left(format(E'🛠️ Nowe zadanie dla *%s*\nKlient: %s\nWycena: %s%s',
      _slack_esc(v_assignee), _slack_esc(v_order.customer_email), _pln(v_order.total),
      case when p_public_url is null then ''
           else E'\nPo wykonaniu zamknij zadanie: ' || p_public_url || '/webhook/task-done?task_id=' || v_task end), 2900),
    'task:' || v_task);

  return jsonb_build_object('ok', true, 'task_id', v_task, 'order_id', p_order_id,
                            'assignee', v_assignee, 'customer_email', v_order.customer_email,
                            'total', v_order.total);
end $$;

-- Zakończenie zadania: zużycie materiałów, mail dla klienta i wiadomość Slack w jednej transakcji.
create or replace function task_done(p_task_id uuid) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare
  v_order    uuid;
  v_assignee text;
  v_email    text;
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

  select customer_email into v_email from orders where id = v_order;
  perform enqueue_email(v_order, 'order_done', v_email, 'Twoje zamówienie jest gotowe',
    E'Dzień dobry,\n\nz przyjemnością informujemy, że Twoje zamówienie jest gotowe. '
    'Skontaktujemy się w sprawie odbioru lub dostawy.\n\nPozdrawiamy,\nStolarnia');
  perform enqueue_slack('task_done',
    left(format('✅ %s zakończył(a) zadanie dla %s. Klient dostanie informację.',
                _slack_esc(v_assignee), _slack_esc(v_email)), 2900),
    'done:' || p_task_id);

  return jsonb_build_object('ok', true, 'order_id', v_order, 'assignee', v_assignee, 'customer_email', v_email);
end $$;

-- 4. Kolejka dostarczania ---------------------------------------------------------------------------------

alter table slack_outbox
  add column attempts int not null default 0,
  add column next_attempt_at timestamptz not null default now(),
  add column failed_at timestamptz,
  add column last_error text;
alter table email_outbox
  add column attempts int not null default 0,
  add column next_attempt_at timestamptz not null default now(),
  add column failed_at timestamptz,
  add column last_error text;

drop index if exists slack_outbox_created_at_idx;
drop index if exists email_outbox_sent_at_idx;
create index slack_outbox_due_idx on slack_outbox (next_attempt_at) where sent_at is null and failed_at is null;
create index email_outbox_due_idx on email_outbox (next_attempt_at) where sent_at is null and failed_at is null;

drop function pending_deliveries(int, boolean);

-- Adres jest dozwolony, gdy pasuje do listy rozdzielonej przecinkami: pełny adres albo "@domena".
create function _email_allowed(p_to text, p_allowlist text) returns boolean
language sql immutable set search_path = public, pg_temp as $$
  select coalesce(p_to ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$', false)
    and exists (
      select 1
      from unnest(string_to_array(lower(coalesce(p_allowlist, '')), ',')) as a(entry), lateral (select trim(entry) as e) t
      where t.e <> ''
        and case when left(t.e, 1) = '@'
                 then right(lower(trim(p_to)), length(t.e)) = t.e
                 else lower(trim(p_to)) = t.e end)
$$;

-- Odbiera wiadomości do wysłania i dzierżawi je na 2 minuty (drugi wykonawca ich nie dostanie, a jeśli pierwszy
-- padnie, wiadomość wróci). Limit dotyczy każdego kanału osobno i jest liczony PO filtrach, więc wiadomości,
-- których nie wolno wysłać (maile wyłączone lub poza listą dozwolonych), nie blokują reszty kolejki.
-- Semantyka to "co najmniej raz": jeśli proces padnie po wysłaniu, a przed mark_delivered, wiadomość może pójść ponownie.
create function claim_deliveries(
  p_limit int default 20, p_only_test boolean default false,
  p_slack boolean default true, p_email boolean default false, p_allowlist text default ''
) returns jsonb
language sql set search_path = public, pg_temp as $$
  with s as (
    select id from slack_outbox
    where p_slack and sent_at is null and failed_at is null and next_attempt_at <= now()
      and (not p_only_test or dedupe_key like 'deliver-test-%')
    order by created_at limit greatest(p_limit, 0)
    for update skip locked),
  e as (
    select id from email_outbox
    where p_email and sent_at is null and failed_at is null and next_attempt_at <= now()
      and (not p_only_test or subject like '[deliver-test]%')
      and _email_allowed(to_email, p_allowlist)
    order by created_at limit greatest(p_limit, 0)
    for update skip locked),
  su as (
    update slack_outbox set next_attempt_at = now() + interval '2 minutes'
    where id in (select id from s) returning id, kind, text, created_at),
  eu as (
    update email_outbox set next_attempt_at = now() + interval '2 minutes'
    where id in (select id from e) returning id, kind, to_email, subject, body, created_at),
  u as (
    select jsonb_build_object('channel', 'slack', 'id', id, 'kind', kind, 'text', text) as x, created_at from su
    union all
    select jsonb_build_object('channel', 'email', 'id', id, 'kind', kind, 'to', to_email,
                              'subject', subject, 'text', body), created_at from eu)
  select coalesce(jsonb_agg(x order by created_at), '[]'::jsonb) from u
$$;

-- Nieudana próba: kolejna za 2, 4, 8... minut (najwyżej godzinę), a po 8 próbach wiadomość przestaje być ponawiana.
create function mark_failed(p_channel text, p_id uuid, p_error text) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
begin
  if p_channel = 'slack' then
    update slack_outbox set attempts = attempts + 1, last_error = left(coalesce(p_error, ''), 300),
      next_attempt_at = now() + make_interval(mins => least(power(2, attempts + 1)::int, 60)),
      failed_at = case when attempts + 1 >= 8 then now() end
    where id = p_id and sent_at is null;
  elsif p_channel = 'email' then
    update email_outbox set attempts = attempts + 1, last_error = left(coalesce(p_error, ''), 300),
      next_attempt_at = now() + make_interval(mins => least(power(2, attempts + 1)::int, 60)),
      failed_at = case when attempts + 1 >= 8 then now() end
    where id = p_id and sent_at is null;
  else
    raise exception 'UNKNOWN_CHANNEL:%', p_channel;
  end if;
  return jsonb_build_object('ok', true);
end $$;
