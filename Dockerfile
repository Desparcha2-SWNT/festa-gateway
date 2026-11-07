FROM kong:3.9.1

USER root
COPY kong.yml.tmpl /kong/kong.yml.tmpl
COPY --chmod=755 entrypoint.sh /festa-entrypoint.sh
# Git en Windows puede dejar CRLF: el shebang fallaría.
RUN sed -i 's/\r$//' /festa-entrypoint.sh
USER kong

ENV KONG_DATABASE=off \
    KONG_DECLARATIVE_CONFIG=/tmp/kong.yml \
    KONG_PROXY_LISTEN="0.0.0.0:8000, 0.0.0.0:8443 ssl" \
    KONG_STATUS_LISTEN=0.0.0.0:8100 \
    KONG_ADMIN_LISTEN=off \
    KONG_NGINX_WORKER_PROCESSES=1 \
    KONG_PROXY_ACCESS_LOG=/dev/stdout \
    KONG_PROXY_ERROR_LOG=/dev/stderr \
    KONG_HEADERS=off

EXPOSE 8000 8443 8100
HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=5 CMD kong health
ENTRYPOINT ["/festa-entrypoint.sh"]
CMD ["kong", "docker-start"]
