#!/usr/bin/env bash
set -euo pipefail

# Audit local Docker compose runtime logs for high-signal errors.
#
# This is read-only by default. With --create-issue, unrelated runtime errors
# are reported to a deduplicated GitHub Issue so they become visible backlog
# instead of disappearing into local logs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.local.yml}"
ENV_TYPE="${ENV_TYPE:-local}"
TAIL_LINES="${TAIL_LINES:-250}"
TASK_ID=""
TASK_REPO=""
OUTPUT_FILE="${ROLE_CACHE_DIR:-${HOME}/.claude/role-cache}/runtime-log-audit.json"
CREATE_ISSUE=false
ISSUE_REPO="${RUNTIME_LOG_ISSUE_REPO:-MyAiDevs/livemask-ci-cd}"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/runtime-log-audit.sh [options]

Options:
  --compose FILE       Compose file to inspect (default: infra/docker-compose.local.yml)
  --env NAME           Environment name for reports (default: local)
  --tail N             Log lines per service (default: 250)
  --task-id TASK-ID    Current TASK-* for related/unrelated classification
  --task-repo REPO     Current target repo, e.g. livemask-backend
  --output FILE        JSON output path
  --create-issue       Create/update a deduplicated GitHub issue for unrelated errors
  --issue-repo REPO    GitHub repo for runtime anomaly issues (default: MyAiDevs/livemask-ci-cd)
  --help               Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compose) COMPOSE_FILE="${2:-}"; shift 2 ;;
    --env) ENV_TYPE="${2:-local}"; shift 2 ;;
    --tail) TAIL_LINES="${2:-250}"; shift 2 ;;
    --task-id) TASK_ID="${2:-}"; shift 2 ;;
    --task-repo) TASK_REPO="${2:-}"; shift 2 ;;
    --output) OUTPUT_FILE="${2:-}"; shift 2 ;;
    --create-issue) CREATE_ISSUE=true; shift ;;
    --issue-repo) ISSUE_REPO="${2:-MyAiDevs/livemask-ci-cd}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ ! "${COMPOSE_FILE}" == /* ]]; then
  COMPOSE_FILE="${REPO_DIR}/${COMPOSE_FILE}"
fi

mkdir -p "$(dirname "${OUTPUT_FILE}")" /tmp/claude 2>/dev/null || true
if ! { : >"${OUTPUT_FILE}"; } 2>/dev/null; then
  OUTPUT_FILE="/tmp/claude/$(basename "${OUTPUT_FILE}")"
  : >"${OUTPUT_FILE}" 2>/dev/null || {
    echo "ERROR: cannot write runtime log audit output" >&2
    exit 1
  }
fi

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  python3 - "${OUTPUT_FILE}" <<'PY'
import json, sys
from pathlib import Path
out = Path(sys.argv[1])
out.write_text(json.dumps({
    "schema_version": 1,
    "status": "unavailable",
    "reason": "docker unavailable",
    "errors": [],
    "related_count": 0,
    "unrelated_count": 0,
}, indent=2), encoding="utf-8")
PY
  echo "runtime-log-audit: docker unavailable; wrote ${OUTPUT_FILE}"
  exit 0
fi

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  python3 - "${OUTPUT_FILE}" "${COMPOSE_FILE}" <<'PY'
import json, sys
from pathlib import Path
out = Path(sys.argv[1])
compose = sys.argv[2]
out.write_text(json.dumps({
    "schema_version": 1,
    "status": "unavailable",
    "reason": f"compose file not found: {compose}",
    "errors": [],
    "related_count": 0,
    "unrelated_count": 0,
}, indent=2), encoding="utf-8")
PY
  echo "runtime-log-audit: compose missing; wrote ${OUTPUT_FILE}"
  exit 0
fi

services="$(docker compose -f "${COMPOSE_FILE}" ps --services 2>/dev/null || true)"
if [[ -z "${services}" ]]; then
  python3 - "${OUTPUT_FILE}" "${COMPOSE_FILE}" "${ENV_TYPE}" <<'PY'
import json, sys
from pathlib import Path
out = Path(sys.argv[1])
out.write_text(json.dumps({
    "schema_version": 1,
    "status": "ok",
    "environment": sys.argv[3],
    "compose_file": sys.argv[2],
    "note": "compose has no created services",
    "errors": [],
    "related_count": 0,
    "unrelated_count": 0,
}, indent=2), encoding="utf-8")
PY
  echo "runtime-log-audit: no compose services; wrote ${OUTPUT_FILE}"
  exit 0
fi

raw_file="$(mktemp)"
trap 'rm -f "${raw_file}" "${body_file:-}"' EXIT

while IFS= read -r svc; do
  [[ -z "${svc}" ]] && continue
  echo "===== service:${svc} =====" >>"${raw_file}"
  docker compose -f "${COMPOSE_FILE}" logs --no-color --tail="${TAIL_LINES}" "${svc}" 2>/dev/null >>"${raw_file}" || true
done <<< "${services}"

python3 - "${raw_file}" "${OUTPUT_FILE}" "${COMPOSE_FILE}" "${ENV_TYPE}" "${TASK_ID}" "${TASK_REPO}" "${TAIL_LINES}" <<'PY'
import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

raw_path, out_path, compose_file, env_type, task_id, task_repo, tail_lines = sys.argv[1:8]
raw = Path(raw_path).read_text(encoding="utf-8", errors="ignore").splitlines()

service_repo = {
    "backend": "livemask-backend",
    "admin": "livemask-admin",
    "website": "livemask-website",
    "nodeagent": "livemask-nodeagent",
    "job-service": "livemask-job-service",
}

error_re = re.compile(r"\b(panic|fatal|traceback|segmentation fault|runtime error|uncaught|unhandled|exception|level=error|error:)\b", re.I)
noise_re = re.compile(r"(expected error|no error|error rate|errors=0|level=debug|webpack|compiled|hot reload|favicon|source map)", re.I)
secret_re = re.compile(r"(?i)(token|secret|password|authorization|api[_-]?key)=([^\\s]+)")

service = ""
errors = []
for line in raw:
    if line.startswith("===== service:") and line.endswith(" ====="):
        service = line[len("===== service:"):-len(" =====")]
        continue
    if not error_re.search(line) or noise_re.search(line):
        continue
    redacted = secret_re.sub(r"\1=<redacted>", line.strip())
    related = False
    reasons = []
    if task_id and task_id in redacted:
        related = True
        reasons.append("task_id")
    if task_repo and service_repo.get(service) == task_repo:
        related = True
        reasons.append("task_repo_service")
    errors.append({
        "service": service or "unknown",
        "line": redacted[:700],
        "related_to_current_task": related,
        "relation_reasons": reasons,
    })

related_count = sum(1 for e in errors if e["related_to_current_task"])
unrelated_count = len(errors) - related_count
fingerprint_src = "\n".join(f"{e['service']}:{e['line'][:180]}" for e in errors[:20])
fingerprint = hashlib.sha256(fingerprint_src.encode()).hexdigest()[:12] if errors else ""

out = {
    "schema_version": 1,
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "status": "warn" if errors else "ok",
    "environment": env_type,
    "compose_file": compose_file,
    "task_id": task_id,
    "task_repo": task_repo,
    "services": [s for s in sorted(set(service_repo) | {e["service"] for e in errors}) if s],
    "tail_lines": int(tail_lines) if str(tail_lines).isdigit() else 250,
    "error_count": len(errors),
    "related_count": related_count,
    "unrelated_count": unrelated_count,
    "fingerprint": fingerprint,
    "errors": errors[:40],
}
Path(out_path).write_text(json.dumps(out, indent=2, ensure_ascii=False), encoding="utf-8")
PY

issue_url=""
unrelated_count="$(python3 -c "import json; print(json.load(open('${OUTPUT_FILE}')).get('unrelated_count',0))" 2>/dev/null || echo 0)"
fingerprint="$(python3 -c "import json; print(json.load(open('${OUTPUT_FILE}')).get('fingerprint',''))" 2>/dev/null || true)"

if [[ "${CREATE_ISSUE}" == "true" && "${unrelated_count}" -gt 0 && -n "${fingerprint}" ]] && command -v gh >/dev/null 2>&1; then
  title="[auto][runtime-log] Unrelated ${ENV_TYPE} container log errors need triage (${fingerprint})"
  label="runtime-log-anomaly"
  gh label create "${label}" --repo "${ISSUE_REPO}" --color "B60205" --description "Automatically detected container log anomaly" >/dev/null 2>&1 || true
  issue_number="$(gh issue list --repo "${ISSUE_REPO}" --state open --search "\"${title}\" in:title" --json number --jq '.[0].number // empty' 2>/dev/null || true)"

  body_file="$(mktemp)"
  python3 - "${OUTPUT_FILE}" >"${body_file}" <<'PY'
import json
import sys
from pathlib import Path
d = json.load(open(sys.argv[1]))
print("## Runtime Log Audit")
print("")
print("Unrelated container log errors were detected during Claude/Codex loop preflight.")
print("")
print("### Evidence")
print(f"- environment: `{d.get('environment')}`")
print(f"- compose_file: `{d.get('compose_file')}`")
print(f"- task_id: `{d.get('task_id') or 'none'}`")
print(f"- task_repo: `{d.get('task_repo') or 'none'}`")
print(f"- unrelated_count: `{d.get('unrelated_count')}`")
print(f"- related_count: `{d.get('related_count')}`")
print(f"- fingerprint: `{d.get('fingerprint')}`")
print(f"- artifact: `{Path(sys.argv[1])}`")
print("")
print("### Sample Errors")
for e in d.get("errors", [])[:10]:
    if e.get("related_to_current_task"):
        continue
    print(f"- `{e.get('service')}`: {e.get('line')}")
print("")
print("### Expected Action")
print("Create or link a TASK-* for the affected service, reproduce locally, fix the smallest root cause, and rerun runtime-log-audit plus the relevant smoke.")
PY

  if [[ -n "${issue_number}" ]]; then
    gh issue comment "${issue_number}" --repo "${ISSUE_REPO}" --body-file "${body_file}" >/dev/null 2>&1 || true
    issue_url="https://github.com/${ISSUE_REPO}/issues/${issue_number}"
  else
    issue_url="$(gh issue create --repo "${ISSUE_REPO}" --title "${title}" --label "${label}" --body-file "${body_file}" 2>/dev/null || true)"
  fi
fi

if [[ -n "${issue_url}" ]]; then
  python3 - "${OUTPUT_FILE}" "${issue_url}" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text(encoding="utf-8"))
d["github_issue_url"] = sys.argv[2]
p.write_text(json.dumps(d, indent=2, ensure_ascii=False), encoding="utf-8")
PY
fi

python3 - "${OUTPUT_FILE}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"runtime-log-audit: status={d.get('status')} errors={d.get('error_count',0)} related={d.get('related_count',0)} unrelated={d.get('unrelated_count',0)} output={sys.argv[1]}")
if d.get("github_issue_url"):
    print(f"runtime-log-audit: issue={d.get('github_issue_url')}")
for e in d.get("errors", [])[:5]:
    marker = "related" if e.get("related_to_current_task") else "unrelated"
    print(f"  [{marker}] {e.get('service')}: {e.get('line')[:180]}")
PY
