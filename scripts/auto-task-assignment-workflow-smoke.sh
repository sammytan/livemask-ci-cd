#!/usr/bin/env bash
# TASK-CICD-AUTO-TASK-ASSIGNMENT-WORKFLOW-INTEGRATION-001
#
# Deterministic smoke tests for the auto-task-assignment workflow YAML.
#
# Smoke coverage:
#   WSC-01  workflow file exists and is workflow_dispatch only
#   WSC-02  default mode is dry-run
#   WSC-03  no approved-submit reference in workflow
#   WSC-04  implement-for-review is not an allowed input option
#   WSC-05  run_smoke defaults to true
#   WSC-06  skip-worker-invoke is always used (no worker mutation)
#   WSC-07  py_compile passes on auto-task-assignment.py
#   WSC-08  bash -n passes on auto-task-assignment-smoke.sh
#   WSC-09  bash -n passes on auto-task-assignment-workflow-smoke.sh (self)

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/auto-task-assignment.yml"

PASS_COUNT=0
FAIL_COUNT=0
FAILURES=""

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "  PASS: ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  FAIL: ${label}"
    echo "    Expected: '${expected}'"
    echo "    Actual:   '${actual}'"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES="${FAILURES}  ${label}\n"
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "${haystack}" | grep -qF -- "${needle}"; then
    echo "  PASS: ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  FAIL: ${label}"
    echo "    Expected to contain: '${needle}'"
    echo "    Actual: '$(echo "${haystack}" | head -5)'"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES="${FAILURES}  ${label}\n"
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if ! echo "${haystack}" | grep -qF -- "${needle}"; then
    echo "  PASS: ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  FAIL: ${label}"
    echo "    Should NOT contain: '${needle}'"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES="${FAILURES}  ${label}\n"
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  if [[ -f "${path}" ]]; then
    echo "  PASS: ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  FAIL: ${label} (file not found: ${path})"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES="${FAILURES}  ${label} (file not found)\n"
  fi
}

# ============================================================================
# WSC-01: Workflow file exists and is workflow_dispatch only
# ============================================================================

test_workflow_exists_and_dispatch_only() {
  echo ""
  echo "=== WSC-01: workflow file exists and is workflow_dispatch only ==="

  assert_file_exists "WSC-01: workflow file exists" "${WORKFLOW_FILE}"

  local content
  content="$(cat "${WORKFLOW_FILE}")"

  # Must have workflow_dispatch
  assert_contains "WSC-01: has workflow_dispatch" "${content}" "workflow_dispatch:"

  # Must NOT have push, pull_request, or schedule triggers (only workflow_dispatch)
  assert_not_contains "WSC-01: no push trigger" "${content}" "*push:"
  assert_not_contains "WSC-01: no pull_request trigger" "${content}" "*pull_request:"
  assert_not_contains "WSC-01: no schedule trigger" "${content}" "*schedule:"
  assert_not_contains "WSC-01: no cron" "${content}" "cron:"
}

# ============================================================================
# WSC-02: Default mode is dry-run
# ============================================================================

test_default_mode_is_dry_run() {
  echo ""
  echo "=== WSC-02: default mode is dry-run ==="

  local content
  content="$(cat "${WORKFLOW_FILE}")"

  # Look for the mode input default: dry-run
  assert_contains "WSC-02: mode default is dry-run" "${content}" "default: dry-run"

  # The mode options should include dry-run and accept-only
  assert_contains "WSC-02: mode has dry-run option" "${content}" "- dry-run"
  assert_contains "WSC-02: mode has accept-only option" "${content}" "- accept-only"
}

# ============================================================================
# WSC-03: No approved-submit reference
# ============================================================================

test_no_approved_submit() {
  echo ""
  echo "=== WSC-03: no approved-submit reference ==="

  local content
  content="$(cat "${WORKFLOW_FILE}")"

  assert_not_contains "WSC-03: no approved-submit" "${content}" "approved-submit"
}

# ============================================================================
# WSC-04: implement-for-review not an allowed input option
# ============================================================================

test_no_implement_for_review() {
  echo ""
  echo "=== WSC-04: implement-for-review is not an allowed input option ==="

  local content
  content="$(cat "${WORKFLOW_FILE}")"

  assert_not_contains "WSC-04: no implement-for-review in mode options" "${content}" "implement-for-review"
}

# ============================================================================
# WSC-05: run_smoke defaults to true
# ============================================================================

test_run_smoke_defaults_true() {
  echo ""
  echo "=== WSC-05: run_smoke defaults to true ==="

  local content
  content="$(cat "${WORKFLOW_FILE}")"

  assert_contains "WSC-05: run_smoke input exists" "${content}" "run_smoke"
  assert_contains "WSC-05: run_smoke defaults to true" "${content}" "default: true"
}

# ============================================================================
# WSC-06: skip-worker-invoke is always used
# ============================================================================

test_skip_worker_invoke_used() {
  echo ""
  echo "=== WSC-06: skip-worker-invoke is always used ==="

  local content
  content="$(cat "${WORKFLOW_FILE}")"

  # The workflow should always pass --skip-worker-invoke
  assert_contains "WSC-06: skip-worker-invoke in args" "${content}" "--skip-worker-invoke"
}

# ============================================================================
# WSC-07: py_compile passes on auto-task-assignment.py
# ============================================================================

test_py_compile() {
  echo ""
  echo "=== WSC-07: py_compile passes on auto-task-assignment.py ==="

  local pycache_prefix="${TMPDIR:-/tmp}/pycache-ata-wf-smoke"
  mkdir -p "${pycache_prefix}"
  if PYTHONPYCACHEPREFIX="${pycache_prefix}" python3 -m py_compile "${SCRIPT_DIR}/auto-task-assignment.py" 2>&1; then
    echo "  PASS: WSC-07 py_compile OK"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  FAIL: WSC-07 py_compile failed"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES="${FAILURES}  WSC-07 py_compile\n"
  fi
  rm -rf "${pycache_prefix}"
}

# ============================================================================
# WSC-08: bash -n passes on auto-task-assignment-smoke.sh
# ============================================================================

test_bash_n_smoke() {
  echo ""
  echo "=== WSC-08: bash -n passes on auto-task-assignment-smoke.sh ==="

  if bash -n "${SCRIPT_DIR}/auto-task-assignment-smoke.sh" 2>&1; then
    echo "  PASS: WSC-08 bash -n OK"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  FAIL: WSC-08 bash -n failed"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES="${FAILURES}  WSC-08 bash -n smoke\n"
  fi
}

# ============================================================================
# WSC-09: bash -n passes on this script (self check)
# ============================================================================

test_bash_n_self() {
  echo ""
  echo "=== WSC-09: bash -n passes on workflow smoke script ==="

  if bash -n "${BASH_SOURCE[0]}" 2>&1; then
    echo "  PASS: WSC-09 bash -n OK"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  FAIL: WSC-09 bash -n failed"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES="${FAILURES}  WSC-09 bash -n self\n"
  fi
}

# ============================================================================
# Main
# ============================================================================

echo ""
echo "================================================================"
echo " Auto Task Assignment — Workflow Smoke Tests"
echo "================================================================"
echo ""

test_workflow_exists_and_dispatch_only
test_default_mode_is_dry_run
test_no_approved_submit
test_no_implement_for_review
test_run_smoke_defaults_true
test_skip_worker_invoke_used
test_py_compile
test_bash_n_smoke
test_bash_n_self

echo ""
echo "================================================================"
echo " RESULTS"
echo "================================================================"
echo " Passed: ${PASS_COUNT}"
echo " Failed: ${FAIL_COUNT}"
if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  echo ""
  echo " FAILURES:"
  printf '%b' "${FAILURES}"
fi
echo "================================================================"

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  exit 1
fi
exit 0
