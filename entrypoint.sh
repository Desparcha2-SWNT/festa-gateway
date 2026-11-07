#!/bin/sh
# Renderiza la configuración declarativa (llave pública de auth-service y URLs de los servicios) y arranca Kong.
set -eu

TEMPLATE=/kong/kong.yml.tmpl
OUT="${KONG_DECLARATIVE_CONFIG:-/tmp/kong.yml}"
KEY_FILE="${JWT_PUBLIC_KEY_PATH:-/run/secrets/jwt_public.pem}"

# En ECS Fargate no se montan archivos: la llave llega como texto PEM en JWT_PUBLIC_KEY (desde Secrets
# Manager). Si viene, gana sobre el archivo.
if [ -n "${JWT_PUBLIC_KEY:-}" ]; then
  KEY_FILE=/tmp/jwt_public.pem
  printf '%s\n' "$JWT_PUBLIC_KEY" > "$KEY_FILE"
fi

if [ ! -s "$KEY_FILE" ]; then
  echo "festa-gateway: no hay llave pública JWT (ni JWT_PUBLIC_KEY ni el archivo $KEY_FILE; corre festa-infra/scripts/gen-secrets.sh)" >&2
  exit 1
fi

# URL de cada servicio. Por defecto, el nombre del contenedor en el Docker Compose de festa-infra. En AWS se
# pasan las del balanceador interno, porque el Learner Lab no permite Cloud Map (SCRUM-134).
AUTH_SERVICE_URL="${AUTH_SERVICE_URL:-http://auth-service:8081}"
USER_SERVICE_URL="${USER_SERVICE_URL:-http://user-service:8082}"
EVENT_SERVICE_URL="${EVENT_SERVICE_URL:-http://event-service:8083}"
BOOKING_SERVICE_URL="${BOOKING_SERVICE_URL:-http://booking-service:8084}"
PAYMENT_SERVICE_URL="${PAYMENT_SERVICE_URL:-http://payment-service:8085}"
AI_SERVICE_URL="${AI_SERVICE_URL:-http://ai-service:8086}"
NOTIFICATION_SERVICE_URL="${NOTIFICATION_SERVICE_URL:-http://notification-service:8087}"
ANALYTICS_SERVICE_URL="${ANALYTICS_SERVICE_URL:-http://analytics-service:8088}"

# Inserta la PEM como bloque literal YAML con la indentación de la línea del placeholder y reemplaza
# cada __<SERVICIO>_SERVICE_URL__ por su URL. Una URL vacía o mal formada detiene el arranque.
awk -v keyfile="$KEY_FILE" \
    -v auth="$AUTH_SERVICE_URL" -v user="$USER_SERVICE_URL" -v event="$EVENT_SERVICE_URL" \
    -v booking="$BOOKING_SERVICE_URL" -v payment="$PAYMENT_SERVICE_URL" -v ai="$AI_SERVICE_URL" \
    -v notification="$NOTIFICATION_SERVICE_URL" -v analytics="$ANALYTICS_SERVICE_URL" '
  BEGIN {
    url["AUTH"] = auth; url["USER"] = user; url["EVENT"] = event; url["BOOKING"] = booking
    url["PAYMENT"] = payment; url["AI"] = ai; url["NOTIFICATION"] = notification; url["ANALYTICS"] = analytics
  }
  /^[[:space:]]*rsa_public_key: __JWT_PUBLIC_KEY__[[:space:]]*$/ {
    match($0, /^ */); indent = substr($0, 1, RLENGTH)
    sub(/__JWT_PUBLIC_KEY__/, "|"); print
    while ((getline line < keyfile) > 0) { sub(/\r$/, "", line); if (line != "") print indent "  " line }
    next
  }
  /^[[:space:]]*url: __[A-Z]+_SERVICE_URL__[[:space:]]*$/ {
    match($0, /__[A-Z]+_SERVICE_URL__/); name = substr($0, RSTART + 2, RLENGTH - 16)
    if (!(name in url) || url[name] !~ /^https?:\/\/[^[:space:]]+$/) {
      print "festa-gateway: URL inválida o vacía en " name "_SERVICE_URL" > "/dev/stderr"; exit 1
    }
    sub(/__[A-Z]+_SERVICE_URL__/, url[name]); print
    next
  }
  { print }
' "$TEMPLATE" > "$OUT"

kong config parse "$OUT" >/dev/null
echo "festa-gateway: configuración válida en $OUT"

exec /docker-entrypoint.sh "$@"
