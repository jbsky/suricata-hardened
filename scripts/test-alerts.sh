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
echo "[1/6] Healthcheck..."
if docker exec "$CONTAINER" /usr/local/bin/init --healthcheck; then
  echo "  PASS: Suricata process alive"
else
  echo "  FAIL: Suricata not healthy"
  exit 1
fi

# Check no shell
echo "[2/6] No-shell validation..."
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
echo "[3/6] Log file check..."
if docker cp "$CONTAINER:/var/log/suricata" - >/dev/null 2>&1; then
  echo "  PASS: log directory exists"
else
  echo "  FAIL: log directory missing"
  exit 1
fi

# Check stats.log for activity (if running long enough)
echo "[4/6] Stats check..."
if docker cp "$CONTAINER:/var/log/suricata/stats.log" - >/dev/null 2>&1; then
  echo "  PASS: stats.log exists (Suricata is logging)"
else
  echo "  INFO: stats.log not yet created (container may have just started)"
fi

# The image's dependency closure travels through busybox tar, which has no
# xattr support: cap_net_admin reaches the final image only because
# /usr/bin/suricata gets a COPY of its own. Nothing else here would notice if
# that stopped being true -- this compose stack grants NET_ADMIN to the
# container (cap_add), so Suricata starts and stays healthy either way, and the
# failure surfaces only on the router, at NFQUEUE bind time. `docker cp`
# streams a tar carrying PAX xattr headers, so the capability is readable
# without root and without a shell in the image.
echo "[5/6] File capability on the suricata binary..."
if docker cp "$CONTAINER:/usr/bin/suricata" - 2>/dev/null \
   | grep -aq 'SCHILY.xattr.security.capability'; then
  echo "  PASS: file capability present on /usr/bin/suricata"
else
  echo "  FAIL: /usr/bin/suricata has no file capability -- NFQUEUE would fail on the router"
  exit 1
fi

# suricata-update is a Python program running on a hand-assembled Python tree:
# the build prunes stdlib modules and C extensions, and Suricata itself never
# touches Python, so every test above passes on an image whose interpreter is
# broken. Ten lib-dynload modules once shipped unimportable without a single
# test going red. `--help` is enough: it walks the real import chain.
echo "[6/6] suricata-update import chain..."
if docker exec "$CONTAINER" suricata-update --help >/dev/null 2>&1; then
  echo "  PASS: suricata-update starts"
else
  echo "  FAIL: suricata-update cannot start"
  docker exec "$CONTAINER" suricata-update --help 2>&1 | tail -20
  exit 1
fi

echo ""
echo "=== All basic tests passed ==="
echo "NOTE: Full IPS validation requires NFQUEUE mode on VyOS with live traffic."
