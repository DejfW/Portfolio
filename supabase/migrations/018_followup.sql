-- Task 8: follow-upy wycen i ankieta powodów rezygnacji. Wycena (status quoted) bez odpowiedzi dostaje przypomnienie
-- po 3 dniach i po 7 dniach, a po 14 dniach staje się lost; klient w mailu może jednym kliknięciem podać powód.
-- Licznik przypomnień i mail zmieniają się w jednej transakcji, więc ponowny run niczego nie dubluje.

alter table email_outbox drop constraint email_outbox_kind_check;
alter table email_outbox add constraint email_outbox_kind_check
  check (kind in ('customer_quote', 'needs_info', 'owner_alert', 'order_done', 'showroom_lead', 'purchase_order',
                  'followup_1', 'followup_2', 'lost_survey'));

create table lost_reasons (
  order_id   uuid primary key references orders(id) on delete cascade,
  reason     text not null check (reason in ('price', 'time', 'other_offer', 'other')),
  created_at timestamptz not null default now()
);
alter table lost_reasons enable row level security;
revoke all on lost_reasons from anon, authenticated;

-- Wyceny, którym należy się przypomnienie: nr 1 po 3 dniach, nr 2 po 7 dniach (po wysłaniu nr 1). Wycena starsza niż
-- 14 dni dostaje już tylko status lost, więc po przerwie w działaniu workflowu nie wysyłamy spóźnionych przypomnień.
create function quotes_due_followup()
returns table (order_id uuid, customer_email text, followup_no int, quote jsonb)
language sql stable set search_path = public, pg_temp as $$
  select o.id, o.customer_email, o.followups_sent + 1, o.quote
  from orders o
  where o.status = 'quoted' and o.quote is not null and o.quoted_at is not null
    and o.quoted_at > now() - interval '14 days'
    and ((o.followups_sent = 0 and o.quoted_at <= now() - interval '3 days')
      or (o.followups_sent = 1 and o.quoted_at <= now() - interval '7 days'))
  order by o.quoted_at
$$;

-- Zapisuje przypomnienie: mail do klienta i przesunięcie licznika w jednej transakcji. False, gdy przypomnienie
-- nie jest już należne (inny status, licznik inny niż no-1), więc równoległe lub ponowione wywołanie nic nie robi.
create function record_followup(p_order_id uuid, p_no int, p_subject text, p_body text) returns boolean
language plpgsql set search_path = public, pg_temp as $$
declare
  v_o orders;
  -- po ilu dniach od wyceny należy się to przypomnienie (CASE poza IF: plpgsql kończy warunek na pierwszym THEN)
  v_wait interval := case p_no when 1 then interval '3 days' else interval '7 days' end;
begin
  if p_no not in (1, 2) then
    return false;
  end if;
  if btrim(coalesce(p_subject, '')) = '' or length(p_subject) > 200 or p_subject ~ '[[:cntrl:]]'
     or btrim(coalesce(p_body, '')) = '' or length(p_body) > 5000 then
    raise exception 'INVALID_MAIL';
  end if;
  select * into v_o from orders where id = p_order_id for update;
  -- pełne warunki sprawdzamy ponownie pod blokadą: generowanie tekstu trwa, a wycena mogła w międzyczasie
  -- zmienić status, datę albo przekroczyć 14 dni
  if not found or v_o.status <> 'quoted' or v_o.followups_sent <> p_no - 1 or v_o.quoted_at is null
     or v_o.quoted_at <= now() - interval '14 days'
     or v_o.quoted_at > now() - v_wait then
    return false;
  end if;
  perform enqueue_email(p_order_id, 'followup_' || p_no, v_o.customer_email, p_subject, p_body);
  update orders set followups_sent = p_no where id = p_order_id;
  return true;
end $$;

-- Wyceny bez odpowiedzi przez p_days dni stają się lost. Każda dostaje mail z linkiem do ankiety (adres http/https;
-- NULL pomija ankietę, a błędny adres kończy się wyjątkiem INVALID_PUBLIC_URL bez żadnej zmiany). Zwraca id zmienionych zamówień; zamówienia zablokowane przez inną transakcję
-- (np. właśnie zatwierdzane) są pomijane i wrócą przy następnym uruchomieniu.
create function mark_lost_quotes(p_days int default 14, p_public_url text default null) returns setof uuid
language plpgsql set search_path = public, pg_temp as $$
declare
  v_url text := regexp_replace(p_public_url, '/+$', '');
  r     record;
begin
  if p_days is null or p_days < 1 or p_days > 365 then
    raise exception 'INVALID_DAYS';
  end if;
  -- błędna konfiguracja adresu przerywa operację, zanim jakakolwiek wycena straci status quoted (wtedy ankieta
  -- nigdy by nie wyszła); NULL oznacza świadome pominięcie ankiety
  if v_url is not null and v_url !~ '^https?://[A-Za-z0-9.:-]{1,200}$' then
    raise exception 'INVALID_PUBLIC_URL';
  end if;
  for r in
    select id, customer_email, public_token from orders
    where status = 'quoted' and quoted_at <= now() - make_interval(days => p_days)
    order by quoted_at for update skip locked
  loop
    update orders set status = 'lost' where id = r.id;
    if v_url is not null then
      perform enqueue_email(r.id, 'lost_survey', r.customer_email, 'Czy możemy zapytać, dlaczego zrezygnowali Państwo z wyceny?',
        format(E'Dzień dobry,\n\nnie otrzymaliśmy odpowiedzi na naszą wycenę, więc zamykamy ją w systemie. ' ||
               E'Będziemy wdzięczni za jedno kliknięcie: dlaczego zrezygnowali Państwo?\n\n%s/webhook/lost-reason?token=%s\n\n' ||
               E'Gdyby wycena nadal była aktualna, wystarczy odpowiedzieć na tego maila.\n\nPozdrawiamy', v_url, r.public_token));
    end if;
    return next r.id;
  end loop;
end $$;

-- Dane do strony ankiety. NULL, gdy nie ma takiego zamówienia. Nie zwraca nic poza statusem i faktem odpowiedzi.
create function lost_reason_context(p_token uuid) returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select jsonb_build_object('status', o.status, 'answered', exists (select 1 from lost_reasons l where l.order_id = o.id))
  from orders o where o.public_token = p_token
$$;

-- Powód rezygnacji z ankiety w mailu. Dostęp ma właściciel tokenu zamówienia; pierwsza odpowiedź wygrywa.
create function record_lost_reason(p_token uuid, p_reason text) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare
  v_o orders;
begin
  if p_reason is null or p_reason not in ('price', 'time', 'other_offer', 'other') then
    return jsonb_build_object('ok', false, 'error', 'INVALID_REASON');
  end if;
  select * into v_o from orders where public_token = p_token for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'ORDER_NOT_FOUND');
  end if;
  if v_o.status <> 'lost' then
    return jsonb_build_object('ok', false, 'error', 'ORDER_NOT_LOST');
  end if;
  insert into lost_reasons (order_id, reason) values (v_o.id, p_reason) on conflict (order_id) do nothing;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'ALREADY_ANSWERED');
  end if;
  return jsonb_build_object('ok', true);
end $$;

revoke execute on function quotes_due_followup(), record_followup(uuid, int, text, text), mark_lost_quotes(int, text),
  lost_reason_context(uuid), record_lost_reason(uuid, text) from public, anon, authenticated;
grant execute on function quotes_due_followup(), record_followup(uuid, int, text, text), mark_lost_quotes(int, text),
  lost_reason_context(uuid), record_lost_reason(uuid, text) to service_role;
