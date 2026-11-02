-- Poprawki po recenzji kodu: walidacja wejścia, blokada ponownej wyceny w trakcie realizacji,
-- jedno otwarte zadanie na zamówienie i spójne zaokrąglenia kwot.

-- Ustawienia: wartości nieujemne, a brak klucza przerywa wycenę zamiast dawać NULL.
alter table settings add constraint settings_value_nonneg check (value >= 0);

create or replace function _setting(p_key text) returns numeric
language plpgsql stable as $$
declare
  v numeric;
begin
  select value into v from settings where key = p_key;
  if v is null then
    raise exception 'MISSING_SETTING:%', p_key;
  end if;
  return v;
end $$;

-- Jedno otwarte zadanie na zamówienie, także przy bezpośrednim INSERT.
create unique index tasks_one_open_per_order on tasks (order_id) where status <> 'done';

create function _try_uuid(p_text text) returns uuid
language plpgsql immutable as $$
begin
  return p_text::uuid;
exception when invalid_text_representation then
  return null;
end $$;

-- Wymiar mebla na wymiar: liczba z zakresu 20–300 cm. Brakujący klucz (SQL NULL) to fałsz.
create function _valid_dim(p jsonb) returns boolean
language sql immutable as $$
  select coalesce(jsonb_typeof(p) = 'number' and (p #>> '{}')::numeric between 20 and 300, false)
$$;

-- Wycena listy pozycji [{product_id | custom_spec, qty}] bez zapisu.
-- Zwraca {lines, materials_cost, labor_cost, margin, total} albo {error, ...}.
-- Kwoty są zaokrąglane per pozycja, a nagłówek to suma zaokrąglonych pozycji,
-- więc rozbicie zawsze sumuje się do total co do grosza.
create or replace function _quote_lines(p_items jsonb) returns jsonb
language plpgsql stable as $$
declare
  v_rate       numeric := _setting('labor_rate');
  v_margin_pct numeric := _setting('margin');
  v_item       jsonb;
  v_qty_j      jsonb;
  v_qty        int;
  v_spec       jsonb;
  v_product    uuid;
  v_material   uuid;
  v_label      text;
  v_hours      numeric;
  v_area       numeric;
  v_price      numeric;
  v_mat        numeric;
  v_lab        numeric;
  v_bom        record;
  v_bom_rows   int;
  v_lines      jsonb := '[]';
  v_mat_total  numeric := 0;
  v_lab_total  numeric := 0;
  v_margin     numeric;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    return jsonb_build_object('error', 'NO_ITEMS');
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    if jsonb_typeof(v_item) <> 'object' then
      return jsonb_build_object('error', 'INVALID_ITEM');
    end if;

    -- ilość: brak klucza = 1, w przeciwnym razie dodatnia liczba całkowita
    v_qty_j := v_item->'qty';
    if v_qty_j is null then
      v_qty := 1;
    elsif jsonb_typeof(v_qty_j) = 'number'
          and (v_qty_j #>> '{}')::numeric = trunc((v_qty_j #>> '{}')::numeric)
          and (v_qty_j #>> '{}')::numeric between 1 and 1000 then
      v_qty := (v_qty_j #>> '{}')::int;
    else
      return jsonb_build_object('error', 'INVALID_QTY');
    end if;

    v_spec := nullif(v_item->'custom_spec', 'null'::jsonb);
    v_product := _try_uuid(v_item->>'product_id');
    if (v_item->>'product_id' is not null and v_product is null)
       or ((v_product is null) = (v_spec is null)) then
      return jsonb_build_object('error', 'INVALID_ITEM');
    end if;

    v_mat := 0;
    if v_product is not null then
      select name, labor_hours into v_label, v_hours from products where id = v_product;
      if not found then
        return jsonb_build_object('error', 'UNKNOWN_PRODUCT', 'product_id', v_product);
      end if;

      select count(*) into v_bom_rows from product_materials where product_id = v_product;
      if v_bom_rows = 0 or v_hours <= 0 then
        return jsonb_build_object('error', 'INCOMPLETE_PRODUCT', 'product_id', v_product);
      end if;

      v_lab := v_hours * v_rate;
      for v_bom in
        select pm.material_id, pm.qty, m.name
        from product_materials pm join materials m on m.id = pm.material_id
        where pm.product_id = v_product
      loop
        v_price := _material_price(v_bom.material_id);
        if v_price is null then
          return jsonb_build_object('error', 'NO_PRICE',
            'material_id', v_bom.material_id, 'material_name', v_bom.name);
        end if;
        v_mat := v_mat + v_bom.qty * v_price;
      end loop;
    else
      if jsonb_typeof(v_spec) <> 'object'
         or not _valid_dim(v_spec->'width_cm')
         or not _valid_dim(v_spec->'height_cm')
         or not _valid_dim(v_spec->'depth_cm') then
        return jsonb_build_object('error', 'INVALID_SPEC');
      end if;

      v_material := _try_uuid(v_spec->>'material_id');
      select name into v_label from materials where id = v_material;
      if not found then
        return jsonb_build_object('error', 'UNKNOWN_MATERIAL', 'material_id', v_spec->>'material_id');
      end if;
      v_price := _material_price(v_material);
      if v_price is null then
        return jsonb_build_object('error', 'NO_PRICE',
          'material_id', v_material, 'material_name', v_label);
      end if;

      v_area  := _custom_area(v_spec);
      v_mat   := v_area * v_price;
      v_lab   := (4 + 2 * v_area) * v_rate;
      v_label := format('Na wymiar %s×%s×%s cm, %s',
        v_spec->>'width_cm', v_spec->>'height_cm', v_spec->>'depth_cm', v_label);
    end if;

    v_mat := round(v_mat * v_qty, 2);
    v_lab := round(v_lab * v_qty, 2);
    v_mat_total := v_mat_total + v_mat;
    v_lab_total := v_lab_total + v_lab;
    v_lines := v_lines || jsonb_build_object(
      'label', v_label, 'qty', v_qty, 'materials_cost', v_mat, 'labor_cost', v_lab);
  end loop;

  v_margin := round((v_mat_total + v_lab_total) * v_margin_pct, 2);
  return jsonb_build_object(
    'lines', v_lines,
    'materials_cost', v_mat_total,
    'labor_cost', v_lab_total,
    'margin', v_margin,
    'total', v_mat_total + v_lab_total + v_margin);
end $$;

-- Przy przyjęciu zamówienia status może być tylko początkowy; 'quoted' i dalsze ustawia system.
-- JSON null w custom_spec jest traktowany jak brak pola.
create or replace function upsert_order(p jsonb) returns uuid
language plpgsql as $$
declare
  v_id     uuid;
  v_status text := coalesce(p->>'status', 'new');
begin
  if coalesce(p->>'external_id', '') = '' then
    raise exception 'MISSING_EXTERNAL_ID';
  end if;
  if v_status not in ('new', 'needs_info', 'needs_review') then
    raise exception 'INVALID_STATUS:%', v_status;
  end if;

  insert into orders (external_id, source, customer_email, kind, status, raw_text, parsed)
  values (p->>'external_id', p->>'source', p->>'customer_email', p->>'kind',
          v_status, p->>'raw_text', p->'parsed')
  on conflict (external_id) do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from orders where external_id = p->>'external_id';
    return v_id;
  end if;

  insert into order_items (order_id, product_id, custom_spec, qty)
  select v_id, (e->>'product_id')::uuid, nullif(e->'custom_spec', 'null'::jsonb), coalesce((e->>'qty')::int, 1)
  from jsonb_array_elements(coalesce(p->'items', '[]')) e;

  return v_id;
end $$;

-- Wycenia zamówienie. Po przejściu do realizacji (approved i dalej) wyceny nie wolno zmienić.
create or replace function estimate_quote(p_order_id uuid) returns jsonb
language plpgsql as $$
declare
  v_status text;
  v_items  jsonb;
  v_quote  jsonb;
begin
  select status into v_status from orders where id = p_order_id for update;
  if not found then
    raise exception 'ORDER_NOT_FOUND';
  end if;
  if v_status not in ('new', 'needs_info', 'needs_review', 'quoted') then
    raise exception 'ORDER_LOCKED:%', v_status;
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

-- Zapotrzebowanie jest liczone raz, a ta sama lista służy do blokad, kontroli i rezerwacji.
-- Zamówienie bez poprawnej wyceny albo bez zapotrzebowania nie przejdzie do realizacji.
create or replace function create_task(p_order_id uuid, p_assignee text) returns uuid
language plpgsql as $$
declare
  v_status text;
  v_quote  jsonb;
  v_req    jsonb;
  v_task   uuid;
  r        record;
begin
  if coalesce(trim(p_assignee), '') = '' then
    raise exception 'MISSING_ASSIGNEE';
  end if;

  select status, quote into v_status, v_quote from orders where id = p_order_id for update;
  if not found then
    raise exception 'ORDER_NOT_FOUND';
  end if;
  if v_status not in ('quoted', 'approved') then
    raise exception 'ORDER_NOT_READY:%', v_status;
  end if;
  if v_quote is null or v_quote ? 'error' then
    raise exception 'ORDER_NOT_QUOTED';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('material_id', material_id, 'qty', qty)
                            order by material_id), '[]')
  into v_req
  from _task_requirements(p_order_id);
  if jsonb_array_length(v_req) = 0 then
    raise exception 'EMPTY_ORDER';
  end if;

  perform 1 from materials
  where id in (select (e->>'material_id')::uuid from jsonb_array_elements(v_req) e)
  order by id
  for update;

  for r in
    select x.material_id, x.qty, m.name, m.stock - m.reserved as available
    from jsonb_to_recordset(v_req) as x(material_id uuid, qty numeric)
    join materials m on m.id = x.material_id
    order by m.name
  loop
    if r.available < r.qty then
      raise exception 'INSUFFICIENT_STOCK:%', r.name;
    end if;
  end loop;

  insert into tasks (order_id, assignee) values (p_order_id, p_assignee) returning id into v_task;

  for r in select * from jsonb_to_recordset(v_req) as x(material_id uuid, qty numeric) loop
    update materials set reserved = reserved + r.qty where id = r.material_id;
    insert into stock_movements (material_id, task_id, qty, kind)
    values (r.material_id, v_task, r.qty, 'reserve');
  end loop;

  update orders set status = 'in_progress' where id = p_order_id;
  return v_task;
end $$;
