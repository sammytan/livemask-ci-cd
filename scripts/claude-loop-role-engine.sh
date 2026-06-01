#!/usr/bin/env bash
# TASK-CICD-CLAUDE-ROLE-ENGINE-V2-001
# Multi-role reasoning engine. Each role does 3 deep analysis points, each
# tracing the "why" chain to root cause. Script gathers context, Claude reasons.
#
# Principle: Every detection MUST answer "why did this happen?" and produce
# a concrete next action. Nothing is just printed and forgotten.
#
# Roles: pm | product | tech | qa | task-review | deep-review | closure-audit | impact-analysis
# Usage: bash scripts/claude-loop-role-engine.sh <role> [TASK-ID]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/lark-card.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/health-check.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/reasoning-engine.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/github-ops.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/memory-fast.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/local-verify.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/ledger-intelligence.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/review-gate.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/monitor-learn.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/executor-guard.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/event-bus.sh" 2>/dev/null || true
log_setup "role-engine" 2>/dev/null || true
memory_init 2>/dev/null || true
monitor_init 2>/dev/null || true
event_init 2>/dev/null || true

LIVEMASK_ROOT="/Users/sammytan/Developer/LiveMask"
DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"
ROLE_CACHE_DIR="${HOME}/.claude/role-cache"
FINDINGS_FILE="${ROLE_CACHE_DIR}/findings.jsonl"
AGENT_STATE="${LIVEMASK_ROOT}/.claude/agent-state.json"
LEASE_FILE="${DOCS_DIR}/docs/development/leases/task-leases.json"
DISPATCH_DIR="${DOCS_DIR}/docs/development/dispatch-packets"
ADAPTER_LIB="${CI_CD_DIR}/scripts/event-adapters/lib/adapter-lib.sh"
AUTO_FIXED_TASKS=""
AUTO_CREATED_TASKS=""
PM_SKIP=0
COORDINATION_DECISION="proceed"
COORDINATION_NEXT_ACTOR="claude-role-engine"
COORDINATION_STATUS_FILE="/tmp/claude/role-engine-coordination-status.json"
ROLE="${1:-pm}"
ARG2="${2:-}"
ROLE_ENGINE_START_DIR="$(pwd)"
SELF_SCRIPT="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
SELF_ARGS=("$@")
SELF_CI_CD_HEAD_AT_START="$(git -C "${CI_CD_DIR}" rev-parse HEAD 2>/dev/null || echo "")"

hot_reload_if_ci_cd_updated() {
  local reason="${1:-ci-cd sync}"
  local current_head changed

  current_head="$(git -C "${CI_CD_DIR}" rev-parse HEAD 2>/dev/null || echo "")"
  [[ -z "${SELF_CI_CD_HEAD_AT_START}" || -z "${current_head}" ]] && return 0
  [[ "${current_head}" == "${SELF_CI_CD_HEAD_AT_START}" ]] && return 0

  changed="$(git -C "${CI_CD_DIR}" diff --name-only "${SELF_CI_CD_HEAD_AT_START}" "${current_head}" -- \
    scripts/claude-loop-role-engine.sh \
    scripts/claude-loop-startup.sh \
    scripts/lib \
    scripts/event-adapters/lib/adapter-lib.sh 2>/dev/null | head -1 || true)"
  [[ -z "${changed}" ]] && return 0

  if [[ "${CLAUDE_LOOP_HOT_RELOADED:-}" == "role-engine:${current_head}" ]]; then
    echo "  [HOT-RELOAD] role-engine already attempted for ${current_head:0:7}; continuing"
    return 0
  fi

  echo ""
  echo "  [HOT-RELOAD] role-engine code changed during ${reason}: ${SELF_CI_CD_HEAD_AT_START:0:7} -> ${current_head:0:7}"
  echo "  changed: ${changed}"
  echo "  exec: bash ${SELF_SCRIPT} ${SELF_ARGS[*]:-}"
  export CLAUDE_LOOP_HOT_RELOADED="role-engine:${current_head}"
  cd "${ROLE_ENGINE_START_DIR}" 2>/dev/null || true
  trap - EXIT
  exec bash "${SELF_SCRIPT}" "${SELF_ARGS[@]}"
}

# ── Workspace guard: NEVER leave the working tree dirty ──────────────────────
# Trap EXIT ensures cleanup runs even if the script crashes mid-cycle
cleanup_workspace() {
  local exit_code=$?
  cd "${DOCS_DIR}" 2>/dev/null || true

  # 1. Switch back to dev (no matter what branch we're on)
  local current_br; current_br=$(git branch --show-current 2>/dev/null || echo "")
  if [[ -n "${current_br}" && "${current_br}" != "dev" ]]; then
    # Only stash if there are actual uncommitted changes on this branch.
    # NEVER stash --include-untracked blindly — it can nuke user files.
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
      git stash -m "auto-stash: role-engine cleanup $(date -u +%Y%m%d-%H%M%S)" 2>/dev/null || true
    fi
    git checkout dev 2>/dev/null || true
  fi

  # 2. Clean up leftover task branches from this run.
  # Preserve any branch whose tip has not reached dev; otherwise a failed
  # merge/guard can leave only a dangling commit and hide real control-plane
  # work from the next loop.
  for br in $(git branch --list "task/pm-auto-reconcile-*" "task/auto-create-*" "task/role-*" "task/fallback-sap-*" --format='%(refname:short)' 2>/dev/null); do
    if git merge-base --is-ancestor "${br}" dev 2>/dev/null; then
      git branch -D "${br}" 2>/dev/null || true
    else
      echo "  [CLEANUP] preserving unmerged branch ${br}"
    fi
  done

  # 3. Release PM lease if held
  if [[ -f "${PM_LEASE_FILE:-}" ]]; then
    local cleanup_agent="${ROLE:-unknown}"
    [[ "${cleanup_agent}" == "all" ]] && cleanup_agent="claude-pm-backup"
    python3 -c "
import json, pathlib
try:
    d = json.load(open('${PM_LEASE_FILE}'))
    if d.get('agent') == '${cleanup_agent}' and d.get('phase') != 'complete':
        d['phase'] = 'complete'
        d['completed_at'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
        pathlib.Path('${PM_LEASE_FILE}').write_text(json.dumps(d, indent=2))
except: pass
" 2>/dev/null || true
  fi

  # 4. Pull latest dev (so we're synced for next cycle)
  git pull --ff-only origin dev 2>/dev/null || true

  exit ${exit_code}
}
trap cleanup_workspace EXIT

# ── Auto-create task from finding (therapeutic layer) ────────────────────────
# Only creates if finding is actionable AND no existing task covers it.
# Returns task_id if created, empty string if skipped.
auto_create_task() {
  local role="$1" check="$2" title="$3" priority="${4:-P1}" repo="${5:-livemask-ci-cd}" body="${6:-}"
  case "${repo}" in
    livemask-backend|livemask-admin|livemask-app|livemask-website|livemask-ci-cd|livemask-nodeagent|livemask-job-service|livemask-docs) ;;
    *)
      echo "    (skip auto-create: repo '${repo}' is not a canonical ledger repo)"
      record_finding "${role}" "warning" "" "${check}" \
        "auto-create skipped because repo '${repo}' is not a canonical ledger repo" \
        "decompose this cross-repo finding into one canonical TASK per livemask-* repo before dispatch" \
        ""
      return 0
      ;;
  esac

  # ── Global guard: prevent Claude↔Codex ping-pong ──────────────────────────
  # If there are already >=3 TASK-AUTO tasks in open status (ready/in_progress/
  # blocked/partial), skip auto-creation. Too many auto-tasks mean they're not
  # being dispatched and implemented — creating more only feeds the oscillation.
  local open_auto_count; open_auto_count=$(python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
open_statuses = {'ready','in_progress','blocked','partial','implemented','verified','evidence_missing'}
count = 0
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        tid = t.get('task_id','')
        if tid.startswith('TASK-AUTO-') and t.get('status','') in open_statuses:
            count += 1
print(count)
" 2>/dev/null || echo "0")
  if [[ "${open_auto_count:-0}" -ge 3 ]]; then
    echo "    (skip auto-create: ${open_auto_count} open TASK-AUTO tasks already pending — dispatch and implement existing tasks before creating more)"
    record_finding "${role}" "warning" "" "${check}" \
      "auto-create skipped: ${open_auto_count} open TASK-AUTO tasks already exist — dispatch/implement them first" \
      "stop creating new tasks; pick up and implement existing dispatched tasks" \
      "bash ${CI_CD_DIR}/scripts/claude-loop-startup.sh"
    return 0
  fi

  # Generate short, ledger-compliant task ID: TASK-AUTO-{REPO-SHORT}-{UNIQ}
  local repo_short; repo_short=$(echo "${repo}" | sed 's/livemask-//' | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]\+/-/g; s/^-//; s/-$//' | cut -c1-16)
  [[ -n "${repo_short}" ]] || repo_short="MISC"
  local uniq; uniq=$(echo "${title}" | tr '[:lower:] ' '[:upper:]-' | sed 's/[^A-Z0-9-]//g' | tr '-' '\n' | head -4 | tr '\n' '-' | cut -c1-20)
  local tid="TASK-AUTO-${repo_short}-${uniq}"
  tid="${tid%-}"  # strip trailing dash
  tid=$(echo "${tid}" | cut -c1-60)  # hard cap at 60 chars

  if [[ "${COORDINATION_DECISION:-proceed}" != "proceed" ]]; then
    echo "    (coordination ${COORDINATION_DECISION}: skip creating ${tid}; next actor=${COORDINATION_NEXT_ACTOR})"
    record_finding "${role}" "info" "${tid}" "${check}" \
      "auto-create skipped by coordination guard (${COORDINATION_DECISION})" \
      "wait for ${COORDINATION_NEXT_ACTOR} or rerun after active work completes" \
      "bash ${ADAPTER_LIB} coordination-status claude-role-engine ${tid}"
    return 0
  fi

  # Check if task already exists in ledger
  local exists; exists=$(python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id','') == '${tid}': print('yes'); break
" 2>/dev/null || echo "")
  [[ -n "${exists}" ]] && { echo "    (task ${tid} already exists — skip)"; return 0; }

  # Check for duplicate in this cycle
  if echo "${AUTO_CREATED_TASKS}" | grep -q "${tid}"; then
    return 0
  fi

  local intelligence_file="${ROLE_CACHE_DIR}/task-intelligence-${tid}.json"
  mkdir -p "${ROLE_CACHE_DIR}" "$(dirname "${COORDINATION_STATUS_FILE}")"
  TASK_ID="${tid}" TASK_TITLE="${title}" TASK_BODY="${body}" TASK_REPO="${repo}" \
    TASK_ROLE="${role}" TASK_CHECK="${check}" DOCS_DIR="${DOCS_DIR}" python3 - "${intelligence_file}" <<'PY' 2>/dev/null || true
import json, os, re, subprocess, sys
from pathlib import Path

out = Path(sys.argv[1])
docs_root = Path(os.environ["DOCS_DIR"])
docs_tree = docs_root / "docs"
tid = os.environ["TASK_ID"]
title = os.environ["TASK_TITLE"]
body = os.environ["TASK_BODY"]
repo = os.environ["TASK_REPO"]
role = os.environ["TASK_ROLE"]
check = os.environ["TASK_CHECK"]

stop = {
    "task", "auto", "implement", "add", "fix", "sync", "for", "and", "the",
    "with", "from", "ready", "contract", "documentation", "smoke", "tests",
    "test", "pipeline", "role", "engine", "finding", "create", "across",
}
tokens = []
for token in re.findall(r"[A-Za-z0-9]{3,}", f"{title} {body} {repo}"):
    low = token.lower()
    if low not in stop and low not in tokens:
        tokens.append(low)
tokens = tokens[:12]

def read_json(path, default):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except Exception:
        return default

ledger = read_json(docs_root / "docs/development/task-state-ledger.json", {"modules": []})
related_tasks = []
duplicate_signals = []
issue_urls = []
for module in ledger.get("modules", []):
    for task in module.get("tasks", []):
        text = " ".join(str(task.get(k, "")) for k in ("task_id", "repo", "status", "notes", "validation", "task_doc"))
        text_low = text.lower()
        overlap = [t for t in tokens if t in text_low]
        same_repo = task.get("repo") == repo
        if same_repo or len(overlap) >= 2:
            related_tasks.append({
                "task_id": task.get("task_id", ""),
                "repo": task.get("repo", ""),
                "status": task.get("status", ""),
                "priority": task.get("priority", ""),
                "task_doc": task.get("task_doc", ""),
                "issue": task.get("issue", ""),
                "relation": "same_repo" if same_repo else "keyword_overlap",
                "matched_terms": overlap[:6],
            })
        issue = str(task.get("issue", ""))
        if issue.startswith("http") and (same_repo or overlap):
            issue_urls.append(issue)
        if task.get("status") in ("ready", "dispatched", "in_progress", "blocked", "partial") and len(overlap) >= 4:
            duplicate_signals.append({
                "task_id": task.get("task_id", ""),
                "status": task.get("status", ""),
                "reason": f"high keyword overlap: {', '.join(overlap[:6])}",
            })

context_docs = []
allowed_suffixes = {".md", ".json", ".yaml", ".yml"}
for path in docs_tree.rglob("*"):
    if not path.is_file() or path.suffix.lower() not in allowed_suffixes:
        continue
    rel = path.relative_to(docs_root).as_posix()
    if "/node_modules/" in rel or "/.git/" in rel:
        continue
    score = 0
    rel_low = rel.lower()
    if repo.replace("livemask-", "") in rel_low:
        score += 3
    try:
        sample = path.read_text(encoding="utf-8", errors="ignore")[:8000].lower()
    except Exception:
        sample = ""
    matched = []
    for token in tokens:
        if token in rel_low or token in sample:
            score += 1
            matched.append(token)
    if score:
        context_docs.append({"path": rel, "score": score, "matched_terms": matched[:8]})
context_docs.sort(key=lambda d: (-d["score"], d["path"]))

repo_doc_hints = {
    "livemask-backend": ["docs/backend", "docs/contracts", "docs/data", "docs/architecture"],
    "livemask-admin": ["docs/admin", "docs/contracts", "docs/design", "docs/architecture"],
    "livemask-app": ["docs/app", "docs/contracts", "docs/architecture"],
    "livemask-nodeagent": ["docs/nodeagent", "docs/contracts", "docs/architecture"],
    "livemask-job-service": ["docs/job-service", "docs/contracts", "docs/operations"],
    "livemask-ci-cd": ["docs/development", "docs/operations", "docs/contracts"],
    "livemask-docs": ["docs/development", "docs/contracts", "docs/architecture"],
}

quality_gates = [
    "git diff --check",
    "run the repo-native formatter/linter/test suite for touched files",
    "do not introduce a new abstraction when an existing project helper or contract already covers the behavior",
    "update docs/contracts or task evidence when behavior, API, schema, CI, or runtime expectations change",
]
if repo == "livemask-docs":
    quality_gates.insert(0, "bash scripts/check-docs.sh")
elif repo == "livemask-backend":
    quality_gates.extend(["go test ./...", "verify OpenAPI/Swagger docs when routes or DTOs change"])
elif repo == "livemask-admin":
    quality_gates.extend(["npm test", "npm run build", "browser/network evidence for UI acceptance"])
elif repo == "livemask-ci-cd":
    quality_gates.extend(["bash -n changed shell scripts", "run the matching smoke script in dry-run/local mode when available"])

issue_context = []
search_query = " ".join(tokens[:5]) or title[:80]
if repo and re.match(r"^livemask-[A-Za-z0-9-]+$", repo):
    try:
        raw = subprocess.check_output([
            "gh", "issue", "list", "--repo", f"MyAiDevs/{repo}",
            "--search", search_query, "--state", "all", "--limit", "5",
            "--json", "number,title,state,url,updatedAt",
        ], text=True, timeout=8, stderr=subprocess.DEVNULL)
        for item in json.loads(raw):
            comments = []
            try:
                detail = subprocess.check_output([
                    "gh", "issue", "view", str(item["number"]), "--repo", f"MyAiDevs/{repo}",
                    "--json", "comments", "--jq", ".comments[-2:]",
                ], text=True, timeout=8, stderr=subprocess.DEVNULL)
                comments = json.loads(detail) if detail.strip() else []
            except Exception:
                comments = []
            issue_context.append({**item, "recent_comments": [
                {
                    "author": c.get("author", {}).get("login", ""),
                    "createdAt": c.get("createdAt", ""),
                    "body_excerpt": (c.get("body", "") or "")[:240],
                }
                for c in comments
            ]})
    except Exception:
        issue_context = []

summary = {
    "schema_version": 1,
    "task_id": tid,
    "title": title,
    "repo": repo,
    "source": {"role": role, "check": check, "body_excerpt": body[:600]},
    "query_terms": tokens,
    "duplicate_blocker": bool(duplicate_signals),
    "duplicate_signals": duplicate_signals[:8],
    "related_tasks": related_tasks[:12],
    "context_docs": context_docs[:20],
    "repo_doc_hints": repo_doc_hints.get(repo, ["docs/development", "docs/contracts", "docs/architecture"]),
    "github_issue_candidates": issue_context,
    "ledger_issue_refs": sorted(set(issue_urls))[:10],
    "comment_association": "Use linked issue recent comments plus fixed channels #14/#68 as evidence; do not treat comments as a replacement for ledger/task-doc updates.",
    "code_quality_gates": quality_gates,
    "no_duplicate_rule": "If duplicate_signals is non-empty, do not create a new task; update or unblock the existing task instead.",
}
out.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
PY

  local duplicate_blocker=""
  duplicate_blocker=$(python3 -c "import json; d=json.load(open('${intelligence_file}')); print('yes' if d.get('duplicate_blocker') else '')" 2>/dev/null || echo "")
  if [[ -n "${duplicate_blocker}" ]]; then
    echo "    (duplicate task signal found — skip creating ${tid}; see ${intelligence_file})"
    bash "${ADAPTER_LIB}" memory-add "role-engine-duplicate-skip" "${tid}" "${repo}" \
      "auto-create skipped because intelligence pack found duplicate signals for ${title}" \
      "${intelligence_file}" >/dev/null 2>&1 || true
    return 0
  fi

  local issue_linked=""
  issue_linked=$(python3 -c "import json; d=json.load(open('${intelligence_file}')); print('yes' if (d.get('github_issue_candidates') or d.get('ledger_issue_refs')) else '')" 2>/dev/null || echo "")
  if [[ -z "${issue_linked}" ]]; then
    local issue_body issue_url
    issue_body="${ROLE_CACHE_DIR}/issue-${tid}.md"
    cat > "${issue_body}" << ISSUEBODY
Auto-created by Claude role-engine ${role}/${check}.

Task: ${tid}
Repo: ${repo}
Priority: ${priority}

Why now:
${title}

Context:
${body}

Evidence bundle:
${intelligence_file}

Rules:
- This issue is the GitHub linkage for the generated TASK doc, ledger entry, and dispatch packet.
- The implementer must cite task context, related docs, validation commands, CI/dev evidence, and any residual blockers before closure.
- Do not close until task doc, task-state-ledger, review contract, validation, and dev evidence agree.
ISSUEBODY
    issue_url=$(gh issue create \
      --repo "MyAiDevs/${repo}" \
      --title "${tid}: ${title}" \
      --body-file "${issue_body}" 2>/dev/null || true)
    if [[ -n "${issue_url}" ]]; then
      echo "    (created GitHub issue for ${tid}: ${issue_url})"
      python3 - "${intelligence_file}" "${issue_url}" "${repo}" "${title}" <<'PY' 2>/dev/null || true
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
url, repo, title = sys.argv[2:5]
d = json.loads(path.read_text(encoding="utf-8"))
d.setdefault("github_issue_candidates", []).insert(0, {
    "number": "",
    "title": title,
    "state": "OPEN",
    "url": url,
    "updatedAt": "",
    "recent_comments": [],
    "created_by_role_engine": True,
})
path.write_text(json.dumps(d, indent=2, ensure_ascii=False), encoding="utf-8")
PY
      issue_linked="yes"
    else
      echo "    (skip auto-create ${tid}: no GitHub issue/comment or ledger issue reference found; see ${intelligence_file})"
      record_finding "${role}" "warning" "" "${check}" \
        "auto-create skipped because no GitHub issue/comment linkage was found for ${title}" \
        "link or create a GitHub issue first, then create a canonical TASK with docs/context and quality gates" \
        "${intelligence_file}"
      bash "${ADAPTER_LIB}" memory-add "role-engine-auto-create-skip" "${tid}" "${repo}" \
        "auto-create skipped because no GitHub issue/comment or ledger issue reference existed for ${title}" \
        "${intelligence_file}" >/dev/null 2>&1 || true
      return 0
    fi
  fi

  # Create task doc with ALL required sections per check-docs.sh schema
  local task_doc="${DOCS_DIR}/docs/development/tasks/${tid}.md"
  local now_ts; now_ts=$(date -u +%Y-%m-%d)
  local context_pack_md cross_repo_impact_md quality_gates_md
  local context_pack_file quality_gates_file
  context_pack_file="${ROLE_CACHE_DIR}/context-pack-${tid}.md"
  quality_gates_file="${ROLE_CACHE_DIR}/quality-gates-${tid}.md"
  if python3 - "${intelligence_file}" > "${context_pack_file}" 2>/dev/null <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"- Intelligence pack: `{sys.argv[1]}`")
print(f"- Source: role-engine {d.get('source',{}).get('role','?')}/{d.get('source',{}).get('check','?')}")
print(f"- Query terms: {', '.join(d.get('query_terms', [])[:10]) or 'none'}")
print("- Required docs/context roots:")
for item in d.get("repo_doc_hints", [])[:8]:
    print(f"  - `{item}`")
if d.get("context_docs"):
    print("- Highest-signal project docs:")
    for item in d["context_docs"][:8]:
        terms = ", ".join(item.get("matched_terms", [])[:5])
        print(f"  - `{item['path']}` (score={item['score']}; terms={terms})")
if d.get("related_tasks"):
    print("- Related ledger tasks:")
    for item in d["related_tasks"][:8]:
        issue = f"; issue={item.get('issue')}" if item.get("issue") else ""
        print(f"  - `{item.get('task_id','?')}` status={item.get('status','?')} repo={item.get('repo','?')} relation={item.get('relation','?')}{issue}")
if d.get("github_issue_candidates"):
    print("- GitHub issue/comment candidates:")
    for item in d["github_issue_candidates"][:5]:
        print(f"  - {item.get('url')} [{item.get('state')}] {item.get('title')}")
        for c in item.get("recent_comments", [])[:2]:
            body = (c.get("body_excerpt") or "").replace("\n", " ")[:180]
            print(f"    - comment {c.get('createdAt','?')} by {c.get('author','?')}: {body}")
if d.get("duplicate_signals"):
    print("- Duplicate signals:")
    for item in d["duplicate_signals"][:5]:
        print(f"  - `{item.get('task_id')}` status={item.get('status')}: {item.get('reason')}")
print(f"- Comment association rule: {d.get('comment_association')}")
PY
  then
    context_pack_md="$(cat "${context_pack_file}")"
  else
    context_pack_md="- Intelligence pack unavailable; rerun role-engine before dispatch."
  fi
  cross_repo_impact_md=$(python3 -c "
repo='${repo}'
impacts = {'livemask-backend': '- Admin UI, App client, NodeAgent, Job Service, Website, CI/CD smoke', 'livemask-admin': '- CI/CD admin smoke tests', 'livemask-app': '- CI/CD app build/release smoke', 'livemask-nodeagent': '- Backend internal API, CI/CD node smoke', 'livemask-job-service': '- Backend executor endpoints, CI/CD job smoke', 'livemask-ci-cd': '- All repos (CI/CD script changes affect all)', 'livemask-docs': '- All repos (contract/rule changes need implementation)'}
print(impacts.get(repo, '- Related repos as identified during implementation'))
" 2>/dev/null)
  if python3 - "${intelligence_file}" > "${quality_gates_file}" 2>/dev/null <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
gates = d.get("code_quality_gates", [])
if not gates:
    print("- Run repo-native checks and document evidence.")
for gate in gates:
    print(f"- {gate}")
PY
  then
    quality_gates_md="$(cat "${quality_gates_file}")"
  else
    quality_gates_md="- Run repo-native checks and document evidence."
  fi
  cat > "${task_doc}" << TASKDOC
# ${tid} — ${title}

Edit provenance:
- Edited by: Claude Role Engine
- Window/role: livemask-ci-cd role-engine
- Date: ${now_ts}
- TASK ID: ${tid}
- Reason: auto-created from role-engine finding ${role}/${check}

> Status: ready
> Repository: ${repo}
> Priority: ${priority}
> Source: role-engine ${role}/${check}
> Created: ${now_ts}

## 1. Background

Role-engine ${role}/${check} detected an actionable gap: ${title}

${body}

### 1.1 Project Context Pack

${context_pack_md}

## 2. Scope

### In Scope
- Address the root cause identified by role-engine finding
- Implement the fix or improvement described above
- Reuse existing project helpers, contracts, schemas, runbooks, and task patterns found in the context pack
- Preserve or update related task/GitHub issue/comment evidence instead of creating an unlinked parallel lane

### Out of Scope
- Unrelated refactoring or feature additions
- Rebuilding an existing capability under a new name when a related task/helper already exists

## 3. Acceptance Criteria
- [ ] Root cause verified and addressed
- [ ] Implementation validated with appropriate evidence
- [ ] No regression in existing functionality
- [ ] Related task IDs, blockers, and unlocks from the context pack are explicitly handled
- [ ] Linked GitHub issue(s) and recent relevant comments are cited in the completion report or blocked note
- [ ] No duplicate TASK, dispatch packet, issue, helper, or CI lane is introduced
- [ ] Code follows the existing repo architecture and uses established helpers before adding new abstractions

## 4. Cross-Repo Impact

This task affects **${repo}**. Downstream repos to verify:
${cross_repo_impact_md}

## 5. Validation
- check-docs.sh PASS
- git diff --check PASS
- CI/CD pipeline green for affected repos

### 5.1 Code Quality Gates
${quality_gates_md}
TASKDOC

  # Add to ledger with valid field types
  python3 -c "
import json, pathlib
ledger_path = pathlib.Path('${DOCS_DIR}/docs/development/task-state-ledger.json')
intel_path = pathlib.Path('${intelligence_file}')
intel = json.loads(intel_path.read_text()) if intel_path.exists() else {}
ledger = json.loads(ledger_path.read_text())
module = None
for m in ledger.get('modules',[]):
    if m.get('module_id') == 'auto-tasks':
        module = m; break
if not module:
    module = {'module_id': 'auto-tasks', 'overall_status': 'partial', 'owner_repo': '${repo}', 'tasks': [], 'open_gaps': []}
    ledger['modules'].append(module)
module['tasks'].append({
    'task_id': '${tid}',
    'repo': '${repo}',
    'module_id': 'auto-tasks',
    'status': 'ready',
    'priority': '${priority}',
    'task_doc': 'docs/development/tasks/${tid}.md',
    'issue': (intel.get('github_issue_candidates') or [{}])[0].get('url',''),
    'validation': '',
    'dev_merge_commit': '',
    'remote_dev_ref': '',
    'blocked_by': [t.get('task_id') for t in intel.get('related_tasks', [])[:5] if t.get('status') in ('blocked','in_progress')],
    'unlocks': [],
    'notes': 'Auto-created by role-engine ${role}/${check}; context_pack=${intelligence_file}; related_tasks=' + ','.join(t.get('task_id','') for t in intel.get('related_tasks', [])[:8] if t.get('task_id')) + '; github_issues=' + ','.join(i.get('url','') for i in intel.get('github_issue_candidates', [])[:5] if i.get('url')) + '; quality_gates=' + ' | '.join(intel.get('code_quality_gates', [])[:6])
})
ledger_path.write_text(json.dumps(ledger, indent=2, ensure_ascii=False))
" 2>/dev/null

  # Create dispatch packet
  local dp_file="${DOCS_DIR}/docs/development/dispatch-packets/${tid}.json"
  python3 -c "
import json, pathlib, datetime
now = datetime.datetime.now(datetime.timezone.utc)
dp = {
    'schema_version': 1,
    'task_id': '${tid}',
    'repo': '${repo}',
    'priority': '${priority}',
    'readiness': 'ready',
    'assigned_to': 'claude',
    'assigned_at': now.strftime('%Y-%m-%dT%H:%M:%SZ'),
    'expires_at': (now + datetime.timedelta(hours=2)).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'assigned_by': 'Claude-Role-Engine',
    'reason': '${role}/${check}: ${title}',
    'why_now': ['${role}/${check}: ${title}'],
    'context': {
        'generated_by': 'Claude-Role-Engine',
        'source': 'role-engine PM-3 auto_create_task',
        'task_doc': 'docs/development/tasks/${tid}.md',
        'intelligence_pack': '${intelligence_file}',
        'context_docs': (json.loads(pathlib.Path('${intelligence_file}').read_text()).get('context_docs', [])[:8] if pathlib.Path('${intelligence_file}').exists() else []),
        'related_tasks': (json.loads(pathlib.Path('${intelligence_file}').read_text()).get('related_tasks', [])[:8] if pathlib.Path('${intelligence_file}').exists() else []),
        'github_issue_candidates': (json.loads(pathlib.Path('${intelligence_file}').read_text()).get('github_issue_candidates', [])[:5] if pathlib.Path('${intelligence_file}').exists() else [])
    },
    'acceptance': {
        'task_doc_exists': 'docs/development/tasks/${tid}.md',
        'ledger_status': 'dispatched',
        'evidence_required': True,
        'must_cite_context_pack': True,
        'must_cite_github_issue_or_explain_absence': True,
        'must_pass_code_quality_gates': True,
        'must_not_duplicate_existing_task_or_helper': True
    }
}
pathlib.Path('${dp_file}').write_text(json.dumps(dp, indent=2))
" 2>/dev/null

  AUTO_CREATED_TASKS="${AUTO_CREATED_TASKS} ${tid}"
  echo -e "  ${GREEN}[CREATE]${RESET} ${tid}: ${title}"
  bash "${ADAPTER_LIB}" memory-add "role-engine-auto-create" "${tid}" "${repo}" \
    "auto-created task from ${role}/${check}; context_pack=${intelligence_file}; title=${title}" \
    "${intelligence_file}" >/dev/null 2>&1 || true

  # Immediately commit + push so task is available to planner (don't wait for end of cycle)
  cd "${DOCS_DIR}"
  local cr_br="task/auto-create-$(date -u +%Y%m%d-%H%M%S)"
  local saved_br; saved_br=$(git branch --show-current 2>/dev/null || echo "dev")
  git checkout -b "${cr_br}" 2>/dev/null
  git add docs/development/tasks/ docs/development/dispatch-packets/ docs/development/task-state-ledger.json 2>/dev/null
  if git diff --cached --quiet 2>/dev/null; then
    git checkout "${saved_br}" 2>/dev/null || true
  else
    # Gate: run docs checks before pushing — reject unlinked TASK-AUTO artifacts
    if ! bash "${DOCS_DIR}/scripts/check-docs.sh" >/tmp/claude-role-engine-auto-create-check.log 2>&1; then
      WARN "auto-create ${tid} failed docs checks; reverting staged artifacts"
      git reset HEAD docs/development/tasks/ docs/development/dispatch-packets/ docs/development/task-state-ledger.json 2>/dev/null || true
      git checkout -- docs/development/tasks/ docs/development/dispatch-packets/ docs/development/task-state-ledger.json 2>/dev/null || true
      git checkout "${saved_br}" 2>/dev/null || true
      git branch -D "${cr_br}" 2>/dev/null || true
      return 0
    fi
    git commit -m "role-engine: auto-create ${tid}" 2>/dev/null
    git checkout dev 2>/dev/null && git merge "${cr_br}" --no-edit 2>/dev/null && git push origin dev 2>/dev/null
    git checkout "${saved_br}" 2>/dev/null || git checkout dev 2>/dev/null
  fi
  return 0
}

mkdir -p "${ROLE_CACHE_DIR}"
: > "${FINDINGS_FILE}"  # truncate for this cycle

BOLD="\033[1m" GREEN="\033[32m" YELLOW="\033[33m" RED="\033[31m" CYAN="\033[36m" RESET="\033[0m"
H1() { echo -e "\n${BOLD}${CYAN}═══ $* ═══${RESET}"; }
OK() { echo -e "  ${GREEN}[OK]${RESET} $*"; }
WARN(){ echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
ACT() { echo -e "  ${RED}[ACT]${RESET} $*"; }
ASK() { echo -e "  ${BOLD}[REASON]${RESET} $*"; }
NEXT(){ echo -e "  ${BOLD}${GREEN}[NEXT]${RESET} $*"; }

claude_self_audit_gate() {
  local audit_file="${ROLE_CACHE_DIR}/self-audit.json"

  if [[ ! -f "${DOCS_DIR}/scripts/check-auto-task-artifacts.py" ]] || \
     ! grep -q "check-auto-task-artifacts.py" "${DOCS_DIR}/scripts/check-docs.sh" 2>/dev/null; then
    WARN "self-audit: docs TASK-AUTO guard missing; role-engine will not mutate control-plane artifacts"
    COORDINATION_DECISION="read_only"
    record_finding "shared" "blocker" "" "SELF-AUDIT" \
      "TASK-AUTO artifact guard is missing from docs checks" \
      "pull latest livemask-docs/dev and rerun startup before creating tasks" \
      "bash ${CI_CD_DIR}/scripts/claude-loop-startup.sh"
    return 0
  fi

  if [[ -f "${audit_file}" ]]; then
    local fresh_overflow
    fresh_overflow=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print('yes' if any(s.get('type') == 'context_overflow_error' and int(s.get('age_min', 9999)) <= 20 for s in d.get('signals', [])) else '')" "${audit_file}" 2>/dev/null || echo "")
    if [[ -n "${fresh_overflow}" ]]; then
      WARN "self-audit: recent Claude context overflow detected; switching role-engine to read-only diagnostics"
      COORDINATION_DECISION="read_only"
      record_finding "shared" "blocker" "" "SELF-AUDIT" \
        "recent Claude context overflow means this session may be repeating stale instructions" \
        "restart Claude in a fresh session, run startup, and only then mutate control-plane artifacts" \
        "bash ${CI_CD_DIR}/scripts/claude-loop-startup.sh"
    fi
  fi
}

# ── Shared: findings recording (machine-readable output) ──────────────────────
# Severity: blocker (must fix) > warning (should fix) > info (FYI)
record_finding() {
  local role="$1" severity="$2" task_id="${3:-}" check="$4" finding="$5" next="${6:-}" cmd="${7:-}"
  FINDINGS_FILE="${FINDINGS_FILE}" NOW_SHA_FULL="${NOW_SHA_FULL:-}" python3 - \
    "${role}" "${severity}" "${task_id}" "${check}" "${finding}" "${next}" "${cmd}" <<'PY'
import json, os, sys
from datetime import datetime, timezone
role, severity, task_id, check, finding, nxt, cmd = sys.argv[1:8]
lower_next = (nxt or "").lower()
lower_cmd = (cmd or "").lower()
if "human" in lower_next or severity == "blocker" and not cmd:
    actor = "human"
elif "codex" in lower_next:
    actor = "codex"
elif cmd or "claude" in lower_next or role in ("pm", "product", "tech", "qa"):
    actor = "claude"
else:
    actor = "claude"

if not cmd:
    action_type = "manual_review"
elif "adapter-lib.sh" in lower_cmd or "plan-next-tasks.py" in lower_cmd or "claude-loop-preflight.sh" in lower_cmd:
    action_type = "diagnose"
elif "claude-loop-startup.sh" in lower_cmd or "claude-loop-role-engine.sh" in lower_cmd:
    action_type = "dispatch_or_analyze"
elif "dev-merge-guard" in lower_cmd or "git " in lower_cmd:
    action_type = "mutating"
else:
    action_type = "manual_review"

entry = {
    "role": role,
    "severity": severity,
    "task_id": task_id,
    "check": check,
    "finding": finding,
    "next": nxt,
    "cmd": cmd,
    "actor_hint": actor,
    "action_type": action_type,
    "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "docs_head": os.environ.get("NOW_SHA_FULL", ""),
}
path = os.environ["FINDINGS_FILE"]
with open(path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(entry, ensure_ascii=False) + "\n")
PY
}

current_task_repo_hint() {
  local tid="${1:-}"
  if [[ -z "${tid}" ]]; then
    echo ""
    return 0
  fi
  python3 - "${DOCS_DIR}/docs/development/task-state-ledger.json" "${tid}" <<'PY' 2>/dev/null || true
import json, sys
ledger, tid = sys.argv[1:3]
d = json.load(open(ledger))
for module in d.get("modules", []):
    for task in module.get("tasks", []):
        if task.get("task_id") == tid:
            print(task.get("repo", ""))
            raise SystemExit
PY
}

runtime_log_audit_findings() {
  local tid="${1:-}"
  local repo="${2:-}"
  local out="/tmp/claude/role-engine-runtime-log-audit.json"
  mkdir -p /tmp/claude "${ROLE_CACHE_DIR}" 2>/dev/null || true

  bash "${CI_CD_DIR}/scripts/runtime-log-audit.sh" \
    --compose "${CI_CD_DIR}/infra/docker-compose.local.yml" \
    --env local \
    --tail 250 \
    --task-id "${tid}" \
    --task-repo "${repo}" \
    --output "${out}" \
    --create-issue >/tmp/claude/runtime-log-audit.out 2>/dev/null || true

  if [[ ! -f "${out}" ]]; then
    record_finding "shared" "warning" "${tid}" "RUNTIME-LOGS" \
      "runtime log audit did not produce an artifact" \
      "run runtime-log-audit.sh and inspect Docker access" \
      "bash ${CI_CD_DIR}/scripts/runtime-log-audit.sh"
    return 0
  fi

  python3 - "${out}" <<'PY' 2>/tmp/claude/runtime-log-audit.findings || true
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("status", "unknown"), d.get("error_count", 0), d.get("related_count", 0), d.get("unrelated_count", 0), d.get("github_issue_url", ""))
for e in d.get("errors", [])[:5]:
    marker = "related" if e.get("related_to_current_task") else "unrelated"
    print(f"{marker}\t{e.get('service')}\t{e.get('line')[:220]}")
PY

  local status error_count related_count unrelated_count issue_url
  read -r status error_count related_count unrelated_count issue_url < <(head -1 /tmp/claude/runtime-log-audit.findings 2>/dev/null || echo "unknown 0 0 0")
  if [[ "${error_count:-0}" -gt 0 ]]; then
    WARN "runtime logs: ${error_count} error signal(s), related=${related_count}, unrelated=${unrelated_count}"
    if [[ "${unrelated_count:-0}" -gt 0 ]]; then
      record_finding "shared" "warning" "${tid}" "RUNTIME-LOGS" \
        "unrelated local container log errors detected (${unrelated_count}); issue=${issue_url:-not-created}" \
        "triage or link runtime anomaly before ignoring it" \
        "bash ${CI_CD_DIR}/scripts/runtime-log-audit.sh --create-issue"
    else
      record_finding "shared" "warning" "${tid}" "RUNTIME-LOGS" \
        "container log errors detected for current task scope (${related_count})" \
        "inspect runtime-log-audit artifact and fix before completion" \
        "bash ${CI_CD_DIR}/scripts/runtime-log-audit.sh --task-id ${tid}"
    fi
  else
    OK "runtime logs clean"
  fi
}

task_environment_freshness_findings() {
  local tid="${1:-}"
  local repo="${2:-}"
  [[ -z "${tid}" && -z "${repo}" ]] && return 0

  local out="/tmp/claude/role-engine-task-environment-freshness.json"
  mkdir -p /tmp/claude "${ROLE_CACHE_DIR}" 2>/dev/null || true
  bash "${CI_CD_DIR}/scripts/task-environment-freshness.sh" \
    --task-id "${tid}" \
    --repo "${repo}" \
    --output "${out}" >/tmp/claude/task-environment-freshness.out 2>/dev/null || true

  if [[ ! -f "${out}" ]]; then
    record_finding "shared" "warning" "${tid}" "ENV-FRESHNESS" \
      "task environment freshness check did not produce an artifact" \
      "verify local repo and remote dev runtime freshness before coding" \
      "bash ${CI_CD_DIR}/scripts/task-environment-freshness.sh --task-id ${tid} --repo ${repo}"
    return 0
  fi

  local issue_count
  issue_count="$(python3 -c "import json; print(len(json.load(open('${out}')).get('issues', [])))" 2>/dev/null || echo 0)"
  if [[ "${issue_count}" -gt 0 ]]; then
    record_finding "shared" "warning" "${tid}" "ENV-FRESHNESS" \
      "task local/remote environment is not verified fresh (${issue_count} issue(s))" \
      "pull/sync local dev and wait for latest Dev Runtime Deploy before task completion" \
      "bash ${CI_CD_DIR}/scripts/task-environment-freshness.sh --task-id ${tid} --repo ${repo}"
  else
    OK "task environment freshness verified"
  fi
}

write_decision_summary() {
  local out="${ROLE_CACHE_DIR}/decision-summary.json"
  python3 - "${FINDINGS_FILE}" "${out}" <<'PY'
import json, sys
from collections import Counter
from pathlib import Path

findings_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
severity_order = {"blocker": 0, "warning": 1, "info": 2}
seen = set()
findings = []
if findings_path.exists():
    for line in findings_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        f = json.loads(line)
        key = (f.get("role"), f.get("check"), f.get("task_id"), f.get("finding"))
        if key in seen:
            continue
        seen.add(key)
        findings.append(f)

findings.sort(key=lambda f: (
    severity_order.get(f.get("severity", "info"), 9),
    f.get("actor_hint", "claude"),
    f.get("role", ""),
    f.get("check", ""),
))

counts = {
    "by_severity": Counter(f.get("severity", "info") for f in findings),
    "by_actor": Counter(f.get("actor_hint", "claude") for f in findings),
    "by_action_type": Counter(f.get("action_type", "manual_review") for f in findings),
}

if counts["by_severity"].get("blocker", 0):
    next_actor = "human" if counts["by_actor"].get("human", 0) else "claude"
    classification = "blocked"
elif counts["by_actor"].get("codex", 0):
    next_actor = "codex"
    classification = "needs_codex_review"
elif findings:
    next_actor = "claude"
    classification = "work_available"
else:
    next_actor = "none"
    classification = "idle"

summary = {
    "schema_version": 1,
    "classification": classification,
    "next_required_actor": next_actor,
    "counts": {k: dict(v) for k, v in counts.items()},
    "top_actions": findings[:8],
}
out_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")

print(f"  classification: {classification}")
print(f"  next_required_actor: {next_actor}")
print(f"  decision_summary: {out_path}")
for i, f in enumerate(findings[:5], 1):
    print(f"  {i}. [{f.get('severity','info').upper()}] actor={f.get('actor_hint','claude')} type={f.get('action_type','manual_review')} {f.get('role','?')}-{f.get('check','?')}: {f.get('finding','')}")
    if f.get("next"):
        print(f"     next: {f.get('next')}")
PY
}

is_safe_diagnostic_cmd() {
  local cmd="${1:-}"
  case "${cmd}" in
    "bash ${ADAPTER_LIB} pm-status"|\
    "bash ${ADAPTER_LIB} findings-search"*|\
    "bash ${ADAPTER_LIB} dispatch-status"*|\
    "bash ${CI_CD_DIR}/scripts/claude-loop-preflight.sh"|\
    "python3 ${DOCS_DIR}/scripts/plan-next-tasks.py --format json")
      return 0
      ;;
  esac
  return 1
}

run_safe_diagnostic_cmd() {
  local cmd="${1:-}" arg=""
  case "${cmd}" in
    "bash ${ADAPTER_LIB} pm-status")
      bash "${ADAPTER_LIB}" pm-status
      ;;
    "bash ${ADAPTER_LIB} findings-search")
      bash "${ADAPTER_LIB}" findings-search
      ;;
    "bash ${ADAPTER_LIB} findings-search "*)
      arg="${cmd#bash ${ADAPTER_LIB} findings-search }"
      [[ "${arg}" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 1
      bash "${ADAPTER_LIB}" findings-search "${arg}"
      ;;
    "bash ${ADAPTER_LIB} dispatch-status")
      bash "${ADAPTER_LIB}" dispatch-status
      ;;
    "bash ${ADAPTER_LIB} dispatch-status "*)
      arg="${cmd#bash ${ADAPTER_LIB} dispatch-status }"
      [[ "${arg}" =~ ^TASK-[A-Z0-9-]+$ ]] || return 1
      bash "${ADAPTER_LIB}" dispatch-status "${arg}"
      ;;
    "bash ${CI_CD_DIR}/scripts/claude-loop-preflight.sh")
      bash "${CI_CD_DIR}/scripts/claude-loop-preflight.sh"
      ;;
    "python3 ${DOCS_DIR}/scripts/plan-next-tasks.py --format json")
      python3 "${DOCS_DIR}/scripts/plan-next-tasks.py" --format json
      ;;
    *)
      return 1
      ;;
  esac
}

print_top_actions() {
  local count="${1:-3}"
  echo ""
  echo -e "${BOLD}${CYAN}═══ Top-${count} Priority Actions ═══${RESET}"

  if [[ ! -f "${FINDINGS_FILE}" ]] || [[ $(wc -l < "${FINDINGS_FILE}" 2>/dev/null || echo "0") -eq 0 ]]; then
    OK "no findings — system appears healthy"
    return 0
  fi

  # Sort by severity (blocker > warning > info), print top N
  python3 -c "
import json
severity_order = {'blocker': 0, 'warning': 1, 'info': 2}
findings = []
with open('${FINDINGS_FILE}') as f:
    for line in f:
        line = line.strip()
        if line: findings.append(json.loads(line))
findings.sort(key=lambda f: severity_order.get(f.get('severity','info'), 3))

for i, f in enumerate(findings[:${count}]):
    sev = f['severity'].upper()
    print(f\"{i+1}. [{sev}] [{f['role']}-{f['check']}] {f['finding']}\")
    if f.get('task_id'): print(f\"   task: {f['task_id']}\")
    if f.get('next'): print(f\"   next: {f['next']}\")
    if f.get('cmd'): print(f\"   cmd: {f['cmd']}\")
    print()
print(f'Total findings: {len(findings)} (${FINDINGS_FILE})')
" 2>/dev/null
}

# ── Shared: sync and cache ──────────────────────────────────────────────────
sync_all() {
  cd "${DOCS_DIR}" && git pull --ff-only origin dev 2>/dev/null || true
  cd "${CI_CD_DIR}" && git pull --ff-only origin dev 2>/dev/null || true
  hot_reload_if_ci_cd_updated "sync_all"
  NOW_SHA=$(git -C "${DOCS_DIR}" rev-parse --short HEAD 2>/dev/null || echo "?")
  NOW_SHA_FULL=$(git -C "${DOCS_DIR}" rev-parse HEAD 2>/dev/null || echo "")
}

# ── PM Mutual Exclusion: prevent Claude and Codex from colliding ──────────────
# Acquire PM lease before touching shared state. Stale leases (>15min) can be
# taken over. Returns 0 if lease acquired, 1 if another agent is active.
PM_LEASE_FILE="${PM_LEASE_FILE:-${ROLE_CACHE_DIR}/pm-lease.json}"
PM_LEASE_TTL_MIN=15

acquire_pm_lease() {
  local agent="${1:-unknown}"
  mkdir -p "${ROLE_CACHE_DIR}"

  if [[ -f "${PM_LEASE_FILE}" ]]; then
    local holder holder_start age_min holder_phase
    read -r holder holder_start age_min holder_phase <<< "$(python3 -c "
import json, time
try:
    d = json.load(open('${PM_LEASE_FILE}'))
    holder = d.get('agent', '?')
    started = d.get('started_at_epoch', 0)
    age = (time.time() - started) / 60
    print(holder, d.get('started_at','?'), f'{age:.0f}', d.get('phase','?'))
except: print('?','?','999','?')
" 2>/dev/null || echo "? ? 999")"

    if [[ "${holder}" == "${agent}" ]]; then
      # Same agent — renew lease
      :
    elif [[ "${holder_phase}" == "complete" || "${holder_phase}" == "stale-auto-released" ]]; then
      echo -e "  ${YELLOW}[LEASE]${RESET} previous PM lease by '${holder}' is terminal (${holder_phase}) — reusing"
    elif [[ "${age_min}" -lt "${PM_LEASE_TTL_MIN}" ]]; then
      echo -e "  ${YELLOW}[WAIT]${RESET} PM lease held by '${holder}' (${age_min}min ago) — skipping to avoid collision"
      echo "  Lease: ${PM_LEASE_FILE}"
      return 1
    else
      echo -e "  ${YELLOW}[TAKEOVER]${RESET} PM lease from '${holder}' is stale (${age_min}min > ${PM_LEASE_TTL_MIN}min TTL) — taking over"
    fi
  fi

  # Acquire/renew lease
  if ! python3 -c "
import json, time, pathlib
d = {
    'agent': '${agent}',
    'started_at': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'started_at_epoch': time.time(),
    'phase': 'preflight',
    'docs_head': '${NOW_SHA_FULL:-?}'
}
pathlib.Path('${PM_LEASE_FILE}').write_text(json.dumps(d, indent=2))
" 2>/dev/null; then
    WARN "failed to write PM lease file — continuing without lease"
    return 0
  fi
  echo "  [LEASE] PM lock acquired by ${agent}"
  return 0
}

release_pm_lease() {
  if [[ -f "${PM_LEASE_FILE}" ]]; then
    local release_agent="${ROLE:-unknown}"
    [[ "${release_agent}" == "all" ]] && release_agent="claude-pm-backup"
    local released
    released=$(python3 -c "
import json, pathlib
d = json.load(open('${PM_LEASE_FILE}'))
if d.get('agent') == '${release_agent}':
    d['phase'] = 'complete'
    d['completed_at'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
    pathlib.Path('${PM_LEASE_FILE}').write_text(json.dumps(d, indent=2))
    print('released')
else:
    print('held-by-' + str(d.get('agent', '?')))
" 2>/dev/null || echo "unknown")
    if [[ "${released}" == "released" ]]; then
      echo "  [LEASE] PM lock released"
    else
      echo "  [LEASE] PM lock not released (${released})"
    fi
  fi
}

# Shared intake aligned with CODEX_LOOP_RULES.md §2 and §12
preflight_context() {
  H1 "Preflight Context (Codex control-plane alignment)"

  # PM mutual exclusion FIRST — don't sync or touch state if another agent is working
  local pm_agent="${ROLE:-unknown}"
  if [[ "${ROLE}" == "all" ]]; then
    pm_agent="claude-pm-backup"
  fi
  if ! acquire_pm_lease "${pm_agent}"; then
    # Another agent holds the lease — skip this cycle
    PM_SKIP=1
    return 1
  fi
  PM_SKIP=0

  sync_all
  echo "  docs_head: ${NOW_SHA}"

  mkdir -p "${ROLE_CACHE_DIR}"
  local coord_task="${ARG2:-}"
  if ! bash "${ADAPTER_LIB}" coordination-status "${pm_agent}" "${coord_task}" > "${COORDINATION_STATUS_FILE}" 2>/dev/null; then
    WARN "coordination-status unavailable — continuing with PM lease only"
    COORDINATION_DECISION="proceed"
    COORDINATION_NEXT_ACTOR="claude-role-engine"
  else
    read -r COORDINATION_DECISION COORDINATION_NEXT_ACTOR <<< "$(python3 - "${COORDINATION_STATUS_FILE}" <<'PY' 2>/dev/null || echo "proceed claude-role-engine"
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("decision", "proceed"), d.get("next_required_actor", "claude-role-engine"))
PY
)"
    python3 - "${COORDINATION_STATUS_FILE}" <<'PY' 2>/dev/null || true
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  coordination: {d.get('decision','?')} next={d.get('next_required_actor','?')}")
for reason in d.get("reasons", [])[:4]:
    print(f"    reason: {reason}")
blocked = d.get("blocked_actions") or []
if blocked:
    print("    blocked: " + "; ".join(blocked[:5]))
PY
  fi

  if [[ "${COORDINATION_DECISION}" == "wait" || "${COORDINATION_DECISION}" == "handoff_wait" ]]; then
    record_finding "shared" "info" "${coord_task:-}" "COORDINATION" \
      "role-engine switched to safe diagnostics because coordination=${COORDINATION_DECISION}" \
      "diagnose/read context only; next actor: ${COORDINATION_NEXT_ACTOR}" \
      "bash ${ADAPTER_LIB} coordination-status claude-role-engine ${coord_task}"
    COORDINATION_DECISION="read_only"
  fi

  if [[ "${COORDINATION_DECISION}" == "read_only" ]]; then
    WARN "coordination read_only — diagnostics may run, but role-engine will not mutate control-plane artifacts"
  fi

  # Claude agent state (read-only)
  if [[ -f "${AGENT_STATE}" ]]; then
    python3 -c "
import json
d = json.load(open('${AGENT_STATE}'))
task = d.get('current_task') or {}
print(f\"  claude agent: phase={d.get('phase','?')} task={task.get('task_id') or 'null'} repo={task.get('target_repo') or ''}\")
" 2>/dev/null || WARN "could not parse agent-state.json"
  else
    echo "  claude agent: (no agent-state.json)"
  fi

  # Active leases
  if [[ -f "${LEASE_FILE}" ]]; then
    python3 -c "
import json
data = json.load(open('${LEASE_FILE}'))
active = [l for l in data.get('leases', []) if l.get('status') == 'active']
print(f'  active leases: {len(active)}')
for l in active[:5]:
    print(f\"    {l.get('task_id','?')} owner={l.get('lease_owner','?')} repo={l.get('repo','?')}\")
" 2>/dev/null || true
  fi

  # Dispatch packets
  local pkt_count=0
  if [[ -d "${DISPATCH_DIR}" ]]; then
    pkt_count=$(find "${DISPATCH_DIR}" -maxdepth 1 -name 'TASK-*.json' 2>/dev/null | wc -l | tr -d ' ')
    echo "  dispatch packets: ${pkt_count}"
    for pf in "${DISPATCH_DIR}"/TASK-*.json; do
      [[ -f "${pf}" ]] || continue
      python3 -c "
import json, pathlib
p = json.load(open('${pf}'))
print(f\"    {p.get('task_id','?')} -> {p.get('assigned_to','?')} repo={p.get('repo','?')}\")
" 2>/dev/null
    done
  fi

  # Planner top candidate
  local planner_line
  planner_line=$(python3 "${DOCS_DIR}/scripts/plan-next-tasks.py" --format json 2>/dev/null | \
    python3 -c "
import json, sys
d = json.load(sys.stdin)
tasks = [t for t in d.get('global_next', []) if t.get('readiness') == 'dispatch_now']
if not tasks:
    print('NONE|0|0')
else:
    t = tasks[0]
    print(f\"{t['task_id']}|{t['repo']}|{d.get('summary',{}).get('candidate_count',0)}\")
" 2>/dev/null || echo "NONE|0|0")

  local top_task top_repo candidate_count
  top_task="${planner_line%%|*}"
  planner_line="${planner_line#*|}"
  top_repo="${planner_line%%|*}"
  candidate_count="${planner_line##*|}"

  if [[ "${top_task}" != "NONE" ]]; then
    echo "  planner top: ${top_task} (${top_repo}) candidates=${candidate_count}"
    local pkt="${DISPATCH_DIR}/${top_task}.json"
    if [[ -f "${pkt}" ]]; then
      OK "dispatch packet exists for top task"
      record_finding "shared" "info" "${top_task}" "PREFLIGHT" \
        "handoff pending: dispatch packet exists for ${top_task}" \
        "run claude-loop-startup.sh and ACK_TASK" \
        "bash ${CI_CD_DIR}/scripts/claude-loop-startup.sh"
    else
      WARN "top dispatch_now task has no packet yet — Codex should create one"
      record_finding "shared" "warning" "${top_task}" "PREFLIGHT" \
        "dispatch_now without packet: ${top_task}" \
        "wait for Codex dispatch or run startup only" \
        "bash ${CI_CD_DIR}/scripts/claude-loop-startup.sh"
    fi
  else
    echo "  planner top: (no dispatch_now tasks) candidates=${candidate_count}"
  fi

  if [[ -n "${LAST_SHA:-}" && "${LAST_SHA}" == "${NOW_SHA}" ]]; then
    echo "  docs unchanged since last role-engine run (${LAST_SHA})"
  fi
}

finish_role() {
  local role_name="$1"
  save_cache "${role_name}" "${2:-done}"
}

load_cache() {
  local role_name="$1"
  local cache="${ROLE_CACHE_DIR}/${role_name}-cache.json"
  if [[ -f "${cache}" ]]; then
    LAST_SHA=$(python3 -c "import json; print(json.load(open('${cache}')).get('last_sha',''))" 2>/dev/null || echo "")
    LAST_TIME=$(python3 -c "import json; print(json.load(open('${cache}')).get('updated_at',''))" 2>/dev/null || echo "")
    echo "  last cycle: ${LAST_TIME} (${LAST_SHA:0:7})"
  else
    LAST_SHA=""
    echo "  no cache — full analysis"
  fi
}

save_cache() {
  local role_name="$1"
  local summary="$2"
  local sha="${NOW_SHA:-}"
  python3 -c "
import json, time, pathlib
cache = {'schema_version':2, 'role':'${role_name}', 'updated_at':'$(date -u +%Y-%m-%dT%H:%M:%SZ)', 'updated_at_epoch':time.time(), 'last_sha':'${sha}', 'summary':'${summary}'}
pathlib.Path('${ROLE_CACHE_DIR}/${role_name}-cache.json').write_text(json.dumps(cache, indent=2))
" 2>/dev/null
}

push_changes() {
  local msg="${1:-role-engine cycle}"
  if [[ "${COORDINATION_DECISION:-proceed}" == "read_only" ]]; then
    WARN "coordination read_only — not staging, committing, or pushing control-plane artifacts"
    return 0
  fi
  cd "${DOCS_DIR}"
  if [[ -z "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "  (no changes to push)"
    return 0
  fi
  local changes; changes=$(git status --porcelain | wc -l | tr -d ' ')
  WARN "${changes} file(s) changed — NOT auto-pushing to dev (safety gate)"

  # Create task branch but DO NOT merge to dev automatically
  local br="task/role-$(date -u +%Y%m%d-%H%M%S)"
  git checkout -b "${br}" 2>/dev/null
  git add -A
  git commit -m "${msg}
Co-Authored-By: Claude Role Engine <noreply@anthropic.com>" 2>/dev/null

  echo ""
  echo "  Branch '${br}' created with ${changes} changes."
  echo "  To merge: bash ${CI_CD_DIR}/scripts/dev-merge-guard.sh --repo ${DOCS_DIR} --task-branch ${br} --task-id ${tid} --push"
  echo "  Or manually: git checkout dev && git merge ${br} --no-edit && git push origin dev"
  echo ""
  WARN "Changes saved to branch but NOT merged to dev. Merge requires explicit action."
}

# ── Helper: get ledger entry for a task ──────────────────────────────────────
ledger_get() {
  local tid="$1" field="$2"
  python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id') == '${tid}':
            print(t.get('${field}',''))
" 2>/dev/null || echo ""
}

# ── Helper: get all tasks with a given status ────────────────────────────────
ledger_filter() {
  local status="$1"
  python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('status') == '${status}':
            print(f\"{t['task_id']}|{t.get('repo','?')}|{t.get('issue','')}|{t.get('blocked_by',[])}|{t.get('validation','')[:80]}\")
" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
# PM: 3 deep reasoning points
# ══════════════════════════════════════════════════════════════════════════════

role_pm() {
  H1 "PM — Project Manager Reasoning"
  load_cache "pm"
  preflight_context

  # ── PM-1: WHY are there blocked tasks? Trace to root blocker ───────────────
  H1 "PM-1: Blocked Task Root Cause Analysis"

  local blocked_tasks
  blocked_tasks=$(ledger_filter "blocked")

  if [[ -z "${blocked_tasks}" ]]; then
    OK "no blocked tasks"
  else
    echo "  blocked tasks:"
    local pm1_list
    pm1_list=$(echo "${blocked_tasks}" | head -10)
    while IFS='|' read -r tid repo issue blockers validation; do
      [[ -z "${tid}" ]] && continue
      echo "    ${tid} (${repo})"

      # WHY is it blocked? Trace each blocker's status
      local blocker_list; blocker_list=$(echo "${blockers}" | tr -d '[]' | tr ',' '\n' | sed "s/'//g" | sed "s/ //g")
      for blocker in ${blocker_list}; do
        [[ -z "${blocker}" ]] && continue
        local b_status; b_status=$(ledger_get "${blocker}" "status")
        local b_repo; b_repo=$(ledger_get "${blocker}" "repo")
        local b_issue; b_issue=$(ledger_get "${blocker}" "issue")

        ASK "blocked by ${blocker} → WHY is ${blocker} not done?"

        echo "      blocker: ${blocker} (${b_repo}) | status=${b_status}"
        [[ -n "${b_issue}" ]] && echo "      issue: ${b_issue}"

        local b_blockers; b_blockers=$(ledger_get "${blocker}" "blocked_by")
        [[ -n "${b_blockers}" && "${b_blockers}" != "[]" ]] && echo "      meta-blocked: ${blocker} is blocked by ${b_blockers}"

        local brf="${DOCS_DIR}/docs/development/review-contracts/${blocker}-review.json"
        [[ -f "${brf}" ]] && python3 -c "
import json; d=json.load(open('${brf}'))
print(f\"      review: state={d.get('state')} actor={d.get('next_required_actor')}\")
" 2>/dev/null

        case "${b_status}" in
          blocked)
            ASK "→ ${blocker} itself is blocked — this is a CHAIN. Find the root blocker and fix it first."
            NEXT "Action: trace dependency chain to root → fix root → chain unblocks"
            record_finding "pm" "warning" "${tid}" "PM-1" "chain-blocked: ${blocker} is itself blocked" "trace to root blocker" ""
            ;;
          partial|evidence_missing)
            ASK "→ ${blocker} is ${b_status} — implementation exists but evidence is missing. WHY is evidence missing?"
            ASK "   IF CI unavailable → fix CI first"
            ASK "   IF nobody collected it → create evidence-collection subtask"
            ASK "   IF evidence exists but not recorded → update ledger/task doc"
            NEXT "Action: diagnose evidence gap, create collection task or update records"
            record_finding "pm" "warning" "${tid}" "PM-1" "blocker ${blocker} is ${b_status} — evidence missing" "diagnose evidence gap for ${blocker}" "bash scripts/claude-loop-role-engine.sh --closure-audit ${blocker}"
            ;;
          ready|in_progress|implementing)
            ASK "→ ${blocker} is ${b_status} — it's in progress but not done. WHY is it stalled?"
            ASK "   IF Claude picked it up and stalled → check agent-state.json for recovery"
            ASK "   IF never dispatched → check dispatch queue priority"
            NEXT "Action: check agent state, bump dispatch priority, or create reminder SAP"
            record_finding "pm" "info" "${tid}" "PM-1" "blocker ${blocker} is ${b_status} — stalled" "check agent-state.json or bump dispatch" ""
            ;;
          *)
            ASK "→ ${blocker} status=${b_status} — unexpected state. Investigate."
            NEXT "Action: read task doc and review contract for ${blocker}"
            ;;
        esac
        echo ""
      done
    done <<< "${pm1_list}"

    # ── Auto-unblock: if ALL blockers are completed, mark task as ready ──────
    if [[ -n "${blocked_tasks}" ]]; then
      python3 -c "
import json, pathlib
p = pathlib.Path('${DOCS_DIR}/docs/development/task-state-ledger.json')
d = json.loads(p.read_text())
done = {'completed','completed_with_skip'}
unblocked = 0
for m in d.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('status') != 'blocked': continue
        blockers = t.get('blocked_by',[])
        if not blockers: continue
        # Check if ALL blockers are completed
        all_done = True
        for b in blockers:
            b_done = False
            for m2 in d.get('modules',[]):
                for t2 in m2.get('tasks',[]):
                    if t2.get('task_id') == b and t2.get('status') in done:
                        b_done = True; break
            if not b_done: all_done = False; break
        if all_done:
            t['status'] = 'ready'
            t['blocked_by'] = []
            t['notes'] = t.get('notes','') + ' [auto-unblocked: all blockers completed]'
            print(f'AUTO-UNBLOCK: {t[\"task_id\"]} blocked→ready')
            unblocked += 1
if unblocked: p.write_text(json.dumps(d, indent=2, ensure_ascii=False))
" 2>/dev/null
    fi
  fi

  # ── PM-2: WHY are there doc/ledger conflicts? ──────────────────────────────
  H1 "PM-2: Doc/Ledger Consistency Reasoning"

  local pm2_conflicts
  pm2_conflicts=$(python3 -c "
import json, re
from pathlib import Path

docs = Path('${DOCS_DIR}')
ledger = json.loads((docs / 'docs/development/task-state-ledger.json').read_text())

for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        tid = t.get('task_id','')
        doc_path = docs / 'docs/development/tasks' / f'{tid}.md'
        if not doc_path.exists(): continue

        content = doc_path.read_text()
        dm = re.search(r'>\\s*Status:\\s*(\\S+)', content)
        if not dm: continue

        doc_status = dm.group(1).lower().replace(':','').strip()
        if doc_status.startswith('✅'):
            doc_status = 'completed'
        elif doc_status.startswith('🟡') or doc_status == 'partial':
            doc_status = 'partial'
        elif doc_status.startswith('🔴') or doc_status == 'blocked':
            doc_status = 'blocked'
        ledger_status = t.get('status','').lower()
        done = {'completed','completed_with_skip'}

        if doc_status in done and ledger_status not in done:
            print(f'CONFLICT|{tid}|{t.get(\"repo\",\"?\")}|doc={doc_status}|ledger={ledger_status}|{t.get(\"issue\",\"\")}')
        elif ledger_status in done and doc_status not in done:
            print(f'CONFLICT|{tid}|{t.get(\"repo\",\"?\")}|doc={doc_status}|ledger={ledger_status}|{t.get(\"issue\",\"\")}')
" 2>/dev/null | head -10)

  local conflicts_found=0
  while IFS='|' read -r tag tid repo detail1 detail2 issue; do
    [[ -z "${tid}" ]] && continue
    conflicts_found=$((conflicts_found + 1))

    ASK "WHY does ${tid} (${repo}) have mismatched status: ${detail1} vs ${detail2}?"

    # Gather context: check review contract and git log
    local rstate="" verdict=""
    local rf="${DOCS_DIR}/docs/development/review-contracts/${tid}-review.json"
    if [[ -f "${rf}" ]]; then
      read -r rstate verdict <<< "$(python3 -c "
import json; d=json.load(open('${rf}'))
state = d.get('state','?')
for r in d.get('rounds',[]):
    cx = r.get('codex',{})
    if cx: print(state, cx.get('verdict','?')); break
else: print(state, 'no_verdict')
" 2>/dev/null || echo "? ?")"

      ASK "   review contract: state=${rstate} verdict=${verdict}"
      # WHY reasoning
      if [[ "${rstate}" == "changes_requested" ]]; then
        ASK "→ Contract says CHANGES_REQUESTED but doc/ledger says completed. Claude may have pre-maturely marked done."
        NEXT "Action: revert doc to Partial, create SAP warning Claude"
        record_finding "pm" "warning" "${tid}" "PM-2" "doc/ledger vs review: changes_requested" "revert premature completion" ""
      elif [[ "${rstate}" == "under_codex_review" ]]; then
        ASK "→ Contract is under review — status should NOT be completed. Claude may have jumped the gun."
        NEXT "Action: hold status at implemented/verified until verdict"
        record_finding "pm" "warning" "${tid}" "PM-2" "doc/ledger ahead of review state" "hold until codex verdict" ""
      elif [[ "${verdict}" == "approved" || "${rstate}" == "approved" ]]; then
        ASK "→ Contract approved — doc/ledger should BOTH be completed. Which side is stale?"
        NEXT "Action: sync the stale side to completed"
        record_finding "pm" "info" "${tid}" "PM-2" "doc/ledger mismatch after approval" "sync stale side to completed" ""
      fi
    else
      ASK "→ No review contract exists — completion without review is a PROCESS_DEFECT"
      NEXT "Action: create review contract retroactively, mark task as evidence_missing until reviewed"
      record_finding "pm" "warning" "${tid}" "PM-2" "doc/ledger conflict without review contract" "create review contract or reconcile ledger" ""
    fi

    # Check git for dev merge evidence
    local dev_merge; dev_merge=$(git -C "${LIVEMASK_ROOT}/${repo}" log --oneline --grep="${tid}" -1 2>/dev/null || echo "")
    [[ -n "${dev_merge}" ]] && echo "      dev merge: ${dev_merge}" || ASK "      no dev merge commit found — was this ever pushed?"

    # ── AUTO-RECONCILE: resolve conflict when evidence is clear ────────────────
    local auto_fixed=0
    local target_status=""
    local issue_state=""

    # Rule 1: Review contract approved → sync both to completed
    if [[ "${rstate:-}" == "approved" || "${verdict:-}" == "approved" ]]; then
      target_status="completed"
      ACT "AUTO-FIX: review contract approved → syncing doc+ledger to completed"
      auto_fixed=1
    # Rule 2: Review contract changes_requested → revert doc to partial
    elif [[ "${rstate:-}" == "changes_requested" ]]; then
      target_status="partial"
      ACT "AUTO-FIX: review contract changes_requested → reverting doc to partial"
      auto_fixed=1
    # Rule 3: No contract but dev merge exists → sync both to completed
    elif [[ -z "${rstate:-}" ]] && [[ -n "${dev_merge}" ]]; then
      target_status="completed"
      ACT "AUTO-FIX: dev merge exists without contract → syncing to completed (merge is evidence)"
      auto_fixed=1
    # Rule 4: No contract, no merge → leave as conflict for human/Codex
    else
      WARN "Cannot auto-resolve — no review contract and no dev merge. Needs human decision."
    fi

    if [[ "${auto_fixed}" -eq 1 && "${target_status}" == "completed" && -n "${issue}" ]]; then
      issue_state=$(ISSUE_URL="${issue}" python3 - <<'PY'
import os, re, subprocess
url = os.environ.get("ISSUE_URL", "")
m = re.search(r"github\.com/([^/]+/[^/]+)/issues/([0-9]+)", url)
if not m:
    print("UNKNOWN")
    raise SystemExit(0)
repo, num = m.group(1), m.group(2)
try:
    out = subprocess.check_output(
        ["gh", "issue", "view", num, "--repo", repo, "--json", "state", "--jq", ".state"],
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=15,
    ).strip()
    print(out or "UNKNOWN")
except Exception:
    print("UNKNOWN")
PY
)
      if [[ "${issue_state}" != "CLOSED" ]]; then
        WARN "skip auto-reconcile ${tid} → completed: linked issue state=${issue_state} (${issue})"
        record_finding "pm" "warning" "${tid}" "PM-2" \
          "auto-reconcile to completed blocked by linked issue state=${issue_state}" \
          "keep task non-terminal until GitHub issue, task doc, ledger, review contract, and validation evidence agree" \
          ""
        auto_fixed=0
        target_status=""
      fi
    fi

    if [[ "${auto_fixed}" -eq 1 && -n "${target_status}" ]]; then
      # Update ledger
      python3 -c "
import json, re, pathlib
docs = pathlib.Path('${DOCS_DIR}')

# Update ledger
ledger_path = docs / 'docs/development/task-state-ledger.json'
ledger = json.loads(ledger_path.read_text())
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id') == '${tid}':
            t['status'] = '${target_status}'
            if '${target_status}' == 'completed':
                t['validation'] = t.get('validation','') + ' [auto-reconciled: review contract or dev merge evidence]'
ledger_path.write_text(json.dumps(ledger, indent=2, ensure_ascii=False))

# Update task doc Status line
doc_path = docs / 'docs/development/tasks' / '${tid}.md'
if doc_path.exists():
    content = doc_path.read_text()
    # Replace Status line: > Status: X or > **Status**: X  or > ✅ X etc
    new_status = '> Status: ' + '${target_status}'.capitalize()
    content = re.sub(r'>\s*\*?\*?Status:?\*?\*?\s*[^\n]+', new_status, content)
    doc_path.write_text(content)
print('auto-reconciled: ${tid} → ${target_status}')
" 2>/dev/null && OK "auto-reconciled: ${tid} → ${target_status}" || WARN "auto-reconcile failed for ${tid}"

      # Collect auto-reconciled task IDs for batch push
      AUTO_FIXED_TASKS="${AUTO_FIXED_TASKS} ${tid}"
    fi

    echo ""
  done <<< "${pm2_conflicts}"

  # Push auto-reconciled changes via proper task branch flow
  if [[ -n "${AUTO_FIXED_TASKS:-}" ]]; then
    cd "${DOCS_DIR}"
    local auto_count; auto_count=$(echo "${AUTO_FIXED_TASKS}" | wc -w | tr -d ' ')
    local auto_br="task/pm-auto-reconcile-$(date -u +%Y%m%d-%H%M%S)"
    git checkout -b "${auto_br}" 2>/dev/null
    git add docs/development/task-state-ledger.json docs/development/tasks/ 2>/dev/null
    git commit -m "docs: auto-reconcile ${auto_count} task(s) to completed (dev merge evidence)
$(echo ${AUTO_FIXED_TASKS} | tr ' ' '\n' | sed 's/^/  - /')
Co-Authored-By: Claude Role Engine <noreply@anthropic.com>" 2>/dev/null
    # Merge to dev via dev-merge-guard. The guard owns the final dev push.
    local first_auto_task
    first_auto_task="$(echo "${AUTO_FIXED_TASKS}" | awk '{print $1}')"
    if bash "${CI_CD_DIR}/scripts/dev-merge-guard.sh" \
      --repo "${DOCS_DIR}" \
      --task-branch "${auto_br}" \
      --task-id "${first_auto_task}" \
      --push 2>/dev/null; then
      OK "auto-pushed ${auto_count} reconciled task(s) via task branch flow"
    else
      WARN "dev-merge-guard failed — changes saved on ${auto_br}, manual merge needed"
    fi
    AUTO_FIXED_TASKS=""
  fi

  # Push auto-created tasks
  if [[ -n "${AUTO_CREATED_TASKS:-}" ]]; then
    local created_count; created_count=$(echo "${AUTO_CREATED_TASKS}" | wc -w | tr -d ' ')
    cd "${DOCS_DIR}"
    git add docs/development/tasks/ docs/development/dispatch-packets/ docs/development/task-state-ledger.json 2>/dev/null
    if git diff --cached --quiet 2>/dev/null; then
      :
    else
      if ! bash "${DOCS_DIR}/scripts/check-docs.sh" >/tmp/claude-role-engine-check-docs.log 2>&1; then
        WARN "auto-create output failed docs checks; reverting staged auto-created artifacts"
        git restore --staged docs/development/tasks/ docs/development/dispatch-packets/ docs/development/task-state-ledger.json 2>/dev/null || true
        git restore docs/development/tasks/ docs/development/dispatch-packets/ docs/development/task-state-ledger.json 2>/dev/null || true
        AUTO_CREATED_TASKS=""
        return 0
      fi
      local cr_br="task/auto-create-$(date -u +%Y%m%d-%H%M%S)"
      git checkout -b "${cr_br}" 2>/dev/null
      git commit -m "role-engine: auto-create ${created_count} task(s) from findings
$(echo ${AUTO_CREATED_TASKS} | tr ' ' '\n' | sed 's/^/  - /')
Co-Authored-By: Claude Role Engine <noreply@anthropic.com>" 2>/dev/null
      git checkout dev 2>/dev/null && git merge "${cr_br}" --no-edit 2>/dev/null && git push origin dev 2>/dev/null && \
        OK "auto-created + pushed ${created_count} task(s) to origin/dev" || WARN "auto-create push failed — saved on ${cr_br}"
    fi
    AUTO_CREATED_TASKS=""
  fi

  [[ "${conflicts_found}" -eq 0 ]] && OK "all doc/ledger statuses consistent"

  # ── PM-3: WHY is the dispatch queue empty? What's the bottleneck? ──────────
  H1 "PM-3: Queue Health Root Cause"

  local candidates blocked
  read -r candidates blocked <<< "$(python3 "${DOCS_DIR}/scripts/plan-next-tasks.py" --format json 2>/dev/null | \
    python3 -c "import json,sys; d=json.load(sys.stdin)['summary']; print(d['candidate_count'], d['blocked_open_count'])" 2>/dev/null || echo "? ?")"

  echo "  candidates: ${candidates} | blocked: ${blocked}"

  if [[ "${candidates}" == "0" ]]; then
    ASK "WHY is the dispatch queue empty?"

    if [[ "${blocked}" == "0" || "${blocked}" == "?" ]]; then
      ASK "→ No candidates AND no blocked tasks. Possible causes:"
      ASK "   1. All MVP tasks are done — system is complete (verify against contracts)"
      ASK "   2. Tasks exist in ledger but planner can't dispatch them (check readiness)"
      ASK "   3. No new tasks have been created (check Product role for decomposition gaps)"
      ASK "   4. All tasks are in non-dispatchable states (in_progress without progress)"

      # Check which statuses dominate
      local status_dist; status_dist=$(python3 -c "
import json
from collections import Counter
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
statuses = Counter()
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        statuses[t.get('status','?')] += 1
for s,c in statuses.most_common(8): print(f'{s}: {c}')
" 2>/dev/null)
      echo "      status distribution:"
      echo "${status_dist}" | while read -r line; do echo "        ${line}"; done

      NEXT "Action: if MVP complete → mark milestone. If tasks stuck → diagnose each stuck status. If no tasks → report gaps for human/Codex triage."
      record_finding "pm" "warning" "" "PM-3" "dispatch queue empty (candidate_count=0)" "report Ready contract gaps for triage; do NOT auto-create" "bash scripts/claude-loop-role-engine.sh product"
      # Gap detection only — NO auto-create. Auto-created TASK-AUTO tasks cause
      # Claude↔Codex ping-pong (create→reconcile→create→reconcile) and block
      # Claude executor from picking up real implementation work.
      python3 -c "
import json, re
from pathlib import Path
docs = Path('${DOCS_DIR}')
ledger = json.loads((docs / 'docs/development/task-state-ledger.json').read_text())
all_tasks = set()
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id'): all_tasks.add(t['task_id'])
auto_existing = set()
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        tid = t.get('task_id','')
        if tid.startswith('TASK-AUTO-'):
            auto_existing.add(tid)
ci = docs / 'docs/contracts/contract-index.md'
if ci.exists():
    gaps = []
    for line in ci.read_text().split('\n'):
        if '| Ready |' not in line or 'TASK-' not in line: continue
        for match in re.finditer(r'TASK-[A-Z0-9-]+', line):
            if match.group(0) in all_tasks: continue
            parts = [p.strip() for p in line.split('|')]
            domain = parts[1][:40] if len(parts) > 1 else 'unknown'
            repos_raw = parts[5].strip()[:80] if len(parts) > 5 else 'livemask-backend'
            first_repo = repos_raw.split('/')[0].strip()
            repo_map = {
                'Backend': 'livemask-backend',
                'Admin': 'livemask-admin',
                'App': 'livemask-app',
                'Website': 'livemask-website',
                'CI-CD': 'livemask-ci-cd',
                'CI/CD': 'livemask-ci-cd',
                'NodeAgent': 'livemask-nodeagent',
                'Job Service': 'livemask-job-service',
                'Jobs': 'livemask-job-service',
                'Docs': 'livemask-docs',
            }
            repo = repo_map.get(first_repo, first_repo)
            auto_tid = f\"TASK-AUTO-{domain.lower().replace(' ','-')[:30]}\"
            if auto_tid in auto_existing: continue
            gaps.append(f'{domain}|{repo}|{repos_raw}|{auto_tid}')
    if gaps:
        print(f'GAPS_FOUND|{len(gaps)}|||')
        for g in gaps[:10]: print(g)
" 2>/dev/null | while IFS='|' read -r gap_domain gap_repo gap_repos gap_tid; do
        if [[ "${gap_domain}" == "GAPS_FOUND" ]]; then
          WARN "PM-3: ${gap_repo} Ready contract gaps found — reporting for triage (NOT auto-creating)"
          continue
        fi
        [[ -z "${gap_domain}" || -z "${gap_repo}" ]] && continue
        WARN "PM-3 gap: '${gap_domain}' (${gap_repo}) lacks implementation task — needs human/Codex dispatch"
        record_finding "pm" "warning" "" "PM-3" "Ready contract gap: ${gap_domain} (${gap_repo}) has no implementation task" "create canonical TASK via startup dispatch; do NOT auto-create TASK-AUTO" ""
      done
    else
      ASK "→ ${blocked} tasks are blocked — the queue IS the blocker list. Resolve root blockers to unblock candidates."
      NEXT "Action: run PM-1 blocker analysis for each blocked task"
      record_finding "pm" "warning" "" "PM-3" "queue empty but ${blocked} blocked tasks open" "resolve root blockers" "bash scripts/claude-loop-role-engine.sh pm"
    fi
  else
    OK "${candidates} tasks ready — queue is healthy"
    local top_id
    top_id=$(python3 "${DOCS_DIR}/scripts/plan-next-tasks.py" --format json 2>/dev/null | \
      python3 -c "import json,sys; d=json.load(sys.stdin); t=[x for x in d.get('global_next',[]) if x.get('readiness')=='dispatch_now']; print(t[0]['task_id'] if t else '')" 2>/dev/null || echo "")
    if [[ -n "${top_id}" ]]; then
      NEXT "Action: accept ${top_id} via claude-loop-startup.sh — do not re-decompose in Codex PM loop"
      record_finding "pm" "info" "${top_id}" "PM-3" "dispatch_now available (${candidates} candidates)" "accept top task from startup" "bash ${CI_CD_DIR}/scripts/claude-loop-startup.sh"
    fi
  fi

  finish_role "pm" "blocked=$(echo "${blocked_tasks}" | wc -l | tr -d ' ') conflicts=${conflicts_found} queue=${candidates}/${blocked}"
  H1 "PM complete. Top actions and findings.jsonl above."
}

# ══════════════════════════════════════════════════════════════════════════════
# PRODUCT: 3 deep reasoning points
# ══════════════════════════════════════════════════════════════════════════════

role_product() {
  H1 "PRODUCT — Product Manager Reasoning"
  load_cache "product"
  preflight_context

  # ── PROD-1: WHY are Ready contracts not implemented? ───────────────────────
  H1 "PROD-1: Contract-to-Implementation Gap Reasoning"

  local uncovered=0
  local prod1_raw
  prod1_raw=$(python3 -c "
import json, re
from pathlib import Path

docs = Path('${DOCS_DIR}')
ledger = json.loads((docs / 'docs/development/task-state-ledger.json').read_text())
all_tasks = set()
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id'): all_tasks.add(t['task_id'])

contracts_with_gaps = []
ci = docs / 'docs/contracts/contract-index.md'
if not ci.exists():
    print('NO_INDEX')
    exit(0)

for line in ci.read_text().split('\n'):
    if '|' not in line: continue
    parts = [p.strip() for p in line.split('|')]
    if len(parts) < 5: continue
    status = parts[2]
    if status not in ('Ready','Stable'): continue
    domain = parts[0].strip()
    contract_file = parts[1].strip() if len(parts) > 1 else ''
    impacted = parts[4].strip() if len(parts) > 4 else ''
    tasks_in_line = re.findall(r'TASK-[A-Z0-9-]+', line)
    covered = any(t in all_tasks for t in tasks_in_line)
    if not covered:
        contracts_with_gaps.append(f'{domain}|{contract_file}|{status}|{impacted}|{tasks_in_line[0] if tasks_in_line else \"none\"}')

for c in contracts_with_gaps[:10]:
    print(c)
" 2>/dev/null)
  while IFS='|' read -r domain contract status impacted suggested_task; do
    [[ -z "${domain}" ]] && continue
    uncovered=$((uncovered + 1))

    ASK "WHY is '${domain}' (${status} contract) not implemented?"

    # Check: does the contract file exist and have detail?
    local cf="${DOCS_DIR}/docs/contracts/${contract}"
    if [[ -f "${cf}" ]]; then
      local cf_size; cf_size=$(wc -c < "${cf}" | tr -d ' ')
      echo "      contract: ${contract} (${cf_size} bytes)"
      ASK "   Contract is ${status} — implementation should exist. WHY doesn't it?"

      # Reason hypotheses
      ASK "   IF no one created the task → Product gap: decomposition pipeline didn't run"
      ASK "   IF task exists but in wrong status → check ledger for ${suggested_task}"
      ASK "   IF contract was just marked Ready → normal: task creation is next step"
      ASK "   IF contract is purely docs/design → does it actually need implementation?"

      # Check if there's a dependency blocking this
      local suggested_tid="${suggested_task}"
      local in_ledger; in_ledger=$(ledger_get "${suggested_tid}" "status")
      [[ -z "${in_ledger}" ]] && ASK "   ${suggested_tid} NOT in ledger — task was never created"
      [[ -n "${in_ledger}" ]] && ASK "   ${suggested_tid} exists in ledger with status=${in_ledger}"

      NEXT "Action: IF contract needs implementation AND no task exists → create task stub with blocked_by chain. IF task exists but wrong status → fix. IF docs-only → mark contract as Stable."
      record_finding "product" "warning" "${suggested_tid}" "PROD-1" "Ready contract '${domain}' lacks implementation coverage" "create TASK or verify docs-only" ""
    else
      WARN "   contract file missing: ${contract}"
      record_finding "product" "warning" "" "PROD-1" "contract file missing: ${contract}" "restore contract or fix contract-index" ""
    fi
    echo ""
  done <<< "${prod1_raw}"

  [[ "${uncovered}" -eq 0 ]] && OK "all Ready/Stable contracts have task coverage"

  # ── PROD-2: WHY are MVP milestones not progressing? ────────────────────────
  H1 "PROD-2: MVP Milestone Progress Reasoning"

  if [[ -f "${DOCS_DIR}/docs/development/MVP_IMPLEMENTATION_PLAN.md" ]]; then
    local completed ready partial
    completed=$(grep -c "Completed" "${DOCS_DIR}/docs/development/MVP_IMPLEMENTATION_PLAN.md" 2>/dev/null || echo "0")
    ready=$(grep -c "Ready" "${DOCS_DIR}/docs/development/MVP_IMPLEMENTATION_PLAN.md" 2>/dev/null || echo "0")
    partial=$(grep -c "Partial" "${DOCS_DIR}/docs/development/MVP_IMPLEMENTATION_PLAN.md" 2>/dev/null || echo "0")
    local total=$((completed + ready + partial))
    local pct=$(( completed * 100 / (total + 1) ))

    echo "  MVP: ${completed}/${total} completed (${pct}%) | ${ready} ready | ${partial} partial"

    ASK "WHY is completion at ${pct}%? What's blocking the remaining ${ready}+${partial} items?"

    if [[ "${partial}" -gt 0 ]]; then
      ASK "→ ${partial} items are partially complete. WHY are they stuck?"
      ASK "   Check each partial item: is it waiting for evidence? blocked by another task? abandoned?"
      NEXT "Action: audit each partial item — either finish it or explicitly defer with reason"
      record_finding "product" "warning" "" "PROD-2" "MVP: ${partial} partial items stalled at ${pct}% completion" "audit each partial item or defer with reason" ""
    fi
    if [[ "${ready}" -gt 0 ]]; then
      ASK "→ ${ready} items are ready but not started. WHY aren't they dispatched?"
      ASK "   IF queue has other priorities → correct"
      ASK "   IF they depend on blocked tasks → diagnose blockers"
      ASK "   IF no one picked them up → check dispatch pipeline"
      NEXT "Action: ensure ready items are in planner queue with correct priority"
      record_finding "product" "info" "" "PROD-2" "MVP: ${ready} items ready but undispatched at ${pct}% completion" "verify planner priority and dispatch pipeline" ""
    fi
  fi

  # ── PROD-3: WHY are requirements sitting in inbox? ─────────────────────────
  H1 "PROD-3: Requirement Inbox Processing"

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

    inbox_count=$((inbox_count + 1))
    ASK "WHY is this requirement still in inbox? (by=${gen_by}, at=${gen_at})"
    ASK "→ IF it's valid → create TASK stub and move to ledger"
    ASK "→ IF it needs more detail → read source contract, flesh out scope"
    ASK "→ IF it's obsolete → delete or mark as rejected with reason"
    ASK "→ IF awaiting human approval → create GitHub Issue for review"
    NEXT "Action: process or reject each inbox item — inbox should trend to zero"
    record_finding "product" "warning" "" "PROD-3" "requirement still in inbox (by=${gen_by}, at=${gen_at})" "process or reject: create TASK, add detail, or mark rejected" ""
    echo ""
  done
  [[ "${inbox_count}" -eq 0 ]] && OK "requirement inbox clean"

  finish_role "product" "gaps=${uncovered} mvp=${pct:-?}% inbox=${inbox_count}"
  H1 "Product complete."
}

# ══════════════════════════════════════════════════════════════════════════════
# TECH: 3 deep reasoning points
# ══════════════════════════════════════════════════════════════════════════════

role_tech() {
  H1 "TECH — Tech Lead Reasoning"
  load_cache "tech"
  preflight_context

  # ── TECH-1: API/Swagger drift — WHY and what exactly is missing? ───────────
  H1 "TECH-1: API/Swagger Drift Analysis"

  local BACKEND="${LIVEMASK_ROOT}/livemask-backend"
  if [[ -f "${BACKEND}/main.go" ]]; then
    # Extract actual routes from main.go
    local routes; routes=$(grep -oE '"(/[^"]+)"' "${BACKEND}/main.go" 2>/dev/null | tr -d '"' | sort -u)
    local route_count; route_count=$(echo "${routes}" | grep -c "/" || echo "0")

    # Extract swagger paths
    local swagger_paths=""
    for sf in "${BACKEND}/internal/swagger/"*.yaml; do
      [[ -f "${sf}" ]] && swagger_paths+=$(grep -E '^\s+/' "${sf}" 2>/dev/null | sed 's/^[[:space:]]*//' | sed 's/:.*$//')
      swagger_paths+=$'\n'
    done
    local swagger_count; swagger_count=$(echo "${swagger_paths}" | grep -c "/" || echo "0")

    echo "  routes: ${route_count} | swagger paths: ${swagger_count}"

    if [[ "${route_count}" -gt "${swagger_count}" ]]; then
      local diff=$((route_count - swagger_count))
      WARN "${diff} routes may be undocumented"

      # Find exact missing routes
      ASK "WHY are ${diff} routes not in Swagger? Which ones exactly?"
      echo "  Routes in main.go but possibly not in swagger:"
      echo "${routes}" | head -30 | while read -r route; do
        [[ -z "${route}" ]] && continue
        # Skip non-API routes
        [[ "${route}" != /api/* && "${route}" != /admin/* && "${route}" != /internal/* ]] && continue
        local in_swagger; in_swagger=$(echo "${swagger_paths}" | grep -c "${route}" 2>/dev/null || echo "0")
        if [[ "${in_swagger}" -eq 0 ]]; then
          echo "    MISSING: ${route}"
        fi
      done

      ASK "   IF route was just added → normal delay, create Swagger sync task"
      ASK "   IF route has been there for weeks → tech debt, prioritize Swagger completion"
      ASK "   IF route is internal only (/internal/) → may not need public Swagger, document internally"
      NEXT "Action: create TASK-BACKEND-SWAGGER-SYNC listing exact missing routes"
      record_finding "tech" "warning" "TASK-BACKEND-SWAGGER-SYNC" "TECH-1" "${diff} routes may be missing from Swagger" "create swagger sync task" ""
      auto_create_task "tech" "TECH-1" "Sync Swagger/OpenAPI specs: ${diff} routes missing documentation" "P1" "livemask-backend" "${diff} API routes in main.go have no corresponding Swagger/OpenAPI path definition. List exact missing routes, add to internal/swagger/ YAML files, verify with OpenAPI validator."
    else
      OK "Swagger coverage matches or exceeds routes"
    fi
  fi

  # ── TECH-2: DB Migration Safety — WHY was ADD COLUMN used? ─────────────────
  H1 "TECH-2: DB Migration Safety Review"

  local add_cols=0
  cd "${BACKEND}" 2>/dev/null || true
  for go_file in $(grep -rl "ADD COLUMN" internal/ --include="*.go" 2>/dev/null); do
    local cols; cols=$(grep -n "ADD COLUMN" "${go_file}" 2>/dev/null)
    while IFS= read -r line; do
      add_cols=$((add_cols + 1))
      local lineno; lineno=$(echo "${line}" | cut -d: -f1)

      ASK "WHY was ADD COLUMN needed in ${go_file}:${lineno}?"
      echo "      ${line:0:150}"

      # Check for NOT NULL without DEFAULT (dangerous)
      if echo "${line}" | grep -q "NOT NULL" && ! echo "${line}" | grep -q "DEFAULT"; then
        WARN "→ NOT NULL without DEFAULT — this will fail on existing rows with data!"
        ASK "   IF table has existing rows → migration WILL fail. Add DEFAULT or make nullable."
        NEXT "Action: FIX immediately — add DEFAULT value or remove NOT NULL constraint"
        record_finding "tech" "blocker" "" "TECH-2" "NOT NULL without DEFAULT in ${go_file}:${lineno}" "fix migration before merge" ""
      fi

      # Check for indexes on new column
      local col_name; col_name=$(echo "${line}" | grep -oE '[a-z_]+' | tail -3 | head -1 | tr -d '\n' | xargs)
      if [[ -n "${col_name}" ]]; then
        local has_index; has_index=$(grep -c "INDEX.*${col_name}" "${go_file}" 2>/dev/null || echo "0")
        has_index=$(echo "${has_index}" | tr -d '\n' | xargs)
        [[ -n "${has_index}" && "${has_index}" -eq 0 ]] && ASK "   New column '${col_name}' has no index — will queries on this column be slow?"
      fi
    done <<< "${cols}"
  done
  [[ "${add_cols}" -eq 0 ]] && OK "no ADD COLUMN migrations to review"

  # ── TECH-3: Cross-repo interface breakage risk ─────────────────────────────
  H1 "TECH-3: Cross-Repo Interface Change Detection"

  # Check recent backend API changes that might break consumers
  local recent_changes
  recent_changes=$(git -C "${BACKEND}" log --oneline --since="3 days ago" --name-only -- 'internal/handler/*.go' 'main.go' 2>/dev/null | head -30)

  if [[ -n "${recent_changes}" ]]; then
    echo "  recent API changes (3 days):"
    echo "${recent_changes}" | head -15 | while read -r line; do
      [[ -z "${line}" ]] && continue
      echo "    ${line}"
    done

    ASK "WHY were these API changes made? Do downstream consumers know?"
    ASK "→ Check: does Admin use any changed endpoint? (grep in admin/src/lib/)"
    ASK "→ Check: does App model match the new API shape? (grep in app/lib/models/)"
    ASK "→ Check: does CI/CD smoke test the changed paths? (grep in ci-cd/scripts/)"

    # Quick impact scan
    for changed_file in $(echo "${recent_changes}" | grep "internal/" | head -5); do
      local symbol; symbol=$(basename "${changed_file}" .go | sed 's/_test$//')
      echo "      impact scan for '${symbol}':"
      for rd in "${LIVEMASK_ROOT}"/livemask-admin "${LIVEMASK_ROOT}"/livemask-app "${LIVEMASK_ROOT}"/livemask-nodeagent "${LIVEMASK_ROOT}"/livemask-job-service; do
        local rn; rn=$(basename "${rd}")
        local hits; hits=$(grep -rl "${symbol}" "${rd}" --include="*.ts" --include="*.tsx" --include="*.dart" --include="*.go" 2>/dev/null | wc -l | tr -d ' ')
        [[ "${hits}" -gt 0 ]] && ASK "      ${rn}: ${hits} files reference '${symbol}' — VERIFY compatibility"
      done
    done
    NEXT "Action: if API shape changed and consumers not updated → create follow-up tasks for each affected repo"
  else
    OK "no recent API surface changes"
  fi

  finish_role "tech" "swagger_diff=${diff:-0} add_columns=${add_cols}"
  H1 "Tech complete."
}

# ══════════════════════════════════════════════════════════════════════════════
# QA: 3 deep reasoning points
# ══════════════════════════════════════════════════════════════════════════════

role_qa() {
  H1 "QA — Quality Assurance Reasoning"
  load_cache "qa"
  preflight_context

  # ── QA-1: WHY does a completed task lack evidence? ─────────────────────────
  H1 "QA-1: Completion Evidence Deep Verification"

  local evidence_gaps=0
  local qa1_raw
  qa1_raw=$(python3 -c "
import json
from pathlib import Path

ledger = json.loads(Path('${DOCS_DIR}/docs/development/task-state-ledger.json').read_text())
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('status') in ('completed','completed_with_skip','verified'):
            validation = t.get('validation','')
            if len(validation.strip()) < 20:
                print(f\"{t['task_id']}|{t.get('repo','?')}|{t.get('issue','')}\")
" 2>/dev/null | head -5)
  while IFS='|' read -r tid repo issue; do
    [[ -z "${tid}" ]] && continue
    evidence_gaps=$((evidence_gaps + 1))

    ASK "WHY is ${tid} marked completed but has no validation evidence?"

    # Check review contract
    local rf="${DOCS_DIR}/docs/development/review-contracts/${tid}-review.json"
    if [[ -f "${rf}" ]]; then
      local rstate verdict
      read -r rstate verdict <<< "$(python3 -c "
import json; d=json.load(open('${rf}'))
state=d.get('state','?')
for r in d.get('rounds',[]):
    cx=r.get('codex',{})
    if cx: print(state, cx.get('verdict','?')); break
else: print(state, 'no_verdict')
" 2>/dev/null || echo "? ?")"

      ASK "   review contract: state=${rstate} verdict=${verdict}"
      ASK "   IF approved by Codex → ledger validation field should have been filled, find the gap"
      ASK "   IF no review contract → task was completed without review — PROCESS_DEFECT"
      ASK "   IF changes_requested → task should NOT be completed, revert status"
    else
      ASK "   No review contract — completion without review is invalid"
    fi

    # Check if task doc has evidence
    local task_doc="${DOCS_DIR}/docs/development/tasks/${tid}.md"
    if [[ -f "${task_doc}" ]]; then
      local has_evidence; has_evidence=$(grep -c "dev merge\|origin/dev\|validation\|check-docs" "${task_doc}" 2>/dev/null || echo "0")
      ASK "   task doc has ${has_evidence} evidence references"
    fi

    NEXT "Action: IF completed without review → revert to evidence_missing, create review contract. IF review passed but ledger blank → fill ledger validation field."
    record_finding "qa" "warning" "${tid}" "QA-1" "completed task lacks validation evidence" "fill ledger validation or revert status" "bash scripts/claude-loop-role-engine.sh --closure-audit ${tid}"
    echo ""
  done <<< "${qa1_raw}"

  [[ "${evidence_gaps}" -eq 0 ]] && OK "all completed tasks have validation evidence"

  # ── QA-2: WHY are there open bugs? Triage and root cause ───────────────────
  H1 "QA-2: Bug Triage with Root Cause"

  local total_bugs=0
  for repo in "livemask-backend" "livemask-admin" "livemask-app" "livemask-nodeagent" "livemask-website"; do
    local bugs
    bugs=$(gh issue list --repo "MyAiDevs/${repo}" --label "bug" --state open --limit 10 --json number,title,createdAt 2>/dev/null || echo "[]")
    local bug_count; bug_count=$(echo "${bugs}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

    if [[ "${bug_count}" -gt 0 ]]; then
      echo "  ${repo}: ${bug_count} open bugs"
      total_bugs=$((total_bugs + bug_count))

      # Analyze each bug
      local qa2_list
      qa2_list=$(echo "${bugs}" | python3 -c "
import json,sys
for b in json.load(sys.stdin):
    print(f\"{b['number']}|{b['title'][:100]}|{b['createdAt'][:10]}\")
" 2>/dev/null | head -5)
      while IFS='|' read -r num title created; do
        [[ -z "${num}" ]] && continue

        ASK "BUG ${repo}#${num}: '${title}' (since ${created})"
        ASK "   WHY hasn't this been fixed?"

        local age_days; age_days=$(( ($(date +%s) - $(date -j -f "%Y-%m-%d" "${created}" +%s 2>/dev/null || date +%s)) / 86400 ))
        [[ "${age_days}" -gt 7 ]] && ASK "   → ${age_days} days old — is this being ignored? Does it need priority bump?"

        local has_task; has_task=$(python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if '${repo}#${num}' in t.get('issue','') or '/${num}' in t.get('issue',''):
            print(t.get('task_id'))
            break
" 2>/dev/null || echo "")
        [[ -z "${has_task}" ]] && ASK "   → No TASK linked to this bug — needs task creation"
        [[ -n "${has_task}" ]] && ASK "   → Linked to ${has_task} — check task status"

        NEXT "Action: IF no task → create bug-fix task. IF task exists but stalled → diagnose. IF low priority → explicitly defer with reason."
        echo ""
      done <<< "${qa2_list}"
    fi
  done
  [[ "${total_bugs}" -eq 0 ]] && OK "no open bugs across repos"

  # ── QA-3: Regression Risk — WHAT changed in high-risk areas? WHY was it changed? ──
  H1 "QA-3: Regression Risk Assessment"

  for area in "auth" "billing" "payment" "node/credential" "configcenter"; do
    local area_dir="${LIVEMASK_ROOT}/livemask-backend/internal/${area}"
    [[ ! -d "${area_dir}" ]] && continue

    local changes; changes=$(git -C "${LIVEMASK_ROOT}/livemask-backend" log --oneline --since="7 days ago" -- "${area_dir}/" 2>/dev/null)
    local change_count; change_count=$(echo "${changes}" | grep -c "." 2>/dev/null || echo "0")

    if [[ "${change_count}" -gt 0 ]]; then
      WARN "HIGH RISK: ${area} — ${change_count} changes in 7 days"

      ASK "WHY was ${area} changed ${change_count} times?"
      echo "${changes}" | head -3 | while read -r cline; do
        [[ -z "${cline}" ]] && continue
        echo "      ${cline}"
      done

      ASK "→ IF bug fixes → are regression tests in place?"
      ASK "→ IF feature work → is the feature complete or still churning?"
      ASK "→ IF refactoring → are downstream consumers tested?"

      # Check if smoke tests cover this area
      local smoke_coverage; smoke_coverage=$(grep -rl "${area}" "${CI_CD_DIR}/scripts/"*smoke*.sh 2>/dev/null | wc -l | tr -d ' ')
      ASK "→ Smoke coverage for '${area}': ${smoke_coverage} scripts — IF 0, high regression risk"

      NEXT "Action: IF no smoke coverage → create targeted smoke test. IF churn is feature work → prioritize completion. IF bug fixes → verify each fix has a regression test."
      if [[ "${change_count}" -ge 5 && "${smoke_coverage}" -lt 5 ]]; then
        auto_create_task "qa" "QA-3" "Add regression smoke tests for high-churn area: ${area} (${change_count} changes in 7 days, ${smoke_coverage} smoke scripts)" "P1" "livemask-ci-cd" "The ${area} module has ${change_count} changes in 7 days with only ${smoke_coverage} smoke scripts covering it. High regression risk. Create targeted smoke tests for the changed paths."
      fi
      echo ""
    fi
  done

  finish_role "qa" "evidence_gaps=${evidence_gaps} bugs=${total_bugs}"
  H1 "QA complete."
}

# ══════════════════════════════════════════════════════════════════════════════
# TASK REVIEW: GitHub/task evidence-chain auditor
# ══════════════════════════════════════════════════════════════════════════════

role_task_review() {
  H1 "TASK REVIEW — GitHub Issue / Ledger Evidence Chain"
  load_cache "task-review"
  if ! preflight_context; then
    WARN "task-review skipped because PM lease/coordination guard is active"
    finish_role "task-review" "skipped_by_pm_lease"
    return 0
  fi

  local limit="${TASK_REVIEW_LIMIT:-30}"
  local reopen="${TASK_REVIEW_REOPEN:-true}"
  local comment_open="${TASK_REVIEW_COMMENT_OPEN:-false}"
  local report="${ROLE_CACHE_DIR}/task-review-report.json"

  H1 "TASK-REVIEW-1: Closed Issue Completion Claims"
  echo "  scope: recent ${limit} issues per repo; reopen=${reopen}; comment_open=${comment_open}"

  TASK_REVIEW_LIMIT="${limit}" TASK_REVIEW_REOPEN="${reopen}" TASK_REVIEW_COMMENT_OPEN="${comment_open}" \
    DOCS_DIR="${DOCS_DIR}" LIVEMASK_ROOT="${LIVEMASK_ROOT}" python3 - "${report}" <<'PY'
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

out = Path(sys.argv[1])
docs_dir = Path(os.environ["DOCS_DIR"])
limit = int(os.environ.get("TASK_REVIEW_LIMIT", "30"))
reopen_enabled = os.environ.get("TASK_REVIEW_REOPEN", "true").lower() == "true"
comment_open = os.environ.get("TASK_REVIEW_COMMENT_OPEN", "false").lower() == "true"
owner = "MyAiDevs"
repos = [
    "livemask-docs",
    "livemask-ci-cd",
    "livemask-backend",
    "livemask-admin",
    "livemask-app",
    "livemask-nodeagent",
    "livemask-job-service",
    "livemask-website",
]
task_re = re.compile(r"\bTASK-[A-Z0-9][A-Z0-9-]{8,}\b")
bad_claim_re = re.compile(
    r"\b(unverified|not\s+verified|not\s+implemented|todo|blocked|skip|skipped|placeholder|"
    r"manual\s+only|failed|failure|error|没有验证|未验证|未完成|占位)\b",
    re.I,
)
good_evidence_re = re.compile(
    r"\b(pass|passed|success|succeeded|green|origin/dev|dev merge|merged|commit|sha|"
    r"go test|npm test|flutter test|check-docs|smoke|build|deploy|validated|verified)\b",
    re.I,
)
marker_prefix = "<!-- livemask-task-review-reopen:"


def run(cmd, timeout=40):
    try:
        p = subprocess.run(cmd, text=True, capture_output=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except Exception as exc:
        return 124, "", str(exc)


def read_json(path, default):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except Exception:
        return default


def normalize_task_ids(values):
    out = set()
    for value in values:
        tid = str(value).strip().rstrip("-.,;:)]}")
        if tid:
            out.add(tid)
    return out


ledger = read_json(docs_dir / "docs/development/task-state-ledger.json", {"modules": []})
review_dir = docs_dir / "docs/development/review-contracts"
tasks_by_id = {}
issues_to_tasks = {}
for module in ledger.get("modules", []):
    for task in module.get("tasks", []):
        tid = str(task.get("task_id", "")).strip()
        if not tid:
            continue
        tasks_by_id[tid] = task
        issue = str(task.get("issue", "")).strip()
        if issue:
            for repo in repos:
                short = repo.replace("livemask-", "")
                patterns = [
                    rf"{re.escape(owner)}/{re.escape(repo)}#(\d+)",
                    rf"{re.escape(repo)}#(\d+)",
                    rf"github\.com/{re.escape(owner)}/{re.escape(repo)}/issues/(\d+)",
                    rf"\b{re.escape(short)}#(\d+)",
                ]
                for pattern in patterns:
                    m = re.search(pattern, issue, re.I)
                    if m:
                        issues_to_tasks.setdefault((repo, int(m.group(1))), set()).add(tid)


def task_doc_has_evidence(tid):
    path = docs_dir / f"docs/development/tasks/{tid}.md"
    if not path.exists():
        return False, "missing task doc"
    text = path.read_text(encoding="utf-8", errors="ignore")
    if not good_evidence_re.search(text):
        return False, "task doc lacks validation/commit/merge evidence"
    return True, "task doc evidence present"


def validation_strong(task):
    text = " ".join(str(task.get(k, "")) for k in ("validation", "notes", "completed_at", "dev_merge_sha", "origin_dev_sha"))
    return len(text.strip()) >= 30 and bool(good_evidence_re.search(text))


def review_contract_ok(tid):
    path = review_dir / f"{tid}-review.json"
    if not path.exists():
        return False, "missing review contract"
    data = read_json(path, {})
    state = str(data.get("state", "")).lower()
    verdicts = []
    for round_data in data.get("rounds", []):
        codex = round_data.get("codex") or {}
        if codex.get("verdict"):
            verdicts.append(str(codex.get("verdict")).lower())
    if state not in ("closed", "complete", "completed") and "approved" not in verdicts:
        return False, f"review contract not closed/approved (state={state or 'unknown'}, verdicts={verdicts or ['none']})"
    return True, "review contract closed/approved"


def issue_has_task_signal(issue, body, comments):
    labels = [str((label or {}).get("name", "")).lower() for label in issue.get("labels", [])]
    text = "\n".join([issue.get("title", ""), body or ""] + comments)
    return bool(task_re.search(text)) or any("task" in label or "codex" in label or "claude" in label for label in labels)


def dedup_marker(repo, number):
    return f"{marker_prefix}{repo}#{number} -->"


def maybe_comment_or_reopen(repo, number, state, defects, evidence, comments):
    marker = dedup_marker(repo, number)
    if any(marker in c for c in comments):
        return "deduped"
    if state == "CLOSED" and reopen_enabled:
        body = "\n".join([
            marker,
            "Task Review reopened this issue because the completion evidence chain is incomplete.",
            "",
            "Evidence gaps:",
            *[f"- {d}" for d in defects[:8]],
            "",
            "Checked evidence:",
            *[f"- {e}" for e in evidence[:8]],
            "",
            "Required before closing again: task doc + ledger + review contract + local validation + dev merge/CI evidence must all agree.",
        ])
        run(["gh", "issue", "reopen", str(number), "--repo", f"{owner}/{repo}"], timeout=30)
        rc, _, err = run(["gh", "issue", "comment", str(number), "--repo", f"{owner}/{repo}", "--body", body], timeout=30)
        return "reopened" if rc == 0 else f"reopen_comment_failed:{err[:120]}"
    if state == "OPEN" and comment_open:
        body = "\n".join([
            marker,
            "Task Review found an incomplete evidence chain on this still-open issue.",
            "",
            *[f"- {d}" for d in defects[:8]],
        ])
        rc, _, err = run(["gh", "issue", "comment", str(number), "--repo", f"{owner}/{repo}", "--body", body], timeout=30)
        return "commented" if rc == 0 else f"comment_failed:{err[:120]}"
    return "recorded"


def evaluate_issue(repo, issue):
    number = int(issue["number"])
    full_repo = f"{owner}/{repo}"
    rc, raw, err = run([
        "gh", "issue", "view", str(number), "--repo", full_repo,
        "--json", "number,title,state,url,body,labels,comments,closedAt,updatedAt",
    ])
    if rc != 0:
        return [{
            "repo": repo,
            "issue_number": number,
            "issue_url": issue.get("url", ""),
            "state": issue.get("state", "UNKNOWN"),
            "task_ids": [],
            "severity": "warning",
            "defects": [f"could not load issue details: {err[:160]}"],
            "evidence": ["gh issue view failed"],
            "action": "recorded",
        }]
    detail = json.loads(raw)
    body = detail.get("body") or ""
    comments = [str(c.get("body", "")) for c in (detail.get("comments") or [])]
    text = "\n".join([detail.get("title", ""), body] + comments)
    linked_tasks = normalize_task_ids(task_re.findall(text))
    linked_tasks.update(issues_to_tasks.get((repo, number), set()))

    if detail.get("state") == "CLOSED" and not linked_tasks and not issue_has_task_signal(detail, body, comments):
        return []

    defects = []
    evidence = []
    if not linked_tasks:
        defects.append("GitHub issue has task/agent signal but no TASK ID or ledger issue linkage")
        evidence.append("no TASK-* reference in title/body/comments and no ledger issue match")

    for tid in sorted(linked_tasks):
        task = tasks_by_id.get(tid)
        if not task:
            defects.append(f"{tid} is referenced by issue but missing from task-state-ledger.json")
            evidence.append(f"{tid}: no ledger entry")
            continue
        status = str(task.get("status", ""))
        repo_field = str(task.get("repo", ""))
        if repo_field and repo_field != repo and repo != "livemask-docs":
            evidence.append(f"{tid}: ledger repo={repo_field}, issue repo={repo}")
        if status not in ("completed", "completed_with_skip", "verified"):
            defects.append(f"{tid} ledger status is {status or 'blank'}, not completed/verified")
        else:
            evidence.append(f"{tid}: ledger status={status}")
        if not validation_strong(task):
            defects.append(f"{tid} ledger validation evidence is missing or weak")
        else:
            evidence.append(f"{tid}: ledger validation has pass/commit/merge signal")
        doc_ok, doc_msg = task_doc_has_evidence(tid)
        evidence.append(f"{tid}: {doc_msg}")
        if not doc_ok:
            defects.append(f"{tid} {doc_msg}")
        review_ok, review_msg = review_contract_ok(tid)
        evidence.append(f"{tid}: {review_msg}")
        if not review_ok:
            defects.append(f"{tid} {review_msg}")

    if detail.get("state") == "CLOSED" and bad_claim_re.search(text) and not any("accepted skip" in e.lower() for e in evidence):
        defects.append("closed issue comments/body include unverified, skipped, failed, blocked, TODO, or placeholder signal")

    if not defects:
        return []

    severity = "blocker" if detail.get("state") == "CLOSED" else "warning"
    action = maybe_comment_or_reopen(repo, number, detail.get("state", "UNKNOWN"), defects, evidence, comments)
    return [{
        "repo": repo,
        "issue_number": number,
        "issue_url": detail.get("url", issue.get("url", "")),
        "state": detail.get("state", "UNKNOWN"),
        "title": detail.get("title", ""),
        "task_ids": sorted(linked_tasks),
        "severity": severity,
        "defects": defects,
        "evidence": evidence,
        "action": action,
    }]


findings = []
repo_errors = []
for repo in repos:
    rc, raw, err = run([
        "gh", "issue", "list", "--repo", f"{owner}/{repo}", "--state", "all",
        "--limit", str(limit), "--json", "number,title,state,url,labels,updatedAt,closedAt",
    ])
    if rc != 0:
        repo_errors.append({"repo": repo, "error": err[:240]})
        continue
    try:
        issues = json.loads(raw)
    except Exception as exc:
        repo_errors.append({"repo": repo, "error": f"json parse failed: {exc}"})
        continue
    for issue in issues:
        findings.extend(evaluate_issue(repo, issue))

report = {
    "schema_version": 1,
    "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "limit_per_repo": limit,
    "reopen_enabled": reopen_enabled,
    "comment_open": comment_open,
    "repos": repos,
    "repo_errors": repo_errors,
    "finding_count": len(findings),
    "reopened_count": sum(1 for f in findings if f.get("action") == "reopened"),
    "findings": findings,
}
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")

print(f"  report: {out}")
print(f"  findings={len(findings)} reopened={report['reopened_count']} repo_errors={len(repo_errors)}")
for err in repo_errors[:5]:
    print(f"  repo_error {err['repo']}: {err['error']}")
for f in findings[:10]:
    tids = ",".join(f.get("task_ids") or ["NO_TASK"])
    print(f"  [{f['severity'].upper()}] {f['repo']}#{f['issue_number']} {f['state']} action={f['action']} tasks={tids}")
    for defect in f.get("defects", [])[:3]:
        print(f"    - {defect}")
PY

  if [[ ! -f "${report}" ]]; then
    record_finding "task-review" "blocker" "" "TASK-REVIEW" \
      "task review report was not produced" \
      "inspect gh auth/network and rerun task-review" \
      "bash ${CI_CD_DIR}/scripts/claude-loop-role-engine.sh task-review"
    finish_role "task-review" "report_missing"
    return 0
  fi

  while IFS='|' read -r severity tid repo_issue action defect; do
    [[ -z "${severity}" ]] && continue
    local audit_cmd="bash ${CI_CD_DIR}/scripts/claude-loop-role-engine.sh task-review"
    [[ -n "${tid}" ]] && audit_cmd="bash ${CI_CD_DIR}/scripts/claude-loop-role-engine.sh --closure-audit ${tid}"
    record_finding "task-review" "${severity}" "${tid}" "TASK-REVIEW" \
      "${repo_issue}: ${defect} (action=${action})" \
      "reopen or keep open until ledger, task doc, review contract, validation, and CI/dev evidence agree" \
      "${audit_cmd}"
  done < <(python3 - "${report}" <<'PY'
import json
import sys

d = json.load(open(sys.argv[1]))
for f in d.get("findings", [])[:50]:
    tids = f.get("task_ids") or [""]
    tid = tids[0] if tids else ""
    repo_issue = f"{f.get('repo')}#{f.get('issue_number')}"
    defect = "; ".join(f.get("defects", [])[:3]).replace("|", "/")[:500]
    print("|".join([f.get("severity", "warning"), tid, repo_issue, f.get("action", "recorded"), defect]))
PY
)

  local count reopened errors
  read -r count reopened errors <<< "$(python3 - "${report}" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
print(d.get("finding_count",0), d.get("reopened_count",0), len(d.get("repo_errors",[])))
PY
)"
  [[ "${count}" -eq 0 ]] && OK "no closed/open issue evidence-chain defects found in reviewed window"
  [[ "${count}" -gt 0 ]] && WARN "task-review found ${count} evidence-chain defect(s), reopened=${reopened}, repo_errors=${errors}"

  H1 "TASK REVIEW complete."
  finish_role "task-review" "findings=${count} reopened=${reopened} errors=${errors}"
}

# ══════════════════════════════════════════════════════════════════════════════
# DEEP ANALYSIS: single-task deep dives (cross-cutting)
# ══════════════════════════════════════════════════════════════════════════════

deep_review() {
  local tid="${1:-}"
  [[ -z "${tid}" ]] && { echo "Usage: --deep-review <TASK-ID>"; return 1; }

  H1 "DEEP REVIEW: ${tid}"
  sync_all

  echo ""; echo "--- TASK DOC ---"
  local task_doc="${DOCS_DIR}/docs/development/tasks/${tid}.md"
  [[ -f "${task_doc}" ]] && head -60 "${task_doc}" || echo "  not found"

  echo ""; echo "--- LEDGER ---"
  python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id')=='${tid}':
            print(json.dumps({k:t[k] for k in ['status','repo','issue','validation','blocked_by','unlocks','notes'] if k in t}, indent=2))
" 2>/dev/null || echo "  not in ledger"

  echo ""; echo "--- REVIEW CONTRACT ---"
  local rf="${DOCS_DIR}/docs/development/review-contracts/${tid}-review.json"
  if [[ -f "${rf}" ]]; then
    python3 -c "
import json; d=json.load(open('${rf}'))
print(f'state={d.get(\"state\")} round={d.get(\"review_round\")} actor={d.get(\"next_required_actor\")}')
for r in d.get('rounds',[]):
    c=r.get('claude',{}); cx=r.get('codex',{})
    if c: print(f'claude: {c.get(\"submitted_at\")} commit={str(c.get(\"commit\",\"\"))[:7]}')
    for v in c.get('validation',[]): print(f'  validation: {v.get(\"cmd\")} → {v.get(\"result\")}')
    if cx: print(f'codex: verdict={cx.get(\"verdict\")} findings={cx.get(\"findings\",[])}')
" 2>/dev/null
  fi

  echo ""; echo "--- GIT DIFF ---"
  local repo; repo=$(ledger_get "${tid}" "repo")
  [[ -z "${repo}" ]] && repo="livemask-docs"
  cd "${LIVEMASK_ROOT}/${repo}" 2>/dev/null || true
  local branch; branch=$(git branch -r --list "origin/task/*${tid}*" --format='%(refname:short)' 2>/dev/null | head -1 || echo "")
  if [[ -n "${branch}" ]]; then
    git diff "origin/dev...${branch}" --stat 2>/dev/null | head -15
    echo ""; git diff "origin/dev...${branch}" 2>/dev/null | head -200
  elif [[ -f "${rf}" ]]; then
    local tc; tc=$(python3 -c "import json; print(json.load(open('${rf}')).get('task_commit',''))" 2>/dev/null || echo "")
    [[ -n "${tc}" ]] && { git show "${tc}" --stat 2>/dev/null | head -15; echo ""; git show "${tc}" 2>/dev/null | head -150; }
  fi

  echo ""; echo "=== DEEP ANALYSIS PROMPT ==="
  ASK "1. WHY was this implementation approach chosen?"
  ASK "   Compare task doc requirements vs actual code change."
  ASK "   IF approach differs → was the deviation intentional (simpler, constrained) or accidental?"
  echo ""
  ASK "2. WHY might this fail or be incomplete?"
  ASK "   Edge cases not handled? Dependent services not updated? Tests missing?"
  echo ""
  ASK "3. WHAT downstream effects does this have?"
  ASK "   Trace: this change → admin UI → app client → node agent → smoke tests"
  echo ""
  ASK "4. CAN this be closed? What evidence proves it works?"
  ASK "   IF evidence is sufficient → recommend APPROVE"
  ASK "   IF evidence is missing → specify exactly what's needed"
  ASK "   IF implementation is wrong → recommend CHANGES_REQUESTED with concrete fixes"
}

closure_audit() {
  local tid="${1:-}"
  [[ -z "${tid}" ]] && { echo "Usage: --closure-audit <TASK-ID>"; return 1; }

  H1 "CLOSURE AUDIT: ${tid}"
  sync_all

  local score=0 max=7 gaps=()

  check() { max=$((max)); local label="$1"; shift; if eval "$@"; then score=$((score+1)); echo "  [✓] ${label}"; else gaps+=("${label}"); echo "  [✗] ${label}"; fi; }

  local ls; ls=$(ledger_get "${tid}" "status")
  check "ledger status=completed" "[[ '${ls}' == 'completed' || '${ls}' == 'completed_with_skip' ]]"

  local sha=""; local rf="${DOCS_DIR}/docs/development/review-contracts/${tid}-review.json"
  [[ -f "${rf}" ]] && sha=$(python3 -c "import json; print(json.load(open('${rf}')).get('origin_dev_sha',''))" 2>/dev/null || echo "")
  check "origin/dev push evidence" "[[ -n '${sha}' ]]"

  local docs_ok=0
  [[ -f "${rf}" ]] && python3 -c "
import json; d=json.load(open('${rf}'))
for r in d.get('rounds',[]):
    for v in r.get('claude',{}).get('validation',[]):
        if 'check-docs' in v.get('cmd','') and v.get('result')=='pass': print('PASS')
" 2>/dev/null | grep -q "PASS" && docs_ok=1
  check "check-docs.sh PASS" "[[ ${docs_ok} -eq 1 ]]"

  local has_issue; has_issue=$(ledger_get "${tid}" "issue")
  check "GitHub issue linked in ledger" "[[ -n '${has_issue}' ]]"

  local td="${DOCS_DIR}/docs/development/tasks/${tid}.md"
  local doc_done=0; [[ -f "${td}" ]] && grep -q "Completed" "${td}" 2>/dev/null && doc_done=1
  check "task doc marked Completed" "[[ ${doc_done} -eq 1 ]]"

  local repo; repo=$(ledger_get "${tid}" "repo"); [[ -z "${repo}" ]] && repo="livemask-docs"
  local dirty; dirty=$(git -C "${LIVEMASK_ROOT}/${repo}" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  check "target repo clean (${repo})" "[[ ${dirty} -eq 0 ]]"

  local child=0; [[ -f "${rf}" ]] && child=$(python3 -c "import json; print(len(json.load(open('${rf}')).get('links',{}).get('issues',[])))" 2>/dev/null || echo "0")
  check "cross-repo child issues tracked" "[[ ${child} -gt 0 ]]"

  echo ""; echo "SCORE: ${score}/${max}"
  [[ ${score} -ge 6 ]] && echo "VERDICT: READY" || echo "VERDICT: NEEDS EVIDENCE"
  for g in "${gaps[@]}"; do echo "  GAP: $g"; done
  ASK "FOR EACH GAP: WHY does it exist? WHEN will it be resolved? WHO should resolve it?"
}

impact_analysis() {
  local tid="${1:-}"
  [[ -z "${tid}" ]] && { echo "Usage: --impact-analysis <TASK-ID>"; return 1; }
  H1 "IMPACT ANALYSIS: ${tid}"
  sync_all

  local repo; repo=$(ledger_get "${tid}" "repo"); [[ -z "${repo}" ]] && repo="livemask-docs"
  echo "source: ${repo} → ${tid}"

  echo ""; echo "--- UNLOCK CHAIN ---"
  python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
target='${tid}'
blocks=[]; unlocks=[]
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if target in (t.get('blocked_by') or []): blocks.append(t['task_id'])
        if target in (t.get('unlocks') or []): unlocks.append(t['task_id'])
for b in blocks: print(f'  BLOCKS: {b}')
for u in unlocks: print(f'  UNLOCKS: {u}')
if not blocks and not unlocks: print('  (no dependency chain recorded in ledger)')
" 2>/dev/null

  echo ""; echo "--- CODE REFERENCES ---"
  local td="${DOCS_DIR}/docs/development/tasks/${tid}.md"
  if [[ -f "${td}" ]]; then
    for kw in $(grep -oE '[A-Z][a-zA-Z]{4,}' "${td}" 2>/dev/null | sort -u | head -5); do
      echo "  '${kw}' across repos:"
      for rd in "${LIVEMASK_ROOT}"/livemask-*/; do
        local rn; rn=$(basename "${rd}")
        [[ "${rn}" == "${repo}" || "${rn}" == "livemask-docs" || "${rn}" == "livemask-ci-cd" ]] && continue
        [[ ! -d "${rd}" ]] && continue
        local hits; hits=$(grep -rl "${kw}" "${rd}" --include="*.go" --include="*.ts" --include="*.tsx" --include="*.dart" 2>/dev/null | wc -l | tr -d ' ')
        [[ "${hits}" -gt 0 ]] && echo "    ${rn}: ${hits} files"
      done
    done
  fi

  ASK "IF this task completes today, what is the NEXT task that becomes unblocked?"
  ASK "IF this task CAN'T complete, what is the ALTERNATIVE path to the same goal?"
}

# ══════════════════════════════════════════════════════════════════════════════
# ORCHESTRATOR
# ══════════════════════════════════════════════════════════════════════════════

# ── Self-healing: clean up artifacts that the role-engine itself created ─────
self_heal_clean_state() {
  H1 "Self-Heal: Clean State"

  if [[ "${COORDINATION_DECISION:-proceed}" == "read_only" ]]; then
    WARN "coordination read_only — skipping self-heal writes"
    return 0
  fi

  local healed=0

  # 1. Remove empty modules from ledger
  local empty_mods; empty_mods=$(python3 -c "
import json, pathlib
p = pathlib.Path('${DOCS_DIR}/docs/development/task-state-ledger.json')
d = json.loads(p.read_text())
removed = []
new_modules = []
for m in d.get('modules', []):
    tasks = m.get('tasks', [])
    if len(tasks) == 0 and m.get('module_id') in ('auto-tasks',):
        removed.append(m['module_id'])
    else:
        new_modules.append(m)
if removed:
    d['modules'] = new_modules
    p.write_text(json.dumps(d, indent=2, ensure_ascii=False))
    for r in removed: print(r)
" 2>/dev/null)
  if [[ -n "${empty_mods}" ]]; then
    while read -r mod; do
      [[ -z "${mod}" ]] && continue
      ACT "SELF-HEAL: removed empty module '${mod}' from ledger"
      healed=$((healed + 1))
    done <<< "${empty_mods}"
  fi

  # 1b. Remove unlinked TASK-AUTO artifacts created by stale Claude contexts.
  # The docs repo guard is authoritative; this is the automatic cleanup path.
  if [[ -x "${DOCS_DIR}/scripts/check-auto-task-artifacts.py" ]] && \
     ! python3 "${DOCS_DIR}/scripts/check-auto-task-artifacts.py" >/tmp/claude-role-engine-auto-task-check.log 2>&1; then
    local removed_auto; removed_auto=$(python3 - "${DOCS_DIR}" <<'PY' 2>/dev/null
import json, pathlib, sys

root = pathlib.Path(sys.argv[1])
ledger = json.loads((root / "docs/development/task-state-ledger.json").read_text(encoding="utf-8"))
valid = {}
for module in ledger.get("modules", []):
    for task in module.get("tasks", []):
        tid = task.get("task_id")
        if isinstance(tid, str):
            valid[tid] = bool(task.get("issue"))

removed = []
for path in sorted((root / "docs/development/tasks").glob("TASK-AUTO-*.md")):
    if not valid.get(path.stem):
        path.unlink()
        removed.append(path.relative_to(root).as_posix())
for path in sorted((root / "docs/development/dispatch-packets").glob("TASK-AUTO-*.json")):
    try:
        tid = json.loads(path.read_text(encoding="utf-8")).get("task_id")
    except Exception:
        tid = path.stem
    if not valid.get(tid):
        path.unlink()
        removed.append(path.relative_to(root).as_posix())
for item in removed:
    print(item)
PY
)
    if [[ -n "${removed_auto}" ]]; then
      while read -r f; do
        [[ -z "${f}" ]] && continue
        ACT "SELF-HEAL: removed unlinked stale TASK-AUTO artifact: ${f}"
        healed=$((healed + 1))
      done <<< "${removed_auto}"
    fi
  fi

  # 2. Resolve orphaned fallback SAPs (duplicates from repeated cycles)
  local sap_dir="${DOCS_DIR}/docs/development/supervisor-actions"
  if [[ -d "${sap_dir}" ]]; then
    local sap_count=0
    for sf in "${sap_dir}"/SAP-ACTION-NEEDED-*.json; do
      [[ -f "${sf}" ]] || continue
      local sap_task sap_status; read -r sap_task sap_status <<< "$(python3 -c "
import json; d=json.load(open('${sf}'))
print(d.get('task_id',''), d.get('status',''))
" 2>/dev/null || echo '? ?')"
      # Clean up ALL fallback SAPs (self-decompose handles this now, §0.2)
      if [[ "${sap_task}" == "TASK-DOCS-AUTO-DECOMPOSE-FALLBACK" && "${sap_status}" == "open" ]]; then
        sap_count=$((sap_count + 1))
        # Archive it — fallback SAPs are obsolete since self-decompose was implemented
        python3 -c "
import json, pathlib
d = json.load(open('${sf}'))
d['status'] = 'resolved'
d['resolution'] = {'by': 'claude-pm-backup', 'how': 'self-heal: fallback SAP obsolete — self-decompose handles this'}
pathlib.Path('${sf}').write_text(json.dumps(d, indent=2))
" 2>/dev/null
        ACT "SELF-HEAL: resolved obsolete fallback SAP: $(basename ${sf}) (self-decompose now handles this)"
        healed=$((healed + 1))
      fi
    done
  fi

  # 3. Clean up obsolete untracked fallback artifacts from previous incomplete cycles
  cd "${DOCS_DIR}" 2>/dev/null || true
  local untracked; untracked=$(git ls-files --others --exclude-standard 2>/dev/null | grep -E "supervisor-actions/SAP|requirements-inbox/auto-decompose-" | head -5)
  if [[ -n "${untracked}" ]]; then
    while read -r f; do
      [[ -z "${f}" ]] && continue
      if [[ -f "${f}" ]]; then
        rm -f -- "${f}"
        ACT "SELF-HEAL: removed obsolete untracked fallback artifact: ${f}"
        healed=$((healed + 1))
      fi
    done <<< "${untracked}"
  fi

  [[ "${healed}" -eq 0 ]] && OK "state is clean — no self-healing needed"
}

run_all() {
  role_pm || true
  role_product || true
  role_tech || true
  role_qa || true
  role_task_review || true

  self_heal_clean_state || true

  set +e  # don't let Lark, print, or diagnostic failures kill the cycle
  print_top_actions 5

  # ── PM decision layer: diagnose safely, queue mutating actions for humans/PM ──
  echo ""
  echo -e "${BOLD}${CYAN}═══ PM Decision Summary ═══${RESET}"
  write_decision_summary || true
  if [[ -f "${ROLE_CACHE_DIR}/decision-summary.json" ]]; then
    local decision_memory
    decision_memory=$(python3 -c "
import json
d=json.load(open('${ROLE_CACHE_DIR}/decision-summary.json'))
print(f\"classification={d.get('classification')} next_actor={d.get('next_required_actor')} counts={d.get('counts')}\")
" 2>/dev/null || echo "role-engine decision summary")
    bash "${ADAPTER_LIB}" memory-add "role-engine-decision" "" "livemask-docs" "${decision_memory}" "${ROLE_CACHE_DIR}/decision-summary.json" >/dev/null 2>&1 || true
  fi

  echo ""
  echo -e "${BOLD}${CYAN}═══ Safe Diagnostic Actions ═══${RESET}"
  local executed=0
  while IFS=$'\t' read -r sev tid cmd; do
    [[ -z "${cmd}" ]] && continue
    if is_safe_diagnostic_cmd "${cmd}"; then
      echo "  diagnosing: ${cmd}"
      run_safe_diagnostic_cmd "${cmd}" 2>&1 | head -8 || true
      executed=$((executed + 1))
      [[ "${executed}" -ge 3 ]] && break
    else
      echo "  queued only: ${cmd}"
    fi
  done < <(python3 -c "
import json
severity_order = {'blocker': 0, 'warning': 1, 'info': 2}
findings = []
with open('${FINDINGS_FILE}') as f:
    for line in f:
        line = line.strip()
        if line: findings.append(json.loads(line))
findings.sort(key=lambda f: severity_order.get(f.get('severity','info'), 3))
for f in findings[:10]:
    cmd = f.get('cmd','')
    if cmd and (cmd.startswith('bash ') or cmd.startswith('python3 ')):
        print(f['severity'] + '\t' + f.get('task_id','') + '\t' + cmd)
" 2>/dev/null)
  [[ "${executed}" -gt 0 ]] && echo "  ran ${executed} safe diagnostic action(s)" || echo "  no safe diagnostic actions found"

  # Lark: aggregate summary card
  local total_findings; total_findings=$(wc -l < "${FINDINGS_FILE}" 2>/dev/null | tr -d ' ' || echo "0")
  lark_card_batch "Role Engine All — $(date -u +%H:%M)Z" \
    "[{\"emoji\":\"📋\",\"label\":\"PM\",\"value\":\"${total_findings} findings\"},{\"emoji\":\"🎯\",\"label\":\"Product\",\"value\":\"MVP audit done\"},{\"emoji\":\"🔧\",\"label\":\"Tech\",\"value\":\"Swagger/DB/API check\"},{\"emoji\":\"🔍\",\"label\":\"QA\",\"value\":\"Evidence + bugs verified\"},{\"emoji\":\"🧾\",\"label\":\"Task Review\",\"value\":\"GitHub evidence chain\"}]" 2>/dev/null || true
  set -e

  push_changes "role-engine: full cycle $(date -u +%Y-%m-%dT%H:%MZ)"
  echo ""
  echo -e "  Machine-readable findings: ${FINDINGS_FILE}"
  echo "  Decision summary: ${ROLE_CACHE_DIR}/decision-summary.json"
  echo "  Consume: bash ${ADAPTER_LIB} findings-search"

  # ── Model Reasoning Handoff ──────────────────────────────────────────
  # The role engine has collected data. Now hand off to the model for reasoning.
  # The model MUST read the findings and decision summary, then:
  # 1. Reason about root causes (WHY each finding exists)
  # 2. Prioritize actions (what to fix first)
  # 3. Execute fixes (not just report)
  echo ""
  echo -e "${BOLD}${CYAN}═══ Model Reasoning Handoff ═══${RESET}"
  echo ""
  echo "  The role engine has finished data collection."
  echo "  The MODEL must now reason about these findings and take action."
  echo ""
  echo "  Quick reasoning commands:"
  echo "    source ${CI_CD_DIR}/scripts/lib/reasoning-engine.sh"
  echo "    reasoning_startup_decision    # What to work on and why"
  echo "    reasoning_flow_diagnosis       # Why is work not flowing?"
  echo "    reasoning_self_heal            # What can be auto-fixed?"
  echo "    reasoning_local_verify <repo>   # Verify a repo locally"
  echo "    reasoning_github_context <repo> # Get GitHub context"
  echo ""
  echo "  Memory commands:"
  echo "    memory_save_decision <ctx> <decision> <reasoning>"
  echo "    memory_search <query>"
  echo "    memory_recent_decisions 24"
  echo "    memory_learned_patterns"
  echo ""
  echo "  Executor guard commands (crash recovery, lease renewal, verify gate):"
  echo "    executor_full_guard <TASK-ID> <repo>  # Full guard cycle before/after commit"
  echo "    executor_renew_lease <agent> <TASK>   # Renew PM lease (every 10min)"
  echo "    executor_crash_recovery               # Recover from executor crash"
  echo "    executor_pre_commit_verify <repo>     # Build/test/lint before commit"
  echo "    executor_load_learnings [TASK-ID]     # Load learned patterns + tips"
  echo "    executor_check_review_timeout         # Check for stale reviews"
  echo "    executor_check_qa_retries [TASK-ID]   # Check QA retry limits"
  echo ""
  echo "  Monitor & self-learning commands:"
  echo "    monitor_watch                     # Observe executor activity (git, CI, tasks)"
  echo "    monitor_analyze                   # Detect patterns from observations"
  echo "    monitor_learn                     # Generate executor guidance from patterns"
  echo "    monitor_self_update               # Apply learnings to improve system"
  echo "    monitor_full_cycle                # Watch→Analyze→Learn→Update (full cycle)"
  echo "    monitor_guide_executor [TASK-ID]  # Real-time guidance for executor"
  echo ""
  echo "  Review gate commands (executor→leader→QA→merge):"
  echo "    executor_submit_review <TASK-ID>   # Submit implementation for review"
  echo "    leader_review <TASK-ID>            # Model reviews code diff + evidence"
  echo "    qa_verify <TASK-ID>                # QA runs build/test/acceptance"
  echo "    leader_approve <TASK-ID>           # Approve → executor merges to dev"
  echo "    leader_request_changes <TASK-ID> \"<reason>\"  # Request fixes"
  echo "    review_status [TASK-ID]            # Check review state"
  echo ""
  echo "  Ledger intelligence commands:"
  echo "    ledger_health_dashboard          # Status overview"
  echo "    ledger_dispatch_recommendations  # What to work on next"
  echo "    ledger_find_stuck 5              # Tasks with no recent activity"
  echo "    ledger_closure_score <TASK-ID>   # 0-100 readiness score"
  echo "    ledger_trace_blockers <TASK-ID>  # Dependency chain to root"
  echo "    ledger_unblock_impact <TASK-ID>  # What completing this unlocks"
  echo "    ledger_full_report               # Complete intelligence report"
  echo ""

  # Auto-run monitor to observe executor activity and learn
  monitor_watch 2>/dev/null || true

  # Auto-save cycle memory for future retrieval
  local cycle_summary; cycle_summary="role-engine cycle $(date -u +%Y-%m-%dT%H:%MZ): ${total_findings} findings, docs_head=${NOW_SHA}"
  memory_put "role-engine-cycle-$(date -u +%Y%m%d-%H%M%S)" "cycle" "${cycle_summary}" "role-engine,cycle,auto" 2>/dev/null || true
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

# Check if another agent is running PM — skip if so
if [[ "${PM_SKIP:-0}" -eq 1 ]]; then
  echo -e "  ${YELLOW}[SKIP]${RESET} Another agent holds PM lease. Exiting to avoid collision."
  echo "  Check: cat ${PM_LEASE_FILE}"
  release_pm_lease 2>/dev/null || true
  exit 0
fi

# ── Proactive health check: catch problems before they become bugs ─────────
health_check_all 2>/dev/null || true
claude_self_audit_gate 2>/dev/null || true

RUNTIME_TASK_ID=""
RUNTIME_TASK_REPO=""
if [[ "${ARG2:-}" =~ ^TASK- ]]; then
  RUNTIME_TASK_ID="${ARG2}"
elif [[ -f "${AGENT_STATE}" ]]; then
  RUNTIME_TASK_ID="$(python3 -c "import json; d=json.load(open('${AGENT_STATE}')); print(d.get('current_task',{}).get('task_id') or '')" 2>/dev/null || true)"
fi
if [[ -n "${RUNTIME_TASK_ID}" && "${RUNTIME_TASK_ID}" != "null" ]]; then
  RUNTIME_TASK_REPO="$(current_task_repo_hint "${RUNTIME_TASK_ID}")"
else
  RUNTIME_TASK_ID=""
fi
runtime_log_audit_findings "${RUNTIME_TASK_ID}" "${RUNTIME_TASK_REPO}" 2>/dev/null || true
task_environment_freshness_findings "${RUNTIME_TASK_ID}" "${RUNTIME_TASK_REPO}" 2>/dev/null || true

case "${ROLE}" in
  pm)
    role_pm
    print_top_actions 3
    echo "  Machine-readable findings: ${FINDINGS_FILE}"
    ;;
  product)
    role_product
    print_top_actions 3
    echo "  Machine-readable findings: ${FINDINGS_FILE}"
    ;;
  tech)
    role_tech
    print_top_actions 3
    echo "  Machine-readable findings: ${FINDINGS_FILE}"
    ;;
  qa)
    role_qa
    print_top_actions 3
    echo "  Machine-readable findings: ${FINDINGS_FILE}"
    ;;
  task-review)
    role_task_review
    print_top_actions 3
    echo "  Machine-readable findings: ${FINDINGS_FILE}"
    echo "  Task review report: ${ROLE_CACHE_DIR}/task-review-report.json"
    ;;
  all)
    # Pre-flight PM lease check before running all roles.
    # Without this, each role calls preflight_context individually (5x)
    # and the MAIN-level PM_SKIP guard never fires for 'all' mode.
    if ! acquire_pm_lease "claude-pm-backup"; then
      echo -e "  ${YELLOW}[SKIP]${RESET} PM lease held by another agent. Exiting to avoid collision."
      exit 0
    fi
    run_all
    release_pm_lease 2>/dev/null || true
    ;;
  --deep-review)     deep_review "${ARG2}";;
  --closure-audit)   closure_audit "${ARG2}";;
  --impact-analysis) impact_analysis "${ARG2}";;
  *)
    echo "Usage: bash scripts/claude-loop-role-engine.sh <role|mode> [args]"
    echo ""
    echo "  Reasoning roles (each asks WHY and produces NEXT actions):"
    echo "    pm       — Blocked task root cause, doc/ledger consistency, queue health"
    echo "    product  — Contract gaps, MVP progress, inbox processing"
    echo "    tech     — API/Swagger drift, DB migration safety, interface breakage"
    echo "    qa       — Evidence verification, bug triage, regression risk"
    echo "    task-review — GitHub issue/comment + ledger/task-doc evidence-chain audit"
    echo "    all      — All roles + push changes"
    echo ""
    echo "  Deep dives (single task, full reasoning):"
    echo "    --deep-review <TASK>      — Implementation quality + approach reasoning"
    echo "    --closure-audit <TASK>    — 7-point scoring + gap diagnosis"
    echo "    --impact-analysis <TASK>  — Dependency chain + code reference trace"
    exit 1
    ;;
esac

release_pm_lease 2>/dev/null || true
log_summary "role-engine" 0 "${ROLE}" 2>/dev/null || true
log_debug_info 2>/dev/null || true
