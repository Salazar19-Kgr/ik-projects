
-- ===== supabase/migrations/0001_tipos_base.sql =====
-- =====================================================================
-- 0001 · Tipos base
-- Enumeraciones del dominio y funciones utilitarias.
-- =====================================================================

create type public.app_role as enum ('admin', 'cocina', 'mesero');

create type public.table_status as enum ('libre', 'ocupada', 'inactiva');

create type public.order_status as enum (
  'recibido', 'en_preparacion', 'listo', 'entregado', 'cancelado'
);

create type public.check_status as enum ('abierta', 'pagada', 'anulada');

create type public.payment_status as enum (
  'pendiente', 'en_revision', 'aprobado', 'rechazado', 'anulado'
);

create type public.evidence_status as enum ('pendiente', 'aprobado', 'rechazado');

create type public.currency_code as enum ('USD', 'VES');

create type public.payment_method_kind as enum (
  'efectivo_usd', 'efectivo_ves', 'transferencia_ves',
  'pago_movil', 'zelle', 'tarjeta', 'otro'
);

create type public.service_call_type as enum ('mesero', 'cuenta', 'ayuda');

create type public.service_call_status as enum ('pendiente', 'atendida', 'cancelada');

-- Mantiene updated_at al día en cada UPDATE.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ===== supabase/migrations/0002_esquema_principal.sql =====
-- =====================================================================
-- 0002 · Esquema principal
-- Precios base en USD; los bolívares se derivan con la tasa vigente y
-- cada pedido/pago guarda la tasa usada (snapshot) para auditoría.
-- =====================================================================

-- ---------- Personal y configuración ---------------------------------

create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  full_name   text not null check (char_length(full_name) between 2 and 120),
  role        public.app_role not null,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table public.restaurant_settings (
  id                  smallint primary key default 1 check (id = 1),
  name                text not null default 'Mi Restaurante' check (char_length(name) between 1 and 120),
  base_currency       public.currency_code not null default 'USD',
  iva_rate            numeric(5,4) not null default 0.16 check (iva_rate >= 0 and iva_rate < 1),
  prices_include_iva  boolean not null default false,
  igtf_rate           numeric(5,4) not null default 0.03 check (igtf_rate >= 0 and igtf_rate < 1),
  igtf_enabled        boolean not null default true,
  timezone            text not null default 'America/Caracas',
  updated_at          timestamptz not null default now()
);

-- Tasa de cambio USD -> VES. Solo se insertan filas nuevas (historial inmutable).
create table public.exchange_rates (
  id            bigint generated always as identity primary key,
  rate_ves      numeric(18,4) not null check (rate_ves > 0),
  source        text not null default 'BCV' check (char_length(source) between 1 and 40),
  effective_at  timestamptz not null default now(),
  created_by    uuid references auth.users (id) on delete set null,
  created_at    timestamptz not null default now()
);
create index exchange_rates_effective_idx on public.exchange_rates (effective_at desc);

-- ---------- Mesas ----------------------------------------------------

create table public.dining_tables (
  id          uuid primary key default gen_random_uuid(),
  number      smallint not null unique check (number between 1 and 999),
  label       text not null default '',
  -- Token del QR: 64 caracteres hex no predecibles (no se confía en el número).
  qr_token    text not null unique
              default (replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')),
  status      public.table_status not null default 'libre',
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ---------- Catálogo -------------------------------------------------

create table public.categories (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) between 1 and 80),
  sort_order  integer not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table public.products (
  id           uuid primary key default gen_random_uuid(),
  category_id  uuid not null references public.categories (id) on delete restrict,
  name         text not null check (char_length(name) between 1 and 120),
  description  text not null default '' check (char_length(description) <= 600),
  price_usd    numeric(12,2) not null check (price_usd >= 0),
  image_path   text,
  available    boolean not null default true,
  active       boolean not null default true,
  sort_order   integer not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index products_category_idx on public.products (category_id, sort_order);

-- ---------- Cuentas y pedidos ---------------------------------------

create table public.checks (
  id          uuid primary key default gen_random_uuid(),
  table_id    uuid not null references public.dining_tables (id) on delete restrict,
  status      public.check_status not null default 'abierta',
  opened_at   timestamptz not null default now(),
  closed_at   timestamptz,
  updated_at  timestamptz not null default now()
);
-- Una sola cuenta abierta por mesa (protege contra pedidos simultáneos).
create unique index checks_one_open_per_table
  on public.checks (table_id) where status = 'abierta';

create table public.orders (
  id              uuid primary key default gen_random_uuid(),
  order_number    bigint generated always as identity,
  check_id        uuid not null references public.checks (id) on delete restrict,
  table_id        uuid not null references public.dining_tables (id) on delete restrict,
  status          public.order_status not null default 'recibido',
  notes           text not null default '' check (char_length(notes) <= 300),
  subtotal_usd    numeric(14,2) not null check (subtotal_usd >= 0),
  tax_usd         numeric(14,2) not null check (tax_usd >= 0),
  total_usd       numeric(14,2) not null check (total_usd >= 0),
  rate_ves        numeric(18,4) not null check (rate_ves > 0),
  total_ves       numeric(16,2) not null check (total_ves >= 0),
  cancel_reason   text,
  cancelled_by    uuid references auth.users (id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint orders_cancel_consistency check (
    (status = 'cancelado' and cancel_reason is not null)
    or (status <> 'cancelado')
  )
);
create index orders_status_created_idx on public.orders (status, created_at);
create index orders_check_idx on public.orders (check_id);
create index orders_table_idx on public.orders (table_id, created_at desc);

create table public.order_items (
  id              uuid primary key default gen_random_uuid(),
  order_id        uuid not null references public.orders (id) on delete cascade,
  product_id      uuid references public.products (id) on delete set null,
  product_name    text not null,
  unit_price_usd  numeric(12,2) not null check (unit_price_usd >= 0),
  quantity        integer not null check (quantity between 1 and 50),
  notes           text not null default '' check (char_length(notes) <= 200),
  line_total_usd  numeric(14,2) generated always as (unit_price_usd * quantity) stored
);
create index order_items_order_idx on public.order_items (order_id);

create table public.order_status_history (
  id          bigint generated always as identity primary key,
  order_id    uuid not null references public.orders (id) on delete cascade,
  from_status public.order_status,
  to_status   public.order_status not null,
  changed_by  uuid references auth.users (id) on delete set null,
  note        text,
  created_at  timestamptz not null default now()
);
create index order_status_history_order_idx on public.order_status_history (order_id, created_at);

-- ---------- Servicio -------------------------------------------------

create table public.service_calls (
  id           uuid primary key default gen_random_uuid(),
  table_id     uuid not null references public.dining_tables (id) on delete restrict,
  type         public.service_call_type not null default 'mesero',
  status       public.service_call_status not null default 'pendiente',
  note         text not null default '' check (char_length(note) <= 200),
  attended_by  uuid references auth.users (id) on delete set null,
  attended_at  timestamptz,
  created_at   timestamptz not null default now()
);
create index service_calls_pending_idx on public.service_calls (status, created_at);
create unique index service_calls_one_pending_per_type
  on public.service_calls (table_id, type) where status = 'pendiente';

-- ---------- Pagos ----------------------------------------------------

create table public.payment_methods (
  id            uuid primary key default gen_random_uuid(),
  kind          public.payment_method_kind not null,
  label         text not null check (char_length(label) between 1 and 80),
  currency      public.currency_code not null,
  instructions  text not null default '' check (char_length(instructions) <= 1000),
  igtf_applies  boolean not null default false,
  active        boolean not null default true,
  sort_order    integer not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table public.payments (
  id           uuid primary key default gen_random_uuid(),
  check_id     uuid not null references public.checks (id) on delete restrict,
  method_id    uuid not null references public.payment_methods (id) on delete restrict,
  currency     public.currency_code not null,
  amount       numeric(16,2) not null check (amount > 0),
  rate_ves     numeric(18,4) not null check (rate_ves > 0),
  amount_usd   numeric(14,2) not null check (amount_usd > 0),
  igtf_usd     numeric(14,2) not null default 0 check (igtf_usd >= 0),
  status       public.payment_status not null default 'pendiente',
  reference    text check (char_length(reference) <= 80),
  review_note  text check (char_length(review_note) <= 300),
  reviewed_by  uuid references auth.users (id) on delete set null,
  reviewed_at  timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index payments_check_idx on public.payments (check_id);
create index payments_status_idx on public.payments (status, created_at);

create table public.payment_evidence (
  id            uuid primary key default gen_random_uuid(),
  payment_id    uuid not null references public.payments (id) on delete cascade,
  storage_path  text not null,
  mime_type     text not null check (mime_type in ('image/jpeg', 'image/png', 'image/webp', 'application/pdf')),
  size_bytes    integer not null check (size_bytes > 0 and size_bytes <= 5242880),
  status        public.evidence_status not null default 'pendiente',
  reviewed_by   uuid references auth.users (id) on delete set null,
  reviewed_at   timestamptz,
  review_note   text check (char_length(review_note) <= 300),
  created_at    timestamptz not null default now()
);
create index payment_evidence_payment_idx on public.payment_evidence (payment_id);

-- ---------- Auditoría -----------------------------------------------

create table public.audit_log (
  id          bigint generated always as identity primary key,
  actor_id    uuid,
  action      text not null,
  entity      text not null,
  entity_id   text,
  data        jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);
create index audit_log_entity_idx on public.audit_log (entity, created_at desc);

-- ---------- Triggers updated_at -------------------------------------

create trigger trg_profiles_updated         before update on public.profiles            for each row execute function public.set_updated_at();
create trigger trg_settings_updated         before update on public.restaurant_settings for each row execute function public.set_updated_at();
create trigger trg_dining_tables_updated    before update on public.dining_tables       for each row execute function public.set_updated_at();
create trigger trg_categories_updated       before update on public.categories          for each row execute function public.set_updated_at();
create trigger trg_products_updated         before update on public.products            for each row execute function public.set_updated_at();
create trigger trg_checks_updated           before update on public.checks              for each row execute function public.set_updated_at();
create trigger trg_orders_updated           before update on public.orders              for each row execute function public.set_updated_at();
create trigger trg_payment_methods_updated  before update on public.payment_methods     for each row execute function public.set_updated_at();
create trigger trg_payments_updated         before update on public.payments            for each row execute function public.set_updated_at();

-- ===== supabase/migrations/0003_funciones.sql =====
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

-- ===== supabase/migrations/0004_seguridad_rls.sql =====
-- =====================================================================
-- 0004 · Seguridad: privilegios mínimos + Row Level Security
-- Principio: se revoca todo y se concede solo lo estrictamente necesario.
--  · anon (cliente por QR): lee catálogo y métodos de pago; escribe SOLO
--    mediante funciones (create_order, create_service_call, ...).
--  · authenticated (personal): lee según rol; cambios críticos por funciones.
-- =====================================================================

-- ---------- 1. Revocar privilegios por defecto -----------------------

revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from public, anon, authenticated;

-- ---------- 2. Activar RLS en todas las tablas -----------------------

alter table public.profiles              enable row level security;
alter table public.restaurant_settings   enable row level security;
alter table public.exchange_rates        enable row level security;
alter table public.dining_tables         enable row level security;
alter table public.categories            enable row level security;
alter table public.products              enable row level security;
alter table public.checks                enable row level security;
alter table public.orders                enable row level security;
alter table public.order_items           enable row level security;
alter table public.order_status_history  enable row level security;
alter table public.service_calls         enable row level security;
alter table public.payment_methods       enable row level security;
alter table public.payments              enable row level security;
alter table public.payment_evidence      enable row level security;
alter table public.audit_log             enable row level security;

-- ---------- 3. Concesiones de tabla ---------------------------------

-- Cliente anónimo: solo catálogo y métodos de pago activos (filtrado por RLS).
grant select on public.categories, public.products, public.payment_methods to anon;

-- Personal autenticado: lectura (acotada por RLS)...
grant select on
  public.profiles, public.restaurant_settings, public.exchange_rates,
  public.dining_tables, public.categories, public.products,
  public.checks, public.orders, public.order_items, public.order_status_history,
  public.service_calls, public.payment_methods, public.payments,
  public.payment_evidence, public.audit_log
to authenticated;

-- ...y escritura solo donde administración gestiona datos maestros.
grant insert, update, delete on public.categories, public.products, public.payment_methods to authenticated;
grant insert, update         on public.dining_tables, public.profiles to authenticated;
grant update                 on public.restaurant_settings to authenticated;
grant insert                 on public.exchange_rates to authenticated;

-- ---------- 4. Concesiones de funciones -----------------------------

grant execute on function
  public.resolve_table(text),
  public.public_info(),
  public.create_order(text, jsonb, text),
  public.get_table_orders(text),
  public.get_table_check(text),
  public.create_service_call(text, public.service_call_type, text)
to anon, authenticated;

grant execute on function
  public.staff_role(),
  public.latest_rate(),
  public.advance_order_status(uuid, public.order_status, text),
  public.attend_service_call(uuid)
to authenticated;

-- ---------- 5. Políticas --------------------------------------------

-- Perfiles
create policy profiles_select_self  on public.profiles for select to authenticated
  using (id = (select auth.uid()));
create policy profiles_admin_select on public.profiles for select to authenticated
  using ((select public.staff_role()) = 'admin');
create policy profiles_admin_insert on public.profiles for insert to authenticated
  with check ((select public.staff_role()) = 'admin');
create policy profiles_admin_update on public.profiles for update to authenticated
  using ((select public.staff_role()) = 'admin')
  with check ((select public.staff_role()) = 'admin');

-- Configuración
create policy settings_staff_select on public.restaurant_settings for select to authenticated
  using ((select public.staff_role()) is not null);
create policy settings_admin_update on public.restaurant_settings for update to authenticated
  using ((select public.staff_role()) = 'admin')
  with check ((select public.staff_role()) = 'admin' and id = 1);

-- Tasas de cambio (historial inmutable: sin UPDATE ni DELETE)
create policy rates_staff_select on public.exchange_rates for select to authenticated
  using ((select public.staff_role()) is not null);
create policy rates_admin_insert on public.exchange_rates for insert to authenticated
  with check ((select public.staff_role()) = 'admin');

-- Mesas
create policy tables_staff_select on public.dining_tables for select to authenticated
  using ((select public.staff_role()) is not null);
create policy tables_admin_insert on public.dining_tables for insert to authenticated
  with check ((select public.staff_role()) = 'admin');
create policy tables_admin_update on public.dining_tables for update to authenticated
  using ((select public.staff_role()) = 'admin')
  with check ((select public.staff_role()) = 'admin');

-- Catálogo: público ve lo activo; administración gestiona todo.
create policy categories_public_select on public.categories for select to anon, authenticated
  using (active);
create policy categories_admin_all on public.categories for all to authenticated
  using ((select public.staff_role()) = 'admin')
  with check ((select public.staff_role()) = 'admin');

create policy products_public_select on public.products for select to anon, authenticated
  using (active);
create policy products_admin_all on public.products for all to authenticated
  using ((select public.staff_role()) = 'admin')
  with check ((select public.staff_role()) = 'admin');

create policy payment_methods_public_select on public.payment_methods for select to anon, authenticated
  using (active);
create policy payment_methods_admin_all on public.payment_methods for all to authenticated
  using ((select public.staff_role()) = 'admin')
  with check ((select public.staff_role()) = 'admin');

-- Operación: lectura para todo el personal; escritura solo vía funciones.
create policy checks_staff_select on public.checks for select to authenticated
  using ((select public.staff_role()) is not null);
create policy orders_staff_select on public.orders for select to authenticated
  using ((select public.staff_role()) is not null);
create policy order_items_staff_select on public.order_items for select to authenticated
  using ((select public.staff_role()) is not null);
create policy order_history_staff_select on public.order_status_history for select to authenticated
  using ((select public.staff_role()) is not null);
create policy service_calls_staff_select on public.service_calls for select to authenticated
  using ((select public.staff_role()) is not null);

-- Pagos: administración y meseros.
create policy payments_select on public.payments for select to authenticated
  using ((select public.staff_role()) in ('admin', 'mesero'));
create policy payment_evidence_select on public.payment_evidence for select to authenticated
  using ((select public.staff_role()) in ('admin', 'mesero'));

-- Auditoría: solo administración.
create policy audit_admin_select on public.audit_log for select to authenticated
  using ((select public.staff_role()) = 'admin');

-- ===== supabase/migrations/0005_almacenamiento.sql =====
-- =====================================================================
-- 0005 · Almacenamiento (Supabase Storage)
--  · menu-images      → público (fotos del catálogo), escritura solo admin.
--  · payment-evidence → PRIVADO, sin acceso directo desde el navegador del
--    cliente; la subida se hará con URLs firmadas desde el servidor (Fase 4).
-- Se omite sin error si el esquema "storage" no existe (p. ej. en CI).
-- =====================================================================

do $$
begin
  if to_regnamespace('storage') is null then
    raise notice 'Esquema storage no encontrado: se omite 0005.';
    return;
  end if;

  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values
    ('menu-images', 'menu-images', true, 2097152,
     array['image/jpeg', 'image/png', 'image/webp']),
    ('payment-evidence', 'payment-evidence', false, 5242880,
     array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
  on conflict (id) do update
    set public = excluded.public,
        file_size_limit = excluded.file_size_limit,
        allowed_mime_types = excluded.allowed_mime_types;

  drop policy if exists menu_images_public_read  on storage.objects;
  drop policy if exists menu_images_admin_write  on storage.objects;
  drop policy if exists evidence_staff_read      on storage.objects;

  create policy menu_images_public_read on storage.objects
    for select to anon, authenticated
    using (bucket_id = 'menu-images');

  create policy menu_images_admin_write on storage.objects
    for all to authenticated
    using (bucket_id = 'menu-images' and (select public.staff_role()) = 'admin')
    with check (bucket_id = 'menu-images' and (select public.staff_role()) = 'admin');

  create policy evidence_staff_read on storage.objects
    for select to authenticated
    using (bucket_id = 'payment-evidence' and (select public.staff_role()) in ('admin', 'mesero'));
end;
$$;

-- ===== supabase/migrations/0006_admin_unico.sql =====
-- 0006 · Acceso solo para correos autorizados
-- Un correo que no esté en allowed_emails no puede crear ni cambiar cuentas.
-- Al registrarse un correo autorizado, su perfil y rol se crean automáticamente.

create table public.allowed_emails (
  email      text primary key check (email = lower(btrim(email)) and email like '%@%'),
  role       public.app_role not null,
  full_name  text not null default 'Personal' check (char_length(full_name) between 2 and 120),
  created_at timestamptz not null default now()
);
alter table public.allowed_emails enable row level security;
revoke all on public.allowed_emails from anon, authenticated;

create or replace function public.enforce_allowed_email()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.email is null
     or not exists (select 1 from public.allowed_emails a where a.email = lower(btrim(new.email))) then
    raise exception 'email_no_autorizado';
  end if;
  return new;
end;
$$;

create or replace function public.provision_profile()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, full_name, role)
  select new.id, a.full_name, a.role
  from public.allowed_emails a
  where a.email = lower(btrim(new.email))
  on conflict (id) do update
    set role = excluded.role, full_name = excluded.full_name, active = true;
  return new;
end;
$$;

revoke all on function public.enforce_allowed_email(), public.provision_profile()
  from public, anon, authenticated;

create trigger trg_enforce_allowed_email
  before insert or update of email on auth.users
  for each row execute function public.enforce_allowed_email();

create trigger trg_provision_profile
  after insert on auth.users
  for each row execute function public.provision_profile();
