#!/usr/bin/env bash
# deepseek-engine.sh — DeepSeek API integration for multi-role reasoning.
# Uses thinking mode (deepseek-reasoner) for complex role decisions,
# chat mode (deepseek-chat) for fast queries, JSON mode for structured output.
set -euo pipefail

DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}"
DEEPSEEK_BASE="https://api.deepseek.com"
ROLE_CACHE_DIR="${HOME}/.claude/role-cache/deepseek"
mkdir -p "${ROLE_CACHE_DIR}"

# ── Call DeepSeek with thinking mode ──────────────────────────────────
ds_reason() {
  local system_prompt="$1" user_prompt="$2" role="${3:-pm}"
  local cache_file="${ROLE_CACHE_DIR}/${role}-$(date +%Y%m%d-%H%M%S).json"
  
  python3 -c "
import json, urllib.request, sys
sp = '''${system_prompt}'''
up = '''${user_prompt}'''
body = json.dumps({
    'model': 'deepseek-reasoner',
    'messages': [
        {'role': 'system', 'content': sp},
        {'role': 'user', 'content': up}
    ],
    'stream': False
}).encode()

req = urllib.request.Request('${DEEPSEEK_BASE}/v1/chat/completions', data=body,
    headers={'Authorization': 'Bearer ${DEEPSEEK_API_KEY}', 'Content-Type': 'application/json'})
try:
    resp = json.loads(urllib.request.urlopen(req, timeout=120).read())
    choice = resp['choices'][0]['message']
    result = {
        'reasoning': choice.get('reasoning_content', ''),
        'answer': choice.get('content', ''),
        'model': resp.get('model', ''),
        'usage': resp.get('usage', {})
    }
    print(json.dumps(result, indent=2, ensure_ascii=False))
    with open('${cache_file}', 'w') as f: json.dump(result, f, indent=2, ensure_ascii=False)
except Exception as e:
    print(json.dumps({'error': str(e)}))
" 2>/dev/null || echo '{"error": "API call failed"}'
}

# ── Fast chat (no thinking, for quick queries) ────────────────────────
ds_chat() {
  local system_prompt="$1" user_prompt="$2"
  
  python3 -c "
import json, urllib.request
body = json.dumps({
    'model': 'deepseek-chat',
    'messages': [
        {'role': 'system', 'content': '''${system_prompt}'''},
        {'role': 'user', 'content': '''${user_prompt}'''}
    ],
    'stream': False,
    'temperature': 0.3
}).encode()

req = urllib.request.Request('${DEEPSEEK_BASE}/v1/chat/completions', data=body,
    headers={'Authorization': 'Bearer ${DEEPSEEK_API_KEY}', 'Content-Type': 'application/json'})
try:
    resp = json.loads(urllib.request.urlopen(req, timeout=60).read())
    print(resp['choices'][0]['message']['content'])
except Exception as e:
    print(f'Error: {e}')
" 2>/dev/null || echo "API call failed"
}

# ── JSON structured output ────────────────────────────────────────────
ds_json() {
  local system_prompt="$1" user_prompt="$2"
  
  python3 -c "
import json, urllib.request
body = json.dumps({
    'model': 'deepseek-chat',
    'messages': [
        {'role': 'system', 'content': '''${system_prompt}'''},
        {'role': 'user', 'content': '''${user_prompt}'''}
    ],
    'response_format': {'type': 'json_object'},
    'stream': False
}).encode()

req = urllib.request.Request('${DEEPSEEK_BASE}/v1/chat/completions', data=body,
    headers={'Authorization': 'Bearer ${DEEPSEEK_API_KEY}', 'Content-Type': 'application/json'})
try:
    resp = json.loads(urllib.request.urlopen(req, timeout=60).read())
    result = json.loads(resp['choices'][0]['message']['content'])
    print(json.dumps(result, indent=2, ensure_ascii=False))
except Exception as e:
    print(json.dumps({'error': str(e)}))
" 2>/dev/null || echo '{"error": "API call failed"}'
}

# ── Multi-role analysis (PM thinking + JSON tasks) ────────────────────
ds_analyze_queue() {
  local context="${1:-}"
  echo "  [DeepSeek] Analyzing queue with thinking mode..."
  
  ds_reason \
    "You are the PM of LiveMask autonomous engine. Analyze the queue state deeply." \
    "Current state: ${context}. Should we create tasks? What gaps exist? What should be the priority order? Think step by step, then provide a JSON action plan." \
    "pm-queue"
}

# ── Code review with DeepSeek ─────────────────────────────────────────
ds_review_code() {
  local diff="${1:-}" task_id="${2:-}"
  echo "  [DeepSeek] Reviewing code for ${task_id}..."
  
  ds_json \
    "You are a code reviewer. Output JSON: {\"verdict\":\"approved\"|\"changes_requested\",\"issues\":[...],\"suggestions\":[...]}" \
    "Review this diff for task ${task_id}:\n${diff}"
}

# ── Self-learning: analyze patterns ───────────────────────────────────
ds_analyze_patterns() {
  local findings="${1:-}"
  echo "  [DeepSeek] Analyzing patterns with thinking mode..."
  
  ds_reason \
    "You are the Monitor role. Analyze patterns in engine findings. Identify root causes and suggest improvements." \
    "Recent findings:\n${findings}\n\nWhat patterns do you see? What should the engine learn from this?" \
    "monitor-learn"
}
