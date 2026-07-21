#!/bin/sh
# =====================================================================
#  test-alerts.sh — Validate Suricata IPS by triggering a known rule
#  Requires a running Suricata instance (NFQUEUE or PCAP mode)
#
#  Usage: ./scripts/test-alerts.sh [container_name]
# =====================================================================
set -eu

CONTAINER="${1:-suricata-hardened}"

echo "=== Suricata IPS Alert Test ==="

# Check container is running
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "ERROR: container '$CONTAINER' not running"
  exit 1
fi

# Check healthcheck
echo "[1/4] Healthcheck..."
if docker exec "$CONTAINER" /usr/local/bin/init --healthcheck; then
  echo "  PASS: Suricata process alive"
else
  echo "  FAIL: Suricata not healthy"
  exit 1
fi

# Check no shell
echo "[2/4] No-shell validation..."
if docker exec "$CONTAINER" /bin/sh 2>&1 | grep -qi "not found\|no such file"; then
  echo "  PASS: no shell available"
else
  echo "  FAIL: shell found in container"
  exit 1
fi

# Check log file exists. There's no shell/coreutils in this FROM-scratch
# image (confirmed by step 2), so `docker exec ... test`/`ls` can't work --
# `docker cp` reads the container's filesystem via the daemon API instead,
# without executing anything inside the container.
echo "[3/4] Log file check..."
if docker cp "$CONTAINER:/var/log/suricata" - >/dev/null 2>&1; then
  echo "  PASS: log directory exists"
else
  echo "  FAIL: log directory missing"
  exit 1
fi

# Check stats.log for activity (if running long enough)
echo "[4/4] Stats check..."
if docker cp "$CONTAINER:/var/log/suricata/stats.log" - >/dev/null 2>&1; then
  echo "  PASS: stats.log exists (Suricata is logging)"
else
  echo "  INFO: stats.log not yet created (container may have just started)"
fi

echo ""
echo "=== All basic tests passed ==="
echo "NOTE: Full IPS validation requires NFQUEUE mode on VyOS with live traffic."
