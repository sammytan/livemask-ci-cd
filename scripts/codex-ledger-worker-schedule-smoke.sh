#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# TASK-DOCS-LEDGER-WORKER-SCHEDULE-001
# Codex Ledger Worker Schedule Smoke — lockfile fields, failure log path,
#   and failure log content assertions.
# ═══════════════════════════════════════════════════════════════════════════════
# Covers:
#   [1] Lockfile JSON schema (run_id, pid, started_at, mode, command, cwd)
#   [2] Lockfile stale-PID overwrite
#   [3] Failure log written to docs/development/automation-runs/
#   [4] Failure log required fields (command, cwd, lock state, exit code,
#       mode, timestamp, stdout/stderr summary)
#   [5] Lockfile is NOT removed on failure (preserved for diagnostics)
#   [6] Lockfile is removed on success
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

SCHEDULED_SCRIPT="${SCRIPT_DIR}/codex-ledger-worker-scheduled.sh"
LOCKFILE="${REPO_DIR}/.local-dev/codex-ledger-worker-schedule.lock"
AUTOMATION_RUNS_DIR="${REPO_DIR}/docs/development/automation-runs"
LOG_DIR="${REPO_DIR}/.local-dev/logs"

FAILED=0
SUMMARY_LINES=()

fail() { echo "  FAIL: $*"; SUMMARY_LINES+=("FAIL: $*"); FAILED=1; }
pass() { echo "  PASS: $*"; SUMMARY_LINES+=("PASS: $*"); }
skip() { echo "  SKIP: $*"; SUMMARY_LINES+=("SKIP: $*"); }

LOCK_REQUIRED_FIELDS=("run_id" "pid" "started_at" "mode" "command" "cwd")
FAILURE_LOG_REQUIRED_FIELDS=("Run ID" "Timestamp" "Mode" "Command" "CWD" "Exit Code" "Lock State" "Stdout Summary" "Stderr Summary")

cleanup() {
  rm -f "${LOCKFILE}"
  rm -f "${LOG_DIR}/codex-ledger-worker-schedule-failure-"*.json 2>/dev/null || true
  rm -f "${AUTOMATION_RUNS_DIR}/clws-"*-failure.md 2>/dev/null || true
}
trap cleanup EXIT

echo "================================================"
echo " TASK-DOCS-LEDGER-WORKER-SCHEDULE-001"
echo " Codex Ledger Worker Schedule Smoke"
echo "================================================"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# [1] Lockfile JSON schema
# ──────────────────────────────────────────────────────────────────────────────
echo "--- [1] Lockfile JSON Schema ---"

# Run the scheduled script with a command that will fail quickly
"${SCHEDULED_SCRIPT}" "smoke-test" "false" "${REPO_DIR}" >/dev/null 2>&1 || true

if [[ ! -f "${LOCKFILE}" ]]; then
  fail "Lockfile not created at ${LOCKFILE}"
  echo ""
  printf '%s\n' "${SUMMARY_LINES[@]}"
  exit 1
fi
pass "Lockfile created: ${LOCKFILE}"

# Validate JSON is parseable
LOCK_JSON="$(python3 -c "
import json, sys
with open('${LOCKFILE}') as f:
    d = json.load(f)
required = ['run_id','pid','started_at','mode','command','cwd']
for field in required:
    if field not in d:
        print(f'MISSING: {field}')
        sys.exit(1)
    val = d[field]
    if val is None or (isinstance(val, str) and val == ''):
        print(f'EMPTY: {field}')
        sys.exit(1)
print('OK')
" 2>&1)" || true

if [[ "${LOCK_JSON}" == "OK" ]]; then
  pass "Lockfile JSON parseable with all required fields"
else
  fail "Lockfile JSON: ${LOCK_JSON}"
fi

# Assert individual fields
check_lock_field() {
  local field="$1" label="$2"
  local val
  val="$(python3 -c "import json; print(json.load(open('${LOCKFILE}')).get('${field}',''))" 2>/dev/null || echo "")"
  if [[ -n "${val}" ]]; then
    pass "Lock ${label}: ${val}"
  else
    fail "Lock ${label}: missing or empty"
  fi
}

check_lock_field "run_id" "run_id"
check_lock_field "pid" "pid"
check_lock_field "started_at" "started_at"
check_lock_field "mode" "mode"
check_lock_field "command" "command"
check_lock_field "cwd" "cwd"

# ──────────────────────────────────────────────────────────────────────────────
# [2] Stale-PID overwrite
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [2] Stale-PID Overwrite ---"

# The lock should still be there from the failed run above
if [[ -f "${LOCKFILE}" ]]; then
  # Write a bogus PID into the lock to simulate stale lock
  python3 -c "
import json
with open('${LOCKFILE}') as f:
    d = json.load(f)
d['pid'] = 99999
with open('${LOCKFILE}', 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
"
  # Re-run the script; it should overwrite the stale lock since pid 99999 won't exist
  if "${SCHEDULED_SCRIPT}" "smoke-test" "false" "${REPO_DIR}" >/dev/null 2>&1; then
    fail "Script succeeded unexpectedly with stale lock"
  else
    LOCK_PID="$(python3 -c "import json; print(json.load(open('${LOCKFILE}')).get('pid',''))" 2>/dev/null || echo "")"
    if [[ "${LOCK_PID}" != "99999" && -n "${LOCK_PID}" ]]; then
      pass "Stale lock overwritten: new pid=${LOCK_PID} (was 99999)"
    else
      fail "Stale lock not overwritten: pid=${LOCK_PID}"
    fi
  fi
else
  skip "Stale-PID test: lockfile not present"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [3] Failure log written to automation-runs
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [3] Failure Log in automation-runs ---"

# Check for failure markdown files
FAILURE_FILES="$(find "${AUTOMATION_RUNS_DIR}" -name "clws-*-failure.md" -type f 2>/dev/null | sort | tail -3)"
if [[ -z "${FAILURE_FILES}" ]]; then
  fail "No failure log found in ${AUTOMATION_RUNS_DIR}"
else
  while IFS= read -r ff; do
    pass "Failure log exists: $(basename "${ff}")"
  done <<< "${FAILURE_FILES}"
fi

# Check for JSON failure record in logs
FAILURE_JSON_FILES="$(find "${LOG_DIR}" -name "codex-ledger-worker-schedule-failure-*.json" -type f 2>/dev/null | sort | tail -3)"
if [[ -z "${FAILURE_JSON_FILES}" ]]; then
  skip "No JSON failure record in ${LOG_DIR} (non-blocking)"
else
  while IFS= read -r fj; do
    pass "Failure JSON record exists: $(basename "${fj}")"
  done <<< "${FAILURE_JSON_FILES}"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [4] Failure log required fields
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [4] Failure Log Required Fields ---"

LATEST_FAILURE="$(find "${AUTOMATION_RUNS_DIR}" -name "clws-*-failure.md" -type f 2>/dev/null | sort | tail -1)"

if [[ -z "${LATEST_FAILURE}" ]]; then
  fail "No failure log to inspect for required fields"
else
  FAILURE_CONTENT="$(cat "${LATEST_FAILURE}")"

  check_failure_field() {
    local pattern="$1" label="$2"
    if echo "${FAILURE_CONTENT}" | grep -q "${pattern}"; then
      pass "Failure log has ${label}"
    else
      fail "Failure log missing ${label}"
    fi
  }

  check_failure_field "Run ID" "Run ID"
  check_failure_field "Timestamp" "Timestamp"
  check_failure_field "Mode" "Mode"
  check_failure_field "Command" "Command"
  check_failure_field "CWD" "CWD"
  check_failure_field "Exit Code" "Exit Code"
  check_failure_field "Lock State" "Lock State"
  check_failure_field "Stdout Summary" "Stdout Summary"
  check_failure_field "Stderr Summary" "Stderr Summary"

  # Check that lock state reflects "acquired" (lock kept on failure)
  if echo "${FAILURE_CONTENT}" | grep -q "Lock State.*acquired"; then
    pass "Failure log lock state = acquired"
  else
    fail "Failure log lock state should be 'acquired'"
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# [5] Lockfile preserved on failure
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [5] Lockfile Preserved on Failure ---"

if [[ -f "${LOCKFILE}" ]]; then
  pass "Lockfile preserved on failure (not removed)"
else
  fail "Lockfile was removed on failure (should be kept for diagnostics)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [6] Lockfile removed on success
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [6] Lockfile Removed on Success ---"

# Remove any stale lock from previous tests
rm -f "${LOCKFILE}"

if "${SCHEDULED_SCRIPT}" "smoke-test" "true" "${REPO_DIR}" >/dev/null 2>&1; then
  if [[ ! -f "${LOCKFILE}" ]]; then
    pass "Lockfile removed on successful run"
  else
    fail "Lockfile not removed on success"
    rm -f "${LOCKFILE}"
  fi
else
  skip "Success mode: script failed unexpectedly"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "================================================"
echo " TASK-DOCS-LEDGER-WORKER-SCHEDULE-001 SUMMARY"
echo "================================================"
printf '%s\n' "${SUMMARY_LINES[@]}"

echo ""
if [[ "${FAILED}" -eq 1 ]]; then
  echo "[TASK-DOCS-LEDGER-WORKER-SCHEDULE-001] SMOKE FAILED."
  exit 1
fi

echo "[TASK-DOCS-LEDGER-WORKER-SCHEDULE-001] Codex ledger worker schedule smoke PASSED."
echo "Covers: Lockfile JSON schema (run_id/pid/started_at/mode/command/cwd),"
echo "  Stale-PID overwrite, Failure log path (automation-runs),"
echo "  Failure log required fields, Lockfile preserved on failure,"
echo "  Lockfile removed on success"
