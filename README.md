# festa-gateway

Punto de entrada único de la app móvil. Usa **Kong 3.9 en modo DB-less**: la configuración es declarativa, vive en [`kong.yml.tmpl`](kong.yml.tmpl) y no usa base de datos.

| Puerto | Uso |
|---|---|
| 8000 | Proxy HTTP |
| 8443 | Proxy HTTPS (certificado autofirmado en local) |
| 8100 | Métricas Prometheus (`/metrics`) y estado de Kong. No se expone al público. |

Desde el emulador de Android el gateway es `http://10.0.2.2:8000`.

## Rutas

El cliente siempre llama a `/api/<servicio>/...`. Kong quita el prefijo `/api` antes de pasar la petición al servicio, así que cada servicio monta sus rutas bajo `/<servicio>`.

| Ruta pública (cliente) | Servicio → ruta interna | JWT | Rate limit |
|---|---|---|---|
| `POST /api/auth/*` (register, login, google, refresh, logout) | auth-service → `/auth/*` | no | 30/min y 300/h por IP |
| `/api/auth/me*`, `/api/auth/admin/*` | auth-service | sí | 120/min por token |
| `/api/users`, `/api/merchants`, `/api/reports` | user-service | sí | 120/min por token |
| `/api/events` | event-service | sí | 300/min por token (el mapa pide mucho) |
| `/api/bookings` | booking-service | sí | 300/min por token (ráfagas al escanear QR) |
| `/api/payments` | payment-service | sí | 30/min por token |
| `POST /webhooks/wompi` | payment-service (verifica la firma de Wompi) | no | 120/min por IP |
| `/api/ai` | ai-service | sí | 30/min por token (el límite fino 5–20/min lo pone ai-service) |
| `/api/notifications` | notification-service | sí | 120/min por token |
| `/api/analytics` | analytics-service | sí | 120/min por token |

Además hay un **límite global de 600/min por IP**. Es holgado a propósito: en la ECI muchos estudiantes salen a internet por la misma IP pública (NAT). Por eso las rutas con login limitan por **token** y no por IP.

Los `/health` y `/metrics` de los servicios **no** pasan por el gateway, porque solo se enrutan rutas que empiezan por `/api/` o `/webhooks/`.

## JWT

- **Quién lo emite:** auth-service, con RS256.
- **Cómo lo verifica Kong:** busca la credencial por el claim `iss` (= `festa-auth`) y comprueba la firma y `exp`. Además rechaza tokens que duren más de 1 h.
- **De dónde sale la llave pública:** el contenedor monta `festa-infra/secrets/jwt_public.pem`. Al arrancar, `entrypoint.sh` la inserta en la plantilla, valida el resultado con `kong config parse` y solo entonces arranca Kong. Si la llave no está, el contenedor no arranca.
- **Qué pasa después:** Kong solo deja pasar tokens auténticos. Cada servicio vuelve a verificar el JWT y lee `sub` y `role` de él para autorizar (defensa en profundidad).
- **Respuestas de Kong:** los 401 y 429 que genera Kong traen `{"message": "..."}`, no el formato de error de los servicios. La app debe guiarse por el **código de estado**.

## Plugins globales

| Plugin | Para qué |
|---|---|
| `pre-function` | Reescribe `/api/x` → `/x` hacia el servicio |
| `correlation-id` | Pone `X-Correlation-ID`: lo respeta si viene y si no lo genera. Lo devuelve al cliente y los servicios lo propagan a sus logs y mensajes |
| `prometheus` | Métricas de peticiones, latencia y estado HTTP por servicio y ruta |
| `request-size-limiting` | Cuerpo máximo de 1 MB |
| `response-transformer` | Agrega HSTS, `nosniff`, `X-Frame-Options` y `Referrer-Policy` |
| `cors` | Solo para Flutter web en desarrollo |

## Correr

```bash
# desde festa-infra (necesita secrets/jwt_public.pem: ./scripts/gen-secrets.sh)
docker compose --profile gateway --profile auth up -d --build
./scripts/smoke.sh            # prueba de humo (desde este repo)
```

Para validar la configuración sin levantar nada:

```bash
docker build -t festa-gateway . && docker run --rm \
  -v "$PWD/../festa-infra/secrets/jwt_public.pem:/run/secrets/jwt_public.pem:ro" \
  --entrypoint sh festa-gateway -c '/festa-entrypoint.sh true'
```
