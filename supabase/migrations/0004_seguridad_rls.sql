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
