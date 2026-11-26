FROM kong:3.9.1

USER root
COPY kong.yml.tmpl /kong/kong.yml.tmpl
COPY --chmod=755 entrypoint.sh /festa-entrypoint.sh
# Git en Windows puede dejar CRLF: el shebang fallaría.
RUN sed -i 's/\r$//' /festa-entrypoint.sh
USER kong

# KONG_SSL_CIPHER_SUITE=modern (SCRUM-48): el HTTPS de Kong solo negocia TLS 1.3 (perfil "modern" de Mozilla).
# En AWS el TLS público lo termina API Gateway; esto aplica al 8443 local y a cualquier despliegue que exponga Kong.
ENV KONG_DATABASE=off \
    KONG_DECLARATIVE_CONFIG=/tmp/kong.yml \
    KONG_PROXY_LISTEN="0.0.0.0:8000, 0.0.0.0:8443 ssl" \
    KONG_SSL_CIPHER_SUITE=modern \
    KONG_STATUS_LISTEN=0.0.0.0:8100 \
    KONG_ADMIN_LISTEN=off \
    KONG_NGINX_WORKER_PROCESSES=1 \
    KONG_PROXY_ERROR_LOG=/dev/stderr \
    KONG_HEADERS=off

# El log de acceso registra la ruta sin la consulta: la app pide el mapa con lat y lng en la URL (RNF5, Ley 1581).
# $uri no incluye la consulta; el formato por defecto de nginx usa $request, que sí la incluye.
ENV KONG_PROXY_ACCESS_LOG="/dev/stdout festa" \
    KONG_NGINX_HTTP_LOG_FORMAT="festa '\$remote_addr [\$time_local] \"\$request_method \$uri \$server_protocol\" \$status \$body_bytes_sent \$request_time \"\$http_user_agent\"'"

EXPOSE 8000 8443 8100
HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=5 CMD kong health
ENTRYPOINT ["/festa-entrypoint.sh"]
CMD ["kong", "docker-start"]
