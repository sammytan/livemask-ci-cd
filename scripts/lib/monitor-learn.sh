#!/usr/bin/env bash
# monitor-learn.sh — Real-time, event-driven monitor for ALL roles.
#
# Watches every role's activity, detects patterns across the entire system,
# learns from successes AND failures, and feeds guidance back to each role
# via the event bus in real-time.
#
# Monitored roles: PM, Product, Tech, QA, Task Review, Leader, Executor, Codex
# Interaction: event-bus.sh — monitor subscribes to ALL events and reacts immediately
#
# Architecture:
#   Any Role emits event → Monitor receives → Analyze + Learn → Feed back to Role
#   ┌─────────┐    ┌──────────┐    ┌──────────────┐    ┌──────────────┐
#   │  Role   │───→│ Event Bus│───→│   Monitor    │───→│  Role Guide  │
#   │ (action)│    │ (event)  │    │ (analyze)    │    │ (feedback)   │
#   └─────────┘    └──────────┘    └──────────────┘    └──────────────┘
set -euo pipefail

LIVEMASK_ROOT="${LIVEMASK_ROOT:-/Users/sammytan/Developer/LiveMask}"
DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"
ROLE_CACHE_DIR="${HOME}/.claude/role-cache"
MONITOR_DIR="${ROLE_CACHE_DIR}/monitor"
LEARNED_DIR="${ROLE_CACHE_DIR}/learned"
OBSERVATIONS_FILE="${MONITOR_DIR}/observations.jsonl"
PATTERNS_FILE="${LEARNED_DIR}/patterns.json"
GUIDANCE_FILE="${LEARNED_DIR}/guidance.json"
MEMORY_DIR="${HOME}/.claude/projects/-Users-sammytan-Developer-LiveMask/memory"

monitor_init() {
  mkdir -p "${MONITOR_DIR}" "${LEARNED_DIR}"
  touch "${OBSERVATIONS_FILE}" 2>/dev/null || true
  if [[ ! -f "${PATTERNS_FILE}" ]]; then
    echo '{"schema_version":2,"updated_at":"","role_patterns":{},"cross_role_patterns":[],"learned_rules":[],"velocity_stats":{}}' > "${PATTERNS_FILE}"
  fi
  if [[ ! -f "${GUIDANCE_FILE}" ]]; then
    echo '{"schema_version":2,"updated_at":"","per_role_guidance":{},"active_warnings":[],"deadlock_alerts":[]}' > "${GUIDANCE_FILE}"
  fi
}

# ── Observe ALL roles via event bus ──────────────────────────────────────
# Called by event-bus.sh after ANY event is emitted
monitor_observe_event() {
  local event_type="${1:-}" task_id="${2:-}" metadata="${3:-{}}"
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  monitor_init

  python3 -c "
import json, pathlib, sys, time
event_type = '${event_type}'
task_id = '${task_id}'
now = '${now}'

# Record observation
obs = {
    'event_type': event_type,
    'task_id': task_id,
    'observed_at': now,
    'metadata': json.loads('${metadata}') if '${metadata}' and '${metadata}' != '{}' else {},
}

# Add contextual data based on event type
docs = pathlib.Path('${DOCS_DIR}')
root = pathlib.Path('${LIVEMASK_ROOT}')

# Agent state context
agent_file = root / '.claude/agent-state.json'
if agent_file.exists():
    agent = json.loads(agent_file.read_text())
    obs['agent_phase'] = agent.get('phase', '?')

# Task context
if task_id:
    ledger = json.loads((docs / 'docs/development/task-state-ledger.json').read_text())
    for m in ledger.get('modules', []):
        for t in m.get('tasks', []):
            if t.get('task_id') == task_id:
                obs['task_status'] = t.get('status', '?')
                obs['task_repo'] = t.get('repo', '?')
                break

path = pathlib.Path('${OBSERVATIONS_FILE}')
with open(path, 'a', encoding='utf-8') as f:
    f.write(json.dumps(obs, ensure_ascii=False) + '\n')
print(f'  [Monitor] Observed: {event_type} {task_id}')
" 2>/dev/null

  # Analyze immediately (real-time, not batch)
  monitor_analyze_event "${event_type}" "${task_id}" 2>/dev/null || true
}

# ── Analyze single event in real-time ────────────────────────────────────
monitor_analyze_event() {
  local event_type="${1:-}" task_id="${2:-}"
  monitor_init

  python3 - "${event_type}" "${task_id}" "${PATTERNS_FILE}" "${GUIDANCE_FILE}" "${OBSERVATIONS_FILE}" "${DOCS_DIR}" "${LIVEMASK_ROOT}" "${MEMORY_DIR}" <<'PY'
import json, pathlib, sys, time
from collections import Counter, defaultdict
from datetime import datetime, timezone

event_type = sys.argv[1]
task_id = sys.argv[2]
patterns_file = pathlib.Path(sys.argv[3])
guidance_file = pathlib.Path(sys.argv[4])
obs_file = pathlib.Path(sys.argv[5])
docs = pathlib.Path(sys.argv[6])
root = pathlib.Path(sys.argv[7])
memory_dir = pathlib.Path(sys.argv[8])

now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

# Load existing patterns
patterns = json.loads(patterns_file.read_text()) if patterns_file.exists() else {"role_patterns": {}, "cross_role_patterns": [], "learned_rules": [], "velocity_stats": {}}
guidance = json.loads(guidance_file.read_text()) if guidance_file.exists() else {"per_role_guidance": {}, "active_warnings": [], "deadlock_alerts": []}

# Count recent events for pattern detection
recent_events = []
if obs_file.exists():
    for line in obs_file.read_text().splitlines()[-200:]:
        try: recent_events.append(json.loads(line))
        except: pass

# ── Per-role pattern detection ────────────────────────────────────────
role_patterns = patterns.setdefault("role_patterns", {})

# PM patterns
pm_events = [e for e in recent_events if e["event_type"] in ("task_accepted", "task_completed", "task_blocked", "review_submitted", "leader_approved")]
if pm_events:
    role_patterns.setdefault("PM", {"event_counts": {}, "insights": []})
    for e in pm_events:
        role_patterns["PM"]["event_counts"][e["event_type"]] = role_patterns["PM"]["event_counts"].get(e["event_type"], 0) + 1

    # Insight: if no task_completed in last 20 events, executor may be stuck
    completions = sum(1 for e in pm_events[-20:] if e["event_type"] == "task_completed")
    if len(pm_events) >= 10 and completions == 0:
        insight = "PM: No task completions in recent window — executor may be stuck or not submitting"
        if insight not in role_patterns["PM"]["insights"]:
            role_patterns["PM"]["insights"].append(insight)
            guidance.setdefault("per_role_guidance", {}).setdefault("PM", []).append({"tip": insight, "at": now})

# Tech patterns
if event_type in ("code_committed", "review_submitted"):
    role_patterns.setdefault("Tech", {"event_counts": {}, "insights": []})
    role_patterns["Tech"]["event_counts"][event_type] = role_patterns["Tech"]["event_counts"].get(event_type, 0) + 1

# QA patterns
qa_events = [e for e in recent_events if e["event_type"] in ("qa_passed", "qa_failed", "review_submitted")]
if qa_events:
    role_patterns.setdefault("QA", {"event_counts": {}, "insights": []})
    for e in qa_events:
        role_patterns["QA"]["event_counts"][e["event_type"]] = role_patterns["QA"]["event_counts"].get(e["event_type"], 0) + 1

    # Insight: high QA failure rate
    qa_total = sum(1 for e in qa_events if e["event_type"] in ("qa_passed", "qa_failed"))
    qa_fails = sum(1 for e in qa_events if e["event_type"] == "qa_failed")
    if qa_total >= 3 and qa_fails / qa_total > 0.5:
        insight = f"QA: {qa_fails}/{qa_total} QA failures — check common failure reasons"
        if insight not in role_patterns["QA"]["insights"]:
            role_patterns["QA"]["insights"].append(insight)
            guidance.setdefault("per_role_guidance", {}).setdefault("QA", []).append({"tip": insight, "at": now})

# Leader patterns
leader_events = [e for e in recent_events if e["event_type"] in ("leader_approved", "changes_requested", "review_submitted")]
if leader_events:
    role_patterns.setdefault("Leader", {"event_counts": {}, "insights": []})
    for e in leader_events:
        role_patterns["Leader"]["event_counts"][e["event_type"]] = role_patterns["Leader"]["event_counts"].get(e["event_type"], 0) + 1

# Executor patterns
executor_events = [e for e in recent_events if e["agent_phase"] in ("implementing", "under_review", "revising", "merging")]
if executor_events:
    role_patterns.setdefault("Executor", {"event_counts": {}, "insights": []})
    phases = Counter(e.get("agent_phase", "?") for e in executor_events)
    for phase, count in phases.most_common(3):
        role_patterns["Executor"]["event_counts"][phase] = count

# ── Cross-role pattern detection ──────────────────────────────────────
cross_patterns = patterns.setdefault("cross_role_patterns", [])

# Deadlock detection: queue empty + PM lease held > 30min
empty_queue_events = [e for e in recent_events if e.get("event_type") == "task_completed"]
if len(empty_queue_events) >= 2:
    # Check if new tasks were created after completions
    accepted_after = [e for e in recent_events if e.get("event_type") == "task_accepted"]
    if len(accepted_after) < len(empty_queue_events[-3:]):
        alert = f"Cross-role: More completions than acceptances — queue may be draining. Last check: {now}"
        if alert not in [a.get("alert") for a in guidance.get("deadlock_alerts", [])]:
            guidance.setdefault("deadlock_alerts", []).append({"alert": alert, "at": now, "severity": "warning"})
            cross_patterns.append({"type": "queue_draining", "detected_at": now, "detail": alert})

# ── Write feedback to memory for real-time role consumption ────────────
for role_name, role_data in role_patterns.items():
    if "insights" in role_data and role_data["insights"]:
        memory_file = memory_dir / f"monitor-{role_name.lower()}.md"
        memory_file.parent.mkdir(parents=True, exist_ok=True)
        lines = [f"# Monitor: {role_name} Insights\n", f"Updated: {now}\n\n"]
        for insight in role_data["insights"][-5:]:
            lines.append(f"- {insight}\n")
        memory_file.write_text("".join(lines))

# Save updated patterns and guidance
patterns["updated_at"] = now
guidance["updated_at"] = now
patterns_file.write_text(json.dumps(patterns, indent=2, ensure_ascii=False))
guidance_file.write_text(json.dumps(guidance, indent=2, ensure_ascii=False))
PY
}

# ── Get guidance for any role in real-time ───────────────────────────────
monitor_guide_role() {
  local role="${1:-}" task_id="${2:-}"
  monitor_init

  python3 - "${role}" "${task_id}" "${GUIDANCE_FILE}" "${PATTERNS_FILE}" "${DOCS_DIR}" <<'PY'
import json, pathlib, sys

role = sys.argv[1]
task_id = sys.argv[2]
guidance_file = pathlib.Path(sys.argv[3])
patterns_file = pathlib.Path(sys.argv[4])
docs = pathlib.Path(sys.argv[5])

guidance = json.loads(guidance_file.read_text()) if guidance_file.exists() else {}
patterns = json.loads(patterns_file.read_text()) if patterns_file.exists() else {}

print(f"=== Monitor Guidance for {role} ===")
print()

# Role-specific guidance
role_guidance = guidance.get("per_role_guidance", {}).get(role, [])
if role_guidance:
    print("Recent insights:")
    for g in role_guidance[-5:]:
        print(f"  - {g.get('tip', g)}")

# Cross-role patterns relevant to this role
for pattern in patterns.get("cross_role_patterns", [])[-5:]:
    if role.lower() in pattern.get("detail", "").lower():
        print(f"  [!] {pattern.get('detail', '')}")

# Deadlock alerts
for alert in guidance.get("deadlock_alerts", [])[-3:]:
    print(f"  [DEADLOCK] {alert.get('alert', '')} (severity={alert.get('severity', '?')})")

# Active warnings
for warn in guidance.get("active_warnings", [])[-5:]:
    print(f"  [WARN] {warn.get('message', '')}")

# Event stats for this role
role_stats = patterns.get("role_patterns", {}).get(role, {}).get("event_counts", {})
if role_stats:
    print(f"\nEvent counts for {role}:")
    for event, count in sorted(role_stats.items()):
        print(f"  {event}: {count}")

if not role_guidance and not role_stats:
    print("  No data yet — monitor needs more observations")
PY
}

# ── Full system health from monitor's perspective ────────────────────────
monitor_system_health() {
  monitor_init

  python3 - "${PATTERNS_FILE}" "${GUIDANCE_FILE}" "${OBSERVATIONS_FILE}" "${DOCS_DIR}" <<'PY'
import json, pathlib, sys
from collections import Counter

patterns_file = pathlib.Path(sys.argv[1])
guidance_file = pathlib.Path(sys.argv[2])
obs_file = pathlib.Path(sys.argv[3])
docs = pathlib.Path(sys.argv[4])

patterns = json.loads(patterns_file.read_text()) if patterns_file.exists() else {}
guidance = json.loads(guidance_file.read_text()) if guidance_file.exists() else {}

# Count observations
obs_count = 0
if obs_file.exists():
    obs_count = len(obs_file.read_text().splitlines())

# Event type distribution
event_counts = Counter()
if obs_file.exists():
    for line in obs_file.read_text().splitlines()[-500:]:
        try: event_counts[json.loads(line).get("event_type", "?")] += 1
        except: pass

print(json.dumps({
    "total_observations": obs_count,
    "recent_events": dict(event_counts.most_common(10)),
    "roles_monitored": list(patterns.get("role_patterns", {}).keys()),
    "cross_role_patterns": len(patterns.get("cross_role_patterns", [])),
    "deadlock_alerts": len(guidance.get("deadlock_alerts", [])),
    "active_warnings": len(guidance.get("active_warnings", [])),
    "last_updated": patterns.get("updated_at", "never"),
}, indent=2))
PY
}

# ── Learn from Codex reconcile patterns ────────────────────────────────
monitor_learn_from_codex() {
  echo "  [CodexLearn] Analyzing Codex reconcile patterns..."
  cd "${DOCS_DIR}" 2>/dev/null || return 0
  git log --oneline --since="24 hours ago" --grep="reconcile" 2>/dev/null | head -20 | python3 -c "
import sys,re
lines = sys.stdin.readlines()
completed = [l for l in lines if 'completed' in l.lower() or 'mark' in l.lower()]
skipped = [l for l in lines if 'skip' in l.lower() or 'blocked' in l.lower()]
patterns = []
for l in completed[:5]:
    tid = re.findall(r'TASK-[A-Z0-9-]+', l)
    if tid: patterns.append(f'Codex completed {tid[0]}')
for l in skipped[:3]:
    tid = re.findall(r'TASK-[A-Z0-9-]+', l)
    if tid: patterns.append(f'Codex skipped {tid[0]}')
for p in patterns: print(f'  [CodexLearn] {p}')
if not patterns: print('  [CodexLearn] No recent Codex activity')
" 2>/dev/null || true
}

# ── Track verify performance over time ──────────────────────────────────
monitor_performance_track() {
  local perf_file="${ROLE_CACHE_DIR}/monitor/perf-stats.jsonl"
  mkdir -p "$(dirname "${perf_file}")" 2>/dev/null
  for repo in livemask-backend livemask-admin livemask-docs; do
    local repo_dir="${LIVEMASK_ROOT}/${repo}"
    [[ ! -d "${repo_dir}" ]] && continue
    local start; start=$(python3 -c "import time; print(int(time.time()))")
    case "${repo}" in
      livemask-backend) cd "${repo_dir}" && go build ./... 2>/dev/null ;;
      livemask-admin) cd "${repo_dir}" && npm run build 2>/dev/null | tail -1 ;;
      livemask-docs) cd "${repo_dir}" && bash scripts/check-docs.sh 2>/dev/null | tail -1 ;;
    esac
    local elapsed; elapsed=$(python3 -c "import time; print(int(time.time())-${start})")
    python3 -c "import json,pathlib; d={'repo':'${repo}','elapsed_s':${elapsed},'at':'$(date -u +%Y-%m-%dT%H:%M:%SZ)'}; f=open('${perf_file}','a'); f.write(json.dumps(d)+'\n')" 2>/dev/null || true
  done
  # Show trend
  python3 -c "
import json,pathlib
from collections import defaultdict
f=pathlib.Path('${perf_file}')
if f.exists():
    data=[json.loads(l) for l in f.read_text().splitlines() if l.strip()]
    by_repo=defaultdict(list)
    for d in data: by_repo[d['repo']].append(d['elapsed_s'])
    for repo,times in sorted(by_repo.items()):
        avg=sum(times)/len(times)
        trend='↑' if len(times)>1 and times[-1]>times[-2] else '↓' if len(times)>1 else '→'
        print(f'  [Perf] {repo}: avg={avg:.1f}s over {len(times)} builds {trend}')
" 2>/dev/null || true
}

# ── Scan for TODOs and create tech-debt tasks ──────────────────────────
monitor_scan_techdebt() {
  echo "  [TechDebt] Scanning for TODOs..."
  local todo_count=0
  for repo in livemask-backend livemask-admin livemask-app livemask-nodeagent livemask-job-service; do
    local dir="${LIVEMASK_ROOT}/${repo}"
    [[ ! -d "${dir}" ]] && continue
    local count; count=$(grep -r "TODO\|FIXME\|HACK\|XXX" "${dir}" --include="*.go" --include="*.ts" --include="*.tsx" --include="*.dart" 2>/dev/null | grep -v "node_modules\|\.git\|vendor" | wc -l | tr -d ' ')
    todo_count=$((todo_count + count))
    [[ "${count}" -gt 5 ]] && echo "  [TechDebt] ${repo}: ${count} TODOs"
  done
  echo "  [TechDebt] Total TODOs across repos: ${todo_count}"
  [[ "${todo_count}" -gt 50 ]] && executor_notify_human "tech_debt" "${todo_count} TODOs across codebase"
}
