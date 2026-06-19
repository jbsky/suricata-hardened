#!/bin/bash
# =====================================================================
#  suricata-update.sh — VyOS task-scheduler script
#  Runs suricata-update in ephemeral container, reloads rules via socket
# =====================================================================
set -euo pipefail

LOGFILE="/var/log/suricata-update.log"
TAG="suricata-update"
RULES_DIR="/config/containers/suricata/rules"
CONFIG_DIR="/config/containers/suricata/etc"
RUN_DIR="/run/suricata"
UPDATER_IMAGE="docker.io/jbsky/suricata-updater:latest"
CONTAINER="suricata"

log() {
    local level="$1"; shift
    local msg="$*"
    logger -t "$TAG" -p "user.${level}" "$msg"
    echo "$(date '+%F %T') - $msg" | sudo tee -a "$LOGFILE" >/dev/null
}

log info "=== Mise à jour des règles Suricata ==="

# Verify main container is running
if ! sudo podman ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    log error "Erreur : conteneur '$CONTAINER' introuvable."
    exit 1
fi

# Run updater in ephemeral container
# --network host: required for DNS resolution (updater has no proxy config)
# entrypoint is suricata-update, so pass subcommand args directly
log info "Exécution de suricata-update..."
if ! sudo podman run --rm --network host \
    -v "$RULES_DIR":/var/lib/suricata/rules \
    -v "$CONFIG_DIR":/etc/suricata:ro \
    "$UPDATER_IMAGE" \
    update -f --no-test \
        --suricata-conf /etc/suricata/suricata.yaml \
        --output /var/lib/suricata/rules 2>&1 | sudo tee -a "$LOGFILE"; then
    log error "Échec de suricata-update."
    exit 2
fi

# Reload rules via unix socket (no restart needed)
# Override entrypoint to run suricatasc instead of suricata-update
log info "Rechargement des règles via socket..."
if sudo podman run --rm \
    --entrypoint suricatasc \
    -v "$RUN_DIR":/var/run/suricata \
    "$UPDATER_IMAGE" \
    -c reload-rules /var/run/suricata/suricata-command.socket 2>&1 | sudo tee -a "$LOGFILE"; then
    log info "Règles rechargées avec succès (hot reload)."
else
    log warning "Reload via socket échoué, restart du conteneur..."
    if /opt/vyatta/bin/vyatta-op-cmd-wrapper restart container "$CONTAINER" 2>&1 | sudo tee -a "$LOGFILE"; then
        log info "Conteneur redémarré avec succès."
    else
        log error "Erreur lors du redémarrage."
        exit 3
    fi
fi

log info "Mise à jour terminée avec succès."
