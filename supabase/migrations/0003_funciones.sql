-- =====================================================================
-- 0003 · Funciones de negocio
-- Los clientes (QR) NUNCA escriben en las tablas: todo pasa por funciones
-- SECURITY DEFINER que validan mesa, precios, cantidades y estados.
-- =====================================================================

-- ---------- Utilidades internas -------------------------------------

create or replace function public.staff_role()
returns public.app_role
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p.role from public.profiles p where p.id = auth.uid() and p.active
$$;

create or replace function public.latest_rate()
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select e.rate_ves from public.exchange_rates e
  order by e.effective_at desc, e.id desc
  limit 1
$$;

create or replace function public.set_created_by()
returns trigger
language plpgsql
as $$
begin
  new.created_by := auth.uid();
  return new;
end;
$$;

create trigger trg_exchange_rates_created_by
  before insert on public.exchange_rates
  for each row execute function public.set_created_by();

-- Auditoría genérica de cambios sensibles.
create or replace function public.audit_row()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.audit_log (actor_id, action, entity, entity_id, data)
  values (
    auth.uid(),
    tg_op,
    tg_table_name,
    coalesce(to_jsonb(new) ->> 'id', to_jsonb(old) ->> 'id'),
    jsonb_build_object(
      'old', case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
      'new', case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end
    )
  );
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger trg_audit_products         after insert or update or delete on public.products            for each row execute function public.audit_row();
create trigger trg_audit_categories       after insert or update or delete on public.categories          for each row execute function public.audit_row();
create trigger trg_audit_payment_methods  after insert or update or delete on public.payment_methods     for each row execute function public.audit_row();
create trigger trg_audit_settings         after insert or update or delete on public.restaurant_settings for each row execute function public.audit_row();
create trigger trg_audit_exchange_rates   after insert on public.exchange_rates                          for each row execute function public.audit_row();
create trigger trg_audit_profiles         after insert or update or delete on public.profiles            for each row execute function public.audit_row();
create trigger trg_audit_dining_tables    after insert or update or delete on public.dining_tables       for each row execute function public.audit_row();

-- ---------- API pública (cliente por QR) -----------------------------

-- Valida el QR y devuelve los datos mínimos de la mesa.
create or replace function public.resolve_table(p_token text)
returns table (id uuid, number smallint, label text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select t.id, t.number, t.label
  from public.dining_tables t
  where t.qr_token = p_token and t.active
$$;

-- Datos públicos del restaurante y tasa vigente para mostrar precios en Bs.
create or replace function public.public_info()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'name', s.name,
    'base_currency', s.base_currency,
    'iva_rate', s.iva_rate,
    'prices_include_iva', s.prices_include_iva,
    'rate_ves', public.latest_rate(),
    'rate_at', (select e.effective_at from public.exchange_rates e order by e.effective_at desc, e.id desc limit 1)
  )
  from public.restaurant_settings s
  where s.id = 1
$$;

-- Crea un pedido. Los precios y totales se calculan SIEMPRE en el servidor.
-- p_items: [{"product_id": "<uuid>", "quantity": 2, "notes": "sin cebolla"}, ...]
create or replace function public.create_order(
  p_token text,
  p_items jsonb,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_table     public.dining_tables%rowtype;
  v_settings  public.restaurant_settings%rowtype;
  v_rate      numeric(18,4);
  v_count     integer;
  v_valid     integer;
  v_subtotal  numeric(14,2);
  v_tax       numeric(14,2);
  v_total     numeric(14,2);
  v_check_id  uuid;
  v_order_id  uuid;
  v_notes     text := coalesce(btrim(p_notes), '');
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'items_invalid';
  end if;

  v_count := jsonb_array_length(p_items);
  if v_count < 1 or v_count > 40 then
    raise exception 'items_count_invalid';
  end if;

  if char_length(v_notes) > 300 then
    raise exception 'notes_too_long';
  end if;

  select * into v_table
  from public.dining_tables
  where qr_token = p_token and active;
  if not found then
    raise exception 'table_not_found';
  end if;

  select * into v_settings from public.restaurant_settings where id = 1;
  if not found then
    raise exception 'settings_missing';
  end if;

  v_rate := public.latest_rate();
  if v_rate is null then
    raise exception 'no_exchange_rate';
  end if;

  -- Freno simple contra abuso: máx. 5 pedidos por mesa por minuto.
  if (select count(*) from public.orders o
      where o.table_id = v_table.id and o.created_at > now() - interval '1 minute') >= 5 then
    raise exception 'rate_limited';
  end if;

  -- Cada línea debe existir, estar activa y disponible, con cantidad válida.
  select count(*), coalesce(sum(p.price_usd * x.quantity), 0)
    into v_valid, v_subtotal
  from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer, notes text)
  join public.products p
    on p.id = x.product_id and p.active and p.available
  where x.quantity between 1 and 50
    and char_length(coalesce(x.notes, '')) <= 200;

  if v_valid <> v_count then
    raise exception 'items_invalid';
  end if;

  if v_settings.prices_include_iva then
    v_tax   := round(v_subtotal - v_subtotal / (1 + v_settings.iva_rate), 2);
    v_total := v_subtotal;
  else
    v_tax   := round(v_subtotal * v_settings.iva_rate, 2);
    v_total := v_subtotal + v_tax;
  end if;

  -- Cuenta abierta de la mesa (única por el índice parcial).
  insert into public.checks (table_id) values (v_table.id)
  on conflict (table_id) where status = 'abierta' do nothing;

  select c.id into v_check_id
  from public.checks c
  where c.table_id = v_table.id and c.status = 'abierta';

  insert into public.orders (
    check_id, table_id, notes, subtotal_usd, tax_usd, total_usd, rate_ves, total_ves
  ) values (
    v_check_id, v_table.id, v_notes, v_subtotal, v_tax, v_total, v_rate, round(v_total * v_rate, 2)
  )
  returning id into v_order_id;

  insert into public.order_items (order_id, product_id, product_name, unit_price_usd, quantity, notes)
  select v_order_id, p.id, p.name, p.price_usd, x.quantity, btrim(coalesce(x.notes, ''))
  from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer, notes text)
  join public.products p on p.id = x.product_id;

  insert into public.order_status_history (order_id, from_status, to_status)
  values (v_order_id, null, 'recibido');

  update public.dining_tables set status = 'ocupada'
  where id = v_table.id and status = 'libre';

  return v_order_id;
end;
$$;

-- Pedidos de la cuenta abierta de la mesa (seguimiento del cliente).
create or replace function public.get_table_orders(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_table_id uuid;
  v_check_id uuid;
begin
  select t.id into v_table_id
  from public.dining_tables t where t.qr_token = p_token and t.active;
  if not found then
    raise exception 'table_not_found';
  end if;

  select c.id into v_check_id
  from public.checks c where c.table_id = v_table_id and c.status = 'abierta';
  if v_check_id is null then
    return '[]'::jsonb;
  end if;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', o.id,
        'number', o.order_number,
        'status', o.status,
        'notes', o.notes,
        'total_usd', o.total_usd,
        'total_ves', o.total_ves,
        'created_at', o.created_at,
        'items', (
          select coalesce(jsonb_agg(
            jsonb_build_object(
              'name', i.product_name,
              'quantity', i.quantity,
              'unit_price_usd', i.unit_price_usd,
              'notes', i.notes
            ) order by i.product_name
          ), '[]'::jsonb)
          from public.order_items i where i.order_id = o.id
        )
      ) order by o.created_at desc
    )
    from public.orders o
    where o.check_id = v_check_id
  ), '[]'::jsonb);
end;
$$;

-- Resumen de la cuenta de la mesa (excluye pedidos cancelados).
create or replace function public.get_table_check(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_table_id uuid;
  v_check_id uuid;
  v_subtotal numeric(14,2);
  v_tax      numeric(14,2);
  v_total    numeric(14,2);
  v_total_ves numeric(16,2);
  v_paid     numeric(14,2);
begin
  select t.id into v_table_id
  from public.dining_tables t where t.qr_token = p_token and t.active;
  if not found then
    raise exception 'table_not_found';
  end if;

  select c.id into v_check_id
  from public.checks c where c.table_id = v_table_id and c.status = 'abierta';
  if v_check_id is null then
    return jsonb_build_object('check_id', null, 'subtotal_usd', 0, 'tax_usd', 0,
                              'total_usd', 0, 'total_ves', 0, 'paid_usd', 0, 'balance_usd', 0);
  end if;

  select coalesce(sum(o.subtotal_usd), 0), coalesce(sum(o.tax_usd), 0),
         coalesce(sum(o.total_usd), 0), coalesce(sum(o.total_ves), 0)
    into v_subtotal, v_tax, v_total, v_total_ves
  from public.orders o
  where o.check_id = v_check_id and o.status <> 'cancelado';

  select coalesce(sum(p.amount_usd), 0) into v_paid
  from public.payments p
  where p.check_id = v_check_id and p.status = 'aprobado';

  return jsonb_build_object(
    'check_id', v_check_id,
    'subtotal_usd', v_subtotal,
    'tax_usd', v_tax,
    'total_usd', v_total,
    'total_ves', v_total_ves,
    'paid_usd', v_paid,
    'balance_usd', greatest(v_total - v_paid, 0)
  );
end;
$$;

-- Llamada al mesero. Idempotente: si ya hay una pendiente del mismo tipo, la reutiliza.
create or replace function public.create_service_call(
  p_token text,
  p_type public.service_call_type default 'mesero',
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_table_id uuid;
  v_id uuid;
  v_note text := coalesce(btrim(p_note), '');
begin
  if char_length(v_note) > 200 then
    raise exception 'note_too_long';
  end if;

  select t.id into v_table_id
  from public.dining_tables t where t.qr_token = p_token and t.active;
  if not found then
    raise exception 'table_not_found';
  end if;

  insert into public.service_calls (table_id, type, note)
  values (v_table_id, p_type, v_note)
  on conflict (table_id, type) where status = 'pendiente' do nothing
  returning id into v_id;

  if v_id is null then
    select s.id into v_id
    from public.service_calls s
    where s.table_id = v_table_id and s.type = p_type and s.status = 'pendiente';
  end if;

  return v_id;
end;
$$;

-- ---------- API del personal ----------------------------------------

-- Cambia el estado de un pedido validando rol y transición permitida.
create or replace function public.advance_order_status(
  p_order_id uuid,
  p_new_status public.order_status,
  p_reason text default null
)
returns public.order_status
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_role   public.app_role := public.staff_role();
  v_order  public.orders%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if v_role is null then
    raise exception 'forbidden';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'order_not_found';
  end if;

  if not (
    (v_order.status = 'recibido'       and p_new_status in ('en_preparacion', 'cancelado')) or
    (v_order.status = 'en_preparacion' and p_new_status in ('listo', 'cancelado')) or
    (v_order.status = 'listo'          and p_new_status in ('entregado', 'cancelado'))
  ) then
    raise exception 'invalid_transition';
  end if;

  if p_new_status = 'cancelado' then
    if v_role <> 'admin' then
      raise exception 'forbidden';
    end if;
    if v_reason is null or char_length(v_reason) < 3 then
      raise exception 'reason_required';
    end if;
  elsif p_new_status in ('en_preparacion', 'listo') then
    if v_role not in ('admin', 'cocina') then
      raise exception 'forbidden';
    end if;
  elsif p_new_status = 'entregado' then
    if v_role not in ('admin', 'mesero') then
      raise exception 'forbidden';
    end if;
  end if;

  update public.orders
     set status        = p_new_status,
         cancel_reason = case when p_new_status = 'cancelado' then v_reason else cancel_reason end,
         cancelled_by  = case when p_new_status = 'cancelado' then auth.uid() else cancelled_by end
   where id = p_order_id;

  insert into public.order_status_history (order_id, from_status, to_status, changed_by, note)
  values (p_order_id, v_order.status, p_new_status, auth.uid(), v_reason);

  if p_new_status = 'cancelado' then
    insert into public.audit_log (actor_id, action, entity, entity_id, data)
    values (auth.uid(), 'CANCEL', 'orders', p_order_id::text,
            jsonb_build_object('reason', v_reason, 'from', v_order.status));
  end if;

  return p_new_status;
end;
$$;

create or replace function public.attend_service_call(p_call_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if public.staff_role() is null then
    raise exception 'forbidden';
  end if;

  update public.service_calls
     set status = 'atendida', attended_by = auth.uid(), attended_at = now()
   where id = p_call_id and status = 'pendiente';

  if not found then
    raise exception 'call_not_pending';
  end if;
end;
$$;

-- ---------- Realtime -------------------------------------------------

do $$
declare
  t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['orders', 'order_items', 'service_calls', 'payments'] loop
      if not exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
      ) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end;
$$;
