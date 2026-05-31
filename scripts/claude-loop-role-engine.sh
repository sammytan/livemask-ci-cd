#!/usr/bin/env bash
# TASK-CICD-CLAUDE-ROLE-ENGINE-V2-001
# Multi-role reasoning engine. Each role does 3 deep analysis points, each
# tracing the "why" chain to root cause. Script gathers context, Claude reasons.
#
# Principle: Every detection MUST answer "why did this happen?" and produce
# a concrete next action. Nothing is just printed and forgotten.
#
# Roles: pm | product | tech | qa | deep-review | closure-audit | impact-analysis
# Usage: bash scripts/claude-loop-role-engine.sh <role> [TASK-ID]
set -euo pipefail

LIVEMASK_ROOT="/Users/sammytan/Developer/LiveMask"
DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"
ROLE_CACHE_DIR="${LIVEMASK_ROOT}/.claude/role-cache"
FINDINGS_FILE="${ROLE_CACHE_DIR}/findings.jsonl"
AGENT_STATE="${LIVEMASK_ROOT}/.claude/agent-state.json"
LEASE_FILE="${DOCS_DIR}/docs/development/leases/task-leases.json"
DISPATCH_DIR="${DOCS_DIR}/docs/development/dispatch-packets"
ROLE="${1:-pm}"
ARG2="${2:-}"

mkdir -p "${ROLE_CACHE_DIR}"
: > "${FINDINGS_FILE}"  # truncate for this cycle

BOLD="\033[1m" GREEN="\033[32m" YELLOW="\033[33m" RED="\033[31m" CYAN="\033[36m" RESET="\033[0m"
H1() { echo -e "\n${BOLD}${CYAN}═══ $* ═══${RESET}"; }
OK() { echo -e "  ${GREEN}[OK]${RESET} $*"; }
WARN(){ echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
ACT() { echo -e "  ${RED}[ACT]${RESET} $*"; }
ASK() { echo -e "  ${BOLD}[REASON]${RESET} $*"; }
NEXT(){ echo -e "  ${BOLD}${GREEN}[NEXT]${RESET} $*"; }

# ── Shared: findings recording (machine-readable output) ──────────────────────
# Severity: blocker (must fix) > warning (should fix) > info (FYI)
record_finding() {
  local role="$1" severity="$2" task_id="${3:-}" check="$4" finding="$5" next="${6:-}" cmd="${7:-}"
  FINDINGS_FILE="${FINDINGS_FILE}" NOW_SHA_FULL="${NOW_SHA_FULL:-}" python3 - \
    "${role}" "${severity}" "${task_id}" "${check}" "${finding}" "${next}" "${cmd}" <<'PY'
import json, os, sys
role, severity, task_id, check, finding, nxt, cmd = sys.argv[1:8]
entry = {
    "role": role,
    "severity": severity,
    "task_id": task_id,
    "check": check,
    "finding": finding,
    "next": nxt,
    "cmd": cmd,
    "docs_head": os.environ.get("NOW_SHA_FULL", ""),
}
path = os.environ["FINDINGS_FILE"]
with open(path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(entry, ensure_ascii=False) + "\n")
PY
}

print_top_actions() {
  local count="${1:-3}"
  echo ""
  echo -e "${BOLD}${CYAN}═══ Top-${count} Priority Actions ═══${RESET}"

  if [[ ! -f "${FINDINGS_FILE}" ]] || [[ $(wc -l < "${FINDINGS_FILE}" 2>/dev/null || echo "0") -eq 0 ]]; then
    OK "no findings — system appears healthy"
    return 0
  fi

  # Sort by severity (blocker > warning > info), print top N
  python3 -c "
import json
severity_order = {'blocker': 0, 'warning': 1, 'info': 2}
findings = []
with open('${FINDINGS_FILE}') as f:
    for line in f:
        line = line.strip()
        if line: findings.append(json.loads(line))
findings.sort(key=lambda f: severity_order.get(f.get('severity','info'), 3))

for i, f in enumerate(findings[:${count}]):
    sev = f['severity'].upper()
    print(f\"{i+1}. [{sev}] [{f['role']}-{f['check']}] {f['finding']}\")
    if f.get('task_id'): print(f\"   task: {f['task_id']}\")
    if f.get('next'): print(f\"   next: {f['next']}\")
    if f.get('cmd'): print(f\"   cmd: {f['cmd']}\")
    print()
print(f'Total findings: {len(findings)} (${FINDINGS_FILE})')
" 2>/dev/null
}

# ── Shared: sync and cache ──────────────────────────────────────────────────
sync_all() {
  cd "${DOCS_DIR}" && git pull --ff-only origin dev 2>/dev/null || true
  cd "${CI_CD_DIR}" && git pull --ff-only origin dev 2>/dev/null || true
  NOW_SHA=$(git -C "${DOCS_DIR}" rev-parse --short HEAD 2>/dev/null || echo "?")
  NOW_SHA_FULL=$(git -C "${DOCS_DIR}" rev-parse HEAD 2>/dev/null || echo "")
}

# Shared intake aligned with CODEX_LOOP_RULES.md §2 and §12
preflight_context() {
  H1 "Preflight Context (Codex control-plane alignment)"
  sync_all
  echo "  docs_head: ${NOW_SHA}"

  # Claude agent state (read-only)
  if [[ -f "${AGENT_STATE}" ]]; then
    python3 -c "
import json
d = json.load(open('${AGENT_STATE}'))
task = d.get('current_task') or {}
print(f\"  claude agent: phase={d.get('phase','?')} task={task.get('task_id') or 'null'} repo={task.get('target_repo') or ''}\")
" 2>/dev/null || WARN "could not parse agent-state.json"
  else
    echo "  claude agent: (no agent-state.json)"
  fi

  # Active leases
  if [[ -f "${LEASE_FILE}" ]]; then
    python3 -c "
import json
data = json.load(open('${LEASE_FILE}'))
active = [l for l in data.get('leases', []) if l.get('status') == 'active']
print(f'  active leases: {len(active)}')
for l in active[:5]:
    print(f\"    {l.get('task_id','?')} owner={l.get('lease_owner','?')} repo={l.get('repo','?')}\")
" 2>/dev/null || true
  fi

  # Dispatch packets
  local pkt_count=0
  if [[ -d "${DISPATCH_DIR}" ]]; then
    pkt_count=$(find "${DISPATCH_DIR}" -maxdepth 1 -name 'TASK-*.json' 2>/dev/null | wc -l | tr -d ' ')
    echo "  dispatch packets: ${pkt_count}"
    for pf in "${DISPATCH_DIR}"/TASK-*.json; do
      [[ -f "${pf}" ]] || continue
      python3 -c "
import json, pathlib
p = json.load(open('${pf}'))
print(f\"    {p.get('task_id','?')} -> {p.get('assigned_to','?')} repo={p.get('repo','?')}\")
" 2>/dev/null
    done
  fi

  # Planner top candidate
  local planner_line
  planner_line=$(python3 "${DOCS_DIR}/scripts/plan-next-tasks.py" --format json 2>/dev/null | \
    python3 -c "
import json, sys
d = json.load(sys.stdin)
tasks = [t for t in d.get('global_next', []) if t.get('readiness') == 'dispatch_now']
if not tasks:
    print('NONE|0|0')
else:
    t = tasks[0]
    print(f\"{t['task_id']}|{t['repo']}|{d.get('summary',{}).get('candidate_count',0)}\")
" 2>/dev/null || echo "NONE|0|0")

  local top_task top_repo candidate_count
  top_task="${planner_line%%|*}"
  planner_line="${planner_line#*|}"
  top_repo="${planner_line%%|*}"
  candidate_count="${planner_line##*|}"

  if [[ "${top_task}" != "NONE" ]]; then
    echo "  planner top: ${top_task} (${top_repo}) candidates=${candidate_count}"
    local pkt="${DISPATCH_DIR}/${top_task}.json"
    if [[ -f "${pkt}" ]]; then
      OK "dispatch packet exists for top task"
      record_finding "shared" "info" "${top_task}" "PREFLIGHT" \
        "handoff pending: dispatch packet exists for ${top_task}" \
        "run claude-loop-startup.sh and ACK_TASK" \
        "bash ${CI_CD_DIR}/scripts/claude-loop-startup.sh"
    else
      WARN "top dispatch_now task has no packet yet — Codex should create one"
      record_finding "shared" "warning" "${top_task}" "PREFLIGHT" \
        "dispatch_now without packet: ${top_task}" \
        "wait for Codex dispatch or run startup only" \
        "bash ${CI_CD_DIR}/scripts/claude-loop-startup.sh"
    fi
  else
    echo "  planner top: (no dispatch_now tasks) candidates=${candidate_count}"
  fi

  if [[ -n "${LAST_SHA:-}" && "${LAST_SHA}" == "${NOW_SHA}" ]]; then
    echo "  docs unchanged since last role-engine run (${LAST_SHA})"
  fi
}

finish_role() {
  local role_name="$1"
  save_cache "${role_name}" "${2:-done}"
}

load_cache() {
  local role_name="$1"
  local cache="${ROLE_CACHE_DIR}/${role_name}-cache.json"
  if [[ -f "${cache}" ]]; then
    LAST_SHA=$(python3 -c "import json; print(json.load(open('${cache}')).get('last_sha',''))" 2>/dev/null || echo "")
    LAST_TIME=$(python3 -c "import json; print(json.load(open('${cache}')).get('updated_at',''))" 2>/dev/null || echo "")
    echo "  last cycle: ${LAST_TIME} (${LAST_SHA:0:7})"
  else
    LAST_SHA=""
    echo "  no cache — full analysis"
  fi
}

save_cache() {
  local role_name="$1"
  local summary="$2"
  python3 -c "
import json, time, pathlib
cache = {'schema_version':2, 'role':'${role_name}', 'updated_at':'$(date -u +%Y-%m-%dT%H:%M:%SZ)', 'updated_at_epoch':time.time(), 'last_sha':'${NOW_SHA}', 'summary':'${summary}'}
pathlib.Path('${ROLE_CACHE_DIR}/${role_name}-cache.json').write_text(json.dumps(cache, indent=2))
" 2>/dev/null
}

push_changes() {
  local msg="${1:-role-engine cycle}"
  cd "${DOCS_DIR}"
  if [[ -z "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "  (no changes to push)"
    return 0
  fi
  local changes; changes=$(git status --porcelain | wc -l | tr -d ' ')
  WARN "${changes} file(s) changed — NOT auto-pushing to dev (safety gate)"

  # Create task branch but DO NOT merge to dev automatically
  local br="task/role-$(date -u +%Y%m%d-%H%M%S)"
  git checkout -b "${br}" 2>/dev/null
  git add -A
  git commit -m "${msg}
Co-Authored-By: Claude Role Engine <noreply@anthropic.com>" 2>/dev/null

  echo ""
  echo "  Branch '${br}' created with ${changes} changes."
  echo "  To merge: bash ${CI_CD_DIR}/scripts/dev-merge-guard.sh ${br}"
  echo "  Or manually: git checkout dev && git merge ${br} --no-edit && git push origin dev"
  echo ""
  WARN "Changes saved to branch but NOT merged to dev. Merge requires explicit action."
}

# ── Helper: get ledger entry for a task ──────────────────────────────────────
ledger_get() {
  local tid="$1" field="$2"
  python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id') == '${tid}':
            print(t.get('${field}',''))
" 2>/dev/null || echo ""
}

# ── Helper: get all tasks with a given status ────────────────────────────────
ledger_filter() {
  local status="$1"
  python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('status') == '${status}':
            print(f\"{t['task_id']}|{t.get('repo','?')}|{t.get('issue','')}|{t.get('blocked_by',[])}|{t.get('validation','')[:80]}\")
" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
# PM: 3 deep reasoning points
# ══════════════════════════════════════════════════════════════════════════════

role_pm() {
  H1 "PM — Project Manager Reasoning"
  load_cache "pm"
  preflight_context

  # ── PM-1: WHY are there blocked tasks? Trace to root blocker ───────────────
  H1 "PM-1: Blocked Task Root Cause Analysis"

  local blocked_tasks
  blocked_tasks=$(ledger_filter "blocked")

  if [[ -z "${blocked_tasks}" ]]; then
    OK "no blocked tasks"
  else
    echo "  blocked tasks:"
    local pm1_list
    pm1_list=$(echo "${blocked_tasks}" | head -10)
    while IFS='|' read -r tid repo issue blockers validation; do
      [[ -z "${tid}" ]] && continue
      echo "    ${tid} (${repo})"

      # WHY is it blocked? Trace each blocker's status
      local blocker_list; blocker_list=$(echo "${blockers}" | tr -d '[]' | tr ',' '\n' | sed "s/'//g" | sed "s/ //g")
      for blocker in ${blocker_list}; do
        [[ -z "${blocker}" ]] && continue
        local b_status; b_status=$(ledger_get "${blocker}" "status")
        local b_repo; b_repo=$(ledger_get "${blocker}" "repo")
        local b_issue; b_issue=$(ledger_get "${blocker}" "issue")

        ASK "blocked by ${blocker} → WHY is ${blocker} not done?"

        echo "      blocker: ${blocker} (${b_repo}) | status=${b_status}"
        [[ -n "${b_issue}" ]] && echo "      issue: ${b_issue}"

        local b_blockers; b_blockers=$(ledger_get "${blocker}" "blocked_by")
        [[ -n "${b_blockers}" && "${b_blockers}" != "[]" ]] && echo "      meta-blocked: ${blocker} is blocked by ${b_blockers}"

        local brf="${DOCS_DIR}/docs/development/review-contracts/${blocker}-review.json"
        [[ -f "${brf}" ]] && python3 -c "
import json; d=json.load(open('${brf}'))
print(f\"      review: state={d.get('state')} actor={d.get('next_required_actor')}\")
" 2>/dev/null

        case "${b_status}" in
          blocked)
            ASK "→ ${blocker} itself is blocked — this is a CHAIN. Find the root blocker and fix it first."
            NEXT "Action: trace dependency chain to root → fix root → chain unblocks"
            record_finding "pm" "warning" "${tid}" "PM-1" "chain-blocked: ${blocker} is itself blocked" "trace to root blocker" ""
            ;;
          partial|evidence_missing)
            ASK "→ ${blocker} is ${b_status} — implementation exists but evidence is missing. WHY is evidence missing?"
            ASK "   IF CI unavailable → fix CI first"
            ASK "   IF nobody collected it → create evidence-collection subtask"
            ASK "   IF evidence exists but not recorded → update ledger/task doc"
            NEXT "Action: diagnose evidence gap, create collection task or update records"
            record_finding "pm" "warning" "${tid}" "PM-1" "blocker ${blocker} is ${b_status} — evidence missing" "diagnose evidence gap for ${blocker}" "bash scripts/claude-loop-role-engine.sh --closure-audit ${blocker}"
            ;;
          ready|in_progress|implementing)
            ASK "→ ${blocker} is ${b_status} — it's in progress but not done. WHY is it stalled?"
            ASK "   IF Claude picked it up and stalled → check agent-state.json for recovery"
            ASK "   IF never dispatched → check dispatch queue priority"
            NEXT "Action: check agent state, bump dispatch priority, or create reminder SAP"
            record_finding "pm" "info" "${tid}" "PM-1" "blocker ${blocker} is ${b_status} — stalled" "check agent-state.json or bump dispatch" ""
            ;;
          *)
            ASK "→ ${blocker} status=${b_status} — unexpected state. Investigate."
            NEXT "Action: read task doc and review contract for ${blocker}"
            ;;
        esac
        echo ""
      done
    done <<< "${pm1_list}"
  fi

  # ── PM-2: WHY are there doc/ledger conflicts? ──────────────────────────────
  H1 "PM-2: Doc/Ledger Consistency Reasoning"

  local pm2_conflicts
  pm2_conflicts=$(python3 -c "
import json, re
from pathlib import Path

docs = Path('${DOCS_DIR}')
ledger = json.loads((docs / 'docs/development/task-state-ledger.json').read_text())

for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        tid = t.get('task_id','')
        doc_path = docs / 'docs/development/tasks' / f'{tid}.md'
        if not doc_path.exists(): continue

        content = doc_path.read_text()
        dm = re.search(r'>\\s*Status:\\s*(\\S+)', content)
        if not dm: continue

        doc_status = dm.group(1).lower().replace(':','').strip()
        if doc_status.startswith('✅'):
            doc_status = 'completed'
        elif doc_status.startswith('🟡') or doc_status == 'partial':
            doc_status = 'partial'
        elif doc_status.startswith('🔴') or doc_status == 'blocked':
            doc_status = 'blocked'
        ledger_status = t.get('status','').lower()
        done = {'completed','completed_with_skip'}

        if doc_status in done and ledger_status not in done:
            print(f'CONFLICT|{tid}|{t.get(\"repo\",\"?\")}|doc={doc_status}|ledger={ledger_status}|{t.get(\"issue\",\"\")}')
        elif ledger_status in done and doc_status not in done:
            print(f'CONFLICT|{tid}|{t.get(\"repo\",\"?\")}|doc={doc_status}|ledger={ledger_status}|{t.get(\"issue\",\"\")}')
" 2>/dev/null | head -10)

  local conflicts_found=0
  while IFS='|' read -r tag tid repo detail1 detail2 issue; do
    [[ -z "${tid}" ]] && continue
    conflicts_found=$((conflicts_found + 1))

    ASK "WHY does ${tid} (${repo}) have mismatched status: ${detail1} vs ${detail2}?"

    # Gather context: check review contract and git log
    local rf="${DOCS_DIR}/docs/development/review-contracts/${tid}-review.json"
    if [[ -f "${rf}" ]]; then
      local rstate verdict
      read -r rstate verdict <<< "$(python3 -c "
import json; d=json.load(open('${rf}'))
state = d.get('state','?')
for r in d.get('rounds',[]):
    cx = r.get('codex',{})
    if cx: print(state, cx.get('verdict','?')); break
else: print(state, 'no_verdict')
" 2>/dev/null || echo "? ?")"

      ASK "   review contract: state=${rstate} verdict=${verdict}"
      # WHY reasoning
      if [[ "${rstate}" == "changes_requested" ]]; then
        ASK "→ Contract says CHANGES_REQUESTED but doc/ledger says completed. Claude may have pre-maturely marked done."
        NEXT "Action: revert doc to Partial, create SAP warning Claude"
        record_finding "pm" "warning" "${tid}" "PM-2" "doc/ledger vs review: changes_requested" "revert premature completion" ""
      elif [[ "${rstate}" == "under_codex_review" ]]; then
        ASK "→ Contract is under review — status should NOT be completed. Claude may have jumped the gun."
        NEXT "Action: hold status at implemented/verified until verdict"
        record_finding "pm" "warning" "${tid}" "PM-2" "doc/ledger ahead of review state" "hold until codex verdict" ""
      elif [[ "${verdict}" == "approved" || "${rstate}" == "approved" ]]; then
        ASK "→ Contract approved — doc/ledger should BOTH be completed. Which side is stale?"
        NEXT "Action: sync the stale side to completed"
        record_finding "pm" "info" "${tid}" "PM-2" "doc/ledger mismatch after approval" "sync stale side to completed" ""
      fi
    else
      ASK "→ No review contract exists — completion without review is a PROCESS_DEFECT"
      NEXT "Action: create review contract retroactively, mark task as evidence_missing until reviewed"
      record_finding "pm" "warning" "${tid}" "PM-2" "doc/ledger conflict without review contract" "create review contract or reconcile ledger" ""
    fi

    # Check git for dev merge evidence
    local dev_merge; dev_merge=$(git -C "${LIVEMASK_ROOT}/${repo}" log --oneline --grep="${tid}" -1 2>/dev/null || echo "")
    [[ -n "${dev_merge}" ]] && echo "      dev merge: ${dev_merge}" || ASK "      no dev merge commit found — was this ever pushed?"
    echo ""
  done <<< "${pm2_conflicts}"

  [[ "${conflicts_found}" -eq 0 ]] && OK "all doc/ledger statuses consistent"

  # ── PM-3: WHY is the dispatch queue empty? What's the bottleneck? ──────────
  H1 "PM-3: Queue Health Root Cause"

  local candidates blocked
  read -r candidates blocked <<< "$(python3 "${DOCS_DIR}/scripts/plan-next-tasks.py" --format json 2>/dev/null | \
    python3 -c "import json,sys; d=json.load(sys.stdin)['summary']; print(d['candidate_count'], d['blocked_open_count'])" 2>/dev/null || echo "? ?")"

  echo "  candidates: ${candidates} | blocked: ${blocked}"

  if [[ "${candidates}" == "0" ]]; then
    ASK "WHY is the dispatch queue empty?"

    if [[ "${blocked}" == "0" || "${blocked}" == "?" ]]; then
      ASK "→ No candidates AND no blocked tasks. Possible causes:"
      ASK "   1. All MVP tasks are done — system is complete (verify against contracts)"
      ASK "   2. Tasks exist in ledger but planner can't dispatch them (check readiness)"
      ASK "   3. No new tasks have been created (check Product role for decomposition gaps)"
      ASK "   4. All tasks are in non-dispatchable states (in_progress without progress)"

      # Check which statuses dominate
      local status_dist; status_dist=$(python3 -c "
import json
from collections import Counter
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
statuses = Counter()
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        statuses[t.get('status','?')] += 1
for s,c in statuses.most_common(8): print(f'{s}: {c}')
" 2>/dev/null)
      echo "      status distribution:"
      echo "${status_dist}" | while read -r line; do echo "        ${line}"; done

      NEXT "Action: if MVP complete → mark milestone. If tasks stuck → diagnose each stuck status. If no tasks → trigger Product decomposition."
      record_finding "pm" "warning" "" "PM-3" "dispatch queue empty (candidate_count=0)" "run product decomposition or audit backlog" "bash scripts/claude-loop-role-engine.sh product"
    else
      ASK "→ ${blocked} tasks are blocked — the queue IS the blocker list. Resolve root blockers to unblock candidates."
      NEXT "Action: run PM-1 blocker analysis for each blocked task"
      record_finding "pm" "warning" "" "PM-3" "queue empty but ${blocked} blocked tasks open" "resolve root blockers" "bash scripts/claude-loop-role-engine.sh pm"
    fi
  else
    OK "${candidates} tasks ready — queue is healthy"
    local top_id
    top_id=$(python3 "${DOCS_DIR}/scripts/plan-next-tasks.py" --format json 2>/dev/null | \
      python3 -c "import json,sys; d=json.load(sys.stdin); t=[x for x in d.get('global_next',[]) if x.get('readiness')=='dispatch_now']; print(t[0]['task_id'] if t else '')" 2>/dev/null || echo "")
    if [[ -n "${top_id}" ]]; then
      NEXT "Action: accept ${top_id} via claude-loop-startup.sh — do not re-decompose in Codex PM loop"
      record_finding "pm" "info" "${top_id}" "PM-3" "dispatch_now available (${candidates} candidates)" "accept top task from startup" "bash ${CI_CD_DIR}/scripts/claude-loop-startup.sh"
    fi
  fi

  finish_role "pm" "blocked=$(echo "${blocked_tasks}" | wc -l | tr -d ' ') conflicts=${conflicts_found} queue=${candidates}/${blocked}"
  H1 "PM complete. Top actions and findings.jsonl above."
}

# ══════════════════════════════════════════════════════════════════════════════
# PRODUCT: 3 deep reasoning points
# ══════════════════════════════════════════════════════════════════════════════

role_product() {
  H1 "PRODUCT — Product Manager Reasoning"
  load_cache "product"
  preflight_context

  # ── PROD-1: WHY are Ready contracts not implemented? ───────────────────────
  H1 "PROD-1: Contract-to-Implementation Gap Reasoning"

  local uncovered=0
  local prod1_raw
  prod1_raw=$(python3 -c "
import json, re
from pathlib import Path

docs = Path('${DOCS_DIR}')
ledger = json.loads((docs / 'docs/development/task-state-ledger.json').read_text())
all_tasks = set()
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id'): all_tasks.add(t['task_id'])

contracts_with_gaps = []
ci = docs / 'docs/contracts/contract-index.md'
if not ci.exists():
    print('NO_INDEX')
    exit(0)

for line in ci.read_text().split('\n'):
    if '|' not in line: continue
    parts = [p.strip() for p in line.split('|')]
    if len(parts) < 5: continue
    status = parts[2]
    if status not in ('Ready','Stable'): continue
    domain = parts[0].strip()
    contract_file = parts[1].strip() if len(parts) > 1 else ''
    impacted = parts[4].strip() if len(parts) > 4 else ''
    tasks_in_line = re.findall(r'TASK-[A-Z0-9-]+', line)
    covered = any(t in all_tasks for t in tasks_in_line)
    if not covered:
        contracts_with_gaps.append(f'{domain}|{contract_file}|{status}|{impacted}|{tasks_in_line[0] if tasks_in_line else \"none\"}')

for c in contracts_with_gaps[:10]:
    print(c)
" 2>/dev/null)
  while IFS='|' read -r domain contract status impacted suggested_task; do
    [[ -z "${domain}" ]] && continue
    uncovered=$((uncovered + 1))

    ASK "WHY is '${domain}' (${status} contract) not implemented?"

    # Check: does the contract file exist and have detail?
    local cf="${DOCS_DIR}/docs/contracts/${contract}"
    if [[ -f "${cf}" ]]; then
      local cf_size; cf_size=$(wc -c < "${cf}" | tr -d ' ')
      echo "      contract: ${contract} (${cf_size} bytes)"
      ASK "   Contract is ${status} — implementation should exist. WHY doesn't it?"

      # Reason hypotheses
      ASK "   IF no one created the task → Product gap: decomposition pipeline didn't run"
      ASK "   IF task exists but in wrong status → check ledger for ${suggested_task}"
      ASK "   IF contract was just marked Ready → normal: task creation is next step"
      ASK "   IF contract is purely docs/design → does it actually need implementation?"

      # Check if there's a dependency blocking this
      local suggested_tid="${suggested_task}"
      local in_ledger; in_ledger=$(ledger_get "${suggested_tid}" "status")
      [[ -z "${in_ledger}" ]] && ASK "   ${suggested_tid} NOT in ledger — task was never created"
      [[ -n "${in_ledger}" ]] && ASK "   ${suggested_tid} exists in ledger with status=${in_ledger}"

      NEXT "Action: IF contract needs implementation AND no task exists → create task stub with blocked_by chain. IF task exists but wrong status → fix. IF docs-only → mark contract as Stable."
      record_finding "product" "warning" "${suggested_tid}" "PROD-1" "Ready contract '${domain}' lacks implementation coverage" "create TASK or verify docs-only" ""
    else
      WARN "   contract file missing: ${contract}"
      record_finding "product" "warning" "" "PROD-1" "contract file missing: ${contract}" "restore contract or fix contract-index" ""
    fi
    echo ""
  done <<< "${prod1_raw}"

  [[ "${uncovered}" -eq 0 ]] && OK "all Ready/Stable contracts have task coverage"

  # ── PROD-2: WHY are MVP milestones not progressing? ────────────────────────
  H1 "PROD-2: MVP Milestone Progress Reasoning"

  if [[ -f "${DOCS_DIR}/docs/development/MVP_IMPLEMENTATION_PLAN.md" ]]; then
    local completed ready partial
    completed=$(grep -c "Completed" "${DOCS_DIR}/docs/development/MVP_IMPLEMENTATION_PLAN.md" 2>/dev/null || echo "0")
    ready=$(grep -c "Ready" "${DOCS_DIR}/docs/development/MVP_IMPLEMENTATION_PLAN.md" 2>/dev/null || echo "0")
    partial=$(grep -c "Partial" "${DOCS_DIR}/docs/development/MVP_IMPLEMENTATION_PLAN.md" 2>/dev/null || echo "0")
    local total=$((completed + ready + partial))
    local pct=$(( completed * 100 / (total + 1) ))

    echo "  MVP: ${completed}/${total} completed (${pct}%) | ${ready} ready | ${partial} partial"

    ASK "WHY is completion at ${pct}%? What's blocking the remaining ${ready}+${partial} items?"

    if [[ "${partial}" -gt 0 ]]; then
      ASK "→ ${partial} items are partially complete. WHY are they stuck?"
      ASK "   Check each partial item: is it waiting for evidence? blocked by another task? abandoned?"
      NEXT "Action: audit each partial item — either finish it or explicitly defer with reason"
    fi
    if [[ "${ready}" -gt 0 ]]; then
      ASK "→ ${ready} items are ready but not started. WHY aren't they dispatched?"
      ASK "   IF queue has other priorities → correct"
      ASK "   IF they depend on blocked tasks → diagnose blockers"
      ASK "   IF no one picked them up → check dispatch pipeline"
      NEXT "Action: ensure ready items are in planner queue with correct priority"
    fi
  fi

  # ── PROD-3: WHY are requirements sitting in inbox? ─────────────────────────
  H1 "PROD-3: Requirement Inbox Processing"

  local inbox_count=0
  for f in "${DOCS_DIR}/docs/development/requirements-inbox/"*.json; do
    [[ ! -f "${f}" ]] && continue
    [[ "$(basename "${f}")" == ".gitkeep" ]] && continue
    inbox_count=$((inbox_count + 1))

    local gen_by gen_at
    read -r gen_by gen_at <<< "$(python3 -c "
import json; d=json.load(open('${f}'))
print(d.get('generated_by','?'), d.get('generated_at','?')[:16])
" 2>/dev/null || echo "? ?")"

    ASK "WHY is this requirement still in inbox? (by=${gen_by}, at=${gen_at})"
    ASK "→ IF it's valid → create TASK stub and move to ledger"
    ASK "→ IF it needs more detail → read source contract, flesh out scope"
    ASK "→ IF it's obsolete → delete or mark as rejected with reason"
    ASK "→ IF awaiting human approval → create GitHub Issue for review"
    NEXT "Action: process or reject each inbox item — inbox should trend to zero"
    echo ""
  done
  [[ "${inbox_count}" -eq 0 ]] && OK "requirement inbox clean"

  finish_role "product" "gaps=${uncovered} mvp=${pct:-?}% inbox=${inbox_count}"
  H1 "Product complete."
}

# ══════════════════════════════════════════════════════════════════════════════
# TECH: 3 deep reasoning points
# ══════════════════════════════════════════════════════════════════════════════

role_tech() {
  H1 "TECH — Tech Lead Reasoning"
  load_cache "tech"
  preflight_context

  # ── TECH-1: API/Swagger drift — WHY and what exactly is missing? ───────────
  H1 "TECH-1: API/Swagger Drift Analysis"

  local BACKEND="${LIVEMASK_ROOT}/livemask-backend"
  if [[ -f "${BACKEND}/main.go" ]]; then
    # Extract actual routes from main.go
    local routes; routes=$(grep -oE '"(/[^"]+)"' "${BACKEND}/main.go" 2>/dev/null | tr -d '"' | sort -u)
    local route_count; route_count=$(echo "${routes}" | grep -c "/" || echo "0")

    # Extract swagger paths
    local swagger_paths=""
    for sf in "${BACKEND}/internal/swagger/"*.yaml; do
      [[ -f "${sf}" ]] && swagger_paths+=$(grep -E '^\s+/' "${sf}" 2>/dev/null | sed 's/^[[:space:]]*//' | sed 's/:.*$//')
      swagger_paths+=$'\n'
    done
    local swagger_count; swagger_count=$(echo "${swagger_paths}" | grep -c "/" || echo "0")

    echo "  routes: ${route_count} | swagger paths: ${swagger_count}"

    if [[ "${route_count}" -gt "${swagger_count}" ]]; then
      local diff=$((route_count - swagger_count))
      WARN "${diff} routes may be undocumented"

      # Find exact missing routes
      ASK "WHY are ${diff} routes not in Swagger? Which ones exactly?"
      echo "  Routes in main.go but possibly not in swagger:"
      echo "${routes}" | head -30 | while read -r route; do
        [[ -z "${route}" ]] && continue
        # Skip non-API routes
        [[ "${route}" != /api/* && "${route}" != /admin/* && "${route}" != /internal/* ]] && continue
        local in_swagger; in_swagger=$(echo "${swagger_paths}" | grep -c "${route}" 2>/dev/null || echo "0")
        if [[ "${in_swagger}" -eq 0 ]]; then
          echo "    MISSING: ${route}"
        fi
      done

      ASK "   IF route was just added → normal delay, create Swagger sync task"
      ASK "   IF route has been there for weeks → tech debt, prioritize Swagger completion"
      ASK "   IF route is internal only (/internal/) → may not need public Swagger, document internally"
      NEXT "Action: create TASK-BACKEND-SWAGGER-SYNC listing exact missing routes"
      record_finding "tech" "warning" "TASK-BACKEND-SWAGGER-SYNC" "TECH-1" "${diff} routes may be missing from Swagger" "create swagger sync task" ""
    else
      OK "Swagger coverage matches or exceeds routes"
    fi
  fi

  # ── TECH-2: DB Migration Safety — WHY was ADD COLUMN used? ─────────────────
  H1 "TECH-2: DB Migration Safety Review"

  local add_cols=0
  cd "${BACKEND}" 2>/dev/null || true
  for go_file in $(grep -rl "ADD COLUMN" internal/ --include="*.go" 2>/dev/null); do
    local cols; cols=$(grep -n "ADD COLUMN" "${go_file}" 2>/dev/null)
    while IFS= read -r line; do
      add_cols=$((add_cols + 1))
      local lineno; lineno=$(echo "${line}" | cut -d: -f1)

      ASK "WHY was ADD COLUMN needed in ${go_file}:${lineno}?"
      echo "      ${line:0:150}"

      # Check for NOT NULL without DEFAULT (dangerous)
      if echo "${line}" | grep -q "NOT NULL" && ! echo "${line}" | grep -q "DEFAULT"; then
        WARN "→ NOT NULL without DEFAULT — this will fail on existing rows with data!"
        ASK "   IF table has existing rows → migration WILL fail. Add DEFAULT or make nullable."
        NEXT "Action: FIX immediately — add DEFAULT value or remove NOT NULL constraint"
        record_finding "tech" "blocker" "" "TECH-2" "NOT NULL without DEFAULT in ${go_file}:${lineno}" "fix migration before merge" ""
      fi

      # Check for indexes on new column
      local col_name; col_name=$(echo "${line}" | grep -oE '[a-z_]+' | tail -3 | head -1)
      if [[ -n "${col_name}" ]]; then
        local has_index; has_index=$(grep -c "INDEX.*${col_name}" "${go_file}" 2>/dev/null || echo "0")
        [[ "${has_index}" -eq 0 ]] && ASK "   New column '${col_name}' has no index — will queries on this column be slow?"
      fi
    done <<< "${cols}"
  done
  [[ "${add_cols}" -eq 0 ]] && OK "no ADD COLUMN migrations to review"

  # ── TECH-3: Cross-repo interface breakage risk ─────────────────────────────
  H1 "TECH-3: Cross-Repo Interface Change Detection"

  # Check recent backend API changes that might break consumers
  local recent_changes
  recent_changes=$(git -C "${BACKEND}" log --oneline --since="3 days ago" --name-only -- 'internal/handler/*.go' 'main.go' 2>/dev/null | head -30)

  if [[ -n "${recent_changes}" ]]; then
    echo "  recent API changes (3 days):"
    echo "${recent_changes}" | head -15 | while read -r line; do
      [[ -z "${line}" ]] && continue
      echo "    ${line}"
    done

    ASK "WHY were these API changes made? Do downstream consumers know?"
    ASK "→ Check: does Admin use any changed endpoint? (grep in admin/src/lib/)"
    ASK "→ Check: does App model match the new API shape? (grep in app/lib/models/)"
    ASK "→ Check: does CI/CD smoke test the changed paths? (grep in ci-cd/scripts/)"

    # Quick impact scan
    for changed_file in $(echo "${recent_changes}" | grep "internal/" | head -5); do
      local symbol; symbol=$(basename "${changed_file}" .go | sed 's/_test$//')
      echo "      impact scan for '${symbol}':"
      for rd in "${LIVEMASK_ROOT}"/livemask-admin "${LIVEMASK_ROOT}"/livemask-app "${LIVEMASK_ROOT}"/livemask-nodeagent "${LIVEMASK_ROOT}"/livemask-job-service; do
        local rn; rn=$(basename "${rd}")
        local hits; hits=$(grep -rl "${symbol}" "${rd}" --include="*.ts" --include="*.tsx" --include="*.dart" --include="*.go" 2>/dev/null | wc -l | tr -d ' ')
        [[ "${hits}" -gt 0 ]] && ASK "      ${rn}: ${hits} files reference '${symbol}' — VERIFY compatibility"
      done
    done
    NEXT "Action: if API shape changed and consumers not updated → create follow-up tasks for each affected repo"
  else
    OK "no recent API surface changes"
  fi

  finish_role "tech" "swagger_diff=${diff:-0} add_columns=${add_cols}"
  H1 "Tech complete."
}

# ══════════════════════════════════════════════════════════════════════════════
# QA: 3 deep reasoning points
# ══════════════════════════════════════════════════════════════════════════════

role_qa() {
  H1 "QA — Quality Assurance Reasoning"
  load_cache "qa"
  preflight_context

  # ── QA-1: WHY does a completed task lack evidence? ─────────────────────────
  H1 "QA-1: Completion Evidence Deep Verification"

  local evidence_gaps=0
  local qa1_raw
  qa1_raw=$(python3 -c "
import json
from pathlib import Path

ledger = json.loads(Path('${DOCS_DIR}/docs/development/task-state-ledger.json').read_text())
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('status') in ('completed','completed_with_skip','verified'):
            validation = t.get('validation','')
            if len(validation.strip()) < 20:
                print(f\"{t['task_id']}|{t.get('repo','?')}|{t.get('issue','')}\")
" 2>/dev/null | head -5)
  while IFS='|' read -r tid repo issue; do
    [[ -z "${tid}" ]] && continue
    evidence_gaps=$((evidence_gaps + 1))

    ASK "WHY is ${tid} marked completed but has no validation evidence?"

    # Check review contract
    local rf="${DOCS_DIR}/docs/development/review-contracts/${tid}-review.json"
    if [[ -f "${rf}" ]]; then
      local rstate verdict
      read -r rstate verdict <<< "$(python3 -c "
import json; d=json.load(open('${rf}'))
state=d.get('state','?')
for r in d.get('rounds',[]):
    cx=r.get('codex',{})
    if cx: print(state, cx.get('verdict','?')); break
else: print(state, 'no_verdict')
" 2>/dev/null || echo "? ?")"

      ASK "   review contract: state=${rstate} verdict=${verdict}"
      ASK "   IF approved by Codex → ledger validation field should have been filled, find the gap"
      ASK "   IF no review contract → task was completed without review — PROCESS_DEFECT"
      ASK "   IF changes_requested → task should NOT be completed, revert status"
    else
      ASK "   No review contract — completion without review is invalid"
    fi

    # Check if task doc has evidence
    local task_doc="${DOCS_DIR}/docs/development/tasks/${tid}.md"
    if [[ -f "${task_doc}" ]]; then
      local has_evidence; has_evidence=$(grep -c "dev merge\|origin/dev\|validation\|check-docs" "${task_doc}" 2>/dev/null || echo "0")
      ASK "   task doc has ${has_evidence} evidence references"
    fi

    NEXT "Action: IF completed without review → revert to evidence_missing, create review contract. IF review passed but ledger blank → fill ledger validation field."
    record_finding "qa" "warning" "${tid}" "QA-1" "completed task lacks validation evidence" "fill ledger validation or revert status" "bash scripts/claude-loop-role-engine.sh --closure-audit ${tid}"
    echo ""
  done <<< "${qa1_raw}"

  [[ "${evidence_gaps}" -eq 0 ]] && OK "all completed tasks have validation evidence"

  # ── QA-2: WHY are there open bugs? Triage and root cause ───────────────────
  H1 "QA-2: Bug Triage with Root Cause"

  local total_bugs=0
  for repo in "livemask-backend" "livemask-admin" "livemask-app" "livemask-nodeagent" "livemask-website"; do
    local bugs
    bugs=$(gh issue list --repo "MyAiDevs/${repo}" --label "bug" --state open --limit 10 --json number,title,createdAt 2>/dev/null || echo "[]")
    local bug_count; bug_count=$(echo "${bugs}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

    if [[ "${bug_count}" -gt 0 ]]; then
      echo "  ${repo}: ${bug_count} open bugs"
      total_bugs=$((total_bugs + bug_count))

      # Analyze each bug
      local qa2_list
      qa2_list=$(echo "${bugs}" | python3 -c "
import json,sys
for b in json.load(sys.stdin):
    print(f\"{b['number']}|{b['title'][:100]}|{b['createdAt'][:10]}\")
" 2>/dev/null | head -5)
      while IFS='|' read -r num title created; do
        [[ -z "${num}" ]] && continue

        ASK "BUG ${repo}#${num}: '${title}' (since ${created})"
        ASK "   WHY hasn't this been fixed?"

        local age_days; age_days=$(( ($(date +%s) - $(date -j -f "%Y-%m-%d" "${created}" +%s 2>/dev/null || date +%s)) / 86400 ))
        [[ "${age_days}" -gt 7 ]] && ASK "   → ${age_days} days old — is this being ignored? Does it need priority bump?"

        local has_task; has_task=$(python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if '${repo}#${num}' in t.get('issue','') or '/${num}' in t.get('issue',''):
            print(t.get('task_id'))
            break
" 2>/dev/null || echo "")
        [[ -z "${has_task}" ]] && ASK "   → No TASK linked to this bug — needs task creation"
        [[ -n "${has_task}" ]] && ASK "   → Linked to ${has_task} — check task status"

        NEXT "Action: IF no task → create bug-fix task. IF task exists but stalled → diagnose. IF low priority → explicitly defer with reason."
        echo ""
      done <<< "${qa2_list}"
    fi
  done
  [[ "${total_bugs}" -eq 0 ]] && OK "no open bugs across repos"

  # ── QA-3: Regression Risk — WHAT changed in high-risk areas? WHY was it changed? ──
  H1 "QA-3: Regression Risk Assessment"

  for area in "auth" "billing" "payment" "node/credential" "configcenter"; do
    local area_dir="${LIVEMASK_ROOT}/livemask-backend/internal/${area}"
    [[ ! -d "${area_dir}" ]] && continue

    local changes; changes=$(git -C "${LIVEMASK_ROOT}/livemask-backend" log --oneline --since="7 days ago" -- "${area_dir}/" 2>/dev/null)
    local change_count; change_count=$(echo "${changes}" | grep -c "." 2>/dev/null || echo "0")

    if [[ "${change_count}" -gt 0 ]]; then
      WARN "HIGH RISK: ${area} — ${change_count} changes in 7 days"

      ASK "WHY was ${area} changed ${change_count} times?"
      echo "${changes}" | head -3 | while read -r cline; do
        [[ -z "${cline}" ]] && continue
        echo "      ${cline}"
      done

      ASK "→ IF bug fixes → are regression tests in place?"
      ASK "→ IF feature work → is the feature complete or still churning?"
      ASK "→ IF refactoring → are downstream consumers tested?"

      # Check if smoke tests cover this area
      local smoke_coverage; smoke_coverage=$(grep -rl "${area}" "${CI_CD_DIR}/scripts/"*smoke*.sh 2>/dev/null | wc -l | tr -d ' ')
      ASK "→ Smoke coverage for '${area}': ${smoke_coverage} scripts — IF 0, high regression risk"

      NEXT "Action: IF no smoke coverage → create targeted smoke test. IF churn is feature work → prioritize completion. IF bug fixes → verify each fix has a regression test."
      echo ""
    fi
  done

  finish_role "qa" "evidence_gaps=${evidence_gaps} bugs=${total_bugs}"
  H1 "QA complete."
}

# ══════════════════════════════════════════════════════════════════════════════
# DEEP ANALYSIS: single-task deep dives (cross-cutting)
# ══════════════════════════════════════════════════════════════════════════════

deep_review() {
  local tid="${1:-}"
  [[ -z "${tid}" ]] && { echo "Usage: --deep-review <TASK-ID>"; return 1; }

  H1 "DEEP REVIEW: ${tid}"
  sync_all

  echo ""; echo "--- TASK DOC ---"
  local task_doc="${DOCS_DIR}/docs/development/tasks/${tid}.md"
  [[ -f "${task_doc}" ]] && head -60 "${task_doc}" || echo "  not found"

  echo ""; echo "--- LEDGER ---"
  python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id')=='${tid}':
            print(json.dumps({k:t[k] for k in ['status','repo','issue','validation','blocked_by','unlocks','notes'] if k in t}, indent=2))
" 2>/dev/null || echo "  not in ledger"

  echo ""; echo "--- REVIEW CONTRACT ---"
  local rf="${DOCS_DIR}/docs/development/review-contracts/${tid}-review.json"
  if [[ -f "${rf}" ]]; then
    python3 -c "
import json; d=json.load(open('${rf}'))
print(f'state={d.get(\"state\")} round={d.get(\"review_round\")} actor={d.get(\"next_required_actor\")}')
for r in d.get('rounds',[]):
    c=r.get('claude',{}); cx=r.get('codex',{})
    if c: print(f'claude: {c.get(\"submitted_at\")} commit={str(c.get(\"commit\",\"\"))[:7]}')
    for v in c.get('validation',[]): print(f'  validation: {v.get(\"cmd\")} → {v.get(\"result\")}')
    if cx: print(f'codex: verdict={cx.get(\"verdict\")} findings={cx.get(\"findings\",[])}')
" 2>/dev/null
  fi

  echo ""; echo "--- GIT DIFF ---"
  local repo; repo=$(ledger_get "${tid}" "repo")
  [[ -z "${repo}" ]] && repo="livemask-docs"
  cd "${LIVEMASK_ROOT}/${repo}" 2>/dev/null || true
  local branch; branch=$(git branch -r --list "origin/task/*${tid}*" --format='%(refname:short)' 2>/dev/null | head -1 || echo "")
  if [[ -n "${branch}" ]]; then
    git diff "origin/dev...${branch}" --stat 2>/dev/null | head -15
    echo ""; git diff "origin/dev...${branch}" 2>/dev/null | head -200
  elif [[ -f "${rf}" ]]; then
    local tc; tc=$(python3 -c "import json; print(json.load(open('${rf}')).get('task_commit',''))" 2>/dev/null || echo "")
    [[ -n "${tc}" ]] && { git show "${tc}" --stat 2>/dev/null | head -15; echo ""; git show "${tc}" 2>/dev/null | head -150; }
  fi

  echo ""; echo "=== DEEP ANALYSIS PROMPT ==="
  ASK "1. WHY was this implementation approach chosen?"
  ASK "   Compare task doc requirements vs actual code change."
  ASK "   IF approach differs → was the deviation intentional (simpler, constrained) or accidental?"
  echo ""
  ASK "2. WHY might this fail or be incomplete?"
  ASK "   Edge cases not handled? Dependent services not updated? Tests missing?"
  echo ""
  ASK "3. WHAT downstream effects does this have?"
  ASK "   Trace: this change → admin UI → app client → node agent → smoke tests"
  echo ""
  ASK "4. CAN this be closed? What evidence proves it works?"
  ASK "   IF evidence is sufficient → recommend APPROVE"
  ASK "   IF evidence is missing → specify exactly what's needed"
  ASK "   IF implementation is wrong → recommend CHANGES_REQUESTED with concrete fixes"
}

closure_audit() {
  local tid="${1:-}"
  [[ -z "${tid}" ]] && { echo "Usage: --closure-audit <TASK-ID>"; return 1; }

  H1 "CLOSURE AUDIT: ${tid}"
  sync_all

  local score=0 max=7 gaps=()

  check() { max=$((max)); local label="$1"; shift; if eval "$@"; then score=$((score+1)); echo "  [✓] ${label}"; else gaps+=("${label}"); echo "  [✗] ${label}"; fi; }

  local ls; ls=$(ledger_get "${tid}" "status")
  check "ledger status=completed" "[[ '${ls}' == 'completed' || '${ls}' == 'completed_with_skip' ]]"

  local sha=""; local rf="${DOCS_DIR}/docs/development/review-contracts/${tid}-review.json"
  [[ -f "${rf}" ]] && sha=$(python3 -c "import json; print(json.load(open('${rf}')).get('origin_dev_sha',''))" 2>/dev/null || echo "")
  check "origin/dev push evidence" "[[ -n '${sha}' ]]"

  local docs_ok=0
  [[ -f "${rf}" ]] && python3 -c "
import json; d=json.load(open('${rf}'))
for r in d.get('rounds',[]):
    for v in r.get('claude',{}).get('validation',[]):
        if 'check-docs' in v.get('cmd','') and v.get('result')=='pass': print('PASS')
" 2>/dev/null | grep -q "PASS" && docs_ok=1
  check "check-docs.sh PASS" "[[ ${docs_ok} -eq 1 ]]"

  local has_issue; has_issue=$(ledger_get "${tid}" "issue")
  check "GitHub issue linked in ledger" "[[ -n '${has_issue}' ]]"

  local td="${DOCS_DIR}/docs/development/tasks/${tid}.md"
  local doc_done=0; [[ -f "${td}" ]] && grep -q "Completed" "${td}" 2>/dev/null && doc_done=1
  check "task doc marked Completed" "[[ ${doc_done} -eq 1 ]]"

  local repo; repo=$(ledger_get "${tid}" "repo"); [[ -z "${repo}" ]] && repo="livemask-docs"
  local dirty; dirty=$(git -C "${LIVEMASK_ROOT}/${repo}" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  check "target repo clean (${repo})" "[[ ${dirty} -eq 0 ]]"

  local child=0; [[ -f "${rf}" ]] && child=$(python3 -c "import json; print(len(json.load(open('${rf}')).get('links',{}).get('issues',[])))" 2>/dev/null || echo "0")
  check "cross-repo child issues tracked" "[[ ${child} -gt 0 ]]"

  echo ""; echo "SCORE: ${score}/${max}"
  [[ ${score} -ge 6 ]] && echo "VERDICT: READY" || echo "VERDICT: NEEDS EVIDENCE"
  for g in "${gaps[@]}"; do echo "  GAP: $g"; done
  ASK "FOR EACH GAP: WHY does it exist? WHEN will it be resolved? WHO should resolve it?"
}

impact_analysis() {
  local tid="${1:-}"
  [[ -z "${tid}" ]] && { echo "Usage: --impact-analysis <TASK-ID>"; return 1; }
  H1 "IMPACT ANALYSIS: ${tid}"
  sync_all

  local repo; repo=$(ledger_get "${tid}" "repo"); [[ -z "${repo}" ]] && repo="livemask-docs"
  echo "source: ${repo} → ${tid}"

  echo ""; echo "--- UNLOCK CHAIN ---"
  python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
target='${tid}'
blocks=[]; unlocks=[]
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if target in (t.get('blocked_by') or []): blocks.append(t['task_id'])
        if target in (t.get('unlocks') or []): unlocks.append(t['task_id'])
for b in blocks: print(f'  BLOCKS: {b}')
for u in unlocks: print(f'  UNLOCKS: {u}')
if not blocks and not unlocks: print('  (no dependency chain recorded in ledger)')
" 2>/dev/null

  echo ""; echo "--- CODE REFERENCES ---"
  local td="${DOCS_DIR}/docs/development/tasks/${tid}.md"
  if [[ -f "${td}" ]]; then
    for kw in $(grep -oE '[A-Z][a-zA-Z]{4,}' "${td}" 2>/dev/null | sort -u | head -5); do
      echo "  '${kw}' across repos:"
      for rd in "${LIVEMASK_ROOT}"/livemask-*/; do
        local rn; rn=$(basename "${rd}")
        [[ "${rn}" == "${repo}" || "${rn}" == "livemask-docs" || "${rn}" == "livemask-ci-cd" ]] && continue
        [[ ! -d "${rd}" ]] && continue
        local hits; hits=$(grep -rl "${kw}" "${rd}" --include="*.go" --include="*.ts" --include="*.tsx" --include="*.dart" 2>/dev/null | wc -l | tr -d ' ')
        [[ "${hits}" -gt 0 ]] && echo "    ${rn}: ${hits} files"
      done
    done
  fi

  ASK "IF this task completes today, what is the NEXT task that becomes unblocked?"
  ASK "IF this task CAN'T complete, what is the ALTERNATIVE path to the same goal?"
}

# ══════════════════════════════════════════════════════════════════════════════
# ORCHESTRATOR
# ══════════════════════════════════════════════════════════════════════════════

run_all() {
  role_pm
  role_product
  role_tech
  role_qa
  print_top_actions 5
  push_changes "role-engine: full cycle $(date -u +%Y-%m-%dT%H:%MZ)"
  echo ""
  echo -e "  Machine-readable findings: ${FINDINGS_FILE}"
  echo "  Consume: tail -1 ~/.claude/role-cache/findings.jsonl | python3 -m json.tool"
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

case "${ROLE}" in
  pm)
    role_pm
    print_top_actions 3
    echo "  Machine-readable findings: ${FINDINGS_FILE}"
    ;;
  product)
    role_product
    print_top_actions 3
    echo "  Machine-readable findings: ${FINDINGS_FILE}"
    ;;
  tech)
    role_tech
    print_top_actions 3
    echo "  Machine-readable findings: ${FINDINGS_FILE}"
    ;;
  qa)
    role_qa
    print_top_actions 3
    echo "  Machine-readable findings: ${FINDINGS_FILE}"
    ;;
  all)               run_all;;
  --deep-review)     deep_review "${ARG2}";;
  --closure-audit)   closure_audit "${ARG2}";;
  --impact-analysis) impact_analysis "${ARG2}";;
  *)
    echo "Usage: bash scripts/claude-loop-role-engine.sh <role|mode> [args]"
    echo ""
    echo "  Reasoning roles (each asks WHY and produces NEXT actions):"
    echo "    pm       — Blocked task root cause, doc/ledger consistency, queue health"
    echo "    product  — Contract gaps, MVP progress, inbox processing"
    echo "    tech     — API/Swagger drift, DB migration safety, interface breakage"
    echo "    qa       — Evidence verification, bug triage, regression risk"
    echo "    all      — All roles + push changes"
    echo ""
    echo "  Deep dives (single task, full reasoning):"
    echo "    --deep-review <TASK>      — Implementation quality + approach reasoning"
    echo "    --closure-audit <TASK>    — 7-point scoring + gap diagnosis"
    echo "    --impact-analysis <TASK>  — Dependency chain + code reference trace"
    exit 1
    ;;
esac
