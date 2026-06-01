#!/usr/bin/env bash
# executor-guard.sh — Critical gap fixes for the executor lifecycle.
#
# Fixes the gaps found in full closed-loop audit:
#   1. PM lease renewal during long implementations
#   2. Crash recovery for uncommitted work
#   3. Review timeout monitoring
#   4. QA retry limit enforcement
#   5. Pre-commit verification gate
#   6. Auto-load learned patterns at startup
set -euo pipefail

LIVEMASK_ROOT="${LIVEMASK_ROOT:-/Users/sammytan/Developer/LiveMask}"
DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"
ROLE_CACHE_DIR="${HOME}/.claude/role-cache"
AGENT_STATE="${LIVEMASK_ROOT}/.claude/agent-state.json"
PM_LEASE_FILE="${ROLE_CACHE_DIR}/pm-lease.json"
MEMORY_DIR="${HOME}/.claude/projects/-Users-sammytan-Developer-LiveMask/memory"

# ── Gap Fix 1: PM Lease Renewal ─────────────────────────────────────────
# Call this periodically during long implementations (>10min)
executor_renew_lease() {
  local agent="${1:-claude-executor}"
  local task_id="${2:-}"

  if [[ ! -f "${PM_LEASE_FILE}" ]]; then
    echo "  [LEASE] No existing lease — acquiring new one"
    python3 -c "
import json, time, pathlib
d = {
    'agent': '${agent}',
    'started_at': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'started_at_epoch': time.time(),
    'phase': 'implementing',
    'docs_head': '$(git -C "${DOCS_DIR}" rev-parse HEAD 2>/dev/null || echo "?")',
    'note': 'Executor lease — Codex must skip reconciliation',
}
pathlib.Path('${PM_LEASE_FILE}').write_text(json.dumps(d, indent=2))
" 2>/dev/null
    echo "  [LEASE] PM lock acquired by ${agent}"
    return 0
  fi

  # Renew existing lease
  local holder age_min
  read -r holder age_min <<< "$(python3 -c "
import json, time
d = json.load(open('${PM_LEASE_FILE}'))
age = (time.time() - d.get('started_at_epoch', 0)) / 60
print(d.get('agent', '?'), f'{age:.0f}')
" 2>/dev/null || echo "? 999")"

  if [[ "${holder}" != "${agent}" ]]; then
    echo "  [LEASE] WARNING: lease held by '${holder}' (${age_min}min) — cannot renew"
    return 1
  fi

  # Update lease timestamp (renew)
  python3 -c "
import json, time, pathlib
d = json.load(open('${PM_LEASE_FILE}'))
d['started_at_epoch'] = time.time()
d['started_at'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
d['renewed_count'] = d.get('renewed_count', 0) + 1
d['note'] = 'Executor lease renewed — Codex must skip reconciliation'
pathlib.Path('${PM_LEASE_FILE}').write_text(json.dumps(d, indent=2))
" 2>/dev/null
  echo "  [LEASE] PM lease renewed by ${agent} (renewal #$(python3 -c "import json; print(json.load(open('${PM_LEASE_FILE}')).get('renewed_count',0))" 2>/dev/null || echo "?"))"
}

# ── Gap Fix 2: Crash Recovery ───────────────────────────────────────────
# Called by startup when it detects stale implementing phase
executor_crash_recovery() {
  echo "=== EXECUTOR CRASH RECOVERY ==="
  echo ""

  # Check agent state
  if [[ ! -f "${AGENT_STATE}" ]]; then
    echo "  No agent state — nothing to recover"
    return 0
  fi

  local phase task_id repo
  read -r phase task_id repo <<< "$(python3 -c "
import json
d = json.load(open('${AGENT_STATE}'))
t = d.get('current_task') or {}
print(d.get('phase','?'), t.get('task_id',''), t.get('target_repo',''))
" 2>/dev/null || echo "?  ")"

  if [[ "${phase}" != "implementing" && "${phase}" != "under_review" ]]; then
    echo "  Phase is '${phase}' — no crash recovery needed"
    return 0
  fi

  echo "  Detected crashed executor: phase=${phase} task=${task_id} repo=${repo}"

  # Check for uncommitted changes in target repo
  if [[ -n "${repo}" && -d "${LIVEMASK_ROOT}/${repo}" ]]; then
    local repo_dir="${LIVEMASK_ROOT}/${repo}"
    local dirty; dirty=$(git -C "${repo_dir}" status --porcelain 2>/dev/null | wc -l | tr -d ' ' || echo "0")

    if [[ "${dirty}" -gt 0 ]]; then
      echo "  Found ${dirty} uncommitted files in ${repo} — saving to recovery branch"
      local recovery_br="recovery/crash-${task_id}-$(date -u +%Y%m%d-%H%M%S)"

      cd "${repo_dir}"
      git stash -m "crash-recovery: ${task_id} $(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null || true
      git checkout -b "${recovery_br}" 2>/dev/null || true
      git stash pop 2>/dev/null || true

      if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        git add -A 2>/dev/null
        git commit -m "recovery: auto-save crashed executor work for ${task_id}

Co-Authored-By: Claude Executor Guard <noreply@anthropic.com>" 2>/dev/null || true
        git push origin "${recovery_br}" 2>/dev/null || true
        echo "  Recovery branch pushed: ${recovery_br}"
      fi

      git checkout dev 2>/dev/null || true
      cd "${LIVEMASK_ROOT}" 2>/dev/null || true
    else
      echo "  No uncommitted changes — nothing to recover"
    fi
  fi

  # Reset agent state
  python3 -c "
import json, pathlib
d = json.load(open('${AGENT_STATE}'))
d['phase'] = 'idle'
d['current_task'] = {}
d['last_action'] = 'crash_recovery'
d['updated_at'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
d['crash_recovery_note'] = 'Executor crashed during ${phase} for ${task_id}. Recovery branch created if there were uncommitted changes.'
pathlib.Path('${AGENT_STATE}').write_text(json.dumps(d, indent=2))
" 2>/dev/null

  # Release PM lease
  if [[ -f "${PM_LEASE_FILE}" ]]; then
    python3 -c "
import json, pathlib
d = json.load(open('${PM_LEASE_FILE}'))
d['phase'] = 'stale-auto-released'
d['note'] = 'Auto-released by crash recovery'
pathlib.Path('${PM_LEASE_FILE}').write_text(json.dumps(d, indent=2))
" 2>/dev/null
    echo "  PM lease released"
  fi

  echo "  Crash recovery complete — agent reset to idle"
}

# ── Gap Fix 3: Review Timeout Monitor ────────────────────────────────────
executor_check_review_timeout() {
  python3 - "${DOCS_DIR}" "${AGENT_STATE}" <<'PY'
import json, pathlib, time, sys

docs = pathlib.Path(sys.argv[1])
agent_file = pathlib.Path(sys.argv[2])
now = time.time()

review_dir = docs / "docs/development/review-contracts"
if not review_dir.exists():
    print(json.dumps({"status": "no_reviews"}))
    sys.exit(0)

timeouts = []
for rf in sorted(review_dir.glob("*-review.json")):
    d = json.loads(rf.read_text())
    state = d.get("state", "")
    if state in ("under_review", "changes_requested"):
        # Check age
        updated = d.get("updated_at", "")
        if updated:
            try:
                from datetime import datetime
                dt = datetime.fromisoformat(updated.replace("Z", "+00:00"))
                age_min = (now - dt.timestamp()) / 60
                if age_min > 30 and state == "under_review":
                    timeouts.append({
                        "task_id": d.get("task_id", ""),
                        "state": state,
                        "age_min": round(age_min),
                        "action": "REVIEW_TIMEOUT — escalate to human or auto-approve if trivial",
                    })
                elif age_min > 60 and state == "changes_requested":
                    timeouts.append({
                        "task_id": d.get("task_id", ""),
                        "state": state,
                        "age_min": round(age_min),
                        "action": "CHANGES_REQUESTED_TIMEOUT — executor may have abandoned. Reset to ready.",
                    })
            except: pass

if timeouts:
    print(json.dumps({"status": "timeouts_found", "timeouts": timeouts}, indent=2))
else:
    print(json.dumps({"status": "all_reviews_fresh"}))
PY
}

# ── Gap Fix 4: QA Retry Limit ────────────────────────────────────────────
executor_check_qa_retries() {
  local tid="${1:-}"
  python3 - "${DOCS_DIR}" "${tid}" <<'PY'
import json, pathlib, sys

docs = pathlib.Path(sys.argv[1])
tid = sys.argv[2] if len(sys.argv) > 2 else ""

review_dir = docs / "docs/development/review-contracts"
if not review_dir.exists():
    sys.exit(0)

for rf in sorted(review_dir.glob("*-review.json")):
    d = json.loads(rf.read_text())
    if tid and d.get("task_id") != tid: continue

    # Count QA failures
    qa_failures = 0
    for rnd in d.get("rounds", []):
        qa = rnd.get("qa", {})
        if qa.get("verdict") == "QA_FAILED":
            qa_failures += 1

    if qa_failures >= 3:
        print(json.dumps({
            "task_id": d.get("task_id", ""),
            "qa_failures": qa_failures,
            "action": "QA_RETRY_LIMIT_EXCEEDED — escalate to human. Do not allow more re-submits.",
        }, indent=2))
    elif qa_failures > 0:
        print(json.dumps({
            "task_id": d.get("task_id", ""),
            "qa_failures": qa_failures,
            "remaining_retries": 3 - qa_failures,
        }, indent=2))
PY
}

# ── Gap Fix 5: Pre-Commit Verification Gate ──────────────────────────────
executor_pre_commit_verify() {
  local repo="${1:-}"
  [[ -z "${repo}" ]] && { echo "Usage: executor_pre_commit_verify <repo>"; return 1; }

  echo "=== PRE-COMMIT VERIFICATION: ${repo} ==="
  echo ""

  local repo_dir="${LIVEMASK_ROOT}/${repo}"
  cd "${repo_dir}" 2>/dev/null || { echo "ERROR: repo not found"; return 1; }

  local failures=0

  # 1. Git diff check
  echo "--- git diff --check ---"
  if git diff --check 2>&1 | head -5; then
    echo "  PASS"
  else
    echo "  FAIL — fix whitespace errors before commit"
    failures=$((failures + 1))
  fi

  # 2. Repo-specific checks
  case "${repo}" in
    livemask-docs)
      echo "--- check-docs.sh ---"
      bash scripts/check-docs.sh 2>&1 | tail -3
      [[ ${PIPESTATUS[0]} -eq 0 ]] || failures=$((failures + 1))
      ;;
    livemask-ci-cd)
      echo "--- bash syntax ---"
      find scripts -name "*.sh" -exec bash -n {} \; 2>&1 | head -5
      [[ ${PIPESTATUS[0]} -eq 0 ]] || failures=$((failures + 1))
      ;;
    livemask-backend)
      echo "--- go build ---"
      go build ./... 2>&1 | tail -3
      [[ ${PIPESTATUS[0]} -eq 0 ]] || failures=$((failures + 1))
      echo "--- go vet ---"
      go vet ./... 2>&1 | tail -3
      [[ ${PIPESTATUS[0]} -eq 0 ]] || failures=$((failures + 1))
      ;;
    livemask-admin)
      echo "--- npm run build ---"
      npm run build 2>&1 | tail -3
      [[ ${PIPESTATUS[0]} -eq 0 ]] || failures=$((failures + 1))
      ;;
    *)
      echo "--- no specific checks for ${repo} ---"
      ;;
  esac

  cd "${LIVEMASK_ROOT}" 2>/dev/null || true

  if [[ "${failures}" -gt 0 ]]; then
    echo ""
    echo "  VERIFICATION FAILED (${failures} checks failed)"
    echo "  Fix the issues above before committing."
    return 1
  else
    echo ""
    echo "  VERIFICATION PASSED — safe to commit"
    return 0
  fi
}

# ── Gap Fix 6: Auto-Load Learned Patterns ────────────────────────────────
executor_load_learnings() {
  local task_id="${1:-}"
  echo "=== LOADED LEARNINGS ==="
  echo ""

  # Load patterns from memory
  if [[ -d "${MEMORY_DIR}" ]]; then
    echo "--- Learned patterns ---"
    grep -rl "type: feedback" "${MEMORY_DIR}" --include="*.md" 2>/dev/null | while read f; do
      local name; name=$(basename "${f}" .md)
      local desc; desc=$(grep "description:" "${f}" 2>/dev/null | head -1 | sed 's/.*description: *//')
      echo "  ${name}: ${desc:-no description}"
    done | head -10

    # Search for task-specific learnings
    if [[ -n "${task_id}" ]]; then
      echo ""
      echo "--- Task-specific learnings for ${task_id} ---"
      grep -rl "${task_id}" "${MEMORY_DIR}" --include="*.md" 2>/dev/null | while read f; do
        echo "  $(basename "${f}" .md)"
      done | head -5
    fi
  fi

  # Load executor guidance from monitor
  local guidance_file="${ROLE_CACHE_DIR}/learned/executor-guidance.json"
  if [[ -f "${guidance_file}" ]]; then
    echo ""
    echo "--- Active executor tips ---"
    python3 -c "
import json
d = json.load(open('${guidance_file}'))
for tip in d.get('active_tips', [])[-5:]:
    print(f'  TIP: {tip[\"tip\"][:150]}')
" 2>/dev/null
  fi

  # Load velocity stats
  local patterns_file="${ROLE_CACHE_DIR}/learned/patterns.json"
  if [[ -f "${patterns_file}" ]]; then
    echo ""
    echo "--- System velocity ---"
    python3 -c "
import json
d = json.load(open('${patterns_file}'))
v = d.get('velocity_stats', {})
print(f'  Tasks: {v.get(\"total\",\"?\")} total, {v.get(\"completed\",\"?\")} completed ({v.get(\"completion_rate\",\"?\")})')
print(f'  In progress: {v.get(\"in_progress\",\"?\")}, Ready: {v.get(\"ready\",\"?\")}, Blocked: {v.get(\"blocked\",\"?\")}')
" 2>/dev/null
  fi
}

# ── Full executor cycle guard ────────────────────────────────────────────
executor_full_guard() {
  local task_id="${1:-}" repo="${2:-}"

  echo "=== EXECUTOR GUARD ==="
  echo ""

  # 1. Load learnings
  executor_load_learnings "${task_id}"

  echo ""

  # 2. Renew lease (prevent Codex takeover during long implementations)
  executor_renew_lease "claude-executor" "${task_id}"

  echo ""

  # 3. Check review timeouts
  executor_check_review_timeout 2>/dev/null || true

  echo ""

  # 4. Check QA retries
  executor_check_qa_retries "${task_id}" 2>/dev/null || true

  echo ""

  # 5. Pre-commit verify (if repo provided)
  if [[ -n "${repo}" ]]; then
    executor_pre_commit_verify "${repo}" || echo "  (verification skipped or failed)"
  fi
}
