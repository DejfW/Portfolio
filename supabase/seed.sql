-- Dane demo. Wszystkie firmy, adresy i klienci są fikcyjni.

insert into settings (key, value) values
  ('labor_rate', 120),   -- PLN za godzinę robocizny
  ('margin',     0.25),  -- marża od materiałów i robocizny
  ('waste',      0.15);  -- naddatek na odpad przy meblach na wymiar

insert into suppliers (name, email) values
  ('Hurtownia Drewna Lasek', 'zamowienia@lasek.example.com'),
  ('MebloHurt Poznań',       'biuro@meblohurt.example.com'),
  ('Okucia24 Hurt',          'hurt@okucia24.example.com');

-- Uchwyt czarny 128 mm i Olej do drewna są celowo poniżej stanu minimalnego (alert w demo).
insert into materials (name, unit, stock, min_stock) values
  ('Płyta dębowa 18 mm',          'm2',   40,  10),
  ('Płyta MDF 18 mm biała',       'm2',   60,  15),
  ('Płyta orzechowa 18 mm',       'm2',   15,   8),
  ('Sklejka brzozowa 18 mm',      'm2',   30,  10),
  ('Płyta HDF 3 mm',              'm2',   50,  15),
  ('Blat dębowy lity 40 mm',      'm2',    8,   4),
  ('Zawias z cichym domykiem',    'szt', 120,  40),
  ('Prowadnica szuflady 50 cm',   'para', 30,  20),
  ('Uchwyt czarny 128 mm',        'szt',  15,  30),
  ('Nóżka stalowa 70 cm',         'szt',  24,  16),
  ('Lakier wodny bezbarwny',      'l',     6,   5),
  ('Olej do drewna',              'l',     2,   3),
  ('Konfirmat 7x50 (op. 100 szt)', 'op',  10,   4);

-- Ceny hurtowni. Dąb w Lasku jest najtańszy, ale cena ma 40 dni, więc po Task 2 przestaje się liczyć.
insert into supplier_prices (supplier_id, material_id, price, updated_at)
select s.id, m.id, v.price, now() - make_interval(days => v.age_days)
from (values
  ('Hurtownia Drewna Lasek', 'Płyta dębowa 18 mm',          189.00, 40),
  ('MebloHurt Poznań',       'Płyta dębowa 18 mm',          205.00,  2),
  ('Hurtownia Drewna Lasek', 'Płyta MDF 18 mm biała',        92.00,  3),
  ('MebloHurt Poznań',       'Płyta MDF 18 mm biała',        85.00,  2),
  ('Hurtownia Drewna Lasek', 'Płyta orzechowa 18 mm',       310.00,  5),
  ('Hurtownia Drewna Lasek', 'Sklejka brzozowa 18 mm',      128.00,  3),
  ('MebloHurt Poznań',       'Sklejka brzozowa 18 mm',      134.00,  2),
  ('Hurtownia Drewna Lasek', 'Płyta HDF 3 mm',               18.00,  3),
  ('MebloHurt Poznań',       'Płyta HDF 3 mm',               16.00,  2),
  ('Hurtownia Drewna Lasek', 'Blat dębowy lity 40 mm',      640.00,  3),
  ('MebloHurt Poznań',       'Blat dębowy lity 40 mm',      615.00,  2),
  ('MebloHurt Poznań',       'Zawias z cichym domykiem',     14.50,  2),
  ('Okucia24 Hurt',          'Zawias z cichym domykiem',     11.90,  1),
  ('MebloHurt Poznań',       'Prowadnica szuflady 50 cm',    42.00,  2),
  ('Okucia24 Hurt',          'Prowadnica szuflady 50 cm',    38.50,  1),
  ('MebloHurt Poznań',       'Uchwyt czarny 128 mm',          9.80,  2),
  ('Okucia24 Hurt',          'Uchwyt czarny 128 mm',         12.40,  1),
  ('Okucia24 Hurt',          'Nóżka stalowa 70 cm',          54.00,  1),
  ('MebloHurt Poznań',       'Lakier wodny bezbarwny',       69.00,  2),
  ('Okucia24 Hurt',          'Lakier wodny bezbarwny',       72.00,  1),
  ('MebloHurt Poznań',       'Olej do drewna',               85.00,  2),
  ('Okucia24 Hurt',          'Olej do drewna',               79.00,  1),
  ('Okucia24 Hurt',          'Konfirmat 7x50 (op. 100 szt)', 21.00,  1)
) as v(supplier, material, price, age_days)
join suppliers s on s.name = v.supplier
join materials m on m.name = v.material;

insert into products (name, base_price, labor_hours) values
  ('Komoda dębowa, 4 szuflady',     2400,  9),
  ('Szafka nocna MDF biała',         650,  3),
  ('Stół dębowy 160×90',            3200,  6),
  ('Regał sklejkowy 80×200',        1300,  5),
  ('Szafa MDF 2-drzwiowa',          3900, 12),
  ('Biurko orzechowe 140×70',       2800,  7),
  ('Ławka dębowa 120 cm',           1100,  4),
  ('Szafka RTV sklejka 180 cm',     1700,  6);

insert into product_materials (product_id, material_id, qty)
select p.id, m.id, v.qty
from (values
  ('Komoda dębowa, 4 szuflady', 'Płyta dębowa 18 mm',           3.2),
  ('Komoda dębowa, 4 szuflady', 'Płyta HDF 3 mm',               0.8),
  ('Komoda dębowa, 4 szuflady', 'Prowadnica szuflady 50 cm',    4),
  ('Komoda dębowa, 4 szuflady', 'Uchwyt czarny 128 mm',         4),
  ('Komoda dębowa, 4 szuflady', 'Olej do drewna',               0.5),
  ('Szafka nocna MDF biała',    'Płyta MDF 18 mm biała',        1.1),
  ('Szafka nocna MDF biała',    'Płyta HDF 3 mm',               0.3),
  ('Szafka nocna MDF biała',    'Prowadnica szuflady 50 cm',    1),
  ('Szafka nocna MDF biała',    'Uchwyt czarny 128 mm',         1),
  ('Stół dębowy 160×90',        'Blat dębowy lity 40 mm',       1.44),
  ('Stół dębowy 160×90',        'Nóżka stalowa 70 cm',          4),
  ('Stół dębowy 160×90',        'Olej do drewna',               0.4),
  ('Regał sklejkowy 80×200',    'Sklejka brzozowa 18 mm',       3.6),
  ('Regał sklejkowy 80×200',    'Płyta HDF 3 mm',               1.6),
  ('Regał sklejkowy 80×200',    'Lakier wodny bezbarwny',       0.6),
  ('Regał sklejkowy 80×200',    'Konfirmat 7x50 (op. 100 szt)', 0.3),
  ('Szafa MDF 2-drzwiowa',      'Płyta MDF 18 mm biała',        6.5),
  ('Szafa MDF 2-drzwiowa',      'Płyta HDF 3 mm',               2.2),
  ('Szafa MDF 2-drzwiowa',      'Zawias z cichym domykiem',     4),
  ('Szafa MDF 2-drzwiowa',      'Uchwyt czarny 128 mm',         2),
  ('Szafa MDF 2-drzwiowa',      'Konfirmat 7x50 (op. 100 szt)', 0.5),
  ('Biurko orzechowe 140×70',   'Płyta orzechowa 18 mm',        2.2),
  ('Biurko orzechowe 140×70',   'Nóżka stalowa 70 cm',          4),
  ('Biurko orzechowe 140×70',   'Olej do drewna',               0.3),
  ('Ławka dębowa 120 cm',       'Płyta dębowa 18 mm',           1.0),
  ('Ławka dębowa 120 cm',       'Nóżka stalowa 70 cm',          4),
  ('Ławka dębowa 120 cm',       'Olej do drewna',               0.2),
  ('Szafka RTV sklejka 180 cm', 'Sklejka brzozowa 18 mm',       2.4),
  ('Szafka RTV sklejka 180 cm', 'Płyta HDF 3 mm',               0.6),
  ('Szafka RTV sklejka 180 cm', 'Zawias z cichym domykiem',     4),
  ('Szafka RTV sklejka 180 cm', 'Lakier wodny bezbarwny',       0.4)
) as v(product, material, qty)
join products p on p.name = v.product
join materials m on m.name = v.material;

-- 60 zrealizowanych zamówień z ostatnich 90 dni. Rozkład jest celowo nierówny,
-- żeby raport bestsellerów miał wyraźnego lidera (komoda, szafka nocna, stół).
do $$
declare
  v_names text[];
  v_id    uuid;
  v_items jsonb;
  v_at    timestamptz;
  i       int;
begin
  v_names := array_fill('Komoda dębowa, 4 szuflady'::text, array[14])
          || array_fill('Szafka nocna MDF biała'::text,    array[12])
          || array_fill('Stół dębowy 160×90'::text,        array[10])
          || array_fill('Regał sklejkowy 80×200'::text,    array[7])
          || array_fill('Szafa MDF 2-drzwiowa'::text,      array[5])
          || array_fill('Biurko orzechowe 140×70'::text,   array[4])
          || array_fill('Ławka dębowa 120 cm'::text,       array[3])
          || array_fill('Szafka RTV sklejka 180 cm'::text, array[3]);

  for i in 1 .. array_length(v_names, 1) loop
    v_at := now() - make_interval(days => 1 + (i * 37) % 89);
    v_items := jsonb_build_array(jsonb_build_object(
      'product_id', (select id from products where name = v_names[i]),
      'qty', case when i % 5 = 0 then 2 else 1 end));
    v_id := upsert_order(jsonb_build_object(
      'external_id', format('seed-%s', lpad(i::text, 3, '0')),
      'source', case when i % 3 = 0 then 'email' else 'form' end,
      'customer_email', format('klient%s@example.com', i),
      'kind', 'catalog',
      'items', v_items));
    update orders
    set status = 'done', quote = _quote_lines(v_items), quoted_at = v_at, created_at = v_at
    where id = v_id;
  end loop;

  -- 2 meble na wymiar
  for i in 1 .. 2 loop
    v_at := now() - make_interval(days => 10 + i * 20);
    v_items := jsonb_build_array(jsonb_build_object(
      'custom_spec', jsonb_build_object(
        'width_cm', 120 + i * 40, 'height_cm', 90, 'depth_cm', 45,
        'material_id', (select id from materials where name = 'Sklejka brzozowa 18 mm')),
      'qty', 1));
    v_id := upsert_order(jsonb_build_object(
      'external_id', format('seed-custom-%s', i),
      'source', 'email',
      'customer_email', format('projekt%s@example.com', i),
      'kind', 'custom',
      'items', v_items));
    update orders
    set status = 'done', quote = _quote_lines(v_items), quoted_at = v_at, created_at = v_at
    where id = v_id;
  end loop;
end $$;

-- Wyceny czekające na odpowiedź klienta (demo follow-upów z Task 8): 4, 8 i 15 dni.
do $$
declare
  v_id    uuid;
  v_items jsonb;
  v_days  int;
  i       int := 0;
begin
  foreach v_days in array array[4, 8, 15] loop
    i := i + 1;
    v_items := jsonb_build_array(jsonb_build_object(
      'product_id', (select id from products where name = 'Szafa MDF 2-drzwiowa'), 'qty', 1));
    v_id := upsert_order(jsonb_build_object(
      'external_id', format('seed-quoted-%s', i),
      'source', 'form',
      'customer_email', format('oferta%s@example.com', i),
      'kind', 'catalog',
      'items', v_items));
    update orders
    set status = 'quoted', quote = _quote_lines(v_items),
        quoted_at = now() - make_interval(days => v_days),
        created_at = now() - make_interval(days => v_days),
        followups_sent = case when v_days >= 8 then 1 else 0 end
    where id = v_id;
  end loop;
end $$;
