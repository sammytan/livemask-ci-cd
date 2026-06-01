#!/usr/bin/env bash
# lark-notify.sh — Beautiful Lark card notifications for all role results.
set -euo pipefail

LIVEMASK_ROOT="${LIVEMASK_ROOT:-/Users/sammytan/Developer/LiveMask}"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"
ROLE_CACHE_DIR="${HOME}/.claude/role-cache"
LARK_WEBHOOK="${LARK_WEBHOOK_URL:-https://open.larksuite.com/open-apis/bot/v2/hook/803303ee-1632-4a99-8847-a071b3c832ad}"

lark_send_card() {
  local title="$1" color="$2" content="$3"
  python3 -c "
import json,urllib.request
card={'msg_type':'interactive','card':{'header':{'title':{'tag':'plain_text','content':'${title}'},'template':'${color}'},'elements':[{'tag':'markdown','content':'''${content}'''}]}}
try:
    urllib.request.urlopen(urllib.request.Request('${LARK_WEBHOOK}',data=json.dumps(card).encode(),headers={'Content-Type':'application/json'}),timeout=10)
except: pass
" 2>/dev/null || true
}

lark_notify_pm_report() {
  lark_send_card "PM Report" "blue" "Findings: ${1:-0} | Blocked: ${2:-0} | Gaps: ${3:-0}\nTime: $(date '+%H:%M:%S')"
}
lark_notify_task_accepted() {
  lark_send_card "Task Accepted" "green" "**${1:-?}**\nRepo: ${2:-?} | Priority: ${3:-P1}\nTime: $(date '+%H:%M:%S')"
}
lark_notify_review_result() {
  local emoji=$([[ "${2:-}" == "approved" ]] && echo "PASS" || echo "FAIL")
  local clr=$([[ "${2:-}" == "approved" ]] && echo "green" || echo "red")
  lark_send_card "${emoji} Review: ${1:-?}" "${clr}" "Verdict: ${2:-?}\nReason: ${3:-?}\nTime: $(date '+%H:%M:%S')"
}
lark_notify_qa_result() {
  local emoji=$([[ "${2:-false}" == "true" ]] && echo "PASS" || echo "FAIL")
  local clr=$([[ "${2:-false}" == "true" ]] && echo "green" || echo "red")
  lark_send_card "${emoji} QA: ${1:-?}" "${clr}" "Result: $([[ "${2:-false}" == "true" ]] && echo 'PASSED' || echo 'FAILED')\n${3:-}\nTime: $(date '+%H:%M:%S')"
}
lark_notify_merge_complete() {
  lark_send_card "Merge Complete" "green" "**${1:-?}**\nRepo: ${2:-?} | Commit: ${3:-?}\nTime: $(date '+%H:%M:%S')"
}
lark_notify_monitor_insight() {
  lark_send_card "Monitor Insight" "blue" "${1:-?}\nTime: $(date '+%H:%M:%S')"
}
lark_notify_engine_status() {
  lark_send_card "Engine Status" "blue" "Queue: ${1:-0} | Packets: ${2:-0} | Agent: ${3:-idle}\nDaemon PID: ${4:-?}\nTime: $(date '+%H:%M:%S')"
}
lark_notify_alert() {
  local clr=$([[ "${1:-warning}" == "critical" ]] && echo "red" || echo "yellow")
  lark_send_card "ALERT: ${2:-?}" "${clr}" "${3:-?}\nTime: $(date '+%H:%M:%S')"
}
