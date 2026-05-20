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
BACKEND_PORT="${LIVEMASK_BACKEND_HTTP_PORT:-18080}"
ADMIN_PORT="${LIVEMASK_ADMIN_PORT:-3001}"
WEBSITE_PORT="${LIVEMASK_WEBSITE_PORT:-3002}"
JOB_PORT="${LIVEMASK_JOB_SERVICE_PORT:-19191}"
POSTGRES_HOST_PORT="${POSTGRES_PORT:-15432}"
REDIS_HOST_PORT="${REDIS_PORT:-16379}"

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

BACKEND_REF_VALUE="$(collect_ref "BACKEND_REF" "livemask-backend" "dev")"
JOB_SERVICE_REF_VALUE="$(collect_ref "JOB_SERVICE_REF" "livemask-job-service" "dev")"
ADMIN_REF_VALUE="$(collect_ref "ADMIN_REF" "livemask-admin" "dev")"
WEBSITE_REF_VALUE="$(collect_ref "WEBSITE_REF" "livemask-website" "dev")"
APP_REF_VALUE="$(collect_ref "APP_REF" "livemask-app" "dev")"
NODEAGENT_REF_VALUE="$(collect_ref "NODEAGENT_REF" "livemask-nodeagent" "dev")"

bool_json() {
  case "$1" in
    true|TRUE|True|1|yes|YES) echo "true" ;;
    *) echo "false" ;;
  esac
}

http_code_with_retries() {
  local url="$1"
  local attempts="${2:-15}"
  local delay="${3:-2}"
  local code="000"

  for attempt in $(seq 1 "${attempts}"); do
    code="$(curl -sS --max-time 3 -o /dev/null -w "%{http_code}" "${url}" 2>/dev/null || true)"
    if [[ "${code}" =~ ^(200|301|302|307|308)$ ]]; then
      echo "${code}"
      return 0
    fi
    sleep "${delay}"
  done

  if [[ -z "${code}" ]]; then
    code="000"
  fi
  echo "${code}"
  return 1
}

# ============================================================
# 3. Health endpoints
# ============================================================
HEALTH_RESULTS="[]"
HEALTH_ALL_PASS=true
HEALTH_DETAILS=""

if [[ "${COLLECT_ONLY}" == "false" ]] && docker info &>/dev/null; then
  # Backend health
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

  # Admin and website HTTP reachability
  ADMIN_URL="http://127.0.0.1:${ADMIN_PORT}/login"
  ADMIN_CODE=$(http_code_with_retries "${ADMIN_URL}" 20 2 || true)
  if [[ "${ADMIN_CODE}" =~ ^(200|301|302|307|308)$ ]]; then
    HEALTH_DETAILS+="admin page: HTTP ${ADMIN_CODE}\n"
  else
    HEALTH_ALL_PASS=false
    HEALTH_DETAILS+="admin page: HTTP ${ADMIN_CODE} (${ADMIN_URL})\n"
  fi

  WEBSITE_URL="http://127.0.0.1:${WEBSITE_PORT}/"
  WEBSITE_CODE=$(http_code_with_retries "${WEBSITE_URL}" 10 2 || true)
  if [[ "${WEBSITE_CODE}" =~ ^(200|301|302|307|308)$ ]]; then
    HEALTH_DETAILS+="website page: HTTP ${WEBSITE_CODE}\n"
  else
    HEALTH_ALL_PASS=false
    HEALTH_DETAILS+="website page: HTTP ${WEBSITE_CODE} (${WEBSITE_URL})\n"
  fi
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
COMPOSE_UP_DETECTED_JSON="$(bool_json "${COMPOSE_UP_DETECTED}")"
ALL_CONTAINERS_UP_JSON="$(bool_json "${ALL_CONTAINERS_UP}")"
HEALTH_ALL_PASS_JSON="$(bool_json "${HEALTH_ALL_PASS}")"

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
    'host_port_map': {
        'backend': '${BACKEND_PORT}->8080',
        'admin': '${ADMIN_PORT}->3000',
        'website': '${WEBSITE_PORT}->3000/5173',
        'job-service': '${JOB_PORT}->19191',
        'postgres': '${POSTGRES_HOST_PORT}->5432',
        'redis': '${REDIS_HOST_PORT}->6379'
    },
    'host_health_urls': {
        'backend': 'http://127.0.0.1:${BACKEND_PORT}/api/v1/health',
        'admin': 'http://127.0.0.1:${ADMIN_PORT}/login',
        'website': 'http://127.0.0.1:${WEBSITE_PORT}/',
        'job-service': 'http://127.0.0.1:${JOB_PORT}/health'
    },
    'compose_up_detected': json.loads('${COMPOSE_UP_DETECTED_JSON}'),
    'all_containers_up': json.loads('${ALL_CONTAINERS_UP_JSON}'),
    'container_summary': '${CONTAINER_SUMMARY}',
    'containers': ${CONTAINER_JSON},
    'failed_containers': '${FAILED_CONTAINERS}',
    'refs': {
        'BACKEND_REF': '${BACKEND_REF_VALUE}',
        'JOB_SERVICE_REF': '${JOB_SERVICE_REF_VALUE}',
        'ADMIN_REF': '${ADMIN_REF_VALUE}',
        'WEBSITE_REF': '${WEBSITE_REF_VALUE}',
        'NODEAGENT_REF': '${NODEAGENT_REF_VALUE}'
    },
    'local_only_refs': {
        'APP_REF': '${APP_REF_VALUE}'
    },
    'compose_up_result': '${COMPOSE_UP_DETECTED}',
    'health_all_pass': json.loads('${HEALTH_ALL_PASS_JSON}'),
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
