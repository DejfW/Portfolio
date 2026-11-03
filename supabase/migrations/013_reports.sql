-- Task 5: kalkulator dla klienta (wycena bez zapisu) i raport bestsellerów.

-- Publiczny katalog dla kalkulatora: tylko pozycje, które da się wycenić (są ceny materiałów i skład).
-- Bez cen hurtowych i stanów magazynowych.
create function catalog_for_calculator() returns jsonb
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
      from materials m where _material_price(m.id) is not null), '[]'),
    'limits', jsonb_build_object('min_cm', 20, 'max_cm', 300, 'max_items', 20, 'max_qty', 1000))
$$;

-- Wycena na żywo dla kalkulatora: ta sama logika co estimate_quote (_quote_lines), ale bez zapisu.
-- Wejście: {"items": [{"product_id": "...", "qty": 1} | {"custom_spec": {...}, "qty": 1}]}.
-- Błędy wracają jako {"error": "..."}; liczba pozycji jest ograniczona, bo funkcja jest publiczna.
create function quote_preview(p jsonb) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
declare
  v_items jsonb := p->'items';
begin
  if p is null or jsonb_typeof(p) <> 'object' or v_items is null or jsonb_typeof(v_items) <> 'array' then
    return jsonb_build_object('error', 'NO_ITEMS');
  end if;
  if jsonb_array_length(v_items) > 20 then
    return jsonb_build_object('error', 'TOO_MANY_ITEMS');
  end if;
  return _quote_lines(v_items);
end $$;

-- Bestsellery z ostatnich p_days dni: liczą się zamówienia zatwierdzone przez właściciela
-- (approved, in_progress, done). Przychód to wycena pozycji po aktualnych cenach materiałów;
-- meble na wymiar są jedną pozycją "Na wymiar" (product_id null).
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
         coalesce(sum(i.total), 0) as revenue
  from items i left join products p on p.id = i.product_id
  group by i.product_id, p.name
  order by sum(i.qty) desc, coalesce(sum(i.total), 0) desc, coalesce(p.name, 'Na wymiar')
$$;

-- Dane do tygodniowego raportu w jednym wywołaniu.
create function weekly_report() returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'week',  coalesce((select jsonb_agg(to_jsonb(b)) from bestsellers(7) b), '[]'),
    'month', coalesce((select jsonb_agg(to_jsonb(b)) from bestsellers(30) b), '[]'))
$$;

alter table slack_outbox drop constraint slack_outbox_kind_check;
alter table slack_outbox add constraint slack_outbox_kind_check
  check (kind in ('task_assigned', 'stock_shortage', 'stock_digest', 'task_done', 'weekly_report'));

revoke execute on function catalog_for_calculator(), quote_preview(jsonb), bestsellers(int), weekly_report()
  from public, anon, authenticated;
grant execute on function catalog_for_calculator(), quote_preview(jsonb), bestsellers(int), weekly_report()
  to service_role;
