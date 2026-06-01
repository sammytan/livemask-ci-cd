#!/usr/bin/env bash
# ledger-intelligence.sh — Smart task ledger queries and analytics.
# Source this, then call ledger_* functions for structured JSON output.
# Designed for model consumption: every function outputs JSON.
set -euo pipefail

LIVEMASK_ROOT="${LIVEMASK_ROOT:-/Users/sammytan/Developer/LiveMask}"
DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"
LEDGER_FILE="${DOCS_DIR}/docs/development/task-state-ledger.json"

# ── Dependency Chain Tracer ──────────────────────────────────────────────
# Trace what's blocking a task, all the way to root
ledger_trace_blockers() {
  local tid="${1:-}"
  python3 - "${tid}" "${LEDGER_FILE}" <<'PY'
import json, sys
tid = sys.argv[1]
ledger = json.load(open(sys.argv[2]))

# Build task lookup
tasks = {}
for m in ledger.get("modules", []):
    for t in m.get("tasks", []):
        tid_key = t.get("task_id", "")
        if tid_key:
            tasks[tid_key] = t

def trace(task_id, depth=0, visited=None):
    if visited is None: visited = set()
    if task_id in visited or depth > 10:
        return {"task_id": task_id, "chain": "circular or too deep"}
    visited.add(task_id)
    task = tasks.get(task_id, {})
    blockers = task.get("blocked_by", [])
    chain = {
        "task_id": task_id,
        "status": task.get("status", "?"),
        "repo": task.get("repo", "?"),
        "depth": depth,
        "blocked_by": [],
    }
    for b in blockers:
        chain["blocked_by"].append(trace(b, depth + 1, visited.copy()))
    return chain

if tid not in tasks:
    print(json.dumps({"error": f"task {tid} not in ledger"}, indent=2))
else:
    print(json.dumps(trace(tid), indent=2))
PY
}

# ── Find Stuck Tasks ─────────────────────────────────────────────────────
# Tasks that are in_progress/implementing but have no git activity in N days
ledger_find_stuck() {
  local days="${1:-3}"
  python3 - "${LEDGER_FILE}" "${LIVEMASK_ROOT}" "${days}" <<'PY'
import json, subprocess, sys, pathlib
ledger = json.load(open(sys.argv[1]))
root = pathlib.Path(sys.argv[2])
days = int(sys.argv[3])

stuck = []
for m in ledger.get("modules", []):
    for t in m.get("tasks", []):
        status = t.get("status", "")
        if status not in ("in_progress", "implementing", "implemented", "verified"):
            continue
        tid = t.get("task_id", "")
        repo = t.get("repo", "")
        if not repo: continue
        repo_dir = root / repo
        if not repo_dir.exists(): continue
        # Check git activity
        r = subprocess.run(
            ["git", "-C", str(repo_dir), "log", "--oneline", f"--since={days} days ago", "--grep", tid, "-1"],
            capture_output=True, text=True, timeout=10)
        if not r.stdout.strip():
            # Check if there's ANY recent commit in the repo
            r2 = subprocess.run(
                ["git", "-C", str(repo_dir), "log", "--oneline", "-1", f"--since={days} days ago"],
                capture_output=True, text=True, timeout=10)
            stuck.append({
                "task_id": tid,
                "repo": repo,
                "status": status,
                "no_task_commits_days": days,
                "repo_has_recent_commits": bool(r2.stdout.strip()),
                "issue": t.get("issue", ""),
                "validation": t.get("validation", "")[:100],
            })
print(json.dumps({"stuck_count": len(stuck), "stuck_tasks": stuck}, indent=2))
PY
}

# ── Closure Readiness Score ───────────────────────────────────────────────
# Score 0-100: how ready is this task to be closed?
ledger_closure_score() {
  local tid="${1:-}"
  python3 - "${tid}" "${LEDGER_FILE}" "${LIVEMASK_ROOT}" <<'PY'
import json, subprocess, sys, pathlib
tid = sys.argv[1]
ledger = json.load(open(sys.argv[2]))
root = pathlib.Path(sys.argv[3])
docs = root / "livemask-docs"

# Find task
task = None
for m in ledger.get("modules", []):
    for t in m.get("tasks", []):
        if t.get("task_id") == tid:
            task = t
            break
if not task:
    print(json.dumps({"error": f"task {tid} not found"}, indent=2))
    sys.exit(0)

score = 0
max_score = 7
checks = {}

# 1. Task doc exists
doc = docs / f"docs/development/tasks/{tid}.md"
checks["task_doc"] = doc.exists()
if doc.exists():
    score += 1

# 2. Ledger has validation evidence
val = task.get("validation", "")
checks["validation"] = len(val) >= 20
if checks["validation"]:
    score += 1

# 3. GitHub issue linked
issue = task.get("issue", "")
checks["issue_linked"] = bool(issue)
if checks["issue_linked"]:
    score += 1

# 4. Review contract exists and approved
review = docs / f"docs/development/review-contracts/{tid}-review.json"
if review.exists():
    d = json.loads(review.read_text())
    state = d.get("state", "")
    approved = state in ("closed", "completed") or any(
        r.get("codex", {}).get("verdict") == "approved"
        for r in d.get("rounds", []))
    checks["review_contract"] = approved
    if approved: score += 1
else:
    checks["review_contract"] = False

# 5. Dev merge commit
merge = task.get("dev_merge_commit", "")
checks["dev_merge"] = len(merge) >= 7
if checks["dev_merge"]:
    score += 1

# 6. Git evidence in target repo
repo = task.get("repo", "")
if repo:
    r = subprocess.run(
        ["git", "-C", str(root / repo), "log", "--oneline", "--grep", tid, "-1"],
        capture_output=True, text=True, timeout=10)
    checks["git_evidence"] = bool(r.stdout.strip())
    if checks["git_evidence"]:
        score += 1
else:
    checks["git_evidence"] = False

# 7. Status is completed in ledger
checks["ledger_completed"] = task.get("status") in ("completed", "completed_with_skip")
if checks["ledger_completed"]:
    score += 1

pct = round(score * 100 / max_score)
verdict = "READY_TO_CLOSE" if pct == 100 else \
          "NEARLY_DONE" if pct >= 71 else \
          "IN_PROGRESS" if pct >= 43 else \
          "NOT_STARTED"

print(json.dumps({
    "task_id": tid,
    "closure_score": pct,
    "score_detail": f"{score}/{max_score}",
    "verdict": verdict,
    "checks": checks,
    "missing": [k for k, v in checks.items() if not v],
}, indent=2))
PY
}

# ── Dispatch Recommendations ──────────────────────────────────────────────
# Which tasks should be dispatched next, ranked by priority and readiness
ledger_dispatch_recommendations() {
  local limit="${1:-10}"
  python3 - "${LEDGER_FILE}" "${LIVEMASK_ROOT}" "${limit}" <<'PY'
import json, pathlib, sys
ledger = json.load(open(sys.argv[1]))
root = pathlib.Path(sys.argv[2])
limit = int(sys.argv[3])
docs = root / "livemask-docs"
dispatch_dir = docs / "docs/development/dispatch-packets"

priority_order = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}
status_order = {"ready": 0, "partial": 1, "blocked": 2, "evidence_missing": 3,
                "in_progress": 4, "draft": 5}

candidates = []
for m in ledger.get("modules", []):
    for t in m.get("tasks", []):
        tid = t.get("task_id", "")
        if not tid: continue
        status = t.get("status", "")
        if status not in ("ready", "partial", "evidence_missing", "draft"):
            continue
        # Check if dispatch packet exists
        has_packet = (dispatch_dir / f"{tid}.json").exists()
        has_issue = bool(t.get("issue", ""))
        has_doc = (docs / f"docs/development/tasks/{tid}.md").exists()
        prio = priority_order.get(t.get("priority", "P2"), 2)
        stat = status_order.get(status, 9)
        # Score: lower is better
        ready_score = stat + prio * 0.5 + (0 if has_packet else 2) + (0 if has_issue else 1) + (0 if has_doc else 3)
        candidates.append({
            "task_id": tid,
            "repo": t.get("repo", ""),
            "status": status,
            "priority": t.get("priority", "P2"),
            "has_dispatch_packet": has_packet,
            "has_issue": has_issue,
            "has_task_doc": has_doc,
            "ready_score": ready_score,
            "issue": t.get("issue", "")[:80],
        })

candidates.sort(key=lambda c: c["ready_score"])
top = candidates[:limit]

# Generate recommendations
for c in top:
    actions = []
    if not c["has_task_doc"]: actions.append("CREATE_TASK_DOC")
    if not c["has_issue"]: actions.append("LINK_GITHUB_ISSUE")
    if not c["has_dispatch_packet"]: actions.append("CREATE_DISPATCH_PACKET")
    if not actions: actions.append("READY_TO_ACCEPT")
    c["recommended_actions"] = actions

print(json.dumps({
    "total_candidates": len(candidates),
    "recommendations": top,
}, indent=2))
PY
}

# ── Status Health Dashboard ───────────────────────────────────────────────
ledger_health_dashboard() {
  python3 - "${LEDGER_FILE}" <<'PY'
import json, sys
from collections import Counter, defaultdict
ledger = json.load(open(sys.argv[1]))

statuses = Counter()
no_issue = []
no_doc = []
no_review_completed = []
stale_in_progress = []
modules_health = []

for m in ledger.get("modules", []):
    module_name = m.get("module_id", "?")
    module_tasks = m.get("tasks", [])
    module_statuses = Counter(t.get("status", "?") for t in module_tasks)
    open_count = sum(v for k, v in module_statuses.items()
                     if k not in ("completed", "completed_with_skip", "cancelled", "deferred"))
    total = len(module_tasks)
    modules_health.append({
        "module": module_name,
        "total": total,
        "open": open_count,
        "pct_complete": round((total - open_count) * 100 / max(total, 1)),
        "statuses": dict(module_statuses.most_common(5)),
    })

    for t in module_tasks:
        tid = t.get("task_id", "")
        status = t.get("status", "")
        statuses[status] += 1
        if not t.get("issue") and status in ("completed", "completed_with_skip"):
            no_issue.append(tid)
        if not t.get("task_doc"):
            no_doc.append(tid)
        if status in ("completed", "completed_with_skip"):
            if not t.get("validation") or len(t.get("validation", "")) < 20:
                no_review_completed.append(tid)
        if status == "in_progress":
            stale_in_progress.append({"task_id": tid, "repo": t.get("repo", ""),
                                       "notes": t.get("notes", "")[:100]})

modules_health.sort(key=lambda m: m["pct_complete"])

print(json.dumps({
    "total_tasks": sum(statuses.values()),
    "status_distribution": dict(statuses.most_common()),
    "pct_completed": round(statuses.get("completed", 0) * 100 / max(sum(statuses.values()), 1)),
    "completed_without_issue": len(no_issue),
    "completed_without_issue_sample": no_issue[:10],
    "without_task_doc": len(no_doc),
    "completed_weak_validation": len(no_review_completed),
    "stale_in_progress_count": len(stale_in_progress),
    "stale_in_progress": stale_in_progress[:5],
    "modules": modules_health,
}, indent=2))
PY
}

# ── What-If: Impact of unblocking a task ──────────────────────────────────
ledger_unblock_impact() {
  local tid="${1:-}"
  python3 - "${tid}" "${LEDGER_FILE}" <<'PY'
import json, sys
tid = sys.argv[1]
ledger = json.load(open(sys.argv[2]))

# Find all tasks blocked by this task
unlocks = []
for m in ledger.get("modules", []):
    for t in m.get("tasks", []):
        if tid in t.get("blocked_by", []):
            unlocks.append({
                "task_id": t.get("task_id", ""),
                "status": t.get("status", ""),
                "repo": t.get("repo", ""),
                "priority": t.get("priority", ""),
                "blocked_by": t.get("blocked_by", []),
            })

# Count transitive unlocks
transitive = []
seen = set()
queue = [u["task_id"] for u in unlocks]
while queue:
    current = queue.pop(0)
    if current in seen: continue
    seen.add(current)
    for m in ledger.get("modules", []):
        for t in m.get("tasks", []):
            if current in t.get("blocked_by", []):
                next_tid = t.get("task_id", "")
                if next_tid not in seen:
                    transitive.append(next_tid)
                    queue.append(next_tid)

print(json.dumps({
    "unblocking": tid,
    "directly_unblocks": len(unlocks),
    "directly_unblocked_tasks": unlocks[:10],
    "transitively_unblocks": len(transitive),
    "total_impact": len(unlocks) + len(transitive),
}, indent=2))
PY
}

# ── Full Intelligence Report ──────────────────────────────────────────────
ledger_full_report() {
  echo "=== LEDGER INTELLIGENCE REPORT ==="
  echo ""
  echo "--- Health Dashboard ---"
  ledger_health_dashboard
  echo ""
  echo "--- Dispatch Recommendations ---"
  ledger_dispatch_recommendations 8
  echo ""
  echo "--- Stuck Tasks ---"
  ledger_find_stuck 5
  echo ""
  echo "--- END REPORT ---"
}
