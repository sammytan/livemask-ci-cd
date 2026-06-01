#!/usr/bin/env bash
# cleanup-branches.sh — Remove merged task/integration/rescue/recovery branches.
# Run periodically to prevent disk bloat and branch proliferation.
set -euo pipefail

LIVEMASK_ROOT="/Users/sammytan/Developer/LiveMask"
REPOS=("livemask-docs" "livemask-ci-cd" "livemask-backend" "livemask-admin" "livemask-app" "livemask-website" "livemask-nodeagent" "livemask-job-service")
TOTAL_CLEANED=0

for repo in "${REPOS[@]}"; do
  repo_dir="${LIVEMASK_ROOT}/${repo}"
  [[ ! -d "${repo_dir}/.git" ]] && continue

  cd "${repo_dir}"

  # Fetch latest to determine merge status
  git fetch origin dev 2>/dev/null || true

  cleaned=0
  preserved=0

  # Remove merged branches: task/*, integration/*, rescue/*, recovery/*
  for pattern in "task/*" "integration/*" "rescue/*" "recovery/*"; do
    for br in $(git branch --list "${pattern}" --format='%(refname:short)' 2>/dev/null); do
      # Check if merged to dev
      if git merge-base --is-ancestor "${br}" origin/dev 2>/dev/null; then
        git branch -D "${br}" 2>/dev/null && cleaned=$((cleaned + 1)) || true
      else
        # Unmerged branch — check age
        local age_days; age_days=$(git log -1 --format="%ct" "${br}" 2>/dev/null | python3 -c "import sys,time; print(int((time.time()-int(sys.stdin.read().strip()))/86400))" 2>/dev/null || echo "0")
        if [[ "${age_days}" -gt 7 ]]; then
          echo "  [OLD] ${repo}: ${br} (${age_days}d old, unmerged) — preserving"
          preserved=$((preserved + 1))
        fi
      fi
    done
  done

  # Remove remote tracking refs for deleted branches
  git remote prune origin 2>/dev/null || true

  TOTAL_CLEANED=$((TOTAL_CLEANED + cleaned))
  [[ "${cleaned}" -gt 0 || "${preserved}" -gt 0 ]] && echo "  ${repo}: cleaned ${cleaned}, preserved ${preserved} old branches" || true
done

echo "Total branches cleaned: ${TOTAL_CLEANED}"

# Also clean old logs
find /tmp/claude -name "*.log" -mtime +3 -delete 2>/dev/null || true
find /Users/sammytan/.claude/role-cache/alerts -name "*.json" -mtime +1 -delete 2>/dev/null || true
echo "Old logs/alerts cleaned"
