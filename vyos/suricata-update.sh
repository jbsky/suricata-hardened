#!/bin/bash
# =====================================================================
#  suricata-update.sh — VyOS task-scheduler script
#  Runs suricata-update inside the running container, reloads via socket
# =====================================================================
set -euo pipefail

LOGFILE="/var/log/suricata-update.log"
TAG="suricata-update"
CONTAINER="suricata"

log() {
    local level="$1"; shift
    local msg="$*"
    logger -t "$TAG" -p "user.${level}" "$msg"
    echo "$(date '+%F %T') - $msg" | sudo tee -a "$LOGFILE" >/dev/null
}

log info "=== Mise à jour des règles Suricata ==="

# Verify container is running
if ! sudo podman ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    log error "Erreur : conteneur '$CONTAINER' introuvable."
    exit 1
fi

# Run suricata-update inside the running container
log info "Exécution de suricata-update..."
if ! sudo podman exec "$CONTAINER" \
    suricata-update update -f --no-test \
        --suricata-conf /etc/suricata/suricata.yaml \
        --output /var/lib/suricata/rules 2>&1 | sudo tee -a "$LOGFILE"; then
    log error "Échec de suricata-update."
    exit 2
fi

# Reload rules via suricatasc (hot reload, no restart)
log info "Rechargement des règles via socket..."
if sudo podman exec "$CONTAINER" \
    suricatasc -c reload-rules /var/run/suricata/suricata-command.socket 2>&1 | sudo tee -a "$LOGFILE"; then
    log info "Règles rechargées avec succès (hot reload)."
else
    log warning "Reload via socket échoué, restart du conteneur..."
    if sudo systemctl restart vyos-container-suricata.service 2>&1 | sudo tee -a "$LOGFILE"; then
        log info "Conteneur redémarré avec succès."
    else
        log error "Erreur lors du redémarrage."
        exit 3
    fi
fi

log info "Mise à jour terminée avec succès."
