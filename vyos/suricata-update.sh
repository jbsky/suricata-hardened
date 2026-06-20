#!/bin/bash
# =====================================================================
#  suricata-update.sh — VyOS task-scheduler script
#  Strategy: stop suricata → update rules (ephemeral) → start suricata
#  Traffic continues via --queue-bypass during the stop window (~30s)
# =====================================================================
set -euo pipefail

LOGFILE="/var/log/suricata-update.log"
TAG="suricata-update"
IMAGE="docker.io/jbsky/suricata-hardened:8.0.5"
RULES_DIR="/config/containers/suricata/rules"
CONFIG_DIR="/config/containers/suricata/etc"
RULES_FILE="$RULES_DIR/suricata.rules"

log() {
    local level="$1"; shift
    logger -t "$TAG" -p "user.${level}" "$*"
    echo "$(date '+%F %T') [$level] $*" | sudo tee -a "$LOGFILE" >/dev/null
}

log info "=== Mise à jour des règles Suricata ==="

# Save current rules timestamp for comparison
OLD_MTIME=$(stat -c %Y "$RULES_FILE" 2>/dev/null || echo 0)

# 1. Stop suricata (--queue-bypass keeps traffic flowing)
log info "Arrêt de Suricata (bypass actif)..."
sudo systemctl stop vyos-container-suricata.service || true

# 2. Update rules in ephemeral container
#    --network host: Internet access (safe: NFQUEUE queues are empty, no caps)
#    --user root: to rename suricata binary (file caps prevent exec without NET_ADMIN)
#    Note: suricata-update exits non-zero due to reload-command needing /bin/sh
#          (absent in FROM scratch). Rules are written BEFORE that error. We verify
#          success via file timestamp, not exit code.
log info "Téléchargement des règles..."

UPDATE_ARGS="update -f --no-test --suricata-conf /etc/suricata/suricata.yaml --output /var/lib/suricata/rules"
[ -f "$CONFIG_DIR/disable.conf" ] && UPDATE_ARGS="$UPDATE_ARGS --disable-conf /etc/suricata/disable.conf"
[ -f "$CONFIG_DIR/modify.conf" ] && UPDATE_ARGS="$UPDATE_ARGS --modify-conf /etc/suricata/modify.conf"

sudo podman run --rm --user root --network host --memory 1g \
    -v "$RULES_DIR":/var/lib/suricata/rules \
    -v "$CONFIG_DIR":/etc/suricata:ro \
    --entrypoint python3 "$IMAGE" \
    -c "
import os, sys
os.rename('/usr/bin/suricata', '/usr/bin/suricata.bak')
os.execvp('suricata-update', ['suricata-update'] + sys.argv[1].split())
" "$UPDATE_ARGS" 2>&1 | sudo tee -a "$LOGFILE" || true

# Verify rules were actually updated (timestamp changed)
NEW_MTIME=$(stat -c %Y "$RULES_FILE" 2>/dev/null || echo 0)
if [ "$NEW_MTIME" -le "$OLD_MTIME" ]; then
    log error "Rules non mises à jour (fichier inchangé). Redémarrage anciennes règles."
    sudo systemctl start vyos-container-suricata.service
    exit 2
fi

# 3. Start with new rules
log info "Démarrage Suricata..."
sudo systemctl start vyos-container-suricata.service || { log error "Échec start!"; exit 3; }

# 4. Verify
sleep 15
if sudo podman ps --format '{{.Names}}' | grep -qx suricata; then
    DROPS=$(grep -c '^drop ' "$RULES_FILE" 2>/dev/null || echo 0)
    ALERTS=$(grep -c '^alert ' "$RULES_FILE" 2>/dev/null || echo 0)
    log info "OK. Rules: $DROPS drop, $ALERTS alert."
else
    log error "Suricata non démarré!"
    exit 4
fi
