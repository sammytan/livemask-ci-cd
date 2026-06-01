#!/usr/bin/env bash
# reasoning-engine.sh — Model reasoning layer for the Claude loop.
# Source this, then call reasoning_* functions to get structured reasoning
# prompts. Each function collects relevant context and outputs a prompt
# that forces model reasoning (not mechanical script execution).
#
# Principle: Scripts collect data → Model reasons → Model decides → Model acts.
# The script NEVER mutates state. It only outputs structured context for the model.
set -euo pipefail

LIVEMASK_ROOT="${LIVEMASK_ROOT:-/Users/sammytan/Developer/LiveMask}"
DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"
ROLE_CACHE_DIR="${HOME}/.claude/role-cache"
MEMORY_DIR="${HOME}/.claude/projects/-Users-sammytan-Developer-LiveMask/memory"

# ── Phase 1: Startup Reasoning — "What should I work on and WHY?" ──────────
# Reads findings, planner output, dispatch packets, agent state.
# Outputs a structured reasoning prompt for the model.
reasoning_startup_decision() {
  local findings_file="${ROLE_CACHE_DIR}/findings.jsonl"
  local dispatch_dir="${DOCS_DIR}/docs/development/dispatch-packets"
  local agent_state="${LIVEMASK_ROOT}/.claude/agent-state.json"

  cat << 'REASONING_PROMPT'
=== STARTUP REASONING CHECKPOINT ===

You are about to start a new Claude loop cycle. Before doing ANYTHING, reason through these questions:

1. WHAT WORK EXISTS RIGHT NOW?
   - Read the dispatch packets in docs/development/dispatch-packets/
   - Read the planner output from plan-next-tasks.py
   - Read the findings file in ~/.claude/role-cache/findings.jsonl
   - List every task that is ready and assigned to claude.

2. WHAT IS THE HIGHEST PRIORITY WORK?
   - Sort tasks by: has dispatch packet > has issue link > P1 > P2
   - Check if any task has a GitHub issue that's been updated recently
   - Check if any task has review contracts that need action

3. WHAT BLOCKERS EXIST?
   - Check agent-state.json: am I mid-task? (phase != idle)
   - Check PM lease: is Codex working?
   - Check CI state: any failures?

4. DECISION TREE:
   IF agent phase is mid-task (implementing/revising/merging):
     → RECOVER: read the task doc, check what's left, continue
   IF dispatch packet exists for a task assigned to claude:
     → ACCEPT: update agent-state.json, read task doc, start implementing
   IF findings show evidence gaps or review needed:
     → AUDIT: verify each finding with real evidence, not regex
   IF queue is empty but MVP < 100%:
     → DIAGNOSE: why are Ready contracts not dispatched? fix the chain
   IF nothing actionable:
     → MONITOR: enter idle monitoring, wait for triggers

5. AFTER DECIDING, DO NOT JUST PRINT THE ANSWER.
   - Update agent-state.json with your decision
   - Read the task doc for the chosen task
   - Read the linked GitHub issue (body + comments)
   - Switch to the task repo and start implementing

DO NOT:
- Run the role engine again if you already have findings
- Create new TASK-AUTO tasks
- Report "clean" without verifying every signal
- Ask the user "what should I do?" — that's YOUR job to decide
REASONING_PROMPT

  # Output hard data
  echo ""
  echo "=== HARD DATA ==="
  echo ""

  # Agent state
  if [[ -f "${agent_state}" ]]; then
    python3 -c "
import json; d=json.load(open('${agent_state}'))
t=d.get('current_task') or {}
print(f'agent_phase={d.get(\"phase\",\"?\")}')
print(f'current_task={t.get(\"task_id\",\"null\")}')
print(f'target_repo={t.get(\"target_repo\",\"\")}')
print(f'task_phase={t.get(\"task_phase\",\"\")}')
" 2>/dev/null || echo "agent_state=unavailable"
  fi

  # Dispatch packets
  local pkt_count=0
  if [[ -d "${dispatch_dir}" ]]; then
    pkt_count=$(ls "${dispatch_dir}"/TASK-*.json 2>/dev/null | wc -l | tr -d ' ')
    echo "dispatch_packets=${pkt_count}"
    for pf in "${dispatch_dir}"/TASK-*.json; do
      [[ -f "${pf}" ]] || continue
      python3 -c "
import json; d=json.load(open('${pf}'))
print(f'  DISPATCH: {d[\"task_id\"]} -> {d[\"repo\"]} assigned={d.get(\"assigned_to\",\"?\")} priority={d.get(\"priority\",\"?\")}')
" 2>/dev/null
    done
  else
    echo "dispatch_packets=0"
  fi

  # Planner
  python3 "${DOCS_DIR}/scripts/plan-next-tasks.py" --format json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
s=d.get('summary',{})
print(f'planner_candidates={s.get(\"candidate_count\",0)}')
print(f'planner_blocked={s.get(\"blocked_open_count\",0)}')
for t in d.get('global_next',[])[:8]:
    print(f'  CANDIDATE: {t[\"task_id\"]} repo={t[\"repo\"]} readiness={t.get(\"readiness\",\"?\")}')
" 2>/dev/null || echo "planner=unavailable"

  # Findings summary
  if [[ -f "${findings_file}" ]]; then
    python3 -c "
import json
from collections import Counter
findings=[]
with open('${findings_file}') as f:
    for l in f:
        if l.strip(): findings.append(json.loads(l))
print(f'findings_total={len(findings)}')
for s,c in Counter(f['severity'] for f in findings).most_common():
    print(f'findings_{s}={c}')
for s,c in Counter(f['check'] for f in findings).most_common():
    print(f'findings_check_{s}={c}')
" 2>/dev/null
  fi

  # PM lease
  local lease_file="${ROLE_CACHE_DIR}/pm-lease.json"
  if [[ -f "${lease_file}" ]]; then
    python3 -c "
import json,time
d=json.load(open('${lease_file}'))
age=(time.time()-d.get('started_at_epoch',0))/60
print(f'pm_lease_holder={d.get(\"agent\",\"?\")}')
print(f'pm_lease_age_min={age:.0f}')
print(f'pm_lease_phase={d.get(\"phase\",\"?\")}')
" 2>/dev/null || echo "pm_lease=unavailable"
  else
    echo "pm_lease=none"
  fi
}

# ── Phase 2: Task Verification Reasoning — "Is this task REALLY done?" ─────
reasoning_verify_task() {
  local tid="${1:-}"
  [[ -z "${tid}" ]] && { echo "Usage: reasoning_verify_task <TASK-ID>"; return 1; }

  cat << REASONING_PROMPT
=== TASK VERIFICATION REASONING CHECKPOINT ===

You are verifying whether task ${tid} is genuinely complete. Do NOT use regex patterns. Actually verify:

1. GIT EVIDENCE:
   - Does a dev merge commit exist for this task?
   - Run: git -C /path/to/repo log --oneline --grep "${tid}" -1
   - If no merge commit: task is NOT done, regardless of what ledger says.

2. GITHUB ISSUE:
   - Is the linked issue CLOSED? (not just marked completed in ledger)
   - Read the issue body + comments for actual completion evidence
   - If issue is still OPEN: task is NOT done.

3. TASK DOC:
   - Read docs/development/tasks/${tid}.md
   - What does the Status line say?
   - Does it have actual commit SHAs, test output, or just placeholder text?

4. REVIEW CONTRACT:
   - Does docs/development/review-contracts/${tid}-review.json exist?
   - Is it approved or changes_requested?
   - No contract = no review = insufficient evidence.

5. CI/CD:
   - Did the docs CI pass for the merge commit?
   - Did the repo's CI pass?

6. VERDICT:
   - ALL of: merge commit + closed issue + approved review + CI pass = TRULY DONE
   - ANY missing = REOPEN or keep open with specific missing items listed

7. ACTION:
   - Output specific, actionable next steps, not generic advice.
   - "Create review contract at docs/development/review-contracts/${tid}-review.json with fields X,Y,Z"
   - "Link GitHub issue by updating ledger entry field 'issue' to URL"
   - "Revert ledger status from completed to ready because evidence A,B,C missing"
REASONING_PROMPT

  # Collect hard evidence for the task
  echo ""
  echo "=== EVIDENCE FOR ${tid} ==="

  # Ledger entry
  python3 -c "
import json
ledger=json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id')=='${tid}':
            print(f'ledger_status={t.get(\"status\",\"?\")}')
            print(f'ledger_repo={t.get(\"repo\",\"?\")}')
            print(f'ledger_issue={t.get(\"issue\",\"\")}')
            print(f'ledger_validation={t.get(\"validation\",\"\")[:200]}')
            print(f'ledger_dev_merge={t.get(\"dev_merge_commit\",\"\")}')
            break
" 2>/dev/null || echo "ledger=not_found"

  # Task doc
  local doc="${DOCS_DIR}/docs/development/tasks/${tid}.md"
  if [[ -f "${doc}" ]]; then
    echo "task_doc=exists"
    grep "^> Status:" "${doc}" 2>/dev/null || echo "task_doc_status=not_found"
    grep -oE '[0-9a-f]{7,40}' "${doc}" 2>/dev/null | head -3 | while read sha; do echo "task_doc_sha=${sha}"; done
  else
    echo "task_doc=MISSING"
  fi

  # Review contract
  local rf="${DOCS_DIR}/docs/development/review-contracts/${tid}-review.json"
  if [[ -f "${rf}" ]]; then
    python3 -c "
import json; d=json.load(open('${rf}'))
print(f'review_state={d.get(\"state\",\"?\")}')
for r in d.get('rounds',[]):
    cx=r.get('codex',{})
    if cx: print(f'review_codex_verdict={cx.get(\"verdict\",\"?\")}')
" 2>/dev/null
  else
    echo "review_contract=MISSING"
  fi

  # Git merge check in target repo
  local repo; repo=$(python3 -c "
import json
ledger=json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id')=='${tid}': print(t.get('repo','')); break
" 2>/dev/null || echo "")
  if [[ -n "${repo}" ]]; then
    echo "git_merge=$(git -C "${LIVEMASK_ROOT}/${repo}" log --oneline --grep '${tid}' -1 2>/dev/null || echo 'NONE')"
  fi

  # GitHub issue state
  local issue; issue=$(python3 -c "
import json
ledger=json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id')=='${tid}': print(t.get('issue','')); break
" 2>/dev/null || echo "")
  if [[ -n "${issue}" ]]; then
    # Extract owner/repo/number
    local gh_repo gh_num
    if gh_repo=$(echo "${issue}" | grep -oE 'MyAiDevs/livemask-[a-z-]+' | head -1) && gh_num=$(echo "${issue}" | grep -oE '[0-9]+$' | head -1); then
      echo "github_issue=$(gh issue view "${gh_num}" --repo "${gh_repo}" --json state,title,closedAt --jq '{state,title,closedAt}' 2>/dev/null || echo 'unavailable')"
    fi
  else
    echo "github_issue=NONE"
  fi
}

# ── Phase 3: Gap Reasoning — "Why is work not flowing?" ─────────────────
reasoning_flow_diagnosis() {
  cat << REASONING_PROMPT
=== FLOW DIAGNOSIS REASONING CHECKPOINT ===

Tasks are stuck. Reason through WHY work isn't flowing through the system:

1. SUPPLY SIDE (tasks entering the queue):
   - Are Ready contracts decomposed into tasks? (check contract-index.md vs ledger)
   - Do tasks have dispatch packets? (check dispatch-packets/ directory)
   - Do tasks have GitHub issues linked? (check ledger 'issue' field)
   - If any NO: the supply chain is broken. Fix it.

2. DISPATCH SIDE (tasks being picked up):
   - Does startup detect work? (check preflight output)
   - Does Claude executor accept tasks? (check agent-state.json phase changes)
   - If work exists but isn't accepted: the acceptance mechanism is broken.

3. EXECUTION SIDE (tasks being implemented):
   - Are in_progress tasks actually progressing? (check git activity in target repos)
   - Are tasks stuck in implementing phase without commits?
   - If stuck: diagnose why. Missing dependency? Unclear requirements?

4. COMPLETION SIDE (tasks being closed):
   - Are completed tasks genuinely done? (verify each with reasoning_verify_task)
   - Are review contracts being created?
   - Is evidence being recorded?
   - If fake completions: revert them and investigate root cause.

5. BOTTLENECK IDENTIFICATION:
   - Count tasks at each stage: draft→ready→in_progress→implemented→verified→completed
   - Where is the biggest pileup?
   - What's blocking that stage specifically?

6. ROOT CAUSE (trace to the WHY):
   - Don't just say "tasks are stuck". Say WHY they're stuck.
   - Example: "TASK-X is ready but has no dispatch packet because the PM loop
     didn't create one. The PM loop didn't create one because it was busy
     auto-creating TASK-AUTO tasks instead of dispatching real tasks."
REASONING_PROMPT

  # Flow statistics
  echo ""
  echo "=== FLOW STATISTICS ==="
  python3 -c "
import json
from collections import Counter
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
statuses = Counter()
no_issue = 0
no_doc = 0
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        statuses[t.get('status','?')] += 1
        if not t.get('issue'): no_issue += 1
        if not t.get('task_doc'): no_doc += 1
print('=== Status Distribution ===')
for s,c in statuses.most_common():
    print(f'{s}: {c}')
print(f'\ntasks_without_issue: {no_issue}')
print(f'tasks_without_doc: {no_doc}')
print(f'total_tasks: {sum(statuses.values())}')

# Check for in_progress tasks without recent git activity
import subprocess, pathlib
stuck = []
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('status') == 'in_progress':
            tid = t.get('task_id','')
            repo = t.get('repo','')
            if repo:
                r = subprocess.run(['git','-C',f'${LIVEMASK_ROOT}/{repo}','log','--oneline','--since=3 days ago','--grep',tid,'-1'], capture_output=True, text=True)
                if not r.stdout.strip():
                    stuck.append(f'{tid} ({repo}): no commits in 3 days')
if stuck:
    print(f'\n=== Stuck in_progress tasks ({len(stuck)}) ===')
    for s in stuck[:10]: print(s)
" 2>/dev/null
}

# ── Phase 4: Self-Healing Reasoning — "What can I fix automatically?" ─────
reasoning_self_heal() {
  cat << REASONING_PROMPT
=== SELF-HEALING REASONING CHECKPOINT ===

Detect and auto-fix common issues. For each category, check and fix:

1. STALE LEASES:
   - PM lease > 30min old? → auto-release it
   - Task leases with no git activity in 7 days? → mark stale

2. ORPHANED ARTIFACTS:
   - Dispatch packets without matching ledger entries? → remove
   - Task docs without ledger entries? → add or flag
   - TASK-AUTO artifacts without issue links? → add issue or remove

3. MODULE STATUS MISMATCH:
   - Module overall_status != derived from task statuses? → fix

4. DOC/LEDGER CONFLICTS:
   - Task doc Status != ledger status? → trace evidence
   - Can auto-resolve? (review contract approved + dev merge) → fix
   - Cannot auto-resolve? → flag for human with specific evidence gap

5. DISPATCH PACKET STALENESS:
   - Packets > 24h old without acceptance? → check why
   - Task assigned but agent phase still idle? → dispatch failure

6. CI STATE:
   - Latest docs CI failed? → diagnose and fix
   - Repo CI failing? → flag with link to failed run

FOR EACH ISSUE FOUND:
   - If auto-fixable: apply the fix AND record what you did
   - If not auto-fixable: create a specific, actionable finding
   - Never say "needs human decision" without specifying exactly what decision
REASONING_PROMPT

  # Auto-detect common issues
  echo ""
  echo "=== SELF-HEAL DIAGNOSTICS ==="

  # PM lease staleness
  local lease_file="${ROLE_CACHE_DIR}/pm-lease.json"
  if [[ -f "${lease_file}" ]]; then
    python3 -c "
import json, time
d=json.load(open('${lease_file}'))
age=(time.time()-d.get('started_at_epoch',0))/60
if age > 30: print(f'STALE_PM_LEASE: {age:.0f}min old, agent={d.get(\"agent\",\"?\")}, phase={d.get(\"phase\",\"?\")}')
else: print(f'pm_lease_ok: {age:.0f}min')
" 2>/dev/null
  fi

  # Module status consistency
  python3 -c "
import json
from collections import Counter
ledger=json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
open_s={'draft','ready','in_progress','implemented','verified','partial','blocked','evidence_missing'}
for m in ledger.get('modules',[]):
    tasks=m.get('tasks',[])
    if not tasks: continue
    has_open=any(t.get('status') in open_s for t in tasks)
    expected='partial' if has_open else 'completed'
    actual=m.get('overall_status','?')
    if actual != expected:
        print(f'MODULE_MISMATCH: {m[\"module_id\"]} overall={actual} expected={expected} (open_tasks={has_open})')
" 2>/dev/null

  # Dispatch packet staleness
  python3 -c "
import json, pathlib, datetime
dispatch_dir = pathlib.Path('${DOCS_DIR}/docs/development/dispatch-packets')
if dispatch_dir.exists():
    now = datetime.datetime.now(datetime.timezone.utc)
    for pf in sorted(dispatch_dir.glob('TASK-*.json')):
        d = json.loads(pf.read_text())
        assigned = d.get('assigned_at','')
        if assigned:
            try:
                at = datetime.datetime.fromisoformat(assigned.replace('Z','+00:00'))
                age_h = (now - at).total_seconds() / 3600
                if age_h > 24:
                    print(f'STALE_PACKET: {d[\"task_id\"]} assigned {age_h:.0f}h ago to {d.get(\"assigned_to\",\"?\")}')
            except: pass
" 2>/dev/null

  # Docs CI check
  if command -v gh &>/dev/null; then
    gh run list --repo MyAiDevs/livemask-docs --limit 1 --json conclusion,createdAt,displayTitle 2>/dev/null | python3 -c "
import json,sys
try:
    runs=json.load(sys.stdin)
    if runs:
        r=runs[0]
        if r.get('conclusion')=='failure':
            print(f'DOCS_CI_FAILED: {r.get(\"displayTitle\",\"?\")} at {r.get(\"createdAt\",\"?\")}')
        else:
            print(f'docs_ci: {r.get(\"conclusion\",\"?\")}')
except: print('docs_ci: unavailable')
"
  fi
}

# ── Phase 5: Memory Quick Retrieval ──────────────────────────────────────
reasoning_memory_retrieve() {
  local query="${1:-}"
  local limit="${2:-10}"

  cat << REASONING_PROMPT
=== MEMORY RETRIEVAL REASONING ===

Retrieved memories for context. Use these to inform your decisions:
- Project memories tell you WHY certain decisions were made
- Feedback memories tell you HOW to approach the work
- Reference memories tell you WHERE to look for external info

DO NOT treat memories as current fact — verify against actual repo state.
DO use memories to understand context and avoid repeating past mistakes.
REASONING_PROMPT

  echo ""
  echo "=== MEMORY RESULTS ==="

  if [[ -d "${MEMORY_DIR}" ]]; then
    if [[ -n "${query}" ]]; then
      # Search for query in memory files
      grep -rl "${query}" "${MEMORY_DIR}" --include="*.md" 2>/dev/null | while read f; do
        local name; name=$(basename "${f}" .md)
        local desc; desc=$(head -3 "${f}" 2>/dev/null | grep "description:" | sed 's/.*description: *//' | head -1)
        echo "  MEMORY: ${name} — ${desc:-no description}"
      done | head -"${limit}"
    else
      # List recent memories
      ls -t "${MEMORY_DIR}"/*.md 2>/dev/null | head -"${limit}" | while read f; do
        local name; name=$(basename "${f}" .md)
        [[ "${name}" == "MEMORY" ]] && continue
        local desc; desc=$(head -3 "${f}" 2>/dev/null | grep "description:" | sed 's/.*description: *//' | head -1)
        echo "  MEMORY: ${name} — ${desc:-no description}"
      done
    fi
  else
    echo "  (no memory directory at ${MEMORY_DIR})"
  fi
}

# ── Phase 6: GitHub Quick Context ─────────────────────────────────────────
reasoning_github_context() {
  local repo="${1:-livemask-docs}"
  local limit="${2:-5}"

  cat << REASONING_PROMPT
=== GITHUB CONTEXT REASONING ===

Use this GitHub context to inform your decisions. Key sources:
- Fixed channels: livemask-ci-cd#14 (rules), livemask-docs#68 (control plane)
- Repo issues: linked to tasks
- CI runs: pass/fail state

Verify issue state before acting on it. Don't assume a closed issue means done.
REASONING_PROMPT

  echo ""
  echo "=== GITHUB DATA ==="

  # Fixed channels
  for ch in "MyAiDevs/livemask-ci-cd:14" "MyAiDevs/livemask-docs:68"; do
    local ch_repo="${ch%%:*}"
    local ch_num="${ch##*:}"
    echo "--- Fixed Channel: ${ch_repo}#${ch_num} ---"
    gh issue view "${ch_num}" --repo "${ch_repo}" --json state,title,updatedAt --jq '{state,title,updatedAt}' 2>/dev/null || echo "  unavailable"
    # Last 2 comments
    gh issue view "${ch_num}" --repo "${ch_repo}" --json comments --jq '.comments[-2:] | .[] | "  comment by \(.author.login): \(.body[:200])"' 2>/dev/null || true
  done

  # Recent CI
  echo "--- CI Status ---"
  for r in livemask-docs livemask-ci-cd livemask-backend livemask-admin; do
    gh run list --repo "MyAiDevs/${r}" --limit 1 --json conclusion,createdAt 2>/dev/null | python3 -c "
import json,sys
try:
    runs=json.load(sys.stdin)
    if runs: print(f'  ${r}: {runs[0].get(\"conclusion\",\"?\")} ({runs[0].get(\"createdAt\",\"?\")[:16]})')
except: print(f'  ${r}: unavailable')
"
  done

  # Recent issues with task labels
  echo "--- Recent Task Issues (${repo}) ---"
  gh issue list --repo "MyAiDevs/${repo}" --limit "${limit}" --state all --json number,title,state,url,updatedAt 2>/dev/null | python3 -c "
import json,sys
for i in json.load(sys.stdin):
    print(f'  {i[\"state\"]} #{i[\"number\"]}: {i[\"title\"][:80]}')
" 2>/dev/null || echo "  unavailable"
}

# ── Phase 7: Local Verification Reasoning ─────────────────────────────────
reasoning_local_verify() {
  local repo="${1:-livemask-docs}"

  cat << REASONING_PROMPT
=== LOCAL VERIFICATION REASONING ===

Before claiming a task is done, verify it locally:
1. Does the code compile/build?
2. Do tests pass?
3. Is the code formatted/linted?
4. Does the change match the task doc requirements?

Run actual verification commands, don't just check checkboxes.
REASONING_PROMPT

  echo ""
  echo "=== VERIFICATION FOR ${repo} ==="

  local repo_dir="${LIVEMASK_ROOT}/${repo}"
  if [[ ! -d "${repo_dir}" ]]; then
    echo "ERROR: repo directory not found: ${repo_dir}"
    return 1
  fi

  cd "${repo_dir}" 2>/dev/null || return 1

  case "${repo}" in
    livemask-docs)
      echo "--- check-docs.sh ---"
      bash scripts/check-docs.sh 2>&1 | tail -5
      echo "--- git diff --check ---"
      git diff --check 2>&1 | head -5 || echo "  clean"
      ;;
    livemask-ci-cd)
      echo "--- bash syntax check ---"
      find scripts -name "*.sh" -exec bash -n {} \; 2>&1 | head -10 || echo "  all clean"
      echo "--- git diff --check ---"
      git diff --check 2>&1 | head -5 || echo "  clean"
      ;;
    livemask-backend)
      echo "--- go build ---"
      go build ./... 2>&1 | tail -5 || echo "  build failed"
      echo "--- go test ---"
      go test ./... 2>&1 | tail -10 || echo "  tests failed"
      ;;
    livemask-admin)
      echo "--- npm run build ---"
      npm run build 2>&1 | tail -5 || echo "  build failed"
      echo "--- npm test ---"
      npm test 2>&1 | tail -10 || echo "  tests failed"
      ;;
    *)
      echo "--- git status ---"
      git status --short 2>&1 | head -5 || echo "  clean"
      ;;
  esac

  cd "${LIVEMASK_ROOT}" 2>/dev/null || true
}

# ── Full Reasoning Cycle ──────────────────────────────────────────────────
reasoning_full_cycle() {
  echo "=== BEGIN FULL REASONING CYCLE ==="
  echo ""

  reasoning_memory_retrieve "dispatch task review" 5
  echo ""

  reasoning_startup_decision
  echo ""

  reasoning_flow_diagnosis
  echo ""

  reasoning_self_heal
  echo ""

  reasoning_github_context "livemask-docs" 5
  echo ""

  echo "=== END REASONING CYCLE ==="
  echo ""
  echo "NEXT: Based on the reasoning checkpoints above, make a decision and act."
  echo "Do NOT just print this output — use it to decide what to do next."
}
