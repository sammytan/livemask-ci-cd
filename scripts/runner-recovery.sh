#!/usr/bin/env bash
# =============================================================================
# TASK-CICD-RUNNER-BACKLOG-001 — Runner Recovery Script
#
# Run directly on the runner SERVER (via SSH or console) to recover stuck
# self-hosted runner agents.
#
# Usage on the runner server:
#   sudo bash /path/to/runner-recovery.sh
#
# Or from any machine that can SSH:
#   ssh <runner-server> "sudo bash -s" < scripts/runner-recovery.sh
# =============================================================================
set -euo pipefail

echo "============================================"
echo " LiveMask CI/CD Runner Recovery"
echo " $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo "============================================"

# ── Pre-checks ──────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "WARNING: Not running as root. 'systemctl restart' requires sudo."
  echo "Prefer: sudo bash $0"
fi

# ── 1. Snapshot current state ───────────────────────────────────────────────
echo ""
echo "=== Systemd runner services ==="
systemctl list-units '*actions*' --type=service --no-pager 2>&1

echo ""
echo "=== Runner agent processes ==="
ps aux | grep -iE 'runsvc|Runner\.Listener|run\.sh' | grep -v grep || echo "(no runner processes found — both agents may be dead)"

echo ""
echo "=== Runner working dirs ==="
ls -la /opt/actions-runner/*/ 2>&1 | head -30

echo ""
echo "=== Stale worktrees (older than 1 hour) ==="
find /opt/actions-runner -path '*/_work/*' -maxdepth 2 -type d -mmin +60 2>/dev/null | head -20

# ── 2. Restart both runners ─────────────────────────────────────────────────
echo ""
echo "=== Restarting CI runner ==="
sudo systemctl restart actions.runner.MyAiDevs.livemask-ci-runner-01.service 2>&1 || {
  echo "FALLBACK: systemctl restart failed. Trying direct svc.sh..."
  cd /opt/actions-runner/livemask-ci && sudo ./svc.sh stop 2>/dev/null; sudo ./svc.sh start 2>/dev/null || true
}

echo ""
echo "=== Restarting Staging runner ==="
sudo systemctl restart actions.runner.MyAiDevs.livemask-staging-runner-01.service 2>&1 || {
  echo "FALLBACK: systemctl restart failed. Trying direct svc.sh..."
  cd /opt/actions-runner/livemask-staging && sudo ./svc.sh stop 2>/dev/null; sudo ./svc.sh start 2>/dev/null || true
}

# ── 3. Wait for agents to register ──────────────────────────────────────────
echo ""
echo "=== Waiting for runners to come online (10s) ==="
sleep 10
systemctl status actions.runner.MyAiDevs.livemask-ci-runner-01.service --no-pager -l 2>&1 | head -15
echo ""
systemctl status actions.runner.MyAiDevs.livemask-staging-runner-01.service --no-pager -l 2>&1 | head -15

# ── 4. Clean stale worktrees ────────────────────────────────────────────────
echo ""
echo "=== Cleaning stale worktrees (>2h old) ==="
find /opt/actions-runner -path '*/_work/*' -maxdepth 2 -type d -mmin +120 2>/dev/null \
  -exec echo "Removing stale: {}" \; -exec rm -rf {} \; 2>/dev/null || true

# ── 5. Disk & Docker cleanup ────────────────────────────────────────────────
echo ""
echo "=== Docker system prune (safe, non-interactive) ==="
docker system prune -f 2>&1 || true

echo ""
echo "=== Disk usage ==="
df -h / /opt 2>/dev/null || df -h /

echo ""
echo "============================================"
echo " Recovery actions complete."
echo ""
echo " Verify from any Cursor window:"
echo "   gh api '/orgs/MyAiDevs/actions/runners' -q '.runners[] | {name, status, busy}'"
echo ""
echo " Then re-trigger backend CI:"
echo "   gh workflow run \"Backend CI\" --ref dev --repo MyAiDevs/livemask-backend"
echo "============================================"
