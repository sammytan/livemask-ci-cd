#!/usr/bin/env bash
# monitor-learn.sh — Self-learning monitor for Claude executor activity.
#
# Watches executor behavior in real-time, detects patterns, learns from
# successes and failures, and auto-updates both the role engine and executor
# guidance. This is the meta-cognitive layer of the Claude loop.
#
# Architecture:
#   Watch → Record → Analyze → Learn → Update
#     ↑___________________________________↓
#
# Sources monitored:
#   - git commits (what, when, how often, commit message quality)
#   - task state transitions (accepted → implementing → submitted → approved → merged)
#   - review outcomes (approved vs changes_requested, common rejection reasons)
#   - CI results (pass/fail patterns, flaky tests)
#   - executor velocity (time per task, time per phase)
#   - role engine findings (recurring issues, auto-fixed items)
#
# Output:
#   - Pattern detection → feedback memories
#   - Learned rules → auto-update CODEX_LOOP_RULES suggestions
#   - Executor guidance → real-time tips based on past learnings
#   - Self-improvement → adjust thresholds, refine checks
set -euo pipefail

LIVEMASK_ROOT="${LIVEMASK_ROOT:-/Users/sammytan/Developer/LiveMask}"
DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"
ROLE_CACHE_DIR="${HOME}/.claude/role-cache"
MONITOR_DIR="${ROLE_CACHE_DIR}/monitor"
LEARNED_DIR="${ROLE_CACHE_DIR}/learned"
OBSERVATIONS_FILE="${MONITOR_DIR}/observations.jsonl"
PATTERNS_FILE="${LEARNED_DIR}/patterns.json"
GUIDANCE_FILE="${LEARNED_DIR}/executor-guidance.json"
MEMORY_DIR="${HOME}/.claude/projects/-Users-sammytan-Developer-LiveMask/memory"

# ── Initialize ──────────────────────────────────────────────────────────
monitor_init() {
  mkdir -p "${MONITOR_DIR}" "${LEARNED_DIR}"
  touch "${OBSERVATIONS_FILE}" 2>/dev/null || true

  # Init patterns if missing
  if [[ ! -f "${PATTERNS_FILE}" ]]; then
    cat > "${PATTERNS_FILE}" << 'JSON'
{
  "schema_version": 1,
  "updated_at": "",
  "success_patterns": [],
  "failure_patterns": [],
  "learned_rules": [],
  "velocity_stats": {},
  "common_mistakes": [],
  "effective_patterns": []
}
JSON
  fi

  # Init guidance if missing
  if [[ ! -f "${GUIDANCE_FILE}" ]]; then
    cat > "${GUIDANCE_FILE}" << 'JSON'
{
  "schema_version": 1,
  "updated_at": "",
  "active_tips": [],
  "phase_specific_guidance": {},
  "repo_specific_guidance": {}
}
JSON
  fi
}

# ── Watch: Observe executor activity ─────────────────────────────────────
monitor_watch() {
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  monitor_init

  python3 - "${now}" "${LIVEMASK_ROOT}" "${DOCS_DIR}" "${OBSERVATIONS_FILE}" "${AGENT_STATE:-/Users/sammytan/Developer/LiveMask/.claude/agent-state.json}" <<'PY'
import json, pathlib, subprocess, sys, time
from datetime import datetime, timezone

now = sys.argv[1]
root = pathlib.Path(sys.argv[2])
docs = pathlib.Path(sys.argv[3])
obs_file = pathlib.Path(sys.argv[4])
agent_file = pathlib.Path(sys.argv[5])

observations = []

# 1. Agent state observation
if agent_file.exists():
    agent = json.loads(agent_file.read_text())
    observations.append({
        "source": "agent_state",
        "type": "phase",
        "phase": agent.get("phase", "?"),
        "task_id": agent.get("current_task", {}).get("task_id", ""),
        "task_phase": agent.get("current_task", {}).get("task_phase", ""),
        "observed_at": now,
    })

# 2. Git activity observation (last hour)
repos = ["livemask-backend", "livemask-admin", "livemask-app", "livemask-ci-cd",
         "livemask-nodeagent", "livemask-job-service", "livemask-website", "livemask-docs"]
for repo in repos:
    repo_dir = root / repo
    if not repo_dir.exists():
        continue
    r = subprocess.run(
        ["git", "-C", str(repo_dir), "log", "--oneline", "--since=1 hour ago", "--format=%H|%s|%an|%aI"],
        capture_output=True, text=True, timeout=10)
    for line in r.stdout.strip().split('\n'):
        if not line: continue
        parts = line.split('|', 3)
        if len(parts) >= 2:
            observations.append({
                "source": "git",
                "type": "commit",
                "repo": repo,
                "hash": parts[0][:8] if len(parts) > 0 else "",
                "message": parts[1] if len(parts) > 1 else "",
                "observed_at": now,
            })

# 3. CI observation (latest runs)
for repo in ["livemask-docs", "livemask-ci-cd", "livemask-backend", "livemask-admin"]:
    try:
        r = subprocess.run(
            ["gh", "run", "list", "--repo", f"MyAiDevs/{repo}", "--limit", "3", "--json", "conclusion,status,createdAt,displayTitle"],
            capture_output=True, text=True, timeout=10)
        runs = json.loads(r.stdout) if r.stdout.strip() else []
        for run in runs:
            observations.append({
                "source": "ci",
                "type": "ci_run",
                "repo": repo,
                "conclusion": run.get("conclusion", ""),
                "status": run.get("status", ""),
                "title": run.get("displayTitle", "")[:100],
                "observed_at": now,
            })
    except: pass

# 4. Task state transitions
ledger = json.loads((docs / "docs/development/task-state-ledger.json").read_text())
for m in ledger.get("modules", []):
    for t in m.get("tasks", []):
        status = t.get("status", "")
        if status in ("in_progress", "implementing", "implemented", "verified", "under_review"):
            observations.append({
                "source": "ledger",
                "type": "active_task",
                "task_id": t.get("task_id", ""),
                "repo": t.get("repo", ""),
                "status": status,
                "has_review_contract": (docs / f"docs/development/review-contracts/{t.get('task_id','')}-review.json").exists(),
                "observed_at": now,
            })

# Append observations
with open(obs_file, 'a', encoding='utf-8') as f:
    for obs in observations:
        f.write(json.dumps(obs, ensure_ascii=False) + '\n')

print(json.dumps({
    "observations_recorded": len(observations),
    "by_source": {
        "agent_state": sum(1 for o in observations if o["source"] == "agent_state"),
        "git": sum(1 for o in observations if o["source"] == "git"),
        "ci": sum(1 for o in observations if o["source"] == "ci"),
        "ledger": sum(1 for o in observations if o["source"] == "ledger"),
    },
    "observation_file": str(obs_file),
}, indent=2))
PY
}

# ── Analyze: Detect patterns from observations ──────────────────────────
monitor_analyze() {
  monitor_init

  python3 - "${OBSERVATIONS_FILE}" "${PATTERNS_FILE}" "${DOCS_DIR}" "${LIVEMASK_ROOT}" "${MEMORY_DIR}" <<'PY'
import json, pathlib, sys
from collections import Counter, defaultdict
from datetime import datetime, timezone

obs_file = pathlib.Path(sys.argv[1])
patterns_file = pathlib.Path(sys.argv[2])
docs = pathlib.Path(sys.argv[3])
root = pathlib.Path(sys.argv[4])
memory_dir = pathlib.Path(sys.argv[5])

if not obs_file.exists():
    print(json.dumps({"analyzed": 0, "message": "no observations yet"}))
    sys.exit(0)

observations = []
for line in obs_file.read_text().splitlines():
    try: observations.append(json.loads(line))
    except: pass

if len(observations) < 5:
    print(json.dumps({"analyzed": len(observations), "message": "need more data for pattern detection"}))
    sys.exit(0)

now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
patterns = json.loads(patterns_file.read_text()) if patterns_file.exists() else {"success_patterns": [], "failure_patterns": [], "learned_rules": [], "velocity_stats": {}, "common_mistakes": [], "effective_patterns": []}

# Detect patterns
new_learnings = []

# Pattern 1: CI failure frequency by repo
ci_failures = Counter()
ci_total = Counter()
for obs in observations:
    if obs["source"] == "ci":
        repo = obs["repo"]
        ci_total[repo] += 1
        if obs.get("conclusion") == "failure":
            ci_failures[repo] += 1

for repo in ci_total:
    rate = ci_failures.get(repo, 0) / max(ci_total[repo], 1)
    if rate > 0.3:
        new_learnings.append({
            "type": "ci_risk",
            "repo": repo,
            "failure_rate": round(rate, 2),
            "learning": f"{repo} CI fails {rate*100:.0f}% of the time — executor should verify locally before pushing",
            "guidance": f"Run 'verify_repo {repo}' before committing to {repo}",
        })

# Pattern 2: Most active repos (where work happens)
repo_activity = Counter(o["repo"] for o in observations if o.get("repo"))
active_repos = repo_activity.most_common(3)
stale_repos = [r for r in ["livemask-backend","livemask-admin","livemask-app","livemask-nodeagent","livemask-job-service","livemask-website"] if r not in repo_activity]

if stale_repos:
    new_learnings.append({
        "type": "stale_repos",
        "repos": stale_repos,
        "learning": f"No recent activity in {', '.join(stale_repos)} — may need task creation",
        "guidance": "Create runtime tasks for these repos to keep pipeline balanced",
    })

# Pattern 3: Task status progression speed
ledger = json.loads((docs / "docs/development/task-state-ledger.json").read_text())
status_counts = Counter(t.get("status") for m in ledger.get("modules", []) for t in m.get("tasks", []))
total = sum(status_counts.values())
completed = status_counts.get("completed", 0) + status_counts.get("completed_with_skip", 0)

if total > 0:
    velocity = {
        "total_tasks": total,
        "completed": completed,
        "completion_rate": round(completed / total, 2),
        "in_progress": status_counts.get("in_progress", 0),
        "ready": status_counts.get("ready", 0),
        "blocked": status_counts.get("blocked", 0),
        "analyzed_at": now,
    }
    patterns["velocity_stats"] = velocity

# Pattern 4: Review outcomes
review_outcomes = Counter()
for rf in (docs / "docs/development/review-contracts").glob("*-review.json"):
    try:
        d = json.loads(rf.read_text())
        state = d.get("state", "")
        review_outcomes[state] += 1
        # Check for common rejection reasons
        for rnd in d.get("rounds", []):
            leader = rnd.get("leader", {})
            if leader.get("verdict") == "changes_requested":
                reason = leader.get("reason", "")
                if reason:
                    new_learnings.append({
                        "type": "review_rejection",
                        "task_id": d.get("task_id", ""),
                        "reason": reason,
                        "learning": f"Common rejection: {reason[:100]}",
                        "guidance": f"Executor: before submitting, check for: {reason[:80]}",
                    })
    except: pass

# Pattern 5: Commit message quality
commit_messages = [o["message"] for o in observations if o.get("source") == "git" and o.get("message")]
short_messages = [m for m in commit_messages if len(m) < 20]
vague_messages = [m for m in commit_messages if any(w in m.lower() for w in ["fix", "wip", "tmp", "test", "update"])]

if len(short_messages) > len(commit_messages) * 0.5:
    new_learnings.append({
        "type": "commit_quality",
        "learning": f"{len(short_messages)}/{len(commit_messages)} commits have short messages (<20 chars) — encourage descriptive commits",
        "guidance": "Use commit format: 'type(scope): description' with at least 30 chars",
    })

# Save patterns
patterns["success_patterns"] = patterns.get("success_patterns", [])[-20:]
patterns["failure_patterns"] = patterns.get("failure_patterns", [])[-20:]
patterns["learned_rules"] = (patterns.get("learned_rules", []) + new_learnings)[-50:]
patterns["updated_at"] = now
patterns_file.write_text(json.dumps(patterns, indent=2, ensure_ascii=False))

# Write learnings to memory for fast retrieval
for learn in new_learnings[:10]:
    memory_file = memory_dir / f"learned-{learn['type']}.md"
    memory_file.parent.mkdir(parents=True, exist_ok=True)
    memory_file.write_text(f"""---
name: learned-{learn['type']}
description: {learn.get('learning', '')[:100]}
metadata:
  type: feedback
---

{learn.get('learning', '')}

**Guidance:** {learn.get('guidance', '')}

**Detected:** {now}
""")

print(json.dumps({
    "analyzed": len(observations),
    "patterns_detected": len(new_learnings),
    "new_learnings": new_learnings[:10],
    "velocity": patterns.get("velocity_stats", {}),
    "patterns_file": str(patterns_file),
}, indent=2))
PY
}

# ── Learn: Update rules based on patterns ────────────────────────────────
monitor_learn() {
  monitor_init
  monitor_analyze 2>/dev/null || true

  echo "=== SELF-LEARNING REPORT ==="
  echo ""

  python3 - "${PATTERNS_FILE}" "${GUIDANCE_FILE}" "${MEMORY_DIR}" <<'PY'
import json, pathlib, sys

patterns_file = pathlib.Path(sys.argv[1])
guidance_file = pathlib.Path(sys.argv[2])
memory_dir = pathlib.Path(sys.argv[3])

if not patterns_file.exists():
    print("No patterns yet — run monitor_watch + monitor_analyze first")
    sys.exit(0)

patterns = json.loads(patterns_file.read_text())
now = patterns.get("updated_at", "")

print(f"Patterns file: {patterns_file}")
print(f"Last updated: {now}")
print(f"Learned rules: {len(patterns.get('learned_rules', []))}")
print()

# Group learnings by type
from collections import defaultdict
by_type = defaultdict(list)
for rule in patterns.get("learned_rules", []):
    by_type[rule.get("type", "unknown")].append(rule)

for ptype, rules in by_type.items():
    print(f"  [{ptype}] {len(rules)} learnings:")
    for r in rules[-3:]:
        print(f"    - {r.get('learning', '')[:120]}")
    print()

# Generate executor guidance
guidance = {
    "schema_version": 1,
    "updated_at": now,
    "active_tips": [],
    "phase_specific_guidance": {},
    "repo_specific_guidance": {},
}

# Phase-specific tips from learned patterns
for rule in patterns.get("learned_rules", []):
    if rule.get("guidance"):
        guidance["active_tips"].append({
            "tip": rule["guidance"],
            "source": rule.get("type", "unknown"),
            "learned_at": now,
        })

# Velocity-based guidance
velocity = patterns.get("velocity_stats", {})
if velocity:
    if velocity.get("blocked", 0) > 0:
        guidance["phase_specific_guidance"]["startup"] = f"Focus on unblocking {velocity['blocked']} blocked tasks before accepting new work"
    if velocity.get("ready", 0) == 0:
        guidance["phase_specific_guidance"]["planner"] = "Queue is empty — run Phase 4 decomposition to create new tasks"
    if velocity.get("in_progress", 0) > 3:
        guidance["phase_specific_guidance"]["executor"] = "Too many in_progress tasks — focus on completing current tasks before starting new ones"

# Keep top 20 tips
guidance["active_tips"] = guidance["active_tips"][-20:]

guidance_file.write_text(json.dumps(guidance, indent=2, ensure_ascii=False))
print(f"Guidance file: {guidance_file}")
print(f"Active tips: {len(guidance['active_tips'])}")
for tip in guidance["active_tips"][-5:]:
    print(f"  TIP: {tip['tip'][:120]}")
PY
}

# ── Self-update: Apply learnings to improve the system ───────────────────
monitor_self_update() {
  monitor_init
  monitor_learn 2>/dev/null || true

  echo ""
  echo "=== SELF-UPDATE ==="
  echo ""

  # Apply learned improvements
  python3 - "${PATTERNS_FILE}" "${GUIDANCE_FILE}" "${DOCS_DIR}" "${CI_CD_DIR}" <<'PY'
import json, pathlib, sys

patterns_file = pathlib.Path(sys.argv[1])
guidance_file = pathlib.Path(sys.argv[2])
docs = pathlib.Path(sys.argv[3])
ci_cd = pathlib.Path(sys.argv[4])

patterns = json.loads(patterns_file.read_text()) if patterns_file.exists() else {}
guidance = json.loads(guidance_file.read_text()) if guidance_file.exists() else {}

updates_applied = []

# 1. Check if we should adjust task creation thresholds
velocity = patterns.get("velocity_stats", {})
if velocity.get("ready", 0) < 2:
    # Too few ready tasks — suggest creating more
    updates_applied.append({
        "action": "create_more_tasks",
        "reason": f"Only {velocity.get('ready', 0)} tasks ready — need at least 3",
        "suggestion": "Run model reasoning to create implementation tasks from Ready contract gaps",
    })

# 2. Check if review process needs tightening
for rule in patterns.get("learned_rules", []):
    if rule.get("type") == "review_rejection":
        updates_applied.append({
            "action": "update_executor_checklist",
            "reason": rule.get("reason", "")[:100],
            "suggestion": f"Executor should check: {rule.get('guidance', '')[:100]}",
        })

# 3. Check if CI failures need attention
for rule in patterns.get("learned_rules", []):
    if rule.get("type") == "ci_risk":
        updates_applied.append({
            "action": "update_ci_guidance",
            "repo": rule.get("repo", ""),
            "suggestion": f"Executor should verify locally before pushing to {rule.get('repo')} — CI failure rate is {rule.get('failure_rate', 0)}",
        })

print(json.dumps({
    "updates_applied": len(updates_applied),
    "updates": updates_applied[:10],
    "guidance_updated": bool(guidance),
    "patterns_learned": len(patterns.get("learned_rules", [])),
}, indent=2))
PY
}

# ── Full monitor cycle ──────────────────────────────────────────────────
monitor_full_cycle() {
  echo "=== MONITOR CYCLE START ==="
  echo ""

  echo "--- Watching ---"
  monitor_watch 2>/dev/null || echo "  (watch skipped)"

  echo ""
  echo "--- Analyzing ---"
  monitor_analyze 2>/dev/null || echo "  (analyze skipped)"

  echo ""
  echo "--- Learning ---"
  monitor_learn 2>/dev/null || echo "  (learn skipped)"

  echo ""
  echo "--- Self-Updating ---"
  monitor_self_update 2>/dev/null || echo "  (self-update skipped)"

  echo ""
  echo "=== MONITOR CYCLE COMPLETE ==="
}

# ── Quick executor guidance ──────────────────────────────────────────────
monitor_guide_executor() {
  local task_id="${1:-}"
  monitor_init

  echo "=== EXECUTOR GUIDANCE ==="
  echo ""

  if [[ -f "${GUIDANCE_FILE}" ]]; then
    python3 - "${GUIDANCE_FILE}" "${task_id}" "${DOCS_DIR}" <<'PY'
import json, pathlib, sys

guidance_file = pathlib.Path(sys.argv[1])
task_id = sys.argv[2]
docs = pathlib.Path(sys.argv[3])

guidance = json.loads(guidance_file.read_text()) if guidance_file.exists() else {}

print("Active tips from learned patterns:")
for tip in guidance.get("active_tips", [])[-5:]:
    print(f"  - {tip['tip'][:150]}")

if task_id:
    print(f"\nTask-specific guidance for {task_id}:")
    ledger = json.loads((docs / "docs/development/task-state-ledger.json").read_text())
    for m in ledger.get("modules", []):
        for t in m.get("tasks", []):
            if t.get("task_id") == task_id:
                print(f"  Status: {t.get('status')}")
                print(f"  Repo: {t.get('repo')}")
                # Phase-specific guidance
                status = t.get("status", "")
                if status == "ready":
                    print("  Next: Accept task → update agent-state → start implementing")
                    print("  Before coding: read task doc, check related tasks, verify local env")
                elif status == "in_progress":
                    print("  Next: Implement → write tests → verify locally → submit for review")
                    print("  Remember: verify_repo before committing")
                elif status == "under_review":
                    print("  Waiting for leader review — check review contract for verdict")
                elif status == "changes_requested":
                    print("  Leader requested changes — fix issues and re-submit")

# Phase-specific guidance from monitor
phase_guidance = guidance.get("phase_specific_guidance", {})
if phase_guidance:
    print("\nPhase-specific guidance:")
    for phase, tip in phase_guidance.items():
        print(f"  [{phase}] {tip[:150]}")
PY
  fi
}
