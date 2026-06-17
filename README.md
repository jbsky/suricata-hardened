# suricata-hardened

[![Build](https://github.com/jbsky/suricata-hardened/actions/workflows/build-push.yml/badge.svg)](https://github.com/jbsky/suricata-hardened/actions/workflows/build-push.yml)
[![Docker Hub](https://img.shields.io/docker/v/jbsky/suricata-hardened?sort=semver&label=Docker%20Hub)](https://hub.docker.com/r/jbsky/suricata-hardened)
[![Hardening](https://img.shields.io/badge/hardening-platine-blueviolet)](https://github.com/jbsky/suricata-hardened#security--verification)

Hardened Suricata 8 IPS container image — FROM scratch, non-root, file capabilities, zero shell.

## Features

- **FROM scratch** final image: no shell, no package manager, no attack surface
- **Non-root** (uid 8000) with file capabilities (`cap_net_admin,cap_sys_nice+ep`)
- **Compiler hardening**: RELRO, PIE, stack-protector, FORTIFY_SOURCE, NX stack
- **Go static entrypoint**: healthcheck + config validation + setup-dirs (no shell needed)
- **tini-static** as PID 1 for proper signal handling and zombie reaping
- **NFQUEUE IPS mode** optimized for VyOS deployment (4 queues, workers runmode)
- **Hot rule reload** via unix socket (zero downtime updates)

## Quick start

```bash
cp .env.example .env
make build
make up
make test
```

## VyOS deployment

See `vyos/vyos-container.config` for the full VyOS configuration commands and `vyos/suricata-update.sh` for the daily rule update script.

## Images

| Image | Registry | Description |
|-------|----------|-------------|
| suricata-hardened | `docker.io/jbsky/suricata-hardened` | Production IPS engine |
| suricata-updater | `docker.io/jbsky/suricata-updater` | Rule update tool (ephemeral) |

## License

GPL-2.0-only (same as Suricata)

## Security & Verification

This image is signed with [cosign](https://github.com/sigstore/cosign) using keyless OIDC (Sigstore).

### Verify image signature

```bash
# From ghcr.io (signatures stored natively)
cosign verify \
  --certificate-identity-regexp '^https://github.com/jbsky/suricata-hardened/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/jbsky/suricata-hardened:latest

# From Docker Hub (signatures stored in ghcr.io)
COSIGN_REPOSITORY=ghcr.io/jbsky/suricata-hardened \
  cosign verify \
  --certificate-identity-regexp '^https://github.com/jbsky/suricata-hardened/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  docker.io/jbsky/suricata-hardened:latest
```


### Hardening tier "Platine" guarantees

| Property | Description |
|----------|-------------|
| FROM scratch | No base image, no shell, no package manager |
| Go static init | Binary entrypoint + healthcheck (no script) |
| tini PID 1 | Proper signal forwarding and zombie reaping |
| Non-root | Runs as unprivileged UID |
| Compiler hardening | RELRO, PIE, SSP, FORTIFY_SOURCE, stack-clash, NX |
| Cosign signed | OIDC keyless signature via Sigstore transparency log |
| SBOM | Software Bill of Materials embedded in manifest |
| SLSA provenance | Build provenance attestation (level 2) |
