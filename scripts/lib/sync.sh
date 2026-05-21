#!/usr/bin/env bash
# TASK-LOCAL-DEV-AUTO-SYNC-001
# Shared auto-sync library for local/dev runtime.
#
# This file provides targeted container sync/rebuild/recreate after cross-repo
# builds. It NEVER runs docker compose down, down -v, or deletes volumes.
#
# Usage (from local-dev.sh or runtime.sh):
#   source "${SCRIPT_DIR}/lib/sync.sh"
#   lm_sync_detect_services "livemask-admin"   # => prints "admin"
#   lm_sync_detect_services "livemask-backend" # => prints "backend"
#   lm_sync_execute --dry-run "admin" "backend"
#   lm_sync_execute "admin"

if [[ -n "${LIVEMASK_SYNC_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
LIVEMASK_SYNC_SH_LOADED=1

# ---------------------------------------------------------------------------
# Repo → Docker service mapping
# Returns space-separated Docker compose services for a repo name.
# Supports both bare repo names (livemask-admin) and full paths.
# ---------------------------------------------------------------------------
lm_sync_detect_services() {
  local input="$1"
  local repo_name

  # Extract repo name from full path or bare name
  if [[ "${input}" == */* ]]; then
    repo_name="$(basename "${input}")"
  else
    repo_name="${input}"
  fi

  case "${repo_name}" in
    livemask-admin)     echo "admin" ;;
    livemask-website)   echo "website" ;;
    livemask-backend)   echo "backend" ;;
    livemask-nodeagent) echo "nodeagent" ;;
    livemask-job-service) echo "job-service" ;;
    livemask-app)
      echo "app"
      ;;
    *)
      echo "" >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Check whether a service is managed by Docker compose in local mode.
# Returns 0 if yes, 1 if no (e.g. app).
# ---------------------------------------------------------------------------
lm_sync_is_docker_service() {
  local service="$1"
  case "${service}" in
    backend|admin|website|nodeagent|job-service) return 0 ;;
    app) return 1 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Describe how the service handles code changes (bind-mount vs image-build).
# ---------------------------------------------------------------------------
lm_sync_service_type() {
  local service="$1"
  case "${service}" in
    admin|website)  echo "frontend:bind-mount" ;;
    backend|nodeagent|job-service) echo "go:bind-mount" ;;
    app)            echo "flutter:local" ;;
    *)              echo "unknown" ;;
  esac
}

# ---------------------------------------------------------------------------
# Human-readable description for sync output.
# ---------------------------------------------------------------------------
lm_sync_service_desc() {
  local service="$1"
  case "${service}" in
    admin)      echo "Admin UI (Next.js, bind-mount + hot reload)" ;;
    website)    echo "Website (Vite, bind-mount + hot reload)" ;;
    backend)    echo "Backend (Go, bind-mount, go run .)" ;;
    nodeagent)  echo "NodeAgent (Go, bind-mount, go run)" ;;
    job-service) echo "Job Service (Go, bind-mount, go run)" ;;
    app)        echo "Flutter App (not Docker-managed)" ;;
    *)          echo "${service} (unknown)" ;;
  esac
}

# ---------------------------------------------------------------------------
# Validate service names, exiting on unknown.
# ---------------------------------------------------------------------------
lm_sync_validate_services() {
  local invalid=0
  for svc in "$@"; do
    case "${svc}" in
      backend|admin|website|nodeagent|job-service|app) ;;
      "")
        ;;
      *)
        echo "[sync] ERROR: Unknown service '${svc}'. Valid: backend, admin, website, nodeagent, job-service, app" >&2
        invalid=1
        ;;
    esac
  done
  return "${invalid}"
}

# ---------------------------------------------------------------------------
# Check if a given Docker container is currently running.
# ---------------------------------------------------------------------------
lm_sync_container_running() {
  local service="$1"
  local cname="livemask-local-${service}-1"
  docker inspect --format '{{.State.Status}}' "${cname}" 2>/dev/null | grep -q "^running$"
}

# ---------------------------------------------------------------------------
# Targeted sync: rebuild/recreate only the specified Docker services.
#
# Flags (parsed from args):
#   --dry-run   Show what would happen without executing.
#
# The function NEVER runs docker compose down or deletes volumes.
# It uses targeted `docker compose up -d --build <service>` for services
# that need image rebuild, and targeted `docker compose up -d --force-recreate
# <service>` for services that run with bind mounts.
#
# For local mode (bind mounts), frontend services are already live via hot
# reload; Go services are restarted to pick up any dependency or env changes.
# ---------------------------------------------------------------------------
lm_sync_execute() {
  local dry_run=false
  local args=()

  # Parse leading flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        shift
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done

  local services=("${args[@]}")

  if [[ "${#services[@]}" -eq 0 ]]; then
    echo "[sync] No services specified for execution." >&2
    return 1
  fi

  echo "============================================"
  echo " Local/Dev Runtime Auto-Sync"
  echo "============================================"

  if [[ "${dry_run}" == "true" ]]; then
    echo " MODE: DRY-RUN (no changes made)"
  else
    echo " MODE: LIVE"
  fi
  echo ""

  # Validate all services first
  lm_sync_validate_services "${services[@]}"
  echo ""

  # Process each service
  local docker_services=()
  local has_app=false
  local has_go=false
  local has_frontend=false

  for svc in "${services[@]}"; do
    local stype
    stype="$(lm_sync_service_type "${svc}")"
    local desc
    desc="$(lm_sync_service_desc "${svc}")"

    echo "--- Service: ${svc} (${desc}) ---"

    if [[ "${stype}" == "flutter:local" ]]; then
      has_app=true
      echo "  Type:     Flutter (not Docker-managed)"
      echo "  Sync:     N/A — use livemask-app/scripts/local-app.sh for build/run"
      echo "            or rebuild manually."
      echo ""
      continue
    fi

    if [[ "${stype}" != "unknown" ]]; then
      local cname="livemask-local-${svc}-1"
      local running=false
      if docker inspect --format '{{.State.Status}}' "${cname}" 2>/dev/null | grep -q "^running$"; then
        running=true
      fi

      echo "  Container: ${cname}"
      echo "  Running:   ${running}"

      if [[ "${stype}" == *"bind-mount"* ]]; then
        echo "  Bind mount: YES — source code changes are live via volume mount"
        if [[ "${stype}" == frontend:* ]]; then
          echo "  Hot reload: YES — dev server auto-reloads on file changes"
          has_frontend=true
        fi
        if [[ "${stype}" == go:* ]]; then
          echo "  'go run':   YES — source is re-compiled on each request (dev mode)"
          has_go=true
        fi
      fi
      docker_services+=("${svc}")
    fi
    echo ""
  done

  # Show overall sync plan
  echo "--- Sync Plan ---"
  if [[ "${#docker_services[@]}" -eq 0 ]]; then
    echo "  No Docker services to sync."
  else
    echo "  Docker services: ${docker_services[*]}"
    echo "  Action: docker compose up -d --force-recreate <services>"
    echo "  No 'docker compose down' will be executed."
    echo "  No volumes will be deleted."
  fi
  echo ""

  if [[ "${dry_run}" == "true" ]]; then
    echo "--- DRY-RUN: No changes applied ---"
    return 0
  fi

  # --- LIVE EXECUTION ---
  echo "--- Executing Sync ---"

  if [[ "${#docker_services[@]}" -eq 0 ]]; then
    echo "  No Docker services to sync. Done."
    return 0
  fi

  local compose_file
  local sync_repo_root
  # sync.sh lives in scripts/lib/; repo root is two directories up
  sync_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  compose_file="${REPO_DIR:-${sync_repo_root}}/infra/docker-compose.local.yml"

  if [[ ! -f "${compose_file}" ]]; then
    echo "  ERROR: Compose file not found: ${compose_file}" >&2
    return 1
  fi

  # Build profiles and service list for targeted compose command
  local profiles=()
  local svc_list=()
  for svc in "${docker_services[@]}"; do
    case "${svc}" in
      admin)       profiles+=(--profile admin) ;;
      website)     profiles+=(--profile website) ;;
      nodeagent)   profiles+=(--profile nodeagent) ;;
      job-service) profiles+=(--profile "job-service") ;;
    esac
    svc_list+=("${svc}")
  done

  # Remove duplicate profiles
  local unique_profiles=()
  for p in "${profiles[@]:-}"; do
    local seen=false
    for up in "${unique_profiles[@]:-}"; do
      [[ "${up}" == "${p}" ]] && seen=true && break
    done
    if [[ "${seen}" == "false" ]]; then
      unique_profiles+=("${p}")
    fi
  done

  local service_list
  service_list="$(IFS=','; echo "${svc_list[*]}")"

  echo "  Service(s): ${service_list}"
  echo "  Command: docker compose up -d --force-recreate ${svc_list[*]}"
  echo ""

  # Check docker is available
  if ! command -v docker &>/dev/null; then
    echo "  ERROR: docker CLI not found." >&2
    return 1
  fi

  if ! docker info &>/dev/null; then
    echo "  ERROR: docker daemon is not running." >&2
    return 1
  fi

  # Execute targeted compose up — use full path for -f
  set +e
  if [[ "${#unique_profiles[@]}" -gt 0 ]]; then
    docker compose -f "${compose_file}" "${unique_profiles[@]}" up -d --force-recreate "${svc_list[@]}"
  else
    docker compose -f "${compose_file}" up -d --force-recreate "${svc_list[@]}"
  fi
  local exit_code=$?
  set -e

  if [[ "${exit_code}" -ne 0 ]]; then
    echo "  WARNING: docker compose up exited with code ${exit_code}" >&2
    echo "  Some services may not have started correctly." >&2
  fi

  echo ""
  echo "--- Sync Complete ---"
  echo "  Action: docker compose up -d --force-recreate"
  echo "  Services: ${service_list}"
  echo "  No volumes deleted."
  echo "  No 'docker compose down' executed."
  echo ""
}
