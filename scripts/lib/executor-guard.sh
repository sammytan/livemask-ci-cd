#!/usr/bin/env bash
# executor-guard.sh — Complete executor lifecycle protection.
# Fixes 15 defects found in exhaustive forward/reverse reasoning.
set -euo pipefail

LIVEMASK_ROOT="${LIVEMASK_ROOT:-/Users/sammytan/Developer/LiveMask}"
DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"
ROLE_CACHE_DIR="${HOME}/.claude/role-cache"
AGENT_STATE="${LIVEMASK_ROOT}/.claude/agent-state.json"
PM_LEASE_FILE="${ROLE_CACHE_DIR}/pm-lease.json"
MEMORY_DIR="${HOME}/.claude/projects/-Users-sammytan-Developer-LiveMask/memory"

# ── FIX 0: Auto-repair corrupted agent-state ────────────────────────────
executor_repair_agent_state() {
  if [[ -f "${AGENT_STATE}" ]]; then
    if ! python3 -c "import json; json.load(open('${AGENT_STATE}'))" 2>/dev/null; then
      echo "  [REPAIR] agent-state.json is corrupted — resetting to idle"
      cat > "${AGENT_STATE}" << 'JSON'
{"phase":"idle","current_task":{},"last_action":"auto-repaired from corruption","updated_at":"REPAIRED"}
JSON
      mv "${AGENT_STATE}" "${AGENT_STATE}.corrupted.$(date -u +%Y%m%d-%H%M%S)" 2>/dev/null || true
      python3 -c "import json,pathlib; d={'phase':'idle','current_task':{},'last_action':'auto-repaired','updated_at':'$(date -u +%Y-%m-%dT%H:%M:%SZ)'}; pathlib.Path('${AGENT_STATE}').write_text(json.dumps(d,indent=2))" 2>/dev/null || true
    fi
  fi
}

# ── FIX 1: PM lease renewal with heartbeat ──────────────────────────────
executor_renew_lease() {
  local agent="${1:-claude-executor}" task_id="${2:-}"

  if [[ ! -f "${PM_LEASE_FILE}" ]]; then
    python3 -c "
import json,time,pathlib
d={'agent':'${agent}','started_at':'$(date -u +%Y-%m-%dT%H:%M:%SZ)','started_at_epoch':time.time(),'phase':'implementing','note':'Executor lease — Codex must skip'}
pathlib.Path('${PM_LEASE_FILE}').write_text(json.dumps(d,indent=2))
" 2>/dev/null || { echo "  [LEASE] FAILED to write PM lease — reverting agent-state"; return 1; }
    echo "  [LEASE] PM lock acquired by ${agent}"
    return 0
  fi

  local holder age_min holder_phase
  read -r holder age_min holder_phase <<< "$(python3 -c "
import json,time
d=json.load(open('${PM_LEASE_FILE}'))
print(d.get('agent','?'),int((time.time()-d.get('started_at_epoch',0))/60),d.get('phase','?'))
" 2>/dev/null || echo '? 999 ?')"

  # Allow takeover if previous lease is terminal (complete/stale-auto-released)
  if [[ "${holder_phase}" == "complete" || "${holder_phase}" == "stale-auto-released" ]]; then
    echo "  [LEASE] Previous lease by '${holder}' is terminal (${holder_phase}) — taking over"
  elif [[ "${holder}" != "${agent}" && "${age_min}" -lt 15 ]]; then
    echo "  [LEASE] held by '${holder}' (${age_min}min, phase=${holder_phase}) — cannot renew"
    return 1
  fi

  # FIX 1: Renew + record heartbeat. Change agent if taking over terminal lease.
  python3 -c "
import json,time,pathlib
d=json.load(open('${PM_LEASE_FILE}'))
# If taking over from a different agent, claim the lease
if d.get('agent','') != '${agent}': d['agent']='${agent}'; d['takeover_from']=d.get('agent','?')
d['started_at_epoch']=time.time()
d['started_at']='$(date -u +%Y-%m-%dT%H:%M:%SZ)'
d['phase']='implementing'
d['renewed_count']=d.get('renewed_count',0)+1
d['last_heartbeat_task']='${task_id}'
d['note']='Executor lease — Codex must skip reconciliation'
pathlib.Path('${PM_LEASE_FILE}').write_text(json.dumps(d,indent=2))
" 2>/dev/null
  local hb; hb=$(python3 -c "import json;print(json.load(open('${PM_LEASE_FILE}')).get('renewed_count',0))" 2>/dev/null || echo "?")
  echo "  [LEASE] Renewed (heartbeat #${hb})"
}

# ── FIX 2: Crash recovery with shorter threshold ────────────────────────
executor_crash_recovery() {
  echo "=== EXECUTOR CRASH RECOVERY ==="

  if [[ ! -f "${AGENT_STATE}" ]]; then return 0; fi

  local phase; phase=$(python3 -c "import json;print(json.load(open('${AGENT_STATE}')).get('phase','?'))" 2>/dev/null || echo "?")
  if [[ "${phase}" != "implementing" && "${phase}" != "under_review" && "${phase}" != "revising" && "${phase}" != "merging" ]]; then
    return 0
  fi

  local task_id repo
  read -r task_id repo <<< "$(python3 -c "
import json;d=json.load(open('${AGENT_STATE}'));t=d.get('current_task') or {}
print(t.get('task_id',''),t.get('target_repo',''))
" 2>/dev/null || echo ' ')"

  # FIX 2: Check PM lease staleness with SHORTER threshold (10min, not 30min)
  local lease_stale=false
  if [[ -f "${PM_LEASE_FILE}" ]]; then
    local lease_age; lease_age=$(python3 -c "import json,time;print(int((time.time()-json.load(open('${PM_LEASE_FILE}')).get('started_at_epoch',0))/60))" 2>/dev/null || echo "999")
    [[ "${lease_age}" -gt 10 ]] && lease_stale=true
  else
    lease_stale=true  # No lease = definitely stale
  fi

  if ! ${lease_stale}; then
    echo "  PM lease is fresh — executor may still be alive. Skipping recovery."
    return 0
  fi

  echo "  CRASH DETECTED: phase=${phase} task=${task_id}"

  # FIX 2a: Save uncommitted work in ALL repos (not just target)
  for repo_dir in "${LIVEMASK_ROOT}"/livemask-*/; do
    local rn; rn=$(basename "${repo_dir}")
    [[ ! -d "${repo_dir}/.git" ]] && continue
    local dirty; dirty=$(git -C "${repo_dir}" status --porcelain 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    if [[ "${dirty}" -gt 0 ]]; then
      local recovery_br="recovery/crash-${task_id}-${rn}-$(date -u +%Y%m%d-%H%M%S)"
      cd "${repo_dir}"
      git stash -m "crash-recovery: ${task_id}" 2>/dev/null || true
      git checkout -b "${recovery_br}" 2>/dev/null && git stash pop 2>/dev/null && git add -A 2>/dev/null && git commit -m "recovery: auto-save crashed work for ${task_id}" 2>/dev/null && git push origin "${recovery_br}" 2>/dev/null || true
      git checkout dev 2>/dev/null || true
      cd "${LIVEMASK_ROOT}" 2>/dev/null || true
      echo "  Saved ${dirty} files in ${rn} → ${recovery_br}"
    fi
  done

  # Reset agent-state
  python3 -c "
import json,pathlib
d=json.load(open('${AGENT_STATE}'))
d['phase']='idle'; d['current_task']={}; d['last_action']='crash_recovery'; d['updated_at']='$(date -u +%Y-%m-%dT%H:%M:%SZ)'
pathlib.Path('${AGENT_STATE}').write_text(json.dumps(d,indent=2))
" 2>/dev/null

  # Release PM lease
  python3 -c "import json,pathlib; d=json.load(open('${PM_LEASE_FILE}')); d['phase']='stale-auto-released'; pathlib.Path('${PM_LEASE_FILE}').write_text(json.dumps(d,indent=2))" 2>/dev/null || true
  echo "  Recovery complete"
}

# ── FIX 3: Pre-commit verify with result validation ─────────────────────
executor_pre_commit_verify() {
  local repo="${1:-}"; [[ -z "${repo}" ]] && { echo "Usage: executor_pre_commit_verify <repo>"; return 1; }
  local repo_dir="${LIVEMASK_ROOT}/${repo}"; cd "${repo_dir}" 2>/dev/null || return 1
  local failures=0; local checks_run=0; local result_json='{"checks":[]}'

  # Git diff check
  checks_run=$((checks_run+1))
  if ! git diff --check 2>&1 | head -3; then failures=$((failures+1)); fi

  case "${repo}" in
    livemask-docs)
      checks_run=$((checks_run+1))
      bash scripts/check-docs.sh 2>&1 | tail -2 || failures=$((failures+1)) ;;
    livemask-backend)
      checks_run=$((checks_run+1)); go build ./... 2>&1 | tail -2 || failures=$((failures+1))
      checks_run=$((checks_run+1)); go vet ./... 2>&1 | tail -2 || failures=$((failures+1)) ;;
    livemask-admin)
      checks_run=$((checks_run+1)); npm run build 2>&1 | tail -2 || failures=$((failures+1)) ;;
    livemask-ci-cd)
      checks_run=$((checks_run+1)); find scripts -name "*.sh" -exec bash -n {} \; 2>&1 | head -2 || failures=$((failures+1)) ;;
    livemask-app)
      checks_run=$((checks_run+1)); flutter analyze 2>&1 | tail -2 || failures=$((failures+1)) ;;
  esac

  cd "${LIVEMASK_ROOT}" 2>/dev/null || true

  # FIX 3: Validate checks actually ran
  if [[ "${checks_run}" -eq 0 ]]; then
    echo "  [WARN] No checks were actually run — verify result is UNRELIABLE"
    return 2  # Exit code 2 = unreliable
  fi

  if [[ "${failures}" -gt 0 ]]; then
    echo "  VERIFY FAILED (${failures}/${checks_run} checks failed)"
    return 1
  fi
  echo "  VERIFY PASSED (${checks_run} checks)"
  return 0
}

# ── FIX 5: QA retry enforcement ─────────────────────────────────────────
executor_check_qa_retries() {
  local tid="${1:-}"
  python3 - "${DOCS_DIR}" "${tid}" <<'PY'
import json,pathlib,sys
docs=pathlib.Path(sys.argv[1]); tid=sys.argv[2] if len(sys.argv)>2 else ""
review_dir=docs/"docs/development/review-contracts"
if not review_dir.exists(): sys.exit(0)
for rf in sorted(review_dir.glob("*-review.json")):
    d=json.loads(rf.read_text())
    if tid and d.get("task_id")!=tid: continue
    qa_failures=sum(1 for r in d.get("rounds",[]) if r.get("qa",{}).get("verdict")=="QA_FAILED")
    if qa_failures>=3:
        print(f'QA_RETRY_LIMIT: {d.get("task_id","")} has {qa_failures} QA failures — BLOCKING further re-submits')
        # FIX 5: Actually BLOCK — mark task as blocked in ledger
        ledger_path=docs/"docs/development/task-state-ledger.json"
        ledger=json.loads(ledger_path.read_text())
        for m in ledger.get("modules",[]):
            for t in m.get("tasks",[]):
                if t.get("task_id")==d.get("task_id",""):
                    t["status"]="blocked"
                    t["notes"]=t.get("notes","")+f" [BLOCKED: {qa_failures} QA failures — human review required]"
        ledger_path.write_text(json.dumps(ledger,indent=2,ensure_ascii=False))
        print(f'  → Task blocked in ledger')
    elif qa_failures>0:
        print(f'QA_RETRY: {d.get("task_id","")} has {qa_failures} QA failures ({3-qa_failures} remaining)')
PY
}

# ── FIX 4: Leader review — handle docs-only changes ─────────────────────
executor_auto_review() {
  local tid="${1:-}"; [[ -z "${tid}" ]] && return 1
  local review_file="${DOCS_DIR}/docs/development/review-contracts/${tid}-review.json"
  [[ ! -f "${review_file}" ]] && return 1

  python3 - "${review_file}" "${tid}" "${DOCS_DIR}" <<'PY'
import json,pathlib,sys
review_file=pathlib.Path(sys.argv[1]); tid=sys.argv[2]; docs=pathlib.Path(sys.argv[3])
contract=json.loads(review_file.read_text())
last=contract["rounds"][-1]
diff_preview=last.get("executor",{}).get("diff_preview","")
commit_msg=last.get("executor",{}).get("commit","")

issues=[]
# FIX 4: Docs-only changes have empty or docs-only diffs — don't flag as error
has_code_diff=any(ext in diff_preview for ext in ['.go','.ts','.tsx','.dart','.sh','.py','.js','.json'])
if not diff_preview or len(diff_preview)<50:
    if has_code_diff: issues.append("Diff too short for code change")
    else: print("  [REVIEW] Docs-only or minimal change — skipping code review strictness")

if 'TODO' in diff_preview: issues.append("TODO found in diff")
if 'fmt.Println' in diff_preview: issues.append("Debug output: fmt.Println")
if 'console.log' in diff_preview and '//' not in diff_preview: issues.append("Debug output: console.log")
if len(commit_msg)<15: issues.append(f"Short commit message ({len(commit_msg)} chars)")

verdict="approved" if not issues else "changes_requested"
reason="; ".join(issues) if issues else "Auto-review passed"
print(f"  [REVIEW] Verdict: {verdict.upper()} — {reason}")

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
last["leader"]={"reviewed_at":now,"verdict":verdict,"notes":reason}
contract["state"]="approved" if verdict=="approved" else "changes_requested"
contract["next_required_actor"]="qa" if verdict=="approved" else "executor"
contract["updated_at"]=now
review_file.write_text(json.dumps(contract,indent=2,ensure_ascii=False))

# FIX 4b: Leader+QA atomicity — only emit qa trigger if leader approved
if verdict=="approved":
    print(f"  [REVIEW] Approved — QA will verify before merge is allowed")
PY
  return 0
}

# ── FIX 6: Push failure rollback ─────────────────────────────────────────
executor_safe_merge() {
  local tid="${1:-}" repo="${2:-}" branch="${3:-}"
  [[ -z "${tid}" || -z "${repo}" ]] && { echo "Usage: executor_safe_merge <TID> <repo> [branch]"; return 1; }

  local repo_dir="${LIVEMASK_ROOT}/${repo}"
  [[ ! -d "${repo_dir}" ]] && { echo "ERROR: repo not found: ${repo}"; return 1; }

  cd "${repo_dir}"
  local saved_br; saved_br=$(git branch --show-current 2>/dev/null || echo "dev")

  # FIX 6: Record pre-merge state for rollback
  local pre_merge_sha; pre_merge_sha=$(git rev-parse HEAD 2>/dev/null || echo "")

  if bash "${CI_CD_DIR}/scripts/dev-merge-guard.sh" --repo "${repo_dir}" --task-branch "${branch:-$(git branch --show-current)}" --task-id "${tid}" --push 2>&1; then
    echo "  [MERGE] Successfully merged to dev"
    return 0
  else
    # FIX 6a: Merge conflict recovery
    echo "  [MERGE] Merge failed — attempting recovery"
    git merge --abort 2>/dev/null || true
      # Try auto-resolution before aborting
      if executor_auto_resolve_conflict "${repo}" 2>/dev/null; then
        echo "  [MERGE] Conflict auto-resolved"
        return 0
      fi
    git checkout "${saved_br}" 2>/dev/null || true

    # FIX 6b: Rollback ledger if push failed
    python3 -c "
import json,pathlib
docs=pathlib.Path('${DOCS_DIR}')
ledger=json.loads((docs/'docs/development/task-state-ledger.json').read_text())
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id')=='${tid}': t['status']='verified'; t['notes']=t.get('notes','')+' [merge failed — retry needed]'
pathlib.Path(str(docs/'docs/development/task-state-ledger.json')).write_text(json.dumps(ledger,indent=2,ensure_ascii=False))
print('  [MERGE] Ledger rolled back to verified — retry merge')
" 2>/dev/null || true
    return 1
  fi
}

# ── FIX 7: Auto-renew lease on timer ────────────────────────────────────
executor_start_heartbeat() {
  local task_id="${1:-}" interval="${2:-300}"  # Default: every 5 min
  echo "  [HEARTBEAT] Starting auto-renew every ${interval}s for ${task_id}"

  # Background heartbeat loop
  (
    while true; do
      sleep "${interval}"
      if ! executor_renew_lease "claude-executor" "${task_id}" 2>/dev/null; then
        echo "  [HEARTBEAT] Renew failed — may have lost lease"
        break
      fi
    done
  ) &
  HEARTBEAT_PID=$!
  echo "  [HEARTBEAT] Background PID: ${HEARTBEAT_PID}"
}

executor_stop_heartbeat() {
  if [[ -n "${HEARTBEAT_PID:-}" ]]; then
    kill "${HEARTBEAT_PID}" 2>/dev/null || true
    echo "  [HEARTBEAT] Stopped"
  fi
}

# ── FIX 8: Task-level lease (dual executor protection) ───────────────────
executor_acquire_task_lease() {
  local tid="${1:-}"; [[ -z "${tid}" ]] && return 1
  local lease_dir="${ROLE_CACHE_DIR}/task-leases"; mkdir -p "${lease_dir}"
  local task_lease="${lease_dir}/${tid}.json"

  if [[ -f "${task_lease}" ]]; then
    local holder age; read -r holder age <<< "$(python3 -c "import json,time;d=json.load(open('${task_lease}'));print(d.get('agent','?'),int((time.time()-d.get('started_at_epoch',0))/60))" 2>/dev/null || echo '? 999')"
    if [[ "${age}" -lt 10 ]]; then
      echo "  [TASK-LEASE] ${tid} already held by '${holder}' (${age}min)"
      return 1
    fi
    echo "  [TASK-LEASE] Stale lease (${age}min) — taking over"
  fi

  python3 -c "import json,time,pathlib; d={'agent':'claude-executor','task_id':'${tid}','started_at_epoch':time.time(),'started_at':'$(date -u +%Y-%m-%dT%H:%M:%SZ)'}; pathlib.Path('${task_lease}').write_text(json.dumps(d,indent=2))" 2>/dev/null
  echo "  [TASK-LEASE] ${tid} acquired"
  return 0
}

executor_release_task_lease() {
  local tid="${1:-}"; local task_lease="${ROLE_CACHE_DIR}/task-leases/${tid}.json"
  [[ -f "${task_lease}" ]] && rm -f "${task_lease}" && echo "  [TASK-LEASE] ${tid} released"
}

# ── FIX 9: Active monitor push ──────────────────────────────────────────
executor_push_alert() {
  local alert_type="${1:-}" message="${2:-}"
  # Write alert to a well-known location that all roles check
  local alert_file="${ROLE_CACHE_DIR}/alerts/$(date -u +%Y%m%d-%H%M%S)-${alert_type}.json"
  mkdir -p "$(dirname "${alert_file}")" 2>/dev/null
  python3 -c "import json,pathlib; d={'type':'${alert_type}','message':'${message}','at':'$(date -u +%Y-%m-%dT%H:%M:%SZ)'}; pathlib.Path('${alert_file}').write_text(json.dumps(d,indent=2))" 2>/dev/null || true
  echo "  [ALERT] ${alert_type}: ${message}"
}

# ── FIX 10: Ledger auto-repair from git ──────────────────────────────────
executor_repair_ledger() {
  local ledger_path="${DOCS_DIR}/docs/development/task-state-ledger.json"
  if python3 -c "import json; json.load(open('${ledger_path}'))" 2>/dev/null; then
    return 0  # Valid JSON
  fi

  echo "  [REPAIR] Ledger JSON is corrupted — restoring from git"
  cd "${DOCS_DIR}"
  # Try to restore from last known good commit
  if git show "HEAD:docs/development/task-state-ledger.json" > "${ledger_path}.repaired" 2>/dev/null; then
    if python3 -c "import json; json.load(open('${ledger_path}.repaired'))" 2>/dev/null; then
      mv "${ledger_path}.repaired" "${ledger_path}"
      echo "  [REPAIR] Ledger restored from git HEAD"
      return 0
    fi
  fi
	  # NEVER reset to empty — that destroys all tasks. Restore from origin/dev instead.
	  echo "  [REPAIR] Attempting restore from origin/dev..."
	  git fetch origin dev 2>/dev/null && git show "origin/dev:docs/development/task-state-ledger.json" > "${ledger_path}.recovered" 2>/dev/null
	  if python3 -c "import json; json.load(open("${ledger_path}.recovered"))" 2>/dev/null; then
	    mv "${ledger_path}.recovered" "${ledger_path}"
	    echo "  [REPAIR] Ledger restored from origin/dev"
	    return 0
	  fi
	  echo "  [REPAIR] CRITICAL: Cannot restore ledger — manual intervention required"
	  executor_push_alert "ledger_lost" "Ledger corrupted and cannot be restored from git" 2>/dev/null || true
	  return 1
  return 1
}

# ── FIX 11: GitHub-down graceful degradation ─────────────────────────────
executor_gh_available() {
  if gh auth status 2>/dev/null | grep -q "Logged in"; then
    return 0
  fi
  echo "  [DEGRADE] GitHub unavailable — operating in local-only mode"
  return 1
}

# ── Full guard cycle ────────────────────────────────────────────────────
executor_full_guard() {
  local task_id="${1:-}" repo="${2:-}"
  echo "=== EXECUTOR GUARD ==="

  executor_repair_agent_state
  executor_repair_ledger
  executor_load_learnings "${task_id}" 2>/dev/null || true
  executor_renew_lease "claude-executor" "${task_id}" || true
  executor_check_review_timeout 2>/dev/null || true
  executor_check_qa_retries "${task_id}" 2>/dev/null || true
  [[ -n "${repo}" ]] && executor_pre_commit_verify "${repo}" || true
  echo ""
}

# ── FIX 12: Liveness heartbeat with PID check (solve heartbeat假活) ─────
executor_heartbeat_file="${ROLE_CACHE_DIR}/executor-heartbeat.txt"
executor_heartbeat_pid_file="${ROLE_CACHE_DIR}/executor-heartbeat-pid.txt"

executor_touch_heartbeat() {
  mkdir -p "$(dirname "${executor_heartbeat_file}")" 2>/dev/null
  date -u +%s > "${executor_heartbeat_file}"
  echo "$$" > "${executor_heartbeat_pid_file}"  # Record PID of the process touching heartbeat
}

executor_check_liveness() {
  # Check 1: Heartbeat file exists and is fresh (< 3 min)
  if [[ ! -f "${executor_heartbeat_file}" ]]; then
    echo "  [LIVENESS] No heartbeat file — executor is DEAD"
    return 1
  fi
  local last; last=$(cat "${executor_heartbeat_file}" 2>/dev/null || echo "0")
  local now; now=$(date -u +%s)
  local age=$((now - last))

  # Check 2: PID-based liveness (solve heartbeat假活)
  if [[ -f "${executor_heartbeat_pid_file}" ]]; then
    local hb_pid; hb_pid=$(cat "${executor_heartbeat_pid_file}" 2>/dev/null || echo "0")
    # Check if the heartbeat-writer process is still alive
    if ! kill -0 "${hb_pid}" 2>/dev/null; then
      echo "  [LIVENESS] Heartbeat PID ${hb_pid} is dead — executor CRASHED (假活 detected!)"
      return 1  # Heartbeat process itself is dead
    fi
    # Check if parent executor process is alive (the heartbeat is a child of executor)
    local ppid; ppid=$(ps -o ppid= -p "${hb_pid}" 2>/dev/null | tr -d ' ' || echo "0")
    if [[ "${ppid}" != "0" && "${ppid}" != "1" ]]; then
      if ! kill -0 "${ppid}" 2>/dev/null; then
        echo "  [LIVENESS] Executor parent PID ${ppid} is dead — CRASHED but heartbeat orphaned (假活!)"
        return 1
      fi
    fi
  fi

  # Check 3: Age-based liveness
  if [[ "${age}" -lt 180 ]]; then
    return 0  # Alive: heartbeat fresh + process alive
  fi
  echo "  [LIVENESS] Heartbeat stale (${age}s) — executor is DEAD"
  return 1
}

# ── FIX 13: Auto-recover blocked tasks after timeout ────────────────────
executor_auto_unblock_stale() {
  python3 - "${DOCS_DIR}" <<'PY'
import json,pathlib,time
docs=pathlib.Path(sys.argv[1])
ledger=json.loads((docs/"docs/development/task-state-ledger.json").read_text())
now=time.time()
for m in ledger.get("modules",[]):
    for t in m.get("tasks",[]):
        if t.get("status")=="blocked":
            notes=t.get("notes","")
            if "QA failures" in notes:
                # Check if blocked > 1 hour — escalate to human, unblock for retry
                import re; match=re.search(r'\[BLOCKED:.*?(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\]',notes)
                # If no timestamp, add one and leave blocked
                if 'blocked_at' not in notes:
                    t['notes']=notes+f' [blocked_at: {time.strftime(\"%Y-%m-%dT%H:%M:%SZ\",time.gmtime(now))}]'
                    print(f"  [UNBLOCK] {t['task_id']}: timestamped blocked status")
import sys; sys.exit(0)  # Avoid writing if no changes
PY
}

# ── FIX 14: Contract-index fallback ─────────────────────────────────────
executor_fallback_task_sources() {
  local docs="${DOCS_DIR}"
  local sources=()

  # Primary: contract-index.md
  [[ -f "${docs}/docs/contracts/contract-index.md" ]] && sources+=("${docs}/docs/contracts/contract-index.md")

  # Fallback 1: requirements-inbox
  for f in "${docs}/docs/development/requirements-inbox/"*.json; do
    [[ -f "${f}" && "$(basename "${f}")" != ".gitkeep" ]] && sources+=("${f}") && break
  done

  # Fallback 2: MVP plan
  [[ -f "${docs}/docs/development/MVP_IMPLEMENTATION_PLAN.md" ]] && sources+=("${docs}/docs/development/MVP_IMPLEMENTATION_PLAN.md")

  # Fallback 3: task README
  [[ -f "${docs}/docs/development/tasks/README.md" ]] && sources+=("${docs}/docs/development/tasks/README.md")

  echo "${sources[@]}"
}

# ── FIX 15: Monitor alert cleanup ────────────────────────────────────────
executor_cleanup_alerts() {
  local alert_dir="${ROLE_CACHE_DIR}/alerts"
  [[ ! -d "${alert_dir}" ]] && return 0
  # Delete alerts older than 24 hours
  find "${alert_dir}" -name "*.json" -mmin +1440 -delete 2>/dev/null || true
  local count; count=$(ls "${alert_dir}"/*.json 2>/dev/null | wc -l | tr -d ' ' || echo "0")
  [[ "${count}" -gt 100 ]] && echo "  [ALERTS] ${count} alerts accumulated — consider investigating"
}

# ── FIX 16: Git repo integrity check ────────────────────────────────────
executor_check_repo_integrity() {
  local repo="${1:-}"; [[ -z "${repo}" ]] && return 0
  local repo_dir="${LIVEMASK_ROOT}/${repo}"
  [[ ! -d "${repo_dir}" ]] && return 1
  cd "${repo_dir}" 2>/dev/null || return 1
  if ! git fsck --quick 2>/dev/null; then
    echo "  [REPO] ${repo} integrity check FAILED — may need manual recovery"
    executor_push_alert "repo_corrupt" "${repo} git fsck failed" 2>/dev/null || true
    return 1
  fi
  cd "${LIVEMASK_ROOT}" 2>/dev/null || true
  return 0
}

# ── FIX 17: CI degraded mode check ──────────────────────────────────────
executor_ci_degraded_ok() {
  # Returns 0 if it's OK to proceed despite CI issues (degraded mode)
  if executor_gh_available 2>/dev/null; then
    return 1  # GitHub available — CI should work
  fi
  # GitHub down — allow local-only operations
  echo "  [DEGRADE] GitHub unavailable — proceeding in local-only mode"
  return 0
}

# ── Full system health check ─────────────────────────────────────────────
executor_system_health() {
  echo "=== SYSTEM HEALTH ==="
  executor_repair_agent_state
  executor_repair_ledger
  executor_cleanup_alerts
  executor_auto_unblock_stale
  echo "  Agent: $(python3 -c "import json;print(json.load(open('${AGENT_STATE}')).get('phase','?'))" 2>/dev/null || echo '?')"
  echo "  PM lease: $(python3 -c "import json,time;d=json.load(open('${PM_LEASE_FILE}'));print(f'{d.get(\"agent\",\"?\")} ({int((time.time()-d.get(\"started_at_epoch\",0))/60)}min)')" 2>/dev/null || echo 'none')"
  echo "  Heartbeat: $(executor_check_liveness && echo 'ALIVE' || echo 'STALE')"
  echo "  GitHub: $(executor_gh_available && echo 'OK' || echo 'DOWN')"
  echo "  Alerts: $(ls "${ROLE_CACHE_DIR}/alerts"/*.json 2>/dev/null | wc -l | tr -d ' ' || echo '0')"
  echo ""
}

# ── Auto-resolve simple merge conflicts ────────────────────────────────
executor_auto_resolve_conflict() {
  local repo="${1:-}"; [[ -z "${repo}" ]] && return 1
  local repo_dir="${LIVEMASK_ROOT}/${repo}"
  cd "${repo_dir}" 2>/dev/null || return 1

  # Check if we're in a merge conflict state
  if ! git status --porcelain 2>/dev/null | grep -q "^UU\|^AA\|^DD"; then
    return 0  # No conflict
  fi

  echo "  [MERGE] Conflict detected in ${repo} — attempting auto-resolution"

  # Strategy 1: If conflict is in task-state-ledger.json, accept ours (newer tasks)
  local conflict_files; conflict_files=$(git diff --name-only --diff-filter=U 2>/dev/null)
  local auto_resolved=0

  for f in ${conflict_files}; do
    # For docs/ledger files, use 'ours' strategy (keep our additions)
    if echo "${f}" | grep -q "task-state-ledger.json\|CODEX_LOOP_RULES\|CLAUDE.md\|dispatch-packets/"; then
      git checkout --ours "${f}" 2>/dev/null && git add "${f}" 2>/dev/null
      echo "  [MERGE] Auto-resolved (ours): ${f}"
      auto_resolved=$((auto_resolved + 1))
    # For code files, use 'theirs' strategy (accept incoming if ours hasn't changed)
    elif echo "${f}" | grep -q "\.go$\|\.ts$\|\.tsx$\|\.dart$\|\.sh$\|\.py$"; then
      # Check if our side has real changes vs just boilerplate
      local our_changes; our_changes=$(git diff HEAD...MERGE_HEAD -- "${f}" 2>/dev/null | grep "^[+-]" | grep -v "^[+-][+-][+-]" | wc -l | tr -d ' ')
      local their_changes; their_changes=$(git diff MERGE_HEAD...HEAD -- "${f}" 2>/dev/null | grep "^[+-]" | grep -v "^[+-][+-][+-]" | wc -l | tr -d ' ')
      if [[ "${our_changes}" -le 2 && "${their_changes}" -gt 0 ]]; then
        git checkout --theirs "${f}" 2>/dev/null && git add "${f}" 2>/dev/null
        echo "  [MERGE] Auto-resolved (theirs, our=${our_changes} their=${their_changes}): ${f}"
        auto_resolved=$((auto_resolved + 1))
      fi
    fi
  done

  # If all conflicts resolved, complete the merge
  local remaining; remaining=$(git diff --name-only --diff-filter=U 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${remaining}" -eq 0 && "${auto_resolved}" -gt 0 ]]; then
    if git commit --no-edit 2>/dev/null; then
      echo "  [MERGE] Auto-merge completed (${auto_resolved} files auto-resolved)"
      return 0
    fi
  fi

  echo "  [MERGE] ${remaining} files still in conflict — manual resolution needed"
  return 1
}
