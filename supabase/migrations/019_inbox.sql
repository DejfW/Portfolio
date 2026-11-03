-- Task 9: triage skrzynki. Każda wiadomość dostaje kategorię od AI, ale o kierowaniu decyduje baza:
-- zamówienie, niepewność, błąd AI i wszelkie śmieci trafiają do intake, a nie do spamu (żadne zamówienie nie ginie).
-- Pytania i reklamacje wywołują powiadomienie dla właściciela; szkic odpowiedzi to tylko tekst do akceptacji,
-- system niczego sam nie wysyła klientowi. Spam jest tylko oznaczany i zostaje w tabeli.

alter table slack_outbox drop constraint slack_outbox_kind_check;
alter table slack_outbox add constraint slack_outbox_kind_check
  check (kind in ('task_assigned', 'stock_shortage', 'stock_digest', 'task_done', 'weekly_report', 'po_draft', 'po_unpriced',
                  'inbox_question', 'inbox_complaint'));

create table inbox_messages (
  id            uuid primary key default gen_random_uuid(),
  -- klucz idempotencji w formacie akceptowanym przez intake; Message-ID spoza tego zestawu znaków zapisujemy jako skrót
  external_id   text not null unique check (external_id ~ '^[A-Za-z0-9._:@<>+=/-]{1,200}$'),
  message_id    text check (length(message_id) <= 500),
  from_email    text not null check (from_email ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' and length(from_email) <= 200),
  subject       text not null default '' check (length(subject) <= 300),
  body          text not null check (btrim(body) <> '' and length(body) <= 5000),
  category      text check (category in ('order', 'question', 'complaint', 'spam', 'unknown')),
  confidence    numeric check (confidence between 0 and 1),
  route         text check (route in ('intake', 'question', 'complaint', 'spam')),
  reply_draft   text check (length(reply_draft) <= 1500),
  created_at    timestamptz not null default now(),
  classified_at timestamptz,
  forwarded_at  timestamptz,
  forward_attempts int not null default 0,
  next_forward_at  timestamptz
);
alter table inbox_messages enable row level security;
revoke all on inbox_messages from anon, authenticated;
create index on inbox_messages (created_at) where classified_at is null;
create index on inbox_messages (classified_at) where route = 'intake' and forwarded_at is null;

-- Zapisuje wiadomość. created = false oznacza, że taki external_id (np. Message-ID) już jest.
create function triage_receive(p jsonb) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare
  v_mid   text := p->>'external_id';
  v_ext   text;
  v_email text := btrim(coalesce(p->>'from_email', ''));
  v_subj  text := left(regexp_replace(coalesce(p->>'subject', ''), '[[:cntrl:]]', ' ', 'g'), 300);
  v_body  text := left(btrim(coalesce(p->>'body', '')), 5000);
  v_id    uuid;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    return jsonb_build_object('error', 'INVALID_INPUT');
  end if;
  -- Message-ID może zawierać znaki spoza bezpiecznego zestawu (np. "!"): wtedy kluczem jest skrót oryginału
  if coalesce(v_mid, '') !~ '^[\x21-\x7E]+$' or length(v_mid) > 500 then
    return jsonb_build_object('error', 'INVALID_EXTERNAL_ID');
  end if;
  v_ext := case when v_mid ~ '^[A-Za-z0-9._:@<>+=/-]{1,200}$' then v_mid
                else 'mid-' || encode(sha256(convert_to(v_mid, 'UTF8')), 'hex') end;
  if v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' or length(v_email) > 200 then
    return jsonb_build_object('error', 'INVALID_EMAIL');
  end if;
  if v_body = '' then
    return jsonb_build_object('error', 'INVALID_BODY');
  end if;
  insert into inbox_messages (external_id, message_id, from_email, subject, body) values (v_ext, v_mid, v_email, v_subj, v_body)
  on conflict (external_id) do nothing returning id into v_id;
  if v_id is null then
    select id into v_id from inbox_messages where external_id = v_ext;
    return jsonb_build_object('created', false, 'inbox_id', v_id, 'external_id', v_ext);
  end if;
  return jsonb_build_object('created', true, 'inbox_id', v_id, 'external_id', v_ext);
end $$;

-- Adresy URL w tekście dla właściciela są rozbrojone (Slack zamienia gołe adresy w linki, a tekst pochodzi od klienta lub modelu).
create function _defang(p text) returns text
language sql immutable set search_path = public, pg_temp as $$
  select regexp_replace(regexp_replace(coalesce(p, ''), 'https?://', 'hxxp://', 'gi'), 'www\.', 'www[.]', 'gi')
$$;

-- Zapisuje wynik klasyfikacji i wybiera trasę. Wejście p to dokładnie to, co zwróciło AI po wstępnej walidacji,
-- a może być też pustym obiektem albo NULL (awaria modelu). Pierwsza klasyfikacja wygrywa, ponowne wywołanie
-- zwraca tę samą trasę i niczego nie dubluje. Powiadomienie dla właściciela powstaje w tej samej transakcji.
create function triage_complete(p_inbox_id uuid, p jsonb) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare
  v_m     inbox_messages;
  v_cat   text;
  v_conf  numeric;
  v_route text;
  v_draft text;
  v_head  text;
begin
  select * into v_m from inbox_messages where id = p_inbox_id for update;
  if not found then
    return jsonb_build_object('error', 'INBOX_NOT_FOUND');
  end if;
  if v_m.classified_at is not null then
    return jsonb_build_object('route', v_m.route, 'inbox_id', p_inbox_id);
  end if;

  v_cat := case when jsonb_typeof(p->'category') = 'string' and (p->>'category') in ('order', 'question', 'complaint', 'spam')
                then p->>'category' end;
  v_conf := case when jsonb_typeof(p->'confidence') = 'number' then (p->>'confidence')::numeric end;
  if v_cat is null or v_conf is null or v_conf < 0 or v_conf > 1 then
    v_cat := null; v_conf := null; v_route := 'intake';
  elsif v_cat = 'order' then
    v_route := 'intake';
  elsif v_cat = 'spam' then
    -- Spam to jedyna trasa, po której nic się nie dzieje, więc deklarowana pewność modelu nie wystarcza (treść maila może
    -- model przekonać do dowolnej odpowiedzi): spam wymaga pewności >= 0,9 ORAZ braku śladów zapytania o meble.
    v_route := case when v_conf >= 0.9 and (v_m.subject || ' ' || v_m.body) !~* '(wycen|zam[oó]w|zamawi|mebl|komod|szaf|st[oó][łl]|stoł|reg[aą]ł|biurk|[łl][oó][żz]k|\d+\s*(x|×)\s*\d+|\d+\s*cm)'
                    then 'spam' else 'intake' end;
  else
    v_route := case when v_conf >= 0.7 then v_cat else 'intake' end;
  end if;

  if v_route = 'question' and jsonb_typeof(p->'reply_draft') = 'string' then
    v_draft := nullif(btrim(left(_defang(regexp_replace(replace(p->>'reply_draft', E'\r', ''), '[\x01-\x08\x0B\x0C\x0E-\x1F\x7F]', ' ', 'g')), 1500)), '');
  end if;

  update inbox_messages
     set category = coalesce(v_cat, 'unknown'), confidence = v_conf, route = v_route, reply_draft = v_draft, classified_at = now()
   where id = p_inbox_id;

  if v_route in ('question', 'complaint') then
    v_head := format(E'%s\nOd: %s\nTemat: %s\n\n%s',
      case v_route when 'question' then '📩 Pytanie klienta' else '⚠️ Reklamacja lub skarga klienta' end,
      _slack_esc(v_m.from_email), _slack_esc(_defang(v_m.subject)), _slack_esc(_defang(left(v_m.body, 500))));
    perform enqueue_slack('inbox_' || v_route,
      left(v_head || case when v_draft is not null
        then E'\n\n*Szkic odpowiedzi do akceptacji (nic nie zostało wysłane):*\n' || _slack_esc(v_draft) else '' end, 2900),
      'inbox:' || p_inbox_id);
  end if;
  return jsonb_build_object('route', v_route, 'inbox_id', p_inbox_id);
end $$;

-- Dane do przekazania do intake (workflow 01). NULL, gdy nie ma takiej wiadomości.
create function inbox_forward_data(p_inbox_id uuid) returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select jsonb_build_object('id', id, 'external_id', external_id, 'from_email', from_email, 'subject', subject, 'body', body)
  from inbox_messages where id = p_inbox_id
$$;

create function triage_mark_forwarded(p_inbox_id uuid) returns void
language sql set search_path = public, pg_temp as $$
  update inbox_messages set forwarded_at = now() where id = p_inbox_id and forwarded_at is null
$$;

-- Wiadomości, które powinny trafić do intake, a jeszcze nie trafiły (awaria po klasyfikacji albo przed nią).
-- Wiadomość bez odpowiedzi AI starsza niż 5 minut jest najpierw kierowana do intake: nic nie wisi w nieskończoność.
create function inbox_unforwarded()
returns table (id uuid, external_id text, from_email text, subject text, body text)
language plpgsql set search_path = public, pg_temp as $$
begin
  update inbox_messages m set category = 'unknown', route = 'intake', classified_at = m.created_at
   where m.classified_at is null and m.created_at <= now() - interval '5 minutes';
  -- Atomowe przejęcie z dzierżawą: równoległe sweepy nie biorą tych samych wiadomości, a każda nieudana próba odsuwa
  -- kolejną (5, 10, ... 60 minut). Po 20 próbach wiadomość przestaje być ponawiana, ale zostaje w tabeli do ręcznej obsługi,
  -- więc trwale wadliwe rekordy nie zagłodzą pozostałych.
  return query
    with c as (
      select m.id from inbox_messages m
      where m.route = 'intake' and m.forwarded_at is null and m.classified_at <= now() - interval '2 minutes'
        and m.forward_attempts < 20 and (m.next_forward_at is null or m.next_forward_at <= now())
      order by m.created_at limit 50
      for update skip locked),
    u as (
      update inbox_messages m
         set forward_attempts = m.forward_attempts + 1,
             next_forward_at = now() + make_interval(mins => 5 * least(m.forward_attempts + 1, 12))
        from c where m.id = c.id
      returning m.id, m.external_id, m.from_email, m.subject, m.body, m.created_at)
    select u.id, u.external_id, u.from_email, u.subject, u.body from u order by u.created_at;
end $$;

revoke execute on function triage_receive(jsonb), triage_complete(uuid, jsonb), inbox_forward_data(uuid),
  triage_mark_forwarded(uuid), inbox_unforwarded(), _defang(text) from public, anon, authenticated;
grant execute on function triage_receive(jsonb), triage_complete(uuid, jsonb), inbox_forward_data(uuid),
  triage_mark_forwarded(uuid), inbox_unforwarded(), _defang(text) to service_role;
