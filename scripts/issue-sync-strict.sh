#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# TASK-CICD-ISSUE-SYNC-STRICT-001
# Strict cross-repo Issue consistency check.
#
# Searches docs repo + runtime repo(s) for a TASK ID and reports whether the
# Issue state is consistent across repositories.
#
# Usage:
#   bash scripts/issue-sync-strict.sh --task-id TASK-XXXX [options]
#
# Required:
#   --task-id TASK-XXXX    The task ID to search for.
#
# Options:
#   --repo REPO            Runtime repo to check (repeatable or comma-separated).
#                          Default: current GitHub repo, or livemask-ci-cd locally.
#   --gh-token TOKEN       GitHub token with issues:read access.
#                          Default: LIVEMASK_BOT_TOKEN, then GITHUB_TOKEN env.
#   --format text|json     Output format (default: text).
#   --docs-required BOOL   Whether a docs Issue is required (default: true).
#   --missing-runtime MODE Runtime missing Issue policy: fail|warn (default: fail).
#   --verbose              Show raw issue data.
#   --help                 Show this help.
#
# Exit codes:
#   0 = PASS  (issue sync is acceptable under configured policy)
#   1 = FAIL  (one or more repos missing or mismatched)
#   2 = AMBIGUOUS (multiple open issues match the same TASK ID)
#   3 = MISSING (no issue found in docs repo)
#
# Example:
#   bash scripts/issue-sync-strict.sh --task-id TASK-CICD-ISSUE-SYNC-STRICT-001
#   bash scripts/issue-sync-strict.sh --task-id TASK-BACKEND-XXX-001 --repo livemask-backend --format json
# =============================================================================

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
ORG="${GITHUB_REPOSITORY_OWNER:-MyAiDevs}"
GH_TOKEN="${LIVEMASK_BOT_TOKEN:-${GITHUB_TOKEN:-}}"

DOCS_REPO="livemask-docs"
ALL_REPOS=(
  "livemask-docs"
  "livemask-backend"
  "livemask-nodeagent"
  "livemask-app"
  "livemask-admin"
  "livemask-website"
  "livemask-job-service"
  "livemask-ci-cd"
)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ============================================================
# Help
# ============================================================
usage() {
  awk '
    /^# =+$/ { block++; next }
    block == 1 && /^#/ { sub(/^# ?/, ""); print }
    block == 2 { exit }
  ' "${BASH_SOURCE[0]}"
  exit 0
}

# ============================================================
# Parse args
# ============================================================
task_id=""
repos_to_check=()
format="text"
verbose=false
docs_required=true
missing_runtime="fail"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id)
      task_id="${2:-}"
      shift 2
      ;;
    --repo)
      repos_to_check+=("${2:-}")
      shift 2
      ;;
    --gh-token)
      GH_TOKEN="${2:-}"
      shift 2
      ;;
    --format)
      format="${2:-text}"
      shift 2
      ;;
    --docs-required)
      docs_required="${2:-true}"
      shift 2
      ;;
    --missing-runtime)
      missing_runtime="${2:-fail}"
      shift 2
      ;;
    --verbose)
      verbose=true
      shift
      ;;
    --help|-h)
      usage
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage
      ;;
  esac
done

# ============================================================
# Validate
# ============================================================
if [[ -z "${task_id}" ]]; then
  echo "ERROR: --task-id is required" >&2
  usage
fi

if [[ ! "${task_id}" =~ ^TASK-[A-Z0-9]+(-[A-Z0-9]+)*(-[A-Za-z0-9_-]+)*$ ]]; then
  echo "ERROR: --task-id must look like TASK-XXXX, got '${task_id}'" >&2
  exit 2
fi

if [[ -z "${GH_TOKEN}" ]]; then
  echo "ERROR: LIVEMASK_BOT_TOKEN, GITHUB_TOKEN, or --gh-token is required for GitHub API access" >&2
  exit 2
fi

if [[ "${format}" != "text" && "${format}" != "json" ]]; then
  echo "ERROR: --format must be text or json, got '${format}'" >&2
  exit 2
fi

if [[ "${docs_required}" != "true" && "${docs_required}" != "false" ]]; then
  echo "ERROR: --docs-required must be true or false, got '${docs_required}'" >&2
  exit 2
fi

if [[ "${missing_runtime}" != "fail" && "${missing_runtime}" != "warn" ]]; then
  echo "ERROR: --missing-runtime must be fail or warn, got '${missing_runtime}'" >&2
  exit 2
fi

# If no --repo given, check the current repo. This avoids turning a repo-local
# CI gate into an all-runtime-repo blocker.
if [[ ${#repos_to_check[@]} -eq 0 ]]; then
  current_repo="${GITHUB_REPOSITORY:-}"
  current_repo="${current_repo##*/}"
  if [[ -z "${current_repo}" || "${current_repo}" == "${GITHUB_REPOSITORY}" || "${current_repo}" == "${DOCS_REPO}" ]]; then
    current_repo="livemask-ci-cd"
  fi
  repos_to_check+=("${current_repo}")
fi

expanded_repos=()
for repo_arg in "${repos_to_check[@]}"; do
  IFS=',' read -r -a split_repos <<< "${repo_arg}"
  for repo in "${split_repos[@]}"; do
    repo="${repo//[[:space:]]/}"
    if [[ -n "${repo}" ]]; then
      expanded_repos+=("${repo}")
    fi
  done
done
repos_to_check=("${expanded_repos[@]}")

for repo in "${repos_to_check[@]}"; do
  known=false
  for known_repo in "${ALL_REPOS[@]}"; do
    if [[ "${repo}" == "${known_repo}" ]]; then
      known=true
      break
    fi
  done
  if [[ "${known}" != "true" || "${repo}" == "${DOCS_REPO}" ]]; then
    echo "ERROR: --repo must be a known runtime repo, got '${repo}'" >&2
    exit 2
  fi
done

# ============================================================
# Helpers
# ============================================================
info()  { echo -e "${CYAN}[${SCRIPT_NAME}]${NC} $*"; }
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

# Search Issues in a given repo for the TASK ID.
# Returns JSON array of matching open issues.
search_repo_issues() {
  local repo="$1"
  local tid="$2"
  local query
  query="repo:${ORG}/${repo} is:issue in:title,body \"${tid}\""
  local encoded_query
  encoded_query="$(python3 -c "import urllib.parse; print(urllib.parse.quote('''${query}'''))")"
  gh_api_get "/search/issues?q=${encoded_query}" 2>/dev/null || echo '{"items":[]}'
}

# Extract issue count from search response.
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

# Extract issue number list.
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

# Extract issue state list.
issue_states() {
  python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    items = data.get('items', [])
    states = [f\"#{i['number']}={i['state']}\" for i in items]
    print(', '.join(states) if states else 'none')
except Exception:
    print('none')
"
}

# Check if the search response indicates ambiguity (>1 open issue).
is_ambiguous() {
  python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    items = data.get('items', [])
    open_items = [i for i in items if i['state'] == 'open']
    if len(open_items) > 1:
        print('true')
    else:
        print('false')
except Exception:
    print('false')
"
}

# ============================================================
# Main check
# ============================================================
JSON_RESULTS='{}'
OVERALL_EXIT=0
DOCS_OK=false

# Always check docs repo first
info "Checking ${DOCS_REPO} for TASK ID: ${task_id}"
docs_response="$(search_repo_issues "${DOCS_REPO}" "${task_id}")"
docs_count="$(echo "${docs_response}" | issue_count)"
docs_ambiguous="$(echo "${docs_response}" | is_ambiguous)"

if [[ "${docs_count}" -eq 0 ]]; then
  if [[ "${docs_required}" == "true" ]]; then
    fail "No Issue found in ${DOCS_REPO} with TASK ID '${task_id}'"
    OVERALL_EXIT=3
  else
    warn "No Issue found in ${DOCS_REPO} with TASK ID '${task_id}' (docs-required=false)"
  fi
fi

if [[ "${docs_ambiguous}" == "true" ]]; then
  warn "Multiple open Issues in ${DOCS_REPO} match TASK ID '${task_id}'"
  OVERALL_EXIT=2
fi

if [[ "${docs_count}" -eq 1 ]]; then
  docs_num="$(echo "${docs_response}" | issue_numbers)"
  pass "${DOCS_REPO}: Issue #${docs_num} found for ${task_id}"
  DOCS_OK=true
elif [[ "${docs_count}" -gt 1 ]]; then
  docs_nums="$(echo "${docs_response}" | issue_numbers)"
  docs_states="$(echo "${docs_response}" | issue_states)"
  warn "${DOCS_REPO}: ${docs_count} issues found (${docs_states})"
  DOCS_OK=true  # docs has at least one issue; runtime check is what matters
fi

if [[ "${verbose}" == "true" ]]; then
  echo "${docs_response}" | python3 -m json.tool 2>/dev/null || echo "${docs_response}"
fi

# Check each runtime repo
RUNNING_RESULTS="{}"
for repo in "${repos_to_check[@]}"; do
  info "Checking ${repo} for TASK ID: ${task_id}"
  response="$(search_repo_issues "${repo}" "${task_id}")"
  count="$(echo "${response}" | issue_count)"
  ambiguous="$(echo "${response}" | is_ambiguous)"
  numbers="$(echo "${response}" | issue_numbers)"
  states="$(echo "${response}" | issue_states)"

  if [[ "${count}" -eq 0 ]]; then
    if [[ "${DOCS_OK}" == "true" ]]; then
      missing_message="${repo}: MISSING (no Issue found for ${task_id}, but exists in ${DOCS_REPO})"
    else
      missing_message="${repo}: MISSING (no Issue found for ${task_id})"
    fi
    if [[ "${missing_runtime}" == "fail" ]]; then
      fail "${missing_message}"
      if [[ "${OVERALL_EXIT}" -eq 0 ]]; then
        OVERALL_EXIT=1
      fi
    else
      warn "${missing_message} (missing-runtime=warn)"
    fi
  elif [[ "${ambiguous}" == "true" ]]; then
    warn "${repo}: AMBIGUOUS — ${count} open Issues match ${task_id} (${states})"
    if [[ "${OVERALL_EXIT}" -eq 0 ]]; then
      OVERALL_EXIT=2
    fi
  else
    pass "${repo}: Issue #${numbers} found for ${task_id}"
  fi

  if [[ "${verbose}" == "true" ]]; then
    echo "${response}" | python3 -m json.tool 2>/dev/null || echo "${response}"
  fi

  # Accumulate structured result
  RUNNING_RESULTS="$(python3 -c "
import json
data = json.loads('''${RUNNING_RESULTS}''')
data['${repo}'] = {
    'count': ${count},
    'issues': '${states}',
    'ambiguous': json.loads('${ambiguous}')
}
print(json.dumps(data))
")"
done

JSON_RESULTS="$(python3 -c "
import json
result = {
    'task_id': '${task_id}',
    'docs_required': json.loads('${docs_required}'),
    'missing_runtime': '${missing_runtime}',
    'docs_repo': {
        'repo': '${DOCS_REPO}',
        'count': ${docs_count},
        'issues': '$(echo "${docs_response}" | issue_states)',
        'ambiguous': json.loads('${docs_ambiguous}')
    },
    'runtime_repos': json.loads('''${RUNNING_RESULTS}'''),
    'overall_exit': ${OVERALL_EXIT}
}
print(json.dumps(result, indent=2))
")"

# Output
if [[ "${format}" == "json" ]]; then
  echo "${JSON_RESULTS}"
else
  echo ""
  echo "========================================"
  if [[ "${OVERALL_EXIT}" -eq 0 ]]; then
    pass "Issue sync consistency check PASS for ${task_id}"
  elif [[ "${OVERALL_EXIT}" -eq 2 ]]; then
    warn "Issue sync consistency check AMBIGUOUS for ${task_id}"
  elif [[ "${OVERALL_EXIT}" -eq 3 ]]; then
    fail "Issue sync consistency check FAIL: docs repo has no matching Issue for ${task_id}"
  else
    fail "Issue sync consistency check FAIL for ${task_id}"
  fi
  echo "========================================"
fi

# Write GitHub Actions output if available
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  # GITHUB_OUTPUT is set; write structured output
  {
    echo "task_id=${task_id}"
    echo "docs_issue_count=${docs_count}"
    echo "overall_exit=${OVERALL_EXIT}"
    echo "result_json<<JSONEOF"
    echo "${JSON_RESULTS}"
    echo "JSONEOF"
  } >> "${GITHUB_OUTPUT}"
fi

exit "${OVERALL_EXIT}"
