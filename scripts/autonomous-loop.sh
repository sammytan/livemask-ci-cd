#!/usr/bin/env bash
# autonomous-loop.sh — Continuous autonomous development daemon v2.
# Integrates adapter-lib.sh shared knowledge + GitHub issues/comments.
# Every sleep is labeled with WHY. Never stops unless explicitly killed.
# Daemon MUST NEVER exit on error. All error handling is explicit.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIVEMASK_ROOT="/Users/sammytan/Developer/LiveMask"
export DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"
ROLE_CACHE_DIR="${HOME}/.claude/role-cache"
AGENT_STATE="${LIVEMASK_ROOT}/.claude/agent-state.json"
PM_LEASE_FILE="${ROLE_CACHE_DIR}/pm-lease.json"
LOOP_PID_FILE="${ROLE_CACHE_DIR}/autonomous-loop.pid"
LOOP_LOG="/tmp/claude/autonomous-loop.log"
CYCLE_COUNT=0
CONSECUTIVE_BLOCKS=0
MAX_CONSECUTIVE_BLOCKS=6  # Stop creating tasks after 6 consecutive blocks
SLEEP_IDLE=60    # Sleep when no work
SLEEP_BUSY=30    # Sleep when agent is busy
SLEEP_CYCLE=5    # Minimum sleep between cycles
SLEEP_RETRY=60   # Sleep after failure before retry
SLEEP_CRASH=60   # Sleep after crash recovery
SLEEP_DEADLOOP=120 # Sleep after dead-loop detection
MAX_ATTEMPTS=3   # Max attempts per task before skip
WAIT_CHECK=30    # Check interval while waiting for model
WAIT_MAX=120     # Max checks before timeout (60 min)
ADAPTER_LIB="${CI_CD_DIR}/scripts/event-adapters/lib/adapter-lib.sh"

source "${SCRIPT_DIR}/lib/logging.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/event-bus.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/executor-guard.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/review-gate.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/impl-assist.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/memory-fast.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/monitor-learn.sh" 2>/dev/null || true
source "${ADAPTER_LIB}" 2>/dev/null || true
# CRITICAL: adapter-lib.sh overrides DOCS_DIR to DOCS_REPO_DIR/docs — restore ours
export DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"
event_init 2>/dev/null || true
monitor_init 2>/dev/null || true
memory_init 2>/dev/null || true
mkdir -p /tmp/claude "$(dirname "${LOOP_PID_FILE}")"

echo $$ > "${LOOP_PID_FILE}"

cleanup_loop() {
  echo "[$(date -u +%H:%M:%S)] Daemon exiting after ${CYCLE_COUNT} cycles" | tee -a "${LOOP_LOG}"
  rm -f "${LOOP_PID_FILE}"
  executor_stop_heartbeat 2>/dev/null || true
}
trap cleanup_loop EXIT

# ── Watchdog: auto-restart daemon if it dies ─────────────────────────
daemon_watchdog() {
  local pid_file="${LOOP_PID_FILE}"
  local script_path="${CI_CD_DIR}/scripts/autonomous-loop.sh"
  while true; do
    sleep 60
    if [[ ! -f "${pid_file}" ]]; then break; fi
    local recorded_pid; recorded_pid=$(cat "${pid_file}" 2>/dev/null || echo "0")
    if ! kill -0 "${recorded_pid}" 2>/dev/null; then
      echo "[$(date -u +%H:%M:%S)] WATCHDOG: Daemon PID ${recorded_pid} died — restarting" | tee -a "${LOOP_LOG}"
      kill "${recorded_pid}" 2>/dev/null || true; sleep 1; nohup bash "${script_path}" &>/tmp/claude/autonomous-loop-stdout.log &
      break  # Old watchdog dies, new daemon starts its own watchdog
    fi
  done
}
# Start watchdog in background (only if not already watched)
if [[ -z "${WATCHDOG_ACTIVE:-}" ]]; then
  export WATCHDOG_ACTIVE=1
  daemon_watchdog &
fi

log_cycle() { echo "[$(date -u +%H:%M:%S)] CYCLE#${CYCLE_COUNT} $*" | tee -a "${LOOP_LOG}"; }

# ── GitHub status update ──────────────────────────────────────────────────
post_github_status() {
  local context="$1" message="$2"
  # Post to #68 (control channel) for cross-role visibility
  if command -v gh &>/dev/null && executor_gh_available 2>/dev/null; then
    gh issue comment 68 --repo MyAiDevs/livemask-docs \
      --body "<!-- autonomous-loop --> [$(date -u +%H:%M:%SZ)] ${context}: ${message}" 2>/dev/null || true
  fi
}

# ── Adapter knowledge sync ────────────────────────────────────────────────
sync_knowledge() {
  # Search recent knowledge for the current task context
  if [[ -n "${1:-}" ]]; then
    bash "${ADAPTER_LIB}" knowledge-search "${1}" 8 2>/dev/null | head -5 >> "${LOOP_LOG}" || true
  fi
  # Query PM status
  bash "${ADAPTER_LIB}" pm-status 2>/dev/null | python3 -c "import json,sys;d=json.load(sys.stdin);print(f'PM: {d.get(\"pm_lease\",\"?\")}')" 2>/dev/null >> "${LOOP_LOG}" || true
}

# ── Main autonomous loop ─────────────────────────────────────────────────
log_cycle "DAEMON STARTED (PID: $$, adapter=$(test -f "${ADAPTER_LIB}" && echo OK || echo MISSING))"

while [[ "${CYCLE_COUNT}" -lt 1000 ]]; do
  CYCLE_COUNT=$((CYCLE_COUNT + 1))
  set +e  # NEVER exit — daemon tolerates all failures

  # ── SLEEP: Prevent rapid CPU burn between every cycle ──────────────
  sleep "${SLEEP_CYCLE}"

  # ── Phase 0: System health ──────────────────────────────────────────
  executor_repair_agent_state 2>/dev/null || true
  executor_repair_ledger 2>/dev/null || true
  executor_cleanup_alerts 2>/dev/null || true
  # Clean up orphaned branches every 10 cycles to prevent disk bloat
  if [[ $((CYCLE_COUNT % 10)) -eq 0 ]]; then
    log_cycle "Running branch cleanup (every 10 cycles)"
    bash "${CI_CD_DIR}/scripts/cleanup-branches.sh" 2>&1 | tail -3 >> "${LOOP_LOG}" || true
    sleep 5  # SLEEP: let git operations settle
  fi

  # ── Phase 1: Check work availability ────────────────────────────────
  queue_count=$(python3 "${DOCS_DIR}/scripts/plan-next-tasks.py" --format json 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('summary',{}).get('candidate_count',0))" 2>/dev/null || echo "0")
  pkt_count=$(python3 -c 'import pathlib; p=pathlib.Path("'"${DOCS_DIR}"'/docs/development/dispatch-packets"); print(len(list(p.glob("TASK-*.json"))))' 2>/dev/null || echo 0)
  echo "DEBUG pkt_count=[${pkt_count}] DOCS_DIR=[${DOCS_DIR}]" >> "${LOOP_LOG}"
  log_cycle "Queue: ${queue_count} candidates, ${pkt_count} packets, ${CONSECUTIVE_BLOCKS} consecutive blocks"

  # ── ALL-TASKS-BLOCKED DETECTION ─────────────────────────────────────
  if [[ "${CONSECUTIVE_BLOCKS}" -ge "${MAX_CONSECUTIVE_BLOCKS}" ]]; then
    log_cycle "CRITICAL: ${CONSECUTIVE_BLOCKS} consecutive blocked tasks — stopping task creation"
    post_github_status "BLOCKED_CASCADE" "${CONSECUTIVE_BLOCKS} consecutive tasks blocked. Human review needed."
    # Write to adapter knowledge base
    bash "${ADAPTER_LIB}" memory-add "autonomous-loop" "" "livemask-ci-cd" \
      "ALL_TASKS_BLOCKED: ${CONSECUTIVE_BLOCKS} consecutive blocks. Daemon paused task creation." \
      "${LOOP_LOG}" 2>/dev/null || true
    # SLEEP: Long sleep waiting for human intervention
    log_cycle "Sleeping 300s — waiting for human to unblock tasks"
    sleep 300
    CONSECUTIVE_BLOCKS=0  # Reset to try again
    continue
  fi

  # ── Case A: No work → create tasks ──────────────────────────────────
  if [[ "${queue_count}" -eq 0 && "${pkt_count}" -eq 0 ]]; then
    log_cycle "No work — running role engine to create tasks"
    (bash "${CI_CD_DIR}/scripts/claude-loop-role-engine.sh" all 2>&1 || true) | tail -10 >> "${LOOP_LOG}" || true

    # Re-check after role engine
    pkt_count=$(python3 -c 'import pathlib; p=pathlib.Path("'"${DOCS_DIR}"'/docs/development/dispatch-packets"); print(len(list(p.glob("TASK-*.json"))))' 2>/dev/null || echo 0)
  echo "DEBUG pkt_count=[${pkt_count}] DOCS_DIR=[${DOCS_DIR}]" >> "${LOOP_LOG}"
    if [[ "${pkt_count}" -eq 0 ]]; then
      log_cycle "Still no work — syncing knowledge base"
      sync_knowledge "task creation gap" 2>/dev/null || true
      # Post to GitHub for visibility
      post_github_status "QUEUE_EMPTY" "No dispatchable tasks. Role engine found no gaps." 2>/dev/null || true
      # SLEEP: No work available, wait before re-checking
      log_cycle "Sleeping ${SLEEP_IDLE}s — waiting for new tasks to appear"
      sleep "${SLEEP_IDLE}"
      continue
    fi
  fi

  # ── Case B: Agent busy → monitor ────────────────────────────────────
  agent_phase=$(python3 -c "import json;print(json.load(open('${AGENT_STATE}')).get('phase','?'))" 2>/dev/null || echo "?")
  if [[ "${agent_phase}" != "idle" ]]; then
    log_cycle "Agent busy (phase=${agent_phase}) — checking liveness"
    if ! executor_check_liveness 2>/dev/null; then
      log_cycle "Agent DEAD — running crash recovery"
      executor_crash_recovery 2>&1 | tail -5 >> "${LOOP_LOG}" || true
      # Sync with adapter
      bash "${ADAPTER_LIB}" memory-add "autonomous-loop" "" "livemask-ci-cd" \
        "Crash recovery triggered: agent was ${agent_phase}, liveness check failed" \
        "${LOOP_LOG}" 2>/dev/null || true
      # SLEEP: Cool down after crash recovery before re-accepting
      log_cycle "Sleeping ${SLEEP_CRASH}s — cooldown after crash recovery"
      sleep "${SLEEP_CRASH}"
      continue
    else
      log_cycle "Agent alive — waiting"
      # SLEEP: Agent is doing work, wait before checking again
      sleep "${SLEEP_BUSY}"
      continue
    fi
  fi

  # ── Case C: Work exists + agent idle → ACCEPT ───────────────────────
  top_pkt=$(ls "${DOCS_DIR}/docs/development/dispatch-packets"/TASK-*.json 2>/dev/null | head -1)
  [[ -z "${top_pkt}" ]] && { log_cycle "No dispatch packet"; sleep "${SLEEP_IDLE}"; continue; }

  tid=$(python3 -c "import json;print(json.load(open('${top_pkt}'))['task_id'])" 2>/dev/null || echo "")
  [[ -z "${tid}" ]] && { log_cycle "Bad packet"; sleep "${SLEEP_RETRY}"; continue; }

  # ── DEAD-LOOP DETECTION ─────────────────────────────────────────────
  ATTEMPT_FILE="${ROLE_CACHE_DIR}/task-attempts/${tid}.count"
  mkdir -p "$(dirname "${ATTEMPT_FILE}")" 2>/dev/null
  attempt_count=$(cat "${ATTEMPT_FILE}" 2>/dev/null || echo "0")
  attempt_count=$((attempt_count + 1))
  echo "${attempt_count}" > "${ATTEMPT_FILE}"

  if [[ "${attempt_count}" -gt "${MAX_ATTEMPTS}" ]]; then
    log_cycle "DEAD-LOOP: ${tid} failed ${attempt_count} times — SKIPPING"
    CONSECUTIVE_BLOCKS=$((CONSECUTIVE_BLOCKS + 1))
    # Mark blocked in ledger
    python3 -c "
import json,pathlib
l=json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in l['modules']:
    for t in m['tasks']:
        if t.get('task_id')=='${tid}': t['status']='blocked'; t['notes']=t.get('notes','')+' [BLOCKED: dead-loop after ${attempt_count} attempts]'
pathlib.Path('${DOCS_DIR}/docs/development/task-state-ledger.json').write_text(json.dumps(l,indent=2,ensure_ascii=False))
" 2>/dev/null || true
    rm -f "${top_pkt}" 2>/dev/null || true
    executor_push_alert "dead_loop" "${tid} blocked (${attempt_count} attempts)" 2>/dev/null || true
    post_github_status "DEAD_LOOP" "${tid} blocked after ${attempt_count} failed implementation attempts" 2>/dev/null || true
    bash "${ADAPTER_LIB}" memory-add "autonomous-loop" "${tid}" "livemask-ci-cd" \
      "DEAD-LOOP: ${tid} blocked after ${attempt_count} failed attempts" \
      "${LOOP_LOG}" 2>/dev/null || true
    # SLEEP: Long pause after detecting a dead loop
    log_cycle "Sleeping ${SLEEP_DEADLOOP}s — dead-loop cooldown"
    sleep "${SLEEP_DEADLOOP}"
    continue
  fi

  log_cycle "ACCEPTING: ${tid} (attempt ${attempt_count}/${MAX_ATTEMPTS})"

  # ── ACCEPT TASK ─────────────────────────────────────────────────────
  if ! event_emit "task_accepted" "${tid}" '{"source":"autonomous-loop"}' 2>/dev/null; then
    log_cycle "Accept failed — retrying after sleep"
    sleep "${SLEEP_RETRY}"
    continue
  fi

  # ── Generate implementation plan ────────────────────────────────────
  log_cycle "Generating implementation plan"
  impl_generate_plan "${tid}" 2>&1 | head -20 >> "${LOOP_LOG}" || true

  # Get repo context
  repo=$(python3 -c "import json;l=json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'));[print(t['repo']) for m in l['modules'] for t in m['tasks'] if t['task_id']=='${tid}']" 2>/dev/null || echo "")
  [[ -n "${repo}" ]] && impl_repo_context "${repo}" 2>&1 | head -10 >> "${LOOP_LOG}" || true

  # ── Sync knowledge base ────────────────────────────────────────────
  sync_knowledge "${tid}" 2>/dev/null || true

  # ── Post GitHub status ──────────────────────────────────────────────
  post_github_status "TASK_ACCEPTED" "${tid} in ${repo} (attempt ${attempt_count}/${MAX_ATTEMPTS})" 2>/dev/null || true

  # ── Model implementation instructions ───────────────────────────────
  log_cycle "WAITING FOR MODEL: ${tid} in ${repo}"
  log_cycle "Model must: 1) write code 2) executor_notify commit ${tid} 3) executor_submit_review ${tid}"

  # ── Monitor loop: wait for model ────────────────────────────────────
  wait_count=0
  while [[ "${wait_count}" -lt "${WAIT_MAX}" ]]; do
    task_status=$(python3 -c "import json;l=json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'));[print(t['status']) for m in l['modules'] for t in m['tasks'] if t['task_id']=='${tid}']" 2>/dev/null || echo "unknown")

    case "${task_status}" in
      completed|completed_with_skip)
        log_cycle "TASK COMPLETED: ${tid}"
        event_emit "task_completed" "${tid}" '{"source":"autonomous-loop"}' 2>/dev/null || true
        CONSECUTIVE_BLOCKS=0  # Reset block counter on success
        # Write success to adapter memory
        bash "${ADAPTER_LIB}" memory-add "autonomous-loop" "${tid}" "${repo}" \
          "Task completed successfully after ${attempt_count} attempt(s)" \
          "${LOOP_LOG}" 2>/dev/null || true
        post_github_status "TASK_COMPLETED" "${tid} completed successfully" 2>/dev/null || true
        break
        ;;
      blocked)
        log_cycle "Task ${tid} was blocked externally — moving on"
        CONSECUTIVE_BLOCKS=$((CONSECUTIVE_BLOCKS + 1))
        break
        ;;
    esac

    # Check executor liveness
    if ! executor_check_liveness 2>/dev/null; then
      log_cycle "Executor appears DEAD — crash recovery"
      executor_crash_recovery 2>&1 | tail -3 >> "${LOOP_LOG}" || true
      break
    fi

    executor_touch_heartbeat 2>/dev/null || true
    wait_count=$((wait_count + 1))
    # SLEEP: Wait for model to implement, checking periodically
    sleep "${WAIT_CHECK}"
  done

  if [[ "${wait_count}" -ge "${WAIT_MAX}" ]]; then
    log_cycle "TIMEOUT: ${tid} not completed within 60 min — releasing"
    executor_stop_heartbeat 2>/dev/null || true
    executor_release_task_lease "${tid}" 2>/dev/null || true
    CONSECUTIVE_BLOCKS=$((CONSECUTIVE_BLOCKS + 1))
    post_github_status "IMPLEMENTATION_TIMEOUT" "${tid} timed out after 60min" 2>/dev/null || true
  fi

  # ── End of cycle ────────────────────────────────────────────────────
  log_cycle "Cycle complete"
  # Reset agent for next cycle
  python3 -c "import json,pathlib; d=json.load(open('${AGENT_STATE}')); d['phase']='idle'; d['current_task']={}; d['updated_at']='$(date -u +%Y-%m-%dT%H:%M:%SZ)'; pathlib.Path('${AGENT_STATE}').write_text(json.dumps(d,indent=2))" 2>/dev/null || true

  # SLEEP: Pause between full cycles
  log_cycle "Sleeping ${SLEEP_CYCLE}s between cycles"
done

log_cycle "MAX_CYCLES reached — exiting"
