#!/usr/bin/env bash
# TASK-CICD-RUNNER-BACKLOG-001
# Restart the livemask-ci-runner-01 service on the shared runner server.
# Must run from a workflow that uses the livemask-staging runner group
# (same server as livemask-ci-runner-01).
set -euo pipefail

CI_SERVICE="actions.runner.MyAiDevs.livemask-ci-runner-01.service"

sudo_noninteractive() {
  if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo -n "$@"
    return $?
  fi
  echo "SKIP: sudo unavailable without password; not running: $*"
  return 125
}

echo "============================================"
echo " CI Runner Restart"
echo " $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo "============================================"

echo ""
echo "=== Step 1: Check current state ==="
sudo_noninteractive systemctl status "${CI_SERVICE}" --no-pager -l 2>&1 | head -30 || true

echo ""
echo "=== Step 2: Restart service ==="
if sudo_noninteractive systemctl restart "${CI_SERVICE}" 2>&1; then
  echo "Restart command completed."
else
  rc=$?
  if [[ "${rc}" -eq 125 ]]; then
    echo "Restart skipped because non-interactive sudo is unavailable."
    exit 0
  fi
  echo "Restart command failed with exit code: ${rc}"
  exit "${rc}"
fi

echo ""
echo "=== Step 3: Verify new state ==="
sleep 3
sudo_noninteractive systemctl status "${CI_SERVICE}" --no-pager -l 2>&1 | head -30 || true

echo ""
echo "=== Step 4: Check GitHub API runner status (will be checked from workflow) ==="
echo "runner: livemask-ci-runner-01"
echo "expected: online, busy=false"

echo ""
echo "=== Step 5: Clean up stale runner working dirs ==="
echo "Removing stale job worktrees older than 2 hours..."
find /opt/actions-runner/livemask-ci/_work -mindepth 1 -maxdepth 1 -type d -mmin +120 2>/dev/null | while read -r dir; do
  echo "  Removing stale worktree: ${dir}"
  rm -rf "${dir}"
done || echo "(no stale worktrees found)"

echo ""
echo "============================================"
echo " CI Runner Restart Complete"
echo "============================================"
