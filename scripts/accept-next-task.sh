#!/usr/bin/env bash
# TASK-DOCS-CURSOR-WORKER-CONTINUATION-001
#
# Safely accept the next docs-assigned task for a repo-local Cursor worker.
# This script intentionally does not implement task work. It only verifies
# worker/session/task guards, selects one eligible assignment, writes a local
# worker state file, and generates a Cursor brief for the next task.

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Exit code contract. Cursor should continue only on 0.
EXIT_ACCEPTED=0
EXIT_IDLE=10
EXIT_BLOCKED=20
EXIT_DIRTY=30
EXIT_MISMATCH=40
EXIT_REPORT_PENDING=50
EXIT_VALIDATION_FAILED=60
EXIT_NETWORK_TIMEOUT=70
EXIT_LEASE_EXPIRED=80
EXIT_MANUAL_REQUIRED=90
EXIT_INTERNAL_ERROR=100

DOCS_REPO="${DOCS_REPO:-MyAiDevs/livemask-docs}"
DOCS_REF="${DOCS_REF:-dev}"
TASKS_PATH="${TASKS_PATH:-scripts/tasks-readiness.json}"
TASKS_FILE=""
STATE_FILE="${CURSOR_WORKER_STATE_FILE:-.cursor-worker-state.json}"
BRIEF_DIR="${CURSOR_WORKER_BRIEF_DIR:-.cursor-worker/briefs}"
WORKER="${CURSOR_WORKER_ID:-cursor-worker}"
REPO_NAME="${CURSOR_WORKER_REPO:-$(basename "${REPO_ROOT}")}"
MAX_CHAIN="${CURSOR_WORKER_MAX_CHAIN:-3}"
MAX_RUNTIME_MINUTES="${CURSOR_WORKER_MAX_RUNTIME_MINUTES:-90}"
POLL_ATTEMPTS="${CURSOR_WORKER_POLL_ATTEMPTS:-3}"
POLL_INTERVAL="${CURSOR_WORKER_POLL_INTERVAL:-10}"
FETCH_TIMEOUT="${CURSOR_WORKER_FETCH_TIMEOUT:-30}"
ACCEPT_STATUSES="${CURSOR_WORKER_ACCEPT_STATUSES:-dispatched,leased}"
PREVIOUS_TASK_ID="${CURSOR_PREVIOUS_TASK_ID:-}"
PREVIOUS_REPORT_ID="${CURSOR_PREVIOUS_REPORT_ID:-}"
REQUIRE_PREVIOUS_CONFIRMED="${CURSOR_REQUIRE_PREVIOUS_CONFIRMED:-true}"
DRY_RUN="${CURSOR_WORKER_DRY_RUN:-false}"
FORCE="${CURSOR_WORKER_FORCE:-false}"
SKIP_ORIGIN_CHECK="${CURSOR_WORKER_SKIP_ORIGIN_CHECK:-false}"

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} [options]

Accept the next docs-assigned task for a repo-local Cursor worker.

Options:
  --repo NAME                 Expected current repo (default: basename of git root)
  --worker ID                 Worker/session id (default: cursor-worker)
  --max-chain N               Max tasks per worker window (default: 3)
  --max-runtime-minutes N     Max worker runtime minutes (default: 90)
  --poll-attempts N           Poll attempts for docs assignment (default: 3)
  --poll-interval SEC         Delay between polls (default: 10)
  --timeout SEC               GitHub fetch timeout (default: 30)
  --tasks-file FILE           Read tasks readiness JSON from local file
  --tasks-path PATH           Path in docs repo (default: scripts/tasks-readiness.json)
  --docs-repo OWNER/REPO      Docs repo (default: MyAiDevs/livemask-docs)
  --docs-ref REF              Docs ref (default: dev)
  --state-file FILE           Local worker state file (default: .cursor-worker-state.json)
  --brief-dir DIR             Cursor brief output dir (default: .cursor-worker/briefs)
  --previous-task-id ID       Require previous task to be confirmed before continuing
  --previous-report-id ID     Previous report id, for audit checks when available
  --no-previous-confirm       Skip previous task report confirmation
  --dry-run                   Validate/select only; do not write state/brief
  --force                     Bypass local chain/runtime state limits only
  --skip-origin-check         Skip local origin/repo check for central CI callers
  --help                      Show this help

Exit codes:
  0   accepted_next_task
  10  idle_no_task
  20  blocked
  30  dirty_worktree
  40  task_mismatch
  50  report_pending
  60  validation_failed
  70  network_timeout
  80  lease_expired
  90  manual_required
  100 internal_error
USAGE
}

log() {
  printf '[%s] %s\n' "${SCRIPT_NAME}" "$*"
}

die() {
  local code="$1"
  shift
  log "STOP: $*"
  exit "${code}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO_NAME="${2:-}"; shift 2 ;;
    --worker) WORKER="${2:-}"; shift 2 ;;
    --max-chain) MAX_CHAIN="${2:-}"; shift 2 ;;
    --max-runtime-minutes) MAX_RUNTIME_MINUTES="${2:-}"; shift 2 ;;
    --poll-attempts) POLL_ATTEMPTS="${2:-}"; shift 2 ;;
    --poll-interval) POLL_INTERVAL="${2:-}"; shift 2 ;;
    --timeout) FETCH_TIMEOUT="${2:-}"; shift 2 ;;
    --tasks-file) TASKS_FILE="${2:-}"; shift 2 ;;
    --tasks-path) TASKS_PATH="${2:-}"; shift 2 ;;
    --docs-repo) DOCS_REPO="${2:-}"; shift 2 ;;
    --docs-ref) DOCS_REF="${2:-}"; shift 2 ;;
    --state-file) STATE_FILE="${2:-}"; shift 2 ;;
    --brief-dir) BRIEF_DIR="${2:-}"; shift 2 ;;
    --previous-task-id) PREVIOUS_TASK_ID="${2:-}"; shift 2 ;;
    --previous-report-id) PREVIOUS_REPORT_ID="${2:-}"; shift 2 ;;
    --no-previous-confirm) REQUIRE_PREVIOUS_CONFIRMED=false; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    --skip-origin-check) SKIP_ORIGIN_CHECK=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "${EXIT_INTERNAL_ERROR}" "unknown option: $1" ;;
  esac
done

case "${REPORT_RESULT:-completed}" in
  completed|verified|accepted|"") ;;
  partial|evidence_missing|needs-review|mismatch|stale|blocked|failed)
    die "${EXIT_REPORT_PENDING}" "previous report result is '${REPORT_RESULT}', not safe to continue"
    ;;
esac

if ! [[ "${MAX_CHAIN}" =~ ^[0-9]+$ ]] || [[ "${MAX_CHAIN}" -lt 1 ]]; then
  die "${EXIT_INTERNAL_ERROR}" "--max-chain must be a positive integer"
fi
if ! [[ "${MAX_RUNTIME_MINUTES}" =~ ^[0-9]+$ ]] || [[ "${MAX_RUNTIME_MINUTES}" -lt 1 ]]; then
  die "${EXIT_INTERNAL_ERROR}" "--max-runtime-minutes must be a positive integer"
fi

cd "${REPO_ROOT}"

if [[ "${SKIP_ORIGIN_CHECK}" != "true" ]]; then
  REMOTE_URL="$(git remote get-url origin 2>/dev/null || true)"
  if [[ -n "${REMOTE_URL}" ]] && ! echo "${REMOTE_URL}" | grep -q "${REPO_NAME}"; then
    die "${EXIT_MISMATCH}" "current origin (${REMOTE_URL}) does not look like repo ${REPO_NAME}"
  fi
fi

if ! git diff --quiet --ignore-submodules -- 2>/dev/null || ! git diff --cached --quiet --ignore-submodules -- 2>/dev/null; then
  die "${EXIT_DIRTY}" "git worktree is dirty; refusing to accept next task"
fi

if git rev-parse --verify HEAD >/dev/null 2>&1; then
  CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
else
  CURRENT_BRANCH="unknown"
fi

if [[ "${CURRENT_BRANCH}" != "dev" ]]; then
  log "WARN: current branch is ${CURRENT_BRANCH}; next task should normally start from dev"
fi

STATE_JSON="{}"
if [[ -f "${STATE_FILE}" ]]; then
  STATE_JSON="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))))' "${STATE_FILE}" 2>/dev/null || echo '{}')"
fi

SESSION_ID="$(python3 -c '
import json,sys,uuid
d=json.loads(sys.argv[1])
print(d.get("worker_session_id") or str(uuid.uuid4()))
' "${STATE_JSON}")"

CHAIN_COUNT="$(python3 -c '
import json,sys
d=json.loads(sys.argv[1])
print(int(d.get("chain_count", 0)))
' "${STATE_JSON}" 2>/dev/null || echo 0)"

STARTED_AT_EPOCH="$(python3 -c '
import datetime,json,sys,time
d=json.loads(sys.argv[1])
raw=d.get("started_at")
if not raw:
    print(int(time.time()))
else:
    try:
        print(int(datetime.datetime.fromisoformat(raw.replace("Z","+00:00")).timestamp()))
    except Exception:
        print(int(time.time()))
' "${STATE_JSON}" 2>/dev/null || date +%s)"

NOW_EPOCH="$(date +%s)"
RUNTIME_SECONDS=$((NOW_EPOCH - STARTED_AT_EPOCH))
MAX_RUNTIME_SECONDS=$((MAX_RUNTIME_MINUTES * 60))

if [[ "${FORCE}" != "true" ]]; then
  if [[ "${CHAIN_COUNT}" -ge "${MAX_CHAIN}" ]]; then
    die "${EXIT_BLOCKED}" "max_chain reached (${CHAIN_COUNT}/${MAX_CHAIN}); stop this Cursor window"
  fi
  if [[ "${RUNTIME_SECONDS}" -ge "${MAX_RUNTIME_SECONDS}" ]]; then
    die "${EXIT_BLOCKED}" "max_runtime reached (${RUNTIME_SECONDS}s/${MAX_RUNTIME_SECONDS}s); stop this Cursor window"
  fi
fi

if [[ "${REQUIRE_PREVIOUS_CONFIRMED}" == "true" && -n "${PREVIOUS_TASK_ID}" ]]; then
  log "Previous task confirmation requested for ${PREVIOUS_TASK_ID}"
  log "Using docs assignment source as confirmation input; report_id=${PREVIOUS_REPORT_ID:-<not-provided>}"
fi

TMP_TASKS="$(mktemp "${TMPDIR:-/tmp}/livemask-tasks.XXXXXX")"
trap 'rm -f "${TMP_TASKS}"' EXIT

fetch_tasks() {
  if [[ -n "${TASKS_FILE}" ]]; then
    cp "${TASKS_FILE}" "${TMP_TASKS}"
    return 0
  fi

  local token="${LIVEMASK_BOT_TOKEN:-${GITHUB_TOKEN:-}}"
  local api_url="https://api.github.com/repos/${DOCS_REPO}/contents/${TASKS_PATH}?ref=${DOCS_REF}"
  if [[ -z "${token}" ]]; then
    log "ERROR: LIVEMASK_BOT_TOKEN or GITHUB_TOKEN is required when --tasks-file is not used"
    return 1
  fi

  python3 - "$api_url" "$token" "$FETCH_TIMEOUT" "$TMP_TASKS" <<'PY'
import base64
import json
import sys
import urllib.error
import urllib.request

url, token, timeout, out_path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
req = urllib.request.Request(
    url,
    headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "livemask-cursor-worker",
    },
)
try:
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.load(resp)
    content = data.get("content", "")
    decoded = base64.b64decode(content).decode("utf-8")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(decoded)
except Exception as exc:
    print(f"fetch_failed: {exc}", file=sys.stderr)
    sys.exit(1)
PY
}

attempt=1
while [[ "${attempt}" -le "${POLL_ATTEMPTS}" ]]; do
  log "Fetching task assignments (${attempt}/${POLL_ATTEMPTS}) from ${DOCS_REPO}:${DOCS_REF}/${TASKS_PATH}"
  if fetch_tasks; then
    break
  fi
  if [[ "${attempt}" -eq "${POLL_ATTEMPTS}" ]]; then
    die "${EXIT_NETWORK_TIMEOUT}" "unable to fetch task assignments after ${POLL_ATTEMPTS} attempts"
  fi
  sleep "${POLL_INTERVAL}"
  attempt=$((attempt + 1))
done

SELECTION_JSON="$(python3 - "${TMP_TASKS}" "${REPO_NAME}" "${ACCEPT_STATUSES}" "${STATE_JSON}" "${PREVIOUS_TASK_ID}" "${PREVIOUS_REPORT_ID}" "${REQUIRE_PREVIOUS_CONFIRMED}" <<'PY'
import datetime
import hashlib
import json
import sys

(
    path, repo, accept_statuses_raw, state_raw,
    previous_task_id, previous_report_id, require_previous_confirmed_raw,
) = sys.argv[1:8]
accept_statuses = {s.strip() for s in accept_statuses_raw.split(",") if s.strip()}
state = json.loads(state_raw or "{}")
processed = set(state.get("processed_task_ids") or [])
require_previous_confirmed = require_previous_confirmed_raw.lower() == "true"

with open(path, encoding="utf-8") as f:
    raw = json.load(f)

if isinstance(raw, list):
    tasks = raw
elif isinstance(raw, dict):
    if isinstance(raw.get("tasks"), list):
        tasks = raw["tasks"]
    elif isinstance(raw.get("items"), list):
        tasks = raw["items"]
    else:
        tasks = []
        for value in raw.values():
            if isinstance(value, list):
                tasks.extend(x for x in value if isinstance(x, dict))
else:
    tasks = []

now = datetime.datetime.now(datetime.timezone.utc)

def parse_time(value):
    if not value:
        return None
    try:
        return datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except Exception:
        return None

def task_hash(task):
    keys = [
        "task_id", "repo", "source_repo", "dependencies", "conflict_group",
        "touch_surface", "environment_stage", "manual_dispatch_required",
        "allow_same_batch_dependency", "risk_level", "estimated_size",
    ]
    payload = {k: task.get(k) for k in keys if k in task}
    return hashlib.sha256(json.dumps(payload, sort_keys=True, ensure_ascii=False).encode()).hexdigest()

def task_status(task):
    for key in ("effective_status", "result", "status", "completion_status"):
        value = task.get(key)
        if value:
            return str(value)
    return ""

def report_id(task):
    return str(task.get("report_id") or task.get("completion_report_id") or task.get("last_report_id") or "")

previous_confirmation = {"required": bool(require_previous_confirmed and previous_task_id), "ok": True, "reason": "not_required"}
if require_previous_confirmed and previous_task_id:
    matches = [t for t in tasks if isinstance(t, dict) and (t.get("task_id") or t.get("id")) == previous_task_id]
    if not matches:
        previous_confirmation = {"required": True, "ok": False, "reason": "previous_task_not_found"}
    else:
        previous = matches[0]
        status = task_status(previous)
        evidence = str(previous.get("evidence_status") or "")
        expected_report_id = previous_report_id.strip()
        actual_report_id = report_id(previous)
        completed_statuses = {"completed", "verified", "accepted"}
        if status not in completed_statuses:
            previous_confirmation = {"required": True, "ok": False, "reason": f"previous_status_{status or 'unknown'}"}
        elif evidence in {"missing", "mismatch", "stale"}:
            previous_confirmation = {"required": True, "ok": False, "reason": f"previous_evidence_{evidence}"}
        elif expected_report_id and actual_report_id and expected_report_id != actual_report_id:
            previous_confirmation = {"required": True, "ok": False, "reason": "previous_report_id_mismatch"}
        else:
            previous_confirmation = {
                "required": True,
                "ok": True,
                "reason": "confirmed",
                "status": status,
                "evidence_status": evidence,
                "report_id": actual_report_id,
            }

blocked = []
eligible = []
for task in tasks:
    if not isinstance(task, dict):
        continue
    task_id = task.get("task_id") or task.get("id") or ""
    task_repo = task.get("repo") or task.get("source_repo") or ""
    source_repo = task.get("source_repo") or task_repo
    status = task.get("dispatch_status") or task.get("status") or "ready"
    if task_repo != repo and source_repo != repo:
        continue
    reason = None
    if not task_id:
        reason = "missing_task_id"
    elif task_id in processed:
        reason = "already_processed_in_session"
    elif task.get("manual_dispatch_required") is True or str(task.get("manual_dispatch_required")).lower() == "true":
        reason = "manual_required"
    elif status not in accept_statuses:
        reason = f"status_{status}_not_acceptable"
    elif task.get("repo") and task.get("source_repo") and task.get("repo") != task.get("source_repo"):
        reason = "repo_source_repo_mismatch"
    elif task.get("evidence_status") in {"mismatch", "stale"}:
        reason = f"evidence_{task.get('evidence_status')}"
    else:
        expires = parse_time(task.get("lease_expires_at"))
        if expires is not None and expires < now:
            reason = "lease_expired"

    task["computed_task_spec_hash"] = task.get("task_spec_hash") or task_hash(task)
    if reason:
        blocked.append({"task_id": task_id, "reason": reason, "status": status})
    else:
        eligible.append(task)

eligible.sort(key=lambda t: (
    int(t.get("priority", 999) if str(t.get("priority", "999")).isdigit() else 999),
    str(t.get("lease_expires_at") or ""),
    str(t.get("task_id") or ""),
))

result = {
    "selected": eligible[0] if eligible else None,
    "eligible_count": len(eligible),
    "blocked": blocked[:20],
    "total_repo_tasks": len([t for t in tasks if isinstance(t, dict) and ((t.get("repo") or t.get("source_repo")) == repo or (t.get("source_repo") or t.get("repo")) == repo)]),
    "previous_confirmation": previous_confirmation,
}
print(json.dumps(result, ensure_ascii=False))
PY
)"

PREVIOUS_CONFIRMATION_OK="$(python3 -c 'import json,sys; print(str(json.loads(sys.argv[1]).get("previous_confirmation", {}).get("ok", True)).lower())' "${SELECTION_JSON}")"
if [[ "${PREVIOUS_CONFIRMATION_OK}" != "true" ]]; then
  PREVIOUS_CONFIRMATION_REASON="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("previous_confirmation", {}).get("reason", "unknown"))' "${SELECTION_JSON}")"
  die "${EXIT_REPORT_PENDING}" "previous task ${PREVIOUS_TASK_ID} is not confirmed by docs: ${PREVIOUS_CONFIRMATION_REASON}"
fi

SELECTED_TASK_ID="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); s=d.get("selected"); print((s or {}).get("task_id",""))' "${SELECTION_JSON}")"

if [[ -z "${SELECTED_TASK_ID}" ]]; then
  log "No eligible next task for ${REPO_NAME}."
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(json.dumps({"blocked": d.get("blocked", []), "total_repo_tasks": d.get("total_repo_tasks", 0)}, indent=2, ensure_ascii=False))' "${SELECTION_JSON}" || true
  exit "${EXIT_IDLE}"
fi

MANUAL_REQUIRED="$(python3 -c 'import json,sys; s=json.loads(sys.argv[1])["selected"]; print(str(s.get("manual_dispatch_required", False)).lower())' "${SELECTION_JSON}")"
if [[ "${MANUAL_REQUIRED}" == "true" ]]; then
  die "${EXIT_MANUAL_REQUIRED}" "selected task ${SELECTED_TASK_ID} is manual_dispatch_required"
fi

LEASE_EXPIRES_AT="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["selected"].get("lease_expires_at",""))' "${SELECTION_JSON}")"
if [[ -n "${LEASE_EXPIRES_AT}" ]]; then
  if ! python3 - "${LEASE_EXPIRES_AT}" <<'PY'
import datetime
import sys
raw = sys.argv[1]
dt = datetime.datetime.fromisoformat(raw.replace("Z", "+00:00"))
sys.exit(0 if dt >= datetime.datetime.now(datetime.timezone.utc) else 1)
PY
  then
    die "${EXIT_LEASE_EXPIRED}" "selected task ${SELECTED_TASK_ID} lease expired at ${LEASE_EXPIRES_AT}"
  fi
fi

TASK_SPEC_HASH="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["selected"].get("computed_task_spec_hash",""))' "${SELECTION_JSON}")"
TASK_BRANCH="$(python3 -c 'import json,sys; s=json.loads(sys.argv[1])["selected"]; print(s.get("task_branch") or ("task/" + s.get("task_id","")))' "${SELECTION_JSON}")"
ENVIRONMENT_STAGE="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["selected"].get("environment_stage","dev-runtime"))' "${SELECTION_JSON}")"
BATCH_ID="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["selected"].get("batch_id",""))' "${SELECTION_JSON}")"
LEASE_ID="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["selected"].get("lease_id",""))' "${SELECTION_JSON}")"

SAFE_TASK_ID="$(printf '%s' "${SELECTED_TASK_ID}" | tr -c 'A-Za-z0-9_.-' '_')"
BRIEF_PATH="${BRIEF_DIR}/${SAFE_TASK_ID}.md"

if [[ "${DRY_RUN}" == "true" ]]; then
  log "[DRY-RUN] Would accept ${SELECTED_TASK_ID} for ${REPO_NAME}"
  python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["selected"], indent=2, ensure_ascii=False))' "${SELECTION_JSON}"
  exit "${EXIT_ACCEPTED}"
fi

mkdir -p "${BRIEF_DIR}"

python3 - "${SELECTION_JSON}" "${BRIEF_PATH}" "${REPO_NAME}" "${SESSION_ID}" <<'PY'
import json
import sys

selection = json.loads(sys.argv[1])
brief_path, repo, session_id = sys.argv[2], sys.argv[3], sys.argv[4]
task = selection["selected"]

lines = [
    f"# {task.get('task_id', 'UNKNOWN')}",
    "",
    "## Cursor Worker Assignment",
    f"- Repo: {repo}",
    f"- Worker session: {session_id}",
    f"- Batch: {task.get('batch_id', '<none>')}",
    f"- Lease: {task.get('lease_id', '<none>')}",
    f"- Lease expires: {task.get('lease_expires_at', '<none>')}",
    f"- Environment stage: {task.get('environment_stage', 'dev-runtime')}",
    f"- Task spec hash: {task.get('computed_task_spec_hash', task.get('task_spec_hash', '<none>'))}",
    "",
    "## Scope",
    str(task.get("summary") or task.get("title") or task.get("description") or "Read the source task document before editing."),
    "",
    "## Guardrails",
    "- Do not edit another repo for this task.",
    "- Do not continue if validation fails, worktree is dirty, lease expires, or task spec changes.",
    "- Merge to dev, validate on dev, push origin/dev, then dispatch completion report.",
    "- Continue to the next task only by running scripts/accept-next-task.sh again.",
    "",
    "## Validation",
    str(task.get("validation") or task.get("validation_commands") or "Run repo-local validation and dev merge guard."),
    "",
    "## Raw Task Metadata",
    "```json",
    json.dumps(task, indent=2, ensure_ascii=False),
    "```",
    "",
]

with open(brief_path, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
PY

PROCESSED_TASKS_JSON="$(python3 -c '
import json,sys
d=json.loads(sys.argv[1])
processed=list(d.get("processed_task_ids") or [])
task=sys.argv[2]
if task not in processed:
    processed.append(task)
print(json.dumps(processed))
' "${STATE_JSON}" "${SELECTED_TASK_ID}")"

NOW_ISO="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
STARTED_ISO="$(python3 -c 'import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).isoformat().replace("+00:00","Z"))' "${STARTED_AT_EPOCH}")"

python3 - "${STATE_FILE}" "${SESSION_ID}" "${WORKER}" "${REPO_NAME}" "${CHAIN_COUNT}" "${PROCESSED_TASKS_JSON}" "${SELECTED_TASK_ID}" "${TASK_SPEC_HASH}" "${BATCH_ID}" "${LEASE_ID}" "${NOW_ISO}" "${STARTED_ISO}" "${BRIEF_PATH}" <<'PY'
import json
import os
import sys

(
    state_file, session_id, worker, repo, chain_count_raw, processed_raw,
    task_id, task_spec_hash, batch_id, lease_id, now_iso, started_iso, brief_path
) = sys.argv[1:]

chain_count = int(chain_count_raw) + 1
processed = json.loads(processed_raw)
state = {
    "worker_session_id": session_id,
    "worker_id": worker,
    "repo": repo,
    "chain_count": chain_count,
    "processed_task_ids": processed,
    "last_task_id": task_id,
    "last_task_spec_hash": task_spec_hash,
    "last_batch_id": batch_id,
    "last_lease_id": lease_id,
    "last_brief_path": brief_path,
    "started_at": started_iso,
    "last_heartbeat_at": now_iso,
}
os.makedirs(os.path.dirname(state_file) or ".", exist_ok=True)
with open(state_file, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY

log "Accepted next task: ${SELECTED_TASK_ID}"
log "Repo: ${REPO_NAME}"
log "Branch suggestion: ${TASK_BRANCH}"
log "Environment stage: ${ENVIRONMENT_STAGE}"
log "Batch: ${BATCH_ID:-<none>} Lease: ${LEASE_ID:-<none>}"
log "Brief: ${BRIEF_PATH}"
log "State: ${STATE_FILE}"

exit "${EXIT_ACCEPTED}"
