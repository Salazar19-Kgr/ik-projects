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
