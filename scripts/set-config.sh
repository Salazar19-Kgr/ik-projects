#!/usr/bin/env sh
# Uso: sh scripts/set-config.sh https://TU-PROYECTO.supabase.co TU_CLAVE
set -eu
cd "$(dirname "$0")/.."
[ $# -eq 2 ] || { echo "Uso: sh scripts/set-config.sh <URL> <CLAVE>"; exit 1; }
cat > public/config.js <<EOT
window.IK_CONFIG = { SUPABASE_URL: '$1', SUPABASE_ANON_KEY: '$2' };
EOT
echo "Listo: public/config.js actualizado"
