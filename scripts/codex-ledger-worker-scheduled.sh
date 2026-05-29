#!/usr/bin/env bash
set -euo pipefail

# TASK-DOCS-LEDGER-WORKER-SCHEDULE-001
# Scheduled wrapper for codex ledger worker. Acquires a JSON lock, invokes
# the worker command, and writes structured failure logs to automation-runs
# when the worker exits non-zero or crashes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

LOCKFILE="${REPO_DIR}/.local-dev/codex-ledger-worker-schedule.lock"
LOG_DIR="${REPO_DIR}/.local-dev/logs"
AUTOMATION_RUNS_DIR="${REPO_DIR}/docs/development/automation-runs"

# ── Arguments ────────────────────────────────────────────────────────────────
MODE="${1:-scheduled}"
COMMAND="${2:-python3 .livemask-docs/scripts/check-task-state-ledger.py}"
CWD="${3:-${REPO_DIR}}"

RUN_ID="clws-$(date +%Y%m%d%H%M%S)-$$"
STARTED_AT="$(date -Iseconds)"
PID=$$
LOCK_STATE="unknown"

STDOUT_FILE=""
STDERR_FILE=""

mkdir -p "${LOG_DIR}" "${AUTOMATION_RUNS_DIR}"

# ── Helpers ───────────────────────────────────────────────────────────────────

die() {
  echo "ERROR: $*" >&2
  exit 2
}

info() {
  echo "[codex-ledger-scheduled] $*"
}

# ── Lock ──────────────────────────────────────────────────────────────────────

acquire_lock() {
  if [[ -f "${LOCKFILE}" ]]; then
    local existing_pid
    existing_pid="$(python3 -c "import json; d=json.load(open('${LOCKFILE}')); print(d.get('pid',''))" 2>/dev/null || echo "")"
    if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" 2>/dev/null; then
      die "lock held by running process pid=${existing_pid}; refusing to start"
    fi
    info "stale lock from pid=${existing_pid}; overwriting"
  fi

  python3 -c "
import json, os
lock = {
    'run_id': '${RUN_ID}',
    'pid': ${PID},
    'started_at': '${STARTED_AT}',
    'mode': '${MODE}',
    'command': '${COMMAND}',
    'cwd': '${CWD}',
}
with open('${LOCKFILE}', 'w') as f:
    json.dump(lock, f, indent=2)
    f.write('\n')
"
  LOCK_STATE="acquired"
  info "lock acquired: run_id=${RUN_ID} pid=${PID}"
}

release_lock() {
  if [[ -f "${LOCKFILE}" ]]; then
    rm -f "${LOCKFILE}"
    LOCK_STATE="released"
    info "lock released: run_id=${RUN_ID}"
  fi
}

# ── Failure log ───────────────────────────────────────────────────────────────

write_failure_log() {
  local exit_code="$1"
  local stdout_summary=""
  local stderr_summary=""
  local timestamp
  timestamp="$(date -Iseconds)"

  if [[ -n "${STDOUT_FILE}" && -f "${STDOUT_FILE}" ]]; then
    stdout_summary="$(tail -n 80 "${STDOUT_FILE}" 2>/dev/null || echo "(empty)")"
  fi
  if [[ -n "${STDERR_FILE}" && -f "${STDERR_FILE}" ]]; then
    stderr_summary="$(tail -n 80 "${STDERR_FILE}" 2>/dev/null || echo "(empty)")"
  fi

  local safe_id
  safe_id="$(echo "${RUN_ID}" | tr -cd 'A-Za-z0-9_.-')"
  local failure_md="${AUTOMATION_RUNS_DIR}/${safe_id}-failure.md"

  cat > "${failure_md}" <<EOF
# Codex Ledger Worker Schedule — Failure Log

- **Run ID**: \`${RUN_ID}\`
- **Timestamp**: ${timestamp}
- **Mode**: ${MODE}
- **Command**: \`${COMMAND}\`
- **CWD**: ${CWD}
- **Exit Code**: ${exit_code}
- **PID**: ${PID}
- **Lock State**: ${LOCK_STATE}

## Stdout Summary (last 80 lines)

\`\`\`
${stdout_summary:-"(no output)"}
\`\`\`

## Stderr Summary (last 80 lines)

\`\`\`
${stderr_summary:-"(no output)"}
\`\`\`
EOF

  info "failure log written: ${failure_md}"

  # Also write a JSON failure record alongside the lockfile
  local failure_json="${LOG_DIR}/codex-ledger-worker-schedule-failure-${safe_id}.json"
  python3 -c "
import json
record = {
    'run_id': '${RUN_ID}',
    'timestamp': '${timestamp}',
    'mode': '${MODE}',
    'command': '${COMMAND}',
    'cwd': '${CWD}',
    'exit_code': ${exit_code},
    'pid': ${PID},
    'lock_state': '${LOCK_STATE}',
    'stdout_last_80': $(python3 -c "import json; print(json.dumps('''${stdout_summary}'''))" 2>/dev/null || echo '""'),
    'stderr_last_80': $(python3 -c "import json; print(json.dumps('''${stderr_summary}'''))" 2>/dev/null || echo '""'),
}
with open('${failure_json}', 'w') as f:
    json.dump(record, f, indent=2)
    f.write('\n')
"
  info "failure JSON record: ${failure_json}"
}

# ── Main ──────────────────────────────────────────────────────────────────────

acquire_lock

# Create temp files for stdout/stderr capture
STDOUT_FILE="$(mktemp)"
STDERR_FILE="$(mktemp)"

# Run the worker command; capture output
set +e
(
  cd "${CWD}" || die "cannot cd to ${CWD}"
  bash -lc "${COMMAND}"
) > "${STDOUT_FILE}" 2> "${STDERR_FILE}"
EXIT_CODE=$?
set -e

if [[ "${EXIT_CODE}" -ne 0 ]]; then
  info "worker exited non-zero: exit_code=${EXIT_CODE}"
  write_failure_log "${EXIT_CODE}"

  # Dump stderr to real stderr for visibility
  if [[ -s "${STDERR_FILE}" ]]; then
    echo "--- worker stderr ---" >&2
    tail -n 40 "${STDERR_FILE}" >&2
    echo "--- end stderr ---" >&2
  fi

  rm -f "${STDOUT_FILE}" "${STDERR_FILE}"
  # Keep lockfile on failure for diagnostics; release_lock would delete it
  exit "${EXIT_CODE}"
fi

release_lock
rm -f "${STDOUT_FILE}" "${STDERR_FILE}"
info "worker completed successfully: run_id=${RUN_ID}"
exit 0
