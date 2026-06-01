#!/usr/bin/env bash
# server-skill.sh — Remote server management via SSH.
# Server: root@47.243.128.122 (Debian, key-based auth)
set -euo pipefail

SERVER_HOST="${SERVER_HOST:-root@47.243.128.122}"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
WEBHOOK_PORT="${WEBHOOK_PORT:-10086}"
REMOTE_DIR="/opt/livemask-webhook"

# ── Deploy webhook server ───────────────────────────────────────────────
server_deploy_webhook() {
  echo "=== Deploying webhook server to ${SERVER_HOST} ==="
  
  # Create remote directory
  ssh ${SSH_OPTS} "${SERVER_HOST}" "mkdir -p ${REMOTE_DIR} ${REMOTE_DIR}/events" 2>/dev/null
  
  # Copy webhook server
  scp ${SSH_OPTS} "${CI_CD_DIR:-/Users/sammytan/Developer/LiveMask/livemask-ci-cd}/scripts/webhook-server.py" "${SERVER_HOST}:${REMOTE_DIR}/" 2>/dev/null
  
  echo "  Files copied to ${REMOTE_DIR}"
}

# ── Start webhook server ────────────────────────────────────────────────
server_start_webhook() {
  echo "=== Starting webhook server ==="
  
  # Kill existing instance
  ssh ${SSH_OPTS} "${SERVER_HOST}" "pkill -f webhook-server.py 2>/dev/null || true" 2>/dev/null
  sleep 1
  
  # Start with token
  ssh ${SSH_OPTS} "${SERVER_HOST}" "cd ${REMOTE_DIR} && WEBHOOK_TOKEN=${WEBHOOK_TOKEN:-livemask-webhook-2026} nohup python3 webhook-server.py --port ${WEBHOOK_PORT} > /var/log/livemask-webhook.log 2>&1 & echo \$!" 2>/dev/null
  
  echo "  Webhook server starting on port ${WEBHOOK_PORT}"
}

# ── Check webhook status ────────────────────────────────────────────────
server_status() {
  echo "=== Server Status ==="
  
  # Webhook process
  echo "  Webhook process:"
  ssh ${SSH_OPTS} "${SERVER_HOST}" "ps aux | grep webhook-server | grep -v grep || echo '    not running'" 2>/dev/null
  
  # Health check
  echo "  Health check:"
  curl -sS "http://${SERVER_HOST#*@}:${WEBHOOK_PORT}/health" 2>/dev/null || echo "    unreachable"
  
  # Disk
  echo "  Disk:"
  ssh ${SSH_OPTS} "${SERVER_HOST}" "df -h / | tail -1 | awk '{print \"    \"\$3\"/\"\$2\" (\"\$5\")\"}'" 2>/dev/null
  
  # Uptime
  echo "  Uptime:"
  ssh ${SSH_OPTS} "${SERVER_HOST}" "uptime" 2>/dev/null
}

# ── View webhook logs ───────────────────────────────────────────────────
server_logs() {
  local lines="${1:-50}"
  ssh ${SSH_OPTS} "${SERVER_HOST}" "tail -${lines} /var/log/livemask-webhook.log 2>/dev/null || echo 'No logs yet'" 2>/dev/null
}

# ── Restart webhook ─────────────────────────────────────────────────────
server_restart() {
  server_deploy_webhook
  server_start_webhook
  sleep 2
  server_status
}

# ── Fetch remote events to local ────────────────────────────────────────
server_fetch_events() {
  echo "=== Fetching remote events ==="
  local local_dir="${HOME}/.claude/role-cache/webhook-events"
  mkdir -p "${local_dir}"
  scp ${SSH_OPTS} "${SERVER_HOST}:${REMOTE_DIR}/events/*.jsonl" "${local_dir}/" 2>/dev/null && echo "  Events synced" || echo "  No events to sync"
}

echo "Server skill loaded: server_deploy_webhook, server_start_webhook, server_status, server_logs, server_restart, server_fetch_events"
