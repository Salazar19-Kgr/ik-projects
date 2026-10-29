-- =====================================================================
-- SOLO DESARROLLO / PRUEBAS. NO ejecutar en producción.
-- Tasa de ejemplo y un menú de muestra para probar el flujo completo.
-- =====================================================================

insert into public.exchange_rates (rate_ves, source) values (100.0000, 'DEMO');

with c as (
  insert into public.categories (name, sort_order)
  values ('Entradas', 1), ('Platos fuertes', 2), ('Bebidas', 3)
  returning id, name
)
insert into public.products (category_id, name, description, price_usd, sort_order)
select c.id, p.name, p.description, p.price, p.ord
from c
join (values
  ('Entradas',       'Tequeños (6 uds)', 'Con salsa de guasacaca.',        6.50, 1),
  ('Platos fuertes', 'Pabellón criollo', 'Carne mechada, caraotas, arroz y tajadas.', 12.00, 1),
  ('Bebidas',        'Papelón con limón','Jarra individual.',               2.50, 1)
) as p(cat, name, description, price, ord) on p.cat = c.name;
