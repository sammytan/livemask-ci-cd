#!/usr/bin/env bash
set -euo pipefail

# Create or update a single open GitHub Issue for Staging Smoke failures.
# The issue is intentionally deduplicated so repeated pushes do not spam Cursor;
# each failed run appends a comment with the concrete run/commit evidence.

if [[ "${AUTO_CREATE_STAGING_SMOKE_ISSUE:-true}" != "true" ]]; then
  echo "AUTO_CREATE_STAGING_SMOKE_ISSUE is not true; skipping issue creation"
  exit 0
fi

if [[ -z "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]]; then
  echo "No GH_TOKEN/GITHUB_TOKEN available; skipping issue creation"
  exit 0
fi

repo="${GITHUB_REPOSITORY:-MyAiDevs/livemask-ci-cd}"
run_id="${GITHUB_RUN_ID:-unknown}"
run_attempt="${GITHUB_RUN_ATTEMPT:-1}"
sha="${GITHUB_SHA:-unknown}"
short_sha="${sha:0:12}"
ref_name="${GITHUB_REF_NAME:-dev}"
workflow="${GITHUB_WORKFLOW:-Staging Smoke}"
server_url="${GITHUB_SERVER_URL:-https://github.com}"
run_url="${server_url}/${repo}/actions/runs/${run_id}"
status_file="${RUNTIME_STATUS_FILE:-/tmp/livemask-runtime/status.json}"
title="[auto][staging-smoke] Staging Smoke failure needs Cursor triage"
label="staging-smoke-failure"
token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

github_api() {
  local method="$1"
  local path="$2"
  local data_file="${3:-}"
  if [[ -n "${data_file}" ]]; then
    curl -fsS \
      -X "${method}" \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${token}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      --data @"${data_file}" \
      "https://api.github.com${path}"
  else
    curl -fsS \
      -X "${method}" \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${token}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com${path}"
  fi
}

json_payload_file() {
  local output_file="$1"
  local title_arg="${2:-}"
  local body_file_arg="${3:-}"
  local labels_arg="${4:-}"
  python3 - "${output_file}" "${title_arg}" "${body_file_arg}" "${labels_arg}" <<'PY'
import json
import sys

output_file, title, body_file, labels = sys.argv[1:5]
payload = {}
if title:
    payload["title"] = title
if body_file:
    with open(body_file, "r", encoding="utf-8") as fh:
        payload["body"] = fh.read()
if labels:
    payload["labels"] = [item for item in labels.split(",") if item]
with open(output_file, "w", encoding="utf-8") as fh:
    json.dump(payload, fh)
PY
}

issue_number=""
if command -v gh >/dev/null 2>&1; then
  export GH_TOKEN="${token}"
  issue_number="$(
    gh issue list \
      --repo "${repo}" \
      --state open \
      --search "\"${title}\" in:title" \
      --json number \
      --jq '.[0].number // empty' 2>/dev/null || true
  )"
else
  echo "gh CLI is not available; using GitHub REST API fallback"
  issues_json="$(mktemp)"
  if github_api GET "/repos/${repo}/issues?state=open&per_page=100" >"${issues_json}" 2>/dev/null; then
    issue_number="$(
      python3 - "${issues_json}" "${title}" <<'PY'
import json
import sys

path, expected = sys.argv[1:3]
with open(path, "r", encoding="utf-8") as fh:
    issues = json.load(fh)
for issue in issues:
    if issue.get("title") == expected and "pull_request" not in issue:
        print(issue.get("number", ""))
        break
PY
    )"
  else
    echo "WARN: unable to list existing issues via GitHub REST API"
  fi
  rm -f "${issues_json}"
fi

status_summary="Runtime status artifact was not available."
if [[ -f "${status_file}" ]]; then
  status_summary="$(
    python3 - "${status_file}" <<'PY' 2>/dev/null || echo "Runtime status artifact could not be parsed."
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

containers = data.get("containers") or []
health = data.get("health") or {}
lines = []
if "compose_up" in data:
    lines.append(f"- compose_up: {data.get('compose_up')}")
if containers:
    running = sum(1 for c in containers if str(c.get("state", "")).lower() == "running")
    lines.append(f"- containers: {running}/{len(containers)} running")
    names = [c.get("name") for c in containers if c.get("name")]
    if names:
        lines.append("- service_names: " + ", ".join(names))
if health:
    for key, value in health.items():
        lines.append(f"- {key}: {value}")
print("\n".join(lines) if lines else "Runtime status artifact contained no summary fields.")
PY
  )"
fi

body_file="$(mktemp)"
cat >"${body_file}" <<EOF
## Auto-created Staging Smoke failure

The Staging Smoke workflow failed and needs Cursor triage.

### Failure Evidence

- Repository: \`${repo}\`
- Workflow: \`${workflow}\`
- Run: ${run_url}
- Run ID: \`${run_id}\`
- Attempt: \`${run_attempt}\`
- Ref: \`${ref_name}\`
- Commit: \`${short_sha}\`

### Runtime Snapshot

${status_summary}

### Cursor Task Brief

Investigate the failed Staging Smoke run, identify the exact failing smoke script/step, implement the smallest repo-scoped fix, add a local/offline self-test or fixture where possible, then merge through dev-merge-guard and include the GitHub run ID in the completion report.

### Acceptance

- The root cause is documented in the issue or completion report.
- A local self-test or fixture covers the failure mode when feasible.
- \`Staging Smoke\` passes on \`origin/dev\`.
- Lark notification contains enough detail to understand the failure without opening GitHub first.
EOF

if command -v gh >/dev/null 2>&1; then
  gh label create "${label}" \
    --repo "${repo}" \
    --color "D93F0B" \
    --description "Automatically created from Staging Smoke failure" >/dev/null 2>&1 || true
fi

payload_file="$(mktemp)"
if [[ -n "${issue_number}" ]]; then
  if command -v gh >/dev/null 2>&1; then
    gh issue comment "${issue_number}" --repo "${repo}" --body-file "${body_file}"
  else
    json_payload_file "${payload_file}" "" "${body_file}" ""
    github_api POST "/repos/${repo}/issues/${issue_number}/comments" "${payload_file}" >/dev/null
  fi
  echo "Updated existing Staging Smoke failure issue #${issue_number}"
else
  if command -v gh >/dev/null 2>&1; then
    gh issue create \
      --repo "${repo}" \
      --title "${title}" \
      --label "${label}" \
      --body-file "${body_file}"
  else
    json_payload_file "${payload_file}" "${title}" "${body_file}" "${label}"
    github_api POST "/repos/${repo}/issues" "${payload_file}"
  fi
fi

rm -f "${body_file}" "${payload_file}"
