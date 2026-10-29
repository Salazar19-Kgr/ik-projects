# Plataforma integral para restaurante · `ik`

Menú por QR, cocina en tiempo real, pagos en **USD y bolívares**, y panel administrativo para un restaurante de 10 mesas.

**Stack:** GitHub · Cloudflare Pages/Workers · Supabase (PostgreSQL, Auth, Storage, Realtime) · Termux (desarrollo).

## Estado

| Fase | Contenido | Estado |
|---|---|---|
| 1 · Base | Esquema SQL, RLS, funciones, semillas, CI | **Entregada (pendiente de aplicar en Supabase)** |
| 2 · Cliente | Catálogo, QR por mesa, carrito, pedidos | Pendiente |
| 3 · Operación | Cocina, estados, llamadas al mesero | Pendiente |
| 4 · Pagos | Cuenta, métodos, comprobantes, revisión | Pendiente |
| 5 · Administración | Catálogo, mesas, usuarios, informes | Pendiente |
| 6 · Producción | Pruebas, dominio, QR físicos | Pendiente |

## Estructura

```
supabase/migrations/   Esquema versionado (0001…0005)
supabase/seed/         01_base (todos los entornos) · 02_demo_dev (solo pruebas)
supabase/tests/        Pruebas SQL de reglas críticas
scripts/               build-sql.sh · test-db.sh
docs/                  ARQUITECTURA.md · SEGURIDAD.md
apps/ packages/        Se llenan desde la Fase 2
```

## Aplicar la Fase 1 en Supabase

1. Crea un proyecto en Supabase.
2. Genera el SQL unificado: `sh scripts/build-sql.sh` → `dist/schema_completo.sql`.
3. Pégalo en **SQL Editor** y ejecútalo.
4. Ejecuta `supabase/seed/01_base.sql` (configuración, 10 mesas, métodos de pago).
5. Crea tu usuario administrador en **Authentication > Users** y vincúlalo:
   ```sql
   insert into public.profiles (id, full_name, role)
   values ('<UUID del usuario>', 'Tu nombre', 'admin');
   ```
6. Registra la primera tasa de cambio (sin tasa, el sistema rechaza pedidos a propósito):
   ```sql
   insert into public.exchange_rates (rate_ves, source) values (<tasa>, 'BCV');
   ```
7. Solo en pruebas: `supabase/seed/02_demo_dev.sql`.

> Usa una contraseña robusta y activa MFA para el administrador. Nunca guardes contraseñas ni claves en el repositorio.

## Trabajar desde Termux

```sh
pkg install git nodejs
git clone https://github.com/Salazar19-Kgr/ik.git && cd ik
git add . && git commit -m "feat: base de datos (fase 1)" && git push origin main
```

## Pruebas

`sh scripts/test-db.sh` aplica migraciones y pruebas sobre un PostgreSQL (requiere `psql` y `DATABASE_URL`). GitHub Actions lo ejecuta en cada cambio.

## Acceso del administrador (reemplaza los pasos 5 y 6 de arriba)

El acceso es por código enviado al correo. Solo los correos de la tabla `allowed_emails` pueden registrarse (migración 0006); el resto es rechazado. El perfil y el rol se crean solos. La tasa de cambio **no** se escribe a mano: se gestiona desde el panel de administración.
