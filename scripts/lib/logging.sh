#!/usr/bin/env bash
# Shared logging + workspace guard for all Claude loop scripts.
# Source this at script start for file logging AND automatic dev-branch cleanup.
#
# Usage:
#   source "${SCRIPT_DIR}/lib/logging.sh"
#   log_setup "script-name"
#
# Output:
#   /tmp/claude/<name>-<timestamp>.log   Full run log
#   /tmp/claude/latest-<name>.log        Symlink to latest
#   /tmp/claude/last-run-<name>.json     Summary metrics
#
# Workspace guard (automatic via EXIT trap):
#   - Switches livemask-docs AND livemask-ci-cd back to dev
#   - Stashes uncommitted changes if stuck on task branch
#   - Deletes leftover pm-auto-reconcile/auto-create/role/fallback-sap branches
#
# Debug: tail -f /tmp/claude/latest-*.log
set -euo pipefail

LOG_DIR="/tmp/claude"
LOG_MAX_FILES=20

# ── Workspace guard: NEVER leave repos on a non-dev branch ──────────────────
_workspace_guard() {
  local exit_code=$?
  for repo in "/Users/sammytan/Developer/LiveMask/livemask-docs" \
              "/Users/sammytan/Developer/LiveMask/livemask-ci-cd"; do
    [[ ! -d "${repo}/.git" ]] && continue
    cd "${repo}" 2>/dev/null || continue
    local br; br=$(git branch --show-current 2>/dev/null || echo "")
    if [[ -n "${br}" && "${br}" != "dev" ]]; then
      git stash --include-untracked -m "auto-stash: workspace guard $(date -u +%Y%m%d-%H%M%S)" 2>/dev/null || true
      git checkout dev 2>/dev/null || true
    fi
  done
  for repo in "/Users/sammytan/Developer/LiveMask/livemask-docs" \
              "/Users/sammytan/Developer/LiveMask/livemask-ci-cd"; do
    [[ ! -d "${repo}/.git" ]] && continue
    cd "${repo}" 2>/dev/null || continue
    for br in $(git branch --list "task/pm-auto-*" "task/auto-create-*" "task/role-*" "task/fallback-sap-*" --format='%(refname:short)' 2>/dev/null); do
      git branch -D "${br}" 2>/dev/null || true
    done
  done
  exit ${exit_code}
}

log_setup() {
  local name="${1:-unknown}"
  local ts; ts=$(date -u +%Y%m%d-%H%M%S)
  mkdir -p "${LOG_DIR}"

  LOG_FILE="${LOG_DIR}/${name}-${ts}.log"
  LOG_LATEST="${LOG_DIR}/latest-${name}.log"
  LOG_SUMMARY="${LOG_DIR}/last-run-${name}.json"
  LOG_START_EPOCH=$(date +%s)

  local count; count=$(find "${LOG_DIR}" -maxdepth 1 -name "${name}-*.log" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${count}" -gt "${LOG_MAX_FILES}" ]]; then
    find "${LOG_DIR}" -maxdepth 1 -name "${name}-*.log" -type f | sort | head -n "-${LOG_MAX_FILES}" | xargs rm -f 2>/dev/null || true
  fi

  exec > >(tee -a "${LOG_FILE}") 2>&1
  ln -sf "$(basename "${LOG_FILE}")" "${LOG_LATEST}" 2>/dev/null || true

  echo "═══════════════════════════════════════════"
  echo "  LOG: ${name} | $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "  FILE: ${LOG_FILE}"
  echo "  LATEST: ${LOG_LATEST}"
  echo "═══════════════════════════════════════════"
  echo ""

  # EVERY script that calls log_setup gets automatic workspace cleanup on exit
  trap _workspace_guard EXIT
}

# Write structured summary for quick memory lookup
log_summary() {
  local name="$1" exit_code="${2:-0}" extra="${3:-}"
  local elapsed; elapsed=$(($(date +%s) - LOG_START_EPOCH))
  python3 -c "
import json, pathlib
summary = {
    'script': '${name}',
    'timestamp': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'elapsed_sec': ${elapsed},
    'exit_code': ${exit_code},
    'log_file': '${LOG_FILE}',
    'extra': '${extra}'
}
pathlib.Path('${LOG_SUMMARY}').write_text(json.dumps(summary, indent=2))
print(f'  [summary] ${LOG_SUMMARY}')
" 2>/dev/null || true
}

# Debug helper: print where to find logs
log_debug_info() {
  echo ""
  echo "── Debug Info ──"
  echo "  Latest logs:"
  for lf in "${LOG_DIR}"/latest-*.log; do
    [[ -f "${lf}" ]] && echo "    tail -50 ${lf}"
  done
  echo "  All logs:    ls -lt ${LOG_DIR}/"
  echo "  Summaries:   cat ${LOG_DIR}/last-run-*.json"
}
