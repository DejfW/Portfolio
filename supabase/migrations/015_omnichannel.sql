-- Task 11: omnikanałowość (zamówienia z salonów), tabela salonów i realistyczne nazwy materiałów.

alter table orders drop constraint orders_source_check;
alter table orders add constraint orders_source_check check (source in ('form', 'email', 'showroom'));

alter table orders
  add column showroom_name    text,
  add column salesperson_email text,
  add column customer_name    text,
  add column consent_at       timestamptz;

-- Salon identyfikuje kod (w adresie tabletu), a uwierzytelnia token. Nazwę salonu i e-mail handlowca
-- zawsze bierzemy stąd, nigdy z żądania.
create table showrooms (
  code             text primary key check (code ~ '^[a-z0-9-]{3,40}$'),
  name             text not null,
  salesperson_email text not null,
  access_token     text not null unique
                     default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  active           boolean not null default true
);
alter table showrooms enable row level security;

-- Nazwy zgodne z asortymentem stolarskim. Na świeżej bazie to no-op (seed ma już nowe nazwy);
-- na istniejącej (np. w chmurze) zmienia nazwy bez resetu. Ceny, stany i BOM zostają.
update materials set name = 'Płyta laminowana Biała Korpusowa 18 mm' where name = 'Płyta MDF 18 mm biała';
update materials set name = 'Dąb Halifax Naturalny 18 mm (Egger)'    where name = 'Płyta dębowa 18 mm';
update materials set name = 'Zawias Blum Clip Top z cichym domykiem' where name = 'Zawias z cichym domykiem';
update materials set name = 'Prowadnica Blum Tandembox 50 cm'        where name = 'Prowadnica szuflady 50 cm';
