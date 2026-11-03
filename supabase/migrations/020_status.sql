-- Task 10: statusy zamówień. Każda zmiana statusu zostawia zdarzenie (order_events), z którego powstaje oś czasu dla klienta
-- (publiczna strona statusu po tokenie zamówienia), mail o rozpoczęciu realizacji i, 7 dni po zakończeniu, prośba o opinię.
-- Maile powstają w bazie w tej samej transakcji co oznaczenie zdarzenia, więc ponowny przebieg niczego nie dubluje.

alter table email_outbox drop constraint email_outbox_kind_check;
alter table email_outbox add constraint email_outbox_kind_check
  check (kind in ('customer_quote', 'needs_info', 'owner_alert', 'order_done', 'showroom_lead', 'purchase_order',
                  'followup_1', 'followup_2', 'lost_survey', 'status_approved', 'status_in_progress', 'review_request'));

create table order_events (
  id          uuid primary key default gen_random_uuid(),
  seq         bigint generated always as identity,   -- kolejność zdarzeń z jednej transakcji (created_at bywa wspólne)
  order_id    uuid not null references orders(id) on delete cascade,
  old_status  text,
  new_status  text not null,
  created_at  timestamptz not null default now(),
  notified_at timestamptz
);
alter table order_events enable row level security;
revoke all on order_events from anon, authenticated;
create index on order_events (order_id, seq);
create index on order_events (seq) where notified_at is null;

create function _log_order_status() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  -- clock_timestamp() zamiast now(): czas zdarzenia to moment zmiany, a nie początek (potencjalnie długiej) transakcji
  insert into order_events (order_id, old_status, new_status, created_at) values (new.id, old.status, new.status, clock_timestamp());
  return new;
end $$;

create trigger trg_order_status after update of status on orders
  for each row when (old.status is distinct from new.status) execute function _log_order_status();

-- Etap widoczny dla klienta i jego polska nazwa. Statusy wewnętrzne (do uzupełnienia, do sprawdzenia) to dla klienta "przyjęte".
create function _status_stage(p_status text) returns text
language sql immutable set search_path = public, pg_temp as $$
  select case p_status when 'new' then 'received' when 'needs_info' then 'received' when 'needs_review' then 'received'
                       when 'lost' then 'closed' else p_status end
$$;

create function _stage_label(p_stage text) returns text
language sql immutable set search_path = public, pg_temp as $$
  select case p_stage when 'received' then 'Zamówienie przyjęte' when 'quoted' then 'Wyceniono' when 'approved' then 'Zatwierdzone'
                      when 'in_progress' then 'W realizacji' when 'done' then 'Gotowe' when 'closed' then 'Zamknięte' else 'Zamówienie' end
$$;

-- Publiczna strona statusu: wejściem jest nieodgadnialny token zamówienia (public_token). Funkcja działa z uprawnieniami
-- właściciela (security definer), ale zwraca wyłącznie etapy i daty, bez e-maila, cen, wyceny i identyfikatorów.
-- Nieznany token daje pusty obiekt. To jedyna funkcja dostępna dla anon (patrz 006_security_test).
create function order_status_public(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_o orders;
  v_timeline jsonb;
begin
  if p_token is null then
    return '{}'::jsonb;
  end if;
  select * into v_o from orders where public_token = p_token;
  if not found then
    return '{}'::jsonb;
  end if;
  with ev as (
    select 0::bigint as seq, 'received'::text as stage, v_o.created_at as at
    union all
    select e.seq, _status_stage(e.new_status), e.created_at from order_events e where e.order_id = v_o.id),
  marked as (select stage, at, seq, lag(stage) over (order by seq) as prev from ev)
  select jsonb_agg(jsonb_build_object('label_pl', _stage_label(stage), 'at', at) order by seq)
    into v_timeline from marked where prev is distinct from stage;
  return jsonb_build_object('status', _status_stage(v_o.status), 'label_pl', _stage_label(_status_stage(v_o.status)),
                            'timeline', coalesce(v_timeline, '[]'::jsonb));
end $$;

-- Powiadomienia o zmianie statusu. Dla każdego zamówienia z nowymi zdarzeniami liczy się tylko ostatnie z nich, więc
-- "zatwierdzone" i "w realizacji" z jednej transakcji dają jeden mail. Mail idzie tylko, gdy zamówienie nadal jest w tym stanie
-- i zdarzenie nie jest starsze niż 3 dni (po awarii nie wysyłamy spóźnionych wiadomości). Zakończenie ma własny mail (order_done).
-- Zwraca liczbę zakolejkowanych maili. Adres strony statusu (http/https, NULL = mail bez linku) jest sprawdzany przed jakąkolwiek zmianą.
create function notify_status_events(p_status_url text default null) returns int
language plpgsql set search_path = public, pg_temp as $$
declare
  v_url  text := regexp_replace(p_status_url, '/+$', '');
  r      record;
  v_n    int := 0;
  v_cur  text;
  v_link text;
begin
  if v_url is not null and v_url !~ '^https?://[A-Za-z0-9.:-]{1,200}$' then
    raise exception 'INVALID_STATUS_URL';
  end if;
  for r in
    with c as (
      update order_events set notified_at = now() where notified_at is null
      returning seq, order_id, new_status, created_at)
    select distinct on (c.order_id) c.order_id, c.new_status, c.created_at, o.customer_email, o.public_token
    from c join orders o on o.id = c.order_id
    order by c.order_id, c.seq desc
  loop
    -- każde zamówienie w osobnej podtransakcji: jeden wadliwy rekord (np. pusty adres) nie cofa pozostałych, a jego
    -- zdarzenia wracają do kolejki i są ponawiane, dopóki mieszczą się w oknie 3 dni
    begin
      -- blokada zamówienia i aktualny status: stan mógł się zmienić od odczytu zdarzeń
      select status into v_cur from orders where id = r.order_id for update;
      if r.new_status in ('approved', 'in_progress') and v_cur = r.new_status and r.created_at > now() - interval '3 days' then
        v_link := case when v_url is null then ''
                       else E'\n\nStatus zamówienia możesz śledzić tutaj: ' || v_url || '/status.html?token=' || r.public_token end;
        if enqueue_email(r.order_id, 'status_' || r.new_status, r.customer_email,
             case r.new_status when 'approved' then 'Twoje zamówienie zostało zatwierdzone' else 'Twoje zamówienie jest w realizacji' end,
             E'Dzień dobry,\n\n' ||
             case r.new_status when 'approved' then 'Twoje zamówienie zostało zatwierdzone i czeka na rozpoczęcie prac.'
                               else 'rozpoczęliśmy realizację Twojego zamówienia.' end ||
             v_link || E'\n\nPozdrawiamy,\nStolarnia') is not null then
          v_n := v_n + 1;
        end if;
      end if;
    exception when others then
      raise warning 'notify_status_events: zamówienie %: %', r.order_id, sqlerrm;
      update order_events set notified_at = null where order_id = r.order_id and notified_at = now();
    end;
  end loop;
  return v_n;
end $$;

-- Zamówienia, o których opinię warto poprosić: ostatnie zdarzenie to przejście na done sprzed 7 do 60 dni, zamówienie nadal
-- jest done (nie otwarte ponownie) i nie dostało jeszcze prośby. Zamówienia bez zdarzenia done (sprzed tej migracji) są pomijane.
create function orders_due_review() returns setof uuid
language sql stable set search_path = public, pg_temp as $$
  select o.id from orders o
  where o.status = 'done' and o.review_requested_at is null
    and exists (select 1 from order_events e
                where e.order_id = o.id and e.new_status = 'done'
                  and e.seq = (select max(x.seq) from order_events x where x.order_id = o.id)
                  and e.created_at <= now() - interval '7 days' and e.created_at > now() - interval '60 days')
  order by o.created_at
$$;

-- Wysyła prośby o opinię. p_review_url to link do opinii (tylko https; NULL = nie skonfigurowano, nic nie wysyłamy).
create function send_review_requests(p_review_url text) returns int
language plpgsql set search_path = public, pg_temp as $$
declare
  r   record;
  v_n int := 0;
begin
  if p_review_url is null then
    return 0;
  end if;
  -- (limit powtórzeń w regexie Postgresa to 255, więc długość sprawdzamy osobno)
  if p_review_url !~ '^https://[^[:space:]<>"]+$' or length(p_review_url) > 300 then
    raise exception 'INVALID_REVIEW_URL';
  end if;
  for r in select o.id, o.customer_email from orders o where o.id in (select orders_due_review()) for update skip locked loop
    begin
      -- po uzyskaniu blokady kwalifikację sprawdzamy jeszcze raz (zamówienie mogło zostać otwarte ponownie)
      if exists (select 1 from orders_due_review() x where x = r.id) then
        if enqueue_email(r.id, 'review_request', r.customer_email, 'Jak podoba się Twój mebel?',
             E'Dzień dobry,\n\nmamy nadzieję, że meble z naszej pracowni służą dobrze. Będziemy wdzięczni za krótką opinię: ' ||
             p_review_url || E'\n\nJeśli chcesz, odpowiedz na tego maila i dołącz zdjęcie mebla w Twoim wnętrzu, chętnie je zobaczymy.' ||
             E'\n\nDziękujemy i pozdrawiamy,\nStolarnia') is not null then
          v_n := v_n + 1;
        end if;
        update orders set review_requested_at = now() where id = r.id;
      end if;
    exception when others then
      raise warning 'send_review_requests: zamówienie %: %', r.id, sqlerrm;   -- wadliwy rekord nie blokuje reszty
    end;
  end loop;
  return v_n;
end $$;

revoke execute on function _log_order_status(), _status_stage(text), _stage_label(text), order_status_public(uuid),
  notify_status_events(text), orders_due_review(), send_review_requests(text) from public, anon, authenticated;
grant execute on function order_status_public(uuid) to anon, authenticated;
grant execute on function _status_stage(text), _stage_label(text), order_status_public(uuid), notify_status_events(text),
  orders_due_review(), send_review_requests(text) to service_role;
