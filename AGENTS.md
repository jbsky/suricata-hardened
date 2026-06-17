# AGENTS.md

## What this is

Hardened Suricata IPS container image built from source (multi-stage, FROM scratch, non-root, file capabilities, RELRO/PIE). Designed for NFQUEUE mode deployment on VyOS.

## Architecture

Two images:
- **suricata-hardened** — Production IPS engine (FROM scratch, uid 8000, file caps NET_ADMIN+SYS_NICE)
- **suricata-updater** — Ephemeral Alpine container for rule updates via `suricata-update` + `suricatasc`

## VyOS production deployment

Suricata runs with `allow-host-networks` (required for NFQUEUE access to host netfilter). Traffic inspection is WAN-only (eth1 in/out).

| Component | Details |
|-----------|---------|
| Image | `docker.io/jbsky/suricata-hardened:8.0.2` |
| Mode | NFQUEUE IPS (queues 0-3, workers runmode) |
| Memory | 1536 MB |
| Capabilities | NET_ADMIN (verdicts) + SYS_NICE (CPU affinity) |
| User | 8000:8000 (suricata), never root |
| Config | `/config/containers/suricata/etc/` (ro) |
| Rules | `/config/containers/suricata/rules/` (ro) |
| Logs | `/var/log/suricata/` (rw) |
| Socket | `/run/suricata/` (rw, for suricatasc reload) |

### NFQUEUE rules (vyos-preconfig-bootup.script)

```bash
iptables -t mangle -A FORWARD -i eth1 -j MARK --set-mark 10
iptables -t mangle -A FORWARD -o eth1 -j MARK --set-mark 10
iptables -t mangle -A POSTROUTING -m mark --mark 10 -j NFQUEUE \
  --queue-balance 0:3 --queue-cpu-fanout --queue-bypass
```

`--queue-bypass` ensures WAN continues working if Suricata is down.

## Key commands

```bash
cp .env.example .env               # required before first run
make build                          # build suricata-hardened image
make build-updater                  # build suricata-updater image
make up                             # start container (pcap mode for local testing)
make test                           # healthcheck + no-shell validation
make scan                           # trivy scan
make clean                          # cleanup
```

## Image build pattern

4-stage multi-stage Dockerfile:
1. **builder** (Alpine 3.21) — Compile Suricata 8.x from source with Rust + hardened CFLAGS
2. **gobuilder** (golang:1.24-alpine) — Static Go init binary (entrypoint + healthcheck + setup-dirs)
3. **prep** (Alpine 3.21) — Runtime libs, tini-static, user 8000, `setcap` on suricata binary
4. **FROM scratch** — Cherry-pick files, zero shell, zero package manager

## Non-root + file capabilities

The container runs entirely as uid 8000. NET_ADMIN + SYS_NICE are provided via:
- **Podman bounding set**: VyOS `capability "net-admin"` + `capability "sys-nice"`
- **File capabilities**: `setcap 'cap_net_admin,cap_sys_nice+ep' /usr/bin/suricata` (set in prep stage, preserved by COPY)

No process ever runs as root inside the container.

## Rule updates (zero-downtime)

```bash
# On VyOS (via task-scheduler daily):
/config/scripts/suricata-update.sh

# Flow:
# 1. podman run --rm suricata-updater → writes rules to shared volume
# 2. suricatasc reload-rules via unix socket → hot reload
# 3. If reload fails → fallback: restart container suricata
```

## CI pipelines

**GitLab CI** (`.gitlab-ci.yml`): lint → build (2 images) → cosign sign → Trivy scan → release tarball on tags.

**GitHub Actions** (`.github/workflows/build-push.yml`): lint → build → sign → scan → SLSA attestation (on tags only).

## Secrets and generated files

- `.env` — gitignored, copy from `.env.example`
- No CA/certs needed (Suricata doesn't do TLS termination)

## Deployment gotchas

### NFQUEUE requires host network namespace

`allow-host-networks` is mandatory. Without it, Suricata cannot access the host's netfilter queues. This is by design — NFQUEUE operates on packets traversing the host's network stack.

### File capabilities and COPY

Docker/Podman `COPY` preserves extended attributes (xattr), which includes file capabilities set via `setcap`. The capability survives the multi-stage build FROM scratch copy.

### Volumes must be owned by uid 8000

On VyOS, create host directories with correct ownership:
```bash
sudo mkdir -p /config/containers/suricata/{etc,rules}
sudo mkdir -p /var/log/suricata /run/suricata
sudo chown -R 8000:8000 /var/log/suricata /run/suricata
```

Config and rules volumes are mounted read-only — ownership doesn't matter for those.

### suricata-update needs the full config

The updater container mounts `/config/containers/suricata/etc/` as `/etc/suricata:ro` because `suricata-update` reads `suricata.yaml` to determine rule paths and enabled decoders.

### Unix socket for reload

The socket at `/var/run/suricata/suricata-command.socket` is created by Suricata at startup. The updater container needs access to this socket via the shared `/run/suricata` volume.

### Rust compilation time

Suricata 8.x requires Rust for several protocol parsers. The builder stage takes ~15-20 minutes on amd64. Use registry cache (`--cache-from/--cache-to`) in CI.

## Linting

```bash
hadolint Dockerfile updater/Dockerfile
shellcheck scripts/*.sh vyos/suricata-update.sh
```

## Version management

`versions.json` is the single source of truth. `scripts/check-versions.sh --update` propagates changes to Dockerfile ARG and .env.example.
