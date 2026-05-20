#!/usr/bin/env bash
# TASK-CICD-RUNNER-BACKLOG-001 — Collect runtime status evidence for Lark notification.
#
# Collects:
#   - Git refs of all LiveMask repos
#   - Docker compose container status
#   - Health endpoint results (backend + job-service)
#   - Error logs from failed/exited containers
#
# Output: JSON to stdout, or file path via --output.
#
# Usage:
#   bash scripts/dev-runtime-status.sh [options]
#
# Options:
#   --compose FILE   Docker compose file (default: infra/docker-compose.staging.yml)
#   --env TYPE       Environment type: staging or dev (default: staging)
#   --output FILE    Write JSON status to FILE instead of stdout
#   --collect-only   Only collect status; skip health checks (for early failure)
#   --help           Show this help

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.staging.yml}"
ENV_TYPE="staging"
OUTPUT_FILE=""
COLLECT_ONLY=false

LIVEMASK_WORKSPACE_ROOT="${LIVEMASK_WORKSPACE_ROOT:-$HOME/Developer/LiveMask}"

# ============================================================
# Parse args
# ============================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --compose)  COMPOSE_FILE="${2:-}"; shift 2 ;;
    --env)      ENV_TYPE="${2:-staging}"; shift 2 ;;
    --output)   OUTPUT_FILE="${2:-}"; shift 2 ;;
    --collect-only) COLLECT_ONLY=true; shift ;;
    --help|-h)  sed -n '3,/^# =/p' "${BASH_SOURCE[0]}" | sed 's/^# //;s/^#$//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ============================================================
# Resolve compose file path
# ============================================================
if [[ ! "${COMPOSE_FILE}" == /* ]]; then
  COMPOSE_FILE="${REPO_ROOT}/${COMPOSE_FILE}"
fi
COMPOSE_DIR="$(cd "$(dirname "${COMPOSE_FILE}")" && pwd)"
COMPOSE_BASENAME="$(basename "${COMPOSE_FILE}")"

# ============================================================
# Runner host info
# ============================================================
HOSTNAME="$(hostname 2>/dev/null || echo 'unknown')"
UPTIME="$(uptime 2>/dev/null | sed 's/,.*//' || echo 'unknown')"

# ============================================================
# 1. Container status via docker compose ps
# ============================================================
CONTAINER_JSON="[]"
CONTAINER_SUMMARY=""
FAILED_CONTAINERS=""
ALL_CONTAINERS_UP=true
COMPOSE_UP_DETECTED=false

if docker info &>/dev/null; then
  COMPOSE_PROJECT="livemask-${ENV_TYPE}"
  # Detect if compose file exists
  if [[ -f "${COMPOSE_FILE}" ]]; then
    # Check if any containers are running
    PS_OUTPUT=$(docker compose -f "${COMPOSE_FILE}" ps --format json 2>/dev/null || true)
    if [[ -n "${PS_OUTPUT}" ]]; then
      CONTAINER_JSON="["
      first=true
      while IFS= read -r line; do
        if [[ -z "$line" ]]; then continue; fi
        $first || CONTAINER_JSON+=","
        first=false
        CONTAINER_JSON+="$line"

        # Parse individual container status
        name=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('Name',''))" 2>/dev/null || echo "")
        state=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('State',''))" 2>/dev/null || echo "")
        status=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('Status',''))" 2>/dev/null || echo "")

        if [[ "${state}" != "running" ]]; then
          ALL_CONTAINERS_UP=false
          FAILED_CONTAINERS+="${name} (${state}: ${status})\n"
        fi
      done <<< "$PS_OUTPUT"
      CONTAINER_JSON+="]"

      COMPOSE_UP_DETECTED=true
      # Summary line
      RUNNING_COUNT=$(docker compose -f "${COMPOSE_FILE}" ps --filter "status=running" --format json 2>/dev/null | python3 -c "import sys,json; lines=[l for l in sys.stdin if l.strip()]; print(len(lines))" 2>/dev/null || echo 0)
      TOTAL_COUNT=$(echo "$CONTAINER_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
      CONTAINER_SUMMARY="${RUNNING_COUNT}/${TOTAL_COUNT} running"
    fi
  fi
fi

# ============================================================
# 2. Git refs (from CI env vars or workspace repos)
# ============================================================
collect_ref() {
  local var_name="$1"
  local repo_name="$2"
  local default_val="$3"
  local ref="${!var_name:-${default_val}}"
  local commit=""

  # Try to get actual commit from workspace
  local ws_repo="${LIVEMASK_WORKSPACE_ROOT}/${repo_name}"
  if [[ -d "${ws_repo}/.git" ]]; then
    commit="$(git -C "${ws_repo}" rev-parse --short HEAD 2>/dev/null || echo "")"
  fi

  if [[ -n "$commit" ]]; then
    echo "${ref} (${commit})"
  else
    echo "${ref}"
  fi
}

declare -A REF_MAP
REF_MAP["BACKEND_REF"]="$(collect_ref "BACKEND_REF" "livemask-backend" "dev")"
REF_MAP["JOB_SERVICE_REF"]="$(collect_ref "JOB_SERVICE_REF" "livemask-job-service" "dev")"
REF_MAP["ADMIN_REF"]="$(collect_ref "ADMIN_REF" "livemask-admin" "dev")"
REF_MAP["WEBSITE_REF"]="$(collect_ref "WEBSITE_REF" "livemask-website" "dev")"
REF_MAP["APP_REF"]="$(collect_ref "APP_REF" "livemask-app" "dev")"
REF_MAP["NODEAGENT_REF"]="$(collect_ref "NODEAGENT_REF" "livemask-nodeagent" "dev")"

# ============================================================
# 3. Health endpoints
# ============================================================
HEALTH_RESULTS="[]"
HEALTH_ALL_PASS=true
HEALTH_DETAILS=""

if [[ "${COLLECT_ONLY}" == "false" ]] && docker info &>/dev/null; then
  # Backend health
  BACKEND_PORT="${LIVEMASK_BACKEND_HTTP_PORT:-18080}"
  BE_HEALTH_URL="http://127.0.0.1:${BACKEND_PORT}/api/v1/health"
  BE_HEALTH_RESPONSE=""
  BE_HEALTH_OK=false
  BE_HEALTH="unknown"

  for attempt in $(seq 1 5); do
    BE_HEALTH_RESPONSE=$(curl -sS --max-time 3 "${BE_HEALTH_URL}" 2>/dev/null || true)
    if [[ -n "${BE_HEALTH_RESPONSE}" ]]; then
      BE_HEALTH_OK=true
      BE_HEALTH=$(echo "${BE_HEALTH_RESPONSE}" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    s=d.get('status','unknown')
    db=d.get('db_connected','?')
    redis=d.get('redis_connected','?')
    print(f'status={s}, db={db}, redis={redis}')
except: print('parse_error')
" 2>/dev/null || echo "parse_error")
      break
    fi
    sleep 2
  done

  if [[ "${BE_HEALTH_OK}" != "true" ]]; then
    HEALTH_ALL_PASS=false
    HEALTH_DETAILS+="backend health: TIMEOUT (${BE_HEALTH_URL})\n"
  else
    if echo "${BE_HEALTH}" | grep -qv "status=ok"; then
      HEALTH_ALL_PASS=false
    fi
    HEALTH_DETAILS+="backend health: ${BE_HEALTH}\n"
  fi

  HEALTH_RESULTS=$(python3 -c "
import json
h=[{
  'service': 'backend',
  'endpoint': '${BE_HEALTH_URL}',
  'reachable': ${BE_HEALTH_OK},
  'result': '${BE_HEALTH}'
}]
print(json.dumps(h))
" 2>/dev/null || echo "$HEALTH_RESULTS")

  # Job-service health (if running)
  JOB_PORT="${LIVEMASK_JOB_SERVICE_PORT:-19191}"
  JS_HEALTH_URL="http://127.0.0.1:${JOB_PORT}/health"
  JS_HEALTH_RESPONSE=$(curl -sS --max-time 3 "${JS_HEALTH_URL}" 2>/dev/null || true)
  JS_HEALTH_OK=false
  if [[ -n "${JS_HEALTH_RESPONSE}" ]]; then
    JS_HEALTH_OK=true
    HEALTH_DETAILS+="job-service health: reachable\n"
  fi

  HEALTH_RESULTS=$(python3 -c "
import json
results = json.loads('''${HEALTH_RESULTS}''')
results.append({
  'service': 'job-service',
  'endpoint': '${JS_HEALTH_URL}',
  'reachable': ${JS_HEALTH_OK},
  'result': '${JS_HEALTH_RESPONSE}' if '${JS_HEALTH_RESPONSE}' else 'timeout'
})
print(json.dumps(results))
" 2>/dev/null || echo "$HEALTH_RESULTS")
fi

# ============================================================
# 4. Error excerpts from failed containers
# ============================================================
ERROR_EXCERPTS=""
if [[ -n "${FAILED_CONTAINERS}" ]]; then
  # Collect recent logs from each failed container
  while IFS= read -r fail_entry; do
    if [[ -z "$fail_entry" ]]; then continue; fi
    container_name=$(echo "$fail_entry" | cut -d' ' -f1)
    if docker inspect "${container_name}" &>/dev/null; then
      log_snippet=$(docker logs "${container_name}" --tail 30 2>&1 | head -30 || true)
      if [[ -n "${log_snippet}" ]]; then
        ERROR_EXCERPTS+="--- ${container_name} logs (last 30) ---\n${log_snippet}\n"
      fi
    fi
  done <<< "$(printf "%b" "${FAILED_CONTAINERS}")"
fi

# ============================================================
# 5. Assemble JSON
# ============================================================
STATUS_JSON=$(python3 -c "
import json

failed_containers = '''${FAILED_CONTAINERS}'''.strip()
health_details = '''${HEALTH_DETAILS}'''.strip()
error_excerpts = '''${ERROR_EXCERPTS}'''.strip()

result = {
    'schema_version': 1,
    'timestamp': '$(date -u +'%Y-%m-%dT%H:%M:%SZ')',
    'hostname': '${HOSTNAME}',
    'uptime': '${UPTIME}',
    'environment': '${ENV_TYPE}',
    'compose_file': '${COMPOSE_BASENAME}',
    'compose_project': 'livemask-${ENV_TYPE}',
    'compose_up_detected': ${COMPOSE_UP_DETECTED},
    'all_containers_up': ${ALL_CONTAINERS_UP},
    'container_summary': '${CONTAINER_SUMMARY}',
    'containers': ${CONTAINER_JSON},
    'failed_containers': '${FAILED_CONTAINERS}',
    'refs': {
        'BACKEND_REF': '${REF_MAP[BACKEND_REF]}',
        'JOB_SERVICE_REF': '${REF_MAP[JOB_SERVICE_REF]}',
        'ADMIN_REF': '${REF_MAP[ADMIN_REF]}',
        'WEBSITE_REF': '${REF_MAP[WEBSITE_REF]}',
        'APP_REF': '${REF_MAP[APP_REF]}',
        'NODEAGENT_REF': '${REF_MAP[NODEAGENT_REF]}'
    },
    'compose_up_result': '${COMPOSE_UP_DETECTED}',
    'health_all_pass': ${HEALTH_ALL_PASS},
    'health_details': health_details if health_details else '',
    'error_excerpts': error_excerpts if error_excerpts else ''
}

print(json.dumps(result, indent=2))
")

# ============================================================
# Output
# ============================================================
if [[ -n "${OUTPUT_FILE}" ]]; then
  echo "${STATUS_JSON}" > "${OUTPUT_FILE}"
  echo "${STATUS_JSON}"
else
  echo "${STATUS_JSON}"
fi
