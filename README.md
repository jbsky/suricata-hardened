# Suricata Hardened

[![Build](https://github.com/jbsky/suricata-hardened/actions/workflows/build-push.yml/badge.svg)](https://github.com/jbsky/suricata-hardened/actions/workflows/build-push.yml)
[![Docker Hub](https://img.shields.io/docker/v/jbsky/suricata-hardened?sort=semver&label=Docker%20Hub)](https://hub.docker.com/r/jbsky/suricata-hardened)
[![Hardening](https://img.shields.io/badge/hardening-platine-blueviolet)](https://github.com/jbsky/suricata-hardened#security--verification)

Image Docker Suricata 8 IPS hardenee (FROM scratch, Go init, tini PID 1), optimisee pour deploiement VyOS NFQUEUE.

## Features

| Feature | Detail |
|---------|--------|
| FROM scratch | Zero shell, zero package manager, zero attack surface |
| Non-root | uid 8000 avec file capabilities (`cap_net_admin,cap_sys_nice+ep`) |
| Compiler hardening | RELRO, PIE, SSP, FORTIFY_SOURCE, NX |
| Go static init | Healthcheck + config validation + setup-dirs (no shell) |
| tini PID 1 | Signal forwarding + zombie reaping |
| NFQUEUE IPS | 4 queues, workers runmode, optimise VyOS |
| Hot rule reload | Via unix socket (zero downtime updates) |

## Tags

Trois tags par image : `latest` (dernier build de `main`), la version amont
seule, et la version amont suffixee d'un **compteur de revision**. Les deux
premiers sont **reecrits en place** a chaque rebuild -- bump Alpine, correctif
CVE, changement de config -- et le build qu'ils designaient devient alors
inaccessible. **En production, epinglez le tag qui porte le compteur.**

<!-- BEGIN:tags (genere par la CI -- ne pas editer a la main) -->
| Image | Version amont | Tag immuable a epingler |
|-------|---------------|-------------------------|
| `jbsky/suricata-hardened` | `8.0.6` | `8.0.6.20` |
<!-- END:tags -->

Le compteur compte les commits qui touchent les inputs declares (`Dockerfile`, `scripts/`, `versions.json`)
depuis le dernier changement de version amont, et repart a `0` a chaque nouvelle
version amont. Un commit qui ne touche que `.github/` ne l'incremente pas.

Les deux registres, `docker.io` et `ghcr.io`, publient les memes tags avec le
meme digest.

`suricata-update` et `suricatasc` sont embarques dans l'image depuis la 8.0.5 :
l'ancienne image separee `jbsky/suricata-updater` est obsolete.

## Usage rapide

```bash
cp .env.example .env
make build   # Build l'image
make up      # Demarre Suricata en mode IPS
make test    # Smoke tests (healthcheck + alert detection)
make scan    # Trivy vulnerability scan
make down    # Arrete
```

## Deploiement VyOS

Voir `vyos/vyos-container.config` pour les commandes VyOS completes et `vyos/suricata-update.sh` pour le script de mise a jour quotidienne des regles.

```bash
# Appliquer la config container sur VyOS
configure
# ... (coller les commandes de vyos/vyos-container.config)
commit
save
```

## Architecture

```
suricata-hardened/
├── Dockerfile              # Multi-stage (Alpine builder → FROM scratch)
├── docker-compose.yml      # Stack hardenee
├── Makefile                # Raccourcis dev
├── versions.json           # Versions trackees (Suricata, Alpine)
├── go.mod + init.go        # Go static init binary
├── conf/
│   └── suricata.yaml       # Config Suricata (NFQUEUE, workers, thresholds)
├── updater/
│   └── Dockerfile          # Image ephemere suricata-update
├── vyos/
│   ├── vyos-container.config   # Commandes VyOS container
│   └── suricata-update.sh      # Cron daily rule update
├── scripts/
│   ├── check-versions.sh  # Detection version upstream
│   └── test-alerts.sh     # Test de detection (ET rules)
└── .github/
    ├── dependabot.yml      # Weekly GH Actions + Docker updates
    └── workflows/
        ├── build-push.yml      # Build + sign + scan + release
        ├── version-watch.yml   # Daily OISF/suricata release detection
        └── security-audit.yml  # Weekly Trivy + Grype + cosign verify
```

## CI/CD

Dual pipeline (GitLab + GitHub Actions) :

| Stage | Description |
|-------|-------------|
| lint | hadolint |
| build | buildx + push (ghcr.io + Docker Hub) |
| sign | cosign keyless OIDC |
| scan | Trivy SARIF |
| attest | SBOM + SLSA provenance (level 2) |
| version-watch | Cron quotidien — rebuild auto sur nouvelle version Suricata |
| security-audit | Cron hebdomadaire — scan vulnerabilites + verification cosign |

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

### Known Security Exceptions

See [SECURITY.md](SECURITY.md) for the current status of the weekly Trivy/Grype audit,
including CVEs that are suppressed with a documented reason (e.g. code paths that are
present in a bundled runtime but never exercised by this image) versus ones still
genuinely blocked pending an upstream release.

## License

GPL-2.0-only (same as Suricata)
