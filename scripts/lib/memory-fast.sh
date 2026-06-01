#!/usr/bin/env bash
# memory-fast.sh — Fast local memory storage and retrieval.
# Stores project context, decisions, task history, and learned patterns.
# Uses indexed JSON for O(1) key lookup + full-text grep fallback.
set -euo pipefail

LIVEMASK_ROOT="${LIVEMASK_ROOT:-/Users/sammytan/Developer/LiveMask}"
MEMORY_DIR="${HOME}/.claude/projects/-Users-sammytan-Developer-LiveMask/memory"
MEMORY_INDEX="${MEMORY_DIR}/.memory-index.json"
MEMORY_STORE="${MEMORY_DIR}/.memory-store.jsonl"

# ── Initialize ──────────────────────────────────────────────────────────
memory_init() {
  mkdir -p "${MEMORY_DIR}"

  # Initialize index if missing
  if [[ ! -f "${MEMORY_INDEX}" ]]; then
    echo '{"entries": {}, "tags": {}, "updated_at": ""}' > "${MEMORY_INDEX}"
  fi

  # Create store file if missing
  touch "${MEMORY_STORE}" 2>/dev/null || true
}

# ── Write memory ────────────────────────────────────────────────────────
# Usage: memory_put <key> <type> <summary> <tags>
memory_put() {
  local key="$1" type="${2:-note}" summary="$3" tags="${4:-}"
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  memory_init

  # Append to store
  python3 -c "
import json, pathlib, sys
entry = {
    'key': '${key}',
    'type': '${type}',
    'summary': '${summary}',
    'tags': '${tags}',
    'created_at': '${ts}',
    'repo': '$(git -C "${LIVEMASK_ROOT}/livemask-docs" branch --show-current 2>/dev/null || echo "unknown")',
    'docs_head': '$(git -C "${LIVEMASK_ROOT}/livemask-docs" rev-parse --short HEAD 2>/dev/null || echo "?")',
}
path = pathlib.Path('${MEMORY_STORE}')
path.parent.mkdir(parents=True, exist_ok=True)
with open(path, 'a', encoding='utf-8') as f:
    f.write(json.dumps(entry, ensure_ascii=False) + '\n')

# Update index
idx_path = pathlib.Path('${MEMORY_INDEX}')
idx = json.loads(idx_path.read_text()) if idx_path.exists() else {'entries': {}, 'tags': {}}
idx['entries']['${key}'] = {'type': '${type}', 'summary': '${summary}',
    'tags': '${tags}', 'created_at': '${ts}'}
idx['updated_at'] = '${ts}'
# Tag index for fast lookup
for tag in '${tags}'.split(','):
    tag = tag.strip()
    if tag:
        idx['tags'].setdefault(tag, []).append('${key}')
        idx['tags'][tag] = list(set(idx['tags'][tag]))[-20:]  # Keep last 20
idx_path.write_text(json.dumps(idx, indent=2, ensure_ascii=False))
" 2>/dev/null
  echo "{\"stored\": \"${key}\", \"type\": \"${type}\"}"
}

# ── Read memory ─────────────────────────────────────────────────────────
# Usage: memory_get <key>
memory_get() {
  local key="$1"
  memory_init

  python3 -c "
import json, pathlib
store = pathlib.Path('${MEMORY_STORE}')
if not store.exists():
    print('{\"error\": \"not found\"}')
    exit(0)
# Read from end (newest first) to find latest entry for key
lines = store.read_text().splitlines()
for line in reversed(lines):
    try:
        entry = json.loads(line)
        if entry.get('key') == '${key}':
            print(json.dumps(entry, indent=2, ensure_ascii=False))
            exit(0)
    except: pass
print('{\"error\": \"not found\"}')
" 2>/dev/null
}

# ── Search memory ────────────────────────────────────────────────────────
# Usage: memory_search <query> [limit]
memory_search() {
  local query="$1" limit="${2:-10}"

  # First try index lookup
  python3 -c "
import json, pathlib
query = '${query}'.lower()
idx_path = pathlib.Path('${MEMORY_INDEX}')
if idx_path.exists():
    idx = json.loads(idx_path.read_text())
    # Search in keys and tags
    matches = []
    for key, entry in idx.get('entries', {}).items():
        if query in key.lower() or query in entry.get('summary','').lower() or query in entry.get('tags','').lower():
            matches.append({**entry, 'key': key})
            if len(matches) >= ${limit}: break
    if matches:
        print(json.dumps({'source': 'index', 'matches': matches}, indent=2, ensure_ascii=False))
    else:
        print(json.dumps({'source': 'index', 'matches': []}, indent=2, ensure_ascii=False))
" 2>/dev/null

  # Fallback: full-text grep on store
  if [[ -f "${MEMORY_STORE}" ]]; then
    grep -i "${query}" "${MEMORY_STORE}" 2>/dev/null | tail -"${limit}" | python3 -c "
import json, sys
matches = []
for line in sys.stdin:
    try: matches.append(json.loads(line))
    except: pass
print(json.dumps({'source': 'grep_fallback', 'matches': matches[-${limit}:]}, indent=2, ensure_ascii=False))
" 2>/dev/null
  fi
}

# ── Memory context for a task ────────────────────────────────────────────
memory_task_context() {
  local tid="$1"

  # Search for all memories related to this task
  local results
  results=$(memory_search "${tid}" 15 2>/dev/null)

  # Also search by repo if we can find it
  local repo; repo=$(python3 -c "
import json
ledger = json.load(open('${LIVEMASK_ROOT}/livemask-docs/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id') == '${tid}':
            print(t.get('repo',''))
            break
" 2>/dev/null || echo "")
  if [[ -n "${repo}" ]]; then
    memory_search "${repo}" 5 2>/dev/null
  fi

  echo "${results}"
}

# ── Recent decisions (last N hours) ─────────────────────────────────────
memory_recent_decisions() {
  local hours="${1:-24}"
  local since; since=$(python3 -c "import time; print(time.time() - ${hours}*3600)")

  python3 -c "
import json, pathlib, time
store = pathlib.Path('${MEMORY_STORE}')
if not store.exists():
    print('[]')
    exit(0)
since = ${since}
matches = []
for line in reversed(store.read_text().splitlines()):
    try:
        entry = json.loads(line)
        created = entry.get('created_at', '')
        if created:
            ts = time.mktime(time.strptime(created[:19], '%Y-%m-%dT%H:%M:%S'))
            if ts >= since and ('decision' in entry.get('type','').lower() or 'fix' in entry.get('tags','').lower()):
                matches.append(entry)
                if len(matches) >= 20: break
    except: pass
print(json.dumps(matches, indent=2, ensure_ascii=False))
" 2>/dev/null
}

# ── Learned patterns (feedback memories) ─────────────────────────────────
memory_learned_patterns() {
  python3 -c "
import json, pathlib
store = pathlib.Path('${MEMORY_STORE}')
if not store.exists():
    print('[]')
    exit(0)
patterns = []
for line in reversed(store.read_text().splitlines()):
    try:
        entry = json.loads(line)
        if entry.get('type') in ('feedback', 'pattern', 'rule'):
            patterns.append(entry)
            if len(patterns) >= 10: break
    except: pass
print(json.dumps(patterns, indent=2, ensure_ascii=False))
" 2>/dev/null
}

# ── Save a decision with reasoning ──────────────────────────────────────
memory_save_decision() {
  local context="$1" decision="$2" reasoning="$3"

  memory_put \
    "decision-$(date -u +%Y%m%d-%H%M%S)" \
    "decision" \
    "${decision}" \
    "decision,${context}"

  # Also save reasoning separately for future reference
  python3 -c "
import json, pathlib
entry = {
    'type': 'decision_reasoning',
    'context': '${context}',
    'decision': '${decision}',
    'reasoning': '${reasoning}',
    'created_at': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
}
path = pathlib.Path('${MEMORY_STORE}')
with open(path, 'a', encoding='utf-8') as f:
    f.write(json.dumps(entry, ensure_ascii=False) + '\n')
" 2>/dev/null
  echo "{\"decision_saved\": true}"
}

# ── Stats ────────────────────────────────────────────────────────────────
memory_stats() {
  memory_init
  python3 -c "
import json, pathlib
store = pathlib.Path('${MEMORY_STORE}')
idx = json.loads(pathlib.Path('${MEMORY_INDEX}').read_text()) if pathlib.Path('${MEMORY_INDEX}').exists() else {'entries': {}, 'tags': {}}

count = 0
types = {}
if store.exists():
    for line in store.read_text().splitlines():
        try:
            entry = json.loads(line)
            count += 1
            t = entry.get('type', 'unknown')
            types[t] = types.get(t, 0) + 1
        except: pass

print(json.dumps({
    'total_entries': count,
    'indexed_keys': len(idx.get('entries', {})),
    'indexed_tags': len(idx.get('tags', {})),
    'by_type': types,
    'store_size_bytes': store.stat().st_size if store.exists() else 0,
    'last_updated': idx.get('updated_at', 'never'),
}, indent=2, ensure_ascii=False))
" 2>/dev/null
}
