#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

command="${1:-}"
if [[ -z "${command}" ]]; then
  command="help"
else
  shift || true
fi

env_file=""
compose_file="${REPO_DIR}/infra/docker-compose.local.yml"
runtime_mode="local"
services="backend"
with_deps=true
auto_reload=false
pull_images=false

usage() {
  cat <<'EOF'
Usage:
  bash scripts/runtime.sh start   [options]
  bash scripts/runtime.sh stop    [options]
  bash scripts/runtime.sh restart [options]
  bash scripts/runtime.sh status  [options]
  bash scripts/runtime.sh pull    [options]
  bash scripts/runtime.sh logs    [options]

Options:
  --env-file FILE          Load independent runtime config file.
  --compose FILE           Compose file to use. Defaults to infra/docker-compose.local.yml.
  --mode local|runtime     local=source-mounted containers, runtime=image deployment.
  --services LIST          Comma-separated: backend,admin,website,nodeagent,all.
  --no-deps                Do not start internal PostgreSQL/Redis containers.
  --auto-reload            Backend hot reload in local mode.
  --pull                   Pull images before start.

Examples:
  bash scripts/runtime.sh start --mode local --services all
  bash scripts/runtime.sh start --mode runtime --env-file infra/env/production.env --services backend,admin --no-deps
  bash scripts/runtime.sh restart --mode runtime --env-file infra/env/staging.env --services all
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      env_file="$2"
      shift 2
      ;;
    --compose)
      compose_file="$2"
      shift 2
      ;;
    --mode)
      case "$2" in
        local)
          runtime_mode="local"
          compose_file="${REPO_DIR}/infra/docker-compose.local.yml"
          ;;
        runtime)
          runtime_mode="runtime"
          compose_file="${REPO_DIR}/infra/docker-compose.runtime.yml"
          ;;
        *)
          echo "Unknown mode: $2" >&2
          exit 2
          ;;
      esac
      shift 2
      ;;
    --services)
      services="$2"
      shift 2
      ;;
    --no-deps)
      with_deps=false
      shift
      ;;
    --auto-reload)
      auto_reload=true
      shift
      ;;
    --pull)
      pull_images=true
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${env_file}" != "" ]]; then
  if [[ ! -f "${env_file}" && -f "${REPO_DIR}/${env_file}" ]]; then
    env_file="${REPO_DIR}/${env_file}"
  fi
  if [[ ! -f "${env_file}" ]]; then
    echo "Env file not found: ${env_file}" >&2
    exit 1
  fi
fi

profiles=()
service_args=()

add_profile() {
  local profile="$1"
  for existing in "${profiles[@]:-}"; do
    [[ "${existing}" == "${profile}" ]] && return 0
  done
  profiles+=("${profile}")
}

IFS=',' read -r -a selected_services <<<"${services}"
for service in "${selected_services[@]}"; do
  case "${service}" in
    all)
      add_profile backend
      add_profile admin
      add_profile website
      add_profile nodeagent
      service_args+=(backend admin website)
      service_args+=(nodeagent)
      ;;
    app)
      echo "Service 'app' is not started by Docker runtime. Use livemask-docs/scripts/local-dev.sh --app to run Flutter locally." >&2
      exit 2
      ;;
    backend|admin|website|nodeagent)
      add_profile "${service}"
      service_args+=("${service}")
      ;;
    "")
      ;;
    *)
      echo "Unknown service: ${service}" >&2
      exit 2
      ;;
  esac
done

if [[ "${with_deps}" == "true" ]]; then
  add_profile deps
  service_args=(postgres redis "${service_args[@]}")
fi

compose_base() {
  local args=()
  [[ "${env_file}" != "" ]] && args+=(--env-file "${env_file}")
  for profile in "${profiles[@]:-}"; do
    args+=(--profile "${profile}")
  done
  docker compose "${args[@]}" -f "${compose_file}" "$@"
}

export BACKEND_COMMAND="/usr/local/go/bin/go run ."
if [[ "${auto_reload}" == "true" ]]; then
  export BACKEND_COMMAND="export PATH=/usr/local/go/bin:/go/bin:\${PATH}; /usr/local/go/bin/go install github.com/air-verse/air@latest && /go/bin/air"
fi

case "${command}" in
  start)
    [[ "${pull_images}" == "true" ]] && compose_base pull "${service_args[@]}"
    compose_base up -d --force-recreate "${service_args[@]}"
    ;;
  stop)
    compose_base down --remove-orphans
    ;;
  restart)
    compose_base down --remove-orphans
    [[ "${pull_images}" == "true" ]] && compose_base pull "${service_args[@]}"
    compose_base up -d --force-recreate "${service_args[@]}"
    ;;
  status)
    compose_base ps
    echo
    echo "Backend health:"
    curl -fsS "http://127.0.0.1:${LIVEMASK_BACKEND_HTTP_PORT:-18080}/api/v1/health" 2>/dev/null || echo "backend health unavailable"
    echo
    echo "Admin:"
    curl -fsS -o /dev/null -w "HTTP %{http_code}\n" "http://127.0.0.1:${LIVEMASK_ADMIN_PORT:-3001}/login" 2>/dev/null || echo "admin unavailable"
    echo
    echo "Website:"
    curl -fsS -o /dev/null -w "HTTP %{http_code}\n" "http://127.0.0.1:${LIVEMASK_WEBSITE_PORT:-3002}/" 2>/dev/null || echo "website unavailable"
    echo
    echo "App:"
    echo "managed locally by livemask-app/scripts/local-app.sh, not Docker runtime"
    echo
    echo "NodeAgent status:"
    curl -fsS "http://127.0.0.1:${LIVEMASK_NODEAGENT_PORT:-19090}/config/status" 2>/dev/null || echo "nodeagent status unavailable"
    echo
    ;;
  pull)
    compose_base pull "${service_args[@]}"
    ;;
  logs)
    compose_base logs -f "${service_args[@]}"
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
