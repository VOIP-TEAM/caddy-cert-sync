# Image chạy hệ thống thay cert trong container. Cần chạy với --network host và các volume trong compose.example.yml.
FROM docker:cli AS dockercli

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends bash openssl curl jq inotify-tools ca-certificates procps tzdata coreutils util-linux openssh-client \
 && rm -rf /var/lib/apt/lists/*
COPY --from=dockercli /usr/local/bin/docker /usr/local/bin/docker
COPY bin/*.sh /usr/local/bin/
COPY container/entrypoint.sh /usr/local/bin/container-entrypoint.sh
COPY VERSION /usr/local/share/caddy-cert-sync/VERSION
RUN chmod 755 /usr/local/bin/*.sh && chmod 644 /usr/local/bin/lib-*.sh
HEALTHCHECK --interval=60s --timeout=10s --start-period=20s CMD pgrep -f watch-caddy-cert.sh >/dev/null || exit 1
ENTRYPOINT ["/usr/local/bin/container-entrypoint.sh"]
