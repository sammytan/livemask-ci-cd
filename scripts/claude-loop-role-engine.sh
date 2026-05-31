#!/usr/bin/env bash
# TASK-CICD-CLAUDE-ROLE-ENGINE-001
# Multi-role automation engine. Each role has independent context cache,
# check cycle, and output actions. Token-efficient: incremental reads.
#
# Roles:
#   pm       — Project Manager: task lifecycle, ledger sync, dispatch, #68 heartbeat
#   product  — Product Manager: contracts→tasks mapping, MVP milestones, requirements
#   tech     — Tech Lead: API/Swagger sync, DB migration review, code patterns
#   qa       — QA: smoke coverage, evidence verification, bug triage, regression
#   all      — Run all roles sequentially, aggregate report
#
# Usage:
#   bash scripts/claude-loop-role-engine.sh pm              # PM role only
#   bash scripts/claude-loop-role-engine.sh product         # Product role only
#   bash scripts/claude-loop-role-engine.sh tech            # Tech Lead role only
#   bash scripts/claude-loop-role-engine.sh qa              # QA role only
#   bash scripts/claude-loop-role-engine.sh all             # All roles
set -euo pipefail

LIVEMASK_ROOT="/Users/sammytan/Developer/LiveMask"
DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"
ROLE_CACHE_DIR="${LIVEMASK_ROOT}/.claude/role-cache"
ROLE="${1:-pm}"

mkdir -p "${ROLE_CACHE_DIR}"

BOLD="\033[1m" GREEN="\033[32m" YELLOW="\033[33m" RED="\033[31m" CYAN="\033[36m" RESET="\033[0m"
role_header() { echo -e "\n${BOLD}${CYAN}┌──────────────────────────────────────────────┐${RESET}"; echo -e "${BOLD}${CYAN}│  ROLE: $*${RESET}"; echo -e "${BOLD}${CYAN}└──────────────────────────────────────────────┘${RESET}"; }
ok()   { echo -e "  ${GREEN}[OK]${RESET} $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
act()  { echo -e "  ${RED}[ACTION]${RESET} $*"; }
info() { echo -e "  ${CYAN}[..]${RESET} $*"; }

# ══════════════════════════════════════════════════════════════════════════════
# SHARED: Context loading (all roles use this)
# ══════════════════════════════════════════════════════════════════════════════

load_role_cache() {
  local role="$1"
  local cache_file="${ROLE_CACHE_DIR}/${role}-cache.json"

  if [[ -f "${cache_file}" ]]; then
    ROLE_LAST_SHA=$(python3 -c "import json; print(json.load(open('${cache_file}')).get('last_sha',''))" 2>/dev/null || echo "")
    ROLE_LAST_TIME=$(python3 -c "import json; print(json.load(open('${cache_file}')).get('updated_at',''))" 2>/dev/null || echo "")
    ROLE_CACHE_AGE=$(python3 -c "
import json, time
c = json.load(open('${cache_file}'))
print(f\"{(time.time() - c.get('updated_at_epoch',0)) / 60:.0f}\")
" 2>/dev/null || echo "999")
    info "cache: ${ROLE_CACHE_AGE}min old, last SHA ${ROLE_LAST_SHA:0:7}"
  else
    ROLE_LAST_SHA=""
    ROLE_CACHE_AGE=999
    info "no cache — will do full analysis"
  fi
}

sync_repos() {
  cd "${DOCS_DIR}" && git pull --ff-only origin dev 2>/dev/null || true
  cd "${CI_CD_DIR}" && git pull --ff-only origin dev 2>/dev/null || true
  ROLE_CURRENT_SHA=$(git -C "${DOCS_DIR}" rev-parse --short HEAD)
}

get_changed_files() {
  if [[ -n "${ROLE_LAST_SHA:-}" ]] && [[ "${ROLE_CACHE_AGE:-999}" -lt 60 ]]; then
    git -C "${DOCS_DIR}" diff --name-only "${ROLE_LAST_SHA}" HEAD 2>/dev/null | head -30 || echo ""
  else
    echo ""  # full analysis needed
  fi
}

save_role_cache() {
  local role="$1"
  shift
  local cache_file="${ROLE_CACHE_DIR}/${role}-cache.json"
  python3 -c "
import json, time, pathlib
cache = {
    'schema_version': 1,
    'role': '${role}',
    'updated_at': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'updated_at_epoch': time.time(),
    'last_sha': '${ROLE_CURRENT_SHA}',
    'cycle_summary': '$*'
}
pathlib.Path('${cache_file}').write_text(json.dumps(cache, indent=2))
" 2>/dev/null
}

mark_role_done() {
  local role="$1" msg="${2:-cycle complete}"
  echo -e "  ${GREEN}[${role}]${RESET} ${msg}"
}

# ══════════════════════════════════════════════════════════════════════════════
# ROLE: Project Manager — task lifecycle, ledger sync, dispatch, #68 heartbeat
# ══════════════════════════════════════════════════════════════════════════════

role_pm() {
  role_header "Project Manager"
  load_role_cache "pm"
  sync_repos

  local actions=0

  # PM-1: Task State Ledger Audit
  echo ""
  echo "--- PM-1: Ledger Sync ---"
  local stale_count=0 unlinked_count=0 conflict_count=0

  # Find tasks in non-terminal states without GitHub issues
  unlinked_count=$(python3 -c "
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

  if [[ "${unlinked_count}" -gt 0 ]]; then
    warn "${unlinked_count} tasks without GitHub issue links"
    actions=$((actions + 1))
  else
    ok "all non-terminal tasks have issue links"
  fi

  # Find tasks whose doc status disagrees with ledger status
  conflict_count=$(python3 -c "
import json, re
from pathlib import Path
docs = Path('${DOCS_DIR}')
ledger = json.loads((docs / 'docs/development/task-state-ledger.json').read_text())
conflicts = 0
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        tid = t.get('task_id','')
        doc_path = docs / 'docs/development/tasks' / f'{tid}.md'
        if not doc_path.exists():
            continue
        content = doc_path.read_text()
        m = re.search(r'>\\s*Status:\\s*(\\S+)', content)
        if not m:
            continue
        doc_status = m.group(1).lower()
        ledger_status = t.get('status','').lower()
        completed_terms = {'completed','completed_with_skip'}
        if doc_status in completed_terms and ledger_status not in completed_terms:
            conflicts += 1
            print(f'CONFLICT: {tid} doc={doc_status} ledger={ledger_status}')
        elif ledger_status in completed_terms and doc_status not in completed_terms:
            conflicts += 1
            print(f'CONFLICT: {tid} doc={doc_status} ledger={ledger_status}')
print(conflicts)
" 2>/dev/null || echo "0")

  if [[ "${conflict_count}" -gt 0 ]]; then
    warn "${conflict_count} doc/ledger status conflicts"
    actions=$((actions + 1))
  else
    ok "doc ↔ ledger status consistent"
  fi

  # PM-2: GitHub Issue Sync
  echo ""
  echo "--- PM-2: GitHub Issue Management ---"

  # Check for open issues that should be linked to tasks
  local orphan_issues=0
  for repo in "livemask-backend" "livemask-admin" "livemask-app" "livemask-nodeagent" "livemask-job-service" "livemask-website"; do
    local open_count
    open_count=$(gh issue list --repo "MyAiDevs/${repo}" --state open --limit 5 --json number,title --jq 'length' 2>/dev/null || echo "0")
    if [[ "${open_count}" -gt 0 ]]; then
      echo "  ${repo}: ${open_count} open issues"
      # Check if each issue is referenced in ledger
      gh issue list --repo "MyAiDevs/${repo}" --state open --limit 5 --json number,title 2>/dev/null | \
        python3 -c "
import json,sys
ledger_text = open('${DOCS_DIR}/docs/development/task-state-ledger.json').read()
for issue in json.load(sys.stdin):
    num = str(issue['number'])
    if f'/${num}' not in ledger_text and f'/issues/{num}' not in ledger_text:
        print(f'  ORPHAN: {repo}#{num}: {issue[\"title\"][:80]}')
" 2>/dev/null | while read -r line; do
        [[ -z "${line}" ]] && continue
        warn "${line}"
        orphan_issues=$((orphan_issues + 1))
      done
    fi
  done
  [[ "${orphan_issues}" -eq 0 ]] && ok "all open issues referenced in ledger"

  # PM-3: Dispatch Queue Health
  echo ""
  echo "--- PM-3: Dispatch Queue ---"
  local candidate_count blocked_count
  read -r candidate_count blocked_count <<< "$(python3 "${DOCS_DIR}/scripts/plan-next-tasks.py" --format json 2>/dev/null | \
    python3 -c "import json,sys; d=json.load(sys.stdin); s=d['summary']; print(s['candidate_count'], s['blocked_open_count'])" 2>/dev/null || echo "? ?")"

  echo "  candidates: ${candidate_count} | blocked: ${blocked_count}"

  if [[ "${candidate_count}" == "0" && "${blocked_count}" == "0" ]]; then
    warn "queue empty AND no blocked tasks — system may need task decomposition"
    actions=$((actions + 1))
  elif [[ "${candidate_count}" == "0" ]]; then
    warn "no dispatchable tasks — ${blocked_count} tasks blocked"
    # Show top blockers
    python3 "${DOCS_DIR}/scripts/plan-next-tasks.py" --format json 2>/dev/null | \
      python3 -c "
import json,sys
d = json.load(sys.stdin)
for t in d.get('blocked_open',[])[:5]:
    blockers = ','.join(t.get('blocked_by_open',[])[:3]) or 'status-open'
    print(f'  BLOCKED: {t[\"task_id\"]} ({t[\"repo\"]}, by={blockers})')
" 2>/dev/null
  else
    ok "${candidate_count} tasks ready for dispatch"
  fi

  # PM-4: Review Contract Pipeline
  echo ""
  echo "--- PM-4: Review Pipeline ---"
  local pending_reviews=0
  for rf in "${DOCS_DIR}/docs/development/review-contracts/"*.json; do
    [[ ! -f "${rf}" ]] && continue
    [[ "$(basename "${rf}")" == ".gitkeep" ]] && continue
    local state tid actor
    read -r state tid actor <<< "$(python3 -c "
import json; d=json.load(open('${rf}'))
print(d.get('state','?'), d.get('task_id','?'), d.get('next_required_actor','?'))
" 2>/dev/null || echo "? ? ?")"

    case "${state}" in
      under_codex_review) act "pending review: ${tid} (waiting for ${actor})"; pending_reviews=$((pending_reviews + 1));;
      changes_requested)  warn "needs revision: ${tid} (${actor} must act)"; pending_reviews=$((pending_reviews + 1));;
      approved)           ok "approved, ready for merge: ${tid}";;
      blocked)            warn "BLOCKED: ${tid}";;
    esac
  done
  [[ "${pending_reviews}" -eq 0 ]] && ok "review pipeline clear"
  actions=$((actions + pending_reviews))

  # PM-5: Write #68 heartbeat if actions found
  if [[ "${actions}" -gt 0 ]]; then
    echo ""
    info "writing PM heartbeat to #68..."
    local heartbeat_body="PM heartbeat $(date -u +%Y-%m-%dT%H:%MZ)
- ledger: ${unlinked_count} unlinked, ${conflict_count} doc/ledger conflicts
- issues: ${orphan_issues} orphaned
- queue: ${candidate_count} candidates, ${blocked_count} blocked
- reviews: ${pending_reviews} pending
- CI: backend=$(gh run list --repo MyAiDevs/livemask-backend --branch dev --limit 1 --json conclusion --jq '.[0].conclusion' 2>/dev/null || echo '?') admin=$(gh run list --repo MyAiDevs/livemask-admin --branch dev --limit 1 --json conclusion --jq '.[0].conclusion' 2>/dev/null || echo '?')"

    gh issue comment 68 --repo MyAiDevs/livemask-docs --body "${heartbeat_body}" 2>/dev/null || true
    ok "#68 heartbeat written"
  fi

  save_role_cache "pm" "actions=${actions} linked=${unlinked_count} conflicts=${conflict_count}"
  mark_role_done "pm" "${actions} actions identified"
  return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# ROLE: Product Manager — contracts, MVP, requirements, direction alignment
# ══════════════════════════════════════════════════════════════════════════════

role_product() {
  role_header "Product Manager"
  load_role_cache "product"
  sync_repos

  local actions=0

  # PROD-1: Contract → Task Coverage
  echo ""
  echo "--- PROD-1: Contract Coverage ---"
  local uncovered=0
  python3 -c "
import json, re
from pathlib import Path

docs = Path('${DOCS_DIR}')
ledger = json.loads((docs / 'docs/development/task-state-ledger.json').read_text())
all_tasks = set()
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id'): all_tasks.add(t['task_id'])

ci = docs / 'docs/contracts/contract-index.md'
if not ci.exists():
    print('NO_INDEX')
    exit(0)

for line in ci.read_text().split('\n'):
    if '|' not in line: continue
    parts = [p.strip() for p in line.split('|')]
    if len(parts) < 4: continue
    status = parts[2] if len(parts) > 2 else ''
    if status not in ('Ready','Stable'): continue
    tasks_in_line = re.findall(r'TASK-[A-Z0-9-]+', line)
    covered = any(t in all_tasks for t in tasks_in_line)
    if not covered and tasks_in_line:
        domain = parts[0].strip()[:40]
        print(f'UNCOVERED: {domain} | contract={status} | task={tasks_in_line[0]}')
" 2>/dev/null | head -15 | while read -r line; do
    [[ -z "${line}" ]] && continue
    warn "${line}"
    uncovered=$((uncovered + 1))
  done
  [[ "${uncovered}" -eq 0 ]] && ok "all Ready/Stable contracts have task coverage"
  actions=$((actions + uncovered))

  # PROD-2: MVP Milestone Progress
  echo ""
  echo "--- PROD-2: MVP Milestones ---"
  if [[ -f "${DOCS_DIR}/docs/development/MVP_IMPLEMENTATION_PLAN.md" ]]; then
    local completed ready partial
    completed=$(grep -c "Completed" "${DOCS_DIR}/docs/development/MVP_IMPLEMENTATION_PLAN.md" 2>/dev/null || echo "0")
    ready=$(grep -c "Ready" "${DOCS_DIR}/docs/development/MVP_IMPLEMENTATION_PLAN.md" 2>/dev/null || echo "0")
    partial=$(grep -c "Partial" "${DOCS_DIR}/docs/development/MVP_IMPLEMENTATION_PLAN.md" 2>/dev/null || echo "0")
    echo "  MVP items: ${completed} completed, ${ready} ready, ${partial} partial"
  fi

  # PROD-3: Requirement Inbox Processing
  echo ""
  echo "--- PROD-3: Requirement Inbox ---"
  local inbox_count=0
  for f in "${DOCS_DIR}/docs/development/requirements-inbox/"*.json; do
    [[ ! -f "${f}" ]] && continue
    [[ "$(basename "${f}")" == ".gitkeep" ]] && continue
    inbox_count=$((inbox_count + 1))
    local gen_by gen_at
    read -r gen_by gen_at <<< "$(python3 -c "
import json; d=json.load(open('${f}'))
print(d.get('generated_by','?'), d.get('generated_at','?')[:16])
" 2>/dev/null || echo "? ?")"
    echo "  inbox: $(basename "${f}") (by=${gen_by}, at=${gen_at})"
  done
  if [[ "${inbox_count}" -gt 0 ]]; then
    act "${inbox_count} requirements pending review — create tasks or reject with reason"
    actions=$((actions + inbox_count))
  else
    ok "requirement inbox empty"
  fi

  # PROD-4: Direction Alignment Check
  echo ""
  echo "--- PROD-4: Direction Check ---"
  # Compare active tasks against MVP priority
  python3 "${DOCS_DIR}/scripts/plan-next-tasks.py" --format json 2>/dev/null | \
    python3 -c "
import json,sys
d = json.load(sys.stdin)
candidates = d.get('global_next',[])
if not candidates:
    print('  no candidates to check')
else:
    priorities = [t['priority'] for t in candidates[:10]]
    p0_count = priorities.count('P0')
    p1_count = priorities.count('P1')
    print(f'  top 10 candidates: P0={p0_count} P1={p1_count} P2+={10-p0_count-p1_count}')
    if p0_count == 0 and d['summary']['candidate_count'] > 5:
        print('  DIRECTION: no P0 tasks in queue — verify priority assignments')
" 2>/dev/null

  save_role_cache "product" "actions=${actions} uncovered=${uncovered} inbox=${inbox_count}"
  mark_role_done "product" "${actions} actions identified"
  return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# ROLE: Tech Lead — code quality, API/Swagger, DB migration, architecture
# ══════════════════════════════════════════════════════════════════════════════

role_tech() {
  role_header "Tech Lead"
  load_role_cache "tech"
  sync_repos

  local actions=0

  # TECH-1: API/Swagger Alignment
  echo ""
  echo "--- TECH-1: API/Swagger Sync ---"
  if [[ -d "${LIVEMASK_ROOT}/livemask-backend/internal/swagger" ]]; then
    local swagger_age
    swagger_age=$(find "${LIVEMASK_ROOT}/livemask-backend/internal/swagger" -name "*.yaml" -mtime -7 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${swagger_age}" -gt 0 ]]; then
      ok "Swagger updated within 7 days (${swagger_age} files)"
    else
      warn "Swagger files not updated recently — API changes may not be documented"
      actions=$((actions + 1))
    fi

    # Check if main.go route count matches Swagger path count
    local route_count swagger_path_count
    route_count=$(grep -c 'mux.HandleFunc\|Handle(' "${LIVEMASK_ROOT}/livemask-backend/main.go" 2>/dev/null || echo "0")
    swagger_path_count=$(grep -c '^  /' "${LIVEMASK_ROOT}/livemask-backend/internal/swagger/"*.yaml 2>/dev/null || echo "0")
    echo "  routes in main.go: ${route_count} | swagger paths: ${swagger_path_count}"
  else
    echo "  (backend swagger dir not found — skipping)"
  fi

  # TECH-2: Database Migration Safety
  echo ""
  echo "--- TECH-2: DB Migration ---"
  local migration_count=0 add_column_count=0
  for go_file in $(find "${LIVEMASK_ROOT}/livemask-backend/internal" -name "*.go" -not -name "*_test.go" 2>/dev/null); do
    if grep -q "ALTER TABLE\|ADD COLUMN\|CREATE TABLE IF NOT EXISTS" "${go_file}" 2>/dev/null; then
      migration_count=$((migration_count + 1))
      if grep -q "ADD COLUMN" "${go_file}" 2>/dev/null; then
        add_column_count=$((add_column_count + 1))
      fi
    fi
  done
  echo "  files with inline migrations: ${migration_count} (ADD COLUMN: ${add_column_count})"
  if [[ "${add_column_count}" -gt 0 ]]; then
    warn "${add_column_count} ADD COLUMN migrations — verify NOT NULL defaults and index impact"
    actions=$((actions + 1))
  fi

  # TECH-3: Hardcoded Config Detection
  echo ""
  echo "--- TECH-3: Potential Hardcoded Values ---"
  local hardcoded=0
  # Check backend for magic strings that should be config
  for pattern in "time.Duration([0-9]+)" "\"http://[^l]" ":=[0-9]{4,}" "DefaultMax\|DefaultMin\|DefaultTimeout"; do
    local hits
    hits=$(grep -r "${pattern}" "${LIVEMASK_ROOT}/livemask-backend/internal" --include="*.go" -l 2>/dev/null | head -3)
    if [[ -n "${hits}" ]]; then
      while read -r h; do
        [[ -z "${h}" ]] && continue
        hardcoded=$((hardcoded + 1))
        echo "  potential hardcoded: $(echo "${h}" | sed "s|${LIVEMASK_ROOT}/livemask-backend/||")"
      done <<< "${hits}"
    fi
  done
  [[ "${hardcoded}" -eq 0 ]] && ok "no obvious hardcoded values detected"

  # TECH-4: Cross-Repo Interface Consistency
  echo ""
  echo "--- TECH-4: Interface Consistency ---"
  # Check that models shared between repos have consistent field names
  local backend_models
  backend_models=$(grep -rh "json:\"[a-z_]*\"" "${LIVEMASK_ROOT}/livemask-backend/internal" --include="*.go" 2>/dev/null | grep -oE 'json:"[a-z_]+"' | sed 's/json:"//' | sed 's/"//' | sort -u | head -30)
  if [[ -n "${backend_models}" ]]; then
    local mismatch=0
    # Check admin TypeScript types match backend JSON tags
    for field in $(echo "${backend_models}" | head -10); do
      local admin_hits
      admin_hits=$(grep -r "${field}" "${LIVEMASK_ROOT}/livemask-admin/src/types" --include="*.ts" -l 2>/dev/null | wc -l | tr -d ' ')
      local app_hits
      app_hits=$(grep -r "${field}" "${LIVEMASK_ROOT}/livemask-app/lib/models" --include="*.dart" -l 2>/dev/null | wc -l | tr -d ' ')
      [[ "${admin_hits}" == "0" && "${app_hits}" == "0" ]] && continue
      echo "  field '${field}': admin=${admin_hits} files, app=${app_hits} files"
    done
  fi

  save_role_cache "tech" "actions=${actions} migrations=${migration_count} hardcoded=${hardcoded}"
  mark_role_done "tech" "${actions} actions identified"
  return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# ROLE: QA — test coverage, evidence verification, bug triage, regression
# ══════════════════════════════════════════════════════════════════════════════

role_qa() {
  role_header "QA"
  load_role_cache "qa"
  sync_repos

  local actions=0

  # QA-1: Smoke Test Coverage
  echo ""
  echo "--- QA-1: Smoke Coverage ---"
  local smoke_count=0
  smoke_count=$(find "${CI_CD_DIR}/scripts" -name "*smoke*.sh" 2>/dev/null | wc -l | tr -d ' ')
  echo "  smoke scripts: ${smoke_count}"
  # Check if recent backend API changes have smoke coverage
  local recent_api_changes
  recent_api_changes=$(git -C "${LIVEMASK_ROOT}/livemask-backend" log --oneline --since="7 days ago" 2>/dev/null | wc -l | tr -d ' ')
  echo "  backend changes (7 days): ${recent_api_changes}"
  if [[ "${recent_api_changes}" -gt 10 && "${smoke_count}" -lt 30 ]]; then
    warn "high change velocity (${recent_api_changes} commits) with limited smoke coverage (${smoke_count} scripts)"
    actions=$((actions + 1))
  fi

  # QA-2: Evidence Verification for Recently Completed Tasks
  echo ""
  echo "--- QA-2: Completion Evidence ---"
  local recent_completed=0 missing_evidence=0
  python3 -c "
import json
from pathlib import Path

ledger = json.loads(Path('${DOCS_DIR}/docs/development/task-state-ledger.json').read_text())
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('status') in ('completed','completed_with_skip','verified'):
            validation = t.get('validation','')
            if not validation or len(validation.strip()) < 10:
                print(f'MISSING_EVIDENCE: {t[\"task_id\"]} ({t.get(\"repo\",\"?\")})')
" 2>/dev/null | head -10 | while read -r line; do
    [[ -z "${line}" ]] && continue
    warn "${line}"
    missing_evidence=$((missing_evidence + 1))
  done
  [[ "${missing_evidence}" -eq 0 ]] && ok "all completed tasks have validation evidence"
  actions=$((actions + missing_evidence))

  # QA-3: Bug Triage
  echo ""
  echo "--- QA-3: Bug Triage ---"
  local untriaged=0
  for repo in "livemask-docs" "livemask-backend" "livemask-admin" "livemask-app" "livemask-nodeagent" "livemask-website"; do
    local count
    count=$(gh issue list --repo "MyAiDevs/${repo}" --label "bug" --state open --limit 20 --json number --jq 'length' 2>/dev/null || echo "0")
    if [[ "${count}" -gt 0 ]]; then
      echo "  ${repo}: ${count} open bugs"
      untriaged=$((untriaged + count))
    fi
  done
  if [[ "${untriaged}" -gt 0 ]]; then
    warn "${untriaged} open bugs across repos — triage needed"
    actions=$((actions + 1))
  else
    ok "no open bugs"
  fi

  # QA-4: Regression Risk Assessment
  echo ""
  echo "--- QA-4: Regression Risk ---"
  # Check if recent changes touched high-risk areas
  local high_risk_changes=0
  for area in "auth" "billing" "payment" "configcenter" "node/credential"; do
    local changes
    changes=$(git -C "${LIVEMASK_ROOT}/livemask-backend" log --oneline --since="3 days ago" -- "internal/${area}/" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${changes}" -gt 0 ]]; then
      echo "  HIGH RISK: ${area} changed ${changes} times in 3 days"
      high_risk_changes=$((high_risk_changes + changes))
    fi
  done
  if [[ "${high_risk_changes}" -gt 3 ]]; then
    warn "${high_risk_changes} changes in high-risk areas — regression testing recommended"
    actions=$((actions + 1))
  else
    ok "low regression risk"
  fi

  # QA-5: Test Gap Detection
  echo ""
  echo "--- QA-5: Test Gap Detection ---"
  # Find Go packages without test files
  local no_test_packages=0
  for pkg_dir in $(find "${LIVEMASK_ROOT}/livemask-backend/internal" -type d -mindepth 1 -maxdepth 1 2>/dev/null); do
    local test_files
    test_files=$(find "${pkg_dir}" -name "*_test.go" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${test_files}" -eq 0 ]]; then
      local pkg_name
      pkg_name=$(basename "${pkg_dir}")
      # Skip non-code packages
      [[ "${pkg_name}" == "swagger" || "${pkg_name}" == "locale" || "${pkg_name}" == "dbschema" ]] && continue
      echo "  no tests: backend/internal/${pkg_name}"
      no_test_packages=$((no_test_packages + 1))
    fi
  done
  if [[ "${no_test_packages}" -gt 0 ]]; then
    warn "${no_test_packages} backend packages without test coverage"
    actions=$((actions + 1))
  else
    ok "all backend packages have tests"
  fi

  save_role_cache "qa" "actions=${actions} bugs=${untriaged} evidence_gaps=${missing_evidence} no_test=${no_test_packages}"
  mark_role_done "qa" "${actions} actions identified"
  return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# ORCHESTRATOR: Run all roles, aggregate report
# ══════════════════════════════════════════════════════════════════════════════

run_all_roles() {
  echo -e "${BOLD}${CYAN}"
  echo "╔══════════════════════════════════════════════════╗"
  echo "║  Multi-Role Automation Engine — All Roles       ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo -e "${RESET}"

  local pm_actions=0 prod_actions=0 tech_actions=0 qa_actions=0

  role_pm && pm_actions=$? || true
  role_product && prod_actions=$? || true
  role_tech && tech_actions=$? || true
  role_qa && qa_actions=$? || true

  echo ""
  echo -e "${BOLD}${CYAN}┌──────────────────────────────────────────────┐${RESET}"
  echo -e "${BOLD}${CYAN}│  AGGREGATE REPORT                            │${RESET}"
  echo -e "${BOLD}${CYAN}└──────────────────────────────────────────────┘${RESET}"
  echo ""
  echo "  PM:      ${pm_actions} actions"
  echo "  Product: ${prod_actions} actions"
  echo "  Tech:    ${tech_actions} actions"
  echo "  QA:      ${qa_actions} actions"
  echo "  ─────────────────────"
  echo "  TOTAL:   $((pm_actions + prod_actions + tech_actions + qa_actions)) actions"

  # Push all changes together
  cd "${DOCS_DIR}"
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    local total_changes
    total_changes=$(git status --porcelain | wc -l | tr -d ' ')
    local role_branch="task/role-engine-$(date -u +%Y%m%d-%H%M%S)"
    git checkout -b "${role_branch}" 2>/dev/null
    git add -A
    git commit -m "role-engine: multi-role cycle $(date -u +%Y-%m-%dT%H:%MZ)
PM=${pm_actions} Product=${prod_actions} Tech=${tech_actions} QA=${qa_actions}
Co-Authored-By: Claude Role Engine <noreply@anthropic.com>" 2>/dev/null
    git checkout dev 2>/dev/null
    git merge "${role_branch}" --no-edit 2>/dev/null
    git push origin dev 2>/dev/null
    echo ""
    ok "pushed ${total_changes} changes to origin/dev"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# DEEP ANALYSIS: Cross-cutting deep review modes (require TASK-ID argument)
# ══════════════════════════════════════════════════════════════════════════════

deep_review() {
  local target_task="${1:-}"
  [[ -z "${target_task}" ]] && { echo "Usage: bash scripts/claude-loop-role-engine.sh --deep-review <TASK-ID>"; return 1; }

  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${CYAN}║  DEEP REVIEW: ${target_task}${RESET}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${RESET}"

  sync_repos

  # Gather: task doc
  local task_doc="${DOCS_DIR}/docs/development/tasks/${target_task}.md"
  [[ -f "${task_doc}" ]] && { echo ""; echo "--- TASK DOC ---"; head -60 "${task_doc}"; }

  # Gather: ledger entry
  echo ""; echo "--- LEDGER ---"
  python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id') == '${target_task}':
            print(json.dumps({k:t[k] for k in ['status','repo','issue','validation','blocked_by','unlocks','notes'] if k in t}, indent=2))
" 2>/dev/null || echo "not found"

  # Gather: review contract
  local rf="${DOCS_DIR}/docs/development/review-contracts/${target_task}-review.json"
  if [[ -f "${rf}" ]]; then
    echo ""; echo "--- REVIEW CONTRACT ---"
    python3 -c "
import json; d=json.load(open('${rf}'))
print(f'state={d.get(\"state\")} round={d.get(\"review_round\")} actor={d.get(\"next_required_actor\")}')
for r in d.get('rounds',[]):
    c = r.get('claude',{})
    if c: print(f'claude: {c.get(\"submitted_at\")} commit={str(c.get(\"commit\",\"\"))[:7]} summary={c.get(\"summary\",\"\")[:200]}')
    cx = r.get('codex',{})
    if cx: print(f'codex: verdict={cx.get(\"verdict\")} findings={cx.get(\"findings\",[])}')
" 2>/dev/null
  fi

  # Gather: git diff
  local target_repo
  target_repo=$(python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id') == '${target_task}': print(t.get('repo','livemask-docs'))
" 2>/dev/null || echo "livemask-docs")
  local repo_dir="${LIVEMASK_ROOT}/${target_repo}"

  echo ""; echo "--- GIT DIFF (${target_repo}) ---"
  if [[ -d "${repo_dir}/.git" ]]; then
    cd "${repo_dir}"
    local task_branch
    task_branch=$(git branch -r --list "origin/task/*${target_task}*" --format='%(refname:short)' 2>/dev/null | head -1 || echo "")
    if [[ -n "${task_branch}" ]]; then
      git diff "origin/dev...${task_branch}" --stat 2>/dev/null | head -15
      echo ""; git diff "origin/dev...${task_branch}" 2>/dev/null | head -150
    elif [[ -f "${rf}" ]]; then
      local tc; tc=$(python3 -c "import json; d=json.load(open('${rf}')); print(d.get('task_commit',''))" 2>/dev/null || echo "")
      [[ -n "${tc}" ]] && { git show "${tc}" --stat 2>/dev/null | head -15; echo ""; git show "${tc}" 2>/dev/null | head -150; }
    fi
  fi

  # Cross-repo impact search
  echo ""; echo "--- CROSS-REPO IMPACT ---"
  local keywords; keywords=$(grep -oE '[a-z_]+\.[a-z_]+\(|[A-Z][a-z]+Handler|[A-Z][a-z]+Service' "${task_doc}" 2>/dev/null | head -5 | tr '\n' ' ' || echo "")
  [[ -n "${keywords}" ]] && echo "  key symbols: ${keywords}"

  echo ""
  echo "=== DEEP ANALYSIS PROMPT ==="
  echo "Claude: review the context above and evaluate:"
  echo "1. LOGIC: Does the code implement what the task doc describes? Edge cases? Race conditions?"
  echo "2. CROSS-REPO: Which downstream repos are affected? Are they updated? If not, create follow-ups."
  echo "3. QUALITY: Hardcoded values? Missing RBAC? Missing Swagger? TODO/FIXME in prod paths?"
  echo "4. SECURITY: Secrets in logs? SQL injection? Input validation?"
  echo "5. CLOSURE: Can this be marked completed? What evidence is still missing?"
}

closure_audit() {
  local target_task="${1:-}"
  [[ -z "${target_task}" ]] && { echo "Usage: bash scripts/claude-loop-role-engine.sh --closure-audit <TASK-ID>"; return 1; }

  echo -e "${BOLD}${CYAN}CLOSURE AUDIT: ${target_task}${RESET}"
  sync_repos

  local score=0 max=0
  local gaps=()

  check() { max=$((max+1)); local label="$1" cond="$2"; if eval "${cond}"; then score=$((score+1)); echo "  [✓] ${label}"; else gaps+=("${label}"); echo "  [✗] ${label}"; fi; }

  local ledger_status; ledger_status=$(python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id') == '${target_task}': print(t.get('status','?'))
" 2>/dev/null || echo "NOT_FOUND")
  check "ledger status=completed" "[[ '${ledger_status}' == 'completed' || '${ledger_status}' == 'completed_with_skip' ]]"

  local rf="${DOCS_DIR}/docs/development/review-contracts/${target_task}-review.json"
  local origin_sha=""
  [[ -f "${rf}" ]] && origin_sha=$(python3 -c "import json; print(json.load(open('${rf}')).get('origin_dev_sha',''))" 2>/dev/null || echo "")
  check "origin/dev push evidence" "[[ -n '${origin_sha}' ]]"

  local docs_ok=0
  [[ -f "${rf}" ]] && python3 -c "
import json; d=json.load(open('${rf}'))
for r in d.get('rounds',[]):
    for v in r.get('claude',{}).get('validation',[]):
        if 'check-docs' in v.get('cmd','') and v.get('result')=='pass': print('PASS')
" 2>/dev/null | grep -q "PASS" && docs_ok=1
  check "check-docs.sh PASS" "[[ ${docs_ok} -eq 1 ]]"

  local has_issue=""; has_issue=$(python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id') == '${target_task}' and t.get('issue',''): print('yes')
" 2>/dev/null || echo "")
  check "GitHub issue linked" "[[ -n '${has_issue}' ]]"

  local task_doc="${DOCS_DIR}/docs/development/tasks/${target_task}.md"
  local doc_completed=0
  [[ -f "${task_doc}" ]] && grep -q "Completed" "${task_doc}" 2>/dev/null && doc_completed=1
  check "task doc marked Completed" "[[ ${doc_completed} -eq 1 ]]"

  local target_repo; target_repo=$(python3 -c "
import json; ledger=json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id')=='${target_task}': print(t.get('repo','livemask-docs'))
" 2>/dev/null || echo "livemask-docs")
  local dirty; dirty=$(git -C "${LIVEMASK_ROOT}/${target_repo}" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  check "target repo clean" "[[ ${dirty} -eq 0 ]]"

  local child_count=0
  [[ -f "${rf}" ]] && child_count=$(python3 -c "import json; print(len(json.load(open('${rf}')).get('links',{}).get('issues',[])))" 2>/dev/null || echo "0")
  check "child issues tracked" "[[ ${child_count} -gt 0 ]]"

  echo ""; echo "SCORE: ${score}/${max}"
  [[ ${score} -ge $((max - 1)) ]] && echo "VERDICT: READY FOR CLOSURE" || echo "VERDICT: NEEDS EVIDENCE"
  for g in "${gaps[@]}"; do echo "  GAP: $g"; done
}

impact_analysis() {
  local target_task="${1:-}"
  [[ -z "${target_task}" ]] && { echo "Usage: bash scripts/claude-loop-role-engine.sh --impact-analysis <TASK-ID>"; return 1; }

  echo -e "${BOLD}${CYAN}IMPACT ANALYSIS: ${target_task}${RESET}"
  sync_repos

  local target_repo; target_repo=$(python3 -c "
import json; ledger=json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id')=='${target_task}': print(t.get('repo','?'))
" 2>/dev/null || echo "?")

  echo "Source: ${target_repo} → ${target_task}"
  echo ""

  case "${target_repo}" in
    livemask-backend)
      echo "Backend API change → affects: Admin UI, App models, NodeAgent client, Job Service executors, Website, CI/CD smoke, Docs swagger"
      ;;
    livemask-admin)   echo "Admin UI change → affects: CI/CD admin smoke";;
    livemask-app)     echo "App change → affects: CI/CD app build/release smoke";;
    livemask-nodeagent) echo "NodeAgent change → affects: Backend internal API compat, CI/CD node smoke";;
    livemask-job-service) echo "Job Service change → affects: Backend executor endpoints, CI/CD job smoke";;
    livemask-docs)    echo "Docs change → affects: ALL repos (contract/rule changes need implementation)";;
  esac

  # Unlock chain
  echo ""; echo "--- Unlock Chain ---"
  python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
target = '${target_task}'
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        blockers = t.get('blocked_by') or []
        if target in blockers:
            print(f\"  BLOCKS: {t['task_id']} ({t.get('repo','?')}, {t.get('status','?')})\")
        unlocks = t.get('unlocks') or []
        if target in unlocks:
            print(f\"  UNLOCKS: {t['task_id']} ({t.get('repo','?')}, {t.get('status','?')})\")
" 2>/dev/null

  # Search for actual code references
  echo ""; echo "--- Code References ---"
  local task_doc="${DOCS_DIR}/docs/development/tasks/${target_task}.md"
  [[ -f "${task_doc}" ]] && for kw in $(grep -oE '[A-Z][a-zA-Z]{3,}' "${task_doc}" 2>/dev/null | sort -u | head -3); do
    echo "  searching '${kw}' across repos..."
    for rd in "${LIVEMASK_ROOT}"/livemask-*/; do
      local rn; rn=$(basename "${rd}")
      [[ "${rn}" == "${target_repo}" || "${rn}" == "livemask-docs" || "${rn}" == "livemask-ci-cd" ]] && continue
      local hits; hits=$(grep -rl "${kw}" "${rd}" --include="*.go" --include="*.ts" --include="*.tsx" --include="*.dart" 2>/dev/null | wc -l | tr -d ' ')
      [[ "${hits}" -gt 0 ]] && echo "    ${rn}: ${hits} files"
    done
  done
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

case "${ROLE}" in
  pm)      role_pm;;
  product) role_product;;
  tech)    role_tech;;
  qa)      role_qa;;
  all)     run_all_roles;;
  --deep-review)     deep_review "${2:-}";;
  --closure-audit)   closure_audit "${2:-}";;
  --impact-analysis) impact_analysis "${2:-}";;
  *)
    echo "Usage: bash scripts/claude-loop-role-engine.sh <role|mode> [args]"
    echo ""
    echo "  Automated roles:"
    echo "    pm       — Project Manager: ledger sync, issue mgmt, dispatch, review pipeline"
    echo "    product  — Product Manager: contract coverage, MVP milestones, inbox, direction"
    echo "    tech     — Tech Lead: API/Swagger sync, DB migration, hardcoded config, interfaces"
    echo "    qa       — QA: smoke coverage, evidence verification, bug triage, regression"
    echo "    all      — All roles sequentially with aggregate report"
    echo ""
    echo "  Deep analysis (requires TASK-ID):"
    echo "    --deep-review <TASK>     — Full code + logic + cross-repo analysis"
    echo "    --closure-audit <TASK>   — 7-point closure readiness scoring"
    echo "    --impact-analysis <TASK> — Cross-repo dependency trace + unlock chain"
    exit 1
    ;;
esac
