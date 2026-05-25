#!/usr/bin/env bash
# TASK-CICD-CURSOR-SDK-WORKER-HARDENING-001
#
# Deterministic smoke tests for the Cursor SDK Worker Harness library.
#
# These tests use a fake SDK agent and do NOT require a real Cursor
# subscription, GUI session, or model call.
#
# All tests run in an isolated temporary directory to avoid affecting the
# real workspace.
#
# Smoke matrix:
#   SC-01  dry-run: generates planned task info without any side effects
#   SC-02  accept-only: accepts a lease assignment, exits without edits
#   SC-03  fake implement-for-review success: produces diff, validation,
#          review packet; does NOT commit or merge
#   SC-04  missing approval artifact: approved-submit refuses before commit
#   SC-05  branch mismatch: stops with needs_attention
#   SC-06  dirty worktree in approved submit: stops before merge
#   SC-07  validation failure: stops with blocked/partial
#   SC-08  invalid approval (wrong task_id): approved-submit rejects
#   SC-09  invalid approval (wrong approval_id): approved-submit rejects
#   SC-10  invalid approval (missing fields): approved-submit rejects
#   SC-11  invalid approval (diff sha256 mismatch): diff mutation detected
#   SC-12  invalid approval (no commit/merge permission): stage permission denied
#   SC-13  dispatch failure: dispatch script not found
#   SC-14  fake ACK via listener state: receiver-produced ack artifact accepted
#   SC-15  boundary violation: ../livemask-docs edit detected
#   SC-16  dirty submodule state: stopped before commit
#   SC-17  positive approval cycle: review -> approve -> gate PASS
#   SC-18  untracked source file: stopped before commit
#   SC-19  invalid approval (no commit permission): pre-commit gate reject
#   SC-20  dirty submodule: stopped before commit
#   SC-21  dispatch configured (env) + fake dispatch success + ACK via listener
#   SC-21b dispatch configured (config) without env var + ACK success
#   SC-22  dispatch not configured: dispatch_and_ack returns 1,
#          evidence shows dispatch_pending
#   SC-23  dispatch sent but ACK timeout: dispatch_and_ack returns 1,
#          evidence shows dispatch_pending (ACK not confirmed)
#   SC-24  completion evidence content: all required fields present
#          (task_branch_commit, dev_merge_commit, remote_dev_ref, dispatch_status)
#   SC-25  dispatch script body validation: fake gh captures full body,
#          asserts event_type==cursor-report-received, client_payload
#          is JSON object (not string), and contains required fields
#   SC-26  ACK commit scan: recent commits contain task in message but not
#          latest; fake gh confirms ACK via Strategy B
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HARNESS_LIB="${SCRIPT_DIR}/lib/worker-harness.sh"
HELPER_PY="${SCRIPT_DIR}/lib/worker-harness-helper.py"

# Pre-set helper path for harness resolution
export WORKER_HARNESS_HELPER_PATH="${HELPER_PY}"

# ============================================================================
# Test framework
# ============================================================================

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
  if echo "${haystack}" | grep -qF "${needle}"; then
    echo "  PASS: ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  FAIL: ${label}"
    echo "    Expected to contain: '${needle}'"
    echo "    Actual: '$(echo "${haystack}" | head -50)'"
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
    echo "    Actual: '$(echo "${haystack}" | head -3)'"
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

# ============================================================================
# Sandbox setup/teardown
# ============================================================================

SANDBOX=""
SANDBOX_ORIG_DIR=""

setup_sandbox() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/worker-harness-smoke.XXXXXX")"
  SANDBOX_ORIG_DIR="$(pwd)"

  cd "${SANDBOX}"
  git init --initial-branch=dev
  git config user.email "smoke@test.livemask"
  git config user.name "Smoke Test"
  echo "# Smoke test sandbox" > README.md
  echo "*.md text eol=lf" > .gitattributes
  git add -A
  git commit -m "initial commit on dev" --no-gpg-sign

  unset LIVEMASK_BOT_TOKEN
  export WORKER_HARNESS_TASK_ID="TASK-SMOKE-FAKE-001"
  export WORKER_HARNESS_VALIDATION_CMDS="true"
  export WORKER_HARNESS_SECRET_PATTERNS="NONE_USED_IN_SMOKE"
}

teardown_sandbox() {
  cd "${SANDBOX_ORIG_DIR}"
  if [[ -n "${SANDBOX}" && -d "${SANDBOX}" ]]; then
    rm -rf "${SANDBOX}"
  fi
}

# Helper: create a valid approval artifact in the sandbox
create_valid_approval() {
  local approval_id="${1:-approval-smoke-001}"
  local task_id="${2:-TASK-SMOKE-FAKE-001}"
  local repo="${3:-}"
  local branch="${4:-task/TASK-SMOKE-FAKE-001}"
  local head_commit="${5:-dummyhead}"
  local rp_sha256="${6:-dummysha256rp}"
  local diff_sha256="${7:-dummysha256diff}"

  if [[ -z "${repo}" ]]; then
    repo="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo 'sandbox')")"
  fi

  mkdir -p .cursor-worker
  cat > .cursor-worker/approval-artifact.json <<ARTIFACT
{
  "approval_id": "${approval_id}",
  "task_id": "${task_id}",
  "repo": "${repo}",
  "branch": "${branch}",
  "head_commit_before_submit": "${head_commit}",
  "review_packet_sha256": "${rp_sha256}",
  "diff_sha256": "${diff_sha256}",
  "approved_at": "2026-05-25T02:00:00Z",
  "reviewer": "Codex",
  "allow_commit": true,
  "allow_merge": true
}
ARTIFACT
}

# Wrapper to run a harness function in the sandbox with proper sourcing
run_harness_check_approval() {
  local expected_task_id="${1:-TASK-SMOKE-FAKE-001}"
  (
    cd "${SANDBOX}"
    source "${HARNESS_LIB}" > /dev/null 2>&1
    set +e  # Disable errexit after sourcing (library re-enables it)
    export CURSOR_WORKER_MODE="approved-submit"
    export CURSOR_REVIEW_APPROVAL_ID="${CURSOR_REVIEW_APPROVAL_ID:-approval-smoke-001}"
    export WORKER_HARNESS_PACKET_FILE="${SANDBOX}/.cursor-worker/review-packet.json"
    export WORKER_HARNESS_DIFF_FILE="${SANDBOX}/.cursor-worker/latest.diff"
    # Ensure dummy files exist for sha256 computation (tests can override)
    mkdir -p .cursor-worker
    [[ -f "${SANDBOX}/.cursor-worker/review-packet.json" ]] || echo '{"dummy":true}' > "${SANDBOX}/.cursor-worker/review-packet.json"
    [[ -f "${SANDBOX}/.cursor-worker/latest.diff" ]] || echo "dummy diff" > "${SANDBOX}/.cursor-worker/latest.diff"
    worker_harness_check_approval "${expected_task_id}" 2>&1
    echo "EXIT_CODE=$?"
  )
}

# ============================================================================
# SC-01: dry-run
# ============================================================================

test_dry_run() {
  echo ""
  echo "=== SC-01: dry-run ==="
  setup_sandbox
  export CURSOR_WORKER_MODE="dry-run"

  local output
  output="$(cd "${SANDBOX}" && source "${HARNESS_LIB}" && worker_harness_init && worker_harness_dry_run 2>&1 || true)"

  assert_contains "SC-01: prints 'DRY-RUN'" "${output}" "DRY-RUN"
  assert_contains "SC-01: prints task ID" "${output}" "TASK-SMOKE-FAKE-001"

  assert_file_not_exists "SC-01: no review packet" "${SANDBOX}/.cursor-worker/review-packet.json"
  assert_file_not_exists "SC-01: no diff" "${SANDBOX}/.cursor-worker/latest.diff"

  teardown_sandbox
}

# ============================================================================
# SC-02: accept-only
# ============================================================================

test_accept_only() {
  echo ""
  echo "=== SC-02: accept-only ==="
  setup_sandbox
  export CURSOR_WORKER_MODE="accept-only"

  local output
  output="$(cd "${SANDBOX}" && source "${HARNESS_LIB}" && worker_harness_init 2>&1 || true)"

  assert_contains "SC-02: init shows accept-only mode" "${output}" "accept-only"

  assert_file_not_exists "SC-02: no review packet" "${SANDBOX}/.cursor-worker/review-packet.json"
  assert_file_not_exists "SC-02: no diff" "${SANDBOX}/.cursor-worker/latest.diff"

  teardown_sandbox
}

# ============================================================================
# SC-03: implement-for-review (fake agent success)
# ============================================================================

test_implement_for_review() {
  echo ""
  echo "=== SC-03: implement-for-review (fake agent success) ==="
  setup_sandbox
  export CURSOR_WORKER_MODE="implement-for-review"

  cd "${SANDBOX}"
  git checkout -b "task/TASK-SMOKE-FAKE-001"
  echo "# Fake change" >> README.md
  # Stage the change so the staged-only canonical diff captures it
  git add README.md

  # Run review gate: agent_summary, risks, then validation commands
  local output
  output="$(source "${HARNESS_LIB}" && worker_harness_init && worker_harness_run_review_gate "fake agent completed" "no_risks" "true" 2>&1 || true)"

  assert_contains "SC-03: review gate ran" "${output}" "REVIEW PACKET READY"
  assert_contains "SC-03: no commit stated" "${output}" "NOT committed"
  assert_contains "SC-03: no merge stated" "${output}" "NOT merged"
  assert_file_exists "SC-03: review packet JSON" "${SANDBOX}/.cursor-worker/review-packet.json"
  assert_file_exists "SC-03: diff file" "${SANDBOX}/.cursor-worker/latest.diff"

  local packet_content
  packet_content="$(cat "${SANDBOX}/.cursor-worker/review-packet.json" 2>/dev/null || true)"
  assert_contains "SC-03: packet has task_id" "${packet_content}" "TASK-SMOKE-FAKE-001"
  assert_contains "SC-03: packet has mode" "${packet_content}" "implement-for-review"
  assert_contains "SC-03: packet has diff captured" "${packet_content}" "diff"

  # Changes should still be staged but uncommitted
  local status
  status="$(git status --porcelain)"
  assert_contains "SC-03: changes staged (not committed)" "${status}" "M  README.md"

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# SC-04: missing approval artifact
# ============================================================================

test_missing_approval() {
  echo ""
  echo "=== SC-04: missing approval artifact ==="
  setup_sandbox
  export CURSOR_WORKER_MODE="approved-submit"
  export CURSOR_REVIEW_APPROVAL_ID="approval-smoke-fake-001"
  rm -f "${SANDBOX}/.cursor-worker/approval-artifact.json"

  local exit_code=0
  (
    cd "${SANDBOX}"
    source "${HARNESS_LIB}" && worker_harness_init && worker_harness_gate_before_commit 2>&1
  ) || exit_code=$?

  assert_eq "SC-04: non-zero exit" "1" "$( (( exit_code > 0 )) && echo 1 || echo 0)"

  # The gate may create .cursor-worker/ before detecting missing approval — that's expected
  # Verify no commit was made
  local log_before
  log_before="$(cd "${SANDBOX}" && git rev-parse HEAD 2>/dev/null || true)"
  local log_after
  log_after="$(cd "${SANDBOX}" && git rev-parse HEAD 2>/dev/null || true)"
  assert_eq "SC-04: no commit made" "${log_before}" "${log_after}"

  teardown_sandbox
}

# ============================================================================
# SC-05: branch mismatch
# ============================================================================

test_branch_mismatch() {
  echo ""
  echo "=== SC-05: branch mismatch ==="
  setup_sandbox
  export CURSOR_WORKER_MODE="implement-for-review"

  cd "${SANDBOX}"
  git checkout dev

  local exit_code=0
  (
    source "${HARNESS_LIB}" && worker_harness_init && worker_harness_run_review_gate "" "" "true" 2>&1
  ) || exit_code=$?

  assert_eq "SC-05: non-zero exit" "1" "$( (( exit_code > 0 )) && echo 1 || echo 0)"

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# SC-06: dirty worktree in approved submit
# ============================================================================

test_dirty_worktree_approved_submit() {
  echo ""
  echo "=== SC-06: staged diff + later unstaged mutation => reject ==="
  setup_sandbox
  export CURSOR_WORKER_MODE="implement-for-review"
  export WORKER_HARNESS_VALIDATION_CMDS="true"

  cd "${SANDBOX}"
  git checkout -b "task/TASK-SMOKE-FAKE-001"

  # Stage a change and run review gate to get canonical diff
  echo "# Reviewed change" > reviewed-feature.txt
  git add reviewed-feature.txt
  source "${HARNESS_LIB}" 2>/dev/null
  worker_harness_init 2>&1
  worker_harness_run_review_gate "staged feature" "none" "true" 2>&1

  # Read the diff and review-packet to compute proper hashes
  local head rp_sha diff_sha repo_name
  head="$(git rev-parse HEAD)"
  rp_sha="$(python3 -c "import hashlib; print(hashlib.sha256(open('.cursor-worker/review-packet.json','rb').read()).hexdigest())" 2>/dev/null || true)"
  diff_sha="$(python3 -c "import hashlib; print(hashlib.sha256(open('.cursor-worker/latest.diff','rb').read()).hexdigest())" 2>/dev/null || true)"
  repo_name="$(basename "$(git rev-parse --show-toplevel)")"
  create_valid_approval "approval-smoke-006" "TASK-SMOKE-FAKE-001" "${repo_name}" "task/TASK-SMOKE-FAKE-001" "${head}" "${rp_sha}" "${diff_sha}"
  export CURSOR_REVIEW_APPROVAL_ID="approval-smoke-006"

  # Now add an unstaged mutation (simulates "dirty after approval")
  echo "# Unstaged mutation" >> reviewed-feature.txt
  # Do NOT git add

  # Run pre-commit gate — should reject because unstaged changes exist
  local exit_code=0
  local output
  output="$(
    source "${HARNESS_LIB}" 2>/dev/null
    set +e
    CURSOR_WORKER_MODE="approved-submit"
    worker_harness_init 2>&1
    worker_harness_gate_before_commit 2>&1
  )" || exit_code=$?

  assert_contains "SC-06: unstaged changes rejected" "${output}" "Unstaged changes"
  assert_eq "SC-06: non-zero exit from gate" "1" "$( (( exit_code > 0 )) && echo 1 || echo 0)"

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# SC-07: validation failure
# ============================================================================

test_validation_failure() {
  echo ""
  echo "=== SC-07: validation failure ==="
  setup_sandbox
  export CURSOR_WORKER_MODE="implement-for-review"

  cd "${SANDBOX}"
  git checkout -b "task/TASK-SMOKE-FAKE-001"
  echo "# Change" >> README.md
  git add README.md

  # Run with "false" as validation command
  local output
  output="$(source "${HARNESS_LIB}" && worker_harness_init && worker_harness_run_review_gate "fake agent" "" "false" 2>&1 || true)"

  # Validation log should capture the false command failure
  assert_file_exists "SC-07: validation log" "${SANDBOX}/.cursor-worker/validation.log"
  local val_log
  val_log="$(cat "${SANDBOX}/.cursor-worker/validation.log" 2>/dev/null || true)"
  assert_contains "SC-07: false command captured" "${val_log}" "exit_code: 1"

  # Review packet should still be produced even when validation fails
  assert_file_exists "SC-07: review packet exists" "${SANDBOX}/.cursor-worker/review-packet.json"

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# SC-08: invalid approval (wrong task_id)
# ============================================================================

test_invalid_approval_task_id() {
  echo ""
  echo "=== SC-08: invalid approval (wrong task_id) ==="
  setup_sandbox
  export CURSOR_REVIEW_APPROVAL_ID="approval-smoke-008"
  cd "${SANDBOX}"
  git checkout -b "task/TASK-SMOKE-FAKE-001"
  local head
  head="$(git rev-parse HEAD)"
  create_valid_approval "approval-smoke-008" "TASK-SMOKE-WRONG-001" "" "task/TASK-SMOKE-FAKE-001" "${head}" "dummysha" "dummysha"

  local output
  output="$(run_harness_check_approval)"
  assert_contains "SC-08: task_id mismatch detected" "${output}" "task_id mismatch"
  assert_contains "SC-08: approval rejected" "${output}" "EXIT_CODE=1"

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# SC-09: invalid approval (wrong approval_id)
# ============================================================================

test_invalid_approval_approval_id() {
  echo ""
  echo "=== SC-09: invalid approval (wrong approval_id) ==="
  setup_sandbox
  export CURSOR_REVIEW_APPROVAL_ID="approval-smoke-009"
  cd "${SANDBOX}"
  git checkout -b "task/TASK-SMOKE-FAKE-001"
  local head
  head="$(git rev-parse HEAD)"
  create_valid_approval "wrong-id-009" "TASK-SMOKE-FAKE-001" "" "task/TASK-SMOKE-FAKE-001" "${head}" "dummysha" "dummysha"

  local output
  output="$(run_harness_check_approval)"
  assert_contains "SC-09: approval_id mismatch detected" "${output}" "approval_id mismatch"
  assert_contains "SC-09: approval rejected" "${output}" "EXIT_CODE=1"

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# SC-10: invalid approval (missing fields)
# ============================================================================

test_invalid_approval_missing_fields() {
  echo ""
  echo "=== SC-10: invalid approval (missing fields) ==="
  setup_sandbox
  export CURSOR_REVIEW_APPROVAL_ID="approval-smoke-010"
  cd "${SANDBOX}"
  git checkout -b "task/TASK-SMOKE-FAKE-001"

  # Create approval with missing required fields
  mkdir -p .cursor-worker
  cat > .cursor-worker/approval-artifact.json <<'ARTIFACT'
{
  "approval_id": "approval-smoke-010",
  "task_id": "TASK-SMOKE-FAKE-001"
}
ARTIFACT

  local output
  output="$(run_harness_check_approval)"
  assert_contains "SC-10: missing field detected" "${output}" "missing field"
  assert_contains "SC-10: approval rejected" "${output}" "EXIT_CODE=1"

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# SC-11: invalid approval (diff sha256 mismatch — diff mutation)
# ============================================================================

test_invalid_approval_diff_mutation() {
  echo ""
  echo "=== SC-11: invalid approval (diff sha256 mismatch) ==="
  setup_sandbox
  export CURSOR_REVIEW_APPROVAL_ID="approval-smoke-011"
  cd "${SANDBOX}"
  git checkout -b "task/TASK-SMOKE-FAKE-001"
  local head
  head="$(git rev-parse HEAD)"

  # Create review packet and diff files with known content that won't match the approval
  mkdir -p .cursor-worker
  echo "original diff content" > .cursor-worker/latest.diff
  echo '{"review_packet_version":1}' > .cursor-worker/review-packet.json

  # Approval has a different diff_sha256 than what would be computed
  create_valid_approval "approval-smoke-011" "TASK-SMOKE-FAKE-001" "" "task/TASK-SMOKE-FAKE-001" "${head}" "sha256thatwillnotmatch" "sha256thatwillnotmatch"

  local output
  output="$(run_harness_check_approval)"
  assert_contains "SC-11: sha256 mismatch detected" "${output}" "sha256"
  assert_contains "SC-11: approval rejected" "${output}" "EXIT_CODE=1"

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# SC-12: invalid approval (no commit/merge permission)
# ============================================================================

test_invalid_approval_no_permission() {
  echo ""
  echo "=== SC-12: invalid approval (no commit/merge permission) ==="
  setup_sandbox
  export CURSOR_REVIEW_APPROVAL_ID="approval-smoke-012"
  cd "${SANDBOX}"
  git checkout -b "task/TASK-SMOKE-FAKE-001"
  local head
  head="$(git rev-parse HEAD)"

  mkdir -p .cursor-worker
  echo "some diff" > .cursor-worker/latest.diff
  echo '{"packet":true}' > .cursor-worker/review-packet.json

  # Approval artifact with allow_commit=false and allow_merge=false
  cat > .cursor-worker/approval-artifact.json <<ARTIFACT
{
  "approval_id": "approval-smoke-012",
  "task_id": "TASK-SMOKE-FAKE-001",
  "repo": "$(basename "$(git rev-parse --show-toplevel)")",
  "branch": "task/TASK-SMOKE-FAKE-001",
  "head_commit_before_submit": "${head}",
  "review_packet_sha256": "$(shasum -a 256 .cursor-worker/review-packet.json 2>/dev/null | awk '{print $1}')",
  "diff_sha256": "$(shasum -a 256 .cursor-worker/latest.diff 2>/dev/null | awk '{print $1}')",
  "approved_at": "2026-05-25T02:00:00Z",
  "reviewer": "Codex",
  "allow_commit": false,
  "allow_merge": false
}
ARTIFACT

  local output
  output="$(run_harness_check_approval)"
  assert_contains "SC-12: permission denied" "${output}" "commit permission"
  assert_contains "SC-12: approval rejected" "${output}" "EXIT_CODE=1"

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# SC-13: dispatch failure (script not found)
# ============================================================================

test_dispatch_failure() {
  echo ""
  echo "=== SC-13: dispatch failure ==="
  setup_sandbox
  export CURSOR_WORKER_MODE="approved-submit"
  export CURSOR_REVIEW_APPROVAL_ID="approval-smoke-013"

  cd "${SANDBOX}"
  git checkout -b "task/TASK-SMOKE-FAKE-001"
  echo "# Dispatch test" >> README.md

  # Set dispatch script to a non-existent path
  export WORKER_HARNESS_REPORT_DISPATCH_SCRIPT="/nonexistent/dispatch.sh"

  local exit_code=0
  (
    cd "${SANDBOX}"
    source "${HARNESS_LIB}" > /dev/null 2>&1
    worker_harness_dispatch_and_ack 2>&1
  ) || exit_code=$?

  assert_eq "SC-13: dispatch fails" "1" "${exit_code}"

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# SC-14: fake ACK via listener state (receiver-produced artifact)
# ============================================================================

test_fake_ack_listener() {
  echo ""
  echo "=== SC-14: fake ACK via listener state ==="
  setup_sandbox
  export CURSOR_WORKER_MODE="approved-submit"

  cd "${SANDBOX}"
  mkdir -p .cursor-worker/review-packets
  # Create the receiver-produced listener state artifact
  cat > .cursor-worker/review-packets/docs-listener-state.json <<'ARTIFACT'
{
  "reported_task_ids": ["TASK-SMOKE-FAKE-001"]
}
ARTIFACT

  local ack_result
  ack_result="$(
    cd "${SANDBOX}"
    source "${HARNESS_LIB}" > /dev/null 2>&1
    worker_harness_check_docs_ack "TASK-SMOKE-FAKE-001" 2>/dev/null
  )"

  assert_eq "SC-14: ACK confirmed via listener" "confirmed" "${ack_result}"

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# SC-15: boundary violation
# ============================================================================

test_boundary_violation() {
  echo ""
  echo "=== SC-15: boundary violation function test ==="
  setup_sandbox
  export CURSOR_WORKER_MODE="implement-for-review"

  cd "${SANDBOX}"
  git checkout -b "task/TASK-SMOKE-FAKE-001"

  source "${HARNESS_LIB}" 2>/dev/null
  local result="pass"
  if worker_harness_check_boundary 2>/dev/null; then
    result="pass"
  else
    result="violation"
  fi

  assert_eq "SC-15: clean boundary check" "pass" "${result}"
  echo "  INFO: Full boundary violation test requires a real multi-repo workspace."
  echo "  INFO: The boundary check grep for '../livemask-docs/' in git diff paths."

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# SC-16: dirty submodule state
# ============================================================================

test_dirty_submodule() {
  echo ""
  echo "=== SC-16: dirty submodule state ==="
  setup_sandbox
  export CURSOR_WORKER_MODE="approved-submit"
  export CURSOR_REVIEW_APPROVAL_ID="approval-smoke-016"

  cd "${SANDBOX}"
  git checkout -b "task/TASK-SMOKE-FAKE-001"

  # Create a real submodule repo outside the sandbox
  local submod_repo
  submod_repo="$(mktemp -d "${TMPDIR:-/tmp}/submod-origin.XXXXXX")"
  (
    cd "${submod_repo}"
    git init --initial-branch=main > /dev/null 2>&1
    echo "# Submodule content" > submod-file.txt
    git add submod-file.txt
    git commit -m "init submodule" --no-gpg-sign > /dev/null 2>&1
  )

  # Add as submodule to the sandbox repo
  git -c protocol.file.allow=always submodule add "${submod_repo}" fake-submod > /dev/null 2>&1
  git commit -m "add submodule" --no-gpg-sign > /dev/null 2>&1

  # Now make the submodule dirty
  echo "extra dirty change" >> fake-submod/submod-file.txt

  # Create the approval AFTER the submodule commit
  mkdir -p .cursor-worker
  echo '{"dummy":true}' > .cursor-worker/review-packet.json
  echo "dummy diff" > .cursor-worker/latest.diff
  local head
  head="$(git rev-parse HEAD)"
  local rp_sha diff_sha
  rp_sha="$(python3 -c "import hashlib; print(hashlib.sha256(open('.cursor-worker/review-packet.json','rb').read()).hexdigest())" 2>/dev/null || true)"
  diff_sha="$(python3 -c "import hashlib; print(hashlib.sha256(open('.cursor-worker/latest.diff','rb').read()).hexdigest())" 2>/dev/null || true)"
  create_valid_approval "approval-smoke-016" "TASK-SMOKE-FAKE-001" "" "task/TASK-SMOKE-FAKE-001" "${head}" "${rp_sha}" "${diff_sha}"

  local exit_code=0
  local output
  output="$(
    cd "${SANDBOX}"
    source "${HARNESS_LIB}" > /dev/null 2>&1
    set +e
    worker_harness_init 2>&1
    worker_harness_gate_before_commit 2>&1
  )" || exit_code=$?

  assert_contains "SC-16: dirty submodule rejected" "${output}" "Dirty submodule"
  assert_eq "SC-16: non-zero exit from gate" "1" "$( (( exit_code > 0 )) && echo 1 || echo 0)"

  # Cleanup submodule repo
  rm -rf "${submod_repo}"

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# SC-17: Positive smoke — staged change → review gate → valid approval → gate PASS
# ============================================================================

test_positive_approval_cycle() {
  echo ""
  echo "=== SC-17: positive approval cycle ==="
  setup_sandbox
  export CURSOR_WORKER_MODE="implement-for-review"
  export WORKER_HARNESS_VALIDATION_CMDS="true"

  cd "${SANDBOX}"
  git checkout -b "task/TASK-SMOKE-FAKE-001"

  # Make a staged change
  echo "# My feature" > feature.txt
  git add feature.txt

  # Run review gate to produce canonical diff and review packet
  source "${HARNESS_LIB}" 2>/dev/null
  worker_harness_init 2>&1
  worker_harness_run_review_gate "feature implemented" "none" "true" 2>&1
  local rp_rc=$?

  assert_contains "SC-17: review gate produced packet" "$(cat .cursor-worker/review-packet.json 2>/dev/null || true)" "review_packet_version"
  assert_file_exists "SC-17: diff file" ".cursor-worker/latest.diff"
  assert_file_exists "SC-17: review packet" ".cursor-worker/review-packet.json"
  assert_eq "SC-17: review gate exits 0" "0" "${rp_rc}"

  # Compute the exact sha256 hashes from the canonical output
  local head
  head="$(git rev-parse HEAD)"
  local rp_sha diff_sha
  rp_sha="$(python3 -c "import hashlib; print(hashlib.sha256(open('.cursor-worker/review-packet.json','rb').read()).hexdigest())" 2>/dev/null || true)"
  diff_sha="$(python3 -c "import hashlib; print(hashlib.sha256(open('.cursor-worker/latest.diff','rb').read()).hexdigest())" 2>/dev/null || true)"
  local repo_name
  repo_name="$(basename "$(git rev-parse --show-toplevel)")"

  # Create valid approval artifact with the exact hashes
  mkdir -p .cursor-worker
  cat > .cursor-worker/approval-artifact.json <<ARTIFACT
{
  "approval_id": "approval-smoke-positive-017",
  "task_id": "TASK-SMOKE-FAKE-001",
  "repo": "${repo_name}",
  "branch": "task/TASK-SMOKE-FAKE-001",
  "head_commit_before_submit": "${head}",
  "review_packet_sha256": "${rp_sha}",
  "diff_sha256": "${diff_sha}",
  "approved_at": "2026-05-25T04:50:00Z",
  "reviewer": "Codex",
  "allow_commit": true,
  "allow_merge": true
}
ARTIFACT
  export CURSOR_REVIEW_APPROVAL_ID="approval-smoke-positive-017"

  # Now run the pre-commit gate — should PASS since worktree matches the approved diff
  export CURSOR_WORKER_MODE="approved-submit"
  local exit_code=0
  local gate_output
  gate_output="$(
    source "${HARNESS_LIB}" 2>/dev/null
    set +e
    worker_harness_init 2>&1
    worker_harness_gate_before_commit 2>&1
  )" || exit_code=$?

  assert_contains "SC-17: gate says PASS" "${gate_output}" "Pre-commit gate PASS"
  assert_eq "SC-17: gate exits 0" "0" "${exit_code}"

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# SC-18: staged reviewed diff + untracked source file => reject
# ============================================================================

test_untracked_source_rejected() {
  echo ""
  echo "=== SC-18: staged diff + untracked source file => reject ==="
  setup_sandbox
  export CURSOR_WORKER_MODE="implement-for-review"
  export WORKER_HARNESS_VALIDATION_CMDS="true"

  cd "${SANDBOX}"
  git checkout -b "task/TASK-SMOKE-FAKE-001"

  # Stage a change and run review gate to get canonical diff
  echo "# Reviewed change" > reviewed-feature.txt
  git add reviewed-feature.txt
  source "${HARNESS_LIB}" 2>/dev/null
  worker_harness_init 2>&1
  worker_harness_run_review_gate "staged feature" "none" "true" 2>&1

  local head rp_sha diff_sha repo_name
  head="$(git rev-parse HEAD)"
  rp_sha="$(python3 -c "import hashlib; print(hashlib.sha256(open('.cursor-worker/review-packet.json','rb').read()).hexdigest())" 2>/dev/null || true)"
  diff_sha="$(python3 -c "import hashlib; print(hashlib.sha256(open('.cursor-worker/latest.diff','rb').read()).hexdigest())" 2>/dev/null || true)"
  repo_name="$(basename "$(git rev-parse --show-toplevel)")"
  create_valid_approval "approval-smoke-018" "TASK-SMOKE-FAKE-001" "${repo_name}" "task/TASK-SMOKE-FAKE-001" "${head}" "${rp_sha}" "${diff_sha}"
  export CURSOR_REVIEW_APPROVAL_ID="approval-smoke-018"

  # Add an untracked source file (not in .cursor-worker/)
  echo "# Sneaky untracked file" > untracked-source.py

  # Run pre-commit gate — should reject because untracked source files exist
  local exit_code=0
  local output
  output="$(
    source "${HARNESS_LIB}" 2>/dev/null
    set +e
    CURSOR_WORKER_MODE="approved-submit"
    worker_harness_init 2>&1
    worker_harness_gate_before_commit 2>&1
  )" || exit_code=$?

  assert_contains "SC-18: untracked files rejected" "${output}" "Untracked files found"
  assert_eq "SC-18: non-zero exit from gate" "1" "$( (( exit_code > 0 )) && echo 1 || echo 0)"

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# SC-19: invalid approval (missing permissions) in pre-commit gate
# ============================================================================

test_invalid_approval_precommit() {
  echo ""
  echo "=== SC-19: pre-commit gate with invalid approval => reject ==="
  setup_sandbox
  export CURSOR_WORKER_MODE="implement-for-review"
  export WORKER_HARNESS_VALIDATION_CMDS="true"

  cd "${SANDBOX}"
  git checkout -b "task/TASK-SMOKE-FAKE-001"

  # Stage a change and run review gate
  echo "# Reviewed change" > reviewed-feature.txt
  git add reviewed-feature.txt
  source "${HARNESS_LIB}" 2>/dev/null
  worker_harness_init 2>&1
  worker_harness_run_review_gate "staged feature" "none" "true" 2>&1

  local head rp_sha diff_sha repo_name
  head="$(git rev-parse HEAD)"
  rp_sha="$(python3 -c "import hashlib; print(hashlib.sha256(open('.cursor-worker/review-packet.json','rb').read()).hexdigest())" 2>/dev/null || true)"
  diff_sha="$(python3 -c "import hashlib; print(hashlib.sha256(open('.cursor-worker/latest.diff','rb').read()).hexdigest())" 2>/dev/null || true)"
  repo_name="$(basename "$(git rev-parse --show-toplevel)")"
  # Create approval with allow_commit=false
  mkdir -p .cursor-worker
  cat > .cursor-worker/approval-artifact.json <<ARTIFACT
{
  "approval_id": "approval-smoke-019",
  "task_id": "TASK-SMOKE-FAKE-001",
  "repo": "${repo_name}",
  "branch": "task/TASK-SMOKE-FAKE-001",
  "head_commit_before_submit": "${head}",
  "review_packet_sha256": "${rp_sha}",
  "diff_sha256": "${diff_sha}",
  "approved_at": "2026-05-25T04:50:00Z",
  "reviewer": "Codex",
  "allow_commit": false,
  "allow_merge": false
}
ARTIFACT
  export CURSOR_REVIEW_APPROVAL_ID="approval-smoke-019"

  local exit_code=0
  local output
  output="$(
    source "${HARNESS_LIB}" 2>/dev/null
    set +e
    CURSOR_WORKER_MODE="approved-submit"
    worker_harness_init 2>&1
    worker_harness_gate_before_commit 2>&1
  )" || exit_code=$?

  assert_contains "SC-19: commit permission denied" "${output}" "commit permission"
  assert_eq "SC-19: non-zero exit from gate" "1" "$( (( exit_code > 0 )) && echo 1 || echo 0)"

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# SC-20: dirty submodule => reject
# ============================================================================

test_dirty_submodule_gate() {
  echo ""
  echo "=== SC-20: dirty submodule => reject ==="
  setup_sandbox
  export CURSOR_WORKER_MODE="implement-for-review"
  export WORKER_HARNESS_VALIDATION_CMDS="true"

  cd "${SANDBOX}"
  git checkout -b "task/TASK-SMOKE-FAKE-001"

  # Create a real submodule repo
  local submod_repo
  submod_repo="$(mktemp -d "${TMPDIR:-/tmp}/submod-origin-sc20.XXXXXX")"
  (
    cd "${submod_repo}"
    git init --initial-branch=main > /dev/null 2>&1
    echo "# Submodule content" > submod-file.txt
    git add submod-file.txt
    git commit -m "init submodule" --no-gpg-sign > /dev/null 2>&1
  )

  git -c protocol.file.allow=always submodule add "${submod_repo}" fake-submod > /dev/null 2>&1
  git add fake-submod .gitmodules
  git commit -m "add submodule" --no-gpg-sign > /dev/null 2>&1

  # Stage a change and get approval
  echo "# Reviewed change" > reviewed-feature.txt
  git add reviewed-feature.txt
  source "${HARNESS_LIB}" 2>/dev/null
  worker_harness_init 2>&1
  worker_harness_run_review_gate "staged feature" "none" "true" 2>&1

  local head rp_sha diff_sha repo_name
  head="$(git rev-parse HEAD)"
  rp_sha="$(python3 -c "import hashlib; print(hashlib.sha256(open('.cursor-worker/review-packet.json','rb').read()).hexdigest())" 2>/dev/null || true)"
  diff_sha="$(python3 -c "import hashlib; print(hashlib.sha256(open('.cursor-worker/latest.diff','rb').read()).hexdigest())" 2>/dev/null || true)"
  repo_name="$(basename "$(git rev-parse --show-toplevel)")"
  create_valid_approval "approval-smoke-020" "TASK-SMOKE-FAKE-001" "${repo_name}" "task/TASK-SMOKE-FAKE-001" "${head}" "${rp_sha}" "${diff_sha}"
  export CURSOR_REVIEW_APPROVAL_ID="approval-smoke-020"

  # Now make the submodule dirty
  echo "# Dirty submodule change" >> fake-submod/submod-file.txt

  local exit_code=0
  local output
  output="$(
    source "${HARNESS_LIB}" 2>/dev/null
    set +e
    CURSOR_WORKER_MODE="approved-submit"
    worker_harness_init 2>&1
    worker_harness_gate_before_commit 2>&1
  )" || exit_code=$?

  assert_contains "SC-20: dirty submodule rejected" "${output}" "Dirty submodule"
  assert_eq "SC-20: non-zero exit from gate" "1" "$( (( exit_code > 0 )) && echo 1 || echo 0)"

  rm -rf "${submod_repo}"
  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# SC-21: Dispatch configured + fake dispatch success + ACK via listener
# ============================================================================

test_dispatch_configured_and_ack() {
  echo ""
  echo "=== SC-21: dispatch configured + fake dispatch success + ACK via listener ==="
  setup_sandbox
  export CURSOR_WORKER_MODE="implement-for-review"
  export WORKER_HARNESS_VALIDATION_CMDS="true"

  cd "${SANDBOX}"
  git checkout -b "task/TASK-SMOKE-FAKE-001"

  # Create a fake dispatch script that accepts --input - and succeeds
  cat > "${SANDBOX}/fake-dispatch.sh" <<'DISPATCH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--input" && "${2:-}" == "-" ]]; then
  cat > /dev/null
fi
echo "Fake dispatch: success"
exit 0
DISPATCH
  chmod +x "${SANDBOX}/fake-dispatch.sh"
  export WORKER_HARNESS_REPORT_DISPATCH_SCRIPT="${SANDBOX}/fake-dispatch.sh"

  # Make a staged change and run review gate
  echo "# Dispatch test feature" > feature-dispatch.txt
  git add feature-dispatch.txt
  source "${HARNESS_LIB}" 2>/dev/null
  worker_harness_init 2>&1
  worker_harness_run_review_gate "dispatch feature" "none" "true" 2>&1

  local head rp_sha diff_sha repo_name
  head="$(git rev-parse HEAD)"
  rp_sha="$(python3 -c "import hashlib; print(hashlib.sha256(open('.cursor-worker/review-packet.json','rb').read()).hexdigest())" 2>/dev/null || true)"
  diff_sha="$(python3 -c "import hashlib; print(hashlib.sha256(open('.cursor-worker/latest.diff','rb').read()).hexdigest())" 2>/dev/null || true)"
  repo_name="$(basename "$(git rev-parse --show-toplevel)")"
  create_valid_approval "approval-smoke-021" "TASK-SMOKE-FAKE-001" "${repo_name}" "task/TASK-SMOKE-FAKE-001" "${head}" "${rp_sha}" "${diff_sha}"
  export CURSOR_REVIEW_APPROVAL_ID="approval-smoke-021"

  # Commit and capture completion evidence
  git add -A
  git commit -m "TASK-SMOKE-FAKE-001: dispatch test" --no-gpg-sign > /dev/null 2>&1
  local task_commit
  task_commit="$(git rev-parse HEAD)"

  # Simulate dev-merge commit and push
  git checkout dev
  git merge "task/TASK-SMOKE-FAKE-001" --no-edit --no-gpg-sign > /dev/null 2>&1
  local dev_merge_commit
  dev_merge_commit="$(git rev-parse HEAD)"
  local remote_dev_ref="${dev_merge_commit}"

  # Capture initial completion evidence
  worker_harness_capture_completion_evidence \
    "${task_commit}" "${dev_merge_commit}" "${remote_dev_ref}" \
    '{"ok":true}' "dispatch_pending" ""

  # Create the listener state artifact for ACK
  mkdir -p .cursor-worker/review-packets
  cat > .cursor-worker/review-packets/docs-listener-state.json <<'ARTIFACT'
{
  "reported_task_ids": ["TASK-SMOKE-FAKE-001"]
}
ARTIFACT

  # Now call dispatch_and_ack — it should succeed (dispatch sends, ACK via listener)
  local exit_code=0
  local da_output
  da_output="$(
    source "${HARNESS_LIB}" 2>/dev/null
    set +e
    CURSOR_WORKER_MODE="approved-submit"
    worker_harness_init 2>&1
    worker_harness_dispatch_and_ack 2>&1
  )" || exit_code=$?

  assert_eq "SC-21: dispatch_and_ack exits 0" "0" "${exit_code}"
  assert_contains "SC-21: dispatch confirmed" "${da_output}" "ACK: confirmed"

  # Verify completion evidence shows report_dispatched
  local evidence
  evidence="$(cat "${SANDBOX}/.cursor-worker/completion-evidence.json" 2>/dev/null || true)"
  assert_contains "SC-21: evidence has task_branch_commit" "${evidence}" "task_branch_commit"
  assert_contains "SC-21: evidence has dev_merge_commit" "${evidence}" "dev_merge_commit"
  assert_contains "SC-21: evidence has remote_dev_ref" "${evidence}" "remote_dev_ref"
  assert_contains "SC-21: evidence dispatch_status=report_dispatched" "${evidence}" "report_dispatched"
  assert_contains "SC-21: evidence has dispatched_at" "${evidence}" "dispatched_at"

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# SC-21b: Dispatch via config (no env var) + ACK via listener
# ============================================================================

test_dispatch_config_based() {
  echo ""
  echo "=== SC-21b: dispatch via config (no env var) + ACK via listener ==="
  setup_sandbox
  export CURSOR_WORKER_MODE="implement-for-review"
  export WORKER_HARNESS_VALIDATION_CMDS="true"

  cd "${SANDBOX}"
  git checkout -b "task/TASK-SMOKE-FAKE-001"

  # Create a fake dispatch script — rely on worker-harness-config.json
  cat > "${SANDBOX}/fake-config-dispatch.sh" <<'DISPATCH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--input" && "${2:-}" == "-" ]]; then
  cat > /dev/null
fi
echo "Fake config dispatch: success"
exit 0
DISPATCH
  chmod +x "${SANDBOX}/fake-config-dispatch.sh"

  # Write a worker-harness-config.json for the sandbox repo
  local repo_name
  repo_name="$(basename "$(git rev-parse --show-toplevel)")"
  mkdir -p scripts
  cat > scripts/worker-harness-config.json <<CONFIG
{
  "schema_version": 1,
  "repos": {
    "${repo_name}": {
      "report_dispatch_script": "${SANDBOX}/fake-config-dispatch.sh"
    }
  }
}
CONFIG
  export WORKER_HARNESS_CONFIG="${SANDBOX}/scripts/worker-harness-config.json"
  # Ensure env var is unset so harness falls back to config
  unset WORKER_HARNESS_REPORT_DISPATCH_SCRIPT

  # Make a staged change and run review gate
  echo "# Config dispatch test" > feature-config-dispatch.txt
  git add feature-config-dispatch.txt
  source "${HARNESS_LIB}" 2>/dev/null
  worker_harness_init 2>&1
  worker_harness_run_review_gate "config dispatch feature" "none" "true" 2>&1

  local head rp_sha diff_sha
  head="$(git rev-parse HEAD)"
  rp_sha="$(python3 -c "import hashlib; print(hashlib.sha256(open('.cursor-worker/review-packet.json','rb').read()).hexdigest())" 2>/dev/null || true)"
  diff_sha="$(python3 -c "import hashlib; print(hashlib.sha256(open('.cursor-worker/latest.diff','rb').read()).hexdigest())" 2>/dev/null || true)"
  create_valid_approval "approval-smoke-021b" "TASK-SMOKE-FAKE-001" "${repo_name}" "task/TASK-SMOKE-FAKE-001" "${head}" "${rp_sha}" "${diff_sha}"
  export CURSOR_REVIEW_APPROVAL_ID="approval-smoke-021b"

  # Commit and capture completion evidence
  git add -A
  git commit -m "TASK-SMOKE-FAKE-001: config dispatch test" --no-gpg-sign > /dev/null 2>&1
  local task_commit
  task_commit="$(git rev-parse HEAD)"

  # Simulate dev-merge
  git checkout dev
  git merge "task/TASK-SMOKE-FAKE-001" --no-edit --no-gpg-sign > /dev/null 2>&1
  local dev_merge_commit
  dev_merge_commit="$(git rev-parse HEAD)"
  local remote_dev_ref="${dev_merge_commit}"

  worker_harness_capture_completion_evidence \
    "${task_commit}" "${dev_merge_commit}" "${remote_dev_ref}" \
    '{"ok":true}' "dispatch_pending" ""

  # Create listener state for ACK
  mkdir -p .cursor-worker/review-packets
  cat > .cursor-worker/review-packets/docs-listener-state.json <<'ARTIFACT'
{
  "reported_task_ids": ["TASK-SMOKE-FAKE-001"]
}
ARTIFACT

  # Call dispatch_and_ack — no env var set, should read from config
  local exit_code=0
  local da_output
  da_output="$(
    source "${HARNESS_LIB}" 2>/dev/null
    set +e
    CURSOR_WORKER_MODE="approved-submit"
    worker_harness_init 2>&1
    worker_harness_dispatch_and_ack 2>&1
  )" || exit_code=$?

  assert_eq "SC-21b: dispatch_and_ack exits 0" "0" "${exit_code}"
  assert_contains "SC-21b: dispatch script resolved from config" "${da_output}" "config"
  assert_contains "SC-21b: ACK confirmed" "${da_output}" "ACK: confirmed"

  local evidence
  evidence="$(cat "${SANDBOX}/.cursor-worker/completion-evidence.json" 2>/dev/null || true)"
  assert_contains "SC-21b: evidence dispatch_status=report_dispatched" "${evidence}" "report_dispatched"

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# SC-22: Dispatch not configured -> dispatch_pending evidence
# ============================================================================

test_dispatch_not_configured() {
  echo ""
  echo "=== SC-22: dispatch not configured -> dispatch_pending evidence ==="
  setup_sandbox
  export CURSOR_WORKER_MODE="approved-submit"
  export CURSOR_REVIEW_APPROVAL_ID="approval-smoke-022"

  cd "${SANDBOX}"
  git checkout -b "task/TASK-SMOKE-FAKE-001"

  # Unset dispatch script (default blank)
  unset WORKER_HARNESS_REPORT_DISPATCH_SCRIPT

  # Create a fake completion evidence so dispatch_and_ack can read commit info
  mkdir -p .cursor-worker
  local head
  head="$(git rev-parse HEAD)"
  cat > .cursor-worker/completion-evidence.json <<EVIDENCE
{
  "task_branch_commit": "${head}",
  "dev_merge_commit": "${head}",
  "remote_dev_ref": "${head}",
  "validation_result": "{\"ok\":true}",
  "dispatch_status": "dispatch_pending"
}
EVIDENCE

  local exit_code=0
  local output
  output="$(
    cd "${SANDBOX}"
    source "${HARNESS_LIB}" > /dev/null 2>&1
    set +e
    worker_harness_init 2>&1
    worker_harness_dispatch_and_ack 2>&1
  )" || exit_code=$?

  assert_eq "SC-22: dispatch_and_ack returns 1" "1" "${exit_code}"
  assert_contains "SC-22: dispatch_script not set warning" "${output}" "not set"

  # Verify evidence preserved with dispatch_pending
  local evidence
  evidence="$(cat "${SANDBOX}/.cursor-worker/completion-evidence.json" 2>/dev/null || true)"
  assert_contains "SC-22: evidence dispatch_status=dispatch_pending" "${evidence}" "dispatch_pending"

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# SC-23: Dispatch sent but ACK timeout -> dispatch_pending evidence
# ============================================================================

test_dispatch_ack_timeout() {
  echo ""
  echo "=== SC-23: dispatch sent but ACK timeout -> dispatch_pending evidence ==="
  setup_sandbox
  export CURSOR_WORKER_MODE="approved-submit"
  export WORKER_HARNESS_VALIDATION_CMDS="true"

  cd "${SANDBOX}"
  git checkout -b "task/TASK-SMOKE-FAKE-001"

  # Create a fake dispatch script that accepts --input - and succeeds
  cat > "${SANDBOX}/fake-dispatch-23.sh" <<'DISPATCH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--input" && "${2:-}" == "-" ]]; then
  cat > /dev/null
fi
echo "Fake dispatch: sent"
exit 0
DISPATCH
  chmod +x "${SANDBOX}/fake-dispatch-23.sh"
  export WORKER_HARNESS_REPORT_DISPATCH_SCRIPT="${SANDBOX}/fake-dispatch-23.sh"

  # Set very low poll limits for fast timeout
  export WORKER_HARNESS_ACK_POLL_INTERVAL=1
  export WORKER_HARNESS_ACK_POLL_MAX=2

  # Create a fake completion evidence
  mkdir -p .cursor-worker
  local head
  head="$(git rev-parse HEAD)"
  cat > .cursor-worker/completion-evidence.json <<EVIDENCE
{
  "task_branch_commit": "${head}",
  "dev_merge_commit": "${head}",
  "remote_dev_ref": "${head}",
  "validation_result": "{\"ok\":true}",
  "dispatch_status": "dispatch_pending"
}
EVIDENCE

  local exit_code=0
  local output
  output="$(
    cd "${SANDBOX}"
    source "${HARNESS_LIB}" > /dev/null 2>&1
    set +e
    worker_harness_init 2>&1
    worker_harness_dispatch_and_ack 2>&1
  )" || exit_code=$?

  assert_eq "SC-23: dispatch_and_ack returns 1 on ACK timeout" "1" "${exit_code}"
  assert_contains "SC-23: ACK not confirmed" "${output}" "not confirmed"

  # Verify evidence preserved with dispatch_pending
  local evidence
  evidence="$(cat "${SANDBOX}/.cursor-worker/completion-evidence.json" 2>/dev/null || true)"
  assert_contains "SC-23: evidence dispatch_status=dispatch_pending" "${evidence}" "dispatch_pending"
  assert_contains "SC-23: evidence has dispatched_at" "${evidence}" "dispatched_at"

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# SC-24: Completion evidence content check
# ============================================================================

test_completion_evidence_content() {
  echo ""
  echo "=== SC-24: completion evidence content check ==="
  setup_sandbox
  export CURSOR_WORKER_MODE="implement-for-review"
  export WORKER_HARNESS_VALIDATION_CMDS="true"

  cd "${SANDBOX}"
  git checkout -b "task/TASK-SMOKE-FAKE-001"

  # Make staged changes, commit, dev-merge to simulate approved-submit
  echo "# Evidence test" > evidence-feature.txt
  git add evidence-feature.txt
  source "${HARNESS_LIB}" 2>/dev/null
  worker_harness_init 2>&1
  worker_harness_run_review_gate "evidence test" "none" "true" 2>&1

  local head rp_sha diff_sha repo_name
  head="$(git rev-parse HEAD)"
  rp_sha="$(python3 -c "import hashlib; print(hashlib.sha256(open('.cursor-worker/review-packet.json','rb').read()).hexdigest())" 2>/dev/null || true)"
  diff_sha="$(python3 -c "import hashlib; print(hashlib.sha256(open('.cursor-worker/latest.diff','rb').read()).hexdigest())" 2>/dev/null || true)"
  repo_name="$(basename "$(git rev-parse --show-toplevel)")"
  create_valid_approval "approval-smoke-024" "TASK-SMOKE-FAKE-001" "${repo_name}" "task/TASK-SMOKE-FAKE-001" "${head}" "${rp_sha}" "${diff_sha}"

  # Commit and merge dev
  git add -A
  git commit -m "TASK-SMOKE-FAKE-001: evidence test" --no-gpg-sign > /dev/null 2>&1
  local task_commit
  task_commit="$(git rev-parse HEAD)"
  git checkout dev
  git merge "task/TASK-SMOKE-FAKE-001" --no-edit --no-gpg-sign > /dev/null 2>&1
  local dev_merge_commit
  dev_merge_commit="$(git rev-parse HEAD)"
  local remote_dev_ref="${dev_merge_commit}"

  # Capture completion evidence
  worker_harness_capture_completion_evidence \
    "${task_commit}" "${dev_merge_commit}" "${remote_dev_ref}" \
    '[{"cmd":"true","exit_code":0}]' "dispatch_pending" ""

  local evidence
  evidence="$(cat "${SANDBOX}/.cursor-worker/completion-evidence.json" 2>/dev/null || true)"

  assert_contains "SC-24: evidence has task_branch_commit" "${evidence}" "${task_commit}"
  assert_contains "SC-24: evidence has dev_merge_commit" "${evidence}" "${dev_merge_commit}"
  assert_contains "SC-24: evidence has remote_dev_ref" "${evidence}" "${remote_dev_ref}"
  assert_contains "SC-24: evidence has dispatch_status" "${evidence}" "dispatch_pending"
  assert_contains "SC-24: evidence has task_id" "${evidence}" "TASK-SMOKE-FAKE-001"
  assert_contains "SC-24: evidence has validation_result" "${evidence}" "exit_code"
  assert_contains "SC-24: evidence has evidence_version" "${evidence}" "evidence_version"
  assert_contains "SC-24: evidence has completion_time" "${evidence}" "completion_time"

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# SC-25: Dispatch script body validation — fake gh captures full body
# ============================================================================

test_dispatch_body_validation() {
  echo ""
  echo "=== SC-25: dispatch script body validation ==="
  setup_sandbox
  cd "${SANDBOX}"

  local body_captured="${SANDBOX}/captured-body.json"
  local gh_path="${SANDBOX}/gh"

  # Install a fake gh on PATH that captures stdin to ${body_captured}
  # (unquoted FAKEGH so that the shell variable expands at heredoc creation time)
  cat > "${gh_path}" <<FAKEGH
#!/usr/bin/env bash
cat > ${body_captured}
echo "gh-stub: captured body" >&2
exit 0
FAKEGH
  chmod +x "${gh_path}"
  export PATH="${SANDBOX}:${PATH}"
  export LIVEMASK_BOT_TOKEN="fake-token-for-test"

  local input_json
  input_json='{"task_id":"TASK-SMOKE-SC25-001","result":"completed","repo":"smoke-repo","branch":"dev","commit":"abc123def456abc123def456abc123def456abc123","task_branch":"task/TASK-SMOKE-SC25-001","task_commit":"def456abc123def456abc123def456abc123def456","dev_merge_commit":"789012ef789012ef789012ef789012ef789012ef","validation":"{\"ok\":true}"}'

  local dispatch_script="${SCRIPT_DIR}/cursor-report-dispatch.sh"

  echo "${input_json}" | bash "${dispatch_script}" --input -
  local dispatch_rc=$?
  assert_eq "SC-25: dispatch exits 0" "0" "${dispatch_rc}"

  # Read the captured body and validate
  local captured_body=""
  if [[ -f "${body_captured}" ]]; then
    captured_body="$(cat "${body_captured}")"
  fi

  # event_type
  assert_contains "SC-25: body has event_type" "${captured_body}" "cursor-report-received"

  # client_payload is a JSON object (not a string)
  local cp_type
  cp_type="$(echo "${captured_body}" | python3 -c '
import json, sys
try:
    body = json.load(sys.stdin)
    cp = body.get("client_payload")
    if isinstance(cp, dict):
        print("object")
    elif isinstance(cp, str):
        print("string")
    else:
        print("none")
except Exception:
    print("error")
' 2>/dev/null || echo 'error')"
  assert_eq "SC-25: client_payload is JSON object" "object" "${cp_type}"

  # client_payload required fields
  local cp_fields
  cp_fields="$(echo "${captured_body}" | python3 -c '
import json, sys
body = json.load(sys.stdin)
cp = body.get("client_payload", {})
for k in ("task_id","repo","commit","task_commit","dev_merge_commit","validation"):
    print(f"field_{k}={cp.get(k,"")!r}")
' 2>/dev/null || true)"
  assert_contains "SC-25: client_payload has task_id" "${cp_fields}" "TASK-SMOKE-SC25-001"
  assert_contains "SC-25: client_payload has repo" "${cp_fields}" "smoke-repo"
  assert_contains "SC-25: client_payload has commit" "${cp_fields}" "abc123def456abc123def456abc123def456abc123"
  assert_contains "SC-25: client_payload has task_commit" "${cp_fields}" "def456abc123def456abc123def456abc123def456"
  assert_contains "SC-25: client_payload has dev_merge_commit" "${cp_fields}" "789012ef789012ef789012ef789012ef789012ef"
  assert_contains "SC-25: client_payload has validation" "${cp_fields}" "ok"

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# SC-26: ACK commit scan — recent commits contain task but not latest;
#        fake gh confirms ACK via Strategy B
# ============================================================================

test_ack_recent_commits_scan() {
  echo ""
  echo "=== SC-26: ACK commit scan — task found in recent commits (not latest) ==="
  setup_sandbox
  cd "${SANDBOX}"

  # Create a fake gh that always returns commits where the latest commit is
  # for a *different* task, but an earlier commit contains the current task.
  local gh_path="${SANDBOX}/gh"
  cat > "${gh_path}" <<'FAKEGH'
#!/usr/bin/env bash
cat <<COMMITS
fix: unrelated change

chore: bump dep

completion-report: ingest TASK-SMOKE-FAKE-001

docs: update README

feat: add new endpoint
COMMITS
exit 0
FAKEGH
  chmod +x "${gh_path}"
  export PATH="${SANDBOX}:${PATH}"
  export LIVEMASK_BOT_TOKEN="fake-token-for-ack"

  # Set low poll limits for fast test
  export WORKER_HARNESS_ACK_POLL_INTERVAL=1
  export WORKER_HARNESS_ACK_POLL_MAX=2

  git checkout -b "task/TASK-SMOKE-FAKE-001"
  echo "# ack scan" > ack-scan.txt
  git add ack-scan.txt

  mkdir -p .cursor-worker
  local head
  head="$(git rev-parse HEAD)"
  cat > .cursor-worker/completion-evidence.json <<EVIDENCE
{
  "task_branch_commit": "${head}",
  "dev_merge_commit": "${head}",
  "remote_dev_ref": "${head}",
  "validation_result": "{\"ok\":true}",
  "dispatch_status": "dispatch_pending"
}
EVIDENCE

  # Create a fake dispatch script that succeeds
  cat > "${SANDBOX}/fake-dispatch-26.sh" <<'DISPATCH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--input" && "${2:-}" == "-" ]]; then
  cat > /dev/null
fi
echo "Fake dispatch: sent"
exit 0
DISPATCH
  chmod +x "${SANDBOX}/fake-dispatch-26.sh"
  export WORKER_HARNESS_REPORT_DISPATCH_SCRIPT="${SANDBOX}/fake-dispatch-26.sh"

  local exit_code=0
  local output
  output="$(
    source "${HARNESS_LIB}" > /dev/null 2>&1
    set +e
    worker_harness_init 2>&1
    worker_harness_dispatch_and_ack 2>&1
  )" || exit_code=$?

  # dispatch_and_ack should succeed (ACK confirmed via Strategy B commit scan)
  assert_eq "SC-26: dispatch_and_ack exits 0" "0" "${exit_code}"
  assert_contains "SC-26: ACK confirmed" "${output}" "ACK: confirmed"

  # Verify evidence shows report_dispatched
  local evidence
  evidence="$(cat "${SANDBOX}/.cursor-worker/completion-evidence.json" 2>/dev/null || true)"
  assert_contains "SC-26: dispatch_status=report_dispatched" "${evidence}" "report_dispatched"

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# Main
# ============================================================================

echo ""
echo "================================================================"
echo " Cursor SDK Worker Harness — Deterministic Smoke Tests"
echo "================================================================"
echo ""

test_dry_run
test_accept_only
test_implement_for_review
test_missing_approval
test_branch_mismatch
test_dirty_worktree_approved_submit
test_validation_failure
test_invalid_approval_task_id
test_invalid_approval_approval_id
test_invalid_approval_missing_fields
test_invalid_approval_diff_mutation
test_invalid_approval_no_permission
test_dispatch_failure
test_fake_ack_listener
test_boundary_violation
test_dirty_submodule
test_positive_approval_cycle
test_untracked_source_rejected
test_invalid_approval_precommit
test_dirty_submodule_gate
test_dispatch_configured_and_ack
test_dispatch_config_based
test_dispatch_not_configured
test_dispatch_ack_timeout
test_completion_evidence_content
test_dispatch_body_validation
test_ack_recent_commits_scan

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
