#!/usr/bin/env bash
# impl-assist.sh — Model code implementation assistant.
# Bridges the gap between "system manages tasks" and "model writes code".
# When a task is accepted, this provides structured implementation guidance.
set -euo pipefail

LIVEMASK_ROOT="${LIVEMASK_ROOT:-/Users/sammytan/Developer/LiveMask}"
DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"

# ── Generate implementation plan from task doc ───────────────────────────
impl_generate_plan() {
  local tid="${1:-}"; [[ -z "${tid}" ]] && { echo "Usage: impl_generate_plan <TASK-ID>"; return 1; }

  local task_doc="${DOCS_DIR}/docs/development/tasks/${tid}.md"
  [[ ! -f "${task_doc}" ]] && { echo "ERROR: task doc not found"; return 1; }

  python3 - "${task_doc}" "${tid}" "${DOCS_DIR}" "${LIVEMASK_ROOT}" <<'PY'
import json,pathlib,re,sys

task_doc=pathlib.Path(sys.argv[1]); tid=sys.argv[2]
docs=pathlib.Path(sys.argv[3]); root=pathlib.Path(sys.argv[4])

content=task_doc.read_text()

# Extract task info
repo=None; priority="P2"
for line in content.split('\n'):
    if 'Repository:' in line: repo=line.split('Repository:')[1].strip().split()[0]
    if 'Priority:' in line: priority=line.split('Priority:')[1].strip()

# Find repo from ledger if not in doc
if not repo:
    ledger=json.loads((docs/'docs/development/task-state-ledger.json').read_text())
    for m in ledger.get('modules',[]):
        for t in m.get('tasks',[]):
            if t.get('task_id')==tid: repo=t.get('repo',''); break

# Extract scope/description
scope=""
in_scope=False
for line in content.split('\n'):
    if '## 2. Scope' in line or '### In Scope' in line: in_scope=True; continue
    if in_scope and line.startswith('##'): break
    if in_scope and line.strip().startswith('- '): scope+=line.strip()[2:]+'; '

# Determine implementation type from task content
impl_type="unknown"
content_lower=content.lower()
if 'api' in content_lower or 'endpoint' in content_lower: impl_type='api'
elif 'dashboard' in content_lower or 'panel' in content_lower or 'ui' in content_lower: impl_type='ui'
elif 'smoke' in content_lower or 'test' in content_lower: impl_type='test'
elif 'ci' in content_lower or 'pipeline' in content_lower or 'build' in content_lower: impl_type='ci-cd'
elif 'protocol' in content_lower or 'vpn' in content_lower: impl_type='protocol'
elif 'config' in content_lower or 'settings' in content_lower: impl_type='config'

# Repo-specific guidance
repo_guidance={
    'livemask-backend': {
        'dir': 'internal/<domain>/',
        'files': ['handler.go','service.go','store.go'],
        'test': 'go test ./internal/<domain>/...',
        'build': 'go build ./...',
        'pattern': 'Follow existing handler→service→store pattern. Register route in main.go.',
    },
    'livemask-admin': {
        'dir': 'src/pages/<domain>/ or src/components/<domain>/',
        'files': ['index.tsx','api.ts','types.ts'],
        'test': 'npm test -- --testPathPattern=<domain>',
        'build': 'npm run build',
        'pattern': 'Follow Next.js pages pattern. Use existing API client from src/lib/api.ts.',
    },
    'livemask-app': {
        'dir': 'lib/<domain>/',
        'files': ['<feature>_screen.dart','<feature>_provider.dart'],
        'test': 'flutter test test/<domain>/',
        'build': 'flutter analyze',
        'pattern': 'Follow Provider pattern. Use existing API models from lib/models/.',
    },
    'livemask-ci-cd': {
        'dir': 'scripts/',
        'files': ['<task-name>.sh'],
        'test': 'bash -n scripts/*.sh && bash scripts/<task-name>.sh',
        'build': 'bash -n scripts/*.sh',
        'pattern': 'Follow existing smoke script pattern. Use logging.sh for output.',
    },
    'livemask-nodeagent': {
        'dir': 'internal/<domain>/',
        'files': ['handler.go','service.go'],
        'test': 'go test ./internal/<domain>/...',
        'build': 'go build ./...',
        'pattern': 'Follow existing handler pattern. Register in main.go.',
    },
    'livemask-job-service': {
        'dir': 'internal/<domain>/',
        'files': ['job.go','executor.go'],
        'test': 'go test ./internal/<domain>/...',
        'build': 'go build ./...',
        'pattern': 'Follow Job+Executor pattern. Register job in worker registration.',
    },
    'livemask-website': {
        'dir': 'src/<domain>/',
        'files': ['index.tsx','api.ts'],
        'test': 'npm test',
        'build': 'npm run build',
        'pattern': 'Follow Vite+React pattern. Use existing API hooks.',
    },
    'livemask-docs': {
        'dir': 'docs/<domain>/',
        'files': ['README.md','contract.md'],
        'test': 'bash scripts/check-docs.sh',
        'build': 'bash scripts/check-docs.sh',
        'pattern': 'Follow existing doc patterns. Update contract-index.md if adding new contract.',
    },
}

guidance=repo_guidance.get(repo, {'dir':'<repo>/','files':['main'],'test':'repo-native tests','build':'repo-native build','pattern':'Follow existing patterns'})

print(f"""
=== IMPLEMENTATION PLAN: {tid} ===

Repository: {repo or 'UNKNOWN'}
Type: {impl_type}
Priority: {priority}
Scope: {scope[:200]}

--- File Structure ---
Create/edit files in: {guidance['dir']}
Expected files: {', '.join(guidance['files'])}

--- Implementation Pattern ---
{guidance['pattern']}

--- Verification ---
Build: {guidance['build']}
Test:  {guidance['test']}

--- Steps ---
1. cd {root}/{repo or 'livemask-backend'}
2. Create {guidance['dir']} if it doesn't exist
3. Implement: {scope[:150]}
4. Run: {guidance['build']}
5. Run: {guidance['test']}
6. git add -A && git commit -m "{tid}: implement {scope[:60]}"
7. Run: source {root}/livemask-ci-cd/scripts/lib/event-bus.sh && executor_notify commit {tid}

--- Acceptance Check ---
Read the task doc acceptance criteria and verify each:
""")

# Print acceptance criteria
for line in content.split('\n'):
    if '- [ ]' in line or '- [x]' in line:
        print(f"  {line.strip()}")

print(f"\nAfter implementation: source {root}/livemask-ci-cd/scripts/lib/review-gate.sh && executor_submit_review {tid}")
PY
}

# ── Quick repo context for implementation ────────────────────────────────
impl_repo_context() {
  local repo="${1:-livemask-backend}"
  local repo_dir="${LIVEMASK_ROOT}/${repo}"
  [[ ! -d "${repo_dir}" ]] && { echo "ERROR: repo not found"; return 1; }

  echo "=== REPO CONTEXT: ${repo} ==="
  echo "Branch: $(git -C "${repo_dir}" branch --show-current 2>/dev/null || echo ?)"
  echo "Last commit: $(git -C "${repo_dir}" log --oneline -1 2>/dev/null || echo ?)"
  echo "Dirty files: $(git -C "${repo_dir}" status --porcelain 2>/dev/null | wc -l | tr -d ' ' || echo ?)"
  echo ""

  # Show recent changes to identify patterns
  echo "Recent changes (5 commits):"
  git -C "${repo_dir}" log --oneline -5 2>/dev/null || echo "  (none)"
  echo ""

  # Show directory structure for context
  echo "Directory structure (top level):"
  ls -1 "${repo_dir}" 2>/dev/null | head -15
}

# ── Full implementation kickoff ──────────────────────────────────────────
impl_kickoff() {
  local tid="${1:-}"; [[ -z "${tid}" ]] && { echo "Usage: impl_kickoff <TASK-ID>"; return 1; }

  echo "═══════════════════════════════════════════"
  echo "  AUTONOMOUS IMPLEMENTATION KICKOFF"
  echo "═══════════════════════════════════════════"
  echo ""

  # 1. Accept task
  source "${CI_CD_DIR}/scripts/lib/event-bus.sh" 2>/dev/null || true
  source "${CI_CD_DIR}/scripts/lib/executor-guard.sh" 2>/dev/null || true
  event_emit "task_accepted" "${tid}" '{}' 2>/dev/null || true

  # 2. Load learnings
  executor_load_learnings "${tid}" 2>/dev/null || true

  # 3. Generate implementation plan
  impl_generate_plan "${tid}" 2>/dev/null || true

  # 4. Show repo context
  local repo; repo=$(python3 -c "import json;l=json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'));[print(t['repo']) for m in l['modules'] for t in m['tasks'] if t['task_id']=='${tid}']" 2>/dev/null || echo "")
  [[ -n "${repo}" ]] && impl_repo_context "${repo}" 2>/dev/null || true

  echo ""
  echo "═══════════════════════════════════════════"
  echo "  READY TO IMPLEMENT"
  echo "  Task: ${tid}"
  echo "  Repo: ${repo}"
  echo "  The implementation plan above tells you WHAT to build and WHERE."
  echo "  Write the code, verify, commit, then submit for review."
  echo "═══════════════════════════════════════════"
}
