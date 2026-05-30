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

# ── Channel 1: SAP active blockers ──────────────────────────────────────────
echo "--- Channel 1: SAP ---"
SAP_OUT=$("${SUPERVISOR_CLI}" list --active-blockers --blocks-loop true 2>&1 || true)
SAP_COUNT=$(echo "${SAP_OUT}" | grep -cE "^(open|ack) " 2>/dev/null; true)
if [[ "${SAP_COUNT}" -gt 0 ]]; then
  block "SAP: ${SAP_COUNT} active blocking packet(s)"
  echo "${SAP_OUT}"
elif echo "${SAP_OUT}" | grep -qi "error\|traceback\|exception"; then
  block "SAP: supervisor CLI error — cannot determine blocker state"
  echo "${SAP_OUT}"
else
  echo "  SAP: clean (no active blockers)"
  idle_ok "SAP: clean"
fi

# ── Channel 2: Planner ──────────────────────────────────────────────────────
echo "--- Channel 2: Planner ---"
PLAN_OUT=$("${PLANNER}" --ledger "${DOCS_DIR}/docs/development/task-state-ledger.json" --format json 2>&1 || true)
CANDIDATE_COUNT=$(echo "${PLAN_OUT}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['summary']['candidate_count'])" 2>/dev/null || echo "UNKNOWN")
BLOCKED_OPEN=$(echo "${PLAN_OUT}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['summary']['blocked_open_count'])" 2>/dev/null || echo "UNKNOWN")
echo "  Planner: candidates=${CANDIDATE_COUNT}, blocked_open=${BLOCKED_OPEN}"
if [[ "${CANDIDATE_COUNT}" == "UNKNOWN" ]]; then
  block "Planner: could not determine candidate count (planner error)"
elif [[ "${CANDIDATE_COUNT}" -gt 0 ]]; then
  for t in $(echo "${PLAN_OUT}" | python3 -c "import json,sys; d=json.load(sys.stdin); [print(t['task_id']) for t in d.get('global_next',[])]" 2>/dev/null); do
    work "Planner: ${t} (candidate)"
  done
else
  idle_ok "Planner: no candidates"
fi

# ── Channel 3: Git status in livemask-docs ───────────────────────────────────
echo "--- Channel 3: Git Status (livemask-docs) ---"
cd "${DOCS_DIR}"
GIT_PORCELAIN=$(git status --porcelain --untracked-files=all 2>&1 || echo "GIT_ERROR")
if [[ "${GIT_PORCELAIN}" == "GIT_ERROR" ]]; then
  block "git: livemask-docs git command failed — cannot verify clean state"
elif [[ -n "${GIT_PORCELAIN}" ]]; then
  DIRTY_COUNT=$(echo "${GIT_PORCELAIN}" | wc -l | tr -d ' ')
  GIT_BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
  block "git: livemask-docs has ${DIRTY_COUNT} dirty file(s) on branch ${GIT_BRANCH}"
  echo "${GIT_PORCELAIN}" | head -20
else
  echo "  Git: livemask-docs clean"
  idle_ok "Git: livemask-docs clean"
fi
cd "${CI_CD_DIR}"

# ── Channel 4: GitHub issues ─────────────────────────────────────────────────
echo "--- Channel 4: GitHub Issues ---"
for ISSUE_REPO in "MyAiDevs/livemask-docs:62" "MyAiDevs/livemask-ci-cd:14"; do
  REPO="${ISSUE_REPO%%:*}"
  NUM="${ISSUE_REPO##*:}"
  ISSUE_OUT=$(gh issue view "${NUM}" --repo "${REPO}" --json state --jq '.state' 2>&1) || ISSUE_RC=$?
  ISSUE_RC=${ISSUE_RC:-0}
  ISSUE_STATE="${ISSUE_OUT:-UNKNOWN}"
  echo "  ${REPO}#${NUM}: ${ISSUE_STATE} (gh exit=${ISSUE_RC})"
  case "${ISSUE_STATE}" in
    OPEN)
      block "GitHub: ${REPO}#${NUM} is OPEN — must read and acknowledge"
      ;;
    CLOSED)
      idle_ok "GitHub: ${REPO}#${NUM} is closed"
      ;;
    *)
      block "GitHub: ${REPO}#${NUM} state=${ISSUE_STATE} (gh exit=${ISSUE_RC}) — not CLOSED, blocking idle"
      ;;
  esac
done

# ── Channel 5: CI/CD status ────────────────────────────────────────────────
echo "--- Channel 5: CI/CD ---"
for CI_REPO in "MyAiDevs/livemask-docs" "MyAiDevs/livemask-ci-cd"; do
  CI_RUNS=$(gh run list --repo "${CI_REPO}" --branch dev --limit 3 --json status,conclusion,workflowName,headSha,url 2>&1) || CI_RC=$?
  CI_RC=${CI_RC:-0}
  if [[ "${CI_RC}" -ne 0 ]]; then
    block "CI: ${CI_REPO} gh run list failed (exit=${CI_RC})"
    continue
  fi
  FAILURES=$(echo "${CI_RUNS}" | python3 -c "
import json,sys
runs=json.load(sys.stdin)
for r in runs:
    if r.get('conclusion') in ('failure','cancelled','timed_out'):
        print(f\"{r['workflowName']}|{r['conclusion']}|{r['url']}|{r.get('headSha','?')[:7]}\")
" 2>/dev/null || echo "")
  IN_PROGRESS=$(echo "${CI_RUNS}" | python3 -c "
import json,sys
runs=json.load(sys.stdin)
for r in runs:
    if r.get('status') in ('queued','in_progress','waiting','pending'):
        print(f\"{r['workflowName']}|{r['status']}\")
" 2>/dev/null || echo "")
  if [[ -n "${IN_PROGRESS}" ]]; then
    while IFS='|' read -r wf status; do
      [[ -n "${wf}" ]] && REASONS+=("WAIT_CI: ${CI_REPO} ${wf} is ${status}")
    done <<< "${IN_PROGRESS}"
  fi
  if [[ -n "${FAILURES}" ]]; then
    while IFS='|' read -r wf conclusion url sha; do
      [[ -n "${wf}" ]] && block "CI: ${CI_REPO} ${wf} ${conclusion} at ${sha} — ${url}"
    done <<< "${FAILURES}"
  else
    echo "  ${CI_REPO}: no failures (${CI_RUNS:+runs found})"
  fi
done

# ── Summary ──────────────────────────────────────────────────────────────────
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

[[ "${BLOCKED}" -eq 1 ]] && exit 2
[[ "${WORK}" -eq 1 ]] && exit 1
exit 0
