#!/usr/bin/env bash
# deploy-webhook.sh — Deploy webhook server to remote via ci-cd pipeline.
# Usage: bash scripts/deploy-webhook.sh
set -euo pipefail

SERVER="root@47.243.128.122"
PORT="10086"
REMOTE_DIR="/opt/livemask-webhook"
WEBHOOK_TOKEN="${WEBHOOK_TOKEN:-livemask-webhook-2026}"
CI_CD_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WEBHOOK_SRC="${CI_CD_DIR}/scripts/webhook-server.py"

echo "═══════════════════════════════════════════"
echo "  LIVEMASK CI/CD — Webhook Deploy"
echo "═══════════════════════════════════════════"
echo "  Target: ${SERVER}"
echo "  Port:   ${PORT}"
echo "  Source: ${WEBHOOK_SRC}"
echo ""

# Step 1: Verify source exists
if [[ ! -f "${WEBHOOK_SRC}" ]]; then
  echo "ERROR: webhook-server.py not found at ${WEBHOOK_SRC}"
  exit 1
fi

# Step 2: Verify SSH connectivity
echo "--- SSH Check ---"
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${SERVER}" "echo OK" 2>/dev/null; then
  echo "ERROR: Cannot SSH to ${SERVER}"
  exit 1
fi
echo "  SSH: OK"

# Step 3: Create remote directory structure
echo "--- Remote Setup ---"
ssh "${SERVER}" "mkdir -p ${REMOTE_DIR}/events" 2>/dev/null
echo "  Directory: OK"

# Step 4: Copy files
echo "--- Deploy Files ---"
scp "${WEBHOOK_SRC}" "${SERVER}:${REMOTE_DIR}/webhook-server.py" 2>/dev/null
echo "  webhook-server.py: deployed"

# Step 5: Create start script
ssh "${SERVER}" "cat > ${REMOTE_DIR}/start.sh << 'EOF'
#!/bin/bash
export WEBHOOK_TOKEN=\"${WEBHOOK_TOKEN}\"
export LARK_WEBHOOK_URL='https://open.larksuite.com/open-apis/bot/v2/hook/803303ee-1632-4a99-8847-a071b3c832ad'
export LARK_SIGN_KEY='maVOYNybtveyeOzS5f73td'
cd ${REMOTE_DIR}
pkill -f webhook-server.py 2>/dev/null || true
sleep 1
nohup python3 webhook-server.py --port ${PORT} > /var/log/livemask-webhook.log 2>&1 &
echo \"Webhook PID: \$!\"
EOF
chmod +x ${REMOTE_DIR}/start.sh" 2>/dev/null
echo "  start.sh: deployed"

# Step 6: Restart service
echo "--- Restart Service ---"
ssh "${SERVER}" "bash ${REMOTE_DIR}/start.sh" 2>&1
sleep 2

# Step 7: Verify
echo "--- Health Check ---"
if ssh "${SERVER}" "ps aux | grep webhook-server | grep -v grep" 2>/dev/null | grep -q python3; then
  echo "  Process: RUNNING"
else
  echo "  Process: NOT RUNNING — checking log..."
  ssh "${SERVER}" "tail -5 /var/log/livemask-webhook.log 2>/dev/null || echo 'No log'"
fi

# Local health check
if curl -sS --connect-timeout 3 "http://47.243.128.122:${PORT}/health" 2>/dev/null | grep -q healthy; then
  echo "  Endpoint: REACHABLE"
else
  echo "  Endpoint: UNREACHABLE — may need firewall rule: iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT"
fi

echo ""
echo "═══════════════════════════════════════════"
echo "  Deploy complete"
echo "  Lark URL: https://open.larksuite.com/open-apis/bot/v2/hook/803303ee-***"
echo "  Webhook:  http://47.243.128.122:${PORT}"
echo "  Log:      ssh ${SERVER} tail -f /var/log/livemask-webhook.log"
echo "═══════════════════════════════════════════"
