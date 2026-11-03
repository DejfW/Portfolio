-- Zgodność z raportem bezpieczeństwa Supabase (advisors).
begin;

-- test_functions_have_search_path: każda funkcja w schemacie public ma ustawiony search_path,
-- bo inaczej wynik zależy od roli wywołującej (ostrzeżenie function_search_path_mutable).
-- Pomijamy funkcje z rozszerzeń oraz rls_auto_enable, która jest dostarczana przez platformę Supabase.
do $$
declare v_bad text;
begin
  select string_agg(p.oid::regprocedure::text, ', ') into v_bad
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prokind = 'f'
    and p.proname <> 'rls_auto_enable'
    and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
    and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%');
  assert v_bad is null, 'funkcje bez search_path: ' || v_bad;
  raise notice 'PASS test_functions_have_search_path';
end $$;

-- test_no_public_execute: żadna funkcja w public nie jest wykonywalna dla anon ani authenticated
-- (wywołania idą kluczem service_role z n8n). Wyjątki trzeba dodać tu świadomie.
do $$
declare v_bad text;
begin
  select string_agg(p.oid::regprocedure::text, ', ') into v_bad
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prokind = 'f'
    and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
    and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'));
  assert v_bad is null, 'funkcje dostępne publicznie: ' || v_bad;
  raise notice 'PASS test_no_public_execute';
end $$;

-- test_no_anon_table_access: anon i authenticated nie mają żadnych praw do tabel i widoków w public
do $$
declare v_bad text;
begin
  select string_agg(c.relname, ', ') into v_bad
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind in ('r', 'v', 'p', 'm')
    and (has_table_privilege('anon', c.oid, 'select,insert,update,delete')
         or has_table_privilege('authenticated', c.oid, 'select,insert,update,delete'));
  assert v_bad is null, 'tabele dostępne publicznie: ' || v_bad;
  raise notice 'PASS test_no_anon_table_access';
end $$;

rollback;
