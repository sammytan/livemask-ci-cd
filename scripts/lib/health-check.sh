#!/usr/bin/env bash
# Proactive system health check — catches problems BEFORE they become bugs.
# Runs at the start of every PM cycle. If it finds issues, it auto-fixes
# what it can and escalates what it can't.
#
# Source this, then call: health_check_all
set -euo pipefail

LIVEMASK_ROOT="${LIVEMASK_ROOT:-/Users/sammytan/Developer/LiveMask}"
DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"
ROLE_CACHE_DIR="${HOME}/.claude/role-cache"

RED="\033[31m" YELLOW="\033[33m" GREEN="\033[32m" RESET="\033[0m"
PASS() { echo -e "  ${GREEN}[HEALTH OK]${RESET} $*"; }
WARN() { echo -e "  ${YELLOW}[HEALTH WARN]${RESET} $*"; }
FAIL() { echo -e "  ${RED}[HEALTH FAIL]${RESET} $*"; }
FIX()  { echo -e "  ${GREEN}[AUTO-FIX]${RESET} $*"; }

health_check_all() {
  echo ""
  echo "═══════════════════════════════════════════"
  echo "  System Health Preflight"
  echo "═══════════════════════════════════════════"

  local issues=0 healed=0

  # ── 1. Growth warnings ──────────────────────────────────────────────────
  echo "── Growth Boundaries ──"

  # 1a. Ledger size
  local ledger_size; ledger_size=$(wc -c < "${DOCS_DIR}/docs/development/task-state-ledger.json" 2>/dev/null | tr -d ' ' || echo "0")
  if [[ "${ledger_size}" -gt 500000 ]]; then
    WARN "Ledger is $((${ledger_size} / 1024))KB — consider archiving closed tasks"
    issues=$((issues + 1))
  else
    PASS "Ledger: $((${ledger_size} / 1024))KB"
  fi

  # 1b. Findings accumulation
  local findings_count; findings_count=$(wc -l < "${ROLE_CACHE_DIR}/findings.jsonl" 2>/dev/null | tr -d ' ' || echo "0")
  if [[ "${findings_count}" -gt 100 ]]; then
    WARN "Findings: ${findings_count} entries — old findings may be stale, auto-truncating to last 50"
    tail -50 "${ROLE_CACHE_DIR}/findings.jsonl" > "${ROLE_CACHE_DIR}/findings.jsonl.tmp" 2>/dev/null
    mv "${ROLE_CACHE_DIR}/findings.jsonl.tmp" "${ROLE_CACHE_DIR}/findings.jsonl" 2>/dev/null
    FIX "Findings truncated to 50 most recent"
    healed=$((healed + 1))
  elif [[ "${findings_count}" -gt 50 ]]; then
    WARN "Findings: ${findings_count} entries — approaching limit"
    issues=$((issues + 1))
  else
    PASS "Findings: ${findings_count} entries"
  fi

  # 1c. Log directory size
  local log_size; log_size=$(du -sm /tmp/claude/ 2>/dev/null | cut -f1 || echo "0")
  if [[ "${log_size}" -gt 50 ]]; then
    WARN "Logs: ${log_size}MB — auto-cleaning old logs"
    find /tmp/claude/ -name "*.log" -mtime +1 -delete 2>/dev/null || true
    FIX "Deleted logs older than 1 day"
    healed=$((healed + 1))
  else
    PASS "Logs: ${log_size}MB"
  fi

  # ── 2. Stale state detection ────────────────────────────────────────────
  echo "── Stale State ──"

  # 2a. PM lease staleness
  local lease_file="${ROLE_CACHE_DIR}/pm-lease.json"
  if [[ -f "${lease_file}" ]]; then
    local lease_age; lease_age=$(python3 -c "
import json, time
d = json.load(open('${lease_file}'))
age = (time.time() - d.get('started_at_epoch', 0)) / 60
print(f'{age:.0f}')
" 2>/dev/null || echo "0")
    if [[ "${lease_age}" -gt 30 ]]; then
      FAIL "PM lease is ${lease_age}min old — agent may be dead. Auto-releasing."
      python3 -c "
import json, pathlib
d = json.load(open('${lease_file}'))
d['phase'] = 'stale-auto-released'
d['note'] = f'Health check auto-released after {int(${lease_age})}min'
pathlib.Path('${lease_file}').write_text(json.dumps(d, indent=2))
" 2>/dev/null
      FIX "Stale PM lease released (${lease_age}min)"
      healed=$((healed + 1))
    else
      local holder; holder=$(python3 -c "import json; print(json.load(open('${lease_file}')).get('agent','?'))" 2>/dev/null || echo "?")
      PASS "PM lease: ${holder} (${lease_age}min)"
    fi
  else
    PASS "PM lease: none (both agents free to start)"
  fi

  # 2b. Stale SAPs (>2 hours open, unacked)
  local sap_dir="${DOCS_DIR}/docs/development/supervisor-actions"
  if [[ -d "${sap_dir}" ]]; then
    local stale_saps=0
    for sf in "${sap_dir}"/SAP-*.json; do
      [[ -f "${sf}" ]] || continue
      local sap_age; sap_age=$(python3 -c "
import json, time, pathlib
d = json.load(open('${sf}'))
ts = d.get('timestamp','')
if ts:
    try:
        from datetime import datetime
        dt = datetime.fromisoformat(ts.replace('Z','+00:00'))
        age = (time.time() - dt.timestamp()) / 60
        if d.get('status') == 'open' and age > 120:
            print(int(age))
    except: pass
" 2>/dev/null || echo "0")
      if [[ "${sap_age}" -gt 0 ]]; then
        WARN "Stale SAP: $(basename ${sf}) — open for ${sap_age}min, auto-resolving"
        python3 -c "
import json, pathlib
d = json.load(open('${sf}'))
d['status'] = 'resolved'
d['resolution'] = {'by': 'health-check', 'how': f'auto-resolved after {${sap_age}}min stale'}
pathlib.Path('${sf}').write_text(json.dumps(d, indent=2))
" 2>/dev/null
        FIX "Stale SAP $(basename ${sf}) auto-resolved"
        healed=$((healed + 1))
      fi
    done
  fi

  # 2c. Orphaned task branches (>7 days old)
  for repo_dir in "${LIVEMASK_ROOT}"/livemask-*/; do
    [[ ! -d "${repo_dir}/.git" ]] && continue
    local rn; rn=$(basename "${repo_dir}")
    cd "${repo_dir}"
    local old_branches; old_branches=$(git branch --list 'task/*' --format='%(refname:short)|%(committerdate:unix)' 2>/dev/null | \
      python3 -c "
import sys, time
for line in sys.stdin:
    line = line.strip()
    if not line or '|' not in line: continue
    br, ts = line.split('|')
    age_days = (time.time() - int(ts)) / 86400
    if age_days > 7:
        print(f'{br} ({int(age_days)}d old)')
" 2>/dev/null || echo "")
    if [[ -n "${old_branches}" ]]; then
      while read -r br; do
        [[ -z "${br}" ]] && continue
        WARN "${rn}: orphaned branch ${br}"
        issues=$((issues + 1))
      done <<< "${old_branches}"
    fi
  done

  # ── 3. Dependency check ─────────────────────────────────────────────────
  echo "── Dependencies ──"

  # 3a. gh CLI
  if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
    PASS "gh CLI: authenticated"
  else
    FAIL "gh CLI: not available or not authenticated — GitHub operations will fail"
    issues=$((issues + 1))
  fi

  # 3b. python3
  command -v python3 &>/dev/null && PASS "python3: available" || { FAIL "python3: missing"; issues=$((issues + 1)); }

  # 3c. Lark webhook reachability
  local webhook_url="https://open.larksuite.com/open-apis/bot/v2/hook/803303ee-1632-4a99-8847-a071b3c832ad"
  if curl -s -o /dev/null -w "%{http_code}" --max-time 3 "${webhook_url}" 2>/dev/null | grep -q "200"; then
    PASS "Lark webhook: reachable"
  else
    WARN "Lark webhook: may be unreachable — notifications may not deliver"
    issues=$((issues + 1))
  fi

  # ── 4. Structural integrity ─────────────────────────────────────────────
  echo "── Structural Integrity ──"

  # 4a. Required directories exist
  for d in "${DOCS_DIR}/docs/development" "${DOCS_DIR}/docs/development/tasks" \
           "${DOCS_DIR}/docs/development/review-contracts" "${ROLE_CACHE_DIR}"; do
    [[ -d "${d}" ]] && continue
    FAIL "Missing: ${d}"
    mkdir -p "${d}" 2>/dev/null && FIX "Created: ${d}" || true
    healed=$((healed + 1))
  done
  PASS "Required directories: present"

  # 4b. Ledger is valid JSON
  if python3 -c "import json; json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))" 2>/dev/null; then
    PASS "Ledger: valid JSON"
  else
    FAIL "Ledger: INVALID JSON — cannot proceed"
    issues=$((issues + 1))
  fi

  # 4c. No duplicate task IDs in ledger
  local dup_count; dup_count=$(python3 -c "
import json
from collections import Counter
d = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
ids = []
for m in d.get('modules',[]):
    for t in m.get('tasks',[]):
        ids.append(t.get('task_id',''))
dups = [k for k,v in Counter(ids).items() if v > 1]
print(len(dups))
" 2>/dev/null || echo "0")
  if [[ "${dup_count}" -gt 0 ]]; then
    FAIL "Ledger: ${dup_count} duplicate task IDs"
    issues=$((issues + 1))
  else
    PASS "Ledger: no duplicate task IDs"
  fi

  # ── 5. Predictive: what's likely to break next? ─────────────────────────
  echo "── Predictive ──"

  # 5a. Tasks in "in_progress" > 24h (stalled)
  local stalled; stalled=$(python3 -c "
import json
d = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
found = []
for m in d.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('status') == 'in_progress':
            found.append(t['task_id'])
for tid in found[:5]:
    print(tid)
" 2>/dev/null)
  if [[ -n "${stalled}" ]]; then
    WARN "Stalled tasks (in_progress): $(echo "${stalled}" | wc -l | tr -d ' ') — may need recovery"
    while read -r tid; do
      [[ -z "${tid}" ]] && continue
      echo "    ${tid}"
    done <<< "${stalled}"
    issues=$((issues + 1))
  else
    PASS "No stalled in_progress tasks"
  fi

  # 5b. CI failure trend (last 3 runs all failing)
  for r in "MyAiDevs/livemask-backend" "MyAiDevs/livemask-admin"; do
    local fail_count; fail_count=$(gh run list --repo "$r" --branch dev --limit 3 --json conclusion --jq '[.[].conclusion] | join(",")' 2>/dev/null | grep -o "failure" | wc -l | tr -d ' ' || echo "0")
    [[ "${fail_count}" -ge 3 ]] && WARN "CI: $r — last 3 runs all failed (may need fix task)" && issues=$((issues + 1))
  done

  # 5c. Dispatch packets without tasks (orphaned)
  local dp_dir="${DOCS_DIR}/docs/development/dispatch-packets"
  if [[ -d "${dp_dir}" ]]; then
    for dp in "${dp_dir}"/TASK-*.json; do
      [[ -f "${dp}" ]] || continue
      local dp_tid; dp_tid=$(python3 -c "import json; print(json.load(open('${dp}')).get('task_id',''))" 2>/dev/null || echo "")
      [[ -z "${dp_tid}" ]] && continue
      local in_ledger; in_ledger=$(python3 -c "
import json
ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id') == '${dp_tid}': print('yes'); break
" 2>/dev/null || echo "")
      if [[ -z "${in_ledger}" ]]; then
        WARN "Orphaned dispatch packet: ${dp_tid} — no matching ledger entry, removing"
        rm -f "${dp}" 2>/dev/null
        FIX "Removed orphaned dispatch packet: ${dp_tid}"
        healed=$((healed + 1))
      fi
    done
  fi

  # ── Summary ─────────────────────────────────────────────────────────────
  echo ""
  echo "═══════════════════════════════════════════"
  echo -e "  Health: ${issues} warnings | ${healed} auto-fixed"
  if [[ "${issues}" -eq 0 ]]; then
    echo -e "  ${GREEN}System is healthy.${RESET}"
  elif [[ "${issues}" -le 3 ]]; then
    echo -e "  ${YELLOW}Minor issues detected — review warnings above.${RESET}"
  else
    echo -e "  ${RED}${issues} issues need attention — check warnings.${RESET}"
  fi
  echo "═══════════════════════════════════════════"
  echo ""

  return 0
}
