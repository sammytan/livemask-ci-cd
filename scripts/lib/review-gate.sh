#!/usr/bin/env bash
# review-gate.sh — Executor → Leader Review → QA → Merge workflow.
#
# Flow:
#   1. executor_submit_review <TASK-ID>  — submit implementation for review
#   2. leader_review <TASK-ID>            — model reviews code, tests, evidence
#   3. qa_verify <TASK-ID>                — QA runs build/test/acceptance checks
#   4. leader_approve <TASK-ID>           — leader approves → merge to dev
#
# Only after leader_approve does the executor merge to dev.
set -euo pipefail

LIVEMASK_ROOT="${LIVEMASK_ROOT:-/Users/sammytan/Developer/LiveMask}"
DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"
REVIEW_DIR="${DOCS_DIR}/docs/development/review-contracts"
AGENT_STATE="${LIVEMASK_ROOT}/.claude/agent-state.json"
MEMORY_DIR="${HOME}/.claude/projects/-Users-sammytan-Developer-LiveMask/memory"

# ── Phase 1: Executor submits for review ─────────────────────────────────
executor_submit_review() {
  local tid="${1:-}"
  [[ -z "${tid}" ]] && { echo "Usage: executor_submit_review <TASK-ID>"; return 1; }

  # Collect evidence
  local repo; repo=$(python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id') == '${tid}':
            print(t.get('repo',''))
            break
" 2>/dev/null || echo "")

  [[ -z "${repo}" ]] && { echo "ERROR: task ${tid} not found in ledger"; return 1; }

  local repo_dir="${LIVEMASK_ROOT}/${repo}"
  local task_branch; task_branch=$(git -C "${repo_dir}" branch --show-current 2>/dev/null || echo "unknown")
  local last_commit; last_commit=$(git -C "${repo_dir}" log --oneline -1 2>/dev/null || echo "unknown")
  local diff_stat; diff_stat=$(git -C "${repo_dir}" diff --stat origin/dev...HEAD 2>/dev/null | tail -1 || echo "no diff")

  echo "=== Executor Review Submission: ${tid} ==="
  echo ""
  echo "  Task:     ${tid}"
  echo "  Repo:     ${repo}"
  echo "  Branch:   ${task_branch}"
  echo "  Commit:   ${last_commit}"
  echo "  Diff:     ${diff_stat}"
  echo ""

  # Run local verification
  echo "--- Local Verification ---"
  source "${CI_CD_DIR}/scripts/lib/local-verify.sh" 2>/dev/null || true
  verify_repo "${repo}" 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(f'  Build/Test: {d[\"passed\"]} passed, {d[\"failed\"]} failed')
for c in d.get('checks',[]):
    print(f'    [{c[\"status\"].upper()}] {c[\"name\"]} ({c[\"duration_sec\"]}s)')
" 2>/dev/null || echo "  Verification: skipped (local-verify not available)"

  # Create review contract
  mkdir -p "${REVIEW_DIR}"
  local review_file="${REVIEW_DIR}/${tid}-review.json"
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  python3 - "${review_file}" "${tid}" "${repo}" "${now}" "${last_commit}" "${diff_stat}" <<'PY'
import json, pathlib, sys, subprocess

review_file = pathlib.Path(sys.argv[1])
tid = sys.argv[2]
repo = sys.argv[3]
now = sys.argv[4]
last_commit = sys.argv[5]
diff_stat = sys.argv[6]

# Check if review contract already exists
existing = {}
if review_file.exists():
    existing = json.loads(review_file.read_text())

# Build review contract
contract = {
    "schema_version": 2,
    "task_id": tid,
    "repo": repo,
    "state": "under_review",
    "next_required_actor": "leader",
    "created_at": existing.get("created_at", now),
    "updated_at": now,
    "rounds": existing.get("rounds", []) + [{
        "round": len(existing.get("rounds", [])) + 1,
        "executor": {
            "submitted_at": now,
            "commit": last_commit,
            "diff_summary": diff_stat,
            "self_review_notes": "See task doc for implementation details and evidence.",
        },
        "leader": {},
        "qa": {},
    }],
}

# Get git diff for leader to review
root = pathlib.Path(f'/Users/sammytan/Developer/LiveMask/{repo}')
try:
    diff = subprocess.run(['git', '-C', str(root), 'diff', 'origin/dev...HEAD'],
                         capture_output=True, text=True, timeout=30)
    contract["rounds"][-1]["executor"]["diff_preview"] = diff.stdout[:5000]
except:
    contract["rounds"][-1]["executor"]["diff_preview"] = "diff unavailable"

review_file.write_text(json.dumps(contract, indent=2, ensure_ascii=False))
print(json.dumps({"status": "submitted", "review_file": str(review_file), "next_actor": "leader"}, indent=2))
PY

  # Update agent state
  if [[ -f "${AGENT_STATE}" ]]; then
    python3 -c "
import json, pathlib
d = json.load(open('${AGENT_STATE}'))
d['phase'] = 'under_review'
d['current_task']['task_phase'] = 'awaiting_leader_review'
d['updated_at'] = '${now}'
pathlib.Path('${AGENT_STATE}').write_text(json.dumps(d, indent=2))
" 2>/dev/null
  fi

  echo ""
  echo "  Review contract: ${review_file}"
  echo "  Next: leader reviews → qa verifies → leader approves → merge"
}

# ── Phase 2: Leader reviews implementation ───────────────────────────────
leader_review() {
  local tid="${1:-}"
  [[ -z "${tid}" ]] && { echo "Usage: leader_review <TASK-ID>"; return 1; }

  local review_file="${REVIEW_DIR}/${tid}-review.json"
  [[ ! -f "${review_file}" ]] && { echo "ERROR: no review contract for ${tid}. Run executor_submit_review first."; return 1; }

  cat << REASONING_PROMPT
=== LEADER CODE REVIEW: ${tid} ===

You are the LEADER reviewer. Your job is to verify the implementation quality
and decide whether it's ready for QA verification. Do NOT just approve blindly.

Review checklist:
1. Read the task doc: docs/development/tasks/${tid}.md
2. Read the diff in the review contract
3. Verify acceptance criteria are met
4. Check for: security issues, missing tests, incomplete features, breaking changes

Decision: APPROVE (ready for QA) or CHANGES_REQUESTED (needs fixes)

If CHANGES_REQUESTED: specify EXACTLY what needs to change.
REASONING_PROMPT

  # Collect evidence for the leader
  echo ""
  echo "=== EVIDENCE BUNDLE ==="
  python3 - "${review_file}" "${tid}" "${DOCS_DIR}" "${LIVEMASK_ROOT}" <<'PY'
import json, pathlib, subprocess, sys

review_file = pathlib.Path(sys.argv[1])
tid = sys.argv[2]
docs = pathlib.Path(sys.argv[3])
root = pathlib.Path(sys.argv[4])

contract = json.loads(review_file.read_text())
last_round = contract["rounds"][-1]
executor = last_round["executor"]

print(f"Review Round: {last_round['round']}")
print(f"Submitted: {executor['submitted_at']}")
print(f"Commit: {executor['commit']}")
print(f"Diff: {executor['diff_summary']}")
print()

# Task doc evidence
task_doc = docs / f"docs/development/tasks/{tid}.md"
if task_doc.exists():
    content = task_doc.read_text()
    # Show status and acceptance criteria
    for line in content.split('\n'):
        if 'Status:' in line or '[' in line and ('PASS' in line or 'FAIL' in line or 'test' in line.lower()):
            print(f"  TASK_DOC: {line.strip()}")
print()

# Ledger state
ledger = json.loads((docs / "docs/development/task-state-ledger.json").read_text())
for m in ledger.get("modules", []):
    for t in m.get("tasks", []):
        if t.get("task_id") == tid:
            print(f"Ledger status: {t.get('status')}")
            print(f"Validation: {t.get('validation', '')[:200]}")
            print(f"Issue: {t.get('issue', '')}")
            break

# Git log for the task
repo = None
for m in ledger.get("modules", []):
    for t in m.get("tasks", []):
        if t.get("task_id") == tid:
            repo = t.get("repo", "")
            break

if repo:
    print(f"\nGit log for {repo}:")
    r = subprocess.run(["git", "-C", str(root / repo), "log", "--oneline", "--grep", tid, "-5"],
                      capture_output=True, text=True, timeout=10)
    print(r.stdout.strip() or "  (no matching commits)")
PY

  echo ""
  echo "=== LEADER DECISION REQUIRED ==="
  echo "Review the evidence above and record your verdict:"
  echo "  leader_approve ${tid}    # Approve → QA verifies → merge"
  echo "  leader_request_changes ${tid} \"<specific changes needed>\"  # Reject → executor fixes"
}

# ── Phase 3: QA verification ────────────────────────────────────────────
qa_verify() {
  local tid="${1:-}"
  [[ -z "${tid}" ]] && { echo "Usage: qa_verify <TASK-ID>"; return 1; }

  local review_file="${REVIEW_DIR}/${tid}-review.json"
  [[ ! -f "${review_file}" ]] && { echo "ERROR: no review contract for ${tid}."; return 1; }

  # Get repo
  local repo; repo=$(python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id') == '${tid}':
            print(t.get('repo',''))
            break
" 2>/dev/null || echo "")

  echo "=== QA VERIFICATION: ${tid} (${repo}) ==="
  echo ""

  # Run full verification
  source "${CI_CD_DIR}/scripts/lib/local-verify.sh" 2>/dev/null || true
  local verify_result; verify_result=$(verify_repo "${repo}" 2>/dev/null || echo "{}")

  # Check acceptance criteria from task doc
  local task_doc="${DOCS_DIR}/docs/development/tasks/${tid}.md"
  local acceptance_met=true
  local acceptance_details=""

  if [[ -f "${task_doc}" ]]; then
    acceptance_details=$(python3 - "${task_doc}" "${verify_result}" <<'PY'
import json, sys, re

task_doc = sys.argv[1]
verify_json = sys.argv[2]

content = open(task_doc).read()
# Find acceptance criteria checkboxes
criteria = re.findall(r'- \[([ x])\] (.+)', content)
checks = []
for checked, desc in criteria:
    checks.append({"checked": checked in ('x', 'X'), "description": desc})

try:
    verify = json.loads(verify_json)
    verify_passed = verify.get("passed", 0)
    verify_failed = verify.get("failed", 0)
except:
    verify_passed = verify_failed = 0

all_checked = all(c["checked"] for c in checks) if checks else False

print(json.dumps({
    "acceptance_criteria_total": len(checks),
    "acceptance_criteria_met": sum(1 for c in checks if c["checked"]),
    "acceptance_criteria_unmet": [c["description"] for c in checks if not c["checked"]],
    "all_checked": all_checked,
    "verify_passed": verify_passed,
    "verify_failed": verify_failed,
}, indent=2))
PY
)
  fi

  echo "${acceptance_details}"

  # Record QA verdict in review contract
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local qa_passed; qa_passed=$(echo "${acceptance_details}" | python3 -c "import json,sys; d=json.load(sys.stdin); print('true' if d.get('all_checked') and d.get('verify_failed',99)==0 else 'false')" 2>/dev/null || echo "false")

  python3 - "${review_file}" "${now}" "${qa_passed}" "${acceptance_details}" <<'PY'
import json, pathlib, sys

review_file = pathlib.Path(sys.argv[1])
now = sys.argv[2]
qa_passed = sys.argv[3] == 'true'
acceptance_details = sys.argv[4]

contract = json.loads(review_file.read_text())
last_round = contract["rounds"][-1]
last_round["qa"] = {
    "verified_at": now,
    "passed": qa_passed,
    "verdict": "QA_PASSED" if qa_passed else "QA_FAILED",
    "details": json.loads(acceptance_details) if acceptance_details else {},
}
contract["updated_at"] = now
review_file.write_text(json.dumps(contract, indent=2, ensure_ascii=False))

print(json.dumps({
    "qa_verdict": "QA_PASSED" if qa_passed else "QA_FAILED",
    "next": "leader_approve" if qa_passed else "executor_fix"
}, indent=2))
PY
}

# ── Phase 4: Leader approves → merge to dev ──────────────────────────────
leader_approve() {
  local tid="${1:-}"
  [[ -z "${tid}" ]] && { echo "Usage: leader_approve <TASK-ID>"; return 1; }

  local review_file="${REVIEW_DIR}/${tid}-review.json"
  [[ ! -f "${review_file}" ]] && { echo "ERROR: no review contract for ${tid}."; return 1; }

  # Check QA passed
  local qa_ok; qa_ok=$(python3 -c "
import json
d = json.load(open('${review_file}'))
last = d['rounds'][-1]
qa = last.get('qa', {})
print('true' if qa.get('passed') else 'false')
" 2>/dev/null || echo "false")

  if [[ "${qa_ok}" != "true" ]]; then
    echo "ERROR: QA has not passed yet. Run qa_verify ${tid} first."
    return 1
  fi

  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Record leader approval
  python3 - "${review_file}" "${now}" <<'PY'
import json, pathlib, sys
review_file = pathlib.Path(sys.argv[1])
now = sys.argv[2]
contract = json.loads(review_file.read_text())
last_round = contract["rounds"][-1]
last_round["leader"] = {
    "reviewed_at": now,
    "verdict": "approved",
    "notes": "Model-verified: code review passed, QA passed, acceptance criteria met."
}
contract["state"] = "approved"
contract["next_required_actor"] = "executor"
contract["updated_at"] = now
review_file.write_text(json.dumps(contract, indent=2, ensure_ascii=False))
print(json.dumps({"leader_verdict": "APPROVED", "next": "executor_merge_to_dev"}, indent=2))
PY

  # Update agent state for merge
  if [[ -f "${AGENT_STATE}" ]]; then
    python3 -c "
import json, pathlib
d = json.load(open('${AGENT_STATE}'))
d['phase'] = 'merging'
d['current_task']['task_phase'] = 'leader_approved_ready_to_merge'
d['updated_at'] = '${now}'
pathlib.Path('${AGENT_STATE}').write_text(json.dumps(d, indent=2))
" 2>/dev/null
  fi

  # Get repo and task branch for merge
  local repo; repo=$(python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id') == '${tid}':
            print(t.get('repo',''))
            break
" 2>/dev/null || echo "")

  echo ""
  echo "=== LEADER APPROVED: ${tid} ==="
  echo ""
  echo "  Task: ${tid}"
  echo "  Repo: ${repo}"
  echo "  Review: APPROVED"
  echo "  QA: PASSED"
  echo ""
  echo "  Executor: merge your task branch to dev now:"
  echo "    cd ${LIVEMASK_ROOT}/${repo}"
  echo "    bash ${CI_CD_DIR}/scripts/dev-merge-guard.sh --repo ${LIVEMASK_ROOT}/${repo} --task-branch <branch> --task-id ${tid} --push"
  echo ""

  # Save decision to memory
  source "${CI_CD_DIR}/scripts/lib/memory-fast.sh" 2>/dev/null || true
  memory_save_decision "${tid}" "LEADER_APPROVED: code review + QA passed, ready to merge" "Model-verified review: diff reviewed, tests passed, acceptance criteria met" 2>/dev/null || true
}

# ── Phase 5: Leader requests changes ─────────────────────────────────────
leader_request_changes() {
  local tid="${1:-}" reason="${2:-No reason provided}"
  [[ -z "${tid}" ]] && { echo "Usage: leader_request_changes <TASK-ID> \"<reason>\""; return 1; }

  local review_file="${REVIEW_DIR}/${tid}-review.json"
  [[ ! -f "${review_file}" ]] && { echo "ERROR: no review contract for ${tid}."; return 1; }

  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  python3 - "${review_file}" "${now}" "${reason}" <<'PY'
import json, pathlib, sys
review_file = pathlib.Path(sys.argv[1])
now = sys.argv[2]
reason = sys.argv[3]
contract = json.loads(review_file.read_text())
last_round = contract["rounds"][-1]
last_round["leader"] = {
    "reviewed_at": now,
    "verdict": "changes_requested",
    "reason": reason,
}
contract["state"] = "changes_requested"
contract["next_required_actor"] = "executor"
contract["updated_at"] = now
review_file.write_text(json.dumps(contract, indent=2, ensure_ascii=False))
print(json.dumps({"leader_verdict": "CHANGES_REQUESTED", "reason": reason, "next": "executor_fix_and_resubmit"}, indent=2))
PY

  # Update agent state
  if [[ -f "${AGENT_STATE}" ]]; then
    python3 -c "
import json, pathlib
d = json.load(open('${AGENT_STATE}'))
d['phase'] = 'revising'
d['current_task']['task_phase'] = 'changes_requested_by_leader'
d['updated_at'] = '${now}'
pathlib.Path('${AGENT_STATE}').write_text(json.dumps(d, indent=2))
" 2>/dev/null
  fi

  echo ""
  echo "  CHANGES REQUESTED: ${reason}"
  echo "  Next: executor fixes issues and re-submits with executor_submit_review ${tid}"
}

# ── Status: Check review state ────────────────────────────────────────────
review_status() {
  local tid="${1:-}"
  if [[ -z "${tid}" ]]; then
    # Show all reviews
    for rf in "${REVIEW_DIR}"/*-review.json; do
      [[ -f "${rf}" ]] || continue
      python3 -c "
import json
d = json.load(open('${rf}'))
print(f'{d[\"task_id\"]}: state={d[\"state\"]} next={d.get(\"next_required_actor\",\"?\")} rounds={len(d.get(\"rounds\",[]))}')
" 2>/dev/null
    done
  else
    local review_file="${REVIEW_DIR}/${tid}-review.json"
    [[ ! -f "${review_file}" ]] && { echo "No review contract for ${tid}"; return 1; }
    python3 -m json.tool "${review_file}" 2>/dev/null
  fi
}
