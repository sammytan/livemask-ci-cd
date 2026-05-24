#!/usr/bin/env bash
# TASK-CICD-CURSOR-REPORT-DISPATCH-001 / TASK-RUNTIME-CURSOR-REPORT-DISPATCH-ADOPTION-001
#
# Normalize, validate, and dispatch Cursor completion reports to livemask-docs.
#
# Usage:
#   bash scripts/cursor-report-dispatch.sh \
#     --task-id TASK-CICD-FOO-001 \
#     --repo livemask-backend \
#     --branch dev \
#     --commit abc123def456 \
#     --task-branch task/TASK-CICD-FOO-001 \
#     --task-commit abc123def000 \
#     [--dev-merge-commit abc123def789] \
#     --validation "smoke PASS, go test PASS" \
#     --result completed \
#     [--report-kind standard|local-verification] \
#     [--lark-webhook-url https://open.larksuite.com/open-apis/bot/v2/hook/xxx] \
#     [--lark-secret xxx] \
#     [--github-token ghp_xxx] \
#     [--target-repo MyAiDevs/livemask-docs] \
#     [--dry-run]
#
# Required env (fallback when flags omitted):
#   LIVEMASK_BOT_TOKEN  — GitHub token for repository_dispatch API
#   LARK_BOT_WEBHOOK    — Lark bot webhook URL (for notify)
#   LARK_BOT_SECRET     — Lark bot sign secret (optional)
#
# All flags can also be set via env vars:
#   REPORT_TASK_ID, REPORT_SOURCE_REPO, REPORT_BRANCH, REPORT_COMMIT,
#   REPORT_TASK_BRANCH, REPORT_TASK_COMMIT, REPORT_DEV_MERGE_COMMIT,
#   REPORT_VALIDATION, REPORT_RESULT, REPORT_KIND, REPORT_TARGET_REPO

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================
# Defaults
# ============================================================
TARGET_REPO="${REPORT_TARGET_REPO:-MyAiDevs/livemask-docs}"
DRY_RUN="${REPORT_DRY_RUN:-false}"
REPORT_KIND="${REPORT_KIND:-standard}"

# ============================================================
# Parse arguments
# ============================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id) TASK_ID="$2"; shift 2 ;;
    --repo) SOURCE_REPO="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --commit) COMMIT="$2"; shift 2 ;;
    --task-branch) TASK_BRANCH="$2"; shift 2 ;;
    --task-commit) TASK_COMMIT="$2"; shift 2 ;;
    --dev-merge-commit) DEV_MERGE_COMMIT="$2"; shift 2 ;;
    --validation) VALIDATION="$2"; shift 2 ;;
    --result) RESULT="$2"; shift 2 ;;
    --report-kind) REPORT_KIND="$2"; shift 2 ;;
    --lark-webhook-url) LARK_BOT_WEBHOOK="$2"; shift 2 ;;
    --lark-secret) LARK_BOT_SECRET="$2"; shift 2 ;;
    --github-token) LIVEMASK_BOT_TOKEN="$2"; shift 2 ;;
    --target-repo) TARGET_REPO="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h)
      echo "Usage: $SCRIPT_NAME [options]"
      echo ""
      echo "Required:"
      echo "  --task-id ID             TASK ID (e.g. TASK-CICD-FOO-001)"
      echo "  --repo NAME              Source repo (e.g. livemask-backend)"
      echo "  --branch NAME            Git branch (e.g. dev)"
      echo "  --commit SHA             Git commit SHA (the dev merge commit)"
      echo "  --task-branch NAME       Task branch name"
      echo "  --task-commit SHA        Task branch commit SHA"
      echo "  --validation TEXT        Validation evidence summary"
      echo "  --result TEXT            completed / partial / blocked / evidence_missing"
      echo ""
      echo "Optional:"
      echo "  --dev-merge-commit SHA   Dev merge commit (optional; docs downgrades if missing)"
      echo "  --report-kind KIND       standard (default) or local-verification"
      echo "  --lark-webhook-url URL   Lark bot webhook URL"
      echo "  --lark-secret SECRET     Lark bot sign secret"
      echo "  --github-token TOKEN     GitHub API token (for dispatch)"
      echo "  --target-repo REPO       Target repo (default: MyAiDevs/livemask-docs)"
      echo "  --dry-run                Validate but do not send"
      echo ""
      echo "Notes:"
      echo "  - dev-merge-commit is NOT strictly validated: if absent the report"
      echo "    still dispatches and docs downgrades the status."
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ============================================================
# Resolve values: flag > env > git auto-detect
# ============================================================
TASK_ID="${TASK_ID:-${REPORT_TASK_ID:-}}"
SOURCE_REPO="${SOURCE_REPO:-${REPORT_SOURCE_REPO:-$(basename "$(git rev-parse --show-toplevel 2>/dev/null || true)")}}"
BRANCH="${BRANCH:-${REPORT_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)}}"
COMMIT="${COMMIT:-${REPORT_COMMIT:-$(git rev-parse HEAD 2>/dev/null || true)}}"
TASK_BRANCH="${TASK_BRANCH:-${REPORT_TASK_BRANCH:-}}"
TASK_COMMIT="${TASK_COMMIT:-${REPORT_TASK_COMMIT:-}}"
DEV_MERGE_COMMIT="${DEV_MERGE_COMMIT:-${REPORT_DEV_MERGE_COMMIT:-}}"
VALIDATION="${VALIDATION:-${REPORT_VALIDATION:-}}"
RESULT="${RESULT:-${REPORT_RESULT:-completed}}"
REPORT_KIND="${REPORT_KIND:-${REPORT_KIND:-standard}}"

LIVEMASK_BOT_TOKEN="${LIVEMASK_BOT_TOKEN:-${GITHUB_TOKEN:-}}"

# ============================================================
# Required field validation (bash 3.2+ compatible)
# ============================================================
FAILED=0
validate_field() {
  local name="$1" value="$2" varname="$3"
  if [[ -z "$value" ]]; then
    echo "ERROR: Required field '$name' is empty. Use --$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr '_' '-') or set REPORT_${varname} env."
    FAILED=1
  fi
}

validate_field "TASK_ID" "$TASK_ID" "TASK_ID"
validate_field "SOURCE_REPO" "$SOURCE_REPO" "SOURCE_REPO"
validate_field "BRANCH" "$BRANCH" "BRANCH"
validate_field "COMMIT" "$COMMIT" "COMMIT"
validate_field "TASK_BRANCH" "$TASK_BRANCH" "TASK_BRANCH"
validate_field "TASK_COMMIT" "$TASK_COMMIT" "TASK_COMMIT"
validate_field "VALIDATION" "$VALIDATION" "VALIDATION"

# dev-merge-commit is optional: warn if missing but do NOT fail
if [[ -z "$DEV_MERGE_COMMIT" ]]; then
  echo "WARN: dev-merge-commit is empty. Report will still dispatch; docs window will downgrade status."
fi

if [[ -z "$LIVEMASK_BOT_TOKEN" ]]; then
  echo "ERROR: LIVEMASK_BOT_TOKEN (or GITHUB_TOKEN) is required for repository_dispatch API."
  FAILED=1
fi

if [[ "$FAILED" -eq 1 ]]; then
  echo ""
  echo "FATAL: Validation failed. Report not dispatched."
  exit 1
fi

# ============================================================
# Normalize result
# ============================================================
case "$RESULT" in
  completed|partial|blocked|evidence_missing) ;;
  *) echo "WARN: result='$RESULT' not in standard set (completed/partial/blocked/evidence_missing); sending as-is." ;;
esac

# ============================================================
# Normalize report-kind
# ============================================================
case "$REPORT_KIND" in
  standard|local-verification) ;;
  *) echo "WARN: report-kind='$REPORT_KIND' not in standard set (standard/local-verification); sending as-is." ;;
esac

# ============================================================
# Build dispatch payload
# ============================================================
COMPLETION_TIME="$(date '+%Y-%m-%d %H:%M:%S %z')"

PAYLOAD=$(cat <<JSON
{
  "event_type": "cursor-report-received",
  "client_payload": {
    "task_id": "$TASK_ID",
    "source_repo": "$SOURCE_REPO",
    "branch": "$BRANCH",
    "commit": "$COMMIT",
    "task_branch": "$TASK_BRANCH",
    "task_commit": "$TASK_COMMIT",
    "dev_merge_commit": "$DEV_MERGE_COMMIT",
    "validation": "$VALIDATION",
    "result": "$RESULT",
    "report_kind": "$REPORT_KIND",
    "completion_time": "$COMPLETION_TIME"
  }
}
JSON
)

# Pretty print for logs
echo "=== Cursor Report Dispatch ==="
echo "Task ID:         $TASK_ID"
echo "Source Repo:     $SOURCE_REPO"
echo "Branch:          $BRANCH"
echo "Commit:          $COMMIT"
echo "Task Branch:     $TASK_BRANCH"
echo "Task Commit:     $TASK_COMMIT"
echo "Dev Merge Commit:$DEV_MERGE_COMMIT"
echo "Validation:      $VALIDATION"
echo "Result:          $RESULT"
echo "Report Kind:     $REPORT_KIND"
echo "Completion Time: $COMPLETION_TIME"
echo "Target Repo:     $TARGET_REPO"
echo "Dry Run:         $DRY_RUN"
echo ""

# ============================================================
# Dispatch to livemask-docs
# ============================================================
DISPATCH_EXIT=0
DISPATCH_ERROR=""
if [[ "$DRY_RUN" == "true" ]]; then
  echo "[DRY-RUN] Skipping repository_dispatch. Would send to $TARGET_REPO:"
  echo "$PAYLOAD" | python3 -m json.tool 2>/dev/null || echo "$PAYLOAD"
else
  echo "--- Dispatching to $TARGET_REPO ---"
  DISPATCH_RESPONSE=$(curl -sS -X POST "https://api.github.com/repos/${TARGET_REPO}/dispatches" \
    -H "Authorization: Bearer ${LIVEMASK_BOT_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>&1) || true

  if [[ -z "$DISPATCH_RESPONSE" ]]; then
    echo "repository_dispatch sent successfully (204 No Content)"
  else
    echo "repository_dispatch response: $DISPATCH_RESPONSE"
    if echo "$DISPATCH_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if 'message' in d else 1)" 2>/dev/null; then
      DISPATCH_ERROR="$DISPATCH_RESPONSE"
      echo "ERROR: $DISPATCH_RESPONSE"
      DISPATCH_EXIT=1
    else
      echo "WARN: unexpected response shape. Treating as success."
    fi
  fi
fi

echo ""

# ============================================================
# Lark notification
# ============================================================
if [[ -n "${LARK_BOT_WEBHOOK:-}" ]] && [[ "$DRY_RUN" != "true" ]]; then
  echo "--- Sending Lark notification ---"

  # Compute dispatch status for Lark
  if [[ "$DISPATCH_EXIT" -eq 0 ]]; then
    DISPATCH_STATUS="dispatch success"
    LARK_RESULT="$RESULT"
  else
    DISPATCH_STATUS="dispatch failed: ${DISPATCH_ERROR}"
    LARK_RESULT="failure"
  fi

  REPORT_KIND_LABEL="$REPORT_KIND"
  TASK_BRANCH_LABEL="${TASK_BRANCH:-<missing>}"
  TASK_COMMIT_LABEL="${TASK_COMMIT:-<missing>}"
  DEV_MERGE_LABEL="${DEV_MERGE_COMMIT:-<missing>}"

  REPORT_KIND="cursor-report-dispatch" \
  REPORT_TITLE="Cursor Report: ${SOURCE_REPO}/${TASK_ID}" \
  REPORT_SUMMARY="Repo: ${SOURCE_REPO}
Task: ${TASK_ID}
Result: ${RESULT}
Report Kind: ${REPORT_KIND_LABEL}
Branch: ${BRANCH}
Commit: ${COMMIT}
Task Branch: ${TASK_BRANCH_LABEL}
Task Commit: ${TASK_COMMIT_LABEL}
Dev Merge: ${DEV_MERGE_LABEL}
Completion: ${COMPLETION_TIME}

Validation:
${VALIDATION}

Dispatch: ${DISPATCH_STATUS}" \
  REPORT_TASKS="${TASK_ID}" \
  REPORT_RISKS="$(if [[ "$DISPATCH_EXIT" -ne 0 ]]; then echo "repository_dispatch failed: ${DISPATCH_ERROR}"; elif [[ -z "$DEV_MERGE_COMMIT" ]]; then echo "dev-merge-commit missing — docs will downgrade status"; else echo "none"; fi)" \
  REPORT_NEXT_STEPS="Docs window should review report and update task ledger." \
  WORKFLOW_RESULT="${LARK_RESULT}" \
  bash "${SCRIPT_DIR}/../.github/scripts/lark-notify.sh" "${LARK_RESULT}" || true
else
  echo "LARK_BOT_WEBHOOK not set or dry-run; skip Lark notification."
fi

# ============================================================
# Exit
# ============================================================
if [[ "$DISPATCH_EXIT" -ne 0 ]]; then
  echo "FATAL: repository_dispatch failed."
  exit 1
fi

echo ""
echo "Cursor report dispatch completed for ${TASK_ID}."
