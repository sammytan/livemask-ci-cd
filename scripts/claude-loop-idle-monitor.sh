#!/usr/bin/env bash
# TASK-CICD-CLAUDE-LOOP-MACHINE-CHANNEL-LISTENER-001
# Idle-monitor: runs preflight every 30 seconds during idle phases.
# BLOCKED → report and exit with blocker info.
# WORK_AVAILABLE → report candidates and signal acceptance.
# IDLE → sleep 30s and repeat until work appears or user stops.
set -euo pipefail

PREFLIGHT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claude-loop-preflight.sh"
PREFLIGHT_DOCS="/Users/sammytan/Developer/LiveMask/livemask-docs/scripts/supervisor-action.py"
PREFLIGHT_PLANNER="/Users/sammytan/Developer/LiveMask/livemask-docs/scripts/plan-next-tasks.py"

echo "=== Claude Loop Idle Monitor (30s) ==="
echo "Started at $(date -Iseconds)"

IDLE_COUNT=0
while true; do
  PREFLIGHT_OUT=$(bash "${PREFLIGHT}" 2>&1) || PREFLIGHT_RC=$?
  PREFLIGHT_RC=${PREFLIGHT_RC:-0}

  TIMESTAMP=$(date -Iseconds)

  if [[ "${PREFLIGHT_RC}" -eq 2 ]]; then
    # BLOCKED
    echo "[${TIMESTAMP}] BLOCKED — processing blocker"
    echo "${PREFLIGHT_OUT}" | grep "^BLOCKED:" | while read line; do
      echo "  ${line}"
    done
    echo "[${TIMESTAMP}] Idle-monitor exiting: BLOCKED state requires action"
    exit 2

  elif [[ "${PREFLIGHT_RC}" -eq 1 ]]; then
    # WORK_AVAILABLE
    IDLE_COUNT=0
    echo "[${TIMESTAMP}] WORK_AVAILABLE — candidates detected"
    echo "${PREFLIGHT_OUT}" | grep "^WORK_AVAILABLE:" | while read line; do
      echo "  ${line}"
    done
    echo "[${TIMESTAMP}] Idle-monitor exiting: tasks ready for acceptance"
    exit 1

  else
    # IDLE
    IDLE_COUNT=$((IDLE_COUNT + 1))
    if [[ "${IDLE_COUNT}" -eq 1 ]]; then
      echo "[${TIMESTAMP}] IDLE — preflight clean (check #${IDLE_COUNT})"
    elif [[ $((IDLE_COUNT % 10)) -eq 0 ]]; then
      echo "[${TIMESTAMP}] IDLE — preflight clean (check #${IDLE_COUNT}, planner: $(cd /Users/sammytan/Developer/LiveMask/livemask-docs && python3 scripts/plan-next-tasks.py --format json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['summary']['candidate_count'])") candidates, $(cd /Users/sammytan/Developer/LiveMask/livemask-docs && python3 scripts/supervisor-action.py list --active-blockers --blocks-loop true 2>&1 | grep -c "SAP-" || echo "0") active SAPs)"
    fi
    sleep 30
  fi
done
