#!/usr/bin/env bash
# Pruebas de humo del gateway SIN servicios detrás (las usa el CI, SCRUM-44).
# Verifican que Kong protege las rutas: los servicios no existen, así que una petición que
# Kong deja pasar termina en 502/503/504, y una que Kong corta termina en 401.
#
#   ./scripts/ci-smoke.sh <llave-privada.pem> [http://localhost:8000] [http://localhost:8100]
#
# <llave-privada.pem> es la pareja de la llave pública montada en el gateway: sirve para firmar
# un JWT válido. Para el JWT falsificado el script genera otra llave.
set -euo pipefail

KEY="${1:?uso: ci-smoke.sh <llave-privada.pem> [gateway] [status]}"
GW="${2:-http://localhost:8000}"
STATUS="${3:-http://localhost:8100}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok() { printf '  ✓ %s\n' "$1"; }
ko() { printf '  ✗ %s\n' "$1"; FAILS=$((FAILS + 1)); }
code() { curl -s -o "$TMP/body" -D "$TMP/headers" -w '%{http_code}' "$@"; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
# jwt <llave-privada> <exp>: JWT RS256 con iss=festa-auth, el claim por el que Kong busca la credencial.
jwt() {
  local h p
  h=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  p=$(printf '{"iss":"festa-auth","sub":"00000000-0000-4000-8000-000000000000","role":"user","exp":%s}' "$2" | b64url)
  printf '%s.%s.%s' "$h" "$p" "$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$1" | b64url)"
}

NOW=$(date +%s)
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/otra.pem" 2>/dev/null
VALID=$(jwt "$KEY" $((NOW + 600)))
FORGED=$(jwt "$TMP/otra.pem" $((NOW + 600)))
EXPIRED=$(jwt "$KEY" $((NOW - 60)))

echo "gateway en $GW"

c=$(code "$GW/api/auth/me"); [ "$c" = 401 ] && ok "ruta privada sin JWT → 401" || ko "ruta privada sin JWT → $c (esperado 401)"
c=$(code "$GW/api/events"); [ "$c" = 401 ] && ok "/api/events sin JWT → 401" || ko "/api/events sin JWT → $c (esperado 401)"
c=$(code "$GW/api/events" -H "Authorization: Bearer $FORGED"); [ "$c" = 401 ] && ok "JWT firmado con otra llave → 401" || ko "JWT falsificado → $c (esperado 401)"
c=$(code "$GW/api/events" -H "Authorization: Bearer $EXPIRED"); [ "$c" = 401 ] && ok "JWT vencido → 401" || ko "JWT vencido → $c (esperado 401)"

c=$(code "$GW/api/events" -H "Authorization: Bearer $VALID")
case "$c" in 502|503|504) ok "JWT válido pasa el gateway (servicio ausente → $c)";; *) ko "JWT válido → $c (esperado 502/503/504)";; esac
c=$(code -X POST "$GW/api/auth/login" -H 'content-type: application/json' -d '{}')
case "$c" in 502|503|504) ok "ruta pública /api/auth/login no pide JWT (→ $c)";; *) ko "ruta pública → $c (esperado 502/503/504)";; esac

for p in /health /metrics /api/health; do
  c=$(code --path-as-is "$GW$p")
  case "$c" in 401|404|405) ;; *) ko "$p expuesto al público ($c)";; esac
done
ok "/health y /metrics de los servicios no se exponen"

code "$GW/api/events" >/dev/null
grep -qi '^X-Content-Type-Options: nosniff' "$TMP/headers" && ok "encabezados de seguridad en la respuesta" || ko "falta X-Content-Type-Options: nosniff"

c=$(code "$STATUS/metrics"); { [ "$c" = 200 ] && grep -q kong_ "$TMP/body"; } && ok "métricas de Kong en $STATUS/metrics" || ko "métricas → $c"

if [ "$FAILS" -gt 0 ]; then
  echo "FALLÓ: $FAILS verificaciones"
  exit 1
fi
echo "OK"
