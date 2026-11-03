-- Poprawki po recenzji Task 5: publiczna wycena bez kosztów wewnętrznych, materiały dozwolone na wymiar,
-- zamówienia z kalkulatora bezpośrednio do bazy (bez parsera AI), uczciwy przychód w raporcie.

-- Do mebla na wymiar nadają się tylko materiały płytowe; zawiasy, lakier i okucia nie.
alter table materials add column custom_ok boolean not null default false;
update materials set custom_ok = true where unit = 'm2';

create or replace function catalog_for_calculator() returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'products', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name) order by p.name)
      from products p
      where p.labor_hours > 0
        and exists (select 1 from product_materials pm where pm.product_id = p.id)
        and not exists (select 1 from product_materials pm
                        where pm.product_id = p.id and _material_price(pm.material_id) is null)), '[]'),
    'materials', coalesce((
      select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name) order by m.name)
      from materials m where m.custom_ok and _material_price(m.id) is not null), '[]'),
    'limits', jsonb_build_object('min_cm', 20, 'max_cm', 300, 'max_items', 20, 'max_qty', 1000))
$$;

-- Sprawdza pozycje z kalkulatora i wycenia je. Zwraca wynik _quote_lines (koszty wewnętrzne) albo {error}.
create function _calculator_quote(p_items jsonb) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
declare
  v_item jsonb;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    return jsonb_build_object('error', 'NO_ITEMS');
  end if;
  if jsonb_array_length(p_items) > 20 then
    return jsonb_build_object('error', 'TOO_MANY_ITEMS');
  end if;
  for v_item in select * from jsonb_array_elements(p_items) loop
    -- nieznany materiał zgłosi _quote_lines (UNKNOWN_MATERIAL); znany, ale niedozwolony na wymiar, odrzucamy tutaj
    if jsonb_typeof(v_item) = 'object' and jsonb_typeof(v_item->'custom_spec') = 'object'
       and exists (select 1 from materials m
                   where m.id = _try_uuid(v_item->'custom_spec'->>'material_id') and not m.custom_ok) then
      return jsonb_build_object('error', 'MATERIAL_NOT_ALLOWED');
    end if;
  end loop;
  return _quote_lines(p_items);
end $$;

-- Wycena na żywo dla klienta: tylko ceny sprzedaży pozycji i suma. Bez kosztów materiałów, robocizny i marży,
-- bo z nich da się odtworzyć ceny zakupu. Cena pozycji = (materiały + robocizna) × (1 + marża); grosze z
-- zaokrągleń trafiają do ostatniej pozycji, więc suma pozycji zawsze równa się sumie wyceny.
create or replace function quote_preview(p jsonb) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
declare
  v_q     jsonb;
  v_lines jsonb := '[]';
  v_l     jsonb;
  v_n     int;
  v_i     int := 0;
  v_price numeric;
  v_sum   numeric := 0;
  v_total numeric;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    return jsonb_build_object('error', 'NO_ITEMS');
  end if;
  v_q := _calculator_quote(p->'items');
  if v_q ? 'error' then
    return v_q;
  end if;
  v_total := (v_q->>'total')::numeric;
  v_n := jsonb_array_length(v_q->'lines');
  for v_l in select * from jsonb_array_elements(v_q->'lines') loop
    v_i := v_i + 1;
    if v_i < v_n then
      v_price := round(((v_l->>'materials_cost')::numeric + (v_l->>'labor_cost')::numeric) * (1 + _setting('margin')), 2);
      v_sum := v_sum + v_price;
    else
      v_price := v_total - v_sum;
    end if;
    v_lines := v_lines || jsonb_build_object('label', v_l->>'label', 'qty', (v_l->>'qty')::int, 'price', v_price);
  end loop;
  return jsonb_build_object('lines', v_lines, 'total', v_total);
end $$;

-- Zamówienie z kalkulatora: pozycje są już ustrukturyzowane, więc wchodzą bezpośrednio do bazy i są wyceniane
-- po stronie serwera (bez parsera AI). Idempotentne po external_id: ponowienie tego samego żądania zwraca to
-- samo zamówienie (created = false). Zamówienie mieszane (katalog + wymiar) ma kind 'custom'.
create function calculator_order(p jsonb) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare
  v_ext    text := p->>'external_id';
  v_email  text := btrim(coalesce(p->>'customer_email', ''));
  v_notes  text := left(btrim(coalesce(p->>'notes', '')), 1000);
  v_items  jsonb := p->'items';
  v_q      jsonb;
  v_id     uuid;
  v_status text;
  v_has_q  boolean;
  v_kind   text;
  v_desc   text;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    return jsonb_build_object('error', 'INVALID_INPUT');
  end if;
  if v_ext is null or v_ext !~ '^[A-Za-z0-9._:@<>+=/-]{1,200}$' then
    return jsonb_build_object('error', 'INVALID_EXTERNAL_ID');
  end if;
  if length(v_email) > 200 or v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
    return jsonb_build_object('error', 'INVALID_EMAIL');
  end if;

  v_q := _calculator_quote(v_items);
  if v_q ? 'error' then
    return v_q;
  end if;

  v_kind := case when exists (select 1 from jsonb_array_elements(v_items) e
                              where nullif(e->'custom_spec', 'null'::jsonb) is not null) then 'custom' else 'catalog' end;
  v_desc := 'Zamówienie z kalkulatora' || case when v_notes <> '' then E'\nUwagi klienta: ' || v_notes else '' end;

  v_id := upsert_order(jsonb_build_object(
    'external_id', v_ext, 'source', 'form', 'customer_email', v_email, 'kind', v_kind,
    'raw_text', v_desc, 'parsed', jsonb_build_object('source', 'calculator'),
    'items', (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                'product_id', e->>'product_id', 'custom_spec', e->'custom_spec', 'qty', coalesce(e->'qty', '1'::jsonb))))
              from jsonb_array_elements(v_items) e)));

  -- blokada wiersza rozstrzyga równoległe ponowienia: wycenia tylko pierwsze wywołanie
  select status, quote is not null into v_status, v_has_q from orders where id = v_id for update;
  if v_status = 'new' and not v_has_q then
    perform estimate_quote(v_id);
    return jsonb_build_object('order_id', v_id, 'created', true,
      'status', (select status from orders where id = v_id));
  end if;
  return jsonb_build_object('order_id', v_id, 'created', false, 'status', v_status);
end $$;

-- Przychód raportu liczymy po aktualnym cenniku. Gdy którejś pozycji nie da się wycenić (np. wygasła cena),
-- przychód jest nieznany (NULL), a nie zero. Wartość jest przybliżona: zaokrąglenie marży liczone na pozycję.
drop function bestsellers(int);
create function bestsellers(p_days int default 7)
returns table(product_id uuid, name text, qty bigint, revenue numeric)
language sql stable set search_path = public, pg_temp as $$
  with items as (
    select oi.product_id, oi.qty,
           (_quote_lines(jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
              'product_id', oi.product_id, 'custom_spec', oi.custom_spec, 'qty', oi.qty)))) ->> 'total')::numeric as total
    from orders o join order_items oi on oi.order_id = o.id
    where o.status in ('approved', 'in_progress', 'done')
      and o.created_at >= now() - make_interval(days => greatest(1, least(coalesce(p_days, 7), 366)))
  )
  select i.product_id,
         coalesce(p.name, 'Na wymiar') as name,
         sum(i.qty)::bigint as qty,
         case when bool_or(i.total is null) then null else sum(i.total) end as revenue
  from items i left join products p on p.id = i.product_id
  group by i.product_id, p.name
  order by sum(i.qty) desc, sum(i.total) desc nulls last, coalesce(p.name, 'Na wymiar')
$$;

revoke execute on function _calculator_quote(jsonb), calculator_order(jsonb), bestsellers(int), quote_preview(jsonb), catalog_for_calculator()
  from public, anon, authenticated;
grant execute on function _calculator_quote(jsonb), calculator_order(jsonb), bestsellers(int), quote_preview(jsonb), catalog_for_calculator()
  to service_role;
