#!/bin/sh
# Renderiza la configuración declarativa con la llave pública de auth-service y arranca Kong.
set -eu

TEMPLATE=/kong/kong.yml.tmpl
OUT="${KONG_DECLARATIVE_CONFIG:-/tmp/kong.yml}"
KEY_FILE="${JWT_PUBLIC_KEY_PATH:-/run/secrets/jwt_public.pem}"

if [ ! -s "$KEY_FILE" ]; then
  echo "festa-gateway: no existe la llave pública JWT en $KEY_FILE (corre festa-infra/scripts/gen-secrets.sh)" >&2
  exit 1
fi

# Inserta la PEM como bloque literal YAML con la indentación de la línea del placeholder.
awk -v keyfile="$KEY_FILE" '
  /^[[:space:]]*rsa_public_key: __JWT_PUBLIC_KEY__[[:space:]]*$/ {
    match($0, /^ */); indent = substr($0, 1, RLENGTH)
    sub(/__JWT_PUBLIC_KEY__/, "|"); print
    while ((getline line < keyfile) > 0) { sub(/\r$/, "", line); if (line != "") print indent "  " line }
    next
  }
  { print }
' "$TEMPLATE" > "$OUT"

kong config parse "$OUT" >/dev/null
echo "festa-gateway: configuración válida en $OUT"

exec /docker-entrypoint.sh "$@"
