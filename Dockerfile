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

ARG SURICATA_VERSION=8.0.6
# ALPINE_VERSION kept for check-versions.sh/versions.json reference only --
# the FROM lines below pin tag+digest together as a literal so a version
# bump requires deliberately re-resolving the digest, not a silent drift
# if this ARG changes without the pin being updated to match.
ARG ALPINE_VERSION=3.24

# ---------- Stage 1 : builder ----------------------------------------
FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS builder

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
# libhtp-dev is NOT included here: Alpine dropped the libhtp/libhtp-dev
# packages starting with 3.24, so it's built from upstream source below
# instead (keeps --enable-non-bundled-htp working and libhtp independently
# versioned/patchable, without depending on Alpine choosing to package it).
# hadolint ignore=DL3059
RUN apk add --no-cache \
        pcre2-dev yaml-dev jansson-dev \
        libpcap-dev libnet-dev \
        libnetfilter_queue-dev libnfnetlink-dev \
        libcap-ng-dev libcap-dev \
        lz4-dev zlib-dev \
        libmaxminddb-dev

# 4/4  Download tools + Python (for configure script)
# hadolint ignore=DL3059
RUN apk add --no-cache \
        curl xz ca-certificates \
        python3

WORKDIR /src

# Build libhtp from upstream source (see note above)
ARG LIBHTP_VERSION=0.5.53
ARG LIBHTP_SHA256=c6f4aadfc40a57eee5518555c2cc1b2cd38d6d5f8ad3a24e7cfc6a0963c524fb
RUN --mount=type=secret,id=ca-certs,required=false \
    if [ -f /run/secrets/ca-certs ]; then cat /run/secrets/ca-certs >> /etc/ssl/certs/ca-certificates.crt; fi \
 && curl -fsSL "https://github.com/OISF/libhtp/archive/refs/tags/${LIBHTP_VERSION}.tar.gz" -o libhtp.tar.gz \
 && echo "${LIBHTP_SHA256}  libhtp.tar.gz" | sha256sum -c - \
 && tar -xzf libhtp.tar.gz \
 && mv "libhtp-${LIBHTP_VERSION}" libhtp

WORKDIR /src/libhtp

RUN ./autogen.sh \
 && ./configure --prefix=/usr --disable-static \
 && make -j"$(nproc)" \
 && make install \
 && mkdir -p /out/usr/lib \
 && cp -a /usr/lib/libhtp.so* /out/usr/lib/

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
FROM golang:1.26-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2 AS gobuilder
WORKDIR /build
COPY go.mod init.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags='-s -w' -o /init .

# ---------- Stage 2b : pybuilder (Python patche pour suricata-update) ----
# Alpine 3.24 package encore python3 3.14.5 (3 CVE High, fix upstream en
# 3.14.6 pas encore repackage par Alpine -- verifie identique sur 3.21 a
# edge). L'image officielle python:3.14-alpine est basee sur la meme
# Alpine 3.24 mais compile Python depuis les sources independamment du
# cycle apk, et embarque deja 3.14.6.
FROM python:3.14-alpine@sha256:26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92 AS pybuilder
RUN pip install --no-cache-dir suricata-update

# ---------- Stage 3 : prep (assemble runtime filesystem) -------------
FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS prep

# -- Runtime APK installs split for proxy timeout --

# 1/2  Core runtime libs
# openssl + libffi: not needed by any apk package installed here anymore --
# they used to arrive transitively via Alpine's python3 package. Python
# itself now comes from the pybuilder stage (see above), but its _ssl/
# _hashlib/_ctypes C extensions still dlopen libssl.so.3/libcrypto.so.3/
# libffi.so.8 at runtime, so they're listed explicitly.
RUN sed -i 's|https://|http://|g' /etc/apk/repositories \
 && apk add --no-cache \
        pcre2 yaml jansson \
        libpcap libnet \
        libnetfilter_queue libnfnetlink \
        libcap-ng libcap \
        lz4-libs zlib \
        libmaxminddb \
        tini-static \
        tzdata \
        ca-certificates \
        libgcc libstdc++ \
        openssl libffi

# 2/2  Create user + setcap
RUN apk add --no-cache libcap-utils \
 && addgroup -S -g 8000 suricata \
 && adduser -S -D -H -G suricata -u 8000 -s /sbin/nologin suricata

# Python runtime + suricata-update, from pybuilder (see note above).
# libpython3.14.so.1.0 lives directly under /usr/local/lib/, as a sibling
# of the python3.14/ module directory, not inside it -- must be copied
# separately or the interpreter fails to dynamically link at exec time.
COPY --from=pybuilder /usr/local/bin/python3.14 /usr/local/bin/python3.14
COPY --from=pybuilder /usr/local/bin/python3 /usr/local/bin/python3
COPY --from=pybuilder /usr/local/lib/python3.14/ /usr/local/lib/python3.14/
COPY --from=pybuilder /usr/local/lib/libpython3* /usr/local/lib/
COPY --from=pybuilder /usr/local/bin/suricata-update /usr/local/bin/suricata-update

# Suricata binary + data from builder
COPY --from=builder /out/ /

# Set file capabilities on Suricata binary (NET_ADMIN for NFQUEUE, SYS_NICE for CPU affinity)
RUN setcap 'cap_net_admin,cap_sys_nice+ep' /usr/bin/suricata

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

# 3b. suricatasc (reload rules via unix socket, built by suricata itself)
COPY --link --from=prep /usr/bin/suricatasc /usr/bin/suricatasc

# 3c. Python runtime + suricata-update (rule management, from pybuilder --
# see the note on that stage for why it's not the apk-packaged python3)
COPY --link --from=prep /usr/local/bin/suricata-update /usr/local/bin/suricata-update
COPY --link --from=prep /usr/local/bin/python3 /usr/local/bin/python3
COPY --link --from=prep /usr/local/bin/python3.14 /usr/local/bin/python3.14
COPY --link --from=prep /usr/local/lib/python3.14/ /usr/local/lib/python3.14/
COPY --link --from=prep /usr/local/lib/libpython3.14.so* /usr/local/lib/
COPY --link --from=prep /usr/local/lib/libpython3.so /usr/local/lib/libpython3.so

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
