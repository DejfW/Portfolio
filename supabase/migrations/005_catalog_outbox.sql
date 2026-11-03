-- Katalog dla AI parsującego zamówienia i kolejka wychodzących maili.

-- Supabase domyślnie nadaje anon i authenticated prawa do nowych tabel; RLS bez polityk blokuje
-- wiersze, ale odbieramy też same prawa, żeby ochrona nie opierała się na jednej warstwie.
revoke all on all tables in schema public from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;

-- Lista produktów i materiałów (id i nazwa) do promptu. Bez cen i stanów magazynowych.
create function catalog_for_llm() returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'products',  coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name)
                           from products), '[]'),
    'materials', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name)
                           from materials), '[]'))
$$;

-- Wychodzące maile. n8n tylko dopisuje wiersze; faktyczną wysyłkę robi osobny workflow,
-- gdy skrzynka jest podłączona (do tego czasu wszystko da się sprawdzić w tabeli).
create table email_outbox (
  id         uuid primary key default gen_random_uuid(),
  order_id   uuid not null references orders(id) on delete cascade,
  kind       text not null check (kind in ('customer_quote','needs_info','owner_alert')),
  to_email   text not null check (to_email like '%_@_%'),
  subject    text not null check (subject <> ''),
  body       text not null,
  created_at timestamptz not null default now(),
  sent_at    timestamptz,
  -- jeden mail danego rodzaju na zamówienie: ponowne przetworzenie niczego nie dubluje
  unique (order_id, kind)
);
alter table email_outbox enable row level security;
revoke all on email_outbox from anon, authenticated;
create index on email_outbox (sent_at) where sent_at is null;

-- Dopisuje mail do kolejki. Zwraca id albo NULL, gdy taki mail już jest.
create function enqueue_email(p_order_id uuid, p_kind text, p_to text, p_subject text, p_body text)
returns uuid
language sql as $$
  insert into email_outbox (order_id, kind, to_email, subject, body)
  values (p_order_id, p_kind, p_to, p_subject, p_body)
  on conflict (order_id, kind) do nothing
  returning id
$$;
