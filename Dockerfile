# syntax=docker/dockerfile:1

# Pinned by digest so a rebuild of the same tag cannot change underneath a
# release; Dependabot proposes updates to both.
FROM alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a

ARG VERSION=dev

# Package versions follow the pinned Alpine release, so a rebuild picks up its
# security fixes without editing this file. tzdata makes TZ work for log
# timestamps.
RUN apk add --no-cache curl jq tzdata \
    && addgroup -S -g 10001 nofixedaddress \
    && adduser -S -D -H -u 10001 -G nofixedaddress -s /sbin/nologin nofixedaddress

COPY --chmod=0755 src/nofixedaddress.sh /usr/local/bin/nofixedaddress

ENV NFA_VERSION=${VERSION} \
    INTERVAL=86400 \
    IPV4=true \
    IPV6=false \
    CREATE_IF_MISSING=false \
    DRY_RUN=false \
    LOG_LEVEL=info

LABEL org.opencontainers.image.title="No Fixed Address" \
      org.opencontainers.image.description="Keeps Cloudflare DNS records pointed at your current public IP address." \
      org.opencontainers.image.source="https://github.com/mdr6273/no-fixed-address" \
      org.opencontainers.image.url="https://github.com/mdr6273/no-fixed-address" \
      org.opencontainers.image.documentation="https://github.com/mdr6273/no-fixed-address#readme" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.authors="Mike Richardson" \
      org.opencontainers.image.version="${VERSION}"

# Numeric so that Kubernetes and similar can verify runAsNonRoot.
USER 10001:10001

# Fails once the last successful check is older than INTERVAL plus two hours.
HEALTHCHECK --interval=5m --timeout=10s --start-period=2m --retries=3 \
    CMD ["nofixedaddress", "healthcheck"]

# Exec form keeps the script as PID 1, so it receives the SIGTERM from
# `docker stop` directly.
ENTRYPOINT ["nofixedaddress"]
