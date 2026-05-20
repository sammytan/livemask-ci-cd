#!/usr/bin/env bash
set -euo pipefail

# TASK-CICD-WORKSPACE-PATH-MIGRATION-001
# Local dev environment status report — workspace path verification + runtime overview.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIVEMASK_WORKSPACE_ROOT="${LIVEMASK_WORKSPACE_ROOT:-$HOME/Developer/LiveMask}"

# Source workspace check if available
BASE_SERVICE="${SCRIPT_DIR}/lib/base_service.sh"
if [[ -f "${BASE_SERVICE}" ]]; then
  # shellcheck source=scripts/lib/base_service.sh
  source "${BASE_SERVICE}"
fi

echo "============================================"
echo " Local Dev Status Report"
echo "============================================"
echo ""
echo "--- Environment ---"
echo "  PWD:                     $PWD"
echo "  REPO_DIR:                ${REPO_DIR}"
echo "  LIVEMASK_WORKSPACE_ROOT: ${LIVEMASK_WORKSPACE_ROOT}"
echo ""

# Git info
echo "--- Git Info ---"
if git rev-parse --git-dir &>/dev/null; then
  echo "  Branch:   $(git branch --show-current 2>/dev/null || echo 'unknown')"
  echo "  Remote:   $(git remote get-url origin 2>/dev/null || echo 'none')"
  echo "  Status:"
  git status --short 2>/dev/null || echo "    (clean)"
else
  echo "  (not a git repository)"
fi
echo ""

# Old path check
echo "--- Workspace Path Check ---"
if [[ "$PWD" == "/Users/sammytan/Documents/New project 2"* ]]; then
  echo "  FAIL: Old workspace path detected."
  echo "  ACTION: Reopen this repo under ${LIVEMASK_WORKSPACE_ROOT}/<repo>"
elif [[ "$PWD" == "${LIVEMASK_WORKSPACE_ROOT}"* ]]; then
  echo "  PASS: Inside canonical workspace root."
else
  echo "  WARN: Outside canonical workspace root (${LIVEMASK_WORKSPACE_ROOT})"
fi
echo ""

# Repo presence
echo "--- Repositories under ${LIVEMASK_WORKSPACE_ROOT} ---"
for repo in livemask-docs livemask-backend livemask-admin livemask-website \
            livemask-app livemask-nodeagent livemask-job-service livemask-ci-cd; do
  if [[ -d "${LIVEMASK_WORKSPACE_ROOT}/${repo}/.git" ]]; then
    echo "  * ${repo}: present"
  else
    echo "  - ${repo}: missing"
  fi
done
echo ""

# Docker
echo "--- Docker ---"
if command -v docker &>/dev/null; then
  echo "  CLI: available"
  if docker info &>/dev/null; then
    echo "  Daemon: running"
  else
    echo "  Daemon: not running or permission denied"
  fi
else
  echo "  docker CLI: not found"
fi
echo ""

# Runtime containers (optional)
echo "--- Runtime Containers ---"
if command -v docker &>/dev/null && docker info &>/dev/null; then
  local_compose="${REPO_DIR}/infra/docker-compose.local.yml"
  if [[ -f "${local_compose}" ]]; then
    echo "  Compose file: ${local_compose}"
    docker compose -f "${local_compose}" ps --services --filter "status=running" 2>/dev/null || echo "  (compose status unavailable)"
  else
    echo "  Compose file not found: ${local_compose}"
  fi
else
  echo "  (docker info unavailable)"
fi
echo ""
echo "============================================"
