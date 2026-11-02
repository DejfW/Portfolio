-- Przyjmowanie zamówień i wycena.

create function _setting(p_key text) returns numeric
language sql stable as $$
  select value from settings where key = p_key
$$;

-- Cena materiału do wyceny. Task 2 podmienia ją na best_price (reguła 30 dni).
create function _material_price(p_material_id uuid) returns numeric
language sql stable as $$
  select min(price) from supplier_prices where material_id = p_material_id and price > 0
$$;

-- Powierzchnia płyty w m² dla mebla na wymiar, z naddatkiem na odpad.
create function _custom_area(p_spec jsonb) returns numeric
language sql stable as $$
  select (2 * w * d + 2 * h * d + w * h) / 10000 * (1 + _setting('waste'))
  from (select (p_spec->>'width_cm')::numeric  as w,
               (p_spec->>'height_cm')::numeric as h,
               (p_spec->>'depth_cm')::numeric  as d) s
$$;

-- Wycena listy pozycji [{product_id?, custom_spec?, qty}] bez zapisu.
-- Zwraca {lines, materials_cost, labor_cost, margin, total} albo {error, ...}.
create function _quote_lines(p_items jsonb) returns jsonb
language plpgsql stable as $$
declare
  v_rate       numeric := _setting('labor_rate');
  v_margin_pct numeric := _setting('margin');
  v_item       jsonb;
  v_spec       jsonb;
  v_qty        int;
  v_label      text;
  v_hours      numeric;
  v_area       numeric;
  v_price      numeric;
  v_mat        numeric;
  v_lab        numeric;
  v_bom        record;
  v_lines      jsonb := '[]';
  v_mat_total  numeric := 0;
  v_lab_total  numeric := 0;
  v_margin     numeric;
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then
    return jsonb_build_object('error', 'NO_ITEMS');
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty := coalesce((v_item->>'qty')::int, 1);
    v_mat := 0;

    if v_item->>'product_id' is not null then
      select name, labor_hours into v_label, v_hours
      from products where id = (v_item->>'product_id')::uuid;
      if not found then
        return jsonb_build_object('error', 'UNKNOWN_PRODUCT', 'product_id', v_item->>'product_id');
      end if;
      v_lab := v_hours * v_rate;

      for v_bom in
        select pm.material_id, pm.qty, m.name
        from product_materials pm join materials m on m.id = pm.material_id
        where pm.product_id = (v_item->>'product_id')::uuid
      loop
        v_price := _material_price(v_bom.material_id);
        if v_price is null then
          return jsonb_build_object('error', 'NO_PRICE',
            'material_id', v_bom.material_id, 'material_name', v_bom.name);
        end if;
        v_mat := v_mat + v_bom.qty * v_price;
      end loop;
    else
      v_spec := v_item->'custom_spec';
      select name into v_label from materials where id = (v_spec->>'material_id')::uuid;
      if not found then
        return jsonb_build_object('error', 'UNKNOWN_MATERIAL', 'material_id', v_spec->>'material_id');
      end if;
      v_price := _material_price((v_spec->>'material_id')::uuid);
      if v_price is null then
        return jsonb_build_object('error', 'NO_PRICE',
          'material_id', v_spec->>'material_id', 'material_name', v_label);
      end if;
      v_area  := _custom_area(v_spec);
      v_mat   := v_area * v_price;
      v_lab   := (4 + 2 * v_area) * v_rate;
      v_label := format('Na wymiar %s×%s×%s cm, %s',
        v_spec->>'width_cm', v_spec->>'height_cm', v_spec->>'depth_cm', v_label);
    end if;

    v_mat := v_mat * v_qty;
    v_lab := v_lab * v_qty;
    v_mat_total := v_mat_total + v_mat;
    v_lab_total := v_lab_total + v_lab;
    v_lines := v_lines || jsonb_build_object(
      'label', v_label, 'qty', v_qty,
      'materials_cost', round(v_mat, 2), 'labor_cost', round(v_lab, 2));
  end loop;

  -- zaokrąglenie dopiero w wyniku końcowym
  v_margin := (v_mat_total + v_lab_total) * v_margin_pct;
  return jsonb_build_object(
    'lines', v_lines,
    'materials_cost', round(v_mat_total, 2),
    'labor_cost', round(v_lab_total, 2),
    'margin', round(v_margin, 2),
    'total', round(v_mat_total + v_lab_total + v_margin, 2));
end $$;

-- Wstawia zamówienie z pozycjami. Ten sam external_id zwraca istniejące id bez zmian.
create function upsert_order(p jsonb) returns uuid
language plpgsql as $$
declare
  v_id uuid;
begin
  if coalesce(p->>'external_id', '') = '' then
    raise exception 'MISSING_EXTERNAL_ID';
  end if;

  insert into orders (external_id, source, customer_email, kind, status, raw_text, parsed)
  values (p->>'external_id', p->>'source', p->>'customer_email', p->>'kind',
          coalesce(p->>'status', 'new'), p->>'raw_text', p->'parsed')
  on conflict (external_id) do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from orders where external_id = p->>'external_id';
    return v_id;
  end if;

  insert into order_items (order_id, product_id, custom_spec, qty)
  select v_id, (e->>'product_id')::uuid, e->'custom_spec', coalesce((e->>'qty')::int, 1)
  from jsonb_array_elements(coalesce(p->'items', '[]')) e;

  return v_id;
end $$;

-- Wycenia zamówienie i zapisuje wynik. Błąd wyceny daje status needs_review zamiast kwoty.
create function estimate_quote(p_order_id uuid) returns jsonb
language plpgsql as $$
declare
  v_items jsonb;
  v_quote jsonb;
begin
  if not exists (select 1 from orders where id = p_order_id) then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'product_id', product_id, 'custom_spec', custom_spec, 'qty', qty)))
  into v_items
  from order_items where order_id = p_order_id;

  v_quote := _quote_lines(v_items);

  if v_quote ? 'error' then
    update orders set status = 'needs_review', quote = v_quote where id = p_order_id;
  else
    update orders set status = 'quoted', quote = v_quote, quoted_at = now() where id = p_order_id;
  end if;
  return v_quote;
end $$;
