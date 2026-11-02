-- Magazyn: najlepsza cena, rezerwacje materiałów przy zleceniu zadania, widok low_stock.

-- Najtańsza aktualna cena materiału: cena > 0 i nie starsza niż 30 dni.
create function best_price(p_material_id uuid)
returns table (supplier_id uuid, supplier_name text, price numeric)
language sql stable as $$
  select s.id, s.name, sp.price
  from supplier_prices sp
  join suppliers s on s.id = sp.supplier_id
  where sp.material_id = p_material_id
    and sp.price > 0
    and sp.updated_at >= now() - interval '30 days'
  order by sp.price, s.name
  limit 1
$$;

-- Od teraz wycena liczy tylko z cen aktualnych (w Task 1 brała najniższą w ogóle).
create or replace function _material_price(p_material_id uuid) returns numeric
language sql stable as $$
  select price from best_price(p_material_id)
$$;

-- Zapotrzebowanie zamówienia na materiały: BOM produktów plus płyta dla mebli na wymiar.
-- Ilości zaokrąglone w górę do 0,001, tak jak kolumny stanu magazynowego.
create function _task_requirements(p_order_id uuid)
returns table (material_id uuid, qty numeric)
language sql stable as $$
  select t.material_id, ceil(sum(t.qty) * 1000) / 1000
  from (
    select pm.material_id, pm.qty * oi.qty as qty
    from order_items oi
    join product_materials pm on pm.product_id = oi.product_id
    where oi.order_id = p_order_id
    union all
    select (oi.custom_spec->>'material_id')::uuid, _custom_area(oi.custom_spec) * oi.qty
    from order_items oi
    where oi.order_id = p_order_id and oi.custom_spec is not null
  ) t
  group by t.material_id
$$;

-- Tworzy zadanie dla zespołu i rezerwuje materiały. Wszystko w jednej transakcji;
-- wiersze materiałów są blokowane w stałej kolejności (po id), więc równoległe zlecenia
-- czekają na siebie zamiast się mijać i nie powodują zakleszczeń.
create function create_task(p_order_id uuid, p_assignee text) returns uuid
language plpgsql as $$
declare
  v_status text;
  v_task   uuid;
  r        record;
begin
  if coalesce(trim(p_assignee), '') = '' then
    raise exception 'MISSING_ASSIGNEE';
  end if;

  select status into v_status from orders where id = p_order_id for update;
  if not found then
    raise exception 'ORDER_NOT_FOUND';
  end if;
  if v_status not in ('quoted', 'approved') then
    raise exception 'ORDER_NOT_READY:%', v_status;
  end if;

  perform 1 from materials
  where id in (select material_id from _task_requirements(p_order_id))
  order by id
  for update;

  for r in
    select rq.material_id, rq.qty, m.name, m.stock - m.reserved as available
    from _task_requirements(p_order_id) rq
    join materials m on m.id = rq.material_id
    order by m.name
  loop
    if r.available < r.qty then
      raise exception 'INSUFFICIENT_STOCK:%', r.name;
    end if;
  end loop;

  insert into tasks (order_id, assignee) values (p_order_id, p_assignee) returning id into v_task;

  for r in select * from _task_requirements(p_order_id) loop
    update materials set reserved = reserved + r.qty where id = r.material_id;
    insert into stock_movements (material_id, task_id, qty, kind)
    values (r.material_id, v_task, r.qty, 'reserve');
  end loop;

  update orders set status = 'in_progress' where id = p_order_id;
  return v_task;
end $$;

-- Kończy zadanie: rezerwacja staje się zużyciem materiału.
create function complete_task(p_task_id uuid) returns void
language plpgsql as $$
declare
  v_status text;
  v_order  uuid;
  r        record;
begin
  select status, order_id into v_status, v_order from tasks where id = p_task_id for update;
  if not found then
    raise exception 'TASK_NOT_FOUND';
  end if;
  if v_status = 'done' then
    raise exception 'TASK_ALREADY_DONE';
  end if;

  for r in
    select material_id, sum(qty) as qty
    from stock_movements
    where task_id = p_task_id and kind = 'reserve'
    group by material_id
    order by material_id
  loop
    update materials
    set stock = stock - r.qty, reserved = reserved - r.qty
    where id = r.material_id;
    insert into stock_movements (material_id, task_id, qty, kind)
    values (r.material_id, p_task_id, r.qty, 'consume');
  end loop;

  update tasks set status = 'done' where id = p_task_id;
  update orders set status = 'done' where id = v_order;
end $$;

-- Materiały poniżej minimum (liczonego od stanu dostępnego) z najlepszą aktualną ceną.
-- Materiał bez aktualnej ceny też jest na liście, tylko bez dostawcy.
create view low_stock with (security_invoker = on) as
select m.id as material_id,
       m.name,
       m.stock - m.reserved as available,
       m.min_stock,
       bp.supplier_name as best_supplier,
       bp.price as best_price
from materials m
left join lateral best_price(m.id) bp on true
where m.stock - m.reserved < m.min_stock;

revoke all on low_stock from public, anon, authenticated;
grant select on low_stock to service_role;
