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

# Download Suricata source from OISF and verify its signature.
#
# The tarball used to be taken on trust -- a bare curl, no signature, no hash --
# while libhtp right above it was checked against a pinned sha256. OISF does
# publish a detached signature next to each release, so this uses it.
#
# The key is committed next to this Dockerfile rather than pulled from a
# keyserver at build time, and its fingerprint is pinned below: importing a key
# and then verifying with that same key proves nothing on its own, the
# fingerprint is the anchor. `gpg --list-keys <fpr>` fails if the committed file
# is ever swapped for a different key.
COPY oisf.gpg.asc /tmp/oisf.gpg.asc
ARG OISF_FPR=B36FDAF2607E10E8FFA89E5E2BA9C98CCDF1E93A
RUN --mount=type=secret,id=ca-certs,required=false \
    if [ -f /run/secrets/ca-certs ]; then cat /run/secrets/ca-certs >> /etc/ssl/certs/ca-certificates.crt; fi \
 && apk add --no-cache gnupg \
 && curl -fsSL "https://www.openinfosecfoundation.org/download/suricata-${SURICATA_VERSION}.tar.gz" -o suricata.tar.gz \
 && curl -fsSL "https://www.openinfosecfoundation.org/download/suricata-${SURICATA_VERSION}.tar.gz.sig" -o suricata.tar.gz.sig \
 && GNUPGHOME="$(mktemp -d)" && export GNUPGHOME \
 && gpg --batch --import /tmp/oisf.gpg.asc \
 && gpg --batch --list-keys "${OISF_FPR}" > /dev/null \
 && gpg --batch --verify suricata.tar.gz.sig suricata.tar.gz \
 && gpgconf --kill gpg-agent \
 && rm -rf "$GNUPGHOME" suricata.tar.gz.sig /tmp/oisf.gpg.asc \
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

# Strip everything `make install` puts in /out, not just suricata. This line
# used to name a single file, and suricatasc went out with its debug_info
# intact: 19,8 Mo, bigger than the stripped suricata binary itself. Naming the
# directory means the next binary upstream adds is stripped too.
# `file` is guarded rather than assumed: without it every case arm matches the
# empty string, nothing gets stripped, and the image goes out fat in silence.
RUN command -v file > /dev/null \
 && for b in /out/usr/bin/*; do \
      case "$(file -b "$b")" in *ELF*) strip "$b" ;; esac; \
    done

# ---------- Stage 2 : Go builder (entrypoint + healthcheck) ----------
FROM golang:1.26-alpine@sha256:3889b425f035be855a72fb4755265311293b6d414521f0a519d819df32222d83 AS gobuilder
WORKDIR /build
COPY go.mod init.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags='-s -w' -o /init .

# ---------- Stage 2b : pybuilder (Python patche pour suricata-update) ----
# Alpine 3.24 package encore python3 3.14.5 (3 CVE High, fix upstream en
# 3.14.6 pas encore repackage par Alpine -- verifie identique sur 3.21 a
# edge). L'image officielle python:3.14-alpine est basee sur la meme
# Alpine 3.24 mais compile Python depuis les sources independamment du
# cycle apk, et embarque deja 3.14.6.
FROM python:3.14-alpine@sha256:05b2b8b732ecd268fee8727a369f936f022d1321b59befd13c30ede22769dcdc AS pybuilder
# The whole site-packages tree ships in the final image, so pip's own
# transitive picks are part of the attack surface: python:3.14-alpine bundles
# setuptools 70.3.0 (CVE-2025-47273, path traversal) and pip once resolved
# msgpack 1.1.2 (GHSA-6v7p-g79w-8964). Both used to be upgraded here. But
# suricata-update 1.3.3 declares exactly one dependency -- pyyaml -- and
# nothing that runs in this image imports either package (verified: zero
# references in the installed suricata/ tree). An upgraded dependency is still
# 6,5 Mo of code and still a line on the SBOM. They are deleted in the prep
# stage instead of being kept at a version that happens to be unaffected.
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
        openssl libffi \
        xz-libs libbz2

# 2/2  Create user + setcap
RUN apk add --no-cache libcap-utils \
 && addgroup -S -g 8000 suricata \
 && adduser -S -D -H -G suricata -u 8000 -s /sbin/nologin suricata

# Python runtime + suricata-update, from pybuilder (see note above).
# libpython3.14.so.1.0 lives directly under /usr/local/lib/, as a sibling
# of the python3.14/ module directory, not inside it -- must be copied
# separately or the interpreter fails to dynamically link at exec time.
#
# It is named in full rather than matched by a glob: /usr/local/lib/
# libpython3.14.so is a symlink to .so.1.0 over there, and a COPY whose source
# is a wildcard dereferences what it matches -- the "symlink" landed here as a
# second, complete 6 Mo copy of the library. Only the SONAME is ever loaded at
# runtime. libpython3.so (the stable-ABI stub) is not copied at all: nothing in
# this image links against it, and the closure check below fails loudly if that
# ever stops being true.
COPY --from=pybuilder /usr/local/bin/python3.14 /usr/local/bin/python3.14
COPY --from=pybuilder /usr/local/bin/python3 /usr/local/bin/python3
COPY --from=pybuilder /usr/local/lib/python3.14/ /usr/local/lib/python3.14/
COPY --from=pybuilder /usr/local/lib/libpython3.14.so.1.0 /usr/local/lib/
COPY --from=pybuilder /usr/local/bin/suricata-update /usr/local/bin/suricata-update

# pip is a build-time tool: nothing in this image installs packages at
# runtime, and it drags real CVEs in with it -- trivy reads
# `site-packages/pip/_vendor/vendor.txt`, which still declares
# msgpack==1.1.2 (GHSA-6v7p-g79w-8964) and setuptools==70.3.0
# (CVE-2025-47273) no matter what versions are actually installed
# alongside it. Dropping pip + ensurepip removes those vendored
# declarations (and their bundled wheel) instead of suppressing them.
#
# The rest of this list is code that cannot run here, or that nothing calls:
#
#   setuptools / _distutils_hack / distutils-precedence.pth -- 5,5 Mo, and the
#     reason setuptools CVEs kept landing on this image's SBOM. Nothing imports
#     it (suricata-update needs pyyaml and nothing else). The .pth file goes
#     with it: it runs `import _distutils_hack` at every interpreter start, so
#     leaving it behind buys a traceback on stderr forever.
#   msgpack -- 1 Mo, not a dependency of suricata-update 1.3.3 and imported
#     nowhere in the image.
#   tkinter / curses / sqlite3 -- their C modules are deleted a few lines below
#     because the libraries they need have no business in a Suricata image.
#     The pure-Python half was still being shipped: packages that raise
#     ImportError on their first line.
#   turtle / turtledemo -- tkinter again. venv -- needs the ensurepip removed
#     just above. idlelib -- an IDE. pydoc_data -- the help() topic dump.
#     config-3.14-* -- the Makefile fragments for compiling extensions, which
#     is a build-time concern and there is no compiler here anyway.
#   lib-dynload/_test*, xx*, _ctypes_test*, _xxtestfuzz* -- CPython's own test
#     extensions, 1 Mo of code whose only caller is CPython's test suite.
RUN rm -rf /usr/local/lib/python3.14/ensurepip \
           /usr/local/lib/python3.14/site-packages/pip \
           /usr/local/lib/python3.14/site-packages/pip-*.dist-info \
           /usr/local/bin/pip /usr/local/bin/pip3 /usr/local/bin/pip3.14 \
           /usr/local/lib/python3.14/site-packages/setuptools \
           /usr/local/lib/python3.14/site-packages/setuptools-*.dist-info \
           /usr/local/lib/python3.14/site-packages/_distutils_hack \
           /usr/local/lib/python3.14/site-packages/distutils-precedence.pth \
           /usr/local/lib/python3.14/site-packages/msgpack \
           /usr/local/lib/python3.14/site-packages/msgpack-*.dist-info \
           /usr/local/lib/python3.14/tkinter \
           /usr/local/lib/python3.14/curses \
           /usr/local/lib/python3.14/sqlite3 \
           /usr/local/lib/python3.14/turtledemo \
           /usr/local/lib/python3.14/turtle.py \
           /usr/local/lib/python3.14/venv \
           /usr/local/lib/python3.14/idlelib \
           /usr/local/lib/python3.14/pydoc_data \
           /usr/local/lib/python3.14/config-3.14-* \
           /usr/local/lib/python3.14/lib-dynload/_test* \
           /usr/local/lib/python3.14/lib-dynload/xx* \
           /usr/local/lib/python3.14/lib-dynload/_ctypes_test* \
           /usr/local/lib/python3.14/lib-dynload/_xxtestfuzz*

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
# Collect exactly the shared objects that ship. Copying /lib and /usr/lib whole
# defeats the apk cleanup just below: it carried libapk.so along with it.
# lddtree lists each binary, its transitive dependencies, symlinks with their
# targets, and the loader for the architecture being built. It runs before apk
# is removed, since it needs apk to install itself.
#
# Python's stdlib C modules in lib-dynload are dlopen'd by the interpreter, and
# they are what pulls libssl and friends: without them as roots the closure is
# short and suricata-update dies on its first import. Enumerated with find, and
# the build stops if the enumeration is empty.
#
# But Python is built from source in pybuilder, against a much larger set of
# libraries than this stage carries: _tkinter, _sqlite3, _gdbm, _curses and
# readline reference libtk/libtcl/libsqlite3/libgdbm/ncurses/libreadline, none
# of which belongs in a Suricata image. lddtree reports each missing dependency
# on stderr and STILL EXITS 0, so those modules used to be shipped broken and
# the closure was quietly incomplete -- verified on the published image, which
# carried ten .so files that could never be imported. A module whose
# dependencies are absent here can never work: it is deleted rather than
# embedded broken. xz-libs and libbz2 are installed above precisely so that
# _lzma and _bz2 survive this pruning -- a rule updater that unpacks archives
# has a real reason to need them, the other ten do not.
#
# lddtree prints each binary it is handed, so this list holds the roots as well
# as their dependencies -- and every one of those roots is ALSO copied on its
# own COPY line in the final stage. Layers are not deduplicated: suricata,
# suricatasc, libpython and all of lib-dynload were shipped twice, 49 Mo of a
# 148 Mo image. Dropping the individual COPY lines instead is not an option:
# `setcap` above puts a file capability on /usr/bin/suricata, busybox tar has
# no xattr support, and the copy that travels through this tar arrives without
# cap_net_admin -- NFQUEUE would fail at runtime, silently at build time. So
# the roots keep their own COPY, and are filtered out here; what this tar
# carries is the system libraries and the loader, nothing else.
#
# The filter also drops an artifact. lddtree resolves libpython through the
# interpreter's RUNPATH and prints it unnormalised, as
# /usr/local/bin/../lib/libpython3.14.so.1.0; busybox tar answers "removing
# leading '/usr/local/bin/../' from member names" and stores it as
# lib/libpython3.14.so.1.0 -- a third 6 Mo copy of the library, sitting in
# /lib, that no loader ever looks at.
#
# The completeness check runs on the UNFILTERED list, before the filter: a
# filter must never be able to hide a missing dependency.
#
# No pipes below: this stage runs the default /bin/sh, without pipefail.
RUN --mount=type=cache,target=/var/cache/apk \
    apk add --no-cache lddtree \
 && mkdir -p /rootfs \
 && find /usr/local/lib/python3*/lib-dynload -name '*.so' > /tmp/dynload.list \
 && test -s /tmp/dynload.list \
 && while IFS= read -r m; do \
      lddtree -l "$m" > /dev/null 2> /tmp/mod.err; \
      if grep -q 'Not found' /tmp/mod.err; then \
        echo "lib-dynload: suppression de ${m} (dependance absente de cette image)"; \
        rm -f "$m"; \
      fi; \
    done < /tmp/dynload.list \
 && { lddtree -l /usr/bin/suricata /usr/bin/suricatasc /usr/local/bin/python3; \
      find /usr/local/lib -maxdepth 1 -name 'libpython3*.so*' -exec lddtree -l {} +; \
      find /usr/local/lib/python3*/lib-dynload -name '*.so' -exec lddtree -l {} +; \
      find /usr/local/lib/python3*/site-packages -name '*.so' -exec lddtree -l {} +; } \
      > /tmp/closure.list 2> /tmp/closure.err \
 && if grep -q 'Not found' /tmp/closure.list /tmp/closure.err; then \
      echo "closure incomplete -- a dependency is missing from this stage:" >&2; \
      grep 'Not found' /tmp/closure.list /tmp/closure.err >&2; \
      exit 1; \
    fi \
 && sort -u /tmp/closure.list -o /tmp/closure.list \
 && grep -v -E '^/usr/(local/|bin/suricata)' /tmp/closure.list > /tmp/closure.deps \
 && tar -cf /tmp/closure.tar -T /tmp/closure.deps \
 && tar -xf /tmp/closure.tar -C /rootfs \
 && rm -f /tmp/dynload.list /tmp/mod.err /tmp/closure.list /tmp/closure.deps \
          /tmp/closure.err /tmp/closure.tar

# OpenSSL providers are dlopen'd, so no closure lists them. The 1.x engines
# (engines-3/) are deprecated and unused.
RUN mkdir -p /rootfs/usr/lib \
 && cp -a /usr/lib/ossl-modules /rootfs/usr/lib/

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
COPY --link --from=prep /rootfs/ /

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
COPY --link --from=prep /usr/local/lib/libpython3.14.so.1.0 /usr/local/lib/

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
