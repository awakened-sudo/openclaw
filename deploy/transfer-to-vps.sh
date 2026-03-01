#!/usr/bin/env bash
# Parliament Twin - Transfer files from Mac to VPS
# Run this on your Mac after VPS setup is complete.
#
# Prerequisites:
#   - Tailscale connected (ssh parliament@parliament-twin works)
#   - VPS setup script already run
#
# Usage:
#   ./deploy/transfer-to-vps.sh [hostname]
#   ./deploy/transfer-to-vps.sh parliament-twin
#
set -euo pipefail

VPS_HOST="${1:-parliament-twin}"
VPS_USER="parliament"
REMOTE="${VPS_USER}@${VPS_HOST}"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_DIR="/Users/ifzat/parliament_twin/parliament-twin/workspaces"
LOCAL_CONFIG="$HOME/.openclaw/openclaw.json"
LOCAL_CRON="$HOME/.openclaw/cron/jobs.json"
DEPLOY_DIR="$REPO_DIR/deploy"

echo "=== Parliament Twin - Transfer to VPS ==="
echo "Target: ${REMOTE}"
echo "Repo:   ${REPO_DIR}"
echo ""

# --- 1. Clone repo on VPS ---
echo "[1/6] Cloning repo on VPS..."
ssh "${REMOTE}" bash -s <<'CLONE_EOF'
set -euo pipefail
if [ ! -d /opt/parliament-twin/openclaw/.git ]; then
  cd /opt/parliament-twin
  git clone https://github.com/awakened-sudo/openclaw.git openclaw
  cd openclaw
  git checkout awakened-sudo/repo-analysis
  echo "Repo cloned and checked out."
else
  cd /opt/parliament-twin/openclaw
  git fetch origin
  git checkout awakened-sudo/repo-analysis
  git pull origin awakened-sudo/repo-analysis --ff-only || true
  echo "Repo updated."
fi
CLONE_EOF

# --- 2. Transfer workspace files ---
# The parent dir (parliament-twin/) mounts as /data/workspace in the container.
# Agent workspaces live at /data/workspace/workspaces/{agent}/.
echo "[2/7] Transferring workspace parent directory..."
rsync -avz --progress \
  --exclude='.DS_Store' \
  --exclude='node_modules/' \
  "$HOME/parliament_twin/parliament-twin/" \
  "${REMOTE}:/opt/parliament-twin/workspaces/"

# --- 3. Transfer server config ---
echo "[3/7] Transferring server config..."
scp "${DEPLOY_DIR}/openclaw-server.json" \
  "${REMOTE}:/opt/parliament-twin/openclaw-state/openclaw.json"

# --- 4. Transfer cron jobs ---
echo "[4/7] Transferring cron jobs..."
scp "${LOCAL_CRON}" \
  "${REMOTE}:/opt/parliament-twin/openclaw-state/cron/jobs.json"

# --- 5. Transfer docker-compose override ---
echo "[5/7] Transferring docker-compose.override.yml..."
scp "${DEPLOY_DIR}/docker-compose.override.yml" \
  "${REMOTE}:/opt/parliament-twin/openclaw/docker-compose.override.yml"

# --- 6. Inject bot tokens + create .env ---
echo "[6/7] Injecting bot tokens and creating .env..."

# Extract secrets from local config
SPEAKER_TOKEN=$(python3 -c "import json; d=json.load(open('$LOCAL_CONFIG')); print(d['channels']['telegram']['accounts']['speaker']['botToken'])")
PM_TOKEN=$(python3 -c "import json; d=json.load(open('$LOCAL_CONFIG')); print(d['channels']['telegram']['accounts']['pm']['botToken'])")
P022_TOKEN=$(python3 -c "import json; d=json.load(open('$LOCAL_CONFIG')); print(d['channels']['telegram']['accounts']['mp-p022']['botToken'])")
P019_TOKEN=$(python3 -c "import json; d=json.load(open('$LOCAL_CONFIG')); print(d['channels']['telegram']['accounts']['mp-p019']['botToken'])")
P160_TOKEN=$(python3 -c "import json; d=json.load(open('$LOCAL_CONFIG')); print(d['channels']['telegram']['accounts']['mp-p160']['botToken'])")
P197_TOKEN=$(python3 -c "import json; d=json.load(open('$LOCAL_CONFIG')); print(d['channels']['telegram']['accounts']['mp-p197']['botToken'])")
P074_TOKEN=$(python3 -c "import json; d=json.load(open('$LOCAL_CONFIG')); print(d['channels']['telegram']['accounts']['mp-p074']['botToken'])")
GW_TOKEN=$(python3 -c "import json; d=json.load(open('$LOCAL_CONFIG')); print(d['gateway']['auth']['token'])")
GOOGLE_KEY=$(python3 -c "import json; d=json.load(open('$LOCAL_CONFIG')); print(d['models']['providers']['google']['apiKey'])")

# Prompt for OpenAI key (not stored in config as plaintext)
read -rsp "Enter OPENAI_API_KEY (paste, then Enter): " OPENAI_KEY
echo ""

# Inject bot tokens into server config on VPS
ssh "${REMOTE}" bash -s <<TOKEN_EOF
set -euo pipefail
cd /opt/parliament-twin/openclaw-state
sed -i "s|REPLACE_SPEAKER_BOT_TOKEN|${SPEAKER_TOKEN}|g" openclaw.json
sed -i "s|REPLACE_PM_BOT_TOKEN|${PM_TOKEN}|g" openclaw.json
sed -i "s|REPLACE_MP_P022_BOT_TOKEN|${P022_TOKEN}|g" openclaw.json
sed -i "s|REPLACE_MP_P019_BOT_TOKEN|${P019_TOKEN}|g" openclaw.json
sed -i "s|REPLACE_MP_P160_BOT_TOKEN|${P160_TOKEN}|g" openclaw.json
sed -i "s|REPLACE_MP_P197_BOT_TOKEN|${P197_TOKEN}|g" openclaw.json
sed -i "s|REPLACE_MP_P074_BOT_TOKEN|${P074_TOKEN}|g" openclaw.json
chmod 600 openclaw.json
echo "Bot tokens injected."
TOKEN_EOF

# Create .env on VPS with all secrets
ssh "${REMOTE}" bash -s <<ENV_EOF
cat > /opt/parliament-twin/openclaw/.env << 'INNER_EOF'
OPENCLAW_GATEWAY_TOKEN=${GW_TOKEN}
OPENAI_API_KEY=${OPENAI_KEY}
GOOGLE_AI_API_KEY=${GOOGLE_KEY}
OPENCLAW_CONFIG_DIR=/opt/parliament-twin/openclaw-state
OPENCLAW_WORKSPACE_DIR=/opt/parliament-twin/workspaces
OPENCLAW_GATEWAY_PORT=18789
INNER_EOF
chmod 600 /opt/parliament-twin/openclaw/.env
echo ".env created and secured."
ENV_EOF

# --- 7. Fix ownership ---
echo "[7/7] Fixing ownership for container user (uid 1000)..."
ssh "${REMOTE}" 'sudo chown -R 1000:1000 /opt/parliament-twin/openclaw-state /opt/parliament-twin/workspaces'

echo ""
echo "=== Transfer complete ==="
echo ""
echo "Next steps on VPS (ssh ${REMOTE}):"
echo "  1. Build:     cd /opt/parliament-twin/openclaw && docker compose build"
echo "  2. Launch:    docker compose up -d"
echo "  3. Logs:      docker compose logs -f openclaw-gateway"
echo "  4. Tailscale: sudo tailscale serve --bg https+insecure://127.0.0.1:18789"
echo ""
echo "CRITICAL: Stop local Mac gateway BEFORE VPS gateway starts polling Telegram!"
echo "  launchctl bootout gui/\$(id -u)/ai.openclaw.gateway"
