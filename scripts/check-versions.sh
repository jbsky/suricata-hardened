#!/bin/sh
# =====================================================================
#  check-versions.sh — Detect new upstream Suricata releases
#  Source: GitHub API (OISF/suricata)
#
#  Usage: ./scripts/check-versions.sh [--update]
#    Without --update: prints diff only (exit 0 = no change, exit 2 = updates available)
#    With --update: writes changes to versions.json + Dockerfile + .env.example
# =====================================================================
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSIONS_FILE="${ROOT_DIR}/versions.json"

UPDATE=false
[ "${1:-}" = "--update" ] && UPDATE=true

# --- Helpers ---
die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

# Extract latest stable Suricata release from GitHub
suricata_latest() {
  url="https://api.github.com/repos/OISF/suricata/releases?per_page=20"
  version=$(curl -fsSL --retry 3 "$url" 2>/dev/null \
    | grep '"tag_name"' | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"//;s/".*//' \
    | grep -E '^suricata-[0-9]+\.[0-9]+\.[0-9]+$' | head -1 \
    | sed 's/^suricata-//')

  if [ -z "$version" ]; then
    # Fallback: tags
    url="https://api.github.com/repos/OISF/suricata/tags?per_page=50"
    version=$(curl -fsSL --retry 3 "$url" 2>/dev/null \
      | grep '"name"' | sed 's/.*"name"[[:space:]]*:[[:space:]]*"//;s/".*//' \
      | grep -E '^suricata-[0-9]+\.[0-9]+\.[0-9]+$' | head -1 \
      | sed 's/^suricata-//')
  fi

  [ -z "$version" ] && return 1
  echo "$version"
}

# --- Read current versions ---
current_suricata=$(grep '"suricata"' "$VERSIONS_FILE" | sed 's/.*: *"//;s/".*//')

# --- Fetch latest ---
printf 'Checking upstream versions...\n'
latest_suricata=$(suricata_latest) || latest_suricata="$current_suricata"

# --- Compare ---
CHANGES=""

if [ "$current_suricata" != "$latest_suricata" ]; then
  printf '  %-14s %s → %s\n' "suricata" "$current_suricata" "$latest_suricata"
  CHANGES="suricata"
else
  printf '  %-14s %s (up to date)\n' "suricata" "$current_suricata"
fi

if [ -z "$CHANGES" ]; then
  printf '\nAll versions are up to date.\n'
  exit 0
fi

printf '\nUpdates available: %s\n' "$CHANGES"

if [ "$UPDATE" = false ]; then
  exit 2
fi

# --- Apply updates ---
printf 'Applying updates...\n'

# 1. versions.json
current_alpine=$(grep '"alpine"' "$VERSIONS_FILE" | sed 's/.*: *"//;s/".*//')
cat > "$VERSIONS_FILE" <<EOF
{
  "suricata": "${latest_suricata}",
  "alpine": "${current_alpine}"
}
EOF

# 2. Dockerfile ARG default
sed -i "s/^ARG SURICATA_VERSION=.*/ARG SURICATA_VERSION=${latest_suricata}/" "${ROOT_DIR}/Dockerfile"

# 3. .env.example
sed -i "s/^SURICATA_VERSION=.*/SURICATA_VERSION=${latest_suricata}/" "${ROOT_DIR}/.env.example"

printf 'Done. Files updated:\n'
printf '  - versions.json\n'
printf '  - Dockerfile\n'
printf '  - .env.example\n'
