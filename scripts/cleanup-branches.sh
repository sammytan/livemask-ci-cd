#!/usr/bin/env bash
set -euo pipefail
LIVEMASK_ROOT="/Users/sammytan/Developer/LiveMask"
TOTAL=0
for repo in livemask-docs livemask-ci-cd livemask-backend livemask-admin livemask-app livemask-website livemask-nodeagent livemask-job-service; do
  d="${LIVEMASK_ROOT}/${repo}"
  [[ ! -d "${d}/.git" ]] && continue
  cd "${d}"
  git fetch origin dev 2>/dev/null || true
  cleaned=0
  for br in $(git branch --list 'task/*' 'integration/*' 'rescue/*' 'recovery/*' --format='%(refname:short)' 2>/dev/null); do
    if git merge-base --is-ancestor "${br}" origin/dev 2>/dev/null; then
      git branch -D "${br}" 2>/dev/null && cleaned=$((cleaned+1)) || true
    fi
  done
  git remote prune origin 2>/dev/null || true
  TOTAL=$((TOTAL+cleaned))
  [[ "${cleaned}" -gt 0 ]] && echo "  ${repo}: cleaned ${cleaned} branches"
done
echo "Total: ${TOTAL} branches cleaned"
find /tmp/claude -name '*.log' -mtime +3 -delete 2>/dev/null || true
