-- Pruebas de humo de reglas críticas. Se ejecutan en una transacción y se
-- revierten (ROLLBACK). Cualquier fallo lanza una excepción.
begin;

-- Datos base
\ir ../seed/01_base.sql
\ir ../seed/02_demo_dev.sql

do $$
declare
  v_token  text;
  v_prod   uuid;
  v_order  uuid;
  v_total  numeric;
  v_admin  uuid := gen_random_uuid();
  v_cocina uuid := gen_random_uuid();
  v_ok     boolean;
begin
  select qr_token into v_token from public.dining_tables where number = 1;
  select id into v_prod from public.products where name = 'Pabellón criollo';

  -- 1) Pedido válido: el total sale del servidor (12.00 + 16% IVA = 13.92)
  v_order := public.create_order(v_token, jsonb_build_array(jsonb_build_object('product_id', v_prod, 'quantity', 1)), 'sin picante');
  select total_usd into v_total from public.orders where id = v_order;
  assert v_total = 13.92, 'total_usd incorrecto: ' || v_total;
  assert (select total_ves from public.orders where id = v_order) = 1392.00, 'total_ves incorrecto';

  -- 2) Token falso rechazado
  begin
    perform public.create_order('token-falso', jsonb_build_array(jsonb_build_object('product_id', v_prod, 'quantity', 1)));
    raise exception 'DEBIO_FALLAR';
  exception when others then
    assert sqlerrm = 'table_not_found', 'token falso: ' || sqlerrm;
  end;

  -- 3) Cantidad inválida rechazada
  begin
    perform public.create_order(v_token, jsonb_build_array(jsonb_build_object('product_id', v_prod, 'quantity', 0)));
    raise exception 'DEBIO_FALLAR';
  exception when others then
    assert sqlerrm = 'items_invalid', 'cantidad 0: ' || sqlerrm;
  end;

  -- 4) Producto inexistente rechazado
  begin
    perform public.create_order(v_token, jsonb_build_array(jsonb_build_object('product_id', gen_random_uuid(), 'quantity', 1)));
    raise exception 'DEBIO_FALLAR';
  exception when others then
    assert sqlerrm = 'items_invalid', 'producto falso: ' || sqlerrm;
  end;

  -- 5) Una sola cuenta abierta por mesa
  perform public.create_order(v_token, jsonb_build_array(jsonb_build_object('product_id', v_prod, 'quantity', 2)));
  assert (select count(*) from public.checks where status = 'abierta') = 1, 'mas de una cuenta abierta';

  -- 6) Llamada al mesero idempotente
  assert public.create_service_call(v_token, 'mesero') = public.create_service_call(v_token, 'mesero'), 'llamada duplicada';

  -- 7) Cambios de estado según rol
  insert into auth.users (id) values (v_admin), (v_cocina);
  insert into public.profiles (id, full_name, role) values (v_admin, 'Admin Prueba', 'admin'), (v_cocina, 'Cocina Prueba', 'cocina');

  perform set_config('request.jwt.claim.sub', v_cocina::text, true);
  perform public.advance_order_status(v_order, 'en_preparacion');
  perform public.advance_order_status(v_order, 'listo');

  begin
    perform public.advance_order_status(v_order, 'entregado');   -- cocina no entrega
    raise exception 'DEBIO_FALLAR';
  exception when others then
    assert sqlerrm = 'forbidden', 'cocina entregando: ' || sqlerrm;
  end;

  begin
    perform public.advance_order_status(v_order, 'cancelado', 'x');  -- cocina no cancela
    raise exception 'DEBIO_FALLAR';
  exception when others then
    assert sqlerrm = 'forbidden', 'cocina cancelando: ' || sqlerrm;
  end;

  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  begin
    perform public.advance_order_status(v_order, 'recibido');    -- no se retrocede
    raise exception 'DEBIO_FALLAR';
  exception when others then
    assert sqlerrm = 'invalid_transition', 'retroceso: ' || sqlerrm;
  end;
  perform public.advance_order_status(v_order, 'cancelado', 'Cliente se retiró');
  assert (select status from public.orders where id = v_order) = 'cancelado', 'no se cancelo';
  assert (select count(*) from public.order_status_history where order_id = v_order) = 4, 'historial incompleto';

  -- 8) Sin tasa de cambio no se aceptan pedidos
  delete from public.exchange_rates;
  begin
    perform public.create_order(v_token, jsonb_build_array(jsonb_build_object('product_id', v_prod, 'quantity', 1)));
    raise exception 'DEBIO_FALLAR';
  exception when others then
    assert sqlerrm = 'no_exchange_rate', 'sin tasa: ' || sqlerrm;
  end;

  raise notice 'OK: pruebas de humo superadas';
end;
$$;

-- 9) RLS: un cliente anónimo no puede leer pedidos ni escribir directo
set local role anon;
do $$
begin
  begin
    perform 1 from public.orders limit 1;
    raise exception 'DEBIO_FALLAR';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.products (category_id, name, price_usd)
    select id, 'hack', 0 from public.categories limit 1;
    raise exception 'DEBIO_FALLAR';
  exception when insufficient_privilege then null;
  end;
  assert (select count(*) from public.products) > 0, 'anon no ve el catalogo';
  raise notice 'OK: aislamiento anon verificado';
end;
$$;
reset role;

rollback;
