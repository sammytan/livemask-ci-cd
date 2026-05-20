#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Prefer LIVEMASK_WORKSPACE_ROOT; fall back to parent of repo dir.
LIVEMASK_WORKSPACE_ROOT="${LIVEMASK_WORKSPACE_ROOT:-$(cd "${REPO_DIR}/.." && pwd)}"
WORKSPACE_DIR="${LIVEMASK_WORKSPACE_ROOT}"
RUNTIME_SH="${SCRIPT_DIR}/runtime.sh"

export LIVEMASK_BACKEND_HTTP_PORT="18080"
export LIVEMASK_ADMIN_PORT="3001"
export LIVEMASK_WEBSITE_PORT="3002"
export LIVEMASK_APP_WEB_PORT="3003"
export LIVEMASK_NODEAGENT_PORT="19090"
export LIVEMASK_JOB_SERVICE_PORT="19191"
export POSTGRES_PORT="15432"
export REDIS_PORT="16379"

command="${1:-help}"
if [[ $# -gt 0 ]]; then
  shift || true
fi

usage() {
  cat <<'EOF'
Usage:
  bash scripts/local-dev.sh start   [options]
  bash scripts/local-dev.sh sync    [options]  # pull clean repos and recreate selected services
  bash scripts/local-dev.sh status  [options]
  bash scripts/local-dev.sh logs    [options]
  bash scripts/local-dev.sh restart [options]  # explicit local runtime restart
  bash scripts/local-dev.sh stop    [options]  # explicit local runtime stop

Options:
  --services LIST       Comma-separated services: backend,admin,website,nodeagent,job-service,all.
                        Defaults to all for local-dev.sh.
  --no-pull             For sync only: recreate services without git pull.
  --auto-reload         Enable backend hot reload in local mode.
  --pull                Pull images before start/restart.
  --env-file FILE       Load a local runtime env file.
  --no-deps             Do not start local PostgreSQL/Redis containers.

Examples:
  bash scripts/local-dev.sh start
  bash scripts/local-dev.sh sync --services backend,nodeagent
  bash scripts/local-dev.sh sync --services admin,website
  bash scripts/local-dev.sh sync --services all
  bash scripts/local-dev.sh status
  bash scripts/local-dev.sh start --services backend,admin
  bash scripts/local-dev.sh logs --services backend

Fixed local ports:
  Backend   http://127.0.0.1:18080
  Admin     http://127.0.0.1:3001
  Website   http://127.0.0.1:3002
  App Web   http://127.0.0.1:3003
  NodeAgent http://127.0.0.1:19090
  JobSvc    http://127.0.0.1:19191
  Postgres  127.0.0.1:15432
  Redis     127.0.0.1:16379

Local Dev Runtime Permanent Rule:
  This script manages the long-lived livemask-local development runtime.
  Do not run stop/restart/cleanup unless the user explicitly asks for it.
  Staging smoke must use the isolated staging compose stack, not this script.
EOF
}

if [[ ! -f "${RUNTIME_SH}" ]]; then
  echo "runtime script not found: ${RUNTIME_SH}" >&2
  exit 1
fi

has_services_arg=false
for arg in "$@"; do
  if [[ "${arg}" == "--services" ]]; then
    has_services_arg=true
    break
  fi
done

runtime_args=(--mode local)
if [[ "${has_services_arg}" == "false" ]]; then
  runtime_args+=(--services all)
fi
runtime_args+=("$@")

expand_services() {
  local raw_services="all"
  local args=("$@")
  local i=0

  while [[ "${i}" -lt "${#args[@]}" ]]; do
    if [[ "${args[$i]}" == "--services" && $((i + 1)) -lt "${#args[@]}" ]]; then
      raw_services="${args[$((i + 1))]}"
      break
    fi
    i=$((i + 1))
  done

  local expanded=()
  IFS=',' read -r -a selected <<<"${raw_services}"
  for service in "${selected[@]}"; do
    case "${service}" in
      all)
        expanded+=(backend admin website nodeagent job-service)
        ;;
      backend|admin|website|nodeagent|job-service|app)
        expanded+=("${service}")
        ;;
      "")
        ;;
      *)
        echo "Unknown service for sync: ${service}" >&2
        exit 2
        ;;
    esac
  done

  printf '%s\n' "${expanded[@]}"
}

repo_for_service() {
  case "$1" in
    backend) echo "${WORKSPACE_DIR}/livemask-backend" ;;
    admin) echo "${WORKSPACE_DIR}/livemask-admin" ;;
    website) echo "${WORKSPACE_DIR}/livemask-website" ;;
    nodeagent) echo "${WORKSPACE_DIR}/livemask-nodeagent" ;;
    job-service) echo "${WORKSPACE_DIR}/livemask-job-service" ;;
    app) echo "${WORKSPACE_DIR}/livemask-app" ;;
    *) return 1 ;;
  esac
}

pull_repo_if_clean() {
  local service="$1"
  local repo
  repo="$(repo_for_service "${service}")"

  if [[ ! -d "${repo}/.git" ]]; then
    echo "[sync] ${service}: repo not found at ${repo}, skipping pull" >&2
    return 0
  fi

  if [[ -n "$(git -C "${repo}" status --porcelain)" ]]; then
    echo "[sync] ${service}: worktree is dirty, skipping git pull to avoid overwriting local/Cursor work" >&2
    git -C "${repo}" status --short >&2
    return 0
  fi

  echo "[sync] ${service}: git pull --ff-only origin dev"
  git -C "${repo}" pull --ff-only origin dev
}

has_service() {
  local wanted="$1"
  shift
  local service
  for service in "$@"; do
    [[ "${service}" == "${wanted}" ]] && return 0
  done
  return 1
}

recreate_local_services() {
  local services=("$@")
  local service_list
  service_list="$(IFS=','; echo "${services[*]}")"
  echo "[sync] recreating local services without docker compose down: ${service_list}"
  bash "${RUNTIME_SH}" start --mode local --services "${service_list}" --no-deps
}

wait_backend_health() {
  local url="http://127.0.0.1:${LIVEMASK_BACKEND_HTTP_PORT:-18080}/api/v1/health"
  local attempt

  for attempt in $(seq 1 30); do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      echo "[sync] backend health is ready"
      return 0
    fi
    sleep 1
  done

  echo "[sync] backend health was not ready after 30s; continuing" >&2
}

run_sync() {
  local sync_pull=true
  local clean_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-pull)
        sync_pull=false
        shift
        ;;
      *)
        clean_args+=("$1")
        shift
        ;;
    esac
  done

  services_to_sync=()
  while IFS= read -r service; do
    [[ -n "${service}" ]] && services_to_sync+=("${service}")
  done < <(expand_services "${clean_args[@]}")
  if [[ "${#services_to_sync[@]}" -eq 0 ]]; then
    echo "[sync] no services selected" >&2
    exit 2
  fi

  if [[ "${sync_pull}" == "true" ]]; then
    for service in "${services_to_sync[@]}"; do
      pull_repo_if_clean "${service}"
    done
  fi

  local docker_services=()
  for service in "${services_to_sync[@]}"; do
    case "${service}" in
      backend|admin|website|nodeagent|job-service)
        docker_services+=("${service}")
        ;;
      app)
        echo "[sync] app: Flutter app is not managed by Docker; use livemask-app/scripts/local-app.sh for build/run"
        ;;
    esac
  done

  if [[ "${#docker_services[@]}" -gt 0 ]]; then
    if has_service backend "${docker_services[@]}" && has_service nodeagent "${docker_services[@]}"; then
      local first_services=()
      local service
      for service in "${docker_services[@]}"; do
        [[ "${service}" != "nodeagent" ]] && first_services+=("${service}")
      done
      recreate_local_services "${first_services[@]}"
      wait_backend_health
      recreate_local_services nodeagent
    else
      recreate_local_services "${docker_services[@]}"
    fi
  fi
}

case "${command}" in
  start|status|logs|pull)
    exec bash "${RUNTIME_SH}" "${command}" "${runtime_args[@]}"
    ;;
  sync)
    run_sync "$@"
    ;;
  restart)
    echo "local-dev restart explicitly requested; this will recreate livemask-local containers." >&2
    exec bash "${RUNTIME_SH}" restart "${runtime_args[@]}"
    ;;
  stop|down)
    echo "local-dev stop explicitly requested; this will stop the long-lived livemask-local runtime." >&2
    exec bash "${RUNTIME_SH}" stop "${runtime_args[@]}"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    echo "Unknown command: ${command}" >&2
    usage >&2
    exit 2
    ;;
esac
