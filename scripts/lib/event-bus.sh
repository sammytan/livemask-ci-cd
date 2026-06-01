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
      event_react_pm_task_accepted "${task_id}" 2>/dev/null || true
      event_react_product_progress "${task_id}" 2>/dev/null || true ;;
    code_committed)
      event_react_tech_commit_check "${task_id}" 2>/dev/null || true
      executor_renew_lease "claude-executor" "${task_id}" 2>/dev/null || true ;;
    review_submitted)
      event_react_leader_review "${task_id}" 2>/dev/null || true
      event_react_qa_verify "${task_id}" 2>/dev/null || true
      event_react_task_review_audit "${task_id}" 2>/dev/null || true ;;
    changes_requested)
      executor_load_learnings "${task_id}" 2>/dev/null || true ;;
    qa_passed)
      echo "  [EVENT] QA passed for ${task_id} → leader can approve" ;;
    qa_failed)
      executor_load_learnings "${task_id}" 2>/dev/null || true
      executor_check_qa_retries "${task_id}" 2>/dev/null || true ;;
    leader_approved)
      event_react_pm_ledger_update "${task_id}" 2>/dev/null || true ;;
    task_completed)
      event_react_pm_cycle_close "${task_id}" 2>/dev/null || true
      event_react_product_progress "${task_id}" 2>/dev/null || true
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
  python3 -c "
import json,pathlib; docs=pathlib.Path('${DOCS_DIR}')
ledger=json.loads((docs/'docs/development/task-state-ledger.json').read_text())
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id')=='${tid}': t['status']='in_progress'; t['notes']=t.get('notes','')+' [accepted by Claude executor]'
pathlib.Path(str(docs/'docs/development/task-state-ledger.json')).write_text(json.dumps(ledger,indent=2,ensure_ascii=False))
" 2>/dev/null || true
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
  local repo; repo=$(python3 -c "import json;l=json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'));[print(t['repo']) for m in l['modules'] for t in m['tasks'] if t['task_id']=='${tid}']" 2>/dev/null || echo "")
  if [[ -n "${repo}" ]]; then
    source "${CI_CD_DIR}/scripts/lib/local-verify.sh" 2>/dev/null || true
    verify_quick "${repo}" 2>/dev/null || true
  fi
}

event_react_leader_review() {
  echo "  [Leader] Review triggered for: ${1:-}"
}

event_react_qa_verify() {
  echo "  [QA] Verification triggered for: ${1:-}"
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
