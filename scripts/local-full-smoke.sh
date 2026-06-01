#!/usr/bin/env bash
# Run the LiveMask full-link smoke suite against the local development runtime.
#
# This script intentionally replaces the old GitHub-hosted full staging smoke.
# It should run on a developer/local runtime where logs, containers, and test
# data can be inspected directly without occupying the GitHub self-hosted runner.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_DIR}"

START_RUNTIME=0
STOP_AFTER=0
SELECTED=""

usage() {
  cat <<'EOF'
Usage:
  bash scripts/local-full-smoke.sh [--start] [--stop-after] [--only LIST]

Options:
  --start       Start/sync the local dev runtime before running smoke scripts.
  --stop-after  Stop the local dev runtime after the suite completes.
  --only LIST   Comma-separated script basenames to run, for example:
                smoke,node,protocol-capability

Default:
  Assumes the local runtime is already running and executes the full suite.

Local runtime ports:
  Backend   http://127.0.0.1:18080
  Admin     http://127.0.0.1:3001
  Website   http://127.0.0.1:3002
  NodeAgent http://127.0.0.1:19090
  JobSvc    http://127.0.0.1:19191
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start) START_RUNTIME=1; shift ;;
    --stop-after) STOP_AFTER=1; shift ;;
    --only) SELECTED="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

export COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.local.yml}"
export LIVEMASK_STACK_NAME="${LIVEMASK_STACK_NAME:-livemask-local}"
export LIVEMASK_BACKEND_HTTP_PORT="${LIVEMASK_BACKEND_HTTP_PORT:-18080}"
export LIVEMASK_ADMIN_PORT="${LIVEMASK_ADMIN_PORT:-3001}"
export LIVEMASK_WEBSITE_PORT="${LIVEMASK_WEBSITE_PORT:-3002}"
export LIVEMASK_NODEAGENT_PORT="${LIVEMASK_NODEAGENT_PORT:-19090}"
export LIVEMASK_JOB_SERVICE_PORT="${LIVEMASK_JOB_SERVICE_PORT:-19191}"
export POSTGRES_PORT="${POSTGRES_PORT:-15432}"
export REDIS_PORT="${REDIS_PORT:-16379}"

SMOKE_SCRIPTS=(
  smoke
  node
  billing
  connect
  geoip
  geoip-credentials
  growth-revenue
  release-control
  jobs
  dashboard
  protocol-endpoint
  protocol-capability
  nodeagent-release
  website
  system-settings
  app-release
  sentry-config
  observability
  i18n
  bandwidth-auto-reconnect
  traffic-analytics-v2
  admin-nav-ia
  jobs-hardening
  nodeagent-config
  nodeagent-speedtest
  nat-sharing
  openapi-drift
  real-data-closed-loop
  jobs-real-data
  node-status-freshness
  app-runtime-governance
  protocol-parity
  log-retention
  admin-nodes-ux
  website-i18n-announcement
  secret-leak-standard
)

should_run() {
  local name="$1"
  [[ -z "${SELECTED}" ]] && return 0
  local item
  IFS=',' read -r -a parts <<<"${SELECTED}"
  for item in "${parts[@]}"; do
    item="$(echo "${item}" | xargs)"
    [[ "${item}" == "${name}" ]] && return 0
  done
  return 1
}

cleanup() {
  local rc=$?
  if [[ "${STOP_AFTER}" -eq 1 ]]; then
    bash scripts/local-dev.sh stop || true
  fi
  exit "${rc}"
}
trap cleanup EXIT

if [[ "${START_RUNTIME}" -eq 1 ]]; then
  bash scripts/local-dev.sh start
fi

mkdir -p /tmp/livemask-runtime
bash scripts/dev-runtime-status.sh \
  --compose "${COMPOSE_FILE}" \
  --env local \
  --output /tmp/livemask-runtime/local-full-smoke-status.json || true

echo "=== LiveMask Local Full Smoke ==="
echo "compose: ${COMPOSE_FILE}"
echo "backend: http://127.0.0.1:${LIVEMASK_BACKEND_HTTP_PORT}"
echo "selected: ${SELECTED:-all}"
echo ""

failed=0
for name in "${SMOKE_SCRIPTS[@]}"; do
  should_run "${name}" || continue
  script="scripts/${name}-smoke.sh"
  [[ "${name}" == "smoke" ]] && script="scripts/smoke.sh"
  if [[ ! -f "${script}" ]]; then
    echo "SKIP: ${name} (${script} not found)"
    continue
  fi
  echo ""
  echo "===== ${name} ====="
  if bash "${script}"; then
    echo "PASS: ${name}"
  else
    echo "FAIL: ${name}" >&2
    failed=1
  fi
done

if [[ "${failed}" -ne 0 ]]; then
  echo ""
  echo "Local full smoke FAILED. Inspect local containers and /tmp/livemask-runtime/local-full-smoke-status.json." >&2
  exit 1
fi

echo ""
echo "Local full smoke PASSED."
