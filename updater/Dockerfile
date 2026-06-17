# =====================================================================
#  Suricata Updater - Alpine + Python + suricata-update + suricatasc
#  Designed to run as ephemeral container (podman run --rm)
#  Writes rules to shared volume, reloads Suricata via unix socket
# =====================================================================

ARG ALPINE_VERSION=3.21

FROM alpine:${ALPINE_VERSION}

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

RUN sed -i 's|https://|http://|g' /etc/apk/repositories \
 && apk add --no-cache \
        python3 \
        py3-pip \
        py3-yaml \
 && pip3 install --no-cache-dir --break-system-packages \
        suricata-update \
 && addgroup -S -g 8000 suricata \
 && adduser -S -D -H -G suricata -u 8000 -s /sbin/nologin suricata

USER 8000:8000

ENTRYPOINT ["suricata-update"]
CMD ["-f", "--no-test"]
