#!/usr/bin/env bash
# Shared service discovery and Docker dev-local helpers for smoke scripts.
#
# This file intentionally keeps helpers small and shell-portable. Smoke scripts
# may still use direct curl for API calls, but service readiness and Admin page
# checks should go through these helpers so local Docker/runtime differences are
# reported consistently.

if [[ -n "${LIVEMASK_BASE_SERVICE_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
LIVEMASK_BASE_SERVICE_SH_LOADED=1

LIVEMASK_BACKEND_HTTP_PORT="${LIVEMASK_BACKEND_HTTP_PORT:-18080}"
LIVEMASK_ADMIN_HTTP_PORT="${LIVEMASK_ADMIN_HTTP_PORT:-3001}"
LIVEMASK_WEBSITE_PORT="${LIVEMASK_WEBSITE_PORT:-3002}"
LIVEMASK_NODEAGENT_PORT="${LIVEMASK_NODEAGENT_PORT:-19090}"
LIVEMASK_JOB_SERVICE_PORT="${LIVEMASK_JOB_SERVICE_PORT:-19191}"

LIVEMASK_BACKEND_CONTAINER="${LIVEMASK_BACKEND_CONTAINER:-livemask-local-backend-1}"
LIVEMASK_ADMIN_CONTAINER="${LIVEMASK_ADMIN_CONTAINER:-livemask-local-admin-1}"
LIVEMASK_WEBSITE_CONTAINER="${LIVEMASK_WEBSITE_CONTAINER:-livemask-local-website-1}"
LIVEMASK_NODEAGENT_CONTAINER="${LIVEMASK_NODEAGENT_CONTAINER:-livemask-local-nodeagent-1}"
LIVEMASK_JOB_SERVICE_CONTAINER="${LIVEMASK_JOB_SERVICE_CONTAINER:-livemask-local-job-service-1}"

lm_backend_base_url() {
  printf 'http://127.0.0.1:%s' "${LIVEMASK_BACKEND_HTTP_PORT}"
}

lm_admin_base_url() {
  printf 'http://127.0.0.1:%s' "${LIVEMASK_ADMIN_HTTP_PORT}"
}

lm_website_base_url() {
  printf 'http://127.0.0.1:%s' "${LIVEMASK_WEBSITE_PORT}"
}

lm_job_service_url() {
  printf 'http://127.0.0.1:%s' "${LIVEMASK_JOB_SERVICE_PORT}"
}

lm_http_code() {
  local url="$1"
  curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "${url}" 2>/dev/null || echo "000"
}

lm_container_http_code() {
  local container="$1"
  local path="$2"
  local port="$3"
  docker exec "${container}" sh -lc "wget -q --spider -S 'http://127.0.0.1:${port}${path}' 2>&1 | awk '/HTTP\\// {code=\$2} END {print code ? code : \"000\"}'" 2>/dev/null || echo "000"
}

lm_container_get() {
  local container="$1"
  local path="$2"
  local port="$3"
  docker exec "${container}" sh -lc "wget -qO- 'http://127.0.0.1:${port}${path}'" 2>/dev/null
}

lm_backend_health_json() {
  local host_url
  host_url="$(lm_backend_base_url)"
  local body
  body=$(curl -sS --max-time 3 "${host_url}/api/v1/health" 2>/dev/null || true)
  if [[ -n "${body}" ]]; then
    printf '%s' "${body}"
    return 0
  fi
  lm_container_get "${LIVEMASK_BACKEND_CONTAINER}" "/api/v1/health" "8080" || true
}

lm_backend_ready() {
  lm_backend_health_json | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('status')=='ok' else 1)" 2>/dev/null
}

lm_backend_host_ready() {
  local code
  code=$(lm_http_code "$(lm_backend_base_url)/api/v1/health")
  [[ "${code}" == "200" ]]
}

lm_admin_page_http() {
  local page="$1"
  local code
  code=$(lm_http_code "$(lm_admin_base_url)${page}")
  if [[ "${code}" == "000" ]]; then
    code=$(lm_container_http_code "${LIVEMASK_ADMIN_CONTAINER}" "${page}" "3000")
  fi
  echo "${code}"
}

# ---------------------------------------------------------------------------
# Workspace path validation
# ---------------------------------------------------------------------------

# Default workspace root — callers can override via LIVEMASK_WORKSPACE_ROOT.
LIVEMASK_WORKSPACE_ROOT="${LIVEMASK_WORKSPACE_ROOT:-$HOME/Developer/LiveMask}"

# List of canonical repos expected under the workspace root.
LIVEMASK_REPOS=(livemask-docs livemask-backend livemask-admin livemask-website
                livemask-app livemask-nodeagent livemask-job-service
                livemask-ci-cd)

lm_workspace_check() {
  local current_dir="$PWD"
  local ws_root="${LIVEMASK_WORKSPACE_ROOT}"

  echo "=== Workspace Path Check ==="
  echo "  Current dir: ${current_dir}"
  echo "  Workspace root: ${ws_root}"

  # 1. Ban old Documents path
  if [[ "${current_dir}" == "/Users/sammytan/Documents/New project 2"* ]]; then
    echo "  FAIL: Old workspace path detected.  Stop and reopen under ${ws_root}." >&2
    return 1
  fi

  # 2. Workspace root must be a directory
  if [[ ! -d "${ws_root}" ]]; then
    echo "  FAIL: Workspace root does not exist: ${ws_root}" >&2
    return 1
  fi
  echo "  * Workspace root exists."

  # 3. Current repo should live under the workspace root
  if [[ "${current_dir}" != "${ws_root}"* ]]; then
    echo "  WARN: Current directory is outside the canonical workspace root."
    echo "        Expected prefix: ${ws_root}"
  else
    echo "  * Current directory is inside the workspace root."
  fi

  # 4. Check essential repos exist (non-fatal warning for missing ones)
  local missing=0
  for repo in "${LIVEMASK_REPOS[@]}"; do
    if [[ -d "${ws_root}/${repo}/.git" ]]; then
      echo "  * ${repo}: present"
    else
      echo "  WARN: ${repo} not found under ${ws_root}" >&2
      missing=$((missing + 1))
    fi
  done

  # 5. Docker runtime check
  if command -v docker &>/dev/null; then
    echo "  * docker CLI is available."
    if docker info &>/dev/null; then
      echo "  * docker daemon is running."
    else
      echo "  WARN: docker daemon is not running (or permission denied)." >&2
    fi
  else
    echo "  WARN: docker CLI not found." >&2
  fi

  echo "=== Workspace Path Check complete (${missing} repo(s) missing) ==="
  return 0
}

lm_runtime_status_report() {
  echo "Runtime endpoints:"
  echo "  Backend:     $(lm_backend_base_url) (container=${LIVEMASK_BACKEND_CONTAINER})"
  echo "  Admin:       $(lm_admin_base_url) (container=${LIVEMASK_ADMIN_CONTAINER})"
  echo "  Website:     $(lm_website_base_url) (container=${LIVEMASK_WEBSITE_CONTAINER})"
  echo "  Job Service: $(lm_job_service_url) (container=${LIVEMASK_JOB_SERVICE_CONTAINER})"
  echo "  NodeAgent:   http://127.0.0.1:${LIVEMASK_NODEAGENT_PORT} (container=${LIVEMASK_NODEAGENT_CONTAINER})"
}

# ---------------------------------------------------------------------------
# Compose file detection and DB helpers (shared across smoke scripts)
# ---------------------------------------------------------------------------
# Usage:
#   source scripts/lib/base_service.sh
#   LM_COMPOSE_FILE="$(lm_detect_compose_file)"
#   lm_pg_exec -c "SELECT 1"
#
# Callers may override the service name to check (default: postgres).

lm_detect_compose_file() {
  local service="${1:-postgres}"
  local candidate
  # Check local first (takes precedence)
  for candidate in "infra/docker-compose.local.yml" "infra/docker-compose.staging.yml"; do
    if [[ -f "${candidate}" ]] && docker compose -f "${candidate}" ps -q "${service}" &>/dev/null 2>&1; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  # Fallback
  printf '%s' "${LM_COMPOSE_FILE:-infra/docker-compose.staging.yml}"
}

lm_pg_exec() {
  local compose_file="${LM_COMPOSE_FILE:-infra/docker-compose.staging.yml}"
  docker compose -f "${compose_file}" exec -T postgres psql -U livemask -tA "$@" 2>/dev/null || true
}
