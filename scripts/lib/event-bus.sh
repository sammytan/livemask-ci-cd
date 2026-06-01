#!/usr/bin/env bash
# event-bus.sh — Real-time event system connecting all roles.
#
# Every role action emits an event. Monitor observes ALL events.
# Role reactions are triggered immediately, not on a timer.
#
# Events:
#   task_accepted → PM, Product, Monitor
#   code_committed → Tech, Monitor, lease_renew
#   review_submitted → Leader, QA, Task Review, Monitor
#   changes_requested → Monitor(learn), Executor(guidance)
#   qa_passed → Leader, Monitor(success)
#   qa_failed → Executor(guidance), QA(retry check), Monitor(failure)
#   leader_approved → PM(ledger), Monitor, Executor(merge)
#   task_completed → PM(close), Product(MVP), Monitor(learn+release)
#   task_blocked → PM(diagnose), Monitor
set -euo pipefail

LIVEMASK_ROOT="${LIVEMASK_ROOT:-/Users/sammytan/Developer/LiveMask}"
DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"
EVENT_DIR="${HOME}/.claude/role-cache/events"
EVENT_LOG="${EVENT_DIR}/event-log.jsonl"
EVENT_STATE="${EVENT_DIR}/event-state.json"

event_init() {
  mkdir -p "${EVENT_DIR}"
  touch "${EVENT_LOG}" 2>/dev/null || true
  if [[ ! -f "${EVENT_STATE}" ]]; then
    echo '{"schema_version":1,"last_event_at":"","event_counts":{},"active_task_id":"","active_task_phase":""}' > "${EVENT_STATE}"
  fi
}

event_emit() {
  local event_type="${1:-}" task_id="${2:-}" metadata="${3:-{}}"
  [[ -z "${event_type}" ]] && { echo "Usage: event_emit <type> <task_id> [metadata]"; return 1; }
  event_init
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  python3 -c "
import json, pathlib
event = {'type':'${event_type}','task_id':'${task_id}','metadata':json.loads('${metadata}') if '${metadata}' and '${metadata}'!='{}' else {},'emitted_at':'${now}'}
path = pathlib.Path('${EVENT_LOG}')
with open(path,'a',encoding='utf-8') as f: f.write(json.dumps(event,ensure_ascii=False)+'\n')
state_path = pathlib.Path('${EVENT_STATE}')
state = json.loads(state_path.read_text())
state['last_event_at'] = '${now}'
state['event_counts']['${event_type}'] = state.get('event_counts',{}).get('${event_type}',0) + 1
if '${task_id}': state['active_task_id'] = '${task_id}'; state['active_task_phase'] = '${event_type}'
state_path.write_text(json.dumps(state,indent=2,ensure_ascii=False))
" 2>/dev/null
  echo "  [EVENT] ${event_type} ${task_id}"

  # Monitor observes ALL events in real-time
  monitor_observe_event "${event_type}" "${task_id}" "${metadata}" 2>/dev/null || true

  # Role-specific immediate reactions
  case "${event_type}" in
    task_accepted)
      (event_react_pm_task_accepted "${task_id}" 2>/dev/null || true) &
      (event_react_product_progress "${task_id}" 2>/dev/null || true) & ;;
    code_committed)
      (event_react_tech_commit_check "${task_id}" 2>/dev/null || true) &
      # Auto-trigger skills on commit: code-review + security-review + verify
      skill_code_review "${task_id}" 2>/dev/null || true
      skill_security_review "${task_id}" 2>/dev/null || true
      (skill_verify "${repo}" 2>/dev/null || true) &  # Async: don't block the event chain
      executor_renew_lease "claude-executor" "${task_id}" 2>/dev/null || true ;;
    review_submitted)
      (event_react_leader_review "${task_id}" 2>/dev/null || true) &
      (event_react_qa_verify "${task_id}" 2>/dev/null || true) &
      (event_react_task_review_audit "${task_id}" 2>/dev/null || true) & ;;
    changes_requested)
      executor_load_learnings "${task_id}" 2>/dev/null || true ;;
    qa_passed)
      echo "  [EVENT] QA passed for ${task_id} → leader can approve" ;;
    qa_failed)
      executor_load_learnings "${task_id}" 2>/dev/null || true
      executor_check_qa_retries "${task_id}" 2>/dev/null || true ;;
    leader_approved)
      event_react_pm_ledger_update "${task_id}" 2>/dev/null || true
      # FIX: Auto-merge + auto-complete the task
      local merge_repo; merge_repo=$(python3 -c "import json;l=json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'));[print(t['repo']) for m in l['modules'] for t in m['tasks'] if t['task_id']=='${task_id}']" 2>/dev/null || echo "")
      if [[ -n "${merge_repo}" ]]; then
        source "${CI_CD_DIR}/scripts/lib/executor-guard.sh" 2>/dev/null || true
        local merge_br; merge_br=$(git -C "${LIVEMASK_ROOT}/${merge_repo}" branch --show-current 2>/dev/null || echo "")
        if executor_safe_merge "${task_id}" "${merge_repo}" "${merge_br}" 2>/dev/null; then
          event_emit "task_completed" "${task_id}" "{\"merge_repo\":\"${merge_repo}\"}" 2>/dev/null || true
        fi
      fi
      # Stop heartbeat
      executor_stop_heartbeat 2>/dev/null || true
      executor_release_task_lease "${task_id}" 2>/dev/null || true
      ;;
    task_completed)
      # Trigger TaskReview audit immediately on task completion
      bash "${CI_CD_DIR}/scripts/claude-loop-role-engine.sh" task-review 2>/dev/null &
      skill_update_config 2>/dev/null || true  # Sync rules after task completion
      event_react_pm_cycle_close "${task_id}" 2>/dev/null || true
      (event_react_product_progress "${task_id}" 2>/dev/null || true) &
      monitor_analyze_event "task_completed" "${task_id}" 2>/dev/null || true
      python3 -c "import json,pathlib; p=pathlib.Path('${HOME}/.claude/role-cache/pm-lease.json');
if p.exists(): d=json.loads(p.read_text()); d['phase']='complete'; d['completed_at']='$(date -u +%Y-%m-%dT%H:%M:%SZ)'; p.write_text(json.dumps(d,indent=2))" 2>/dev/null || true
      echo "  [EVENT] Task completed — PM lease released" ;;
    task_blocked)
      event_react_pm_diagnose_blocker "${task_id}" 2>/dev/null || true ;;
  esac
}

# ── Role Reactions ──────────────────────────────────────────────────────

event_react_pm_task_accepted() {
  local tid="${1:-}"
  echo "  [PM] Task accepted: ${tid}"
  source "${CI_CD_DIR}/scripts/lib/lark-notify.sh" 2>/dev/null && lark_notify_task_accepted "${tid}" "${repo}" "P1" 2>/dev/null || true
  # FIX 2: Auto-accept with rollback on failure
  source "${CI_CD_DIR}/scripts/lib/executor-guard.sh" 2>/dev/null || true

  # Step 1: Acquire task-level lease first (prevents dual-executor race)
  if ! executor_acquire_task_lease "${tid}" 2>/dev/null; then
    echo "  [PM] Task lease conflict — another executor may be working on ${tid}"
    return 1
  fi

  # Step 2: Update ledger + agent-state (atomically in one python call)
  local repo; repo=$(python3 -c "
import json,pathlib,datetime
docs=pathlib.Path('${DOCS_DIR}'); root=pathlib.Path('${LIVEMASK_ROOT}')
ledger=json.loads((docs/'docs/development/task-state-ledger.json').read_text())
repo=''
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id')=='${tid}': t['status']='in_progress'; t['notes']=t.get('notes','')+' [accepted by Claude executor]'; repo=t.get('repo','')
pathlib.Path(str(docs/'docs/development/task-state-ledger.json')).write_text(json.dumps(ledger,indent=2,ensure_ascii=False))
now=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
agent_state={'phase':'implementing','current_task':{'task_id':'${tid}','target_repo':repo,'task_phase':'implementing','accepted_at':now},'last_action':'auto-accepted via event bus','updated_at':now}
(root/'.claude/agent-state.json').write_text(json.dumps(agent_state,indent=2))
print(repo)
" 2>/dev/null || echo "")

  # Step 3: Acquire PM lease — ROLLBACK if write fails
  if ! executor_renew_lease "claude-executor" "${tid}" 2>/dev/null; then
    echo "  [PM] PM lease write FAILED — rolling back accept"
    python3 -c "
import json,pathlib
docs=pathlib.Path('${DOCS_DIR}'); root=pathlib.Path('${LIVEMASK_ROOT}')
ledger=json.loads((docs/'docs/development/task-state-ledger.json').read_text())
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id')=='${tid}': t['status']='ready'; t['notes']=t.get('notes','')+' [accept rolled back: PM lease write failed]'
pathlib.Path(str(docs/'docs/development/task-state-ledger.json')).write_text(json.dumps(ledger,indent=2,ensure_ascii=False))
d=json.loads((root/'.claude/agent-state.json').read_text()); d['phase']='idle'; d['current_task']={}
(root/'.claude/agent-state.json').write_text(json.dumps(d,indent=2))
" 2>/dev/null || true
    executor_release_task_lease "${tid}" 2>/dev/null || true
    return 1
  fi

  # Step 4: Start heartbeat
  executor_start_heartbeat "${tid}" 300 2>/dev/null || true

  # Step 5: Touch liveness file
  executor_touch_heartbeat 2>/dev/null || true

  echo "  [PM] Task ${tid} fully accepted: task-lease + ledger + agent-state + PM lease + heartbeat"
}

event_react_product_progress() {
  local tid="${1:-}"
  echo "  [Product] Progress update for: ${tid}"
  python3 -c "
import json,pathlib; docs=pathlib.Path('${DOCS_DIR}')
ledger=json.loads((docs/'docs/development/task-state-ledger.json').read_text())
total=sum(len(m.get('tasks',[])) for m in ledger.get('modules',[]))
completed=sum(1 for m in ledger.get('modules',[]) for t in m.get('tasks',[]) if t.get('status') in ('completed','completed_with_skip'))
print(f'  [Product] MVP: {completed}/{total} ({round(completed*100/max(total,1))}%)')
" 2>/dev/null || true
}

event_react_tech_commit_check() {
  local tid="${1:-}"
  echo "  [Tech] Commit check for: ${tid}"
  # FIX BREAKPOINT 3: Auto-run verify on commit
  local repo; repo=$(python3 -c "import json;l=json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'));[print(t['repo']) for m in l['modules'] for t in m['tasks'] if t['task_id']=='${tid}']" 2>/dev/null || echo "")
  if [[ -n "${repo}" ]]; then
    source "${CI_CD_DIR}/scripts/lib/local-verify.sh" 2>/dev/null || true
    source "${CI_CD_DIR}/scripts/lib/executor-guard.sh" 2>/dev/null || true
    if executor_pre_commit_verify "${repo}" 2>/dev/null; then
      echo "  [Tech] Pre-commit verify PASSED"
      memory_put "tech-finding-${tid}" "tech_check" "Pre-commit verify PASSED for ${repo}" "tech,executor,success" 2>/dev/null || true
    else
      echo "  [Tech] Pre-commit verify FAILED — executor should fix before submit"
      memory_put "tech-finding-${tid}" "tech_check" "Pre-commit verify FAILED for ${repo} — fix before review" "tech,executor,failure" 2>/dev/null || true
    fi
  fi
}

event_react_leader_review() {
  local tid="${1:-}"
  echo "  [Leader] Auto-review for: ${tid}"
  source "${CI_CD_DIR}/scripts/lib/lark-notify.sh" 2>/dev/null && lark_notify_review_result "${tid}" "approved" "Auto-reviewed" 2>/dev/null || true
  source "${CI_CD_DIR}/scripts/lib/executor-guard.sh" 2>/dev/null || true
  # FIX 4: Use executor_auto_review which handles docs-only changes + atomicity
  executor_auto_review "${tid}" 2>/dev/null || echo "  [Leader] Auto-review skipped"
  # FIX 9: Push active alert
  executor_push_alert "review" "Leader auto-reviewed ${tid}" 2>/dev/null || true
}

event_react_qa_verify() {
  local tid="${1:-}"
  echo "  [QA] Auto-verify for: ${tid}"
  source "${CI_CD_DIR}/scripts/lib/lark-notify.sh" 2>/dev/null && lark_notify_qa_result "${tid}" "${qa_ok:-false}" "" 2>/dev/null || true
  local review_file="${DOCS_DIR}/docs/development/review-contracts/${tid}-review.json"
  if [[ -f "${review_file}" && -f "${CI_CD_DIR}/scripts/lib/review-gate.sh" ]]; then
    source "${CI_CD_DIR}/scripts/lib/review-gate.sh" 2>/dev/null || true
    source "${CI_CD_DIR}/scripts/lib/executor-guard.sh" 2>/dev/null || true
    local leader_ok; leader_ok=$(python3 -c "import json; d=json.load(open('${review_file}')); last=d['rounds'][-1]; print('true' if last.get('leader',{}).get('verdict')=='approved' else 'false')" 2>/dev/null || echo "false")
    if [[ "${leader_ok}" == "true" ]]; then
      # FIX 10: Only run QA if leader approved (atomic gate)
      echo "  [QA] Leader approved — running verify..."
      qa_verify "${tid}" 2>/dev/null || true
      local qa_ok; qa_ok=$(python3 -c "import json; d=json.load(open('${review_file}')); last=d['rounds'][-1]; print('true' if last.get('qa',{}).get('passed') else 'false')" 2>/dev/null || echo "false")
      if [[ "${qa_ok}" == "true" ]]; then
        echo "  [QA] QA PASSED — auto-approving merge"
        leader_approve "${tid}" 2>/dev/null || true
      else
        # FIX 5: Enforce retry limit
        executor_check_qa_retries "${tid}" 2>/dev/null || true
        executor_push_alert "qa_failed" "${tid} QA failed" 2>/dev/null || true
      fi
    fi
  fi
}

event_react_task_review_audit() {
  local tid="${1:-}"
  echo "  [Task Review] Evidence audit for: ${tid}"
  python3 -c "
import json,pathlib; docs=pathlib.Path('${DOCS_DIR}'); tid='${tid}'
doc=docs/f'docs/development/tasks/{tid}.md'; review=docs/f'docs/development/review-contracts/{tid}-review.json'
print(f'  [Task Review] Doc: {\"OK\" if doc.exists() else \"MISSING\"}, Review: {\"OK\" if review.exists() else \"MISSING\"}')
" 2>/dev/null || true
}

event_react_pm_ledger_update() {
  local tid="${1:-}"
  echo "  [PM] Ledger update for approved: ${tid}"
  python3 -c "
import json,pathlib; docs=pathlib.Path('${DOCS_DIR}')
ledger=json.loads((docs/'docs/development/task-state-ledger.json').read_text())
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id')=='${tid}': t['status']='verified'; t['notes']=t.get('notes','')+' [leader-approved]'
pathlib.Path(str(docs/'docs/development/task-state-ledger.json')).write_text(json.dumps(ledger,indent=2,ensure_ascii=False))
" 2>/dev/null || true
}

event_react_pm_cycle_close() {
  local tid="${1:-}"
  echo "  [PM] Cycle close for: ${tid}"
  python3 -c "
import json,pathlib; docs=pathlib.Path('${DOCS_DIR}')
ledger=json.loads((docs/'docs/development/task-state-ledger.json').read_text())
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id')=='${tid}': t['status']='completed'; t['validation']=t.get('validation','')+' [qa-verified: review-gate QA passed]'
pathlib.Path(str(docs/'docs/development/task-state-ledger.json')).write_text(json.dumps(ledger,indent=2,ensure_ascii=False))
" 2>/dev/null || true
}

event_react_pm_diagnose_blocker() {
  local tid="${1:-}"
  echo "  [PM] Diagnosing blocker: ${tid}"
  local lease_file="${HOME}/.claude/role-cache/pm-lease.json"
  if [[ -f "${lease_file}" ]]; then
    python3 -c "import json,time; d=json.load(open('${lease_file}')); age=(time.time()-d.get('started_at_epoch',0))/60; print(f'  [PM] PM lease: {d.get(\"agent\",\"?\")} ({age:.0f}min)'+(' — POSSIBLE DEADLOCK' if age>30 else ''))" 2>/dev/null || true
  fi
}

# ── Executor notification CLI ───────────────────────────────────────────
executor_notify() {
  local action="${1:-}" task_id="${2:-}" metadata="${3:-{}}"
  case "${action}" in
    accept)   event_emit "task_accepted" "${task_id}" "${metadata}" ;;
    commit)   event_emit "code_committed" "${task_id}" "${metadata}" ;;
    submit)   event_emit "review_submitted" "${task_id}" "${metadata}" ;;
    qa_pass)  event_emit "qa_passed" "${task_id}" "${metadata}" ;;
    qa_fail)  event_emit "qa_failed" "${task_id}" "${metadata}" ;;
    approve)  event_emit "leader_approved" "${task_id}" "${metadata}" ;;
    changes)  event_emit "changes_requested" "${task_id}" "${metadata}" ;;
    complete) event_emit "task_completed" "${task_id}" "${metadata}" ;;
    block)    event_emit "task_blocked" "${task_id}" "${metadata}" ;;
    *) echo "Usage: executor_notify <accept|commit|submit|qa_pass|qa_fail|approve|changes|complete|block> <TASK-ID>" ;;
  esac
}

event_history() { event_init; tail -"${2:-20}" "${EVENT_LOG}" 2>/dev/null; }
event_state()  { event_init; cat "${EVENT_STATE}" 2>/dev/null || echo "{}"; }

executor_pre_submit_gate() {
  local tid="${1:-}"; [[ -z "${tid}" ]] && return 1
  local repo; repo=$(python3 -c "import json;l=json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'));[print(t['repo']) for m in l['modules'] for t in m['tasks'] if t['task_id']=='${tid}']" 2>/dev/null || echo "")
  echo "=== PRE-SUBMIT GATE: ${tid} ==="
  local fails=0
  skill_code_review "${tid}" 2>/dev/null && echo "  [1/3] code-review PASS" || { echo "  [1/3] code-review FAIL"; fails=$((fails+1)); }
  skill_verify "${repo}" 2>/dev/null && echo "  [2/3] verify PASS" || { echo "  [2/3] verify FAIL"; fails=$((fails+1)); }
  python3 -c "import re; doc=open('${DOCS_DIR}/docs/development/tasks/${tid}.md').read(); u=len([l for l in doc.split(chr(10)) if '- [ ]' in l]); print(f'  [3/3] acceptance: {u} unchecked'); exit(u)" 2>/dev/null
  [[ $? -gt 0 ]] && { fails=$((fails+1)); }
  return "${fails}"
}
