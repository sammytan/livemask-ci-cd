#!/usr/bin/env bash
# TASK-CICD-CLAUDE-LOOP-MACHINE-CHANNEL-LISTENER-001
# Multi-channel loop preflight: SAP + planner + git status + GitHub issues.
# Output: BLOCKED | WORK_AVAILABLE | IDLE with explicit reasons.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh" 2>/dev/null || true
log_setup "preflight" 2>/dev/null || true

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
review_req() { WORK=1; REASONS+=("REVIEW_REQUIRED: $*"); }
reconcile_req() { WORK=1; REASONS+=("RECONCILE_REQUIRED: $*"); }

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

# ── Channel 2b: Review Contracts ────────────────────────────────────────────
echo "--- Channel 2b: Review Contracts ---"
REVIEW_DIR="${DOCS_DIR}/docs/development/review-contracts"
REVIEW_ACTION_COUNT=0
if [[ -d "${REVIEW_DIR}" ]]; then
  for rf in "${REVIEW_DIR}"/*.json; do
    [[ ! -f "${rf}" ]] && continue
    [[ "$(basename "${rf}")" == ".gitkeep" ]] && continue

    REVIEW_INFO=$(python3 -c "
import json
d = json.load(open('${rf}'))
state = d.get('state','?')
actor = d.get('next_required_actor','?')
tid = d.get('task_id','?')
# Find codex verdict in latest round
rounds = d.get('rounds',[])
verdict = ''
if rounds:
    latest = rounds[-1]
    codex = latest.get('codex',{})
    verdict = codex.get('verdict','')
print(f'{state}|{actor}|{tid}|{verdict}')
" 2>/dev/null || echo "PARSE_ERROR")

    if [[ "${REVIEW_INFO}" == "PARSE_ERROR" ]]; then
      continue
    fi

    r_state="${REVIEW_INFO%%|*}"
    REVIEW_INFO="${REVIEW_INFO#*|}"
    r_actor="${REVIEW_INFO%%|*}"
    REVIEW_INFO="${REVIEW_INFO#*|}"
    r_task="${REVIEW_INFO%%|*}"
    r_verdict="${REVIEW_INFO##*|}"

    case "${r_state}" in
      changes_requested)
        echo "  ${r_task}: changes_requested (next=${r_actor})"
        review_req "contract ${r_task} state=changes_requested next_actor=${r_actor} — Claude must revise and re-submit"
        REVIEW_ACTION_COUNT=$((REVIEW_ACTION_COUNT + 1))
        ;;
      under_codex_review)
        echo "  ${r_task}: under_codex_review (next=${r_actor})"
        REASONS+=("WAIT_REVIEW: contract ${r_task} is under Codex review — do not accept new tasks for this repo until verdict")
        ;;
      approved)
        echo "  ${r_task}: approved (next=${r_actor})"
        if [[ "${r_actor}" == "claude" ]]; then
          review_req "contract ${r_task} state=approved next_actor=claude — Claude should proceed to merge/ledger reconciliation"
          REVIEW_ACTION_COUNT=$((REVIEW_ACTION_COUNT + 1))
        fi
        ;;
      blocked)
        echo "  ${r_task}: blocked (next=${r_actor})"
        block "contract ${r_task} state=blocked — must not proceed until unblocked"
        ;;
      closed|merged|ledger_reconciled)
        echo "  ${r_task}: ${r_state} — terminal, no action"
        ;;
      *)
        echo "  ${r_task}: ${r_state} (next=${r_actor})"
        ;;
    esac
  done
fi
if [[ "${REVIEW_ACTION_COUNT}" -eq 0 ]]; then
  echo "  Review contracts: no contracts requiring Claude action"
  idle_ok "Review contracts: no Claude action required"
fi

# ── Channel 2c: Ledger Staleness Check ──────────────────────────────────────
echo "--- Channel 2c: Ledger Staleness ---"
LEDGER_STALE=$(python3 -c "
import json
from pathlib import Path

ledger_path = Path('${DOCS_DIR}/docs/development/task-state-ledger.json')
if not ledger_path.exists():
    print('LEDGER_MISSING')
    exit(0)

ledger = json.loads(ledger_path.read_text())
stale = []
non_terminal = {'ready', 'in_progress', 'implemented', 'verified', 'partial', 'blocked', 'evidence_missing'}

for module in ledger.get('modules', []):
    module_id = module.get('module_id', '')
    for task in module.get('tasks', []):
        tid = task.get('task_id', '')
        status = task.get('status', '')
        if status not in non_terminal:
            continue
        # Tasks with no issue reference are stale by definition
        issue = task.get('issue', '')
        if not issue:
            stale.append(f'{tid}|{status}|no_issue')
            continue
        # Tasks with no validation evidence in non-terminal state
        validation = task.get('validation', '')
        if not validation or validation.strip() == '':
            stale.append(f'{tid}|{status}|no_validation')
            continue

if stale:
    for s in stale[:8]:
        print(s)
else:
    print('CLEAN')
" 2>/dev/null || echo "PARSE_ERROR")

if echo "${LEDGER_STALE}" | grep -qE "no_issue|no_validation"; then
  echo "  Ledger staleness found:"
  while IFS='|' read -r tid status reason; do
    [[ -z "${tid}" ]] && continue
    echo "    ${tid} (${status}, ${reason})"
    reconcile_req "ledger entry ${tid} status=${status} reason=${reason} — needs task doc or issue link update"
  done <<< "${LEDGER_STALE}"
elif [[ "${LEDGER_STALE}" == "CLEAN" ]]; then
  echo "  Ledger: no obvious staleness detected"
  idle_ok "Ledger: no staleness"
elif [[ "${LEDGER_STALE}" == "LEDGER_MISSING" ]]; then
  echo "  Ledger: file not found"
  block "Ledger: task-state-ledger.json missing — cannot verify task state"
elif [[ "${LEDGER_STALE}" == "PARSE_ERROR" ]]; then
  echo "  Ledger: staleness check failed (parse error)"
else
  echo "  Ledger: staleness check returned unexpected output"
  echo "${LEDGER_STALE}" | head -3
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
for ISSUE_REPO in "MyAiDevs/livemask-docs:68" "MyAiDevs/livemask-ci-cd:14"; do
  REPO="${ISSUE_REPO%%:*}"
  NUM="${ISSUE_REPO##*:}"
  ISSUE_OUT=$(gh issue view "${NUM}" --repo "${REPO}" --json state --jq '.state' 2>&1) || ISSUE_RC=$?
  ISSUE_RC=${ISSUE_RC:-0}
  ISSUE_STATE="${ISSUE_OUT:-UNKNOWN}"
  # #14 and #68 are PERMANENT control channels (per supervisor rules Section 1A).
  # They are designed to stay OPEN indefinitely. Being OPEN is normal state,
  # not a blocker. Only actionable keyword content in comments triggers work.
  echo "  ${REPO}#${NUM}: ${ISSUE_STATE} (gh exit=${ISSUE_RC})"
  case "${ISSUE_STATE}" in
    OPEN)
      idle_ok "GitHub: ${REPO}#${NUM} is OPEN (permanent channel — expected)"
      ;;
    CLOSED)
      warn_msg="GitHub: ${REPO}#${NUM} is CLOSED — permanent channel should not be closed"
      REASONS+=("ADVISORY: ${warn_msg}")
      echo "  ADVISORY: ${warn_msg}"
      ;;
    *)
      block "GitHub: ${REPO}#${NUM} state=${ISSUE_STATE} (gh exit=${ISSUE_RC}) — cannot verify channel state"
      ;;
  esac

  # NEW: Check recent comments for actionable keywords (per supervisor rules Section 1A)
  COMMENT_INFO=$(gh issue view "${NUM}" --repo "${REPO}" --json comments --jq '
    [.comments[-3:][] | {id: .databaseId, author: .author.login, created: .createdAt, prefix: .body[0:120]}]
  ' 2>/dev/null || echo '[]')
  COMMENT_COUNT=$(echo "${COMMENT_INFO}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
  echo "  ${REPO}#${NUM}: ${COMMENT_COUNT} recent comment(s)"

  HAS_ACTIONABLE=$(echo "${COMMENT_INFO}" | python3 -c "
import json,sys
comments = json.load(sys.stdin)
keywords = ['PERMANENT_CHANNEL','RULE_UPDATE','ACTION_NEEDED','ENFORCE','PROCESS_DEFECT','RUNTIME_STALE','LEDGER_STALE','WAIT_TASK','WAIT_CI','accepted-skip']
for c in comments:
    body = c.get('prefix','')
    for kw in keywords:
        if kw in body:
            print(kw)
            sys.exit(0)
print('')
" 2>/dev/null || true)
  if [[ -n "${HAS_ACTIONABLE}" ]]; then
    work "GitHub: ${REPO}#${NUM} latest comment contains ${HAS_ACTIONABLE}"
  fi
done

# ── Channel 5: CI/CD status ────────────────────────────────────────────────
echo "--- Channel 5: CI/CD ---"
for CI_REPO in "MyAiDevs/livemask-docs" "MyAiDevs/livemask-ci-cd" "MyAiDevs/livemask-backend" "MyAiDevs/livemask-admin"; do
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

      # Auto-create CI fix task for repeated failures
      local ci_fix_key="${CI_REPO}:${wf}"
      local fail_count
      fail_count=$(echo "${FAILURES}" | grep -c "${wf}" 2>/dev/null || echo "1")
      if [[ "${fail_count}" -ge 2 ]]; then
        local fix_tid="TASK-CICD-FIX-$(echo "${wf}" | sed 's/[^a-zA-Z0-9]/-/g' | tr '[:upper:]' '[:lower:]' | cut -c1-40)"
        # Check if fix task already exists in ledger
        local fix_exists; fix_exists=$(python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if '${fix_tid}' in t.get('task_id',''): print('yes'); break
" 2>/dev/null || echo "")
        if [[ -z "${fix_exists}" ]]; then
          REASONS+=("AUTO_FIX: CI ${CI_REPO} ${wf} failed ${fail_count} times — auto-creating fix task ${fix_tid}")
          # Create a minimal task stub
          local fix_doc="${DOCS_DIR}/docs/development/tasks/${fix_tid}.md"
          if [[ ! -f "${fix_doc}" ]]; then
            cat > "${fix_doc}" << TASKDOC
# ${fix_tid} — Auto-created CI Fix

> Priority: P0
> Repo: ${CI_REPO}
> Status: ready

## Problem
${wf} failed ${fail_count} consecutive runs on ${CI_REPO}/dev.
Latest: ${url}

## Acceptance Criteria
- [ ] ${wf} passes on dev branch
- [ ] Root cause identified and fixed
- [ ] CI green for 2+ consecutive runs

## Validation
- CI run passes: ${url}
TASKDOC
            # Update ledger
            python3 -c "
import json, pathlib
ledger_path = pathlib.Path('${DOCS_DIR}/docs/development/task-state-ledger.json')
ledger = json.loads(ledger_path.read_text())
# Find or create ci-fix module
module = None
for m in ledger.get('modules',[]):
    if m.get('module_id') == 'ci-health':
        module = m
        break
if not module:
    module = {'module_id': 'ci-health', 'overall_status': 'partial', 'owner_repo': 'livemask-ci-cd', 'tasks': []}
    ledger['modules'].append(module)
module['tasks'].append({
    'task_id': '${fix_tid}',
    'repo': '${CI_REPO}',
    'module_id': 'ci-health',
    'status': 'ready',
    'priority': 'P0',
    'task_doc': 'docs/development/tasks/${fix_tid}.md',
    'issue': '${url}',
    'notes': 'Auto-created: ${wf} failed ${fail_count} times'
})
ledger_path.write_text(json.dumps(ledger, indent=2, ensure_ascii=False))
" 2>/dev/null
          fi
        else
          REASONS+=("AUTO_FIX: fix task ${fix_tid} already exists for ${wf}")
        fi
      fi
    done <<< "${FAILURES}"
  else
    echo "  ${CI_REPO}: no failures (${CI_RUNS:+runs found})"
  fi
done

# ── Channel 6: Event Cache Liveness ──────────────────────────────────────────
echo "--- Channel 6: Event Cache ---"
EVENT_CACHE="${HOME}/.claude/event-cache/event-cache.jsonl"
CURSOR_STATE="${HOME}/.claude/event-cache/adapter-cursors.json"
if [[ -f "${EVENT_CACHE}" ]]; then
  CACHE_SIZE=$(wc -l < "${EVENT_CACHE}" 2>/dev/null | tr -d ' ' || echo "0")
  LAST_LINE=$(tail -1 "${EVENT_CACHE}" 2>/dev/null || echo "")
  if [[ -n "${LAST_LINE}" ]]; then
    LAST_TS=$(echo "${LAST_LINE}" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('ts','unknown'))" 2>/dev/null || echo "unknown")
    echo "  Event cache: ${CACHE_SIZE} events, last at ${LAST_TS}"
  else
    echo "  Event cache: empty (${CACHE_SIZE} lines)"
  fi
  # Check staleness (>60 min since last event)
  NOW_EPOCH=$(date -u +%s)
  EVENT_EPOCH=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "${LAST_TS:-1970-01-01T00:00:00Z}" +%s 2>/dev/null || echo "0")
  AGE_MIN=$(( (NOW_EPOCH - EVENT_EPOCH) / 60 ))
  if [[ "${LAST_TS:-}" != "unknown" && -n "${LAST_TS:-}" ]]; then
    if [[ "${AGE_MIN}" -gt 60 ]]; then
      REASONS+=("ADVISORY: event cache is ${AGE_MIN} min stale — pollers may be down, but this is NOT a blocker (cache is accelerator only)")
    fi
  fi
  idle_ok "Event cache: present"
else
  echo "  Event cache: not found (first run or pollers not yet executed)"
  idle_ok "Event cache: absent (expected on fresh workspace)"
fi
if [[ -f "${CURSOR_STATE}" ]]; then
  echo "  Cursor state: present"
else
  echo "  Cursor state: not yet initialized"
fi

# ── Channel 7: Role-engine findings consumption ──────────────────────────────
echo "--- Channel 7: Role-Engine Findings ---"
FINDINGS_FILE="${HOME}/.claude/role-cache/findings.jsonl"
FINDINGS_BLOCKER=0
FINDINGS_WARNING=0
if [[ -f "${FINDINGS_FILE}" ]]; then
  FINDINGS_AGE_MIN=999
  if [[ "$(uname)" == "Darwin" ]]; then
    FINDINGS_MTIME=$(stat -f %m "${FINDINGS_FILE}" 2>/dev/null || echo "0")
  else
    FINDINGS_MTIME=$(stat -c %Y "${FINDINGS_FILE}" 2>/dev/null || echo "0")
  fi
  NOW_EPOCH=$(date +%s)
  FINDINGS_AGE_MIN=$(( (NOW_EPOCH - FINDINGS_MTIME) / 60 ))

  if [[ "${FINDINGS_AGE_MIN}" -gt 120 ]]; then
    echo "  Findings file is ${FINDINGS_AGE_MIN} min stale — skipping (too old to be actionable)"
    idle_ok "Findings: stale (${FINDINGS_AGE_MIN} min)"
  else
    FINDINGS_BLOCKER=$(python3 -c "
import json
count = 0
try:
    with open('${FINDINGS_FILE}') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            d = json.loads(line)
            if d.get('severity') == 'blocker': count += 1
except: pass
print(count)
" 2>/dev/null || echo "0")
    FINDINGS_WARNING=$(python3 -c "
import json
count = 0
try:
    with open('${FINDINGS_FILE}') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            d = json.loads(line)
            if d.get('severity') == 'warning': count += 1
except: pass
print(count)
" 2>/dev/null || echo "0")

    FINDINGS_TOTAL=$((FINDINGS_BLOCKER + FINDINGS_WARNING))
    echo "  Role-engine findings: ${FINDINGS_BLOCKER} blocker, ${FINDINGS_WARNING} warning (age=${FINDINGS_AGE_MIN}min)"

    if [[ "${FINDINGS_BLOCKER}" -gt 0 ]]; then
      # Show top blockers
      python3 -c "
import json
blockers = []
try:
    with open('${FINDINGS_FILE}') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            d = json.loads(line)
            if d.get('severity') == 'blocker':
                blockers.append(d)
except: pass
for b in blockers[:3]:
    print(f\"  BLOCKER: [{b.get('role','?')}-{b.get('check','?')}] {b.get('finding','?')[:150]}\")
    if b.get('cmd'): print(f\"    cmd: {b.get('cmd')}\")
" 2>/dev/null
      block "Role-engine: ${FINDINGS_BLOCKER} blocker finding(s) — must resolve before idle"
    fi

    if [[ "${FINDINGS_WARNING}" -gt 0 ]]; then
      python3 -c "
import json
warnings = []
try:
    with open('${FINDINGS_FILE}') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            d = json.loads(line)
            if d.get('severity') == 'warning':
                warnings.append(d)
except: pass
for w in warnings[:3]:
    print(f\"  WARNING: [{w.get('role','?')}-{w.get('check','?')}] {w.get('finding','?')[:150]}\")
" 2>/dev/null
      work "Role-engine: ${FINDINGS_WARNING} warning finding(s) — review before declaring idle"
    fi

    if [[ "${FINDINGS_TOTAL}" -eq 0 ]]; then
      echo "  Role-engine: no actionable findings"
      idle_ok "Role-engine: no findings"
    fi
  fi
else
  echo "  Role-engine findings: no file (role-engine not yet run or first cycle)"
  idle_ok "Role-engine: not yet run"
fi

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

# Count specific signal types for startup script consumption
# grep -c outputs "0" on no match (with exit 1), so suppress exit code and strip whitespace
REVIEW_COUNT=$( { printf '%s\n' "${REASONS[@]}" | grep -c "REVIEW_REQUIRED:" 2>/dev/null; } || true )
REVIEW_COUNT=$(echo "${REVIEW_COUNT}" | tr -d '[:space:]')
[[ -z "${REVIEW_COUNT}" ]] && REVIEW_COUNT=0
RECONCILE_COUNT=$( { printf '%s\n' "${REASONS[@]}" | grep -c "RECONCILE_REQUIRED:" 2>/dev/null; } || true )
RECONCILE_COUNT=$(echo "${RECONCILE_COUNT}" | tr -d '[:space:]')
[[ -z "${RECONCILE_COUNT}" ]] && RECONCILE_COUNT=0
if [[ "${REVIEW_COUNT}" -gt 0 ]]; then
  echo "SIGNAL: REVIEW_REQUIRED=${REVIEW_COUNT} contract(s) need Claude action"
fi
if [[ "${RECONCILE_COUNT}" -gt 0 ]]; then
  echo "SIGNAL: RECONCILE_REQUIRED=${RECONCILE_COUNT} ledger/task-doc entries need reconciliation"
fi
if [[ "${FINDINGS_BLOCKER}" -gt 0 ]]; then
  echo "SIGNAL: FINDINGS_BLOCKER=${FINDINGS_BLOCKER} blocker(s) from role-engine — must resolve"
fi
if [[ "${FINDINGS_WARNING}" -gt 0 ]]; then
  echo "SIGNAL: FINDINGS_WARNING=${FINDINGS_WARNING} warning(s) from role-engine — review recommended"
fi

if [[ "${BLOCKED}" -eq 1 ]]; then
  log_summary "preflight" 2 "BLOCKED" 2>/dev/null || true
  exit 2
elif [[ "${WORK}" -eq 1 ]]; then
  log_summary "preflight" 1 "WORK_AVAILABLE" 2>/dev/null || true
  exit 1
else
  log_summary "preflight" 0 "IDLE" 2>/dev/null || true
  exit 0
fi
