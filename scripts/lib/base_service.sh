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

lm_runtime_status_report() {
  echo "Runtime endpoints:"
  echo "  Backend:     $(lm_backend_base_url) (container=${LIVEMASK_BACKEND_CONTAINER})"
  echo "  Admin:       $(lm_admin_base_url) (container=${LIVEMASK_ADMIN_CONTAINER})"
  echo "  Website:     $(lm_website_base_url) (container=${LIVEMASK_WEBSITE_CONTAINER})"
  echo "  Job Service: $(lm_job_service_url) (container=${LIVEMASK_JOB_SERVICE_CONTAINER})"
  echo "  NodeAgent:   http://127.0.0.1:${LIVEMASK_NODEAGENT_PORT} (container=${LIVEMASK_NODEAGENT_CONTAINER})"
}
