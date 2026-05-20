#!/usr/bin/env bash
set -euo pipefail

# TASK-CICD-DEV-MERGE-GUARD-001
# Apply minimal branch protection for LiveMask dev/main branches.
# Requires a GitHub token with administration rights for the repositories.

OWNER="${OWNER:-MyAiDevs}"
BRANCHES="${BRANCHES:-dev main}"
REPOS="${REPOS:-livemask-docs livemask-backend livemask-admin livemask-app livemask-nodeagent livemask-job-service livemask-ci-cd livemask-website}"
DRY_RUN="${DRY_RUN:-false}"

usage() {
  cat <<'EOF'
Usage:
  OWNER=MyAiDevs BRANCHES="dev main" REPOS="livemask-admin ..." bash scripts/apply-branch-protection.sh

Environment:
  DRY_RUN=true    Print target repos/branches without applying.

Protection applied:
  - disallow force pushes
  - disallow branch deletion
  - keep admins unenforced for dev velocity
  - no required status check names yet; CI can be tightened later once checks are stable
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

command -v gh >/dev/null 2>&1 || {
  echo "ERROR: gh CLI is required" >&2
  exit 2
}

for repo in ${REPOS}; do
  for branch in ${BRANCHES}; do
    echo "[branch-protection] ${OWNER}/${repo}:${branch}"
    if ! gh api --silent "/repos/${OWNER}/${repo}/branches/${branch}" >/dev/null 2>&1; then
      echo "[branch-protection] SKIP ${OWNER}/${repo}:${branch} (branch not found)"
      continue
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
      continue
    fi

    gh api \
      --method PUT \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "/repos/${OWNER}/${repo}/branches/${branch}/protection" \
      --input - <<'JSON'
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": false,
  "lock_branch": false,
  "allow_fork_syncing": true
}
JSON
  done
done

echo "Branch protection apply completed."
