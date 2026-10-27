#!/usr/bin/env bash
# Prueba de humo del gateway. Necesita gateway + auth-service corriendo.
#   ./scripts/smoke.sh [http://localhost:8000]
# Usa ../festa-infra/secrets/jwt_public.pem solo para fabricar un token falso con otra llave.
set -euo pipefail
GW="${1:-http://localhost:8000}"
GWS="https://localhost:8443"
EMAIL="gw.$(date +%s)@escuelaing.edu.co"
ok() { printf '  ✓ %s\n' "$1"; }
fail() { printf '  ✗ %s\n' "$1"; [ -f /tmp/gw_body ] && head -c 300 /tmp/gw_body && echo; exit 1; }
json() { node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{const o=JSON.parse(d);console.log($1)})"; }
req() { curl -s -o /tmp/gw_body -D /tmp/gw_headers -w '%{http_code}' "$@"; }
header() { grep -i "^$1:" /tmp/gw_headers | head -1 | cut -d' ' -f2- | tr -d '\r'; }

echo "gateway en $GW"

code=$(req -X POST "$GW/api/auth/register" -H 'content-type: application/json' -H 'X-Correlation-ID: smoke-gw-1' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"clave1234\",\"displayName\":\"Gateway Smoke\",\"accountType\":\"user\"}")
[ "$code" = 201 ] && ok "POST /api/auth/register (público) → 201" || fail "register $code"
TOKEN=$(json o.accessToken < /tmp/gw_body)
[ "$(header X-Correlation-ID)" = smoke-gw-1 ] && ok "X-Correlation-ID se respeta y vuelve al cliente" || fail "correlation id"
[ "$(header X-Content-Type-Options)" = nosniff ] && ok "encabezados de seguridad" || fail "security headers"

[ "$(req "$GW/api/auth/me" -H "Authorization: Bearer $TOKEN")" = 200 ] && ok "GET /api/auth/me con JWT → 200" || fail "me"
[ "$(req "$GW/api/auth/me")" = 401 ] && ok "GET /api/auth/me sin JWT → 401 (lo corta Kong)" || fail "me sin jwt"

# Token con firma válida en forma pero de otra llave: Kong debe rechazarlo.
FORGED=$(node -e '
const c=require("crypto");const {privateKey}=c.generateKeyPairSync("rsa",{modulusLength:2048});
const b=o=>Buffer.from(JSON.stringify(o)).toString("base64url");
const h=b({alg:"RS256",typ:"JWT"}),p=b({iss:"festa-auth",sub:"00000000-0000-4000-8000-000000000000",role:"admin",exp:Math.floor(Date.now()/1000)+600});
console.log(h+"."+p+"."+c.sign("RSA-SHA256",Buffer.from(h+"."+p),privateKey).toString("base64url"))')
[ "$(req "$GW/api/auth/me" -H "Authorization: Bearer $FORGED")" = 401 ] && ok "JWT firmado con otra llave → 401" || fail "forged"
EXPIRED=$(node -e '
const b=o=>Buffer.from(JSON.stringify(o)).toString("base64url");
console.log(b({alg:"RS256",typ:"JWT"})+"."+b({iss:"festa-auth",exp:1})+".x")')
[ "$(req "$GW/api/auth/me" -H "Authorization: Bearer $EXPIRED")" = 401 ] && ok "JWT vencido/mal firmado → 401" || fail "expired"

code=$(req "$GW/api/events" -H "Authorization: Bearer $TOKEN")
case "$code" in 500|502|503) ok "/api/events con JWT pasa el gateway (event-service aún no existe → $code)";; *) false;; esac || fail "events $code"
[ "$(req "$GW/api/events")" = 401 ] && ok "/api/events sin JWT → 401" || fail "events sin jwt"

for p in /health /metrics /api/health /api/auth/../../health; do
  code=$(req --path-as-is "$GW$p")
  [ "$code" = 404 ] || [ "$code" = 401 ] || [ "$code" = 405 ] || fail "$p expuesto ($code)"
done
ok "/health y /metrics de los servicios no se exponen"

[ "$(req -k "$GWS/api/auth/me" -H "Authorization: Bearer $TOKEN")" = 200 ] && ok "HTTPS 8443 (certificado autofirmado) → 200" || fail "https"

[ "$(req http://localhost:8100/metrics)" = 200 ] && grep -q kong_http_requests_total /tmp/gw_body && ok "métricas de Kong en :8100/metrics" || fail "metrics"

limited=""
for i in $(seq 1 40); do
  code=$(req -X POST "$GW/api/auth/login" -H 'content-type: application/json' -d '{"email":"nadie@escuelaing.edu.co","password":"mala1234"}')
  if [ "$code" = 429 ]; then limited=$i; break; fi
done
[ -n "$limited" ] && ok "rate limit de login por IP → 429 en el intento $limited" || fail "sin rate limit"

echo "OK"
