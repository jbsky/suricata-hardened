# suricata-hardened

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
