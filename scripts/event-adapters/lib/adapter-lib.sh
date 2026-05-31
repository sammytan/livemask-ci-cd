#!/usr/bin/env bash
# TASK-CICD-EVENT-ADAPTER-LIB-001
# Shared library for LiveMask event poller adapters.
# Provides: event writing, cursor persistence, dedup checks, snapshot mode,
# and project knowledge discovery for Claude loop/preflight.
#
# Usage:
#   # As a library from pollers:
#   source scripts/event-adapters/lib/adapter-lib.sh
#   adapter_init
#
#   # As a CLI knowledge helper from livemask-ci-cd:
#   bash scripts/event-adapters/lib/adapter-lib.sh knowledge-sources
#   bash scripts/event-adapters/lib/adapter-lib.sh knowledge-inventory [max_files]
#   bash scripts/event-adapters/lib/adapter-lib.sh knowledge-search "<query>" [limit]
#   bash scripts/event-adapters/lib/adapter-lib.sh task-ledger-entry <TASK-ID>
#   bash scripts/event-adapters/lib/adapter-lib.sh task-context <TASK-ID>
#   bash scripts/event-adapters/lib/adapter-lib.sh repo-doc-hints [livemask-backend]
#
# Claude rule:
#   Before implementing, submitting review, or closing a TASK-*, use
#   task-context + task-ledger-entry + knowledge-search to build a docs context
#   bundle from livemask-docs. Local event cache is only a hint layer; the docs
#   repo, task ledger, review contracts, SAPs, GitHub Issues, and Actions remain
#   authoritative.
set -euo pipefail

# ── Guard against double-sourcing ─────────────────────────────────────────────
if [[ -n "${ADAPTER_LIB_LOADED:-}" ]]; then
  return 0
fi
ADAPTER_LIB_LOADED=1

# ── Paths ─────────────────────────────────────────────────────────────────────
ADAPTER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_SCRIPTS_DIR="$(dirname "${ADAPTER_LIB_DIR}")"
CI_CD_DIR="$(cd "${ADAPTER_SCRIPTS_DIR}/../.." && pwd)"
LIVEMASK_ROOT="$(cd "${CI_CD_DIR}/.." && pwd)"
EVENT_CACHE_DIR="${HOME}/.claude/event-cache"
EVENT_CACHE_FILE="${EVENT_CACHE_DIR}/event-cache.jsonl"
EVENT_SCHEMA="${CI_CD_DIR}/scripts/schemas/event-schema-v1.json"
CURSOR_SCHEMA="${CI_CD_DIR}/scripts/schemas/adapter-cursors-schema-v1.json"
ROLE_CACHE_DIR="${HOME}/.claude/role-cache"
FINDINGS_FILE="${ROLE_CACHE_DIR}/findings.jsonl"
PM_LEASE_FILE="${ROLE_CACHE_DIR}/pm-lease.json"
PROJECT_MEMORY_FILE="${ROLE_CACHE_DIR}/project-memory.jsonl"
DOCS_REPO_DIR="${LIVEMASK_ROOT}/livemask-docs"
DOCS_DIR="${DOCS_REPO_DIR}/docs"
DOCS_DEVELOPMENT_DIR="${DOCS_DIR}/development"
TASK_LEDGER_FILE="${DOCS_DEVELOPMENT_DIR}/task-state-ledger.json"
REVIEW_CONTRACTS_DIR="${DOCS_DEVELOPMENT_DIR}/review-contracts"
DISPATCH_PACKETS_DIR="${DOCS_DEVELOPMENT_DIR}/dispatch-packets"
SUPERVISOR_ACTIONS_DIR="${DOCS_DEVELOPMENT_DIR}/supervisor-actions"
AGENT_STATE_FILE="${LIVEMASK_ROOT}/.claude/agent-state.json"

# Project knowledge sources are authoritative search roots for Claude loop,
# event pollers, and preflight helpers. The local event cache can point to work,
# but these files define the project state and technical context.
ADAPTER_KNOWLEDGE_SOURCES=(
  "docs/README.md|global docs index"
  "docs/DEVELOPMENT.md|development entrypoint"
  "docs/development/AI_PROJECT_STATUS_ONBOARDING.md|first-read AI project status"
  "docs/development/CLAUDE_LOOP_SUPERVISOR_RULES.md|Claude loop hard rules"
  "docs/development/task-state-ledger.json|cross-repo task state ledger"
  "docs/development/MVP_IMPLEMENTATION_PLAN.md|MVP progress and dependencies"
  "docs/development/tasks/README.md|task document index"
  "docs/development/review-contracts|structured Codex review contracts"
  "docs/development/supervisor-actions|supervisor action packets"
  "docs/development/completion-reports|task completion evidence"
  "docs/development/ISSUE_TASK_SYNC_GOVERNANCE.md|GitHub issue/task sync rules"
  "docs/development/DEFINITION_OF_DONE.md|completion gate"
  "docs/development/CHANGE_TO_DOC_MATRIX.md|change-to-doc routing"
  "docs/development/AUTO_AUDIT_CENTER.md|audit and consistency checks"
  "docs/development/CODEX_TASK_DISPATCHER_ROLE.md|Codex supervisor role"
  "docs/architecture|system and technical architecture"
  "docs/contracts|API, data, event, runtime, and feature contracts"
  "docs/backend|backend implementation and collaboration docs"
  "docs/admin|admin product and UI docs"
  "docs/app|mobile app runtime and security docs"
  "docs/nodeagent|node agent docs when present"
  "docs/job-service|job-service docs when present"
  "docs/website|website docs when present"
  "docs/data|database migration and data consistency docs"
  "docs/operations|runtime, CI/CD, support, and operational docs"
  "docs/archive/AI_Knowledge_Base.md|legacy knowledge base, reference only"
)

ADAPTER_REPO_DOC_HINTS=(
  "livemask-docs|docs/README.md docs/DEVELOPMENT.md docs/development/AI_PROJECT_STATUS_ONBOARDING.md docs/development/CLAUDE_LOOP_SUPERVISOR_RULES.md docs/development/task-state-ledger.json docs/development/tasks docs/development/review-contracts"
  "livemask-ci-cd|docs/development/CLAUDE_LOOP_SUPERVISOR_RULES.md docs/development/AUTO_AUDIT_CENTER.md docs/development/ISSUE_TASK_SYNC_GOVERNANCE.md docs/development/LiveMask_测试策略与CI_CD落地文件_v3.6.md docs/operations"
  "livemask-backend|docs/backend docs/contracts/api docs/contracts/admin docs/contracts/nodeagent docs/contracts/geoip docs/data docs/architecture docs/development/tasks"
  "livemask-admin|docs/admin docs/contracts/admin docs/contracts/api docs/contracts/i18n docs/development/tasks"
  "livemask-app|docs/app docs/contracts/app docs/contracts/vpn docs/contracts/api docs/development/tasks"
  "livemask-nodeagent|docs/contracts/nodeagent docs/contracts/protocol-endpoint docs/app/VPN_NATIVE_RUNTIME_CONTRACT.md docs/development/tasks"
  "livemask-job-service|docs/contracts/jobs docs/data docs/backend docs/development/tasks"
  "livemask-website|docs/website docs/contracts/content docs/contracts/config docs/development/tasks"
)

# ── In-memory cursor state (populated by adapter_load_cursors) ────────────────
CURSOR_DATA="{}"
CURSOR_CORRUPT=0
CURSOR_FILE_MISSING=0

# ── adapter_init ──────────────────────────────────────────────────────────────
# Set up cache directory. Call once at poller start.
adapter_init() {
  mkdir -p "${EVENT_CACHE_DIR}"

  if ! command -v gh &>/dev/null; then
    echo "ERROR: gh CLI not found. Install GitHub CLI and authenticate." >&2
    return 1
  fi

  if ! gh auth status &>/dev/null 2>&1; then
    echo "WARNING: gh auth status failed. Some GitHub commands may not work." >&2
  fi

  touch "${EVENT_CACHE_FILE}" 2>/dev/null || true
  return 0
}

# ── adapter_require_docs_repo ─────────────────────────────────────────────────
# Ensure the docs repo is present before knowledge lookups.
adapter_require_docs_repo() {
  if [[ ! -d "${DOCS_REPO_DIR}/.git" || ! -d "${DOCS_DIR}" ]]; then
    echo "ERROR: livemask-docs not found at ${DOCS_REPO_DIR}" >&2
    return 1
  fi
  return 0
}

# ── adapter_print_knowledge_sources ───────────────────────────────────────────
# Print canonical docs/knowledge sources as tab-separated records:
#   relative_path<TAB>purpose<TAB>exists|missing
adapter_print_knowledge_sources() {
  adapter_require_docs_repo || return 1

  local entry rel purpose abs status
  for entry in "${ADAPTER_KNOWLEDGE_SOURCES[@]}"; do
    rel="${entry%%|*}"
    purpose="${entry#*|}"
    abs="${DOCS_REPO_DIR}/${rel}"
    if [[ -e "${abs}" ]]; then
      status="exists"
    else
      status="missing"
    fi
    printf '%s\t%s\t%s\n' "${rel}" "${purpose}" "${status}"
  done
}

# ── adapter_print_repo_doc_hints ──────────────────────────────────────────────
# Print the preferred docs to read for one target repo, or all mappings.
adapter_print_repo_doc_hints() {
  local target_repo="${1:-}"
  local entry repo paths

  for entry in "${ADAPTER_REPO_DOC_HINTS[@]}"; do
    repo="${entry%%|*}"
    paths="${entry#*|}"
    if [[ -z "${target_repo}" || "${repo}" == "${target_repo}" ]]; then
      printf '%s\t%s\n' "${repo}" "${paths}"
    fi
  done
}

# ── adapter_search_knowledge ──────────────────────────────────────────────────
# Search LiveMask docs and knowledge files. Uses rg with grep fallback.
# Usage: adapter_search_knowledge "TASK-ID|route|table|keyword" [limit]
adapter_search_knowledge() {
  local query="${1:-}"
  local limit="${2:-80}"

  if [[ -z "${query}" ]]; then
    echo "ERROR: adapter_search_knowledge requires a query" >&2
    return 2
  fi
  adapter_require_docs_repo || return 1

  if command -v rg &>/dev/null; then
    rg -n --hidden --glob '!**/.git/**' --glob '!**/.DS_Store' \
      --glob '!docs/development/completion-reports/*.json' \
      --glob '!docs/development/automation-runs/*.md' \
      "${query}" \
      "${DOCS_DIR}" \
      | head -n "${limit}" || true
  else
    # Fallback to grep when rg is not available
    grep -rn --include="*.md" --include="*.json" --include="*.yml" \
      --exclude-dir=".git" --exclude-dir="completion-reports" --exclude-dir="automation-runs" \
      "${query}" "${DOCS_DIR}" 2>/dev/null | head -n "${limit}" || true
  fi
}

# ── adapter_findings_search ───────────────────────────────────────────────────
# Search role-engine findings for a specific task or keyword.
# Usage: adapter_findings_search [TASK-ID|keyword] [limit]
adapter_findings_search() {
  local query="${1:-}"
  local limit="${2:-20}"

  if [[ ! -f "${FINDINGS_FILE}" ]]; then
    echo '{"findings":[],"note":"findings.jsonl not found — role-engine may not have run yet"}'
    return 0
  fi

  if [[ -z "${query}" ]]; then
    # Show all findings, most recent first
    python3 -c "
import json
findings = []
with open('${FINDINGS_FILE}') as f:
    for line in f:
        line = line.strip()
        if line: findings.append(json.loads(line))
findings.reverse()
print(json.dumps({'findings': findings[:${limit}], 'total': len(findings)}, ensure_ascii=False, indent=2))
" 2>/dev/null
  else
    # Filter by task_id or keyword in finding/next
    python3 -c "
import json
findings = []
with open('${FINDINGS_FILE}') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        d = json.loads(line)
        tid = d.get('task_id','')
        finding = d.get('finding','')
        nxt = d.get('next','')
        combined = f\"{tid} {finding} {nxt}\"
        if '${query}' in combined:
            findings.append(d)
findings.reverse()
print(json.dumps({'findings': findings[:${limit}], 'matching': len(findings)}, ensure_ascii=False, indent=2))
" 2>/dev/null
  fi
}

# ── adapter_pm_status ─────────────────────────────────────────────────────────
# Show PM mutual exclusion status — who is running, what phase, when.
# Usage: adapter_pm_status
adapter_pm_status() {
  if [[ ! -f "${PM_LEASE_FILE}" ]]; then
    echo '{"pm_lease":"none","note":"No PM cycle running. Both Claude and Codex are free to start."}'
    return 0
  fi

  python3 - "${PM_LEASE_FILE}" <<'PY'
import json, time, sys
d = json.load(open(sys.argv[1]))
age_sec = time.time() - d.get('started_at_epoch', 0)
age_min = age_sec / 60
ttl_min = 15
d['age_min'] = round(age_min, 1)
d['status'] = 'active' if age_min < ttl_min else 'stale'
agent = d.get('agent','?')
phase = d.get('phase','?')
if age_min < ttl_min:
    d['note'] = f"Agent '{agent}' is running PM (phase={phase}, {round(age_min,1)}min ago)."
else:
    d['note'] = f"Lease is stale ({round(age_min,1)}min > {ttl_min}min TTL). Safe to take over."
print(json.dumps(d, indent=2, ensure_ascii=False))
PY
}

# ── adapter_dispatch_status ──────────────────────────────────────────────────
# Show dispatch packet status for a task or all packets.
# Usage: adapter_dispatch_status [TASK-ID]
adapter_dispatch_status() {
  local tid="${1:-}"
  if [[ ! -d "${DISPATCH_PACKETS_DIR}" ]]; then
    echo '{"packets":[],"note":"dispatch-packets dir not found"}'
    return 0
  fi

  if [[ -n "${tid}" ]]; then
    local dp="${DISPATCH_PACKETS_DIR}/${tid}.json"
    if [[ -f "${dp}" ]]; then
      python3 -c "import json; print(json.dumps(json.load(open('${dp}')), indent=2, ensure_ascii=False))" 2>/dev/null
    else
      echo "{\"task_id\":\"${tid}\",\"packet\":\"none\"}"
    fi
  else
    python3 -c "
import json, pathlib, os
packets = []
for f in sorted(pathlib.Path('${DISPATCH_PACKETS_DIR}').glob('TASK-*.json')):
    d = json.loads(f.read_text())
    packets.append({'task_id': d.get('task_id'), 'assigned_to': d.get('assigned_to'), 'assigned_at': d.get('assigned_at'), 'repo': d.get('repo')})
print(json.dumps({'packets': packets, 'total': len(packets)}, indent=2, ensure_ascii=False))
" 2>/dev/null
  fi
}

# ── adapter_knowledge_inventory ───────────────────────────────────────────────
# Emit a JSON inventory of current LiveMask docs. This is the shared knowledge
# catalog that lets Claude discover product, technical, contract, task, and
# evidence documents without relying on prompt memory.
adapter_knowledge_inventory() {
  local max_files="${1:-1000}"
  adapter_require_docs_repo || return 1

  python3 - "${DOCS_REPO_DIR}" "${max_files}" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

docs_repo = Path(sys.argv[1])
max_files = int(sys.argv[2])
docs_dir = docs_repo / "docs"

skip_parts = {
    ".git",
    ".DS_Store",
}
skip_suffixes = {
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".webp",
    ".pdf",
}

def category_for(rel: str) -> str:
    parts = rel.split("/")
    if rel == "docs/README.md":
        return "global_index"
    if rel == "docs/DEVELOPMENT.md":
        return "development_entrypoint"
    if len(parts) >= 3 and parts[1] == "development":
        if len(parts) >= 4 and parts[2] == "tasks":
            return "task_doc"
        if len(parts) >= 4 and parts[2] == "completion-reports":
            return "completion_evidence"
        if len(parts) >= 4 and parts[2] == "supervisor-actions":
            return "supervisor_action_packet"
        if len(parts) >= 4 and parts[2] == "review-contracts":
            return "review_contract"
        if len(parts) >= 4 and parts[2] == "schemas":
            return "schema"
        return "development_governance"
    if len(parts) >= 3:
        return parts[1]
    return "docs"

def first_heading(path: Path) -> str:
    try:
        with path.open(encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if line.startswith("#"):
                    return line.lstrip("#").strip()
    except OSError:
        return ""
    return ""

files = []
for path in sorted(docs_dir.rglob("*")):
    if not path.is_file():
        continue
    rel = path.relative_to(docs_repo).as_posix()
    if any(part in skip_parts for part in path.parts):
        continue
    if path.suffix.lower() in skip_suffixes:
        continue
    if len(files) >= max_files:
        break
    files.append({
        "path": rel,
        "category": category_for(rel),
        "title": first_heading(path),
        "suffix": path.suffix,
    })

by_category = {}
for item in files:
    by_category[item["category"]] = by_category.get(item["category"], 0) + 1

print(json.dumps({
    "schema_version": 1,
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "docs_repo": str(docs_repo),
    "file_count": len(files),
    "by_category": by_category,
    "files": files,
}, ensure_ascii=False, indent=2))
PY
}

# ── adapter_task_ledger_entry ─────────────────────────────────────────────────
# Print the exact task-state-ledger entry for a TASK-* as compact JSON.
adapter_task_ledger_entry() {
  local task_id="${1:-}"
  if [[ -z "${task_id}" ]]; then
    echo "ERROR: adapter_task_ledger_entry requires TASK_ID" >&2
    return 2
  fi
  adapter_require_docs_repo || return 1

  if [[ ! -f "${TASK_LEDGER_FILE}" ]]; then
    echo "ERROR: task ledger missing at ${TASK_LEDGER_FILE}" >&2
    return 1
  fi

  python3 - "${TASK_LEDGER_FILE}" "${task_id}" <<'PY'
import json
import sys
from pathlib import Path

ledger_path = Path(sys.argv[1])
task_id = sys.argv[2]
ledger = json.loads(ledger_path.read_text())
matches = []

def walk(value, path=""):
    if isinstance(value, dict):
        if value.get("task_id") == task_id:
            matches.append({"path": path or "$", "entry": value})
        for key, child in value.items():
            walk(child, f"{path}.{key}" if path else key)
    elif isinstance(value, list):
        for idx, child in enumerate(value):
            walk(child, f"{path}[{idx}]")

walk(ledger)
if not matches:
    print(json.dumps({
        "task_id": task_id,
        "found": False,
        "ledger": str(ledger_path),
    }, ensure_ascii=False))
    sys.exit(3)

print(json.dumps({
    "task_id": task_id,
    "found": True,
    "matches": matches,
}, ensure_ascii=False))
PY
}

# ── adapter_task_context_bundle ───────────────────────────────────────────────
# Build a machine-readable docs context bundle for a TASK-*.
# This does not replace authoritative reads; it tells Claude exactly what to
# read/search before implementation, review, or closure.
adapter_task_context_bundle() {
  local task_id="${1:-}"
  if [[ -z "${task_id}" ]]; then
    echo "ERROR: adapter_task_context_bundle requires TASK_ID" >&2
    return 2
  fi
  adapter_require_docs_repo || return 1

  python3 - "${DOCS_REPO_DIR}" "${task_id}" <<'PY'
import json
import sys
from pathlib import Path

docs_repo = Path(sys.argv[1])
task_id = sys.argv[2]
docs_dir = docs_repo / "docs"
dev_dir = docs_dir / "development"

def exists(rel):
    return (docs_repo / rel).exists()

def maybe(rel, reason):
    return {
        "path": rel,
        "reason": reason,
        "exists": exists(rel),
    }

task_doc = f"docs/development/tasks/{task_id}.md"
review_contract = f"docs/development/review-contracts/{task_id}-review.json"
completion_glob = f"docs/development/completion-reports/*{task_id}*.json"
sap_glob = "docs/development/supervisor-actions/**/*"

# Include role-engine findings, dispatch packet, SAPs, PM lease
findings = []
findings_file_path = Path.home() / ".claude/role-cache/findings.jsonl"
if findings_file_path.exists():
    try:
        with open(findings_file_path) as f:
            for line in f:
                line = line.strip()
                if not line: continue
                d = json.loads(line)
                if task_id in (d.get('task_id','') or ''):
                    findings.append({"severity": d.get('severity'), "check": d.get('check'), "finding": d.get('finding'), "next": d.get('next'), "cmd": d.get('cmd')})
    except: pass

dispatch = None
dp_file = docs_repo / f"docs/development/dispatch-packets/{task_id}.json"
if dp_file.exists():
    try: dispatch = json.loads(dp_file.read_text())
    except: pass

saps = []
sap_dir = docs_repo / "docs/development/supervisor-actions"
if sap_dir.exists():
    for sf in sorted(sap_dir.glob("SAP-*.json")):
        try:
            sap = json.loads(sf.read_text())
            if task_id in (sap.get('task_id','') or ''):
                saps.append({"file": sf.name, "action": sap.get('action'), "status": sap.get('status'), "severity": sap.get('severity')})
        except: pass

pm_lease = None
lease_file = Path.home() / ".claude/role-cache/pm-lease.json"
if lease_file.exists():
    try: pm_lease = json.loads(lease_file.read_text())
    except: pass

bundle = {
    "task_id": task_id,
    "knowledge_contract": "Read these docs before implementation, before review submission, and before closure. GitHub comments are evidence only; ledger and task docs remain authoritative.",
    "system_state": {
        "role_engine_findings": findings,
        "dispatch_packet": dispatch,
        "active_saps": saps,
        "pm_lease": pm_lease,
    },
    "required_first_reads": [
        maybe("docs/development/AI_PROJECT_STATUS_ONBOARDING.md", "first-read project status"),
        maybe("docs/development/CLAUDE_LOOP_SUPERVISOR_RULES.md", "current Claude loop hard rules"),
        maybe("docs/development/task-state-ledger.json", "exact TASK state and closure gate"),
        maybe(task_doc, "task-specific requirements and acceptance criteria"),
        maybe(review_contract, "structured Codex review state, if present"),
        maybe("docs/development/tasks/README.md", "task index and dependency hints"),
        maybe("docs/development/MVP_IMPLEMENTATION_PLAN.md", "MVP dependency/progress context"),
        maybe("docs/development/CHANGE_TO_DOC_MATRIX.md", "doc update routing for implementation changes"),
        maybe("docs/development/DEFINITION_OF_DONE.md", "completion evidence requirements"),
    ],
    "domain_roots": [
        maybe("docs/architecture", "system architecture and cross-service chains"),
        maybe("docs/contracts", "API/data/event/runtime contracts"),
        maybe("docs/backend", "backend implementation docs"),
        maybe("docs/admin", "admin UI/product docs"),
        maybe("docs/app", "mobile app and VPN runtime docs"),
        maybe("docs/data", "database migration and data consistency docs"),
        maybe("docs/operations", "runtime, CI/CD, support, and operational docs"),
    ],
    "evidence_roots": [
        maybe("docs/development/supervisor-actions", "SAP/block/action packet evidence"),
        maybe("docs/development/completion-reports", "historical task completion evidence"),
        maybe("docs/development/review-contracts", "Codex review contracts"),
    ],
    "recommended_searches": [
        f"rg -n \"{task_id}\" docs",
        "rg -n \"<GitHub issue number>|<route>|<table>|<env>|<config key>\" docs",
        "rg -n \"OpenAPI|Swagger|RBAC|pagination|error code|migration|seed|index|constraint\" docs/contracts docs/backend docs/data",
        f"find docs/development/completion-reports -maxdepth 1 -name '*{task_id}*.json'",
        "python3 scripts/plan-next-tasks.py --format json",
    ],
    "closure_reminders": [
        "No matching SAP packets does not mean no work.",
        "The exact task-state-ledger TASK entry must be read and updated or blocked.",
        "Review contract state must be approved/closed or explicitly blocked with owner.",
        "Runtime remote deploy/restart/smoke evidence must come through livemask-ci-cd, not ad hoc runtime-repo SSH.",
    ],
}

print(json.dumps(bundle, ensure_ascii=False, indent=2))
PY
}

# ── _generate_event_id ────────────────────────────────────────────────────────
_generate_event_id() {
  local ts
  ts=$(date -u +%Y%m%d%H%M%S)
  local rand
  rand=$(python3 -c "import random,string; print(''.join(random.choices(string.ascii_uppercase+string.digits, k=8)))" 2>/dev/null || echo "DEADBEEF")
  echo "EVT-${rand}-${ts}"
}

# ── _validate_event ───────────────────────────────────────────────────────────
_validate_event() {
  local event_str="${1:-}"
  if [[ -z "${event_str}" ]]; then
    echo "ERROR: empty event passed to validator" >&2
    return 1
  fi

  # Try python3 inline validation against schema
  local result
  result=$(python3 -c "
import json, sys
try:
    event = json.loads(sys.argv[1])
    # Basic structural checks (full schema validation would need check-jsonschema)
    required = ['event_id', 'event_type', 'ts', 'source']
    for f in required:
        if f not in event:
            print(f'MISSING_REQUIRED: {f}')
            sys.exit(1)
    if event.get('event_type') == 'comment.created':
        if 'comment' not in event:
            print('MISSING: comment object for comment.created event')
            sys.exit(1)
        c = event['comment']
        for f in ('issue_number','comment_id','author','cursor_key'):
            if f not in c:
                print(f'MISSING: comment.{f} for comment.created event')
                sys.exit(1)
    if event['event_type'] in ('ci.run.completed','ci.run.in_progress','ci.run.queued','ci.run.failure'):
        if 'ci' not in event:
            print('MISSING: ci object for ci.run.* event')
            sys.exit(1)
        c = event['ci']
        for f in ('run_id','head_sha','workflow_name','status','url'):
            if f not in c:
                print(f'MISSING: ci.{f} for ci.run.* event')
                sys.exit(1)
    if event['event_type'] == 'state.snapshot':
        if 'snapshot' not in event:
            print('MISSING: snapshot object for state.snapshot event')
            sys.exit(1)
        s = event['snapshot']
        for f in ('reason','affected_poller'):
            if f not in s:
                print(f'MISSING: snapshot.{f} for state.snapshot event')
                sys.exit(1)
    print('OK')
except json.JSONDecodeError as e:
    print(f'JSON_INVALID: {e}')
    sys.exit(1)
except Exception as e:
    print(f'ERROR: {e}')
    sys.exit(1)
" "${event_str}" 2>/dev/null)
  if [[ "${result}" != "OK" ]]; then
    echo "EVENT_VALIDATION_FAILED: ${result}" >&2
    return 1
  fi
  return 0
}

# ── adapter_write_event ───────────────────────────────────────────────────────
# Append a validated JSONL line to the event cache.
# Usage: adapter_write_event '{"event_id":"...", ...}'
# Returns: 0 on success, 1 on validation failure
adapter_write_event() {
  local event_json="${1:-}"
  if [[ -z "${event_json}" ]]; then
    echo "ERROR: adapter_write_event called with empty argument" >&2
    return 1
  fi

  _validate_event "${event_json}" || return 1

  echo "${event_json}" >> "${EVENT_CACHE_FILE}"
  local event_id
  event_id=$(echo "${event_json}" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('event_id','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")
  echo "  [event] wrote ${event_id}" >&2
  return 0
}

# ── adapter_load_cursors ─────────────────────────────────────────────────────
# Read cursor state from disk into CURSOR_DATA.
# Sets CURSOR_CORRUPT=1 if file is malformed, CURSOR_FILE_MISSING=1 if absent.
adapter_load_cursors() {
  local cursor_file="${EVENT_CACHE_DIR}/adapter-cursors.json"

  if [[ ! -f "${cursor_file}" ]]; then
    CURSOR_FILE_MISSING=1
    CURSOR_CORRUPT=0
    CURSOR_DATA='{"schema_version":1,"updated_at":"","pollers":{}}'
    echo "  [cursor] no cursor file yet — starting fresh (first run baseline)" >&2
    return 0
  fi

  local raw
  if ! raw=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
# Validate structure
assert 'pollers' in d, 'missing pollers'
assert isinstance(d['pollers'], dict), 'pollers not object'
print(json.dumps(d))
" "${cursor_file}" 2>/dev/null); then
    CURSOR_CORRUPT=1
    CURSOR_FILE_MISSING=0
    CURSOR_DATA='{"schema_version":1,"updated_at":"","pollers":{}}'
    echo "  [cursor] CORRUPT cursor file — snapshot mode should be entered" >&2
    return 0
  fi

  CURSOR_DATA="${raw}"
  CURSOR_CORRUPT=0
  CURSOR_FILE_MISSING=0
  echo "  [cursor] cursors loaded successfully" >&2
  return 0
}

# ── adapter_save_cursors ─────────────────────────────────────────────────────
# Atomically write CURSOR_DATA to disk.
adapter_save_cursors() {
  local cursor_file="${EVENT_CACHE_DIR}/adapter-cursors.json"
  local tmp_file="${cursor_file}.tmp.$$"

  # Update timestamp
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  CURSOR_DATA=$(echo "${CURSOR_DATA}" | python3 -c "
import json,sys
d = json.loads(sys.stdin.read())
d['updated_at'] = '${now}'
print(json.dumps(d, indent=2))
" 2>/dev/null || echo "${CURSOR_DATA}")

  echo "${CURSOR_DATA}" > "${tmp_file}"
  mv "${tmp_file}" "${cursor_file}"
  echo "  [cursor] saved" >&2
  return 0
}

# ── adapter_is_duplicate_comment ──────────────────────────────────────────────
# Check if a comment has already been seen.
# Usage: adapter_is_duplicate_comment "MyAiDevs/livemask-ci-cd" "14" "4582965630"
# Returns: 0 (true = duplicate), 1 (false = new)
adapter_is_duplicate_comment() {
  local repo="${1:-}"
  local issue="${2:-}"
  local comment_id="${3:-}"
  local poller_name="${4:-poll-fixed-control-issues}"

  if [[ -z "${repo}" || -z "${issue}" || -z "${comment_id}" ]]; then
    echo "ERROR: adapter_is_duplicate_comment requires repo, issue, comment_id" >&2
    return 1
  fi

  local key="${repo}#${issue}"
  local last_id
  last_id=$(echo "${CURSOR_DATA}" | python3 -c "
import json,sys
d = json.loads(sys.stdin.read())
cursors = d.get('pollers',{}).get('${poller_name}',{}).get('cursors',{})
entry = cursors.get('${key}',{})
print(entry.get('last_comment_id', -1))
" 2>/dev/null || echo "-1")

  if [[ -z "${last_id}" || "${last_id}" == "-1" ]]; then
    # No cursor yet — first run for this issue, establish baseline
    return 0  # treat as duplicate to suppress events on first run
  fi

  if [[ "${comment_id}" -le "${last_id}" ]]; then
    return 0  # duplicate
  fi
  return 1  # new
}

# ── adapter_is_duplicate_run ──────────────────────────────────────────────────
# Check if a CI run has already been seen by (run_id, head_sha) pair.
# Returns: 0 (true = duplicate), 1 (false = new)
adapter_is_duplicate_run() {
  local repo="${1:-}"
  local run_id="${2:-}"
  local head_sha="${3:-}"
  local poller_name="${4:-poll-ci-runs}"

  if [[ -z "${repo}" || -z "${run_id}" || -z "${head_sha}" ]]; then
    echo "ERROR: adapter_is_duplicate_run requires repo, run_id, head_sha" >&2
    return 1
  fi

  local entry
  entry=$(echo "${CURSOR_DATA}" | python3 -c "
import json,sys
d = json.loads(sys.stdin.read())
cursors = d.get('pollers',{}).get('${poller_name}',{}).get('cursors',{})
entry = cursors.get('${repo}',{})
print(json.dumps({
    'last_run_id': entry.get('last_run_id', -1),
    'last_head_sha': entry.get('last_head_sha', ''),
    'exists': 'last_run_id' in entry
}))
" 2>/dev/null || echo '{"last_run_id":-1,"last_head_sha":"","exists":false}')

  local last_run_id last_head_sha exists
  last_run_id=$(echo "${entry}" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['last_run_id'])" 2>/dev/null || echo "-1")
  last_head_sha=$(echo "${entry}" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['last_head_sha'])" 2>/dev/null || echo "")
  exists=$(echo "${entry}" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['exists'])" 2>/dev/null || echo "False")

  if [[ "${exists}" != "True" || "${last_run_id}" == "-1" ]]; then
    # No cursor yet — first run, establish baseline
    return 0  # treat as duplicate
  fi

  # Same run_id AND same head_sha = duplicate
  # Same run_id but different head_sha = re-run, new event
  if [[ "${run_id}" == "${last_run_id}" && "${head_sha}" == "${last_head_sha}" ]]; then
    return 0  # duplicate
  fi

  # If run_id is older than cursor's last_run_id, but head_sha differs -
  # this shouldn't normally happen. Treat as non-duplicate.
  return 1  # new
}

# ── adapter_enter_snapshot ────────────────────────────────────────────────────
# Write a state.snapshot event and mark cursor as needing rebuild.
adapter_enter_snapshot() {
  local poller_name="${1:-unknown}"
  local reason="${2:-cursor corruption detected}"

  local event_id
  event_id=$(_generate_event_id)
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local event_json
  event_json=$(python3 -c "
import json
event = {
    'event_id': '${event_id}',
    'event_type': 'state.snapshot',
    'ts': '${ts}',
    'source': '${poller_name}',
    'priority': 'low',
    'snapshot': {
        'reason': '${reason}',
        'affected_poller': '${poller_name}',
        'cursor_dump': json.loads('''${CURSOR_DATA}''')
    }
}
print(json.dumps(event))
" 2>/dev/null)

  if [[ -n "${event_json}" ]]; then
    adapter_write_event "${event_json}" || true
  fi

  # Mark this poller as in error state in cursors
  CURSOR_DATA=$(echo "${CURSOR_DATA}" | python3 -c "
import json,sys
d = json.loads(sys.stdin.read())
poller = d.setdefault('pollers',{}).setdefault('${poller_name}',{'last_run_ts':'','cursors':{}})
poller['error_state'] = 'snapshot_mode: ${reason}'
print(json.dumps(d))
" 2>/dev/null || echo "${CURSOR_DATA}")

  echo "  [snapshot] entered snapshot mode for ${poller_name}: ${reason}" >&2
  return 0
}

# ── adapter_update_comment_cursor ─────────────────────────────────────────────
# Update cursor for an issue comment poller.
adapter_update_comment_cursor() {
  local repo="${1:-}"
  local issue="${2:-}"
  local comment_id="${3:-}"
  local poller_name="${4:-poll-fixed-control-issues}"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local key="${repo}#${issue}"
  CURSOR_DATA=$(echo "${CURSOR_DATA}" | python3 -c "
import json,sys
d = json.loads(sys.stdin.read())
poller = d.setdefault('pollers',{}).setdefault('${poller_name}',{'last_run_ts':'${now}','cursors':{}})
poller['last_run_ts'] = '${now}'
entry = poller['cursors'].setdefault('${key}',{'last_comment_id':0,'total_comments_seen':0})
entry['last_comment_id'] = max(entry.get('last_comment_id',0), ${comment_id})
entry['total_comments_seen'] = entry.get('total_comments_seen',0) + 1
entry['last_checked_at'] = '${now}'
# Clear error_state on successful poll
poller.pop('error_state', None)
print(json.dumps(d))
" 2>/dev/null || echo "${CURSOR_DATA}")
}

# ── adapter_update_ci_cursor ──────────────────────────────────────────────────
# Update cursor for a CI run poller.
adapter_update_ci_cursor() {
  local repo="${1:-}"
  local run_id="${2:-}"
  local head_sha="${3:-}"
  local status="${4:-}"
  local conclusion="${5:-null}"
  local poller_name="${6:-poll-ci-runs}"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  CURSOR_DATA=$(echo "${CURSOR_DATA}" | python3 -c "
import json,sys
d = json.loads(sys.stdin.read())
poller = d.setdefault('pollers',{}).setdefault('${poller_name}',{'last_run_ts':'${now}','cursors':{}})
poller['last_run_ts'] = '${now}'
entry = poller['cursors'].setdefault('${repo}',{'last_run_id':0,'last_head_sha':'','total_runs_seen':0})
current_id = entry.get('last_run_id',0)
if ${run_id} >= current_id:
    entry['last_run_id'] = ${run_id}
    entry['last_head_sha'] = '${head_sha}'
    entry['last_status'] = '${status}'
    entry['last_conclusion'] = ${conclusion}
    entry['total_runs_seen'] = entry.get('total_runs_seen',0) + 1
    entry['last_checked_at'] = '${now}'
poller.pop('error_state', None)
print(json.dumps(d))
" 2>/dev/null || echo "${CURSOR_DATA}")
}

# ── adapter_memory_add ─────────────────────────────────────────────────────────
# Append a lightweight local memory event. This is an accelerator only; docs,
# ledger, GitHub Issues/comments, SAPs, dispatch packets, and CI remain authority.
adapter_memory_add() {
  local source="${1:-}"
  local task_id="${2:-}"
  local repo="${3:-}"
  local summary="${4:-}"
  local context_path="${5:-}"

  if [[ -z "${source}" || -z "${summary}" ]]; then
    echo "ERROR: memory-add requires source task_id repo summary [context_path]" >&2
    return 2
  fi

  mkdir -p "${ROLE_CACHE_DIR}"
  python3 - "${PROJECT_MEMORY_FILE}" "${source}" "${task_id}" "${repo}" "${summary}" "${context_path}" <<'PY'
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

path = Path(sys.argv[1])
source, task_id, repo, summary, context_path = sys.argv[2:7]
tokens = []
for token in re.findall(r"[A-Za-z0-9_.:/#-]{3,}", " ".join([source, task_id, repo, summary, context_path])):
    low = token.lower()
    if low not in tokens:
        tokens.append(low)

entry = {
    "schema_version": 1,
    "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "source": source,
    "task_id": task_id,
    "repo": repo,
    "summary": summary[:1200],
    "context_path": context_path,
    "tokens": tokens[:40],
    "authority_note": "Local memory is an accelerator only; verify against docs, ledger, GitHub, SAPs, dispatch packets, and CI before acting.",
}
with path.open("a", encoding="utf-8") as fh:
    fh.write(json.dumps(entry, ensure_ascii=False) + "\n")
print(json.dumps({"memory_file": str(path), "written": True, "task_id": task_id, "repo": repo}, ensure_ascii=False))
PY
}

# ── adapter_memory_search ──────────────────────────────────────────────────────
# Search local loop memory by TASK-ID, repo, issue number, or keyword.
adapter_memory_search() {
  local query="${1:-}"
  local limit="${2:-10}"

  mkdir -p "${ROLE_CACHE_DIR}"
  if [[ ! -f "${PROJECT_MEMORY_FILE}" ]]; then
    echo '{"matches":[],"total":0,"note":"no local project memory yet"}'
    return 0
  fi

  python3 - "${PROJECT_MEMORY_FILE}" "${query}" "${limit}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
query = sys.argv[2].lower()
limit = int(sys.argv[3])
matches = []

for line in path.read_text(encoding="utf-8").splitlines():
    if not line.strip():
        continue
    try:
        entry = json.loads(line)
    except Exception:
        continue
    haystack = " ".join([
        entry.get("source", ""),
        entry.get("task_id", ""),
        entry.get("repo", ""),
        entry.get("summary", ""),
        entry.get("context_path", ""),
        " ".join(entry.get("tokens", [])),
    ]).lower()
    if not query or query in haystack:
        matches.append(entry)

matches = matches[-limit:][::-1]
print(json.dumps({
    "memory_file": str(path),
    "query": query,
    "matches": matches,
    "total": len(matches),
    "authority_note": "Memory results are hints only; verify authoritative project state before editing or dispatching.",
}, ensure_ascii=False, indent=2))
PY
}

adapter_usage() {
  cat <<'USAGE'
Usage:
  source scripts/event-adapters/lib/adapter-lib.sh
  scripts/event-adapters/lib/adapter-lib.sh <command> [args]

Commands:
  knowledge-sources
      Print canonical LiveMask docs/knowledge sources as TSV:
      path, purpose, exists|missing.

  repo-doc-hints [repo]
      Print preferred docs for one repo, or all repo mappings.

  knowledge-search <query> [limit]
      Search LiveMask docs with rg. Use for TASK IDs, routes, tables,
      GitHub issue numbers, env/config keys, API names, and error text.

  knowledge-inventory [max_files]
      Print a JSON inventory of current docs, grouped by category with first
      headings. Use when Claude needs to discover relevant project knowledge.

  task-ledger-entry <TASK-ID>
      Print the exact task-state-ledger entry for a TASK-* as JSON.

  findings-search [TASK-ID|keyword] [limit]
      Search role-engine findings.jsonl. With TASK-ID, filters to that task.
      With keyword, filters finding/next text. No arg shows all recent.

  pm-status
      Show PM mutual exclusion lease status — which agent is running PM,
      what phase, how long ago, whether the lease is active or stale.

  dispatch-status [TASK-ID]
      Show dispatch packet status. No arg lists all packets. With TASK-ID
      shows that specific packet.

  memory-add <source> <TASK-ID> <repo> <summary> [context_path]
      Append a local project memory hint. This is never authoritative.

  memory-search [TASK-ID|repo|keyword] [limit]
      Search local project memory hints from prior startup/role-engine cycles.

  task-context <TASK-ID>
      Print a JSON context bundle: required first reads, domain roots,
      evidence roots, recommended searches, closure reminders, system
      state (findings, dispatch packet, SAPs, PM lease).
USAGE
}

adapter_main() {
  local command="${1:-}"
  shift || true

  case "${command}" in
    knowledge-sources)
      adapter_print_knowledge_sources "$@"
      ;;
    repo-doc-hints)
      adapter_print_repo_doc_hints "$@"
      ;;
    knowledge-search)
      adapter_search_knowledge "$@"
      ;;
    knowledge-inventory)
      adapter_knowledge_inventory "$@"
      ;;
    task-ledger-entry)
      adapter_task_ledger_entry "$@"
      ;;
    task-context)
      adapter_task_context_bundle "$@"
      ;;
    findings-search)
      adapter_findings_search "$@"
      ;;
    pm-status)
      adapter_pm_status
      ;;
    dispatch-status)
      adapter_dispatch_status "$@"
      ;;
    memory-add)
      adapter_memory_add "$@"
      ;;
    memory-search)
      adapter_memory_search "$@"
      ;;
    ""|-h|--help|help)
      adapter_usage
      ;;
    *)
      echo "ERROR: unknown adapter-lib command: ${command}" >&2
      adapter_usage >&2
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  adapter_main "$@"
  exit $?
fi

echo "  [adapter-lib] loaded (cache_dir=${EVENT_CACHE_DIR})" >&2
