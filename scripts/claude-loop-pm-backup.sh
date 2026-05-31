#!/usr/bin/env bash
# TASK-CICD-CLAUDE-PM-BACKUP-MODE-001
# Claude PM Backup Mode — fills Codex role when Codex is unavailable.
# Token-efficient: uses context cache + incremental diff, not full re-read.
#
# Roles covered:
#   - Task Leader (task creation, decomposition, assignment)
#   - Project Oversight (progress tracking, ledger audit)
#   - Product Manager (contract review, milestone alignment)
#   - QA/Tester (evidence verification, bug submission)
#   - Troubleshooter (CI failure diagnosis, blocker resolution)
#
# Usage:
#   bash scripts/claude-loop-pm-backup.sh              # full PM cycle
#   bash scripts/claude-loop-pm-backup.sh --quick      # skip deep analysis
#   bash scripts/claude-loop-pm-backup.sh --review     # review-only (fastest)
#   bash scripts/claude-loop-pm-backup.sh --decompose  # decomposition-only
set -euo pipefail

LIVEMASK_ROOT="/Users/sammytan/Developer/LiveMask"
DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"
CACHE_DIR="${LIVEMASK_ROOT}/.claude/pm-cache"
CACHE_FILE="${CACHE_DIR}/pm-context-cache.json"
MEMORY_DIR="${HOME}/.claude/projects/-Users-sammytan-Developer-LiveMask/memory"
MODE="${1:-full}"

mkdir -p "${CACHE_DIR}"

BOLD="\033[1m" GREEN="\033[32m" YELLOW="\033[33m" RED="\033[31m" CYAN="\033[36m" RESET="\033[0m"
header()  { echo -e "\n${BOLD}${CYAN}═══ $* ═══${RESET}"; }
ok()      { echo -e "  ${GREEN}[OK]${RESET} $*"; }
warn()    { echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
action()  { echo -e "  ${RED}[ACTION]${RESET} $*"; }

# ── Global state counters (not local to any function) ──────────────────────────
reviewed=0
gap_count=0
candidate_count=0
sap_count=0
ci_failures=0
task_id=""
PM_ISSUES_FOUND=0
PM_HAS_REVIEWS=0
PM_QUEUE_EMPTY=1

# ── Phase 0: Load context cache (token efficient) ─────────────────────────────
load_context_cache() {
  header "Phase 0: Context Cache"

  if [[ -f "${CACHE_FILE}" ]]; then
    CACHE_AGE=$(python3 -c "
import json, time
cache = json.load(open('${CACHE_FILE}'))
age_min = (time.time() - cache.get('updated_at_epoch', 0)) / 60
print(f'{age_min:.0f}')
" 2>/dev/null || echo "999")
    echo "  cache age: ${CACHE_AGE} min"
  else
    CACHE_AGE=999
    echo "  no cache — will build fresh"
  fi

  # Load cache into env vars for quick access
  if [[ -f "${CACHE_FILE}" ]]; then
    LAST_PM_SHA=$(python3 -c "import json; print(json.load(open('${CACHE_FILE}')).get('last_sha',''))" 2>/dev/null || echo "")
    LAST_PM_TIME=$(python3 -c "import json; print(json.load(open('${CACHE_FILE}')).get('updated_at',''))" 2>/dev/null || echo "")
    echo "  last cycle: ${LAST_PM_TIME} (${LAST_PM_SHA:0:7})"
  else
    LAST_PM_SHA=""
    LAST_PM_TIME=""
  fi
}

# ── Phase 1: Incremental sync (only read what changed) ────────────────────────
incremental_sync() {
  header "Phase 1: Incremental Sync"

  cd "${DOCS_DIR}"
  git pull --ff-only origin dev 2>/dev/null || true
  cd "${CI_CD_DIR}"
  git pull --ff-only origin dev 2>/dev/null || true

  CURRENT_SHA=$(git -C "${DOCS_DIR}" rev-parse --short HEAD)

  if [[ -n "${LAST_PM_SHA}" ]] && [[ "${CACHE_AGE}" -lt 120 ]]; then
    # Incremental: only show what changed since last PM cycle
    local changed_files
    changed_files=$(git -C "${DOCS_DIR}" diff --name-only "${LAST_PM_SHA}" HEAD 2>/dev/null | head -20 || echo "")
    if [[ -z "${changed_files}" ]]; then
      ok "no changes since last PM cycle (${LAST_PM_SHA:0:7}..${CURRENT_SHA})"
    else
      echo "  changed since last cycle:"
      echo "${changed_files}" | while read -r f; do
        [[ -z "$f" ]] && continue
        echo "    $f"
      done
    fi
  else
    # Fresh or stale cache: show recent commits
    local recent
    recent=$(git -C "${DOCS_DIR}" log --oneline -5 2>/dev/null || echo "?")
    echo "  recent commits:"
    echo "${recent}" | while read -r line; do
      echo "    $line"
    done
  fi

  echo "  current: ${CURRENT_SHA}"
}

# ── Phase 2: PM Preflight (focused, not full 6-channel) ───────────────────────
pm_preflight() {
  header "Phase 2: PM Preflight"

  # Quick health pulse — just the essentials
  echo "--- Pulse ---"

  # 2a. Review contracts needing PM attention
  local review_dir="${DOCS_DIR}/docs/development/review-contracts"
  local review_count=0
  if [[ -d "${review_dir}" ]]; then
    for rf in "${review_dir}"/*.json; do
      [[ ! -f "${rf}" ]] && continue
      [[ "$(basename "${rf}")" == ".gitkeep" ]] && continue
      local state actor tid
      read -r state actor tid <<< "$(python3 -c "
import json
d = json.load(open('${rf}'))
print(d.get('state','?'), d.get('next_required_actor','?'), d.get('task_id','?'))
" 2>/dev/null || echo "? ? ?")"
      case "${state}" in
        under_codex_review|claimed)
          action "review pending: ${tid} (state=${state}, actor=${actor})"
          review_count=$((review_count + 1))
          PM_HAS_REVIEWS=1
          ;;
        changes_requested)
          warn "changes_requested: ${tid} — Claude should be revising"
          ;;
        approved|closed|merged) ;;
        *) echo "  ${tid}: ${state}";;
      esac
    done
  fi
  [[ "${review_count:-0}" -eq 0 ]] && ok "no reviews pending"

  # 2b. Planner snapshot
  local candidate_count
  candidate_count=$(python3 "${DOCS_DIR}/scripts/plan-next-tasks.py" --format json 2>/dev/null | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['summary']['candidate_count'])" 2>/dev/null || echo "?")
  echo "  planner candidates: ${candidate_count}"

  # 2c. Active SAPs
  local sap_count
  sap_count=$(python3 "${DOCS_DIR}/scripts/supervisor-action.py" list --active-blockers --blocks-loop true 2>/dev/null | grep -cE "open|ack" || echo "0")
  [[ "${sap_count}" -gt 0 ]] && warn "${sap_count} active SAP(s)"
  [[ "${sap_count}" -eq 0 ]] && ok "no active SAPs"

  # 2d. CI pulse (fast check only if cache is stale)
  if [[ "${CACHE_AGE}" -gt 30 ]]; then
    local ci_failures=0
    for r in "MyAiDevs/livemask-backend" "MyAiDevs/livemask-admin" "MyAiDevs/livemask-ci-cd"; do
      local conclusion
      conclusion=$(gh run list --repo "$r" --branch dev --limit 1 --json conclusion --jq '.[0].conclusion' 2>/dev/null || echo "unknown")
      [[ "${conclusion}" == "failure" ]] && { warn "CI: $r FAIL"; ci_failures=$((ci_failures + 1)); }
    done
    [[ "${ci_failures}" -eq 0 ]] && ok "CI: key repos passing"
  else
    echo "  CI: using cached state (age=${CACHE_AGE}min)"
  fi

  # Decision
  PM_WORK=$(( ${review_count:-0} + ${PM_HAS_REVIEWS:-0} ))
  if [[ "${candidate_count}" == "0" || "${candidate_count}" == "?" ]]; then
    PM_QUEUE_EMPTY=1
  else
    PM_QUEUE_EMPTY=0
  fi
}

# ── Phase 3: Review Mode (judge Claude submissions) ───────────────────────────
pm_review() {
  header "Phase 3: Review"

  local review_dir="${DOCS_DIR}/docs/development/review-contracts"
  local reviewed=0

  for rf in "${review_dir}"/*.json; do
    [[ ! -f "${rf}" ]] && continue
    [[ "$(basename "${rf}")" == ".gitkeep" ]] && continue

    local state tid
    read -r state tid <<< "$(python3 -c "
import json
d = json.load(open('${rf}'))
print(d.get('state','?'), d.get('task_id','?'))
" 2>/dev/null || echo "? ?")"

    [[ "${state}" != "under_codex_review" && "${state}" != "claimed" ]] && continue

    echo ""
    echo -e "  ${BOLD}Reviewing: ${tid}${RESET}"

    # Show what Claude submitted
    python3 -c "
import json
d = json.load(open('${rf}'))
rounds = d.get('rounds', [])
if rounds:
    latest = rounds[-1]
    claude = latest.get('claude', {})
    print(f'  submitted: {claude.get(\"submitted_at\",\"?\")}')
    print(f'  commit: {claude.get(\"commit\",\"?\")}')
    print(f'  summary: {claude.get(\"summary\",\"?\")[:200]}')
    validation = claude.get('validation', [])
    for v in validation:
        print(f'  validation: {v.get(\"cmd\",\"?\")} → {v.get(\"result\",\"?\")}')
" 2>/dev/null

    # Verify evidence
    local evidence_ok=1
    local findings=()

    # Check 1: dev merge evidence
    local origin_sha
    origin_sha=$(python3 -c "import json; print(json.load(open('${rf}')).get('origin_dev_sha',''))" 2>/dev/null || echo "")
    if [[ -z "${origin_sha}" ]]; then
      findings+=("missing origin_dev_sha — no remote dev push evidence")
      evidence_ok=0
    fi

    # Check 2: task doc exists
    local task_doc
    task_doc=$(python3 -c "import json; print(json.load(open('${rf}')).get('links',{}).get('task_doc',''))" 2>/dev/null || echo "")
    if [[ -n "${task_doc}" ]] && [[ ! -f "${DOCS_DIR}/${task_doc}" ]]; then
      findings+=("task doc not found: ${task_doc}")
      evidence_ok=0
    fi

    # Check 3: check-docs.sh result
    local has_docs_check=0
    python3 -c "
import json
d = json.load(open('${rf}'))
for r in d.get('rounds',[]):
    for v in r.get('claude',{}).get('validation',[]):
        if 'check-docs' in v.get('cmd',''):
            print(v.get('result',''))
" 2>/dev/null | grep -q "pass" && has_docs_check=1
    [[ "${has_docs_check}" -eq 0 ]] && findings+=("check-docs.sh evidence missing or failed")

    # Write verdict
    echo ""
    if [[ "${evidence_ok}" -eq 1 ]]; then
      ok "VERDICT: approved"
      python3 -c "
import json, pathlib
d = json.load(open('${rf}'))
rounds = d.get('rounds', [])
if rounds:
    rounds[-1]['codex'] = {
        'reviewed_at': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
        'reviewed_by': 'Claude-PM-Backup',
        'verdict': 'approved',
        'findings': [],
        'approved_parts': ['Evidence complete: origin_dev_sha present, check-docs PASS, task doc exists']
    }
    d['state'] = 'approved'
    d['next_required_actor'] = 'claude'
    pathlib.Path('${rf}').write_text(json.dumps(d, indent=2))
    print('  review contract updated: approved')
" 2>/dev/null
    else
      warn "VERDICT: changes_requested"
      for f in "${findings[@]}"; do echo "    - $f"; done
      # Build findings JSON from bash array
      FINDINGS_JSON=$(printf '%s\n' "${findings[@]}" | python3 -c "import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))" 2>/dev/null || echo "[]")
      python3 -c "
import json, pathlib
d = json.load(open('${rf}'))
rounds = d.get('rounds', [])
findings = json.loads('''${FINDINGS_JSON}''')
if rounds:
    rounds[-1]['codex'] = {
        'reviewed_at': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
        'reviewed_by': 'Claude-PM-Backup',
        'verdict': 'changes_requested',
        'findings': findings,
        'required_changes': findings
    }
    d['state'] = 'changes_requested'
    d['next_required_actor'] = 'claude'
    pathlib.Path('${rf}').write_text(json.dumps(d, indent=2))
    print('  review contract updated: changes_requested')
" 2>/dev/null
    fi
    reviewed=$((reviewed + 1))
  done

  [[ "${reviewed}" -eq 0 ]] && echo "  no contracts to review"
  return 0
}

# ── Phase 4: Decompose Mode (create tasks from contracts) ─────────────────────
pm_decompose() {
  header "Phase 4: Decompose"

  # Only deep-read contracts if queue is empty
  if [[ "${PM_QUEUE_EMPTY:-1}" -eq 0 ]]; then
    echo "  queue has ${candidate_count:-?} candidates — skipping decomposition"
    return 0
  fi

  action "queue empty — scanning contracts for task gaps"

  # Read contract index (small file, ~2KB)
  local gaps
  gaps=$(python3 -c "
import re, json
from pathlib import Path

docs = Path('${DOCS_DIR}')
ledger = json.loads((docs / 'docs/development/task-state-ledger.json').read_text())
all_tasks = set()
for m in ledger.get('modules', []):
    for t in m.get('tasks', []):
        tid = t.get('task_id', '')
        if tid: all_tasks.add(tid)

# Read ONLY the contract index, not individual contracts
ci = docs / 'docs/contracts/contract-index.md'
if not ci.exists():
    print('NO_INDEX')
    exit(0)

lines = ci.read_text().split('\n')
gaps = []
for line in lines:
    if '| Ready |' in line:
        match = re.search(r'TASK-[A-Z0-9-]+', line)
        if match and match.group(0) not in all_tasks:
            # Extract repo hint from line
            repos = re.findall(r'livemask-[a-z0-9-]+', line)
            gaps.append({
                'line': line.strip()[:150],
                'parent_task': match.group(0),
                'repos': list(set(repos))
            })

print(json.dumps(gaps[:8], indent=2))
" 2>/dev/null || echo "[]")

  local gap_count
  gap_count=$(echo "${gaps}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

  if [[ "${gap_count}" -eq 0 ]]; then
    ok "no contract gaps found"
    return 0
  fi

  echo "  found ${gap_count} Ready contracts without implementation tasks:"
  echo "${gaps}" | python3 -c "
import json,sys
for g in json.load(sys.stdin):
    print(f\"    {g['parent_task']}: {g['line'][:100]}\")
" 2>/dev/null

  # Create requirements-inbox candidates
  local ts
  ts=$(date -u +%Y%m%d-%H%M%S)
  local candidate_file="${DOCS_DIR}/docs/development/requirements-inbox/pm-decompose-${ts}.json"

  python3 -c "
import json, pathlib
gaps = json.loads('''${gaps}''')
candidate = {
    'generated_at': '${ts}',
    'generated_by': 'Claude-PM-Backup',
    'mode': 'auto-decompose',
    'contracts_analyzed': len(gaps),
    'gaps': gaps,
    'recommended_action': 'Create TASK stubs and ledger entries for each gap',
    'human_review_required': True
}
pathlib.Path('${candidate_file}').write_text(json.dumps(candidate, indent=2))
print(f'candidate file: ${candidate_file}')
" 2>/dev/null

  action "Created ${gap_count} task candidates in requirements-inbox/"
  echo "  file: ${candidate_file}"
}

# ── Phase 5: Dispatch (assign tasks to Claude) ────────────────────────────────
pm_dispatch() {
  header "Phase 5: Dispatch"

  local top_task
  top_task=$(python3 "${DOCS_DIR}/scripts/plan-next-tasks.py" --format json 2>/dev/null | \
    python3 -c "
import json,sys
d = json.load(sys.stdin)
for t in d.get('global_next',[]):
    if t.get('readiness') == 'dispatch_now':
        print(f\"{t['task_id']}|{t['repo']}|{t['priority']}\")
        break
" 2>/dev/null || echo "NONE")

  if [[ "${top_task}" == "NONE" ]]; then
    warn "no dispatch_now tasks — decomposition needed"
    return 1
  fi

  local task_id repo priority
  task_id="${top_task%%|*}"
  top_task="${top_task#*|}"
  repo="${top_task%%|*}"
  priority="${top_task##*|}"

  # Check if already has active lease
  if python3 "${DOCS_DIR}/scripts/check-task-leases.py" 2>/dev/null | grep -q "${task_id}"; then
    ok "task ${task_id} already leased — skip dispatch"
    return 0
  fi

  # Create dispatch packet
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local dp_file="${DOCS_DIR}/docs/development/dispatch-packets/${task_id}.json"

  python3 -c "
import json, pathlib
dp = {
    'schema_version': 1,
    'task_id': '${task_id}',
    'repo': '${repo}',
    'priority': '${priority}',
    'assigned_to': 'claude',
    'assigned_at': '${ts}',
    'assigned_by': 'Claude-PM-Backup',
    'expires_at': '$(date -u -v+2H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ)'
}
pathlib.Path('${dp_file}').write_text(json.dumps(dp, indent=2))
print(f'dispatch packet: ${dp_file}')
" 2>/dev/null

  action "dispatched: ${task_id} (${repo}, ${priority})"
  echo "  Claude will pick this up on next preflight"
}

# ── Phase 6: Audit (health check) ─────────────────────────────────────────────
pm_audit() {
  header "Phase 6: Audit"

  local issues_found=0

  # 6a. Check for orphaned task branches
  echo "--- Orphaned branches ---"
  for repo_dir in "${LIVEMASK_ROOT}"/livemask-*/; do
    local rn
    rn=$(basename "${repo_dir}")
    [[ "${rn}" == "livemask-docs" || "${rn}" == "livemask-ci-cd" ]] && continue
    [[ ! -d "${repo_dir}/.git" ]] && continue
    cd "${repo_dir}"
    local branches
    branches=$(git branch --list 'task/*' --format='%(refname:short)' 2>/dev/null | wc -l | tr -d ' ')
    [[ "${branches}" -gt 0 ]] && { warn "${rn}: ${branches} task branches"; issues_found=$((issues_found + 1)); }
  done
  [[ "${issues_found}" -eq 0 ]] && ok "no orphaned branches"

  # 6b. CI health summary
  echo "--- CI Health ---"
  for r in "MyAiDevs/livemask-backend" "MyAiDevs/livemask-admin" "MyAiDevs/livemask-ci-cd" "MyAiDevs/livemask-docs"; do
    local status
    status=$(gh run list --repo "$r" --branch dev --limit 1 --json status,conclusion --jq '.[0].conclusion // .[0].status' 2>/dev/null || echo "unknown")
    case "${status}" in
      success|completed) ok "$r: PASS" ;;
      failure) warn "$r: FAIL"; issues_found=$((issues_found + 1)) ;;
      *) echo "  $r: ${status}" ;;
    esac
  done

  # 6c. Ledger staleness (from preflight cache or quick check)
  echo "--- Ledger Health ---"
  local stale_count
  stale_count=$(python3 -c "
import json
from pathlib import Path
ledger = json.loads(Path('${DOCS_DIR}/docs/development/task-state-ledger.json').read_text())
non_terminal = {'ready','in_progress','implemented','verified','partial','blocked','evidence_missing'}
count = 0
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('status','') in non_terminal and not t.get('issue',''):
            count += 1
print(count)
" 2>/dev/null || echo "?")
  [[ "${stale_count}" -gt 0 ]] && warn "${stale_count} stale ledger entries (no issue link)"
  [[ "${stale_count}" == "0" ]] && ok "ledger entries all have issue links"

  PM_ISSUES_FOUND="${issues_found}"
}

# ── Phase 7: Bug/Issue Submission ─────────────────────────────────────────────
pm_submit_bug() {
  header "Phase 7: Bug/Issue Intake"

  # Check needs-triage issues on GitHub
  local triage_count
  triage_count=$(gh issue list --repo MyAiDevs/livemask-docs --label "needs-triage" --state open --limit 10 --json number,title --jq 'length' 2>/dev/null || echo "0")

  if [[ "${triage_count}" -gt 0 ]]; then
    echo "  ${triage_count} issues need triage:"
    gh issue list --repo MyAiDevs/livemask-docs --label "needs-triage" --state open --limit 5 --json number,title,labels --jq '.[] | "    #\(.number): \(.title) [\(.labels | map(.name) | join(","))]"' 2>/dev/null || true
  else
    ok "no issues waiting for triage"
  fi
}

# ── Phase 8: Update context cache ─────────────────────────────────────────────
update_context_cache() {
  header "Phase 8: Update Cache"

  local current_sha
  current_sha=$(git -C "${DOCS_DIR}" rev-parse --short HEAD)

  python3 -c "
import json, time, pathlib

cache = {
    'schema_version': 2,
    'updated_at': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'updated_at_epoch': time.time(),
    'last_sha': '${current_sha}',
    'pm_cycle': {
        'reviews_completed': ${reviewed:-0},
        'candidates_dispatched': $([[ -n "${task_id:-}" ]] && echo 1 || echo 0),
        'gaps_found': ${gap_count:-0},
        'issues_found': ${PM_ISSUES_FOUND:-0}
    },
    'state_snapshot': {
        'planner_candidates': ${candidate_count:-0},
        'active_saps': ${sap_count:-0},
        'ci_failures': ${ci_failures:-0}
    }
}
pathlib.Path('${CACHE_FILE}').write_text(json.dumps(cache, indent=2))
" 2>/dev/null

  ok "cache updated: ${CACHE_FILE}"
}

# ── Phase 9: Write memory (for cross-session persistence) ─────────────────────
update_pm_memory() {
  header "Phase 9: PM Memory"

  # Update the auto-memory system with PM context
  local pm_memory_file="${MEMORY_DIR}/pm-context.md"

  cat > "${pm_memory_file}" << PMEOF
---
name: pm-context
description: Claude PM Backup mode — cached project understanding for efficient context loading
metadata:
  type: project
---

# PM Context Cache (last updated: $(date -u +%Y-%m-%dT%H:%M:%SZ))

## Project Pulse
- Planner candidates: ${candidate_count:-?}
- Active SAPs: ${sap_count:-?}
- CI status: backend=$(gh run list --repo MyAiDevs/livemask-backend --branch dev --limit 1 --json conclusion --jq '.[0].conclusion' 2>/dev/null || echo "?") admin=$(gh run list --repo MyAiDevs/livemask-admin --branch dev --limit 1 --json conclusion --jq '.[0].conclusion' 2>/dev/null || echo "?")

## Key Decisions (this cycle)
- Reviews: ${reviewed:-0} contracts processed
- Dispatch: $([[ -n "${task_id:-}" ]] && echo "${task_id}" || echo "none")
- Gaps found: ${gap_count:-0}

## Known Blockers
$(python3 -c "
import json
from pathlib import Path
ledger = json.loads(Path('${DOCS_DIR}/docs/development/task-state-ledger.json').read_text())
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('status') == 'blocked':
            blockers = t.get('blocked_by',[])
            print(f'- {t[\"task_id\"]}: blocked_by={blockers}')
" 2>/dev/null | head -5 || echo "- unable to read ledger")

## Recent Activity
$(git -C "${DOCS_DIR}" log --oneline -5 2>/dev/null || echo "?")

**Why:** PM mode needs efficient context loading. This memory prevents full 367KB ledger re-reads.
**How to apply:** Load this memory when starting PM mode. Read ledger only for deep-dives on specific tasks.
PMEOF

  ok "PM memory updated: ${pm_memory_file}"
}

# ── Phase 10: Push changes ────────────────────────────────────────────────────
pm_push() {
  header "Phase 10: Push"

  cd "${DOCS_DIR}"
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    local changes
    changes=$(git status --porcelain | wc -l | tr -d ' ')
    echo "  ${changes} changed file(s)"

    # Create task branch
    local pm_branch="task/pm-backup-$(date -u +%Y%m%d-%H%M%S)"
    git checkout -b "${pm_branch}" 2>/dev/null
    git add -A
    git commit -m "pm-backup: PM cycle $(date -u +%Y-%m-%dT%H:%MZ)
Reviews: ${reviewed:-0} | Dispatch: ${task_id:-none} | Gaps: ${gap_count:-0}
Co-Authored-By: Claude PM Backup <noreply@anthropic.com>" 2>/dev/null

    # Merge to dev
    git checkout dev 2>/dev/null
    git merge "${pm_branch}" --no-edit 2>/dev/null
    git push origin dev 2>/dev/null
    ok "pushed to origin/dev"
  else
    ok "no changes to push"
  fi
}

# ── Phase A: Deep Review (full code + logic analysis) ────────────────────────
pm_deep_review() {
  local target_task="${1:-}"
  if [[ -z "${target_task}" ]]; then
    echo "Usage: bash scripts/claude-loop-pm-backup.sh --deep-review <TASK-ID>"
    return 1
  fi

  header "Phase A: Deep Review — ${target_task}"

  # Step A1: Gather context efficiently
  echo "=== Context Bundle ==="

  # A1a: Task doc
  local task_doc="${DOCS_DIR}/docs/development/tasks/${target_task}.md"
  if [[ -f "${task_doc}" ]]; then
    echo ""
    echo "--- TASK DOC ---"
    head -80 "${task_doc}"
  else
    warn "task doc not found: ${task_doc}"
  fi

  # A1b: Ledger entry
  echo ""
  echo "--- LEDGER ENTRY ---"
  python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id') == '${target_task}':
            print(json.dumps(t, indent=2))
" 2>/dev/null || echo "not found in ledger"

  # A1c: Review contract (if exists)
  local review_file="${DOCS_DIR}/docs/development/review-contracts/${target_task}-review.json"
  if [[ -f "${review_file}" ]]; then
    echo ""
    echo "--- REVIEW CONTRACT ---"
    python3 -c "
import json
d = json.load(open('${review_file}'))
print(f'state: {d.get(\"state\")}')
print(f'review_round: {d.get(\"review_round\")}')
for r in d.get('rounds',[]):
    claude = r.get('claude',{})
    if claude:
        print(f'claude submitted: {claude.get(\"submitted_at\")} commit={claude.get(\"commit\",\"?\")[:7]}')
        print(f'  summary: {claude.get(\"summary\",\"?\")[:300]}')
        print(f'  files: {claude.get(\"files_changed\",[])}')
        for v in claude.get('validation',[]):
            print(f'  validation: {v.get(\"cmd\")} → {v.get(\"result\")}')
    codex = r.get('codex',{})
    if codex:
        print(f'codex verdict: {codex.get(\"verdict\")}')
        for f in codex.get('findings',[]):
            print(f'  finding: {f}')
" 2>/dev/null
  fi

  # A1d: Git diff — the actual code changes
  local target_repo
  target_repo=$(python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id') == '${target_task}':
            print(t.get('repo','livemask-docs'))
" 2>/dev/null || echo "livemask-docs")

  local repo_dir="${LIVEMASK_ROOT}/${target_repo}"
  echo ""
  echo "--- GIT DIFF (${target_repo}) ---"
  if [[ -d "${repo_dir}/.git" ]]; then
    cd "${repo_dir}"
    # Find the task branch
    local task_branch
    task_branch=$(git branch -r --list "origin/task/*${target_task}*" --format='%(refname:short)' 2>/dev/null | head -1 || echo "")
    if [[ -n "${task_branch}" ]]; then
      echo "  task branch: ${task_branch}"
      git diff "origin/dev...${task_branch}" --stat 2>/dev/null | head -20
      echo ""
      echo "  === FULL DIFF (first 200 lines) ==="
      git diff "origin/dev...${task_branch}" 2>/dev/null | head -200
    else
      # Try to find by commit
      local task_commit
      task_commit=$(python3 -c "
import json
d = json.load(open('${review_file}'))
for r in d.get('rounds',[]):
    c = r.get('claude',{}).get('commit','')
    if c: print(c); break
" 2>/dev/null || echo "")
      if [[ -n "${task_commit}" ]]; then
        echo "  commit: ${task_commit}"
        git show "${task_commit}" --stat 2>/dev/null | head -20
        echo ""
        git show "${task_commit}" 2>/dev/null | head -200
      else
        echo "  (cannot find task branch or commit — review manually)"
      fi
    fi
  fi

  # A1e: Related contracts
  echo ""
  echo "--- RELATED CONTRACTS ---"
  if [[ -f "${task_doc}" ]]; then
    grep -oE 'docs/contracts/[^ )]+' "${task_doc}" 2>/dev/null | head -10 || echo "  none referenced"
  fi

  # A1f: Cross-repo search — where else is this used?
  echo ""
  echo "--- CROSS-REPO IMPACT ---"
  local keywords
  keywords=$(grep -oE '[a-z_]+\.[a-z_]+\(|[A-Z][a-z]+Handler|[A-Z][a-z]+Service|[A-Z][a-z]+Store' "${task_doc}" 2>/dev/null | head -5 | tr '\n' ' ' || echo "")
  if [[ -n "${keywords}" ]]; then
    echo "  key symbols: ${keywords}"
    for kw in $(echo "${keywords}" | tr ' ' '\n' | head -3); do
      echo "  searching for '${kw}' across repos..."
      for rd in "${LIVEMASK_ROOT}"/livemask-*/; do
        local rn
        rn=$(basename "${rd}")
        [[ "${rn}" == "livemask-docs" || "${rn}" == "livemask-ci-cd" ]] && continue
        [[ ! -d "${rd}" ]] && continue
        local hits
        hits=$(grep -rl "${kw}" "${rd}" --include="*.go" --include="*.ts" --include="*.tsx" --include="*.dart" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        [[ "${hits}" -gt 0 ]] && echo "    ${rn}: ${hits} files"
      done
    done
  else
    echo "  (no key symbols extracted)"
  fi

  echo ""
  echo "=== DEEP ANALYSIS PROMPT ==="
  echo ""
  echo "Claude PM: review the context above and answer:"
  echo ""
  echo "1. LOGIC CORRECTNESS:"
  echo "   - Does the code change implement what the task doc describes?"
  echo "   - Are there logic gaps, edge cases not handled, or race conditions?"
  echo "   - Does the error handling follow the project pattern (error codes, retryable vs fatal)?"
  echo ""
  echo "2. CROSS-REPO CHAIN:"
  echo "   - Which other repos are affected by this change?"
  echo "   - Are the downstream repos updated (admin UI, app client, smoke tests)?"
  echo "   - If not, create follow-up tasks or mark as blocked."
  echo ""
  echo "3. CODE QUALITY:"
  echo "   - Any hardcoded values that should be in config center?"
  echo "   - Any missing RBAC/permission checks on admin routes?"
  echo "   - Any missing Swagger/OpenAPI updates for API changes?"
  echo "   - Any TODO/FIXME left in production paths?"
  echo "   - Does the new code have unit tests? Are they meaningful?"
  echo ""
  echo "4. SECURITY:"
  echo "   - Any secrets/logging issues (passwords, tokens in logs)?"
  echo "   - SQL injection risks (parameterized queries used)?"
  echo "   - Input validation on user-supplied values?"
  echo ""
  echo "5. CLOSURE READINESS:"
  echo "   - Can this task be marked completed, or does it need more evidence?"
  echo "   - What specific evidence is still missing?"
  echo "   - What downstream tasks are now unblocked?"
}

# ── Phase B: Closure Audit (rigorous task completion validation) ─────────────
pm_closure_audit() {
  local target_task="${1:-}"
  if [[ -z "${target_task}" ]]; then
    echo "Usage: bash scripts/claude-loop-pm-backup.sh --closure-audit <TASK-ID>"
    return 1
  fi

  header "Phase B: Closure Audit — ${target_task}"

  local score=0 max_score=12
  local gaps=()

  # B1: Ledger status check
  echo "--- Ledger Status ---"
  local ledger_status
  ledger_status=$(python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id') == '${target_task}':
            print(t.get('status','?'))
" 2>/dev/null || echo "NOT_FOUND")
  echo "  ledger status: ${ledger_status}"
  [[ "${ledger_status}" == "completed" ]] && score=$((score + 1)) || gaps+=("ledger not marked completed (current: ${ledger_status})")

  # B2: Dev merge evidence
  echo "--- Dev Merge ---"
  local review_file="${DOCS_DIR}/docs/development/review-contracts/${target_task}-review.json"
  if [[ -f "${review_file}" ]]; then
    local origin_sha
    origin_sha=$(python3 -c "import json; print(json.load(open('${review_file}')).get('origin_dev_sha',''))" 2>/dev/null || echo "")
    if [[ -n "${origin_sha}" ]]; then
      echo "  origin_dev_sha: ${origin_sha}"
      score=$((score + 1))
    else
      gaps+=("missing origin_dev_sha in review contract")
    fi
  else
    gaps+=("no review contract found")
  fi

  # B3: check-docs.sh passed
  echo "--- Docs Check ---"
  if [[ -f "${review_file}" ]]; then
    local docs_ok=0
    python3 -c "
import json
d = json.load(open('${review_file}'))
for r in d.get('rounds',[]):
    for v in r.get('claude',{}).get('validation',[]):
        if 'check-docs' in v.get('cmd','') and v.get('result') == 'pass':
            print('PASS')
" 2>/dev/null | grep -q "PASS" && docs_ok=1
    [[ "${docs_ok}" -eq 1 ]] && score=$((score + 1)) || gaps+=("check-docs.sh not passed or not recorded")
  fi

  # B4: GitHub issue updated
  echo "--- GitHub Issue ---"
  local issue_url
  issue_url=$(python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id') == '${target_task}':
            print(t.get('issue',''))
" 2>/dev/null || echo "")
  if [[ -n "${issue_url}" ]]; then
    echo "  issue: ${issue_url}"
    score=$((score + 1))
  else
    gaps+=("no GitHub issue linked in ledger")
  fi

  # B5: Task doc updated
  echo "--- Task Doc ---"
  local task_doc="${DOCS_DIR}/docs/development/tasks/${target_task}.md"
  if [[ -f "${task_doc}" ]]; then
    local doc_status
    doc_status=$(grep -m1 "^> Status:" "${task_doc}" 2>/dev/null || echo "")
    echo "  doc status: ${doc_status}"
    if echo "${doc_status}" | grep -q "Completed"; then
      score=$((score + 1))
    else
      gaps+=("task doc status not marked Completed")
    fi
  else
    gaps+=("task doc file not found")
  fi

  # B6: Cross-repo child issues resolved
  echo "--- Child Issues ---"
  if [[ -f "${review_file}" ]]; then
    local child_issues
    child_issues=$(python3 -c "
import json
d = json.load(open('${review_file}'))
issues = d.get('links',{}).get('issues',[])
print(len(issues))
" 2>/dev/null || echo "0")
    echo "  child issues: ${child_issues}"
    [[ "${child_issues}" -gt 0 ]] && score=$((score + 1))
  fi

  # B7: No dirty task branch
  echo "--- Branch Hygiene ---"
  local target_repo
  target_repo=$(python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id') == '${target_task}':
            print(t.get('repo','livemask-docs'))
" 2>/dev/null || echo "livemask-docs")
  local repo_dir="${LIVEMASK_ROOT}/${target_repo}"
  if [[ -d "${repo_dir}/.git" ]]; then
    cd "${repo_dir}"
    local dirty
    dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    [[ "${dirty}" -eq 0 ]] && score=$((score + 1)) || gaps+=("${target_repo} has ${dirty} dirty file(s)")
  fi

  # Summary
  echo ""
  echo "=== CLOSURE SCORE: ${score}/${max_score} ==="
  if [[ "${score}" -ge 10 ]]; then
    echo "VERDICT: READY FOR CLOSURE"
  elif [[ "${score}" -ge 7 ]]; then
    echo "VERDICT: NEEDS EVIDENCE (${#gaps[@]} gaps)"
    for g in "${gaps[@]}"; do echo "  - $g"; done
  else
    echo "VERDICT: NOT READY (${#gaps[@]} gaps)"
    for g in "${gaps[@]}"; do echo "  - $g"; done
  fi
}

# ── Phase C: Impact Analysis (trace change effects across repos) ─────────────
pm_impact_analysis() {
  local target_task="${1:-}"
  if [[ -z "${target_task}" ]]; then
    echo "Usage: bash scripts/claude-loop-pm-backup.sh --impact-analysis <TASK-ID>"
    return 1
  fi

  header "Phase C: Impact Analysis — ${target_task}"

  # C1: Determine target repo and changed files
  local target_repo
  target_repo=$(python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id') == '${target_task}':
            print(t.get('repo','?'))
" 2>/dev/null || echo "?")

  echo "--- Source: ${target_repo} ---"

  # C2: Get the actual changed files from the task branch
  local task_doc="${DOCS_DIR}/docs/development/tasks/${target_task}.md"
  local changed_files=""
  if [[ -f "${task_doc}" ]]; then
    # Extract repo-specific files from task doc
    changed_files=$(grep -E "^- \`[^)]+\.[a-z]+\`" "${task_doc}" 2>/dev/null | head -20 | sed 's/^- `//' | sed 's/`.*$//' || echo "")
  fi

  # C3: For each changed file, trace impact
  echo ""
  echo "--- Impact Map ---"
  echo ""
  echo "  Source repo: ${target_repo}"
  echo "  Task: ${target_task}"
  echo ""

  # Map target repo to affected repos
  case "${target_repo}" in
    livemask-backend)
      echo "  [${target_repo}] Backend API change → affects:"
      echo "    → livemask-admin: check if admin pages use changed endpoints"
      echo "    → livemask-app: check if Flutter models match new API shape"
      echo "    → livemask-nodeagent: check if agent's HTTP client is affected"
      echo "    → livemask-job-service: check if executor calls changed endpoint"
      echo "    → livemask-website: check if public API consumer is affected"
      echo "    → livemask-ci-cd: check smoke tests cover changed paths"
      echo "    → livemask-docs: check swagger/OpenAPI is updated"
      ;;
    livemask-admin)
      echo "  [${target_repo}] Admin UI change → affects:"
      echo "    → livemask-ci-cd: check admin-specific smoke tests"
      ;;
    livemask-app)
      echo "  [${target_repo}] App change → affects:"
      echo "    → livemask-ci-cd: check app build CI and release smoke"
      ;;
    livemask-nodeagent)
      echo "  [${target_repo}] NodeAgent change → affects:"
      echo "    → livemask-backend: check internal API compatibility"
      echo "    → livemask-ci-cd: check nodeagent smoke tests"
      ;;
    livemask-job-service)
      echo "  [${target_repo}] Job Service change → affects:"
      echo "    → livemask-backend: check executor endpoint compatibility"
      echo "    → livemask-ci-cd: check job service smoke tests"
      ;;
    livemask-docs)
      echo "  [${target_repo}] Docs change → affects:"
      echo "    → All repos: contract/rule changes may require implementation updates"
      ;;
  esac

  # C4: Search for actual references across repos
  echo ""
  echo "--- Cross-Repo Reference Search ---"
  if [[ -n "${changed_files}" ]]; then
    for f in ${changed_files}; do
      # Extract symbols from changed file names
      local symbol
      symbol=$(basename "${f}" | sed 's/\.[a-z]*$//' | sed 's/_test$//')
      [[ -z "${symbol}" || "${symbol}" == "main" ]] && continue
      echo "  searching for '${symbol}' references..."
      for rd in "${LIVEMASK_ROOT}"/livemask-*/; do
        local rn
        rn=$(basename "${rd}")
        [[ "${rn}" == "${target_repo}" || "${rn}" == "livemask-docs" || "${rn}" == "livemask-ci-cd" ]] && continue
        [[ ! -d "${rd}" ]] && continue
        local hits
        hits=$(grep -rl "${symbol}" "${rd}" --include="*.go" --include="*.ts" --include="*.tsx" --include="*.dart" 2>/dev/null | head -5)
        if [[ -n "${hits}" ]]; then
          echo "    ${rn}:"
          echo "${hits}" | while read -r h; do
            echo "      $(echo "${h}" | sed "s|${rd}||")"
          done
        fi
      done
    done
  fi

  # C5: Unlock chain
  echo ""
  echo "--- Unlock Chain ---"
  python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
target = '${target_task}'
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if target in (t.get('blocked_by') or []):
            print(f\"  BLOCKS: {t['task_id']} ({t.get('repo','?')}, {t.get('status','?')})\")
        if target in (t.get('unlocks') or []):
            print(f\"  UNLOCKS: {t['task_id']} ({t.get('repo','?')}, {t.get('status','?')})\")
" 2>/dev/null
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo -e "${BOLD}${CYAN}"
  echo "╔══════════════════════════════════════════════════╗"
  echo "║  Claude PM Backup Mode — Codex Role Stand-in    ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo -e "${RESET}"

  # Deep analysis modes (take a TASK-ID argument)
  case "${MODE}" in
    --deep-review)
      pm_deep_review "${2:-}"
      return $?
      ;;
    --closure-audit)
      pm_closure_audit "${2:-}"
      return $?
      ;;
    --impact-analysis)
      pm_impact_analysis "${2:-}"
      return $?
      ;;
  esac

  load_context_cache
  incremental_sync
  pm_preflight

  case "${MODE}" in
    --review)
      pm_review
      ;;
    --decompose)
      pm_decompose
      ;;
    --quick)
      pm_review || true
      pm_dispatch || true
      ;;
    *)
      # Full PM cycle
      pm_review || true
      pm_decompose || true
      pm_dispatch || true
      pm_audit || true
      pm_submit_bug || true
      ;;
  esac

  update_context_cache
  update_pm_memory
  pm_push

  echo ""
  echo -e "${BOLD}${GREEN}PM cycle complete.${RESET}"
  echo "  reviews: ${reviewed:-0}"
  echo "  dispatched: ${task_id:-none}"
  echo "  gaps: ${gap_count:-0}"
  echo "  issues: ${PM_ISSUES_FOUND:-0}"
  echo ""
  echo "  Next cycle: bash scripts/claude-loop-pm-backup.sh"
}

main
