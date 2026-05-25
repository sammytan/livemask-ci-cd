#!/usr/bin/env bash
# TASK-CICD-WORKER-REPORT-DISPATCH-WIRING-001
#
# Dispatch a completion report to livemask-docs via repository_dispatch.
#
# Accepts a JSON report object via --input - (stdin).  If --input -
# is not given, falls back to individual --<field> <value> flags.
#
# All field extraction and PAYLOAD building is done via env-to-Python
# (no shell concatenation of user content).
#
# Sends the full body as:
#   { "event_type": "cursor-report-received", "client_payload": { ... } }
#
# The client_payload is a JSON object (not a string), matching the event
# type that the docs workflow already supports.
#
# Requires:
#   - LIVEMASK_BOT_TOKEN    GitHub PAT with repo scope for repo_dispatch
#   - gh CLI installed
#
# Exit codes:
#   0  – dispatch sent successfully
#   1  – missing required input or env
#   2  – gh CLI not found or dispatch API call failed

set -euo pipefail

DOCS_REPO="${DOCS_REPO:-MyAiDevs/livemask-docs}"

# If --input - is given, read full JSON object from stdin and use a single
# Python pass to produce env-exportable key=value strings.
if [[ "${1:-}" == "--input" && "${2:-}" == "-" ]]; then
  INPUT_JSON="$(cat)"
  eval "$(echo "${INPUT_JSON}" | python3 -c '
import json, sys, shlex
obj = json.load(sys.stdin)
for k in ("task_id","result","repo","branch","commit","task_branch","task_commit","dev_merge_commit","validation","module_id"):
    v = obj.get(k, "")
    print(f"FD_{k}={shlex.quote(str(v))}")
')"
  TASK_ID="${FD_task_id}"
  RESULT="${FD_result}"
  REPO="${FD_repo}"
  BRANCH="${FD_branch}"
  COMMIT="${FD_commit}"
  TASK_BRANCH="${FD_task_branch}"
  TASK_COMMIT="${FD_task_commit}"
  DEV_MERGE_COMMIT="${FD_dev_merge_commit}"
  VALIDATION="${FD_validation}"
  MODULE_ID="${FD_module_id}"
else
  PARSED_ARGS=$(getopt -o '' \
    --long task-id:,result:,repo:,branch:,commit:,task-branch:,task-commit:,dev-merge-commit:,validation:,module-id: \
    -n 'cursor-report-dispatch' -- "$@")
  eval set -- "${PARSED_ARGS}"
  TASK_ID=""; RESULT=""; REPO=""; BRANCH=""; COMMIT=""
  TASK_BRANCH=""; TASK_COMMIT=""; DEV_MERGE_COMMIT=""; VALIDATION=""; MODULE_ID=""
  while true; do
    case "$1" in
      --task-id) TASK_ID="$2"; shift 2 ;;
      --result) RESULT="$2"; shift 2 ;;
      --repo) REPO="$2"; shift 2 ;;
      --branch) BRANCH="$2"; shift 2 ;;
      --commit) COMMIT="$2"; shift 2 ;;
      --task-branch) TASK_BRANCH="$2"; shift 2 ;;
      --task-commit) TASK_COMMIT="$2"; shift 2 ;;
      --dev-merge-commit) DEV_MERGE_COMMIT="$2"; shift 2 ;;
      --validation) VALIDATION="$2"; shift 2 ;;
      --module-id) MODULE_ID="$2"; shift 2 ;;
      --) shift; break ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done
fi

if [[ -z "${TASK_ID}" || -z "${REPO}" || -z "${RESULT}" ]]; then
  echo "ERROR: task_id, repo, and result are required (via --input - JSON or individual flags)" >&2
  exit 1
fi

if [[ -z "${LIVEMASK_BOT_TOKEN:-}" ]]; then
  echo "ERROR: LIVEMASK_BOT_TOKEN not set" >&2
  exit 1
fi

if ! command -v gh &>/dev/null; then
  echo "ERROR: gh CLI not found" >&2
  exit 1
fi

# Build full body via env-to-Python (no shell concatenation).
# event_type = "cursor-report-received" (already supported by docs workflow).
# client_payload is a JSON object, never a string.
BODY=$(CR_DISPATCH_TASK_ID="${TASK_ID}" \
  CR_DISPATCH_RESULT="${RESULT}" \
  CR_DISPATCH_REPO="${REPO}" \
  CR_DISPATCH_BRANCH="${BRANCH}" \
  CR_DISPATCH_COMMIT="${COMMIT}" \
  CR_DISPATCH_TASK_BRANCH="${TASK_BRANCH}" \
  CR_DISPATCH_TASK_COMMIT="${TASK_COMMIT}" \
  CR_DISPATCH_DEV_MERGE_COMMIT="${DEV_MERGE_COMMIT}" \
  CR_DISPATCH_VALIDATION="${VALIDATION}" \
  CR_DISPATCH_MODULE_ID="${MODULE_ID}" \
  python3 -c '
import json, os, datetime

client_payload = {
    # Keep ≤ 10 properties (GitHub repository_dispatch API limit).
    # When module_id is provided, omit "branch" to stay within the limit.
    "task_id": os.environ.get("CR_DISPATCH_TASK_ID", ""),
    "result": os.environ.get("CR_DISPATCH_RESULT", "completed"),
    "repo": os.environ.get("CR_DISPATCH_REPO", ""),
    "commit": os.environ.get("CR_DISPATCH_COMMIT", ""),
    "task_branch": os.environ.get("CR_DISPATCH_TASK_BRANCH", ""),
    "task_commit": os.environ.get("CR_DISPATCH_TASK_COMMIT", ""),
    "dev_merge_commit": os.environ.get("CR_DISPATCH_DEV_MERGE_COMMIT", ""),
    "validation": os.environ.get("CR_DISPATCH_VALIDATION", ""),
    "completion_time": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
module_id = os.environ.get("CR_DISPATCH_MODULE_ID", "")
if module_id:
    client_payload["module_id"] = module_id
else:
    # When module_id is not provided, include branch for backward compatibility.
    client_payload["branch"] = os.environ.get("CR_DISPATCH_BRANCH", "")
body = {
    "event_type": "cursor-report-received",
    "client_payload": client_payload,
}
print(json.dumps(body, ensure_ascii=False))
')

echo "Dispatching completion report to ${DOCS_REPO}..."
echo "  event_type: cursor-report-received"
echo "  task_id: ${TASK_ID}"

GH_TOKEN="${LIVEMASK_BOT_TOKEN}" gh api \
  "/repos/${DOCS_REPO}/dispatches" \
  --method POST \
  --input - <<<"${BODY}" 2>&1 || {
    rc=$?
    echo "ERROR: gh dispatch API call failed (exit=${rc})" >&2
    exit 2
  }

echo "Dispatch sent successfully to ${DOCS_REPO} (event: cursor-report-received)"
exit 0
