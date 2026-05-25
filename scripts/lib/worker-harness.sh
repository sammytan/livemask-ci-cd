#!/usr/bin/env bash
# TASK-CICD-CURSOR-SDK-WORKER-HARDENING-001
#
# Shared Cursor SDK Worker Harness Library
#
# Implements the CURSOR_SDK_WORKER_AUTOMATION_CONTRACT review-gated worker
# pattern.  Any repo-local worker can source this library and call its
# functions.  The harness never commits, merges, or reports completion without
# an explicit Codex approval artifact.
#
# Worker modes (set CURSOR_WORKER_MODE):
#   dry-run               Show planned task/prompt, do nothing.
#   accept-only           Accept task lease, exit without edits.
#   implement-for-review  Run SDK agent, produce review packet, STOP.
#   revise-after-review   Same as implement-for-review for revision rounds.
#   approved-submit       Mechanical commit + guard merge + report dispatch.
#                         Requires CURSOR_REVIEW_APPROVAL_ID.
#
# Key functions:
#   worker_harness_init                    Validate env, resolve mode, print banner.
#   worker_harness_require_mode <mode>     Exit if current mode is not <mode>.
#   worker_harness_run_review_gate         Produce review packet: diff, validation,
#                                          files, secrets, risks.
#   worker_harness_produce_review_packet   Build and write the review packet JSON.
#   worker_harness_check_approval          Validate Codex approval artifact.
#   worker_harness_gate_before_commit      Pre-commit checks (clean worktree, approval).
#   worker_harness_dispatch_and_ack        Dispatch report, wait for docs ACK.
#
# Usage:
#   source "${SCRIPT_DIR}/lib/worker-harness.sh"
#   WORKER_HARNESS_TASK_ID="TASK-FOO-001"
#   worker_harness_init
#   worker_harness_require_mode "implement-for-review"
#   # ... run the SDK agent ...
#   worker_harness_run_review_gate
#   worker_harness_produce_review_packet

set -euo pipefail

# Guard against double-source
if [[ -n "${LIVEMASK_WORKER_HARNESS_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
LIVEMASK_WORKER_HARNESS_SH_LOADED=1

# ============================================================================
# Resolve paths
# ============================================================================

_wh_resolve_helper() {
  # Allow override via env
  if [[ -n "${WORKER_HARNESS_HELPER_PATH:-}" ]]; then
    echo "${WORKER_HARNESS_HELPER_PATH}"
    return
  fi
  # When sourced, try BASH_SOURCE
  if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "${0}" ]]; then
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)"
    if [[ -n "${lib_dir}" && -f "${lib_dir}/worker-harness-helper.py" ]]; then
      echo "${lib_dir}/worker-harness-helper.py"
      return
    fi
  fi
  # Fall back: check common locations
  for d in "${PWD}/scripts/lib" "$(git rev-parse --show-toplevel 2>/dev/null || true)/scripts/lib"; do
    if [[ -n "${d}" && -f "${d}/worker-harness-helper.py" ]]; then
      echo "${d}/worker-harness-helper.py"
      return
    fi
  done
  echo ""
}
_wh_helper="$(_wh_resolve_helper)"

# ============================================================================
# Resolve report dispatch script from repo-local config
# ============================================================================

_wh_resolve_config_dispatch_script() {
  local config_path="${WORKER_HARNESS_CONFIG:-scripts/worker-harness-config.json}"
  local repo_dir repo_name
  repo_dir="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -z "${repo_dir}" ]] && { echo ""; return; }
  repo_name="$(basename "${repo_dir}")"

  # If config_path is already absolute, use it directly
  local config_abs
  if [[ "${config_path:0:1}" == "/" ]]; then
    config_abs="${config_path}"
  else
    config_abs="${repo_dir}/${config_path}"
  fi

  [[ ! -f "${config_abs}" ]] && { echo ""; return; }

  WH_CFG_ABS="${config_abs}" WH_CFG_REPO="${repo_name}" WH_CFG_ROOT="${repo_dir}" \
  python3 -c "
import json, os
try:
    with open(os.environ['WH_CFG_ABS']) as f:
        cfg = json.load(f)
    script = cfg.get('repos', {}).get(os.environ['WH_CFG_REPO'], {}).get('report_dispatch_script', '')
    if script:
        if script.startswith('/'):
            print(script)
        else:
            print(os.path.join(os.environ['WH_CFG_ROOT'], script))
    else:
        print('')
except Exception:
    print('')
" 2>/dev/null || echo ""
}

# ============================================================================
# Configuration with defaults
# ============================================================================

# -- Mode --
CURSOR_WORKER_MODE="${CURSOR_WORKER_MODE:-implement-for-review}"

# -- Task context --
WORKER_HARNESS_TASK_ID="${WORKER_HARNESS_TASK_ID:-}"

# -- Approval artifact (only for approved-submit) --
CURSOR_REVIEW_APPROVAL_ID="${CURSOR_REVIEW_APPROVAL_ID:-}"
WORKER_HARNESS_APPROVAL_FILE="${WORKER_HARNESS_APPROVAL_FILE:-.cursor-worker/approval-artifact.json}"

# -- Report dispatch --
WORKER_HARNESS_REPORT_DISPATCH_SCRIPT="${WORKER_HARNESS_REPORT_DISPATCH_SCRIPT:-}"
WORKER_HARNESS_DOCS_REPO="${WORKER_HARNESS_DOCS_REPO:-MyAiDevs/livemask-docs}"
WORKER_HARNESS_DOCS_REF="${WORKER_HARNESS_DOCS_REF:-dev}"

# -- Paths --
WORKER_HARNESS_CAPTURE_DIR="${WORKER_HARNESS_CAPTURE_DIR:-.cursor-worker/review-packets}"
WORKER_HARNESS_DIFF_FILE="${WORKER_HARNESS_DIFF_FILE:-.cursor-worker/latest.diff}"
WORKER_HARNESS_VALIDATION_LOG="${WORKER_HARNESS_VALIDATION_LOG:-.cursor-worker/validation.log}"
WORKER_HARNESS_PACKET_FILE="${WORKER_HARNESS_PACKET_FILE:-.cursor-worker/review-packet.json}"
WORKER_HARNESS_COMPLETION_ARCHIVE="${WORKER_HARNESS_COMPLETION_ARCHIVE:-.cursor-worker/completion-evidence.json}"

# -- Secret scan patterns --
WORKER_HARNESS_SECRET_PATTERNS="${WORKER_HARNESS_SECRET_PATTERNS:-sk-[a-zA-Z0-9]{20,}|ghp_[a-zA-Z0-9]{36}|gho_[a-zA-Z0-9]{36}|ghu_[a-zA-Z0-9]{36}|ghs_[a-zA-Z0-9]{36}|ghr_[a-zA-Z0-9]{36}}"

# -- Validation --
WORKER_HARNESS_VALIDATION_CMDS="${WORKER_HARNESS_VALIDATION_CMDS:-}"

# -- Timeouts --
WORKER_HARNESS_ACK_POLL_INTERVAL="${WORKER_HARNESS_ACK_POLL_INTERVAL:-10}"
WORKER_HARNESS_ACK_POLL_MAX="${WORKER_HARNESS_ACK_POLL_MAX:-30}"

# -- Exit codes --
WH_EXIT_PASS=0
WH_EXIT_MODE_MISMATCH=40
WH_EXIT_DIRTY=41
WH_EXIT_BRANCH_MISMATCH=42
WH_EXIT_NO_APPROVAL=43
WH_EXIT_VALIDATION_FAILED=44
WH_EXIT_SECRET_DETECTED=45
WH_EXIT_BOUNDARY_VIOLATION=46
WH_EXIT_DOCS_ACK_FAILED=47
WH_EXIT_INTERNAL_ERROR=100

# ============================================================================
# Helpers
# ============================================================================

_wh_log() {
  printf '[worker-harness] %s\n' "$*" >&2
}

_wh_die() {
  local code="$1"
  shift
  _wh_log "STOP: $*"
  exit "${code}"
}

# ============================================================================
# Init
# ============================================================================

worker_harness_init() {
  _wh_log "====== Worker Harness Init ======"
  _wh_log "Mode: ${CURSOR_WORKER_MODE}"
  _wh_log "Task: ${WORKER_HARNESS_TASK_ID}"

  case "${CURSOR_WORKER_MODE}" in
    dry-run|accept-only|implement-for-review|revise-after-review|approved-submit) ;;
    *)
      _wh_die "${WH_EXIT_INTERNAL_ERROR}" "Unknown CURSOR_WORKER_MODE='${CURSOR_WORKER_MODE}'. Valid: dry-run, accept-only, implement-for-review, revise-after-review, approved-submit"
      ;;
  esac

  if [[ -z "${WORKER_HARNESS_TASK_ID}" ]]; then
    _wh_die "${WH_EXIT_INTERNAL_ERROR}" "WORKER_HARNESS_TASK_ID is required"
  fi

  if [[ "${CURSOR_WORKER_MODE}" == "approved-submit" ]]; then
    worker_harness_validate_approval_env
  fi

  _wh_log "Worker harness init complete for ${WORKER_HARNESS_TASK_ID} (mode=${CURSOR_WORKER_MODE})"
}

# ============================================================================
# Mode requirement gate
# ============================================================================

worker_harness_require_mode() {
  local required="$1"
  if [[ "${CURSOR_WORKER_MODE}" != "${required}" ]]; then
    _wh_die "${WH_EXIT_MODE_MISMATCH}" "Current mode is '${CURSOR_WORKER_MODE}', required '${required}'. Stopping."
  fi
}

# ============================================================================
# Branch check
# ============================================================================

worker_harness_check_branch() {
  local expected_branch="${1:-task/${WORKER_HARNESS_TASK_ID}}"
  local current_branch
  current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"

  if [[ "${current_branch}" != "${expected_branch}" ]]; then
    _wh_log "BRANCH MISMATCH: current='${current_branch}', expected='${expected_branch}'"
    return 1
  fi
  _wh_log "Branch check PASS: ${current_branch}"
  return 0
}

# ============================================================================
# Canonical diff capture
# ============================================================================

worker_harness_capture_diff() {
  local diff_path="${WORKER_HARNESS_DIFF_FILE}"
  mkdir -p "$(dirname "${diff_path}")"

  # Canonical diff: staged-only (HEAD-to-index).
  # The approved-submit model requires all changes to be staged before review;
  # unstaged changes are rejected by the pre-commit gate.
  git diff --cached --no-color HEAD > "${diff_path}" 2>/dev/null

  # Compute staged-only stats
  local file_count insert_count delete_count
  file_count="$(git diff --cached --numstat HEAD 2>/dev/null | awk '{fc++} END {print fc+0}')"
  insert_count="$(git diff --cached --numstat HEAD 2>/dev/null | awk '{i+=$1} END {print i+0}')"
  delete_count="$(git diff --cached --numstat HEAD 2>/dev/null | awk '{d+=$2} END {print d+0}')"

  [[ -z "${file_count}" || "${file_count}" == "0" ]] && file_count=0 && insert_count=0 && delete_count=0

  _wh_log "DIFF: ${file_count} files, +${insert_count} / -${delete_count} lines"

  echo "${file_count}"
  echo "${insert_count}"
  echo "${delete_count}"
}

# ============================================================================
# Changed file list and ownership boundary check
# ============================================================================

worker_harness_changed_files() {
  git diff --cached --name-only HEAD 2>/dev/null | sort -u || true
}

worker_harness_check_boundary() {
  local changed_files
  changed_files="$(worker_harness_changed_files | sort -u)"

  local docs_edits=""
  while IFS= read -r f; do
    if [[ -z "${f}" ]]; then
      continue
    fi
    if [[ "${f}" == "../livemask-docs/"* ]] || [[ "${f}" == *"../livemask-docs/"* ]]; then
      docs_edits="${docs_edits} ${f}"
    fi
  done <<< "${changed_files}"

  if [[ -n "${docs_edits}" ]]; then
    _wh_log "BOUNDARY VIOLATION: attempted edits to ../livemask-docs:${docs_edits}"
    return 1
  fi

  _wh_log "Boundary check PASS: no ../livemask-docs edits detected"
  return 0
}

# ============================================================================
# Secret scan
# ============================================================================

worker_harness_secret_scan() {
  local pattern="${WORKER_HARNESS_SECRET_PATTERNS}"

  local changed_files
  changed_files="$(worker_harness_changed_files | sort -u)"

  local found=0
  local findings=""

  while IFS= read -r f; do
    if [[ -z "${f}" ]] || [[ ! -f "${f}" ]]; then
      continue
    fi
    if file "${f}" 2>/dev/null | grep -qi "binary"; then
      continue
    fi
    local matches
    matches="$(grep -inE "${pattern}" "${f}" 2>/dev/null || true)"
    if [[ -n "${matches}" ]]; then
      found=$((found + 1))
      findings="${findings}${f}: $(echo "${matches}" | head -3 | sed 's/\S*sk-[a-zA-Z0-9]\{20,\}/sk-<REDACTED>/g; s/\S*ghp_[a-zA-Z0-9]\{36\}/ghp_<REDACTED>/g' 2>/dev/null || true)\n"
    fi
  done <<< "${changed_files}"

  if [[ "${found}" -gt 0 ]]; then
    _wh_log "SECRET SCAN: ${found} suspicious pattern(s) detected"
    _wh_log "${findings}"
    return 1
  fi
  _wh_log "Secret scan PASS: no suspicious patterns"
  return 0
}

# ============================================================================
# Validation runner
# ============================================================================

worker_harness_run_validation() {
  local commands=("$@")
  if [[ ${#commands[@]} -eq 0 ]]; then
    if [[ -n "${WORKER_HARNESS_VALIDATION_CMDS}" ]]; then
      IFS='|' read -ra commands <<< "${WORKER_HARNESS_VALIDATION_CMDS}"
    else
      commands=("bash -n scripts/*.sh" "git diff --check")
    fi
  fi

  mkdir -p "$(dirname "${WORKER_HARNESS_VALIDATION_LOG}")"
  > "${WORKER_HARNESS_VALIDATION_LOG}"

  local overall_rc=0
  local result_items="["
  local first=true

  local cmd
  for cmd in "${commands[@]}"; do
    if [[ "${first}" == true ]]; then
      first=false
    else
      result_items="${result_items},"
    fi

    _wh_log "Validation: ${cmd}"
    {
      echo "=== command: ${cmd} ==="
      echo "started_at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } >> "${WORKER_HARNESS_VALIDATION_LOG}"

    local stdout rc
    stdout="$(bash -c "${cmd}" 2>&1)" && rc=0 || rc=$?

    {
      echo "${stdout}"
      echo "exit_code: ${rc}"
      echo "finished_at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      echo ""
    } >> "${WORKER_HARNESS_VALIDATION_LOG}"

    local cmd_json
    cmd_json="$(printf '%s' "${cmd}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '"<cmd>"')"
    local stdout_summary
    stdout_summary="$(echo "${stdout}" | head -20 | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '"<captured>"')"

    result_items="${result_items}{\"cmd\":${cmd_json},\"exit_code\":${rc},\"stdout_summary\":${stdout_summary}}"

    if [[ "${rc}" -ne 0 ]]; then
      _wh_log "Validation FAILED: ${cmd} (exit=${rc})"
      overall_rc="${rc}"
    else
      _wh_log "Validation PASS: ${cmd}"
    fi
  done

  result_items="${result_items}]"
  echo "${result_items}"
  return "${overall_rc}"
}

# ============================================================================
# Review packet builder (uses helper Python script)
# ============================================================================

worker_harness_build_review_packet() {
  local validation_json="$1"
  local agent_summary="$2"
  local risks="$3"

  local current_branch expected_branch now_iso
  current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
  expected_branch="task/${WORKER_HARNESS_TASK_ID}"
  now_iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  local branch_match="false"
  local branch_note=""
  if [[ "${current_branch}" == "${expected_branch}" ]]; then
    branch_match="true"
  else
    branch_note="Current branch '${current_branch}' does not match expected '${expected_branch}'"
  fi

  local diff_stat diff_file_count diff_insert diff_delete
  diff_stat="$(worker_harness_capture_diff)"
  diff_file_count="$(echo "${diff_stat}" | sed -n '1p')"
  diff_insert="$(echo "${diff_stat}" | sed -n '2p')"
  diff_delete="$(echo "${diff_stat}" | sed -n '3p')"

  local diff_summary="${diff_file_count:-0} files changed, +${diff_insert:-0}/-${diff_delete:-0}"

  local changed_files_json
  changed_files_json="$(worker_harness_changed_files | python3 -c 'import json,sys; files=[l.strip() for l in sys.stdin if l.strip()]; print(json.dumps(files))' 2>/dev/null || echo '[]')"

  local boundary_result="pass"
  if ! worker_harness_check_boundary 2>/dev/null; then
    boundary_result="violation"
  fi

  local secret_result="pass"
  local secret_count="0"
  if ! worker_harness_secret_scan 2>/dev/null; then
    secret_result="suspicious_patterns_found"
    secret_count="1"
  fi

  # Resolve repo name
  local repo_name
  repo_name="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo 'unknown')")"

  # Call the helper Python script via env vars
  mkdir -p "$(dirname "${WORKER_HARNESS_PACKET_FILE}")"
  PKT_NOW_ISO="${now_iso}" \
  PKT_MODE="${CURSOR_WORKER_MODE}" \
  PKT_TASK_ID="${WORKER_HARNESS_TASK_ID}" \
  PKT_REPO="${repo_name}" \
  PKT_CURRENT_BRANCH="${current_branch}" \
  PKT_EXPECTED_BRANCH="${expected_branch}" \
  PKT_BRANCH_MATCH="${branch_match}" \
  PKT_BRANCH_NOTE="${branch_note}" \
  PKT_DIFF_SUMMARY="${diff_summary}" \
  PKT_DIFF_CAPTURED_PATH="${WORKER_HARNESS_DIFF_FILE}" \
  PKT_DIFF_FILE_COUNT="${diff_file_count:-0}" \
  PKT_DIFF_INSERT="${diff_insert:-0}" \
  PKT_DIFF_DELETE="${diff_delete:-0}" \
  PKT_CHANGED_FILES_JSON="${changed_files_json}" \
  PKT_BOUNDARY_RESULT="${boundary_result}" \
  PKT_SECRET_RESULT="${secret_result}" \
  PKT_SECRET_COUNT="${secret_count:-0}" \
  PKT_VALIDATION_JSON="${validation_json}" \
  PKT_AGENT_SUMMARY="${agent_summary}" \
  PKT_RISKS="${risks}" \
  HARNESS_OUTPUT_FILE="${WORKER_HARNESS_PACKET_FILE}" \
  python3 "${_wh_helper}" build-review-packet

  _wh_log "Review packet written to ${WORKER_HARNESS_PACKET_FILE}"

  # Also archive to capture dir
  mkdir -p "${WORKER_HARNESS_CAPTURE_DIR}"
  local dated_packet="${WORKER_HARNESS_CAPTURE_DIR}/${WORKER_HARNESS_TASK_ID}-${now_iso}.json"
  cp "${WORKER_HARNESS_PACKET_FILE}" "${dated_packet}"
  _wh_log "Review packet also archived at ${dated_packet}"

  # Print the packet to stdout for callers
  cat "${WORKER_HARNESS_PACKET_FILE}"
}

# ============================================================================
# Review gate runner (orchestrator)
# ============================================================================

worker_harness_run_review_gate() {
  local agent_summary="${1:-<no agent summary provided>}"
  local risks="${2:-}"
  shift 2 2>/dev/null || true
  # Remaining "$@" are validation commands, or empty to use defaults.

  _wh_log "====== Review Gate ======"
  _wh_log "Mode: ${CURSOR_WORKER_MODE}"

  case "${CURSOR_WORKER_MODE}" in
    implement-for-review|revise-after-review) ;;
    approved-submit)
      worker_harness_check_approval ""
      return $?
      ;;
    *)
      _wh_die "${WH_EXIT_MODE_MISMATCH}" "Review gate requires mode implement-for-review, revise-after-review, or approved-submit (current: ${CURSOR_WORKER_MODE})"
      ;;
  esac

  # 1. Branch check
  _wh_log "--- Review Gate: Branch Check ---"
  local expected_branch="task/${WORKER_HARNESS_TASK_ID}"
  if ! worker_harness_check_branch "${expected_branch}"; then
    _wh_die "${WH_EXIT_BRANCH_MISMATCH}" "Branch mismatch. Expected '${expected_branch}', got '$(git rev-parse --abbrev-ref HEAD)'"
  fi

  # 2. Diff capture
  _wh_log "--- Review Gate: Diff Capture ---"
  worker_harness_capture_diff

  # 3. Boundary check
  _wh_log "--- Review Gate: Boundary Check ---"
  if ! worker_harness_check_boundary; then
    local docs_files
    docs_files="$(worker_harness_changed_files | grep '../livemask-docs/' || true)"
    _wh_log "BLOCKED: Found edits to ../livemask-docs:"
    _wh_log "${docs_files}"
    _wh_die "${WH_EXIT_BOUNDARY_VIOLATION}" "Boundary violation: runtime repo attempted to edit ../livemask-docs"
  fi

  # 4. Secret scan
  _wh_log "--- Review Gate: Secret Scan ---"
  if ! worker_harness_secret_scan 2>/dev/null; then
    _wh_die "${WH_EXIT_SECRET_DETECTED}" "Secret scan failed: suspicious patterns found. Review before proceeding."
  fi

  # 5. Run validation
  _wh_log "--- Review Gate: Validation ---"
  local validation_result
  validation_result="$(worker_harness_run_validation "$@" || true)"

  # 6. Build review packet
  _wh_log "--- Review Gate: Build Review Packet ---"
  worker_harness_build_review_packet "${validation_result}" "${agent_summary}" "${risks}"

  # 7. Print summary
  _wh_log ""
  _wh_log "=============================================="
  _wh_log "REVIEW PACKET READY FOR CODEX REVIEW"
  _wh_log "Task: ${WORKER_HARNESS_TASK_ID}"
  _wh_log "Mode: ${CURSOR_WORKER_MODE}"
  _wh_log "Packet: ${WORKER_HARNESS_PACKET_FILE}"
  _wh_log ""
  _wh_log "Cursor has NOT committed, NOT merged, NOT dispatched."
  _wh_log "Codex must review the review packet and produce an approval artifact."
  _wh_log "=============================================="
}

# ============================================================================
# Approval artifact validation
# ============================================================================

worker_harness_validate_approval_env() {
  if [[ -z "${CURSOR_REVIEW_APPROVAL_ID}" ]]; then
    _wh_die "${WH_EXIT_NO_APPROVAL}" "CURSOR_REVIEW_APPROVAL_ID is required for approved-submit mode"
  fi
}

worker_harness_check_approval() {
  local expected_task_id="${1:-${WORKER_HARNESS_TASK_ID}}"
  local approval_file="${WORKER_HARNESS_APPROVAL_FILE}"

  _wh_log "--- Approval Gate ---"
  _wh_log "Looking for approval artifact: ${approval_file}"
  _wh_log "Approval ID: ${CURSOR_REVIEW_APPROVAL_ID}"

  if [[ ! -f "${approval_file}" ]]; then
    _wh_die "${WH_EXIT_NO_APPROVAL}" "Approval artifact not found at ${approval_file}. Cannot proceed with approved-submit."
  fi

  # Compute current state for binding comparison
  local current_branch current_head_commit repo_name
  current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
  current_head_commit="$(git rev-parse HEAD 2>/dev/null || echo 'unknown')"
  repo_name="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo 'unknown')")"

  # Recompute sha256 of review packet and diff (if they exist)
  local review_packet_sha256=""
  if [[ -f "${WORKER_HARNESS_PACKET_FILE}" ]]; then
    review_packet_sha256="$(python3 -c "import hashlib; print(hashlib.sha256(open('${WORKER_HARNESS_PACKET_FILE//\'/\\\'}','rb').read()).hexdigest())" 2>/dev/null || true)"
  fi

  local diff_sha256=""
  if [[ -f "${WORKER_HARNESS_DIFF_FILE}" ]]; then
    diff_sha256="$(python3 -c "import hashlib; print(hashlib.sha256(open('${WORKER_HARNESS_DIFF_FILE//\'/\\\'}','rb').read()).hexdigest())" 2>/dev/null || true)"
  fi

  local approval_output
  local approval_rc=0
  approval_output="$(python3 "${_wh_helper}" check-approval \
    "${approval_file}" \
    "${expected_task_id}" \
    "${CURSOR_REVIEW_APPROVAL_ID}" \
    "${current_branch}" \
    "${current_head_commit}" \
    "${repo_name}" \
    "${review_packet_sha256}" \
    "${diff_sha256}" 2>&1)" || approval_rc=$?

  if [[ "${approval_rc}" -ne 0 ]]; then
    _wh_log "APPROVAL REJECTED: ${approval_output}"
    return 1
  fi

  local approved_at
  approved_at="$(python3 "${_wh_helper}" read-approved-at "${approval_file}" 2>/dev/null || echo '')"

  _wh_log "Approval artifact VALID for ${expected_task_id}"
  _wh_log "  Approved at: ${approved_at}"
  _wh_log "  Reviewer: Codex"
  _wh_log "  Head commit: ${current_head_commit}"
  _wh_log "  Review packet SHA256: ${review_packet_sha256}"
  _wh_log "  Diff SHA256: ${diff_sha256}"
  return 0
}

# ============================================================================
# Pre-commit gate (for approved-submit)
# ============================================================================

worker_harness_gate_before_commit() {
  _wh_log "====== Pre-Commit Gate ======"

  if [[ "${CURSOR_WORKER_MODE}" != "approved-submit" ]]; then
    _wh_die "${WH_EXIT_MODE_MISMATCH}" "Pre-commit gate requires approved-submit mode (current: ${CURSOR_WORKER_MODE})"
  fi

  # 1. Check for merge in progress
  if [[ -e "$(git rev-parse --git-path MERGE_HEAD 2>/dev/null || echo /dev/null)" ]]; then
    _wh_die "${WH_EXIT_DIRTY}" "Merge in progress; cannot commit"
  fi

  # 2. Check for dirty submodules — look for Subproject change lines in the diff
  #    This covers both dirty and uninitialized submodule states reliably.
  local submod_changes
  submod_changes="$(git diff --submodule=short HEAD 2>/dev/null | grep -E '^[-+]Subproject' || true)"
  if [[ -n "${submod_changes}" ]]; then
    _wh_log "${submod_changes}"
    _wh_die "${WH_EXIT_DIRTY}" "Dirty submodule(s) detected. Worktree has changed since review. Rejecting."
  fi

  # 3. Reject if there are any unstaged changes (worktree differs from index).
  #    In the staged-only submit model every change must be staged before
  #    review; any unstaged mutation after approval is a rejection.
  #    NOTE: we check `git diff --quiet` (worktree vs index), NOT
  #    `git diff --quiet HEAD` (worktree vs HEAD), because staged changes
  #    legitimately differ from HEAD.
  _wh_log "--- Pre-Commit Gate: Unstaged Check ---"
  if ! git diff --quiet 2>/dev/null; then
    _wh_die "${WH_EXIT_DIRTY}" "Unstaged changes detected. All changes must be staged. Rejecting."
  fi

  # 4. Re-capture diff (staged-only canonical) for binding check
  _wh_log "--- Pre-Commit Gate: Re-capture Diff ---"
  worker_harness_capture_diff

  # 5. Check for untracked files (exclude harness own artifacts in .cursor-worker/)
  local untracked
  untracked="$(git ls-files --others --exclude-standard 2>/dev/null | grep -v '^\.cursor-worker/' || true)"
  if [[ -n "${untracked}" ]]; then
    _wh_log "Untracked files detected:"
    _wh_log "${untracked}"
    _wh_die "${WH_EXIT_DIRTY}" "Untracked files found outside .cursor-worker/. Worktree has changed since review. Rejecting."
  fi

  # 6. Ensure approval artifact exists before doing binding checks
  local approval_file="${WORKER_HARNESS_APPROVAL_FILE}"
  if [[ ! -f "${approval_file}" ]]; then
    _wh_die "${WH_EXIT_NO_APPROVAL}" "Approval artifact not found at ${approval_file}. Cannot proceed with approved-submit."
  fi

  # 7. Compute fresh diff sha256 and compare against artifact
  local current_diff_sha256=""
  local diff_path="${WORKER_HARNESS_DIFF_FILE}"
  if [[ -s "${diff_path}" ]]; then
    current_diff_sha256="$(python3 -c "import hashlib; print(hashlib.sha256(open('${diff_path//\'/\\\'}','rb').read()).hexdigest())" 2>/dev/null || true)"
  fi

  local artifact_diff_sha256=""
  artifact_diff_sha256="$(python3 -c "
import json, sys
try:
    with open('${approval_file//\'/\\\'}') as f:
        print(json.load(f).get('diff_sha256', ''))
except Exception:
    print('')
" 2>/dev/null || true)"

  if [[ -n "${artifact_diff_sha256}" && -n "${current_diff_sha256}" && \
        "${current_diff_sha256}" != "${artifact_diff_sha256}" ]]; then
    _wh_log "DIFF SHA256 MISMATCH: current='${current_diff_sha256}', artifact='${artifact_diff_sha256}'"
    _wh_die "${WH_EXIT_DIRTY}" "Working-tree diff does not match the reviewed/approved diff. Dirty worktree detected. Rejecting."
  fi

  # 8. Full approval binding check (branch, repo, head_commit, review_packet_sha256)
  _wh_log "--- Pre-Commit Gate: Approval Binding Check ---"
  if ! worker_harness_check_approval; then
    _wh_die "${WH_EXIT_NO_APPROVAL}" "Approval validation failed."
  fi

  _wh_log "Pre-commit gate PASS. Worktree matches approved state."
  return 0
}

# ============================================================================
# Report dispatch and docs receiver ACK
# ============================================================================

worker_harness_dispatch_and_ack() {
  _wh_log "====== Report Dispatch and Docs ACK ======"

  local task_id="${WORKER_HARNESS_TASK_ID}"
  local dispatched_at=""

  # Resolve dispatch script: env takes precedence, fall back to config
  local dispatch_script="${WORKER_HARNESS_REPORT_DISPATCH_SCRIPT:-}"
  if [[ -z "${dispatch_script}" ]]; then
    dispatch_script="$(_wh_resolve_config_dispatch_script)"
    if [[ -n "${dispatch_script}" ]]; then
      _wh_log "Report dispatch script resolved from config: ${dispatch_script}"
    fi
  fi

  if [[ -z "${dispatch_script}" ]]; then
    _wh_log "WARN: WORKER_HARNESS_REPORT_DISPATCH_SCRIPT not set and no config entry found. Cannot dispatch."
    _wh_log "Completion evidence dispatch_status will remain dispatch_pending."
    if [[ -f "${WORKER_HARNESS_COMPLETION_ARCHIVE}" ]]; then
      local ce_task_commit ce_dev_merge ce_remote_ref ce_validation
      ce_task_commit="$(python3 -c "import json; d=json.load(open('${WORKER_HARNESS_COMPLETION_ARCHIVE//\'/\\\'}')); print(d.get('task_branch_commit',''))" 2>/dev/null || true)"
      ce_dev_merge="$(python3 -c "import json; d=json.load(open('${WORKER_HARNESS_COMPLETION_ARCHIVE//\'/\\\'}')); print(d.get('dev_merge_commit',''))" 2>/dev/null || true)"
      ce_remote_ref="$(python3 -c "import json; d=json.load(open('${WORKER_HARNESS_COMPLETION_ARCHIVE//\'/\\\'}')); print(d.get('remote_dev_ref',''))" 2>/dev/null || true)"
      ce_validation="$(python3 -c "import json; d=json.load(open('${WORKER_HARNESS_COMPLETION_ARCHIVE//\'/\\\'}')); print(d.get('validation_result',''))" 2>/dev/null || true)"
      worker_harness_capture_completion_evidence \
        "${ce_task_commit}" "${ce_dev_merge}" "${ce_remote_ref}" "${ce_validation}" \
        "dispatch_pending" ""
    fi
    return 1
  fi

  if [[ ! -f "${dispatch_script}" ]]; then
    _wh_log "WARN: Dispatch script not found at ${dispatch_script}"
    _wh_log "Completion evidence dispatch_status will remain dispatch_pending."
    if [[ -f "${WORKER_HARNESS_COMPLETION_ARCHIVE}" ]]; then
      local ce_task_commit ce_dev_merge ce_remote_ref ce_validation
      ce_task_commit="$(python3 -c "import json; d=json.load(open('${WORKER_HARNESS_COMPLETION_ARCHIVE//\'/\\\'}')); print(d.get('task_branch_commit',''))" 2>/dev/null || true)"
      ce_dev_merge="$(python3 -c "import json; d=json.load(open('${WORKER_HARNESS_COMPLETION_ARCHIVE//\'/\\\'}')); print(d.get('dev_merge_commit',''))" 2>/dev/null || true)"
      ce_remote_ref="$(python3 -c "import json; d=json.load(open('${WORKER_HARNESS_COMPLETION_ARCHIVE//\'/\\\'}')); print(d.get('remote_dev_ref',''))" 2>/dev/null || true)"
      ce_validation="$(python3 -c "import json; d=json.load(open('${WORKER_HARNESS_COMPLETION_ARCHIVE//\'/\\\'}')); print(d.get('validation_result',''))" 2>/dev/null || true)"
      worker_harness_capture_completion_evidence \
        "${ce_task_commit}" "${ce_dev_merge}" "${ce_remote_ref}" "${ce_validation}" \
        "dispatch_pending" ""
    fi
    return 1
  fi

  # Read commit info from existing completion evidence
  local task_commit="${TASK_BRANCH_COMMIT:-}"
  local dev_merge_commit="${DEV_MERGE_COMMIT:-}"
  local remote_dev_ref="${REMOTE_DEV_REF:-}"
  local validation_result="${VALIDATION_RESULT:-}"

  if [[ -f "${WORKER_HARNESS_COMPLETION_ARCHIVE}" ]]; then
    task_commit="$(python3 -c "import json; d=json.load(open('${WORKER_HARNESS_COMPLETION_ARCHIVE//\'/\\\'}')); print(d.get('task_branch_commit',''))" 2>/dev/null || true)"
    dev_merge_commit="$(python3 -c "import json; d=json.load(open('${WORKER_HARNESS_COMPLETION_ARCHIVE//\'/\\\'}')); print(d.get('dev_merge_commit',''))" 2>/dev/null || true)"
    remote_dev_ref="$(python3 -c "import json; d=json.load(open('${WORKER_HARNESS_COMPLETION_ARCHIVE//\'/\\\'}')); print(d.get('remote_dev_ref',''))" 2>/dev/null || true)"
    validation_result="$(python3 -c "import json; d=json.load(open('${WORKER_HARNESS_COMPLETION_ARCHIVE//\'/\\\'}')); print(d.get('validation_result',''))" 2>/dev/null || true)"
  fi

  local current_commit current_branch repo_name
  current_commit="$(git rev-parse HEAD 2>/dev/null || echo 'unknown')"
  current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
  repo_name="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo 'unknown')")"

  [[ -z "${task_commit}" ]] && task_commit="${current_commit}"
  [[ -z "${dev_merge_commit}" ]] && dev_merge_commit="${current_commit}"
  [[ -z "${remote_dev_ref}" ]] && remote_dev_ref="${current_commit}"

  local validation_summary
  if [[ -f "${WORKER_HARNESS_VALIDATION_LOG}" ]]; then
    validation_summary="$(head -50 "${WORKER_HARNESS_VALIDATION_LOG}" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '"<from file>"')"
  else
    validation_summary='"no validation log"'
  fi
  [[ -z "${validation_result}" ]] && validation_result="${validation_summary}"

  _wh_log "Dispatching report for ${task_id}..."

  # Build a JSON report object and pipe to dispatch script via --input -
  local dispatch_output
  local dispatch_rc=0
  local dispatch_json
  dispatch_json="$(WH_DISPATCH_TASK_ID="${task_id}" \
    WH_DISPATCH_REPO="${repo_name}" \
    WH_DISPATCH_BRANCH="${current_branch}" \
    WH_DISPATCH_COMMIT="${remote_dev_ref}" \
    WH_DISPATCH_TASK_BRANCH="task/${task_id}" \
    WH_DISPATCH_TASK_COMMIT="${task_commit}" \
    WH_DISPATCH_DEV_MERGE_COMMIT="${dev_merge_commit}" \
    WH_DISPATCH_VALIDATION="${validation_result}" \
    WH_DISPATCH_RESULT="completed" \
    python3 -c '
import json, os
p = {
    "task_id": os.environ.get("WH_DISPATCH_TASK_ID", ""),
    "result": os.environ.get("WH_DISPATCH_RESULT", "completed"),
    "repo": os.environ.get("WH_DISPATCH_REPO", ""),
    "branch": os.environ.get("WH_DISPATCH_BRANCH", ""),
    "commit": os.environ.get("WH_DISPATCH_COMMIT", ""),
    "task_branch": os.environ.get("WH_DISPATCH_TASK_BRANCH", ""),
    "task_commit": os.environ.get("WH_DISPATCH_TASK_COMMIT", ""),
    "dev_merge_commit": os.environ.get("WH_DISPATCH_DEV_MERGE_COMMIT", ""),
    "validation": os.environ.get("WH_DISPATCH_VALIDATION", ""),
}
print(json.dumps(p, ensure_ascii=False))
')" || dispatch_rc=$?

  dispatch_output="$(echo "${dispatch_json}" | bash "${dispatch_script}" --input - 2>&1)" || dispatch_rc=$?
  echo "${dispatch_output}" | while IFS= read -r line; do _wh_log "[dispatch] ${line}"; done

  if [[ "${dispatch_rc}" -ne 0 ]]; then
    _wh_log "Report dispatch FAILED (exit=${dispatch_rc})"
    worker_harness_capture_completion_evidence \
      "${task_commit}" "${dev_merge_commit}" "${remote_dev_ref}" "${validation_result}" \
      "dispatch_failed" ""
    _wh_log "Completion evidence updated: dispatch_status=dispatch_failed"
    return 1
  fi

  dispatched_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  _wh_log "Report dispatched. Waiting for docs receiver acknowledgement..."

  local poll_count=0
  local ack_ok=false

  while [[ "${poll_count}" -lt "${WORKER_HARNESS_ACK_POLL_MAX}" ]]; do
    poll_count=$((poll_count + 1))
    _wh_log "Docs ACK poll ${poll_count}/${WORKER_HARNESS_ACK_POLL_MAX}..."

    local ack_result
    ack_result="$(worker_harness_check_docs_ack "${task_id}" 2>/dev/null || true)"
    if [[ "${ack_result}" == "confirmed" ]]; then
      ack_ok=true
      _wh_log "Docs receiver ACK: confirmed"
      break
    fi

    sleep "${WORKER_HARNESS_ACK_POLL_INTERVAL}"
  done

  if [[ "${ack_ok}" == true ]]; then
    _wh_log "Docs receiver acknowledgement CONFIRMED."
    # Re-capture evidence with report_dispatched=true status
    worker_harness_capture_completion_evidence \
      "${task_commit}" "${dev_merge_commit}" "${remote_dev_ref}" "${validation_result}" \
      "report_dispatched" "${dispatched_at}"
    _wh_log "Completion evidence updated: dispatch_status=report_dispatched"
    return 0
  else
    _wh_log "WARN: Docs receiver acknowledgement not confirmed after ${WORKER_HARNESS_ACK_POLL_MAX} polls."
    _wh_log "Completion evidence dispatch_status will remain dispatch_pending."
    _wh_log "Codex should manually verify docs-side ingestion."
    # Re-capture evidence with dispatch_pending status (sent but ACK pending)
    worker_harness_capture_completion_evidence \
      "${task_commit}" "${dev_merge_commit}" "${remote_dev_ref}" "${validation_result}" \
      "dispatch_pending" "${dispatched_at}"
    _wh_log "Completion evidence updated: dispatch_status=dispatch_pending (ACK not yet confirmed)"
    return 1
  fi
}

# ============================================================================
# Docs receiver ACK check
# ============================================================================

worker_harness_check_docs_ack() {
  local task_id="$1"
  local docs_repo="${WORKER_HARNESS_DOCS_REPO}"
  local docs_ref="${WORKER_HARNESS_DOCS_REF}"

  # Strategy A: Check local docs listener state file (receiver-produced artifact)
  local listener_state="${WORKER_HARNESS_CAPTURE_DIR}/docs-listener-state.json"
  if [[ -f "${listener_state}" ]]; then
    local reported_tasks
    reported_tasks="$(python3 "${_wh_helper}" check-docs-ack-listener "${listener_state}" 2>/dev/null || true)"
    if echo "${reported_tasks}" | grep -qF "${task_id}"; then
      echo "confirmed"
      return 0
    fi
  fi

  # Strategy B: Poll docs repo remote commits for ingestion evidence.
  # Checks up to 30 recent commits on docs/${docs_ref}; if any commit
  # message contains "completion-report: ingest ${task_id}", ACK is
  # confirmed.  This is much more reliable than checking GitHub Actions
  # display_title/head_branch which do not contain the task ID for
  # repository_dispatch events.
  if command -v gh &>/dev/null && [[ -n "${LIVEMASK_BOT_TOKEN:-}" ]]; then
    local ack_script
    ack_script="$(mktemp /tmp/harness-ack-strat-b.XXXXXX.py)"
    cat > "${ack_script}" <<PYSTRATB
import json, os, subprocess, sys

docs_repo = "${docs_repo}"
docs_ref  = "${docs_ref}"
task_id   = "${task_id}"
token     = os.environ.get("LIVEMASK_BOT_TOKEN", "")

env = os.environ.copy()
env["GH_TOKEN"] = token

try:
    result = subprocess.run(
        ["gh", "api", f"repos/{docs_repo}/commits?sha={docs_ref}&per_page=30",
         "--jq", ".[] | .commit.message"],
        capture_output=True, text=True, timeout=15, env=env,
    )
    if result.returncode != 0:
        print("check_failed")
        sys.exit(0)
    for line in result.stdout.strip().split(chr(10)):
        marker = f"completion-report: ingest {task_id}"
        if marker in line:
            print("confirmed")
            sys.exit(0)
    print("pending")
except Exception:
    print("check_failed")
PYSTRATB
    local ack_found
    ack_found="$(python3 "${ack_script}" 2>/dev/null || echo "check_failed")"
    rm -f "${ack_script}"
    if [[ "${ack_found}" == "confirmed" ]]; then
      echo "confirmed"
      return 0
    fi
  fi

  echo "pending"
  return 1
}

# ============================================================================
# Completion evidence capture
# ============================================================================

worker_harness_capture_completion_evidence() {
  local task_branch_commit="$1"
  local dev_merge_commit="$2"
  local remote_dev_ref="$3"
  local validation_result="$4"
  local dispatch_status="${5:-dispatch_pending}"
  local dispatched_at="${6:-}"

  local now_iso
  now_iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  mkdir -p "$(dirname "${WORKER_HARNESS_COMPLETION_ARCHIVE}")"

  WH_NOW_ISO="${now_iso}" \
  WH_TASK_ID="${WORKER_HARNESS_TASK_ID}" \
  WH_MODE="${CURSOR_WORKER_MODE}" \
  WH_TASK_BRANCH_COMMIT="${task_branch_commit}" \
  WH_DEV_MERGE_COMMIT="${dev_merge_commit}" \
  WH_REMOTE_DEV_REF="${remote_dev_ref}" \
  WH_VALIDATION_RESULT="${validation_result}" \
  WH_PACKET_PATH="${WORKER_HARNESS_PACKET_FILE}" \
  WH_APPROVAL_ID="${CURSOR_REVIEW_APPROVAL_ID}" \
  WH_DISPATCH_STATUS="${dispatch_status}" \
  WH_DISPATCHED_AT="${dispatched_at}" \
  HARNESS_OUTPUT_FILE="${WORKER_HARNESS_COMPLETION_ARCHIVE}" \
  python3 "${_wh_helper}" capture-completion-evidence

  _wh_log "Completion evidence captured at ${WORKER_HARNESS_COMPLETION_ARCHIVE}"
}

# ============================================================================
# dry-run helper: print planned task information
# ============================================================================

worker_harness_dry_run() {
  if [[ "${CURSOR_WORKER_MODE}" != "dry-run" ]]; then
    return 0
  fi

  cat <<DRYRUN
=========================================================================
 WORKER DRY-RUN
=========================================================================
 Mode:          dry-run
 Task ID:       ${WORKER_HARNESS_TASK_ID}
 Worktree:      $(git diff --quiet --ignore-submodules 2>/dev/null && echo 'clean' || echo 'DIRTY')
 Current ref:   $(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')

 This is a dry run. No files will be modified, no state written.
 Set CURSOR_WORKER_MODE=accept-only to verify task intake.
 Set CURSOR_WORKER_MODE=implement-for-review to proceed with implementation.
=========================================================================
DRYRUN
  exit "${WH_EXIT_PASS}"
}

# ============================================================================
# Visual status banner
# ============================================================================

worker_harness_print_status() {
  local passing="${1:-}"
  local failing="${2:-}"

  _wh_log ""
  _wh_log "+=============================================+"
  _wh_log "| WORKER STATUS REPORT                        |"
  _wh_log "+=============================================+"
  _wh_log "| Task: ${WORKER_HARNESS_TASK_ID}"
  _wh_log "| Mode: ${CURSOR_WORKER_MODE}"
  _wh_log "| Passing gates: ${passing:-<none>}"
  _wh_log "| Failing gates: ${failing:-<none>}"
  if [[ -f "${WORKER_HARNESS_PACKET_FILE}" ]]; then
    _wh_log "| Review packet: ${WORKER_HARNESS_PACKET_FILE}"
  fi
  _wh_log "| NO COMMIT | NO MERGE | NO REPORT DISPATCH"
  _wh_log "+=============================================+"
  _wh_log ""
}

# shellcheck disable=SC2155,SC2312,SC2207
