#!/usr/bin/env bash
# TASK-CICD-RUNNER-BACKLOG-001
# Diagnostic script for self-hosted CI runner issues.
# Designed to run from livemask-staging group on the same server as livemask-ci.
set -euo pipefail

echo "============================================"
echo " CI Runner Diagnostic Report"
echo " $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo "============================================"
echo ""

# ── 1. Runner service status ────────────────────────────────────────────────
echo "=== Systemd runner services ==="
systemctl list-units '*actions*' --type=service --no-pager 2>&1 || echo "(systemctl not available)"
echo ""

sudo_noninteractive() {
  if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo -n "$@"
    return $?
  fi
  echo "(sudo unavailable without password; skipped: $*)"
  return 0
}

for svc in actions.runner.MyAiDevs.livemask-ci-runner-01.service actions.runner.MyAiDevs.livemask-staging-runner-01.service; do
  echo "--- systemctl status ${svc} (last 20 lines) ---"
  sudo_noninteractive systemctl status "${svc}" --no-pager -l 2>&1 | tail -20 || echo "(unable to check ${svc})"
  echo ""
done

# ── 2. Runner process ──────────────────────────────────────────────────────
echo "=== Runner agent processes ==="
ps aux | grep -i 'runsvc\|Runner.Listener\|run.sh' | grep -v grep || echo "(no runner processes found)"
echo ""

# ── 3. Runner working directory ─────────────────────────────────────────────
echo "=== Runner working directory: /opt/actions-runner/livemask-ci ==="
ls -la /opt/actions-runner/livemask-ci/ 2>&1 | head -20
echo ""

echo "=== Runner _work directory listing ==="
ls -la /opt/actions-runner/livemask-ci/_work/ 2>&1 | head -20
echo ""
echo "=== Residue job directories ==="
find /opt/actions-runner/livemask-ci/_work -maxdepth 2 -type d -mmin +120 2>/dev/null | head -30 || echo "(find not available or path does not exist)"
echo ""

# ── 4. Runner diagnostics file ─────────────────────────────────────────────
echo "=== Runner diagnostics (if available) ==="
cat /opt/actions-runner/livemask-ci/_diag/*.log 2>/dev/null | tail -50 || echo "(no diag log found)"
echo ""

# ── 5. Runner .runner file (registration info) ──────────────────────────────
echo "=== Runner registration info ==="
cat /opt/actions-runner/livemask-ci/.runner 2>/dev/null || echo "(no .runner found)"
echo ""

# ── 6. Docker daemon health ─────────────────────────────────────────────────
echo "=== Docker daemon ==="
docker info 2>&1 | head -15 || echo "(Docker not available)"
echo ""

echo "=== Docker disk usage ==="
docker system df 2>&1 || echo "(docker system df not available)"
echo ""

echo "=== Running containers ==="
docker ps --format 'table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Names}}' 2>&1 || echo "(docker ps not available)"
echo ""

echo "=== All containers (including stopped) ==="
docker ps -a --format 'table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Names}}' 2>&1 | head -50 || echo "(docker ps -a not available)"
echo ""

# ── 7. Disk space ───────────────────────────────────────────────────────────
echo "=== Disk space ==="
df -h / /opt 2>&1 || df -h / 2>&1
echo ""

# ── 8. Memory ───────────────────────────────────────────────────────────────
echo "=== Memory ==="
free -h 2>&1 || vm_stat 2>/dev/null | head -20 || echo "(memory info not available)"
echo ""

# ── 9. Runner journal log ───────────────────────────────────────────────────
echo "=== Recent runner journal log (last 50 lines) ==="
journalctl -u actions.runner.MyAiDevs.livemask-ci-runner-01.service --no-pager -n 50 2>&1 || echo "(journalctl not available)"
echo ""

# ── 10. Summary ──────────────────────────────────────────────────────────────
echo "============================================"
echo " Diagnostic Complete"
echo "============================================"
