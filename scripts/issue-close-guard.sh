#!/usr/bin/env bash
# TASK-CICD-ISSUE-CLOSE-GUARD-001 — Guarded Issue Close / Reopen Automation.
#
# Evaluates whether a TASK-ID's Issue may be safely closed or needs reopen,
# based on the governance rules in ISSUE_TASK_SYNC_GOVERNANCE.md.
#
# Decision table:
#   task status          | issue_action           | can child close? | can epic close?
#   ---------------------|------------------------|------------------|-----------------
#   completed            | close_child_issue      | YES              | NO (unless all done)
#   completed_with_skip  | comment_only           | NO               | NO
#   blocked/deferred     | comment_only           | NO               | NO
#   implemented/verified | comment_only           | NO               | NO
#   evidence_missing     | reopen_required        | N/A              | N/A
#
# Dry-run by default. Pass --write to apply close/reopen.

# =============================================================================
# Usage:
#   bash scripts/issue-close-guard.sh --task-id TASK-XXXX [options]
#
# Required:
#   --task-id TASK-XXXX    The task ID to evaluate.
#   --gh-token TOKEN       GitHub token with issues:write (for --write mode).
#
# Options:
#   --ledger FILE          Path to task-state-ledger.json (default: autodetect).
#   --repo REPO            Target repo for the Issue (default: current repo).
#   --dry-run              Show decision without writing (default: true).
#   --write                Apply close/reopen to GitHub Issue.
#   --format text|json     Output format (default: text).
#   --verbose              Show all decision details.
#   --help                 Show this help.
#
# Exit codes:
#   0 = PASS  (decision made, no action needed, or action applied)
#   1 = FAIL  (guard blocked due to insufficient evidence)
#   2 = AMBIGUOUS (multiple issues match, cannot decide)
#   3 = ERROR (missing args, ledger, or API failure)
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ORG="${GITHUB_REPOSITORY_OWNER:-MyAiDevs}"
GH_TOKEN="${LIVEMASK_BOT_TOKEN:-${GITHUB_TOKEN:-}}"

DOCS_REPO="livemask-docs"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================
# Parse args
# ============================================================
task_id=""
ledger_file=""
target_repo=""
format="text"
verbose=false
write_mode=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id)
      task_id="${2:-}"
      shift 2 ;;
    --gh-token)
      GH_TOKEN="${2:-}"
      shift 2 ;;
    --ledger)
      ledger_file="${2:-}"
      shift 2 ;;
    --repo)
      target_repo="${2:-}"
      shift 2 ;;
    --dry-run)
      write_mode=false
      shift ;;
    --write)
      write_mode=true
      shift ;;
    --format)
      format="${2:-text}"
      shift 2 ;;
    --verbose)
      verbose=true
      shift ;;
    --help|-h)
      sed -n '3,/^# =/p' "${BASH_SOURCE[0]}" | sed 's/^# //;s/^#$//'
      exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2; exit 3 ;;
  esac
done

# ============================================================
# Validate
# ============================================================
if [[ -z "${task_id}" ]]; then
  echo "ERROR: --task-id is required" >&2; exit 3
fi

if [[ ! "${task_id}" =~ ^TASK-[A-Z0-9]+ ]]; then
  echo "ERROR: --task-id must look like TASK-XXXX, got '${task_id}'" >&2; exit 3
fi

if [[ -z "${GH_TOKEN}" ]]; then
  echo "ERROR: LIVEMASK_BOT_TOKEN, GITHUB_TOKEN, or --gh-token required" >&2; exit 3
fi

if [[ "${format}" != "text" && "${format}" != "json" ]]; then
  echo "ERROR: --format must be text or json" >&2; exit 3
fi

# Determine target repo
if [[ -z "${target_repo}" ]]; then
  current_repo="${GITHUB_REPOSITORY:-}"
  current_repo="${current_repo##*/}"
  target_repo="${current_repo:-livemask-ci-cd}"
fi

# Autodetect ledger
if [[ -z "${ledger_file}" ]]; then
  candidate="${LIVEMASK_WORKSPACE_ROOT:-$HOME/Developer/LiveMask}/livemask-docs/docs/development/task-state-ledger.json"
  if [[ -f "${candidate}" ]]; then
    ledger_file="${candidate}"
  else
    # Fallback: search adjacent
    for d in "${REPO_ROOT}/../livemask-docs" "${HOME}/Developer/LiveMask/livemask-docs"; do
      if [[ -f "${d}/docs/development/task-state-ledger.json" ]]; then
        ledger_file="${d}/docs/development/task-state-ledger.json"
        break
      fi
    done
  fi
fi

if [[ -z "${ledger_file}" || ! -f "${ledger_file}" ]]; then
  echo "ERROR: task-state-ledger.json not found. Pass --ledger explicitly." >&2; exit 3
fi

# ============================================================
# Helpers
# ============================================================
info()  { echo -e "${CYAN}[guard]${NC} $*"; }
pass()  { echo -e "${GREEN}[PASS]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
fail()  { echo -e "${RED}[FAIL]${NC} $*" >&2; }

gh_api_get() {
  local path="$1"
  curl -sS --fail-with-body \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com${path}"
}

gh_api_patch() {
  local path="$1"; shift
  local data="$1"
  curl -sS --fail-with-body -X PATCH \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "Content-Type: application/json" \
    -d "${data}" \
    "https://api.github.com${path}"
}

gh_api_post() {
  local path="$1"; shift
  local data="$1"
  curl -sS --fail-with-body -X POST \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "Content-Type: application/json" \
    -d "${data}" \
    "https://api.github.com${path}"
}

# Search GitHub Issues for a TASK ID in a given repo
search_task_issues() {
  local repo="$1"
  local tid="$2"
  local query
  query="repo:${ORG}/${repo} is:issue in:title,body \"${tid}\""
  local encoded_query
  encoded_query="$(python3 -c "import urllib.parse; print(urllib.parse.quote('''${query}'''))")"
  gh_api_get "/search/issues?q=${encoded_query}" 2>/dev/null || echo '{"items":[]}'
}

# Extract issue count from search response
issue_count() {
  python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    items = data.get('items', [])
    print(len(items))
except Exception:
    print(0)
"
}

# Extract issue number
issue_numbers() {
  python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    items = data.get('items', [])
    nums = [str(i['number']) for i in items]
    print(', '.join(nums) if nums else 'none')
except Exception:
    print('none')
"
}

# Extract issue state list
issue_states() {
  python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    items = data.get('items', [])
    states = [f'#{i[\"number\"]}={i[\"state\"]}, labels={[l[\"name\"] for l in i.get(\"labels\",[])]}' for i in items]
    print('; '.join(states) if states else 'none')
except Exception:
    print('none')
"
}

# Check if open issues are ambiguous (>1 open)
has_open_ambiguous() {
  python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    items = data.get('items', [])
    open_items = [i for i in items if i['state'] == 'open']
    print('true' if len(open_items) > 1 else 'false')
except Exception:
    print('false')
"
}

# ============================================================
# Phase 1: Read ledger for task status
# ============================================================
info "Target: ${task_id}"
info "Ledger: ${ledger_file}"
info "Repo:   ${target_repo}"
info "Mode:   $(${write_mode} && echo 'WRITE' || echo 'DRY-RUN')"
echo ""

LEDGER_ENTRY=$(python3 -c "
import json, sys
with open('${ledger_file}') as f:
    data = json.load(f)
for mod in data.get('modules', []):
    for t in mod.get('tasks', []):
        if t['task_id'] == '${task_id}':
            print(json.dumps(t))
            sys.exit(0)
print('NOT_FOUND')
sys.exit(1)
" 2>/dev/null || echo "NOT_FOUND")

if [[ "${LEDGER_ENTRY}" == "NOT_FOUND" ]]; then
  fail "Task ${task_id} not found in ledger ${ledger_file}"
  # Check GitHub anyway for existing Issue
  info "Searching GitHub Issues for ${task_id}..."

  DOCS_RESPONSE=$(search_task_issues "${DOCS_REPO}" "${task_id}")
  DOCS_COUNT=$(echo "${DOCS_REPO}" | issue_count)
  if [[ "${DOCS_COUNT}" -eq 0 ]]; then
    fail "No Issue found in ${DOCS_REPO} for ${task_id}. Nothing to close."
    exit 1
  fi
  # Fall through — we can still operate on the GitHub Issue even without ledger
fi

TASK_STATUS=""
TASK_DEV_MERGE=""
TASK_REMOTE_REF=""
TASK_ISSUE=""
TASK_NOTES=""
TASK_BLOCKED_BY=""

if [[ "${LEDGER_ENTRY}" != "NOT_FOUND" ]]; then
  TASK_STATUS=$(echo "${LEDGER_ENTRY}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))")
  TASK_DEV_MERGE=$(echo "${LEDGER_ENTRY}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('dev_merge_commit',''))")
  TASK_REMOTE_REF=$(echo "${LEDGER_ENTRY}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('remote_dev_ref',''))")
  TASK_ISSUE=$(echo "${LEDGER_ENTRY}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('issue',''))")
  TASK_NOTES=$(echo "${LEDGER_ENTRY}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('notes',''))" | head -c 200)
  TASK_BLOCKED_BY=$(echo "${LEDGER_ENTRY}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
b=d.get('blocked_by',[])
print(', '.join(b) if b else 'none')
")

  if [[ "${verbose}" == "true" ]]; then
    info "Ledger status:      ${TASK_STATUS}"
    info "Ledger dev_merge:   ${TASK_DEV_MERGE}"
    info "Ledger remote_ref:  ${TASK_REMOTE_REF}"
    info "Ledger issue:       ${TASK_ISSUE}"
    info "Ledger blocked_by:  ${TASK_BLOCKED_BY}"
    info ""
  fi
fi

# ============================================================
# Phase 2: Search GitHub Issues for this TASK ID
# ============================================================
info "Searching Issues in ${target_repo} for ${task_id}..."
RUNTIME_RESPONSE=$(search_task_issues "${target_repo}" "${task_id}")
RUNTIME_COUNT=$(echo "${RUNTIME_RESPONSE}" | issue_count)
RUNTIME_AMBIGUOUS=$(echo "${RUNTIME_RESPONSE}" | has_open_ambiguous)

if [[ "${verbose}" == "true" ]]; then
  echo "${RUNTIME_RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${RUNTIME_RESPONSE}"
fi

info "Searching Issues in ${DOCS_REPO} for ${task_id}..."
DOCS_RESPONSE=$(search_task_issues "${DOCS_REPO}" "${task_id}")
DOCS_COUNT=$(echo "${DOCS_RESPONSE}" | issue_count)
DOCS_AMBIGUOUS=$(echo "${DOCS_RESPONSE}" | has_open_ambiguous)

TOTAL_OPEN=0
# Compute total open across both repos
python3 -c "
import sys, json
for raw in ['${RUNTIME_RESPONSE}', '${DOCS_RESPONSE}']:
    data = json.loads(raw)
    for i in data.get('items', []):
        if i['state'] == 'open':
            pass
" 2>/dev/null || true
TOTAL_OPEN=$(( $(echo "${RUNTIME_RESPONSE}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(len([i for i in data.get('items', []) if i['state'] == 'open']))
") + $(echo "${DOCS_RESPONSE}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(len([i for i in data.get('items', []) if i['state'] == 'open']))
") ))

RUNTIME_NUMBERS=$(echo "${RUNTIME_RESPONSE}" | issue_numbers)
DOCS_NUMBERS=$(echo "${DOCS_RESPONSE}" | issue_numbers)
RUNTIME_STATES=$(echo "${RUNTIME_RESPONSE}" | issue_states)
DOCS_STATES=$(echo "${DOCS_RESPONSE}" | issue_states)

# ============================================================
# Phase 3: Decision logic
# ============================================================
DECISION="comment_only"
SHOULD_CLOSE=false
SHOULD_REOPEN=false
CLOSE_ISSUES=()
REOPEN_ISSUES=()
DECISION_REASONS=()
BLOCKER_REASONS=()
EPIC_DETECTED=false
CHILD_DETECTED=false

# Detect if this is likely an Epic (from labels or title)
python3 -c "
import sys, json
data = json.load(sys.stdin)
for i in data.get('items', []):
    labels = [l['name'].lower() for l in i.get('labels', [])]
    title = i.get('title', '').lower()
    if 'epic' in labels or 'epic' in title:
        print('true')
        sys.exit(0)
    # Check for Epic in body
    body = i.get('body', '').lower()
    if 'type: epic' in body or 'issue type: epic' in body:
        print('true')
        sys.exit(0)
print('false')
" <<< "${RUNTIME_RESPONSE}" 2>/dev/null && EPIC_DETECTED=true || EPIC_DETECTED=false

# ---------- Decision Table ----------
case "${TASK_STATUS}" in
  completed)
    # Check dev merge evidence
    if [[ -z "${TASK_DEV_MERGE}" && -z "${TASK_REMOTE_REF}" ]]; then
      BLOCKER_REASONS+=("Ledger missing dev_merge_commit and remote_dev_ref")
      DECISION="comment_only"
      SHOULD_CLOSE=false
    else
      DECISION="close_child_issue"
      SHOULD_CLOSE=true
    fi
    ;;
  completed_with_skip)
    DECISION="comment_only"
    BLOCKER_REASONS+=("Status is completed_with_skip; close requires explicit Verification Issue acceptance")
    SHOULD_CLOSE=false
    ;;
  blocked|deferred|cancelled)
    DECISION="comment_only"
    BLOCKER_REASONS+=("Status is ${TASK_STATUS}; not ready for close")
    SHOULD_CLOSE=false
    ;;
  implemented|verified|in_progress|draft|ready)
    DECISION="comment_only"
    BLOCKER_REASONS+=("Status is ${TASK_STATUS}; not completed")
    SHOULD_CLOSE=false
    ;;
  evidence_missing)
    DECISION="reopen_required"
    SHOULD_REOPEN=true
    ;;
  "")
    # No ledger entry — rely on GitHub Issue state
    if [[ "${RUNTIME_COUNT}" -eq 0 ]]; then
      BLOCKER_REASONS+=("No ledger entry and no Issue found in ${target_repo}")
      SHOULD_CLOSE=false
    else
      # Issue exists but no ledger — cannot verify completion, keep open
      BLOCKER_REASONS+=("No ledger entry for ${task_id}; cannot verify completion evidence")
      SHOULD_CLOSE=false
    fi
    ;;
esac

# Epic override: never close epics from a single child task decision
if [[ "${EPIC_DETECTED}" == "true" ]]; then
  if [[ "${DECISION}" == "close_child_issue" ]]; then
    DECISION="comment_only"
    SHOULD_CLOSE=false
    BLOCKER_REASONS+=("Issue detected as Epic; close requires all children done + final smoke PASS")
  fi
fi

# Ambiguity override
if [[ "${RUNTIME_AMBIGUOUS}" == "true" ]]; then
  DECISION="comment_only"
  SHOULD_CLOSE=false
  BLOCKER_REASONS+=("Multiple open Issues in ${target_repo} match ${task_id}; cannot auto-close")
fi

# Reopen trigger check
# Conditions from governance §6.3: contract mismatch, CI/CD FAIL, mock prod path, security fail
if [[ "${SHOULD_CLOSE}" == "false" && "${DECISION}" != "reopen_required" ]]; then
  # Check if any matching Issues are closed but should be reopened based on ledger
  python3 -c "
import sys, json
data = json.load(sys.stdin)
for i in data.get('items', []):
    if i['state'] == 'closed':
        # Check if ledger says evidence_missing or status is not completed
        pass
" <<< "${RUNTIME_RESPONSE}" 2>/dev/null || true
fi

# ============================================================
# Phase 4: Build action items
# ============================================================
if [[ "${SHOULD_CLOSE}" == "true" ]]; then
  # Collect open issues to close
  while IFS= read -r item; do
    if [[ -z "${item}" ]]; then continue; fi
    num=$(echo "${item}" | python3 -c "import sys,json; print(json.load(sys.stdin)['number'])" 2>/dev/null || true)
    state=$(echo "${item}" | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])" 2>/dev/null || true)
    if [[ -n "${num}" && "${state}" == "open" ]]; then
      CLOSE_ISSUES+=("${target_repo}/#${num}")
    fi
  done <<< "$(echo "${RUNTIME_RESPONSE}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for i in data.get('items', []):
    print(json.dumps(i))
")"
  while IFS= read -r item; do
    if [[ -z "${item}" ]]; then continue; fi
    num=$(echo "${item}" | python3 -c "import sys,json; print(json.load(sys.stdin)['number'])" 2>/dev/null || true)
    state=$(echo "${item}" | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])" 2>/dev/null || true)
    if [[ -n "${num}" && "${state}" == "open" ]]; then
      CLOSE_ISSUES+=("${DOCS_REPO}/#${num}")
    fi
  done <<< "$(echo "${DOCS_RESPONSE}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for i in data.get('items', []):
    print(json.dumps(i))
")"
fi

if [[ "${SHOULD_REOPEN}" == "true" ]]; then
  # Collect closed issues to reopen
  while IFS= read -r item; do
    if [[ -z "${item}" ]]; then continue; fi
    num=$(echo "${item}" | python3 -c "import sys,json; print(json.load(sys.stdin)['number'])" 2>/dev/null || true)
    state=$(echo "${item}" | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])" 2>/dev/null || true)
    if [[ -n "${num}" && "${state}" == "closed" ]]; then
      REOPEN_ISSUES+=("${target_repo}/#${num}")
    fi
  done <<< "$(echo "${RUNTIME_RESPONSE}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for i in data.get('items', []):
    print(json.dumps(i))
")"
fi

# ============================================================
# Phase 5: Output & Execute
# ============================================================
# Build structured result
RESULT_JSON=$(python3 -c "
import json
result = {
    'task_id': '${task_id}',
    'target_repo': '${target_repo}',
    'write_mode': ${write_mode},
    'ledger_entry': ${LEDGER_ENTRY:-'null'},
    'decision': '${DECISION}',
    'should_close': ${SHOULD_CLOSE},
    'should_reopen': ${SHOULD_REOPEN},
    'epic_detected': ${EPIC_DETECTED},
    'runtime_issues': {
        'count': ${RUNTIME_COUNT},
        'numbers': '${RUNTIME_NUMBERS}',
        'states': '${RUNTIME_STATES}',
        'ambiguous': ${RUNTIME_AMBIGUOUS}
    },
    'docs_issues': {
        'count': ${DOCS_COUNT},
        'numbers': '${DOCS_NUMBERS}',
        'states': '${DOCS_STATES}',
        'ambiguous': ${DOCS_AMBIGUOUS}
    },
    'close_issues': $(printf '%s\n' "${CLOSE_ISSUES[@]}" | python3 -c "import sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))" 2>/dev/null || echo '[]'),
    'reopen_issues': $(printf '%s\n' "${REOPEN_ISSUES[@]}" | python3 -c "import sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))" 2>/dev/null || echo '[]'),
    'reasons': $(printf '%s\n' "${DECISION_REASONS[@]}" | python3 -c "import sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))" 2>/dev/null || echo '[]'),
    'blockers': $(printf '%s\n' "${BLOCKER_REASONS[@]}" | python3 -c "import sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))" 2>/dev/null || echo '[]')
}
print(json.dumps(result, indent=2))
")

OVERALL_EXIT=0

# Print decision summary
echo ""
echo "============================================"
echo " Issue Close Guard — Decision"
echo "============================================"
echo "  Task:        ${task_id}"
echo "  Repo:        ${target_repo}"
echo "  Epic:        ${EPIC_DETECTED}"
echo "  Status:      ${TASK_STATUS:-no ledger entry}"
echo "  Decision:    ${DECISION}"
echo "  Close:       ${SHOULD_CLOSE}"
echo "  Reopen:      ${SHOULD_REOPEN}"
echo ""

if [[ ${#BLOCKER_REASONS[@]} -gt 0 ]]; then
  echo "  Blockers:"
  for b in "${BLOCKER_REASONS[@]}"; do
    echo "    - ${b}"
  done
  echo ""
fi

if [[ ${#DECISION_REASONS[@]} -gt 0 ]]; then
  echo "  Reasons:"
  for r in "${DECISION_REASONS[@]}"; do
    echo "    - ${r}"
  done
  echo ""
fi

if [[ "${SHOULD_CLOSE}" == "true" ]]; then
  echo "  Issues to close:"
  if [[ ${#CLOSE_ISSUES[@]} -gt 0 ]]; then
    for i in "${CLOSE_ISSUES[@]}"; do
      echo "    - ${i}"
    done
  else
    echo "    (none open)"
  fi
  echo ""
fi

if [[ "${SHOULD_REOPEN}" == "true" ]]; then
  echo "  Issues to reopen:"
  if [[ ${#REOPEN_ISSUES[@]} -gt 0 ]]; then
    for i in "${REOPEN_ISSUES[@]}"; do
      echo "    - ${i}"
    done
  else
    echo "    (none closed)"
  fi
  echo ""
fi

echo "============================================"

# ---------- Execute (write mode only) ----------
if [[ "${write_mode}" == "true" ]]; then
  if [[ "${SHOULD_CLOSE}" == "true" ]]; then
    info "Write mode: closing issues..."

    # Get matching issue numbers from runtime repo
    for item in $(echo "${RUNTIME_RESPONSE}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for i in data.get('items', []):
    if i['state'] == 'open':
        print(i['number'])
" 2>/dev/null); do
      local_repo="${target_repo}"
      info "Closing ${local_repo}/#${item}..."
      close_payload="{\"state\":\"closed\",\"state_reason\":\"completed\"}"
      comment_body="## Task Close Guard\n\n**Task:** ${task_id}\n**Action:** Closed by guarded automation\n**Ledger status:** ${TASK_STATUS}\n**Dev merge:** ${TASK_DEV_MERGE:-not available}\n**Decision:** ${DECISION}"
      comment_payload="{\"body\": $(python3 -c "import json; print(json.dumps('''${comment_body}'''))")}"

      if ! gh_api_patch "/repos/${ORG}/${local_repo}/issues/${item}" "${close_payload}" > /dev/null 2>&1; then
        warn "Failed to close ${local_repo}/#${item}"
        OVERALL_EXIT=1
      else
        pass "Closed ${local_repo}/#${item}"
        # Add close comment
        gh_api_post "/repos/${ORG}/${local_repo}/issues/${item}/comments" "${comment_payload}" > /dev/null 2>&1 || true
      fi
    done

    # Also close docs repo issue
    for item in $(echo "${DOCS_RESPONSE}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for i in data.get('items', []):
    if i['state'] == 'open':
        print(i['number'])
" 2>/dev/null); do
      info "Closing ${DOCS_REPO}/#${item}..."
      close_payload="{\"state\":\"closed\",\"state_reason\":\"completed\"}"
      comment_body="## Task Close Guard\n\n**Task:** ${task_id}\n**Action:** Closed by guarded automation\n**Ledger status:** ${TASK_STATUS}\n**Dev merge:** ${TASK_DEV_MERGE:-not available}\n**Origin:** dev merge guard validated this task is completed."
      comment_payload="{\"body\": $(python3 -c "import json; print(json.dumps('''${comment_body}'''))")}"

      if ! gh_api_patch "/repos/${ORG}/${DOCS_REPO}/issues/${item}" "${close_payload}" > /dev/null 2>&1; then
        warn "Failed to close ${DOCS_REPO}/#${item}"
        OVERALL_EXIT=1
      else
        pass "Closed ${DOCS_REPO}/#${item}"
        gh_api_post "/repos/${ORG}/${DOCS_REPO}/issues/${item}/comments" "${comment_payload}" > /dev/null 2>&1 || true
      fi
    done
  fi

  if [[ "${SHOULD_REOPEN}" == "true" ]]; then
    info "Write mode: reopening issues..."

    for item in $(echo "${RUNTIME_RESPONSE}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for i in data.get('items', []):
    if i['state'] == 'closed':
        print(i['number'])
" 2>/dev/null); do
      local_repo="${target_repo}"
      info "Reopening ${local_repo}/#${item}..."
      reopen_payload="{\"state\":\"open\"}"
      comment_body="## Task Close Guard\n\n**Task:** ${task_id}\n**Action:** Reopened — evidence_missing detected\n**Ledger status:** ${TASK_STATUS}\n**Note:** Downstream contract mismatch or CI/CD FAIL requires re-implementation review."
      comment_payload="{\"body\": $(python3 -c "import json; print(json.dumps('''${comment_body}'''))")}"

      if ! gh_api_patch "/repos/${ORG}/${local_repo}/issues/${item}" "${reopen_payload}" > /dev/null 2>&1; then
        warn "Failed to reopen ${local_repo}/#${item}"
        OVERALL_EXIT=1
      else
        pass "Reopened ${local_repo}/#${item}"
        gh_api_post "/repos/${ORG}/${local_repo}/issues/${item}/comments" "${comment_payload}" > /dev/null 2>&1 || true
      fi
    done
  fi

  if [[ "${SHOULD_CLOSE}" == "false" && "${SHOULD_REOPEN}" == "false" ]]; then
    info "No close/reopen action needed. Skipping write."
  fi
else
  echo ""
  info "DRY-RUN mode (use --write to apply). No issues were modified."
fi

echo ""

# Write GitHub Actions output
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "task_id=${task_id}"
    echo "decision=${DECISION}"
    echo "should_close=${SHOULD_CLOSE}"
    echo "should_reopen=${SHOULD_REOPEN}"
    echo "epic_detected=${EPIC_DETECTED}"
    echo "runtime_issue_count=${RUNTIME_COUNT}"
    echo "docs_issue_count=${DOCS_COUNT}"
    echo "result_json<<JSONEOF"
    echo "${RESULT_JSON}"
    echo "JSONEOF"
  } >> "${GITHUB_OUTPUT}"
fi

# Output JSON if requested
if [[ "${format}" == "json" ]]; then
  echo "${RESULT_JSON}"
fi

exit "${OVERALL_EXIT}"
