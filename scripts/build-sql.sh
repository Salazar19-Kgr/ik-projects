#!/usr/bin/env sh
# Une las migraciones en un solo archivo para pegarlo en Supabase > SQL Editor.
set -eu
cd "$(dirname "$0")/.."
mkdir -p dist
out="dist/schema_completo.sql"
: > "$out"
for f in supabase/migrations/*.sql; do
  printf '\n-- ===== %s =====\n' "$f" >> "$out"
  cat "$f" >> "$out"
done
echo "Generado: $out ($(wc -l < "$out") líneas)"
