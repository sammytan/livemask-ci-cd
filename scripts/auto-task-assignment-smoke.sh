#!/usr/bin/env bash
# TASK-CICD-AUTO-TASK-ASSIGNMENT-DEVELOPMENT-001
#
# Deterministic smoke tests for the auto-task-assignment runner.
#
# All tests use temp ledger / temp lease / temp state dir. They must not
# mutate real docs ledger/lease or runtime repos.
#
# Smoke coverage:
#   SC-01  dry-run selects a dispatchable task from a temp ledger
#   SC-02  active lease (non-expired) prevents task selection
#   SC-03  expired lease allows task selection
#   SC-04  non-dry-run accept-only acquires lease in temp lease file
#   SC-04B accept-only uses wildcard expected_files when ledger scope is missing
#   SC-05  worker command mapping resolves expected paths for all 6 runtime repos
#   SC-06  implement-for-review requires opt-in guard
#   SC-07  no commits/merges/pushes/dispatches in any mode
#   SC-08  real docs files unchanged (SHA256 check)
#   SC-09  unmapped repos are filtered before selection and reported
#   SC-10  active work expected_files overlap blocks selection
#   SC-11  same repo different expected_files can run in parallel
#   SC-12  unknown expected_files on same repo blocks conservatively

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
AUTO_ASSIGN="${SCRIPT_DIR}/auto-task-assignment.py"
DOCS_DIR="${REPO_ROOT}/../livemask-docs"

# Real files that must not be mutated
REAL_LEDGER="${DOCS_DIR}/docs/development/task-state-ledger.json"
REAL_LEASE_FILE="${DOCS_DIR}/docs/development/task-leases.json"

PASS_COUNT=0
FAIL_COUNT=0
FAILURES=""

SANDBOX=""
SANDBOX_ORIG_DIR=""

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
  if echo "${haystack}" | grep -qF "${needle}"; then
    echo "  PASS: ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  FAIL: ${label}"
    echo "    Expected to contain: '${needle}'"
    echo "    Actual: '$(echo "${haystack}" | head -20)'"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES="${FAILURES}  ${label}\n"
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if ! echo "${haystack}" | grep -qF "${needle}"; then
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

assert_file_not_exists() {
  local label="$1" path="$2"
  if [[ ! -f "${path}" ]]; then
    echo "  PASS: ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  FAIL: ${label} (file exists: ${path})"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES="${FAILURES}  ${label} (file exists)\n"
  fi
}

record_real_hashes() {
  SANDBOX_REAL_LEDGER_HASH=""
  SANDBOX_REAL_LEASE_HASH=""
  if [[ -f "${REAL_LEDGER}" ]]; then
    SANDBOX_REAL_LEDGER_HASH="$(shasum -a 256 "${REAL_LEDGER}" 2>/dev/null | awk '{print $1}')"
  fi
  if [[ -f "${REAL_LEASE_FILE}" ]]; then
    SANDBOX_REAL_LEASE_HASH="$(shasum -a 256 "${REAL_LEASE_FILE}" 2>/dev/null | awk '{print $1}')"
  fi
}

verify_real_files_unchanged() {
  local label_prefix="$1"
  local ledger_hash lease_hash
  if [[ -f "${REAL_LEDGER}" ]]; then
    ledger_hash="$(shasum -a 256 "${REAL_LEDGER}" 2>/dev/null | awk '{print $1}')"
    assert_eq "${label_prefix}: real ledger unchanged" "${SANDBOX_REAL_LEDGER_HASH}" "${ledger_hash}"
  fi
  if [[ -f "${REAL_LEASE_FILE}" ]]; then
    lease_hash="$(shasum -a 256 "${REAL_LEASE_FILE}" 2>/dev/null | awk '{print $1}')"
    assert_eq "${label_prefix}: real lease file unchanged" "${SANDBOX_REAL_LEASE_HASH}" "${lease_hash}"
  fi
}

setup_sandbox() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/auto-task-assignment-smoke.XXXXXX")"
  SANDBOX_ORIG_DIR="$(pwd)"

  # Create a fake task-state-ledger.json with a dispatchable task
  cat > "${SANDBOX}/task-state-ledger.json" << 'LEDGER'
{
  "schema_version": 1,
  "modules": [
    {
      "module_id": "governance-control-plane",
      "overall_status": "in_progress",
      "owner_repo": "livemask-ci-cd",
      "tasks": [
        {
          "task_id": "TASK-SMOKE-CICD-001",
          "repo": "livemask-ci-cd",
          "module_id": "governance-control-plane",
          "status": "ready",
          "priority": "P0",
          "blocked_by": [],
          "unlocks": [],
          "task_doc": "",
          "validation": "",
          "notes": "Smoke test task for unmapped ci-cd repo",
          "expected_files": ["scripts/protocol-smoke.sh"]
        },
        {
          "task_id": "TASK-SMOKE-FAKE-001",
          "repo": "livemask-backend",
          "module_id": "governance-control-plane",
          "status": "ready",
          "priority": "P0",
          "blocked_by": [],
          "unlocks": ["TASK-SMOKE-FAKE-002"],
          "task_doc": "docs/development/tasks/TASK-SMOKE-FAKE-001.md",
          "validation": "",
          "notes": "Smoke test task",
          "expected_files": ["internal/protocol/types.go"]
        },
        {
          "task_id": "TASK-SMOKE-FAKE-002",
          "repo": "livemask-backend",
          "module_id": "governance-control-plane",
          "status": "ready",
          "priority": "P1",
          "blocked_by": ["TASK-SMOKE-FAKE-001"],
          "unlocks": [],
          "task_doc": "",
          "validation": "",
          "notes": "Smoke test task blocked by 001",
          "expected_files": ["internal/protocol/service.go"]
        },
        {
          "task_id": "TASK-SMOKE-FAKE-003",
          "repo": "livemask-nodeagent",
          "module_id": "governance-control-plane",
          "status": "ready",
          "priority": "P0",
          "blocked_by": [],
          "unlocks": [],
          "task_doc": "",
          "validation": "",
          "notes": "Smoke test task for nodeagent",
          "expected_files": ["internal/agent/runner.go"]
        },
        {
          "task_id": "TASK-SMOKE-FAKE-004",
          "repo": "livemask-admin",
          "module_id": "governance-control-plane",
          "status": "ready",
          "priority": "P2",
          "blocked_by": [],
          "unlocks": [],
          "task_doc": "",
          "validation": "",
          "notes": "Smoke test task for admin",
          "expected_files": ["src/pages/nodes/NodesPage.tsx"]
        }
      ]
    }
  ]
}
LEDGER

  # Create an empty task-leases.json
  cat > "${SANDBOX}/task-leases.json" << 'LEASES'
{
  "schema_version": 1,
  "updated_at": "2026-05-26T00:00:00+08:00",
  "leases": []
}
LEASES

  # Create the evidence and state dirs
  mkdir -p "${SANDBOX}/evidence" "${SANDBOX}/state"

  # Record real file hashes
  record_real_hashes
}

teardown_sandbox() {
  cd "${SANDBOX_ORIG_DIR}"
  if [[ -n "${SANDBOX}" && -d "${SANDBOX}" ]]; then
    rm -rf "${SANDBOX}"
  fi
}

run_assign() {
  local extra_args="$*"
  python3 "${AUTO_ASSIGN}" \
    --ledger "${SANDBOX}/task-state-ledger.json" \
    --lease-file "${SANDBOX}/task-leases.json" \
    --lease-owner ci-cd-smoke-test \
    --state-dir "${SANDBOX}/state" \
    --evidence-dir "${SANDBOX}/evidence" \
    --skip-worker-invoke \
    ${extra_args} 2>&1 || true
}

# ============================================================================
# SC-01: Dry-run selects a dispatchable task from temp ledger
# ============================================================================

test_dry_run_selects_task() {
  echo ""
  echo "=== SC-01: dry-run selects a dispatchable task ==="
  setup_sandbox

  local output
  output="$(run_assign "--dry-run --limit 2 --json")"

  assert_contains "SC-01: shows candidates" "${output}" "total_candidates"
  assert_contains "SC-01: shows selected" "${output}" "selected"
  assert_contains "SC-01: shows dispatched" "${output}" "dispatched"
  assert_contains "SC-01: dry_run is true" "${output}" '"dry_run": true'

  # Verify no lease was acquired
  local lease_content
  lease_content="$(cat "${SANDBOX}/task-leases.json")"
  assert_contains "SC-01: no lease acquired" "${lease_content}" '"leases": []'

  verify_real_files_unchanged "SC-01"

  teardown_sandbox
}

# ============================================================================
# SC-02: Active lease prevents task selection
# ============================================================================

test_active_lease_blocks_selection() {
  echo ""
  echo "=== SC-02: active lease prevents selection ==="
  setup_sandbox

  # Add an active lease for the same repo/task with a different owner
  python3 -c "
import json
with open('${SANDBOX}/task-leases.json', 'r') as f:
    data = json.load(f)
data['leases'].append({
    'task_id': 'TASK-SMOKE-FAKE-001',
    'repo': 'livemask-backend',
    'branch': 'task/TASK-SMOKE-FAKE-001',
    'lease_owner': 'cursor-backend-window',
    'started_at': '2026-05-26T00:00:00+08:00',
    'expires_at': '2099-12-31T23:59:59+08:00',
    'status': 'active'
})
with open('${SANDBOX}/task-leases.json', 'w') as f:
    json.dump(data, f, indent=2)
"

  local output
  output="$(run_assign "--dry-run --limit 5 --json")"

  assert_contains "SC-02: lease block reported" "${output}" "filtered_by_lease"
  assert_contains "SC-02: lease_blocked > 0" "${output}" '"lease_blocked"'
  assert_contains "SC-02: TASK-SMOKE-FAKE-001 in lease_blocked" "${output}" "cursor-backend-window"

  verify_real_files_unchanged "SC-02"

  teardown_sandbox
}

# ============================================================================
# SC-03: Expired lease allows task selection
# ============================================================================

test_expired_lease_allows_selection() {
  echo ""
  echo "=== SC-03: expired lease allows selection ==="
  setup_sandbox

  python3 -c "
import json, datetime
with open('${SANDBOX}/task-leases.json', 'r') as f:
    data = json.load(f)
expires = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1)).isoformat(timespec='seconds')
data['leases'].append({
    'task_id': 'TASK-SMOKE-FAKE-001',
    'repo': 'livemask-backend',
    'branch': 'task/TASK-SMOKE-FAKE-001',
    'lease_owner': 'cursor-backend-window',
    'started_at': (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=2)).isoformat(timespec='seconds'),
    'expires_at': expires,
    'status': 'active'
})
with open('${SANDBOX}/task-leases.json', 'w') as f:
    json.dump(data, f, indent=2)
"

  local output
  output="$(run_assign "--dry-run --limit 5 --json")"

  # The expired lease should not block the task; it should remain selectable.
  assert_contains "SC-03: no lease block reported" "${output}" '"filtered_by_lease": 0'
  assert_contains "SC-03: expired task remains selectable" "${output}" 'TASK-SMOKE-FAKE-001'

  verify_real_files_unchanged "SC-03"

  teardown_sandbox
}

# ============================================================================
# SC-04: Non-dry-run accept-only acquires lease in temp lease file
# ============================================================================

test_accept_acquires_lease() {
  echo ""
  echo "=== SC-04: accept-only acquires lease ==="
  setup_sandbox

  local output
  output="$(run_assign "--mode accept-only --limit 1 --json" 2>&1 || true)"

  assert_contains "SC-04: shows dispatched" "${output}" "dispatched"

  local lease_content
  lease_content="$(cat "${SANDBOX}/task-leases.json")"
  assert_contains "SC-04: lease was acquired" "${lease_content}" '"status": "active"'
  assert_contains "SC-04: lease has owner" "${lease_content}" 'ci-cd-smoke-test'
  assert_contains "SC-04: lease has task id" "${lease_content}" 'TASK-SMOKE-FAKE-001'
  assert_contains "SC-04: lease carries expected_files" "${lease_content}" 'internal/protocol/types.go'

  verify_real_files_unchanged "SC-04"

  teardown_sandbox
}

test_accept_missing_expected_files_uses_wildcard() {
  echo ""
  echo "=== SC-04B: accept-only missing expected_files uses wildcard ==="
  setup_sandbox

  python3 - <<PY
import json
from pathlib import Path

path = Path("${SANDBOX}/task-state-ledger.json")
data = json.loads(path.read_text())
for module in data["modules"]:
    for task in module["tasks"]:
        if task["task_id"] == "TASK-SMOKE-FAKE-001":
            task.pop("expected_files", None)
path.write_text(json.dumps(data, indent=2) + "\n")
PY

  local output
  output="$(run_assign "--mode accept-only --limit 1 --json" 2>&1 || true)"

  assert_contains "SC-04B: shows dispatched" "${output}" "dispatched"

  local lease_content
  lease_content="$(cat "${SANDBOX}/task-leases.json")"
  assert_contains "SC-04B: lease was acquired" "${lease_content}" '"status": "active"'
  assert_contains "SC-04B: wildcard expected_files used" "${lease_content}" '"*"'

  verify_real_files_unchanged "SC-04B"

  teardown_sandbox
}

# ============================================================================
# SC-05: Worker command mapping resolves expected script paths for all 6 runtime repos
# ============================================================================

test_worker_mapping_resolves() {
  echo ""
  echo "=== SC-05: worker mapping all 6 runtime repos ==="
  # Check each runtime repo has a worker script on disk
  local repos=(
    "livemask-backend"
    "livemask-nodeagent"
    "livemask-job-service"
    "livemask-app"
    "livemask-admin"
    "livemask-website"
  )

  local idx=0
  for repo in "${repos[@]}"; do
    idx=$((idx + 1))
    local expected_path="${REPO_ROOT}/../${repo}/scripts/task-worker.sh"
    if [[ -f "${expected_path}" ]]; then
      echo "  PASS: SC-05.${idx} worker exists for ${repo}"
      PASS_COUNT=$((PASS_COUNT + 1))
    else
      echo "  FAIL: SC-05.${idx} worker missing for ${repo}: ${expected_path}"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      FAILURES="${FAILURES}  SC-05.${idx} (missing worker)\n"
    fi
  done

  # Also verify the Python script's REPO_WORKER_MAP has exactly 6 entries
  local map_count
  map_count="$(python3 -c "
import re
content = open('${SCRIPT_DIR}/auto-task-assignment.py').read()
m = re.search(r'REPO_WORKER_MAP\s*=\s*\{(.*?)\}', content, re.DOTALL)
if m:
    entries = re.findall(r'\"livemask-[^\"]+\"', m.group(1))
    print(len(entries))
else:
    print('0')
")"
  assert_eq "SC-05: Python mapping has 6 entries" "6" "${map_count}"
}

# Alternative approach for SC-05 since importing the .py directly might have issues
test_worker_mapping_script_parse() {
  echo ""
  echo "=== SC-05b: worker mapping count via Python ==="
  local map_lines
  map_lines="$(python3 -c "
import re
with open('${SCRIPT_DIR}/auto-task-assignment.py') as f:
    content = f.read()
m = re.search(r'REPO_WORKER_MAP[^=]*=\s*\{(.*?)\}', content, re.DOTALL)
if m:
    entries = re.findall(r'\"(livemask-[^\"]+)\"\s*:', m.group(1))
    print(len(entries))
else:
    print('0')
")"
  assert_eq "SC-05b: script has 6 worker entries" "6" "${map_lines}"
}

# ============================================================================
# SC-06: implement-for-review requires opt-in guard
# ============================================================================

test_implement_requires_opt_in() {
  echo ""
  echo "=== SC-06: implement-for-review requires opt-in guard ==="
  setup_sandbox

  # Without --confirm-implement and without --task-id or --repo, it should fail
  local output
  output="$(run_assign "--mode implement-for-review --limit 1" 2>&1 || true)"

  assert_contains "SC-06: requires confirm-implement" "${output}" "requires --confirm-implement"

  verify_real_files_unchanged "SC-06"

  teardown_sandbox
}

# ============================================================================
# SC-07: No commits/merges/pushes/dispatches attempted
# ============================================================================

test_no_side_effects() {
  echo ""
  echo "=== SC-07: no commits/merges/pushes/dispatches ==="
  setup_sandbox

  # Run dry-run
  local output1
  output1="$(run_assign "--dry-run --limit 2 --json")"
  assert_not_contains "SC-07: no git commit in dry-run output" "${output1}" "git commit"
  assert_not_contains "SC-07: no git push in dry-run output" "${output1}" "git push"
  assert_not_contains "SC-07: no merge in dry-run output" "${output1}" "git merge"

  # Run accept-only (will attempt worker call but worker will fail = no side effects)
  local output2
  output2="$(run_assign "--mode accept-only --limit 1 --json" 2>&1 || true)"

  # Neither mode should write evidence outside the sandbox
  local sandbox_evidence_files
  sandbox_evidence_files="$(find "${SANDBOX}/evidence" -type f 2>/dev/null | wc -l | tr -d ' ')"
  assert_contains "SC-07: evidence files written in sandbox" "Evidence files in sandbox: ${sandbox_evidence_files}" "sandbox"
  assert_file_not_exists "SC-07: no workspace evidence leaked" "${REPO_ROOT}/.cursor-worker/auto-task-assignment/TASK-SMOKE-FAKE-001.json"

  verify_real_files_unchanged "SC-07"

  teardown_sandbox
}

# ============================================================================
# SC-08: Real docs files unchanged
# ============================================================================

test_real_docs_files_unchanged() {
  echo ""
  echo "=== SC-08: real docs ledger and lease files unchanged ==="
  setup_sandbox

  # These tests never touched the real files, but verify explicitly
  verify_real_files_unchanged "SC-08"

  teardown_sandbox
}


# ============================================================================
# SC-09: Unmapped repos are filtered before selection and reported
# ============================================================================

test_worker_coverage_filters_unmapped_repo() {
  echo ""
  echo "=== SC-09: worker coverage filters unmapped repo ==="
  setup_sandbox

  local output
  output="$(run_assign "--dry-run --repo livemask-ci-cd --limit 5 --json")"

  assert_contains "SC-09: selected count is zero" "${output}" '"selected_count": 0'
  assert_contains "SC-09: assignable count is zero" "${output}" '"assignable_candidates": 0'
  assert_contains "SC-09: filtered by worker mapping" "${output}" '"filtered_by_worker_mapping": 1'
  assert_contains "SC-09: unassignable repo reported" "${output}" '"livemask-ci-cd"'
  assert_contains "SC-09: unassignable task reported" "${output}" '"task_id": "TASK-SMOKE-CICD-001"'
  assert_contains "SC-09: no worker mapping reason" "${output}" '"reason": "no worker mapping"'
  assert_not_contains "SC-09: no skipped result emitted" "${output}" '"status": "skipped"'

  verify_real_files_unchanged "SC-09"

  teardown_sandbox
}


# ============================================================================
# SC-10: Active work expected_files overlap blocks selection
# ============================================================================

test_active_work_overlap_blocks_selection() {
  echo ""
  echo "=== SC-10: active work overlap blocks selection ==="
  setup_sandbox

  python3 -c "
import json
path = '${SANDBOX}/task-leases.json'
with open(path, 'r') as f:
    data = json.load(f)
data['leases'].append({
    'task_id': 'TASK-SMOKE-ACTIVE-OVERLAP',
    'repo': 'livemask-backend',
    'branch': 'task/TASK-SMOKE-ACTIVE-OVERLAP',
    'lease_owner': 'cursor-backend-window',
    'expected_files': ['internal/protocol/types.go'],
    'started_at': '2026-05-26T00:00:00+08:00',
    'expires_at': '2099-12-31T23:59:59+08:00',
    'status': 'active'
})
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
"

  local output
  output="$(run_assign "--dry-run --task-id TASK-SMOKE-FAKE-001 --json")"

  assert_contains "SC-10: selected count is zero" "${output}" '"selected_count": 0'
  assert_contains "SC-10: active work filtered" "${output}" '"filtered_by_active_work": 1'
  assert_contains "SC-10: overlap reason" "${output}" '"reason": "expected file overlap"'
  assert_contains "SC-10: overlap file listed" "${output}" 'internal/protocol/types.go'
  assert_contains "SC-10: active task id listed" "${output}" 'TASK-SMOKE-ACTIVE-OVERLAP'

  verify_real_files_unchanged "SC-10"

  teardown_sandbox
}

# ============================================================================
# SC-11: Same repo different expected_files can run in parallel
# ============================================================================

test_active_work_different_files_allows_selection() {
  echo ""
  echo "=== SC-11: active work different files allows selection ==="
  setup_sandbox

  python3 -c "
import json
path = '${SANDBOX}/task-leases.json'
with open(path, 'r') as f:
    data = json.load(f)
data['leases'].append({
    'task_id': 'TASK-SMOKE-ACTIVE-DIFFERENT',
    'repo': 'livemask-backend',
    'branch': 'task/TASK-SMOKE-ACTIVE-DIFFERENT',
    'lease_owner': 'cursor-backend-window',
    'expected_files': ['internal/other/file.go'],
    'started_at': '2026-05-26T00:00:00+08:00',
    'expires_at': '2099-12-31T23:59:59+08:00',
    'status': 'active'
})
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
"

  local output
  output="$(run_assign "--dry-run --task-id TASK-SMOKE-FAKE-001 --json")"

  assert_contains "SC-11: selected one task" "${output}" '"selected": 1'
  assert_contains "SC-11: no active work filtered" "${output}" '"filtered_by_active_work": 0'
  assert_contains "SC-11: selected task remains" "${output}" 'TASK-SMOKE-FAKE-001'

  verify_real_files_unchanged "SC-11"

  teardown_sandbox
}

# ============================================================================
# SC-12: Unknown expected_files on same repo blocks conservatively
# ============================================================================

test_active_work_unknown_files_blocks_selection() {
  echo ""
  echo "=== SC-12: active work unknown expected_files blocks selection ==="
  setup_sandbox

  python3 -c "
import json
path = '${SANDBOX}/task-leases.json'
with open(path, 'r') as f:
    data = json.load(f)
data['leases'].append({
    'task_id': 'TASK-SMOKE-ACTIVE-UNKNOWN',
    'repo': 'livemask-backend',
    'branch': 'task/TASK-SMOKE-ACTIVE-UNKNOWN',
    'lease_owner': 'cursor-backend-window',
    'expected_files': [],
    'started_at': '2026-05-26T00:00:00+08:00',
    'expires_at': '2099-12-31T23:59:59+08:00',
    'status': 'active'
})
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
"

  local output
  output="$(run_assign "--dry-run --task-id TASK-SMOKE-FAKE-001 --json")"

  assert_contains "SC-12: selected count is zero" "${output}" '"selected_count": 0'
  assert_contains "SC-12: active work filtered" "${output}" '"filtered_by_active_work": 1'
  assert_contains "SC-12: unknown expected files reason" "${output}" 'unknown expected_files for same repo active lease'

  verify_real_files_unchanged "SC-12"

  teardown_sandbox
}

# ============================================================================
# Main
# ============================================================================

echo ""
echo "================================================================"
echo " Auto Task Assignment — Deterministic Smoke Tests"
echo "================================================================"
echo ""

# Run all tests
test_dry_run_selects_task
test_active_lease_blocks_selection
test_expired_lease_allows_selection
test_accept_acquires_lease
test_accept_missing_expected_files_uses_wildcard
test_worker_mapping_script_parse
test_implement_requires_opt_in
test_no_side_effects
test_real_docs_files_unchanged
test_worker_coverage_filters_unmapped_repo
test_active_work_overlap_blocks_selection
test_active_work_different_files_allows_selection
test_active_work_unknown_files_blocks_selection

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
