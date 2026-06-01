#!/usr/bin/env bash
# autonomous-loop.sh — Continuous autonomous development daemon.
# Never stops. Runs the full cycle: detect → create → accept → implement → review → QA → merge → repeat.
# Uses PM lease + heartbeat to ensure only one instance runs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIVEMASK_ROOT="/Users/sammytan/Developer/LiveMask"
DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"
ROLE_CACHE_DIR="${HOME}/.claude/role-cache"
AGENT_STATE="${LIVEMASK_ROOT}/.claude/agent-state.json"
PM_LEASE_FILE="${ROLE_CACHE_DIR}/pm-lease.json"
LOOP_PID_FILE="${ROLE_CACHE_DIR}/autonomous-loop.pid"
LOOP_LOG="/tmp/claude/autonomous-loop.log"
CYCLE_COUNT=0
MAX_CYCLES=${MAX_CYCLES:-1000}
SLEEP_BETWEEN=${SLEEP_BETWEEN:-60}  # Sleep between cycles when idle

source "${SCRIPT_DIR}/lib/logging.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/event-bus.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/executor-guard.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/review-gate.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/impl-assist.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/memory-fast.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/monitor-learn.sh" 2>/dev/null || true
event_init 2>/dev/null || true
monitor_init 2>/dev/null || true
memory_init 2>/dev/null || true
mkdir -p /tmp/claude "$(dirname "${LOOP_PID_FILE}")"

# ── Write PID ────────────────────────────────────────────────────────────
echo $$ > "${LOOP_PID_FILE}"

# ── Cleanup on exit ──────────────────────────────────────────────────────
cleanup_loop() {
  echo "[$(date -u +%H:%M:%S)] Autonomous loop exiting after ${CYCLE_COUNT} cycles" | tee -a "${LOOP_LOG}"
  rm -f "${LOOP_PID_FILE}"
  executor_stop_heartbeat 2>/dev/null || true
}
trap cleanup_loop EXIT

# ── Log helper ────────────────────────────────────────────────────────────
log_cycle() { echo "[$(date -u +%H:%M:%S)] CYCLE#${CYCLE_COUNT} $*" | tee -a "${LOOP_LOG}"; }

# ── Main autonomous loop ─────────────────────────────────────────────────
log_cycle "AUTONOMOUS DEVELOPMENT DAEMON STARTED (PID: $$, MAX: ${MAX_CYCLES})"

while [[ "${CYCLE_COUNT}" -lt "${MAX_CYCLES}" ]]; do
  CYCLE_COUNT=$((CYCLE_COUNT + 1))

  # ── Phase 0: System health ──────────────────────────────────────────
  executor_repair_agent_state 2>/dev/null || true
  executor_repair_ledger 2>/dev/null || true
  executor_cleanup_alerts 2>/dev/null || true

  # ── Phase 1: Check for work ─────────────────────────────────────────
  queue_count=$(python3 "${DOCS_DIR}/scripts/plan-next-tasks.py" --format json 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('summary',{}).get('candidate_count',0))" 2>/dev/null || echo "0")
  pkt_count=$(ls "${DOCS_DIR}/docs/development/dispatch-packets"/TASK-*.json 2>/dev/null | wc -l | tr -d ' ' || echo "0")

  log_cycle "Queue: ${queue_count} candidates, ${pkt_count} dispatch packets"

  # ── Case A: No work → create tasks or idle ──────────────────────────
  if [[ "${queue_count}" == "0" && "${pkt_count}" == "0" ]]; then
    log_cycle "No work — running role engine to create tasks"
    bash "${CI_CD_DIR}/scripts/claude-loop-role-engine.sh" all 2>&1 | grep -E "AUTO|dispatch|queue|complete" | tail -5 >> "${LOOP_LOG}" || true

    # Re-check
    pkt_count=$(ls "${DOCS_DIR}/docs/development/dispatch-packets"/TASK-*.json 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    if [[ "${pkt_count}" == "0" ]]; then
      log_cycle "Still no work — sleeping ${SLEEP_BETWEEN}s"
      sleep "${SLEEP_BETWEEN}"
      continue
    fi
  fi

  # ── Case B: Work exists but agent is already busy ───────────────────
  agent_phase=$(python3 -c "import json;print(json.load(open('${AGENT_STATE}')).get('phase','?'))" 2>/dev/null || echo "?")
  if [[ "${agent_phase}" != "idle" ]]; then
    log_cycle "Agent busy (phase=${agent_phase}) — checking liveness"
    if ! executor_check_liveness 2>/dev/null; then
      log_cycle "Agent appears DEAD — running crash recovery"
      executor_crash_recovery 2>&1 | tail -3 >> "${LOOP_LOG}" || true
    else
      log_cycle "Agent alive — waiting ${SLEEP_BETWEEN}s"
      sleep "${SLEEP_BETWEEN}"
      continue
    fi
  fi

  # ── Case C: Work exists + agent idle → ACCEPT AND IMPLEMENT ─────────
  top_pkt=$(ls "${DOCS_DIR}/docs/development/dispatch-packets"/TASK-*.json 2>/dev/null | head -1)
  [[ -z "${top_pkt}" ]] && { log_cycle "No dispatch packet found"; sleep "${SLEEP_BETWEEN}"; continue; }

  tid=$(python3 -c "import json;print(json.load(open('${top_pkt}'))['task_id'])" 2>/dev/null || echo "")
  [[ -z "${tid}" ]] && { log_cycle "Could not parse task ID"; continue; }

  log_cycle "ACCEPTING: ${tid}"

  # Step 1: Accept task
  if ! event_emit "task_accepted" "${tid}" '{"source":"autonomous-loop"}' 2>/dev/null; then
    log_cycle "Failed to accept ${tid} — retrying later"
    sleep "${SLEEP_BETWEEN}"
    continue
  fi

  # Step 2: Generate implementation plan
  log_cycle "Generating implementation plan for ${tid}"
  impl_generate_plan "${tid}" 2>&1 | head -20 >> "${LOOP_LOG}" || true

  # Step 3: Get repo context
  repo=$(python3 -c "import json;l=json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'));[print(t['repo']) for m in l['modules'] for t in m['tasks'] if t['task_id']=='${tid}']" 2>/dev/null || echo "")
  [[ -n "${repo}" ]] && impl_repo_context "${repo}" 2>&1 | head -10 >> "${LOOP_LOG}" || true

  # Step 4: Implement code (THE MODEL MUST WRITE CODE HERE)
  log_cycle "IMPLEMENTATION REQUIRED: ${tid} in ${repo}"
  log_cycle "Task doc: docs/development/tasks/${tid}.md"
  log_cycle "The model (Claude) must now write the implementation code."
  log_cycle "After implementation, the model should:"
  log_cycle "  1. Write code in ${LIVEMASK_ROOT}/${repo}"
  log_cycle "  2. Run: source ${CI_CD_DIR}/scripts/lib/event-bus.sh && executor_notify commit ${tid}"
  log_cycle "  3. Run: source ${CI_CD_DIR}/scripts/lib/review-gate.sh && executor_submit_review ${tid}"
  log_cycle "  4. Run: qa_verify ${tid}"
  log_cycle "  5. Run: leader_approve ${tid}"
  log_cycle "  6. Run: executor_notify complete ${tid}"

  # The autonomous loop pauses here — the MODEL does the implementation.
  # After implementation is committed, the event chain takes over:
  #   code_committed → verify
  #   review_submitted → leader auto-review
  #   qa_passed → leader_approve
  #   leader_approved → auto-merge + task_completed
  log_cycle "Waiting for model to implement... (monitoring heartbeat)"

  # Monitor: wait for task_completed event, checking every 30s
  wait_count=0
  while [[ "${wait_count}" -lt 120 ]]; do  # Max 60 min wait
    # Check if task is completed
    task_status=$(python3 -c "import json;l=json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'));[print(t['status']) for m in l['modules'] for t in m['tasks'] if t['task_id']=='${tid}']" 2>/dev/null || echo "unknown")

    if [[ "${task_status}" == "completed" || "${task_status}" == "completed_with_skip" ]]; then
      log_cycle "TASK COMPLETED: ${tid} (status=${task_status})"
      event_emit "task_completed" "${tid}" '{"source":"autonomous-loop","auto_detected":true}' 2>/dev/null || true
      break
    fi

    # Check liveness
    if ! executor_check_liveness 2>/dev/null; then
      log_cycle "WARNING: Executor appears dead — recovering"
      executor_crash_recovery 2>&1 | tail -3 >> "${LOOP_LOG}" || true
      break
    fi

    # Touch heartbeat to show the loop is alive
    executor_touch_heartbeat 2>/dev/null || true

    wait_count=$((wait_count + 1))
    sleep 30
  done

  if [[ "${wait_count}" -ge 120 ]]; then
    log_cycle "TIMEOUT: ${tid} not completed within 60 min — releasing"
    executor_stop_heartbeat 2>/dev/null || true
    executor_release_task_lease "${tid}" 2>/dev/null || true
  fi

  log_cycle "Cycle ${CYCLE_COUNT} complete — starting next cycle"
done

log_cycle "MAX_CYCLES (${MAX_CYCLES}) reached — exiting"
