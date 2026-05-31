#!/usr/bin/env bash
# TASK-CICD-CLAUDE-LOOP-STARTUP-001
# Deterministic startup sequence for Claude /loop.
# Every Claude session starts here. No guessing, no aimless exploration.
#
# Usage:
#   bash scripts/claude-loop-startup.sh              # full startup
#   bash scripts/claude-loop-startup.sh --recovery   # recovery only
#   bash scripts/claude-loop-startup.sh --quick      # skip preflight, use cached state
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/lark-card.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/health-check.sh" 2>/dev/null || true
log_setup "startup" 2>/dev/null || true

LIVEMASK_ROOT="/Users/sammytan/Developer/LiveMask"
DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"
AGENT_STATE="${LIVEMASK_ROOT}/.claude/agent-state.json"
ADAPTER_LIB="${CI_CD_DIR}/scripts/event-adapters/lib/adapter-lib.sh"

MODE="${1:-full}"

# ── Colors ────────────────────────────────────────────────────────────────────
BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

# ── Repo Context Guard: ENFORCE correct working directory ─────────────────────
# Claude may be in a runtime repo from a previous task. All control-plane
# commands (supervisor-action.py, plan-next-tasks.py, gh issue, etc.) MUST
# run from livemask-docs or with absolute paths.
STARTUP_START_DIR=$(pwd)
# Export absolute paths for Claude to use in manual commands
export DOCS_SCRIPTS="${DOCS_DIR}/scripts"
export CI_CD_SCRIPTS="${CI_CD_DIR}/scripts"
if [[ ! "${STARTUP_START_DIR}" =~ livemask-(docs|ci-cd) ]]; then
  echo -e "  ${YELLOW}[WARN]${RESET} startup invoked from ${STARTUP_START_DIR} — control-plane commands need absolute paths"
  echo "  Use: python3 ${DOCS_SCRIPTS}/supervisor-action.py ..."
  echo "  Use: bash ${CI_CD_SCRIPTS}/claude-loop-preflight.sh"
fi

header()  { echo -e "\n${BOLD}${CYAN}═══ $* ═══${RESET}"; }
ok()      { echo -e "  ${GREEN}[OK]${RESET} $*"; }
warn()    { echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
fail()    { echo -e "  ${RED}[FAIL]${RESET} $*"; }
info()    { echo -e "  ${CYAN}[..]${RESET} $*"; }

# ── Step 0: Read agent state ──────────────────────────────────────────────────
read_agent_state() {
  header "Step 0: Agent State"
  if [[ ! -f "${AGENT_STATE}" ]]; then
    warn "no agent-state.json — treating as fresh start"
    AGENT_PHASE="idle"
    CURRENT_TASK="null"
    TASK_PHASE="null"
    TARGET_REPO=""
    TASK_BRANCH=""
    LAST_ACTION=""
    return 0
  fi

  AGENT_PHASE=$(python3 -c "import json; d=json.load(open('${AGENT_STATE}')); print(d.get('phase','idle'))" 2>/dev/null || echo "idle")
  CURRENT_TASK=$(python3 -c "import json; d=json.load(open('${AGENT_STATE}')); print(d.get('current_task',{}).get('task_id') or 'null')" 2>/dev/null || echo "null")
  TASK_PHASE=$(python3 -c "import json; d=json.load(open('${AGENT_STATE}')); print(d.get('current_task',{}).get('phase') or 'null')" 2>/dev/null || echo "null")
  TARGET_REPO=$(python3 -c "import json; d=json.load(open('${AGENT_STATE}')); print(d.get('current_task',{}).get('target_repo') or '')" 2>/dev/null || echo "")
  TASK_BRANCH=$(python3 -c "import json; d=json.load(open('${AGENT_STATE}')); print(d.get('current_task',{}).get('task_branch') or '')" 2>/dev/null || echo "")
  LAST_ACTION=$(python3 -c "import json; d=json.load(open('${AGENT_STATE}')); print(d.get('current_task',{}).get('last_action') or '')" 2>/dev/null || echo "")

  echo ""
  echo "  phase:        ${AGENT_PHASE}"
  echo "  task_id:      ${CURRENT_TASK}"
  echo "  task_phase:   ${TASK_PHASE}"
  echo "  target_repo:  ${TARGET_REPO:-none}"
  echo "  task_branch:  ${TASK_BRANCH:-none}"
  echo "  last_action:  ${LAST_ACTION:-none}"
}

# ── Step 1: Recovery check ────────────────────────────────────────────────────
run_recovery() {
  header "Step 1: Recovery Check"

  # 1a. Sync docs first (always)
  info "syncing livemask-docs/dev..."
  cd "${DOCS_DIR}"
  if git switch dev 2>/dev/null && git pull --ff-only origin dev 2>/dev/null; then
    DOCS_HEAD=$(git rev-parse --short HEAD)
    ok "docs/dev at ${DOCS_HEAD}"
  else
    fail "docs/dev sync failed — may be dirty or diverged"
  fi

  # 1a2. Sync ci-cd (so Claude picks up script updates)
  info "syncing livemask-ci-cd/dev..."
  cd "${CI_CD_DIR}"
  if git switch dev 2>/dev/null && git pull --ff-only origin dev 2>/dev/null; then
    CI_CD_HEAD=$(git rev-parse --short HEAD)
    ok "ci-cd/dev at ${CI_CD_HEAD}"
  else
    warn "ci-cd/dev sync failed — running with local scripts, may miss updates"
  fi

  # 1b. Check for orphaned task branches
  info "scanning for orphaned task branches..."
  local orphaned=0
  for repo_dir in "${LIVEMASK_ROOT}"/livemask-*/; do
    local repo_name
    repo_name=$(basename "${repo_dir}")
    [[ "${repo_name}" == "livemask-docs" ]] && continue
    [[ "${repo_name}" == "livemask-ci-cd" ]] && continue
    [[ ! -d "${repo_dir}/.git" ]] && continue

    cd "${repo_dir}"
    local branches
    branches=$(git branch --list 'task/*' --format='%(refname:short)' 2>/dev/null || true)
    if [[ -n "${branches}" ]]; then
      while IFS= read -r branch; do
        [[ -z "${branch}" ]] && continue
        local branch_sha
        branch_sha=$(git rev-parse --short "${branch}" 2>/dev/null || echo "?")
        local branch_date
        branch_date=$(git log -1 --format=%ar "${branch}" 2>/dev/null || echo "?")
        echo "  ${repo_name}: ${branch} (${branch_sha}, ${branch_date})"
        orphaned=$((orphaned + 1))
      done <<< "${branches}"
    fi
  done

  if [[ "${orphaned}" -eq 0 ]]; then
    ok "no orphaned task branches"
  else
    warn "${orphaned} task branch(es) found — if current_task is null, these need attention"
  fi

  # 1c. Check for dirty worktrees
  info "checking for dirty worktrees..."
  local dirty=0
  cd "${DOCS_DIR}"
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    warn "livemask-docs: DIRTY"
    dirty=$((dirty + 1))
  fi
  for repo_dir in "${LIVEMASK_ROOT}"/livemask-backend "${LIVEMASK_ROOT}"/livemask-admin; do
    local rn
    rn=$(basename "${repo_dir}")
    [[ ! -d "${repo_dir}/.git" ]] && continue
    cd "${repo_dir}"
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
      warn "${rn}: DIRTY"
      dirty=$((dirty + 1))
    fi
  done
  if [[ "${dirty}" -eq 0 ]]; then
    ok "all worktrees clean"
  fi

  # 1d. Decision
  if [[ "${AGENT_PHASE}" != "idle" && "${AGENT_PHASE}" != "idle_monitor" ]]; then
    echo ""
    echo -e "${BOLD}${YELLOW}>>> RECOVERY PATH: phase=${AGENT_PHASE}, task=${CURRENT_TASK}${RESET}"
    echo "  task_phase: ${TASK_PHASE}"
    echo "  last_action: ${LAST_ACTION:-none}"
    echo ""
    echo "  Claude must:"
    echo "  1. Read agent-state.json for recovery context"
    echo "  2. bash ${ADAPTER_LIB} task-context ${CURRENT_TASK}"
    echo "  3. Read the required_first_reads from the context bundle"
    echo "  4. Continue from last_action: ${LAST_ACTION:-none}"
    echo "  5. Do NOT accept new tasks until this one reaches closure"
    return 10  # signal: recovery path
  fi

  ok "no recovery needed — agent phase is ${AGENT_PHASE}"
  return 0
}

# ── Step 1.5: Quick Health Pulse (critical checks only) ──────────────────────
quick_health_pulse() {
  echo ""
  echo -e "  ${CYAN}[..]${RESET} quick health pulse..."
  local pulse_ok=0

  # Check PM lease (don't start if another agent is working)
  local lease_file="${HOME}/.claude/role-cache/pm-lease.json"
  if [[ -f "${lease_file}" ]]; then
    local holder age; read -r holder age <<< "$(python3 -c "
import json, time
d = json.load(open('${lease_file}'))
age = (time.time() - d.get('started_at_epoch',0)) / 60
print(d.get('agent','?'), f'{age:.0f}')
" 2>/dev/null || echo "? 0")"
    if [[ "${holder}" != "claude-pm-backup" && "${age}" -lt 15 ]]; then
      echo -e "  ${YELLOW}[WAIT]${RESET} PM lease held by ${holder} (${age}min) — may conflict with PM cycle"
    else
      pulse_ok=$((pulse_ok + 1))
    fi
  else
    pulse_ok=$((pulse_ok + 1))
  fi

  # Check planner anomaly (ready tasks but 0 candidates)
  local ready ledger_ready; ledger_ready=$(python3 -c "
import json
d = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
print(sum(1 for m in d.get('modules',[]) for t in m.get('tasks',[]) if t.get('status')=='ready'))
" 2>/dev/null || echo "0")
  if [[ "${ledger_ready}" -gt 0 ]]; then
    local planner_c; planner_c=$(python3 "${DOCS_DIR}/scripts/plan-next-tasks.py" --format json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['summary']['candidate_count'])" 2>/dev/null || echo "0")
    if [[ "${planner_c}" == "0" ]]; then
      echo -e "  ${YELLOW}[WARN]${RESET} Planner anomaly: ${ledger_ready} ready tasks in ledger but planner shows 0 candidates"
    else
      pulse_ok=$((pulse_ok + 1))
    fi
  else
    pulse_ok=$((pulse_ok + 1))
  fi

  [[ "${pulse_ok}" -ge 2 ]] && echo -e "  ${GREEN}[OK]${RESET} health pulse: clear"
}

# ── Step 2: Preflight ─────────────────────────────────────────────────────────
run_preflight() {
  header "Step 2: Preflight"
  local preflight_rc=0
  local preflight_output

  preflight_output=$(bash "${CI_CD_DIR}/scripts/claude-loop-preflight.sh" 2>&1) || preflight_rc=$?

  # Extract signal counts for routing (safe grep — see preflight.sh SIGNAL lines)
  local review_count=0 reconcile_count=0
  if echo "${preflight_output}" | grep -q "REVIEW_REQUIRED:" 2>/dev/null; then
    review_count=$(echo "${preflight_output}" | grep -c "REVIEW_REQUIRED:" 2>/dev/null || true)
    review_count=$(echo "${review_count}" | tr -d '[:space:]')
  fi
  if echo "${preflight_output}" | grep -q "RECONCILE_REQUIRED:" 2>/dev/null; then
    reconcile_count=$(echo "${preflight_output}" | grep -c "RECONCILE_REQUIRED:" 2>/dev/null || true)
    reconcile_count=$(echo "${reconcile_count}" | tr -d '[:space:]')
  fi

  # Print preflight output
  echo "${preflight_output}"

  # Save signal counts for main flow consumption
  export PREFLIGHT_REVIEW_COUNT="${review_count}"
  export PREFLIGHT_RECONCILE_COUNT="${reconcile_count}"

  echo ""
  case "${preflight_rc}" in
    0)
      # IDLE: only if no REVIEW_REQUIRED or RECONCILE_REQUIRED signals (defense in depth)
      if [[ "${review_count}" -gt 0 ]] || [[ "${reconcile_count}" -gt 0 ]]; then
        echo -e "${BOLD}${YELLOW}>>> preflight: WORK_AVAILABLE (REVIEW_REQUIRED=${review_count}, RECONCILE_REQUIRED=${reconcile_count})${RESET}"
        preflight_rc=1
      else
        ok "preflight: IDLE — no work, no blockers, no review actions"
      fi
      ;;
    1) echo -e "${BOLD}${YELLOW}>>> preflight: WORK_AVAILABLE — must act before declaring idle${RESET}";;
    2) echo -e "${BOLD}${RED}>>> preflight: BLOCKED — resolve blockers first${RESET}";;
    *) warn "preflight: unexpected exit code ${preflight_rc}";;
  esac
  return "${preflight_rc}"
}

# ── Step 3: Build task context ────────────────────────────────────────────────
build_task_context() {
  header "Step 3: Task Context"

  # 3a. Check dispatch packets first (Codex-assigned tasks)
  info "checking dispatch packets..."
  local dispatch_task=""
  local dp_dir="${DOCS_DIR}/docs/development/dispatch-packets"
  if [[ -d "${dp_dir}" ]]; then
    for dp in "${dp_dir}"/TASK-*.json; do
      [[ -f "${dp}" ]] || continue
      local dp_task dp_repo dp_assigned
      read -r dp_task dp_repo dp_assigned <<< "$(python3 -c "
import json
d = json.load(open('${dp}'))
print(d.get('task_id',''), d.get('repo',''), d.get('assigned_to',''))
" 2>/dev/null || echo "? ? ?")"
      # Check if not already leased
      if ! python3 "${DOCS_DIR}/scripts/check-task-leases.py" 2>/dev/null | grep -q "${dp_task}"; then
        if [[ -n "${dp_task}" ]]; then
          dispatch_task="${dp_task}|${dp_repo}|dispatch_packet|P1"
          ok "found dispatch packet: ${dp_task} (${dp_repo}) assigned to ${dp_assigned}"
          break
        fi
      fi
    done
  fi

  if [[ -z "${dispatch_task}" ]]; then
    echo "  no unleased dispatch packets — falling back to planner"
  fi

  # 3b. Get top task (dispatch packet first, then planner fallback)
  local top_task="${dispatch_task}"
  if [[ -z "${top_task}" ]]; then
    info "planner fallback..."
    top_task=$(python3 "${DOCS_DIR}/scripts/plan-next-tasks.py" --format json 2>/dev/null | \
      python3 -c "
import json,sys
d = json.load(sys.stdin)
tasks = [t for t in d.get('global_next',[]) if t.get('readiness') == 'dispatch_now']
if tasks:
    t = tasks[0]
    print(f\"{t['task_id']}|{t['repo']}|{t['status']}|{t['priority']}\")
else:
    print('NONE')
" 2>/dev/null || echo "NONE")
  fi

  if [[ "${top_task}" == "NONE" ]]; then
    warn "no dispatch_now tasks — checking for dispatch_for_evidence..."
    top_task=$(python3 "${DOCS_DIR}/scripts/plan-next-tasks.py" --format json 2>/dev/null | \
      python3 -c "
import json,sys
d = json.load(sys.stdin)
tasks = [t for t in d.get('global_next',[]) if t.get('readiness') in ('dispatch_for_evidence','dispatch_with_issue_gap')]
if tasks:
    t = tasks[0]
    print(f\"{t['task_id']}|{t['repo']}|{t['status']}|{t['priority']}\")
else:
    print('NONE')
" 2>/dev/null || echo "NONE")
  fi

  if [[ "${top_task}" == "NONE" ]]; then
    warn "no dispatchable tasks found — checking open modules..."
    python3 "${DOCS_DIR}/scripts/plan-next-tasks.py" --format json 2>/dev/null | \
      python3 -c "
import json,sys
d = json.load(sys.stdin)
modules = d.get('open_modules',[])
for m in modules[:5]:
    print(f\"  {m['module_id']}: {m['overall_status']}\")
"
    # ── Fallback: task decomposition when queue is empty ──────────────────
    fallback_task_decomposition
    return 1
  fi

  local task_id repo status priority
  task_id="${top_task%%|*}"
  top_task="${top_task#*|}"
  repo="${top_task%%|*}"
  top_task="${top_task#*|}"
  status="${top_task%%|*}"
  priority="${top_task##*|}"

  echo ""
  echo -e "${BOLD}Top dispatchable task:${RESET}"
  echo "  task_id:   ${task_id}"
  echo "  repo:      ${repo}"
  echo "  status:    ${status}"
  echo "  priority:  ${priority}"

  # Build the context bundle
  echo ""
  info "building context bundle..."
  bash "${ADAPTER_LIB}" task-context "${task_id}" 2>/dev/null | python3 -c "
import json,sys
bundle = json.load(sys.stdin)
print(f\"  required_first_reads: {len(bundle.get('required_first_reads',[]))} files\")
for f in bundle.get('required_first_reads',[]):
    mark = '[EXISTS]' if f.get('exists') else '[MISSING]'
    print(f\"    {mark} {f['path']} — {f.get('reason','')}\")
print(f\"  domain_roots: {len(bundle.get('domain_roots',[]))} dirs\")
print(f\"  recommended_searches: {len(bundle.get('recommended_searches',[]))}\")
reminders = bundle.get('closure_reminders',[])
if reminders:
    print(f\"  closure_reminders: {len(reminders)}\")
    for r in reminders:
        print(f\"    REMINDER: {r}\")
" 2>/dev/null || warn "could not parse context bundle"

  # Also show ledger entry
  echo ""
  info "ledger entry:"
  bash "${ADAPTER_LIB}" task-ledger-entry "${task_id}" 2>/dev/null | python3 -c "
import json,sys
entry = json.load(sys.stdin)
print(f\"  status:     {entry.get('status','?')}\")
print(f\"  repo:       {entry.get('repo','?')}\")
print(f\"  issue:      {entry.get('issue','?')}\")
print(f\"  validation: {entry.get('validation','?')[:120]}\")
blocked = entry.get('blocked_by',[])
if blocked:
    print(f\"  blocked_by: {', '.join(blocked)}\")
notes = entry.get('notes','')
if notes:
    print(f\"  notes:      {notes[:200]}\")
" 2>/dev/null || warn "could not parse ledger entry"

  # Show repo doc hints
  echo ""
  info "repo doc hints:"
  bash "${ADAPTER_LIB}" repo-doc-hints "${repo}" 2>/dev/null | while IFS=$'\t' read -r r p; do
    echo "  ${r}: ${p}"
  done || true

  return 0
}

# ── Fallback: Task decomposition when planner queue is empty ──────────────────
fallback_task_decomposition() {
  header "Fallback: Task Decomposition"

  echo ""
  echo -e "  ${BOLD}${YELLOW}Queue is empty. Running autonomous task decomposition...${RESET}"
  echo ""

  local created=0

  # 1. Scan Ready contracts for unimplemented tasks
  info "scanning Ready contracts for gaps..."
  CONTRACT_COUNT=$(python3 -c "
import json
from pathlib import Path

docs_dir = Path('${DOCS_DIR}')
ledger = json.loads((docs_dir / 'docs/development/task-state-ledger.json').read_text())

# Collect all task IDs in ledger
all_tasks = set()
for m in ledger.get('modules', []):
    for t in m.get('tasks', []):
        tid = t.get('task_id', '')
        if tid:
            all_tasks.add(tid)

# Read contract index
contract_index = docs_dir / 'docs/contracts/contract-index.md'
if not contract_index.exists():
    print('CONTRACT_INDEX_MISSING')
    exit(0)

content = contract_index.read_text()
import re
# Find Ready contracts and their primary tasks
ready_contracts = []
for line in content.split('\n'):
    if '| Ready |' in line and 'TASK-' in line:
        match = re.search(r'TASK-[A-Z0-9-]+', line)
        if match:
            tid = match.group(0)
            if tid not in all_tasks:
                ready_contracts.append(line.strip()[:120])

if ready_contracts:
    for c in ready_contracts[:5]:
        print(f'GAP: {c}')
else:
    print('NO_GAPS')
" 2>/dev/null || echo "PARSE_ERROR")

  if echo "${CONTRACT_COUNT}" | grep -q "GAP:"; then
    echo "${CONTRACT_COUNT}" | grep "GAP:" | while read -r line; do
      echo "  ${line}"
    done
  else
    echo "  No contract gaps detected"
  fi

  # 2. Check open modules for gaps
  info "checking open modules for actionable gaps..."
  python3 "${DOCS_DIR}/scripts/plan-next-tasks.py" --format json 2>/dev/null | \
    python3 -c "
import json,sys
d = json.load(sys.stdin)
modules = d.get('open_modules',[])
gaps = d.get('automation_gaps',{})
print(f'  open_modules: {len(modules)}')
print(f'  missing_issue: {len(gaps.get(\"missing_issue\",[]))}')
print(f'  needs_runtime_evidence: {len(gaps.get(\"needs_runtime_evidence\",[]))}')
" 2>/dev/null || true

  # 3. §0.2: fallback SAP/inbox artifacts are obsolete. Role-engine PM-3
  # creates real TASK/ledger/dispatch packets instead of delegating back to Codex.
  if echo "${CONTRACT_COUNT}" | grep -q "GAP:"; then
    echo ""
    info "Ready gaps detected; §0.2 requires role-engine PM-3 self-decomposition."
    echo "  No fallback SAP or requirements-inbox file was created."
    echo "  Next actor: claude-pm-backup role-engine PM-3"
    created=1
  fi

  # 4. Summary
  echo ""
  if [[ "${created}" -eq 1 ]]; then
    echo -e "  ${BOLD}${YELLOW}Fallback meta-artifact creation skipped by design.${RESET}"
    echo "  PM-3 must create real task docs, ledger entries, and dispatch packets."
  else
    echo "  No actionable gaps found. System may be fully built or require manual planning."
  fi

  return 0
}

# ── Step 3.5: Active idle poll (replaces passive sleep) ──────────────────────
active_idle_poll() {
  header "Step 3.5: Active Idle Monitor"

  local poll_seconds="${1:-120}"
  local max_cycles="${2:-30}"  # 30 cycles * 2min = 60min max
  local cycle=0

  echo ""
  echo -e "  ${BOLD}${CYAN}Queue empty. Actively polling origin/dev every ${poll_seconds}s (max ${max_cycles} cycles)...${RESET}"
  echo "  Claude will wake immediately when Codex pushes new tasks."
  echo ""

  local baseline_sha
  baseline_sha=$(git -C "${DOCS_DIR}" ls-remote origin dev | awk '{print $1}')
  echo "  baseline: ${baseline_sha:0:7}"

  while [[ "${cycle}" -lt "${max_cycles}" ]]; do
    sleep "${poll_seconds}"
    cycle=$((cycle + 1))

    local current_sha
    current_sha=$(git -C "${DOCS_DIR}" ls-remote origin dev 2>/dev/null | awk '{print $1}')
    [[ -z "${current_sha}" ]] && continue

    if [[ "${current_sha}" != "${baseline_sha}" ]]; then
      echo ""
      echo -e "  ${BOLD}${GREEN}[WAKE] origin/dev changed: ${baseline_sha:0:7} → ${current_sha:0:7}${RESET}"
      echo "  Re-running preflight..."

      # Pull new state
      cd "${DOCS_DIR}" && git pull --ff-only origin dev 2>/dev/null
      cd "${CI_CD_DIR}" && git pull --ff-only origin dev 2>/dev/null

      # Re-run preflight to check for new work
      local new_rc=0
      bash "${CI_CD_DIR}/scripts/claude-loop-preflight.sh" 2>&1 | tail -20 || new_rc=$?

      if [[ "${new_rc}" -ne 0 ]]; then
        echo ""
        echo -e "  ${BOLD}${GREEN}>>> WORK FOUND. Breaking idle loop to accept task.${RESET}"
        return 1  # Signal: work available, re-enter task acceptance
      fi

      baseline_sha="${current_sha}"
      echo "  (preflight still IDLE, continuing to poll)"
    fi

    # Every 5 cycles, print a heartbeat
    if [[ $((cycle % 5)) -eq 0 ]]; then
      echo "  [heartbeat cycle ${cycle}/${max_cycles}] still watching..."
    fi
  done

  echo ""
  echo "  Max idle cycles reached (${max_cycles}). Exiting monitor."
  echo "  Next cron trigger will restart the loop."
  return 0
}

# ── Step 4: Fixed channels ───────────────────────────────────────────────────
check_fixed_channels() {
  header "Step 4: Fixed Control Channels"

  for pair in "MyAiDevs/livemask-ci-cd:14" "MyAiDevs/livemask-docs:68"; do
    local repo="${pair%%:*}"
    local num="${pair##*:}"
    info "${repo}#${num}..."

    local summary
    summary=$(gh issue view "${num}" --repo "${repo}" --json state,updatedAt,comments --jq '
"state=\(.state) updated=\(.updatedAt) comments=\(.comments | length)"
' 2>/dev/null || echo "FETCH_FAILED")

    echo "  ${summary}"

    # Check latest comment for actionable keywords
    local latest_keywords
    latest_keywords=$(gh issue view "${num}" --repo "${repo}" --json comments --jq '
[.comments[-1].body | scan("ACTION_NEEDED|RULE_UPDATE|ENFORCE|PROCESS_DEFECT|WAIT_TASK|WAIT_CI|PERMANENT_CHANNEL")] | join(",")
' 2>/dev/null || echo "")

    if [[ -n "${latest_keywords}" ]]; then
      echo -e "  ${RED}>>> latest comment contains: ${latest_keywords}${RESET}"
    else
      ok "no actionable keywords in latest comment"
    fi
  done
}

# ── Step 5: Event cache ──────────────────────────────────────────────────────
check_event_cache() {
  header "Step 5: Event Cache (accelerator only)"
  local cache_file="${LIVEMASK_ROOT}/.claude/event-cache/event-cache.jsonl"

  if [[ ! -f "${cache_file}" ]]; then
    info "no event cache — first run or pollers not yet executed"
    return 0
  fi

  local line_count
  line_count=$(wc -l < "${cache_file}" 2>/dev/null | tr -d ' ' || echo "0")
  echo "  events in cache: ${line_count}"

  if [[ "${line_count}" -gt 0 ]]; then
    local last_events
    last_events=$(tail -5 "${cache_file}" 2>/dev/null | python3 -c "
import json,sys
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        e = json.loads(line)
        print(f\"  {e.get('event_type','?')} | {e.get('source','?')} | {e.get('ts','?')}\")
    except: pass
" 2>/dev/null || echo "  (parse error)")
    echo "${last_events}"
  fi

  echo ""
  echo "  Event cache is accelerator only. Authoritative state is GitHub + ledger."
}

# ── Step 6: Decision summary ─────────────────────────────────────────────────
# Accepts: $1 = preflight exit code (0=IDLE, 1=WORK_AVAILABLE, 2=BLOCKED)
#          $2 = review signal count (REVIEW_REQUIRED)
#          $3 = reconcile signal count (RECONCILE_REQUIRED)
decision_summary() {
  local pf_rc="${1:-0}"
  local review_ct="${2:-0}"
  local reconcile_ct="${3:-0}"

  header "Step 6: Decision"

  echo ""
  echo -e "${BOLD}══════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}  STARTUP COMPLETE${RESET}"
  echo -e "${BOLD}══════════════════════════════════════════════${RESET}"
  echo ""
  echo "  agent phase:   ${AGENT_PHASE}"
  echo "  current task:  ${CURRENT_TASK}"
  echo "  task phase:    ${TASK_PHASE}"
  echo "  preflight:     exit=${pf_rc} review=${review_ct} reconcile=${reconcile_ct}"

  # ── RECOVERY PATH: non-idle agent phase ────────────────────────────────
  if [[ "${AGENT_PHASE}" != "idle" && "${AGENT_PHASE}" != "idle_monitor" ]]; then
    echo ""
    echo -e "  ${BOLD}${YELLOW}>>> RECOVERING: Continue ${CURRENT_TASK} from phase ${TASK_PHASE}${RESET}"
    echo "  Last action: ${LAST_ACTION:-none}"
    echo ""
    echo "  NEXT: bash ${ADAPTER_LIB} task-context ${CURRENT_TASK}"
    return 0
  fi

  # ── BLOCKED: preflight exit 2 ──────────────────────────────────────────
  if [[ "${pf_rc}" -eq 2 ]]; then
    echo ""
    echo -e "  ${BOLD}${RED}>>> BLOCKED: Must resolve blockers before any other action${RESET}"
    echo ""
    echo "  REQUIRED:"
    echo "  1. Address each BLOCKED: reason in the preflight output above"
    echo "  2. For CI failures: diagnose, fix, re-push, wait for CI pass"
    echo "  3. For SAP blockers: ack, resolve, archive per supervisor rules"
    echo "  4. Re-run preflight after each resolution"
    echo "  5. DO NOT accept new tasks until preflight returns IDLE or WORK_AVAILABLE"
    return 0
  fi

  # ── REVIEW_REQUIRED / RECONCILE_REQUIRED take priority over new tasks ──
  if [[ "${review_ct}" -gt 0 ]]; then
    echo ""
    echo -e "  ${BOLD}${YELLOW}>>> REVIEW_REQUIRED: ${review_ct} review contract(s) need Claude action${RESET}"
    echo ""
    echo "  REQUIRED before accepting new tasks:"
    echo "  1. Read the review contract(s) under docs/development/review-contracts/"
    echo "  2. If state=changes_requested: read Codex findings, revise, re-submit"
    echo "  3. If state=approved: proceed to merge + ledger reconciliation"
    echo "  4. Update agent-state.json: phase=revising or phase=merging"
    echo "  5. DO NOT skip to new task dispatch while review contracts are pending"
  fi

  if [[ "${reconcile_ct}" -gt 0 ]]; then
    echo ""
    echo -e "  ${BOLD}${YELLOW}>>> RECONCILE_REQUIRED: ${reconcile_ct} ledger/task-doc entr(ies) need synchronization${RESET}"
    echo ""
    echo "  REQUIRED before declaring clean:"
    echo "  1. Read the stale ledger entries listed in preflight above"
    echo "  2. Update task-state-ledger.json and/or task doc on a task/* branch"
    echo "  3. Run bash scripts/check-docs.sh && git diff --check"
    echo "  4. Merge through dev-merge-guard.sh"
    echo "  5. DO NOT report Clean/idle while RECONCILE_REQUIRED signals remain"
  fi

  # ── WORK_AVAILABLE: must accept work, CANNOT enter monitoring ───────────
  if [[ "${pf_rc}" -eq 1 ]]; then
    if [[ "${review_ct}" -eq 0 && "${reconcile_ct}" -eq 0 ]]; then
      echo ""
      echo -e "  ${BOLD}${GREEN}>>> WORK_AVAILABLE: Must accept task from planner queue${RESET}"
      echo ""
      echo "  HARD RULE: preflight exit=1 means work exists. Declaring idle is a PROCESS_DEFECT."
      echo ""
      echo "  BEFORE implementing:"
      echo "  1. Read ALL required_first_reads from the context bundle above"
      echo "  2. Read the relevant domain docs for the target repo"
      echo "  3. Read the linked GitHub issue (body + comments)"
      echo "  4. Read the task doc under docs/development/tasks/"
      echo "  5. Run the recommended searches for existing references"
      echo "  6. Update agent-state.json: phase=implementing"
    fi
    return 0
  fi

  # ── IDLE: only reachable when pf_rc=0 AND no review/reconcile signals ──
  echo ""
  echo -e "  ${BOLD}${GREEN}>>> IDLE: No work, no blockers, no review actions. Entering monitor mode.${RESET}"
  echo ""
  echo "  Wake triggers: new SAP, planner candidate, review contract update,"
  echo "                 #14/#68 actionable comment, CI failure, manual /loop"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
case "${MODE}" in
  --recovery)
    read_agent_state
    run_recovery
    decision_summary 0 0 0
    ;;
  --quick)
    read_agent_state
    if [[ "${AGENT_PHASE}" != "idle" && "${AGENT_PHASE}" != "idle_monitor" ]]; then
      run_recovery
      decision_summary 0 0 0
    else
      echo "quick mode: agent is idle, nothing to recover"
    fi
    ;;
  *)
    read_agent_state

    # If in a non-idle phase, go straight to recovery
    if [[ "${AGENT_PHASE}" != "idle" && "${AGENT_PHASE}" != "idle_monitor" ]]; then
      run_recovery
      decision_summary
      exit $?
    fi

    # Full startup: recovery + health pulse + preflight + context + channels + cache
    run_recovery || true  # recovery warnings don't block
    quick_health_pulse
    preflight_rc=0
    run_preflight || preflight_rc=$?

    # Read signal counts from exported vars (set by run_preflight)
    review_signal_count="${PREFLIGHT_REVIEW_COUNT:-0}"
    reconcile_signal_count="${PREFLIGHT_RECONCILE_COUNT:-0}"

    if [[ "${preflight_rc}" -eq 2 ]]; then
      echo ""
      echo -e "${BOLD}${RED}BLOCKED — resolve the blockers listed above before accepting tasks.${RESET}"
      decision_summary 2 "${review_signal_count}" "${reconcile_signal_count}"
      log_summary "startup" 2 "BLOCKED" 2>/dev/null || true
      exit 2
    fi

    # Always build context so Claude knows what to read
    build_task_context || warn "context build returned non-zero"

    # Remaining checks (informational — don't block on cache being stale)
    check_fixed_channels || true
    check_event_cache || true

    # HARD GATE: if preflight_rc != 0, decision_summary enforces action (never monitoring)
    decision_summary "${preflight_rc}" "${review_signal_count}" "${reconcile_signal_count}"

    # ── Task Execution Summary ──────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}${CYAN}═══ Cycle Report ═══${RESET}"
    echo "  preflight:      $( [[ ${preflight_rc} -eq 0 ]] && echo -e "${GREEN}IDLE${RESET}" || ([[ ${preflight_rc} -eq 2 ]] && echo -e "${RED}BLOCKED${RESET}" || echo -e "${YELLOW}WORK${RESET}") )"
    echo "  candidates:     ${candidate_count:-0} dispatchable, ${blocked_count:-0} blocked"
    echo "  dispatch pkts:  $(ls "${DOCS_DIR}/docs/development/dispatch-packets"/TASK-*.json 2>/dev/null | wc -l | tr -d ' ' || echo "0")"
    echo "  findings:       ${FINDINGS_WARNING:-0} warnings, ${FINDINGS_BLOCKER:-0} blockers"
    echo "  review:         ${review_signal_count} contracts need action"
    echo "  reconcile:      ${reconcile_signal_count} ledger entries stale"
    echo "  CI:             $(gh run list --repo MyAiDevs/livemask-backend --branch dev --limit 1 --json conclusion --jq '.[0].conclusion' 2>/dev/null || echo '?') (backend) | $(gh run list --repo MyAiDevs/livemask-admin --branch dev --limit 1 --json conclusion --jq '.[0].conclusion' 2>/dev/null || echo '?') (admin)"
    echo "  PM lease:       $(cat ${HOME}/.claude/role-cache/pm-lease.json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(f\"{d.get(\"agent\",\"none\")} ({d.get(\"phase\",\"?\")})\")' 2>/dev/null || echo 'none')"
    echo "  logs:           tail -30 /tmp/claude/latest-startup.log"
    echo ""

    # Lark notification
    lark_card_preflight "${preflight_rc}" "${pf_label:-IDLE}" "${candidate_count:-0}" "${blocked_count:-0}" \
      "${FINDINGS_WARNING:-0}" "${ci_status:-?}" "${review_signal_count}" "${reconcile_signal_count}" 2>/dev/null || true

    # If IDLE (exit 0), enter active polling instead of passive sleep
    if [[ "${preflight_rc}" -eq 0 ]]; then
      log_summary "startup" 0 "IDLE → active poll" 2>/dev/null || true
      active_idle_poll 120 30 || {
        # active_idle_poll returned 1 = work detected during polling
        echo ""
        echo -e "${BOLD}${GREEN}>>> Work detected during idle poll. Re-entering task acceptance...${RESET}"
        # Re-run preflight to get fresh state
        run_preflight || preflight_rc=$?
        if [[ "${preflight_rc}" -eq 2 ]]; then
          decision_summary 2 "${PREFLIGHT_REVIEW_COUNT:-0}" "${PREFLIGHT_RECONCILE_COUNT:-0}"
          exit 2
        fi
        build_task_context || true
        check_fixed_channels || true
        decision_summary "${preflight_rc}" "${PREFLIGHT_REVIEW_COUNT:-0}" "${PREFLIGHT_RECONCILE_COUNT:-0}"
      }
    fi
    ;;
esac
