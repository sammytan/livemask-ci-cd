#!/usr/bin/env bash
# TASK-CICD-CLAUDE-LOOP-MACHINE-CHANNEL-LISTENER-001
# Multi-channel loop preflight: SAP + planner + git status + GitHub issues.
# Output: BLOCKED | WORK_AVAILABLE | IDLE with explicit reasons.
set -euo pipefail

DOCS_DIR="/Users/sammytan/Developer/LiveMask/livemask-docs"
CI_CD_DIR="/Users/sammytan/Developer/LiveMask/livemask-ci-cd"
SUPERVISOR_CLI="${DOCS_DIR}/scripts/supervisor-action.py"
PLANNER="${DOCS_DIR}/scripts/plan-next-tasks.py"

BLOCKED=0
WORK=0
REASONS=()

block() { BLOCKED=1; REASONS+=("BLOCKED: $*"); }
work() { WORK=1; REASONS+=("WORK_AVAILABLE: $*"); }
idle_ok() { REASONS+=("IDLE_OK: $*"); }

echo "=== Claude Loop Multi-Channel Preflight ==="

# Channel 1: SAP active blockers
echo "--- Channel 1: SAP ---"
SAP_OUT=$("${SUPERVISOR_CLI}" list --active-blockers --blocks-loop true 2>&1 || true)
if echo "${SAP_OUT}" | grep -q "SAP-"; then
  SAP_COUNT=$(echo "${SAP_OUT}" | grep -c "SAP-" || echo "0")
  block "SAP: ${SAP_COUNT} active blocking packet(s)"
  echo "${SAP_OUT}"
else
  echo "  SAP: clean (no active blockers)"
  idle_ok "SAP: clean"
fi

# Channel 2: Planner
echo "--- Channel 2: Planner ---"
PLAN_OUT=$("${PLANNER}" --ledger "${DOCS_DIR}/docs/development/task-state-ledger.json" --format json 2>&1 || true)
CANDIDATE_COUNT=$(echo "${PLAN_OUT}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['summary']['candidate_count'])" 2>/dev/null || echo "0")
BLOCKED_OPEN=$(echo "${PLAN_OUT}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['summary']['blocked_open_count'])" 2>/dev/null || echo "0")
echo "  Planner: candidates=${CANDIDATE_COUNT}, blocked_open=${BLOCKED_OPEN}"
if [[ "${CANDIDATE_COUNT}" -gt 0 ]]; then
  for t in $(echo "${PLAN_OUT}" | python3 -c "import json,sys; d=json.load(sys.stdin); [print(t['task_id']) for t in d.get('global_next',[])]" 2>/dev/null); do
    work "Planner: ${t} (candidate)"
  done
else
  idle_ok "Planner: no candidates"
fi

# Channel 3: Git status in livemask-docs
echo "--- Channel 3: Git Status (livemask-docs) ---"
cd "${DOCS_DIR}"
GIT_STATUS=$(git status --short --branch --untracked-files=all 2>&1 || true)
if echo "${GIT_STATUS}" | grep -q "^[?MADRCU]"; then
  DIRTY_COUNT=$(echo "${GIT_STATUS}" | grep -c "^[?MADRCU]" || echo "0")
  block "git: livemask-docs has ${DIRTY_COUNT} dirty file(s)"
  echo "${GIT_STATUS}" | head -20
else
  echo "  Git: livemask-docs clean"
  idle_ok "Git: livemask-docs clean"
fi

# Channel 4: GitHub issues
echo "--- Channel 4: GitHub Issues ---"
for ISSUE in "MyAiDevs/livemask-docs:62" "MyAiDevs/livemask-ci-cd:14"; do
  REPO="${ISSUE%%:*}"
  NUM="${ISSUE##*:}"
  ISSUE_STATE=$(gh issue view "${NUM}" --repo "${REPO}" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
  ISSUE_RC=$?
  echo "  ${REPO}#${NUM}: ${ISSUE_STATE}"
  case "${ISSUE_STATE}" in
    OPEN)
      block "GitHub: ${REPO}#${NUM} is OPEN — must read and acknowledge"
      ;;
    CLOSED)
      idle_ok "GitHub: ${REPO}#${NUM} is closed"
      ;;
    *)
      # UNKNOWN, command failure, auth failure, network failure, or any other state
      block "GitHub: ${REPO}#${NUM} is ${ISSUE_STATE} (not CLOSED — gh exit=${ISSUE_RC}) — blocking idle"
      ;;
  esac
done

# Summary
echo ""
echo "============================================"
if [[ "${BLOCKED}" -eq 1 ]]; then
  echo " PREFLIGHT: BLOCKED"
elif [[ "${WORK}" -eq 1 ]]; then
  echo " PREFLIGHT: WORK_AVAILABLE"
else
  echo " PREFLIGHT: IDLE"
fi
echo "============================================"
printf '%s\n' "${REASONS[@]}"

# Exit codes: 0=IDLE, 1=WORK_AVAILABLE, 2=BLOCKED
[[ "${BLOCKED}" -eq 1 ]] && exit 2
[[ "${WORK}" -eq 1 ]] && exit 1
exit 0
