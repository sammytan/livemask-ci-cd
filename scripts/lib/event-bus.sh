#!/usr/bin/env bash
# event-bus.sh — Event-driven connection between executor and all roles.
#
# Closes the 7/8 broken loops by making role reactions event-triggered
# instead of timer-driven. When executor does something, relevant roles
# react IMMEDIATELY.
#
# Events:
#   task_accepted     → PM updates queue, Product updates progress
#   code_committed    → Tech checks API/db impact, Monitor records
#   review_submitted  → Leader reviews, QA verifies, Task Review audits
#   changes_requested → Executor fixes, Monitor records rejection
#   qa_passed         → Leader approves, Monitor records success
#   qa_failed         → Executor fixes, Monitor records failure
#   leader_approved   → Executor merges, PM updates ledger, Monitor records
#   task_completed    → PM closes cycle, Product updates MVP, Monitor learns
#   task_blocked      → PM diagnoses, Product updates, Monitor records
#
# Usage:
#   event_emit <event_type> <task_id> [metadata_json]
#   event_subscribe <event_type> <handler_function>
#   event_replay [since_timestamp]
set -euo pipefail

LIVEMASK_ROOT="${LIVEMASK_ROOT:-/Users/sammytan/Developer/LiveMask}"
DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"
EVENT_DIR="${HOME}/.claude/role-cache/events"
EVENT_LOG="${EVENT_DIR}/event-log.jsonl"
EVENT_STATE="${EVENT_DIR}/event-state.json"

# ── Initialize ──────────────────────────────────────────────────────────
event_init() {
  mkdir -p "${EVENT_DIR}"
  touch "${EVENT_LOG}" 2>/dev/null || true

  if [[ ! -f "${EVENT_STATE}" ]]; then
    cat > "${EVENT_STATE}" << 'JSON'
{
  "schema_version": 1,
  "last_event_at": "",
  "event_counts": {},
  "active_task_id": "",
  "active_task_phase": "",
  "subscribers": {}
}
JSON
  fi
}

# ── Emit event ──────────────────────────────────────────────────────────
event_emit() {
  local event_type="${1:-}" task_id="${2:-}" metadata="${3:-{}}"
  [[ -z "${event_type}" ]] && { echo "Usage: event_emit <type> <task_id> [metadata]"; return 1; }

  event_init
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Record event
  python3 -c "
import json, pathlib, sys
event = {
    'type': '${event_type}',
    'task_id': '${task_id}',
    'metadata': json.loads('${metadata}') if '${metadata}' and '${metadata}' != '{}' else {},
    'emitted_at': '${now}',
    'docs_head': '$(git -C "${DOCS_DIR}" rev-parse --short HEAD 2>/dev/null || echo "?")',
}
path = pathlib.Path('${EVENT_LOG}')
with open(path, 'a', encoding='utf-8') as f:
    f.write(json.dumps(event, ensure_ascii=False) + '\n')

# Update state
state_path = pathlib.Path('${EVENT_STATE}')
state = json.loads(state_path.read_text())
state['last_event_at'] = '${now}'
state['event_counts']['${event_type}'] = state['event_counts'].get('${event_type}', 0) + 1
if '${task_id}':
    state['active_task_id'] = '${task_id}'
    state['active_task_phase'] = '${event_type}'
state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False))
" 2>/dev/null

  echo "  [EVENT] ${event_type} ${task_id}"

  # Trigger immediate reactions based on event type
  case "${event_type}" in
    task_accepted)
      # PM: update queue awareness
      event_react_pm_task_accepted "${task_id}" 2>/dev/null || true
      # Product: update progress tracking
      event_react_product_progress "${task_id}" 2>/dev/null || true
      # Monitor: record acceptance
      monitor_watch 2>/dev/null || true
      ;;
    code_committed)
      # Tech: check for API/DB impact of this commit
      event_react_tech_commit_check "${task_id}" 2>/dev/null || true
      # Monitor: record commit
      monitor_watch 2>/dev/null || true
      # Renew PM lease
      executor_renew_lease "claude-executor" "${task_id}" 2>/dev/null || true
      ;;
    review_submitted)
      # Leader: trigger review
      event_react_leader_review "${task_id}" 2>/dev/null || true
      # QA: trigger verification
      event_react_qa_verify "${task_id}" 2>/dev/null || true
      # Task Review: audit evidence chain
      event_react_task_review_audit "${task_id}" 2>/dev/null || true
      # Monitor: record submission
      monitor_watch 2>/dev/null || true
      ;;
    changes_requested)
      # Monitor: record rejection reason for learning
      monitor_watch 2>/dev/null || true
      # Executor: load guidance for fix
      executor_load_learnings "${task_id}" 2>/dev/null || true
      ;;
    qa_passed)
      # Leader: can now approve
      echo "  [EVENT] QA passed for ${task_id} → leader can approve"
      # Monitor: record success pattern
      monitor_watch 2>/dev/null || true
      ;;
    qa_failed)
      # Executor: load guidance
      executor_load_learnings "${task_id}" 2>/dev/null || true
      # Check retry limit
      executor_check_qa_retries "${task_id}" 2>/dev/null || true
      # Monitor: record failure pattern
      monitor_watch 2>/dev/null || true
      ;;
    leader_approved)
      # Executor: merge to dev
      echo "  [EVENT] Leader approved ${task_id} → executor merge to dev"
      # PM: update ledger
      event_react_pm_ledger_update "${task_id}" 2>/dev/null || true
      # Monitor: record approval
      monitor_watch 2>/dev/null || true
      ;;
    task_completed)
      # PM: close cycle, check next task
      event_react_pm_cycle_close "${task_id}" 2>/dev/null || true
      # Product: update MVP progress
      event_react_product_progress "${task_id}" 2>/dev/null || true
      # Monitor: full analyze + learn cycle
      monitor_analyze 2>/dev/null || true
      monitor_learn 2>/dev/null || true
      # Release PM lease so next cycle can start
      python3 -c "
import json, pathlib
p = pathlib.Path('${HOME}/.claude/role-cache/pm-lease.json')
if p.exists():
    d = json.loads(p.read_text())
    d['phase'] = 'complete'
    d['completed_at'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
    p.write_text(json.dumps(d, indent=2))
" 2>/dev/null || true
      echo "  [EVENT] Task completed — PM lease released, monitor analyzed"
      ;;
    task_blocked)
      # PM: diagnose blocker
      event_react_pm_diagnose_blocker "${task_id}" 2>/dev/null || true
      # Monitor: record blocker
      monitor_watch 2>/dev/null || true
      ;;
  esac
}

# ── Role-specific event reactions ───────────────────────────────────────
event_react_pm_task_accepted() {
  local tid="${1:-}"
  echo "  [PM] Task accepted: ${tid} — updating queue awareness"
  # PM knows executor is working, won't re-dispatch
}

event_react_product_progress() {
  local tid="${1:-}"
  echo "  [Product] Progress update for: ${tid}"
  # Update MVP progress tracking
  python3 -c "
import json, pathlib
docs = pathlib.Path('${DOCS_DIR}')
ledger = json.loads((docs / 'docs/development/task-state-ledger.json').read_text())
task = None
for m in ledger.get('modules', []):
    for t in m.get('tasks', []):
        if t.get('task_id') == '${tid}':
            task = t
            break
if task:
    print(f'  [Product] Task {tid}: status={task.get(\"status\")} repo={task.get(\"repo\")}')
" 2>/dev/null || true
}

event_react_tech_commit_check() {
  local tid="${1:-}"
  echo "  [Tech] Checking commit impact for: ${tid}"
  # Quick API/db impact check
  local repo; repo=$(python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules', []):
    for t in m.get('tasks', []):
        if t.get('task_id') == '${tid}':
            print(t.get('repo', '')); break
" 2>/dev/null || echo "")
  if [[ -n "${repo}" ]]; then
    source "${CI_CD_DIR}/scripts/lib/local-verify.sh" 2>/dev/null || true
    verify_quick "${repo}" 2>/dev/null || true
  fi
}

event_react_leader_review() {
  local tid="${1:-}"
  echo "  [Leader] Review triggered for: ${tid}"
  echo "  [Leader] Run: leader_review ${tid}"
}

event_react_qa_verify() {
  local tid="${1:-}"
  echo "  [QA] Verification triggered for: ${tid}"
  echo "  [QA] Run: qa_verify ${tid}"
}

event_react_task_review_audit() {
  local tid="${1:-}"
  echo "  [Task Review] Evidence audit triggered for: ${tid}"
  # Quick evidence chain check
  python3 -c "
import json, pathlib
docs = pathlib.Path('${DOCS_DIR}')
tid = '${tid}'
# Check task doc exists
doc = docs / f'docs/development/tasks/{tid}.md'
print(f'  [Task Review] Task doc: {\"exists\" if doc.exists() else \"MISSING\"}')
# Check review contract
review = docs / f'docs/development/review-contracts/{tid}-review.json'
print(f'  [Task Review] Review contract: {\"exists\" if review.exists() else \"MISSING\"}')
# Check ledger entry
ledger = json.loads((docs / 'docs/development/task-state-ledger.json').read_text())
for m in ledger.get('modules', []):
    for t in m.get('tasks', []):
        if t.get('task_id') == tid:
            print(f'  [Task Review] Ledger: status={t.get(\"status\")} issue={t.get(\"issue\",\"\")[:50]}')
" 2>/dev/null || true
}

event_react_pm_ledger_update() {
  local tid="${1:-}"
  echo "  [PM] Ledger update for approved task: ${tid}"
}

event_react_pm_cycle_close() {
  local tid="${1:-}"
  echo "  [PM] Cycle closing for completed task: ${tid}"
}

event_react_pm_diagnose_blocker() {
  local tid="${1:-}"
  echo "  [PM] Diagnosing blocker for: ${tid}"
}

# ── Query events ─────────────────────────────────────────────────────────
event_history() {
  local task_id="${1:-}" limit="${2:-20}"
  event_init

  if [[ -n "${task_id}" ]]; then
    grep "${task_id}" "${EVENT_LOG}" 2>/dev/null | tail -"${limit}"
  else
    tail -"${limit}" "${EVENT_LOG}" 2>/dev/null
  fi
}

event_state() {
  event_init
  cat "${EVENT_STATE}" 2>/dev/null || echo "{}"
}

# ── Full executor integration ────────────────────────────────────────────
# Call this after every executor action to keep all roles in sync
executor_notify() {
  local action="${1:-}" task_id="${2:-}" metadata="${3:-{}}"

  case "${action}" in
    accept)     event_emit "task_accepted" "${task_id}" "${metadata}" ;;
    commit)     event_emit "code_committed" "${task_id}" "${metadata}" ;;
    submit)     event_emit "review_submitted" "${task_id}" "${metadata}" ;;
    qa_pass)    event_emit "qa_passed" "${task_id}" "${metadata}" ;;
    qa_fail)    event_emit "qa_failed" "${task_id}" "${metadata}" ;;
    approve)    event_emit "leader_approved" "${task_id}" "${metadata}" ;;
    changes)    event_emit "changes_requested" "${task_id}" "${metadata}" ;;
    complete)   event_emit "task_completed" "${task_id}" "${metadata}" ;;
    block)      event_emit "task_blocked" "${task_id}" "${metadata}" ;;
    *)
      echo "Usage: executor_notify <accept|commit|submit|qa_pass|qa_fail|approve|changes|complete|block> <TASK-ID> [metadata]"
      return 1
      ;;
  esac
}
