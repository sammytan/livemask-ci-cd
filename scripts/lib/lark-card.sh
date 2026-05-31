#!/usr/bin/env bash
# Lark card notification library. Source this, then call lark_card_send.
#
# Usage:
#   source "${SCRIPT_DIR}/lib/lark-card.sh"
#   lark_card_send "title" "status" "body_lines" "footer"
#
# Env vars expected:
#   LARK_BOT_WEBHOOK, LARK_BOT_SECRET (set by caller or hardcoded fallback)
set -euo pipefail

LARK_BOT_WEBHOOK="${LARK_BOT_WEBHOOK:-https://open.larksuite.com/open-apis/bot/v2/hook/803303ee-1632-4a99-8847-a071b3c832ad}"
LARK_BOT_SECRET="${LARK_BOT_SECRET:-maVOYNybtveyeOzS5f73td}"

# ── Color/emoji helpers ──────────────────────────────────────────────────────
_emoji() {
  case "$1" in
    PASS|IDLE|OK|success|completed)    echo "✅";;
    WORK|WARN|warning|in_progress)     echo "🟡";;
    FAIL|BLOCKED|blocker|error)        echo "🔴";;
    INFO|running)                      echo "🔵";;
    *)                                 echo "📌";;
  esac
}

_color() {
  case "$1" in
    PASS|IDLE|OK|success)     echo "green";;
    WORK|WARN|warning)        echo "yellow";;
    FAIL|BLOCKED|blocker)     echo "red";;
    INFO)                     echo "blue";;
    *)                        echo "grey";;
  esac
}

# ── Send a single card message ───────────────────────────────────────────────
lark_card_send() {
  local title="${1:-LiveMask}"
  local card_status="${2:-INFO}"
  local body_lines="${3:-}"
  local footer="${4:-}"
  local emoji; emoji=$(_emoji "${card_status}")
  local color; color=$(_color "${card_status}")
  local ts; ts=$(date -u +"%Y-%m-%d %H:%M UTC")

  python3 - "${title}" "${emoji}" "${color}" "${body_lines}" "${footer}" "${ts}" "${LARK_BOT_WEBHOOK}" "${LARK_BOT_SECRET}" <<'PY'
import base64, hashlib, hmac, json, os, sys, time, urllib.request

title, emoji, color, body_lines, footer, ts = sys.argv[1:7]
webhook = sys.argv[7]
secret = sys.argv[8]

# Build card content
elements = []
if body_lines:
    for line in body_lines.strip().split("\n"):
        line = line.strip()
        if not line: continue
        elements.append({"tag": "div", "text": {"tag": "lark_md", "content": line}})

card = {
    "config": {"wide_screen_mode": True},
    "header": {
        "title": {"tag": "plain_text", "content": f"{emoji} {title}"},
        "template": color
    },
    "elements": elements,
}

if footer:
    card["elements"].append({"tag": "hr"})
    card["elements"].append({
        "tag": "note",
        "elements": [{"tag": "plain_text", "content": f"{footer} · {ts}"}]
    })
else:
    card["elements"].append({"tag": "hr"})
    card["elements"].append({
        "tag": "note",
        "elements": [{"tag": "plain_text", "content": f"LiveMask · {ts}"}]
    })

body = {
    "msg_type": "interactive",
    "card": card
}

# Sign
ts_epoch = str(int(time.time()))
sign_str = f"{ts_epoch}\n{secret}"
sign = base64.b64encode(hmac.new(secret.encode(), sign_str.encode(), hashlib.sha256).digest()).decode()

data = json.dumps(body).encode()
req = urllib.request.Request(webhook, data=data, headers={"Content-Type": "application/json"})
try:
    resp = urllib.request.urlopen(req, timeout=5)
    print(f"  [lark] sent: {title} ({resp.status})")
except Exception as e:
    print(f"  [lark] send failed: {e}")
PY
}

# ── Send a batch of cards (aggregate summary) ────────────────────────────────
lark_card_batch() {
  local title="${1:-LiveMask Summary}"
  local cards_json="${2:-}"
  local ts; ts=$(date -u +"%Y-%m-%d %H:%M UTC")

  python3 - "${title}" "${cards_json}" "${ts}" "${LARK_BOT_WEBHOOK}" "${LARK_BOT_SECRET}" <<'PY'
import hashlib, hmac, json, os, sys, time, urllib.request, base64

title, cards_json, ts = sys.argv[1:4]
webhook = sys.argv[4]
secret = sys.argv[5]

try:
    cards = json.loads(cards_json)
except:
    cards = []

elements = []
for c in cards:
    emoji = c.get("emoji","📌")
    label = c.get("label","")
    value = c.get("value","")
    elements.append({
        "tag": "div",
        "text": {"tag": "lark_md", "content": f"{emoji} **{label}**: {value}"}
    })

if elements:
    elements.insert(0, {"tag": "div", "text": {"tag": "lark_md", "content": ""}})

card = {
    "config": {"wide_screen_mode": True},
    "header": {
        "title": {"tag": "plain_text", "content": f"📊 {title}"},
        "template": "blue"
    },
    "elements": elements + [
        {"tag": "hr"},
        {"tag": "note", "elements": [{"tag": "plain_text", "content": f"LiveMask · {ts}"}]}
    ]
}

body = {"msg_type": "interactive", "card": card}
ts_epoch = str(int(time.time()))
sign_str = f"{ts_epoch}\n{secret}"
sign = base64.b64encode(hmac.new(secret.encode(), sign_str.encode(), hashlib.sha256).digest()).decode()
data = json.dumps(body).encode()
req = urllib.request.Request(webhook, data=data, headers={"Content-Type": "application/json"})
try:
    resp = urllib.request.urlopen(req, timeout=5)
    print(f"  [lark] batch sent: {title} ({resp.status})")
except Exception as e:
    print(f"  [lark] batch failed: {e}")
PY
}

# ── Convenience: send preflight result card ──────────────────────────────────
lark_card_preflight() {
  local pf_rc="${1:-0}" pf_label="${2:-IDLE}" candidates="${3:-0}" blocked="${4:-0}" findings="${5:-0}" ci="${6:-?}" review="${7:-0}" reconcile="${8:-0}"
  local st; case "${pf_rc}" in 2) st="BLOCKED";; 1) st="WORK";; *) st="IDLE";; esac

  local body="**Preflight**: ${pf_label}
Candidates: **${candidates}** | Blocked: **${blocked}**
Findings: **${findings}** | CI: **${ci}**
Review: **${review}** contracts | Reconcile: **${reconcile}** entries"

  if [[ "${pf_rc}" -eq 2 ]]; then
    body="${body}
⚠️ System BLOCKED — requires immediate attention"
  elif [[ "${pf_rc}" -eq 1 ]]; then
    body="${body}
🟡 Work available — Claude must not declare idle"
  fi

  lark_card_send "Claude Loop Preflight" "${st}" "${body}" "preflight · exit=${pf_rc}" 2>/dev/null || true
}

# ── Convenience: send role-engine cycle summary card ─────────────────────────
lark_card_role_summary() {
  local role="${1:-pm}" findings="${2:-0}" auto_fixed="${3:-0}" auto_created="${4:-0}" duration="${5:-0s}"
  local emoji; case "${role}" in
    pm) emoji="📋";;
    product) emoji="🎯";;
    tech) emoji="🔧";;
    qa) emoji="🔍";;
    all) emoji="🚀";;
    *) emoji="📌";;
  esac

  local card_st="PASS"
  [[ "${findings}" -gt 0 ]] && card_st="WARN"
  [[ "${findings}" -gt 5 ]] && card_st="WARN"

  local body="Role: **${role}** | Duration: **${duration}**
Findings: **${findings}** | Auto-fixed: **${auto_fixed}** | Auto-created: **${auto_created}**"

  if [[ "${auto_created}" -gt 0 ]]; then
    body="${body}
✨ **${auto_created}** new task(s) auto-created and dispatched"
  fi
  if [[ "${auto_fixed}" -gt 0 ]]; then
    body="${body}
🔧 **${auto_fixed}** ledger conflict(s) auto-reconciled"
  fi
  if [[ "${findings}" -eq 0 ]]; then
    body="${body}
✅ All checks passed — system healthy"
  fi

  lark_card_send "${emoji} Role Engine: ${role}" "${card_st}" "${body}" "role-engine · $(date -u +%H:%M)Z"
}
