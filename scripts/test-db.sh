#!/usr/bin/env sh
# Aplica migraciones + pruebas sobre un PostgreSQL local o de CI.
set -eu
cd "$(dirname "$0")/.."
: "${DATABASE_URL:?Define DATABASE_URL}"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -f supabase/tests/00_stub_supabase.sql
for f in supabase/migrations/*.sql; do
  echo ">> $f"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -f "$f"
done
cd supabase/tests
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 10_smoke.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 20_admin_unico.sql
