#!/usr/bin/env bash
# lark-notify.sh — Beautiful Lark cards + templates + GitHub integration
set -euo pipefail
SEND_PY="$(cd "$(dirname "$0")" && pwd)/_lark_send.py"
DOCS_DIR="${DOCS_DIR:-/Users/sammytan/Developer/LiveMask/livemask-docs}"

lark_send() { python3 "${SEND_PY}" "$1" "$2" "$3"; }

# ── Beautiful Templates ──────────────────────────────────────────────
lark_template_menu() {
  lark_send "🤖 LiveMask 引擎" "blue" $'**欢迎使用 LiveMask 自主开发引擎**\n\n🐛  **Bug**  —  提交 Bug 报告\n📋  **需求**  —  提交新需求\n📝  **文档**  —  文档更新请求\n\n━━━━━━━━━━━━━━━━━━━\n\n📊  **MVP**  —  查看 MVP 进度\n📊  **总览**  —  项目全局报告\n📋  **任务** \\<ID\\>  —  查询任务进度\n⚙️  **状态**  —  引擎运行状态\n\n━━━━━━━━━━━━━━━━━━━\n\n💡 直接回复关键词即可交互'
}

lark_template_bug() {
  lark_send "🐛 Bug 提交" "yellow" $'**请描述你遇到的问题**\n\n格式:\n⎡ Bug: \\<标题\\>\n⎣ Bug: \\<标题\\> | \\<详细描述\\>\n\n📌 **示例**\n• Bug: VPN 连接偶尔断线\n• Bug: 后台节点列表不刷新\n• Bug: 登录页验证码不显示 | iOS Safari 浏览器'
}

lark_template_requirement() {
  lark_send "📋 需求提交" "blue" $'**请描述你需要的功能**\n\n格式:\n⎡ 需求: \\<标题\\>\n⎣ 需求: \\<标题\\> | \\<详细描述\\>\n\n📌 **示例**\n• 需求: 用户需要多语言切换\n• 需求: 增加节点测速功能\n• 需求: 支持导出流量报表 | CSV 格式'
}

lark_template_doc() {
  lark_send "📝 文档更新" "blue" $'**请描述需要更新的文档**\n\n格式:\n⎡ 文档: \\<标题\\>\n⎣ 文档: \\<标题\\> | \\<详细描述\\>\n\n📌 **示例**\n• 文档: 更新 API 认证流程\n• 文档: 补充部署文档\n• 文档: 修正架构图 | 第三章架构部分'
}

# ── Notifications ───────────────────────────────────────────────────
lark_notify_pm_report() {
  lark_send "📋 PM 诊断完成" "blue" $'🔍 **发现**: '"${1:-0}"$' 条\n🚫 **阻塞**: '"${2:-0}"$' 个\n📌 **缺口**: '"${3:-0}"$' 个'
}
lark_notify_task_accepted() {
  lark_send "✅ 任务已接受" "green" $'**'"${1:-?}"$'**\n\n📦 仓库: '"${2:-?}"$'\n⭐ 优先级: '"${3:-P1}"$'\n\n引擎已开始实现'
}
lark_notify_review_result() {
  if [[ "${2:-}" == "approved" ]]; then
    lark_send "✅ 审查通过" "green" $'**'"${1:-?}"$'**\n\n✅ 代码审查通过\n💬 '"${3:-}"$''
  else
    lark_send "❌ 审查驳回" "red" $'**'"${1:-?}"$'**\n\n❌ 需要修改\n💬 '"${3:-}"$''
  fi
}
lark_notify_qa_result() {
  if [[ "${2:-false}" == "true" ]]; then
    lark_send "✅ QA 通过" "green" $'**'"${1:-?}"$'**\n\n🟢 Build 通过\n🟢 Test 通过\n🟢 Acceptance 通过'
  else
    lark_send "❌ QA 失败" "red" $'**'"${1:-?}"$'**\n\n🔴 QA 验证未通过\n💬 '"${3:-}"$''
  fi
}
lark_notify_merge_complete() {
  lark_send "🚀 合并完成" "green" $'**'"${1:-?}"$'**\n\n📦 仓库: '"${2:-?}"$'\n🔗 提交: '"${3:-?}"$'\n\n✅ 已合并到 dev，CI 运行中'
}
lark_notify_monitor_insight() {
  lark_send "🧠 Monitor 洞察" "blue" "${1:-}"
}
lark_notify_engine_status() {
  lark_send "⚙️ 引擎状态" "blue" $'📋 队列: '"${1:-0}"$' 候选\n📦 调度包: '"${2:-0}"$' 个\n🤖 代理: '"${3:-idle}"$'\n🔧 PID: '"${4:-?}"
}
lark_notify_alert() {
  local clr="yellow"; [[ "${1:-warning}" == "critical" ]] && clr="red"
  lark_send "🚨 ${2:-告警}" "${clr}" "${3:-}"
}

# ── Queries ─────────────────────────────────────────────────────────
lark_query_task() {
  local tid="${1:-}"
  if [[ -n "${tid}" ]]; then
    local i; i=$(python3 -c "import json;l=json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'));[print(t.get('status','?')+'|'+t.get('repo','?')+'|'+str(t.get('issue',''))[:60]) for m in l['modules'] for t in m['tasks'] if t.get('task_id')=='${tid}']" 2>/dev/null||echo "?|?|?")
    local ts="${i%%|*}"; local tr="${i#*|}"; local trepo="${tr%%|*}"; local tissue="${tr##*|}"
    lark_send "📋 ${tid}" "blue" $'📊 状态: '"${ts}"$'\n📦 仓库: '"${trepo}"$'\n🔗 Issue: '"${tissue}"
  else
    local s; s=$(python3 -c "import json;l=json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'));from collections import Counter;c=Counter(t['status'] for m in l['modules'] for t in m['tasks']);[print(k+': '+str(v)) for k,v in c.most_common(6)]" 2>/dev/null)
    lark_send "📋 任务概况" "blue" "${s}"
  fi
}

lark_query_mvp() {
  local m; m=$(python3 -c "import json,pathlib;l=json.loads((pathlib.Path('${DOCS_DIR}')/'docs/development/task-state-ledger.json').read_text());t=sum(len(m.get('tasks',[])) for m in l['modules']);d=sum(1 for m in l['modules'] for t in m.get('tasks',[]) if t.get('status') in ('completed','completed_with_skip'));print(str(d)+'/'+str(t)+' ('+str(round(d*100/max(t,1)))+'%)')" 2>/dev/null)
  local pct; pct=$(echo "${m}" | grep -oE '[0-9]+%' | head -1)
  local bar=""
  for i in $(seq 1 10); do
    if [[ $((i * 10)) -le "${pct%%%}" ]]; then bar="${bar}█"; else bar="${bar}░"; fi
  done
  lark_send "📊 MVP 进度" "blue" $'**'"${m}"$'**\n\n'"${bar}"$'\n\n━━━━━━━━━━━━━━━━━━━'
}

lark_query_overview() {
  local r; r=$(python3 -c "import json,pathlib;l=json.loads((pathlib.Path('${DOCS_DIR}')/'docs/development/task-state-ledger.json').read_text());from collections import Counter;c=Counter(t['status'] for m in l['modules'] for t in m['tasks']);t=sum(c.values());a=c.get('in_progress',0)+c.get('implementing',0)+c.get('ready',0)+c.get('partial',0);d=c.get('completed',0)+c.get('completed_with_skip',0);print(str(t)+'|'+str(a)+'|'+str(d)+'|'+str(c.get('blocked',0)))" 2>/dev/null)
  local total="${r%%|*}"; local r1="${r#*|}"; local active="${r1%%|*}"; local r2="${r1#*|}"; local done="${r2%%|*}"; local blocked="${r2##*|}"
  lark_send "📊 项目总览" "blue" $'📦 总任务: '"${total}"$'\n🔄 活跃: '"${active}"$'\n✅ 已完成: '"${done}"$'\n🚫 阻塞: '"${blocked}"
}

lark_query_submit_bug() {
  local t="${1:-}"; [[ -z "${t}" ]] && { lark_template_bug; return; }
  local u; u=$(gh issue create --repo "MyAiDevs/livemask-docs" --title "Bug: ${t:0:80}" --body "Lark 提交\n\n${t}" --label "bug" 2>/dev/null||echo "")
  if [[ -n "${u}" ]]; then lark_send "🐛 Bug 已创建" "yellow" $'**'"${t:0:100}"$'**\n\n✅ GitHub Issue 已创建\n'"${u}"; else lark_send "🐛 Bug 已记录" "yellow" $'**'"${t:0:100}"$'**\n\n(离线模式)'; fi
}

lark_query_submit_req() {
  local t="${1:-}"; [[ -z "${t}" ]] && { lark_template_requirement; return; }
  local u; u=$(gh issue create --repo "MyAiDevs/livemask-docs" --title "需求: ${t:0:80}" --body "Lark 提交\n\n${t}" --label "requirement" 2>/dev/null||echo "")
  if [[ -n "${u}" ]]; then lark_send "📋 需求已创建" "blue" $'**'"${t:0:100}"$'**\n\n✅ GitHub Issue 已创建\n'"${u}"; else lark_send "📋 需求已记录" "blue" $'**'"${t:0:100}"$'**\n\n(离线模式)'; fi
}

lark_query_submit_doc() {
  local t="${1:-}"; [[ -z "${t}" ]] && { lark_template_doc; return; }
  local u; u=$(gh issue create --repo "MyAiDevs/livemask-docs" --title "文档: ${t:0:80}" --body "Lark 提交\n\n${t}" --label "documentation" 2>/dev/null||echo "")
  if [[ -n "${u}" ]]; then lark_send "📝 文档已创建" "blue" $'**'"${t:0:100}"$'**\n\n✅ GitHub Issue 已创建\n'"${u}"; else lark_send "📝 文档已记录" "blue" $'**'"${t:0:100}"$'**\n\n(离线模式)'; fi
}
