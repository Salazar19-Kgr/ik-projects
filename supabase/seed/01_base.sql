-- =====================================================================
-- Semilla base (PRODUCCIÓN y desarrollo). Idempotente.
-- Crea la configuración, las 10 mesas y los métodos de pago iniciales.
-- La tasa de cambio NO se siembra: la registra administración (el sistema
-- rechaza pedidos si no existe una tasa, para evitar totales en Bs erróneos).
-- =====================================================================

insert into public.restaurant_settings (id, name)
values (1, 'Mi Restaurante')
on conflict (id) do nothing;

insert into public.dining_tables (number, label)
select n, 'Mesa ' || n
from generate_series(1, 10) as n
on conflict (number) do nothing;

insert into public.payment_methods (kind, label, currency, instructions, igtf_applies, sort_order)
select * from (values
  ('efectivo_usd'::public.payment_method_kind,       'Efectivo (USD)',       'USD'::public.currency_code, 'Paga en caja o al mesero.', false, 10),
  ('efectivo_ves'::public.payment_method_kind,       'Efectivo (Bs.)',       'VES'::public.currency_code, 'Paga en caja o al mesero.', false, 20),
  ('pago_movil'::public.payment_method_kind,         'Pago móvil (Bs.)',     'VES'::public.currency_code, 'Datos de pago móvil: configurar en el panel.', false, 30),
  ('transferencia_ves'::public.payment_method_kind,  'Transferencia (Bs.)',  'VES'::public.currency_code, 'Datos bancarios: configurar en el panel.', false, 40),
  ('zelle'::public.payment_method_kind,              'Zelle (USD)',          'USD'::public.currency_code, 'Correo Zelle: configurar en el panel.', false, 50)
) as v(kind, label, currency, instructions, igtf_applies, sort_order)
where not exists (select 1 from public.payment_methods);
