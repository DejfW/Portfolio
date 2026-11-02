-- Schemat systemu dla sklepu z meblami na zamówienie.
-- Baza jest jedynym źródłem prawdy; n8n łączy się kluczem service_role.

create table settings (
  key   text primary key,
  value numeric not null
);

create table materials (
  id        uuid primary key default gen_random_uuid(),
  name      text not null unique,
  unit      text not null,
  stock     numeric(12,3) not null default 0 check (stock >= 0),
  reserved  numeric(12,3) not null default 0 check (reserved >= 0),
  min_stock numeric(12,3) not null default 0 check (min_stock >= 0),
  -- dostępne = stock - reserved nigdy nie spada poniżej zera
  check (reserved <= stock)
);

create table products (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  base_price  numeric(12,2) not null default 0,
  labor_hours numeric(8,2) not null default 0 check (labor_hours >= 0)
);

create table product_materials (
  product_id  uuid not null references products(id) on delete cascade,
  material_id uuid not null references materials(id),
  qty         numeric(12,3) not null check (qty > 0),
  primary key (product_id, material_id)
);

create table suppliers (
  id    uuid primary key default gen_random_uuid(),
  name  text not null unique,
  email text not null
);

create table supplier_prices (
  supplier_id uuid not null references suppliers(id) on delete cascade,
  material_id uuid not null references materials(id) on delete cascade,
  price       numeric(12,2) not null,
  updated_at  timestamptz not null default now(),
  primary key (supplier_id, material_id)
);

create table orders (
  id                  uuid primary key default gen_random_uuid(),
  external_id         text not null unique,
  source              text not null check (source in ('form','email')),
  customer_email      text not null,
  kind                text not null check (kind in ('catalog','custom')),
  status              text not null default 'new' check (status in
                        ('new','needs_info','needs_review','quoted','approved','in_progress','done','lost')),
  raw_text            text,
  parsed              jsonb,
  quote               jsonb,
  quoted_at           timestamptz,
  followups_sent      int not null default 0,
  public_token        uuid not null unique default gen_random_uuid(),
  review_requested_at timestamptz,
  created_at          timestamptz not null default now()
);

create table order_items (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references orders(id) on delete cascade,
  product_id  uuid references products(id),
  custom_spec jsonb,
  qty         int not null default 1 check (qty > 0),
  -- pozycja to albo produkt z katalogu, albo mebel na wymiar
  check ((product_id is null) <> (custom_spec is null))
);

create table tasks (
  id         uuid primary key default gen_random_uuid(),
  order_id   uuid not null references orders(id),
  assignee   text not null,
  status     text not null default 'todo' check (status in ('todo','doing','done')),
  created_at timestamptz not null default now()
);

create table stock_movements (
  id          uuid primary key default gen_random_uuid(),
  material_id uuid not null references materials(id),
  task_id     uuid references tasks(id),
  qty         numeric(12,3) not null check (qty > 0),
  kind        text not null check (kind in ('reserve','consume','release','receive')),
  created_at  timestamptz not null default now()
);

create index on order_items (order_id);
create index on orders (status);
create index on supplier_prices (material_id);
create index on stock_movements (material_id);

-- Tabele nie są dostępne przez publiczne API: RLS bez polityk, więc dostęp ma tylko service_role.
alter table settings          enable row level security;
alter table materials         enable row level security;
alter table products          enable row level security;
alter table product_materials enable row level security;
alter table suppliers         enable row level security;
alter table supplier_prices   enable row level security;
alter table orders            enable row level security;
alter table order_items       enable row level security;
alter table tasks             enable row level security;
alter table stock_movements   enable row level security;

-- Funkcje też nie są wywoływalne anonimowo; wyjątki (np. strona statusu) dostają grant jawnie.
-- Prawo PUBLIC do funkcji jest globalnym domyślnym uprawnieniem Postgresa, więc odbieramy je
-- bez "in schema"; grant dla anon/authenticated nadaje Supabase per schemat.
alter default privileges for role postgres revoke execute on functions from public;
alter default privileges for role postgres in schema public revoke execute on functions from anon, authenticated;
alter default privileges for role postgres in schema public grant execute on functions to service_role;
