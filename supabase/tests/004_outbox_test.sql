-- Task 3: katalog dla AI i kolejka wychodzących maili (email_outbox).
begin;

insert into suppliers (id, name, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'Test Hurt', 'a@example.com');
insert into materials (id, name, unit, stock, min_stock) values
  ('00000000-0000-0000-0000-0000000000b1', 'Test materiał katalogowy', 'szt', 10, 1);
insert into products (id, name, base_price, labor_hours) values
  ('00000000-0000-0000-0000-0000000000c1', 'Test produkt katalogowy', 0, 1);

-- test_catalog_for_llm: lista produktów i materiałów z id i nazwą, bez cen i stanów
do $$
declare v_c jsonb;
begin
  v_c := catalog_for_llm();
  assert exists (select 1 from jsonb_array_elements(v_c->'products') p
                 where p->>'id' = '00000000-0000-0000-0000-0000000000c1'
                   and p->>'name' = 'Test produkt katalogowy'), 'product listed';
  assert exists (select 1 from jsonb_array_elements(v_c->'materials') m
                 where m->>'id' = '00000000-0000-0000-0000-0000000000b1'
                   and m->>'name' = 'Test materiał katalogowy'), 'material listed';
  assert not (v_c::text like '%stock%' or v_c::text like '%price%'), 'no stock or price leaked';
  raise notice 'PASS test_catalog_for_llm';
end $$;

-- test_enqueue_email_idempotent: ten sam rodzaj maila dla zamówienia trafia do kolejki raz
do $$
declare v_o uuid; v_a uuid; v_b uuid;
begin
  v_o := upsert_order(jsonb_build_object(
    'external_id', 'ob-1', 'source', 'form', 'customer_email', 'k@example.com', 'kind', 'catalog'));
  v_a := enqueue_email(v_o, 'customer_quote', 'k@example.com', 'Wycena', 'Treść');
  v_b := enqueue_email(v_o, 'customer_quote', 'k@example.com', 'Wycena', 'Treść');
  assert v_a is not null, 'first enqueued';
  assert v_b is null, 'second ignored';
  assert (select count(*) from email_outbox where order_id = v_o and kind = 'customer_quote') = 1, 'one row';

  -- inny rodzaj maila dla tego samego zamówienia jest dozwolony
  assert enqueue_email(v_o, 'owner_alert', 'owner@example.com', 'Alert', 'Treść') is not null, 'other kind ok';
  raise notice 'PASS test_enqueue_email_idempotent';
end $$;

-- test_enqueue_email_validates: pusty adres, temat i nieznany rodzaj są odrzucane
do $$
declare v_o uuid;
begin
  v_o := upsert_order(jsonb_build_object(
    'external_id', 'ob-2', 'source', 'form', 'customer_email', 'k@example.com', 'kind', 'catalog'));
  begin
    perform enqueue_email(v_o, 'customer_quote', '', 'Temat', 'Treść');
    assert false, 'empty to accepted';
  exception when others then
    assert sqlerrm <> 'empty to accepted', 'wrong: ' || sqlerrm;
  end;
  begin
    perform enqueue_email(v_o, 'spam_blast', 'k@example.com', 'Temat', 'Treść');
    assert false, 'unknown kind accepted';
  exception when others then
    assert sqlerrm <> 'unknown kind accepted', 'wrong: ' || sqlerrm;
  end;
  raise notice 'PASS test_enqueue_email_validates';
end $$;

-- test_outbox_not_public: kolejka maili i funkcje dostępne tylko dla service_role
do $$
declare v_fn text;
begin
  foreach v_fn in array array['catalog_for_llm()', 'enqueue_email(uuid,text,text,text,text)'] loop
    assert not has_function_privilege('anon', v_fn, 'execute'), 'anon can execute ' || v_fn;
    assert not has_function_privilege('authenticated', v_fn, 'execute'), 'authenticated can execute ' || v_fn;
    assert has_function_privilege('service_role', v_fn, 'execute'), 'service_role cannot execute ' || v_fn;
  end loop;
  assert not has_table_privilege('anon', 'email_outbox', 'select'), 'anon can read outbox';
  assert not has_table_privilege('authenticated', 'email_outbox', 'select'), 'authenticated can read outbox';
  assert (select relrowsecurity from pg_class where relname = 'email_outbox'), 'rls enabled';
  raise notice 'PASS test_outbox_not_public';
end $$;

rollback;
