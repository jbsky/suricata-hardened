# Prompt : Construire suricata-hardened from scratch

## Contexte

Je veux construire une image Docker hardened pour Suricata 8 IPS, deployee sur VyOS en mode NFQUEUE. Le projet suit exactement le meme pattern que mon repo `~/stack-squid/` (voir `~/stack-squid/.opencode/skills/docker-hardener/SKILL.md` pour les conventions).

## Repos

- GitLab (origin) : `git@gitlab.home.arpa:docker/suricata.git`
- GitHub (github) : `git@github.com:jbsky/suricata-hardened.git`
- Repertoire local : `~/suricata-hardened/`

## Architecture cible

Deux images :
- **suricata-hardened** : image production FROM scratch, Suricata 8.0.2 compile from source
- **suricata-updater** : image Alpine ephemere (suricata-update + suricatasc) pour mise a jour des rules

## Decisions techniques

### Image principale (suricata-hardened)

- **4-stage Dockerfile** : builder (Alpine, compile Suricata + Rust) → gobuilder (Go init statique) → prep (runtime libs + tini-static + setcap) → FROM scratch
- **UID 8000:8000** (user `suricata`), jamais root
- **File capabilities** : `setcap 'cap_net_admin,cap_sys_nice+ep' /usr/bin/suricata` dans le stage prep (preservees par COPY dans scratch)
- **Go init binary** (`init.go`) avec 3 modes : `--setup-dirs` (build-time), `--healthcheck` (PID file check), default (config validation + syscall.Exec)
- **PID 1** : tini-static (pas tini regular pour eviter dep musl)
- **ENTRYPOINT** : `["/sbin/tini", "--", "/usr/local/bin/init"]`
- **CMD** : `["suricata", "-q", "0", "-q", "1", "-q", "2", "-q", "3", "--runmode", "workers"]`
- **Compiler flags** : `-O2 -fstack-protector-strong -fstack-clash-protection -fPIE -D_FORTIFY_SOURCE=2` + `-Wl,-z,relro,-z,now,-z,noexecstack -pie`
- **Healthcheck** : verifie existence du PID file + signal 0 au process

### Image updater (suricata-updater)

- Alpine + python3 + suricata-update (pip) + suricatasc
- UID 8000:8000
- Executee en ephemere (`podman run --rm`)
- Ecrit les rules dans le volume partage, puis reload via unix socket

### Deploiement VyOS

- Container avec `allow-host-networks` (obligatoire pour NFQUEUE)
- Capabilities : `net-admin` + `sys-nice`
- Volumes : config (ro), rules (ro), logs (rw), run (rw pour le unix socket)
- `restart on-failure`
- NFQUEUE rules dans `vyos-preconfig-bootup.script` : mark WAN (eth1 in/out) → NFQUEUE 0:3 avec `--queue-bypass`
- Script daily `suricata-update.sh` : podman run updater → suricatasc reload-rules → fallback restart

### CI

- `.gitlab-ci.yml` : lint (hadolint + shellcheck) → build (matrix 2 images) → sign (cosign OIDC) → scan (Trivy) → release (tarball sur tags)
- Pattern identique a `~/stack-squid/.gitlab-ci.yml`
- Proxy-aware : CA secret injection, APK split, BuildKit proxy env forwarding

## Structure fichiers

```
suricata-hardened/
├── .dockerignore
├── .env.example              # SURICATA_VERSION=8.0.2, ALPINE_VERSION=3.21
├── .gitignore
├── .gitlab-ci.yml
├── .hadolint.yaml            # ignore DL3018
├── AGENTS.md                 # doc operationnelle complete
├── Dockerfile                # 4-stage (builder, gobuilder, prep, scratch)
├── Makefile                  # build, build-updater, up, down, test, scan, clean
├── README.md
├── conf/suricata.yaml        # config reference NFQUEUE + unix-command socket
├── docker-compose.yml        # test local (pcap mode, pas NFQUEUE)
├── go.mod                    # module init, go 1.24, zero deps
├── init.go                   # Go static binary (setup-dirs + healthcheck + entrypoint)
├── scripts/
│   ├── check-versions.sh    # detection upstream OISF/suricata releases
│   └── test-alerts.sh       # validation container (healthcheck + no-shell)
├── updater/
│   └── Dockerfile            # Alpine + suricata-update
├── versions.json             # {"suricata": "8.0.2", "alpine": "3.21"}
└── vyos/
    ├── suricata-update.sh    # script VyOS daily (podman run updater + reload)
    └── vyos-container.config # commandes set VyOS
```

## Instructions

1. Charge le skill `docker-hardener` depuis `~/stack-squid/.opencode/skills/docker-hardener/SKILL.md` et suis la checklist
2. Cree le repertoire `~/suricata-hardened/`, init git, branche main
3. Implemente tous les fichiers selon l'architecture ci-dessus
4. Commit signe (`git commit -S`)
5. Push sur GitLab origin : `git@gitlab.home.arpa:docker/suricata.git`
6. Cree le repo GitHub avec `gh repo create jbsky/suricata-hardened --public` et push
7. Verifie que hadolint passe sur les Dockerfiles
8. Verifie que shellcheck passe sur les scripts

## References

- Pattern Dockerfile : `~/stack-squid/squid/Dockerfile` (4-stage exact)
- Pattern init.go : `~/stack-squid/squid/init.go` (memes helpers)
- Pattern CI : `~/stack-squid/.gitlab-ci.yml` (build-template + matrix)
- Pattern Makefile : `~/stack-squid/Makefile`
- Pattern versions : `~/stack-squid/versions.json` + `~/stack-squid/scripts/check-versions.sh`
- Conventions hardening : `~/stack-squid/.opencode/skills/docker-hardener/SKILL.md`
