# Seguridad · Fase 1

- RLS activado en todas las tablas; políticas por rol (`admin`, `cocina`, `mesero`).
- `service_role` jamás en el navegador ni en GitHub.
- QR con token de 64 hex no predecible; el número de mesa no autoriza nada.
- Límite de 5 pedidos/minuto por mesa y una sola llamada pendiente por tipo.
- `payment-evidence` es un bucket privado; la subida será por URL firmada (Fase 4).
- Auditoría automática de catálogo, métodos de pago, ajustes, tasas, perfiles y mesas, y de cancelaciones.

## Límites conocidos / pendientes
- Personal con rol `cocina` puede leer `dining_tables` (incluye `qr_token`). Riesgo bajo; se afinará con vistas en la Fase 5.
- Límites de peticiones por IP y protección contra bots (Cloudflare Turnstile/WAF) se configuran en la Fase 6.
- El usuario administrador debe usar contraseña robusta y MFA.
