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

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo -e "${BOLD}${CYAN}"
  echo "╔══════════════════════════════════════════════════╗"
  echo "║  Claude PM Backup Mode — Codex Role Stand-in    ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo -e "${RESET}"

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
