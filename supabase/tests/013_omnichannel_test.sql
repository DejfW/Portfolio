-- Task 11: omnikanałowość (source 'showroom'), salony, realistyczny asortyment w seedzie.
begin;

-- test_source_showroom_allowed
do $$
begin
  insert into orders (external_id, source, customer_email, kind)
  values ('t13-showroom', 'showroom', 'a@example.com', 'catalog');
  begin
    insert into orders (external_id, source, customer_email, kind)
    values ('t13-fax', 'fax', 'a@example.com', 'catalog');
    assert false, 'source fax should be rejected';
  exception when check_violation then
    null;
  end;
  raise notice 'PASS %', 'test_source_showroom_allowed';
end $$;

-- test_orders_new_columns
do $$
begin
  update orders set showroom_name = 'Salon', salesperson_email = 's@example.com',
                    customer_name = 'Jan', consent_at = now()
  where external_id = 't13-showroom';
  assert found, 'new orders columns exist';
  raise notice 'PASS %', 'test_orders_new_columns';
end $$;

-- test_showrooms_seeded
do $$
begin
  assert (select count(*) from showrooms where active) = 3, 'three active showrooms';
  assert (select count(distinct access_token) from showrooms) = 3, 'tokens are unique';
  assert not exists (select 1 from showrooms where salesperson_email !~ '@example\.com$'), 'fictional addresses';
  raise notice 'PASS %', 'test_showrooms_seeded';
end $$;

-- test_material_names_realistic
do $$
declare v_missing text;
begin
  select string_agg(n, ', ') into v_missing
  from unnest(array[
    'Płyta laminowana Biała Korpusowa 18 mm', 'Dąb Halifax Naturalny 18 mm (Egger)', 'MDF Lakierowany Mat 18 mm',
    'Zawias Blum Clip Top z cichym domykiem', 'Prowadnica Blum Tandembox 50 cm', 'Obrzeże ABS 2 mm']) n
  where not exists (select 1 from materials m where m.name = n);
  assert v_missing is null, 'missing materials: ' || coalesce(v_missing, '');
  assert (select unit from materials where name = 'Obrzeże ABS 2 mm') = 'mb', 'edging unit is mb';
  assert (select unit from materials where name = 'MDF Lakierowany Mat 18 mm') = 'm2', 'MDF unit is m2';
  raise notice 'PASS %', 'test_material_names_realistic';
end $$;

-- test_quote_unchanged_after_rename: wartości zapisane z bazy przed zmianą nazw
do $$
declare r record;
begin
  for r in select * from (values
      ('Biurko orzechowe 140×70', 2202.13), ('Komoda dębowa, 4 szuflady', 2476.88),
      ('Ławka dębowa 120 cm', 1146.00), ('Regał sklejkowy 80×200', 1417.63),
      ('Stół dębowy 160×90', 2316.50), ('Szafa MDF 2-drzwiowa', 2631.75),
      ('Szafka nocna MDF biała', 633.25), ('Szafka RTV sklejka 180 cm', 1390.00)) v(name, expected) loop
    assert (select (_quote_lines(jsonb_build_array(jsonb_build_object('product_id', p.id, 'qty', 1)))->>'total')::numeric
            from products p where p.name = r.name) = r.expected, 'quote changed for ' || r.name;
  end loop;
  raise notice 'PASS %', 'test_quote_unchanged_after_rename';
end $$;

-- test_obrzeze_not_custom_ok
do $$
begin
  assert (select custom_ok from materials where name = 'Obrzeże ABS 2 mm') = false, 'edging is not custom_ok';
  assert not (catalog_for_calculator()::text like '%Obrzeże ABS%'), 'edging hidden from calculator';
  assert (select count(*) from best_price((select id from materials where name = 'Obrzeże ABS 2 mm'))) = 1, 'edging priced';
  raise notice 'PASS %', 'test_obrzeze_not_custom_ok';
end $$;

rollback;
