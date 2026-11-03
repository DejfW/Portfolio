-- Poprawki z raportu bezpieczeństwa Supabase (advisors).

-- 1. Stały search_path we wszystkich funkcjach aplikacji. Bez niego wynik funkcji zależy od ustawień
--    roli wywołującej, a nazwy bez schematu można podmienić obiektem w innym schemacie.
--    Pętla obejmuje też funkcje dodawane w przyszłych migracjach, jeśli ta migracja zostanie uruchomiona
--    ponownie; nowe funkcje i tak pilnuje test supabase/tests/006_security_test.sql.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      and p.proname <> 'rls_auto_enable'
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('alter function %s set search_path = public, pg_temp', f.sig);
  end loop;
end $$;

-- 2. rls_auto_enable() dostarcza platforma Supabase (wyzwalacz zdarzeń ensure_rls włącza RLS na nowych
--    tabelach). Jako SECURITY DEFINER nie powinna być wywoływalna przez publiczne API, a wyzwalacz
--    zdarzeń nie wymaga prawa EXECUTE przy uruchomieniu. Lokalnie funkcji nie ma, więc warunek.
do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
  end if;
end $$;
