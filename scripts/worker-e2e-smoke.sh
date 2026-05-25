#!/usr/bin/env bash
# TASK-CICD-WORKER-E2E-SMOKE-001
#
# Sandbox-only end-to-end worker smoke test.  Proves the worker lifecycle
# in an isolated temporary git sandbox with no production mutation.
#
# This smoke does NOT perform real repository_dispatch or docs ACK.
# --real is a future-scope placeholder (see REAL MODE below).
#
# ============================================================================
# Smoke Scenarios (Sandbox Only)
# ============================================================================
#
#   E2E-01  Dry-run: prints planned flow, no side effects, exit 0.
#   E2E-02  implement-for-review: stages a change, captures canonical diff,
#           runs validation, builds review packet.  Validates packet
#           against review-packet-schema-v1.json.  Asserts non-empty
#           validation[] array.  No commit.
#   E2E-03  approved-submit gate: valid approval artifact passes pre-commit
#           gate; allow_commit=false / allow_merge=false gates reject.
#   E2E-04  Dispatch body validation: builds dispatch JSON, pipes through
#           cursor-report-dispatch.sh --input -, captures dispatch body,
#           asserts event_type=cursor-report-received and client_payload
#           is a JSON object with all required fields (≤10 properties).
#   E2E-05  Docs ACK via listener state: receiver-produced listener state
#           artifact, worker_harness_check_docs_ack returns "confirmed".
#   E2E-06  Completion evidence: after commit+merge, evidence JSON
#           contains task_branch_commit, dev_merge_commit, remote_dev_ref,
#           dispatch_status, completion_time, evidence_version.
#
# ============================================================================
# REAL MODE (NOT YET IMPLEMENTED)
# ============================================================================
#
# --real is a placeholder for a future task that will wire real GitHub
# repository_dispatch to livemask-docs.  In this revision:
#
#   --real is accepted but ignored (stub with informational message).
#   No real repository_dispatch, no real docs ACK is performed.
#   This script is sandbox-only E2E.
#
# ============================================================================
# Usage
# ============================================================================
#
#   bash scripts/worker-e2e-smoke.sh                  # dry-run (default)
#   bash scripts/worker-e2e-smoke.sh --no-dry-run      # run all in sandbox
#   bash scripts/worker-e2e-smoke.sh --no-dry-run --smoke E2E-04,E2E-05
#
# ============================================================================

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HARNESS_LIB="${SCRIPT_DIR}/lib/worker-harness.sh"
HELPER_PY="${SCRIPT_DIR}/lib/worker-harness-helper.py"
DISPATCH_SCRIPT="${SCRIPT_DIR}/cursor-report-dispatch.sh"

# ============================================================================
# Config
# ============================================================================

SYNTHETIC_TASK_ID="TASK-SMOKE-E2E-FAKE-001"

# Default: dry-run only
DRY_RUN=true
REAL_DISPATCH=false
SELECTED_SCENARIOS=""

# ============================================================================
# Args
# ============================================================================

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} [options]

Options:
  --dry-run          Print planned scenarios and exit (default).
  --no-dry-run       Execute scenarios in a sandbox.
  --smoke <ids>      Comma-separated scenario IDs (E2E-01,E2E-02,...).
  --real             Also perform real GitHub repository_dispatch.
                     Requires LIVEMASK_BOT_TOKEN and gh CLI.
  -h, --help         Show this help.

Scenarios:
  E2E-01  Dry-run mode output
  E2E-02  implement-for-review lifecycle
  E2E-03  approved-submit gate (positive and negative)
  E2E-04  Dispatch body validation
  E2E-05  Docs ACK via listener state
  E2E-06  Completion evidence content
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --no-dry-run) DRY_RUN=false; shift ;;
    --smoke) SELECTED_SCENARIOS="$2"; shift 2 ;;
    --real) REAL_DISPATCH=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

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
# Sandbox
# ============================================================================

SANDBOX=""
SANDBOX_ORIG_DIR=""

setup_sandbox() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/worker-e2e-smoke.XXXXXX")"
  SANDBOX_ORIG_DIR="$(pwd)"

  cd "${SANDBOX}"
  git init --initial-branch=dev
  git config user.email "e2e-smoke@test.livemask"
  git config user.name "E2E Smoke Test"
  echo "# E2E smoke sandbox" > README.md
  echo "*.md text eol=lf" > .gitattributes
  git add -A
  git commit -m "initial commit on dev" --no-gpg-sign

  unset LIVEMASK_BOT_TOKEN
  export WORKER_HARNESS_TASK_ID="${SYNTHETIC_TASK_ID}"
  export WORKER_HARNESS_VALIDATION_CMDS="true"
  export WORKER_HARNESS_SECRET_PATTERNS="NONE_USED_IN_SMOKE"
  export WORKER_HARNESS_HELPER_PATH="${HELPER_PY}"
}

teardown_sandbox() {
  cd "${SANDBOX_ORIG_DIR}"
  if [[ -n "${SANDBOX}" && -d "${SANDBOX}" ]]; then
    rm -rf "${SANDBOX}"
  fi
}

# ============================================================================
# Helper: create valid approval artifact
# ============================================================================

create_valid_approval() {
  local approval_id="${1:-approval-e2e-001}"
  local task_id="${2:-${SYNTHETIC_TASK_ID}}"
  local repo="${3:-}"
  local branch="${4:-task/${SYNTHETIC_TASK_ID}}"
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

# ============================================================================
# Scenario filter
# ============================================================================

run_scenario() {
  local id="$1"
  if [[ -n "${SELECTED_SCENARIOS}" ]]; then
    local found=false
    IFS=',' read -ra ids <<< "${SELECTED_SCENARIOS}"
    for sid in "${ids[@]}"; do
      if [[ "${sid}" == "${id}" ]]; then
        found=true
        break
      fi
    done
    if [[ "${found}" != true ]]; then
      return 0
    fi
  fi
  "$2"
}

# ============================================================================
# E2E-01: Dry-run mode output
# ============================================================================

scenario_dry_run_output() {
  echo ""
  echo "=== E2E-01: Dry-run mode output ==="
  setup_sandbox
  export CURSOR_WORKER_MODE="dry-run"

  local output
  output="$(cd "${SANDBOX}" && source "${HARNESS_LIB}" && worker_harness_init && worker_harness_dry_run 2>&1 || true)"

  assert_contains "E2E-01: prints 'DRY-RUN'" "${output}" "DRY-RUN"
  assert_contains "E2E-01: prints task ID" "${output}" "${SYNTHETIC_TASK_ID}"
  assert_contains "E2E-01: mentions worktree state" "${output}" "Worktree"

  assert_file_not_exists "E2E-01: no review packet" "${SANDBOX}/.cursor-worker/review-packet.json"
  assert_file_not_exists "E2E-01: no diff" "${SANDBOX}/.cursor-worker/latest.diff"

  teardown_sandbox
}

# ============================================================================
# E2E-02: implement-for-review lifecycle
# ============================================================================

scenario_implement_for_review() {
  echo ""
  echo "=== E2E-02: implement-for-review lifecycle ==="
  setup_sandbox
  export CURSOR_WORKER_MODE="implement-for-review"

  cd "${SANDBOX}"
  git checkout -b "task/${SYNTHETIC_TASK_ID}"
  echo "# E2E feature" > feature.txt
  git add feature.txt

  local output
  output="$(source "${HARNESS_LIB}" && worker_harness_init && worker_harness_run_review_gate "e2e agent done" "no_risks" "true" 2>&1 || true)"

  assert_contains "E2E-02: review gate ran" "${output}" "REVIEW PACKET READY"
  assert_contains "E2E-02: NOT committed" "${output}" "NOT committed"
  assert_contains "E2E-02: NOT merged" "${output}" "NOT merged"
  assert_file_exists "E2E-02: review packet" "${SANDBOX}/.cursor-worker/review-packet.json"
  assert_file_exists "E2E-02: canonical diff" "${SANDBOX}/.cursor-worker/latest.diff"

  local packet
  packet="$(cat "${SANDBOX}/.cursor-worker/review-packet.json" 2>/dev/null || true)"
  assert_contains "E2E-02: packet has task_id" "${packet}" "${SYNTHETIC_TASK_ID}"
  assert_contains "E2E-02: packet has implement-for-review mode" "${packet}" "implement-for-review"
  assert_contains "E2E-02: packet has diff fields" "${packet}" "diff"
  assert_contains "E2E-02: packet has codex_approval_required" "${packet}" "codex_approval_required_for_next_stage"

  # Assert validation[] array is non-empty (schema requires minItems: 1)
  assert_contains "E2E-02: validation[] non-empty" "${packet}" '"cmd":'
  assert_contains "E2E-02: validation[] has exit_code" "${packet}" '"exit_code":'

  # Assert committed, merged, report_dispatched are all false
  assert_contains "E2E-02: committed=false" "${packet}" '"committed": false'
  assert_contains "E2E-02: merged=false" "${packet}" '"merged": false'
  assert_contains "E2E-02: report_dispatched=false" "${packet}" '"report_dispatched": false'

  local status
  status="$(git status --porcelain)"
  assert_contains "E2E-02: changes staged" "${status}" "feature.txt"

  # Validate the generated packet against review-packet-schema-v1.json
  if [[ -f "${SCRIPT_DIR}/validate-review-packet.sh" ]]; then
    local val_output val_rc=0
    val_output="$(bash "${SCRIPT_DIR}/validate-review-packet.sh" "${SANDBOX}/.cursor-worker/review-packet.json" 2>&1)" || val_rc=$?
    assert_eq "E2E-02: schema validation exit 0" "0" "${val_rc}"
    assert_contains "E2E-02: schema validation PASS" "${val_output}" "PASS"
  else
    echo "  SKIP: validate-review-packet.sh not found (schema validation skipped)"
  fi

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# E2E-03: approved-submit gate
# ============================================================================

scenario_approved_submit_gate() {
  echo ""
  echo "=== E2E-03: approved-submit gate ==="
  setup_sandbox
  export CURSOR_WORKER_MODE="implement-for-review"
  export WORKER_HARNESS_VALIDATION_CMDS="true"

  cd "${SANDBOX}"
  git checkout -b "task/${SYNTHETIC_TASK_ID}"

  # Stage a change and run review gate
  echo "# Gate feature" > gate-feature.txt
  git add gate-feature.txt
  source "${HARNESS_LIB}" 2>/dev/null
  worker_harness_init 2>&1
  worker_harness_run_review_gate "gate test" "none" "true" 2>&1

  local head rp_sha diff_sha repo_name
  head="$(git rev-parse HEAD)"
  rp_sha="$(python3 -c "import hashlib; print(hashlib.sha256(open('.cursor-worker/review-packet.json','rb').read()).hexdigest())" 2>/dev/null || true)"
  diff_sha="$(python3 -c "import hashlib; print(hashlib.sha256(open('.cursor-worker/latest.diff','rb').read()).hexdigest())" 2>/dev/null || true)"
  repo_name="$(basename "$(git rev-parse --show-toplevel)")"

  # --- Subtest A: valid approval -> gate PASS ---
  echo "  --- Subtest A: valid approval PASS ---"
  create_valid_approval "approval-e2e-03a" "${SYNTHETIC_TASK_ID}" "${repo_name}" "task/${SYNTHETIC_TASK_ID}" "${head}" "${rp_sha}" "${diff_sha}"
  export CURSOR_REVIEW_APPROVAL_ID="approval-e2e-03a"

  local exit_code_a=0
  local output_a
  output_a="$(
    source "${HARNESS_LIB}" 2>/dev/null
    set +e
    CURSOR_WORKER_MODE="approved-submit"
    worker_harness_init 2>&1
    worker_harness_gate_before_commit 2>&1
  )" || exit_code_a=$?

  assert_eq "E2E-03a: valid approval exits 0" "0" "${exit_code_a}"
  assert_contains "E2E-03a: gate PASS message" "${output_a}" "Pre-commit gate PASS"

  # --- Subtest B: allow_commit=false -> reject ---
  echo "  --- Subtest B: allow_commit=false -> reject ---"
  cat > .cursor-worker/approval-artifact.json <<ARTIFACT
{
  "approval_id": "approval-e2e-03b",
  "task_id": "${SYNTHETIC_TASK_ID}",
  "repo": "${repo_name}",
  "branch": "task/${SYNTHETIC_TASK_ID}",
  "head_commit_before_submit": "${head}",
  "review_packet_sha256": "${rp_sha}",
  "diff_sha256": "${diff_sha}",
  "approved_at": "2026-05-25T02:00:00Z",
  "reviewer": "Codex",
  "allow_commit": false,
  "allow_merge": false
}
ARTIFACT
  export CURSOR_REVIEW_APPROVAL_ID="approval-e2e-03b"

  local exit_code_b=0
  local output_b
  output_b="$(
    source "${HARNESS_LIB}" 2>/dev/null
    set +e
    CURSOR_WORKER_MODE="approved-submit"
    worker_harness_init 2>&1
    worker_harness_gate_before_commit 2>&1
  )" || exit_code_b=$?

  assert_contains "E2E-03b: reject mentions commit permission" "${output_b}" "commit permission"
  assert_eq "E2E-03b: invalid permission exits non-zero" "1" "$( (( exit_code_b > 0 )) && echo 1 || echo 0)"

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# E2E-04: Dispatch body validation
# ============================================================================

scenario_dispatch_body_validation() {
  echo ""
  echo "=== E2E-04: Dispatch body validation ==="
  setup_sandbox

  local body_captured="${SANDBOX}/captured-body.json"
  local gh_path="${SANDBOX}/gh"

  # Install a fake gh that captures stdin to ${body_captured}
  cat > "${gh_path}" <<FAKEGH
#!/usr/bin/env bash
cat > ${body_captured}
echo "gh-stub: captured body" >&2
exit 0
FAKEGH
  chmod +x "${gh_path}"
  export PATH="${SANDBOX}:${PATH}"
  export LIVEMASK_BOT_TOKEN="fake-token-for-e2e"

  local input_json
  input_json='{"task_id":"TASK-SMOKE-E2E-FAKE-001","result":"completed","repo":"smoke-e2e","branch":"dev","commit":"abc123def456abc123def456abc123def456abc123","task_branch":"task/TASK-SMOKE-E2E-FAKE-001","task_commit":"def456abc123def456abc123def456abc123def456","dev_merge_commit":"789012ef789012ef789012ef789012ef789012ef","validation":"{\"ok\":true}","completion_time":"2026-05-25T06:00:00Z"}'

  echo "${input_json}" | bash "${DISPATCH_SCRIPT}" --input -
  local dispatch_rc=$?
  assert_eq "E2E-04: dispatch exits 0" "0" "${dispatch_rc}"

  local captured_body=""
  if [[ -f "${body_captured}" ]]; then
    captured_body="$(cat "${body_captured}")"
  fi

  # event_type
  assert_contains "E2E-04: body has event_type" "${captured_body}" "cursor-report-received"

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
  assert_eq "E2E-04: client_payload is JSON object" "object" "${cp_type}"

  # Verify specific fields in client_payload
  local cp_fields
  cp_fields="$(echo "${captured_body}" | python3 -c '
import json, sys
body = json.load(sys.stdin)
cp = body.get("client_payload", {})
for k in ("task_id","repo","commit","task_commit","dev_merge_commit","validation"):
    print(f"field_{k}={cp.get(k, "")!r}")
' 2>/dev/null || true)"
  assert_contains "E2E-04: cp has task_id" "${cp_fields}" "TASK-SMOKE-E2E-FAKE-001"
  assert_contains "E2E-04: cp has repo" "${cp_fields}" "smoke-e2e"
  assert_contains "E2E-04: cp has dev_merge_commit" "${cp_fields}" "789012ef789012ef789012ef789012ef789012ef"

  # Verify payload is ≤ 10 properties (GitHub API limit)
  local cp_prop_count
  cp_prop_count="$(echo "${captured_body}" | python3 -c '
import json, sys
body = json.load(sys.stdin)
cp = body.get("client_payload", {})
print(len(cp))
' 2>/dev/null || echo "0")"
  assert_eq "E2E-04: client_payload ≤ 10 properties" "10" "${cp_prop_count}"

  teardown_sandbox
}

# ============================================================================
# E2E-05: Docs ACK via listener state
# ============================================================================

scenario_docs_ack_listener() {
  echo ""
  echo "=== E2E-05: Docs ACK via listener state ==="
  setup_sandbox
  export CURSOR_WORKER_MODE="approved-submit"

  cd "${SANDBOX}"
  mkdir -p .cursor-worker/review-packets

  # Create the receiver-produced listener state artifact
  cat > .cursor-worker/review-packets/docs-listener-state.json <<ARTIFACT
{
  "reported_task_ids": ["${SYNTHETIC_TASK_ID}"]
}
ARTIFACT

  local ack_result
  ack_result="$(
    cd "${SANDBOX}"
    source "${HARNESS_LIB}" > /dev/null 2>&1
    worker_harness_check_docs_ack "${SYNTHETIC_TASK_ID}" 2>/dev/null
  )"

  assert_eq "E2E-05: ACK confirmed via listener" "confirmed" "${ack_result}"

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# E2E-06: Completion evidence content
# ============================================================================

scenario_completion_evidence() {
  echo ""
  echo "=== E2E-06: Completion evidence content ==="
  setup_sandbox
  export CURSOR_WORKER_MODE="implement-for-review"
  export WORKER_HARNESS_VALIDATION_CMDS="true"

  cd "${SANDBOX}"
  git checkout -b "task/${SYNTHETIC_TASK_ID}"

  # Stage and review gate
  echo "# Evidence test" > evidence.txt
  git add evidence.txt
  source "${HARNESS_LIB}" 2>/dev/null
  worker_harness_init 2>&1
  worker_harness_run_review_gate "evidence e2e" "none" "true" 2>&1

  # Assert review packet has non-empty validation[]
  local packet
  packet="$(cat "${SANDBOX}/.cursor-worker/review-packet.json" 2>/dev/null || true)"
  assert_contains "E2E-06: review packet has validation[n]" "${packet}" '"cmd":'
  assert_contains "E2E-06: review packet has exit_code" "${packet}" '"exit_code":'

  local head rp_sha diff_sha repo_name
  head="$(git rev-parse HEAD)"
  rp_sha="$(python3 -c "import hashlib; print(hashlib.sha256(open('.cursor-worker/review-packet.json','rb').read()).hexdigest())" 2>/dev/null || true)"
  diff_sha="$(python3 -c "import hashlib; print(hashlib.sha256(open('.cursor-worker/latest.diff','rb').read()).hexdigest())" 2>/dev/null || true)"
  repo_name="$(basename "$(git rev-parse --show-toplevel)")"
  create_valid_approval "approval-e2e-06" "${SYNTHETIC_TASK_ID}" "${repo_name}" "task/${SYNTHETIC_TASK_ID}" "${head}" "${rp_sha}" "${diff_sha}"
  export CURSOR_REVIEW_APPROVAL_ID="approval-e2e-06"

  # Commit and merge to dev
  git add -A
  git commit -m "${SYNTHETIC_TASK_ID}: evidence e2e" --no-gpg-sign > /dev/null 2>&1
  local task_commit
  task_commit="$(git rev-parse HEAD)"
  git checkout dev
  git merge "task/${SYNTHETIC_TASK_ID}" --no-edit --no-gpg-sign > /dev/null 2>&1
  local dev_merge_commit
  dev_merge_commit="$(git rev-parse HEAD)"
  local remote_dev_ref="${dev_merge_commit}"

  # Capture completion evidence
  worker_harness_capture_completion_evidence \
    "${task_commit}" "${dev_merge_commit}" "${remote_dev_ref}" \
    '[{"cmd":"true","exit_code":0}]' "dispatch_pending" ""

  local evidence
  evidence="$(cat "${SANDBOX}/.cursor-worker/completion-evidence.json" 2>/dev/null || true)"

  assert_contains "E2E-06: evidence has task_id" "${evidence}" "${SYNTHETIC_TASK_ID}"
  assert_contains "E2E-06: evidence has task_branch_commit" "${evidence}" "${task_commit}"
  assert_contains "E2E-06: evidence has dev_merge_commit" "${evidence}" "${dev_merge_commit}"
  assert_contains "E2E-06: evidence has remote_dev_ref" "${evidence}" "${remote_dev_ref}"
  assert_contains "E2E-06: evidence has dispatch_status" "${evidence}" "dispatch_pending"
  assert_contains "E2E-06: evidence has evidence_version" "${evidence}" "evidence_version"
  assert_contains "E2E-06: evidence has completion_time" "${evidence}" "completion_time"

  cd "${SANDBOX_ORIG_DIR}"
  teardown_sandbox
}

# ============================================================================
# Main
# ============================================================================

echo ""
echo "========================================================================="
echo " Worker E2E Smoke — ${SYNTHETIC_TASK_ID}"
echo "========================================================================="
echo ""

if [[ "${DRY_RUN}" == true ]]; then
  echo "=== DRY-RUN MODE ==="
  echo ""
  echo "The following scenarios are defined and will execute when --no-dry-run is passed:"
  echo ""
  echo "  E2E-01  Dry-run:              verify dry-run prints task info, no artifacts"
  echo "  E2E-02  implement-for-review:  verify review gate produces packet,"
  echo "                                 non-empty validation[], no commit,"
  echo "                                 and validates against review-packet-schema"
  echo "  E2E-03  approved-submit gate:  verify pre-commit PASS with valid approval,"
  echo "                                 reject with allow_commit=false"
  echo "  E2E-04  Dispatch body:         verify cursor-report-dispatch.sh produces"
  echo "                                 correct event_type and client_payload"
  echo "  E2E-05  Docs ACK:              verify listener state ACK mechanism"
  echo "  E2E-06  Completion evidence:   verify evidence JSON has all required fields"
  echo ""
  echo "--- Configuration ---"
  echo "  --dry-run       Print scenarios and exit (default). Safe, no side effects."
  echo "  --no-dry-run    Execute in isolated temp sandbox. No production mutation."
  echo "  --smoke <ids>   Run only specified scenarios (comma-separated)."
  echo ""
  echo "--- Real Dispatch (NOT YET IMPLEMENTED) ---"
  echo "  This is a sandbox-only E2E smoke. --real is a placeholder for a future"
  echo "  task.  No real repository_dispatch or docs ACK is performed."
  echo "  --real is accepted but ignored; it triggers an informational stub."
  echo ""
  echo "=== NO REAL DISPATCH IS PERFORMED ==="
  echo ""
  exit 0
fi

echo "=== Running E2E smoke scenarios in isolated sandbox ==="
echo ""

run_scenario "E2E-01" scenario_dry_run_output
run_scenario "E2E-02" scenario_implement_for_review
run_scenario "E2E-03" scenario_approved_submit_gate
run_scenario "E2E-04" scenario_dispatch_body_validation
run_scenario "E2E-05" scenario_docs_ack_listener
run_scenario "E2E-06" scenario_completion_evidence

# Real dispatch — NOT YET IMPLEMENTED
if [[ "${REAL_DISPATCH}" == true ]]; then
  echo ""
  echo "=== REAL DISPATCH (--real) ==="
  echo "WARNING: --real is accepted but NOT YET IMPLEMENTED."
  echo "This E2E smoke is sandbox-only.  No real repository_dispatch,"
  echo "no real docs ACK, and no real production mutation is performed."
  echo ""
  echo "A future TASK may add the real dispatch pathway."
fi

echo ""
echo "========================================================================="
echo " RESULTS"
echo "========================================================================="
echo " Passed: ${PASS_COUNT}"
echo " Failed: ${FAIL_COUNT}"
if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  echo ""
  echo " FAILURES:"
  printf '%b' "${FAILURES}"
fi
echo "========================================================================="

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  exit 1
fi
exit 0
