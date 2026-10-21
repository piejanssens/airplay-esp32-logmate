FROM alpine:3.24

# websocat is a static binary; grab the latest musl (Alpine-compatible) release
ARG WEBSOCAT_VERSION=v1.14.1
# tzdata lets the TZ env var from compose.yaml control log timestamps
# yq parses config.yaml
RUN apk add --no-cache bash curl coreutils logrotate tzdata yq \
    && curl -fsSL -o /usr/local/bin/websocat \
       "https://github.com/vi/websocat/releases/download/${WEBSOCAT_VERSION}/websocat.x86_64-unknown-linux-musl" \
    && chmod +x /usr/local/bin/websocat

WORKDIR /app
# Everything under app/ is baked into the image; config.yaml and logs/ at the
# top level are host state bind-mounted at runtime (see compose.yaml).
COPY app/ /app/
RUN chmod +x /app/capture_logs.sh /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]