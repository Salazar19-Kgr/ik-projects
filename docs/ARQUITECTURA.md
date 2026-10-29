# Arquitectura · Fase 1

## Principios
- **El servidor decide**: precios, totales, impuestos, tasa y transiciones de estado se calculan en la base de datos. El navegador solo envía `product_id` y `quantity`.
- **Mínimo privilegio**: se revoca todo a `anon`/`authenticated` y se concede lo necesario. Los clientes escriben únicamente mediante funciones.
- **Inmutabilidad contable**: cada pedido guarda precio unitario, tasa y totales en USD y Bs. al momento de comprar. Las tasas son un historial solo-inserción.

## Monedas e impuestos
- Precio base en USD (`products.price_usd`). Bs. = USD × tasa vigente (`exchange_rates`).
- `restaurant_settings`: `iva_rate`, `prices_include_iva`, `igtf_rate`, `igtf_enabled`. Son configurables porque la normativa puede cambiar; confirmar con el contador.
- El IGTF se aplicará por pago (`payment_methods.igtf_applies`, `payments.igtf_usd`) en la Fase 4.

## API (funciones RPC)
| Función | Quién | Descripción |
|---|---|---|
| `resolve_table(token)` | cliente | Valida QR, devuelve mesa |
| `public_info()` | cliente | Nombre, IVA, tasa vigente |
| `create_order(token, items, notas)` | cliente | Crea pedido validado |
| `get_table_orders(token)` | cliente | Seguimiento de pedidos |
| `get_table_check(token)` | cliente | Cuenta de la mesa |
| `create_service_call(token, tipo, nota)` | cliente | Llamar al mesero (idempotente) |
| `advance_order_status(id, estado, motivo)` | personal | Transición validada por rol |
| `attend_service_call(id)` | personal | Marca llamada atendida |

Errores: `table_not_found`, `items_invalid`, `items_count_invalid`, `notes_too_long`, `no_exchange_rate`, `rate_limited`, `forbidden`, `invalid_transition`, `reason_required`, `order_not_found`, `call_not_pending`.

## Flujo de estados
`recibido → en_preparacion → listo → entregado`; cancelación desde cualquier estado previo a entregado (solo admin, con motivo). Cocina: preparar/listo. Mesero: entregar.

## Tiempo real
Publicación `supabase_realtime`: `orders`, `order_items`, `service_calls`, `payments`. El personal escucha cambios (RLS aplica). El cliente anónimo hará sondeo ligero sobre `get_table_orders` (Fase 2) porque no tiene lectura directa de tablas.
