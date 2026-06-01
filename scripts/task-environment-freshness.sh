#!/usr/bin/env bash
set -euo pipefail

# Verify that a task starts from fresh local code and a healthy remote dev
# runtime deployment signal. This script never mutates worktrees beyond fetch.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIVEMASK_ROOT="${LIVEMASK_ROOT:-$HOME/Developer/LiveMask}"

TASK_ID=""
TASK_REPO=""
OUTPUT_FILE="${ROLE_CACHE_DIR:-${HOME}/.claude/role-cache}/task-environment-freshness.json"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/task-environment-freshness.sh --task-id TASK-ID --repo livemask-backend [options]

Options:
  --task-id TASK-ID  Current TASK-*.
  --repo REPO        Target repo, e.g. livemask-backend.
  --output FILE      JSON output path.
  --help             Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id) TASK_ID="${2:-}"; shift 2 ;;
    --repo) TASK_REPO="${2:-}"; shift 2 ;;
    --output) OUTPUT_FILE="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$(dirname "${OUTPUT_FILE}")" /tmp/claude 2>/dev/null || true
if ! { : >"${OUTPUT_FILE}"; } 2>/dev/null; then
  OUTPUT_FILE="/tmp/claude/$(basename "${OUTPUT_FILE}")"
  : >"${OUTPUT_FILE}" 2>/dev/null || {
    echo "ERROR: cannot write task environment freshness output" >&2
    exit 1
  }
fi

repos=()
for repo in livemask-docs livemask-ci-cd "${TASK_REPO}"; do
  [[ -z "${repo}" ]] && continue
  found=false
  for existing in "${repos[@]:-}"; do
    [[ "${existing}" == "${repo}" ]] && found=true && break
  done
  [[ "${found}" == "false" ]] && repos+=("${repo}")
done

tmp_json="$(mktemp)"
trap 'rm -f "${tmp_json}"' EXIT
printf '[' >"${tmp_json}"
first=true

for repo in "${repos[@]}"; do
  repo_path="${LIVEMASK_ROOT}/${repo}"
  if [[ ! -d "${repo_path}/.git" ]]; then
    $first || printf ',' >>"${tmp_json}"
    first=false
    python3 - "${repo}" >>"${tmp_json}" <<'PY'
import json, sys
print(json.dumps({"repo": sys.argv[1], "present": False, "status": "missing"}))
PY
    continue
  fi

  git -C "${repo_path}" fetch origin dev >/dev/null 2>&1 || true
  current_branch="$(git -C "${repo_path}" branch --show-current 2>/dev/null || true)"
  head="$(git -C "${repo_path}" rev-parse --short HEAD 2>/dev/null || true)"
  origin_dev="$(git -C "${repo_path}" rev-parse --short origin/dev 2>/dev/null || true)"
  dirty_count="$(git -C "${repo_path}" status --porcelain 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
  origin_is_ancestor=false
  if git -C "${repo_path}" merge-base --is-ancestor origin/dev HEAD >/dev/null 2>&1; then
    origin_is_ancestor=true
  fi
  dev_is_at_origin=false
  if [[ "${current_branch}" == "dev" && -n "${origin_dev}" && "${head}" == "${origin_dev}" ]]; then
    dev_is_at_origin=true
  fi
  local_ok=false
  if [[ "${dirty_count}" -eq 0 && ( "${dev_is_at_origin}" == "true" || "${origin_is_ancestor}" == "true" ) ]]; then
    local_ok=true
  fi

  $first || printf ',' >>"${tmp_json}"
  first=false
  python3 - "${repo}" "${repo_path}" "${current_branch}" "${head}" "${origin_dev}" "${dirty_count}" "${origin_is_ancestor}" "${dev_is_at_origin}" "${local_ok}" >>"${tmp_json}" <<'PY'
import json, sys
repo, path, branch, head, origin_dev, dirty, ancestor, dev_at_origin, local_ok = sys.argv[1:10]
print(json.dumps({
    "repo": repo,
    "path": path,
    "present": True,
    "branch": branch,
    "head": head,
    "origin_dev": origin_dev,
    "dirty_count": int(dirty or 0),
    "origin_dev_is_ancestor_of_head": ancestor == "true",
    "dev_branch_at_origin_dev": dev_at_origin == "true",
    "local_fresh": local_ok == "true",
}))
PY
done
printf ']' >>"${tmp_json}"

remote_json='{}'
if command -v gh >/dev/null 2>&1; then
  remote_json="$(gh run list \
    --repo MyAiDevs/livemask-ci-cd \
    --workflow dev-runtime-deploy.yml \
    --branch dev \
    --limit 1 \
    --json databaseId,status,conclusion,headSha,url,createdAt 2>/dev/null || echo '{}')"
fi

ci_cd_origin="$(git -C "${REPO_DIR}" rev-parse origin/dev 2>/dev/null || true)"

python3 - "${tmp_json}" "${OUTPUT_FILE}" "${TASK_ID}" "${TASK_REPO}" "${remote_json}" "${ci_cd_origin}" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

repos = json.load(open(sys.argv[1]))
out = Path(sys.argv[2])
task_id, task_repo, remote_raw, ci_cd_origin = sys.argv[3:7]
try:
    remote_runs = json.loads(remote_raw)
except Exception:
    remote_runs = []
if isinstance(remote_runs, dict):
    remote_runs = []
latest = remote_runs[0] if remote_runs else {}
remote_ok = (
    latest.get("status") == "completed"
    and latest.get("conclusion") == "success"
    and (not ci_cd_origin or str(latest.get("headSha", "")).startswith(ci_cd_origin[:12]))
)
issues = []
for repo in repos:
    if not repo.get("present"):
        issues.append(f"{repo.get('repo')} missing locally")
    elif not repo.get("local_fresh"):
        issues.append(
            f"{repo.get('repo')} not fresh: branch={repo.get('branch')} head={repo.get('head')} "
            f"origin/dev={repo.get('origin_dev')} dirty={repo.get('dirty_count')}"
        )
if not remote_ok:
    issues.append(
        "remote dev runtime deploy is not verified at current ci-cd origin/dev "
        f"(status={latest.get('status','none')} conclusion={latest.get('conclusion','none')})"
    )

data = {
    "schema_version": 1,
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "task_id": task_id,
    "task_repo": task_repo,
    "status": "ok" if not issues else "warn",
    "local_repos": repos,
    "remote_runtime": {
        "verified": remote_ok,
        "ci_cd_origin_dev": ci_cd_origin[:12] if ci_cd_origin else "",
        "latest_dev_runtime_deploy": latest,
    },
    "issues": issues,
}
out.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
print(f"task-environment-freshness: status={data['status']} issues={len(issues)} output={out}")
for issue in issues[:6]:
    print(f"  - {issue}")
PY
