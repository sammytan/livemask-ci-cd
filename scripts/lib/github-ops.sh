#!/usr/bin/env bash
# github-ops.sh — GitHub quick operations for Claude loop.
# Source this library to get fast, structured GitHub operations.
# All functions output JSON for model consumption.
set -euo pipefail

LIVEMASK_ROOT="${LIVEMASK_ROOT:-/Users/sammytan/Developer/LiveMask}"
OWNER="MyAiDevs"
REPOS=("livemask-docs" "livemask-ci-cd" "livemask-backend" "livemask-admin" "livemask-app" "livemask-website" "livemask-nodeagent" "livemask-job-service")

# ── Quick issue operations ─────────────────────────────────────────────

# Create issue with task template
gh_issue_create_task() {
  local repo="$1" title="$2" body="${3:-}" labels="${4:-task,claude}"
  gh issue create \
    --repo "${OWNER}/${repo}" \
    --title "${title}" \
    --body "${body}" \
    --label "${labels}" \
    --json number,title,url,state 2>/dev/null
}

# Get issue with task context (body + recent comments)
gh_issue_get_task_context() {
  local repo="$1" number="$2"
  gh issue view "${number}" --repo "${OWNER}/${repo}" \
    --json number,title,state,url,body,labels,comments,closedAt,updatedAt 2>/dev/null
}

# Quick comment on an issue
gh_issue_comment() {
  local repo="$1" number="$2" body="$3"
  gh issue comment "${number}" --repo "${OWNER}/${repo}" --body "${body}" 2>/dev/null
}

# Reopen issue with evidence-gap comment
gh_issue_reopen_with_evidence() {
  local repo="$1" number="$2" task_id="$3" missing_evidence="${4:-}"
  local body="<!-- livemask-task-review-reopen:${repo}#${number} -->
## Task Review: Reopened — Incomplete Evidence Chain

**Task:** ${task_id}
**Missing Evidence:** ${missing_evidence}

### Required before closing again:
- [ ] Dev merge commit exists and is traceable
- [ ] Task doc Status updated with completion evidence
- [ ] Review contract created and approved
- [ ] CI/CD validation passed
- [ ] GitHub issue references actual implementation commits

This issue was reopened by Claude model reasoning, not by a script regex."

  gh issue reopen "${number}" --repo "${OWNER}/${repo}" 2>/dev/null
  gh issue comment "${number}" --repo "${OWNER}/${repo}" --body "${body}" 2>/dev/null
  echo "{\"action\": \"reopened\", \"repo\": \"${repo}\", \"number\": ${number}, \"task_id\": \"${task_id}\"}"
}

# Close issue with completion evidence
gh_issue_close_with_evidence() {
  local repo="$1" number="$2" task_id="$3" evidence="${4:-}"
  local body="## Task Complete — Evidence Verified

**Task:** ${task_id}
**Verification Method:** Claude model reasoning (not regex)
**Evidence:**
${evidence}

This issue was closed after model-verified completion check."

  gh issue close "${number}" --repo "${OWNER}/${repo}" --reason completed 2>/dev/null
  gh issue comment "${number}" --repo "${OWNER}/${repo}" --body "${body}" 2>/dev/null
  echo "{\"action\": \"closed\", \"repo\": \"${repo}\", \"number\": ${number}, \"task_id\": \"${task_id}\"}"
}

# ── CI operations ──────────────────────────────────────────────────────

# Get latest CI status for a repo
gh_ci_status() {
  local repo="${1:-livemask-docs}"
  gh run list --repo "${OWNER}/${repo}" --limit 3 --json conclusion,status,createdAt,displayTitle,url,headBranch 2>/dev/null
}

# Get CI failure details
gh_ci_failure_details() {
  local repo="$1" run_id="$2"
  gh run view "${run_id}" --repo "${OWNER}/${repo}" --log-failed 2>/dev/null | tail -50
}

# Wait for CI to complete and report status
gh_ci_wait() {
  local repo="$1" branch="${2:-dev}" timeout_sec="${3:-300}"
  local start; start=$(date +%s)
  while true; do
    local status; status=$(gh run list --repo "${OWNER}/${repo}" --branch "${branch}" --limit 1 --json status,conclusion 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['status'] if d else 'unknown')")
    if [[ "${status}" == "completed" ]]; then
      gh run list --repo "${OWNER}/${repo}" --branch "${branch}" --limit 1 --json conclusion,url 2>/dev/null
      return
    fi
    local now; now=$(date +%s)
    if [[ $((now - start)) -gt "${timeout_sec}" ]]; then
      echo "{\"status\": \"timeout\", \"message\": \"CI did not complete within ${timeout_sec}s\"}"
      return 1
    fi
    sleep 15
  done
}

# ── Branch/PR operations ────────────────────────────────────────────────

# Check if a branch has been merged to dev
gh_is_merged_to_dev() {
  local repo="$1" branch="$2"
  local base; base=$(gh api "repos/${OWNER}/${repo}/compare/dev...${branch}" --jq '.status' 2>/dev/null || echo "error")
  if [[ "${base}" == "identical" || "${base}" == "behind" ]]; then
    echo "{\"merged\": true, \"status\": \"${base}\"}"
  else
    echo "{\"merged\": false, \"status\": \"${base}\"}"
  fi
}

# Get task branch refs for a task ID
gh_find_task_branch() {
  local repo="$1" task_id="$2"
  git -C "${LIVEMASK_ROOT}/${repo}" branch -r --list "origin/task/*${task_id}*" --format='%(refname:short)' 2>/dev/null | head -5
}

# ── Bulk operations ─────────────────────────────────────────────────────

# Get all open issues across repos with task labels
gh_all_task_issues() {
  for repo in "${REPOS[@]}"; do
    gh issue list --repo "${OWNER}/${repo}" --label task,claude,codex --state open --limit 10 --json number,title,state,url,repo 2>/dev/null
  done | python3 -c "
import json, sys
all_issues = []
for line in sys.stdin:
    line = line.strip()
    if line:
        try:
            for issue in json.loads(line):
                issue['repo'] = '${repo}' if 'repo' not in issue else issue.get('repo','')
                all_issues.append(issue)
        except: pass
print(json.dumps(all_issues, indent=2))
" 2>/dev/null
}

# Get cross-repo CI status
gh_all_ci_status() {
  echo "["
  local first=true
  for repo in "${REPOS[@]}"; do
    ${first} || echo ","
    first=false
    local status; status=$(gh run list --repo "${OWNER}/${repo}" --limit 1 --json conclusion,status,createdAt 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d[0]) if d else '{}')")
    echo "{\"repo\": \"${repo}\", \"ci\": ${status}}"
  done
  echo "]"
}

# ── Fixed channels (#14, #68) ───────────────────────────────────────────

# Check fixed channel for rule updates
gh_check_fixed_channel() {
  local repo="$1" number="$2"
  local channel_data; channel_data=$(gh issue view "${number}" --repo "${OWNER}/${repo}" \
    --json state,title,updatedAt,comments 2>/dev/null)

  # Extract last 2 comments and check for RULE_UPDATE or ACTION_NEEDED
  echo "${channel_data}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f'channel={repo}#{number}')
print(f'state={d[\"state\"]}')
print(f'updated={d[\"updatedAt\"]}')
comments = d.get('comments', [])[-3:]
actionable = False
for c in comments:
    body = c.get('body', '')
    author = c.get('author', {}).get('login', '?')
    created = c.get('createdAt', '?')
    has_action = any(kw in body for kw in ['RULE_UPDATE','ACTION_NEEDED','RELOAD_REQUIRED','RELOAD_VERIFIED'])
    if has_action:
        actionable = True
        print(f'ACTIONABLE_COMMENT by {author} at {created}: {body[:200]}')
print(f'actionable={actionable}')
" 2>/dev/null
}
