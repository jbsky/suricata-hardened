# =====================================================================
#  Suricata Hardened Image - NFQUEUE IPS mode
#  4-stage build : compile -> Go init -> prep runtime -> FROM scratch
#  Conformité Docker Hardened Image :
#   - FROM scratch final stage: zero shell, zero package manager
#   - utilisateur non-root (uid 8000) + file capabilities (NET_ADMIN)
#   - binaires strip + RELRO + PIE + stack-protector
#   - entrypoint + healthcheck en binaire Go statique
#   - filesystem read-only friendly
# =====================================================================

ARG SURICATA_VERSION=8.0.5
ARG ALPINE_VERSION=3.21

# ---------- Stage 1 : builder ----------------------------------------
FROM alpine:${ALPINE_VERSION} AS builder

ARG SURICATA_VERSION
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
ENV CFLAGS="-O2 -fstack-protector-strong -fstack-clash-protection -fPIE -D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security" \
    CXXFLAGS="-O2 -fstack-protector-strong -fstack-clash-protection -fPIE -D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security" \
    LDFLAGS="-Wl,-z,relro,-z,now,-z,noexecstack -pie"

# -- APK installs split across multiple RUN commands so that each
#    completes well within the proxy's 240-second connection timeout.

# 1/4  Inject CA + core build toolchain
RUN --mount=type=secret,id=ca-certs,required=false \
    if [ -f /run/secrets/ca-certs ]; then cat /run/secrets/ca-certs >> /etc/ssl/certs/ca-certificates.crt; fi \
 && sed -i 's|https://|http://|g' /etc/apk/repositories \
 && apk add --no-cache \
        build-base \
        autoconf automake libtool pkgconf \
        linux-headers \
        file

# 2/4  Rust toolchain (required by Suricata 8.x parsers)
RUN apk add --no-cache \
        rust cargo cbindgen

# 3/4  Library dependencies
RUN apk add --no-cache \
        pcre2-dev yaml-dev jansson-dev \
        libpcap-dev libnet-dev libhtp-dev \
        libnetfilter_queue-dev libnfnetlink-dev \
        libcap-ng-dev libcap-dev \
        lz4-dev zlib-dev \
        libmaxminddb-dev

# 4/4  Download tools + Python (for configure script)
RUN apk add --no-cache \
        curl xz ca-certificates \
        python3

WORKDIR /src

# Download Suricata source from OISF
RUN --mount=type=secret,id=ca-certs,required=false \
    if [ -f /run/secrets/ca-certs ]; then cat /run/secrets/ca-certs >> /etc/ssl/certs/ca-certificates.crt; fi \
 && curl -fsSL "https://www.openinfosecfoundation.org/download/suricata-${SURICATA_VERSION}.tar.gz" -o suricata.tar.gz \
 && tar -xzf suricata.tar.gz \
 && mv "suricata-${SURICATA_VERSION}" suricata

WORKDIR /src/suricata

RUN ./configure \
        --prefix=/usr \
        --sysconfdir=/etc \
        --localstatedir=/var \
        --enable-nfqueue \
        --enable-geoip \
        --enable-non-bundled-htp \
        --disable-suricata-update \
        --disable-python \
        --disable-gccmarch-native

RUN make -j"$(nproc)" \
 && make install DESTDIR=/out

# Strip binary
RUN strip /out/usr/bin/suricata

# ---------- Stage 2 : Go builder (entrypoint + healthcheck) ----------
FROM golang:1.26-alpine AS gobuilder
WORKDIR /build
COPY go.mod init.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags='-s -w' -o /init .

# ---------- Stage 3 : prep (assemble runtime filesystem) -------------
FROM alpine:${ALPINE_VERSION} AS prep

# -- Runtime APK installs split for proxy timeout --

# 1/2  Core runtime libs
RUN sed -i 's|https://|http://|g' /etc/apk/repositories \
 && apk add --no-cache \
        pcre2 yaml jansson \
        libpcap libnet libhtp \
        libnetfilter_queue libnfnetlink \
        libcap-ng libcap \
        lz4-libs zlib \
        libmaxminddb \
        tini-static \
        tzdata \
        ca-certificates \
        libgcc libstdc++

# 2/2  Create user + setcap
RUN apk add --no-cache libcap-utils \
 && addgroup -S -g 8000 suricata \
 && adduser -S -D -H -G suricata -u 8000 -s /sbin/nologin suricata

# Suricata binary + data from builder
COPY --from=builder /out/ /

# Set file capabilities on Suricata binary (NET_ADMIN for NFQUEUE, NET_RAW for pcap, SYS_NICE for CPU affinity)
RUN setcap 'cap_net_admin,cap_net_raw,cap_sys_nice+ep' /usr/bin/suricata

# Default config + rules directory structure
RUN mkdir -p /etc/suricata/rules /var/lib/suricata/rules \
 && touch /var/lib/suricata/rules/suricata.rules \
 && chown -R root:suricata /etc/suricata \
 && chown -R suricata:suricata /var/lib/suricata/rules \
 && chmod 0750 /etc/suricata

# Strip APK artifacts
RUN rm -rf /lib/apk /lib/libapk* /var/cache/apk /etc/apk /sbin/apk

# ---------- Stage 4 : FROM scratch (final hardened image) ------------
FROM scratch

LABEL org.opencontainers.image.title="suricata-hardened" \
      org.opencontainers.image.description="Suricata 8 FROM scratch — NFQUEUE IPS, non-root, file caps, zero shell" \
      org.opencontainers.image.vendor="jbsky" \
      org.opencontainers.image.licenses="GPL-2.0-only" \
      org.opencontainers.image.source="https://github.com/jbsky/suricata-hardened" \
      security.hardening.tier="platine" \
      security.hardening.features="from-scratch,go-init,tini-pid1,zero-shell,non-root,compiler-hardening,cosign-signed,sbom,slsa-provenance"

# 1. User database (musl getpwuid needs /etc/passwd)
COPY --link --from=prep /etc/passwd /etc/passwd
COPY --link --from=prep /etc/group  /etc/group

# 2. Dynamic linker (musl) + shared libraries
COPY --link --from=prep /lib/ /lib/
COPY --link --from=prep /usr/lib/ /usr/lib/

# 3. Suricata binary (with file capabilities preserved)
COPY --link --from=prep /usr/bin/suricata /usr/bin/suricata

# 4. Suricata data files (classification, reference, threshold configs)
COPY --link --from=prep /usr/share/suricata/ /usr/share/suricata/

# 5. Default config (overridden by volume mount at runtime)
COPY --link --from=prep /etc/suricata/ /etc/suricata/

# 5b. Rules directory with empty default rules file
COPY --link --from=prep /var/lib/suricata/ /var/lib/suricata/

# 6. TLS trust store + timezone data
COPY --link --from=prep /etc/ssl/ /etc/ssl/
COPY --link --from=prep /usr/share/zoneinfo/ /usr/share/zoneinfo/

# 7. PID 1 — tini-static (no musl dependency for PID 1 reliability)
COPY --link --from=prep /sbin/tini-static /sbin/tini

# 8. Go init binary (static, entrypoint + healthcheck + setup-dirs)
COPY --link --from=gobuilder /init /usr/local/bin/init

# 9. Create runtime directories (no shell available)
RUN ["/usr/local/bin/init", "--setup-dirs"]

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

USER 8000:8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["/usr/local/bin/init", "--healthcheck"]

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/init"]
CMD ["suricata", "-q", "0", "-q", "1", "-q", "2", "-q", "3", "--runmode", "workers"]
