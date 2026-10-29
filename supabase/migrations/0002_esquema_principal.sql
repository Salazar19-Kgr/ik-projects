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
